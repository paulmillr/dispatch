import Foundation

/// A key on this phone (M8a's Key file list). The private half is in the Keychain under `KeyStore`; this record is
/// what the list shows and what `keys.json` keeps.
struct KeyRecord: Identifiable, Equatable, Codable, Sendable {
    enum Kind: Equatable, Codable, Sendable {
        /// Made on the phone with CryptoKit; the seed is in the Keychain behind Face ID.
        case ed25519
        /// Made in the Secure Enclave and presented as `ecdsa-sha2-nistp256`; it never leaves the chip.
        case secureEnclaveP256
        /// An imported OpenSSH key file, by its algorithm ("ssh-ed25519", "ssh-rsa", ...).
        case imported(String)
    }

    let id: UUID
    var label: String
    let kind: Kind
    /// The `authorized_keys` line.
    let publicKey: String
    /// `SHA256:<base64 without padding>`, as `ssh-keygen -l` prints it.
    let fingerprint: String
    let created: Date

    init(id: UUID = UUID(), label: String, kind: Kind, blob: Data, created: Date = Date()) {
        self.id = id
        self.label = label
        self.kind = kind
        publicKey = SSHKeyEncoding.authorizedKey(blob, comment: label) ?? ""
        fingerprint = SSHKeyEncoding.fingerprint(blob)
        self.created = created
    }

    var blob: Data? { SSHKeyEncoding.blob(authorizedKey: publicKey) }

    /// "ED25519", "ECDSA P-256", "RSA 4096".
    var typeLabel: String { blob.map(SSHKeyEncoding.typeLabel) ?? "Unknown" }

    var isSecureEnclave: Bool { kind == .secureEnclaveP256 }
}
