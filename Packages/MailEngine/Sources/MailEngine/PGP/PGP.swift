import Foundation
import PGPCoreFFI

public struct PGPKeyInfo: Codable, Hashable, Identifiable, Sendable {
    public var fingerprint: String
    public var keyID: String
    public var userIDs: [String]
    public var isSecret: Bool
    public var created: Date
    public var expires: Date?
    public var algorithm: String
    public var canEncrypt: Bool
    public var revoked: Bool
    /// ASCII-armored public key (certificate).
    public var publicArmored: String
    /// ASCII-armored secret key when `isSecret`, otherwise the public key.
    public var armored: String

    public var id: String { fingerprint }
    public var isExpired: Bool { expires.map { $0 < Date() } ?? false }
    public var isUsable: Bool { !revoked && !isExpired }

    /// Lowercased e-mail addresses from the user IDs.
    public var emails: [String] {
        userIDs.flatMap { HeaderCodec.parseAddressList($0).map { $0.email.lowercased() } }
    }

    public var primaryUserID: String { userIDs.first ?? "(ohne Benutzer-ID)" }

    /// Fingerprint in groups of four for display.
    public var formattedFingerprint: String {
        stride(from: 0, to: fingerprint.count, by: 4).map { offset -> String in
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: offset)
            let end = fingerprint.index(start, offsetBy: 4, limitedBy: fingerprint.endIndex) ?? fingerprint.endIndex
            return String(fingerprint[start..<end])
        }.joined(separator: " ")
    }

    fileprivate init?(json: [String: Any]) {
        guard let fingerprint = json["fingerprint"] as? String,
              let publicArmored = json["public_armored"] as? String else { return nil }
        self.fingerprint = fingerprint
        keyID = json["key_id"] as? String ?? ""
        userIDs = json["user_ids"] as? [String] ?? []
        isSecret = json["is_secret"] as? Bool ?? false
        created = Date(timeIntervalSince1970: (json["created"] as? NSNumber)?.doubleValue ?? 0)
        expires = (json["expires"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        algorithm = json["algorithm"] as? String ?? ""
        canEncrypt = json["can_encrypt"] as? Bool ?? false
        revoked = json["revoked"] as? Bool ?? false
        self.publicArmored = publicArmored
        armored = json["armored"] as? String ?? publicArmored
    }
}

/// A secret key together with the passphrase that unlocks it.
public struct PGPSecret: Sendable {
    public var armored: String
    public var passphrase: String

    public init(armored: String, passphrase: String) {
        self.armored = armored
        self.passphrase = passphrase
    }

    fileprivate var json: [String: Any] { ["secret": armored, "passphrase": passphrase] }
}

public struct PGPSignatureInfo: Sendable, Equatable {
    public enum Status: String, Sendable { case valid, invalid, unknownKey = "unknown_key" }
    public var status: Status
    public var keyID: String
    public var signerFingerprint: String?

    fileprivate init?(json: [String: Any]) {
        guard let raw = json["status"] as? String, let status = Status(rawValue: raw) else { return nil }
        self.status = status
        keyID = json["key_id"] as? String ?? ""
        signerFingerprint = json["signer_fingerprint"] as? String
    }
}

/// Swift face of the Rust `pgpcore` library (rPGP).
public enum PGP {

    private static func call(_ request: [String: Any]) throws -> [String: Any] {
        let payload = try JSONSerialization.data(withJSONObject: request)
        let text = String(decoding: payload, as: UTF8.self)
        guard let pointer = text.withCString({ pgpcore_call($0) }) else {
            throw MailError.pgp("Keine Antwort der Kryptobibliothek.")
        }
        defer { pgpcore_free(pointer) }
        let response = Data(bytes: pointer, count: strlen(pointer))
        guard let json = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw MailError.pgp("Ungültige Antwort der Kryptobibliothek.")
        }
        guard json["ok"] as? Bool == true else {
            throw MailError.pgp(json["error"] as? String ?? "Unbekannter Fehler")
        }
        return json
    }

    private static func signatures(_ json: [String: Any]) -> [PGPSignatureInfo] {
        (json["signatures"] as? [[String: Any]] ?? []).compactMap(PGPSignatureInfo.init(json:))
    }

    /// Creates an Ed25519 key with a Curve25519 encryption subkey.
    public static func generateKey(userID: String, passphrase: String) throws -> PGPKeyInfo {
        let json = try call(["op": "generate", "user_id": userID, "passphrase": passphrase])
        guard let key = (json["key"] as? [String: Any]).flatMap(PGPKeyInfo.init(json:)) else {
            throw MailError.pgp("Schlüssel konnte nicht erzeugt werden.")
        }
        return key
    }

    private static let armorBlock = try! NSRegularExpression(
        pattern: #"-----BEGIN PGP (PUBLIC|PRIVATE) KEY BLOCK-----[\s\S]*?-----END PGP \1 KEY BLOCK-----"#)

    /// Reads all keys from armored text (possibly several blocks) or binary key data.
    public static func inspect(_ data: Data) throws -> [PGPKeyInfo] {
        var chunks: [Data] = []
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN PGP") {
            let ns = text as NSString
            for match in armorBlock.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                chunks.append(Data(ns.substring(with: match.range).utf8))
            }
        }
        if chunks.isEmpty { chunks = [data] }

        var byFingerprint: [String: PGPKeyInfo] = [:]
        var order: [String] = []
        var lastError: Error?
        for chunk in chunks {
            do {
                let json = try call(["op": "inspect", "data": chunk.base64EncodedString()])
                for key in (json["keys"] as? [[String: Any]] ?? []).compactMap(PGPKeyInfo.init(json:)) {
                    if byFingerprint[key.fingerprint] == nil { order.append(key.fingerprint) }
                    if byFingerprint[key.fingerprint]?.isSecret != true { byFingerprint[key.fingerprint] = key }
                }
            } catch {
                lastError = error
            }
        }
        if order.isEmpty { throw lastError ?? MailError.pgp("Kein OpenPGP-Schlüssel gefunden.") }
        return order.compactMap { byFingerprint[$0] }
    }

    public static func checkPassphrase(secretArmored: String, passphrase: String) -> Bool {
        let json = try? call(["op": "check_passphrase", "secret": secretArmored, "passphrase": passphrase])
        return json?["valid"] as? Bool ?? false
    }

    /// Encrypts (and optionally signs) to all recipient certificates. Returns an armored message.
    public static func encrypt(_ data: Data, recipients: [String], signer: PGPSecret?) throws -> String {
        var request: [String: Any] = [
            "op": "encrypt",
            "data": data.base64EncodedString(),
            "recipients": recipients,
        ]
        if let signer { request["signer"] = signer.json }
        guard let armored = try call(request)["armored"] as? String else {
            throw MailError.pgp("Verschlüsselung fehlgeschlagen.")
        }
        return armored
    }

    public struct Decrypted: Sendable {
        public var data: Data
        public var wasEncrypted: Bool
        public var signatures: [PGPSignatureInfo]
    }

    public static func decrypt(_ data: Data, secrets: [PGPSecret], verifiers: [String]) throws -> Decrypted {
        let json = try call([
            "op": "decrypt",
            "data": data.base64EncodedString(),
            "secrets": secrets.map(\.json),
            "verifiers": verifiers,
        ])
        guard let plain = (json["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            throw MailError.pgp("Entschlüsselung fehlgeschlagen.")
        }
        return Decrypted(data: plain,
                         wasEncrypted: json["was_encrypted"] as? Bool ?? false,
                         signatures: signatures(json))
    }

    /// Detached, armored signature over `data` (SHA-256).
    public static func signDetached(_ data: Data, signer: PGPSecret) throws -> String {
        let json = try call(["op": "sign_detached", "data": data.base64EncodedString(), "signer": signer.json])
        guard let armored = json["armored"] as? String else { throw MailError.pgp("Signieren fehlgeschlagen.") }
        return armored
    }

    public static func verifyDetached(_ data: Data, signature: Data, verifiers: [String]) throws -> [PGPSignatureInfo] {
        signatures(try call([
            "op": "verify_detached",
            "data": data.base64EncodedString(),
            "signature": signature.base64EncodedString(),
            "verifiers": verifiers,
        ]))
    }

    public static func verifyCleartext(_ text: String, verifiers: [String]) throws -> (text: String, signatures: [PGPSignatureInfo]) {
        let json = try call(["op": "verify_cleartext", "text": text, "verifiers": verifiers])
        return (json["text"] as? String ?? "", signatures(json))
    }

    /// Strips the ASCII armor from a key block and returns the binary packets.
    public static func dearmor(_ armored: String) -> Data? {
        var payload = ""
        var inBody = false
        var sawBegin = false
        for rawLine in armored.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("-----BEGIN") { sawBegin = true; continue }
            if line.hasPrefix("-----END") { break }
            guard sawBegin else { continue }
            if !inBody {
                if line.isEmpty { inBody = true }          // end of armor headers
                else if !line.contains(":") { inBody = true; payload += line }
                continue
            }
            if line.hasPrefix("=") { continue }            // CRC-24
            payload += line
        }
        return Data(base64Encoded: payload)
    }
}
