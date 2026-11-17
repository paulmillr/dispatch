/// Writes SSH wire types (RFC 4251 §5). Writes never trap: a value that cannot be encoded (a string longer than
/// 2^32 - 1, an invalid name) marks the writer failed and `finish` throws, so a caller checks once at the end.
/// The bytes are only reachable through `finish` (or `finishSecret`).
public struct WireWriter {
  private var buffer: [UInt8]
  private var failed = false

  /// `capacity`: bytes reserved up front. A writer that will hold a secret should reserve all it needs, so the
  /// array never grows (a grown array leaves its old storage behind unwiped).
  public init(capacity: Int = 64) {
    buffer = []
    buffer.reserveCapacity(max(0, capacity))
  }

  /// A writer whose payload starts with `message`.
  public init(_ message: MessageNumber, capacity: Int = 64) {
    self.init(capacity: capacity)
    write(message)
  }

  /// The bytes written, or `WireError.unencodable` if any write was invalid.
  public func finish() throws(WireError) -> [UInt8] {
    guard !failed else { throw .unencodable }
    return buffer
  }

  /// The bytes written, moved into wiped memory; the writer's own buffer is zeroed and emptied. For payloads that
  /// hold a secret (a password request). Throws as `finish`, after wiping.
  public mutating func finishSecret() throws(WireError) -> SecretBytes {
    defer {
      buffer.withUnsafeMutableBytes { SecretBytes.wipe($0) }
      buffer.removeAll()
    }
    guard !failed else { throw .unencodable }
    return SecretBytes(copying: buffer)
  }

  public var count: Int { buffer.count }

  // MARK: Values

  public mutating func write(_ message: MessageNumber) {
    buffer.append(message.rawValue)
  }

  public mutating func writeByte(_ value: UInt8) {
    buffer.append(value)
  }

  public mutating func writeBoolean(_ value: Bool) {
    buffer.append(value ? 1 : 0)
  }

  public mutating func writeUInt32(_ value: UInt32) {
    for shift in stride(from: 24, through: 0, by: -8) { buffer.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
  }

  /// Raw bytes with no length (a cookie, a nested encoding already framed).
  public mutating func writeBytes(_ bytes: some Collection<UInt8>) {
    buffer.append(contentsOf: bytes)
  }

  /// A `string`: uint32 length, then the bytes.
  public mutating func writeString(_ bytes: some Collection<UInt8>) {
    guard let length = UInt32(exactly: bytes.count) else {
      failed = true
      return
    }
    writeUInt32(length)
    buffer.append(contentsOf: bytes)
  }

  /// A `string` holding `text` as UTF-8.
  public mutating func writeString(_ text: String) {
    writeString(Array(text.utf8))
  }

  /// A `string` holding a secret (a password): copied from wiped memory, so the only other copy is this writer's,
  /// which `finishSecret` wipes.
  public mutating func writeString(_ secret: SecretBytes) {
    secret.withUnsafeBytes { writeString($0) }
  }

  /// A `string` holding one name; an invalid name (`WireReader`'s rules) fails the writer.
  public mutating func writeName(_ name: String) {
    let raw = Array(name.utf8)
    guard WireReader.name(raw[...]) != nil else {
      failed = true
      return
    }
    writeString(raw)
  }

  /// A `name-list`; an invalid name fails the writer.
  public mutating func writeNameList(_ names: [String]) {
    var joined: [UInt8] = []
    for (index, name) in names.enumerated() {
      let raw = Array(name.utf8)
      guard WireReader.name(raw[...]) != nil else {
        failed = true
        return
      }
      if index > 0 { joined.append(UInt8(ascii: ",")) }
      joined.append(contentsOf: raw)
    }
    writeString(joined)
  }

  /// A non-negative `mpint` from an unsigned big-endian magnitude (leading zeros allowed in the input): minimal, with
  /// a 0x00 only where the high bit would read as a sign; zero is the empty string.
  public mutating func writeMPInt(magnitude: some Collection<UInt8>) {
    let trimmed = magnitude.drop { $0 == 0 }
    let pad = (trimmed.first ?? 0) & 0x80 != 0
    guard let length = UInt32(exactly: trimmed.count + (pad ? 1 : 0)) else {
      failed = true
      return
    }
    writeUInt32(length)
    if pad { buffer.append(0) }
    buffer.append(contentsOf: trimmed)
  }

  /// A secret mpint (a shared secret's encoding for the exchange hash), as `writeMPInt(magnitude:)`.
  public mutating func writeMPInt(_ secret: SecretBytes) {
    secret.withUnsafeBytes { writeMPInt(magnitude: $0) }
  }
}
