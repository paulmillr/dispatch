import Foundation

/// HAND-WRITTEN MULTI-PRECISION ARITHMETIC ON SECRETS. The only arithmetic the engine does itself on key material,
/// and the smallest that works: x mod m by binary long division.
///
/// Why it exists: an `openssh-key-v1` RSA key carries n, e, d, iqmp, p and q, but Security.framework imports an RSA
/// private key only as PKCS#1, which also needs d mod (p - 1) and d mod (q - 1). Measured on macOS 27: without them,
/// or with them zero, or with d in their place, `SecKeyCreateWithData` refuses the key or every signature fails its
/// fault check (`RSAKeys`). Apple exposes no big-number arithmetic, so the two remainders are computed here.
///
/// Where it runs: only on a key file the user imports, on the device; never on network data. A wrong result cannot
/// produce a bad signature unnoticed: Security's CRT signing checks its result (a wrong remainder fails with
/// ccerr -28), and `RSAKeys.checkPair` signs and verifies once before a key is accepted. Tested against the values
/// `ssh-keygen -p -m PEM` (OpenSSL's BIGNUM) writes for the same keys, and against hand-checked small cases
/// (`RSAArithmeticTests`).
///
/// Timing: the loop's trip counts depend on the operands' byte lengths only (public: the key size), and the
/// conditional subtraction is a mask, not a branch. Swift promises nothing about the machine code; this is a property
/// of the source. Memory: the working limbs are wiped (`memset_s`) before they are freed.
enum RSAArithmetic {
  /// `x mod m` for big-endian magnitudes `x` and `m` (m non-zero), as a big-endian magnitude `m.count` bytes wide;
  /// nil when m is zero.
  ///
  /// r starts at 0; for each bit of x from the top, r = 2r + bit, then r - m replaces r unless that borrows. r < m
  /// holds throughout (2r + 1 < 2m), so one subtraction per bit suffices, and r has one limb more than m for the doubling.
  static func remainder(_ x: UnsafeRawBufferPointer, modulo m: UnsafeRawBufferPointer) -> SecretBytes? {
    guard m.contains(where: { $0 != 0 }) else { return nil }
    let limbs = (m.count + 7) / 8 + 1
    let buffer = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: 3 * limbs)
    buffer.initialize(repeating: 0)
    defer {
      SecretBytes.wipe(UnsafeMutableRawBufferPointer(buffer))
      buffer.deallocate()
    }
    let r = UnsafeMutableBufferPointer(rebasing: buffer[0..<limbs])
    let modulus = UnsafeMutableBufferPointer(rebasing: buffer[limbs..<(2 * limbs)])
    let difference = UnsafeMutableBufferPointer(rebasing: buffer[(2 * limbs)...])
    // Little-endian limbs of m: byte i from the end is limb i / 8, shifted by 8 * (i % 8).
    for index in 0..<m.count {
      modulus[index / 8] |= UInt64(m[m.count - 1 - index]) << UInt64(8 * (index % 8))
    }

    for byte in x {
      var bit = 8
      while bit > 0 {
        bit -= 1
        // r = 2r + the next bit of x.
        var carry = UInt64(byte >> UInt8(bit)) & 1
        for index in 0..<limbs {
          let limb = r[index]
          r[index] = limb << 1 | carry
          carry = limb >> 63
        }
        // difference = r - m, and whether it borrowed (r < m).
        var borrow: UInt64 = 0
        for index in 0..<limbs {
          let (first, overflow1) = r[index].subtractingReportingOverflow(modulus[index])
          let (second, overflow2) = first.subtractingReportingOverflow(borrow)
          difference[index] = second
          borrow = UInt64(overflow1 ? 1 : 0) | UInt64(overflow2 ? 1 : 0)
        }
        // keep = all ones when r < m (borrowed): r stays; otherwise r takes the difference.
        let keep = 0 &- borrow
        for index in 0..<limbs { r[index] = (r[index] & keep) | (difference[index] & ~keep) }
      }
    }

    return SecretBytes(count: m.count) { (output: UnsafeMutableRawBufferPointer) in
      for index in 0..<m.count {
        output[m.count - 1 - index] = UInt8(truncatingIfNeeded: r[index / 8] >> UInt64(8 * (index % 8)))
      }
    }
  }

  /// d mod (p - 1) for an odd prime p > 2 (OpenSSH has already made p odd: p - 1 is p with its low bit cleared). Nil
  /// when p is even or below 3.
  static func exponent(_ d: SecretBytes, prime p: SecretBytes) -> SecretBytes? {
    let pMinusOne: SecretBytes? = p.withUnsafeBytes { prime in
      guard let low = prime.last, low & 1 == 1, prime.dropLast().contains(where: { $0 != 0 }) || low >= 3 else {
        return nil
      }
      return SecretBytes(count: prime.count) { (target: UnsafeMutableRawBufferPointer) in
        target.copyMemory(from: prime)
        target[prime.count - 1] = low & 0xFE
      }
    }
    guard let pMinusOne else { return nil }
    return d.withUnsafeBytes { x in pMinusOne.withUnsafeBytes { remainder(x, modulo: $0) } }
  }
}
