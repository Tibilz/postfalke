import Foundation
import Observation
import CryptoKit
import MailEngine

/// Serialises asynchronous work: IMAP allows one command at a time per connection.
actor AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// One IMAP connection per account, reconnecting on demand.
final class MailSession: Sendable {
    private let client: IMAPClient
    private let lock = AsyncLock()

    init(account: Account, password: String) {
        client = IMAPClient(config: account.imap, password: password)
    }

    /// Runs `operation` with `folder` selected. Retries once if the connection had gone stale.
    func perform<T: Sendable>(folder: String? = nil,
                              _ operation: @Sendable (IMAPClient) async throws -> T) async throws -> T {
        await lock.lock()
        do {
            let result = try await attempt(folder: folder, operation)
            await lock.unlock()
            return result
        } catch {
            await lock.unlock()
            throw error
        }
    }

    private func attempt<T: Sendable>(folder: String?,
                                      _ operation: @Sendable (IMAPClient) async throws -> T) async throws -> T {
        var retried = false
        while true {
            do {
                if !(await client.isConnected) { try await client.connect() }
                if let folder { try await client.select(folder) }
                return try await operation(client)
            } catch MailError.connection(let message) {
                await client.disconnect()
                if retried { throw MailError.connection(message) }
                retried = true
            }
        }
    }

    func close() async {
        await lock.lock()
        await client.logout()
        await lock.unlock()
    }
}

@MainActor
@Observable
final class MailboxState {
    var headers: [MessageHeader] = []
    var exists = 0
    var uidValidity: UInt32 = 0
    /// Lowest sequence number that has been loaded (1 = everything).
    var lowestSequence = 1
    var isLoading = false
    var hasLoaded = false
    var error: String?

    var canLoadMore: Bool { hasLoaded && lowestSequence > 1 }
}

/// Central mail state shared by all views.
@MainActor
@Observable
final class MailStore {
    static let pageSize = 50

    let accounts: AccountStore
    private var sessions: [UUID: MailSession] = [:]
    private(set) var folders: [UUID: [MailFolder]] = [:]
    private(set) var folderErrors: [UUID: String] = [:]
    private var mailboxes: [FolderKey: MailboxState] = [:]
    /// Subjects recovered from encrypted mail, so the list need not show "...".
    private var protectedSubjects: [String: String] = [:]
    private static let subjectsFile = "protected-subjects.json"

    init(accounts: AccountStore) {
        self.accounts = accounts
        protectedSubjects = Storage.load([String: String].self, from: Self.subjectsFile) ?? [:]
        for account in accounts.accounts {
            folders[account.id] = Storage.load([MailFolder].self, from: "folders-\(account.id.uuidString).json")
        }
    }

    // MARK: Sessions

    private func session(_ accountID: UUID) throws -> MailSession {
        if let existing = sessions[accountID] { return existing }
        guard let account = accounts.account(accountID) else {
            throw MailError.connection("Das Konto existiert nicht mehr.")
        }
        let session = MailSession(account: account, password: accounts.password(for: account))
        sessions[accountID] = session
        return session
    }

    /// Drops the connection (after the settings changed or the account was removed).
    func resetSession(_ accountID: UUID) {
        if let session = sessions.removeValue(forKey: accountID) {
            Task { await session.close() }
        }
    }

