import Foundation

/// A message as written by the user, before MIME encoding.
public struct OutgoingMessage: Sendable {
    public var from: MailAddress
    public var to: [MailAddress] = []
    public var cc: [MailAddress] = []
    public var bcc: [MailAddress] = []
    public var subject = ""
    public var body = ""
    public var attachments: [MailAttachment] = []
    public var inReplyTo: String?
    public var references: String?
    public var date = Date()
    public var messageID: String
    /// Own public key (armored) to advertise in an Autocrypt header.
    public var autocryptKey: String?

    public init(from: MailAddress) {
        self.from = from
        let domain = from.email.split(separator: "@").last.map(String.init) ?? "localhost"
        messageID = "<\(UUID().uuidString.lowercased())@\(domain)>"
    }

    public var allRecipients: [MailAddress] { to + cc + bcc }
}

/// How an outgoing message is protected with OpenPGP.
public struct PGPSendOptions: Sendable {
    public var sign: Bool
    public var encrypt: Bool
    public var signer: PGPSecret?
    /// Armored certificates of every recipient plus the sender (to read the sent copy).
    public var recipientKeys: [String]
    /// Move the subject into the encrypted part (protected headers, as Thunderbird does).
    /// Servers and anyone without the key only see "...".
    public var protectSubject = false

    public init(sign: Bool, encrypt: Bool, signer: PGPSecret?, recipientKeys: [String], protectSubject: Bool = false) {
        self.protectSubject = protectSubject
        self.sign = sign
        self.encrypt = encrypt
        self.signer = signer
        self.recipientKeys = recipientKeys
    }
}

public enum MIMEBuilder {

