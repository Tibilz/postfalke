import SwiftUI
import UniformTypeIdentifiers
import MailEngine

struct ComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountStore.self) private var accounts
    @Environment(MailStore.self) private var mail
    @Environment(KeyStore.self) private var keys

    @State var draft: ComposeDraft
    @State private var sign = false
    @State private var encrypt = false
    @State private var attachOwnKey = false
    @AppStorage("protectSubject") private var protectSubject = true
    @State private var showCopies = false
    @State private var showImporter = false
    @State private var isSending = false
    @State private var error: String?
    @State private var didSetDefaults = false
    @State private var confirmDiscard = false
    @FocusState private var focus: Field?

    private enum Field { case to, cc, bcc, subject, body }

    private var account: Account? { accounts.account(draft.accountID) }
    private var personalKey: PGPKeyInfo? { account.flatMap { keys.personalKey(for: $0) } }

    private var recipients: [MailAddress] {
        HeaderCodec.parseAddressList(draft.to) + HeaderCodec.parseAddressList(draft.cc) + HeaderCodec.parseAddressList(draft.bcc)
    }

    /// Recipients for whom no usable public key is known.
    private var missingKeys: [MailAddress] {
        recipients.filter { keys.encryptionKey(for: $0.email) == nil }
    }

    private var canEncrypt: Bool {
        personalKey != nil && !recipients.isEmpty && missingKeys.isEmpty
    }

    private var canSend: Bool {
        !recipients.isEmpty && !isSending && (!encrypt || canEncrypt) && (!sign || personalKey != nil)
    }

    private var hasContent: Bool {
        !draft.to.isEmpty || !draft.subject.isEmpty || !draft.attachments.isEmpty
            || !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    row("An:") {
                        addressField($draft.to, field: .to, id: "compose.to")
                        if encrypt, !recipients.isEmpty {
                            Image(systemName: missingKeys.isEmpty ? "lock.fill" : "lock.open.trianglebadge.exclamationmark")
                                .foregroundStyle(missingKeys.isEmpty ? .green : .orange)
                                .accessibilityLabel(missingKeys.isEmpty ? "Schlüssel für alle Empfänger vorhanden" : "Schlüssel fehlen")
                        }
                    }
                    separator

                    if showCopies {
                        row("Kopie:") { addressField($draft.cc, field: .cc, id: "compose.cc") }
                        separator
                        row("Blindkopie:") { addressField($draft.bcc, field: .bcc, id: "compose.bcc") }
                        separator
                        row("Von:") { fromPicker }
                        separator
                    } else {
                        Button {
                            withAnimation(.snappy) { showCopies = true }
                        } label: {
                            row("Kopie/Blindkopie, Von:") {
                                Text(account?.email ?? "")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                        separator
                    }

                    row("Betreff:") {
                        TextField("", text: $draft.subject)
                            .focused($focus, equals: .subject)
                            .submitLabel(.next)
                            .onSubmit { focus = .body }
                            .accessibilityIdentifier("compose.subject")
                    }
                    separator

                    securityRow
                    separator

                    if !draft.attachments.isEmpty {
                        attachmentStrip
                        separator
                    }

                    TextEditor(text: $draft.body)
                        .focused($focus, equals: .body)
                        .font(.body)
                        .scrollDisabled(true)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 320)
                        .padding(.horizontal, 11)
                        .padding(.top, 6)
                        .accessibilityIdentifier("compose.body")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(draft.subject.isEmpty ? "Neue E-Mail" : draft.subject)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        if hasContent { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Anhang hinzufügen", systemImage: "paperclip")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button {
                            Task { await send() }
                        } label: {
                            Label("Senden", systemImage: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                        .disabled(!canSend)
                        .tint(encrypt ? .green : .accentColor)
                    }
                }
            }
            .confirmationDialog("E-Mail verwerfen?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Entwurf löschen", role: .destructive) { dismiss() }
            } message: {
                Text("Entwürfe werden noch nicht gespeichert.")
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                attach(result)
            }
            .alert("Senden fehlgeschlagen", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("Fehler kopieren") { UIPasteboard.general.string = error }
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
            .interactiveDismissDisabled(isSending || hasContent)
            .onAppear(perform: applyDefaults)
            .onChange(of: draft.accountID) {
                didSetDefaults = false
                applyDefaults()
            }
        }
    }

    // MARK: Rows

    private var separator: some View {
        Divider().padding(.leading, 16)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
                .fixedSize()
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func addressField(_ text: Binding<String>, field: Field, id: String) -> some View {
        TextField("", text: text, axis: .vertical)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .focused($focus, equals: field)
            .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private var fromPicker: some View {
        if accounts.accounts.count > 1 {
            Menu {
                Picker("Von", selection: $draft.accountID) {
                    ForEach(accounts.accounts) { Text($0.email).tag($0.id) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(account?.email ?? "")
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
            }
        } else {
            Text(account?.email ?? "")
                .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
    }

    private var securityRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if personalKey != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ChipToggle(title: "Signieren", systemImage: "checkmark.seal", isOn: $sign)
                            .accessibilityIdentifier("compose.sign")
                        ChipToggle(title: "Verschlüsseln", systemImage: encrypt ? "lock.fill" : "lock.open",
                                   isOn: $encrypt, tint: .green)
                            .accessibilityIdentifier("compose.encrypt")
                        if encrypt {
                            ChipToggle(title: "Betreff verschlüsseln", systemImage: "text.badge.checkmark",
                                       isOn: $protectSubject, tint: .green)
                                .accessibilityIdentifier("compose.protectSubject")
                        }
                        ChipToggle(title: "Schlüssel anhängen", systemImage: "key", isOn: $attachOwnKey)
                            .accessibilityIdentifier("compose.attachKey")
                    }
                    .padding(.horizontal, 16)
                }
            }
            if let note = securityNote {
                Text(note.text)
                    .font(.caption)
                    .foregroundStyle(note.isWarning ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 10)
    }

    private var securityNote: (text: String, isWarning: Bool)? {
        if personalKey == nil {
            return ("OpenPGP ist aus: Für dieses Konto gibt es noch keinen eigenen Schlüssel (Einstellungen › Schlüsselverwaltung).", false)
        }
        if encrypt, !missingKeys.isEmpty {
            return ("Kein öffentlicher Schlüssel für \(missingKeys.map(\.email).joined(separator: ", ")). So kann nicht verschlüsselt gesendet werden.", true)
        }
        if encrypt {
            return (protectSubject
                    ? "Text, Anhänge und Betreff werden Ende-zu-Ende verschlüsselt. Absender und Empfänger bleiben sichtbar."
                    : "Text und Anhänge werden Ende-zu-Ende verschlüsselt. Betreff, Absender und Empfänger bleiben sichtbar.", false)
        }
        if !recipients.isEmpty, missingKeys.isEmpty {
            return ("Für alle Empfänger sind Schlüssel vorhanden – du kannst verschlüsseln.", false)
        }
        return nil
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.fill").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(attachment.filename).font(.footnote.weight(.medium)).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Button {
                            draft.attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(attachment.filename) entfernen")
                    }
                    .frame(maxWidth: 220, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: Behaviour

    private func applyDefaults() {
        guard !didSetDefaults, let account else { return }
        didSetDefaults = true
        let hasKey = personalKey != nil
        sign = hasKey && (account.signByDefault || draft.preferEncryption)
        encrypt = hasKey && (account.encryptByDefault || draft.preferEncryption)
        showCopies = showCopies || !draft.cc.isEmpty || !draft.bcc.isEmpty
        focus = draft.to.isEmpty ? .to : .body
    }

    private func attach(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            draft.attachments.append(MailAttachment(filename: url.lastPathComponent, mimeType: type, data: data))
        }
    }

    private func send() async {
        guard let account else { return }
        isSending = true
        defer { isSending = false }

        var message = OutgoingMessage(from: account.address)
        message.to = HeaderCodec.parseAddressList(draft.to)
        message.cc = HeaderCodec.parseAddressList(draft.cc)
        message.bcc = HeaderCodec.parseAddressList(draft.bcc)
        message.subject = draft.subject
        message.body = draft.body
        message.attachments = draft.attachments
        message.inReplyTo = draft.inReplyTo
        message.references = draft.references

        var options: PGPSendOptions?
        if let key = personalKey {
            message.autocryptKey = key.publicArmored
            if attachOwnKey {
                message.attachments.append(MailAttachment(
                    filename: "OpenPGP_0x\(key.keyID).asc", mimeType: "application/pgp-keys",
                    data: Data(key.publicArmored.utf8)))
            }
            if sign || encrypt {
                // Encrypt to every recipient and to ourselves, so the sent copy stays readable.
                let recipientKeys = encrypt
                    ? message.allRecipients.compactMap { keys.encryptionKey(for: $0.email)?.publicArmored } + [key.publicArmored]
                    : []
                options = PGPSendOptions(sign: sign, encrypt: encrypt,
                                         signer: keys.secret(for: key.fingerprint),
                                         recipientKeys: recipientKeys,
                                         protectSubject: encrypt && protectSubject)
            }
        }

        do {
            try await mail.send(message, pgp: options, account: account)
            if let answering = draft.answering {
                await mail.markAnswered(answering.folder, uid: answering.uid)
            }
            dismiss()
        } catch {
            self.error = MailStore.describe(error)
        }
    }
}
