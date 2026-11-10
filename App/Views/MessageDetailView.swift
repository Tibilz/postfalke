import SwiftUI
import QuickLook
import MailEngine

struct MessageDetailView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(MailStore.self) private var mail
    @Environment(KeyStore.self) private var keys

    let folder: FolderKey
    let header: MessageHeader
    var compose: (ComposeDraft) -> Void
    var close: () -> Void

    @State private var message: ProcessedMessage?
    @State private var loadError: String?
    @State private var allowRemote = false
    @State private var bodyHeight: CGFloat = 60
    @State private var preview: URL?
    @State private var notice: String?
    @State private var showDetails = false

    private var subject: String {
        let text = message?.protectedSubject ?? mail.subject(folder, header: header)
        return text.isEmpty ? "(kein Betreff)" : text
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerBlock
                if let message {
                    SecurityBanner(security: message.security)
                    keyOffer(message)
                    if !message.content.attachments.isEmpty {
                        attachments(message.content.attachments)
                    }
                    Divider()
                    content(message)
                } else if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Button("Erneut versuchen") { Task { await load() } }
                } else {
                    HStack { Spacer(); ProgressView("Nachricht wird geladen …"); Spacer() }
                        .padding(.top, 40)
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task { await load() }
        .quickLookPreview($preview)
        .alert("OpenPGP", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: Loading

    private func load() async {
        loadError = nil
        do {
            let raw = try await mail.rawMessage(folder, uid: header.uid)
            let context = keys.context
            message = await Task.detached(priority: .userInitiated) {
                MessageProcessor.process(raw: raw, context: context)
            }.value
            if let protected = message?.protectedSubject, header.isEncrypted {
                mail.rememberSubject(protected, folder, uid: header.uid)
            }
            await mail.setSeen(folder, header: header, seen: true)
        } catch {
            loadError = MailStore.describe(error)
        }
    }

    // MARK: Header

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(subject)
                .font(.title3.bold())
                .textSelection(.enabled)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(header.from.first?.displayName ?? "(unbekannter Absender)")
                        .font(.headline)
                    if showDetails {
                        addressLine("Von", header.from)
                        addressLine("An", header.to)
                        addressLine("Kopie", header.cc)
                    } else {
                        Text("An: " + (header.to + header.cc).map(\.displayName).joined(separator: ", "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text((header.date ?? header.internalDate)?.formatted(date: .abbreviated, time: .shortened) ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { showDetails.toggle() } }
        }
    }

    @ViewBuilder
    private func addressLine(_ label: String, _ list: [MailAddress]) -> some View {
        if !list.isEmpty {
            Text("\(label): " + list.map(\.formatted).joined(separator: ", "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ message: ProcessedMessage) -> some View {
        if let html = message.content.htmlWithInlineImages {
            if !allowRemote, MessageHTML.hasRemoteContent(html) {
                Button {
                    allowRemote = true
                } label: {
                    Label("Externe Inhalte wurden blockiert – jetzt laden", systemImage: "photo")
                        .font(.footnote)
                }
            }
            HTMLView(html: MessageHTML.page(html: html), allowRemoteContent: allowRemote, height: $bodyHeight)
                .frame(height: bodyHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if let plain = message.content.plain, !plain.isEmpty {
            HTMLView(html: MessageHTML.page(plain: plain), allowRemoteContent: false, height: $bodyHeight)
                .frame(height: bodyHeight)
        } else if message.security.decryptionError == nil {
            Text("Diese Nachricht hat keinen Textinhalt.")
                .foregroundStyle(.secondary)
        }
    }

    private func attachments(_ list: [MailAttachment]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(list) { attachment in
                    Button {
                        open(attachment)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: attachment.isPGPKey ? "key" : "paperclip")
                            VStack(alignment: .leading) {
                                Text(attachment.filename).lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.footnote)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
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

    // MARK: Keys offered by the sender

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
                Label("Öffentlichen Schlüssel des Absenders importieren", systemImage: "key.viewfinder")
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Toolbar

    private var account: Account? { accounts.account(folder.accountID) }

    private var replyText: String {
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

    private func reply(all: Bool) {
        guard let account else { return }
        compose(.reply(to: header, subject: subject, text: replyText,
                       wasEncrypted: message?.security.wasEncrypted ?? false,
                       all: all, account: account, folder: folder))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button {
                close()
                Task { await mail.delete(folder, header: header) }
            } label: {
                Label("Löschen", systemImage: "trash")
            }
            Spacer()
            Menu {
                ForEach(mail.folders[folder.accountID]?.filter { $0.isSelectable && $0.path != folder.path } ?? []) { target in
                    Button {
                        close()
                        Task { await mail.move(folder, header: header, to: target) }
                    } label: {
                        Label(FolderRow.title(target), systemImage: FolderRow.icon(target))
                    }
                }
            } label: {
                Label("Verschieben", systemImage: "folder")
            }
            Spacer()
            Button {
                Task { await mail.setFlagged(folder, header: header, flagged: !header.isFlagged) }
            } label: {
                Label("Markieren", systemImage: header.isFlagged ? "star.fill" : "star")
            }
            Spacer()
            Menu {
                Button { reply(all: false) } label: { Label("Antworten", systemImage: "arrowshape.turn.up.left") }
                Button { reply(all: true) } label: { Label("Allen antworten", systemImage: "arrowshape.turn.up.left.2") }
                Button {
                    guard let account else { return }
                    compose(.forward(header, subject: subject, text: replyText,
                                     attachments: message?.content.attachments ?? [],
                                     wasEncrypted: message?.security.wasEncrypted ?? false, account: account))
                } label: {
                    Label("Weiterleiten", systemImage: "arrowshape.turn.up.right")
                }
                Divider()
                Button {
                    close()
                    Task { await mail.setSeen(folder, header: header, seen: false) }
                } label: {
                    Label("Als ungelesen markieren", systemImage: "envelope.badge")
                }
            } label: {
                Label("Antworten", systemImage: "arrowshape.turn.up.left")
            } primaryAction: {
                reply(all: false)
            }
            .disabled(message == nil)
        }
    }
}

/// Shows what OpenPGP found out about the message.
struct SecurityBanner: View {
    @Environment(KeyStore.self) private var keys
    let security: MessageSecurity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = security.decryptionError {
                row("lock.slash", .red, "Entschlüsselung fehlgeschlagen", error)
            } else if security.wasEncrypted {
                row("lock.fill", .green, "Verschlüsselte Nachricht", "Mit deinem privaten Schlüssel entschlüsselt.")
            }
            switch security.signature {
            case .none:
                EmptyView()
            case .valid(let fingerprint):
                row("checkmark.seal.fill", .green, "Gültige Signatur", keys.ownerName(fingerprint: fingerprint))
            case .invalid:
                row("xmark.seal.fill", .red, "Ungültige Signatur",
                    "Die Nachricht wurde verändert oder nicht mit dem bekannten Schlüssel signiert.")
            case .unknownKey(let keyID):
                row("questionmark.diamond", .orange, "Signatur nicht prüfbar",
                    "Der öffentliche Schlüssel \(keyID) ist nicht im Schlüsselbund.")
            }
        }
    }

    private func row(_ icon: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
