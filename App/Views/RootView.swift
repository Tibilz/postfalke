import SwiftUI
import MailEngine

struct RootView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(MailStore.self) private var mail
    @Environment(KeyStore.self) private var keys
    @Environment(Outbox.self) private var outbox
    @Environment(AppNavigator.self) private var navigator
    @State private var draftError: String?
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
            // A new draft must get a new view; otherwise SwiftUI keeps the old one's state.
            ComposeView(draft: draft)
                .id(draft.id)
        }
        // Key files handed over by other apps (Files, Bitwarden attachments, AirDrop …).
        .onOpenURL { url in
            if url.isFileURL {
                keyImport.start(url: url, keys: keys)
            } else if let link = MailtoLink(url) {
                compose(link)
            }
        }
        // A tapped notification opens its message.
        .onChange(of: navigator.requestedMessage?.uid) {
            guard let request = navigator.requestedMessage else { return }
            navigator.requestedMessage = nil
            selectedFolder = request.folder
            Task {
                await mail.refresh(request.folder)
                selectedMessage = request.uid
            }
        }
        .keyImportAlerts(keyImport)
        .overlay(alignment: .bottom) {
            UndoSendBar { draft = $0 }
                .padding(.bottom, 76)
        }
        .alert("Entwurf lässt sich nicht öffnen", isPresented: Binding(get: { draftError != nil }, set: { if !$0 { draftError = nil } })) {
            Button("Fehler kopieren") { UIPasteboard.general.string = draftError }
            Button("OK", role: .cancel) {}
        } message: {
            Text(draftError ?? "")
        }
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
            SidebarView(selection: $selectedFolder, showSettings: $showSettings, compose: composeNew)
        } content: {
            if selectedFolder == .outbox {
                OutboxView(compose: { draft = $0 })
            } else if let key = selectedFolder {
                MessageListView(folder: key, selection: $selectedMessage, compose: { draft = $0 })
                    .id(key)
            } else {
                ContentUnavailableView("Kein Ordner ausgewählt", systemImage: "folder")
            }
        } detail: {
            if let key = selectedFolder, !key.isOutbox, mail.folder(key)?.role != .drafts,
               let uid = selectedMessage, let thread = mail.thread(key, containing: uid), thread.messages.count > 1 {
                ThreadDetailView(folder: key, thread: thread,
                                 compose: { draft = $0 },
                                 close: { selectedMessage = nil })
                    .id("\(key.path)-thread-\(thread.id)")
            } else if let key = selectedFolder, !key.isOutbox, mail.folder(key)?.role != .drafts,
               let uid = selectedMessage, let header = mail.header(key, uid: uid) {
                MessageDetailView(folder: key, header: header,
                                  compose: { draft = $0 },
                                  navigate: { selectedMessage = $0 },
                                  close: { selectedMessage = nil })
                    .id("\(key.path)-\(uid)")
            } else {
                ContentUnavailableView("Keine Nachricht ausgewählt", systemImage: "envelope.open")
            }
        }
        .onChange(of: selectedFolder) { selectedMessage = nil }
        .onChange(of: selectedMessage) { openDraftIfNeeded() }
    }

    /// Messages in the Drafts folder open for editing instead of reading.
    private func openDraftIfNeeded() {
        guard let key = selectedFolder, let uid = selectedMessage, mail.folder(key)?.role == .drafts,
              let header = mail.header(key, uid: uid) else { return }
        selectedMessage = nil
        Task {
            do {
                draft = try await mail.loadDraft(key, header: header, keys: keys)
            } catch {
                draftError = MailStore.describe(error)
            }
        }
    }

    /// mailto: or postfalke://compose links.
    private func compose(_ link: MailtoLink) {
        let account = selectedFolder.flatMap { accounts.account($0.accountID) } ?? accounts.accounts.first
        guard let account else { return }
        var new = ComposeDraft.new(account: account)
        new.to = link.to.joined(separator: ", ")
        new.cc = link.cc.joined(separator: ", ")
        new.bcc = link.bcc.joined(separator: ", ")
        new.subject = link.subject
        if !link.body.isEmpty { new.body = link.body + new.body }
        draft = new
    }

    private func composeNew() {
        let account = selectedFolder.flatMap { accounts.account($0.accountID) } ?? accounts.accounts.first
        if let account { draft = .new(account: account) }
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
