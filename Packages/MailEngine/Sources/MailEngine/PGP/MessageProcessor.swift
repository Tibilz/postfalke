import Foundation

/// Keys available while reading a message.
public struct PGPContext: Sendable {
    public var secrets: [PGPSecret]
    /// Armored certificates used to check signatures.
    public var verifiers: [String]

    public init(secrets: [PGPSecret] = [], verifiers: [String] = []) {
        self.secrets = secrets
        self.verifiers = verifiers
    }
}

public struct MessageSecurity: Sendable, Equatable {
    public enum Signature: Sendable, Equatable {
        case none
        case valid(fingerprint: String)
        case invalid
        case unknownKey(keyID: String)
    }

    public var wasEncrypted = false
    public var signature: Signature = .none
    /// Set when decryption failed (missing key, wrong passphrase, damaged data).
    public var decryptionError: String?

    public init() {}

    mutating func merge(_ infos: [PGPSignatureInfo]) {
        guard !infos.isEmpty else { return }
        if case .valid = signature { return }
        if let good = infos.first(where: { $0.status == .valid }) {
            signature = .valid(fingerprint: good.signerFingerprint ?? good.keyID)
        } else if infos.contains(where: { $0.status == .invalid }) {
            signature = .invalid
        } else if signature == .none, let first = infos.first {
            signature = .unknownKey(keyID: first.keyID)
        }
    }
}

/// A message ready for display: decrypted, verified, flattened.
public struct ProcessedMessage: Sendable {
    public var root: MIMEPart
    public var content: MessageContent
    public var security: MessageSecurity
    /// Subject from protected headers inside the encrypted part, if any.
    public var protectedSubject: String?
    /// Binary sender key from the Autocrypt header, if any.
    public var autocryptKey: Data?
}

public enum MessageProcessor {

    public static func process(raw: Data, context: PGPContext) -> ProcessedMessage {
        let root = MIMEPart(data: raw)
        var security = MessageSecurity()
        var protectedSubject: String?
        let resolved = resolve(root, context: context, security: &security, protectedSubject: &protectedSubject, depth: 0)
        var content = MessageContent(part: resolved)
        handleInlinePGP(&content, context: context, security: &security)
        // The detached signature itself is not interesting as an attachment.
        content.attachments.removeAll { $0.mimeType == "application/pgp-signature" }

        var autocrypt: Data?
        if let header = root.header("Autocrypt") {
            let params = HeaderCodec.parseParameters("x;" + header).params
            if let keydata = params["keydata"] {
                autocrypt = Data(base64Encoded: keydata.filter { !$0.isWhitespace })
            }
        }
        return ProcessedMessage(root: root, content: content, security: security,
                                protectedSubject: protectedSubject, autocryptKey: autocrypt)
    }

    /// Replaces multipart/encrypted and multipart/signed nodes by their payload.
    private static func resolve(_ part: MIMEPart, context: PGPContext, security: inout MessageSecurity,
                                protectedSubject: inout String?, depth: Int) -> MIMEPart {
        guard depth < 10 else { return part }

        if part.mediaType == "multipart/encrypted", part.parts.count >= 2 {
            let payload = part.parts[1].decodedBody
            do {
                let result = try PGP.decrypt(payload, secrets: context.secrets, verifiers: context.verifiers)
                security.wasEncrypted = true
                security.merge(result.signatures)
                let inner = MIMEPart(data: result.data)
                if let subject = inner.decodedHeader("Subject"), protectedSubject == nil, !subject.isEmpty {
                    protectedSubject = subject
                }
                return resolve(inner, context: context, security: &security,
                               protectedSubject: &protectedSubject, depth: depth + 1)
            } catch {
                security.wasEncrypted = true
                security.decryptionError = (error as? MailError)?.errorDescription ?? error.localizedDescription
                return MIMEPart(data: Data("Content-Type: text/plain; charset=UTF-8\r\n\r\n".utf8))
            }
        }

        if part.mediaType == "multipart/signed", part.parts.count >= 2 {
            let signed = part.parts[0]
            if let infos = try? PGP.verifyDetached(canonical(signed.raw),
                                                   signature: part.parts[1].decodedBody,
                                                   verifiers: context.verifiers) {
                security.merge(infos)
            } else {
                security.merge([])
                if security.signature == .none { security.signature = .invalid }
            }
            return resolve(signed, context: context, security: &security,
                           protectedSubject: &protectedSubject, depth: depth + 1)
        }

        if part.mediaType.hasPrefix("multipart/") {
            var copy = part
            copy.parts = part.parts.map {
                resolve($0, context: context, security: &security, protectedSubject: &protectedSubject, depth: depth + 1)
            }
            return copy
        }
        return part
    }

    /// Signed MIME data is defined with CRLF line endings; repair bare LFs.
    private static func canonical(_ data: Data) -> Data {
        guard data.contains(0x0A) else { return data }
        var out = Data(capacity: data.count + 64)
        var previous: UInt8 = 0
        for byte in data {
            if byte == 0x0A, previous != 0x0D { out.append(0x0D) }
            out.append(byte)
            previous = byte
        }
        return out
    }

    private static func block(in text: String, begin: String, end: String) -> Range<String.Index>? {
        guard let start = text.range(of: begin),
              let stop = text.range(of: end, range: start.upperBound..<text.endIndex) else { return nil }
        return start.lowerBound..<stop.upperBound
    }

    /// Inline ("classic") PGP inside the text body.
    private static func handleInlinePGP(_ content: inout MessageContent, context: PGPContext,
                                        security: inout MessageSecurity) {
        guard let plain = content.plain else { return }

        if let range = block(in: plain, begin: "-----BEGIN PGP MESSAGE-----", end: "-----END PGP MESSAGE-----") {
            do {
                let result = try PGP.decrypt(Data(plain[range].utf8), secrets: context.secrets, verifiers: context.verifiers)
                security.wasEncrypted = security.wasEncrypted || result.wasEncrypted
                security.merge(result.signatures)
                let text = HeaderCodec.string(from: result.data, charset: "utf-8")
                content.plain = plain.replacingCharacters(in: range, with: text)
                content.html = nil
            } catch {
                security.wasEncrypted = true
                security.decryptionError = (error as? MailError)?.errorDescription ?? error.localizedDescription
            }
            return
        }

        if let range = block(in: plain, begin: "-----BEGIN PGP SIGNED MESSAGE-----", end: "-----END PGP SIGNATURE-----"),
           let result = try? PGP.verifyCleartext(String(plain[range]), verifiers: context.verifiers) {
            security.merge(result.signatures)
            content.plain = plain.replacingCharacters(in: range, with: result.text)
            content.html = nil
        }
    }
}
