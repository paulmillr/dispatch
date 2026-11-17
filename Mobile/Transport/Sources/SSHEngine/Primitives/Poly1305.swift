import Foundation

/// Poly1305 (RFC 8439 §2.5): the one-time authenticator, one-shot (`authenticate`) or incremental (`update`, then
/// `finalize`). A key must authenticate one message only; the SSH cipher takes it from keystream block 0.
///
/// Arithmetic is poly1305-donna's 32-bit form, ported from its `poly1305-donna-32.h`
/// (https://github.com/floodyberry/poly1305-donna, offered as "MIT or PUBLIC DOMAIN" and taken here under its
/// public-domain option): the accumulator `h` and `r` in five 26-bit limbs, products in `UInt64`.
/// Bounds (so `&+`/`&*` never actually wrap): after each block `h` limbs are below 2^26 except `h1` below 2^26 + 2^6;
/// adding a block keeps them below 2^27; `r` limbs are below 2^26 and `5·r` below 2^29, so each of the five products
/// in a column is below 2^56 and a column sum below 2^59.
///
/// Constant time: no branch, index or loop bound depends on the key, the accumulator or the message bytes; loops and
/// branches depend on lengths only (the bytes buffered so far, the count passed in). Carries are shifts and masks. The
/// final reduction computes `h + 5 - 2^130` and selects it or `h` with a mask built from its sign bit (`mask = (g4 >>
/// 31) &- 1`), never a comparison. Multiplication is 32×32→64 (`umull` on arm64), which Apple's arm64 and x86-64 cores
/// execute in data-independent time. As with `ChaCha20`, this holds for the source: Swift gives no constant-time
/// guarantee, so it assumes the compiler does not turn the mask arithmetic back into branches (LLVM has no reason to,
/// and nothing here is a comparison it could fold).
///
/// Secrets: `finalize` clears the whole state (`memset_s` over the value) before it returns, and the one-shot form
/// never lets its state escape. Copies Swift made of an incremental value in between, and register or stack
/// temporaries, cannot be cleared from Swift.
struct Poly1305: Sendable {
  static let keySize = 32
  static let tagSize = 16

  private var r0, r1, r2, r3, r4: UInt32
  private var s1, s2, s3, s4: UInt32
  private var h0: UInt32 = 0, h1: UInt32 = 0, h2: UInt32 = 0, h3: UInt32 = 0, h4: UInt32 = 0
  private var pad0, pad1, pad2, pad3: UInt32
  /// A partial block waiting for more bytes, and how many of its 16 bytes are filled (a length: public).
  private var pending: (UInt64, UInt64) = (0, 0)
  private var pendingCount = 0

  /// `key`: 32 bytes, `r` then `s` (a precondition: the key's size is the caller's, never the peer's).
  init(key: UnsafeRawBufferPointer) {
    precondition(key.count == Self.keySize, "a Poly1305 key is 32 bytes")
    // r &= 0x0ffffffc0ffffffc0ffffffc0fffffff, split into 26-bit limbs.
    r0 = Self.word(key, 0) & 0x3ff_ffff
    r1 = (Self.word(key, 3) &>> 2) & 0x3ff_ff03
    r2 = (Self.word(key, 6) &>> 4) & 0x3ff_c0ff
    r3 = (Self.word(key, 9) &>> 6) & 0x3f0_3fff
    r4 = (Self.word(key, 12) &>> 8) & 0x00f_ffff
    s1 = r1 &* 5; s2 = r2 &* 5; s3 = r3 &* 5; s4 = r4 &* 5
    pad0 = Self.word(key, 16); pad1 = Self.word(key, 20); pad2 = Self.word(key, 24); pad3 = Self.word(key, 28)
  }

  init(key: some ContiguousBytes) {
    self = key.withUnsafeBytes { Poly1305(key: $0) }
  }

  /// The tag of `message` under the one-time `key`.
  static func authenticate(_ message: UnsafeRawBufferPointer, key: UnsafeRawBufferPointer) -> [UInt8] {
    var state = Poly1305(key: key)
    state.update(message)
    return state.finalize()
  }

  static func authenticate(_ message: some ContiguousBytes, key: some ContiguousBytes) -> [UInt8] {
    key.withUnsafeBytes { key in message.withUnsafeBytes { authenticate($0, key: key) } }
  }

