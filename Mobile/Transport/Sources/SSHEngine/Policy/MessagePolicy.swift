/// Which inbound message numbers each phase accepts (design rule 1: fail closed). The transport asks for every
/// decrypted packet, before anything parses its payload: a number the phase does not list ends the connection with
/// `ProtocolViolation.unexpectedMessage`. That includes every unknown or reserved number: the engine never answers
/// UNIMPLEMENTED, a deliberate deviation from RFC 4253 §11.4 (a peer that sends what we never asked for is not one
/// we keep talking to).
///
/// The phase has two halves, owned by different layers: the transport's (`TransportPhase`: key exchanges) and the
/// layers above it (`ServicePhase`: the userauth service, then the connection protocol). While a key exchange is
/// running past both KEXINITs, nothing of the upper layers is accepted (RFC 4253 §7.1). What the policy cannot see
/// is checked by the layer that handles the message: a channel number, a reply with no request pending.
///
/// Transport generics (RFC 4253 §11): DISCONNECT is accepted everywhere. IGNORE and DEBUG everywhere except in a
/// strict initial exchange once both KEXINITs are known (`kex-strict-*`: "any unexpected packet"); before the server's
/// KEXINIT strictness is unknown, so they are accepted there and `checkFirstKexInit` refuses a strict KEXINIT that was
/// not packet 0. UNIMPLEMENTED only after the initial exchange (before it the engine sent nothing a server may lack);
/// the transport then ends the connection unless the sequence number is a keepalive's (a server without global
/// requests may answer one that way).
///
/// EXT_INFO (RFC 8308 §2.4): as the first packet after the first NEWKEYS, and while a userauth request is out, where
/// it immediately precedes USERAUTH_SUCCESS: after it the next message for the layers above must be that success
/// (`Context.extInfoBeforeSuccess`). Transport messages between them (IGNORE, DEBUG) are taken as anywhere else.
public enum MessagePolicy {
  /// Where a key exchange is, past both KEXINITs.
  public enum KeyExchangeStage: Sendable, Hashable {
    /// The client sent its method message (30); the reply (31) is next.
    case awaitingReply
    /// The reply arrived and verified; the server's NEWKEYS (21) is next.
    case awaitingNewKeys
  }

  /// The transport's half.
  public enum TransportPhase: Sendable, Hashable {
    /// Before the server's first KEXINIT.
    case awaitingFirstKexInit
    /// The first exchange, past both KEXINITs. `strict`: both sent the strict signal.
    case initialExchange(KeyExchangeStage, strict: Bool)
    /// Keys in place, no exchange running.
    case established
    /// The client sent KEXINIT for a re-exchange and the server's has not arrived: the upper layers' messages
    /// still arrive (the server sent them before it saw ours).
    case rekeyRequested
    /// A re-exchange past both KEXINITs: only transport generics and the exchange's own messages.
    case reexchange(KeyExchangeStage)
  }

  /// The userauth request the auth layer has outstanding: what 60 means, if anything.
  public enum UserauthWait: Sendable, Hashable {
    /// No request outstanding (between attempts, or while a prompt or signature is being answered).
    case idle
    /// The `none` method.
    case noneMethod
    /// `password`: 60 is PASSWD_CHANGEREQ.
    case password
    /// A publickey query (no signature): 60 is PK_OK.
    case publicKeyQuery
    /// A signed publickey request, direct or after PK_OK: no 60.
    case publicKeySigned
    /// `keyboard-interactive`: 60 is INFO_REQUEST.
    case keyboardInteractive
  }

  /// The upper layers' half.
  public enum ServicePhase: Sendable, Hashable {
    /// No SERVICE_REQUEST sent yet.
    case serviceNotRequested
    /// SERVICE_REQUEST for `ssh-userauth` sent; its accept is next (a direct login's request may already follow it).
    case serviceRequested
    /// The userauth service runs.
    case userauth(UserauthWait)
    /// USERAUTH_SUCCESS arrived: the connection protocol.
    case connection
  }

  public struct Context: Sendable, Hashable, CustomStringConvertible {
    public var transport: TransportPhase
    public var service: ServicePhase
    /// No packet has arrived since the server's first NEWKEYS (RFC 8308 §2.4: the first EXT_INFO's place).
    public var firstPacketAfterNewKeys: Bool
    /// EXT_INFO messages received so far.
    public var extInfoReceived: Int
    /// An EXT_INFO arrived during authentication and no message for the upper layers since: the next one must be
    /// USERAUTH_SUCCESS (RFC 8308 §2.4, "immediately preceding").
    public var extInfoBeforeSuccess: Bool

    public init(transport: TransportPhase, service: ServicePhase = .serviceNotRequested,
                firstPacketAfterNewKeys: Bool = false, extInfoReceived: Int = 0, extInfoBeforeSuccess: Bool = false) {
      self.transport = transport
      self.service = service
      self.firstPacketAfterNewKeys = firstPacketAfterNewKeys
      self.extInfoReceived = extInfoReceived
      self.extInfoBeforeSuccess = extInfoBeforeSuccess
    }

