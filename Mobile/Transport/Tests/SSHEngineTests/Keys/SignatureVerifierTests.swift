import CryptoKit
import Foundation
import Security
import XCTest
@testable import SSHEngine

/// `SSHSignatureVerifier` per algorithm: valid signatures from CryptoKit and Security keys made here; every way a blob,
/// key or algorithm can be wrong, each refused with `invalidSignature`; ECDSA's mpint edge cases; RSA's bounds and
/// SHA-1. (ssh-keygen's and openssl's signatures are checked in `KeygenOracleTests`.)
final class SignatureVerifierTests: XCTestCase {
  private let verifier = SSHSignatureVerifier()
  private let data = Array("fictional exchange hash".utf8)

  private func blob(_ algorithm: String, _ signature: [UInt8]) -> [UInt8] {
    Raw.string(algorithm) + Raw.string(signature)
  }

  private func assertValid(_ signature: [UInt8], key: PublicKeyBlob, algorithm: SignatureAlgorithm,
                           over data: [UInt8]? = nil, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNoThrow(try verifier.verify(signatureBlob: signature, over: data ?? self.data, key: key, algorithm: algorithm),
                     file: file, line: line)
  }

  private func assertInvalid(_ signature: [UInt8], key: PublicKeyBlob, algorithm: SignatureAlgorithm,
                             over data: [UInt8]? = nil, _ message: String = "", file: StaticString = #filePath,
                             line: UInt = #line) {
    XCTAssertThrows(SSHError.protocolViolation(.keyExchange(.invalidSignature)), file: file, line: line) {
      () throws(SSHError) in
      try verifier.verify(signatureBlob: signature, over: data ?? self.data, key: key, algorithm: algorithm)
    }
  }

