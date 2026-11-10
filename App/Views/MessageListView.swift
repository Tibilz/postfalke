import SwiftUI
import MailEngine

struct MessageListView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(MailStore.self) private var mail
    @Environment(\.scenePhase) private var scenePhase
    let folder: FolderKey
    @Binding var selection: UInt32?
    var compose: (ComposeDraft) -> Void

    @State private var query = ""
    @State private var searchResults: [MessageHeader]?
    @State private var searchError: String?
    @State private var isSearching = false

    private var state: MailboxState { mail.mailbox(folder) }
    private var isOutgoing: Bool {
        let role = mail.folder(folder)?.role
        return role == .sent || role == .drafts
    }

    var body: some View {
        let state = state
        let shown = searchResults ?? state.headers
        List(selection: $selection) {
            if let error = searchError ?? state.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            ForEach(shown) { header in
                MessageRow(header: header, subject: mail.subject(folder, header: header), showRecipient: isOutgoing)
                    .tag(header.uid)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await remove(header) }
                        } label: {
                            Label("Löschen", systemImage: "trash")
                        }
                        Button {
                            Task { await mail.setFlagged(folder, header: header, flagged: !header.isFlagged) }
                        } label: {
                            Label("Markieren", systemImage: header.isFlagged ? "star.slash" : "star")
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            Task { await mail.setSeen(folder, header: header, seen: !header.isSeen) }
                        } label: {
                            Label(header.isSeen ? "Ungelesen" : "Gelesen",
                                  systemImage: header.isSeen ? "envelope.badge" : "envelope.open")
                        }
                        .tint(.blue)
                    }
            }
            if searchResults == nil, state.canLoadMore {
                Button {
                    Task { await mail.loadMore(folder) }
                } label: {
                    HStack {
                        Spacer()
                        if state.isLoading { ProgressView() } else { Text("Ältere Nachrichten laden") }
                        Spacer()
                    }
                }
                .disabled(state.isLoading)
            }
        }
        .listStyle(.plain)
        .overlay {
            if isSearching || (state.isLoading && !state.hasLoaded) {
                ProgressView()
            } else if shown.isEmpty, searchResults != nil {
                ContentUnavailableView.search(text: query)
            } else if shown.isEmpty, state.hasLoaded {
                ContentUnavailableView("Keine Nachrichten", systemImage: "tray")
            }
        }
        .navigationTitle(mail.folder(folder).map(FolderRow.title) ?? "Posteingang")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Auf dem Server suchen")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: query) {
            if query.isEmpty {
                searchResults = nil
                searchError = nil
            }
        }
        .refreshable { await mail.refresh(folder) }
        .task {
            // Refresh now and then keep looking while the list is on screen.
            while !Task.isCancelled {
                await mail.refresh(folder)
                try? await Task.sleep(for: .seconds(90))
            }
        }
        .onChange(of: scenePhase) {
            // Coming back to the app: look for new mail.
            if scenePhase == .active { Task { await mail.refresh(folder) } }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let account = accounts.account(folder.accountID) { compose(.new(account: account)) }
                } label: {
                    Label("Verfassen", systemImage: "square.and.pencil")
                }
            }
        }
    }

    private func remove(_ header: MessageHeader) async {
        if selection == header.uid { selection = nil }
        searchResults?.removeAll { $0.uid == header.uid }
        await mail.delete(folder, header: header)
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            searchResults = try await mail.search(folder, query: text)
            searchError = nil
        } catch {
            searchError = MailStore.describe(error)
        }
    }
}

struct MessageRow: View {
    let header: MessageHeader
    var subject: String
    var showRecipient = false

    private var people: String {
        let list = showRecipient ? header.to : header.from
        let names = list.map(\.displayName).joined(separator: ", ")
        if names.isEmpty { return showRecipient ? "(kein Empfänger)" : "(unbekannter Absender)" }
        return showRecipient ? "An: \(names)" : names
    }

    static func shortDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Gestern" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(header.isSeen ? Color.clear : Color.accentColor)
                .frame(width: 9, height: 9)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(people)
                        .font(.headline)
                        .fontWeight(header.isSeen ? .regular : .semibold)
                        .lineLimit(1)
                    Spacer()
                    Text(Self.shortDate(header.sortDate))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Text(subject.isEmpty ? "(kein Betreff)" : subject)
                        .font(.subheadline)
                        .lineLimit(2)
                        .foregroundStyle(header.isSeen ? .secondary : .primary)
                    Spacer(minLength: 0)
                    if header.isEncrypted {
                        Image(systemName: "lock.fill").foregroundStyle(.green)
                    }
                    if header.isSigned {
                        Image(systemName: "checkmark.seal").foregroundStyle(.secondary)
                    }
                    if header.mayHaveAttachments {
                        Image(systemName: "paperclip").foregroundStyle(.secondary)
                    }
                    if header.isAnswered {
                        Image(systemName: "arrowshape.turn.up.left").foregroundStyle(.secondary)
                    }
                    if header.isFlagged {
                        Image(systemName: "star.fill").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 3)
    }
}