    public var description: String {
      let transport = switch self.transport {
      case .awaitingFirstKexInit: "awaiting the server's KEXINIT"
      case .initialExchange(let stage, let strict): "initial key exchange, \(stage)\(strict ? ", strict" : "")"
      case .established: "established"
      case .rekeyRequested: "re-exchange requested"
      case .reexchange(let stage): "key re-exchange, \(stage)"
      }
      return switch self.transport {
      case .awaitingFirstKexInit, .initialExchange: transport
      default: "\(transport), \(service)"
      }
    }
  }

  /// The layer that handles an accepted message.
  public enum Route: Sendable, Hashable {
    /// The transport: DISCONNECT, IGNORE, DEBUG, UNIMPLEMENTED, EXT_INFO, KEXINIT, NEWKEYS, the exchange's reply,
    /// and the global requests (80-82).
    case transport
    /// The layers above: SERVICE_ACCEPT, userauth (50-79), channels (90-100).
    case service
  }

  /// The route for `number` in `context`, or nil when the phase does not accept it.
  public static func route(for number: MessageNumber, in context: Context) -> Route? {
    if number == .disconnect { return .transport }
    switch context.transport {
    case .awaitingFirstKexInit:
      return [.ignore, .debug, .kexInit].contains(number) ? .transport : nil
    case .initialExchange(let stage, let strict):
      if !strict && (number == .ignore || number == .debug) { return .transport }
      return number == expected(stage) ? .transport : nil
    case .reexchange(let stage):
      if [.ignore, .debug, .unimplemented].contains(number) { return .transport }
      return number == expected(stage) ? .transport : nil
    case .established, .rekeyRequested:
      if [.ignore, .debug, .unimplemented, .kexInit].contains(number) { return .transport }
      if number == .extInfo { return extInfoAccepted(in: context) ? .transport : nil }
      // Global requests are the transport's: it sends the keepalives these answer (checking one is outstanding),
      // and refuses the server's own requests, which RFC 4254 allows only after authentication.
      if number == .requestSuccess || number == .requestFailure { return .transport }
      if number == .globalRequest { return context.service == .connection ? .transport : nil }
      guard serviceAccepts(number, context.service) else { return nil }
      return !context.extInfoBeforeSuccess || number == .userauthSuccess ? .service : nil
    }
  }

  /// `route`, or the protocol error that ends the connection.
  public static func check(_ number: MessageNumber, in context: Context) throws(SSHError) -> Route {
    if let route = route(for: number, in: context) { return route }
    if number == .extInfo && context.extInfoReceived >= Limits.extInfoMessages {
      throw .protocolViolation(.tooManyExtInfo)
    }
    throw .protocolViolation(.unexpectedMessage(number, context))
  }

  /// Strict key exchange: once the server's first KEXINIT shows both sides signalled it, that KEXINIT must have been
  /// the first packet received (`sequence` 0), so an IGNORE or DEBUG accepted before it is refused after all.
  public static func checkFirstKexInit(sequence: UInt32, strict: Bool) throws(SSHError) {
    guard !strict || sequence == 0 else { throw .protocolViolation(.strictKeyExchange) }
  }

  private static func expected(_ stage: KeyExchangeStage) -> MessageNumber {
    switch stage {
    case .awaitingReply: .kexECDHReply
    case .awaitingNewKeys: .newKeys
    }
  }

  /// As the first packet after the server's first NEWKEYS, and while a userauth request is outstanding unless one
  /// already came there (it precedes USERAUTH_SUCCESS); never more than `Limits.extInfoMessages`.
  private static func extInfoAccepted(in context: Context) -> Bool {
    guard context.extInfoReceived < Limits.extInfoMessages, !context.extInfoBeforeSuccess else { return false }
    switch context.service {
    case .serviceNotRequested, .serviceRequested:
      return context.firstPacketAfterNewKeys && context.extInfoReceived == 0
    case .userauth(let wait):
      return wait != .idle
    case .connection:
      return false
    }
  }

  private static func serviceAccepts(_ number: MessageNumber, _ phase: ServicePhase) -> Bool {
    switch phase {
    case .serviceNotRequested:
      return false
    case .serviceRequested:
      return number == .serviceAccept
    case .userauth(let wait):
      // RFC 4252 §5.4: a banner may come any time before USERAUTH_SUCCESS.
      if number == .userauthBanner { return true }
      guard wait != .idle else { return false }
      if number == .userauthFailure || number == .userauthSuccess { return true }
      guard number.rawValue == 60 else { return false }
      return wait == .password || wait == .publicKeyQuery || wait == .keyboardInteractive
    case .connection:
      return (90...100).contains(number.rawValue)
    }
  }
}