    func forget(_ accountID: UUID) {
        resetSession(accountID)
        folders[accountID] = nil
        folderErrors[accountID] = nil
        mailboxes = mailboxes.filter { $0.key.accountID != accountID }
        try? FileManager.default.removeItem(at: Storage.url("folders-\(accountID.uuidString).json"))
        try? FileManager.default.removeItem(at: Self.cacheDirectory.appendingPathComponent(accountID.uuidString))
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Folders

    func folder(_ key: FolderKey) -> MailFolder? {
        folders[key.accountID]?.first { $0.path == key.path }
    }

    func folder(role: MailFolder.Role, account: UUID) -> MailFolder? {
        folders[account]?.first { $0.role == role }
    }

    func loadFolders(_ accountID: UUID) async {
        do {
            let session = try session(accountID)
            var list = try await session.perform { try await $0.listFolders() }
            // Keep known counts until the fresh ones arrive.
            for index in list.indices {
                let old = folders[accountID]?.first { $0.path == list[index].path }
                list[index].unread = old?.unread
                list[index].total = old?.total
            }
            folders[accountID] = list
            folderErrors[accountID] = nil

            for folder in list.filter(\.isSelectable).prefix(30) {
                guard let counts = try? await session.perform({ try await $0.folderCounts(folder.path) }) else { continue }
                if let index = folders[accountID]?.firstIndex(where: { $0.path == folder.path }) {
                    folders[accountID]?[index].unread = counts.unread
                    folders[accountID]?[index].total = counts.total
                }
            }
            Storage.save(folders[accountID] ?? [], to: "folders-\(accountID.uuidString).json")
        } catch {
            folderErrors[accountID] = Self.describe(error)
        }
    }

    private func adjustUnread(_ key: FolderKey, by delta: Int) {
        guard let index = folders[key.accountID]?.firstIndex(where: { $0.path == key.path }),
              let unread = folders[key.accountID]?[index].unread else { return }
        folders[key.accountID]?[index].unread = max(0, unread + delta)
    }

    // MARK: Message lists

    func mailbox(_ key: FolderKey) -> MailboxState {
        if let state = mailboxes[key] { return state }
        let state = MailboxState()
        mailboxes[key] = state
        return state
    }

    /// Reloads the newest messages (as many as are currently shown, at least one page).
    func refresh(_ key: FolderKey) async {
        let state = mailbox(key)
        guard !state.isLoading else { return }
        state.isLoading = true
        defer { state.isLoading = false }
        let wanted = min(max(Self.pageSize, state.headers.count), 400)
        do {
            let result = try await session(key.accountID).perform { imap -> (MailboxStatus, [MessageHeader], Int) in
                let status = try await imap.select(key.path, force: true)
                guard status.exists > 0 else { return (status, [], 1) }
                let low = max(1, status.exists - wanted + 1)
                return (status, try await imap.fetchHeaders(sequence: low...status.exists), low)
            }
            state.exists = result.0.exists
            state.uidValidity = result.0.uidValidity
            state.headers = result.1.sorted { $0.uid > $1.uid }
            state.lowestSequence = result.2
            state.hasLoaded = true
            state.error = nil
            if key.path.uppercased() == "INBOX" {
                noteSeen(key.accountID, uidValidity: state.uidValidity, headers: state.headers)
            }
        } catch {
            state.error = Self.describe(error)
        }
    }

    func loadMore(_ key: FolderKey) async {
        let state = mailbox(key)
        guard !state.isLoading, state.canLoadMore else { return }
        state.isLoading = true
        defer { state.isLoading = false }
        let high = state.lowestSequence - 1
        let low = max(1, high - Self.pageSize + 1)
        do {
            let older = try await session(key.accountID).perform(folder: key.path) {
                try await $0.fetchHeaders(sequence: low...high)
            }
            let known = Set(state.headers.map(\.uid))
            state.headers = (state.headers + older.filter { !known.contains($0.uid) }).sorted { $0.uid > $1.uid }
            state.lowestSequence = low
        } catch {
            state.error = Self.describe(error)
        }
    }

    func search(_ key: FolderKey, query: String) async throws -> [MessageHeader] {
        let headers = try await session(key.accountID).perform(folder: key.path) { imap -> [MessageHeader] in
            let uids = try await imap.search(query)
            return try await imap.fetchHeaders(uids: Array(uids.suffix(200)))
        }
        return headers.sorted { $0.uid > $1.uid }
    }

    // MARK: Protected subjects

    private func subjectKey(_ key: FolderKey, uid: UInt32) -> String {
        "\(key.accountID.uuidString)|\(key.path)|\(mailbox(key).uidValidity)|\(uid)"
    }

    func subject(_ key: FolderKey, header: MessageHeader) -> String {
        guard header.isEncrypted else { return header.subject }
        return protectedSubjects[subjectKey(key, uid: header.uid)] ?? header.subject
    }

    func rememberSubject(_ subject: String, _ key: FolderKey, uid: UInt32) {
        let id = subjectKey(key, uid: uid)
        guard protectedSubjects[id] != subject else { return }
        protectedSubjects[id] = subject
        Storage.save(protectedSubjects, to: Self.subjectsFile)
    }

    // MARK: New mail

    struct NewMail: Sendable {
        var account: String
        var header: MessageHeader
    }

    private static func baselineKey(_ accountID: UUID) -> String { "newest-seen-uid-\(accountID.uuidString)" }

    /// Remembers what the user has already had on screen, so it is not announced again.
    private func noteSeen(_ accountID: UUID, uidValidity: UInt32, headers: [MessageHeader]) {
        let newest = headers.map(\.uid).max() ?? 0
        let stored = UserDefaults.standard.dictionary(forKey: Self.baselineKey(accountID)) as? [String: Int]
        if stored?["validity"] == Int(uidValidity), (stored?["uid"] ?? 0) >= Int(newest) { return }
        UserDefaults.standard.set(["validity": Int(uidValidity), "uid": Int(newest)], forKey: Self.baselineKey(accountID))
    }

    /// Looks into every inbox and returns unread messages that arrived since the last look.
    func checkNewMail() async -> [NewMail] {
        var found: [NewMail] = []
        for account in accounts.accounts {
            let key = FolderKey(accountID: account.id, path: "INBOX")
            let stored = UserDefaults.standard.dictionary(forKey: Self.baselineKey(account.id)) as? [String: Int]
            await refresh(key)
            let state = mailbox(key)
            guard state.error == nil, state.hasLoaded else { continue }
            // First look, or the server renumbered the folder: nothing to compare with.
            if let stored, stored["validity"] == Int(state.uidValidity), let known = stored["uid"] {
                found += state.headers
                    .filter { Int($0.uid) > known && !$0.isSeen }
                    .map { NewMail(account: account.email, header: $0) }
            }
        }
        return found
    }

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("messages")
    }

