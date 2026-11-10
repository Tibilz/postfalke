import SwiftUI
import MailEngine

/// Creates a new account (`account == nil`) or edits an existing one.
struct AccountEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountStore.self) private var accounts
    @Environment(MailStore.self) private var mail
    @Environment(KeyStore.self) private var keys

    let account: Account?

    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var imap = ServerConfig(host: "", port: 993, security: .tls, username: "")
    @State private var smtp = ServerConfig(host: "", port: 587, security: .startTLS, username: "")
    @State private var signature = ""
    @State private var pgpFingerprint: String?
    @State private var signByDefault = false
    @State private var encryptByDefault = false

    @State private var isLookingUp = false
    @State private var lookupNote: String?
    @State private var isSaving = false
    @State private var error: String?
    @State private var confirmDelete = false

    private var isNew: Bool { account == nil }

    private var isComplete: Bool {
        email.contains("@") && !imap.host.isEmpty && !smtp.host.isEmpty
            && (!password.isEmpty || !isNew)
    }

    var body: some View {
        Form {
            Section {
                TextField("Dein Name", text: $name)
                    .textContentType(.name)
                TextField("E-Mail-Adresse", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(isNew ? "Passwort" : "Passwort (unverändert)", text: $password)
            } header: {
                Text("Konto")
            } footer: {
                Text("Anbieter wie Gmail, Outlook oder iCloud verlangen ein App-Passwort; bei manchen (z. B. WEB.DE, GMX) muss IMAP erst in den Einstellungen des Postfachs aktiviert werden.")
            }

            Section {
                Button {
                    Task { await lookup() }
                } label: {
                    HStack {
                        Label("Servereinstellungen automatisch ermitteln", systemImage: "wand.and.stars")
                        if isLookingUp { Spacer(); ProgressView() }
                    }
                }
                .disabled(!email.contains("@") || isLookingUp)
                if let lookupNote {
                    Text(lookupNote).font(.footnote).foregroundStyle(.secondary)
                }
            }

            ServerSection(title: "Posteingang (IMAP)", config: $imap)
            ServerSection(title: "Postausgang (SMTP)", config: $smtp)

            if !isNew {
                Section("Signatur") {
                    TextEditor(text: $signature).frame(minHeight: 70)
                }
                Section {
                    Picker("Eigener Schlüssel", selection: $pgpFingerprint) {
                        Text("Automatisch").tag(String?.none)
                        ForEach(keys.secretKeys) { key in
                            Text(key.primaryUserID).tag(String?.some(key.fingerprint))
                        }
                    }
                    Toggle("Standardmäßig signieren", isOn: $signByDefault)
                    Toggle("Standardmäßig verschlüsseln", isOn: $encryptByDefault)
                } header: {
                    Text("OpenPGP")
                } footer: {
                    Text("Verschlüsselt wird nur, wenn für alle Empfänger ein öffentlicher Schlüssel vorhanden ist.")
                }
                Section {
                    Button("Konto entfernen", role: .destructive) { confirmDelete = true }
                }
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("Ohne Prüfung speichern") { store() }
                }
            }
        }
        .navigationTitle(isNew ? "Konto hinzufügen" : (account?.email ?? "Konto"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Abbrechen") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Sichern") { Task { await verifyAndStore() } }
                        .disabled(!isComplete)
                }
            }
        }
        .confirmationDialog("Konto wirklich von diesem Gerät entfernen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Entfernen", role: .destructive) {
                if let account {
                    mail.forget(account.id)
                    accounts.remove(account)
                }
                dismiss()
            }
        } message: {
            Text("Die Nachrichten auf dem Server bleiben erhalten.")
        }
        .onAppear(perform: fill)
    }

    private func fill() {
        #if DEBUG
        // UI tests talk to Tools/fakemail.py: -testServer <imapPort>,<smtpPort>
        if account == nil, let index = CommandLine.arguments.firstIndex(of: "-testServer"),
           CommandLine.arguments.count > index + 1 {
            let ports = CommandLine.arguments[index + 1].split(separator: ",").compactMap { Int($0) }
            if ports.count == 2, imap.host.isEmpty {
                imap = ServerConfig(host: "127.0.0.1", port: ports[0], security: .none, username: "")
                smtp = ServerConfig(host: "127.0.0.1", port: ports[1], security: .none, username: "")
            }
        }
        #endif
        guard let account, email.isEmpty else { return }
        name = account.name
        email = account.email
        imap = account.imap
        smtp = account.smtp
        signature = account.signature
        pgpFingerprint = account.pgpFingerprint
        signByDefault = account.signByDefault
        encryptByDefault = account.encryptByDefault
    }

    private func lookup() async {
        isLookingUp = true
        defer { isLookingUp = false }
        let address = email.trimmingCharacters(in: .whitespaces)
        if let result = await Autoconfig.lookup(email: address) {
            imap = result.imap
            smtp = result.smtp
            lookupNote = "Einstellungen für \(result.displayName ?? "den Anbieter") gefunden."
        } else {
            let domain = address.split(separator: "@").last.map(String.init) ?? ""
            if imap.host.isEmpty { imap.host = "imap.\(domain)" }
            if smtp.host.isEmpty { smtp.host = "smtp.\(domain)" }
            if imap.username.isEmpty { imap.username = address }
            if smtp.username.isEmpty { smtp.username = address }
            lookupNote = "Keine Einstellungen gefunden – bitte die vorgeschlagenen Werte prüfen."
        }
    }

    private func buildAccount() -> Account {
        var result = account ?? Account(name: "", email: "", imap: imap, smtp: smtp)
        result.name = name.trimmingCharacters(in: .whitespaces)
        result.email = email.trimmingCharacters(in: .whitespaces)
        result.imap = imap
        result.smtp = smtp
        // The address is the usual login name.
        if result.imap.username.isEmpty { result.imap.username = result.email }
        if result.smtp.username.isEmpty { result.smtp.username = result.email }
        result.signature = signature
        result.pgpFingerprint = pgpFingerprint
        result.signByDefault = signByDefault
        result.encryptByDefault = encryptByDefault
        return result
    }

    private func verifyAndStore() async {
        isSaving = true
        defer { isSaving = false }
        let candidate = buildAccount()
        let secret = password.isEmpty ? accounts.password(for: candidate) : password
        do {
            try await MailStore.verify(candidate, password: secret)
            store()
        } catch {
            self.error = MailStore.describe(error)
        }
    }

    private func store() {
        let candidate = buildAccount()
        accounts.save(candidate, password: password.isEmpty ? nil : password)
        mail.resetSession(candidate.id)
        dismiss()
    }
}

private struct ServerSection: View {
    let title: String
    @Binding var config: ServerConfig

    var body: some View {
        Section(title) {
            TextField("Server", text: $config.host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            HStack {
                Text("Port")
                Spacer()
                TextField("Port", value: $config.port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
            Picker("Sicherheit", selection: $config.security) {
                Text("SSL/TLS").tag(ConnectionSecurity.tls)
                Text("STARTTLS").tag(ConnectionSecurity.startTLS)
                Text("Keine (unsicher)").tag(ConnectionSecurity.none)
            }
            TextField("Benutzername (Standard: E-Mail-Adresse)", text: $config.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}
