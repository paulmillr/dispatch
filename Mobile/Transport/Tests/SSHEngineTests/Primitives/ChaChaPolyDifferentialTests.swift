import CryptoKit
import XCTest
@testable import SSHEngine

/// The RFC 8439 AEAD assembled from `ChaCha20` and `Poly1305` (`AssembledAEAD`) against RFC 8439's, StableLib's and
/// Wycheproof's AEAD vectors and against CryptoKit's `ChaChaPoly`, which is the same construction: byte-identical
/// ciphertext and tag for random keys, nonces, AAD and message lengths, and each side opens what the other sealed and
/// rejects a flipped bit.
///
/// Case count: 30,000 per run, times `SSHENGINE_PRIMITIVE_CASES` (PrimitiveTestSupport).
final class ChaChaPolyDifferentialTests: XCTestCase {
  private typealias T = PrimitiveTestSupport

  /// §2.8.2: nonce = the 32-bit constant | the 64-bit IV.
  func testRFC8439AEADVector() throws {
    let nonce = T.bytes(RFC8439.aeadFixed) + T.bytes(RFC8439.aeadIV)
    let sealed = try AssembledAEAD.seal(key: T.bytes(RFC8439.aeadKey), nonce: nonce, aad: T.bytes(RFC8439.aeadAAD),
                                        plaintext: T.bytes(RFC8439.aeadPlaintext))
    XCTAssertEqual(T.hex(sealed.ciphertext), RFC8439.aeadCiphertext)
    XCTAssertEqual(T.hex(sealed.tag), RFC8439.aeadTag)
  }

  /// A.5: decryption, tag checked first.
  func testRFC8439AppendixDecryption() throws {
    let opened = try AssembledAEAD.open(key: T.bytes(RFC8439.a5Key), nonce: T.bytes(RFC8439.a5Nonce), aad: T.bytes(RFC8439.a5AAD),
                                        ciphertext: T.bytes(RFC8439.a5Ciphertext), tag: T.bytes(RFC8439.a5Tag))
    XCTAssertEqual(opened.map { T.hex($0) }, RFC8439.a5Plaintext)
    var tag = T.bytes(RFC8439.a5Tag)
    tag[15] ^= 0x80
    XCTAssertNil(try AssembledAEAD.open(key: T.bytes(RFC8439.a5Key), nonce: T.bytes(RFC8439.a5Nonce), aad: T.bytes(RFC8439.a5AAD),
                                        ciphertext: T.bytes(RFC8439.a5Ciphertext), tag: tag))
  }

  /// StableLib's 67 ChaCha20-Poly1305 vectors (noble-ciphers' `stablelib_chacha20poly1305.json`, 12-byte nonces,
  /// `result` = ciphertext | tag): the seal is `result`, the open gives `msg` back, and `result` with its last byte
  /// (the tag's) flipped is rejected.
  func testStableLibAEADVectors() throws {
    let vectors = try VectorFiles.stableLibChaCha20Poly1305()
    XCTAssertEqual(vectors.count, 67)
    for (number, vector) in vectors.enumerated() {
      let key = T.bytes(vector.key), nonce = T.bytes(vector.nonce), aad = T.bytes(vector.aad ?? "")
      let result = T.bytes(vector.result)
      XCTAssertEqual(nonce.count, AssembledAEAD.nonceSize, "#\(number)")
      guard result.count >= Poly1305.tagSize else {
        XCTFail("#\(number): result shorter than a tag")
        continue
      }
      let sealed = try AssembledAEAD.seal(key: key, nonce: nonce, aad: aad, plaintext: T.bytes(vector.msg))
      XCTAssertEqual(T.hex(sealed.ciphertext + sealed.tag), vector.result, "#\(number) seal")
      let ciphertext = Array(result.dropLast(Poly1305.tagSize))
      var tag = Array(result.suffix(Poly1305.tagSize))
      let opened = try AssembledAEAD.open(key: key, nonce: nonce, aad: aad, ciphertext: ciphertext, tag: tag)
      XCTAssertEqual(opened.map { T.hex($0) }, vector.msg, "#\(number) open")
      tag[tag.count - 1] ^= 1
      XCTAssertNil(try AssembledAEAD.open(key: key, nonce: nonce, aad: aad, ciphertext: ciphertext, tag: tag),
                   "#\(number): flipped last byte accepted")
    }
  }