  /// Absorbs `message`; any split of a message gives the same tag as the whole.
  mutating func update(_ message: UnsafeRawBufferPointer) {
    guard var source = message.baseAddress, message.count > 0 else { return }
    var remaining = message.count
    if pendingCount > 0 {
      let take = min(16 &- pendingCount, remaining)
      let filled = pendingCount
      withUnsafeMutableBytes(of: &pending) { $0.baseAddress!.advanced(by: filled).copyMemory(from: source, byteCount: take) }
      pendingCount = pendingCount &+ take
      source += take
      remaining = remaining &- take
      guard pendingCount == 16 else { return }
      var block = pending
      withUnsafeBytes(of: &block) { absorb($0.baseAddress!, count: 16, hibit: 1 &<< 24) }
      Self.clear(&block)
      pending = (0, 0)
      pendingCount = 0
    }
    let whole = remaining & ~15
    if whole > 0 { absorb(source, count: whole, hibit: 1 &<< 24) }
    if remaining > whole {
      let rest = remaining &- whole
      withUnsafeMutableBytes(of: &pending) { $0.baseAddress!.copyMemory(from: source + whole, byteCount: rest) }
      pendingCount = rest
    }
  }

  mutating func update(_ message: some ContiguousBytes) {
    message.withUnsafeBytes { update($0) }
  }

