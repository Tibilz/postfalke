import SwiftUI
import UniformTypeIdentifiers
import MailEngine

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountStore.self) private var accounts
    @Environment(KeyStore.self) private var keys
    @Environment(ContactKeySync.self) private var contacts
    @AppStorage(BackgroundRefresh.notifyKey) private var notifyNewMail = false
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
                    Text("Kontakte (CardDAV)")
                } footer: {
                    Text("Liest die öffentlichen Schlüssel aus dem KEY-Feld deiner Kontakte, z. B. aus Nextcloud.")
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
            } header: {
                Text("Server")
            } footer: {
                Text("Nextcloud: die Adresse deiner Cloud mit /remote.php/dav. Verwende am besten ein App-Passwort (Einstellungen › Sicherheit). Postfalke liest nur; es werden keine Kontakte geändert.")
            }
            Section {
                Button {
                    Task {
                        contacts.save(.init(url: url.trimmingCharacters(in: .whitespaces),
                                            username: username.trimmingCharacters(in: .whitespaces)),
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
                    Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
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

struct KeyGenerateView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountStore.self) private var accounts
    @Environment(KeyStore.self) private var keys

    @State private var name = ""
    @State private var email = ""
    @State private var passphrase = ""
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
                    if passphrase != repeatPassphrase, !repeatPassphrase.isEmpty {
                        Text("Die Passphrasen stimmen nicht überein.").font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Schutz")
                } footer: {
                    Text("Erzeugt wird ein Ed25519-Schlüssel mit Curve25519-Unterschlüssel zum Verschlüsseln. Die Passphrase schützt die Sicherungsdatei des privaten Schlüssels.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
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
            try await keys.generate(name: name.trimmingCharacters(in: .whitespaces),
                                    email: email.trimmingCharacters(in: .whitespaces),
                                    passphrase: passphrase)
            dismiss()
        } catch {
            self.error = MailStore.describe(error)
        }
    }
}
