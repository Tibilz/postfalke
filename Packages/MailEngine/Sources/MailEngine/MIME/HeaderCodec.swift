import Foundation

/// Parsing and encoding of RFC 5322 / 2047 / 2231 header syntax.
public enum HeaderCodec {

    // MARK: Charsets

    public static func string(from data: Data, charset: String?) -> String {
        let name = (charset ?? "utf-8").trimmingCharacters(in: .whitespaces).lowercased()
        if name != "utf-8", name != "utf8", name != "us-ascii" {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let s = String(data: data, encoding: encoding) { return s }
            }
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    // MARK: Header blocks

    /// Splits a raw header block into unfolded `(name, value)` pairs.
    public static func parseHeaderBlock(_ data: Data) -> [(name: String, value: String)] {
        let text = string(from: data, charset: "utf-8")
        var fields: [(name: String, value: String)] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty { continue }
            if let first = line.first, first == " " || first == "\t" {
                guard !fields.isEmpty else { continue }
                fields[fields.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                fields.append((name, value))
            }
        }
        return fields
    }

    // MARK: RFC 2047 encoded words

    private static let encodedWord = try! NSRegularExpression(
        pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?\s]*)\?="#)

    /// Decodes `=?charset?B/Q?…?=` words inside a header value.
    public static func decodeWords(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        let ns = input as NSString
        let matches = encodedWord.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var out = ""
        var cursor = 0
        var pendingCharset: String?
        var pending = Data()

        func flush() {
            if let charset = pendingCharset {
                out += string(from: pending, charset: charset)
            }
            pendingCharset = nil
            pending = Data()
        }

        for match in matches {
            let between = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            // Whitespace between two encoded words is not part of the text.
            if !(pendingCharset != nil && between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                flush()
                out += between
            }
            var charset = ns.substring(with: match.range(at: 1)).lowercased()
            if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) } // language tag
            let kind = ns.substring(with: match.range(at: 2)).lowercased()
            let payload = ns.substring(with: match.range(at: 3))
            let bytes: Data
            if kind == "b" {
                bytes = TransferEncoding.decodeBase64(Data(payload.utf8))
            } else {
                bytes = TransferEncoding.decodeQuotedPrintable(
                    Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
            }
            if let current = pendingCharset, current != charset { flush() }
            pendingCharset = charset
            pending.append(bytes)
            cursor = match.range.location + match.range.length
        }
        flush()
        out += ns.substring(from: cursor)
        return out
    }

    /// Encodes free text for use in a header (Subject, display names).
    public static func encodeWords(_ text: String) -> String {
        let needsEncoding = text.unicodeScalars.contains { !$0.isASCII || $0.value < 0x20 } || text.contains("=?")
        guard needsEncoding else { return text }
        var words: [String] = []
        var chunk = Data()
        for character in text {
            let bytes = Data(String(character).utf8)
            if chunk.count + bytes.count > 42 {
                words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=")
                chunk = Data()
            }
            chunk.append(bytes)
        }
        if !chunk.isEmpty { words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=") }
        return words.joined(separator: "\r\n ")
    }

    // MARK: Addresses

    public static func parseAddressList(_ input: String?) -> [MailAddress] {
        guard let input, !input.isEmpty else { return [] }
        var result: [MailAddress] = []
        for var entry in splitTopLevel(input, separators: [",", ";"]) {
            entry = entry.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            // Group syntax: `Team: a@x, b@y;` – drop the label.
            if let colon = firstTopLevel(":", in: entry), !entry[..<colon].contains("@") {
                entry = String(entry[entry.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                guard !entry.isEmpty else { continue }
            }
            if let open = lastTopLevel("<", in: entry),
               let close = entry[open...].firstIndex(of: ">") {
                let email = entry[entry.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                var name = String(entry[..<open]).trimmingCharacters(in: .whitespaces)
                name = decodeWords(unquote(name))
                guard email.contains("@") else { continue }
                result.append(MailAddress(name: name.isEmpty ? nil : name, email: email))
            } else {
                var email = entry
                var name: String?
                if let open = email.firstIndex(of: "("), let close = email.lastIndex(of: ")"), open < close {
                    name = decodeWords(String(email[email.index(after: open)..<close]))
                    email.removeSubrange(open...close)
                }
                email = email.trimmingCharacters(in: .whitespaces)
                guard email.contains("@"), !email.contains(" ") else { continue }
                result.append(MailAddress(name: name, email: email))
            }
        }
        return result
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        var out = ""
        var escaped = false
        for ch in text.dropFirst().dropLast() {
            if escaped { out.append(ch); escaped = false }
            else if ch == "\\" { escaped = true }
            else { out.append(ch) }
        }
        return out
    }

    /// Walks `text` and reports characters that are outside quotes, comments and angle brackets.
    private static func scanTopLevel(_ text: String, _ body: (String.Index, Character, _ inAngle: Bool) -> Void) {
        var inQuote = false, escaped = false, comment = 0, angle = false
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if escaped { escaped = false }
            else if ch == "\\" { escaped = true }
            else if inQuote { if ch == "\"" { inQuote = false } }
            else if ch == "\"" { inQuote = true }
            else if ch == "(" { comment += 1 }
            else if ch == ")", comment > 0 { comment -= 1 }
            else if comment == 0 {
                body(i, ch, angle)
                if ch == "<" { angle = true } else if ch == ">" { angle = false }
            }
            i = text.index(after: i)
        }
    }

    private static func splitTopLevel(_ text: String, separators: Set<Character>) -> [String] {
        var cuts: [String.Index] = []
        scanTopLevel(text) { index, ch, inAngle in
            if !inAngle, separators.contains(ch) { cuts.append(index) }
        }
        var parts: [String] = []
        var start = text.startIndex
        for cut in cuts {
            parts.append(String(text[start..<cut]))
            start = text.index(after: cut)
        }
        parts.append(String(text[start...]))
        return parts
    }

    private static func firstTopLevel(_ target: Character, in text: String) -> String.Index? {
        var found: String.Index?
        scanTopLevel(text) { index, ch, inAngle in
            if found == nil, !inAngle, ch == target { found = index }
        }
        return found
    }

    private static func lastTopLevel(_ target: Character, in text: String) -> String.Index? {
        var found: String.Index?
        scanTopLevel(text) { index, ch, _ in
            if ch == target { found = index }
        }
        return found
    }

    /// Header form of an address: `=?UTF-8?B?…?= <mail@example.org>`.
    public static func formatAddress(_ address: MailAddress) -> String {
        guard let name = address.name, !name.isEmpty else { return address.email }
        let isPlain = name.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 }
        if !isPlain { return "\(encodeWords(name)) <\(address.email)>" }
        let atomSafe = name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || " !#$%&'*+-/=?^_`{|}~".unicodeScalars.contains($0)
        }
        if atomSafe { return "\(name) <\(address.email)>" }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\" <\(address.email)>"
    }

    public static func formatAddressList(_ list: [MailAddress]) -> String {
        list.map(formatAddress).joined(separator: ",\r\n ")
    }

    // MARK: Dates

    private static let dateFormatters: [DateFormatter] = {
        ["d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm:ss zzz",
         "d MMM yyyy HH:mm:ss", "d MMM yy HH:mm:ss Z"].map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = format
            return f
        }
    }()

    public static func parseDate(_ input: String?) -> Date? {
        guard var text = input else { return nil }
        if let paren = text.firstIndex(of: "(") { text = String(text[..<paren]) } // "(CEST)"
        if let comma = text.firstIndex(of: ",") { text = String(text[text.index(after: comma)...]) } // weekday
        text = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        for formatter in dateFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    public static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    /// IMAP INTERNALDATE: `17-Jul-1996 02:44:25 -0700`.
    static func parseInternalDate(_ input: String?) -> Date? {
        guard let input else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return f.date(from: input.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Parameters (Content-Type, Content-Disposition)

    /// Splits `text/plain; charset="utf-8"; name*=UTF-8''a%20b` into value and parameters.
    public static func parseParameters(_ input: String) -> (value: String, params: [String: String]) {
        let pieces = splitParameters(input)
        let value = pieces.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var plain: [String: String] = [:]
        var extended: [String: [(index: Int, encoded: Bool, text: String)]] = [:]

        for piece in pieces.dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            var name = piece[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var text = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("\"") { text = unquote(text) }
            guard name.contains("*") else {
                plain[name] = decodeWords(text)
                continue
            }
            // RFC 2231: name*0*=…, name*1=…, name*=…
            var encoded = false
            if name.hasSuffix("*") { encoded = true; name.removeLast() }
            var index = 0
            if let star = name.firstIndex(of: "*") {
                index = Int(name[name.index(after: star)...]) ?? 0
                name = String(name[..<star])
            }
            extended[name, default: []].append((index, encoded, text))
        }

        for (name, parts) in extended {
            var charset: String?
            var bytes = Data()
            for (offset, part) in parts.sorted(by: { $0.index < $1.index }).enumerated() {
                var text = part.text
                if part.encoded {
                    if offset == 0 {
                        let fields = text.components(separatedBy: "'")
                        if fields.count >= 3 {
                            charset = fields[0]
                            text = fields[2...].joined(separator: "'")
                        }
                    }
                    bytes.append(percentDecode(text))
                } else {
                    bytes.append(Data(text.utf8))
                }
            }
            plain[name] = string(from: bytes, charset: charset)
        }
        return (value, plain)
    }

    private static func splitParameters(_ input: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuote = false, escaped = false
        for ch in input {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" && inQuote { current.append(ch); escaped = true; continue }
            if ch == "\"" { inQuote.toggle() }
            if ch == ";" && !inQuote {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    private static func percentDecode(_ text: String) -> Data {
        var out = Data()
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.count,
               let value = UInt8(String(decoding: bytes[i + 1...i + 2], as: UTF8.self), radix: 16) {
                out.append(value)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    /// `name="…"` parameter with RFC 2231 encoding when needed.
    static func formatParameter(_ name: String, _ value: String) -> String {
        if value.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 }) {
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\(name)=\"\(escaped)\""
        }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(name)*=UTF-8''\(encoded)"
    }
}
