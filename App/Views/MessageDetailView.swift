import SwiftUI
import QuickLook
import MailEngine

struct MessageDetailView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(MailStore.self) private var mail

    let folder: FolderKey
    let header: MessageHeader
    var compose: (ComposeDraft) -> Void
    /// Shows another message of the same list (previous/next).
    var navigate: (UInt32) -> Void
    var close: () -> Void

    @State private var message: ProcessedMessage?
    @State private var showDetails = false

    private var subject: String {
        MessageActions.subject(message: message, header: header, folder: folder, mail: mail)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MessageHeaderBlock(folder: folder, header: header, showDetails: $showDetails)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                Divider()
                    .padding(.leading, 16)
                    .padding(.vertical, 12)

                Text(subject)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)

                MessageBody(folder: folder, header: header) { message = $0 }
            }
            .padding(.bottom, 24)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
    }

    private var account: Account? { accounts.account(folder.accountID) }

    /// Neighbours in the list (newest first): `previous` is above, `next` below.
    private var neighbours: (previous: UInt32?, next: UInt32?) {
        let uids = mail.mailbox(folder).headers.map(\.uid)
        guard let index = uids.firstIndex(of: header.uid) else { return (nil, nil) }
        return (index > 0 ? uids[index - 1] : nil, index + 1 < uids.count ? uids[index + 1] : nil)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            let around = neighbours
            Button {
                if let uid = around.previous { navigate(uid) }
            } label: {
                Label("Vorherige E-Mail", systemImage: "chevron.up")
            }
            .disabled(around.previous == nil)
            Button {
                if let uid = around.next { navigate(uid) }
            } label: {
                Label("Nächste E-Mail", systemImage: "chevron.down")
            }
            .disabled(around.next == nil)
        }
        MessageToolbar(folder: folder, messages: [header], latest: header, loaded: message,
                       compose: compose, close: close)
    }
}

/// Avatar, sender, date and the recipient line that expands to all addresses.
struct MessageHeaderBlock: View {
    @Environment(AccountStore.self) private var accounts
    let folder: FolderKey
    let header: MessageHeader
    @Binding var showDetails: Bool

