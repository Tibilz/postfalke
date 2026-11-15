import Foundation
import CryptoKit

/// Finds public keys on the internet: Web Key Directory of the recipient's
/// domain first, then keys.openpgp.org (which only serves verified addresses).
public enum KeyDiscovery {
    public enum Source: String, Sendable {
        case wkd = "Web Key Directory"
        case keysOpenPGP = "keys.openpgp.org"
    }

    public struct Found: Sendable {
        public var data: Data
        public var source: Source
    }

    private static let zBase32 = Array("ybndrfg8ejkmcpqxot1uwisza345h769")

    /// z-base-32 of the SHA-1 of the lowercased local part (draft-koch-openpgp-webkey-service).
    public static func wkdHash(localPart: String) -> String {
        let digest = Array(Insecure.SHA1.hash(data: Data(localPart.lowercased().utf8)))
        var bits = 0, value = 0
        var out = ""
        for byte in digest {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(zBase32[(value >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(zBase32[(value << (5 - bits)) & 31]) }
        return out
    }

    /// Advanced method first, then the direct method.
    public static func wkdURLs(for email: String) -> [URL] {
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return [] }
        let domain = parts[1].lowercased()
        let hash = wkdHash(localPart: parts[0])
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let local = parts[0].addingPercentEncoding(withAllowedCharacters: allowed) ?? parts[0]
        return [
            "https://openpgpkey.\(domain)/.well-known/openpgpkey/\(domain)/hu/\(hash)?l=\(local)",
            "https://\(domain)/.well-known/openpgpkey/hu/\(hash)?l=\(local)",
        ].compactMap(URL.init(string:))
    }

    public static func keyServerURL(for email: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = email.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://keys.openpgp.org/vks/v1/by-email/\(encoded)")
    }

    /// Looks the address up. Only keys whose user IDs contain the address are returned.
    public static func lookup(email: String, session: URLSession = .shared) async -> Found? {
        let wanted = email.lowercased()
        func matching(_ data: Data) -> Data? {
            guard let keys = try? PGP.inspect(data),
                  keys.contains(where: { $0.emails.contains(wanted) && $0.isUsable && $0.canEncrypt }) else { return nil }
            return data
        }
        for url in wkdURLs(for: email) {
            if let data = await fetch(url, session: session), let key = matching(data) {
                return Found(data: key, source: .wkd)
            }
        }
        if let url = keyServerURL(for: email), let data = await fetch(url, session: session), let key = matching(data) {
            return Found(data: key, source: .keysOpenPGP)
        }
        return nil
    }

    private static func fetch(_ url: URL, session: URLSession) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              !data.isEmpty, data.count < 2_000_000 else { return nil }
        return data
    }
}
