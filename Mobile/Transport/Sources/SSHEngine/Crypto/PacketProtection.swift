/// Makes a direction's `PacketOpener`/`PacketSealer` from the negotiated cipher, MAC and that direction's keys (see
/// `Contract/PacketCipher.swift` for how each family treats the length). Key sizes are the derivation's, so a size
/// mismatch is the engine's bug, reported as a usage error rather than trapping.
public enum PacketProtection {
  public static func opener(cipher: CipherAlgorithm, mac: MACAlgorithm?, keys: DirectionKeys) throws(SSHError) -> any PacketOpener {
    try check(cipher: cipher, mac: mac, keys: keys)
    switch cipher {
    case .aes256GCM, .aes128GCM:
      return try AESGCMOpener(keys: keys)
    case .chacha20Poly1305:
      return try ChaChaPolyOpener(key: keys.key)
    case .aes256CTR, .aes192CTR, .aes128CTR:
      guard let mac, let macKey = keys.macKey else { throw invalid }
      return mac.isEncryptThenMAC
        ? try AESCTREncryptThenMACOpener(keys: keys, mac: MACKey(mac, key: macKey))
        : try AESCTREncryptAndMACOpener(keys: keys, mac: MACKey(mac, key: macKey))
    }
  }

  public static func sealer(cipher: CipherAlgorithm, mac: MACAlgorithm?, keys: DirectionKeys) throws(SSHError) -> any PacketSealer {
    try check(cipher: cipher, mac: mac, keys: keys)
    switch cipher {
    case .aes256GCM, .aes128GCM:
      return try AESGCMSealer(keys: keys)
    case .chacha20Poly1305:
      return try ChaChaPolySealer(key: keys.key)
    case .aes256CTR, .aes192CTR, .aes128CTR:
      guard let mac, let macKey = keys.macKey else { throw invalid }
      return try AESCTRSealer(keys: keys, mac: MACKey(mac, key: macKey))
    }
  }

  static let invalid = SSHError.usage(.invalidArgument("packet protection keys of the wrong size"))

  private static func check(cipher: CipherAlgorithm, mac: MACAlgorithm?, keys: DirectionKeys) throws(SSHError) {
    guard keys.key.count == cipher.keyBytes, keys.iv.count == cipher.ivBytes, cipher.isAEAD == (mac == nil),
      keys.macKey?.count == mac?.keyBytes
    else { throw invalid }
  }
}

/// Before the first NEWKEYS (RFC 4253 §6): no encryption, no MAC, aligned to 8 with the length included.
public final class PlaintextOpener: PacketOpener {
  public init() {}
  public var lengthPrefixBytes: Int { 4 }
  public var tagBytes: Int { 0 }
  public var blockBytes: Int { 8 }
  public var lengthIsAligned: Bool { true }

  public func packetLength(_ prefix: [UInt8], sequence: UInt32) throws(SSHError) -> UInt32 {
    try readLength(prefix)
  }

  public func open(_ packet: [UInt8], sequence: UInt32) throws(SSHError) -> [UInt8] {
    guard packet.count >= 4 else { throw .protocolViolation(.packet(.lengthOutOfRange)) }
    return Array(packet[4...])
  }
}

public final class PlaintextSealer: PacketSealer {
  public init() {}
  public var tagBytes: Int { 0 }
  public var blockBytes: Int { 8 }
  public var lengthIsAligned: Bool { true }

  public func seal(_ packet: [UInt8], sequence: UInt32) throws(SSHError) -> [UInt8] { packet }
}

/// The big-endian uint32 at the start of `bytes`.
func readLength(_ bytes: [UInt8]) throws(SSHError) -> UInt32 {
  guard bytes.count >= 4 else { throw .protocolViolation(.packet(.lengthOutOfRange)) }
  return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
}

/// Whether `packet` holds exactly one whole packet of the length its first 4 bytes (or `length`) give, plus `tag`.
/// The framer guarantees it; the families check again so no slice below can run past the end.
func packetBody(_ packet: [UInt8], length: UInt32, tagBytes: Int) throws(SSHError) -> Int {
  guard let length = Int(exactly: length), length <= Limits.packetLength, packet.count == 4 + length + tagBytes else {
    throw .protocolViolation(.packet(.lengthOutOfRange))
  }
  return length
}
