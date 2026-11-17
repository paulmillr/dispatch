import CryptoKit
import Foundation

/// One running hash of a negotiated `HashAlgorithm` (the exchange hash, the key derivation). Secret input (K) goes in
/// straight from its `SecretBytes`; CryptoKit's own state and the digest values it returns cannot be wiped from Swift.
struct SSHHasher {
  private enum State {
    case sha256(SHA256)
    case sha384(SHA384)
    case sha512(SHA512)
  }

  private var state: State

  init(_ algorithm: HashAlgorithm) {
    switch algorithm {
    case .sha256: state = .sha256(SHA256())
    case .sha384: state = .sha384(SHA384())
    case .sha512: state = .sha512(SHA512())
    }
  }

  mutating func update(_ bytes: UnsafeRawBufferPointer) {
    switch state {
    case .sha256(var hasher): hasher.update(bufferPointer: bytes); state = .sha256(hasher)
    case .sha384(var hasher): hasher.update(bufferPointer: bytes); state = .sha384(hasher)
    case .sha512(var hasher): hasher.update(bufferPointer: bytes); state = .sha512(hasher)
    }
  }

  mutating func update(_ bytes: [UInt8]) {
    bytes.withUnsafeBytes { update($0) }
  }

  mutating func update(_ secret: SecretBytes) {
    secret.withUnsafeBytes { update($0) }
  }

  /// The digest written to `output` (exactly `HashAlgorithm.digestBytes` bytes long).
  func finalize(into output: UnsafeMutableRawBufferPointer) {
    func copy(_ digest: some Digest) {
      digest.withUnsafeBytes { source in
        guard let base = output.baseAddress, let from = source.baseAddress else { return }
        base.copyMemory(from: from, byteCount: min(source.count, output.count))
      }
    }
    switch state {
    case .sha256(let hasher): copy(hasher.finalize())
    case .sha384(let hasher): copy(hasher.finalize())
    case .sha512(let hasher): copy(hasher.finalize())
    }
  }

  func finalize() -> [UInt8] {
    let count: Int
    switch state {
    case .sha256: count = HashAlgorithm.sha256.digestBytes
    case .sha384: count = HashAlgorithm.sha384.digestBytes
    case .sha512: count = HashAlgorithm.sha512.digestBytes
    }
    var digest = [UInt8](repeating: 0, count: count)
    digest.withUnsafeMutableBytes { finalize(into: $0) }
    return digest
  }
}

/// Comparisons and tests on secret bytes whose time depends on the lengths only.
enum ConstantTime {
  /// Equal lengths and equal bytes; every byte is compared.
  static func equal(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer) -> Bool {
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for index in 0..<a.count { difference |= a[index] ^ b[index] }
    return (UInt32(difference) &- 1) &>> 8 & 1 == 1
  }

  static func equal(_ a: some ContiguousBytes, _ b: some ContiguousBytes) -> Bool {
    a.withUnsafeBytes { a in b.withUnsafeBytes { b in equal(a, b) } }
  }

  /// Every byte zero (X25519's degenerate output).
  static func isZero(_ bytes: UnsafeRawBufferPointer) -> Bool {
    var accumulated: UInt8 = 0
    for byte in bytes { accumulated |= byte }
    return (UInt32(accumulated) &- 1) &>> 8 & 1 == 1
  }
}

extension SecretBytes {
  /// The SSH encoding of a shared secret given as a big-endian magnitude (`mpint`, RFC 4251 §5: leading zero bytes
  /// dropped, a 0x00 added where the high bit would read as a sign), length prefix included, in wiped memory. The
  /// number of leading zero bytes shows in the length, as in every SSH implementation.
  static func mpint(magnitude: UnsafeRawBufferPointer) -> SecretBytes {
    var skip = 0
    while skip < magnitude.count && magnitude[skip] == 0 { skip += 1 }
    let significant = magnitude.count - skip
    let pad = significant > 0 && magnitude[skip] & 0x80 != 0 ? 1 : 0
    let length = significant + pad
    return SecretBytes(count: 4 + length) { (buffer: UnsafeMutableRawBufferPointer) in
      buffer.storeBytes(of: UInt32(truncatingIfNeeded: length).bigEndian, toByteOffset: 0, as: UInt32.self)
      for index in 0..<significant { buffer[4 + pad + index] = magnitude[skip + index] }
    }
  }

  /// The SSH `string` encoding of `bytes` (length prefix, then the bytes), in wiped memory.
  static func string(_ bytes: UnsafeRawBufferPointer) -> SecretBytes {
    SecretBytes(count: 4 + bytes.count) { (buffer: UnsafeMutableRawBufferPointer) in
      buffer.storeBytes(of: UInt32(truncatingIfNeeded: bytes.count).bigEndian, toByteOffset: 0, as: UInt32.self)
      for index in 0..<bytes.count { buffer[4 + index] = bytes[index] }
    }
  }
}

/// Zeroes an array's bytes in place (a plaintext packet, a decrypted block) in a way the optimizer keeps.
func wipeBytes(_ bytes: inout [UInt8]) {
  bytes.withUnsafeMutableBytes { SecretBytes.wipe($0) }
}
