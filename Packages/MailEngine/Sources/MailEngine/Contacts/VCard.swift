import Foundation

/// The parts of a vCard this app cares about: who it is and their OpenPGP keys.
public struct VCard: Sendable, Equatable {
    public enum Key: Sendable, Equatable {
        /// Key material embedded in the card (binary or ASCII-armored).
        case data(Data)
        /// Key published elsewhere.
        case url(URL)
    }

    public var name: String?
    public var emails: [String] = []
    public var keys: [Key] = []
}

public enum VCardParser {

    /// Parses one or more vCards (versions 3.0 and 4.0).
    public static func parse(_ text: String) -> [VCard] {
        var cards: [VCard] = []
        var current: VCard?
        for line in unfold(text) {
            guard let property = Property(line) else { continue }
            switch property.name {
            case "BEGIN" where property.value.uppercased() == "VCARD":
                current = VCard()
            case "END" where property.value.uppercased() == "VCARD":
                if let card = current { cards.append(card) }
                current = nil
            case "FN":
                current?.name = unescape(property.value)
            case "EMAIL":
                let email = unescape(property.value).trimmingCharacters(in: .whitespaces).lowercased()
                if email.contains("@") { current?.emails.append(email) }
            case "KEY":
                if let key = key(from: property) { current?.keys.append(key) }
            default:
                break
            }
        }
        return cards
    }

    /// Joins folded lines: a line starting with space or tab continues the previous one.
    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                lines.append(raw)
            }
        }
        return lines
    }

    struct Property {
        var name: String
        var params: [String: String] = [:]
        var value: String

        init?(_ line: String) {
            // The first colon outside a quoted parameter value ends the name part.
            var inQuote = false
            var split: String.Index?
            for index in line.indices {
                let ch = line[index]
                if ch == "\"" { inQuote.toggle() }
                if ch == ":", !inQuote { split = index; break }
            }
            guard let split else { return nil }
            value = String(line[line.index(after: split)...])
            var pieces = line[..<split].components(separatedBy: ";")
            var head = pieces.removeFirst()
            if let dot = head.lastIndex(of: ".") { head = String(head[head.index(after: dot)...]) } // group prefix
            name = head.uppercased()
            for piece in pieces {
                let pair = piece.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 {
                    params[pair[0].uppercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                } else if pair.count == 1 {
                    // vCard 2.1 style bare parameters: `KEY;PGP;BASE64:`
                    let bare = pair[0].uppercased()
                    if bare == "BASE64" || bare == "B" { params["ENCODING"] = "B" } else { params["TYPE"] = bare }
                }
            }
        }
    }

    static func unescape(_ value: String) -> String {
        var out = ""
        var escaped = false
        for ch in value {
            if escaped {
                out.append(ch == "n" || ch == "N" ? "\n" : ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    static func key(from property: Property) -> VCard.Key? {
        let value = property.value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        let lower = value.lowercased()

        if lower.hasPrefix("data:") {
            guard let comma = value.firstIndex(of: ",") else { return nil }
            let meta = value[..<comma].lowercased()
            let payload = String(value[value.index(after: comma)...])
            if meta.contains(";base64") {
                let data = TransferEncoding.decodeBase64(Data(payload.utf8))
                return data.isEmpty ? nil : .data(data)
            }
            return (payload.removingPercentEncoding ?? payload).data(using: .utf8).map(VCard.Key.data)
        }
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") {
            return URL(string: value).map(VCard.Key.url)
        }
        if value.contains("BEGIN PGP") {
            return .data(Data(unescape(value).utf8))
        }
        // vCard 3.0: `KEY;TYPE=PGP;ENCODING=b:<base64>`; some exporters omit the encoding.
        let data = TransferEncoding.decodeBase64(Data(value.utf8))
        return data.count > 32 ? .data(data) : nil
    }
}
