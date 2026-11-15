import XCTest
@testable import MailEngine

final class KeyManagementTests: XCTestCase {

    /// Example from the Web Key Directory specification.
    func testWKDHashMatchesSpecification() {
        XCTAssertEqual(KeyDiscovery.wkdHash(localPart: "Joe.Doe"), "iy9q119eutrkn8s1mk4r39qejnbu3n5q")
        let urls = KeyDiscovery.wkdURLs(for: "Joe.Doe@Example.ORG").map(\.absoluteString)
        XCTAssertEqual(urls, [
            "https://openpgpkey.example.org/.well-known/openpgpkey/example.org/hu/iy9q119eutrkn8s1mk4r39qejnbu3n5q?l=Joe.Doe",
            "https://example.org/.well-known/openpgpkey/hu/iy9q119eutrkn8s1mk4r39qejnbu3n5q?l=Joe.Doe",
        ])
        XCTAssertEqual(KeyDiscovery.keyServerURL(for: "a+b@example.org")?.absoluteString,
                       "https://keys.openpgp.org/vks/v1/by-email/a%2Bb%40example.org")
        XCTAssertTrue(KeyDiscovery.wkdURLs(for: "kein-at").isEmpty)
    }

    func testExpiryAndRevocationFromSwift() throws {
        let key = try PGP.generateKey(userID: "A <a@example.org>", passphrase: "pw")
        let secret = PGPSecret(armored: key.armored, passphrase: "pw")
        let target = Date().addingTimeInterval(30 * 24 * 3600)
        let renewed = try PGP.setExpiry(secret, expires: target)
        XCTAssertEqual(renewed.expires?.timeIntervalSince1970 ?? 0, target.timeIntervalSince1970, accuracy: 1.5)
        XCTAssertTrue(renewed.isUsable)
        XCTAssertNil(try PGP.setExpiry(PGPSecret(armored: renewed.armored, passphrase: "pw"), expires: nil).expires)
        XCTAssertThrowsError(try PGP.setExpiry(PGPSecret(armored: key.armored, passphrase: "falsch"), expires: target))

        let revoked = try PGP.revoke(secret, reason: .retired, text: "ersetzt")
        XCTAssertTrue(revoked.revoked)
        XCTAssertFalse(revoked.isUsable)
        XCTAssertTrue(try PGP.inspect(Data(revoked.publicArmored.utf8)).first?.revoked == true)
    }

    /// Real lookups on the internet; only with MAIL_TEST_LIVE=1.
    func testLiveLookupDoesNotReturnForeignKeys() async throws {
        guard ProcessInfo.processInfo.environment["MAIL_TEST_LIVE"] == "1" else { throw XCTSkip("live test disabled") }
        let none = await KeyDiscovery.lookup(email: "sicher-nicht-vorhanden-\(UUID().uuidString)@example.org")
        XCTAssertNil(none)
    }
}
