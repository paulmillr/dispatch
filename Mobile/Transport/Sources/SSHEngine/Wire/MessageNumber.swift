/// An SSH message number, the first byte of every payload (RFC 4250 §4.1). A struct, not an enum: the method-specific
/// ranges reuse numbers (60 is PK_OK, PASSWD_CHANGEREQ or INFO_REQUEST by the userauth method in progress; 30 and 31
/// are each key exchange method's own), and a server may send any byte. Which numbers are acceptable when is
/// `MessagePolicy`'s decision.
public struct MessageNumber: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
  public let rawValue: UInt8

  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public init(_ rawValue: UInt8) { self.rawValue = rawValue }

  // MARK: Transport layer generic, 1-19 (RFC 4253 §12, RFC 8308)

  public static let disconnect = MessageNumber(1)
  public static let ignore = MessageNumber(2)
  public static let unimplemented = MessageNumber(3)
  public static let debug = MessageNumber(4)
  public static let serviceRequest = MessageNumber(5)
  public static let serviceAccept = MessageNumber(6)
  public static let extInfo = MessageNumber(7)

  // MARK: Algorithm negotiation, 20-29

  public static let kexInit = MessageNumber(20)
  public static let newKeys = MessageNumber(21)

  // MARK: Key exchange method specific, 30-49
  // Every supported method uses the same pair: ecdh-sha2-* (RFC 5656 §7.1), curve25519-sha256 (RFC 8731) and
  // mlkem768x25519-sha256 (draft-ietf-sshm-mlkem-hybrid-kex, KEX_HYBRID_INIT/REPLY) all send 30 and answer 31.

  /// The client's ephemeral value (KEX_ECDH_INIT, KEX_HYBRID_INIT).
  public static let kexECDHInit = MessageNumber(30)
  /// The server's host key, ephemeral value and signature (KEX_ECDH_REPLY, KEX_HYBRID_REPLY).
  public static let kexECDHReply = MessageNumber(31)

  // MARK: User authentication generic, 50-59 (RFC 4252 §6)

  public static let userauthRequest = MessageNumber(50)
  public static let userauthFailure = MessageNumber(51)
  public static let userauthSuccess = MessageNumber(52)
  public static let userauthBanner = MessageNumber(53)

  // MARK: User authentication method specific, 60-79

  /// publickey: the key is acceptable (RFC 4252 §7).
  public static let userauthPKOK = MessageNumber(60)
  /// password: the server asks for a new password (RFC 4252 §8).
  public static let userauthPasswordChangeRequest = MessageNumber(60)
  /// keyboard-interactive: prompts (RFC 4256 §3.2).
  public static let userauthInfoRequest = MessageNumber(60)
  /// keyboard-interactive: the client's answers (RFC 4256 §3.4).
  public static let userauthInfoResponse = MessageNumber(61)

  // MARK: Connection protocol generic, 80-89 (RFC 4254 §9)

  public static let globalRequest = MessageNumber(80)
  public static let requestSuccess = MessageNumber(81)
  public static let requestFailure = MessageNumber(82)

  // MARK: Channel related, 90-127

  public static let channelOpen = MessageNumber(90)
  public static let channelOpenConfirmation = MessageNumber(91)
  public static let channelOpenFailure = MessageNumber(92)
  public static let channelWindowAdjust = MessageNumber(93)
  public static let channelData = MessageNumber(94)
  public static let channelExtendedData = MessageNumber(95)
  public static let channelEOF = MessageNumber(96)
  public static let channelClose = MessageNumber(97)
  public static let channelRequest = MessageNumber(98)
  public static let channelSuccess = MessageNumber(99)
  public static let channelFailure = MessageNumber(100)

  /// The RFC name, or the bare number where it depends on the method (30, 31, 60) or is unassigned.
  public var description: String {
    switch rawValue {
    case 1: "DISCONNECT"
    case 2: "IGNORE"
    case 3: "UNIMPLEMENTED"
    case 4: "DEBUG"
    case 5: "SERVICE_REQUEST"
    case 6: "SERVICE_ACCEPT"
    case 7: "EXT_INFO"
    case 20: "KEXINIT"
    case 21: "NEWKEYS"
    case 50: "USERAUTH_REQUEST"
    case 51: "USERAUTH_FAILURE"
    case 52: "USERAUTH_SUCCESS"
    case 53: "USERAUTH_BANNER"
    case 61: "USERAUTH_INFO_RESPONSE"
    case 80: "GLOBAL_REQUEST"
    case 81: "REQUEST_SUCCESS"
    case 82: "REQUEST_FAILURE"
    case 90: "CHANNEL_OPEN"
    case 91: "CHANNEL_OPEN_CONFIRMATION"
    case 92: "CHANNEL_OPEN_FAILURE"
    case 93: "CHANNEL_WINDOW_ADJUST"
    case 94: "CHANNEL_DATA"
    case 95: "CHANNEL_EXTENDED_DATA"
    case 96: "CHANNEL_EOF"
    case 97: "CHANNEL_CLOSE"
    case 98: "CHANNEL_REQUEST"
    case 99: "CHANNEL_SUCCESS"
    case 100: "CHANNEL_FAILURE"
    default: "message \(rawValue)"
    }
  }
}
