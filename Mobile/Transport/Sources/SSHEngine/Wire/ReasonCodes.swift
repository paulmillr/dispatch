/// A DISCONNECT reason code (RFC 4250 §4.2.2). A struct: a server may send any uint32, which is kept as sent.
public struct DisconnectReason: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
  public let rawValue: UInt32

  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public init(_ rawValue: UInt32) { self.rawValue = rawValue }

  public static let hostNotAllowedToConnect = DisconnectReason(1)
  public static let protocolError = DisconnectReason(2)
  public static let keyExchangeFailed = DisconnectReason(3)
  public static let reserved = DisconnectReason(4)
  public static let macError = DisconnectReason(5)
  public static let compressionError = DisconnectReason(6)
  public static let serviceNotAvailable = DisconnectReason(7)
  public static let protocolVersionNotSupported = DisconnectReason(8)
  public static let hostKeyNotVerifiable = DisconnectReason(9)
  public static let connectionLost = DisconnectReason(10)
  public static let byApplication = DisconnectReason(11)
  public static let tooManyConnections = DisconnectReason(12)
  public static let authCancelledByUser = DisconnectReason(13)
  public static let noMoreAuthMethodsAvailable = DisconnectReason(14)
  public static let illegalUserName = DisconnectReason(15)

  public var description: String {
    switch rawValue {
    case 1: "host not allowed to connect"
    case 2: "protocol error"
    case 3: "key exchange failed"
    case 5: "MAC error"
    case 6: "compression error"
    case 7: "service not available"
    case 8: "protocol version not supported"
    case 9: "host key not verifiable"
    case 10: "connection lost"
    case 11: "by application"
    case 12: "too many connections"
    case 13: "authentication cancelled by user"
    case 14: "no more authentication methods available"
    case 15: "illegal user name"
    default: "reason \(rawValue)"
    }
  }
}

/// A CHANNEL_OPEN_FAILURE reason code (RFC 4254 §5.1), kept as sent.
public struct ChannelOpenFailureReason: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
  public let rawValue: UInt32

  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public init(_ rawValue: UInt32) { self.rawValue = rawValue }

  public static let administrativelyProhibited = ChannelOpenFailureReason(1)
  public static let connectFailed = ChannelOpenFailureReason(2)
  public static let unknownChannelType = ChannelOpenFailureReason(3)
  public static let resourceShortage = ChannelOpenFailureReason(4)

  public var description: String {
    switch rawValue {
    case 1: "administratively prohibited"
    case 2: "connect failed"
    case 3: "unknown channel type"
    case 4: "resource shortage"
    default: "reason \(rawValue)"
    }
  }
}

/// CHANNEL_EXTENDED_DATA's data type code (RFC 4254 §5.2). Only stderr is defined; any other code is a protocol error.
public enum ExtendedDataType {
  public static let stderr: UInt32 = 1
}
