import Foundation
import MailEngine

/// OpenPGP choices of a draft; nil in a draft means "use the account defaults".
struct DraftOptions: Codable, Equatable {
    var sign = false
    var encrypt = false
    var protectSubject = true
    var attachOwnKey = false

    /// `sign=1; encrypt=0; …` for the X-Postfalke-Draft header of a saved draft.
    var headerValue: String {
        "sign=\(sign ? 1 : 0); encrypt=\(encrypt ? 1 : 0); protect-subject=\(protectSubject ? 1 : 0); attach-key=\(attachOwnKey ? 1 : 0)"
    }

    init(sign: Bool = false, encrypt: Bool = false, protectSubject: Bool = true, attachOwnKey: Bool = false) {
        self.sign = sign
        self.encrypt = encrypt
        self.protectSubject = protectSubject
        self.attachOwnKey = attachOwnKey
    }

    init?(headerValue: String?) {
        guard let headerValue else { return nil }
        var values: [String: Bool] = [:]
        for pair in headerValue.split(separator: ";") {
            let parts = pair.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { values[parts[0]] = parts[1] == "1" }
        }
        self.init(sign: values["sign"] ?? false, encrypt: values["encrypt"] ?? false,
                  protectSubject: values["protect-subject"] ?? true, attachOwnKey: values["attach-key"] ?? false)
    }
}

/// The message a reply answers, to set \Answered after sending.
struct AnsweredMessage: Codable, Equatable {
    var folder: FolderKey
    var uid: UInt32
}

/// The editable state of the compose sheet. Codable: drafts are saved locally
/// while writing and travel through the outbox.
struct ComposeDraft: Identifiable, Codable, Equatable {
    var id = UUID()
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
    var answering: AnsweredMessage?
    /// Replies to encrypted mail should be encrypted as well.
    var preferEncryption = false
    var options: DraftOptions?
    /// Message-ID of the copy in the server's Drafts folder, once saved there.
    var serverMessageID: String?

    /// True when there is anything worth keeping.
    var hasContent: Bool {
        !to.isEmpty || !cc.isEmpty || !bcc.isEmpty || !subject.isEmpty || !attachments.isEmpty
            || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
        draft.answering = AnsweredMessage(folder: folder, uid: header.uid)
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
