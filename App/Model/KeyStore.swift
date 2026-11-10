import Foundation
import Observation
import MailEngine

/// The OpenPGP key ring: own key pairs and the public keys of correspondents.
@MainActor
@Observable
final class KeyStore {
    private(set) var keys: [PGPKeyInfo] = []
    /// E-mail address → fingerprint, as assigned by the address book (CardDAV).
    /// Lets a contact use a key whose user ID carries a different address.
    private(set) var bindings: [String: String] = [:]

    private static let file = "keys.json"
    private static let bindingsFile = "key-bindings.json"
    private static func secretKey(_ fingerprint: String) -> String { "pgp-secret-\(fingerprint)" }
    private static func passphraseKey(_ fingerprint: String) -> String { "pgp-passphrase-\(fingerprint)" }

    init() {
        // The JSON file holds public data only; secret material comes from the keychain.
        var loaded = Storage.load([PGPKeyInfo].self, from: Self.file) ?? []
        for index in loaded.indices where loaded[index].isSecret {
            if let secret = Keychain.get(Self.secretKey(loaded[index].fingerprint)) {
                loaded[index].armored = secret
            } else {
                loaded[index].isSecret = false
                loaded[index].armored = loaded[index].publicArmored
            }
        }
        keys = loaded
        bindings = Storage.load([String: String].self, from: Self.bindingsFile) ?? [:]
    }

    /// Replaces the address book assignments (after a contact sync).
    func setBindings(_ new: [String: String]) {
        bindings = new
        Storage.save(new, to: Self.bindingsFile)
    }

    private func persist() {
        let publicOnly = keys.map { key -> PGPKeyInfo in
            var copy = key
            copy.armored = key.publicArmored
            return copy
        }
        Storage.save(publicOnly, to: Self.file)
    }

    var secretKeys: [PGPKeyInfo] { keys.filter(\.isSecret) }
    var publicOnlyKeys: [PGPKeyInfo] { keys.filter { !$0.isSecret } }

    func key(fingerprint: String?) -> PGPKeyInfo? {
        guard let fingerprint else { return nil }
        return keys.first { $0.fingerprint == fingerprint }
    }

    /// Usable encryption key for an address (own keys count too).
    func encryptionKey(for email: String) -> PGPKeyInfo? {
        let lower = email.lowercased()
        if let bound = key(fingerprint: bindings[lower]), bound.isUsable, bound.canEncrypt { return bound }
        return keys
            .filter { $0.isUsable && $0.canEncrypt && $0.emails.contains(lower) }
            .max { $0.created < $1.created }
    }

    func secret(for fingerprint: String?) -> PGPSecret? {
        guard let key = key(fingerprint: fingerprint), key.isSecret else { return nil }
        return PGPSecret(armored: key.armored, passphrase: Keychain.get(Self.passphraseKey(key.fingerprint)) ?? "")
    }

    /// Everything needed to decrypt and verify incoming mail.
    var context: PGPContext {
        PGPContext(secrets: secretKeys.compactMap { secret(for: $0.fingerprint) },
                   verifiers: keys.map(\.publicArmored))
    }

    /// Display name of the key owner for a verified signature.
    func ownerName(fingerprint: String) -> String {
        key(fingerprint: fingerprint)?.primaryUserID ?? fingerprint
    }

    @discardableResult
    func generate(name: String, email: String, passphrase: String) async throws -> PGPKeyInfo {
        let userID = name.isEmpty ? "<\(email)>" : "\(name) <\(email)>"
        let key = try await Task.detached(priority: .userInitiated) {
            try PGP.generateKey(userID: userID, passphrase: passphrase)
        }.value
        store(key, passphrase: passphrase)
        return key
    }

    enum ImportError: LocalizedError {
        case passphraseRequired(PGPKeyInfo)
        var errorDescription: String? {
            switch self {
            case .passphraseRequired(let key):
                return "Die Passphrase für den privaten Schlüssel von \(key.primaryUserID) ist falsch oder fehlt."
            }
        }
    }

    /// Imports every key found in `data`. Secret keys need their passphrase (empty if unprotected).
    /// `allowSecret` is false for keys taken from received mail.
    @discardableResult
    func importKeys(from data: Data, passphrase: String = "", allowSecret: Bool = true) throws -> [PGPKeyInfo] {
        var found = try PGP.inspect(data)
        if !allowSecret {
            found = found.map { key in
                var copy = key
                copy.isSecret = false
                copy.armored = key.publicArmored
                return copy
            }
        }
        for key in found where key.isSecret {
            guard PGP.checkPassphrase(secretArmored: key.armored, passphrase: passphrase) else {
                throw ImportError.passphraseRequired(key)
            }
        }
        for key in found {
            // Never replace an existing key pair by a bare public key.
            if !key.isSecret, self.key(fingerprint: key.fingerprint)?.isSecret == true { continue }
            store(key, passphrase: passphrase)
        }
        return found
    }

    private func store(_ key: PGPKeyInfo, passphrase: String) {
        if key.isSecret {
            Keychain.set(key.armored, for: Self.secretKey(key.fingerprint))
            Keychain.set(passphrase, for: Self.passphraseKey(key.fingerprint))
        }
        if let index = keys.firstIndex(where: { $0.fingerprint == key.fingerprint }) {
            keys[index] = key
        } else {
            keys.append(key)
        }
        persist()
    }

    func delete(_ key: PGPKeyInfo) {
        Keychain.delete(Self.secretKey(key.fingerprint))
        Keychain.delete(Self.passphraseKey(key.fingerprint))
        keys.removeAll { $0.fingerprint == key.fingerprint }
        persist()
        setBindings(bindings.filter { $0.value != key.fingerprint })
    }
}
