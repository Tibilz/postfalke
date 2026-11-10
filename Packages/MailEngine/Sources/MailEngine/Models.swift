import Foundation

public enum ConnectionSecurity: String, Codable, Sendable, CaseIterable {
    case tls        // implicit TLS (IMAP 993, SMTP 465)
    case startTLS   // upgrade after connecting (IMAP 143, SMTP 587)
    case none       // unencrypted – only for testing
}

public struct ServerConfig: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var security: ConnectionSecurity
    public var username: String

    public init(host: String, port: Int, security: ConnectionSecurity, username: String) {
        self.host = host
        self.port = port
        self.security = security
        self.username = username
    }
}

public struct MailAddress: Codable, Hashable, Sendable {
    public var name: String?
    public var email: String

    public init(name: String? = nil, email: String) {
        self.name = name?.isEmpty == true ? nil : name
        self.email = email
    }

    /// Name if there is one, otherwise the address.
    public var displayName: String { name ?? email }

    /// `Name <mail@example.org>` for display and editing (not header-encoded).
    public var formatted: String {
        guard let name else { return email }
        return "\(name) <\(email)>"
    }
}

public struct MailFolder: Codable, Hashable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable {
        case inbox, drafts, sent, archive, junk, trash
    }

    /// Name exactly as the server sent it (modified UTF-7), used in commands.
    public var path: String
    /// Human readable full name.
    public var name: String
    public var delimiter: String?
    public var flags: [String]
    public var role: Role?
    public var unread: Int?
    public var total: Int?

    public var id: String { path }
    public var isSelectable: Bool { !flags.contains { $0.lowercased() == "\\noselect" } }

    /// Last path component.
    public var shortName: String {
        guard let delimiter, !delimiter.isEmpty else { return name }
        return name.components(separatedBy: delimiter).last ?? name
    }

    public var depth: Int {
        guard let delimiter, !delimiter.isEmpty else { return 0 }
        return name.components(separatedBy: delimiter).count - 1
    }

    public init(path: String, name: String, delimiter: String?, flags: [String], role: Role?) {
        self.path = path
        self.name = name
        self.delimiter = delimiter
        self.flags = flags
        self.role = role
    }
}

public struct MessageHeader: Codable, Hashable, Identifiable, Sendable {
    public var uid: UInt32
    public var flags: Set<String>
    public var size: Int
    public var internalDate: Date?
    public var date: Date?
    public var from: [MailAddress]
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var replyTo: [MailAddress]
    public var subject: String
    public var messageID: String?
    public var inReplyTo: String?
    public var references: String?
    /// Lowercased top-level media type, e.g. `multipart/encrypted`.
    public var contentType: String

    public var id: UInt32 { uid }
    public var isSeen: Bool { flags.contains("\\Seen") }
    public var isFlagged: Bool { flags.contains("\\Flagged") }
    public var isAnswered: Bool { flags.contains("\\Answered") }
    public var isEncrypted: Bool { contentType == "multipart/encrypted" }
    public var isSigned: Bool { contentType == "multipart/signed" }
    public var mayHaveAttachments: Bool { contentType == "multipart/mixed" }
    public var sortDate: Date { date ?? internalDate ?? .distantPast }

    public init(uid: UInt32) {
        self.uid = uid
        flags = []
        size = 0
        from = []
        to = []
        cc = []
        replyTo = []
        subject = ""
        contentType = "text/plain"
    }
}

public struct MailboxStatus: Sendable {
    public var exists: Int = 0
    public var uidValidity: UInt32 = 0
    public var uidNext: UInt32 = 0
}

public enum MailError: LocalizedError, Sendable {
    case connection(String)
    case server(String)
    case authentication(String)
    case protocolError(String)
    case pgp(String)

    public var errorDescription: String? {
        switch self {
        case .connection(let m): return "Verbindungsfehler: \(m)"
        case .server(let m): return "Serverfehler: \(m)"
        case .authentication(let m): return "Anmeldung fehlgeschlagen: \(m)"
        case .protocolError(let m): return "Protokollfehler: \(m)"
        case .pgp(let m): return "OpenPGP: \(m)"
        }
    }
}
