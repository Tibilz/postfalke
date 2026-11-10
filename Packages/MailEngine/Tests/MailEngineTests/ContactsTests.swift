import XCTest
@testable import MailEngine

final class ContactsTests: XCTestCase {

    func testVCardParsing() throws {
        let key = try PGP.generateKey(userID: "Carla <carla@example.org>", passphrase: "")
        let binary = try XCTUnwrap(PGP.dearmor(key.publicArmored))
        let folded = binary.base64EncodedString().enumerated()
            .map { $0.offset > 0 && $0.offset % 60 == 0 ? "\r\n \($0.element)" : String($0.element) }.joined()
        let armoredEscaped = key.publicArmored.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\\n")

        let text = """
        BEGIN:VCARD\r
        VERSION:3.0\r
        FN:Carla M\\, Beispiel\r
        item1.EMAIL;TYPE=INTERNET:Carla@Example.org\r
        EMAIL:c2@example.org\r
        KEY;TYPE=PGP;ENCODING=b:\(folded)\r
        END:VCARD\r
        BEGIN:VCARD\r
        VERSION:4.0\r
        FN:Dora\r
        EMAIL:dora@example.org\r
        KEY:data:application/pgp-keys;base64,\(binary.base64EncodedString())\r
        KEY;MEDIATYPE=application/pgp-keys:https://keys.example.org/dora.asc\r
        KEY:\(armoredEscaped)\r
        END:VCARD\r
        BEGIN:VCARD\r
        FN:Ohne Schlüssel\r
        EMAIL:x@example.org\r
        END:VCARD\r

        """
        let cards = VCardParser.parse(text)
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards[0].name, "Carla M, Beispiel")
        XCTAssertEqual(cards[0].emails, ["carla@example.org", "c2@example.org"])
        XCTAssertEqual(cards[0].keys, [.data(binary)])
        XCTAssertEqual(cards[1].keys.count, 3)
        XCTAssertEqual(cards[1].keys[1], .url(URL(string: "https://keys.example.org/dora.asc")!))
        XCTAssertTrue(cards[2].keys.isEmpty)

        for case .data(let data) in cards[0].keys + cards[1].keys {
            XCTAssertEqual(try PGP.inspect(data).first?.fingerprint, key.fingerprint)
        }
    }

    func testProtectedSubject() throws {
        let key = try PGP.generateKey(userID: "A <a@example.org>", passphrase: "")
        let secret = PGPSecret(armored: key.armored, passphrase: "")
        var message = OutgoingMessage(from: MailAddress(name: "A", email: "a@example.org"))
        message.to = [MailAddress(email: "a@example.org")]
        message.subject = "Übergabe am Bahnhof"
        message.body = "Text"
        message.attachments = [MailAttachment(filename: "a.txt", mimeType: "text/plain", data: Data("x".utf8))]
        let raw = try MIMEBuilder.build(message, pgp: PGPSendOptions(
            sign: true, encrypt: true, signer: secret, recipientKeys: [key.publicArmored], protectSubject: true))

        let outer = MIMEPart(data: raw)
        XCTAssertEqual(outer.header("Subject"), "...")
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("Bahnhof"))

        let processed = MessageProcessor.process(raw: raw, context: PGPContext(secrets: [secret], verifiers: [key.publicArmored]))
        XCTAssertEqual(processed.protectedSubject, "Übergabe am Bahnhof")
        XCTAssertEqual(processed.content.plain, "Text\r\n")
        XCTAssertEqual(processed.content.attachments.map(\.filename), ["a.txt"])
        XCTAssertEqual(processed.security.signature, .valid(fingerprint: key.fingerprint))

        // Without the option the subject stays where it was.
        let open = try MIMEBuilder.build(message, pgp: PGPSendOptions(
            sign: false, encrypt: true, signer: nil, recipientKeys: [key.publicArmored]))
        XCTAssertEqual(MIMEPart(data: open).decodedHeader("Subject"), "Übergabe am Bahnhof")
    }

    /// Needs Tools/fakemail.py with a CardDAV port: MAIL_TEST_DAV_PORT.
    func testCardDAVDiscoveryAndKeys() async throws {
        guard let port = ProcessInfo.processInfo.environment["MAIL_TEST_DAV_PORT"].flatMap({ Int($0) }) else {
            throw XCTSkip("no local CardDAV server configured")
        }
        let password = ProcessInfo.processInfo.environment["MAIL_TEST_PASSWORD"] ?? "p\"äss wort"
        let key = try PGP.generateKey(userID: "Carla <alt@example.org>", passphrase: "")
        let card = "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Carla\r\nEMAIL:carla@example.org\r\nKEY:data:application/pgp-keys;base64,\(PGP.dearmor(key.publicArmored)!.base64EncodedString())\r\nEND:VCARD\r\n"
        for (name, body) in [("carla.vcf", card), ("leer.vcf", "BEGIN:VCARD\r\nFN:Leer & <Co>\r\nEMAIL:leer@example.org\r\nEND:VCARD\r\n")] {
            var put = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/dav/addressbooks/tester/contacts/\(name)")!)
            put.httpMethod = "PUT"
            put.httpBody = Data(body.utf8)
            put.setValue("Basic " + Data("tester@example.org:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: put)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
        }

        // Every sensible starting point leads to the same address book.
        for start in ["", "/dav/", "/dav/principals/tester/", "/dav/addressbooks/tester/", "/dav/addressbooks/tester/contacts/"] {
            let client = CardDAVClient(baseURL: URL(string: "http://127.0.0.1:\(port)\(start)")!,
                                       username: "tester@example.org", password: password)
            let contacts = try await client.fetchContacts().sorted { ($0.name ?? "") < ($1.name ?? "") }
            XCTAssertEqual(contacts.map(\.name), ["Carla", "Leer & <Co>"], "start: \(start)")
            guard case .data(let data)? = contacts[0].keys.first else { return XCTFail("no key, start: \(start)") }
            XCTAssertEqual(try PGP.inspect(data).first?.fingerprint, key.fingerprint)
        }

        let wrong = CardDAVClient(baseURL: URL(string: "http://127.0.0.1:\(port)/dav/")!, username: "tester@example.org", password: "x")
        do { _ = try await wrong.fetchContacts(); XCTFail("should fail") } catch MailError.authentication {}
    }
}
