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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if accounts.accounts.count > 1 {
                        Picker("Von", selection: $draft.accountID) {
                            ForEach(accounts.accounts) { Text($0.email).tag($0.id) }
                        }
                    }
                    addressField("An", text: $draft.to, field: .to)
                    if showCopies {
                        addressField("Kopie", text: $draft.cc, field: .cc)
                        addressField("Blindkopie", text: $draft.bcc, field: .bcc)
                    } else {
                        Button("Kopie / Blindkopie hinzufügen") { showCopies = true }
                            .font(.footnote)
                    }
                    TextField("Betreff", text: $draft.subject)
                        .focused($focus, equals: .subject)
                }

                Section {
                    Toggle(isOn: $sign) {
                        Label("Signieren", systemImage: "checkmark.seal")
                    }
                    .disabled(personalKey == nil)
                    Toggle(isOn: $encrypt) {
                        Label("Verschlüsseln", systemImage: encrypt ? "lock.fill" : "lock.open")
                    }
                    .disabled(personalKey == nil)
                    if encrypt {
                        Toggle(isOn: $protectSubject) {
                            Label("Betreff verschlüsseln", systemImage: "text.badge.checkmark")
                        }
                    }
                    if personalKey != nil {
                        Toggle(isOn: $attachOwnKey) {
                            Label("Meinen öffentlichen Schlüssel anhängen", systemImage: "key")
                        }
                    }
                } header: {
                    Text("OpenPGP")
                } footer: {
                    securityFooter
                }

                Section("Nachricht") {
                    TextEditor(text: $draft.body)
                        .frame(minHeight: 260)
                        .focused($focus, equals: .body)
                }

                Section("Anhänge") {
                    ForEach(draft.attachments) { attachment in
                        HStack {
                            Image(systemName: "paperclip")
                            Text(attachment.filename).lineLimit(1)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                    .onDelete { draft.attachments.remove(atOffsets: $0) }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Datei anhängen", systemImage: "plus")
                    }
                }
            }
            .navigationTitle(draft.subject.isEmpty ? "Neue Nachricht" : draft.subject)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button {
                            Task { await send() }
                        } label: {
                            Label("Senden", systemImage: encrypt ? "lock.fill" : "paperplane.fill")
                        }
                        .disabled(!canSend)
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                attach(result)
            }
            .alert("Senden fehlgeschlagen", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
            .interactiveDismissDisabled(isSending || !draft.body.isEmpty)
            .onAppear(perform: applyDefaults)
            .onChange(of: draft.accountID) {
                didSetDefaults = false
                applyDefaults()
            }
        }
    }

    private func addressField(_ label: String, text: Binding<String>, field: Field) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label + ":")
                .foregroundStyle(.secondary)
            TextField("name@example.org", text: text, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .focused($focus, equals: field)
        }
    }

    @ViewBuilder
    private var securityFooter: some View {
        if personalKey == nil {
            Text("Für dieses Konto ist noch kein eigener Schlüssel vorhanden. Lege ihn unter Einstellungen › Schlüsselverwaltung an.")
        } else if encrypt, !missingKeys.isEmpty {
            Text("Kein öffentlicher Schlüssel für: \(missingKeys.map(\.email).joined(separator: ", ")). Ohne Schlüssel aller Empfänger kann nicht verschlüsselt werden.")
                .foregroundStyle(.red)
        } else if encrypt {
            Text(protectSubject
                 ? "Text, Anhänge und Betreff werden Ende-zu-Ende verschlüsselt. Auf dem Server steht als Betreff nur „...“; Absender und Empfänger bleiben sichtbar."
                 : "Text und Anhänge werden Ende-zu-Ende verschlüsselt. Betreff, Absender und Empfänger bleiben sichtbar.")
        } else if !recipients.isEmpty, missingKeys.isEmpty {
            Text("Für alle Empfänger sind Schlüssel vorhanden – Verschlüsselung ist möglich.")
        }
    }

    private func applyDefaults() {
        guard !didSetDefaults, let account else { return }
        didSetDefaults = true
        let hasKey = personalKey != nil
        sign = hasKey && (account.signByDefault || draft.preferEncryption)
        encrypt = hasKey && (account.encryptByDefault || draft.preferEncryption)
        showCopies = showCopies || !draft.cc.isEmpty || !draft.bcc.isEmpty
        if draft.to.isEmpty { focus = .to }
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
