import Foundation

/// A `mailto:` link (RFC 6068) or the app's own `postfalke://compose?…`.
public struct MailtoLink: Equatable, Sendable {
    public var to: [String] = []
    public var cc: [String] = []
    public var bcc: [String] = []
    public var subject = ""
    public var body = ""

    public init?(_ url: URL) {
        let scheme = url.scheme?.lowercased()
        let isMailto = scheme == "mailto"
        let isOwn = scheme == "postfalke" && url.host?.lowercased() == "compose"
        guard isMailto || isOwn else { return nil }

        // Split by hand: URLComponents decodes "+" inconsistently and mailto has no authority.
        let raw = url.absoluteString
        let afterScheme = raw[raw.index(after: raw.firstIndex(of: ":")!)...]
        let parts = afterScheme.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        if isMailto, let path = parts.first, !path.isEmpty {
            to += Self.addresses(String(path))
        }
        guard parts.count > 1 else { return }
        for pair in parts[1].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = kv.first?.lowercased() else { continue }
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            switch key {
            case "to": to += Self.addresses(value)
            case "cc": cc += Self.addresses(value)
            case "bcc": bcc += Self.addresses(value)
            // One line only: no header lines can be smuggled in.
            case "subject": subject = value.components(separatedBy: .newlines).joined(separator: " ")
            case "body": body = value.replacingOccurrences(of: "\r\n", with: "\n")
            default: break
            }
        }
    }

    private static func addresses(_ text: String) -> [String] {
        (text.removingPercentEncoding ?? text)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("@") && !$0.contains("\n") && !$0.contains("\r") }
    }
}
