import XCTest
@testable import MailEngine

final class PGPTests: XCTestCase {
    static let alice = try! PGP.generateKey(userID: "Alice Ä <alice@example.org>", passphrase: "geheim")
    static let bob = try! PGP.generateKey(userID: "Bob <bob@example.org>", passphrase: "")

    var alice: PGPKeyInfo { Self.alice }
    var bob: PGPKeyInfo { Self.bob }

    func message() -> OutgoingMessage {
        var m = OutgoingMessage(from: MailAddress(name: "Alice Ä", email: "alice@example.org"))
        m.to = [MailAddress(name: "Bob", email: "bob@example.org")]
        m.subject = "Geheime Grüße"
        m.body = "Hallo Bob,\n\ndas ist geheim. äöüß €\n-- \nAlice\n"
        m.attachments = [MailAttachment(filename: "Plän.txt", mimeType: "text/plain", data: Data("Anhang".utf8))]
        m.autocryptKey = alice.publicArmored
        return m
    }

    func testKeyInfo() throws {
        XCTAssertTrue(alice.isSecret)
        XCTAssertTrue(alice.canEncrypt)
        XCTAssertEqual(alice.emails, ["alice@example.org"])
        XCTAssertEqual(alice.fingerprint.count, 40)
        XCTAssertTrue(PGP.checkPassphrase(secretArmored: alice.armored, passphrase: "geheim"))
        XCTAssertFalse(PGP.checkPassphrase(secretArmored: alice.armored, passphrase: "x"))

        let both = alice.publicArmored + "\n\n" + bob.armored
        let keys = try PGP.inspect(Data(both.utf8))
        XCTAssertEqual(keys.map(\.fingerprint), [alice.fingerprint, bob.fingerprint])
        XCTAssertEqual(keys.map(\.isSecret), [false, true])
        XCTAssertThrowsError(try PGP.inspect(Data("kein Schlüssel".utf8)))

        let binary = try XCTUnwrap(PGP.dearmor(alice.publicArmored))
        XCTAssertEqual(try PGP.inspect(binary).first?.fingerprint, alice.fingerprint)
    }

    func testEncryptedAndSignedMail() throws {
        let options = PGPSendOptions(sign: true, encrypt: true,
                                     signer: PGPSecret(armored: alice.armored, passphrase: "geheim"),
                                     recipientKeys: [bob.publicArmored, alice.publicArmored])
        let raw = try MIMEBuilder.build(message(), pgp: options)
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertTrue(text.contains("multipart/encrypted"))
        XCTAssertFalse(text.contains("das ist geheim"))
        XCTAssertFalse(text.contains("Anhang"))

        // Bob reads it and knows Alice's key.
        let context = PGPContext(secrets: [PGPSecret(armored: bob.armored, passphrase: "")], verifiers: [alice.publicArmored])
        let processed = MessageProcessor.process(raw: raw, context: context)
        XCTAssertNil(processed.security.decryptionError)
        XCTAssertTrue(processed.security.wasEncrypted)
        XCTAssertEqual(processed.security.signature, .valid(fingerprint: alice.fingerprint))
        XCTAssertEqual(processed.content.plain, "Hallo Bob,\r\n\r\ndas ist geheim. äöüß €\r\n-- \r\nAlice\r\n")
        XCTAssertEqual(processed.content.attachments.map(\.filename), ["Plän.txt"])
        XCTAssertEqual(processed.content.attachments.first?.data, Data("Anhang".utf8))
        XCTAssertEqual(processed.root.decodedHeader("Subject"), "Geheime Grüße")

        // The Autocrypt header carries Alice's key.
        let autocrypt = try XCTUnwrap(processed.autocryptKey)
        XCTAssertEqual(try PGP.inspect(autocrypt).first?.fingerprint, alice.fingerprint)

        // Alice can read her own sent copy.
        let own = MessageProcessor.process(raw: raw, context: PGPContext(
            secrets: [PGPSecret(armored: alice.armored, passphrase: "geheim")], verifiers: [alice.publicArmored]))
        XCTAssertEqual(own.security.signature, .valid(fingerprint: alice.fingerprint))

        // Without a matching key there is an error instead of content.
        let stranger = MessageProcessor.process(raw: raw, context: PGPContext())
        XCTAssertNotNil(stranger.security.decryptionError)
        XCTAssertNil(stranger.content.plain.flatMap { $0.isEmpty ? nil : $0 })
    }

    func testSignedMail() throws {
        let options = PGPSendOptions(sign: true, encrypt: false,
                                     signer: PGPSecret(armored: alice.armored, passphrase: "geheim"), recipientKeys: [])
        let raw = try MIMEBuilder.build(message(), pgp: options)
        XCTAssertTrue(String(decoding: raw, as: UTF8.self).contains("multipart/signed"))

        let known = MessageProcessor.process(raw: raw, context: PGPContext(verifiers: [alice.publicArmored]))
        XCTAssertEqual(known.security.signature, .valid(fingerprint: alice.fingerprint))
        XCTAssertFalse(known.security.wasEncrypted)
        XCTAssertTrue(known.content.plain?.contains("das ist geheim") == true)
        XCTAssertEqual(known.content.attachments.count, 1)

        let unknown = MessageProcessor.process(raw: raw, context: PGPContext(verifiers: [bob.publicArmored]))
        if case .unknownKey = unknown.security.signature {} else { XCTFail("\(unknown.security.signature)") }

        // Tampering with the signed part must be detected.
        var tampered = String(decoding: raw, as: UTF8.self)
        tampered = tampered.replacingOccurrences(of: "Hallo Bob", with: "Hallo Rob")
        let bad = MessageProcessor.process(raw: Data(tampered.utf8), context: PGPContext(verifiers: [alice.publicArmored]))
        XCTAssertEqual(bad.security.signature, .invalid)

        // A wrong passphrase must not produce a message.
        let wrong = PGPSendOptions(sign: true, encrypt: false,
                                   signer: PGPSecret(armored: alice.armored, passphrase: "falsch"), recipientKeys: [])
        XCTAssertThrowsError(try MIMEBuilder.build(message(), pgp: wrong))
    }

    func testInlinePGP() throws {
        let armored = try PGP.encrypt(Data("Inline geheim ä".utf8), recipients: [bob.publicArmored], signer: nil)
        let raw = "From: a@example.org\r\nContent-Type: text/plain\r\n\r\nVorher\r\n\(armored)\r\nNachher\r\n"
        let processed = MessageProcessor.process(raw: Data(raw.utf8), context: PGPContext(
            secrets: [PGPSecret(armored: bob.armored, passphrase: "")]))
        XCTAssertTrue(processed.security.wasEncrypted)
        XCTAssertTrue(processed.content.plain?.contains("Inline geheim ä") == true)
        XCTAssertTrue(processed.content.plain?.contains("Vorher") == true)
    }

    func testPlainMailRoundTrip() throws {
        let raw = try MIMEBuilder.build(message())
        let processed = MessageProcessor.process(raw: raw, context: PGPContext())
        XCTAssertEqual(processed.security, MessageSecurity())
        XCTAssertEqual(processed.content.attachments.first?.filename, "Plän.txt")
        XCTAssertEqual(HeaderCodec.parseAddressList(processed.root.header("From")).first?.name, "Alice Ä")
    }
}
