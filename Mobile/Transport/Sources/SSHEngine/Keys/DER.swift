import Foundation

/// The few DER (X.690) encodings a PEM key file needs: single-byte tags, definite minimal lengths of up to three
/// bytes (a key file is at most `Limits.keyFileBytes`), non-negative minimal INTEGERs. Hand-written because no Apple
/// API reads PKCS#8's envelope or SEC1 with explicit curve parameters (`PEMKeyFile`). Reads return ranges into the
/// caller's array, never copies, and never go past the enclosing element: every length is checked against what is
/// left before it is used. Any failure is `KeyFileProblem.damaged`.
struct DERReader {
  static let sequence: UInt8 = 0x30
  static let integer: UInt8 = 0x02
  static let bitString: UInt8 = 0x03
  static let octetString: UInt8 = 0x04
  static let null: UInt8 = 0x05
  static let objectIdentifier: UInt8 = 0x06
  /// `[0]` and `[1]`, constructed (EXPLICIT, or IMPLICIT over a constructed type).
  static let context0: UInt8 = 0xA0
  static let context1: UInt8 = 0xA1
  /// `[1] IMPLICIT BIT STRING` (PKCS#8 v2's public key).
  static let context1Primitive: UInt8 = 0x81

  private let bytes: [UInt8]
  private(set) var offset: Int
  private let end: Int

  /// Reads `range` of `bytes` (all of it by default).
  init(_ bytes: [UInt8], range: Range<Int>? = nil) {
    self.bytes = bytes
    let range = range ?? bytes.indices
    offset = range.lowerBound
    end = range.upperBound
  }

  /// The bytes of a range this reader returned.
  subscript(range: Range<Int>) -> ArraySlice<UInt8> { bytes[range] }

  var isAtEnd: Bool { offset >= end }
  var nextTag: UInt8? { offset < end ? bytes[offset] : nil }

  func expectEnd() throws(SSHError) {
    guard isAtEnd else { throw KeyFileProblem.damaged.error }
  }

  /// A reader for an element's contents.
  func reader(for contents: Range<Int>) -> DERReader { DERReader(bytes, range: contents) }

  /// One element with `tag`: its whole encoding and its contents.
  mutating func readElement(_ tag: UInt8) throws(SSHError) -> (element: Range<Int>, contents: Range<Int>) {
    let start = offset
    guard end - offset >= 2, bytes[offset] == tag else { throw KeyFileProblem.damaged.error }
    var index = offset + 1
    let first = bytes[index]
    index += 1
    var length: Int
    switch first {
    case 0..<0x80:
      length = Int(first)
    case 0x81...0x83:
      let count = Int(first & 0x7F)
      guard end - index >= count, bytes[index] != 0 else { throw KeyFileProblem.damaged.error }
      length = 0
      for _ in 0..<count {
        length = length << 8 | Int(bytes[index])
        index += 1
      }
      // Minimal: the long form only where the short one cannot hold the length, in as few bytes as it takes.
      guard length >= 0x80 else { throw KeyFileProblem.damaged.error }
    default:
      // 0x80 is BER's indefinite length; four or more length bytes cannot occur within Limits.keyFileBytes.
      throw KeyFileProblem.damaged.error
    }
    guard end - index >= length else { throw KeyFileProblem.damaged.error }
    offset = index + length
    return (start..<offset, index..<offset)
  }

  /// An element's contents.
  mutating func read(_ tag: UInt8) throws(SSHError) -> Range<Int> { try readElement(tag).contents }

  /// The element's contents when the next tag is `tag`; nil (nothing read) otherwise.
  mutating func readOptional(_ tag: UInt8) throws(SSHError) -> Range<Int>? {
    nextTag == tag ? try read(tag) : nil
  }

  /// A non-negative INTEGER as the range of its magnitude without the sign byte (empty for zero). Negative and
  /// non-minimal encodings are refused.
  mutating func readUnsignedInteger() throws(SSHError) -> Range<Int> {
    let contents = try read(Self.integer)
    guard let first = contents.first.map({ bytes[$0] }), first & 0x80 == 0 else { throw KeyFileProblem.damaged.error }
    guard first == 0 else { return contents }
    if contents.count == 1 { return contents.upperBound..<contents.upperBound }
    guard bytes[contents.lowerBound + 1] & 0x80 != 0 else { throw KeyFileProblem.damaged.error }
    return (contents.lowerBound + 1)..<contents.upperBound
  }

  /// A small non-negative INTEGER (a version).
  mutating func readSmallInteger() throws(SSHError) -> Int {
    let magnitude = try readUnsignedInteger()
    guard magnitude.count <= 2 else { throw KeyFileProblem.damaged.error }
    return magnitude.reduce(0) { $0 << 8 | Int(bytes[$1]) }
  }

  /// A BIT STRING with no unused bits, as the range of its bytes.
  mutating func readOctetAlignedBitString(_ tag: UInt8 = DERReader.bitString) throws(SSHError) -> Range<Int> {
    let contents = try read(tag)
    guard let first = contents.first, bytes[first] == 0 else { throw KeyFileProblem.damaged.error }
    return (first + 1)..<contents.upperBound
  }
}

/// DER encodings the engine writes: RSA's PKCS#1 keys for Security.framework.
enum DERWriter {
  /// The bytes of a length field.
  static func length(_ count: Int) -> [UInt8] {
    if count < 0x80 { return [UInt8(count)] }
    var bytes: [UInt8] = []
    var value = count
    while value > 0 {
      bytes.insert(UInt8(value & 0xFF), at: 0)
      value >>= 8
    }
    return [0x80 | UInt8(bytes.count)] + bytes
  }

  /// SEQUENCE { INTEGER ... } of big-endian magnitudes, written straight into wiped memory (the values may be secret).
  static func sequenceOfIntegers(_ values: [any ContiguousBytes]) -> SecretBytes {
    let sizes = values.map { $0.withUnsafeBytes { integerContentsSize($0) } }
    let contents = sizes.reduce(0) { $0 + 1 + length($1).count + $1 }
    let header = [DERReader.sequence] + length(contents)
    return SecretBytes(count: header.count + contents) { (output: UnsafeMutableRawBufferPointer) in
      var at = 0
      func put(_ bytes: some Collection<UInt8>) {
        for byte in bytes {
          output[at] = byte
          at += 1
        }
      }
      put(header)
      for (value, size) in zip(values, sizes) {
        value.withUnsafeBytes { magnitude in
          let trimmed = magnitude.drop { $0 == 0 }
          put([DERReader.integer] + length(size))
          if size > trimmed.count { put([0]) }
          put(trimmed)
        }
      }
    }
  }

  /// The size of an INTEGER's contents for the big-endian magnitude `bytes`: leading zeros dropped, and a zero byte
  /// first for the value 0 or where the first byte's high bit would read as a sign.
  private static func integerContentsSize(_ bytes: UnsafeRawBufferPointer) -> Int {
    let trimmed = bytes.drop { $0 == 0 }
    guard let first = trimmed.first else { return 1 }
    return trimmed.count + (first & 0x80 != 0 ? 1 : 0)
  }
}
