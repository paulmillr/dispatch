import SSHEngine
import XCTest

/// Public key and signature blobs: canonical decoding (re-encoding gives the input back), the bounds, and refusals.
/// The keys are fixed byte patterns, not real keys (an ECDSA fixture point is not on its curve: the blob codec checks
/// structure only).
final class KeyBlobTests: XCTestCase {
  func testEd25519() throws {
    let key = try PublicKeyBlob(decoding: Fixture.ed25519Blob)
    XCTAssertEqual(key, .ed25519(Fixture.ed25519Key))
    XCTAssertEqual(key.keyType, "ssh-ed25519")
    XCTAssertEqual(key.encoded, Fixture.ed25519Blob)
    XCTAssertNil(key.rsaModulusBits)
    for length in [0, 31] {
      let blob = Raw.string("ssh-ed25519") + Raw.string([UInt8](repeating: 1, count: length))
      XCTAssertThrows(WireError.invalidValue) { () throws(WireError) in try PublicKeyBlob(decoding: blob) }
    }
    let long = Raw.string("ssh-ed25519") + Raw.string([UInt8](repeating: 1, count: 33))
    XCTAssertThrows(WireError.tooLong(limit: 32)) { () throws(WireError) in try PublicKeyBlob(decoding: long) }
  }

  func testECDSA() throws {
    for curve in ECDSACurve.allCases {
      let blob = Fixture.ecdsaBlob(curve)
      let key = try PublicKeyBlob(decoding: blob)
      XCTAssertEqual(key.keyType, curve.keyType)
      XCTAssertEqual(key.encoded, blob)
    }
    // Curve identifier of another curve, a compressed point, a short point.
    let p256 = ECDSACurve.p256
    let wrongCurve = Raw.string(p256.keyType) + Raw.string("nistp384") + Raw.string([0x04] + [UInt8](repeating: 1, count: 64))
    let compressed = Raw.string(p256.keyType) + Raw.string("nistp256") + Raw.string([0x02] + [UInt8](repeating: 1, count: 64))
    let short = Raw.string(p256.keyType) + Raw.string("nistp256") + Raw.string([0x04] + [UInt8](repeating: 1, count: 63))
    for blob in [wrongCurve, compressed, short] {
      XCTAssertThrows(WireError.invalidValue) { () throws(WireError) in try PublicKeyBlob(decoding: blob) }
    }
  }

  func testRSA() throws {
    let key = try PublicKeyBlob(decoding: Fixture.rsaBlob)
    XCTAssertEqual(key, .rsa(exponent: [0x01, 0x00, 0x01], modulus: Fixture.rsaModulus))
    XCTAssertEqual(key.rsaModulusBits, 2048)
    XCTAssertEqual(key.encoded, Fixture.rsaBlob)
    XCTAssertEqual(SignatureAlgorithm.algorithms(for: key), [.rsaSHA512, .rsaSHA256])
  }

  func testRSABounds() {
    func blob(exponent: [UInt8], modulus: [UInt8]) -> [UInt8] {
      var writer = WireWriter()
      writer.writeName("ssh-rsa")
      writer.writeMPInt(magnitude: exponent)
      writer.writeMPInt(magnitude: modulus)
      return try! writer.finish()
    }
    let small = [0xC1] + [UInt8](repeating: 0x5A, count: 126) + [0x01]  // 1024 bits
    let even = [0xC1] + [UInt8](repeating: 0x5A, count: 255)
    let large = [0xC1] + [UInt8](repeating: 0x5A, count: Limits.rsaMaximumBits / 8) + [0x01]
    for (exponent, modulus) in [
      ([UInt8]([0x01]), Fixture.rsaModulus), ([0x02], Fixture.rsaModulus), ([0x01, 0x00, 0x00], Fixture.rsaModulus),
      ([UInt8](repeating: 0x01, count: Limits.rsaExponentBytes + 1), Fixture.rsaModulus), ([0x03], small),
      ([0x03], even), ([0x03], [0x03]),
    ] {
      XCTAssertThrows(WireError.invalidValue) { () throws(WireError) in try PublicKeyBlob(decoding: blob(exponent: exponent, modulus: modulus)) }
    }
    // Too large is refused by the mpint's length before it is examined.
    XCTAssertThrows(WireError.tooLong(limit: 1 + Limits.rsaMaximumBits / 8)) { () throws(WireError) in
      try PublicKeyBlob(decoding: blob(exponent: [0x03], modulus: large))
    }
    XCTAssertNoThrow(try PublicKeyBlob(decoding: blob(exponent: [0x03], modulus: Fixture.rsaModulus)))
  }

