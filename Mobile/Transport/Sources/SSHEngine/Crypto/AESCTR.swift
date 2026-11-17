import CommonCrypto
import CryptoKit
import Foundation

/// AES in CTR mode (RFC 4344 §4: the derived IV is the initial 128-bit big-endian counter block), one keystream for
/// the life of the keys: CommonCrypto's cryptor carries the counter from packet to packet. Every call covers whole
/// blocks (the framer's alignment), so no keystream is left half used between calls.
final class AESCTRStream {
  private var cryptor: CCCryptorRef?

  init(key: SecretBytes, iv: SecretBytes) throws(SSHError) {
    guard [16, 24, 32].contains(key.count), iv.count == 16 else { throw PacketProtection.invalid }
    var created: CCCryptorRef?
    let status = key.withUnsafeBytes { key in
      iv.withUnsafeBytes { iv in
        CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                CCPadding(ccNoPadding), iv.baseAddress, key.baseAddress, key.count, nil, 0, 0,
                                CCModeOptions(kCCModeOptionCTR_BE), &created)
      }
    }
    guard status == CCCryptorStatus(kCCSuccess), let created else { throw PacketProtection.invalid }
    cryptor = created
  }

  deinit {
    // CCCryptorRelease clears the key schedule before freeing it.
    if let cryptor { CCCryptorRelease(cryptor) }
  }

  /// XORs `bytes` with the next `bytes.count` keystream bytes, in place.
  func apply(_ bytes: UnsafeMutableRawBufferPointer) throws(SSHError) {
    guard let base = bytes.baseAddress, bytes.count > 0 else { return }
    var moved = 0
    let status = CCCryptorUpdate(cryptor, base, bytes.count, base, bytes.count, &moved)
    guard status == CCCryptorStatus(kCCSuccess), moved == bytes.count else { throw PacketProtection.invalid }
  }

  func apply(_ bytes: inout [UInt8], from start: Int = 0) throws(SSHError) {
    var failure: SSHError?
    bytes.withUnsafeMutableBytes { raw in
      do throws(SSHError) { try apply(UnsafeMutableRawBufferPointer(rebasing: raw[start...])) } catch { failure = error }
    }
    if let failure { throw failure }
  }
}

/// An HMAC key of `hmac-sha2-256`/`-512` (RFC 6668; the `-etm@openssh.com` forms use the same function, over other
/// bytes). The MAC of a packet always starts with the uint32 sequence number.
struct MACKey {
  let algorithm: MACAlgorithm
  private let key: SymmetricKey

  init(_ algorithm: MACAlgorithm, key: SecretBytes) throws(SSHError) {
    guard key.count == algorithm.keyBytes else { throw PacketProtection.invalid }
    self.algorithm = algorithm
    self.key = SymmetricKey(data: key)
  }

  var tagBytes: Int { algorithm.tagBytes }

  /// HMAC(key, uint32 sequence ‖ parts...).
  func code(sequence: UInt32, _ parts: ArraySlice<UInt8>...) -> [UInt8] {
    var number = sequence.bigEndian
    switch algorithm {
    case .hmacSHA256, .hmacSHA256ETM:
      var hmac = HMAC<SHA256>(key: key)
      withUnsafeBytes(of: &number) { hmac.update(data: $0) }
      for part in parts { part.withUnsafeBytes { hmac.update(data: $0) } }
      return Array(hmac.finalize())
    case .hmacSHA512, .hmacSHA512ETM:
      var hmac = HMAC<SHA512>(key: key)
      withUnsafeBytes(of: &number) { hmac.update(data: $0) }
      for part in parts { part.withUnsafeBytes { hmac.update(data: $0) } }
      return Array(hmac.finalize())
    }
  }

  /// Whether `received` is the MAC of the parts, compared in constant time.
  func verify(_ received: ArraySlice<UInt8>, sequence: UInt32, _ parts: ArraySlice<UInt8>...) -> Bool {
    var number = sequence.bigEndian
    let expected: [UInt8]
    switch algorithm {
    case .hmacSHA256, .hmacSHA256ETM:
      var hmac = HMAC<SHA256>(key: key)
      withUnsafeBytes(of: &number) { hmac.update(data: $0) }
      for part in parts { part.withUnsafeBytes { hmac.update(data: $0) } }
      expected = Array(hmac.finalize())
    case .hmacSHA512, .hmacSHA512ETM:
      var hmac = HMAC<SHA512>(key: key)
      withUnsafeBytes(of: &number) { hmac.update(data: $0) }
      for part in parts { part.withUnsafeBytes { hmac.update(data: $0) } }
      expected = Array(hmac.finalize())
    }
    return ConstantTime.equal(expected, received)
  }
}

