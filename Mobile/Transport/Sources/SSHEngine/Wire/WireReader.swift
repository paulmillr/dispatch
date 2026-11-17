/// Reads SSH wire types (RFC 4251 §5) from a byte array, front to back. It never reads past its end: every read
/// checks the remaining bytes first, and every variable-length read takes a limit (from `Limits`) checked before
/// anything is allocated, so a hostile length costs nothing. A failed read throws `WireError` and leaves the position
/// where it was; a reader that threw should be dropped (its message is malformed).
///
/// Strictness, beyond RFC 4251: booleans are 0 or 1; mpints are minimal and never negative; names are printable
/// US-ASCII of 1 to `Limits.nameLength` bytes; text the engine compares or acts on is valid UTF-8 (`readText`), while
/// text a server sends only to be shown is decoded leniently (`readDisplayText`). A whole message is read with
/// `decode`, which also refuses trailing bytes.
public struct WireReader {
  private let bytes: [UInt8]
  /// The index of the next byte to read.
  public private(set) var offset: Int

  public init(_ bytes: [UInt8]) {
    self.bytes = bytes
    offset = 0
  }

  /// Bytes not yet read.
  public var remaining: Int { bytes.count - offset }
  public var isAtEnd: Bool { offset >= bytes.count }

  /// Decodes one whole message or blob: `body` reads its fields, then the input must be at its end.
  public static func decode<T>(_ bytes: [UInt8], _ body: (inout WireReader) throws(WireError) -> T) throws(WireError) -> T {
    var reader = WireReader(bytes)
    let value = try body(&reader)
    try reader.expectEnd()
    return value
  }

  public func expectEnd() throws(WireError) {
    guard isAtEnd else { throw .trailingBytes }
  }

  // MARK: Fixed-size values

  public mutating func readByte() throws(WireError) -> UInt8 {
    guard remaining >= 1 else { throw .truncated }
    defer { offset += 1 }
    return bytes[offset]
  }

  /// A message number, the first byte of every payload.
  public mutating func readMessageNumber() throws(WireError) -> MessageNumber {
    MessageNumber(try readByte())
  }

  public mutating func readBoolean() throws(WireError) -> Bool {
    guard remaining >= 1 else { throw .truncated }
    switch bytes[offset] {
    case 0: offset += 1; return false
    case 1: offset += 1; return true
    default: throw .invalidBoolean
    }
  }

  public mutating func readUInt32() throws(WireError) -> UInt32 {
    guard remaining >= 4 else { throw .truncated }
    var value: UInt32 = 0
    for index in offset..<offset + 4 { value = value << 8 | UInt32(bytes[index]) }
    offset += 4
    return value
  }

  public mutating func readUInt64() throws(WireError) -> UInt64 {
    guard remaining >= 8 else { throw .truncated }
    var value: UInt64 = 0
    for index in offset..<offset + 8 { value = value << 8 | UInt64(bytes[index]) }
    offset += 8
    return value
  }

  /// Exactly `count` raw bytes (a KEXINIT cookie). `count` is the caller's constant, not a value from the input.
  public mutating func readBytes(count: Int) throws(WireError) -> [UInt8] {
    guard count >= 0, remaining >= count else { throw .truncated }
    defer { offset += count }
    return Array(bytes[offset..<offset + count])
  }

  /// Everything not yet read (the tail of a message whose last field is unframed).
  public mutating func readRemaining() -> [UInt8] {
    defer { offset = bytes.count }
    return Array(bytes[offset...])
  }

  // MARK: Strings

  /// A `string`: uint32 length, then that many bytes. The length must be at most `limit` and fit in the input.
  public mutating func readString(limit: Int) throws(WireError) -> [UInt8] {
    let start = offset
    let length = try readLength(limit: limit)
    guard remaining >= length else {
      offset = start
      throw .truncated
    }
    defer { offset += length }
    return Array(bytes[offset..<offset + length])
  }

  /// A `string` read straight into wiped memory (a private key's fields, a decrypted secret): no array copy of the
  /// value is made. The reader's own input is the caller's to wipe.
  public mutating func readSecretString(limit: Int) throws(WireError) -> SecretBytes {
    let start = offset
    let length = try readLength(limit: limit)
    guard remaining >= length else {
      offset = start
      throw .truncated
    }
    defer { offset += length }
    return SecretBytes(copying: bytes[offset..<offset + length])
  }

  /// A `string` holding UTF-8 text (RFC 4251 §5: ISO-10646 UTF-8) that the engine compares, acts on or echoes back.
  /// Invalid UTF-8 is an error, never repaired. Text that is only shown uses `readDisplayText` instead.
  public mutating func readText(limit: Int) throws(WireError) -> String {
    let start = offset
    let raw = try readString(limit: limit)
    guard let text = String(validating: raw, as: UTF8.self) else {
      offset = start
      throw .invalidUTF8
    }
    return text
  }

