import SwiftUI
import MailEngine

/// Shared key import: file, clipboard, "open in" from another app such as Bitwarden.
/// Asks for the passphrase when a protected private key is involved.
@MainActor
@Observable
final class KeyImportFlow {
    var askPassphrase = false
    var passphrase = ""
    var notice: String?
    private var pending: Data?
    private var clearClipboardAfterwards = false

    func start(_ data: Data, keys: KeyStore, fromClipboard: Bool = false) {
        pending = data
        passphrase = ""
        clearClipboardAfterwards = fromClipboard
        finish(keys: keys)
    }

    func startFromClipboard(keys: KeyStore) {
        guard let text = UIPasteboard.general.string, text.contains("-----BEGIN PGP") else {
            notice = "Die Zwischenablage enthält keinen OpenPGP-Schlüssel."
            return
        }
        start(Data(text.utf8), keys: keys, fromClipboard: true)
    }

    func start(url: URL, keys: KeyStore) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            notice = "Die Datei konnte nicht gelesen werden."
            return
        }
        start(data, keys: keys)
    }

    func cancel() {
        pending = nil
        passphrase = ""
    }

    func finish(keys: KeyStore) {
        guard let data = pending else { return }
        do {
            let imported = try keys.importKeys(from: data, passphrase: passphrase)
            var text = "Importiert: " + imported.map(\.primaryUserID).joined(separator: ", ")
            if clearClipboardAfterwards, imported.contains(where: \.isSecret) {
                // A private key should not linger where every app can read it.
                UIPasteboard.general.items = []
                text += "\n\nDie Zwischenablage wurde geleert."
            }
            notice = text
            cancel()
        } catch KeyStore.ImportError.passphraseRequired {
            askPassphrase = true
        } catch {
            notice = MailStore.describe(error)
            cancel()
        }
    }
}

struct KeyImportAlerts: ViewModifier {
    @Environment(KeyStore.self) private var keys
    @Bindable var flow: KeyImportFlow

    func body(content: Content) -> some View {
        content
            .alert("Passphrase des privaten Schlüssels", isPresented: $flow.askPassphrase) {
                SecureField("Passphrase", text: $flow.passphrase)
                Button("Importieren") { flow.finish(keys: keys) }
                Button("Abbrechen", role: .cancel) { flow.cancel() }
            } message: {
                Text("Der private Schlüssel ist geschützt. Die Passphrase wird im Schlüsselbund dieses Geräts gespeichert.")
            }
            .alert("Schlüsselimport", isPresented: Binding(get: { flow.notice != nil }, set: { if !$0 { flow.notice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(flow.notice ?? "")
            }
    }
}

extension View {
    func keyImportAlerts(_ flow: KeyImportFlow) -> some View {
        modifier(KeyImportAlerts(flow: flow))
    }
}
