import Foundation
import Observation
import UIKit
import os
import MailEngine

/// Builds and sends one draft. Shared by the outbox, the share extension path and tests.
@MainActor
enum MailSender {
    static func send(_ draft: ComposeDraft, accounts: AccountStore, keys: KeyStore, mail: MailStore,
                     directory: ContactDirectory? = nil) async throws {
        guard let account = accounts.account(draft.accountID) else {
            throw MailError.protocolError("Das Absenderkonto existiert nicht mehr.")
        }
        let (message, options) = try build(draft, account: account, keys: keys)
        try await mail.send(message, pgp: options, account: account)
        directory?.noteSent(message.allRecipients)
        if let answering = draft.answering {
            await mail.markAnswered(answering.folder, uid: answering.uid)
        }
        if let messageID = draft.serverMessageID {
            await mail.deleteServerDraft(accountID: account.id, messageID: messageID)
        }
    }

    /// The message and its OpenPGP treatment, exactly as it will go out.
    static func build(_ draft: ComposeDraft, account: Account, keys: KeyStore) throws -> (OutgoingMessage, PGPSendOptions?) {
        var message = OutgoingMessage(from: account.address)
        message.to = HeaderCodec.parseAddressList(draft.to)
        message.cc = HeaderCodec.parseAddressList(draft.cc)
        message.bcc = HeaderCodec.parseAddressList(draft.bcc)
        message.subject = draft.subject
        message.body = draft.body
        message.attachments = draft.attachments
        message.inReplyTo = draft.inReplyTo
        message.references = draft.references
        guard !message.allRecipients.isEmpty else { throw MailError.protocolError("Keine Empfänger angegeben.") }

        let options = draft.options ?? DraftOptions()
        guard let key = keys.personalKey(for: account) else {
            if options.sign || options.encrypt {
                throw MailError.pgp("Für \(account.email) gibt es keinen eigenen Schlüssel.")
            }
            return (message, nil)
        }
        message.autocryptKey = key.publicArmored
        if options.attachOwnKey {
            message.attachments.append(MailAttachment(
                filename: "OpenPGP_0x\(key.keyID).asc", mimeType: "application/pgp-keys",
                data: Data(key.publicArmored.utf8)))
        }
        guard options.sign || options.encrypt else { return (message, nil) }

        var recipientKeys: [String] = []
        if options.encrypt {
            let missing = message.allRecipients.filter { keys.encryptionKey(for: $0.email) == nil }
            guard missing.isEmpty else {
                throw MailError.pgp("Kein öffentlicher Schlüssel für \(missing.map(\.email).joined(separator: ", ")).")
            }
            // Encrypt to every recipient and to ourselves, so the sent copy stays readable.
            recipientKeys = message.allRecipients.compactMap { keys.encryptionKey(for: $0.email)?.publicArmored } + [key.publicArmored]
        }
        return (message, PGPSendOptions(sign: options.sign, encrypt: options.encrypt,
                                        signer: keys.secret(for: key.fingerprint),
                                        recipientKeys: recipientKeys,
                                        protectSubject: options.encrypt && options.protectSubject))
    }
}

/// Messages waiting to go out: during the undo window, until a scheduled time,
/// or until the network is back.
@MainActor
@Observable
final class Outbox {
    struct Item: Codable, Identifiable, Equatable {
        var id = UUID()
        var draft: ComposeDraft
        var sendAt: Date
        /// Chosen by the user ("Später senden"); otherwise it is the undo window.
        var scheduled: Bool
        var attempts = 0
        var lastError: String?
        /// When to try again after a failure; nil after a failure means "wait for the user".
        var retryAt: Date?

        var isFailed: Bool { lastError != nil && retryAt == nil }
        var dueDate: Date? {
            if attempts == 0 { return sendAt }
            return retryAt
        }
    }

    static let undoDelayKey = "undoSendDelay"
    private static let file = "outbox.json"
    private static let log = Logger(subsystem: "de.postfalke.app", category: "outbox")

    private(set) var items: [Item] = []
    private(set) var isSending = false
    /// Set once by the app; sends one draft.
    var send: ((ComposeDraft) async throws -> Void)?
    private var wakeTask: Task<Void, Never>?

