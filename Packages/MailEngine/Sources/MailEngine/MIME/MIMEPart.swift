import Foundation

/// One node of a parsed MIME tree.
public struct MIMEPart: Sendable {
    public struct Field: Sendable {
        public var name: String
        public var value: String
    }

    public var fields: [Field]
    /// The exact bytes of this entity (headers + body) as they appeared in the parent.
    /// PGP/MIME signatures are computed over these bytes.
    public var raw: Data
    /// Body bytes, still transfer-encoded.
    public var body: Data
    public var parts: [MIMEPart]

    public var mediaType: String
    public var typeParams: [String: String]
    public var disposition: String?
    public var dispositionParams: [String: String]

    // MARK: Parsing

    public init(data: Data, depth: Int = 0) {
        raw = data
        let (headerData, bodyData) = MIMEPart.splitHeader(data)
        fields = HeaderCodec.parseHeaderBlock(headerData).map { Field(name: $0.name, value: $0.value) }
        body = bodyData
        parts = []

        let contentType = fields.first { $0.name.lowercased() == "content-type" }?.value
        let parsed = HeaderCodec.parseParameters(contentType ?? "text/plain")
        mediaType = parsed.value.isEmpty || !parsed.value.contains("/") ? "text/plain" : parsed.value
        typeParams = parsed.params

        if let value = fields.first(where: { $0.name.lowercased() == "content-disposition" })?.value {
            let d = HeaderCodec.parseParameters(value)
            disposition = d.value
            dispositionParams = d.params
        } else {
            disposition = nil
            dispositionParams = [:]
        }

        if mediaType.hasPrefix("multipart/"), let boundary = typeParams["boundary"], depth < 20 {
            parts = MIMEPart.splitMultipart(bodyData, boundary: boundary).map {
                MIMEPart(data: $0, depth: depth + 1)
            }
        }
    }

    /// Splits at the first empty line. Returns (headers, body).
    static func splitHeader(_ data: Data) -> (Data, Data) {
        if data.starts(with: [0x0D, 0x0A]) { return (Data(), Data(data.dropFirst(2))) }
        if data.starts(with: [0x0A]) { return (Data(), Data(data.dropFirst(1))) }
        let crlf = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A]))
        let lf = data.range(of: Data([0x0A, 0x0A]))
        let cut: Range<Data.Index>?
        switch (crlf, lf) {
        case let (a?, b?): cut = a.lowerBound < b.lowerBound ? a : b
        case let (a?, nil): cut = a
        case let (nil, b?): cut = b
        default: cut = nil
        }
        guard let cut else { return (data, Data()) }
        return (Data(data[data.startIndex..<cut.lowerBound]), Data(data[cut.upperBound...]))
    }

    /// Returns the raw bytes of each body part between the boundary delimiters.
    static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let bytes = [UInt8](body)
        let delimiter = [UInt8](("--" + boundary).utf8)
        var result: [Data] = []
        var partStart: Int?
        var lineStart = 0

        while lineStart < bytes.count {
            var lineEnd = lineStart
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            let next = min(lineEnd + 1, bytes.count)

            let lineLength = lineEnd - lineStart
            if lineLength >= delimiter.count,
               bytes[lineStart..<lineStart + delimiter.count].elementsEqual(delimiter) {
                var tail = bytes[(lineStart + delimiter.count)..<lineEnd]
                if tail.last == 0x0D { tail = tail.dropLast() }
                let isClose = tail.starts(with: [0x2D, 0x2D])
                let trailing = isClose ? tail.dropFirst(2) : tail
                if trailing.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                    if let start = partStart {
                        // The line break before the delimiter belongs to the delimiter.
                        var end = lineStart
                        if end > start, bytes[end - 1] == 0x0A { end -= 1 }
                        if end > start, bytes[end - 1] == 0x0D { end -= 1 }
                        result.append(Data(bytes[start..<max(start, end)]))
                    }
                    partStart = isClose ? nil : next
                    if isClose { break }
                }
            }
            lineStart = next
        }
        // Unterminated final part: take what is there.
        if let start = partStart, start < bytes.count {
            result.append(Data(bytes[start...]))
        }
        return result
    }

    // MARK: Accessors

    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return fields.first { $0.name.lowercased() == lower }?.value
    }

    public func decodedHeader(_ name: String) -> String? {
        header(name).map(HeaderCodec.decodeWords)
    }

    /// Body with the content transfer encoding removed.
    public var decodedBody: Data {
        TransferEncoding.decode(body, encoding: header("Content-Transfer-Encoding"))
    }

    /// Body as text in the declared charset.
    public var text: String {
        HeaderCodec.string(from: decodedBody, charset: typeParams["charset"])
    }

    public var filename: String? {
        dispositionParams["filename"] ?? typeParams["name"]
    }

    public var contentID: String? {
        header("Content-ID")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    public var isAttachment: Bool {
        if disposition == "attachment" { return true }
        if mediaType.hasPrefix("multipart/") { return false }
        if mediaType == "text/plain" || mediaType == "text/html" { return false }
        return true
    }
}

public struct MailAttachment: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public var filename: String
    public var mimeType: String
    public var data: Data
    public var contentID: String?

    public init(filename: String, mimeType: String, data: Data, contentID: String? = nil) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.contentID = contentID
    }

    public var isPGPKey: Bool {
        mimeType == "application/pgp-keys"
            || (filename.lowercased().hasSuffix(".asc") && data.prefix(200).range(of: Data("BEGIN PGP PUBLIC KEY".utf8)) != nil)
    }
}

/// The displayable content collected from a MIME tree.
public struct MessageContent: Sendable {
    public var plain: String?
    public var html: String?
    public var attachments: [MailAttachment] = []

    public init() {}

    public init(part: MIMEPart) {
        collect(part)
    }

    private mutating func collect(_ part: MIMEPart) {
        if part.mediaType == "multipart/alternative" {
            // Later alternatives are richer; take the best plain and html variant.
            for child in part.parts { collect(child) }
            return
        }
        if part.mediaType.hasPrefix("multipart/") {
            for child in part.parts { collect(child) }
            return
        }
        if !part.isAttachment, part.mediaType == "text/plain" {
            let text = part.text
            plain = plain.map { $0 + "\n" + text } ?? text
            return
        }
        if !part.isAttachment, part.mediaType == "text/html" {
            let text = part.text
            html = html.map { $0 + "<hr>" + text } ?? text
            return
        }
        let fallbackName: String
        switch part.mediaType {
        case "message/rfc822": fallbackName = "Nachricht.eml"
        case "application/pgp-keys": fallbackName = "OpenPGP-Schlüssel.asc"
        case "application/pgp-signature": fallbackName = "signature.asc"
        default: fallbackName = "Anhang"
        }
        attachments.append(MailAttachment(filename: part.filename ?? fallbackName,
                                          mimeType: part.mediaType,
                                          data: part.decodedBody,
                                          contentID: part.contentID))
    }

    /// HTML with `cid:` image references replaced by inline data URLs.
    public var htmlWithInlineImages: String? {
        guard var html else { return nil }
        for attachment in attachments {
            guard let cid = attachment.contentID, html.contains("cid:\(cid)") else { continue }
            let url = "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())"
            html = html.replacingOccurrences(of: "cid:\(cid)", with: url)
        }
        return html
    }
}