  /// The 16-byte tag. Clears the state: the value authenticates nothing further (its key is gone).
  mutating func finalize() -> [UInt8] {
    if pendingCount > 0 {
      // The last partial block: its bytes, a 1 byte, zeros; and no 2^128 bit (hibit 0).
      var block = pending
      let filled = pendingCount
      withUnsafeMutableBytes(of: &block) { bytes in
        bytes[filled] = 1
        for index in (filled &+ 1)..<16 { bytes[index] = 0 }
      }
      withUnsafeBytes(of: &block) { absorb($0.baseAddress!, count: 16, hibit: 0) }
      Self.clear(&block)
    }
    var h0 = h0, h1 = h1, h2 = h2, h3 = h3, h4 = h4
    // Full carry: h below 2^130 + small, limbs below 2^26.
    var c = h1 &>> 26; h1 &= 0x3ff_ffff
    h2 = h2 &+ c; c = h2 &>> 26; h2 &= 0x3ff_ffff
    h3 = h3 &+ c; c = h3 &>> 26; h3 &= 0x3ff_ffff
    h4 = h4 &+ c; c = h4 &>> 26; h4 &= 0x3ff_ffff
    h0 = h0 &+ c &* 5; c = h0 &>> 26; h0 &= 0x3ff_ffff
    h1 = h1 &+ c
    // g = h + 5 - 2^130; h >= p exactly when g's top bit is clear.
    var g0 = h0 &+ 5; c = g0 &>> 26; g0 &= 0x3ff_ffff
    var g1 = h1 &+ c; c = g1 &>> 26; g1 &= 0x3ff_ffff
    var g2 = h2 &+ c; c = g2 &>> 26; g2 &= 0x3ff_ffff
    var g3 = h3 &+ c; c = g3 &>> 26; g3 &= 0x3ff_ffff
    var g4 = h4 &+ c &- (1 &<< 26)
    // All ones when g4 did not go negative (select g), zero when it did (keep h).
    var mask = (g4 &>> 31) &- 1
    g0 &= mask; g1 &= mask; g2 &= mask; g3 &= mask; g4 &= mask
    mask = ~mask
    h0 = (h0 & mask) | g0; h1 = (h1 & mask) | g1; h2 = (h2 & mask) | g2
    h3 = (h3 & mask) | g3; h4 = (h4 & mask) | g4
    // h mod 2^128 in four 32-bit words, then + s mod 2^128.
    let w0 = h0 | (h1 &<< 26)
    let w1 = (h1 &>> 6) | (h2 &<< 20)
    let w2 = (h2 &>> 12) | (h3 &<< 14)
    let w3 = (h3 &>> 18) | (h4 &<< 8)
    var f = UInt64(w0) &+ UInt64(pad0)
    let t0 = UInt32(truncatingIfNeeded: f)
    f = UInt64(w1) &+ UInt64(pad1) &+ (f &>> 32)
    let t1 = UInt32(truncatingIfNeeded: f)
    f = UInt64(w2) &+ UInt64(pad2) &+ (f &>> 32)
    let t2 = UInt32(truncatingIfNeeded: f)
    f = UInt64(w3) &+ UInt64(pad3) &+ (f &>> 32)
    let t3 = UInt32(truncatingIfNeeded: f)
    let tag = [UInt8](unsafeUninitializedCapacity: Self.tagSize) { buffer, initialized in
      let raw = UnsafeMutableRawBufferPointer(buffer)
      raw.storeBytes(of: t0.littleEndian, toByteOffset: 0, as: UInt32.self)
      raw.storeBytes(of: t1.littleEndian, toByteOffset: 4, as: UInt32.self)
      raw.storeBytes(of: t2.littleEndian, toByteOffset: 8, as: UInt32.self)
      raw.storeBytes(of: t3.littleEndian, toByteOffset: 12, as: UInt32.self)
      initialized = Self.tagSize
    }
    withUnsafeMutableBytes(of: &self) { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
    return tag
  }

  /// Absorbs `count` bytes (a multiple of 16) at `pointer`; `hibit` is 2^24 in the top limb (the 2^128 bit every
  /// whole block gets) or 0 for an already padded last block. h = (h + block) · r mod 2^130 - 5, partially reduced.
  private mutating func absorb(_ pointer: UnsafeRawPointer, count: Int, hibit: UInt32) {
    let r0 = r0, r1 = r1, r2 = r2, r3 = r3, r4 = r4
    let s1 = s1, s2 = s2, s3 = s3, s4 = s4
    var h0 = h0, h1 = h1, h2 = h2, h3 = h3, h4 = h4
    var offset = 0
    while offset < count {
      let m = pointer + offset
      h0 = h0 &+ (Self.word(m, 0) & 0x3ff_ffff)
      h1 = h1 &+ ((Self.word(m, 3) &>> 2) & 0x3ff_ffff)
      h2 = h2 &+ ((Self.word(m, 6) &>> 4) & 0x3ff_ffff)
      h3 = h3 &+ ((Self.word(m, 9) &>> 6) & 0x3ff_ffff)
      h4 = h4 &+ ((Self.word(m, 12) &>> 8) | hibit)

      let d0 = Self.mul(h0, r0) &+ Self.mul(h1, s4) &+ Self.mul(h2, s3) &+ Self.mul(h3, s2) &+ Self.mul(h4, s1)
      var d1 = Self.mul(h0, r1) &+ Self.mul(h1, r0) &+ Self.mul(h2, s4) &+ Self.mul(h3, s3) &+ Self.mul(h4, s2)
      var d2 = Self.mul(h0, r2) &+ Self.mul(h1, r1) &+ Self.mul(h2, r0) &+ Self.mul(h3, s4) &+ Self.mul(h4, s3)
      var d3 = Self.mul(h0, r3) &+ Self.mul(h1, r2) &+ Self.mul(h2, r1) &+ Self.mul(h3, r0) &+ Self.mul(h4, s4)
      var d4 = Self.mul(h0, r4) &+ Self.mul(h1, r3) &+ Self.mul(h2, r2) &+ Self.mul(h3, r1) &+ Self.mul(h4, r0)

      var c = UInt32(truncatingIfNeeded: d0 &>> 26); h0 = UInt32(truncatingIfNeeded: d0) & 0x3ff_ffff
      d1 = d1 &+ UInt64(c); c = UInt32(truncatingIfNeeded: d1 &>> 26); h1 = UInt32(truncatingIfNeeded: d1) & 0x3ff_ffff
      d2 = d2 &+ UInt64(c); c = UInt32(truncatingIfNeeded: d2 &>> 26); h2 = UInt32(truncatingIfNeeded: d2) & 0x3ff_ffff
      d3 = d3 &+ UInt64(c); c = UInt32(truncatingIfNeeded: d3 &>> 26); h3 = UInt32(truncatingIfNeeded: d3) & 0x3ff_ffff
      d4 = d4 &+ UInt64(c); c = UInt32(truncatingIfNeeded: d4 &>> 26); h4 = UInt32(truncatingIfNeeded: d4) & 0x3ff_ffff
      h0 = h0 &+ c &* 5; c = h0 &>> 26; h0 &= 0x3ff_ffff
      h1 = h1 &+ c
      offset = offset &+ 16
    }
    self.h0 = h0; self.h1 = h1; self.h2 = h2; self.h3 = h3; self.h4 = h4
  }

  @inline(__always)
  private static func mul(_ a: UInt32, _ b: UInt32) -> UInt64 { UInt64(a) &* UInt64(b) }

  @inline(__always)
  private static func word(_ pointer: UnsafeRawPointer, _ offset: Int) -> UInt32 {
    UInt32(littleEndian: pointer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
  }

  @inline(__always)
  private static func word(_ buffer: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
    word(buffer.baseAddress!, offset)
  }

  private static func clear(_ block: inout (UInt64, UInt64)) {
    _ = memset_s(&block, MemoryLayout.size(ofValue: block), 0, MemoryLayout.size(ofValue: block))
  }
}