/// AES-CTR with an `-etm@openssh.com` MAC (OpenSSH PROTOCOL §1.5): the length in the clear, the rest encrypted, the
/// MAC over sequence ‖ length ‖ ciphertext, checked before anything is decrypted.
final class AESCTREncryptThenMACOpener: PacketOpener {
  private let stream: AESCTRStream
  private let mac: MACKey

  init(keys: DirectionKeys, mac: MACKey) throws(SSHError) {
    stream = try AESCTRStream(key: keys.key, iv: keys.iv)
    self.mac = mac
  }

  var lengthPrefixBytes: Int { 4 }
  var tagBytes: Int { mac.tagBytes }
  var blockBytes: Int { 16 }
  var lengthIsAligned: Bool { false }

  func packetLength(_ prefix: [UInt8], sequence: UInt32) throws(SSHError) -> UInt32 { try readLength(prefix) }

  func open(_ packet: [UInt8], sequence: UInt32) throws(SSHError) -> [UInt8] {
    let length = try packetBody(packet, length: try readLength(packet), tagBytes: mac.tagBytes)
    guard mac.verify(packet[(4 + length)...], sequence: sequence, packet[0..<4 + length]) else {
      throw .protocolViolation(.packet(.integrity))
    }
    var plaintext = Array(packet[4..<4 + length])
    try stream.apply(&plaintext)
    return plaintext
  }
}

/// AES-CTR with an encrypt-and-MAC MAC (RFC 4253 §6.4): the length is inside the first encrypted block, so
/// `packetLength` decrypts that block (kept for `open`); the MAC covers sequence ‖ the whole plaintext packet, so it can
/// only be checked after decryption. Nothing decrypted leaves unless it verified; a failed packet's plaintext is wiped.
final class AESCTREncryptAndMACOpener: PacketOpener {
  private let stream: AESCTRStream
  private let mac: MACKey
  /// The first block `packetLength` decrypted, for the same packet's `open`.
  private var firstBlock: [UInt8] = []

  init(keys: DirectionKeys, mac: MACKey) throws(SSHError) {
    stream = try AESCTRStream(key: keys.key, iv: keys.iv)
    self.mac = mac
  }

  deinit { wipeBytes(&firstBlock) }

  var lengthPrefixBytes: Int { 16 }
  var tagBytes: Int { mac.tagBytes }
  var blockBytes: Int { 16 }
  var lengthIsAligned: Bool { true }

  func packetLength(_ prefix: [UInt8], sequence: UInt32) throws(SSHError) -> UInt32 {
    guard prefix.count >= 16 else { throw .protocolViolation(.packet(.lengthOutOfRange)) }
    wipeBytes(&firstBlock)
    firstBlock = Array(prefix[0..<16])
    try stream.apply(&firstBlock)
    return try readLength(firstBlock)
  }

  func open(_ packet: [UInt8], sequence: UInt32) throws(SSHError) -> [UInt8] {
    guard firstBlock.count == 16 else { throw .protocolViolation(.packet(.lengthOutOfRange)) }
    let length = try packetBody(packet, length: try readLength(firstBlock), tagBytes: mac.tagBytes)
    guard 4 + length >= 16 else { throw .protocolViolation(.packet(.lengthOutOfRange)) }
    var plaintext = [UInt8]()
    plaintext.reserveCapacity(4 + length)
    plaintext.append(contentsOf: firstBlock)
    plaintext.append(contentsOf: packet[16..<4 + length])
    wipeBytes(&firstBlock)
    firstBlock = []
    try stream.apply(&plaintext, from: 16)
    guard mac.verify(packet[(4 + length)...], sequence: sequence, plaintext[...]) else {
      wipeBytes(&plaintext)
      throw .protocolViolation(.packet(.integrity))
    }
    return Array(plaintext[4...])
  }
}

/// The sealing side of both AES-CTR forms.
final class AESCTRSealer: PacketSealer {
  private let stream: AESCTRStream
  private let mac: MACKey

  init(keys: DirectionKeys, mac: MACKey) throws(SSHError) {
    stream = try AESCTRStream(key: keys.key, iv: keys.iv)
    self.mac = mac
  }

  var tagBytes: Int { mac.tagBytes }
  var blockBytes: Int { 16 }
  var lengthIsAligned: Bool { !mac.algorithm.isEncryptThenMAC }

  func seal(_ packet: [UInt8], sequence: UInt32) throws(SSHError) -> [UInt8] {
    guard packet.count >= 4 else { throw PacketProtection.invalid }
    var wire = [UInt8]()
    wire.reserveCapacity(packet.count + mac.tagBytes)
    wire.append(contentsOf: packet)
    if mac.algorithm.isEncryptThenMAC {
      try stream.apply(&wire, from: 4)
      wire.append(contentsOf: mac.code(sequence: sequence, wire[...]))
    } else {
      let code = mac.code(sequence: sequence, packet[...])
      try stream.apply(&wire)
      wire.append(contentsOf: code)
    }
    return wire
  }
}
