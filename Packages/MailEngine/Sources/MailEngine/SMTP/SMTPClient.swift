import Foundation

/// A minimal SMTP submission client (RFC 6409) with AUTH PLAIN / LOGIN.
public actor SMTPClient {
    private let config: ServerConfig
    private let password: String

    public init(config: ServerConfig, password: String) {
        self.config = config
        self.password = password
    }

    private struct Reply {
        var code: Int
        var lines: [String]
        var text: String { lines.joined(separator: " ") }
    }

    private func readReply(_ conn: StreamConnection) async throws -> Reply {
        var lines: [String] = []
        while true {
            let raw = try await conn.readLine()
            let line = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.count >= 3, let code = Int(line.prefix(3)) else {
                throw MailError.protocolError("Unerwartete SMTP-Antwort: \(line)")
            }
            lines.append(String(line.dropFirst(4)))
            // "250-…" continues, "250 …" ends the reply.
            if line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] != "-" {
                return Reply(code: code, lines: lines)
            }
        }
    }

    @discardableResult
    private func command(_ conn: StreamConnection, _ line: String, expect: ClosedRange<Int> = 200...299) async throws -> Reply {
        try await conn.write(line + "\r\n")
        let reply = try await readReply(conn)
        guard expect.contains(reply.code) else {
            throw MailError.server("\(reply.code) \(reply.text)")
        }
        return reply
    }

    /// Checks that the server accepts the connection and credentials.
    public func verify() async throws {
        let conn = try await open()
        _ = try? await command(conn, "QUIT")
        conn.close()
    }

    /// Connects, negotiates TLS and authenticates.
    private func open() async throws -> StreamConnection {
        let conn = StreamConnection(host: config.host, port: config.port, security: config.security)
        do {
            let greeting = try await readReply(conn)
            guard greeting.code == 220 else { throw MailError.server("\(greeting.code) \(greeting.text)") }

            var features = try await command(conn, "EHLO [127.0.0.1]").lines.map { $0.uppercased() }
            if config.security == .startTLS {
                guard features.contains(where: { $0.hasPrefix("STARTTLS") }) else {
                    throw MailError.connection("Der Server unterstützt kein STARTTLS.")
                }
                try await command(conn, "STARTTLS")
                conn.startTLS()
                features = try await command(conn, "EHLO [127.0.0.1]").lines.map { $0.uppercased() }
            }

            let auth = features.first { $0.hasPrefix("AUTH") } ?? ""
            do {
                if auth.contains("PLAIN") || !auth.contains("LOGIN") {
                    let token = Data("\u{0}\(config.username)\u{0}\(password)".utf8).base64EncodedString()
                    try await command(conn, "AUTH PLAIN \(token)")
                } else {
                    try await command(conn, "AUTH LOGIN", expect: 334...334)
                    try await command(conn, Data(config.username.utf8).base64EncodedString(), expect: 334...334)
                    try await command(conn, Data(password.utf8).base64EncodedString())
                }
            } catch MailError.server(let message) {
                throw MailError.authentication(message)
            }
            return conn
        } catch {
            conn.close()
            throw error
        }
    }

    /// Sends one message to all recipients.
    public func send(_ message: Data, from: String, recipients: [String]) async throws {
        guard !recipients.isEmpty else { throw MailError.protocolError("Keine Empfänger angegeben.") }
        let conn = try await open()
        defer { conn.close() }

        try await command(conn, "MAIL FROM:<\(from)>")
        for recipient in recipients {
            try await command(conn, "RCPT TO:<\(recipient)>")
        }
        try await command(conn, "DATA", expect: 354...354)
        try await conn.write(Self.dotStuffed(message))
        try await command(conn, ".")
        _ = try? await command(conn, "QUIT")
    }

    /// CRLF-normalised message data with leading dots doubled, ending in CRLF.
    static func dotStuffed(_ message: Data) -> Data {
        var out = Data(capacity: message.count + 64)
        var atLineStart = true
        var previous: UInt8 = 0
        for byte in message {
            if byte == 0x0A, previous != 0x0D { out.append(0x0D) }
            if atLineStart, byte == UInt8(ascii: ".") { out.append(byte) }
            out.append(byte)
            atLineStart = byte == 0x0A
            previous = byte
        }
        if !atLineStart { out.append(contentsOf: [0x0D, 0x0A]) }
        return out
    }
}
