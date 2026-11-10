import Foundation

/// A parsed IMAP data item.
public indirect enum IMAPValue: Equatable, Sendable {
    case atom(String)
    case string(Data)
    case list([IMAPValue])
    case null

    /// Text of an atom or string.
    public var text: String? {
        switch self {
        case .atom(let s): return s
        case .string(let d): return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
        default: return nil
        }
    }

    public var data: Data? {
        switch self {
        case .atom(let s): return Data(s.utf8)
        case .string(let d): return d
        default: return nil
        }
    }

    public var number: Int? { text.flatMap { Int($0) } }

    public var items: [IMAPValue] {
        if case .list(let items) = self { return items }
        return []
    }
}

/// Tokenizer for one complete IMAP response (line plus any embedded literals).
struct IMAPTokenizer {
    private let bytes: [UInt8]
    private var pos = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var isAtEnd: Bool {
        pos >= bytes.count || bytes[pos] == 0x0D || bytes[pos] == 0x0A
    }

    mutating func skipSpaces() {
        while pos < bytes.count, bytes[pos] == 0x20 { pos += 1 }
    }

    /// Everything that is left on the line, as text.
    mutating func rest() -> String {
        var end = bytes.count
        while end > pos, bytes[end - 1] == 0x0D || bytes[end - 1] == 0x0A { end -= 1 }
        defer { pos = bytes.count }
        return String(decoding: bytes[pos..<max(pos, end)], as: UTF8.self)
    }

    /// Parses all remaining values on the line.
    mutating func values() -> [IMAPValue] {
        var out: [IMAPValue] = []
        while true {
            skipSpaces()
            if isAtEnd { break }
            if bytes[pos] == UInt8(ascii: ")") { pos += 1; continue } // stray, be lenient
            guard let value = next() else { break }
            out.append(value)
        }
        return out
    }

    mutating func next() -> IMAPValue? {
        skipSpaces()
        guard pos < bytes.count else { return nil }
        switch bytes[pos] {
        case UInt8(ascii: "("):
            pos += 1
            var items: [IMAPValue] = []
            while true {
                skipSpaces()
                guard pos < bytes.count else { break }
                if bytes[pos] == UInt8(ascii: ")") { pos += 1; break }
                if bytes[pos] == 0x0D || bytes[pos] == 0x0A { pos += 1; continue }
                guard let item = next() else { break }
                items.append(item)
            }
            return .list(items)
        case UInt8(ascii: "\""):
            pos += 1
            var out: [UInt8] = []
            while pos < bytes.count, bytes[pos] != UInt8(ascii: "\"") {
                if bytes[pos] == UInt8(ascii: "\\"), pos + 1 < bytes.count { pos += 1 }
                out.append(bytes[pos])
                pos += 1
            }
            pos += 1
            return .string(Data(out))
        case UInt8(ascii: "{"):
            if let literal = literal() { return literal }
            return atom()
        case 0x0D, 0x0A:
            return nil
        default:
            return atom()
        }
    }

    /// `{123}\r\n` followed by 123 raw bytes.
    private mutating func literal() -> IMAPValue? {
        var i = pos + 1
        var count = 0
        var digits = 0
        while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
            count = count * 10 + Int(bytes[i] - 0x30)
            i += 1
            digits += 1
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "+") { i += 1 }
        guard digits > 0, i < bytes.count, bytes[i] == UInt8(ascii: "}") else { return nil }
        i += 1
        if i < bytes.count, bytes[i] == 0x0D { i += 1 }
        guard i < bytes.count, bytes[i] == 0x0A else { return nil }
        i += 1
        guard i + count <= bytes.count else { return nil }
        pos = i + count
        return .string(Data(bytes[i..<i + count]))
    }

    private mutating func atom() -> IMAPValue {
        let start = pos
        var depth = 0
        while pos < bytes.count {
            let b = bytes[pos]
            if b == UInt8(ascii: "[") { depth += 1 }
            else if b == UInt8(ascii: "]") { depth = max(0, depth - 1) }
            else if depth == 0, b == 0x20 || b == UInt8(ascii: "(") || b == UInt8(ascii: ")") { break }
            else if b == 0x0D || b == 0x0A { break }
            pos += 1
        }
        if pos == start { pos += 1 } // never stall
        let text = String(decoding: bytes[start..<min(pos, bytes.count)], as: UTF8.self)
        return text.uppercased() == "NIL" ? .null : .atom(text)
    }
}

