import XCTest
@testable import MailEngine

final class MailtoTests: XCTestCase {
    func testRFC6068Examples() throws {
        let simple = try XCTUnwrap(MailtoLink(URL(string: "mailto:chris@example.com")!))
        XCTAssertEqual(simple.to, ["chris@example.com"])

        let full = try XCTUnwrap(MailtoLink(URL(string:
            "mailto:a@example.org,b@example.org?cc=c@example.org&bcc=d@example.org&subject=Gr%C3%BC%C3%9Fe%20aus%20M%C3%BCnchen&body=Zeile%201%0D%0AZeile%202")!))
        XCTAssertEqual(full.to, ["a@example.org", "b@example.org"])
        XCTAssertEqual(full.cc, ["c@example.org"])
        XCTAssertEqual(full.bcc, ["d@example.org"])
        XCTAssertEqual(full.subject, "Grüße aus München")
        XCTAssertEqual(full.body, "Zeile 1\nZeile 2")

        // Address only in the query, upper-case keys, plus sign kept literally.
        let query = try XCTUnwrap(MailtoLink(URL(string: "mailto:?To=x%2Btag@example.org&SUBJECT=a+b")!))
        XCTAssertEqual(query.to, ["x+tag@example.org"])
        XCTAssertEqual(query.subject, "a+b")
    }

    func testOwnSchemeAndForeignSchemes() throws {
        let own = try XCTUnwrap(MailtoLink(URL(string: "postfalke://compose?to=a@example.org&subject=Hallo")!))
        XCTAssertEqual(own.to, ["a@example.org"])
        XCTAssertEqual(own.subject, "Hallo")
        XCTAssertNil(MailtoLink(URL(string: "https://example.org")!))
        XCTAssertNil(MailtoLink(URL(fileURLWithPath: "/tmp/key.asc")))
    }

    /// A link must not smuggle header lines into the message.
    func testNoHeaderInjection() throws {
        let link = try XCTUnwrap(MailtoLink(URL(string: "mailto:a@example.org?subject=Hi%0D%0ABcc:%20evil@example.org")!))
        XCTAssertFalse(link.subject.contains("\n"))
        XCTAssertFalse(link.subject.contains("\r"))
    }
}
