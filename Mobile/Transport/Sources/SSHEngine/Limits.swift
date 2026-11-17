/// Every numeric bound the engine applies, in one place. A value the server controls is checked against one of these
/// before it is used or anything is allocated for it; exceeding one ends the connection (or fails the key file) with
/// a protocol error, never a trap. Change a bound here, nowhere else, and say why in the comment.
public enum Limits {
  // MARK: Version exchange (RFC 4253 §4.2)

  /// The longest identification line, CR LF included (RFC 4253 §4.2: 255).
  public static let versionLineBytes = 255
  /// Lines the server may send before its identification line (`SSH-2.0-`, or `SSH-1.99-`, which RFC 4253 §5.1
  /// makes equivalent), each at most `versionLineBytes` (RFC 4253 §4.2 allows other lines first). OpenSSH allows
  /// 1024; nothing real sends more than a few.
  public static let preVersionLines = 64

  // MARK: Packets (RFC 4253 §6)

  /// The largest `packet_length` accepted, checked from the length field alone before the rest is read or room is
  /// made for it: 256 KiB, OpenSSH's `PACKET_MAX_SIZE` (docs/security.md, pre-authentication bounds).
  public static let packetLength = 256 * 1024
  /// The largest MAC or AEAD tag of a supported algorithm (hmac-sha2-512: 64 bytes).
  public static let packetTagBytes = 64
  /// What the inbound buffer may hold: one whole packet of the largest size, its length field and tag.
  public static let inboundBufferBytes = 4 + packetLength + packetTagBytes
  /// The padding every packet carries at least (RFC 4253 §6). At most 255: `padding_length` is one byte.
  public static let minimumPadding = 4
  /// Rekey after this many bytes in either direction under one set of keys (1 GiB, far inside every cipher's limit).
  public static let rekeyBytes: UInt64 = 1 << 30
  /// Rekey after this many packets in either direction, so a sequence number never wraps (OpenSSH: 2^31). A wrap
  /// ends the connection.
  public static let rekeyPackets: UInt64 = 1 << 31
  /// Rekey after this long under one set of keys (russh's default, which the app has used).
  public static let rekeyInterval: Duration = .seconds(3600)

  // MARK: Names and negotiation (RFC 4251 §5, §6)

  /// The longest algorithm, method, service, request or extension name (RFC 4251 §6: 64 characters).
  public static let nameLength = 64
  /// The longest name-list string: a KEXINIT list, the methods of USERAUTH_FAILURE, `server-sig-algs`.
  public static let nameListBytes = 8192
  /// The most names in one name-list.
  public static let nameListCount = 128

  // MARK: Key exchange and host keys

  /// The longest ephemeral public value or ciphertext in a key exchange message (mlkem768x25519's client value is
  /// 1216 bytes, its server reply 1120; P-521's point 133).
  public static let keyExchangeValueBytes = 2048
  /// The longest host or user public key blob (an RSA 16384-bit key is about 2.1 KB).
  public static let publicKeyBlobBytes = 4096
  /// The longest signature blob (an RSA 16384-bit signature is 2048 bytes plus its name).
  public static let signatureBlobBytes = 4096
  /// RSA modulus sizes accepted for host and user keys. 2048 is NIST's floor (OpenSSH refuses below 1024);
  /// 16384 is OpenSSH's ceiling.
  public static let rsaMinimumBits = 2048
  public static let rsaMaximumBits = 16384
  /// The longest RSA public exponent (8 bytes; real keys use 65537): a huge exponent would make each verification
  /// expensive.
  public static let rsaExponentBytes = 8
  // Certificates: none is ever decoded. A host key or key file whose type is a certificate type
  // (`*-cert-v01@openssh.com`) is refused by its name, so the nesting bound of the russh engine (8) has no
  // counterpart: there is no recursion to bound.

  // MARK: Key files (Keys/)

