import XCTest
@testable import SSHEngine

/// Poly1305 against RFC 8439's vectors (A.3's reduction edge cases included) and StableLib's, against a slow
/// big-integer reference on inputs chosen to land the accumulator next to 0 and 2^130 - 5, and the incremental
/// interface against the one-shot.
final class Poly1305Tests: XCTestCase {
  private typealias T = PrimitiveTestSupport

  /// §2.5.2.
  func testRFC8439Example() {
    let key = T.bytes("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b")
    XCTAssertEqual(T.hex(Poly1305.authenticate(T.bytes(RFC8439.polyMessage), key: key)), "a8061dc1305136c6c22b8baf0c0127a9")
    XCTAssertEqual(T.hex(PolyReference.tag(key: key, message: T.bytes(RFC8439.polyMessage))), "a8061dc1305136c6c22b8baf0c0127a9")
  }

  /// A.3 #1-#11: zero key, r = 0, s = 0, and the cases that probe partial reduction, s overflow, carries from an
  /// all-ones limb, results of exactly 2^130 - 5 and 2^130 - 6, and 131-bit intermediate and final results.
  func testRFC8439AppendixVectors() {
    var cases: [(Int, [UInt8], [UInt8], String)] = [
      (1, T.bytes(RFC8439.a3Key1), T.bytes(RFC8439.a3Text1), RFC8439.a3Tag1),
      (2, T.bytes(RFC8439.a3Key2), T.bytes(RFC8439.a3Text2), RFC8439.a3Tag2),
      (3, T.bytes(RFC8439.a3Key3), T.bytes(RFC8439.a3Text3), RFC8439.a3Tag3),
      (4, T.bytes(RFC8439.a3Key4), T.bytes(RFC8439.a3Text4), RFC8439.a3Tag4),
    ]
    let split: [(String, String, String, String)] = [
      (RFC8439.a3R5, RFC8439.a3S5, RFC8439.a3Text5, RFC8439.a3Tag5),
      (RFC8439.a3R6, RFC8439.a3S6, RFC8439.a3Text6, RFC8439.a3Tag6),
      (RFC8439.a3R7, RFC8439.a3S7, RFC8439.a3Text7, RFC8439.a3Tag7),
      (RFC8439.a3R8, RFC8439.a3S8, RFC8439.a3Text8, RFC8439.a3Tag8),
      (RFC8439.a3R9, RFC8439.a3S9, RFC8439.a3Text9, RFC8439.a3Tag9),
      (RFC8439.a3R10, RFC8439.a3S10, RFC8439.a3Text10, RFC8439.a3Tag10),
      (RFC8439.a3R11, RFC8439.a3S11, RFC8439.a3Text11, RFC8439.a3Tag11),
    ]
    for (index, (r, s, text, tag)) in split.enumerated() {
      cases.append((index + 5, T.bytes(r) + T.bytes(s), T.bytes(text), tag))
    }
    for (number, key, text, tag) in cases {
      XCTAssertEqual(T.hex(Poly1305.authenticate(text, key: key)), tag, "A.3 #\(number)")
      XCTAssertEqual(T.hex(PolyReference.tag(key: key, message: text)), tag, "A.3 #\(number) (reference)")
      // Byte at a time through the incremental interface.
      var state = Poly1305(key: key)
      for byte in text { state.update([byte]) }
      XCTAssertEqual(T.hex(state.finalize()), tag, "A.3 #\(number) incremental")
    }
  }

  /// StableLib's 32 Poly1305 vectors (noble-ciphers' `stablelib_poly1305.json`; the key is the field's first 32 bytes;
  /// messages of 0 to 2007 bytes, some repeating A.3): one-shot, byte at a time, and in two `update` calls split on
  /// and around the 16-byte blocks and in the middle.
  func testStableLibVectors() throws {
    let vectors = try VectorFiles.stableLibPoly1305()
    XCTAssertEqual(vectors.count, 32)
    for (number, vector) in vectors.enumerated() {
      let key = Array(T.bytes(vector.key).prefix(32))
      let data = T.bytes(vector.data)
      XCTAssertEqual(T.hex(Poly1305.authenticate(data, key: key)), vector.mac, "#\(number)")
      var bytewise = Poly1305(key: key)
      for byte in data { bytewise.update([byte]) }
      XCTAssertEqual(T.hex(bytewise.finalize()), vector.mac, "#\(number) byte at a time")
      let splits = Set([0, 1, 15, 16, 17, 33, data.count / 2, data.count - 1, data.count])
      for split in splits.sorted() where (0...data.count).contains(split) {
        var state = Poly1305(key: key)
        state.update(Array(data[..<split]))
        state.update(Array(data[split...]))
        XCTAssertEqual(T.hex(state.finalize()), vector.mac, "#\(number) split at \(split)")
      }
    }
  }