    private var sender: MailAddress? { header.from.first }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(name: sender?.displayName ?? "", size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(sender?.displayName ?? "Unbekannter Absender")
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(dateText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if showDetails {
                    addressLine("Von", header.from)
                    addressLine("An", header.to)
                    addressLine("Kopie", header.cc)
                    addressLine("Antwort an", header.replyTo)
                    Button("Ausblenden") { withAnimation(.snappy) { showDetails = false } }
                        .font(.subheadline)
                        .padding(.top, 2)
                } else {
                    HStack(spacing: 4) {
                        Text("An: " + recipientSummary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy) { showDetails = true } }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Zeigt alle Adressen")
                }
            }
        }
    }

    private var recipientSummary: String {
        let own = accounts.account(folder.accountID)?.email.lowercased()
        let names = (header.to + header.cc).map { $0.email.lowercased() == own ? "Ich" : $0.displayName }
        return names.isEmpty ? "–" : names.joined(separator: ", ")
    }

    private var dateText: String {
        guard let date = header.date ?? header.internalDate else { return "" }
        return Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
    }

    @ViewBuilder
    private func addressLine(_ label: String, _ list: [MailAddress]) -> some View {
        if !list.isEmpty {
            (Text("\(label): ").foregroundStyle(.secondary) + Text(list.map(\.formatted).joined(separator: ", ")))
                .font(.subheadline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Loads, decrypts and shows one message: security, offered keys, attachments, text.
struct MessageBody: View {
    @Environment(MailStore.self) private var mail
    @Environment(KeyStore.self) private var keys

    let folder: FolderKey
    let header: MessageHeader
    var onLoaded: (ProcessedMessage) -> Void = { _ in }

    @State private var message: ProcessedMessage?
    @State private var loadError: String?
    @State private var allowRemote = false
    @State private var bodyHeight: CGFloat = 60
    @State private var preview: URL?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message {
                SecurityBanner(security: message.security)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                keyOffer(message)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                if !message.content.attachments.isEmpty {
                    attachments(message.content.attachments)
                        .padding(.top, 12)
                }
                content(message)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
            } else if let loadError {
                VStack(alignment: .leading, spacing: 12) {
                    ErrorNotice(message: loadError)
                    Button("Erneut versuchen") { Task { await load() } }
                        .buttonStyle(.bordered)
                }
                .padding(16)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            }
        }
        .task { await load() }
        .quickLookPreview($preview)
        .alert("OpenPGP", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("Text kopieren") { UIPasteboard.general.string = notice }
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    private func load() async {
        loadError = nil
        do {
            let raw = try await mail.rawMessage(folder, uid: header.uid)
            let context = keys.context
            let processed = await Task.detached(priority: .userInitiated) {
                MessageProcessor.process(raw: raw, context: context)
            }.value
            message = processed
            onLoaded(processed)
            if let protected = processed.protectedSubject, header.isEncrypted {
                mail.rememberSubject(protected, folder, uid: header.uid)
            }
            await mail.setSeen(folder, header: header, seen: true)
        } catch {
            loadError = MailStore.describe(error)
        }
    }

    @ViewBuilder
    private func content(_ message: ProcessedMessage) -> some View {
        if let html = message.content.htmlWithInlineImages {
            if !allowRemote, MessageHTML.hasRemoteContent(html) {
                Button {
                    allowRemote = true
                } label: {
                    Label("Externe Inhalte laden", systemImage: "photo.badge.arrow.down")
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .padding(.horizontal, 2)
                .padding(.bottom, 10)
            }
            HTMLView(html: MessageHTML.page(html: html), allowRemoteContent: allowRemote, height: $bodyHeight)
                .frame(height: bodyHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if let plain = message.content.plain, !plain.isEmpty {
            HTMLView(html: MessageHTML.page(plain: plain), allowRemoteContent: false, height: $bodyHeight)
                .frame(height: bodyHeight)
        } else if message.security.decryptionError == nil {
            Text("Diese E-Mail hat keinen Textinhalt.")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        }
    }

    private func attachments(_ list: [MailAttachment]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(list) { attachment in
                    Button {
                        open(attachment)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: attachment.isPGPKey ? "key.fill" : "doc.fill")
                                .font(.title3)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(attachment.filename)
                                    .font(.footnote.weight(.medium))
                                    .lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: 200, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func open(_ attachment: MailAttachment) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(attachment.id.uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Only the last path component: a file name from a mail must not escape the folder.
        let name = (attachment.filename as NSString).lastPathComponent
        let url = directory.appendingPathComponent(name.isEmpty ? "Anhang" : name)
        do {
            try attachment.data.write(to: url)
            preview = url
        } catch {
            notice = "Der Anhang konnte nicht geöffnet werden."
        }
    }

    /// Public keys that came with the message and are not in the key ring yet.
    private func offeredKeys(_ message: ProcessedMessage) -> [Data] {
        var sources = message.content.attachments.filter(\.isPGPKey).map(\.data)
        if let autocrypt = message.autocryptKey { sources.append(autocrypt) }
        return sources.filter { data in
            guard let found = try? PGP.inspect(data) else { return false }
            return found.contains { keys.key(fingerprint: $0.fingerprint) == nil }
        }
    }

    @ViewBuilder
    private func keyOffer(_ message: ProcessedMessage) -> some View {
        let offered = offeredKeys(message)
        if !offered.isEmpty {
            Button {
                var imported: [PGPKeyInfo] = []
                for data in offered {
                    imported += (try? keys.importKeys(from: data, allowSecret: false)) ?? []
                }
                notice = imported.isEmpty
                    ? "Der Schlüssel konnte nicht importiert werden."
                    : "Importiert: " + imported.map(\.primaryUserID).joined(separator: ", ")
                        + "\n\nVergleiche den Fingerabdruck über einen zweiten Kanal, bevor du dem Schlüssel vertraust."
                Task { await load() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "key.viewfinder")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Schlüssel des Absenders importieren")
                            .font(.subheadline.weight(.medium))
                        Text("Damit kannst du ihm verschlüsselt schreiben.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
    }
}

/// Reply/forward helpers shared by the single message and the conversation view.
@MainActor
enum MessageActions {
    static func subject(message: ProcessedMessage?, header: MessageHeader, folder: FolderKey, mail: MailStore) -> String {
        let text = message?.protectedSubject ?? mail.subject(folder, header: header)
        return text.isEmpty ? "Kein Betreff" : text
    }

    static func replyText(_ message: ProcessedMessage?) -> String {
        if let plain = message?.content.plain, !plain.isEmpty { return plain }
        guard let html = message?.content.html else { return "" }
        // Crude text version of an HTML-only mail for quoting.
        return html
            .replacingOccurrences(of: "(?is)<(style|script|head)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?i)<br\\s*/?>|</p>|</div>|</tr>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    }

    static func reply(_ header: MessageHeader, message: ProcessedMessage?, all: Bool, account: Account,
                      folder: FolderKey, mail: MailStore) -> ComposeDraft {
        .reply(to: header, subject: subject(message: message, header: header, folder: folder, mail: mail),
               text: replyText(message), wasEncrypted: message?.security.wasEncrypted ?? false,
               all: all, account: account, folder: folder)
    }

    static func forward(_ header: MessageHeader, message: ProcessedMessage?, account: Account,
                        folder: FolderKey, mail: MailStore) -> ComposeDraft {
        .forward(header, subject: subject(message: message, header: header, folder: folder, mail: mail),
                 text: replyText(message), attachments: message?.content.attachments ?? [],
                 wasEncrypted: message?.security.wasEncrypted ?? false, account: account)
    }
}

/// Bottom bar of a message or conversation: delete, move, reply menu, compose.
/// Delete and move act on all `messages`; reply and flag on `latest`.
struct MessageToolbar: ToolbarContent {
    @Environment(AccountStore.self) private var accounts
    @Environment(MailStore.self) private var mail

    let folder: FolderKey
    let messages: [MessageHeader]
    let latest: MessageHeader
    let loaded: ProcessedMessage?
    var compose: (ComposeDraft) -> Void
    var close: () -> Void

    private var account: Account? { accounts.account(folder.accountID) }

    var body: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button {
                close()
                Task { for header in messages { await mail.delete(folder, header: header) } }
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
        ToolbarItem(placement: .bottomBar) {
            Menu {
                ForEach(mail.folders[folder.accountID]?.filter { $0.isSelectable && $0.path != folder.path } ?? []) { target in
                    Button {
                        close()
                        Task { for header in messages { await mail.move(folder, header: header, to: target) } }
                    } label: {
                        Label(FolderRow.title(target), systemImage: FolderRow.icon(target))
                    }
                }
            } label: {
                Label("Bewegen", systemImage: "folder")
            }
        }
        ToolbarItem(placement: .bottomBar) {
            Menu {
                Button {
                    if let account { compose(MessageActions.reply(latest, message: loaded, all: false, account: account, folder: folder, mail: mail)) }
                } label: { Label("Antworten", systemImage: "arrowshape.turn.up.left") }
                Button {
                    if let account { compose(MessageActions.reply(latest, message: loaded, all: true, account: account, folder: folder, mail: mail)) }
                } label: { Label("Allen antworten", systemImage: "arrowshape.turn.up.left.2") }
                Button {
                    if let account { compose(MessageActions.forward(latest, message: loaded, account: account, folder: folder, mail: mail)) }
                } label: { Label("Weiterleiten", systemImage: "arrowshape.turn.up.right") }
                Divider()
                Button {
                    Task { await mail.setFlagged(folder, header: latest, flagged: !latest.isFlagged) }
                } label: {
                    Label(latest.isFlagged ? "Markierung entfernen" : "Markieren", systemImage: "flag")
                }
                Button {
                    close()
                    Task { await mail.setSeen(folder, header: latest, seen: false) }
                } label: {
                    Label("Als ungelesen markieren", systemImage: "envelope.badge")
                }
            } label: {
                Label("Antworten", systemImage: "arrowshape.turn.up.left")
            }
            .disabled(loaded == nil)
        }
        ToolbarItem(placement: .bottomBar) {
            Button {
                if let account { compose(.new(account: account)) }
            } label: {
                Label("Verfassen", systemImage: "square.and.pencil")
            }
        }
    }
}

/// What OpenPGP found out about the message: small chips when all is well,
/// a clear explanation when something is wrong.
struct SecurityBanner: View {
    @Environment(KeyStore.self) private var keys
    let security: MessageSecurity
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = security.decryptionError {
                problem("lock.slash.fill", "Entschlüsselung fehlgeschlagen", error)
            }
            switch security.signature {
            case .invalid:
                problem("xmark.seal.fill", "Ungültige Signatur",
                        "Die E-Mail wurde verändert oder nicht mit dem bekannten Schlüssel signiert.")
            case .unknownKey(let keyID):
                problem("questionmark.diamond.fill", "Signatur nicht prüfbar",
                        "Der öffentliche Schlüssel \(keyID) ist nicht in deinem Schlüsselbund.", tint: .orange)
            default:
                EmptyView()
            }
            if hasChips {
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        if security.wasEncrypted, security.decryptionError == nil {
                            chip("lock.fill", "Verschlüsselt")
                        }
                        if case .valid = security.signature {
                            chip("checkmark.seal.fill", "Signatur gültig")
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Zeigt Details zu Verschlüsselung und Signatur")
                if expanded {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(explanation)
                            .font(.footnote)
                        if case .valid(let fingerprint) = security.signature {
                            // Groups of four, like the key list; never split inside a group.
                            Text(PGPKeyInfo.groupedFingerprint(fingerprint))
                                .font(.caption.monospaced())
                        }
                    }
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var hasChips: Bool {
        if security.wasEncrypted, security.decryptionError == nil { return true }
        if case .valid = security.signature { return true }
        return false
    }

    private var explanation: String {
        var parts: [String] = []
        if security.wasEncrypted { parts.append("Mit deinem privaten Schlüssel entschlüsselt.") }
        if case .valid(let fingerprint) = security.signature {
            parts.append("Signiert von \(keys.ownerName(fingerprint: fingerprint)). Fingerabdruck:")
        }
        return parts.joined(separator: "\n")
    }

    private func chip(_ icon: String, _ title: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.green.opacity(0.13), in: Capsule())
    }

    private func problem(_ icon: String, _ title: String, _ detail: String, tint: Color = .red) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.body)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button("Kopieren", systemImage: "doc.on.doc") { UIPasteboard.general.string = "\(title): \(detail)" }
        }
    }
}
