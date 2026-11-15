import Foundation
import Observation
import UserNotifications
import MailEngine

/// Where the user wants to go after tapping a notification.
@MainActor
@Observable
final class AppNavigator {
    var requestedMessage: (folder: FolderKey, uid: UInt32)?
    /// A message to write, e.g. from a mailto: link.
    var requestedDraft: ComposeDraft?
}

/// Handles taps and actions ("Als gelesen markieren", "Löschen") on new-mail notifications.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let category = "NEW_MAIL"
    static let markRead = "MARK_READ"
    static let delete = "DELETE"

    private let mail: MailStore
    private let navigator: AppNavigator

    @MainActor
    init(mail: MailStore, navigator: AppNavigator) {
        self.mail = mail
        self.navigator = navigator
        super.init()
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [
                UNNotificationAction(identifier: Self.markRead, title: "Als gelesen markieren", options: []),
                UNNotificationAction(identifier: Self.delete, title: "Löschen", options: [.destructive]),
            ], intentIdentifiers: [])
        ])
        center.delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let account = (info["account"] as? String).flatMap(UUID.init(uuidString:)),
              let path = info["folder"] as? String,
              let uid = (info["uid"] as? NSNumber)?.uint32Value else { return }
        let key = FolderKey(accountID: account, path: path)
        await MainActor.run { [mail, navigator] in
            let header = mail.header(key, uid: uid) ?? MessageHeader(uid: uid)
            switch response.actionIdentifier {
            case Self.markRead:
                Task { await mail.setSeen(key, header: header, seen: true); await mail.updateBadge() }
            case Self.delete:
                Task { await mail.delete(key, header: header); await mail.updateBadge() }
            default:
                navigator.requestedMessage = (key, uid)
            }
        }
    }

    /// While the app is open the list updates itself; no banner needed.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}

extension MailStore {
    /// Unread mail in all inboxes, shown on the app icon (if notifications are allowed).
    func updateBadge() async {
        var unread = 0
        for account in accounts.accounts {
            if let inbox = folder(role: .inbox, account: account.id), let count = inbox.unread {
                unread += count
            } else {
                unread += mailbox(FolderKey(accountID: account.id, path: "INBOX")).headers.filter { !$0.isSeen }.count
            }
        }
        try? await UNUserNotificationCenter.current().setBadgeCount(unread)
    }
}
