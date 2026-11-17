/// Why bytes did not decode as the SSH wire types asked for (RFC 4251 §5). Thrown (typed) by `WireReader`, the
/// blob codecs and `WireWriter.finish`. The layer that decoded a message wraps it with the message number
/// (`ProtocolViolation.malformed`); a key file wraps it as an invalid key. Cases carry no input bytes, only sizes and
/// validated names, so they are safe to log.
public enum WireError: Error, Sendable, Equatable {
  /// A value runs past the end of the input.
  case truncated
  /// A length is above the limit the caller named (checked before reading or allocating).
  case tooLong(limit: Int)
  /// A count is above the limit the caller named, or more than the remaining bytes could hold.
  case tooMany(limit: Int)
  /// A boolean byte other than 0 or 1 (RFC 4251 §5 says MUST NOT; the engine refuses it rather than guess).
  case invalidBoolean
  /// A name or name-list element that is empty, longer than `Limits.nameLength`, or has a byte outside printable
  /// US-ASCII (or a comma, inside a name-list).
  case invalidName
  /// Text that is not valid UTF-8.
  case invalidUTF8
  /// An mpint with a leading byte RFC 4251 §5 forbids (a 0x00 not needed for the sign, or a zero as `00`).
  case nonMinimalMPInt
  /// A negative mpint: no value the engine reads may be negative.
  case negativeMPInt
  /// Bytes left after the last field of a message or blob.
  case trailingBytes
  /// A field holds a value its context forbids (a key type that does not match, a point not in uncompressed form,
  /// a key or signature of the wrong size).
  case invalidValue
  /// A key or signature type the engine does not support. Certificates (`*-cert-v01@openssh.com`) are reported here.
  case unsupportedType(String)
  /// The writer was given a value it cannot encode (a string longer than 2^32 - 1, an invalid name).
  case unencodable
}
