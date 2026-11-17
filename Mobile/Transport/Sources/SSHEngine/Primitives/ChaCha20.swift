import Foundation

/// ChaCha20 (RFC 8439 §2.3-2.4): the block function and its keystream XOR, in both state layouts.
///
/// State words 12-15 come from `nonce`. An 8-byte nonce gives Bernstein's original layout, which OpenSSH's
/// `chacha20-poly1305@openssh.com` uses: words 12-13 a 64-bit little-endian block counter, 14-15 the nonce (the
/// packet sequence number, big-endian). A 12-byte nonce gives RFC 8439's: word 12 a 32-bit counter, 13-15 the nonce.
/// Below block 2^32 the two agree when the 12-byte nonce is four zero bytes followed by the 8-byte one
/// (`ChaCha20Tests.testOriginalLayoutIsTheIETFLayoutWithAZeroPrefix`).
///
/// Constant time: the block function is add, xor and rotate by constants on `UInt32` (wrapping `&+`, masking shifts),
/// and its four-block form (`apply4`, for each whole 256 bytes) the same operations on `SIMD4<UInt32>` lanes, one block
/// per lane; no table, and no branch, index or loop bound that depends on the key, the counter or the bytes. Loops and
/// the branches (groups of four blocks, single blocks, a tail) depend on the byte count and the layout only, both
/// public. That is a property of
/// the source: Swift promises nothing about the machine code, so it rests on the compiler emitting these operations as
/// the plain instructions they are on arm64 and x86-64, which it has no reason not to (there is nothing to branch on).
///
/// Secrets: the key words live in this value, which Swift copies freely; `wipe()` zeroes the copy it is called on
/// (`memset_s`, which the compiler may not drop). Keystream words exist only in registers and the stack frame of
/// `apply`, where Swift gives no way to clear them; the one keystream block that is spilled to memory on purpose (a
/// partial last block) is cleared with `memset_s`.
struct ChaCha20: Sendable {
  enum Error: Swift.Error, Equatable {
    case keySize(Int)
    case nonceSize(Int)
  }

  static let keySize = 32
  static let blockSize = 64

  private var k0, k1, k2, k3, k4, k5, k6, k7: UInt32
  /// State words 13-15: nonce words in the RFC layout; in the original one `n13` is unused (the counter's high word).
  private var n13, n14, n15: UInt32
  /// The original layout: a 64-bit counter in words 12-13.
  let wideCounter: Bool

