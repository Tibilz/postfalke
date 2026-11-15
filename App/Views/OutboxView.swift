import SwiftUI
import MailEngine

extension FolderKey {
    /// Pseudo folder for the outbox in the mailbox list.
    static let outbox = FolderKey(accountID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)), path: "postfalke:outbox")
    var isOutbox: Bool { self == .outbox }
}

/// Planned, waiting and failed messages, plus drafts kept only on this device.
struct OutboxView: View {
    @Environment(Outbox.self) private var outbox
    var compose: (ComposeDraft) -> Void
    @State private var localDrafts: [ComposeDraft] = []

    var body: some View {
        List {
            let planned = outbox.waiting.filter { $0.scheduled && $0.attempts == 0 }
            let waiting = outbox.waiting.filter { $0.attempts > 0 }
            if !planned.isEmpty {
                Section("Geplant") {
                    ForEach(planned) { row($0) }
                }
            }
            if !waiting.isEmpty {
                Section {
                    ForEach(waiting) { row($0) }
                } header: {
                    Text("Nicht gesendet")
                } footer: {
                    Text("Ohne Verbindung versucht Postfalke es automatisch erneut.")
                }
            }
            if !localDrafts.isEmpty {
                Section {
                    ForEach(localDrafts) { draft in
                        Button {
                            compose(draft)
                        } label: {
                            summary(draft, detail: "Zuletzt bearbeitet")
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                LocalDrafts.remove(draft.id)
                                localDrafts.removeAll { $0.id == draft.id }
                            } label: { Label("Löschen", systemImage: "trash") }
                        }
                    }
                } header: {
                    Text("Entwürfe auf diesem Gerät")
                } footer: {
                    Text("Diese Entwürfe wurden nicht auf dem Server gesichert, etwa weil keine Verbindung bestand.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if outbox.waiting.isEmpty && localDrafts.isEmpty {
                ContentUnavailableView("Postausgang leer", systemImage: "tray.and.arrow.up",
                                       description: Text("Geplante und noch nicht gesendete E-Mails erscheinen hier."))
            }
        }
        .navigationTitle("Postausgang")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { localDrafts = LocalDrafts.all() }
    }

    private func row(_ item: Outbox.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                // Editing takes it out of the queue; it is kept locally until sent again.
                if let draft = outbox.remove(item.id) {
                    LocalDrafts.save(draft)
                    compose(draft)
                }
            } label: {
                summary(item.draft, detail: item.scheduled && item.attempts == 0
                        ? "Senden: \(item.sendAt.formatted(date: .abbreviated, time: .shortened))"
                        : (item.retryAt.map { "Nächster Versuch: \($0.formatted(date: .omitted, time: .shortened))" } ?? "Wartet auf dich"))
            }
            .buttonStyle(.plain)
            if let error = item.lastError {
                ErrorNotice(message: error)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                outbox.remove(item.id)
            } label: { Label("Löschen", systemImage: "trash") }
            Button {
                outbox.sendNow(item.id)
            } label: { Label("Jetzt senden", systemImage: "paperplane") }
            .tint(.blue)
        }
    }

    private func summary(_ draft: ComposeDraft, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(draft.to.isEmpty ? "Kein Empfänger" : HeaderCodec.parseAddressList(draft.to).map(\.displayName).joined(separator: ", "))
                .font(.headline)
                .lineLimit(1)
            Text(draft.subject.isEmpty ? "Kein Betreff" : draft.subject)
                .font(.subheadline)
                .lineLimit(1)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// "Senden widerrufen" above the bottom toolbar while a message can still be withdrawn.
struct UndoSendBar: View {
    @Environment(Outbox.self) private var outbox
    var undo: (ComposeDraft) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            if let item = outbox.undoable(at: context.date) {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Wird gesendet …")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 8)
                    Button("Senden widerrufen") {
                        if let draft = outbox.remove(item.id) { undo(draft) }
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .padding(.horizontal, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: outbox.items.count)
    }
}
