import CryptoKit
import Foundation

/// What a parser learned from a private key file.
struct ParsedOpenSSHKey: Equatable, Sendable {
    /// "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", ...
    let algorithm: String
    /// The public key's SSH wire blob.
    let publicKeyBlob: Data
    let comment: String
    /// The file is encrypted with a passphrase.
    let encrypted: Bool
    /// An ED25519 key's 32-byte seed, when the parser could read the private half: `KeyStore` then keeps the seed,
    /// as for a key made on the phone. Otherwise it keeps the file (and its passphrase) for the transport to load.
    let ed25519Seed: Data?
    /// The parser checked the passphrase (by decrypting); false when it could only read the public half.
    let passphraseVerified: Bool
}

enum OpenSSHKeyError: Error, LocalizedError, Equatable {
    case notOpenSSH
    case malformed
    /// Encrypted: ask for the passphrase and parse again.
    case passphraseRequired
    case wrongPassphrase
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notOpenSSH: "This isn't an OpenSSH private key. Keys start with “-----BEGIN OPENSSH PRIVATE KEY-----”."
        case .malformed: "This key file is damaged."
        case .passphraseRequired: "This key is protected by a passphrase."
        case .wrongPassphrase: "The passphrase is incorrect."
        case .unsupported(let what): what
        }
    }
}

/// Reads OpenSSH private key files for Import key (M8a). The transport integration provides a Citadel-backed
/// parser (RSA, ECDSA, PEM and PKCS#8 files, decryption); `BuiltInOpenSSHKeyParser` covers what the phone needs
/// without it.
protocol OpenSSHPrivateKeyParsing: Sendable {
    /// Throws `OpenSSHKeyError.passphraseRequired` for an encrypted file when `passphrase` is nil.
    func parse(_ file: Data, passphrase: String?) throws -> ParsedOpenSSHKey
}

/// `openssh-key-v1` files (PROTOCOL.key in OpenSSH): the private half of unencrypted ED25519 keys, the public half
/// of every other key and of encrypted files (whose passphrase it cannot check: no bcrypt-pbkdf here).
struct BuiltInOpenSSHKeyParser: OpenSSHPrivateKeyParsing {
    private static let magic = Data("openssh-key-v1\0".utf8)

    func parse(_ file: Data, passphrase: String?) throws -> ParsedOpenSSHKey {
        let body = try Self.unarmor(file)
        guard body.starts(with: Self.magic) else { throw OpenSSHKeyError.notOpenSSH }
        var reader = SSHKeyEncoding.Reader(body.dropFirst(Self.magic.count))
        guard let cipher = reader.text(), let kdf = reader.text(), reader.bytes() != nil, let count = reader.uint32(),
              count == 1, let blob = reader.bytes(), let section = reader.bytes(), reader.isAtEnd,
              let algorithm = SSHKeyEncoding.algorithm(blob)
        else { throw keyCount(body) > 1 ? OpenSSHKeyError.unsupported("Files with more than one key aren't supported.") : OpenSSHKeyError.malformed }
        if cipher != "none" || kdf != "none" {
            guard let passphrase, !passphrase.isEmpty else { throw OpenSSHKeyError.passphraseRequired }
            return ParsedOpenSSHKey(algorithm: algorithm, publicKeyBlob: Data(blob), comment: "", encrypted: true,
                                    ed25519Seed: nil, passphraseVerified: false)
        }
        // checkint twice, then the key: its type, its fields, the comment, then padding 1, 2, 3...
        var keys = SSHKeyEncoding.Reader(section)
        guard let check = keys.uint32(), keys.uint32() == check, keys.text() == algorithm else { throw OpenSSHKeyError.malformed }
        guard algorithm == "ssh-ed25519" else {
            return ParsedOpenSSHKey(algorithm: algorithm, publicKeyBlob: Data(blob), comment: "", encrypted: false,
                                    ed25519Seed: nil, passphraseVerified: true)
        }
        guard let publicKey = keys.bytes(), publicKey.count == 32, let secret = keys.bytes(), secret.count == 64,
              Data(secret.suffix(32)) == Data(publicKey), let comment = keys.text()
        else { throw OpenSSHKeyError.malformed }
        let seed = Data(secret.prefix(32))
        // The seed must derive the public key the file names, or the file is inconsistent.
        guard let derived = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
              derived.publicKey.rawRepresentation == Data(publicKey),
              SSHKeyEncoding.ed25519Blob(derived.publicKey) == Data(blob)
        else { throw OpenSSHKeyError.malformed }
        return ParsedOpenSSHKey(algorithm: algorithm, publicKeyBlob: Data(blob), comment: comment, encrypted: false,
                                ed25519Seed: seed, passphraseVerified: true)
    }

    private func keyCount(_ body: Data) -> UInt32 {
        var reader = SSHKeyEncoding.Reader(body.dropFirst(Self.magic.count))
        _ = (reader.bytes(), reader.bytes(), reader.bytes())
        return reader.uint32() ?? 0
    }

    /// The base64 between the armor lines (pasted text may carry other whitespace or CRLF).
    static func unarmor(_ file: Data) throws -> Data {
        guard let text = String(data: file, encoding: .utf8) else { throw OpenSSHKeyError.notOpenSSH }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(of: "-----BEGIN OPENSSH PRIVATE KEY-----") else {
            if lines.contains(where: { $0.hasPrefix("-----BEGIN ") && $0.hasSuffix("PRIVATE KEY-----") }) {
                throw OpenSSHKeyError.unsupported("Only OpenSSH key files can be imported yet. Convert this one with “ssh-keygen -p -f <file>”.")
            }
            throw OpenSSHKeyError.notOpenSSH
        }
        guard let end = lines[start...].firstIndex(of: "-----END OPENSSH PRIVATE KEY-----"),
              let data = Data(base64Encoded: lines[(start + 1)..<end].joined().filter { !$0.isWhitespace })
        else { throw OpenSSHKeyError.malformed }
        return data
    }
}
