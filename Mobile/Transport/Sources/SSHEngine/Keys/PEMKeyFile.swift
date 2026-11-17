import CryptoKit
import Foundation
import Security

/// Unencrypted PEM key files: `RSA PRIVATE KEY` (PKCS#1, RFC 8017 A.1.2), `EC PRIVATE KEY` (SEC1, RFC 5915) and
/// `PRIVATE KEY` (PKCS#8 / RFC 5958 holding RSA, EC or Ed25519 per RFC 8410). None carries a comment.
///
/// What Apple's importers do, and what is parsed here instead:
/// - RSA: Security.framework imports the PKCS#1 structure itself (`SecKeyCreateWithData`). Here: only the version,
///   n and e (to check `Limits` before the import), the structure's shape, and PKCS#8's envelope, which Security
///   does not read.
/// - EC: CryptoKit's DER and PEM initialisers were tried and are not usable for these files (macOS 27): they refuse
///   the explicit curve parameters macOS's ssh-keygen writes (`ECDomain`), refuse an OpenSSL P-521 SEC1 key, and take
///   a secp256k1 PKCS#8 key as P-256 without checking its curve. So the SEC1 structure is read here (version,
///   scalar, curve, optional public key) and CryptoKit makes the key from the scalar.
/// - Ed25519: CryptoKit has no DER initialiser; RFC 8410's `CurvePrivateKey` is a 32-byte OCTET STRING.
///
/// Every key passes a consistency check: an embedded public key must be the private key's; RSA signs and verifies once
/// (`RSAKeys.checkPair`). That proves the CRT values Security signs with (p, q, dP, dQ, qInv); a PKCS#1 d that
/// disagrees with them goes unnoticed, and is harmless: Security never uses it.
enum PEMKeyFile {
  /// The PKCS#8 algorithm OIDs (contents only).
  enum OID {
    static let rsaEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]  // 1.2.840.113549.1.1.1
    static let ecPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]  // 1.2.840.10045.2.1
    static let ed25519: [UInt8] = [0x2B, 0x65, 0x70]  // 1.3.101.112
    static let dsa: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x38, 0x04, 0x01]  // 1.2.840.10040.4.1
  }

  static func parse(label: String, body: SecretBytes) throws(SSHError) -> FileKey {
    try body.withTemporaryArray { (der) throws(SSHError) -> FileKey in
      var top = DERReader(der)
      let outer = try top.readElement(DERReader.sequence)
      try top.expectEnd()
      switch label {
      case "RSA PRIVATE KEY": return try rsa(der, element: outer.element, publicKey: nil)
      case "EC PRIVATE KEY": return try ec(der, contents: outer.contents, curve: nil, publicKey: nil)
      default: return try pkcs8(der, contents: outer.contents)
      }
    }
  }

  /// `PrivateKeyInfo` / `OneAsymmetricKey`: version 0 or 1, the algorithm, the private key, optional attributes
  /// (ignored) and, in version 1, an optional public key that must match.
  private static func pkcs8(_ der: [UInt8], contents: Range<Int>) throws(SSHError) -> FileKey {
    var info = DERReader(der, range: contents)
    let version = try info.readSmallInteger()
    guard version <= 1 else { throw KeyFileProblem.damaged.error }
    var algorithm = info.reader(for: try info.read(DERReader.sequence))
    let privateKey = try info.read(DERReader.octetString)
    _ = try info.readOptional(DERReader.context0)
    let publicKey = version == 1 && info.nextTag == DERReader.context1Primitive
      ? try info.readOctetAlignedBitString(DERReader.context1Primitive) : nil
    try info.expectEnd()

    let oidRange = try algorithm.read(DERReader.objectIdentifier)
    let oid = Array(algorithm[oidRange])
    var inner = DERReader(der, range: privateKey)
    switch oid {
    case OID.rsaEncryption:
      // Parameters: NULL, or (as some writers do) absent.
      if let null = try algorithm.readOptional(DERReader.null), !null.isEmpty { throw KeyFileProblem.damaged.error }
      try algorithm.expectEnd()
      let element = try inner.readElement(DERReader.sequence)
      try inner.expectEnd()
      return try rsa(der, element: element.element, publicKey: publicKey)
    case OID.ecPublicKey:
      let curve = try ECDomain.curve(&algorithm)
      try algorithm.expectEnd()
      let contents = try inner.read(DERReader.sequence)
      try inner.expectEnd()
      return try ec(der, contents: contents, curve: curve, publicKey: publicKey)
    case OID.ed25519:
      try algorithm.expectEnd()
      let seed = try inner.read(DERReader.octetString)
      try inner.expectEnd()
      guard seed.count == 32 else { throw KeyFileProblem.damaged.error }
      let key: Curve25519.Signing.PrivateKey
      do { key = try Curve25519.Signing.PrivateKey(rawRepresentation: SecretBytes.copying(der, range: seed)) } catch {
        throw KeyFileProblem.damaged.error
      }
      let point = Array(key.publicKey.rawRepresentation)
      if let publicKey, !der[publicKey].elementsEqual(point) { throw KeyFileProblem.mismatchedHalves.error }
      return FileKey(material: .ed25519(key), publicKey: .ed25519(point), comment: "")
    case OID.dsa:
      throw KeyFileRefusal.dsa.error
    default:
      throw KeyFileRefusal.keyType.error
    }
  }

  /// PKCS#1 `RSAPrivateKey`: version 0 (two primes; multi-prime version 1 is refused), then n, e, d, p, q, dP, dQ,
  /// qInv, nothing after. Security imports `element` (the whole SEQUENCE).
  private static func rsa(_ der: [UInt8], element: Range<Int>, publicKey: Range<Int>?) throws(SSHError) -> FileKey {
    var outer = DERReader(der, range: element)
    var key = outer.reader(for: try outer.read(DERReader.sequence))
    guard try key.readSmallInteger() == 0 else { throw KeyFileProblem.damaged.error }
    let modulusRange = try key.readUnsignedInteger()
    let exponentRange = try key.readUnsignedInteger()
    for _ in 0..<6 { _ = try key.readUnsignedInteger() }
    try key.expectEnd()
    let modulus = Array(der[modulusRange]), exponent = Array(der[exponentRange])
    try checkRSASize(exponent: exponent, modulus: modulus)

    let secKey = try SecretBytes.copying(der, range: element).withBytes { (bytes) throws(SSHError) in
      try RSAKeys.privateKey(pkcs1: bytes)
    }
    try RSAKeys.checkPair(secKey, exponent: exponent, modulus: modulus)
    if let publicKey {
      let expected = DERWriter.sequenceOfIntegers([modulus, exponent]).withUnsafeBytes { Array($0) }
      guard der[publicKey].elementsEqual(expected) else { throw KeyFileProblem.mismatchedHalves.error }
    }
    return FileKey(material: .rsa(secKey), publicKey: .rsa(exponent: exponent, modulus: modulus), comment: "")
  }

  /// SEC1 `ECPrivateKey`: version 1, the scalar, `[0]` parameters (required unless PKCS#8 named the curve, and then
  /// the same curve), `[1]` the public key (when present, the scalar's).
  private static func ec(_ der: [UInt8], contents: Range<Int>, curve outer: ECDSACurve?,
                         publicKey: Range<Int>?) throws(SSHError) -> FileKey {
    var key = DERReader(der, range: contents)
    guard try key.readSmallInteger() == 1 else { throw KeyFileProblem.damaged.error }
    let scalar = try key.read(DERReader.octetString)
    var curve = outer
    if let parameters = try key.readOptional(DERReader.context0) {
      var reader = key.reader(for: parameters)
      let named = try ECDomain.curve(&reader)
      try reader.expectEnd()
      if let outer, outer != named { throw KeyFileProblem.damaged.error }
      curve = named
    }
    var inner: Range<Int>?
    if let wrapped = try key.readOptional(DERReader.context1) {
      var reader = key.reader(for: wrapped)
      inner = try reader.readOctetAlignedBitString()
      try reader.expectEnd()
    }
    try key.expectEnd()
    guard let curve else { throw KeyFileProblem.damaged.error }
    let (material, point) = try ECKeys.privateKey(curve: curve, scalar: SecretBytes.copying(der, range: scalar))
    for range in [inner, publicKey].compactMap({ $0 }) where !der[range].elementsEqual(point) {
      throw KeyFileProblem.mismatchedHalves.error
    }
    return FileKey(material: material, publicKey: .ecdsa(curve, point: point), comment: "")
  }

  /// `Limits`' RSA bounds: a size outside them is `KeyFileRefusal.rsaKeySize`; another violation (an even modulus,
  /// an exponent of 1 or above `Limits.rsaExponentBytes`) is `damaged`.
  static func checkRSASize(exponent: [UInt8], modulus: [UInt8]) throws(SSHError) {
    let bits = modulus.first.map { (modulus.count - 1) * 8 + (8 - $0.leadingZeroBitCount) } ?? 0
    guard (Limits.rsaMinimumBits...Limits.rsaMaximumBits).contains(bits) else { throw KeyFileRefusal.rsaKeySize.error }
    do { try PublicKeyBlob.checkRSA(exponent: exponent, modulus: modulus) } catch {
      throw KeyFileProblem.damaged.error
    }
  }
}
