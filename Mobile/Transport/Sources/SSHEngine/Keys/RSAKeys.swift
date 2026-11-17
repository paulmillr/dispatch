import Foundation
import Security

/// RSA keys through Security.framework: private keys imported from PKCS#1 (`SecKeyCreateWithData`), public keys from
/// e and n, and the signing check every imported key passes. The PKCS#1 bytes are handed over in a `CFMutableData`
/// that is wiped as soon as the import returned (Security keeps its own copy inside the `SecKey`).
enum RSAKeys {
  /// What the pairwise check signs: fixed, public, signed once per imported key.
  private static let probe = Array("SSHEngine RSA key check".utf8)

  /// A private key from a PKCS#1 `RSAPrivateKey` (RFC 8017 A.1.2), as `RSA PRIVATE KEY` holds it.
  static func privateKey(pkcs1 der: UnsafeRawBufferPointer) throws(SSHError) -> SecKey {
    guard let data = CFDataCreateMutable(kCFAllocatorDefault, der.count) else { throw KeyFileProblem.damaged.error }
    CFDataSetLength(data, der.count)
    let pointer = CFDataGetMutableBytePtr(data)
    defer {
      _ = memset_s(pointer, der.count, 0, der.count)
      CFDataSetLength(data, 0)
    }
    if let pointer, let base = der.baseAddress { pointer.update(from: base.assumingMemoryBound(to: UInt8.self), count: der.count) }
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
    guard let key = SecKeyCreateWithData(data, attributes as CFDictionary, nil) else {
      throw KeyFileProblem.damaged.error
    }
    return key
  }

  /// A private key from `openssh-key-v1`'s fields (n, e, d, iqmp = q⁻¹ mod p, p, q): the two CRT exponents PKCS#1
  /// also needs are computed (`RSAArithmetic`), then the key is imported as PKCS#1. n and e are the file's validated
  /// public key, so a refused import means the private fields do not belong to them: `mismatchedHalves`.
  static func privateKey(modulus n: [UInt8], exponent e: [UInt8], d: SecretBytes, iqmp: SecretBytes, p: SecretBytes,
                         q: SecretBytes) throws(SSHError) -> SecKey {
    guard let dP = RSAArithmetic.exponent(d, prime: p), let dQ = RSAArithmetic.exponent(d, prime: q) else {
      throw KeyFileProblem.mismatchedHalves.error
    }
    let der = DERWriter.sequenceOfIntegers([[UInt8](), n, e, d, p, q, dP, dQ, iqmp])
    do {
      return try der.withBytes { (bytes) throws(SSHError) in try privateKey(pkcs1: bytes) }
    } catch {
      throw KeyFileProblem.mismatchedHalves.error
    }
  }

  /// A public key from e and n (PKCS#1 `RSAPublicKey`), nil when Security refuses it.
  static func publicKey(exponent e: [UInt8], modulus n: [UInt8]) -> SecKey? {
    let der = DERWriter.sequenceOfIntegers([n, e])
    let data = der.withUnsafeBytes { Data($0) } as CFData
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
    return SecKeyCreateWithData(data, attributes as CFDictionary, nil)
  }

  /// The pairwise check: `key` signs a probe (rsa-sha2-512) that verifies under e and n, so the private half is the
  /// public half's and its CRT values are right. `KeyFileProblem.mismatchedHalves` otherwise.
  static func checkPair(_ key: SecKey, exponent e: [UInt8], modulus n: [UInt8]) throws(SSHError) {
    guard let publicKey = publicKey(exponent: e, modulus: n),
      let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA512, Data(probe) as CFData, nil),
      SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA512, Data(probe) as CFData, signature, nil)
    else { throw KeyFileProblem.mismatchedHalves.error }
  }

  static func secAlgorithm(_ algorithm: SignatureAlgorithm) -> SecKeyAlgorithm? {
    switch algorithm {
    case .rsaSHA512: .rsaSignatureMessagePKCS1v15SHA512
    case .rsaSHA256: .rsaSignatureMessagePKCS1v15SHA256
    case .ed25519, .ecdsaP256, .ecdsaP384, .ecdsaP521: nil
    }
  }
}