/// One untagged server response.
public enum IMAPResponse: Sendable {
    /// `* 12 EXISTS`, `* 3 EXPUNGE`, …
    case count(kind: String, number: Int)
    /// `* 12 FETCH (…)` with upper-cased keys (`BODY[…]` collapsed to `BODY[]`).
    case fetch(seq: Int, items: [String: IMAPValue])
    case list(flags: [String], delimiter: String?, path: String)
    case status(path: String, items: [String: Int])
    case search([UInt32])
    case capability([String])
    /// `* OK [UIDVALIDITY 3] text` and friends: code and its argument.
    case condition(kind: String, code: String?, argument: String?, text: String)
    case other(String)

    static func parse(_ data: Data) -> IMAPResponse {
        var tok = IMAPTokenizer(data)
        guard case .atom("*")? = tok.next(), let first = tok.next()?.text else {
            return .other(String(decoding: data, as: UTF8.self))
        }

        if let number = Int(first) {
            let kind = (tok.next()?.text ?? "").uppercased()
            if kind == "FETCH" {
                let values = tok.next()?.items ?? []
                var items: [String: IMAPValue] = [:]
                var i = 0
                while i + 1 < values.count {
                    var key = (values[i].text ?? "").uppercased()
                    if key.hasPrefix("BODY[") { key = "BODY[]" }
                    items[key] = values[i + 1]
                    i += 2
                }
                return .fetch(seq: number, items: items)
            }
            return .count(kind: kind, number: number)
        }

        switch first.uppercased() {
        case "LIST", "LSUB", "XLIST":
            let values = tok.values()
            guard values.count >= 3, let path = values[2].text else { return .other("LIST") }
            return .list(flags: values[0].items.compactMap(\.text),
                         delimiter: values[1].text,
                         path: path)
        case "STATUS":
            let values = tok.values()
            guard values.count >= 2, let path = values[0].text else { return .other("STATUS") }
            var items: [String: Int] = [:]
            let pairs = values[1].items
            var i = 0
            while i + 1 < pairs.count {
                if let key = pairs[i].text, let n = pairs[i + 1].number { items[key.uppercased()] = n }
                i += 2
            }
            return .status(path: path, items: items)
        case "SEARCH":
            return .search(tok.values().compactMap { $0.text.flatMap { UInt32($0) } })
        case "CAPABILITY":
            return .capability(tok.values().compactMap { $0.text?.uppercased() })
        case "OK", "NO", "BAD", "BYE", "PREAUTH":
            return parseCondition(kind: first.uppercased(), text: tok.rest())
        default:
            return .other(String(decoding: data, as: UTF8.self))
        }
    }

    /// Splits `[CODE arg] human text`.
    static func parseCondition(kind: String, text: String) -> IMAPResponse {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else {
            return .condition(kind: kind, code: nil, argument: nil, text: trimmed)
        }
        let inner = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
        let parts = inner.split(separator: " ", maxSplits: 1)
        let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return .condition(kind: kind,
                          code: parts.first.map { $0.uppercased() },
                          argument: parts.count > 1 ? String(parts[1]) : nil,
                          text: rest)
    }
}

enum ModifiedUTF7 {
    /// Decodes an IMAP mailbox name (RFC 3501 §5.1.3). Returns the input on malformed data.
    static func decode(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var out = ""
        var rest = Substring(input)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            guard let dash = after.firstIndex(of: "-") else { return input }
            let chunk = after[..<dash]
            if chunk.isEmpty {
                out += "&"
            } else {
                var b64 = chunk.replacingOccurrences(of: ",", with: "/")
                while b64.count % 4 != 0 { b64 += "=" }
                guard let data = Data(base64Encoded: b64),
                      let text = String(data: data, encoding: .utf16BigEndian) else { return input }
                out += text
            }
            rest = after[after.index(after: dash)...]
        }
        out += rest
        return out
    }
}
