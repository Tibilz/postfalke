import Foundation

/// A buffered, line-oriented TCP connection with optional TLS / STARTTLS.
///
/// Built on `URLSessionStreamTask` because it can upgrade a plain connection to
/// TLS mid-stream, which IMAP and SMTP need for STARTTLS.
/// Not thread safe on its own: each instance is owned by exactly one actor.
final class StreamConnection: @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionStreamTask
    private var buffer = Data()
    private let timeout: TimeInterval

    init(host: String, port: Int, security: ConnectionSecurity, timeout: TimeInterval = 40) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        task = session.streamTask(withHostName: host, port: port)
        self.timeout = timeout
        if security == .tls {
            task.startSecureConnection()
        }
        task.resume()
    }

    deinit {
        task.cancel()
        session.invalidateAndCancel()
    }

    /// Upgrade the running connection to TLS (after STARTTLS was accepted).
    func startTLS() {
        buffer.removeAll()
        task.startSecureConnection()
    }

    func close() {
        task.closeWrite()
        task.closeRead()
        task.cancel()
        session.invalidateAndCancel()
    }

    func write(_ data: Data) async throws {
        do {
            try await task.write(data, timeout: timeout)
        } catch {
            throw MailError.connection(error.localizedDescription)
        }
    }

    func write(_ string: String) async throws {
        try await write(Data(string.utf8))
    }

    private func fill() async throws {
        do {
            let (data, eof) = try await task.readData(ofMinLength: 1, maxLength: 256 * 1024, timeout: timeout)
            if let data, !data.isEmpty {
                buffer.append(data)
            } else if eof {
                throw MailError.connection("Der Server hat die Verbindung geschlossen.")
            }
        } catch let error as MailError {
            throw error
        } catch {
            throw MailError.connection(error.localizedDescription)
        }
    }

    /// Reads one line including its terminating LF.
    func readLine() async throws -> Data {
        var searchFrom = buffer.startIndex
        while true {
            if let lf = buffer[searchFrom...].firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex...lf]
                buffer = Data(buffer[buffer.index(after: lf)...])
                return Data(line)
            }
            searchFrom = buffer.endIndex
            try await fill()
            // `fill` appends, indices before `searchFrom` stay valid.
        }
    }

    func readBytes(_ count: Int) async throws -> Data {
        while buffer.count < count {
            try await fill()
        }
        let chunk = buffer.prefix(count)
        buffer = Data(buffer.dropFirst(count))
        return Data(chunk)
    }
}