  func testRefusedTypes() {
    for type in ["ssh-ed25519-cert-v01@openssh.com", "ssh-rsa-cert-v01@openssh.com", "ssh-dss", "sk-ssh-ed25519@openssh.com",
                 "rsa-sha2-512", "ecdsa-sha2-nistp224"] {
      let blob = Raw.string(type) + Raw.string(Fixture.ed25519Key)
      XCTAssertThrows(WireError.unsupportedType(type)) { () throws(WireError) in try PublicKeyBlob(decoding: blob) }
    }
  }

  func testNonCanonicalBlobsAreRefused() {
    // Trailing bytes; an exponent with a needless 0x00.
    XCTAssertThrows(WireError.trailingBytes) { () throws(WireError) in try PublicKeyBlob(decoding: Fixture.ed25519Blob + [0]) }
    let padded = Raw.string("ssh-rsa") + Raw.string([0x00, 0x01, 0x00, 0x01]) + Raw.string([0x00] + Fixture.rsaModulus)
    XCTAssertThrows(WireError.nonMinimalMPInt) { () throws(WireError) in try PublicKeyBlob(decoding: padded) }
    let oversized = [UInt8](repeating: 0, count: Limits.publicKeyBlobBytes + 1)
    XCTAssertThrows(WireError.tooLong(limit: Limits.publicKeyBlobBytes)) { () throws(WireError) in try PublicKeyBlob(decoding: oversized) }
  }

  func testSignatureBlobs() throws {
    let raw = Raw.string("ssh-ed25519") + Raw.string([UInt8](repeating: 7, count: 64))
    let blob = try SignatureBlob(decoding: raw)
    XCTAssertEqual(blob.algorithm, "ssh-ed25519")
    XCTAssertEqual(blob.signature.count, 64)
    XCTAssertEqual(try blob.encoded(), raw)
    XCTAssertThrows(WireError.trailingBytes) { () throws(WireError) in try SignatureBlob(decoding: raw + [1]) }
    XCTAssertThrows(WireError.invalidName) { () throws(WireError) in try SignatureBlob(decoding: Raw.string("") + Raw.string([1])) }
    XCTAssertThrows(WireError.unencodable) { () throws(WireError) in try SignatureBlob(algorithm: "a b", signature: []).encoded() }
  }

  func testECDSASignaturesConvertBothWays() throws {
    for curve in ECDSACurve.allCases {
      let width = curve.scalarBytes
      // r with its high bit set (needs a 0x00 in the mpint), s with leading zero bytes (shorter mpint).
      let r = [0x80] + [UInt8](repeating: 0xAB, count: width - 1)
      let s = [0, 0] + [UInt8](repeating: 0x01, count: width - 2)
      let inner = try ECDSASignature.inner(fromRaw: r + s, curve: curve)
      XCTAssertEqual(inner, Raw.string([0] + r) + Raw.string(Array(s.dropFirst(2))))
      XCTAssertEqual(try ECDSASignature.raw(fromInner: inner, curve: curve), r + s)
    }
  }

  func testECDSASignatureBounds() {
    let curve = ECDSACurve.p256
    let zero = [UInt8](repeating: 0, count: 32), one = [UInt8](repeating: 0, count: 31) + [1]
    XCTAssertThrows(WireError.invalidValue) { () throws(WireError) in try ECDSASignature.inner(fromRaw: zero + one, curve: curve) }
    XCTAssertThrows(WireError.invalidValue) { () throws(WireError) in try ECDSASignature.inner(fromRaw: one, curve: curve) }
    // An r wider than the curve, a zero s, trailing bytes.
    let wide = Raw.string([UInt8](repeating: 0x01, count: 33)) + Raw.string([1])
    let zeroS = Raw.string([1]) + Raw.string([])
    for inner in [wide, zeroS] {
      XCTAssertThrows(WireError.invalidValue) { () throws(WireError) in try ECDSASignature.raw(fromInner: inner, curve: curve) }
    }
    XCTAssertThrows(WireError.trailingBytes) { () throws(WireError) in
      try ECDSASignature.raw(fromInner: Raw.string([1]) + Raw.string([1]) + [0], curve: curve)
    }
  }
}