    private func cacheURL(_ key: FolderKey, uid: UInt32) -> URL {
        let folderHash = SHA256.hash(data: Data(key.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let directory = Self.cacheDirectory
            .appendingPathComponent(key.accountID.uuidString)
            .appendingPathComponent(folderHash)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(mailbox(key).uidValidity)-\(uid).eml")
    }

    /// The raw message, from the local cache when possible.
    func rawMessage(_ key: FolderKey, uid: UInt32) async throws -> Data {
        let url = cacheURL(key, uid: uid)
        if let cached = try? Data(contentsOf: url) { return cached }
        let data = try await session(key.accountID).perform(folder: key.path) { try await $0.fetchMessage(uid: uid) }
        try? data.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
        return data
    }

    // MARK: Flags and moving

    private func update(_ key: FolderKey, uid: UInt32, _ change: (inout MessageHeader) -> Void) {
        let state = mailbox(key)
        guard let index = state.headers.firstIndex(where: { $0.uid == uid }) else { return }
        change(&state.headers[index])
    }

    func setSeen(_ key: FolderKey, header: MessageHeader, seen: Bool) async {
        guard header.isSeen != seen else { return }
        update(key, uid: header.uid) { if seen { $0.flags.insert("\\Seen") } else { $0.flags.remove("\\Seen") } }
        adjustUnread(key, by: seen ? -1 : 1)
        await setFlag(key, uid: header.uid, flag: "\\Seen", enabled: seen)
    }

    func setFlagged(_ key: FolderKey, header: MessageHeader, flagged: Bool) async {
        update(key, uid: header.uid) { if flagged { $0.flags.insert("\\Flagged") } else { $0.flags.remove("\\Flagged") } }
        await setFlag(key, uid: header.uid, flag: "\\Flagged", enabled: flagged)
    }

    func markAnswered(_ key: FolderKey, uid: UInt32) async {
        update(key, uid: uid) { $0.flags.insert("\\Answered") }
        await setFlag(key, uid: uid, flag: "\\Answered", enabled: true)
    }

    private func setFlag(_ key: FolderKey, uid: UInt32, flag: String, enabled: Bool) async {
        do {
            try await session(key.accountID).perform(folder: key.path) {
                try await $0.setFlag(flag, on: [uid], enabled: enabled)
            }
        } catch {
            mailbox(key).error = Self.describe(error)
        }
    }

    private func removeLocally(_ key: FolderKey, header: MessageHeader) {
        let state = mailbox(key)
        state.headers.removeAll { $0.uid == header.uid }
        state.exists = max(0, state.exists - 1)
        state.lowestSequence = max(1, state.lowestSequence - 1)
        if !header.isSeen { adjustUnread(key, by: -1) }
    }

    func move(_ key: FolderKey, header: MessageHeader, to destination: MailFolder) async {
        guard destination.path != key.path else { return }
        removeLocally(key, header: header)
        do {
            try await session(key.accountID).perform(folder: key.path) {
                try await $0.move(uids: [header.uid], to: destination.path)
            }
        } catch {
            mailbox(key).error = Self.describe(error)
            await refresh(key)
        }
    }

    /// Moves to the trash; inside the trash (or without one) deletes permanently.
    func delete(_ key: FolderKey, header: MessageHeader) async {
        if let trash = folder(role: .trash, account: key.accountID), trash.path != key.path {
            await move(key, header: header, to: trash)
            return
        }
        removeLocally(key, header: header)
        do {
            try await session(key.accountID).perform(folder: key.path) { try await $0.expunge(uids: [header.uid]) }
        } catch {
            mailbox(key).error = Self.describe(error)
            await refresh(key)
        }
    }

    // MARK: Sending

    /// Sends via SMTP and stores a copy in the Sent folder.
    func send(_ message: OutgoingMessage, pgp: PGPSendOptions?, account: Account) async throws {
        let password = accounts.password(for: account)
        let data = try await Task.detached(priority: .userInitiated) {
            try MIMEBuilder.build(message, pgp: pgp)
        }.value
        let smtp = SMTPClient(config: account.smtp, password: password)
        try await smtp.send(data, from: account.email, recipients: message.allRecipients.map(\.email))

        if let sent = folder(role: .sent, account: account.id) {
            // Gmail files sent mail itself; a second copy would be a duplicate.
            let savesItself = account.smtp.host.lowercased().hasSuffix("gmail.com")
            if !savesItself {
                _ = try? await session(account.id).perform { try await $0.append(data, to: sent.path) }
            }
        }
    }

    /// Checks IMAP and SMTP credentials without touching stored state.
    static func verify(_ account: Account, password: String) async throws {
        let imap = IMAPClient(config: account.imap, password: password)
        try await imap.connect()
        await imap.logout()
        try await SMTPClient(config: account.smtp, password: password).verify()
    }
}
