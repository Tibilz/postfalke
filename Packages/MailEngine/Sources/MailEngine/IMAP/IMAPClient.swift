import Foundation

/// A minimal IMAP4rev1 client: one connection, commands run strictly in sequence.
public actor IMAPClient {
    private enum Segment {
        case text(String)
        case literal(Data)
    }

    private let config: ServerConfig
    private let password: String
    private var connection: StreamConnection?
    private var tagCounter = 0
    public private(set) var capabilities: Set<String> = []
    public private(set) var selectedFolder: String?
    public private(set) var status = MailboxStatus()

    public init(config: ServerConfig, password: String) {
        self.config = config
        self.password = password
    }

    public var isConnected: Bool { connection != nil }

    // MARK: Connection

    public func connect() async throws {
        disconnect()
        let conn = StreamConnection(host: config.host, port: config.port, security: config.security)
        connection = conn
        do {
            let greeting = try await readResponse(conn)
            guard greeting.starts(with: Data("* OK".utf8)) || greeting.starts(with: Data("* PREAUTH".utf8)) else {
                throw MailError.server(String(decoding: greeting, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            try await refreshCapabilities()
            if config.security == .startTLS {
                guard capabilities.contains("STARTTLS") else {
                    throw MailError.connection("Der Server unterstützt kein STARTTLS.")
                }
                _ = try await run([.text("STARTTLS")])
                conn.startTLS()
                try await refreshCapabilities()
            }
            try await login()
        } catch {
            disconnect()
            throw error
        }
    }

    public func disconnect() {
        connection?.close()
        connection = nil
        selectedFolder = nil
        capabilities = []
    }

    public func logout() async {
        if connection != nil { _ = try? await run([.text("LOGOUT")], expectBye: true) }
        disconnect()
    }

    private func refreshCapabilities() async throws {
        for case .capability(let caps) in try await run([.text("CAPABILITY")]) {
            capabilities = Set(caps)
        }
    }

    private func login() async throws {
        if capabilities.contains("LOGINDISABLED") {
            throw MailError.authentication("Der Server erlaubt keine Passwort-Anmeldung auf dieser Verbindung.")
        }
        do {
            let responses = try await run([.text("LOGIN ")] + astring(config.username) + [.text(" ")] + astring(password))
            var sawCapabilities = false
            for case .capability(let caps) in responses {
                capabilities = Set(caps)
                sawCapabilities = true
            }
            if !sawCapabilities { try await refreshCapabilities() }
        } catch MailError.server(let message) {
            throw MailError.authentication(message)
        }
    }

    // MARK: Wire protocol

    /// Quoted string when possible, literal otherwise.
    private func astring(_ value: String) -> [Segment] {
        let simple = value.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F }
        guard simple else { return [.literal(Data(value.utf8))] }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return [.text("\"\(escaped)\"")]
    }

    /// Reads one full response: a line plus any `{n}` literals it announces.
    private func readResponse(_ conn: StreamConnection) async throws -> Data {
        var response = Data()
        while true {
            let line = try await conn.readLine()
            response.append(line)
            guard let size = Self.trailingLiteralSize(line) else { return response }
            response.append(try await conn.readBytes(size))
        }
    }

    /// `… {123}\r\n` → 123
    static func trailingLiteralSize(_ line: Data) -> Int? {
        var end = line.endIndex
        while end > line.startIndex, line[end - 1] == 0x0A || line[end - 1] == 0x0D { end -= 1 }
        guard end > line.startIndex, line[end - 1] == UInt8(ascii: "}") else { return nil }
        var i = end - 2
        var digits: [UInt8] = []
        while i >= line.startIndex, line[i] >= 0x30, line[i] <= 0x39 {
            digits.insert(line[i], at: 0)
            i -= 1
        }
        guard !digits.isEmpty, i >= line.startIndex, line[i] == UInt8(ascii: "{") else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    /// Sends a command and collects the untagged responses until the tagged completion.
    @discardableResult
    private func run(_ segments: [Segment], expectBye: Bool = false) async throws -> [IMAPResponse] {
        guard let conn = connection else { throw MailError.connection("Nicht verbunden.") }
        tagCounter += 1
        let tag = "A\(tagCounter)"
        var untagged: [IMAPResponse] = []

        do {
            var pending = Data("\(tag) ".utf8)
            for segment in segments {
                switch segment {
                case .text(let text):
                    pending.append(Data(text.utf8))
                case .literal(let data):
                    pending.append(Data("{\(data.count)}\r\n".utf8))
                    try await conn.write(pending)
                    pending = data
                    // Wait for the continuation request before sending the literal.
                    waiting: while true {
                        let response = try await readResponse(conn)
                        if response.first == UInt8(ascii: "+") { break waiting }
                        if response.starts(with: Data("* ".utf8)) {
                            untagged.append(IMAPResponse.parse(response))
                        } else if response.starts(with: Data("\(tag) ".utf8)) {
                            try Self.checkCompletion(response, tag: tag)
                            throw MailError.protocolError("Unerwartete Antwort des Servers.")
                        }
                    }
                }
            }
            pending.append(Data("\r\n".utf8))
            try await conn.write(pending)

            while true {
                let response = try await readResponse(conn)
                if response.starts(with: Data("* ".utf8)) {
                    let parsed = IMAPResponse.parse(response)
                    if case .condition(kind: "BYE", _, _, let text) = parsed, !expectBye {
                        throw MailError.connection(text.isEmpty ? "Der Server hat die Sitzung beendet." : text)
                    }
                    untagged.append(parsed)
                } else if response.starts(with: Data("\(tag) ".utf8)) {
                    try Self.checkCompletion(response, tag: tag)
                    return untagged
                }
                // Continuation requests and foreign tags are ignored.
            }
        } catch let error as MailError {
            if case .connection = error { disconnect() }
            throw error
        }
    }

    private static func checkCompletion(_ response: Data, tag: String) throws {
        let line = String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = line.dropFirst(tag.count + 1)
        let parts = rest.split(separator: " ", maxSplits: 1)
        let kind = parts.first.map { $0.uppercased() } ?? ""
        if kind == "OK" { return }
        let text = parts.count > 1 ? String(parts[1]) : line
        throw MailError.server(text)
    }

    // MARK: Folders

    public func listFolders() async throws -> [MailFolder] {
        let command = "LIST \"\" \"*\""
        var folders: [MailFolder] = []
        for case .list(let flags, let delimiter, let path) in try await run([.text(command)]) {
            let lower = Set(flags.map { $0.lowercased() })
            var role: MailFolder.Role?
            if path.uppercased() == "INBOX" { role = .inbox }
            else if lower.contains("\\sent") { role = .sent }
            else if lower.contains("\\drafts") { role = .drafts }
            else if lower.contains("\\trash") { role = .trash }
            else if lower.contains("\\junk") { role = .junk }
            else if lower.contains("\\archive") || lower.contains("\\all") { role = .archive }
            folders.append(MailFolder(path: path, name: ModifiedUTF7.decode(path),
                                      delimiter: delimiter, flags: flags, role: role))
        }
        Self.guessRoles(&folders)
        return folders.sorted(by: Self.folderOrder)
    }

    /// Servers without SPECIAL-USE: recognise the usual folder names.
    static func guessRoles(_ folders: inout [MailFolder]) {
        let names: [(MailFolder.Role, [String])] = [
            (.sent, ["sent", "sent items", "sent messages", "gesendet", "gesendete objekte", "gesendete elemente"]),
            (.drafts, ["drafts", "entwürfe", "entwurf"]),
            (.trash, ["trash", "deleted items", "deleted messages", "papierkorb", "gelöscht", "gelöschte elemente"]),
            (.junk, ["junk", "spam", "junk-e-mail", "spamverdacht", "unerwünscht"]),
            (.archive, ["archive", "archiv", "archives"]),
        ]
        for (role, candidates) in names where !folders.contains(where: { $0.role == role }) {
            if let index = folders.firstIndex(where: { $0.role == nil && candidates.contains($0.shortName.lowercased()) }) {
                folders[index].role = role
            }
        }
    }

    static func folderOrder(_ a: MailFolder, _ b: MailFolder) -> Bool {
        func rank(_ f: MailFolder) -> Int {
            switch f.role {
            case .inbox: return 0
            case .drafts: return 1
            case .sent: return 2
            case .archive: return 3
            case .junk: return 4
            case .trash: return 5
            case nil: return 6
            }
        }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    /// Unread and total counts without selecting the folder.
    public func folderCounts(_ path: String) async throws -> (unread: Int, total: Int) {
        let responses = try await run([.text("STATUS ")] + astring(path) + [.text(" (MESSAGES UNSEEN)")])
        for case .status(_, let items) in responses {
            return (items["UNSEEN"] ?? 0, items["MESSAGES"] ?? 0)
        }
        return (0, 0)
    }

    @discardableResult
    public func select(_ path: String, force: Bool = false) async throws -> MailboxStatus {
        if !force, selectedFolder == path { return status }
        selectedFolder = nil
        var newStatus = MailboxStatus()
        for response in try await run([.text("SELECT ")] + astring(path)) {
            switch response {
            case .count(kind: "EXISTS", let number):
                newStatus.exists = number
            case .condition(_, code: "UIDVALIDITY"?, let argument, _):
                newStatus.uidValidity = argument.flatMap { UInt32($0) } ?? 0
            case .condition(_, code: "UIDNEXT"?, let argument, _):
                newStatus.uidNext = argument.flatMap { UInt32($0) } ?? 0
            default:
                break
            }
        }
        status = newStatus
        selectedFolder = path
        return newStatus
    }

    public func noop() async throws {
        for case .count(kind: "EXISTS", let number) in try await run([.text("NOOP")]) {
            status.exists = number
        }
    }

    // MARK: Messages

    private static let headerItems =
        "(UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (FROM TO CC REPLY-TO SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES CONTENT-TYPE)])"

    /// Headers for a range of sequence numbers (1-based, inclusive) in the selected folder.
    public func fetchHeaders(sequence range: ClosedRange<Int>) async throws -> [MessageHeader] {
        let responses = try await run([.text("FETCH \(range.lowerBound):\(range.upperBound) \(Self.headerItems)")])
        return Self.headers(from: responses)
    }

    public func fetchHeaders(uids: [UInt32]) async throws -> [MessageHeader] {
        guard !uids.isEmpty else { return [] }
        let set = uids.map(String.init).joined(separator: ",")
        let responses = try await run([.text("UID FETCH \(set) \(Self.headerItems)")])
        return Self.headers(from: responses)
    }

    static func headers(from responses: [IMAPResponse]) -> [MessageHeader] {
        var result: [MessageHeader] = []
        for case .fetch(_, let items) in responses {
            guard let uid = items["UID"]?.number.flatMap({ UInt32(exactly: $0) }) else { continue }
            var header = MessageHeader(uid: uid)
            header.flags = Set(items["FLAGS"]?.items.compactMap(\.text) ?? [])
            header.size = items["RFC822.SIZE"]?.number ?? 0
            header.internalDate = HeaderCodec.parseInternalDate(items["INTERNALDATE"]?.text)
            if let block = items["BODY[]"]?.data {
                var fields: [String: String] = [:]
                for field in HeaderCodec.parseHeaderBlock(block) where fields[field.name.lowercased()] == nil {
                    fields[field.name.lowercased()] = field.value
                }
                header.from = HeaderCodec.parseAddressList(fields["from"])
                header.to = HeaderCodec.parseAddressList(fields["to"])
                header.cc = HeaderCodec.parseAddressList(fields["cc"])
                header.replyTo = HeaderCodec.parseAddressList(fields["reply-to"])
                header.subject = HeaderCodec.decodeWords(fields["subject"] ?? "")
                header.date = HeaderCodec.parseDate(fields["date"])
                header.messageID = fields["message-id"]
                header.inReplyTo = fields["in-reply-to"]
                header.references = fields["references"]
                if let contentType = fields["content-type"] {
                    header.contentType = HeaderCodec.parseParameters(contentType).value
                }
            }
            result.append(header)
        }
        return result
    }

    /// The complete raw message (RFC 5322) without setting \Seen.
    public func fetchMessage(uid: UInt32) async throws -> Data {
        for case .fetch(_, let items) in try await run([.text("UID FETCH \(uid) (UID BODY.PEEK[])")]) {
            if let data = items["BODY[]"]?.data { return data }
        }
        throw MailError.server("Die Nachricht wurde auf dem Server nicht gefunden.")
    }

    public func setFlag(_ flag: String, on uids: [UInt32], enabled: Bool) async throws {
        guard !uids.isEmpty else { return }
        let set = uids.map(String.init).joined(separator: ",")
        try await run([.text("UID STORE \(set) \(enabled ? "+" : "-")FLAGS.SILENT (\(flag))")])
    }

    public func move(uids: [UInt32], to path: String) async throws {
        guard !uids.isEmpty else { return }
        let set = uids.map(String.init).joined(separator: ",")
        if capabilities.contains("MOVE") {
            try await run([.text("UID MOVE \(set) ")] + astring(path))
        } else {
            try await run([.text("UID COPY \(set) ")] + astring(path))
            try await expunge(uids: uids)
        }
    }

    /// Marks messages deleted and removes them permanently.
    public func expunge(uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        let set = uids.map(String.init).joined(separator: ",")
        try await run([.text("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")])
        if capabilities.contains("UIDPLUS") {
            try await run([.text("UID EXPUNGE \(set)")])
        } else {
            try await run([.text("EXPUNGE")])
        }
    }

    public func append(_ message: Data, to path: String, flags: [String] = ["\\Seen"]) async throws {
        try await run([.text("APPEND ")] + astring(path)
                      + [.text(" (\(flags.joined(separator: " "))) "), .literal(message)])
    }

    /// UIDs of messages whose headers or text contain `query`.
    public func search(_ query: String) async throws -> [UInt32] {
        let isASCII = query.unicodeScalars.allSatisfy(\.isASCII)
        let prefix = isASCII ? "UID SEARCH TEXT " : "UID SEARCH CHARSET UTF-8 TEXT "
        var uids: [UInt32] = []
        for case .search(let found) in try await run([.text(prefix)] + astring(query)) {
            uids.append(contentsOf: found)
        }
        return uids.sorted()
    }
}
