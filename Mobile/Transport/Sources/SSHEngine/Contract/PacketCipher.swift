/// The packet protection of one direction (RFC 4253 §6), made from a negotiated cipher (and MAC, for CTR) and that
/// direction's derived keys (implemented in Crypto/). A new pair replaces the old at each NEWKEYS; before the first,
/// the plaintext pair applies (block 8, no tag). Instances belong to one core and are not shared.
///
/// The framer (Transport/) owns everything around them: reading the length, its limit and alignment checks, padding,
/// sequence numbers (counted from the first packet, never reset except by strict key exchange at NEWKEYS), and the
/// order of calls. How the three families treat the 4-byte `packet_length`:
///
/// | Family | Length on the wire | `lengthPrefixBytes` | Aligned | Covered by |
/// | --- | --- | --- | --- | --- |
/// | AES-GCM (RFC 5647, OpenSSH) | clear | 4 | `packet_length` only | the tag, as associated data |
/// | ChaCha20-Poly1305 (OpenSSH) | encrypted with the second key, nonce = sequence | 4 | `packet_length` only | the tag |
/// | AES-CTR + `-etm` MAC | clear | 4 | `packet_length` only | the MAC (over sequence, length, ciphertext) |
/// | AES-CTR + MAC (encrypt-and-MAC) | inside the first encrypted block | 16 | `4 + packet_length` | the MAC (over sequence and plaintext) |
///
/// In every family the length is unauthenticated when the framer first sees it: it is only a bound on how many bytes
/// to wait for, checked against `Limits.packetLength` and the alignment before more is read.

/// One direction's keys (RFC 4253 §7.2), each exactly the size its algorithm takes.
public struct DirectionKeys: Sendable {
  /// `CipherAlgorithm.ivBytes` (empty for ChaCha20-Poly1305).
  public let iv: SecretBytes
  /// `CipherAlgorithm.keyBytes`.
  public let key: SecretBytes
  /// `MACAlgorithm.keyBytes`; nil for an AEAD cipher.
  public let macKey: SecretBytes?

  public init(iv: SecretBytes, key: SecretBytes, macKey: SecretBytes?) {
    self.iv = iv
    self.key = key
    self.macKey = macKey
  }
}

/// Inbound: authenticates and decrypts the server's packets.
public protocol PacketOpener: AnyObject {
  /// Bytes the framer must hold before `packetLength` can read the length (the table above).
  var lengthPrefixBytes: Int { get }
  /// The tag or MAC after each packet (0 for the plaintext opener).
  var tagBytes: Int { get }
  /// The alignment the packet must have (`CipherAlgorithm.blockBytes`; 8 for plaintext).
  var blockBytes: Int { get }
  /// Whether the 4 length bytes count toward the alignment (only encrypt-and-MAC and plaintext).
  var lengthIsAligned: Bool { get }

  /// `packet_length` from the packet's first `lengthPrefixBytes` bytes, as received. Called once per packet, then
  /// `open` for the same packet and sequence number (encrypt-and-MAC keeps the first block it decrypted).
  func packetLength(_ prefix: [UInt8], sequence: UInt32) throws(SSHError) -> UInt32

  /// The packet's plaintext, `padding_length ‖ payload ‖ padding`, from all its `4 + packet_length + tagBytes`
  /// bytes as received (the prefix included). The tag or MAC is checked in constant time and nothing decrypted is
  /// returned unless it verified; a failure is `ProtocolViolation.packet(.integrity)` and ends the connection.
  func open(_ packet: [UInt8], sequence: UInt32) throws(SSHError) -> [UInt8]
}

/// Outbound: protects the client's packets.
public protocol PacketSealer: AnyObject {
  var tagBytes: Int { get }
  var blockBytes: Int { get }
  var lengthIsAligned: Bool { get }

  /// The wire bytes for one packet: `packet` is `uint32 packet_length ‖ padding_length ‖ payload ‖ padding`, which
  /// the framer padded (random bytes, at least `Limits.minimumPadding`) to the alignment. Returns the length as the
  /// family sends it, the ciphertext, and the tag or MAC.
  func seal(_ packet: [UInt8], sequence: UInt32) throws(SSHError) -> [UInt8]
}
