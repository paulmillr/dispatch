import CryptoKit
import DispatchMobileSSHCore
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
  /// The OpenSSH public key line (`type base64`), what goes into `authorized_keys`.
  public let publicKey: String
  /// `SHA256:` fingerprint, as `ssh-keygen -lf` prints it (M8a's key list).
  public let fingerprint: String
  /// Backed by the Secure Enclave (signing needs the device; the key cannot be exported).
  public let hardwareBacked: Bool

  enum Backing: Sendable {
    case engine(KeyHandle)
    case signer(blob: Data, sign: Signer)
  }
  let backing: Backing

  /// An OpenSSH private key file (ED25519, ECDSA P-256/384/521, RSA), plain or passphrase-encrypted, or
  /// a PEM/PKCS#8 file. Parsed and decrypted by the engine.
  public static func openSSH(_ file: Data, passphrase: String? = nil) throws -> SSHKey {
    guard let passphrase else { return try openSSH(file, terminated: nil) }
    var copy = Array(passphrase.utf8CString)
    defer { copy.withUnsafeMutableBytes { Engine.wipe($0.baseAddress, count: $0.count) } }
    return try copy.withUnsafeBufferPointer { try openSSH(file, terminated: $0.baseAddress) }
  }

  /// The same with the passphrase as bytes (from the Keychain, never a `String`): its NUL-terminated copy is wiped
  /// once the engine has its own (which it wipes too). The caller owns `file` and `passphrase` and wipes them.
  public static func openSSH(_ file: Data, passphrase: Data?) throws -> SSHKey {
    guard let passphrase else { return try openSSH(file, terminated: nil) }
    var copy = [CChar](repeating: 0, count: passphrase.count + 1)
    defer { copy.withUnsafeMutableBytes { Engine.wipe($0.baseAddress, count: $0.count) } }
    copy.withUnsafeMutableBytes { target in passphrase.withUnsafeBytes { target.copyMemory(from: $0) } }
    return try copy.withUnsafeBufferPointer { try openSSH(file, terminated: $0.baseAddress) }
  }

  private static func openSSH(_ file: Data, terminated passphrase: UnsafePointer<CChar>?) throws -> SSHKey {
    var code: Int32 = 0
    var message: UnsafeMutablePointer<CChar>?
    let handle = file.withUnsafeBytes { bytes in
      dms_key_parse(bytes.bindMemory(to: UInt8.self).baseAddress, file.count, passphrase, &code, &message)
    }
    guard let handle else {
      defer { dms_string_free(message) }
      throw Engine.error(code, message)
    }
    let key = KeyHandle(handle)
    let algorithm = String(cString: dms_key_algorithm(handle))
    guard let kind = Kind(rawValue: algorithm) else { throw SSHTransportError.unsupportedAuthentication(algorithm) }
    return SSHKey(kind: kind, publicKey: String(cString: dms_key_public_key(handle)),
                  fingerprint: String(cString: dms_key_fingerprint(handle)), hardwareBacked: false, backing: .engine(key))
  }

  public init(ed25519 key: Curve25519.Signing.PrivateKey) {
    var blob = Data()
    blob.appendSSHString(Data(Kind.ed25519.rawValue.utf8))
    blob.appendSSHString(key.publicKey.rawRepresentation)
    self.init(kind: .ed25519, blob: blob, hardwareBacked: false) { try key.signature(for: $0) }
  }

  /// A software P-256 key presented as `ecdsa-sha2-nistp256`.
  public init(p256 key: P256.Signing.PrivateKey) {
    self.init(kind: .ecdsaP256, blob: Self.p256Blob(key.publicKey), hardwareBacked: false) {
      try key.signature(for: $0).rawRepresentation
    }
  }

  #if canImport(Darwin)
  /// A Secure Enclave P-256 key: the enclave signs (with its access control, such as Face ID).
  public init(secureEnclave key: SecureEnclave.P256.Signing.PrivateKey) {
    self.init(kind: .ecdsaP256, blob: Self.p256Blob(key.publicKey), hardwareBacked: true) {
      try key.signature(for: $0).rawRepresentation
    }
  }
  #endif

  /// Any other external signer (a Keychain-held key): its SSH public key blob and a raw signer.
  public init(kind: Kind, publicKeyBlob blob: Data, hardwareBacked: Bool, sign: @escaping Signer) {
    let line = kind.rawValue + " " + blob.base64EncodedString()
    self.kind = kind
    publicKey = line
    fingerprint = SSHFingerprint.sha256(blob: blob)
    self.hardwareBacked = hardwareBacked
    backing = .signer(blob: blob, sign: sign)
  }

  private init(kind: Kind, blob: Data, hardwareBacked: Bool, sign: @escaping Signer) {
    self.init(kind: kind, publicKeyBlob: blob, hardwareBacked: hardwareBacked, sign: sign)
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

/// The engine's parsed key; freed with the last SSHKey copy.
final class KeyHandle: @unchecked Sendable {
  let pointer: OpaquePointer
  init(_ pointer: OpaquePointer) { self.pointer = pointer }
  deinit { dms_key_free(pointer) }
}

enum SSHFingerprint {
  static func sha256(blob: Data) -> String {
    "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
  }
}