    static func boundary() -> String {
        "=_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// Builds the complete RFC 5322 message (CRLF line endings).
    public static func build(_ message: OutgoingMessage, pgp: PGPSendOptions? = nil) throws -> Data {
        var entity = contentEntity(message)
        var outerSubject = message.subject

        if let pgp, pgp.encrypt {
            guard !pgp.recipientKeys.isEmpty else { throw MailError.pgp("Keine Empfängerschlüssel vorhanden.") }
            if pgp.sign, pgp.signer == nil { throw MailError.pgp("Kein eigener Schlüssel zum Signieren vorhanden.") }
            if pgp.protectSubject {
                entity = protectedHeaders(message) + entity.replacingFirst("\r\n", with: "; protected-headers=\"v1\"\r\n")
                outerSubject = "..."
            }
            let armored = try PGP.encrypt(Data(entity.utf8), recipients: pgp.recipientKeys,
                                          signer: pgp.sign ? pgp.signer : nil)
            entity = encryptedEntity(armored)
        } else if let pgp, pgp.sign {
            guard let signer = pgp.signer else { throw MailError.pgp("Kein eigener Schlüssel zum Signieren vorhanden.") }
            let signature = try PGP.signDetached(Data(entity.utf8), signer: signer)
            entity = signedEntity(entity, signature: signature)
        }

        var head = ""
        head += "Date: \(HeaderCodec.formatDate(message.date))\r\n"
        head += "From: \(HeaderCodec.formatAddress(message.from))\r\n"
        if !message.to.isEmpty { head += "To: \(HeaderCodec.formatAddressList(message.to))\r\n" }
        if !message.cc.isEmpty { head += "Cc: \(HeaderCodec.formatAddressList(message.cc))\r\n" }
        head += "Subject: \(HeaderCodec.encodeWords(outerSubject))\r\n"
        head += "Message-ID: \(message.messageID)\r\n"
        if let inReplyTo = message.inReplyTo, !inReplyTo.isEmpty { head += "In-Reply-To: \(inReplyTo)\r\n" }
        if let references = message.references, !references.isEmpty {
            head += "References: \(references.split(separator: " ").joined(separator: "\r\n "))\r\n"
        }
        if let key = message.autocryptKey, let binary = PGP.dearmor(key) {
            let keydata = binary.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
                .replacingOccurrences(of: "\r\n", with: "\r\n ")
            head += "Autocrypt: addr=\(message.from.email); prefer-encrypt=mutual; keydata=\r\n \(keydata)\r\n"
        }
        head += "User-Agent: Postfalke (iOS)\r\n"
        head += "MIME-Version: 1.0\r\n"
        return Data((head + entity).utf8)
    }

    /// Copies of the sensitive headers, placed at the top of the encrypted payload.
    static func protectedHeaders(_ message: OutgoingMessage) -> String {
        var out = "Subject: \(HeaderCodec.encodeWords(message.subject))\r\n"
        out += "From: \(HeaderCodec.formatAddress(message.from))\r\n"
        if !message.to.isEmpty { out += "To: \(HeaderCodec.formatAddressList(message.to))\r\n" }
        if !message.cc.isEmpty { out += "Cc: \(HeaderCodec.formatAddressList(message.cc))\r\n" }
        out += "Date: \(HeaderCodec.formatDate(message.date))\r\n"
        out += "Message-ID: \(message.messageID)\r\n"
        return out
    }

    /// The body entity: text alone, or multipart/mixed with attachments.
    /// Starts with its own Content-* headers and ends with CRLF.
    static func contentEntity(_ message: OutgoingMessage) -> String {
        let textPart = "Content-Type: text/plain; charset=UTF-8\r\n"
            + "Content-Transfer-Encoding: quoted-printable\r\n\r\n"
            + TransferEncoding.encodeQuotedPrintable(message.body)
        guard !message.attachments.isEmpty else { return textPart }

        let b = boundary()
        var out = "Content-Type: multipart/mixed; boundary=\"\(b)\"\r\n\r\n"
        out += "--\(b)\r\n" + textPart
        for attachment in message.attachments {
            out += "\r\n--\(b)\r\n"
            out += "Content-Type: \(attachment.mimeType); \(HeaderCodec.formatParameter("name", attachment.filename))\r\n"
            out += "Content-Disposition: attachment; \(HeaderCodec.formatParameter("filename", attachment.filename))\r\n"
            out += "Content-Transfer-Encoding: base64\r\n\r\n"
            out += TransferEncoding.encodeBase64(attachment.data)
        }
        out += "\r\n--\(b)--\r\n"
        return out
    }

    /// RFC 3156 §5: multipart/signed. `entity` is signed byte for byte.
    static func signedEntity(_ entity: String, signature: String) -> String {
        let b = boundary()
        var out = "Content-Type: multipart/signed; micalg=pgp-sha256;\r\n"
            + " protocol=\"application/pgp-signature\"; boundary=\"\(b)\"\r\n\r\n"
        out += "This is an OpenPGP/MIME signed message (RFC 3156).\r\n"
        out += "--\(b)\r\n" + entity
        out += "\r\n--\(b)\r\n"
        out += "Content-Type: application/pgp-signature; name=\"OpenPGP_signature.asc\"\r\n"
        out += "Content-Description: OpenPGP digital signature\r\n"
        out += "Content-Disposition: attachment; filename=\"OpenPGP_signature.asc\"\r\n\r\n"
        out += crlf(signature)
        out += "\r\n--\(b)--\r\n"
        return out
    }

    /// RFC 3156 §4: multipart/encrypted.
    static func encryptedEntity(_ armored: String) -> String {
        let b = boundary()
        var out = "Content-Type: multipart/encrypted;\r\n"
            + " protocol=\"application/pgp-encrypted\"; boundary=\"\(b)\"\r\n\r\n"
        out += "This is an OpenPGP/MIME encrypted message (RFC 4880 and 3156).\r\n"
        out += "--\(b)\r\n"
        out += "Content-Type: application/pgp-encrypted\r\n"
        out += "Content-Description: PGP/MIME version identification\r\n\r\n"
        out += "Version: 1\r\n"
        out += "\r\n--\(b)\r\n"
        out += "Content-Type: application/octet-stream; name=\"encrypted.asc\"\r\n"
        out += "Content-Description: OpenPGP encrypted message\r\n"
        out += "Content-Disposition: inline; filename=\"encrypted.asc\"\r\n\r\n"
        out += crlf(armored)
        out += "\r\n--\(b)--\r\n"
        return out
    }

    /// Normalizes line endings to CRLF and guarantees a trailing one.
    static func crlf(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        if !out.hasSuffix("\r\n") { out += "\r\n" }
        return out
    }
}

private extension String {
    func replacingFirst(_ target: String, with replacement: String) -> String {
        guard let range = range(of: target) else { return self }
        return replacingCharacters(in: range, with: replacement)
    }
}
