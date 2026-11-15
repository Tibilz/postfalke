import Foundation
import Observation
import Contacts
import MailEngine

/// Addresses for suggestions while writing: people written to, senders seen,
/// CardDAV contacts and (if allowed) the iOS contacts.
@MainActor
@Observable
final class ContactDirectory {
    struct Entry: Codable, Hashable, Identifiable {
        var email: String
        var name: String?
        var lastSent: Date?
        var lastSeen: Date?
        var fromContacts = false

        var id: String { email }
        var address: MailAddress { MailAddress(name: name, email: email) }
    }

    static let useSystemContactsKey = "useSystemContacts"
    private static let historyFile = "address-history.json"
    static let cardDAVFile = "carddav-contacts.json"

    /// Addresses from mail traffic, by lowercased address.
    private var history: [String: Entry] = [:]
    /// Address book entries (CardDAV and iOS), by lowercased address.
    private var book: [String: Entry] = [:]
    private var saveTask: Task<Void, Never>?

    init() {
        history = Storage.load([String: Entry].self, from: Self.historyFile) ?? [:]
        reloadAddressBook()
    }

    // MARK: Sources

    /// Reads the CardDAV copy and, if allowed, the iOS contacts.
    func reloadAddressBook() {
        var entries: [String: Entry] = [:]
        for card in Storage.load([VCardContact].self, from: Self.cardDAVFile) ?? [] {
            for email in card.emails {
                entries[email.lowercased()] = Entry(email: email, name: card.name, fromContacts: true)
            }
        }
        book = entries
        guard UserDefaults.standard.bool(forKey: Self.useSystemContactsKey),
              CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
        Task.detached(priority: .utility) {
            let system = Self.readSystemContacts()
            await MainActor.run {
                for entry in system where self.book[entry.email.lowercased()] == nil {
                    self.book[entry.email.lowercased()] = entry
                }
            }
        }
    }

    nonisolated private static func readSystemContacts() -> [Entry] {
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                    CNContactEmailAddressesKey] as [CNKeyDescriptor]
        var result: [Entry] = []
        try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
            let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            for email in contact.emailAddresses {
                result.append(Entry(email: email.value as String,
                                    name: name.isEmpty ? (contact.organizationName.isEmpty ? nil : contact.organizationName) : name,
                                    fromContacts: true))
            }
        }
        return result
    }

    /// Asks iOS for access to all contacts; returns whether it was granted.
    func requestSystemContacts() async -> Bool {
        let granted = (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        UserDefaults.standard.set(granted, forKey: Self.useSystemContactsKey)
        reloadAddressBook()
        return granted
    }

    /// Remembers recipients of a sent message (they rank highest).
    func noteSent(_ addresses: [MailAddress]) {
        for address in addresses {
            let key = address.email.lowercased()
            var entry = history[key] ?? Entry(email: address.email)
            if let name = address.name, !name.isEmpty { entry.name = name }
            entry.lastSent = Date()
            history[key] = entry
        }
        scheduleSave()
    }

    /// Remembers senders of received messages.
    func noteSeen(_ headers: [MessageHeader]) {
        var changed = false
        for header in headers {
            for address in header.from + header.replyTo {
                let key = address.email.lowercased()
                let date = header.sortDate
                var entry = history[key] ?? Entry(email: address.email)
                if entry.name == nil, let name = address.name { entry.name = name }
                if (entry.lastSeen ?? .distantPast) < date {
                    entry.lastSeen = date
                    history[key] = entry
                    changed = true
                }
            }
        }
        if changed { scheduleSave() }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            Storage.save(history, to: Self.historyFile)
        }
    }

    // MARK: Suggestions

    /// Best matches for what is being typed; skips addresses already chosen.
    func suggestions(for query: String, excluding taken: Set<String> = [], limit: Int = 6) -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard needle.count >= 1 else { return [] }
        var merged = book
        for (key, entry) in history {
            var combined = merged[key] ?? entry
            combined.lastSent = entry.lastSent
            combined.lastSeen = entry.lastSeen
            if combined.name == nil { combined.name = entry.name }
            merged[key] = combined
        }
        let matches = merged.values.filter { entry in
            guard !taken.contains(entry.email.lowercased()) else { return false }
            if entry.email.lowercased().hasPrefix(needle) { return true }
            let local = entry.email.lowercased().split(separator: "@").first.map(String.init) ?? ""
            if local.split(whereSeparator: { ".-_".contains($0) }).contains(where: { $0.hasPrefix(needle) }) { return true }
            return (entry.name ?? "").lowercased().split(separator: " ").contains { $0.hasPrefix(needle) }
                || (entry.name ?? "").lowercased().hasPrefix(needle)
        }
        return matches.sorted { a, b in
            // Written to before, then seen, then address book; newest first.
            let rank = { (e: Entry) -> (Int, Date) in
                if let sent = e.lastSent { return (0, sent) }
                if let seen = e.lastSeen { return (e.fromContacts ? 1 : 2, seen) }
                return (3, .distantPast)
            }
            let (ra, da) = rank(a), (rb, db) = rank(b)
            if ra != rb { return ra < rb }
            if da != db { return da > db }
            return (a.name ?? a.email).localizedCaseInsensitiveCompare(b.name ?? b.email) == .orderedAscending
        }
        .prefix(limit)
        .map { $0 }
    }
}

/// Name and addresses of a CardDAV contact, kept for suggestions.
struct VCardContact: Codable {
    var name: String?
    var emails: [String]
}
