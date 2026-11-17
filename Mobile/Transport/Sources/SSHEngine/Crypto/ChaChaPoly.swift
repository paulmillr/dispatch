import Foundation

/// `chacha20-poly1305@openssh.com` (OpenSSH PROTOCOL.chacha20poly1305), from the hand-written `ChaCha20` and
/// `Poly1305`. The 64 derived key bytes are two keys: the first 32 are K_2 (the main key), the last 32 K_1 (the
/// header key). Per packet, with the nonce the 64-bit big-endian sequence number (ChaCha20's original layout):
///
/// - the 4-byte length is encrypted with K_1 at block 0;
/// - the Poly1305 key is the first 32 bytes of K_2's block 0;
/// - `padding_length ‖ payload ‖ padding` is encrypted with K_2 from block 1;
/// - the tag is Poly1305 over the encrypted length and the ciphertext.
///
/// The opener decrypts the length only to know how much to wait for; it checks the tag (constant-time compare) before
/// it decrypts anything else.
struct ChaChaPolyKeys {
  /// K_2 then K_1, as derived. Wiped when the last reference goes.
  let key: SecretBytes

  init(_ key: SecretBytes) throws(SSHError) {
    guard key.count == 64 else { throw PacketProtection.invalid }
    self.key = key
  }

  /// ChaCha20 under K_2 (`header` false) or K_1 for `sequence`. The caller wipes the value after use.
  func cipher(header: Bool, sequence: UInt32) throws(SSHError) -> ChaCha20 {
    var nonce: (UInt32, UInt32) = (0, sequence.bigEndian)
    do {
      return try key.withUnsafeBytes { raw in
        try withUnsafeBytes(of: &nonce) { nonce in
          try ChaCha20(key: UnsafeRawBufferPointer(rebasing: header ? raw[32..<64] : raw[0..<32]), nonce: nonce)
        }
      }
    } catch {
      throw PacketProtection.invalid
    }
  }

  /// Poly1305 over `authenticated` with the one-time key from K_2's block 0.
  static func tag(_ main: ChaCha20, over authenticated: some ContiguousBytes) -> [UInt8] {
    withUnsafeTemporaryAllocation(byteCount: ChaCha20.blockSize, alignment: 16) { block in
      main.block(counter: 0, into: block)
      defer { SecretBytes.wipe(block) }
      var mac = Poly1305(key: UnsafeRawBufferPointer(rebasing: block[0..<Poly1305.keySize]))
      authenticated.withUnsafeBytes { mac.update($0) }
      return mac.finalize()
    }
  }
}

final class ChaChaPolyOpener: PacketOpener {
  private let keys: ChaChaPolyKeys

  init(key: SecretBytes) throws(SSHError) { keys = try ChaChaPolyKeys(key) }

  var lengthPrefixBytes: Int { 4 }
  var tagBytes: Int { 16 }
  var blockBytes: Int { 8 }
  var lengthIsAligned: Bool { false }

  func packetLength(_ prefix: [UInt8], sequence: UInt32) throws(SSHError) -> UInt32 {
    guard prefix.count >= 4 else { throw .protocolViolation(.packet(.lengthOutOfRange)) }
    var header = try keys.cipher(header: true, sequence: sequence)
    defer { header.wipe() }
    var length = Array(prefix[0..<4])
    header.xor(&length, counter: 0)
    return try readLength(length)
  }

  func open(_ packet: [UInt8], sequence: UInt32) throws(SSHError) -> [UInt8] {
    let length = try packetBody(packet, length: try packetLength(packet, sequence: sequence), tagBytes: 16)
    var main = try keys.cipher(header: false, sequence: sequence)
    defer { main.wipe() }
    let expected = ChaChaPolyKeys.tag(main, over: packet[0..<4 + length])
    guard ConstantTime.equal(expected, packet[(4 + length)...]) else {
      throw .protocolViolation(.packet(.integrity))
    }
    var plaintext = Array(packet[4..<4 + length])
    main.xor(&plaintext, counter: 1)
    return plaintext
  }
}

final class ChaChaPolySealer: PacketSealer {
  private let keys: ChaChaPolyKeys

  init(key: SecretBytes) throws(SSHError) { keys = try ChaChaPolyKeys(key) }

  var tagBytes: Int { 16 }
  var blockBytes: Int { 8 }
  var lengthIsAligned: Bool { false }

  func seal(_ packet: [UInt8], sequence: UInt32) throws(SSHError) -> [UInt8] {
    guard packet.count >= 4 else { throw PacketProtection.invalid }
    var header = try keys.cipher(header: true, sequence: sequence)
    var main = try keys.cipher(header: false, sequence: sequence)
    defer {
      header.wipe()
      main.wipe()
    }
    var wire = [UInt8]()
    wire.reserveCapacity(packet.count + 16)
    wire.append(contentsOf: packet)
    wire.withUnsafeMutableBytes { raw in
      header.xor(UnsafeMutableRawBufferPointer(rebasing: raw[0..<4]), counter: 0)
      main.xor(UnsafeMutableRawBufferPointer(rebasing: raw[4...]), counter: 1)
    }
    wire.append(contentsOf: ChaChaPolyKeys.tag(main, over: wire[...]))
    return wire
  }
}
