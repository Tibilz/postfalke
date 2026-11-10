import Foundation

/// Reads address books from a CardDAV server (Nextcloud, Radicale, Baïkal, iCloud, …).
public final class CardDAVClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let baseURL: URL
    private let authorization: String
    private var session: URLSession!

    public init(baseURL: URL, username: String, password: String) {
        self.baseURL = baseURL
        authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: Public API

    /// All contacts of all address books reachable from the configured URL.
    public func fetchContacts() async throws -> [VCard] {
        var cards: [VCard] = []
        for book in try await addressBooks() {
            cards += try await contacts(in: book)
        }
        return cards
    }

    /// Finds the address book collections: the URL itself, or via principal → home set.
    public func addressBooks() async throws -> [URL] {
        let props = "<d:resourcetype/><d:current-user-principal/><card:addressbook-home-set/>"
        var start = baseURL
        var root: [DAVResponse]
        do {
            root = try await propfind(start, depth: 0, props: props)
        } catch MailError.server where baseURL.path.count <= 1 {
            // Bare host name: use the well-known bootstrap path (RFC 6764).
            start = baseURL.appendingPathComponent(".well-known/carddav")
            root = try await propfind(start, depth: 0, props: props)
        }
        guard let first = root.first else { throw MailError.protocolError("Leere Antwort des CardDAV-Servers.") }

        if first.node.find("resourcetype")?.find("addressbook") != nil { return [first.url] }
        if let home = first.href(in: "addressbook-home-set") { return try await list(home) }
        if let principal = first.href(in: "current-user-principal") {
            let answer = try await propfind(principal, depth: 0, props: "<card:addressbook-home-set/>")
            if let home = answer.first?.href(in: "addressbook-home-set") { return try await list(home) }
        }
        // Maybe the URL already is the home collection.
        let books = try await list(first.url)
        if books.isEmpty { throw MailError.server("Unter dieser Adresse wurde kein Adressbuch gefunden.") }
        return books
    }

    private func list(_ home: URL) async throws -> [URL] {
        try await propfind(home, depth: 1, props: "<d:resourcetype/>")
            .filter { $0.node.find("resourcetype")?.find("addressbook") != nil }
            .map(\.url)
    }

    private func contacts(in book: URL) async throws -> [VCard] {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <card:addressbook-query xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
          <d:prop><d:getetag/><card:address-data/></d:prop>
        </card:addressbook-query>
        """
        return try await request("REPORT", book, depth: 1, body: body)
            .compactMap { $0.node.find("address-data")?.text }
            .flatMap(VCardParser.parse)
    }

    // MARK: WebDAV plumbing

    struct DAVResponse {
        var url: URL
        var node: XMLNode

        func href(in property: String) -> URL? {
            guard let text = node.find(property)?.find("href")?.text.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return URL(string: text, relativeTo: url)?.absoluteURL
        }
    }

    private func propfind(_ url: URL, depth: Int, props: String) async throws -> [DAVResponse] {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav"><d:prop>\(props)</d:prop></d:propfind>
        """
        return try await request("PROPFIND", url, depth: depth, body: body)
    }

    private func request(_ method: String, _ url: URL, depth: Int, body: String) async throws -> [DAVResponse] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = Data(body.utf8)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("\(depth)", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MailError.connection(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw MailError.protocolError("Keine HTTP-Antwort.") }
        switch http.statusCode {
        case 207, 200: break
        case 401, 403: throw MailError.authentication("CardDAV-Zugangsdaten wurden abgelehnt (HTTP \(http.statusCode)).")
        default: throw MailError.server("CardDAV-Server antwortet mit HTTP \(http.statusCode).")
        }
        let finalURL = http.url ?? url
        guard let root = XMLNode.parse(data) else { throw MailError.protocolError("Unlesbare Antwort des CardDAV-Servers.") }
        return root.all("response").compactMap { node in
            guard let href = node.find("href")?.text.trimmingCharacters(in: .whitespacesAndNewlines),
                  let resolved = URL(string: href, relativeTo: finalURL)?.absoluteURL else { return nil }
            return DAVResponse(url: resolved, node: node)
        }
    }

    /// URLSession turns redirected requests into GET; WebDAV needs method, body and login kept.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest, let target = request.url,
              target.host == original.url?.host,
              // never downgrade to an unencrypted connection with credentials
              !(original.url?.scheme == "https" && target.scheme != "https") else {
            completionHandler(nil)
            return
        }
        var redirected = original
        redirected.url = target
        completionHandler(redirected)
    }
}

/// A minimal namespace-agnostic XML tree, enough for WebDAV multistatus answers.
final class XMLNode {
    let name: String
    var text = ""
    var children: [XMLNode] = []

    init(name: String) {
        self.name = name
    }

    /// First descendant (depth first) with this local name.
    func find(_ name: String) -> XMLNode? {
        for child in children {
            if child.name == name { return child }
            if let found = child.find(name) { return found }
        }
        return nil
    }

    func all(_ name: String) -> [XMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.all(name) }
    }

    static func parse(_ data: Data) -> XMLNode? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = builder
        return parser.parse() ? builder.root : nil
    }

    private final class Builder: NSObject, XMLParserDelegate {
        let root = XMLNode(name: "#root")
        private lazy var stack: [XMLNode] = [root]

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = XMLNode(name: elementName.lowercased())
            stack.last?.children.append(node)
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if stack.count > 1 { stack.removeLast() }
        }
    }
}
