import XCTest
@testable import MailEngine

final class ProviderAndPreviewTests: XCTestCase {

    // MARK: Providers

    func testProviderDetection() {
        XCTAssertEqual(MailProvider.detect(host: "imap.gmail.com", email: "x@firma.de"), .google)   // Workspace domain
        XCTAssertEqual(MailProvider.detect(host: "", email: "jemand@googlemail.com"), .google)
        XCTAssertEqual(MailProvider.detect(host: "outlook.office365.com", email: "a@b.c"), .microsoft)
        XCTAssertEqual(MailProvider.detect(host: "", email: "a@hotmail.de"), .microsoft)
        XCTAssertEqual(MailProvider.detect(host: "imap.mail.me.com", email: "a@b.c"), .apple)
        XCTAssertEqual(MailProvider.detect(host: "", email: "a@icloud.com"), .apple)
        XCTAssertEqual(MailProvider.detect(host: "imap.mail.yahoo.com", email: "a@b.c"), .yahoo)
        XCTAssertEqual(MailProvider.detect(host: "imap.web.de", email: "a@b.c"), .gmxWebDe)
        XCTAssertEqual(MailProvider.detect(host: "", email: "a@gmx.net"), .gmxWebDe)
        XCTAssertEqual(MailProvider.detect(host: "mail.example.org", email: "a@example.org"), .other)
        XCTAssertNotNil(MailProvider.google.loginHint)
        XCTAssertNil(MailProvider.other.loginHint)
    }

    func testGoogleAppPasswordSpacesAreRemoved() {
        XCTAssertEqual(MailProvider.google.normalizedPassword("abcd efgh ijkl mnop"), "abcdefghijklmnop")
        XCTAssertEqual(MailProvider.google.normalizedPassword(" abcd efgh ijkl mnop\n"), "abcdefghijklmnop")
        // Normal passwords stay untouched, also for other providers.
        XCTAssertEqual(MailProvider.google.normalizedPassword("mein pass wort"), "mein pass wort")
        XCTAssertEqual(MailProvider.other.normalizedPassword("abcd efgh ijkl mnop"), "abcd efgh ijkl mnop")
        XCTAssertEqual(MailProvider.apple.normalizedPassword("abcd-efgh-ijkl-mnop"), "abcd-efgh-ijkl-mnop")
    }

    // MARK: IMAP: header block and text preview come back under separate keys

    func testFetchKeysStaySeparate() {
        let header = "Subject: Hallo\r\n\r\n"
        let text = "Erste Zeile"
        let raw = "* 3 FETCH (UID 7 BODY[HEADER.FIELDS (SUBJECT)] {\(header.utf8.count)}\r\n\(header) BODY[TEXT]<0> {\(text.utf8.count)}\r\n\(text))\r\n"
        guard case .fetch(_, let items) = IMAPResponse.parse(Data(raw.utf8)) else { return XCTFail("no fetch") }
        XCTAssertEqual(items["BODY[HEADER]"]?.text, header)
        XCTAssertEqual(items["BODY[TEXT]"]?.text, text)
        guard case .fetch(_, let full) = IMAPResponse.parse(Data("* 1 FETCH (UID 1 BODY[] {2}\r\nab)\r\n".utf8)) else { return XCTFail() }
        XCTAssertEqual(full["BODY[]"]?.text, "ab")
    }

    func testHeaderKeepsContentTypeDetails() {
        let block = "Content-Type: multipart/alternative; boundary=\"XYZ\"\r\nContent-Transfer-Encoding: 7bit\r\nSubject: s\r\n\r\n"
        let raw = "* 1 FETCH (UID 5 FLAGS () BODY[HEADER.FIELDS (CONTENT-TYPE)] {\(block.utf8.count)}\r\n\(block))\r\n"
        let header = IMAPClient.headers(from: [IMAPResponse.parse(Data(raw.utf8))]).first
        XCTAssertEqual(header?.contentType, "multipart/alternative")
        XCTAssertEqual(header?.contentTypeParams["boundary"], "XYZ")
        XCTAssertEqual(header?.transferEncoding, "7bit")
    }