  /// §2.6.2 and A.4: the one-time key is the first 32 bytes of ChaCha20 block 0.
  func testRFC8439KeyGeneration() throws {
    let cases: [(String, String, String)] = [
      (RFC8439.keyGenKey, RFC8439.keyGenNonce, RFC8439.keyGenOutput),
      (RFC8439.a4Key1, RFC8439.a4Nonce1, RFC8439.a4OneTimeKey1),
      (RFC8439.a4Key2, RFC8439.a4Nonce2, RFC8439.a4OneTimeKey2),
      (RFC8439.a4Key3, RFC8439.a4Nonce3, RFC8439.a4OneTimeKey3),
      (RFC8439.a5Key, RFC8439.a5Nonce, RFC8439.a5OneTimeKey),
    ]
    for (key, nonce, oneTimeKey) in cases {
      let cipher = try ChaCha20(key: T.bytes(key), nonce: T.bytes(nonce))
      XCTAssertEqual(T.hex(cipher.block(counter: 0).prefix(32)), oneTimeKey)
    }
  }

  /// Accumulators next to 0 and p = 2^130 - 5 for random r: the last block is solved (in the reference's arithmetic)
  /// so that h ≡ t (mod p) for t in -8...8 just before s is added, with message lengths ending on and off a block
  /// boundary. These are the values a wrong final reduction or carry gets wrong, and random messages essentially never
  /// produce them.
  func testAccumulatorNextToZeroAndThePrime() {
    var random = PrimitiveRandom(seed: T.seed &+ 10)
    var checked = 0
    for trial in 0..<(40 * T.multiplier) {
      var key = random.bytes(32)
      if trial % 4 == 0 { for index in 16..<32 { key[index] = 0 } }  // s = 0: the tag is h itself
      if trial % 4 == 1 { for index in 16..<32 { key[index] = 0xff } } // s = 2^128 - 1: the addition wraps
      let r = PolyReference.clampedR(key)
      guard !r.isZero else { continue }
      let inverse = PolyReference.inverse(r)
      for target in -8...8 {
        for prefixBlocks in [0, 1, 3] {
          // Prefix blocks are random, except some all 0xFF; then one last whole block solved for the target.
          var message: [UInt8] = []
          for block in 0..<prefixBlocks { message += block % 2 == 0 ? random.bytes(16) : [UInt8](repeating: 0xff, count: 16) }
          guard let last = PolyReference.solveLastBlock(prefix: message, r: r, inverse: inverse, target: target) else { continue }
          message += last
          let expected = PolyReference.tag(key: key, message: message)
          XCTAssertEqual(PolyReference.accumulator(r: r, message: message), PolyReference.residue(target), "target \(target)")
          XCTAssertEqual(Poly1305.authenticate(message, key: key), expected, "target \(target), key \(T.hex(key))")
          checked += 1
        }
      }
    }
    XCTAssertGreaterThan(checked, 200 * T.multiplier)
  }

  /// r = 1: the accumulator is the plain sum of the blocks with their 2^128 bits, so it can be steered to every value in
  /// p - 12 ... p + 12 (three blocks) and 2p - 12 ... 2p + 12 (five blocks, past 2^130 on the way) before the final
  /// reduction (A.3 #8 is p itself), with s = 0 and s all ones, largest blocks first and last.
  func testSumsAroundThePrimeWithROne() {
    typealias Number = PolyReference.Number
    let limit = Number.power(of2: 128).minus(1)
    var checked = 0
    for (multiple, blocks) in [(1, 3), (2, 5)] {
      for delta in -12...12 {
        let target = PolyReference.add(PolyReference.p.times(UInt64(multiple)), delta)
        // Σ m_i = target - blocks · 2^128, each m_i ≤ 2^128 - 1: fill greedily.
        var rest = target.subtracting(Number.power(of2: 128).times(UInt64(blocks)))!
        var parts: [[UInt8]] = []
        for _ in 0..<blocks {
          let part = rest.lessThan(limit) ? rest : limit
          parts.append(part.littleEndian(16))
          rest = rest.subtracting(part)!
        }
        XCTAssertTrue(rest.isZero)
        for message in [parts.joined(), parts.reversed().joined()].map(Array.init) {
          XCTAssertEqual(PolyReference.accumulator(r: Number(1), message: message), PolyReference.reduce(target))
          for s in [[UInt8](repeating: 0, count: 16), [UInt8](repeating: 0xff, count: 16)] {
            let key = [1] + [UInt8](repeating: 0, count: 15) + s
            XCTAssertEqual(Poly1305.authenticate(message, key: key), PolyReference.tag(key: key, message: message),
                           "\(multiple)p + \(delta)")
            checked += 1
          }
        }
      }
    }
    XCTAssertEqual(checked, 2 * 25 * 2 * 2)
  }

