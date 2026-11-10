import XCTest
@testable import MailEngine

/// Self-signed certificates. Needs Tools/fakemail.py running with
/// FAKEMAIL_TLS_CERT/KEY and the variables below (see README).
final class TLSTests: XCTestCase {
    struct Setup {
        var imap: Int, smtp: Int, dav: Int
        var fingerprint: String
        var password: String
    }

    func setup() throws -> Setup {
        let env = ProcessInfo.processInfo.environment
        guard let imap = env["MAIL_TEST_TLS_IMAP_PORT"].flatMap({ Int($0) }),
              let smtp = env["MAIL_TEST_TLS_SMTP_PORT"].flatMap({ Int($0) }),
              let dav = env["MAIL_TEST_TLS_DAV_PORT"].flatMap({ Int($0) }),
              let fingerprint = env["MAIL_TEST_TLS_FINGERPRINT"] else {
            throw XCTSkip("no TLS test server configured")
        }
        return Setup(imap: imap, smtp: smtp, dav: dav,
                     fingerprint: fingerprint.replacingOccurrences(of: ":", with: "").uppercased(),
                     password: env["MAIL_TEST_PASSWORD"] ?? "p\"äss wort")
    }

    /// Runs `operation` and returns the certificate it was refused for.
    func rejection(_ operation: () async throws -> Void) async -> CertificateInfo? {
        do {
            try await operation()
            return nil
        } catch MailError.untrustedCertificate(let info) {
            return info
        } catch {
            XCTFail("unexpected error: \(error)")
            return nil
        }
    }

    func testCardDAV() async throws {
        let s = try setup()
        let url = URL(string: "https://127.0.0.1:\(s.dav)/dav/")!

        let refused = await rejection {
            _ = try await CardDAVClient(baseURL: url, username: "tester@example.org", password: s.password).fetchContacts()
        }
        XCTAssertEqual(refused?.sha256, s.fingerprint)
        XCTAssertEqual(refused?.subject, "nextcloud.local")
        XCTAssertEqual(refused?.port, s.dav)

        let wrongPin = await rejection {
            _ = try await CardDAVClient(baseURL: url, username: "tester@example.org", password: s.password,
                                        trustedCertificate: String(repeating: "0", count: 64)).fetchContacts()
        }
        XCTAssertEqual(wrongPin?.sha256, s.fingerprint)

        let pinned = CardDAVClient(baseURL: url, username: "tester@example.org", password: s.password,
                                   trustedCertificate: s.fingerprint.lowercased())
        _ = try await pinned.fetchContacts()
    }

    func testIMAPAndSMTP() async throws {
        let s = try setup()
        var imap = ServerConfig(host: "127.0.0.1", port: s.imap, security: .tls, username: "tester@example.org")
        var smtp = ServerConfig(host: "127.0.0.1", port: s.smtp, security: .tls, username: "tester@example.org")

        let imapRefused = await rejection { try await IMAPClient(config: imap, password: s.password).connect() }
        XCTAssertEqual(imapRefused?.sha256, s.fingerprint)
        let smtpRefused = await rejection { try await SMTPClient(config: smtp, password: s.password).verify() }
        XCTAssertEqual(smtpRefused?.sha256, s.fingerprint)

        imap.trustedCertificate = s.fingerprint
        smtp.trustedCertificate = s.fingerprint
        let client = IMAPClient(config: imap, password: s.password)
        try await client.connect()
        let folders = try await client.listFolders()
        XCTAssertFalse(folders.isEmpty)
        await client.logout()
        try await SMTPClient(config: smtp, password: s.password).verify()
    }

    /// Old saved accounts have no `trustedCertificate` key and must still load.
    func testOldSettingsDecode() throws {
        let json = #"{"host":"h","port":993,"security":"tls","username":"u"}"#
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))
        XCTAssertNil(config.trustedCertificate)
    }
}
