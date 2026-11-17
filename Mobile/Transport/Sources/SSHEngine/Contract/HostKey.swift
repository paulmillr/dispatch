import CryptoKit
import Foundation

/// The server's host key as an exchange presented it: what the trust callback is shown and what every re-exchange is
/// held to (`HostKeyPin`). The transport makes one from the first exchange's reply, verifies the exchange's signature
/// with `key`, and only then shows it to the trust callback.
public struct HostKey: Sendable, Hashable {
  /// The negotiated host key signature algorithm (`rsa-sha2-512` for an RSA key).
  public let algorithm: SignatureAlgorithm
  /// The public key blob as received; canonical (`PublicKeyBlob` refuses non-canonical encodings), so equal keys
  /// have equal blobs.
  public let blob: [UInt8]
  /// The blob decoded.
  public let key: PublicKeyBlob

  /// Fails unless `blob` decodes and its type is `algorithm`'s key type.
  public init(algorithm: SignatureAlgorithm, blob: [UInt8]) throws(SSHError) {
    let key: PublicKeyBlob
    do {
      key = try PublicKeyBlob(decoding: blob)
    } catch .unsupportedType(let type) where type.hasSuffix(PublicKeyBlob.certificateSuffix) {
      throw .protocolViolation(.keyExchange(.hostKeyCertificate))
    } catch {
      throw .protocolViolation(.keyExchange(.hostKeyTypeMismatch))
    }
    guard key.keyType == algorithm.keyType else { throw .protocolViolation(.keyExchange(.hostKeyTypeMismatch)) }
    self.algorithm = algorithm
    self.blob = blob
    self.key = key
  }

  /// The blob's type: `ssh-ed25519`, `ecdsa-sha2-nistp256`, `ssh-rsa`.
  public var keyType: String { key.keyType }

  /// `SHA256:` and the unpadded base64 of the blob's SHA-256, as `ssh-keygen -lf` prints it.
  public var fingerprint: String {
    let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
    return "SHA256:" + digest.prefix { $0 != "=" }
  }

  /// The OpenSSH public key line, `<keyType> <base64>`: what a known-hosts store keeps.
  public var openSSH: String { keyType + " " + Data(blob).base64EncodedString() }
}

/// The trust decision for the first exchange's host key. Called at most once per connection, never for a
/// re-exchange. May take as long as the user needs (the handshake deadline pauses meanwhile); nothing is sent past
/// the key exchange until it answers. If the connect is abandoned (deadline, cancellation) the calling task is
/// cancelled and the answer, if any, is ignored. `true` trusts the key; `false` ends the connect with
/// `SSHError.hostKeyRejected`.
public typealias HostKeyTrust = @Sendable (HostKey) async -> Bool

/// The rekey rule: every re-exchange must present the first exchange's host key blob and algorithm, or the connection
/// ends before the new keys carry anything (stricter than OpenSSH; docs/security.md, Dispatch for iPhone).
public struct HostKeyPin: Sendable, Hashable {
  public let trusted: HostKey

  /// Pins `trusted`, the key the trust callback (or a trusted store behind it) accepted at the first exchange.
  public init(_ trusted: HostKey) { self.trusted = trusted }

  /// Throws `SSHError.hostKeyChangedAtRekey` unless a re-exchange's negotiated host key algorithm and the blob its
  /// reply carried are the pinned ones. Run on the raw blob, before decoding it: anything but the trusted blob
  /// (a certificate, an undecodable blob) is a change. Another algorithm is reported as such even when the key differs
  /// too. The exchange's signature is then verified with `trusted.key`; the new keys are used only after both passed.
  public func check(algorithm: SignatureAlgorithm, blob: [UInt8]) throws(SSHError) {
    guard algorithm == trusted.algorithm else {
      throw .hostKeyChangedAtRekey(.differentAlgorithm(trusted: trusted.algorithm, presented: algorithm))
    }
    guard blob == trusted.blob else { throw .hostKeyChangedAtRekey(.differentKey) }
  }
}

/// Verifies the server's signature over an exchange hash (`SSHSignatureVerifier`, Keys/SignatureVerifier.swift). Pure:
/// no state, no I/O.
public protocol HostKeySignatureVerifier {
  /// Throws `ProtocolViolation.keyExchange(.invalidSignature)` unless `signatureBlob` is a valid `algorithm`
  /// signature over `data` by `key`. The blob's algorithm name must be `algorithm`'s exactly (no `ssh-rsa` for an
  /// RSA key: SHA-1 signatures are refused). The key's own bounds (`Limits.rsaMinimumBits`, a point on the curve) are
  /// enforced here too.
  func verify(signatureBlob: [UInt8], over data: [UInt8], key: PublicKeyBlob, algorithm: SignatureAlgorithm)
    throws(SSHError)
}
