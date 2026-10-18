import CryptoKit
import Foundation

/// The SSH wire forms of public keys (RFC 4253 6.6, RFC 5656 3.1, RFC 8709) and OpenSSH's presentation of them.
enum SSHKeyEncoding {
    /// A length-prefixed SSH `string`.
    static func string(_ bytes: some Collection<UInt8>) -> Data {
        var data = Data()
        withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: bytes)
        return data
    }

    static func string(_ text: String) -> Data { string(Array(text.utf8)) }

    static func ed25519Blob(_ key: Curve25519.Signing.PublicKey) -> Data {
        string("ssh-ed25519") + string(Array(key.rawRepresentation))
    }

    /// `ecdsa-sha2-nistp256`: the curve name, then the uncompressed point.
    static func p256Blob(_ key: P256.Signing.PublicKey) -> Data {
        string("ecdsa-sha2-nistp256") + string("nistp256") + string(Array(key.x963Representation))
    }

    /// OpenSSH's `SHA256:` fingerprint: the digest of the blob in base64 without padding (`ssh-keygen -l`).
    static func fingerprint(_ blob: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// An `authorized_keys` line: algorithm, base64 blob, comment.
    static func authorizedKey(_ blob: Data, comment: String) -> String? {
        var reader = Reader(blob)
        guard let algorithm = reader.text() else { return nil }
        let comment = comment.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return [algorithm, blob.base64EncodedString(), comment].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The blob of an `authorized_keys` line.
    static func blob(authorizedKey line: String) -> Data? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return nil }
        var reader = Reader(blob)
        return reader.text() == String(fields[0]) ? blob : nil
    }

    /// The algorithm a blob names first.
    static func algorithm(_ blob: Data) -> String? {
        var reader = Reader(blob)
        return reader.text()
    }

    /// How the key list names a key type (M8a): "ED25519", "ECDSA P-256", "RSA 4096".
    static func typeLabel(_ blob: Data) -> String {
        var reader = Reader(blob)
        switch reader.text() {
        case "ssh-ed25519": return "ED25519"
        case "ecdsa-sha2-nistp256": return "ECDSA P-256"
        case "ecdsa-sha2-nistp384": return "ECDSA P-384"
        case "ecdsa-sha2-nistp521": return "ECDSA P-521"
        case "ssh-rsa":
            // e, then the modulus as an mpint: its bit length without leading zero bytes.
            guard reader.bytes() != nil, let modulus = reader.bytes()?.drop(while: { $0 == 0 }), let top = modulus.first
            else { return "RSA" }
            return "RSA \((modulus.count - 1) * 8 + (8 - top.leadingZeroBitCount))"
        case "sk-ssh-ed25519@openssh.com": return "ED25519-SK"
        case "sk-ecdsa-sha2-nistp256@openssh.com": return "ECDSA-SK"
        case let other?: return other
        case nil: return "Unknown"
        }
    }

    /// Reads SSH wire fields in order; every read fails past the end.
    struct Reader {
        private let data: Data
        private var offset: Int

        init(_ data: Data) {
            self.data = Data(data)
            offset = 0
        }

        var isAtEnd: Bool { offset == data.count }

        mutating func uint32() -> UInt32? {
            guard data.count - offset >= 4 else { return nil }
            let value = data[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            offset += 4
            return value
        }

        mutating func bytes() -> Data? {
            guard let length = uint32().map(Int.init), data.count - offset >= length else { return nil }
            defer { offset += length }
            return data[offset..<offset + length]
        }

        mutating func text() -> String? { bytes().flatMap { String(data: $0, encoding: .utf8) } }

        mutating func raw(_ count: Int) -> Data? {
            guard data.count - offset >= count else { return nil }
            defer { offset += count }
            return data[offset..<offset + count]
        }
    }
}
