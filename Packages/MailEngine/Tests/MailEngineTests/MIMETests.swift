import XCTest
@testable import MailEngine

final class MIMETests: XCTestCase {

    func testEncodedWords() {
        XCTAssertEqual(HeaderCodec.decodeWords("=?UTF-8?B?R3LDvMOfZQ==?= aus =?iso-8859-1?Q?M=FCnchen?="), "Grüße aus München")
        // Adjacent words are joined, even when a character is split between them.
        XCTAssertEqual(HeaderCodec.decodeWords("=?UTF-8?B?w4Q=?=\r\n =?UTF-8?B?w5Y=?="), "ÄÖ")
        XCTAssertEqual(HeaderCodec.decodeWords("=?UTF-8?Q?a_b?="), "a b")
        let long = "Überraschung: sehr langer Betreff mit vielen Umlauten äöüß und Emoji 🎉🎉🎉"
        let encoded = HeaderCodec.encodeWords(long)
        XCTAssertTrue(encoded.components(separatedBy: "\r\n ").allSatisfy { $0.count <= 75 })
        XCTAssertEqual(HeaderCodec.decodeWords(encoded.replacingOccurrences(of: "\r\n", with: "")), long)
        XCTAssertEqual(HeaderCodec.encodeWords("plain"), "plain")
    }

    func testAddresses() {
        let list = HeaderCodec.parseAddressList(
            "\"Müller, Hans\" <hans@example.org>, =?UTF-8?B?SsO8cmdlbg==?= <j@example.org>, plain@example.org, undisclosed-recipients:;")
        XCTAssertEqual(list.map(\.email), ["hans@example.org", "j@example.org", "plain@example.org"])
        XCTAssertEqual(list[0].name, "Müller, Hans")
        XCTAssertEqual(list[1].name, "Jürgen")
        XCTAssertNil(list[2].name)
        XCTAssertEqual(HeaderCodec.formatAddress(MailAddress(name: "Doe, John", email: "a@b.c")), "\"Doe, John\" <a@b.c>")
        let roundTrip = HeaderCodec.parseAddressList(HeaderCodec.formatAddress(MailAddress(name: "Jörg Öl", email: "a@b.c")))
        XCTAssertEqual(roundTrip.first?.name, "Jörg Öl")
    }

    func testDates() {
        let date = HeaderCodec.parseDate("Tue, 10 Nov 2026 17:14:05 +0100 (CET)")
        XCTAssertEqual(date?.timeIntervalSince1970, 1_794_327_245)
        XCTAssertNotNil(HeaderCodec.parseDate("10 Nov 2026 17:14 +0000"))
        XCTAssertEqual(HeaderCodec.parseDate(HeaderCodec.formatDate(Date(timeIntervalSince1970: 1_700_000_000)))?.timeIntervalSince1970, 1_700_000_000)
        XCTAssertNotNil(HeaderCodec.parseInternalDate("17-Jul-1996 02:44:25 -0700"))
    }

    func testParameters() {
        let p = HeaderCodec.parseParameters("Multipart/Mixed; boundary=\"a;b\"; name*0*=UTF-8''%C3%84rger; name*1*=%20.pdf")
        XCTAssertEqual(p.value, "multipart/mixed")
        XCTAssertEqual(p.params["boundary"], "a;b")
        XCTAssertEqual(p.params["name"], "Ärger .pdf")
        let formatted = HeaderCodec.formatParameter("filename", "Übersicht 2026.pdf")
        XCTAssertEqual(HeaderCodec.parseParameters("attachment; " + formatted).params["filename"], "Übersicht 2026.pdf")
    }

    func testQuotedPrintable() {
        let text = "Grüße = Test\nFrom here\n" + String(repeating: "ä", count: 60) + "\nTrailing space \n"
        let encoded = TransferEncoding.encodeQuotedPrintable(text)
        XCTAssertTrue(encoded.components(separatedBy: "\r\n").allSatisfy { $0.count <= 76 })
        XCTAssertFalse(encoded.contains("\r\nFrom "))
        let decoded = String(decoding: TransferEncoding.decodeQuotedPrintable(Data(encoded.utf8)), as: UTF8.self)
        XCTAssertEqual(decoded, text.replacingOccurrences(of: "\n", with: "\r\n"))
    }

    func testMultipartParsing() {
        let raw = [
            "From: A <a@example.org>",
            "Subject: =?UTF-8?Q?Hall=C3=B6?=",
            "Content-Type: multipart/mixed; boundary=XX",
            "",
            "preamble",
            "--XX",
            "Content-Type: multipart/alternative; boundary=\"YY\"",
            "",
            "--YY",
            "Content-Type: text/plain; charset=iso-8859-1",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            "Gr=FC=DFe",
            "--YY",
            "Content-Type: text/html; charset=utf-8",
            "",
            "<p>Grüße <img src=\"cid:img1\"></p>",
            "--YY--",
            "--XX",
            "Content-Type: image/png; name=\"bild.png\"",
            "Content-ID: <img1>",
            "Content-Transfer-Encoding: base64",
            "",
            "AAEC",
            "AwQ=",
            "--XX--",
            "epilogue",
        ].joined(separator: "\r\n")
        let part = MIMEPart(data: Data(raw.utf8))
        XCTAssertEqual(part.decodedHeader("Subject"), "Hallö")
        XCTAssertEqual(part.parts.count, 2)
        XCTAssertEqual(part.parts[0].parts.count, 2)
        let content = MessageContent(part: part)
        XCTAssertEqual(content.plain, "Grüße")
        XCTAssertEqual(content.attachments.count, 1)
        XCTAssertEqual(content.attachments[0].filename, "bild.png")
        XCTAssertEqual(content.attachments[0].data, Data([0, 1, 2, 3, 4]))
        XCTAssertTrue(content.htmlWithInlineImages?.contains("data:image/png;base64,AAECAwQ=") == true)
    }

