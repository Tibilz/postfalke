import Foundation
import MailEngine

struct Account: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Name shown to recipients.
    var name: String
    var email: String
    var imap: ServerConfig
    var smtp: ServerConfig
    var signature = ""
    /// Fingerprint of the personal OpenPGP key used for this account.
    var pgpFingerprint: String?
    var signByDefault = false
    var encryptByDefault = false

    var address: MailAddress { MailAddress(name: name, email: email) }
    var passwordKey: String { "account-password-\(id.uuidString)" }
}

struct FolderKey: Hashable, Codable {
    let accountID: UUID
    let path: String
}