  /// All-0xFF and all-zero messages of every length 0...130 under keys whose r has every bit the clamp keeps (and,
  /// separately, r = 0 and r with only the top kept bits), against the reference.
  func testSaturatedMessagesAndKeys() {
    var random = PrimitiveRandom(seed: T.seed &+ 11)
    let rMax = T.bytes("ffffff0ffcffff0ffcffff0ffcffff0f")
    let rTop = T.bytes("0000000ffcffff0f000000000000000f")
    let keys: [[UInt8]] = [
      rMax + [UInt8](repeating: 0xff, count: 16),
      rMax + [UInt8](repeating: 0, count: 16),
      rTop + random.bytes(16),
      [UInt8](repeating: 0, count: 16) + random.bytes(16),
      [UInt8](repeating: 0xff, count: 32),
      random.bytes(32),
    ]
    for key in keys {
      for length in 0...130 {
        for fill: UInt8 in [0xff, 0x00] {
          let message = [UInt8](repeating: fill, count: length)
          XCTAssertEqual(Poly1305.authenticate(message, key: key), PolyReference.tag(key: key, message: message),
                         "length \(length) fill \(fill) key \(T.hex(key))")
        }
      }
    }
  }

  /// The bits the clamp clears (top 4 of bytes 3, 7, 11, 15; low 2 of 4, 8, 12) change nothing.
  func testClampedBitsAreIgnored() {
    var random = PrimitiveRandom(seed: T.seed &+ 12)
    for _ in 0..<(200 * T.multiplier) {
      var key = random.bytes(32)
      let message = random.bytes(Int(random.next() % 100))
      var clamped = key
      for index in [3, 7, 11, 15] { clamped[index] &= 0x0f }
      for index in [4, 8, 12] { clamped[index] &= 0xfc }
      for index in [3, 7, 11, 15] { key[index] |= 0xf0 }
      for index in [4, 8, 12] { key[index] |= 0x03 }
      XCTAssertEqual(Poly1305.authenticate(message, key: key), Poly1305.authenticate(message, key: clamped))
      XCTAssertEqual(Poly1305.authenticate(message, key: key), PolyReference.tag(key: clamped, message: message))
    }
  }

  /// Random keys and messages of lengths around block boundaries and up to a few blocks, against the reference; and
  /// every message split at random points into `update` calls gives the one-shot tag.
  func testRandomMessagesAgainstTheReferenceAndAnySplit() {
    var random = PrimitiveRandom(seed: T.seed &+ 13)
    let lengths = [0, 1, 2, 15, 16, 17, 31, 32, 33, 47, 48, 49, 63, 64, 65, 127, 128, 129, 255, 256, 257, 1000]
    for round in 0..<(1500 * T.multiplier) {
      let key = random.bytes(32)
      let length = round < lengths.count * 20 ? lengths[round % lengths.count] : Int(random.next() % 300)
      let message = random.bytes(length)
      let tag = Poly1305.authenticate(message, key: key)
      XCTAssertEqual(tag, PolyReference.tag(key: key, message: message), "length \(length)")
      var state = Poly1305(key: key)
      var offset = 0
      while offset < length {
        let piece = min(length - offset, Int(random.next() % 40))
        state.update(Array(message[offset..<(offset + piece)]))
        offset += piece
      }
      XCTAssertEqual(state.finalize(), tag, "length \(length), split")
    }
  }

