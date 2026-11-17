import CryptoKit
import SSHEngine
import XCTest

/// A deterministic `RandomSource` (SplitMix64): the same seed gives the same bytes, so a core's output is
/// reproducible. Tests only: never a source of real keys.
final class SeededRandom: RandomSource {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// Uniform in 0..<bound (bound > 0).
  func below(_ bound: Int) -> Int { Int(next() % UInt64(max(1, bound))) }

  func fill(_ buffer: UnsafeMutableRawBufferPointer) throws(SSHError) {
    for index in buffer.indices { buffer[index] = UInt8(truncatingIfNeeded: next()) }
  }
}

/// Raw wire encodings built by hand, independent of `WireWriter`, so the reader is tested against the RFC, not
/// against the writer.
enum Raw {
  static func u32(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
  }

  static func string(_ bytes: [UInt8]) -> [UInt8] { u32(UInt32(bytes.count)) + bytes }
  static func string(_ text: String) -> [UInt8] { string(Array(text.utf8)) }
}

/// The SHA-256 of `bytes` as lowercase hex (what `sha256sum` prints).
func sha256Hex(_ bytes: some DataProtocol) -> String { PrimitiveTestSupport.hex(SHA256.hash(data: bytes)) }

/// Fictional keys: fixed byte patterns, not keys anyone holds.
enum Fixture {
  static let ed25519Key = [UInt8](repeating: 0x11, count: 32)
  static let otherEd25519Key = [UInt8](repeating: 0x22, count: 32)
  static var ed25519Blob: [UInt8] { Raw.string("ssh-ed25519") + Raw.string(ed25519Key) }
  static var otherEd25519Blob: [UInt8] { Raw.string("ssh-ed25519") + Raw.string(otherEd25519Key) }

  static func ecdsaBlob(_ curve: ECDSACurve) -> [UInt8] {
    Raw.string(curve.keyType) + Raw.string(curve.rawValue) + Raw.string([0x04] + [UInt8](repeating: 0x33, count: 2 * curve.scalarBytes))
  }

  /// An odd 2048-bit modulus (top bit set), so it needs a 0x00 in its mpint.
  static let rsaModulus: [UInt8] = [0xC1] + [UInt8](repeating: 0x5A, count: 254) + [0x01]
  static var rsaBlob: [UInt8] {
    Raw.string("ssh-rsa") + Raw.string([0x01, 0x00, 0x01]) + Raw.string([0x00] + rsaModulus)
  }
}

/// Asserts that `body` throws exactly `expected`.
func XCTAssertThrows<T, E: Error & Equatable>(
  _ expected: E, file: StaticString = #filePath, line: UInt = #line, _ body: () throws(E) -> T
) {
  do {
    let value = try body()
    XCTFail("expected \(expected), got \(value)", file: file, line: line)
  } catch {
    XCTAssertEqual(error, expected, file: file, line: line)
  }
}
