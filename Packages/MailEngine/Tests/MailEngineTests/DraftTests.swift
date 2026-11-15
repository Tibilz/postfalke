import XCTest
@testable import MailEngine

final class DraftTests: XCTestCase {

    func testAttachmentsAreCodable() throws {
        let original = MailAttachment(filename: "ä.pdf", mimeType: "application/pdf", data: Data([1, 2, 3]), contentID: "c1")
        let copy = try JSONDecoder().decode(MailAttachment.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(copy, original)
    }

    /// A draft encrypted to the own key keeps subject and options readable after decryption.
    func testEncryptedDraftRoundTrip() throws {
        let key = try PGP.generateKey(userID: "A <a@example.org>", passphrase: "")
        var message = OutgoingMessage(from: MailAddress(name: "A", email: "a@example.org"))
        message.to = [MailAddress(email: "b@example.org")]
        message.subject = "Geheimer Entwurf"
        message.body = "noch nicht fertig"
        message.extraHeaders = ["Bcc": "c@example.org", "X-Postfalke-Draft": "sign=1; encrypt=1"]
        let raw = try MIMEBuilder.build(message, pgp: PGPSendOptions(
            sign: false, encrypt: true, signer: nil, recipientKeys: [key.publicArmored], protectSubject: true))

        let outer = MIMEPart(data: raw)
        XCTAssertEqual(outer.header("Subject"), "...")
        XCTAssertEqual(outer.header("Bcc"), "c@example.org")
        XCTAssertEqual(outer.header("X-Postfalke-Draft"), "sign=1; encrypt=1")
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("noch nicht fertig"))

        let processed = MessageProcessor.process(raw: raw, context: PGPContext(
            secrets: [PGPSecret(armored: key.armored, passphrase: "")]))
        XCTAssertEqual(processed.protectedSubject, "Geheimer Entwurf")
        XCTAssertEqual(processed.content.plain, "noch nicht fertig\r\n")
    }

    func testExtraHeadersCannotInjectLines() throws {
        var message = OutgoingMessage(from: MailAddress(email: "a@example.org"))
        message.extraHeaders = ["X-Test": "eins\r\nBcc: boese@example.org"]
        let raw = String(decoding: try MIMEBuilder.build(message), as: UTF8.self)
        XCTAssertFalse(raw.contains("\r\nBcc: boese@example.org"))
    }
}
