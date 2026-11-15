import Foundation

/// The first lines of a message for the message list, built from the
/// (possibly truncated) beginning of the body.
public enum MessagePreview {

    public static func text(body: Data, contentType: String, params: [String: String],
                            transferEncoding: String?, limit: Int = 300) -> String? {
        guard let raw = extract(body, contentType.lowercased(), params, transferEncoding, depth: 0) else { return nil }
        let cleaned = clean(raw)
        guard !cleaned.isEmpty else { return nil }
        return cleaned.count > limit ? String(cleaned.prefix(limit)) : cleaned
    }

    private static func extract(_ body: Data, _ type: String, _ params: [String: String],
                                _ encoding: String?, depth: Int) -> String? {
        guard depth < 6 else { return nil }
        if type == "multipart/encrypted" { return nil }
        if type.hasPrefix("multipart/") {
            guard let boundary = params["boundary"] else { return nil }
            var html: String?
            for raw in MIMEPart.splitMultipart(body, boundary: boundary) {
                let (headerData, partBody) = MIMEPart.splitHeader(raw)
                var fields: [String: String] = [:]
                for field in HeaderCodec.parseHeaderBlock(headerData) { fields[field.name.lowercased()] = field.value }
                let parsed = HeaderCodec.parseParameters(fields["content-type"] ?? "text/plain")
                if fields["content-disposition"]?.lowercased().hasPrefix("attachment") == true { continue }
                guard let text = extract(partBody, parsed.value, parsed.params, fields["content-transfer-encoding"], depth: depth + 1)
                else { continue }
                if parsed.value == "text/html" {
                    html = html ?? text
                } else {
                    return text
                }
            }
            return html
        }
        guard type == "text/plain" || type == "text/html" else { return nil }
        let text = decode(body, encoding: encoding, charset: params["charset"])
        if text.contains("-----BEGIN PGP MESSAGE-----") { return nil }
        return type == "text/html" ? stripHTML(text) : text
    }

    private static func decode(_ data: Data, encoding: String?, charset: String?) -> String {
        var bytes: Data
        switch (encoding ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64":
            var clean = data.filter { b in
                (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x2B || b == 0x2F || b == 0x3D
            }
            clean = clean.prefix(clean.count - clean.count % 4)   // drop an incomplete group at the cut
            bytes = Data(base64Encoded: clean) ?? Data()
        case "quoted-printable":
            bytes = TransferEncoding.decodeQuotedPrintable(data)
        default:
            bytes = data
        }
        let name = (charset ?? "utf-8").lowercased()
        if name == "utf-8" || name == "utf8" || name == "us-ascii" {
            // A multi-byte character may be cut off at the end.
            return String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\u{FFFD}", with: "")
        }
        return HeaderCodec.string(from: bytes, charset: charset)
    }

    private static func stripHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "(?is)<(style|script|head|title)[^>]*>.*?(</\\1>|$)", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>|</p>|</div>|</li>|</tr>|</h[1-6]>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]*>?", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        return text
    }

    /// One line of running text: no quotes, no signature, collapsed whitespace.
    private static func clean(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if raw == "-- " { break }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(">") { continue }
            lines.append(line)
        }
        return lines.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
