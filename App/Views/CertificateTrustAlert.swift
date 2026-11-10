import SwiftUI
import MailEngine

/// Asks whether to trust a certificate the system rejected, showing its fingerprint.
struct CertificateTrustAlert: ViewModifier {
    @Binding var certificate: CertificateInfo?
    var onTrust: (CertificateInfo) -> Void

    func body(content: Content) -> some View {
        content.alert("Zertifikat nicht vertrauenswürdig",
                      isPresented: Binding(get: { certificate != nil }, set: { if !$0 { certificate = nil } }),
                      presenting: certificate) { info in
            Button("Diesem Zertifikat vertrauen") { onTrust(info) }
            Button("Abbrechen", role: .cancel) {}
        } message: { info in
            // verbatim: a port is not a quantity, so no "21.993"
            Text(verbatim: """
            \(info.subject)
            Server: \(info.host):\(String(info.port))

            SHA-256-Fingerabdruck:
            \(info.formattedFingerprint)

            Vertraue nur, wenn der Fingerabdruck mit dem deines Servers übereinstimmt (z. B. im Browser über das Schloss-Symbol › Zertifikat). Ändert sich das Zertifikat, fragt Postfalke erneut.
            """)
        }
    }
}

extension View {
    func certificateTrustAlert(_ certificate: Binding<CertificateInfo?>, onTrust: @escaping (CertificateInfo) -> Void) -> some View {
        modifier(CertificateTrustAlert(certificate: certificate, onTrust: onTrust))
    }
}

/// Shows that an exception exists and lets the user withdraw it.
struct TrustedCertificateRow: View {
    @Binding var fingerprint: String?

    var body: some View {
        if let value = fingerprint {
            VStack(alignment: .leading, spacing: 4) {
                Label("Eigenes Zertifikat vertraut", systemImage: "checkmark.shield")
                Text(CertificateTrust.format(value))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Vertrauen entziehen", role: .destructive) { fingerprint = nil }
                    .font(.footnote)
            }
        }
    }
}
