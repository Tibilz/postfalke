import SwiftUI
import MailEngine

struct SidebarView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(MailStore.self) private var mail
    @Binding var selection: FolderKey?
    @Binding var showSettings: Bool

    var body: some View {
        List(selection: $selection) {
            ForEach(accounts.accounts) { account in
                Section(account.email) {
                    let folders = mail.folders[account.id] ?? []
                    if folders.isEmpty {
                        // Until the folder list has loaded the inbox is always reachable.
                        Label("Posteingang", systemImage: "tray")
                            .tag(FolderKey(accountID: account.id, path: "INBOX"))
                    }
                    ForEach(folders) { folder in
                        if folder.isSelectable {
                            FolderRow(folder: folder)
                                .tag(FolderKey(accountID: account.id, path: folder.path))
                        } else {
                            FolderRow(folder: folder).foregroundStyle(.secondary)
                        }
                    }
                    if let error = mail.folderErrors[account.id] {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("Postfalke")
        .refreshable {
            for account in accounts.accounts { await mail.loadFolders(account.id) }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Label("Einstellungen", systemImage: "gearshape")
                }
            }
        }
    }
}

struct FolderRow: View {
    let folder: MailFolder

    static func title(_ folder: MailFolder) -> String {
        switch folder.role {
        case .inbox: return "Posteingang"
        case .drafts: return "Entwürfe"
        case .sent: return "Gesendet"
        case .archive: return "Archiv"
        case .junk: return "Spam"
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
        HStack {
            Label(Self.title(folder), systemImage: Self.icon(folder))
                .padding(.leading, folder.role == nil ? CGFloat(folder.depth) * 14 : 0)
            Spacer()
            if let unread = folder.unread, unread > 0 {
                Text("\(unread)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