    // MARK: Previews

    func preview(_ body: String, _ contentType: String, _ params: [String: String] = [:], _ encoding: String? = nil) -> String? {
        MessagePreview.text(body: Data(body.utf8), contentType: contentType, params: params, transferEncoding: encoding)
    }

    func testPlainQuotedPrintable() {
        let body = "Gr=C3=BC=C3=9Fe aus\r\nM=C3=BCnchen,\r\n\r\n> alter Text\r\n> noch mehr\r\nbis bald"
        XCTAssertEqual(preview(body, "text/plain", ["charset": "utf-8"], "quoted-printable"),
                       "Grüße aus München, bis bald")
    }

    func testReplyAttributionIsSkipped() {
        let body = "Klingt gut!\r\n\r\nAm 15. November 2026 um 14:57 schrieb Tina Tester:\r\n> Erste Nachricht\r\n"
        XCTAssertEqual(preview(body, "text/plain"), "Klingt gut!")
        let english = "\r\nOn Mon, Nov 16, 2026 at 9:00 AM Bob <b@x> wrote:\r\n> quoted\r\nSure."
        XCTAssertEqual(preview(english, "text/plain"), "Sure.")
        // A colon at the end of ordinary text stays.
        XCTAssertEqual(preview("Einkaufsliste:\r\nBrot", "text/plain"), "Einkaufsliste: Brot")
    }

    func testMultipartPrefersPlainAndSurvivesTruncation() {
        let plain = Data("Hallo Welt, das ist die Vorschau mit Umlauten äöü".utf8).base64EncodedString()
        // Truncated in the middle of the base64 text and of the html part.
        let body = "--B\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            + plain + "\r\n--B\r\nContent-Type: text/html\r\n\r\n<p>Hal"
        XCTAssertEqual(preview(body, "multipart/alternative", ["boundary": "B"]),
                       "Hallo Welt, das ist die Vorschau mit Umlauten äöü")
        let cut = String(body.prefix(body.count - 60))  // ends inside the base64 block
        XCTAssertTrue(preview(cut, "multipart/alternative", ["boundary": "B"])?.hasPrefix("Hallo Welt") == true)
    }

    func testHTMLOnlyAndNested() {
        let html = "<html><head><style>p{color:red}</style></head><body><p>Hallo&nbsp;<b>du</b> &amp; ich</p><p>Zweite</p></body></html>"
        XCTAssertEqual(preview(html, "text/html"), "Hallo du & ich Zweite")
        let nested = "--O\r\nContent-Type: multipart/alternative; boundary=I\r\n\r\n--I\r\nContent-Type: text/html\r\n\r\n<div>Innen</div>\r\n--I--\r\n--O\r\nContent-Type: image/png\r\n\r\nxxx\r\n--O--"
        XCTAssertEqual(preview(nested, "multipart/mixed", ["boundary": "O"]), "Innen")
    }

    func testNoPreviewForEncryptedOrBinary() {
        XCTAssertNil(preview("whatever", "multipart/encrypted", ["boundary": "B"]))
        XCTAssertNil(preview("-----BEGIN PGP MESSAGE-----\r\nhQEMA", "text/plain"))
        XCTAssertNil(preview("\u{1}\u{2}", "application/pdf"))
    }

    func testLatin1AndLength() {
        let latin = Data([0x47, 0x72, 0xFC, 0xDF, 0x65]) // "Grüße" in ISO-8859-1
        XCTAssertEqual(MessagePreview.text(body: latin, contentType: "text/plain", params: ["charset": "iso-8859-1"], transferEncoding: nil), "Grüße")
        let long = String(repeating: "Wort ", count: 200)
        XCTAssertLessThanOrEqual(preview(long, "text/plain")?.count ?? 0, 300)
    }
}