    func testIMAPParsing() {
        let literal = "From: a@b.c\r\nSubject: Hi (there)\r\n\r\n"
        let raw = "* 12 FETCH (UID 99 FLAGS (\\Seen \\Flagged) INTERNALDATE \"17-Jul-1996 02:44:25 -0700\" RFC822.SIZE 4286 BODY[HEADER.FIELDS (FROM SUBJECT)] {\(literal.utf8.count)}\r\n\(literal))\r\n"
        guard case .fetch(let seq, let items) = IMAPResponse.parse(Data(raw.utf8)) else { return XCTFail("no fetch") }
        XCTAssertEqual(seq, 12)
        XCTAssertEqual(items["UID"]?.number, 99)
        XCTAssertEqual(items["FLAGS"]?.items.compactMap(\.text), ["\\Seen", "\\Flagged"])
        XCTAssertEqual(items["BODY[]"]?.text, literal)
        let headers = IMAPClient.headers(from: [IMAPResponse.parse(Data(raw.utf8))])
        XCTAssertEqual(headers.first?.subject, "Hi (there)")
        XCTAssertEqual(headers.first?.from.first?.email, "a@b.c")
        XCTAssertTrue(headers.first?.isSeen == true)

        guard case .list(let flags, let delimiter, let path) =
            IMAPResponse.parse(Data("* LIST (\\HasNoChildren \\Sent) \"/\" \"Gesendete &AMQ-pfel\"\r\n".utf8)) else { return XCTFail("no list") }
        XCTAssertEqual(flags, ["\\HasNoChildren", "\\Sent"])
        XCTAssertEqual(delimiter, "/")
        XCTAssertEqual(ModifiedUTF7.decode(path), "Gesendete Äpfel")

        guard case .condition(_, let code, let argument, _) =
            IMAPResponse.parse(Data("* OK [UIDVALIDITY 3857529045] UIDs valid\r\n".utf8)) else { return XCTFail("no cond") }
        XCTAssertEqual(code, "UIDVALIDITY")
        XCTAssertEqual(argument, "3857529045")

        guard case .search(let uids) = IMAPResponse.parse(Data("* SEARCH 2 84 882\r\n".utf8)) else { return XCTFail("no search") }
        XCTAssertEqual(uids, [2, 84, 882])
        guard case .status(_, let counts) =
            IMAPResponse.parse(Data("* STATUS \"INBOX\" (MESSAGES 231 UNSEEN 4)\r\n".utf8)) else { return XCTFail("no status") }
        XCTAssertEqual(counts["UNSEEN"], 4)
        XCTAssertEqual(IMAPClient.trailingLiteralSize(Data("* 1 FETCH (BODY[] {342}\r\n".utf8)), 342)
        XCTAssertNil(IMAPClient.trailingLiteralSize(Data("* OK done\r\n".utf8)))
    }

    func testDotStuffing() {
        let out = SMTPClient.dotStuffed(Data("a\r\n.b\n..c".utf8))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "a\r\n..b\r\n...c\r\n")
    }

    func testAutoconfigParsing() {
        let xml = """
        <clientConfig version="1.1"><emailProvider id="example.org"><displayName>Example</displayName>
        <incomingServer type="pop3"><hostname>pop.example.org</hostname><port>995</port><socketType>SSL</socketType><username>%EMAILADDRESS%</username><authentication>password-cleartext</authentication></incomingServer>
        <incomingServer type="imap"><hostname>imap.example.org</hostname><port>143</port><socketType>STARTTLS</socketType><username>%EMAILLOCALPART%</username><authentication>password-cleartext</authentication></incomingServer>
        <incomingServer type="imap"><hostname>imap.example.org</hostname><port>993</port><socketType>SSL</socketType><username>%EMAILADDRESS%</username><authentication>password-cleartext</authentication></incomingServer>
        <outgoingServer type="smtp"><hostname>smtp.example.org</hostname><port>587</port><socketType>STARTTLS</socketType><username>%EMAILADDRESS%</username><authentication>password-cleartext</authentication></outgoingServer>
        </emailProvider></clientConfig>
        """
        let result = Autoconfig.parse(Data(xml.utf8), email: "me@example.org")
        XCTAssertEqual(result?.imap, ServerConfig(host: "imap.example.org", port: 993, security: .tls, username: "me@example.org"))
        XCTAssertEqual(result?.smtp, ServerConfig(host: "smtp.example.org", port: 587, security: .startTLS, username: "me@example.org"))
    }
}
