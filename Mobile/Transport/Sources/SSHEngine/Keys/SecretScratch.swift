import Foundation

/// Helpers for handling a key file's secret bytes without leaving unwiped copies behind.
extension SecretBytes {
  /// Runs `body` on an array copy of the bytes, then wipes that copy: for the parsers that read arrays (`WireReader`,
  /// `DERReader`). The array, and any reader holding it, must not outlive `body`, or the wipe reaches only a copy.
  func withTemporaryArray<R, E: Error>(_ body: ([UInt8]) throws(E) -> R) throws(E) -> R {
    var array = withUnsafeBytes { [UInt8]($0) }
    defer { wipeBytes(&array) }
    return try body(array)
  }

  /// A copy of `range` of these bytes, in wiped memory of its own.
  func slice(_ range: Range<Int>) -> SecretBytes {
    withUnsafeBytes { SecretBytes(copying: $0[range]) }
  }

  /// The big-endian magnitude zero-padded on the left to `width` bytes; nil when it is longer than `width`.
  func leftPadded(to width: Int) -> SecretBytes? {
    guard count <= width else { return nil }
    return withUnsafeBytes { source in
      SecretBytes(count: width) { (target: UnsafeMutableRawBufferPointer) in
        UnsafeMutableRawBufferPointer(rebasing: target[(width - source.count)...]).copyMemory(from: source)
      }
    }
  }
}

/// `bytes.withUnsafeBytes` keeping `body`'s typed error (ContiguousBytes' own is `rethrows`, which erases it).
func withTypedBytes<R, E: Error>(of bytes: some ContiguousBytes,
                                 _ body: (UnsafeRawBufferPointer) throws(E) -> R) throws(E) -> R {
  let result = bytes.withUnsafeBytes { buffer -> Result<R, E> in
    do throws(E) { return .success(try body(buffer)) } catch { return .failure(error) }
  }
  return try result.get()
}

/// `bytes.withUnsafeMutableBytes` keeping `body`'s typed error, as `withTypedBytes`.
func withTypedMutableBytes<R, E: Error>(of bytes: inout [UInt8],
                                        _ body: (UnsafeMutableRawBufferPointer) throws(E) -> R) throws(E) -> R {
  let result = bytes.withUnsafeMutableBytes { buffer -> Result<R, E> in
    do throws(E) { return .success(try body(buffer)) } catch { return .failure(error) }
  }
  return try result.get()
}

extension WireReader {
  /// A non-negative `mpint` read straight into wiped memory, as `readMPInt` reads it (minimal, never negative), as its
  /// magnitude without the sign byte: a private key's d, p, q, a scalar.
  mutating func readSecretMPInt(limit: Int) throws(WireError) -> SecretBytes {
    let raw = try readSecretString(limit: limit)
    let (first, second): (UInt8?, UInt8?) = raw.withUnsafeBytes { ($0.first, $0.count > 1 ? $0[1] : nil) }
    guard let first else { return raw }
    guard first & 0x80 == 0 else { throw .negativeMPInt }
    guard first == 0 else { return raw }
    guard let second, second & 0x80 != 0 else { throw .nonMinimalMPInt }
    return raw.slice(1..<raw.count)
  }
}