  /// A `string` of text a server sends only for display, decoded leniently: invalid UTF-8 sequences (a Latin-1
  /// banner or PAM prompt) become U+FFFD instead of ending the connection. Still bounded by `limit` like any string.
  /// Never compared or acted on; shown through `DisplayText.sanitize` (single-line texts) or the app's own display of
  /// prompts. The fields read this way:
  ///
  /// - USERAUTH_BANNER's message (RFC 4252 §5.4)
  /// - keyboard-interactive INFO_REQUEST's name, instruction and prompts (RFC 4256 §3.2)
  /// - PASSWD_CHANGEREQ's prompt (RFC 4252 §8)
  /// - DISCONNECT's and DEBUG's descriptions (RFC 4253 §11.1, §11.3)
  /// - CHANNEL_OPEN_FAILURE's description (RFC 4254 §5.1)
  /// - exit-signal's error message (RFC 4254 §6.10)
  /// - every language tag, which is read (bounded by `Limits.languageTagBytes`) and ignored
  public mutating func readDisplayText(limit: Int) throws(WireError) -> String {
    String(decoding: try readString(limit: limit), as: UTF8.self)
  }

  /// A `string` holding one name: an algorithm, method, service, request, channel type or extension name.
  public mutating func readName() throws(WireError) -> String {
    let start = offset
    let raw = try readString(limit: Limits.nameLength)
    guard let name = Self.name(raw[...]) else {
      offset = start
      throw .invalidName
    }
    return name
  }

  /// A `name-list`: a string of comma-separated names, empty for none. At most `byteLimit` bytes and `countLimit`
  /// names, each a valid name (no empty elements).
  public mutating func readNameList(
    byteLimit: Int = Limits.nameListBytes, countLimit: Int = Limits.nameListCount
  ) throws(WireError) -> [String] {
    let start = offset
    let raw = try readString(limit: byteLimit)
    if raw.isEmpty { return [] }
    var names: [String] = []
    for element in raw.split(separator: UInt8(ascii: ","), omittingEmptySubsequences: false) {
      guard names.count < countLimit else {
        offset = start
        throw .tooMany(limit: countLimit)
      }
      guard let name = Self.name(element) else {
        offset = start
        throw .invalidName
      }
      names.append(name)
    }
    return names
  }

  // MARK: Numbers

  /// A non-negative `mpint` (RFC 4251 §5) as its big-endian magnitude without leading zeros (empty for zero), at
  /// most `limit` bytes on the wire. Non-minimal encodings and negative values are errors.
  public mutating func readMPInt(limit: Int) throws(WireError) -> [UInt8] {
    let start = offset
    let raw = try readString(limit: limit)
    guard let first = raw.first else { return [] }
    if first & 0x80 != 0 {
      offset = start
      throw .negativeMPInt
    }
    guard first == 0 else { return raw }
    // A leading zero is allowed only to keep the next byte's high bit from reading as a sign.
    guard raw.count >= 2, raw[1] & 0x80 != 0 else {
      offset = start
      throw .nonMinimalMPInt
    }
    return Array(raw[1...])
  }

  /// A uint32 element count, at most `limit` and at most what the remaining bytes can hold when each element takes
  /// at least `elementBytes` (a string takes 4): a count can never make the caller reserve more than the input.
  public mutating func readCount(limit: Int, elementBytes: Int) throws(WireError) -> Int {
    let start = offset
    let value = try readUInt32()
    guard let count = Int(exactly: value), count <= limit else {
      offset = start
      throw .tooMany(limit: limit)
    }
    guard elementBytes <= 0 || count <= remaining / elementBytes else {
      offset = start
      throw .tooMany(limit: limit)
    }
    return count
  }

  // MARK: Helpers

  /// A uint32 length, at most `limit`. Does not check the remaining bytes.
  private mutating func readLength(limit: Int) throws(WireError) -> Int {
    let start = offset
    let value = try readUInt32()
    guard let length = Int(exactly: value), length <= max(0, limit) else {
      offset = start
      throw .tooLong(limit: limit)
    }
    return length
  }

  /// `bytes` as a name (RFC 4251 §6): 1 to `Limits.nameLength` bytes of printable US-ASCII (0x21-0x7E) other than
  /// a comma. Nil otherwise.
  static func name(_ bytes: ArraySlice<UInt8>) -> String? {
    guard !bytes.isEmpty, bytes.count <= Limits.nameLength else { return nil }
    for byte in bytes where byte < 0x21 || byte > 0x7E || byte == UInt8(ascii: ",") { return nil }
    return String(decoding: bytes, as: UTF8.self)
  }
}
