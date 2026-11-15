import XCTest
@testable import MailEngine

final class ThreadingTests: XCTestCase {
    func header(_ uid: UInt32, _ subject: String, id: String? = nil, inReplyTo: String? = nil,
                references: String? = nil, minutes: Double = 0, seen: Bool = true) -> MessageHeader {
        var h = MessageHeader(uid: uid)
        h.subject = subject
        h.messageID = id
        h.inReplyTo = inReplyTo
        h.references = references
        h.date = Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60)
        if seen { h.flags.insert("\\Seen") }
        return h
    }

    func testSubjectNormalisation() {
        XCTAssertEqual(Threading.normalizedSubject("Re: AW: Fwd:  Treffen"), "treffen")
        XCTAssertEqual(Threading.normalizedSubject("WG: [liste] Re[2]: Treffen"), "treffen")
        XCTAssertEqual(Threading.normalizedSubject("Treffen"), "treffen")
    }

    func testReferencesBuildOneConversation() {
        let threads = Threading.group([
            header(1, "Treffen", id: "<a@x>", minutes: 0),
            header(2, "Re: Treffen", id: "<b@x>", inReplyTo: "<a@x>", references: "<a@x>", minutes: 10, seen: false),
            header(3, "Anderes", id: "<c@x>", minutes: 5),
            header(4, "Re: Treffen", id: "<d@x>", inReplyTo: "<b@x>", references: "<a@x> <b@x>", minutes: 20),
        ])
        XCTAssertEqual(threads.map { $0.messages.map(\.uid) }, [[4, 2, 1], [3]])
        XCTAssertEqual(threads[0].unreadCount, 1)
        XCTAssertEqual(threads[0].id, 4)
    }

    /// Two answers to a message that is in another folder (e.g. sent by me).
    func testSharedMissingParent() {
        let threads = Threading.group([
            header(1, "Re: Frage", id: "<r1@x>", inReplyTo: "<mine@x>", minutes: 1),
            header(2, "AW: Frage", id: "<r2@x>", references: "<mine@x>", minutes: 2),
        ])
        XCTAssertEqual(threads.count, 1)
    }

    func testSubjectFallbackOnlyForReplies() {
        let threads = Threading.group([
            header(1, "Hallo", id: "<1@x>", minutes: 1),
            header(2, "Hallo", id: "<2@x>", minutes: 2),           // unrelated, same subject
            header(3, "AW: Bericht", id: "<3@x>", minutes: 3),     // client without references
            header(4, "Bericht", id: "<4@x>", minutes: 0),
            header(5, "...", id: "<5@x>", minutes: 4),             // protected subjects
            header(6, "Re: ...", id: "<6@x>", minutes: 5),
        ])
        let groups = Set(threads.map { Set($0.messages.map(\.uid)) })
        XCTAssertEqual(groups, [[1], [2], [3, 4], [5], [6]])
    }
}
