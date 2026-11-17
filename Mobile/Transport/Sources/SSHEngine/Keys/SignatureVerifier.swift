import CryptoKit
import Foundation
import Security

/// The production `HostKeySignatureVerifier`: Ed25519 and ECDSA through CryptoKit, RSA (rsa-sha2-512/256,
/// RSASSA-PKCS1-v1_5, RFC 8332) through Security. Pure and stateless. Everything that is not a valid signature by
/// `key` over `data` under `algorithm` is `ProtocolViolation.keyExchange(.invalidSignature)`, never a trap: a blob
/// that does not decode, another algorithm name in the blob (`ssh-rsa`, SHA-1, included), a key of another type or
/// curve, a key outside its bounds (`Limits.rsaMinimumBits...rsaMaximumBits` and the exponent bound, re-checked
/// here for keys built by hand; a point CryptoKit refuses as off its curve), a signature of the wrong size.
///
/// Sizes: Ed25519's signature is 64 bytes; ECDSA's is mpint r, mpint s, each non-zero and within the curve's scalar
/// size (`ECDSASignature.raw`), and CryptoKit refuses values at or above the order. RSA's is at most the modulus'
/// size; a shorter one is left-padded with zeros, as OpenSSH does (RFC 8332 says equal; some signers drop leading
/// zero bytes).
public struct SSHSignatureVerifier: HostKeySignatureVerifier, Sendable {
  public init() {}

  public func verify(signatureBlob: [UInt8], over data: [UInt8], key: PublicKeyBlob,
                     algorithm: SignatureAlgorithm) throws(SSHError) {
    guard Self.isValid(signatureBlob: signatureBlob, over: data, key: key, algorithm: algorithm) else {
      throw .protocolViolation(.keyExchange(.invalidSignature))
    }
  }

  /// Whether `signatureBlob` is a valid `algorithm` signature over `data` by `key`.
  public static func isValid(signatureBlob: [UInt8], over data: [UInt8], key: PublicKeyBlob,
                             algorithm: SignatureAlgorithm) -> Bool {
    guard algorithm.keyType == key.keyType, let blob = try? SignatureBlob(decoding: signatureBlob),
      blob.algorithm == algorithm.rawValue
    else { return false }
    let signature = blob.signature
    switch key {
    case .ed25519(let raw):
      guard signature.count == 64, let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
        return false
      }
      return publicKey.isValidSignature(signature, for: data)

    case .ecdsa(let curve, let point):
      guard let raw = try? ECDSASignature.raw(fromInner: signature, curve: curve) else { return false }
      switch curve {
      case .p256:
        guard let publicKey = try? P256.Signing.PublicKey(x963Representation: point),
          let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw)
        else { return false }
        return publicKey.isValidSignature(signature, for: data)
      case .p384:
        guard let publicKey = try? P384.Signing.PublicKey(x963Representation: point),
          let signature = try? P384.Signing.ECDSASignature(rawRepresentation: raw)
        else { return false }
        return publicKey.isValidSignature(signature, for: data)
      case .p521:
        guard let publicKey = try? P521.Signing.PublicKey(x963Representation: point),
          let signature = try? P521.Signing.ECDSASignature(rawRepresentation: raw)
        else { return false }
        return publicKey.isValidSignature(signature, for: data)
      }

    case .rsa(let exponent, let modulus):
      guard (try? PublicKeyBlob.checkRSA(exponent: exponent, modulus: modulus)) != nil,
        !signature.isEmpty, signature.count <= modulus.count,
        let secAlgorithm = RSAKeys.secAlgorithm(algorithm),
        let publicKey = RSAKeys.publicKey(exponent: exponent, modulus: modulus)
      else { return false }
      let padded = [UInt8](repeating: 0, count: modulus.count - signature.count) + signature
      return SecKeyVerifySignature(publicKey, secAlgorithm, Data(data) as CFData, Data(padded) as CFData, nil)
    }
  }
}