  /// Wycheproof's ChaCha20-Poly1305 vectors (`chacha20_poly1305_test.json`, testvectors_v1): every valid one seals to
  /// `ct | tag` and opens to `msg`; every invalid one with a 12-byte nonce (a modified tag) is rejected on open, its
  /// ciphertext being the seal's and its tag not; the invalid ones with other nonce sizes (0 to 32 bytes, 8 among
  /// them, which `ChaCha20` alone would take as the original layout) are refused by the assembly both ways. None is
  /// skipped: the outcomes are counted per kind and checked against the file's `numberOfTests` and exact totals, so a
  /// truncated or changed file fails.
  func testWycheproofVectors() throws {
    let file = try VectorFiles.wycheproofChaCha20Poly1305()
    XCTAssertEqual(file.algorithm, "CHACHA20-POLY1305")
    var outcomes: [String: Int] = [:]
    for group in file.testGroups {
      XCTAssertEqual(group.keySize, 256, "group with \(group.ivSize)-bit nonces")
      XCTAssertEqual(group.tagSize, 128, "group with \(group.ivSize)-bit nonces")
      for test in group.tests {
        let label = test.comment.isEmpty ? "tcId \(test.tcId)" : "tcId \(test.tcId) (\(test.comment))"
        let key = T.bytes(test.key), nonce = T.bytes(test.iv), aad = T.bytes(test.aad)
        let message = T.bytes(test.msg), ciphertext = T.bytes(test.ct), tag = T.bytes(test.tag)
        XCTAssertEqual(nonce.count * 8, group.ivSize, label)
        XCTAssertEqual(key.count * 8, group.keySize, label)
        guard nonce.count == AssembledAEAD.nonceSize else {
          // Refused by construction: never sealed or opened with another layout.
          XCTAssertEqual(test.result, "invalid", label)
          XCTAssertTrue(test.flags.contains("InvalidNonceSize"), label)
          XCTAssertThrowsError(try AssembledAEAD.seal(key: key, nonce: nonce, aad: aad, plaintext: message), label) {
            XCTAssertEqual($0 as? ChaCha20.Error, .nonceSize(nonce.count), label)
          }
          XCTAssertThrowsError(
            try AssembledAEAD.open(key: key, nonce: nonce, aad: aad, ciphertext: ciphertext, tag: tag), label
          ) {
            XCTAssertEqual($0 as? ChaCha20.Error, .nonceSize(nonce.count), label)
          }
          outcomes["invalid: nonce size refused", default: 0] += 1
          continue
        }
        let sealed = try AssembledAEAD.seal(key: key, nonce: nonce, aad: aad, plaintext: message)
        let opened = try AssembledAEAD.open(key: key, nonce: nonce, aad: aad, ciphertext: ciphertext, tag: tag)
        switch test.result {
        case "valid":
          XCTAssertEqual(T.hex(sealed.ciphertext), test.ct, "\(label) seal: ciphertext")
          XCTAssertEqual(T.hex(sealed.tag), test.tag, "\(label) seal: tag")
          XCTAssertEqual(opened.map { T.hex($0) }, test.msg, "\(label) open")
          outcomes["valid: sealed and opened", default: 0] += 1
        case "invalid":
          XCTAssertNil(opened, "\(label): accepted")
          XCTAssertTrue(test.flags.contains("ModifiedTag"), label)
          XCTAssertEqual(T.hex(sealed.ciphertext), test.ct, "\(label) seal: ciphertext")
          XCTAssertNotEqual(T.hex(sealed.tag), test.tag, "\(label) seal: tag")
          outcomes["invalid: rejected on open", default: 0] += 1
        default:
          XCTFail("\(label): result \(test.result) is neither valid nor invalid")
          outcomes["skipped: result \(test.result)", default: 0] += 1
        }
      }
    }
    XCTAssertEqual(outcomes.values.reduce(0, +), file.numberOfTests)
    XCTAssertEqual(file.numberOfTests, 325)
    XCTAssertEqual(outcomes, ["valid: sealed and opened": 256, "invalid: rejected on open": 60,
                              "invalid: nonce size refused": 9])
    print("ChaChaPolyDifferentialTests: Wycheproof \(file.numberOfTests) tests: "
      + outcomes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
  }

  /// Message lengths: the edge list (block boundaries of both primitives) most of the time, else up to 600 bytes,
  /// and one case in 40 between 600 bytes and 16 KiB (one in 400 up to 256 KiB, SSH's largest packets).
  private static let edges = [0, 1, 2, 3, 7, 8, 15, 16, 17, 31, 32, 33, 47, 48, 49, 63, 64, 65, 127, 128, 129, 191, 192, 193,
                              255, 256, 257, 511, 512, 513, 1023, 1024, 1025, 4095, 4096, 4097]
  private static let aadEdges = [0, 1, 4, 8, 12, 13, 15, 16, 17, 31, 32, 33, 63, 64, 65]

  private static func length(_ random: inout PrimitiveRandom) -> Int {
    switch random.next() % 400 {
    case 0: return 16384 + Int(random.next() % (262_144 - 16384))
    case 1..<10: return 600 + Int(random.next() % (16384 - 600))
    case 10..<200: return edges[Int(random.next() % UInt64(edges.count))]
    default: return Int(random.next() % 600)
    }
  }

  func testSealMatchesCryptoKitAndBothOpenEachOther() throws {
    let cases = 30_000 * T.multiplier
    let seed = T.seed
    var random = PrimitiveRandom(seed: seed)
    var bytes = 0
    var rejected = 0
    let start = Date()
    for index in 0..<cases {
      let key = random.bytes(32)
      let nonce = random.bytes(12)
      let aadCount = random.next() % 2 == 0 ? Self.aadEdges[Int(random.next() % UInt64(Self.aadEdges.count))] : Int(random.next() % 300)
      let aad = random.bytes(aadCount)
      let plaintext = random.bytes(Self.length(&random))
      bytes += plaintext.count

      let ours = try AssembledAEAD.seal(key: key, nonce: nonce, aad: aad, plaintext: plaintext)
      let theirs = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: key), nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad)
      guard Array(theirs.ciphertext) == ours.ciphertext, Array(theirs.tag) == ours.tag else {
        XCTFail("case \(index) (seed \(seed)) differs: key \(T.hex(key)) nonce \(T.hex(nonce)) aad \(aad.count) bytes, "
          + "message \(plaintext.count) bytes; tag \(T.hex(ours.tag)) vs \(T.hex(theirs.tag))")
        return
      }
      // We open CryptoKit's box; CryptoKit opens ours (built from our bytes, not its own).
      let opened = try AssembledAEAD.open(key: key, nonce: nonce, aad: aad, ciphertext: Array(theirs.ciphertext), tag: Array(theirs.tag))
      XCTAssertEqual(opened, plaintext, "case \(index): our open of CryptoKit's box")
      let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: ours.ciphertext, tag: ours.tag)
      XCTAssertEqual(Array(try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad)), plaintext,
                     "case \(index): CryptoKit's open of ours")

      // One flipped bit in the ciphertext, the tag or the AAD: both sides reject.
      if index % 4 == 0 {
        var ciphertext = ours.ciphertext, tag = ours.tag, flippedAAD = aad
        let total = ciphertext.count + tag.count + flippedAAD.count
        let position = Int(random.next() % UInt64(total))
        let bit = UInt8(1) << (random.next() % 8)
        if position < ciphertext.count {
          ciphertext[position] ^= bit
        } else if position < ciphertext.count + tag.count {
          tag[position - ciphertext.count] ^= bit
        } else {
          flippedAAD[position - ciphertext.count - tag.count] ^= bit
        }
        XCTAssertNil(try AssembledAEAD.open(key: key, nonce: nonce, aad: flippedAAD, ciphertext: ciphertext, tag: tag),
                     "case \(index): flipped bit \(position) accepted")
        let flippedBox = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
        XCTAssertThrowsError(try ChaChaPoly.open(flippedBox, using: SymmetricKey(data: key), authenticating: flippedAAD))
        rejected += 1
      }
    }
    let seconds = Date().timeIntervalSince(start)
    print("ChaChaPolyDifferentialTests: \(cases) cases (seed \(seed)), \(bytes) message bytes, \(rejected) flipped-bit rejections, "
      + String(format: "%.1f s", seconds))
  }
}