    init() {
        items = Storage.load([Item].self, from: Self.file) ?? []
    }

    /// Seconds a sent message waits so it can be withdrawn (0 = send at once).
    static var undoDelay: TimeInterval {
        UserDefaults.standard.object(forKey: undoDelayKey) == nil ? 10 : UserDefaults.standard.double(forKey: undoDelayKey)
    }

    private func persist() {
        Storage.save(items, to: Self.file)
    }

    // MARK: Queue

    /// Queues a message. Without a date it goes out after the undo delay.
    func enqueue(_ draft: ComposeDraft, at date: Date? = nil) {
        let item = Item(draft: draft, sendAt: date ?? Date().addingTimeInterval(Self.undoDelay), scheduled: date != nil)
        items.append(item)
        persist()
        wake()
    }

    /// Takes a message out of the queue (undo, edit) and returns its draft.
    @discardableResult
    func remove(_ id: UUID) -> ComposeDraft? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let draft = items.remove(at: index).draft
        persist()
        wake()
        return draft
    }

    /// The message that can still be withdrawn, if any.
    func undoable(at now: Date = .now) -> Item? {
        items.filter { !$0.scheduled && $0.attempts == 0 && $0.sendAt > now }.max { $0.sendAt < $1.sendAt }
    }

    /// What the "Postausgang" shows: planned, waiting for the network, or failed.
    var waiting: [Item] {
        items.filter { $0.scheduled || $0.attempts > 0 }.sorted { $0.sendAt < $1.sendAt }
    }

    var nextDue: Date? { items.compactMap(\.dueDate).min() }

    func sendNow(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].sendAt = .now
        items[index].retryAt = items[index].attempts > 0 ? .now : nil
        items[index].lastError = nil
        persist()
        Task { await process() }
    }

    // MARK: Sending

    /// Sends everything that is due. Safe to call often.
    func process() async {
        guard !isSending, let send else { return }
        isSending = true
        defer {
            isSending = false
            wake()
        }
        while let item = items.first(where: { ($0.dueDate ?? .distantFuture) <= .now }) {
            do {
                try await send(item.draft)
                items.removeAll { $0.id == item.id }
                persist()
                Self.log.info("sent queued message")
            } catch {
                guard let index = items.firstIndex(where: { $0.id == item.id }) else { continue }
                items[index].attempts += 1
                items[index].lastError = MailStore.describe(error)
                items[index].retryAt = Self.isTemporary(error)
                    ? Date().addingTimeInterval(Self.backoff(items[index].attempts)) : nil
                persist()
                // Without network nothing else will get through either.
                if Self.isTemporary(error) { break }
            }
        }
    }

    /// The app is leaving the screen: nothing can be withdrawn any more, so send now.
    func flushUndoWindow() async {
        var changed = false
        for index in items.indices where !items[index].scheduled && items[index].attempts == 0 {
            items[index].sendAt = .now
            changed = true
        }
        guard changed else { return }
        persist()
        await process()
    }

    static func isTemporary(_ error: Error) -> Bool {
        if case MailError.connection = error { return true }
        return error is URLError
    }

    static func backoff(_ attempt: Int) -> TimeInterval {
        [30, 120, 600, 1800][min(attempt - 1, 3)]
    }

    /// Sleeps until the next item is due.
    private func wake() {
        wakeTask?.cancel()
        guard let next = nextDue else { return }
        wakeTask = Task { [weak self] in
            let delay = max(0, next.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay + 0.2))
            guard !Task.isCancelled else { return }
            await self?.process()
        }
    }
}

/// Drafts being written, kept on the device so nothing is lost if the app ends.
enum LocalDrafts {
    private static var directory: URL {
        let url = Storage.url("drafts")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func save(_ draft: ComposeDraft) {
        guard draft.hasContent, let data = try? JSONEncoder().encode(draft) else { return }
        try? data.write(to: directory.appendingPathComponent("\(draft.id.uuidString).json"),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).json"))
    }

    static func all() -> [ComposeDraft] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ComposeDraft.self, from: $0) }
        }
    }
}