  func testEd25519() throws {
    let key = Curve25519.Signing.PrivateKey()
    let publicKey = PublicKeyBlob.ed25519(Array(key.publicKey.rawRepresentation))
    let signature = Array(try key.signature(for: data))
    assertValid(blob("ssh-ed25519", signature), key: publicKey, algorithm: .ed25519)

    var flipped = signature
    flipped[10] ^= 1
    let other = PublicKeyBlob.ed25519(Array(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
    assertInvalid(blob("ssh-ed25519", signature), key: publicKey, algorithm: .ed25519, over: data + [0])
    assertInvalid(blob("ssh-ed25519", flipped), key: publicKey, algorithm: .ed25519)
    assertInvalid(blob("ssh-ed25519", Array(signature.dropLast())), key: publicKey, algorithm: .ed25519)
    assertInvalid(blob("ssh-ed25519", signature + [0]), key: publicKey, algorithm: .ed25519)
    assertInvalid(blob("ssh-ed25519", signature) + [0], key: publicKey, algorithm: .ed25519, "trailing bytes")
    assertInvalid(blob("ssh-ed25519", signature), key: other, algorithm: .ed25519)
    assertInvalid(blob("ssh-ed448", signature), key: publicKey, algorithm: .ed25519)
    assertInvalid(blob("ssh-ed25519", signature), key: publicKey, algorithm: .ecdsaP256, "algorithm of another type")
    assertInvalid([], key: publicKey, algorithm: .ed25519)
    // A 32-byte value CryptoKit does not take as a point is refused, not trapped on.
    assertInvalid(blob("ssh-ed25519", signature), key: .ed25519([UInt8](repeating: 0xFF, count: 32)), algorithm: .ed25519)
    assertInvalid(blob("ssh-ed25519", signature), key: .ed25519([1, 2, 3]), algorithm: .ed25519, "a short key built by hand")
  }

  /// The inner signature, mpint r and mpint s, built from r‖s by hand.
  private func ecdsaInner(_ r: [UInt8], _ s: [UInt8]) -> [UInt8] {
    func mpint(_ value: [UInt8]) -> [UInt8] {
      let trimmed = Array(value.drop { $0 == 0 })
      return Raw.string((trimmed.first.map { $0 & 0x80 != 0 } ?? false ? [0] : []) + trimmed)
    }
    return mpint(r) + mpint(s)
  }

  private struct ECKey {
    let curve: ECDSACurve
    let publicKey: PublicKeyBlob
    let sign: ([UInt8]) throws -> [UInt8]
    let order: [UInt8]
  }

  private func ecKeys() -> [ECKey] {
    let p256 = P256.Signing.PrivateKey(), p384 = P384.Signing.PrivateKey(), p521 = P521.Signing.PrivateKey()
    func order(_ curve: ECDSACurve) -> [UInt8] { ECDomain.all.first { $0.curve == curve }!.order }
    return [
      ECKey(curve: .p256, publicKey: .ecdsa(.p256, point: Array(p256.publicKey.x963Representation)),
            sign: { Array(try p256.signature(for: $0).rawRepresentation) }, order: order(.p256)),
      ECKey(curve: .p384, publicKey: .ecdsa(.p384, point: Array(p384.publicKey.x963Representation)),
            sign: { Array(try p384.signature(for: $0).rawRepresentation) }, order: order(.p384)),
      ECKey(curve: .p521, publicKey: .ecdsa(.p521, point: Array(p521.publicKey.x963Representation)),
            sign: { Array(try p521.signature(for: $0).rawRepresentation) }, order: order(.p521)),
    ]
  }

  private func algorithm(_ curve: ECDSACurve) -> SignatureAlgorithm {
    SignatureAlgorithm(rawValue: curve.keyType)!
  }

  func testECDSA() throws {
    let keys = ecKeys()
    for key in keys {
      let width = key.curve.scalarBytes, algorithm = algorithm(key.curve), name = key.curve.keyType
      let raw = try key.sign(data)
      let (r, s) = (Array(raw[..<width]), Array(raw[width...]))
      assertValid(blob(name, ecdsaInner(r, s)), key: key.publicKey, algorithm: algorithm)
      XCTAssertEqual(blob(name, ecdsaInner(r, s)),
                     try SignatureBlob(algorithm: name, signature: ECDSASignature.inner(fromRaw: raw, curve: key.curve)).encoded())

      assertInvalid(blob(name, ecdsaInner(r, s)), key: key.publicKey, algorithm: algorithm, over: data + [0])
      assertInvalid(blob(name, ecdsaInner(s, r)), key: key.publicKey, algorithm: algorithm, "r and s swapped")
      assertInvalid(blob(name, ecdsaInner([], s)), key: key.publicKey, algorithm: algorithm, "r = 0")
      assertInvalid(blob(name, ecdsaInner(r, [])), key: key.publicKey, algorithm: algorithm, "s = 0")
      assertInvalid(blob(name, ecdsaInner(key.order, s)), key: key.publicKey, algorithm: algorithm, "r = n")
      assertInvalid(blob(name, ecdsaInner(r, key.order)), key: key.publicKey, algorithm: algorithm, "s = n")
      assertInvalid(blob(name, ecdsaInner([1] + r, s)), key: key.publicKey, algorithm: algorithm, "r wider than the curve")
      assertInvalid(blob(name, Raw.string([0, 0] + r) + Raw.string(s)), key: key.publicKey, algorithm: algorithm,
                    "a non-minimal mpint")
      let highR = r.first.map { $0 & 0x80 != 0 } ?? false
      if highR {
        assertInvalid(blob(name, Raw.string(r) + ecdsaInner([], s).dropFirst(4)), key: key.publicKey, algorithm: algorithm,
                      "r read as negative")
      }
      assertInvalid(blob(name, ecdsaInner(r, s) + [0]), key: key.publicKey, algorithm: algorithm, "trailing inner bytes")
      assertInvalid(blob(name, ecdsaInner(r, s)) + [0], key: key.publicKey, algorithm: algorithm, "trailing blob bytes")
      assertInvalid(blob(name, raw), key: key.publicKey, algorithm: algorithm, "raw r‖s instead of mpints")
      // A point that is not on the curve (the blob codec checks only its form).
      let offCurve = PublicKeyBlob.ecdsa(key.curve, point: [4] + [UInt8](repeating: 1, count: 2 * width))
      assertInvalid(blob(name, ecdsaInner(r, s)), key: offCurve, algorithm: algorithm, "off the curve")
    }
    // Another curve's key, signature or name.
    let (p256, p384) = (keys[0], keys[1])
    let raw256 = try p256.sign(data)
    let inner256 = ecdsaInner(Array(raw256[..<32]), Array(raw256[32...]))
    assertInvalid(blob("ecdsa-sha2-nistp256", inner256), key: p384.publicKey, algorithm: .ecdsaP256, "a P-384 key")
    assertInvalid(blob("ecdsa-sha2-nistp256", inner256), key: p384.publicKey, algorithm: .ecdsaP384, "a P-256 signature")
    assertInvalid(blob("ecdsa-sha2-nistp384", inner256), key: p256.publicKey, algorithm: .ecdsaP256, "another name")
    assertInvalid(blob("ecdsa-sha2-nistp256", inner256), key: .ecdsa(.p256, point: Array(p384.publicKey.encoded.suffix(97))),
                  algorithm: .ecdsaP256, "a P-384 point as a P-256 key")
  }

  /// r and s whose mpints need a leading zero (high bit set) and ones shorter than the curve's width (leading zero
  /// bytes): signatures are made until each case occurred (each 1 in 2 or 1 in 256 per signature).
  func testECDSAValueWidths() throws {
    for key in ecKeys() {
      let width = key.curve.scalarBytes, algorithm = algorithm(key.curve)
      var seen: Set<String> = []
      var attempts = 0
      // P-521's top byte is 0 or 1 (521 bits in 66 bytes): its "short" case is a zero top byte, its "high" case
      // cannot occur.
      let wanted: Set<String> = key.curve == .p521 ? ["short r", "short s"] : ["high r", "high s", "short r", "short s"]
      while !wanted.isSubset(of: seen), attempts < 6000 {
        attempts += 1
        let message = data + Raw.u32(UInt32(attempts))
        let raw = try key.sign(message)
        let (r, s) = (Array(raw[..<width]), Array(raw[width...]))
        var cases: [String] = []
        if r[0] & 0x80 != 0 { cases.append("high r") }
        if s[0] & 0x80 != 0 { cases.append("high s") }
        if r[0] == 0 { cases.append("short r") }
        if s[0] == 0 { cases.append("short s") }
        guard !cases.isEmpty, !Set(cases).isSubset(of: seen) else { continue }
        seen.formUnion(cases)
        let inner = try ECDSASignature.inner(fromRaw: raw, curve: key.curve)
        if cases.contains("high r") { XCTAssertEqual(Array(inner.prefix(5)), Raw.u32(UInt32(width + 1)) + [0]) }
        if cases.contains("short r") { XCTAssertLessThanOrEqual(Int(inner[3]), width) }
        assertValid(blob(key.curve.keyType, inner), key: key.publicKey, algorithm: algorithm, over: message)
        // The fixed-width encoding some implementations wrongly send (leading zeros kept) is refused where it is
        // not minimal (a zero byte before a byte without its high bit).
        if cases.contains("short r"), r[1] & 0x80 == 0 {
          assertInvalid(blob(key.curve.keyType, Raw.string(r) + Array(inner.dropFirst(4 + Int(inner[3])))), key: key.publicKey,
                        algorithm: algorithm, over: message, "zero-padded r")
        }
      }
      XCTAssertTrue(wanted.isSubset(of: seen), "\(key.curve): saw only \(seen) in \(attempts) signatures")
    }
  }

  private struct RSAKey {
    let key: SecKey
    let publicKey: PublicKeyBlob
    init(bits: Int) throws {
      let rsa = try TestRSAKey(bits: bits)
      key = rsa.key
      publicKey = rsa.publicKey
    }

    func sign(_ data: [UInt8], _ algorithm: SecKeyAlgorithm) -> [UInt8] {
      Array(SecKeyCreateSignature(key, algorithm, Data(data) as CFData, nil)! as Data)
    }
  }

  func testRSA() throws {
    let key = try RSAKey(bits: 2048)
    let sha512 = key.sign(data, .rsaSignatureMessagePKCS1v15SHA512)
    let sha256 = key.sign(data, .rsaSignatureMessagePKCS1v15SHA256)
    let sha1 = key.sign(data, .rsaSignatureMessagePKCS1v15SHA1)
    assertValid(blob("rsa-sha2-512", sha512), key: key.publicKey, algorithm: .rsaSHA512)
    assertValid(blob("rsa-sha2-256", sha256), key: key.publicKey, algorithm: .rsaSHA256)

    assertInvalid(blob("rsa-sha2-512", sha256), key: key.publicKey, algorithm: .rsaSHA512, "a SHA-256 signature as 512")
    assertInvalid(blob("rsa-sha2-256", sha512), key: key.publicKey, algorithm: .rsaSHA256, "a SHA-512 signature as 256")
    assertInvalid(blob("rsa-sha2-512", sha512), key: key.publicKey, algorithm: .rsaSHA256, "another name than negotiated")
    // ssh-rsa (SHA-1): by its name, and as a SHA-1 signature under a SHA-2 name.
    assertInvalid(blob("ssh-rsa", sha1), key: key.publicKey, algorithm: .rsaSHA512, "ssh-rsa")
    assertInvalid(blob("ssh-rsa", sha512), key: key.publicKey, algorithm: .rsaSHA512, "ssh-rsa name, SHA-512 bytes")
    assertInvalid(blob("rsa-sha2-512", sha1), key: key.publicKey, algorithm: .rsaSHA512, "SHA-1 bytes")
    assertInvalid(blob("rsa-sha2-256", sha1), key: key.publicKey, algorithm: .rsaSHA256, "SHA-1 bytes")
    var flipped = sha512
    flipped[100] ^= 4
    assertInvalid(blob("rsa-sha2-512", flipped), key: key.publicKey, algorithm: .rsaSHA512)
    assertInvalid(blob("rsa-sha2-512", sha512), key: key.publicKey, algorithm: .rsaSHA512, over: data + [0])
    assertInvalid(blob("rsa-sha2-512", [0] + sha512), key: key.publicKey, algorithm: .rsaSHA512, "longer than the modulus")
    assertInvalid(blob("rsa-sha2-512", []), key: key.publicKey, algorithm: .rsaSHA512, "empty")
    assertInvalid(blob("rsa-sha2-512", sha512), key: try RSAKey(bits: 2048).publicKey, algorithm: .rsaSHA512, "another key")
    assertInvalid(blob("rsa-sha2-512", sha512), key: .ed25519(Fixture.ed25519Key), algorithm: .rsaSHA512, "an Ed25519 key")
    assertInvalid(blob("rsa-sha2-512", sha512), key: key.publicKey, algorithm: .ed25519, "an Ed25519 algorithm")
  }

  /// Keys outside `Limits` are refused even with a valid signature: below 2048 bits, an exponent of 1, an even
  /// modulus, a longer exponent than allowed (all built by hand, since the blob codec refuses to decode them).
  func testRSABounds() throws {
    let small = try RSAKey(bits: 1024)
    assertInvalid(blob("rsa-sha2-512", small.sign(data, .rsaSignatureMessagePKCS1v15SHA512)), key: small.publicKey,
                  algorithm: .rsaSHA512, "1024 bits")
    let key = try RSAKey(bits: 2048)
    guard case .rsa(let exponent, let modulus) = key.publicKey else { return XCTFail() }
    let signature = blob("rsa-sha2-512", key.sign(data, .rsaSignatureMessagePKCS1v15SHA512))
    var even = modulus
    even[even.count - 1] &= 0xFE
    for (name, bad) in [("exponent 1", PublicKeyBlob.rsa(exponent: [1], modulus: modulus)),
                        ("even modulus", .rsa(exponent: exponent, modulus: even)),
                        ("9-byte exponent", .rsa(exponent: [1, 0, 0, 0, 0, 0, 0, 0, 1], modulus: modulus)),
                        ("empty modulus", .rsa(exponent: exponent, modulus: []))] {
      assertInvalid(signature, key: bad, algorithm: .rsaSHA512, name)
    }
  }

  /// A signature that happens to start with a zero byte, sent without it (as some signers do), is padded back and
  /// verifies, as OpenSSH accepts it.
  func testShortRSASignature() throws {
    let key = try RSAKey(bits: 2048)
    for attempt in 0..<5000 {
      let message = data + Raw.u32(UInt32(attempt))
      let signature = key.sign(message, .rsaSignatureMessagePKCS1v15SHA256)
      guard signature[0] == 0 else { continue }
      assertValid(blob("rsa-sha2-256", Array(signature.dropFirst())), key: key.publicKey, algorithm: .rsaSHA256, over: message)
      assertValid(blob("rsa-sha2-256", signature), key: key.publicKey, algorithm: .rsaSHA256, over: message)
      return
    }
    XCTFail("no signature with a leading zero byte in 5000 (expected about 1 in 256)")
  }

  /// Mutated valid blobs of each algorithm: refused (or, unchanged, accepted), never a trap.
  func testMutatedSignatureBlobs() throws {
    let ed25519 = Curve25519.Signing.PrivateKey()
    let p256 = P256.Signing.PrivateKey()
    let rsa = try RSAKey(bits: 2048)
    let cases: [([UInt8], PublicKeyBlob, SignatureAlgorithm)] = [
      (blob("ssh-ed25519", Array(try ed25519.signature(for: data))), .ed25519(Array(ed25519.publicKey.rawRepresentation)), .ed25519),
      (try SignatureBlob(algorithm: "ecdsa-sha2-nistp256", signature: ECDSASignature.inner(
        fromRaw: Array(try p256.signature(for: data).rawRepresentation), curve: .p256)).encoded(),
       .ecdsa(.p256, point: Array(p256.publicKey.x963Representation)), .ecdsaP256),
      (blob("rsa-sha2-512", rsa.sign(data, .rsaSignatureMessagePKCS1v15SHA512)), rsa.publicKey, .rsaSHA512),
    ]
    let random = SeededRandom(seed: 0x5167)
    for (valid, key, algorithm) in cases {
      XCTAssertTrue(SSHSignatureVerifier.isValid(signatureBlob: valid, over: data, key: key, algorithm: algorithm))
      for _ in 0..<700 {
        let mutated = HostileKeyFileTests.mutate(valid, random)
        let accepted = SSHSignatureVerifier.isValid(signatureBlob: mutated, over: data, key: key, algorithm: algorithm)
        // ECDSA verification accepts only the original; an RSA or Ed25519 mutation that still verifies would be a
        // forgery.
        if accepted { XCTAssertEqual(mutated, valid, "\(algorithm.rawValue): a mutated blob verified") }
      }
    }
  }
}
