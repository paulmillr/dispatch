import CryptoKit
import Foundation
import Security

/// A private key from a key file (`KeyFile.parse`): the `UserKey` the engine signs with itself. The private half lives
/// in a CryptoKit key (Ed25519, ECDSA) or a Security `SecKey` (RSA) and never leaves it; the file's bytes were wiped.
/// Signs only with `algorithms` (RSA: rsa-sha2-512 and rsa-sha2-256, never ssh-rsa).
public final class FileKey: UserKey, CustomStringConvertible {
  /// The private half. CryptoKit's keys and `SecKey` are immutable and safe to use from any thread.
  enum Material: @unchecked Sendable {
    case ed25519(Curve25519.Signing.PrivateKey)
    case p256(P256.Signing.PrivateKey)
    case p384(P384.Signing.PrivateKey)
    case p521(P521.Signing.PrivateKey)
    case rsa(SecKey)
  }

  public let publicKey: PublicKeyBlob
  public let publicKeyBlob: [UInt8]
  /// The file's comment (`openssh-key-v1` has one; PEM files have none: empty). Decoded leniently: invalid UTF-8
  /// shows replacement characters.
  public let comment: String
  let material: Material

  init(material: Material, publicKey: PublicKeyBlob, comment: String) {
    self.material = material
    self.publicKey = publicKey
    publicKeyBlob = publicKey.encoded
    self.comment = comment
  }

  /// `ssh-ed25519`, `ecdsa-sha2-nistp256` (384, 521) or `ssh-rsa`.
  public var keyType: String { publicKey.keyType }

  /// The algorithms this key signs with, preferred first.
  public var algorithms: [SignatureAlgorithm] { SignatureAlgorithm.algorithms(for: publicKey) }

  /// The `authorized_keys` line: `<type> <base64 of the blob>`, then a space and the comment when there is one (as
  /// ssh-keygen writes the `.pub` file and the russh engine showed it).
  public var authorizedKeysLine: String { PublicKeyText.line(blob: publicKeyBlob, key: publicKey, comment: comment) }

  /// `SHA256:` and the unpadded base64 of the blob's SHA-256, as `ssh-keygen -lf` prints it.
  public var fingerprint: String { PublicKeyText.fingerprint(blob: publicKeyBlob, key: publicKey) }

  public var description: String { "FileKey(\(keyType) \(fingerprint))" }

  public func sign(_ data: [UInt8], algorithm: SignatureAlgorithm) async throws(SSHError) -> [UInt8] {
    try signature(for: data, algorithm: algorithm)
  }

  /// The signature blob for `data`, synchronously.
  public func signature(for data: [UInt8], algorithm: SignatureAlgorithm) throws(SSHError) -> [UInt8] {
    guard algorithms.contains(algorithm) else {
      throw .usage(.invalidArgument("a \(keyType) key cannot sign \(algorithm.rawValue)"))
    }
    let signature: [UInt8]
    do {
      switch material {
      case .ed25519(let key):
        signature = Array(try key.signature(for: data))
      case .p256(let key):
        signature = try ECDSASignature.inner(fromRaw: Array(try key.signature(for: data).rawRepresentation), curve: .p256)
      case .p384(let key):
        signature = try ECDSASignature.inner(fromRaw: Array(try key.signature(for: data).rawRepresentation), curve: .p384)
      case .p521(let key):
        signature = try ECDSASignature.inner(fromRaw: Array(try key.signature(for: data).rawRepresentation), curve: .p521)
      case .rsa(let key):
        guard let secAlgorithm = RSAKeys.secAlgorithm(algorithm),
          let signed = SecKeyCreateSignature(key, secAlgorithm, Data(data) as CFData, nil)
        else { throw SSHError.invalidKey("the key could not sign") }
        signature = Array(signed as Data)
      }
      return try SignatureBlob(algorithm: algorithm.rawValue, signature: signature).encoded()
    } catch let error as SSHError {
      throw error
    } catch {
      throw .invalidKey("the key could not sign")
    }
  }
}

/// The public texts of a user key, as the foundation's `HostKey` writes them for host keys.
public enum PublicKeyText {
  /// `SHA256:` and the unpadded base64 of the blob's SHA-256.
  public static func fingerprint(blob: [UInt8], key: PublicKeyBlob) -> String {
    hostKey(blob: blob, key: key)?.fingerprint ?? ""
  }

  /// `<type> <base64>`, then a space and `comment` when it is not empty. Control characters in the comment (a line
  /// break would split the `authorized_keys` line) become spaces.
  public static func line(blob: [UInt8], key: PublicKeyBlob, comment: String) -> String {
    let base = hostKey(blob: blob, key: key)?.openSSH ?? ""
    let cleaned = String(String.UnicodeScalarView(comment.unicodeScalars.map {
      $0.properties.generalCategory == .control || $0.properties.isWhitespace && $0 != " " ? " " : $0
    })).trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? base : base + " " + cleaned
  }

  private static func hostKey(blob: [UInt8], key: PublicKeyBlob) -> HostKey? {
    guard let algorithm = SignatureAlgorithm.algorithms(for: key).first else { return nil }
    return try? HostKey(algorithm: algorithm, blob: blob)
  }
}