  func testTagComparison() {
    var random = PrimitiveRandom(seed: T.seed &+ 14)
    let tag = random.bytes(16)
    XCTAssertTrue(ConstantTime.equal(tag, tag))
    XCTAssertTrue(ConstantTime.equal([UInt8](), [UInt8]()))
    for index in 0..<16 {
      for bit in 0..<8 {
        var other = tag
        other[index] ^= 1 << bit
        XCTAssertFalse(ConstantTime.equal(tag, other), "byte \(index) bit \(bit)")
      }
    }
    var all = tag
    for index in 0..<16 { all[index] = ~all[index] }
    XCTAssertFalse(ConstantTime.equal(tag, all))
    XCTAssertFalse(ConstantTime.equal(tag, Array(tag.prefix(15))))
    XCTAssertFalse(ConstantTime.equal(tag, tag + [0]))
  }

  /// `finalize` clears the state: a second finalize is the tag of nothing under the all-zero key (zero).
  func testFinalizeClearsTheState() {
    var state = Poly1305(key: [UInt8](repeating: 0x77, count: 32))
    state.update([1, 2, 3])
    XCTAssertNotEqual(state.finalize(), [UInt8](repeating: 0, count: 16))
    XCTAssertEqual(state.finalize(), [UInt8](repeating: 0, count: 16))
  }
}

/// Poly1305 by the definition, in slow arbitrary-precision arithmetic (32-bit limbs, reduction by repeated folding
/// and subtraction): shares no code or limb layout with `Poly1305`.
enum PolyReference {
  /// A non-negative integer, little-endian 32-bit limbs (each below 2^32 in a `UInt64`), no trailing zero limbs.
  struct Number: Equatable {
    var limbs: [UInt64]

    init(_ value: UInt64) { limbs = [value & 0xffff_ffff, value >> 32]; trim() }
    init(limbs: [UInt64]) { self.limbs = limbs; trim() }

    init(littleEndian bytes: [UInt8]) {
      var limbs = [UInt64](repeating: 0, count: (bytes.count + 3) / 4)
      for (index, byte) in bytes.enumerated() { limbs[index / 4] |= UInt64(byte) << (8 * (index % 4)) }
      self.init(limbs: limbs)
    }

    static func power(of2 bits: Int) -> Number {
      var limbs = [UInt64](repeating: 0, count: bits / 32 + 1)
      limbs[bits / 32] = 1 << (bits % 32)
      return Number(limbs: limbs)
    }

    var isZero: Bool { limbs.isEmpty }

    mutating func trim() { while limbs.last == 0 { limbs.removeLast() } }

    func plus(_ other: Number) -> Number {
      var out = [UInt64](repeating: 0, count: max(limbs.count, other.limbs.count) + 1)
      var carry: UInt64 = 0
      for index in 0..<out.count {
        let sum = (index < limbs.count ? limbs[index] : 0) + (index < other.limbs.count ? other.limbs[index] : 0) + carry
        out[index] = sum & 0xffff_ffff
        carry = sum >> 32
      }
      return Number(limbs: out)
    }

    func plus(_ small: UInt64) -> Number { plus(Number(small)) }

    /// `self - other`, or nil when negative.
    func subtracting(_ other: Number) -> Number? {
      if lessThan(other) { return nil }
      var out = limbs
      var borrow: Int64 = 0
      for index in 0..<out.count {
        var value = Int64(out[index]) - Int64(index < other.limbs.count ? other.limbs[index] : 0) - borrow
        borrow = 0
        if value < 0 { value += 1 << 32; borrow = 1 }
        out[index] = UInt64(value)
      }
      return Number(limbs: out)
    }

    func minus(_ small: UInt64) -> Number { subtracting(Number(small))! }

    func times(_ other: Number) -> Number {
      if isZero || other.isZero { return Number(0) }
      var out = [UInt64](repeating: 0, count: limbs.count + other.limbs.count + 1)
      for i in 0..<limbs.count {
        var carry: UInt64 = 0
        for j in 0..<other.limbs.count {
          let value = out[i + j] + limbs[i] * other.limbs[j] + carry
          out[i + j] = value & 0xffff_ffff
          carry = value >> 32
        }
        var k = i + other.limbs.count
        while carry > 0 {
          let value = out[k] + carry
          out[k] = value & 0xffff_ffff
          carry = value >> 32
          k += 1
        }
      }
      return Number(limbs: out)
    }

    func times(_ small: UInt64) -> Number { times(Number(small)) }

    func lessThan(_ other: Number) -> Bool {
      if limbs.count != other.limbs.count { return limbs.count < other.limbs.count }
      for index in stride(from: limbs.count - 1, through: 0, by: -1) where limbs[index] != other.limbs[index] {
        return limbs[index] < other.limbs[index]
      }
      return false
    }

