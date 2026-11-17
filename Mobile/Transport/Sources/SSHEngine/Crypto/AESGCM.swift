import CryptoKit
import Foundation

/// `aes256-gcm@openssh.com` / `aes128-gcm@openssh.com` (RFC 5647 §7.1 as OpenSSH implements it, PROTOCOL §1.6): the
/// 4-byte length in the clear as associated data, `padding_length ‖ payload ‖ padding` encrypted, a 16-byte tag. The
/// 12-byte nonce is the derived IV: 4 fixed bytes, then an 8-byte big-endian invocation counter that goes up by one
/// per packet (modulo 2^64, unreachable) and is independent of the sequence number.
struct GCMNonce {
  private var fixed: UInt32
  private var counter: UInt64

  init(iv: SecretBytes) throws(SSHError) {
    guard iv.count == 12 else { throw PacketProtection.invalid }
    (fixed, counter) = iv.withUnsafeBytes { raw in
      (UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)),
       UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt64.self)))
    }
  }

  /// The nonce for the next packet; `advance` after it was used.
  func current() throws(SSHError) -> AES.GCM.Nonce {
    var bytes = [UInt8](repeating: 0, count: 12)
    defer { wipeBytes(&bytes) }
    bytes.withUnsafeMutableBytes { raw in
      raw.storeBytes(of: fixed.bigEndian, toByteOffset: 0, as: UInt32.self)
      raw.storeBytes(of: counter.bigEndian, toByteOffset: 4, as: UInt64.self)
    }
    do { return try AES.GCM.Nonce(data: bytes) } catch { throw PacketProtection.invalid }
  }

  mutating func advance() { counter &+= 1 }

  mutating func wipe() {
    withUnsafeMutableBytes(of: &self) { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
  }
}

final class AESGCMOpener: PacketOpener {
  private let key: SymmetricKey
  private var nonce: GCMNonce

  init(keys: DirectionKeys) throws(SSHError) {
    key = SymmetricKey(data: keys.key)
    nonce = try GCMNonce(iv: keys.iv)
  }

  deinit { nonce.wipe() }

  var lengthPrefixBytes: Int { 4 }
  var tagBytes: Int { 16 }
  var blockBytes: Int { 16 }
  var lengthIsAligned: Bool { false }

  func packetLength(_ prefix: [UInt8], sequence: UInt32) throws(SSHError) -> UInt32 { try readLength(prefix) }

  func open(_ packet: [UInt8], sequence: UInt32) throws(SSHError) -> [UInt8] {
    let length = try packetBody(packet, length: try readLength(packet), tagBytes: 16)
    var plaintext: Data
    do {
      let box = try AES.GCM.SealedBox(nonce: try nonce.current(), ciphertext: packet[4..<4 + length],
                                      tag: packet[(4 + length)...])
      // CryptoKit checks the tag (in constant time) before it returns any plaintext.
      plaintext = try AES.GCM.open(box, using: key, authenticating: packet[0..<4])
    } catch {
      throw .protocolViolation(.packet(.integrity))
    }
    defer { wipeBytes(&plaintext) }
    nonce.advance()
    return [UInt8](plaintext)
  }
}

final class AESGCMSealer: PacketSealer {
  private let key: SymmetricKey
  private var nonce: GCMNonce

  init(keys: DirectionKeys) throws(SSHError) {
    key = SymmetricKey(data: keys.key)
    nonce = try GCMNonce(iv: keys.iv)
  }

  deinit { nonce.wipe() }

  var tagBytes: Int { 16 }
  var blockBytes: Int { 16 }
  var lengthIsAligned: Bool { false }

  func seal(_ packet: [UInt8], sequence: UInt32) throws(SSHError) -> [UInt8] {
    guard packet.count >= 4 else { throw PacketProtection.invalid }
    let box: AES.GCM.SealedBox
    do {
      box = try AES.GCM.seal(packet[4...], using: key, nonce: try nonce.current(), authenticating: packet[0..<4])
    } catch {
      throw PacketProtection.invalid
    }
    nonce.advance()
    var wire = [UInt8]()
    wire.reserveCapacity(packet.count + 16)
    wire.append(contentsOf: packet[0..<4])
    wire.append(contentsOf: box.ciphertext)
    wire.append(contentsOf: box.tag)
    return wire
  }
}
