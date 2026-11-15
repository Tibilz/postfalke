import SwiftUI
import MailEngine

/// A conversation: every message as a card, the newest open, older ones collapsed.
struct ThreadDetailView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(MailStore.self) private var mail

    let folder: FolderKey
    let thread: MessageThread
    var compose: (ComposeDraft) -> Void
    var close: () -> Void

    @State private var expanded: Set<UInt32> = []
    @State private var loaded: [UInt32: ProcessedMessage] = [:]

    private var subject: String {
        MessageActions.subject(message: loaded[thread.latest.uid], header: thread.latest, folder: folder, mail: mail)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Threading.normalizedSubject(subject) == subject.lowercased() ? subject : stripPrefixes(subject))
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(thread.messages.count) E-Mails")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                ForEach(thread.messages) { header in
                    card(header)
                }
            }
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            MessageToolbar(folder: folder, messages: thread.messages, latest: thread.latest,
                           loaded: loaded[thread.latest.uid], compose: compose, close: close)
        }
        .onAppear {
            // The newest message and every unread one start open.
            if expanded.isEmpty {
                expanded = Set([thread.latest.uid] + thread.messages.filter { !$0.isSeen }.map(\.uid))
            }
        }
    }

    private func stripPrefixes(_ text: String) -> String {
        var result = text
        while let range = result.range(of: #"^\s*(re|aw|fwd?|wg)\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            result.removeSubrange(range)
        }
        return result
    }

    private func card(_ header: MessageHeader) -> some View {
        let isOpen = expanded.contains(header.uid)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                AvatarView(name: header.from.first?.displayName ?? "", size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(header.from.first?.displayName ?? "Unbekannter Absender")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if !header.isSeen {
                            Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                                .accessibilityLabel("Ungelesen")
                        }
                        Spacer(minLength: 8)
                        Text(MessageRow.shortDate(header.sortDate))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if !isOpen {
                        Text(mail.preview(folder, header: header) ?? (header.isEncrypted ? "Verschlüsselte E-Mail" : ""))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                if isOpen {
                    cardMenu(header)
                }
            }
            .padding(12)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy) {
                    if isOpen { expanded.remove(header.uid) } else { expanded.insert(header.uid) }
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isOpen ? "Zuklappen" : "Aufklappen")

            if isOpen {
                Divider().padding(.leading, 12)
                MessageBody(folder: folder, header: header) { loaded[header.uid] = $0 }
                    .padding(.bottom, 12)
            }
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
    }

    private func cardMenu(_ header: MessageHeader) -> some View {
        Menu {
            if let account = accounts.account(folder.accountID) {
                Button {
                    compose(MessageActions.reply(header, message: loaded[header.uid], all: false, account: account, folder: folder, mail: mail))
                } label: { Label("Antworten", systemImage: "arrowshape.turn.up.left") }
                Button {
                    compose(MessageActions.reply(header, message: loaded[header.uid], all: true, account: account, folder: folder, mail: mail))
                } label: { Label("Allen antworten", systemImage: "arrowshape.turn.up.left.2") }
                Button {
                    compose(MessageActions.forward(header, message: loaded[header.uid], account: account, folder: folder, mail: mail))
                } label: { Label("Weiterleiten", systemImage: "arrowshape.turn.up.right") }
            }
            Divider()
            Button(role: .destructive) {
                if thread.messages.count == 1 { close() }
                Task { await mail.delete(folder, header: header) }
            } label: { Label("Diese E-Mail löschen", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 28)
        }
        .accessibilityLabel("Aktionen für diese E-Mail")
    }
}
