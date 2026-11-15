import SwiftUI
import UniformTypeIdentifiers
import MailEngine

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountStore.self) private var accounts
    @Environment(KeyStore.self) private var keys
    @Environment(ContactKeySync.self) private var contacts
    @AppStorage(BackgroundRefresh.notifyKey) private var notifyNewMail = false
    @AppStorage(Outbox.undoDelayKey) private var undoDelay = 10.0
    @AppStorage(MailStore.encryptDraftsKey) private var encryptDrafts = true
    @AppStorage(MailStore.threadingKey) private var groupConversations = true
    @AppStorage(ContactDirectory.useSystemContactsKey) private var useSystemContacts = false
    @Environment(ContactDirectory.self) private var directory
    @State private var permissionDenied = false
    @AppStorage(BackgroundRefresh.lastRunKey) private var lastBackgroundRun = 0.0

    var body: some View {
        NavigationStack {
            List {
                Section("Konten") {
                    ForEach(accounts.accounts) { account in
                        NavigationLink {
                            AccountEditView(account: account)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(account.email)
                                Text(account.imap.host).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    NavigationLink {
                        AccountEditView(account: nil)
                    } label: {
                        Label("Konto hinzufügen", systemImage: "plus")
                    }
                }
                Section {
                    NavigationLink {
                        KeyListView()
                    } label: {
                        HStack {
                            Label("Schlüsselverwaltung", systemImage: "key")
                            Spacer()
                            Text("\(keys.keys.count)").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("OpenPGP")
                } footer: {
                    Text("Private Schlüssel und Passwörter liegen im Schlüsselbund dieses Geräts und werden nicht synchronisiert.")
                }
                Section {
                    Toggle("iOS-Kontakte für Vorschläge", isOn: Binding(
                        get: { useSystemContacts },
                        set: { wanted in
                            if wanted {
                                Task { useSystemContacts = await directory.requestSystemContacts() }
                            } else {
                                useSystemContacts = false
                                directory.reloadAddressBook()
                            }
                        }))
                    NavigationLink {
                        CardDAVSettingsView()
                    } label: {
                        HStack {
                            Label("Schlüssel aus Kontakten", systemImage: "person.crop.rectangle.stack")
                            Spacer()
                            Text(contacts.isConfigured ? "\(keys.bindings.count)" : "Aus").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Kontakte")
                } footer: {
                    Text("Beim Schreiben schlägt Postfalke Adressen vor: Empfänger früherer E-Mails, Absender, deine CardDAV-Kontakte (inklusive Schlüsseln aus dem KEY-Feld) und auf Wunsch die iOS-Kontakte. Über ⊕ wählst du einzelne iOS-Kontakte auch ohne diese Freigabe.")
                }
                Section {
                    Picker("Senden widerrufen", selection: $undoDelay) {
                        Text("Aus").tag(0.0)
                        Text("5 Sekunden").tag(5.0)
                        Text("10 Sekunden").tag(10.0)
                        Text("20 Sekunden").tag(20.0)
                        Text("30 Sekunden").tag(30.0)
                    }
                    Toggle("Entwürfe verschlüsseln", isOn: $encryptDrafts)
                    Toggle("Nach Konversation ordnen", isOn: $groupConversations)
                } header: {
                    Text("Verfassen")
                } footer: {
                    Text("Gesendete E-Mails warten so lange, bis du sie noch zurückholen kannst. Entwürfe werden mit deinem eigenen Schlüssel verschlüsselt, sofern du einen hast.")
                }
                Section {
                    Toggle("Mitteilung bei neuer Post", isOn: $notifyNewMail)
                        .onChange(of: notifyNewMail) {
                            guard notifyNewMail else { return }
                            Task {
                                if !(await BackgroundRefresh.requestPermission()) {
                                    notifyNewMail = false
                                    permissionDenied = true
                                }
                            }
                        }
                    LabeledContent("Letzte Hintergrundprüfung",
                                   value: lastBackgroundRun > 0
                                       ? Date(timeIntervalSince1970: lastBackgroundRun).formatted(date: .abbreviated, time: .shortened)
                                       : "noch nie")
                } header: {
                    Text("Im Hintergrund")
                } footer: {
                    Text("Postfalke prüft die Posteingänge, wenn iOS der App Hintergrundzeit gibt – meist alle 15 Minuten bis wenige Stunden. Sofortige Zustellung (Push) ist ohne eigenen Server nicht möglich.")
                }
                Section("Über") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    LabeledContent("Kryptografie", value: "rPGP (OpenPGP, RFC 9580/4880)")
                }
            }
            .alert("Mitteilungen sind für Postfalke in den iOS-Einstellungen ausgeschaltet.", isPresented: $permissionDenied) {
                Button("OK", role: .cancel) {}
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Keys

struct KeyListView: View {
    @Environment(KeyStore.self) private var keys

    @State private var showGenerate = false
    @State private var showFileImporter = false
    @State private var showBitwarden = false
    @State private var flow = KeyImportFlow()
    @State private var showLookup = false
    @State private var lookupAddress = ""
    @State private var isLookingUp = false

    var body: some View {
        List {
            Section {
                ForEach(keys.secretKeys) { KeyRow(key: $0) }
                if keys.secretKeys.isEmpty {
                    Text("Noch kein eigener Schlüssel. Erzeuge ein neues Schlüsselpaar oder importiere dein bestehendes – aus einer Datei, aus Bitwarden oder aus Thunderbird (Extras › OpenPGP-Schlüssel verwalten › Sicherheitskopie).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Eigene Schlüssel")
            }
            Section("Schlüssel anderer") {
                ForEach(keys.publicOnlyKeys) { KeyRow(key: $0) }
                if keys.publicOnlyKeys.isEmpty {
                    Text("Öffentliche Schlüssel deiner Kontakte erscheinen hier, sobald du sie importierst – aus einer Datei, der Zwischenablage, deinen CardDAV-Kontakten oder direkt aus einer empfangenen Nachricht.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Schlüssel")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showGenerate = true } label: { Label("Neues Schlüsselpaar erzeugen", systemImage: "wand.and.stars") }
                    Button { showBitwarden = true } label: { Label("Aus Bitwarden importieren", systemImage: "shield.lefthalf.filled") }
                    Button { showLookup = true } label: { Label("Online suchen …", systemImage: "magnifyingglass") }
                    Button { showFileImporter = true } label: { Label("Aus Datei importieren", systemImage: "doc") }
                    Button { flow.startFromClipboard(keys: keys) } label: {
                        Label("Aus Zwischenablage importieren", systemImage: "doc.on.clipboard")
                    }
                } label: {
                    Label("Hinzufügen", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showGenerate) {
            KeyGenerateView()
        }
        .sheet(isPresented: $showBitwarden) {
            BitwardenImportView(flow: flow)
        }
        .alert("Schlüssel online suchen", isPresented: $showLookup) {
            TextField("name@example.org", text: $lookupAddress)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
            Button("Suchen") { Task { await lookUp() } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Sucht im Web Key Directory des Anbieters und auf keys.openpgp.org. Dabei erfährt der jeweilige Server, nach welcher Adresse du suchst.")
        }
        .overlay { if isLookingUp { ProgressView("Suche …").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { flow.start(url: url, keys: keys) }
        }
        .keyImportAlerts(flow)
    }
}

/// Bitwarden offers no interface through which other iOS apps can read vault items,
/// so the key travels by clipboard (secure note) or as a shared attachment.
struct BitwardenImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(KeyStore.self) private var keys
    let flow: KeyImportFlow

    var body: some View {
        NavigationStack {
            List {
                Section {
                    step(1, "Öffne Bitwarden und den Eintrag mit deinem privaten Schlüssel.")
                    step(2, "Liegt der Schlüssel als Text in einer sicheren Notiz: Notiz kopieren, hierher zurückkehren und „Aus Zwischenablage einfügen“ tippen.")
                    step(3, "Liegt er als Dateianhang (.asc, .gpg): Anhang in Bitwarden herunterladen und über „Teilen“ an Postfalke senden.")
                } header: {
                    Text("So geht es")
                } footer: {
                    Text("Nach dem Import eines privaten Schlüssels leert Postfalke die Zwischenablage. Die Passphrase wird beim Import abgefragt.")
                }
                Section {
                    Button {
                        openURL(URL(string: "bitwarden://")!)
                    } label: {
                        Label("Bitwarden öffnen", systemImage: "arrow.up.forward.app")
                    }
                    Button {
                        dismiss()
                        flow.startFromClipboard(keys: keys)
                    } label: {
                        Label("Aus Zwischenablage einfügen", systemImage: "doc.on.clipboard")
                    }
                }
            }
            .navigationTitle("Aus Bitwarden importieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)").font(.headline).foregroundStyle(.tint)
            Text(text)
        }
    }
}

struct CardDAVSettingsView: View {
    @Environment(KeyStore.self) private var keys
    @Environment(ContactKeySync.self) private var contacts

    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var confirmRemove = false

    private var canSync: Bool {
        ContactKeySync.normalizedURL(url)?.host != nil && !username.isEmpty && (!password.isEmpty || contacts.hasPassword)
    }

    var body: some View {
        Form {
            Section {
                TextField("https://cloud.example.org/remote.php/dav", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Benutzername", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(contacts.hasPassword ? "Passwort (unverändert)" : "Passwort oder App-Passwort", text: $password)
                TrustedCertificateRow(fingerprint: Binding(get: { contacts.settings.trustedCertificate },
                                                           set: { contacts.setTrustedCertificate($0) }))
            } header: {
                Text("Server")
            } footer: {
                Text("Nextcloud: die Adresse deiner Cloud mit /remote.php/dav. Verwende am besten ein App-Passwort (Einstellungen › Sicherheit). Postfalke liest nur; es werden keine Kontakte geändert.")
            }
            Section {
                Button {
                    Task {
                        contacts.save(.init(url: url.trimmingCharacters(in: .whitespaces),
                                            username: username.trimmingCharacters(in: .whitespaces),
                                            trustedCertificate: contacts.settings.trustedCertificate),
                                      password: password.isEmpty ? nil : password)
                        password = ""
                        await contacts.sync(keys: keys)
                    }
                } label: {
                    HStack {
                        Label("Sichern und synchronisieren", systemImage: "arrow.triangle.2.circlepath")
                        if contacts.isSyncing { Spacer(); ProgressView() }
                    }
                }
                .disabled(!canSync || contacts.isSyncing)
                if let error = contacts.lastError {
                    ErrorNotice(message: error)
                } else if let result = contacts.lastResult {
                    Text(result).font(.footnote).foregroundStyle(.secondary)
                }
                if let last = contacts.lastSync {
                    LabeledContent("Zuletzt", value: last.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote)
                }
            } footer: {
                Text("Ein Schlüssel aus einer Kontaktkarte gilt für alle E-Mail-Adressen dieser Karte. Beim Verfassen wird er automatisch verwendet. Synchronisiert wird beim Start der App, höchstens alle sechs Stunden.")
            }
            if !keys.bindings.isEmpty {
                Section("Zugeordnete Adressen") {
                    ForEach(keys.bindings.keys.sorted(), id: \.self) { email in
                        LabeledContent(email, value: "…" + (keys.bindings[email] ?? "").suffix(8))
                            .font(.footnote.monospaced())
                    }
                }
            }
            if contacts.isConfigured {
                Section {
                    Button("Verbindung entfernen", role: .destructive) { confirmRemove = true }
                }
            }
        }
        .certificateTrustAlert(Binding(get: { contacts.untrusted }, set: { contacts.untrusted = $0 })) { info in
            Task { await contacts.trust(info, keys: keys) }
        }
        .navigationTitle("Schlüssel aus Kontakten")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Die Zuordnungen werden entfernt. Bereits importierte Schlüssel bleiben im Schlüsselbund.",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Entfernen", role: .destructive) {
                contacts.remove(keys: keys)
                url = ""
                username = ""
                password = ""
            }
        }
        .onAppear {
            guard url.isEmpty else { return }
            url = contacts.settings.url
            username = contacts.settings.username
        }
    }
}

extension KeyListView {
    fileprivate func lookUp() async {
        let address = lookupAddress.trimmingCharacters(in: .whitespaces)
        guard address.contains("@") else { return }
        isLookingUp = true
        defer { isLookingUp = false }
        let found = await keys.discover([address])
        flow.notice = found[address].map { "Schlüssel für \(address) gefunden (\($0.rawValue)) und importiert. Vergleiche den Fingerabdruck, bevor du ihm vertraust." }
            ?? "Für \(address) wurde online kein Schlüssel gefunden."
        lookupAddress = ""
    }
}

struct KeyRow: View {
    let key: PGPKeyInfo

    var body: some View {
        NavigationLink {
            KeyDetailView(fingerprint: key.fingerprint)
        } label: {
            HStack {
                Image(systemName: key.isSecret ? "key.fill" : "key")
                    .foregroundStyle(key.isUsable ? Color.accentColor : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(key.primaryUserID).lineLimit(1)
                    Text(key.revoked ? "Widerrufen" : key.isExpired ? "Abgelaufen" : "…" + key.fingerprint.suffix(16))
                        .font(.caption.monospaced())
                        .foregroundStyle(key.isUsable ? Color.secondary : .red)
                }
            }
        }
    }
}

struct KeyDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(KeyStore.self) private var keys
    let fingerprint: String

    @State private var confirmDelete = false
    @State private var confirmSecretExport = false
    @State private var secretExport: ExportFile?
    @State private var showExpiry = false
    @State private var confirmRevoke = false
    @State private var isWorking = false
    @State private var actionError: String?
    @State private var notice: String?

    var body: some View {
        if let key = keys.key(fingerprint: fingerprint) {
            List {
                Section("Benutzer-IDs") {
                    ForEach(key.userIDs, id: \.self) { Text($0).textSelection(.enabled) }
                }
                Section {
                    Text(key.formattedFingerprint)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                } header: {
                    Text("Fingerabdruck")
                } footer: {
                    Text("Vergleiche den Fingerabdruck über einen zweiten Kanal (Telefon, persönlich), um sicherzugehen, dass der Schlüssel wirklich dieser Person gehört.")
                }
                Section("Details") {
                    LabeledContent("Typ", value: key.isSecret ? "Schlüsselpaar (privat + öffentlich)" : "Öffentlicher Schlüssel")
                    LabeledContent("Algorithmus", value: key.algorithm)
                    LabeledContent("Erstellt", value: key.created.formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("Läuft ab", value: key.expires?.formatted(date: .abbreviated, time: .omitted) ?? "nie")
                    LabeledContent("Verschlüsselung", value: key.canEncrypt ? "möglich" : "nicht möglich")
                    if key.revoked { Label("Dieser Schlüssel wurde widerrufen.", systemImage: "xmark.octagon").foregroundStyle(.red) }
                }
                Section {
                    ShareLink(item: ExportFile(name: "OpenPGP_0x\(key.keyID)_public.asc", text: key.publicArmored),
                              preview: SharePreview("Öffentlicher Schlüssel")) {
                        Label("Öffentlichen Schlüssel teilen", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = key.publicArmored
                    } label: {
                        Label("Öffentlichen Schlüssel kopieren", systemImage: "doc.on.doc")
                    }
                    if key.isSecret {
                        Button {
                            confirmSecretExport = true
                        } label: {
                            Label("Privaten Schlüssel sichern …", systemImage: "lock.doc")
                        }
                    }
                }
                if key.isSecret {
                    Section {
                        Button {
                            showExpiry = true
                        } label: {
                            Label("Ablaufdatum ändern …", systemImage: "calendar.badge.clock")
                        }
                        .disabled(key.revoked || isWorking)
                        Button(role: .destructive) {
                            confirmRevoke = true
                        } label: {
                            Label("Schlüssel widerrufen …", systemImage: "xmark.seal")
                        }
                        .disabled(key.revoked || isWorking)
                        if let actionError { ErrorNotice(message: actionError) }
                    } header: {
                        Text("Verwalten")
                    } footer: {
                        Text("Nach einer Änderung kennen andere sie erst, wenn sie deinen öffentlichen Schlüssel neu erhalten. Postfalke hängt ihn jeder E-Mail im Autocrypt-Header an; du kannst ihn auch oben teilen.")
                    }
                }
                Section {
                    Button("Schlüssel löschen", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle(key.primaryUserID)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(key.isSecret
                                ? "Ohne den privaten Schlüssel kannst du daran verschlüsselte Nachrichten nie wieder lesen."
                                : "Schlüssel aus dem Schlüsselbund löschen?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) {
                    keys.delete(key)
                    dismiss()
                }
            }
            .sheet(isPresented: $showExpiry) {
                ExpirySheet(current: key.expires) { expires in
                    Task { await run { try await keys.setExpiry(key, expires: expires) }
                        notice = expires.map { "Gültig bis \($0.formatted(date: .long, time: .omitted))." } ?? "Der Schlüssel läuft nicht mehr ab." }
                }
            }
            .confirmationDialog("Ein widerrufener Schlüssel kann nicht mehr zum Verschlüsseln an dich verwendet werden. Das lässt sich nicht rückgängig machen.",
                                isPresented: $confirmRevoke, titleVisibility: .visible) {
                Button("Ersetzt durch neuen Schlüssel", role: .destructive) { revoke(key, .superseded) }
                Button("Nicht mehr verwendet", role: .destructive) { revoke(key, .retired) }
                Button("Schlüssel ist kompromittiert", role: .destructive) { revoke(key, .compromised) }
            }
            .alert("Schlüssel geändert", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text((notice ?? "") + "\n\nTeile deinen öffentlichen Schlüssel erneut, damit andere die Änderung erhalten.")
            }
            .confirmationDialog("Der private Schlüssel erlaubt das Lesen all deiner verschlüsselten Nachrichten. Bewahre die Sicherung an einem sicheren Ort auf.",
                                isPresented: $confirmSecretExport, titleVisibility: .visible) {
                Button("Privaten Schlüssel exportieren") {
                    secretExport = ExportFile(name: "OpenPGP_0x\(key.keyID)_SECRET.asc", text: key.armored)
                }
            }
            .sheet(item: $secretExport) { file in
                NavigationStack {
                    VStack(spacing: 20) {
                        Image(systemName: "lock.doc").font(.system(size: 60)).foregroundStyle(.tint)
                        Text("Die Datei ist mit der Passphrase des Schlüssels geschützt – sofern du eine vergeben hast.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        ShareLink(item: file, preview: SharePreview(file.name)) {
                            Label("Sicherungsdatei speichern oder teilen", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(30)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Fertig") { secretExport = nil } }
                    }
                }
                .presentationDetents([.medium])
            }
        } else {
            ContentUnavailableView("Schlüssel nicht gefunden", systemImage: "key")
        }
    }
}

/// An armored key offered to the share sheet as a real `.asc` file.
struct ExportFile: Transferable, Identifiable {
    let id = UUID()
    let name: String
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { file in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(file.id.uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(file.name)
            try Data(file.text.utf8).write(to: url, options: .completeFileProtection)
            return SentTransferredFile(url)
        }
    }
}

extension KeyDetailView {
    private func run(_ action: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await action()
            actionError = nil
        } catch {
            actionError = MailStore.describe(error)
        }
    }

    private func revoke(_ key: PGPKeyInfo, _ reason: PGP.RevocationReason) {
        Task {
            await run { try await keys.revoke(key, reason: reason) }
            if actionError == nil { notice = "Der Schlüssel ist widerrufen." }
        }
    }
}

/// Picks a new expiry date or "never".
private struct ExpirySheet: View {
    @Environment(\.dismiss) private var dismiss
    let current: Date?
    var onSave: (Date?) -> Void
    @State private var never = false
    @State private var date = Calendar.current.date(byAdding: .year, value: 2, to: .now) ?? .now

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Läuft nie ab", isOn: $never)
                if !never {
                    DatePicker("Gültig bis", selection: $date, in: Date().addingTimeInterval(86_400)...,
                               displayedComponents: .date)
                        .datePickerStyle(.graphical)
                }
            }
            .navigationTitle("Ablaufdatum")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        onSave(never ? nil : date)
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let current, current > .now { date = current }
                never = current == nil
            }
        }
    }
}

struct KeyGenerateView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountStore.self) private var accounts
    @Environment(KeyStore.self) private var keys

    @State private var name = ""
    @State private var email = ""
    @State private var passphrase = ""
    @State private var validityYears = 3
    @State private var repeatPassphrase = ""
    @State private var isWorking = false
    @State private var error: String?

    private var isValid: Bool {
        email.contains("@") && passphrase == repeatPassphrase
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identität") {
                    if accounts.accounts.count > 1 {
                        Picker("Konto", selection: $email) {
                            ForEach(accounts.accounts) { Text($0.email).tag($0.email) }
                        }
                        .onChange(of: email) {
                            if let account = accounts.accounts.first(where: { $0.email == email }) { name = account.name }
                        }
                    }
                    TextField("Name", text: $name)
                    TextField("E-Mail-Adresse", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    SecureField("Passphrase (empfohlen)", text: $passphrase)
                    SecureField("Passphrase wiederholen", text: $repeatPassphrase)
                    Picker("Gültigkeit", selection: $validityYears) {
                        Text("1 Jahr").tag(1)
                        Text("2 Jahre").tag(2)
                        Text("3 Jahre").tag(3)
                        Text("5 Jahre").tag(5)
                        Text("Unbegrenzt").tag(0)
                    }
                    if passphrase != repeatPassphrase, !repeatPassphrase.isEmpty {
                        Text("Die Passphrasen stimmen nicht überein.").font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Schutz")
                } footer: {
                    Text("Erzeugt wird ein Ed25519-Schlüssel mit Curve25519-Unterschlüssel zum Verschlüsseln. Die Passphrase schützt die Sicherungsdatei des privaten Schlüssels.")
                }
                if let error {
                    Section { ErrorNotice(message: error) }
                }
            }
            .navigationTitle("Neues Schlüsselpaar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("Erzeugen") { Task { await generate() } }.disabled(!isValid)
                    }
                }
            }
            .onAppear {
                guard email.isEmpty, let account = accounts.accounts.first else { return }
                name = account.name
                email = account.email
            }
        }
    }

    private func generate() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let expires = validityYears == 0 ? nil : Calendar.current.date(byAdding: .year, value: validityYears, to: .now)
            try await keys.generate(name: name.trimmingCharacters(in: .whitespaces),
                                    email: email.trimmingCharacters(in: .whitespaces),
                                    passphrase: passphrase, expires: expires)
            dismiss()
        } catch {
            self.error = MailStore.describe(error)
        }
    }
}
