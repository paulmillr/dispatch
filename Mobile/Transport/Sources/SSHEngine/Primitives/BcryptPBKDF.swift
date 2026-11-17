import CryptoKit
import Foundation

/// OpenBSD's `bcrypt_pbkdf(3)` (lib/libutil/bcrypt_pbkdf.c), the KDF of passphrase-protected `openssh-key-v1` private
/// key files: PBKDF2's structure with SHA-512 and bcrypt's eksblowfish hash as the PRF, and its non-linear output
/// layout (byte `i` of block `n` goes to `i · stride + n - 1`).
///
/// A Swift port of that file (revision 1.17, copyright 2013 Ted Unangst, ISC license): THIRD_PARTY_NOTICES.md and
/// Mobile/ThirdPartyLicenses/SSHEngine/bcrypt_pbkdf-ISC.txt.
///
/// Not constant time, and not meant to be: Blowfish's S-box lookups are indexed by key-dependent bytes. It runs only
/// on a key file the user imports with their own passphrase, on the device, never on network data.
///
/// Cost: `rounds` bcrypt hashes per 32-byte output block, each 64 · 2 + 1 eksblowfish expansions. The file chooses
/// `rounds` (ssh-keygen writes 16 or 24); the caller should bound it before calling, since a hostile file could ask
/// for 2^32 - 1.
///
/// Secrets: the hashed passphrase, the per-round salts and outputs and the Blowfish state live in buffers this function
/// owns and clears with `memset_s` before it returns, error or not. Not cleared: CryptoKit's SHA-512 hasher state and
/// digest values (CryptoKit owns them), the caller's `password` and the returned key (the caller's to clear).
enum BcryptPBKDF {
  enum Error: Swift.Error, Equatable {
    /// OpenBSD's limits: rounds ≥ 1; password, salt and output non-empty; salt at most 2^20 bytes; output at most 1024.
    case invalidParameters
  }

  static let maximumOutput = 1024
  private static let hashSize = 32

  /// `count` bytes derived from `password` and `salt` over `rounds` rounds.
  static func derive(password: UnsafeRawBufferPointer, salt: UnsafeRawBufferPointer, rounds: Int, count: Int) throws -> [UInt8] {
    guard rounds >= 1, password.count > 0, salt.count > 0, salt.count <= 1 << 20, count > 0, count <= maximumOutput else {
      throw Error.invalidParameters
    }
    let stride = (count &+ hashSize &- 1) / hashSize
    var amount = (count &+ stride &- 1) / stride

    // sha2pass (64) | sha2salt (64) | out (32) | tmpout (32) | countsalt (4)
    let scratchSize = 64 &+ 64 &+ hashSize &+ hashSize &+ 4
    let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: scratchSize, alignment: 16)
    scratch.initializeMemory(as: UInt8.self, repeating: 0)
    defer {
      _ = memset_s(scratch.baseAddress, scratchSize, 0, scratchSize)
      scratch.deallocate()
    }
    let sha2pass = UnsafeMutableRawBufferPointer(rebasing: scratch[0..<64])
    let sha2salt = UnsafeMutableRawBufferPointer(rebasing: scratch[64..<128])
    let out = UnsafeMutableRawBufferPointer(rebasing: scratch[128..<(128 &+ hashSize)])
    let tmpout = UnsafeMutableRawBufferPointer(rebasing: scratch[(128 &+ hashSize)..<(128 &+ 2 &* hashSize)])
    let countsalt = UnsafeMutableRawBufferPointer(rebasing: scratch[(128 &+ 2 &* hashSize)...])
    let blowfish = Blowfish()

    var hasher = SHA512()
    hasher.update(bufferPointer: password)
    copy(hasher.finalize(), to: sha2pass)

    var key = [UInt8](repeating: 0, count: count)
    var remaining = count
    var block: UInt32 = 1
    while remaining > 0 {
      countsalt.storeBytes(of: block.bigEndian, as: UInt32.self)
      hasher = SHA512()
      hasher.update(bufferPointer: salt)
      hasher.update(bufferPointer: UnsafeRawBufferPointer(countsalt))
      copy(hasher.finalize(), to: sha2salt)
      hash(blowfish, password: UnsafeRawBufferPointer(sha2pass), salt: UnsafeRawBufferPointer(sha2salt), into: tmpout)
      out.copyMemory(from: UnsafeRawBufferPointer(tmpout))
      var round = 1
      while round < rounds {
        hasher = SHA512()
        hasher.update(bufferPointer: UnsafeRawBufferPointer(tmpout))
        copy(hasher.finalize(), to: sha2salt)
        hash(blowfish, password: UnsafeRawBufferPointer(sha2pass), salt: UnsafeRawBufferPointer(sha2salt), into: tmpout)
        for index in 0..<hashSize { out[index] ^= tmpout[index] }
        round = round &+ 1
      }
      // The deviation from PBKDF2: block `block`'s bytes are spread `stride` apart.
      amount = min(amount, remaining)
      var index = 0
      while index < amount {
        let destination = index &* stride &+ Int(block) &- 1
        if destination >= count { break }
        key[destination] = out[index]
        index = index &+ 1
      }
      remaining = remaining &- index
      block = block &+ 1
    }
    return key
  }

  static func derive(password: some ContiguousBytes, salt: some ContiguousBytes, rounds: Int, count: Int) throws -> [UInt8] {
    try password.withUnsafeBytes { password in
      try salt.withUnsafeBytes { try derive(password: password, salt: $0, rounds: rounds, count: count) }
    }
  }

  /// `bcrypt_hash`: eksblowfish keyed with the 64-byte hashed password and salt (one salted expansion, then 64 pairs
  /// of unsalted ones), then "OxychromaticBlowfishSwatDynamite" encrypted 64 times, each word written little-endian.
  private static func hash(_ blowfish: borrowing Blowfish, password: UnsafeRawBufferPointer, salt: UnsafeRawBufferPointer,
                           into output: UnsafeMutableRawBufferPointer) {
    blowfish.reset()
    blowfish.expandState(data: salt, key: password)
    for _ in 0..<64 {
      blowfish.expand0State(key: salt)
      blowfish.expand0State(key: password)
    }
    withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 8) { words in
      magic.withUnsafeBytes { magic in
        var position = 0
        for index in 0..<8 { words[index] = Blowfish.streamWord(magic, &position) }
      }
      for _ in 0..<64 {
        var index = 0
        while index < 8 {
          blowfish.encipher(&words[index], &words[index &+ 1])
          index = index &+ 2
        }
      }
      for index in 0..<8 { output.storeBytes(of: words[index].littleEndian, toByteOffset: index &* 4, as: UInt32.self) }
      _ = memset_s(words.baseAddress, 32, 0, 32)
    }
  }

  private static let magic = Array("OxychromaticBlowfishSwatDynamite".utf8)

  private static func copy(_ digest: SHA512.Digest, to target: UnsafeMutableRawBufferPointer) {
    digest.withUnsafeBytes { target.copyMemory(from: $0) }
  }
}
