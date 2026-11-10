import SwiftUI
import MailEngine

struct RootView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(MailStore.self) private var mail
    @Environment(KeyStore.self) private var keys
    @State private var keyImport = KeyImportFlow()

    @State private var selectedFolder: FolderKey?
    @State private var selectedMessage: UInt32?
    @State private var showSettings = false
    @State private var showAddAccount = false
    @State private var draft: ComposeDraft?

    var body: some View {
        Group {
            if accounts.accounts.isEmpty {
                WelcomeView { showAddAccount = true }
            } else {
                split
            }
        }
        .sheet(isPresented: $showAddAccount) {
            NavigationStack { AccountEditView(account: nil) }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: $draft) { draft in
            ComposeView(draft: draft)
        }
        // Key files handed over by other apps (Files, Bitwarden attachments, AirDrop …).
        .onOpenURL { url in
            if url.isFileURL { keyImport.start(url: url, keys: keys) }
        }
        .keyImportAlerts(keyImport)
        .task(id: accounts.accounts.map(\.id)) {
            selectDefaultFolder()
            await withTaskGroup(of: Void.self) { group in
                for account in accounts.accounts {
                    group.addTask { await mail.loadFolders(account.id) }
                }
            }
        }
    }

    private var split: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedFolder, showSettings: $showSettings)
        } content: {
            if let key = selectedFolder {
                MessageListView(folder: key, selection: $selectedMessage, compose: { draft = $0 })
                    .id(key)
            } else {
                ContentUnavailableView("Kein Ordner ausgewählt", systemImage: "folder")
            }
        } detail: {
            if let key = selectedFolder, let uid = selectedMessage,
               let header = mail.mailbox(key).headers.first(where: { $0.uid == uid }) {
                MessageDetailView(folder: key, header: header,
                                  compose: { draft = $0 },
                                  close: { selectedMessage = nil })
                    .id("\(key.path)-\(uid)")
            } else {
                ContentUnavailableView("Keine Nachricht ausgewählt", systemImage: "envelope.open")
            }
        }
        .onChange(of: selectedFolder) { selectedMessage = nil }
    }

    private func selectDefaultFolder() {
        if let current = selectedFolder, accounts.account(current.accountID) != nil { return }
        selectedMessage = nil
        selectedFolder = accounts.accounts.first.map { FolderKey(accountID: $0.id, path: "INBOX") }
    }
}

struct WelcomeView: View {
    var addAccount: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 80))
                .foregroundStyle(.tint)
            Text("Willkommen bei Postfalke")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("E-Mail über IMAP und SMTP mit eingebauter OpenPGP-Verschlüsselung. Schlüssel und Passwörter bleiben auf diesem Gerät.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: addAccount) {
                Text("E-Mail-Konto einrichten")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: 520)
    }
}
