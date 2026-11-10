import XCTest
@testable import MailEngine

/// End-to-end tests against a local test server. Skipped unless
/// MAIL_TEST_IMAP_PORT / MAIL_TEST_SMTP_PORT are set (see README).
final class IntegrationTests: XCTestCase {
    let user = "tester@example.org"
    let password = "p\"äss wort"

    func ports() throws -> (imap: Int, smtp: Int) {
        let env = ProcessInfo.processInfo.environment
        guard let imap = env["MAIL_TEST_IMAP_PORT"].flatMap({ Int($0) }),
              let smtp = env["MAIL_TEST_SMTP_PORT"].flatMap({ Int($0) }) else {
            throw XCTSkip("no local test server configured")
        }
        return (imap, smtp)
    }

    func testFullRoundTrip() async throws {
        let ports = try ports()
        let imapConfig = ServerConfig(host: "127.0.0.1", port: ports.imap, security: .none, username: user)
        let smtpConfig = ServerConfig(host: "127.0.0.1", port: ports.smtp, security: .none, username: user)

        // Wrong password is reported as an authentication problem.
        do {
            try await IMAPClient(config: imapConfig, password: "falsch").connect()
            XCTFail("login should fail")
        } catch MailError.authentication {}

        let imap = IMAPClient(config: imapConfig, password: password)
        try await imap.connect()
        let hasMove = await imap.capabilities.contains("MOVE")
        XCTAssertTrue(hasMove)

        let folders = try await imap.listFolders()
        XCTAssertEqual(folders.map(\.role), [.inbox, .drafts, .sent, .trash])
        XCTAssertEqual(folders[1].name, "Entwürfe")

        let status = try await imap.select("INBOX")
        XCTAssertEqual(status.uidValidity, 42)
        XCTAssertGreaterThanOrEqual(status.exists, 3)
        let headers = try await imap.fetchHeaders(sequence: 1...3)
        XCTAssertEqual(headers.map(\.uid), [1, 2, 3])
        XCTAssertEqual(headers[0].subject, "Testnachricht 1 (mit Klammer)")
        XCTAssertEqual(headers[0].from.first?.name, "Jürgen")
        XCTAssertFalse(headers[0].isSeen)

        let raw = try await imap.fetchMessage(uid: 2)
        let plain = MessageProcessor.process(raw: raw, context: PGPContext())
        XCTAssertEqual(plain.content.plain, "Inhalt 2 äöü\r\n")

        try await imap.setFlag("\\Seen", on: [1], enabled: true)
        let counts = try await imap.folderCounts("INBOX")
        XCTAssertEqual(counts.unread, counts.total - 1)

        // Send an encrypted + signed mail through SMTP, it lands in the INBOX.
        let key = try PGP.generateKey(userID: "Tester <\(user)>", passphrase: "pw")
        let secret = PGPSecret(armored: key.armored, passphrase: "pw")
        var message = OutgoingMessage(from: MailAddress(name: "Tester", email: user))
        message.to = [MailAddress(email: user)]
        message.subject = "Verschlüsselt über SMTP"
        message.body = "Zeile eins\n.Zeile mit Punkt am Anfang\nEnde"
        message.attachments = [MailAttachment(filename: "daten.bin", mimeType: "application/octet-stream",
                                              data: Data((0..<5000).map { UInt8($0 % 251) }))]
        let data = try MIMEBuilder.build(message, pgp: PGPSendOptions(
            sign: true, encrypt: true, signer: secret, recipientKeys: [key.publicArmored]))
        try await SMTPClient(config: smtpConfig, password: password).send(data, from: user, recipients: [user])
        try await imap.append(data, to: "Sent")

        try await imap.noop()
        let exists = await imap.status.exists
        let newest = try await imap.fetchHeaders(sequence: exists...exists)
        XCTAssertEqual(newest.first?.subject, "Verschlüsselt über SMTP")
        XCTAssertTrue(newest.first?.isEncrypted == true)
        let uid = try XCTUnwrap(newest.first?.uid)
        let received = try await imap.fetchMessage(uid: uid)
        let processed = MessageProcessor.process(raw: received, context: PGPContext(secrets: [secret], verifiers: [key.publicArmored]))
        XCTAssertNil(processed.security.decryptionError)
        XCTAssertEqual(processed.security.signature, .valid(fingerprint: key.fingerprint))
        XCTAssertEqual(processed.content.plain, "Zeile eins\r\n.Zeile mit Punkt am Anfang\r\nEnde\r\n")
        XCTAssertEqual(processed.content.attachments.first?.data.count, 5000)

        let found = try await imap.search("OpenPGP/MIME encrypted")
        XCTAssertEqual(found, [uid])

        // Move to trash, then delete for good.
        try await imap.move(uids: [uid], to: "Trash")
        try await imap.select("Trash")
        let trashed = try await imap.fetchHeaders(sequence: 1...1)
        XCTAssertEqual(trashed.count, 1)
        try await imap.expunge(uids: trashed.map(\.uid))
        try await imap.noop()
        let left = await imap.status.exists
        XCTAssertEqual(left, 0)

        try await imap.select("Sent")
        let sent = try await imap.fetchHeaders(sequence: 1...1)
        XCTAssertTrue(sent.first?.isSeen == true)
        await imap.logout()
    }

    /// TLS and STARTTLS against real servers; only the handshake matters, the login must fail.
    func testLiveTLS() async throws {
        guard ProcessInfo.processInfo.environment["MAIL_TEST_LIVE"] == "1" else { throw XCTSkip("live test disabled") }
        let imap = IMAPClient(config: ServerConfig(host: "imap.gmail.com", port: 993, security: .tls,
                                                   username: "nobody@invalid.example"), password: "invalid")
        do { try await imap.connect(); XCTFail("login should fail") } catch MailError.authentication {}

        let smtp = SMTPClient(config: ServerConfig(host: "smtp.gmail.com", port: 587, security: .startTLS,
                                                   username: "nobody@invalid.example"), password: "invalid")
        do { try await smtp.verify(); XCTFail("login should fail") } catch MailError.authentication {}

        let smtps = SMTPClient(config: ServerConfig(host: "smtp.gmail.com", port: 465, security: .tls,
                                                    username: "nobody@invalid.example"), password: "invalid")
        do { try await smtps.verify(); XCTFail("login should fail") } catch MailError.authentication {}
    }
}
