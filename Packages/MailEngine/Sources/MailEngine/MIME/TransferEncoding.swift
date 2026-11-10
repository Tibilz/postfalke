import Foundation

public enum TransferEncoding {

    public static func decode(_ data: Data, encoding: String?) -> Data {
        switch (encoding ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64": return decodeBase64(data)
        case "quoted-printable": return decodeQuotedPrintable(data)
        default: return data
        }
    }

    public static func decodeBase64(_ data: Data) -> Data {
        // Tolerate line breaks, missing padding and stray characters.
        var clean = data.filter { byte in
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39) || byte == 0x2B || byte == 0x2F
        }
        while clean.count % 4 != 0 { clean.append(0x3D) }
        return Data(base64Encoded: clean) ?? Data()
    }

    public static func decodeQuotedPrintable(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = Data(capacity: bytes.count)
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: return b - 0x30
            case 0x41...0x46: return b - 0x41 + 10
            case 0x61...0x66: return b - 0x61 + 10
            default: return nil
            }
        }
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "=") {
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A { i += 3; continue }
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 2; continue }
                if i + 2 < bytes.count, let hi = hex(bytes[i + 1]), let lo = hex(bytes[i + 2]) {
                    out.append(hi << 4 | lo)
                    i += 3
                    continue
                }
            }
            out.append(b)
            i += 1
        }
        return out
    }

    /// Base64 in 76-character lines, CRLF terminated.
    public static func encodeBase64(_ data: Data) -> String {
        let encoded = data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return encoded.isEmpty ? "" : encoded + "\r\n"
    }

    /// Quoted-printable text encoding with CRLF line endings.
    public static func encodeQuotedPrintable(_ text: String) -> String {
        let hexDigits = Array("0123456789ABCDEF")
        var out = ""
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" { lines.removeLast() } // text ended with a newline
        for line in lines {
            var column = 0
            let bytes = Array(line.utf8)
            for (index, byte) in bytes.enumerated() {
                let isLast = index == bytes.count - 1
                let literal = (byte >= 33 && byte <= 126 && byte != UInt8(ascii: "="))
                    || ((byte == 0x20 || byte == 0x09) && !isLast)
                let piece: String
                if literal {
                    piece = String(UnicodeScalar(byte))
                } else {
                    piece = "=" + String(hexDigits[Int(byte >> 4)]) + String(hexDigits[Int(byte & 0x0F)])
                }
                if column + piece.count > 75 {
                    out += "=\r\n"
                    column = 0
                }
                out += piece
                column += piece.count
            }
            out += "\r\n"
        }
        // "From " at line start is mangled by some MTAs, which would break signatures.
        return out.replacingOccurrences(of: "\r\nFrom ", with: "\r\nFrom=20")
    }
}
