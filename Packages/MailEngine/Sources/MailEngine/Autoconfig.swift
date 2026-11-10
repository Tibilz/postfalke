import Foundation

/// Server settings discovery via the Thunderbird ISP database (autoconfig).
public enum Autoconfig {
    public struct Result: Sendable {
        public var imap: ServerConfig
        public var smtp: ServerConfig
        public var displayName: String?
    }

    public static func lookup(email: String) async -> Result? {
        guard let domain = email.split(separator: "@").last.map({ String($0).lowercased() }), !domain.isEmpty else {
            return nil
        }
        let candidates = [
            "https://autoconfig.\(domain)/mail/config-v1.1.xml?emailaddress=\(email)",
            "https://\(domain)/.well-known/autoconfig/mail/config-v1.1.xml",
            "https://autoconfig.thunderbird.net/v1.1/\(domain)",
        ]
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config)
        for candidate in candidates {
            guard let url = URL(string: candidate),
                  let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let result = parse(data, email: email) else { continue }
            return result
        }
        return nil
    }

    static func parse(_ data: Data, email: String) -> Result? {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }

        func config(_ type: String) -> ServerConfig? {
            // Prefer implicit TLS, then STARTTLS; skip OAuth-only and plaintext entries.
            let usable = delegate.servers.filter { $0.type == type && $0.security != nil && $0.passwordAuth }
            let entry = usable.first { $0.security == .tls } ?? usable.first
            guard let entry, let security = entry.security, let port = Int(entry.port) else { return nil }
            let local = email.split(separator: "@").first.map(String.init) ?? email
            let username = entry.username
                .replacingOccurrences(of: "%EMAILADDRESS%", with: email)
                .replacingOccurrences(of: "%EMAILLOCALPART%", with: local)
            return ServerConfig(host: entry.hostname, port: port, security: security,
                                username: username.isEmpty ? email : username)
        }
        guard let imap = config("imap"), let smtp = config("smtp") else { return nil }
        return Result(imap: imap, smtp: smtp, displayName: delegate.displayName)
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        struct Server {
            var type = ""
            var hostname = ""
            var port = ""
            var socketType = ""
            var username = ""
            var authentication: [String] = []

            var security: ConnectionSecurity? {
                switch socketType.uppercased() {
                case "SSL": return .tls
                case "STARTTLS": return .startTLS
                default: return nil
                }
            }
            var passwordAuth: Bool {
                authentication.isEmpty || authentication.contains { $0.lowercased().hasPrefix("password") || $0.lowercased() == "plain" }
            }
        }

        var servers: [Server] = []
        var displayName: String?
        private var current: Server?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "incomingServer" || name == "outgoingServer" {
                current = Server(type: attributes["type"] ?? "")
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "hostname": current?.hostname = value
            case "port": current?.port = value
            case "socketType": current?.socketType = value
            case "username": current?.username = value
            case "authentication": current?.authentication.append(value)
            case "displayName": if current == nil, displayName == nil { displayName = value }
            case "incomingServer", "outgoingServer":
                if let server = current { servers.append(server) }
                current = nil
            default: break
            }
            text = ""
        }
    }
}
