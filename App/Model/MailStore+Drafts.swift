import Foundation
import MailEngine

extension MailStore {
    static let encryptDraftsKey = "encryptDrafts"

    /// Drafts are encrypted to the own key unless the user turned that off.
    static var encryptDrafts: Bool {
        UserDefaults.standard.object(forKey: encryptDraftsKey) == nil || UserDefaults.standard.bool(forKey: encryptDraftsKey)
    }

    /// Saves the draft in the server's Drafts folder, replacing an earlier version.
    /// Returns the Message-ID that identifies it from now on.
    func saveDraft(_ draft: ComposeDraft, keys: KeyStore) async throws -> String {
        guard let account = accounts.account(draft.accountID) else {
            throw MailError.protocolError("Das Konto existiert nicht mehr.")
        }
        guard let drafts = folder(role: .drafts, account: account.id) else {
            throw MailError.server("Dieses Konto hat keinen Entwürfe-Ordner.")
        }
        var message = OutgoingMessage(from: account.address)
        message.to = HeaderCodec.parseAddressList(draft.to)
        message.cc = HeaderCodec.parseAddressList(draft.cc)
        message.subject = draft.subject
        message.body = draft.body
        message.attachments = draft.attachments
        message.inReplyTo = draft.inReplyTo
        message.references = draft.references
        if let id = draft.serverMessageID { message.messageID = id }
        var extra = ["X-Postfalke-Draft": (draft.options ?? DraftOptions()).headerValue]
        if !draft.bcc.isEmpty { extra["Bcc"] = draft.bcc }
        message.extraHeaders = extra

        var pgp: PGPSendOptions?
        if Self.encryptDrafts, let key = keys.personalKey(for: account) {
            // Only the own key can read it, the subject included.
            pgp = PGPSendOptions(sign: false, encrypt: true, signer: nil,
                                 recipientKeys: [key.publicArmored], protectSubject: true)
        }
        let data = try await Task.detached(priority: .userInitiated) { [message, pgp] in
            try MIMEBuilder.build(message, pgp: pgp)
        }.value
        let messageID = message.messageID
        try await session(account.id).perform(folder: drafts.path) { imap in
            let older = try await imap.search(header: "Message-ID", value: messageID)
            try await imap.append(data, to: drafts.path, flags: ["\\Seen", "\\Draft"])
            try await imap.expunge(uids: older)
        }
        Task { await refresh(FolderKey(accountID: account.id, path: drafts.path)) }
        return messageID
    }

    /// Removes a draft from the server (after sending or discarding it).
    func deleteServerDraft(accountID: UUID, messageID: String) async {
        guard let drafts = folder(role: .drafts, account: accountID) else { return }
        _ = try? await session(accountID).perform(folder: drafts.path) { imap in
            try await imap.expunge(uids: try await imap.search(header: "Message-ID", value: messageID))
        }
        await refresh(FolderKey(accountID: accountID, path: drafts.path))
    }

    /// Turns a message of the Drafts folder back into something editable.
    func loadDraft(_ key: FolderKey, header: MessageHeader, keys: KeyStore) async throws -> ComposeDraft {
        let raw = try await rawMessage(key, uid: header.uid)
        let context = keys.context
        let processed = await Task.detached(priority: .userInitiated) {
            MessageProcessor.process(raw: raw, context: context)
        }.value
        if let error = processed.security.decryptionError { throw MailError.pgp(error) }
        let root = processed.root

        var draft = ComposeDraft(accountID: key.accountID)
        func addresses(_ field: String) -> String {
            HeaderCodec.parseAddressList(root.header(field)).map(\.formatted).joined(separator: ", ")
        }
        draft.to = addresses("To")
        draft.cc = addresses("Cc")
        draft.bcc = root.decodedHeader("Bcc") ?? ""
        draft.subject = processed.protectedSubject ?? root.decodedHeader("Subject") ?? ""
        var body = (processed.content.plain ?? "").replacingOccurrences(of: "\r\n", with: "\n")
        if body.hasSuffix("\n") { body.removeLast() }   // added by the transfer encoding
        draft.body = body
        // The own public key is attached again when sending, if wanted.
        draft.attachments = processed.content.attachments.filter {
            !($0.mimeType == "application/pgp-keys" && $0.filename.hasPrefix("OpenPGP_0x"))
        }
        draft.inReplyTo = root.header("In-Reply-To")
        draft.references = root.header("References")
        draft.options = DraftOptions(headerValue: root.header("X-Postfalke-Draft"))
        draft.serverMessageID = root.header("Message-ID")
        return draft
    }
}
