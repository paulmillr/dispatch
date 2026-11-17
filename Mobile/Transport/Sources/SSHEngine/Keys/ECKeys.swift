import CryptoKit
import Foundation

/// ECDSA private keys through CryptoKit, made from their scalar.
enum ECKeys {
  /// The key for `scalar` (a big-endian magnitude of at most `curve.scalarBytes`, left-padded here) and its public
  /// point (uncompressed SEC1). CryptoKit refuses 0 and scalars at or above the curve's order: `damaged`.
  static func privateKey(curve: ECDSACurve, scalar: SecretBytes) throws(SSHError) -> (FileKey.Material, point: [UInt8]) {
    guard !scalar.isEmpty, let padded = scalar.leftPadded(to: curve.scalarBytes) else {
      throw KeyFileProblem.damaged.error
    }
    do {
      switch curve {
      case .p256:
        let key = try P256.Signing.PrivateKey(rawRepresentation: padded)
        return (.p256(key), Array(key.publicKey.x963Representation))
      case .p384:
        let key = try P384.Signing.PrivateKey(rawRepresentation: padded)
        return (.p384(key), Array(key.publicKey.x963Representation))
      case .p521:
        let key = try P521.Signing.PrivateKey(rawRepresentation: padded)
        return (.p521(key), Array(key.publicKey.x963Representation))
      }
    } catch {
      throw KeyFileProblem.damaged.error
    }
  }

  /// The curve's base point G (uncompressed SEC1): the public key of the scalar 1, so it is CryptoKit's own constant.
  static func generator(_ curve: ECDSACurve) -> [UInt8] {
    let one = SecretBytes(copying: [UInt8](repeating: 0, count: curve.scalarBytes - 1) + [1])
    return (try? privateKey(curve: curve, scalar: one))?.point ?? []
  }
}

/// The NIST curves as a PEM file names them (RFC 5480 §2.1.1): a named-curve OID, or the explicit parameters
/// (`SpecifiedECDomain`, SEC 1 §C.2) that macOS's ssh-keygen writes (it links LibreSSL, which writes them for
/// `-m PEM` and `-m PKCS8`). Explicit parameters are accepted only when every field is the named curve's (FIPS 186-4
/// D.1.2): p, a = p - 3, b, G uncompressed, n, and h = 1 when present; the seed is ignored. Anything else is another
/// curve: `KeyFileRefusal.keyType`.
struct ECDomain {
  let curve: ECDSACurve
  /// The OID's contents (the DER after tag and length).
  let oid: [UInt8]
  let prime: [UInt8]
  let b: [UInt8]
  let order: [UInt8]

  static let all: [ECDomain] = [
    ECDomain(
      curve: .p256, oid: [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07],  // 1.2.840.10045.3.1.7
      prime: hex("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff"),
      b: hex("5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b"),
      order: hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")),
    ECDomain(
      curve: .p384, oid: [0x2B, 0x81, 0x04, 0x00, 0x22],  // 1.3.132.0.34
      prime: hex("fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff"),
      b: hex("b3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875ac656398d8a2ed19d2a85c8edd3ec2aef"),
      order: hex("ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973")),
    ECDomain(
      curve: .p521, oid: [0x2B, 0x81, 0x04, 0x00, 0x23],  // 1.3.132.0.35
      prime: [0x01] + [UInt8](repeating: 0xFF, count: 65),  // 2^521 - 1
      b: hex("0051953eb9618e1c9a1f929a21a0b68540eea2da725b99b315f3b8b489918ef109e156193951ec7e937b1652c0bd3bb1bf07"
        + "3573df883d2c34f1ef451fd46b503f00"),
      order: hex("01fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffa51868783bf2f966b7fcc0148f709a5d0"
        + "3bb5c9b8899c47aebb6fb71e91386409")),
  ]

  /// a = p - 3 for all three curves (each prime ends in 0xFF, so only the last byte changes).
  var a: [UInt8] { prime.dropLast() + [prime[prime.count - 1] - 3] }

  /// 1.2.840.10045.1.1, the field type of a prime curve.
  private static let primeField: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x01, 0x01]

  /// The curve an `ECParameters` element names (the reader's next element: an OID or a `SpecifiedECDomain`).
  static func curve(_ reader: inout DERReader) throws(SSHError) -> ECDSACurve {
    switch reader.nextTag {
    case DERReader.objectIdentifier:
      let range = try reader.read(DERReader.objectIdentifier)
      let oid = reader[range]
      guard let domain = all.first(where: { $0.oid.elementsEqual(oid) }) else { throw KeyFileRefusal.keyType.error }
      return domain.curve
    case DERReader.sequence:
      return try explicit(&reader)
    default:
      throw KeyFileProblem.damaged.error
    }
  }

  private static func explicit(_ outer: inout DERReader) throws(SSHError) -> ECDSACurve {
    var domain = outer.reader(for: try outer.read(DERReader.sequence))
    guard (1...3).contains(try domain.readSmallInteger()) else { throw KeyFileProblem.damaged.error }
    var field = domain.reader(for: try domain.read(DERReader.sequence))
    let fieldType = try field.read(DERReader.objectIdentifier)
    guard field[fieldType].elementsEqual(primeField) else { throw KeyFileRefusal.keyType.error }
    let primeRange = try field.readUnsignedInteger()
    try field.expectEnd()
    var curveFields = domain.reader(for: try domain.read(DERReader.sequence))
    let aRange = try curveFields.read(DERReader.octetString)
    let bRange = try curveFields.read(DERReader.octetString)
    _ = try curveFields.readOptional(DERReader.bitString)
    try curveFields.expectEnd()
    let baseRange = try domain.read(DERReader.octetString)
    let orderRange = try domain.readUnsignedInteger()
    let cofactor = domain.nextTag == DERReader.integer ? try domain.readSmallInteger() : 1
    try domain.expectEnd()
    let prime = field[primeRange], a = curveFields[aRange], b = curveFields[bRange]
    let base = domain[baseRange], order = domain[orderRange]

    guard let match = all.first(where: { sameMagnitude($0.prime, prime) }), sameMagnitude(match.a, a),
      sameMagnitude(match.b, b), sameMagnitude(match.order, order), cofactor == 1,
      base.elementsEqual(ECKeys.generator(match.curve))
    else { throw KeyFileRefusal.keyType.error }
    return match.curve
  }

  private static func sameMagnitude(_ x: some Collection<UInt8>, _ y: some Collection<UInt8>) -> Bool {
    x.drop { $0 == 0 }.elementsEqual(y.drop { $0 == 0 })
  }

  private static func hex(_ text: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var high: UInt8?
    for character in text {
      guard let nibble = character.hexDigitValue.map(UInt8.init) else { continue }
      if let value = high {
        bytes.append(value << 4 | nibble)
        high = nil
      } else {
        high = nibble
      }
    }
    return bytes
  }
}
