import CryptoKit
import Foundation
import Security
@testable import SSHEngine

/// A test-only `HostKeySignatureVerifier` (the production one is `SSHSignatureVerifier`, Keys/): CryptoKit for Ed25519
/// and ECDSA, Security.framework for RSA (PKCS#1 v1.5 with SHA-256 or SHA-512). Enough to check real servers'
/// signatures in the transport's tests; it applies the contract's rules (the blob names the negotiated algorithm
/// exactly) but none of the production verifier's extra key bounds.
struct TestSignatureVerifier: HostKeySignatureVerifier {
  func verify(signatureBlob: [UInt8], over data: [UInt8], key: PublicKeyBlob, algorithm: SignatureAlgorithm) throws(SSHError) {
    let invalid = SSHError.protocolViolation(.keyExchange(.invalidSignature))
    guard let blob = try? SignatureBlob(decoding: signatureBlob), blob.algorithm == algorithm.rawValue else { throw invalid }
    let valid: Bool
    switch (key, algorithm) {
    case (.ed25519(let raw), .ed25519):
      valid = (try? Curve25519.Signing.PublicKey(rawRepresentation: raw))?.isValidSignature(blob.signature, for: data) ?? false
    case (.ecdsa(let curve, let point), .ecdsaP256), (.ecdsa(let curve, let point), .ecdsaP384),
         (.ecdsa(let curve, let point), .ecdsaP521):
      guard curve.keyType == algorithm.keyType, let raw = try? ECDSASignature.raw(fromInner: blob.signature, curve: curve) else {
        throw invalid
      }
      switch curve {
      case .p256:
        valid = (try? P256.Signing.PublicKey(x963Representation: point)).flatMap { key in
          (try? P256.Signing.ECDSASignature(rawRepresentation: raw)).map { key.isValidSignature($0, for: data) }
        } ?? false
      case .p384:
        valid = (try? P384.Signing.PublicKey(x963Representation: point)).flatMap { key in
          (try? P384.Signing.ECDSASignature(rawRepresentation: raw)).map { key.isValidSignature($0, for: data) }
        } ?? false
      case .p521:
        valid = (try? P521.Signing.PublicKey(x963Representation: point)).flatMap { key in
          (try? P521.Signing.ECDSASignature(rawRepresentation: raw)).map { key.isValidSignature($0, for: data) }
        } ?? false
      }
    case (.rsa(let exponent, let modulus), .rsaSHA256), (.rsa(let exponent, let modulus), .rsaSHA512):
      valid = Self.verifyRSA(signature: blob.signature, data: data, exponent: exponent, modulus: modulus,
                             sha512: algorithm == .rsaSHA512)
    default:
      throw invalid
    }
    guard valid else { throw invalid }
  }

  private static func verifyRSA(signature: [UInt8], data: [UInt8], exponent: [UInt8], modulus: [UInt8], sha512: Bool) -> Bool {
    // PKCS#1 RSAPublicKey: SEQUENCE { INTEGER n, INTEGER e }.
    let der = DER.sequence(DER.integer(modulus) + DER.integer(exponent))
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
    guard let key = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, nil) else { return false }
    let algorithm: SecKeyAlgorithm = sha512 ? .rsaSignatureMessagePKCS1v15SHA512 : .rsaSignatureMessagePKCS1v15SHA256
    return SecKeyVerifySignature(key, algorithm, Data(data) as CFData, Data(signature) as CFData, nil)
  }
}

/// Just enough DER for an RSA public key.
enum DER {
  static func length(_ count: Int) -> [UInt8] {
    if count < 0x80 { return [UInt8(count)] }
    var bytes: [UInt8] = []
    var value = count
    while value > 0 {
      bytes.insert(UInt8(value & 0xFF), at: 0)
      value >>= 8
    }
    return [0x80 | UInt8(bytes.count)] + bytes
  }

  static func integer(_ magnitude: [UInt8]) -> [UInt8] {
    let trimmed = Array(magnitude.drop { $0 == 0 })
    // A leading 0x00 keeps a high bit from reading as a sign (and zero is one 0x00).
    let needsZero = trimmed.first.map { $0 & 0x80 != 0 } ?? true
    let body = needsZero ? [0] + trimmed : trimmed
    return [0x02] + length(body.count) + body
  }

  static func sequence(_ body: [UInt8]) -> [UInt8] { [0x30] + length(body.count) + body }
}

/// A server's host key in the scripted server: CryptoKit signs (Ed25519; ECDSA for the pin's other algorithm).
enum ServerHostKey {
  case ed25519(Curve25519.Signing.PrivateKey)
  case ecdsaP256(P256.Signing.PrivateKey)

  /// A fresh fictional key from `seed` (generated at test time, never a real one).
  static func ed25519(seed: UInt8) -> ServerHostKey {
    // swiftlint:disable:next force_try
    .ed25519(try! Curve25519.Signing.PrivateKey(rawRepresentation: [UInt8](repeating: seed, count: 32)))
  }

  static func ecdsaP256(seed: UInt8) -> ServerHostKey {
    var scalar = [UInt8](repeating: seed, count: 32)
    scalar[0] = 0x01
    // swiftlint:disable:next force_try
    return .ecdsaP256(try! P256.Signing.PrivateKey(rawRepresentation: scalar))
  }

  var algorithm: SignatureAlgorithm {
    switch self {
    case .ed25519: .ed25519
    case .ecdsaP256: .ecdsaP256
    }
  }

  var publicBlob: [UInt8] {
    switch self {
    case .ed25519(let key): PublicKeyBlob.ed25519(Array(key.publicKey.rawRepresentation)).encoded
    case .ecdsaP256(let key): PublicKeyBlob.ecdsa(.p256, point: Array(key.publicKey.x963Representation)).encoded
    }
  }

  /// The signature blob over `data`.
  func sign(_ data: [UInt8]) -> [UInt8] {
    switch self {
    case .ed25519(let key):
      // swiftlint:disable:next force_try
      let signature = try! key.signature(for: data)
      // swiftlint:disable:next force_try
      return try! SignatureBlob(algorithm: algorithm.rawValue, signature: Array(signature)).encoded()
    case .ecdsaP256(let key):
      // swiftlint:disable:next force_try
      let raw = Array(try! key.signature(for: data).rawRepresentation)
      // swiftlint:disable:next force_try
      let inner = try! ECDSASignature.inner(fromRaw: raw, curve: .p256)
      // swiftlint:disable:next force_try
      return try! SignatureBlob(algorithm: algorithm.rawValue, signature: inner).encoded()
    }
  }
}
