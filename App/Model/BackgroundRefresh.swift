import Foundation
import BackgroundTasks
import UserNotifications
import os

/// Periodic mail check while the app is not on screen.
///
/// iOS decides when (and how often) this runs; it is not push. Typical intervals
/// range from a quarter of an hour to several hours, depending on how the app is used.
enum BackgroundRefresh {
    static let taskID = "de.postfalke.app.refresh"
    static let notifyKey = "notifyNewMail"
    static let lastRunKey = "lastBackgroundRefresh"
    private static let log = Logger(subsystem: "de.postfalke.app", category: "background")

    /// Asks iOS for the next wake-up. Call when the app goes to the background.
    static func schedule(earliest due: Date? = nil) {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        // A planned message may need an earlier wake-up than the regular mail check.
        let regular = Date(timeIntervalSinceNow: 15 * 60)
        request.earliestBeginDate = due.map { min(max($0, Date(timeIntervalSinceNow: 60)), regular) } ?? regular
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.error("could not schedule refresh: \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    static func run(mail: MailStore, outbox: Outbox) async {
        await outbox.process()
        schedule(earliest: outbox.nextDue)
        guard !mail.accounts.accounts.isEmpty else { return }
        let fresh = await mail.checkNewMail()
        log.info("background refresh found \(fresh.count) new message(s)")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastRunKey)
        #if DEBUG
        UserDefaults.standard.set(fresh.map(\.header.subject), forKey: "debugLastBackgroundSubjects")
        #endif
        await mail.updateBadge()
        guard UserDefaults.standard.bool(forKey: notifyKey) else { return }
        for item in fresh.prefix(8) {
            await notify(item, mail: mail)
        }
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    @MainActor
    private static func notify(_ item: MailStore.NewMail, mail: MailStore) async {
        let content = UNMutableNotificationContent()
        content.title = item.header.from.first?.displayName ?? "Neue Nachricht"
        // The subject of an encrypted mail is not known without opening it.
        let subject = item.header.subject
        content.body = item.header.isEncrypted && (subject.isEmpty || subject == "...")
            ? "Verschlüsselte Nachricht" : (subject.isEmpty ? "(kein Betreff)" : subject)
        content.subtitle = mail.accounts.accounts.count > 1 ? item.account : ""
        content.sound = .default
        content.threadIdentifier = item.account
        content.categoryIdentifier = NotificationHandler.category
        content.userInfo = ["account": item.accountID.uuidString, "folder": "INBOX", "uid": NSNumber(value: item.header.uid)]
        let request = UNNotificationRequest(identifier: "\(item.account)-\(item.header.uid)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
