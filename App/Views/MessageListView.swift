import SwiftUI
import MailEngine

struct MessageListView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(MailStore.self) private var mail
    @Environment(\.scenePhase) private var scenePhase
    @Environment(NetworkMonitor.self) private var network
    let folder: FolderKey
    @Binding var selection: UInt32?
    var compose: (ComposeDraft) -> Void

    @State private var query = ""
    @State private var searchResults: [MessageHeader]?
    @State private var searchError: String?
    @State private var isSearching = false
    @State private var unreadOnly = false
    @AppStorage(MailStore.threadingKey) private var groupConversations = true

    private var state: MailboxState { mail.mailbox(folder) }
    private var isOutgoing: Bool {
        let role = mail.folder(folder)?.role
        return role == .sent || role == .drafts
    }

    private var shown: [MessageHeader] {
        let all = searchResults ?? state.headers
        return unreadOnly ? all.filter { !$0.isSeen } : all
    }

    /// Rows: conversations (newest message represents it), or single messages.
    private var rows: [MessageThread] {
        let isDrafts = mail.folder(folder)?.role == .drafts
        guard groupConversations, searchResults == nil, !isDrafts else {
            return shown.map { MessageThread(messages: [$0]) }
        }
        let threads = Threading.group(state.headers)
        return unreadOnly ? threads.filter { $0.unreadCount > 0 } : threads
    }

    var body: some View {
        let state = state
        List(selection: $selection) {
            if let error = searchError ?? (showsQuietOffline ? nil : state.error), network.isOnline {
                ErrorNotice(message: error)
                    .listRowSeparator(.hidden)
            }
            ForEach(rows) { thread in
                let header = thread.latest
                MessageRow(header: header,
                           subject: mail.subject(folder, header: header),
                           preview: mail.preview(folder, header: header),
                           showRecipient: isOutgoing,
                           threadCount: thread.messages.count,
                           threadUnread: thread.unreadCount > 0,
                           threadFlagged: thread.isFlagged)
                    .tag(header.uid)
                    .listRowInsets(EdgeInsets(top: 10, leading: 6, bottom: 10, trailing: 16))
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 26 }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await remove(thread) }
                        } label: {
                            Label("Löschen", systemImage: "trash")
                        }
                        Button {
                            Task { await mail.setFlagged(folder, header: header, flagged: !header.isFlagged) }
                        } label: {
                            Label(header.isFlagged ? "Markierung entfernen" : "Markieren",
                                  systemImage: header.isFlagged ? "flag.slash" : "flag")
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .leading) {
                        let unread = thread.unreadCount > 0
                        Button {
                            Task {
                                if unread {
                                    for message in thread.messages where !message.isSeen {
                                        await mail.setSeen(folder, header: message, seen: true)
                                    }
                                } else {
                                    await mail.setSeen(folder, header: header, seen: false)
                                }
                            }
                        } label: {
                            Label(unread ? "Gelesen" : "Ungelesen",
                                  systemImage: unread ? "envelope.open" : "envelope.badge")
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button {
                            Task { await mail.setSeen(folder, header: header, seen: !header.isSeen) }
                        } label: {
                            Label(header.isSeen ? "Als ungelesen markieren" : "Als gelesen markieren",
                                  systemImage: header.isSeen ? "envelope.badge" : "envelope.open")
                        }
                        Button {
                            Task { await mail.setFlagged(folder, header: header, flagged: !header.isFlagged) }
                        } label: {
                            Label(header.isFlagged ? "Markierung entfernen" : "Markieren", systemImage: "flag")
                        }
                        Divider()
                        Button(role: .destructive) {
                            Task { await remove(thread) }
                        } label: {
                            Label("Löschen", systemImage: "trash")
                        }
                    }
            }
            if searchResults == nil, !unreadOnly, state.canLoadMore {
                Button {
                    Task { await mail.loadMore(folder) }
                } label: {
                    HStack {
                        Spacer()
                        if state.isLoading { ProgressView() } else { Text("Ältere E-Mails laden") }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .disabled(state.isLoading)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay {
            if isSearching || (state.isLoading && !state.hasLoaded) {
                ProgressView()
            } else if rows.isEmpty, searchResults != nil {
                ContentUnavailableView.search(text: query)
            } else if rows.isEmpty, unreadOnly {
                ContentUnavailableView("Keine ungelesenen E-Mails", systemImage: "envelope.open")
            } else if rows.isEmpty, state.hasLoaded {
                ContentUnavailableView("Keine E-Mails", systemImage: "tray")
            }
        }
        .navigationTitle(mail.folder(folder).map(FolderRow.title) ?? "Posteingang")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, prompt: "Suchen")
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
        .onChange(of: network.isOnline) {
            if network.isOnline { Task { await mail.refresh(folder) } }
        }
        .onChange(of: scenePhase) {
            // Coming back to the app: look for new mail.
            if scenePhase == .active { Task { await mail.refresh(folder) } }
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    withAnimation { unreadOnly.toggle() }
                } label: {
                    Label("Nach Ungelesen filtern",
                          systemImage: unreadOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItem(placement: .status) {
                UpdateStatusText(lastUpdated: state.lastUpdated, isLoading: state.isLoading && state.hasLoaded,
                                 detail: showsQuietOffline ? "Gespeicherte E-Mails" : statusDetail,
                                 offline: !network.isOnline, unreachable: network.isOnline && showsQuietOffline)
            }
            ToolbarItem(placement: .bottomBar) {
                Button {
                    if let account = accounts.account(folder.accountID) { compose(.new(account: account)) }
                } label: {
                    Label("Verfassen", systemImage: "square.and.pencil")
                }
            }
        }
    }

    /// No network, or the server cannot be reached while cached mail is shown.
    private var showsQuietOffline: Bool {
        !network.isOnline || (state.isUnreachable && state.hasLoaded && !state.headers.isEmpty)
    }

    private var statusDetail: String? {
        if unreadOnly { return "Gefiltert: Ungelesen" }
        let unread = state.headers.filter { !$0.isSeen }.count
        return unread > 0 ? "\(unread) ungelesen" : nil
    }

    /// Deletes a whole conversation (or the single message).
    private func remove(_ thread: MessageThread) async {
        let uids = Set(thread.messages.map(\.uid))
        if let selected = selection, uids.contains(selected) { selection = nil }
        searchResults?.removeAll { uids.contains($0.uid) }
        for message in thread.messages { await mail.delete(folder, header: message) }
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
    var preview: String?
    var showRecipient = false
    var threadCount = 1
    var threadUnread = false
    var threadFlagged = false

    private var isUnread: Bool { !header.isSeen || threadUnread }
    private var isFlagged: Bool { header.isFlagged || threadFlagged }

    private var people: String {
        let list = showRecipient ? header.to : header.from
        let names = list.map(\.displayName).joined(separator: ", ")
        if names.isEmpty { return showRecipient ? "Kein Empfänger" : "Unbekannter Absender" }
        return showRecipient ? "An: \(names)" : names
    }

    /// Encrypted mail with a protected subject only carries "..." until it is opened once.
    private var subjectIsHidden: Bool { header.isEncrypted && (subject == "..." || subject == "…") }

    private var subjectText: String {
        if subjectIsHidden { return "Betreff verschlüsselt" }
        return subject.isEmpty ? "Kein Betreff" : subject
    }

    static func shortDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Gestern" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: .now)).day,
           days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year(.twoDigits))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Unread dot and flag, in their own column left of the text.
            VStack(spacing: 6) {
                Circle()
                    .fill(isUnread ? Color.accentColor : Color.clear)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(!isUnread)
                    .accessibilityLabel("Ungelesen")
                if isFlagged {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Markiert")
                }
            }
            .frame(width: 20)
            .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(people)
                        .font(.headline)
                        .lineLimit(1)
                    if header.isAnswered {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if threadCount > 1 {
                        Text("\(threadCount)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                            .accessibilityLabel("\(threadCount) E-Mails")
                    }
                    Spacer(minLength: 8)
                    Text(Self.shortDate(header.sortDate))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(subjectText)
                        .font(.subheadline)
                        .foregroundStyle(subjectIsHidden ? Color.secondary : Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Group {
                        if header.mayHaveAttachments { Image(systemName: "paperclip") }
                        if header.isSigned { Image(systemName: "checkmark.seal") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if header.isEncrypted {
                    Label(subjectIsHidden ? "Verschlüsselt – zum Lesen öffnen" : "Verschlüsselte E-Mail", systemImage: "lock.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .labelStyle(TightLabelStyle())
                } else if let preview, !preview.isEmpty {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

/// Label with a small gap between icon and text, as in Mail's preview line.
private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.caption)
            configuration.title
        }
    }
}
