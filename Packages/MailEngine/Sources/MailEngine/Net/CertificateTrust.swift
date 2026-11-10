import Foundation
import Security
import CryptoKit

/// A server certificate the system did not trust (self-signed, private CA, wrong host name …).
public struct CertificateInfo: Sendable, Equatable, Codable {
    public var host: String
    public var port: Int
    /// SHA-256 of the DER certificate, upper-case hex without separators.
    public var sha256: String
    public var subject: String
    /// Why the system rejected it.
    public var reason: String

    /// `AB:CD:…` as shown by browsers and `openssl x509 -fingerprint -sha256`.
    public var formattedFingerprint: String { CertificateTrust.format(sha256) }
}

public enum CertificateTrust {

    public static func format(_ sha256: String) -> String {
        stride(from: 0, to: sha256.count, by: 2).map { offset -> String in
            let start = sha256.index(sha256.startIndex, offsetBy: offset)
            return String(sha256[start..<sha256.index(start, offsetBy: 2, limitedBy: sha256.endIndex)!])
        }.joined(separator: ":")
    }

    /// Accepts what the system trusts, plus exactly the one certificate the user confirmed.
    /// Returns nil when the connection may proceed, otherwise what was rejected.
    static func evaluate(_ trust: SecTrust, host: String, port: Int, pinned: String?) -> (trusted: Bool, rejected: CertificateInfo?) {
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return (true, nil) }

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return (false, nil)
        }
        let der = SecCertificateCopyData(leaf) as Data
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
        if let pinned, pinned.uppercased() == fingerprint { return (true, nil) }

        let reason = error.map { CFErrorCopyDescription($0) as String } ?? "nicht vertrauenswürdig"
        let subject = SecCertificateCopySubjectSummary(leaf) as String? ?? host
        return (false, CertificateInfo(host: host, port: port, sha256: fingerprint, subject: subject, reason: reason))
    }
}

/// URLSession delegate that applies `CertificateTrust` and remembers a rejection,
/// so the caller can report it instead of a generic "SSL error".
final class TrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let pinned: String?
    private let lock = NSLock()
    private var _rejected: CertificateInfo?

    init(pinned: String?) {
        self.pinned = pinned
    }

    var rejected: CertificateInfo? { lock.withLock { _rejected } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    func handle(_ challenge: URLAuthenticationChallenge,
                _ completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let result = CertificateTrust.evaluate(trust, host: space.host, port: space.port, pinned: pinned)
        if result.trusted {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            lock.withLock { _rejected = result.rejected }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
