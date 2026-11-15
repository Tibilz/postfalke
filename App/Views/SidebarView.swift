import SwiftUI
import MailEngine

/// "Postfächer": every account with its folders.
struct SidebarView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(MailStore.self) private var mail
    @Environment(Outbox.self) private var outbox
    @Environment(NetworkMonitor.self) private var network
    @Binding var selection: FolderKey?
    @Binding var showSettings: Bool
    var compose: () -> Void

    var body: some View {
        List(selection: $selection) {
            if !outbox.waiting.isEmpty || !LocalDrafts.all().isEmpty {
                Section {
                    FolderRow(title: "Postausgang", icon: "tray.and.arrow.up",
                              unread: outbox.waiting.isEmpty ? nil : outbox.waiting.count)
                        .tag(FolderKey.outbox)
                }
            }
            ForEach(accounts.accounts) { account in
                Section {
                    let folders = mail.folders[account.id] ?? []
                    if folders.isEmpty {
                        // Until the folder list has loaded the inbox is always reachable.
                        FolderRow(title: "Posteingang", icon: "tray", unread: nil)
                            .tag(FolderKey(accountID: account.id, path: "INBOX"))
                    }
                    ForEach(folders) { folder in
                        if folder.isSelectable {
                            FolderRow(folder: folder)
                                .tag(FolderKey(accountID: account.id, path: folder.path))
                        } else {
                            FolderRow(folder: folder)
                                .foregroundStyle(.secondary)
                                .selectionDisabled()
                        }
                    }
                    if network.isOnline, let error = mail.folderErrors[account.id] {
                        ErrorNotice(message: error)
                    }
                } header: {
                    Text(account.email)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .headerProminence(.increased)
        .navigationTitle("Postfächer")
        .refreshable {
            for account in accounts.accounts { await mail.loadFolders(account.id) }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Label("Einstellungen", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Spacer()
            }
            ToolbarItem(placement: .status) {
                UpdateStatusText(lastUpdated: inboxUpdated, isLoading: false, offline: !network.isOnline)
            }
            ToolbarItem(placement: .bottomBar) {
                Button(action: compose) {
                    Label("Verfassen", systemImage: "square.and.pencil")
                }
            }
        }
    }

    /// Most recent refresh of any inbox.
    private var inboxUpdated: Date? {
        accounts.accounts.compactMap { mail.mailbox(FolderKey(accountID: $0.id, path: "INBOX")).lastUpdated }.max()
    }
}

struct FolderRow: View {
    let title: String
    let icon: String
    let unread: Int?
    var depth = 0

    init(title: String, icon: String, unread: Int?, depth: Int = 0) {
        self.title = title
        self.icon = icon
        self.unread = unread
        self.depth = depth
    }

    init(folder: MailFolder) {
        self.init(title: Self.title(folder), icon: Self.icon(folder), unread: folder.unread,
                  depth: folder.role == nil ? folder.depth : 0)
    }

    static func title(_ folder: MailFolder) -> String {
        switch folder.role {
        case .inbox: return "Posteingang"
        case .drafts: return "Entwürfe"
        case .sent: return "Gesendet"
        case .archive: return "Archiv"
        case .junk: return "Werbung"
        case .trash: return "Papierkorb"
        case nil: return folder.shortName
        }
    }

    static func icon(_ folder: MailFolder) -> String {
        switch folder.role {
        case .inbox: return "tray"
        case .drafts: return "doc"
        case .sent: return "paperplane"
        case .archive: return "archivebox"
        case .junk: return "xmark.bin"
        case .trash: return "trash"
        case nil: return "folder"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 26)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let unread, unread > 0 {
                Text("\(unread)")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(depth) * 18)
        .padding(.vertical, 2)
    }
}