    /// The low `bits` bits, and the rest shifted down.
    func split(at bits: Int) -> (low: Number, high: Number) {
      var low = [UInt64](repeating: 0, count: bits / 32 + 1)
      var high: [UInt64] = []
      for index in 0..<limbs.count {
        if index < bits / 32 { low[index] = limbs[index] }
      }
      if bits / 32 < limbs.count { low[bits / 32] = limbs[bits / 32] & ((1 << (bits % 32)) - 1) }
      let shift = bits % 32
      for index in (bits / 32)..<max(bits / 32, limbs.count) {
        let current = limbs[index] >> shift
        let next = index + 1 < limbs.count ? (limbs[index + 1] << (32 - shift)) & 0xffff_ffff : 0
        high.append(shift == 0 ? limbs[index] : current | next)
      }
      return (Number(limbs: low), Number(limbs: high))
    }

    func littleEndian(_ count: Int) -> [UInt8] {
      (0..<count).map { index in index / 4 < limbs.count ? UInt8(truncatingIfNeeded: limbs[index / 4] >> (8 * (index % 4))) : 0 }
    }
  }

  static let p = Number.power(of2: 130).minus(5)

  /// x mod p: fold 2^130 ≡ 5 until below 2^130, then subtract p at most once.
  static func reduce(_ x: Number) -> Number {
    var x = x
    while !x.lessThan(Number.power(of2: 130)) {
      let (low, high) = x.split(at: 130)
      x = low.plus(high.times(5))
    }
    return x.subtracting(p) ?? x
  }

  static func multiply(_ a: Number, _ b: Number) -> Number { reduce(a.times(b)) }

  /// a + delta for a small signed delta (a ≥ |delta|).
  static func add(_ a: Number, _ delta: Int) -> Number {
    delta >= 0 ? a.plus(UInt64(delta)) : a.minus(UInt64(-delta))
  }

  /// t mod p for a small signed t.
  static func residue(_ t: Int) -> Number { t >= 0 ? Number(UInt64(t)) : p.minus(UInt64(-t)) }

  static func clampedR(_ key: [UInt8]) -> Number {
    var r = Array(key[0..<16])
    for index in [3, 7, 11, 15] { r[index] &= 0x0f }
    for index in [4, 8, 12] { r[index] &= 0xfc }
    return Number(littleEndian: r)
  }

  /// r^(p-2) mod p.
  static func inverse(_ r: Number) -> Number {
    let exponent = p.minus(2)
    var result = Number(1)
    var base = reduce(r)
    for bit in 0..<130 {
      if (exponent.limbs[bit / 32] >> (bit % 32)) & 1 == 1 { result = multiply(result, base) }
      base = multiply(base, base)
    }
    return result
  }

  /// The polynomial part, fully reduced: Σ (block_i + 2^(8·len_i)) · r^(n-i+1) mod p.
  static func accumulator(r: Number, message: [UInt8]) -> Number {
    var h = Number(0)
    var offset = 0
    while offset < message.count {
      let block = Array(message[offset..<min(offset + 16, message.count)]) + [1]
      h = multiply(h.plus(Number(littleEndian: block)), r)
      offset += 16
    }
    return h
  }

  static func tag(key: [UInt8], message: [UInt8]) -> [UInt8] {
    let h = accumulator(r: clampedR(key), message: message)
    return h.plus(Number(littleEndian: Array(key[16..<32]))).littleEndian(16)
  }

  /// A 16-byte block that, appended to `prefix` (whole blocks), makes the accumulator ≡ target (mod p); nil when the
  /// solution does not fit in 128 bits (about three times in four).
  static func solveLastBlock(prefix: [UInt8], r: Number, inverse: Number, target: Int) -> [UInt8]? {
    // ((h + m + 2^128) · r) ≡ t  ⇒  m ≡ t · r⁻¹ - h - 2^128 (mod p).
    let h = accumulator(r: r, message: prefix)
    let wanted = multiply(residue(target), inverse)
    let subtrahend = reduce(h.plus(Number.power(of2: 128)))
    let m = wanted.subtracting(subtrahend) ?? wanted.plus(p).subtracting(subtrahend)!
    guard m.lessThan(Number.power(of2: 128)) else { return nil }
    return m.littleEndian(16)
  }
}
