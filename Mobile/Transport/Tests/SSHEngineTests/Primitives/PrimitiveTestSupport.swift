import Foundation
@testable import SSHEngine

/// Helpers of the primitives' tests: hex, a seeded generator, and the environment knobs.
///
/// `SSHENGINE_PRIMITIVE_CASES` multiplies the randomized suites' case counts (default 1; e.g. 100 for a long run);
/// `SSHENGINE_PRIMITIVE_SEED` replaces the fixed seed (decimal), so a failure reproduces from its printed seed.
enum PrimitiveTestSupport {
  static func bytes(_ hex: String) -> [UInt8] {
    let digits = Array(hex.utf8).filter { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: ":") }
    precondition(digits.count % 2 == 0, "odd hex string")
    func nibble(_ c: UInt8) -> UInt8 {
      switch c {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
      case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
      case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
      default: preconditionFailure("not hex: \(c)")
      }
    }
    return stride(from: 0, to: digits.count, by: 2).map { nibble(digits[$0]) << 4 | nibble(digits[$0 + 1]) }
  }

  static func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  static var multiplier: Int {
    ProcessInfo.processInfo.environment["SSHENGINE_PRIMITIVE_CASES"].flatMap { Int($0) }.map { max(1, $0) } ?? 1
  }

  static var seed: UInt64 {
    ProcessInfo.processInfo.environment["SSHENGINE_PRIMITIVE_SEED"].flatMap { UInt64($0) } ?? 0x5353_4845_6e67_696e
  }

  static var benchmarks: Bool { ProcessInfo.processInfo.environment["SSHENGINE_PRIMITIVE_BENCH"] == "1" }
}

/// SplitMix64: deterministic, seedable, good enough to spread test inputs (not for keys).
struct PrimitiveRandom: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9e37_79b9_7f4a_7c15
    var z = state
    z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
    z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
    return z ^ (z >> 31)
  }

  mutating func bytes(_ count: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: count)
    var index = 0
    while index < count {
      var word = next()
      for _ in 0..<8 where index < count {
        out[index] = UInt8(truncatingIfNeeded: word)
        word >>= 8
        index += 1
      }
    }
    return out
  }
}

extension ChaCha20 {
  /// Keystream block `counter` (64 bytes) as an array, through `block(counter:into:)`.
  func block(counter: UInt64) -> [UInt8] {
    var block = [UInt8](repeating: 0, count: Self.blockSize)
    block.withUnsafeMutableBytes { self.block(counter: counter, into: $0) }
    return block
  }
}

/// RFC 8439 §2.8's AEAD_CHACHA20_POLY1305 assembled from the two primitives, for the differential tests: Poly1305 key
/// from block 0, ciphertext from block 1, tag over aad | pad16 | ciphertext | pad16 | le64(aad) | le64(ciphertext).
///
/// The construction takes 12-byte nonces only. `ChaCha20` also takes 8 (the original layout), which is not this AEAD,
/// so both directions refuse any other size with `ChaCha20.Error.nonceSize` before using the key.
enum AssembledAEAD {
  static let nonceSize = 12

  static func seal(key: [UInt8], nonce: [UInt8], aad: [UInt8], plaintext: [UInt8]) throws -> (ciphertext: [UInt8], tag: [UInt8]) {
    guard nonce.count == nonceSize else { throw ChaCha20.Error.nonceSize(nonce.count) }
    let cipher = try ChaCha20(key: key, nonce: nonce)
    var ciphertext = plaintext
    cipher.xor(&ciphertext, counter: 1)
    return (ciphertext, tag(cipher, aad: aad, ciphertext: ciphertext))
  }

  /// The plaintext, or nil when the tag does not verify (checked before anything is decrypted).
  static func open(key: [UInt8], nonce: [UInt8], aad: [UInt8], ciphertext: [UInt8], tag received: [UInt8]) throws -> [UInt8]? {
    guard nonce.count == nonceSize else { throw ChaCha20.Error.nonceSize(nonce.count) }
    let cipher = try ChaCha20(key: key, nonce: nonce)
    guard ConstantTime.equal(tag(cipher, aad: aad, ciphertext: ciphertext), received) else { return nil }
    var plaintext = ciphertext
    cipher.xor(&plaintext, counter: 1)
    return plaintext
  }

  static func tag(_ cipher: ChaCha20, aad: [UInt8], ciphertext: [UInt8]) -> [UInt8] {
    let oneTimeKey = Array(cipher.block(counter: 0).prefix(32))
    var mac = Poly1305(key: oneTimeKey)
    let zeros = [UInt8](repeating: 0, count: 16)
    mac.update(aad)
    mac.update(Array(zeros.prefix((16 - aad.count % 16) % 16)))
    mac.update(ciphertext)
    mac.update(Array(zeros.prefix((16 - ciphertext.count % 16) % 16)))
    var lengths = [UInt8](repeating: 0, count: 16)
    lengths.withUnsafeMutableBytes {
      $0.storeBytes(of: UInt64(aad.count).littleEndian, toByteOffset: 0, as: UInt64.self)
      $0.storeBytes(of: UInt64(ciphertext.count).littleEndian, toByteOffset: 8, as: UInt64.self)
    }
    mac.update(lengths)
    return mac.finalize()
  }
}
