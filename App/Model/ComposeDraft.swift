import Foundation
import MailEngine

/// The editable state of the compose sheet.
struct ComposeDraft: Identifiable {
    let id = UUID()
    var accountID: UUID
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""
    var attachments: [MailAttachment] = []
    var inReplyTo: String?
    var references: String?
    /// The message being answered, to set \Answered after sending.
    var answering: (folder: FolderKey, uid: UInt32)?
    /// Replies to encrypted mail should be encrypted as well.
    var preferEncryption = false

    static func new(account: Account, to: String = "") -> ComposeDraft {
        var draft = ComposeDraft(accountID: account.id)
        draft.to = to
        draft.body = signatureBlock(account)
        return draft
    }

    private static func signatureBlock(_ account: Account) -> String {
        account.signature.isEmpty ? "" : "\n\n-- \n\(account.signature)"
    }

    private static func prefixed(_ subject: String, with prefix: String, known: [String]) -> String {
        let lower = subject.lowercased()
        if known.contains(where: { lower.hasPrefix($0) }) { return subject }
        return "\(prefix) \(subject)"
    }

    private static func quote(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .map { $0.hasPrefix(">") ? ">\($0)" : "> \($0)" }
            .joined(separator: "\n")
    }

    private static let dateFormat: Date.FormatStyle = .dateTime.day().month(.wide).year().hour().minute()

    static func reply(to header: MessageHeader, subject: String, text: String, wasEncrypted: Bool,
                      all: Bool, account: Account, folder: FolderKey) -> ComposeDraft {
        var draft = ComposeDraft(accountID: account.id)
        let own = account.email.lowercased()
        let sender = header.replyTo.isEmpty ? header.from : header.replyTo
        // Answering one's own mail (from Sent) goes to the original recipients.
        let primary = sender.allSatisfy({ $0.email.lowercased() == own }) ? header.to : sender
        draft.to = primary.map(\.formatted).joined(separator: ", ")
        if all {
            let taken = Set(primary.map { $0.email.lowercased() } + [own])
            let others = (header.to + header.cc).filter { !taken.contains($0.email.lowercased()) }
            draft.cc = others.map(\.formatted).joined(separator: ", ")
        }
        draft.subject = prefixed(subject, with: "Re:", known: ["re:", "aw:"])
        let when = (header.date ?? header.internalDate).map { $0.formatted(dateFormat) } ?? ""
        let who = header.from.first?.displayName ?? ""
        draft.body = "\n\nAm \(when) schrieb \(who):\n\(quote(text))" + signatureBlock(account)
        draft.inReplyTo = header.messageID
        draft.references = [header.references, header.messageID].compactMap { $0 }.joined(separator: " ")
        draft.answering = (folder, header.uid)
        draft.preferEncryption = wasEncrypted
        return draft
    }

    static func forward(_ header: MessageHeader, subject: String, text: String, attachments: [MailAttachment],
                        wasEncrypted: Bool, account: Account) -> ComposeDraft {
        var draft = ComposeDraft(accountID: account.id)
        draft.subject = prefixed(subject, with: "Fwd:", known: ["fwd:", "fw:", "wg:"])
        let when = (header.date ?? header.internalDate).map { $0.formatted(dateFormat) } ?? ""
        draft.body = signatureBlock(account) + """


        -------- Weitergeleitete Nachricht --------
        Betreff: \(subject)
        Datum: \(when)
        Von: \(header.from.map(\.formatted).joined(separator: ", "))
        An: \(header.to.map(\.formatted).joined(separator: ", "))

        \(text.replacingOccurrences(of: "\r\n", with: "\n"))
        """
        draft.attachments = attachments
        draft.preferEncryption = wasEncrypted
        return draft
    }
}

extension KeyStore {
    /// The personal key pair of an account: the configured one, else one matching the address.
    func personalKey(for account: Account) -> PGPKeyInfo? {
        if let key = key(fingerprint: account.pgpFingerprint), key.isSecret { return key }
        return secretKeys.first { $0.emails.contains(account.email.lowercased()) }
    }
}
