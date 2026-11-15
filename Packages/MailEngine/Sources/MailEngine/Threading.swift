import Foundation

/// Messages of one conversation, newest first.
public struct MessageThread: Identifiable, Sendable {
    public var messages: [MessageHeader]

    public init(messages: [MessageHeader]) {
        precondition(!messages.isEmpty, "a conversation has at least one message")
        self.messages = messages
    }

    /// The newest message identifies the conversation in a list.
    public var id: UInt32 { messages[0].uid }
    public var latest: MessageHeader { messages[0] }
    public var unreadCount: Int { messages.filter { !$0.isSeen }.count }
    public var isFlagged: Bool { messages.contains(where: \.isFlagged) }
}

public enum Threading {
    private static let prefix = try! NSRegularExpression(
        pattern: #"^\s*((re|aw|fwd?|wg|sv|antw|tr)(\[\d+\])?\s*:|\[[^\]]{1,40}\])\s*"#, options: [.caseInsensitive])
    private static let messageID = try! NSRegularExpression(pattern: #"<[^<>\s]+>"#)

    /// Subject without reply/forward prefixes and list tags, lowercased.
    public static func normalizedSubject(_ subject: String) -> String {
        var text = subject
        while let match = prefix.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text), !range.isEmpty {
            text.removeSubrange(range)
        }
        return text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func isReply(_ subject: String) -> Bool {
        normalizedSubject(subject) != subject.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func ids(_ text: String?) -> [String] {
        guard let text else { return [] }
        let ns = text as NSString
        return messageID.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range).lowercased() }
    }

    /// Groups messages into conversations (by Message-ID references, and by subject
    /// for replies from clients that send no references). Newest conversation first.
    public static func group(_ headers: [MessageHeader]) -> [MessageThread] {
        var parent = Array(headers.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        func union(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }

        // Every Message-ID a message has or points to is an anchor; sharing one joins.
        var anchors: [String: Int] = [:]
        for (index, header) in headers.enumerated() {
            for id in ids(header.messageID) + ids(header.inReplyTo) + ids(header.references) {
                if let other = anchors[id] { union(index, other) } else { anchors[id] = index }
            }
        }

        // Subject fallback: a reply ("Re: X") joins the conversation about "X".
        var bySubject: [String: Int] = [:]
        for (index, header) in headers.enumerated() {
            let subject = normalizedSubject(header.subject)
            guard !subject.isEmpty, subject != "...", subject != "…", !isReply(header.subject) else { continue }
            if bySubject[subject] == nil { bySubject[subject] = index }
        }
        for (index, header) in headers.enumerated() where isReply(header.subject) {
            let subject = normalizedSubject(header.subject)
            guard !subject.isEmpty, subject != "...", subject != "…" else { continue }
            if let other = bySubject[subject] { union(index, other) } else { bySubject[subject] = index }
        }

        var groups: [Int: [MessageHeader]] = [:]
        for (index, header) in headers.enumerated() { groups[find(index), default: []].append(header) }
        return groups.values
            .map { MessageThread(messages: $0.sorted { ($0.sortDate, $0.uid) > ($1.sortDate, $1.uid) }) }
            .sorted { ($0.latest.sortDate, $0.latest.uid) > ($1.latest.sortDate, $1.latest.uid) }
    }
}
