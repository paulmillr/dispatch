import Foundation
import XCTest
@testable import SSHEngine

/// The hand-written remainder (`RSAArithmetic`) against UInt128 arithmetic for every operand width up to 16 bytes
/// (Horner's rule in UInt128 for long dividends), hand-checked cases and its refusals. `KeygenOracleTests` checks it
/// against OpenSSL's CRT values for real 2048 to 4096-bit keys.
final class RSAArithmeticTests: XCTestCase {
  private func remainder(_ x: [UInt8], _ m: [UInt8]) -> [UInt8]? {
    x.withUnsafeBytes { x in m.withUnsafeBytes { RSAArithmetic.remainder(x, modulo: $0)?.withUnsafeBytes { Array($0) } } }
  }

  private func bytes(_ value: UInt128, width: Int) -> [UInt8] {
    (0..<width).map { UInt8(truncatingIfNeeded: value >> UInt128(8 * (width - 1 - $0))) }
  }

  func testHandCheckedCases() {
    XCTAssertEqual(remainder([], [7]), [0])
    XCTAssertEqual(remainder([0, 0, 0], [7]), [0])
    XCTAssertEqual(remainder([6], [7]), [6])
    XCTAssertEqual(remainder([7], [7]), [0])
    XCTAssertEqual(remainder([1, 0], [7]), [4], "256 mod 7")
    XCTAssertEqual(remainder([0xFF], [1]), [0])
    // 2^64 mod 3 = 1; (2^256 - 1) mod (2^32 - 1) = 0, since 32 divides 256.
    XCTAssertEqual(remainder([1] + [UInt8](repeating: 0, count: 8), [3]), [1])
    XCTAssertEqual(remainder([UInt8](repeating: 0xFF, count: 32), [0xFF, 0xFF, 0xFF, 0xFF]), [0, 0, 0, 0])
    // The result is as wide as m, leading zeros kept.
    XCTAssertEqual(remainder([5], [0, 0, 9]), [0, 0, 5])
    XCTAssertNil(remainder([5], []))
    XCTAssertNil(remainder([5], [0, 0]))
  }

  /// Random operands of 0 to 16 bytes (x) and 1 to 16 bytes (m), across the 8-byte limb boundary, against UInt128.
  func testAgainstUInt128() {
    let random = SeededRandom(seed: 0xC127)
    for _ in 0..<5000 {
      let xWidth = random.below(17), mWidth = 1 + random.below(16)
      var x: UInt128 = UInt128(random.next()) << 64 | UInt128(random.next())
      var m: UInt128 = UInt128(random.next()) << 64 | UInt128(random.next())
      x = xWidth == 16 ? x : x & ((1 << UInt128(8 * xWidth)) - 1)
      m = mWidth == 16 ? m : m & ((1 << UInt128(8 * mWidth)) - 1)
      if random.below(4) == 0 { m >>= UInt128(random.below(8 * mWidth)) }
      guard m != 0 else { continue }
      XCTAssertEqual(remainder(bytes(x, width: xWidth), bytes(m, width: mWidth)), bytes(x % m, width: mWidth), "\(x) mod \(m)")
    }
  }

  /// Long dividends (up to 2 KiB, a 16384-bit d) by moduli of up to 15 bytes: Horner's rule in UInt128 is the reference.
  func testLongDividends() {
    let random = SeededRandom(seed: 0x10A6)
    for round in 0..<300 {
      let x = (0..<(1 + random.below(round < 10 ? 2048 : 300))).map { _ in UInt8(random.below(256)) }
      let mWidth = 1 + random.below(15)
      var m = (0..<mWidth).map { _ in UInt8(random.below(256)) }
      m[mWidth - 1] |= 1
      let modulus = m.reduce(UInt128(0)) { $0 << 8 | UInt128($1) }
      let expected = x.reduce(UInt128(0)) { ($0 << 8 | UInt128($1)) % modulus }
      XCTAssertEqual(remainder(x, m), bytes(expected, width: mWidth))
    }
  }

  func testExponent() {
    func exponent(_ d: [UInt8], _ p: [UInt8]) -> [UInt8]? {
      RSAArithmetic.exponent(SecretBytes(copying: d), prime: SecretBytes(copying: p))?.withUnsafeBytes { Array($0) }
    }
    // d mod (p - 1): 1000 mod 12 = 4 (p = 13); 0x0101 mod 2 = 1 (p = 3).
    XCTAssertEqual(exponent([0x03, 0xE8], [13]), [4])
    XCTAssertEqual(exponent([0x01, 0x01], [3]), [1])
    XCTAssertEqual(exponent([0x01, 0x00], [0x01, 0x05]), [0x01, 0x00])
    XCTAssertNil(exponent([5], [12]), "even p")
    XCTAssertNil(exponent([5], [1]), "p = 1")
    XCTAssertNil(exponent([5], [0, 1]), "p = 1 with a leading zero")
    XCTAssertNil(exponent([5], []))
  }

  /// A 16384-bit d by an 8192-bit modulus: what the largest key allowed costs (printed; debug build).
  func testLargestKeyCost() {
    let random = SeededRandom(seed: 0x16384)
    let d = (0..<2048).map { _ in UInt8(random.below(256)) }
    var p = (0..<1024).map { _ in UInt8(random.below(256)) }
    p[0] |= 0x80
    p[1023] |= 1
    let start = Date()
    XCTAssertNotNil(RSAArithmetic.exponent(SecretBytes(copying: d), prime: SecretBytes(copying: p)))
    print("RSAArithmeticTests: d mod (p - 1) for a 16384-bit key: " + String(format: "%.3f s", Date().timeIntervalSince(start)))
  }
}
