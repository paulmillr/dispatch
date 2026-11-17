import XCTest
@testable import SSHEngine

/// ChaCha20 against RFC 8439's vectors, the original layout against StableLib's streams and libsodium's across the
/// 2^32 counter boundary, the two state layouts against each other, and the XOR's block bookkeeping.
final class ChaCha20Tests: XCTestCase {
  private typealias T = PrimitiveTestSupport

  /// §2.3.2: the block function at counter 1.
  func testRFC8439BlockFunction() throws {
    let cipher = try ChaCha20(key: T.bytes("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
                              nonce: T.bytes("000000090000004a00000000"))
    XCTAssertEqual(T.hex(cipher.block(counter: 1)), RFC8439.blockSerialized)
  }

  /// §2.4.2: the "sunscreen" encryption from counter 1, and its decryption.
  func testRFC8439Encryption() throws {
    let cipher = try ChaCha20(key: T.bytes("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
                              nonce: T.bytes("000000000000004a00000000"))
    var bytes = T.bytes(RFC8439.sunscreenPlaintext)
    cipher.xor(&bytes, counter: 1)
    XCTAssertEqual(T.hex(bytes), RFC8439.sunscreenCiphertext)
    cipher.xor(&bytes, counter: 1)
    XCTAssertEqual(T.hex(bytes), RFC8439.sunscreenPlaintext)
  }

  /// A.1: five block-function vectors (counters 0, 1, 1, 2, 0).
  func testRFC8439AppendixBlocks() throws {
    let cases: [(String, String, UInt64, String)] = [
      (RFC8439.a1Key1, RFC8439.a1Nonce1, 0, RFC8439.a1Keystream1),
      (RFC8439.a1Key2, RFC8439.a1Nonce2, 1, RFC8439.a1Keystream2),
      (RFC8439.a1Key3, RFC8439.a1Nonce3, 1, RFC8439.a1Keystream3),
      (RFC8439.a1Key4, RFC8439.a1Nonce4, 2, RFC8439.a1Keystream4),
      (RFC8439.a1Key5, RFC8439.a1Nonce5, 0, RFC8439.a1Keystream5),
    ]
    for (number, (key, nonce, counter, keystream)) in cases.enumerated() {
      let cipher = try ChaCha20(key: T.bytes(key), nonce: T.bytes(nonce))
      XCTAssertEqual(T.hex(cipher.block(counter: counter)), keystream, "A.1 #\(number + 1)")
      // The XOR of zeros is the keystream, through the same path the cipher uses.
      var zeros = [UInt8](repeating: 0, count: 64)
      cipher.xor(&zeros, counter: counter)
      XCTAssertEqual(T.hex(zeros), keystream, "A.1 #\(number + 1) by xor")
    }
  }

  /// A.2: three encryption vectors (64 bytes from 0, 375 from 1, 127 from 42).
  func testRFC8439AppendixEncryption() throws {
    let cases: [(String, String, UInt64, String, String)] = [
      (RFC8439.a2Key1, RFC8439.a2Nonce1, 0, RFC8439.a2Plaintext1, RFC8439.a2Ciphertext1),
      (RFC8439.a2Key2, RFC8439.a2Nonce2, 1, RFC8439.a2Plaintext2, RFC8439.a2Ciphertext2),
      (RFC8439.a2Key3, RFC8439.a2Nonce3, 42, RFC8439.a2Plaintext3, RFC8439.a2Ciphertext3),
    ]
    for (number, (key, nonce, counter, plaintext, ciphertext)) in cases.enumerated() {
      let cipher = try ChaCha20(key: T.bytes(key), nonce: T.bytes(nonce))
      var bytes = T.bytes(plaintext)
      cipher.xor(&bytes, counter: counter)
      XCTAssertEqual(T.hex(bytes), ciphertext, "A.2 #\(number + 1)")
    }
  }

  /// The original layout (64-bit counter, 8-byte nonce: OpenSSH's) equals the RFC layout with the nonce prefixed by
  /// four zero bytes for every counter below 2^32, block by block and through `xor`. So the SSH cipher may use either.
  func testOriginalLayoutIsTheIETFLayoutWithAZeroPrefix() throws {
    var random = PrimitiveRandom(seed: T.seed)
    for _ in 0..<(200 * T.multiplier) {
      let key = random.bytes(32)
      let sequence = random.bytes(8)
      let original = try ChaCha20(key: key, nonce: sequence)
      let ietf = try ChaCha20(key: key, nonce: [0, 0, 0, 0] + sequence)
      XCTAssertTrue(original.wideCounter)
      XCTAssertFalse(ietf.wideCounter)
      let counters: [UInt64] = [0, 1, 2, UInt64(UInt32.max) - 1, UInt64(UInt32.max), UInt64(random.next() >> 32)]
      for counter in counters {
        XCTAssertEqual(original.block(counter: counter), ietf.block(counter: counter), "counter \(counter)")
      }
      let length = Int(random.next() % 600)
      var a = random.bytes(length)
      var b = a
      let counter = UInt64(random.next() % 1000)
      original.xor(&a, counter: counter)
      ietf.xor(&b, counter: counter)
      XCTAssertEqual(a, b)
    }
  }

  /// The original layout carries the counter from word 12 into word 13: block 2^32 + n is the RFC layout's block n
  /// with nonce word 13 set to 1, and an XOR across the boundary uses both sides.
  func testOriginalLayoutCarriesIntoTheHighCounterWord() throws {
    var random = PrimitiveRandom(seed: T.seed &+ 1)
    let key = random.bytes(32)
    let sequence = random.bytes(8)
    let original = try ChaCha20(key: key, nonce: sequence)
    let low = try ChaCha20(key: key, nonce: [0, 0, 0, 0] + sequence)
    let high = try ChaCha20(key: key, nonce: [1, 0, 0, 0] + sequence)
    XCTAssertEqual(original.block(counter: 1 << 32), high.block(counter: 0))
    XCTAssertEqual(original.block(counter: (1 << 32) + 7), high.block(counter: 7))
    var bytes = [UInt8](repeating: 0, count: 128 + 10)
    original.xor(&bytes, counter: (1 << 32) - 1)
    XCTAssertEqual(Array(bytes[0..<64]), low.block(counter: UInt64(UInt32.max)))
    XCTAssertEqual(Array(bytes[64..<128]), high.block(counter: 0))
    XCTAssertEqual(Array(bytes[128...]), Array(high.block(counter: 1).prefix(10)))
    // And the 64-bit counter's own wrap, which the SSH cipher never reaches, is plain modular arithmetic.
    var wrap = [UInt8](repeating: 0, count: 128)
    original.xor(&wrap, counter: .max)
    XCTAssertEqual(Array(wrap[64...]), original.block(counter: 0))
  }

  /// StableLib's five ChaCha20 streams (noble-ciphers' `stablelib_chacha20.json`): the original layout, 32-byte key,
  /// 8-byte nonce and 64-bit counter, from block 0, as OpenSSH's cipher uses it. Expected bytes from another
  /// implementation, where `testOriginalLayoutIsTheIETFLayoutWithAZeroPrefix` only proves the layout equal to ours.
  func testStableLibOriginalLayoutStreams() throws {
    let vectors = try VectorFiles.stableLibChaCha20()
    XCTAssertEqual(vectors.count, 5)
    for (number, vector) in vectors.enumerated() {
      let cipher = try ChaCha20(key: T.bytes(vector.key), nonce: T.bytes(vector.nonce))
      XCTAssertTrue(cipher.wideCounter, "#\(number)")
      let count = vector.stream.utf8.count / 2
      var zeros = [UInt8](repeating: 0, count: count)
      cipher.xor(&zeros, counter: 0)
      XCTAssertEqual(T.hex(zeros), vector.stream, "#\(number) by xor")
      let blocks = (0..<((count + 63) / 64)).flatMap { cipher.block(counter: UInt64($0)) }
      XCTAssertEqual(T.hex(blocks.prefix(count)), vector.stream, "#\(number) by block")
    }
  }

  /// libsodium's raw ChaCha20 stream (the original layout) from counter 0xffffffff, as pinned in noble-ciphers'
  /// `arx.test.ts` ("chacha20orig: libsodium raw stream carries into the high 32 bits"; noble itself refuses that
  /// counter): key bytes 0x00...0x1f, nonce bytes 0xa0...0xa7, 192 zero bytes, so blocks 2^32 - 1, 2^32 and 2^32 + 1.
  /// The carry into word 13 against another implementation's bytes, where
  /// `testOriginalLayoutCarriesIntoTheHighCounterWord` compares the engine with itself; through the single-block path
  /// (192 bytes), block by block, and through the four-block path (256 bytes, the boundary inside one group).
  func testLibsodiumStreamCarriesIntoTheHighCounterWord() throws {
    let cipher = try ChaCha20(key: (0..<32).map { UInt8($0) }, nonce: (0xa0...0xa7).map { UInt8($0) })
    XCTAssertTrue(cipher.wideCounter)
    var stream = [UInt8](repeating: 0, count: 192)
    cipher.xor(&stream, counter: 0xffff_ffff)
    XCTAssertEqual(T.hex(stream), Self.libsodiumCarry)
    XCTAssertEqual(T.hex((0..<3).flatMap { cipher.block(counter: 0xffff_ffff + UInt64($0)) }), Self.libsodiumCarry)
    var group = [UInt8](repeating: 0, count: 256)
    cipher.xor(&group, counter: 0xffff_ffff)
    XCTAssertEqual(T.hex(group.prefix(192)), Self.libsodiumCarry)
  }

  private static let libsodiumCarry =
    "aa07a6552d0b049adaacee7d2487a4bde0b35396ee1003f75310c36691ac2a8abd997a5e63b9e7954f21323435e6eeff" +
    "c36bd58b8695944fac3eb03fad55a13b8902e65d02ea2c1db273c4f6542aef8a8eeeccca7bbed8564375ed48ff314600" +
    "2c94541c193de0f59f3ede7795dbfd2c8051cb271836ca71247e41a34a0c5f51901b8cf636e3fd52f36e599354a2e643" +
    "11e5f387fdec0ec17058ef95d07910c1ee03735043dc71c06382add9ee6edfaf1df4f22a633efa6012ebc6d9bff49538"

  /// The four-block path (`xor` over 256 bytes and more) gives the blocks `block(counter:)` gives one at a time,
  /// whichever lane the counter's carries fall in: across the original layout's carry into word 13 and its 64-bit
  /// wrap, at the RFC layout's last counters, and from every lane offset, for lengths around the 256-byte groups.
  func testFourBlocksAtOnceAreTheSingleBlocks() throws {
    var random = PrimitiveRandom(seed: T.seed &+ 9)
    let wide = try ChaCha20(key: random.bytes(32), nonce: random.bytes(8))
    let rfc = try ChaCha20(key: random.bytes(32), nonce: random.bytes(12))
    var starts: [(ChaCha20, UInt64)] = []
    for back in 0...8 {
      starts.append((wide, (1 << 32) &- UInt64(back)))
      starts.append((wide, UInt64.max &- UInt64(back)))
      starts.append((wide, UInt64(back)))
      starts.append((rfc, UInt64(back)))
    }
    for (cipher, counter) in starts {
      for length in [255, 256, 257, 511, 512, 513, 767, 768, 1024, 1100] {
        let blocks = (length + 63) / 64
        // The RFC layout takes counters with every block below 2^32.
        guard cipher.wideCounter || counter + UInt64(blocks) <= 1 << 32 else { continue }
        let keystream = (0..<blocks).flatMap { cipher.block(counter: counter &+ UInt64($0)) }.prefix(length)
        let message = random.bytes(length)
        var bytes = message
        cipher.xor(&bytes, counter: counter)
        XCTAssertEqual(bytes, zip(message, keystream).map { $0 ^ $1 }, "counter \(counter), length \(length)")
      }
    }
    // The RFC layout's very last blocks, through the four-block path.
    let last = UInt64(UInt32.max) - 7
    var bytes = [UInt8](repeating: 0, count: 8 * 64)
    rfc.xor(&bytes, counter: last)
    XCTAssertEqual(bytes, (0..<8).flatMap { rfc.block(counter: last + UInt64($0)) })
  }

  /// Every length 0...300 and several starting counters: the XOR equals the concatenated blocks, and XOR in pieces
  /// that end on block boundaries (continuing the counter) equals XOR in one go.
  func testXorMatchesTheConcatenatedKeystream() throws {
    var random = PrimitiveRandom(seed: T.seed &+ 2)
    for nonceSize in [8, 12] {
      let cipher = try ChaCha20(key: random.bytes(32), nonce: random.bytes(nonceSize))
      for length in 0...300 {
        let counter = UInt64(random.next() % 5)
        let blocks = (length + 63) / 64
        let keystream = (0..<blocks).flatMap { cipher.block(counter: counter + UInt64($0)) }.prefix(length)
        let message = random.bytes(length)
        var whole = message
        cipher.xor(&whole, counter: counter)
        XCTAssertEqual(whole, zip(message, keystream).map { $0 ^ $1 }, "length \(length)")
        // In pieces of whole blocks, then the rest.
        var pieces = message
        let split = 64 * Int(random.next() % UInt64(length / 64 + 1))
        pieces.withUnsafeMutableBytes { buffer in
          cipher.xor(UnsafeMutableRawBufferPointer(rebasing: buffer[0..<split]), counter: counter)
          cipher.xor(UnsafeMutableRawBufferPointer(rebasing: buffer[split...]), counter: counter + UInt64(split / 64))
        }
        XCTAssertEqual(pieces, whole, "length \(length) split at \(split)")
      }
    }
  }

  /// The XOR works on unaligned bytes inside a larger buffer and touches nothing outside its range.
  func testXorStaysInsideItsRange() throws {
    var random = PrimitiveRandom(seed: T.seed &+ 3)
    let cipher = try ChaCha20(key: random.bytes(32), nonce: random.bytes(12))
    for offset in 0..<8 {
      for length in [0, 1, 63, 64, 65, 200] {
        let original = random.bytes(offset + length + 8)
        var buffer = original
        buffer.withUnsafeMutableBytes { cipher.xor(UnsafeMutableRawBufferPointer(rebasing: $0[offset..<(offset + length)]), counter: 3) }
        XCTAssertEqual(Array(buffer[..<offset]), Array(original[..<offset]))
        XCTAssertEqual(Array(buffer[(offset + length)...]), Array(original[(offset + length)...]))
        var expected = Array(original[offset..<(offset + length)])
        cipher.xor(&expected, counter: 3)
        XCTAssertEqual(Array(buffer[offset..<(offset + length)]), expected)
      }
    }
  }

  func testRejectsWrongKeyAndNonceSizes() {
    for size in [0, 16, 31, 33, 64] {
      XCTAssertThrowsError(try ChaCha20(key: [UInt8](repeating: 1, count: size), nonce: [UInt8](repeating: 0, count: 12))) {
        XCTAssertEqual($0 as? ChaCha20.Error, .keySize(size))
      }
    }
    for size in [0, 4, 7, 9, 11, 13, 16] {
      XCTAssertThrowsError(try ChaCha20(key: [UInt8](repeating: 1, count: 32), nonce: [UInt8](repeating: 0, count: size))) {
        XCTAssertEqual($0 as? ChaCha20.Error, .nonceSize(size))
      }
    }
    XCTAssertNoThrow(try ChaCha20(key: Data(count: 32), nonce: Data(count: 8)))
  }

  /// `wipe` leaves the all-zero key and nonce: the keystream becomes A.1 #1's.
  func testWipeZeroesTheKey() throws {
    var cipher = try ChaCha20(key: [UInt8](repeating: 0xa5, count: 32), nonce: [UInt8](repeating: 0x5a, count: 12))
    cipher.wipe()
    XCTAssertEqual(T.hex(cipher.block(counter: 0)), RFC8439.a1Keystream1)
  }
}
