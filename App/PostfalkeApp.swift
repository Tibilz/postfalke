import SwiftUI

@main
struct PostfalkeApp: App {
    @State private var accounts: AccountStore
    @State private var mail: MailStore
    @State private var keys = KeyStore()
    @State private var contacts = ContactKeySync()
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
        _accounts = State(initialValue: accounts)
        _mail = State(initialValue: MailStore(accounts: accounts))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(accounts)
                .environment(mail)
                .environment(keys)
                .environment(contacts)
                .task { await contacts.syncIfDue(keys: keys) }
                #if DEBUG
                .task {
                    // The simulator cannot launch background tasks; run the same code after a delay.
                    guard CommandLine.arguments.contains("-simulateBackgroundRefresh") else { return }
                    try? await Task.sleep(for: .seconds(20))
                    await BackgroundRefresh.run(mail: mail)
                }
                #endif
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background { BackgroundRefresh.schedule() }
            if scenePhase == .active { Task { await contacts.syncIfDue(keys: keys) } }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.taskID)) {
            await BackgroundRefresh.run(mail: mail)
        }
    }
}
