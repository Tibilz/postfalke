import SwiftUI
import UniformTypeIdentifiers
import MailEngine

struct ComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountStore.self) private var accounts
    @Environment(MailStore.self) private var mail
    @Environment(KeyStore.self) private var keys
    @Environment(Outbox.self) private var outbox

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
    @State private var showSchedule = false
    @State private var scheduleDate = Date().addingTimeInterval(3600)
    @State private var isSavingDraft = false
    @State private var autosave: Task<Void, Never>?
    /// Set when the sheet closes, so a pending autosave does not bring the draft back.
    @State private var isClosing = false
    /// Incremented to move the cursor into the text (Return in the subject).
    @State private var bodyFocusRequest = 0
    @State private var isLookingUpKeys = false
    @State private var lookupResult: String?
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

    private var hasContent: Bool { draft.hasContent }

    private var currentOptions: DraftOptions {
        DraftOptions(sign: sign, encrypt: encrypt, protectSubject: protectSubject, attachOwnKey: attachOwnKey)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    row("An:") {
                        RecipientField(text: $draft.to, identifier: "compose.to", showKeyState: encrypt,
                                       autofocus: draft.to.isEmpty)
                        ContactPickerButton { add($0, to: \.to) }
                        if encrypt, !recipients.isEmpty {
                            Image(systemName: missingKeys.isEmpty ? "lock.fill" : "lock.open.trianglebadge.exclamationmark")
                                .foregroundStyle(missingKeys.isEmpty ? .green : .orange)
                                .accessibilityLabel(missingKeys.isEmpty ? "Schlüssel für alle Empfänger vorhanden" : "Schlüssel fehlen")
                        }
                    }
                    separator

                    if showCopies {
                        row("Kopie:") {
                            RecipientField(text: $draft.cc, identifier: "compose.cc", showKeyState: encrypt)
                            ContactPickerButton { add($0, to: \.cc) }
                        }
                        separator
                        row("Blindkopie:") {
                            RecipientField(text: $draft.bcc, identifier: "compose.bcc", showKeyState: encrypt)
                            ContactPickerButton { add($0, to: \.bcc) }
                        }
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
                            .onSubmit { bodyFocusRequest += 1 }
                            .accessibilityIdentifier("compose.subject")
                    }
                    separator

                    securityRow
                    separator

                    if !draft.attachments.isEmpty {
                        attachmentStrip
                        separator
                    }

                    BodyEditor(text: $draft.body, startAtTop: draft.body.hasPrefix("\n"),
                               autofocus: !draft.to.isEmpty, focusRequest: bodyFocusRequest)
                        .frame(minHeight: 320, alignment: .top)
                        .padding(.horizontal, 11)
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
                    if isSending || isSavingDraft {
                        ProgressView()
                    } else {
                        // Tap sends, a long press offers "Später senden".
                        Menu {
                            Button { queue(at: nil) } label: { Label("Jetzt senden", systemImage: "paperplane") }
                            if let tonight = Self.tonight {
                                Button { queue(at: tonight) } label: { Label("Heute, 21:00", systemImage: "moon") }
                            }
                            Button { queue(at: Self.tomorrowMorning) } label: { Label("Morgen, 8:00", systemImage: "sunrise") }
                            Button { showSchedule = true } label: { Label("Später senden …", systemImage: "clock") }
                        } label: {
                            Label("Senden", systemImage: "arrow.up.circle.fill")
                                .font(.title2)
                        } primaryAction: {
                            queue(at: nil)
                        }
                        .disabled(!canSend)
                        .tint(encrypt ? .green : .accentColor)
                    }
                }
            }
            .confirmationDialog("Entwurf", isPresented: $confirmDiscard) {
                Button("Entwurf sichern") { Task { await saveDraftAndClose() } }
                Button("Entwurf löschen", role: .destructive) { discard() }
                Button("Weiter bearbeiten", role: .cancel) {}
            } message: {
                Text(MailStore.encryptDrafts && personalKey != nil
                     ? "Der Entwurf wird verschlüsselt im Ordner „Entwürfe“ gesichert."
                     : "Der Entwurf wird im Ordner „Entwürfe“ gesichert.")
            }
            .sheet(isPresented: $showSchedule) { scheduleSheet }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                attach(result)
            }
            .alert("Entwurf nicht gesichert", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("Fehler kopieren") { UIPasteboard.general.string = error }
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
            .interactiveDismissDisabled(isSending || hasContent)
            .onAppear(perform: applyDefaults)
            .onChange(of: draft.accountID) {
                didSetDefaults = false
                draft.options = nil
                applyDefaults()
            }
            .onChange(of: currentOptions) { draft.options = currentOptions }
            .onChange(of: draft) { scheduleAutosave() }
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

    /// Adds an address picked from the contacts to a recipient line.
    private func add(_ address: MailAddress, to field: WritableKeyPath<ComposeDraft, String>) {
        let current = draft[keyPath: field].trimmingCharacters(in: .whitespaces)
        let entry = HeaderCodec.formatAddress(address)
        draft[keyPath: field] = current.isEmpty ? entry : current + ", " + entry
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
            if encrypt, !missingKeys.isEmpty {
                Button {
                    Task { await lookUpMissingKeys() }
                } label: {
                    HStack(spacing: 6) {
                        if isLookingUpKeys { ProgressView().controlSize(.small) } else { Image(systemName: "magnifyingglass") }
                        Text("Schlüssel online suchen")
                    }
                    .font(.footnote.weight(.medium))
                }
                .disabled(isLookingUpKeys)
                .padding(.horizontal, 16)
            }
            if let lookupResult {
                Text(lookupResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
            if let key = personalKey, keys.expiresSoon(key), let expires = key.expires {
                Label("Dein Schlüssel läuft am \(expires.formatted(date: .abbreviated, time: .omitted)) ab. Verlängere ihn unter Einstellungen › Schlüsselverwaltung.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
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
        if let options = draft.options {
            sign = hasKey && options.sign
            encrypt = hasKey && options.encrypt
            protectSubject = options.protectSubject
            attachOwnKey = hasKey && options.attachOwnKey
        } else {
            sign = hasKey && (account.signByDefault || draft.preferEncryption)
            encrypt = hasKey && (account.encryptByDefault || draft.preferEncryption)
        }
        showCopies = showCopies || !draft.cc.isEmpty || !draft.bcc.isEmpty
        // With recipients already filled in (reply), the text view focuses itself.
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

    /// Asks the recipients' providers and keys.openpgp.org (only on request: it reveals the addresses).
    private func lookUpMissingKeys() async {
        isLookingUpKeys = true
        defer { isLookingUpKeys = false }
        let wanted = missingKeys.map { $0.email.lowercased() }
        let found = await keys.discover(wanted)
        let missing = wanted.filter { found[$0] == nil }
        lookupResult = missing.isEmpty
            ? "Alle Schlüssel gefunden. Vergleiche Fingerabdrücke, wenn es auf Vertrauen ankommt."
            : "Nicht gefunden: \(missing.joined(separator: ", "))"
    }

    // MARK: Sending and drafts

    private static var tonight: Date? {
        let date = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: .now)
        return date.flatMap { $0.timeIntervalSinceNow > 30 * 60 ? $0 : nil }
    }

    private static var tomorrowMorning: Date {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        return Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    /// Hands the message to the outbox: it leaves after the undo window or at `date`.
    private func queue(at date: Date?) {
        guard canSend else { return }
        isClosing = true
        autosave?.cancel()
        var final = draft
        final.options = currentOptions
        outbox.enqueue(final, at: date)
        LocalDrafts.remove(draft.id)
        dismiss()
    }

    private func scheduleAutosave() {
        autosave?.cancel()
        guard !isClosing else { return }
        let snapshot = draft
        autosave = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, !isClosing else { return }
            LocalDrafts.save(snapshot)
        }
    }

    private func saveDraftAndClose() async {
        isSavingDraft = true
        defer { isSavingDraft = false }
        autosave?.cancel()
        draft.options = currentOptions
        do {
            let messageID = try await mail.saveDraft(draft, keys: keys)
            isClosing = true
            draft.serverMessageID = messageID
            autosave?.cancel()
            LocalDrafts.remove(draft.id)
            dismiss()
        } catch {
            // Keep it on the device; the outbox list offers it again.
            LocalDrafts.save(draft)
            self.error = MailStore.describe(error) + "\n\nDer Entwurf bleibt auf diesem Gerät gespeichert (Postausgang)."
        }
    }

    private func discard() {
        isClosing = true
        autosave?.cancel()
        LocalDrafts.remove(draft.id)
        if let messageID = draft.serverMessageID {
            let account = draft.accountID
            Task { await mail.deleteServerDraft(accountID: account, messageID: messageID) }
        }
        dismiss()
    }

    private var scheduleSheet: some View {
        NavigationStack {
            Form {
                DatePicker("Senden am", selection: $scheduleDate, in: Date().addingTimeInterval(60)...,
                           displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
            }
            .navigationTitle("Später senden")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { showSchedule = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Planen") {
                        showSchedule = false
                        queue(at: scheduleDate)
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
}

/// The message text: a plain UITextView that grows with its content.
/// In replies the cursor starts above the quote, as in Mail. The text is only
/// pushed into the view when it changed elsewhere, so typing is never disturbed.
private struct BodyEditor: UIViewRepresentable {
    @Binding var text: String
    let startAtTop: Bool
    var autofocus = false
    var focusRequest = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 24, right: 0)
        view.textContainer.lineFragmentPadding = 5
        view.autocapitalizationType = .sentences
        view.delegate = context.coordinator
        view.text = text
        view.accessibilityIdentifier = "compose.body"
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if autofocus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                view.becomeFirstResponder()
                if startAtTop { view.selectedRange = NSRange(location: 0, length: 0) }
            }
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        if context.coordinator.handledFocusRequest != focusRequest {
            context.coordinator.handledFocusRequest = focusRequest
            DispatchQueue.main.async { view.becomeFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: fitting.height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: BodyEditor
        var handledFocusRequest: Int
        private var placedCursor = false

        init(_ parent: BodyEditor) {
            self.parent = parent
            handledFocusRequest = parent.focusRequest
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            // First time in a reply: write above the quote.
            guard !placedCursor else { return }
            placedCursor = true
            if parent.startAtTop {
                DispatchQueue.main.async { textView.selectedRange = NSRange(location: 0, length: 0) }
            }
        }
    }
}