  /// The largest private key file read (an OpenSSH or PEM file holding a 16384-bit RSA key is about 13 KB).
  public static let keyFileBytes = 64 * 1024
  /// The most bcrypt_pbkdf rounds a passphrase-protected `openssh-key-v1` file may ask for. ssh-keygen's default is
  /// 24 (OpenSSH 10.5; older releases wrote 16); guides suggest `-a 100`. Measured in an optimized build: about 4.7 ms per round
  /// at the 48 bytes aes256-ctr derives (two output blocks, the most any supported cipher needs), so this bound costs
  /// about 5 s there and a guessed 2-3 times that on an older iPhone, which is what a hostile file can make the user
  /// wait. A file asking for more is refused (`KeyFileRefusal.bcryptRounds`).
  public static let keyFileBcryptRounds = 1024
  /// The longest bcrypt salt in a key file (ssh-keygen writes 16 bytes).
  public static let keyFileSaltBytes = 64
  /// The longest comment read from an `openssh-key-v1` file.
  public static let keyFileCommentBytes = 1024

  // MARK: Extensions (RFC 8308)

  /// EXT_INFO messages per connection: RFC 8308 allows one after the first NEWKEYS and one before
  /// USERAUTH_SUCCESS. A third ends the connection.
  public static let extInfoMessages = 2
  /// Extensions in one EXT_INFO (OpenSSH sends four or five).
  public static let extInfoExtensions = 64
  /// The longest extension value.
  public static let extensionValueBytes = 8192

  // MARK: User authentication (RFC 4252, RFC 4256)

  /// The longest banner, password-change prompt, or keyboard-interactive name, instruction or prompt read.
  public static let authenticationTextBytes = 16384
  /// The longest DISCONNECT or DEBUG description read (shown cut to `displayTextCharacters`).
  public static let descriptionBytes = 16384
  /// The longest language tag read (RFC 3066 tags are short; every one is ignored).
  public static let languageTagBytes = 256
  /// Prompts in one keyboard-interactive INFO_REQUEST.
  public static let keyboardInteractivePrompts = 32
  /// INFO_REQUEST rounds in one keyboard-interactive attempt (a server sending empty rounds forever is cut off).
  public static let keyboardInteractiveRounds = 32
  /// How long a direct public key request waits for its answer, counted from when it was sent (a signer's own time
  /// does not count); then the connection is closed (`SSHError.timedOut(.directAnswer)`).
  public static let directAnswer: Duration = .seconds(10)

  // MARK: Connection protocol (RFC 4254)

  /// Channels open at once on one connection.
  public static let channels = 64
  /// The window each channel grants the server, and up to which it is topped up as the app reads.
  public static let channelWindow: UInt32 = 2 * 1024 * 1024
  /// The largest CHANNEL_DATA / EXTENDED_DATA payload the engine accepts (announced as its maximum packet size),
  /// and the most it sends in one (the server's maximum may make it fewer).
  public static let channelMaximumPacket: UInt32 = 32 * 1024
  /// The smallest maximum packet size a server may announce for a channel: 0 would block every write to the
  /// channel forever (GHSA-fw5c-8223-6h42), so the open fails.
  public static let peerMinimumPacket: UInt32 = 1
  /// The longest exit-signal or open-failure message read. (An exit-signal's name is read as a name: `nameLength`.)
  public static let channelMessageBytes = 1024
  /// Bytes the core holds for the driver to write before the channel layer stops taking the app's writes.
  public static let outboundBacklogBytes = 1024 * 1024
  /// The app's input one channel holds that the server's window has not taken yet (a write takes at most what fits):
  /// a server that never opens its window costs at most this per channel (OpenSSH opens a session channel at 0).
  public static let channelInputBytes = 256 * 1024
  /// The largest `ConnectOptions.keepaliveCountMax`: the most keepalives a session may leave unanswered.
  public static let keepaliveCountMax = 100

  // MARK: Display

  /// The most characters of server-supplied text (a DISCONNECT or open-failure description) an error keeps.
  public static let displayTextCharacters = 256
}
