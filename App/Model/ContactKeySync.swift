import Foundation
import Observation
import MailEngine

/// Pulls OpenPGP keys out of the KEY field of CardDAV contacts.
@MainActor
@Observable
final class ContactKeySync {
    struct Settings: Codable, Equatable {
        var url = ""
        var username = ""
        /// Fingerprint of a self-signed certificate the user chose to trust.
        var trustedCertificate: String?
    }

    private(set) var settings: Settings
    /// Receives the contacts for address suggestions.
    var directory: ContactDirectory?
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var lastResult: String?
    private(set) var lastError: String?
    /// Set when the server presented a certificate the system rejects.
    var untrusted: CertificateInfo?

    private static let file = "carddav.json"
    private static let passwordKey = "carddav-password"
    private static let lastSyncKey = "carddav-last-sync"

    init() {
        settings = Storage.load(Settings.self, from: Self.file) ?? Settings()
        lastSync = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
    }

    var isConfigured: Bool { URL(string: settings.url)?.host != nil && !settings.username.isEmpty }
    var hasPassword: Bool { Keychain.get(Self.passwordKey)?.isEmpty == false }

    /// A nil password keeps the stored one.
    func save(_ new: Settings, password: String?) {
        settings = new
        Storage.save(new, to: Self.file)
        if let password { Keychain.set(password, for: Self.passwordKey) }
    }

    func remove(keys: KeyStore) {
        settings = Settings()
        try? FileManager.default.removeItem(at: Storage.url(Self.file))
        Keychain.delete(Self.passwordKey)
        UserDefaults.standard.removeObject(forKey: Self.lastSyncKey)
        lastSync = nil
        lastResult = nil
        lastError = nil
        keys.setBindings([:])
    }

    /// Normalises what people type: missing scheme, bare Nextcloud host.
    static func normalizedURL(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "https://" + value }
        return URL(string: value)
    }

    /// Syncs at most every few hours unless forced.
    func syncIfDue(keys: KeyStore) async {
        guard isConfigured else { return }
        if let lastSync, Date().timeIntervalSince(lastSync) < 6 * 3600 { return }
        await sync(keys: keys)
    }

    func sync(keys: KeyStore) async {
        guard !isSyncing, let url = Self.normalizedURL(settings.url) else { return }
        isSyncing = true
        defer { isSyncing = false }
        let client = CardDAVClient(baseURL: url, username: settings.username,
                                   password: Keychain.get(Self.passwordKey) ?? "",
                                   trustedCertificate: settings.trustedCertificate)
        do {
            let contacts = try await client.fetchContacts()
            Storage.save(contacts.filter { !$0.emails.isEmpty }.map { VCardContact(name: $0.name, emails: $0.emails) },
                         to: ContactDirectory.cardDAVFile)
            directory?.reloadAddressBook()
            var bindings: [String: String] = [:]
            var imported = Set<String>()
            for contact in contacts where !contact.keys.isEmpty && !contact.emails.isEmpty {
                for source in contact.keys {
                    guard let data = await Self.keyData(source),
                          let found = try? keys.importKeys(from: data, allowSecret: false) else { continue }
                    imported.formUnion(found.map(\.fingerprint))
                    // The card says whose key this is, whatever the key's own user ID claims.
                    if let usable = found.first(where: { $0.isUsable && $0.canEncrypt }) {
                        for email in contact.emails { bindings[email] = usable.fingerprint }
                    }
                }
            }
            keys.setBindings(bindings)
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: Self.lastSyncKey)
            lastResult = "\(contacts.count) Kontakte gelesen, \(imported.count) Schlüssel für \(bindings.count) Adressen."
            lastError = nil
        } catch MailError.untrustedCertificate(let info) {
            lastError = MailStore.describe(MailError.untrustedCertificate(info))
            untrusted = info
        } catch {
            lastError = MailStore.describe(error)
        }
    }

    func trust(_ info: CertificateInfo, keys: KeyStore) async {
        var updated = settings
        updated.trustedCertificate = info.sha256
        save(updated, password: nil)
        await sync(keys: keys)
    }

    func setTrustedCertificate(_ fingerprint: String?) {
        var updated = settings
        updated.trustedCertificate = fingerprint
        save(updated, password: nil)
    }

    /// Embedded key data, or a key published at an https address.
    private static func keyData(_ key: VCard.Key) async -> Data? {
        switch key {
        case .data(let data):
            return data
        case .url(let url):
            guard url.scheme?.lowercased() == "https" else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_000_000 else { return nil }
            return data
        }
    }
}
