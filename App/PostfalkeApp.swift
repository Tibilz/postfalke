import SwiftUI

@main
struct PostfalkeApp: App {
    @State private var accounts: AccountStore
    @State private var mail: MailStore
    @State private var keys: KeyStore
    @State private var contacts = ContactKeySync()
    @State private var outbox: Outbox
    @State private var network: NetworkMonitor
    @State private var directory: ContactDirectory
    @State private var navigator: AppNavigator
    @State private var notifications: NotificationHandler
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // UI tests start from a clean slate.
        if CommandLine.arguments.contains("-resetState") {
            Storage.reset()
            Keychain.deleteAll()
        }
        #endif
        let accounts = AccountStore()
        let mail = MailStore(accounts: accounts)
        let keys = KeyStore()
        let outbox = Outbox()
        let directory = ContactDirectory()
        mail.directory = directory
        outbox.send = { draft in
            try await MailSender.send(draft, accounts: accounts, keys: keys, mail: mail, directory: directory)
        }
        _directory = State(initialValue: directory)
        let navigator = AppNavigator()
        _navigator = State(initialValue: navigator)
        _notifications = State(initialValue: NotificationHandler(mail: mail, navigator: navigator))
        _accounts = State(initialValue: accounts)
        _mail = State(initialValue: mail)
        _keys = State(initialValue: keys)
        _outbox = State(initialValue: outbox)
        let network = NetworkMonitor()
        mail.network = network
        // Back online: send what waited, then catch up on changes made offline.
        network.onReconnect = {
            Task {
                await outbox.process()
                await mail.replayAllPending()
            }
        }
        _network = State(initialValue: network)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(accounts)
                .environment(mail)
                .environment(keys)
                .environment(contacts)
                .environment(outbox)
                .environment(network)
                .environment(directory)
                .environment(navigator)
                .onAppear { contacts.directory = directory }
                .task { await contacts.syncIfDue(keys: keys) }
                .task { await outbox.process() }
                #if DEBUG
                .task {
                    // The simulator cannot launch background tasks; run the same code after a delay.
                    guard CommandLine.arguments.contains("-simulateBackgroundRefresh") else { return }
                    try? await Task.sleep(for: .seconds(20))
                    await BackgroundRefresh.run(mail: mail, outbox: outbox)
                }
                #endif
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background {
                BackgroundRefresh.schedule(earliest: outbox.nextDue)
                Task { await mail.updateBadge() }
                // Leaving the app ends the undo window; use the grace time iOS gives to send.
                let task = UIApplication.shared.beginBackgroundTask(withName: "outbox")
                Task {
                    await outbox.flushUndoWindow()
                    UIApplication.shared.endBackgroundTask(task)
                }
            }
            if scenePhase == .active {
                Task { await contacts.syncIfDue(keys: keys) }
                Task { await outbox.process() }
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.taskID)) {
            await BackgroundRefresh.run(mail: mail, outbox: outbox)
        }
    }
}