  /// `key`: 32 bytes. `nonce`: 8 bytes (original layout, 64-bit counter) or 12 (RFC 8439, 32-bit counter).
  init(key: some ContiguousBytes, nonce: some ContiguousBytes) throws {
    // Copied through stack tuples (no heap copy of the key), cleared once the words are in place.
    var keyWords: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0, 0, 0, 0)
    let keyCount = key.withUnsafeBytes { source in
      if source.count == Self.keySize { withUnsafeMutableBytes(of: &keyWords) { $0.copyMemory(from: source) } }
      return source.count
    }
    guard keyCount == Self.keySize else { throw Error.keySize(keyCount) }
    // The RFC layout's words 13-15, or the original layout's 14-15 after a zero word 13.
    var nonceWords: (UInt32, UInt32, UInt32) = (0, 0, 0)
    let nonceCount = nonce.withUnsafeBytes { source in
      withUnsafeMutableBytes(of: &nonceWords) { target in
        if source.count == 12 { target.copyMemory(from: source) }
        if source.count == 8 { UnsafeMutableRawBufferPointer(rebasing: target[4...]).copyMemory(from: source) }
      }
      return source.count
    }
    guard nonceCount == 8 || nonceCount == 12 else {
      _ = memset_s(&keyWords, MemoryLayout.size(ofValue: keyWords), 0, MemoryLayout.size(ofValue: keyWords))
      throw Error.nonceSize(nonceCount)
    }
    wideCounter = nonceCount == 8
    k0 = UInt32(littleEndian: keyWords.0); k1 = UInt32(littleEndian: keyWords.1)
    k2 = UInt32(littleEndian: keyWords.2); k3 = UInt32(littleEndian: keyWords.3)
    k4 = UInt32(littleEndian: keyWords.4); k5 = UInt32(littleEndian: keyWords.5)
    k6 = UInt32(littleEndian: keyWords.6); k7 = UInt32(littleEndian: keyWords.7)
    n13 = UInt32(littleEndian: nonceWords.0); n14 = UInt32(littleEndian: nonceWords.1)
    n15 = UInt32(littleEndian: nonceWords.2)
    _ = memset_s(&keyWords, MemoryLayout.size(ofValue: keyWords), 0, MemoryLayout.size(ofValue: keyWords))
  }

  /// Keystream block `counter` (64 bytes). The RFC layout takes counters below 2^32 only (a precondition: callers
  /// choose counters, data never does).
  func block(counter: UInt64) -> [UInt8] {
    [UInt8](unsafeUninitializedCapacity: Self.blockSize) { buffer, initialized in
      // `block(counter:into:)` initializes all 64 bytes.
      block(counter: counter, into: UnsafeMutableRawBufferPointer(buffer))
      initialized = Self.blockSize
    }
  }

  /// Writes keystream block `counter` to the first 64 bytes of `output` (initialized or not). The SSH cipher takes its
  /// Poly1305 key from block 0 this way, into a buffer it owns and clears.
  func block(counter: UInt64, into output: UnsafeMutableRawBufferPointer) {
    precondition(output.count >= Self.blockSize, "a ChaCha20 block is 64 bytes")
    precondition(wideCounter || counter <= UInt64(UInt32.max), "the RFC 8439 layout has a 32-bit counter")
    output.baseAddress!.initializeMemory(as: UInt8.self, repeating: 0, count: Self.blockSize)
    apply(counter: counter, to: output.baseAddress!)
  }

  /// XORs `bytes` in place with the keystream from block `counter` on (encryption and decryption alike). The original
  /// layout's counter wraps modulo 2^64 (2^70 bytes: never reached). The RFC layout requires the blocks to fit below
  /// 2^32 (256 GiB from counter 0), a precondition no buffer that fits in memory on a phone comes near; the SSH
  /// cipher uses the original layout, which has no such limit.
  func xor(_ bytes: UnsafeMutableRawBufferPointer, counter: UInt64) {
    guard let base = bytes.baseAddress, bytes.count > 0 else { return }
    let count = bytes.count
    let blocks = UInt64(count / Self.blockSize) &+ (count % Self.blockSize == 0 ? 0 : 1)
    precondition(wideCounter || (counter <= UInt64(UInt32.max) && blocks <= (1 << 32) &- counter),
                 "the RFC 8439 layout has a 32-bit counter")
    var block = counter
    var offset = 0
    // Four blocks at a time while four whole blocks remain (the same blocks as one at a time: `apply4`).
    while count &- offset >= 4 &* Self.blockSize {
      apply4(counter: block, to: base + offset)
      block = block &+ 4
      offset = offset &+ 4 &* Self.blockSize
    }
    while count &- offset >= Self.blockSize {
      apply(counter: block, to: base + offset)
      block = block &+ 1
      offset = offset &+ Self.blockSize
    }
    let tail = count &- offset
    if tail > 0 {
      withUnsafeTemporaryAllocation(byteCount: Self.blockSize, alignment: 16) { scratch in
        let scratch = scratch.baseAddress!
        scratch.initializeMemory(as: UInt8.self, repeating: 0, count: Self.blockSize)
        apply(counter: block, to: scratch)
        let source = scratch.assumingMemoryBound(to: UInt8.self)
        let target = (base + offset).assumingMemoryBound(to: UInt8.self)
        for index in 0..<tail { target[index] ^= source[index] }
        _ = memset_s(scratch, Self.blockSize, 0, Self.blockSize)
      }
    }
  }

  /// `xor(_:counter:)` over an array.
  func xor(_ bytes: inout [UInt8], counter: UInt64) {
    bytes.withUnsafeMutableBytes { xor($0, counter: counter) }
  }

  /// Zeroes this copy's key and nonce words; the value is unusable (an all-zero key) afterwards.
  mutating func wipe() {
    withUnsafeMutableBytes(of: &self) { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
  }

  /// XORs the 64 bytes at `pointer` (any alignment) with keystream block `counter`: the block function of RFC 8439
  /// §2.3 with the serialization of §2.3 fused into the XOR.
  @inline(__always)
  private func apply(counter: UInt64, to pointer: UnsafeMutableRawPointer) {
    let c12 = UInt32(truncatingIfNeeded: counter)
    // The layout is public; the select is a branch on it, never on data.
    let c13 = wideCounter ? UInt32(truncatingIfNeeded: counter &>> 32) : n13
    var x0: UInt32 = 0x6170_7865, x1: UInt32 = 0x3320_646e, x2: UInt32 = 0x7962_2d32, x3: UInt32 = 0x6b20_6574
    var x4 = k0, x5 = k1, x6 = k2, x7 = k3, x8 = k4, x9 = k5, x10 = k6, x11 = k7
    var x12 = c12, x13 = c13, x14 = n14, x15 = n15
    for _ in 0..<10 {
      Self.quarterRound(&x0, &x4, &x8, &x12)
      Self.quarterRound(&x1, &x5, &x9, &x13)
      Self.quarterRound(&x2, &x6, &x10, &x14)
      Self.quarterRound(&x3, &x7, &x11, &x15)
      Self.quarterRound(&x0, &x5, &x10, &x15)
      Self.quarterRound(&x1, &x6, &x11, &x12)
      Self.quarterRound(&x2, &x7, &x8, &x13)
      Self.quarterRound(&x3, &x4, &x9, &x14)
    }
    Self.mix(pointer, 0, x0 &+ 0x6170_7865)
    Self.mix(pointer, 1, x1 &+ 0x3320_646e)
    Self.mix(pointer, 2, x2 &+ 0x7962_2d32)
    Self.mix(pointer, 3, x3 &+ 0x6b20_6574)
    Self.mix(pointer, 4, x4 &+ k0)
    Self.mix(pointer, 5, x5 &+ k1)
    Self.mix(pointer, 6, x6 &+ k2)
    Self.mix(pointer, 7, x7 &+ k3)
    Self.mix(pointer, 8, x8 &+ k4)
    Self.mix(pointer, 9, x9 &+ k5)
    Self.mix(pointer, 10, x10 &+ k6)
    Self.mix(pointer, 11, x11 &+ k7)
    Self.mix(pointer, 12, x12 &+ c12)
    Self.mix(pointer, 13, x13 &+ c13)
    Self.mix(pointer, 14, x14 &+ n14)
    Self.mix(pointer, 15, x15 &+ n15)
  }

  /// `apply` for blocks `counter` to `counter + 3` at once, XORed into the 256 bytes at `pointer`: the same state words
  /// and quarter rounds with each word a `SIMD4<UInt32>` whose lane i is block `counter + i` (vector add, xor and
  /// rotate by constants; no branch, index or table that depends on the key, counter or bytes, as in `apply`). The
  /// original layout carries each lane's counter into word 13; the RFC layout's callers keep the four counters below
  /// 2^32 (`xor`'s precondition), so its word 13 is the nonce in every lane.
  @inline(__always)
  private func apply4(counter: UInt64, to pointer: UnsafeMutableRawPointer) {
    let counters = SIMD4<UInt64>(counter, counter &+ 1, counter &+ 2, counter &+ 3)
    let c12 = SIMD4<UInt32>(truncatingIfNeeded: counters)
    let c13 = wideCounter ? SIMD4<UInt32>(truncatingIfNeeded: counters &>> 32) : SIMD4<UInt32>(repeating: n13)
    let i0 = SIMD4<UInt32>(repeating: 0x6170_7865), i1 = SIMD4<UInt32>(repeating: 0x3320_646e)
    let i2 = SIMD4<UInt32>(repeating: 0x7962_2d32), i3 = SIMD4<UInt32>(repeating: 0x6b20_6574)
    let i4 = SIMD4<UInt32>(repeating: k0), i5 = SIMD4<UInt32>(repeating: k1), i6 = SIMD4<UInt32>(repeating: k2)
    let i7 = SIMD4<UInt32>(repeating: k3), i8 = SIMD4<UInt32>(repeating: k4), i9 = SIMD4<UInt32>(repeating: k5)
    let i10 = SIMD4<UInt32>(repeating: k6), i11 = SIMD4<UInt32>(repeating: k7)
    let i14 = SIMD4<UInt32>(repeating: n14), i15 = SIMD4<UInt32>(repeating: n15)
    var x0 = i0, x1 = i1, x2 = i2, x3 = i3, x4 = i4, x5 = i5, x6 = i6, x7 = i7
    var x8 = i8, x9 = i9, x10 = i10, x11 = i11, x12 = c12, x13 = c13, x14 = i14, x15 = i15
    for _ in 0..<10 {
      Self.quarterRound4(&x0, &x4, &x8, &x12)
      Self.quarterRound4(&x1, &x5, &x9, &x13)
      Self.quarterRound4(&x2, &x6, &x10, &x14)
      Self.quarterRound4(&x3, &x7, &x11, &x15)
      Self.quarterRound4(&x0, &x5, &x10, &x15)
      Self.quarterRound4(&x1, &x6, &x11, &x12)
      Self.quarterRound4(&x2, &x7, &x8, &x13)
      Self.quarterRound4(&x3, &x4, &x9, &x14)
    }
    let words = (x0 &+ i0, x1 &+ i1, x2 &+ i2, x3 &+ i3, x4 &+ i4, x5 &+ i5, x6 &+ i6, x7 &+ i7,
                 x8 &+ i8, x9 &+ i9, x10 &+ i10, x11 &+ i11, x12 &+ c12, x13 &+ c13, x14 &+ i14, x15 &+ i15)
    for lane in 0..<4 {
      let block = pointer + lane &* Self.blockSize
      Self.mix(block, 0, words.0[lane]); Self.mix(block, 1, words.1[lane])
      Self.mix(block, 2, words.2[lane]); Self.mix(block, 3, words.3[lane])
      Self.mix(block, 4, words.4[lane]); Self.mix(block, 5, words.5[lane])
      Self.mix(block, 6, words.6[lane]); Self.mix(block, 7, words.7[lane])
      Self.mix(block, 8, words.8[lane]); Self.mix(block, 9, words.9[lane])
      Self.mix(block, 10, words.10[lane]); Self.mix(block, 11, words.11[lane])
      Self.mix(block, 12, words.12[lane]); Self.mix(block, 13, words.13[lane])
      Self.mix(block, 14, words.14[lane]); Self.mix(block, 15, words.15[lane])
    }
  }

  @inline(__always)
  private static func quarterRound4(_ a: inout SIMD4<UInt32>, _ b: inout SIMD4<UInt32>, _ c: inout SIMD4<UInt32>,
                                    _ d: inout SIMD4<UInt32>) {
    a = a &+ b; d ^= a; d = (d &<< 16) | (d &>> 16)
    c = c &+ d; b ^= c; b = (b &<< 12) | (b &>> 20)
    a = a &+ b; d ^= a; d = (d &<< 8) | (d &>> 24)
    c = c &+ d; b ^= c; b = (b &<< 7) | (b &>> 25)
  }

  /// XORs little-endian keystream word `word` into the 4 bytes at word offset `index`.
  @inline(__always)
  private static func mix(_ pointer: UnsafeMutableRawPointer, _ index: Int, _ word: UInt32) {
    let offset = index &* 4
    let value = UInt32(littleEndian: pointer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) ^ word
    pointer.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self)
  }

  @inline(__always)
  private static func quarterRound(_ a: inout UInt32, _ b: inout UInt32, _ c: inout UInt32, _ d: inout UInt32) {
    a = a &+ b; d ^= a; d = rotate(d, 16)
    c = c &+ d; b ^= c; b = rotate(b, 12)
    a = a &+ b; d ^= a; d = rotate(d, 8)
    c = c &+ d; b ^= c; b = rotate(b, 7)
  }

  @inline(__always)
  private static func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x &<< n) | (x &>> (32 &- n)) }
}
