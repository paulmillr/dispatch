import CryptoKit
import Foundation

/// A user key ready to sign. Imported OpenSSH files are parsed and held by the engine (the private
/// material never comes back to Swift); CryptoKit keys, Secure Enclave keys included, sign in Swift
/// when the engine asks, and only their public half crosses the FFI.
public struct SSHKey: Sendable {
  public enum Kind: String, Sendable, Hashable {
    case ed25519 = "ssh-ed25519"
    case ecdsaP256 = "ecdsa-sha2-nistp256"
    case ecdsaP384 = "ecdsa-sha2-nistp384"
    case ecdsaP521 = "ecdsa-sha2-nistp521"
    /// Signs rsa-sha2-512 (rsa-sha2-256 if that is all the server offers), never ssh-rsa.
    case rsa = "ssh-rsa"
  }

  /// Signs the bytes the engine hands over and returns the raw signature: Ed25519's 64 bytes, or ECDSA's
  /// fixed-width r‖s (CryptoKit's `rawRepresentation`).
  public typealias Signer = @Sendable (Data) async throws -> Data

  public let kind: Kind
  /// The OpenSSH public key line (`type base64`, then the file's comment for an imported file that has one), what goes
  /// into `authorized_keys`.
  public let publicKey: String
  /// `SHA256:` fingerprint, as `ssh-keygen -lf` prints it (M8a's key list).
  public let fingerprint: String
  /// Backed by the Secure Enclave (signing needs the device; the key cannot be exported).
  public let hardwareBacked: Bool

  enum Backing: Sendable {
    case engine(any EngineKey)
    case signer(blob: Data, sign: Signer)
  }
  let backing: Backing

  /// An OpenSSH private key file (ED25519, ECDSA P-256/384/521, RSA), plain or passphrase-encrypted, or
  /// a PEM/PKCS#8 file. Parsed and decrypted by the engine `SSHTransportEngine.preferred` names, whose connections
  /// alone can log in with it.
  public static func openSSH(_ file: Data, passphrase: String? = nil) throws -> SSHKey {
    try openSSH(file, bytes: passphrase?.utf8)
  }

  /// The same with the passphrase as bytes (from the Keychain, never a `String`). The caller owns `file` and
  /// `passphrase` and wipes them.
  public static func openSSH(_ file: Data, passphrase: Data?) throws -> SSHKey {
    try openSSH(file, bytes: passphrase)
  }

  /// The passphrase's NUL-terminated copy is wiped once the engine has its own (which it wipes too).
  private static func openSSH(_ file: Data, bytes passphrase: (some Collection<UInt8>)?) throws -> SSHKey {
    guard let passphrase else { return try parse(file, nil) }
    var copy = [CChar](repeating: 0, count: passphrase.count + 1)
    defer { copy.withUnsafeMutableBytes { Engine.wipe($0.baseAddress, count: $0.count) } }
    copy.withUnsafeMutableBytes { $0.copyBytes(from: passphrase) }
    return try copy.withUnsafeBufferPointer { try parse(file, $0.baseAddress) }
  }

  private static func parse(_ file: Data, _ passphrase: UnsafePointer<CChar>?) throws -> SSHKey {
    let key = try SSHTransportEngine.preferred.backend.parseKey(file, passphrase: passphrase)
    let algorithm = key.algorithm
    guard let kind = Kind(rawValue: algorithm) else { throw SSHTransportError.unsupportedAuthentication(algorithm) }
    return SSHKey(kind: kind, publicKey: key.publicKey, fingerprint: key.fingerprint, hardwareBacked: false,
                  backing: .engine(key))
  }

  public init(ed25519 key: Curve25519.Signing.PrivateKey) {
    var blob = Data()
    blob.appendSSHString(Data(Kind.ed25519.rawValue.utf8))
    blob.appendSSHString(key.publicKey.rawRepresentation)
    self.init(kind: .ed25519, publicKeyBlob: blob, hardwareBacked: false) { try key.signature(for: $0) }
  }

  /// A software P-256 key presented as `ecdsa-sha2-nistp256`.
  public init(p256 key: P256.Signing.PrivateKey) {
    self.init(kind: .ecdsaP256, publicKeyBlob: Self.p256Blob(key.publicKey), hardwareBacked: false) {
      try key.signature(for: $0).rawRepresentation
    }
  }

  #if canImport(Darwin)
  /// A Secure Enclave P-256 key: the enclave signs (with its access control, such as Face ID).
  public init(secureEnclave key: SecureEnclave.P256.Signing.PrivateKey) {
    self.init(kind: .ecdsaP256, publicKeyBlob: Self.p256Blob(key.publicKey), hardwareBacked: true) {
      try key.signature(for: $0).rawRepresentation
    }
  }
  #endif

  /// Any other external signer (a Keychain-held key): its SSH public key blob and a raw signer.
  public init(kind: Kind, publicKeyBlob blob: Data, hardwareBacked: Bool, sign: @escaping Signer) {
    self.init(kind: kind, publicKey: kind.rawValue + " " + blob.base64EncodedString(),
              fingerprint: SSHFingerprint.sha256(blob: blob), hardwareBacked: hardwareBacked,
              backing: .signer(blob: blob, sign: sign))
  }

  private init(kind: Kind, publicKey: String, fingerprint: String, hardwareBacked: Bool, backing: Backing) {
    self.kind = kind
    self.publicKey = publicKey
    self.fingerprint = fingerprint
    self.hardwareBacked = hardwareBacked
    self.backing = backing
  }

  private static func p256Blob(_ key: P256.Signing.PublicKey) -> Data {
    var blob = Data()
    blob.appendSSHString(Data(Kind.ecdsaP256.rawValue.utf8))
    blob.appendSSHString(Data("nistp256".utf8))
    blob.appendSSHString(key.x963Representation)
    return blob
  }
}

enum SSHFingerprint {
  static func sha256(blob: Data) -> String {
    "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
  }
}
