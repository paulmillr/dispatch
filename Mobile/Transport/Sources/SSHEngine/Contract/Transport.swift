/// The transport as the layers above it see it (Auth/ and Connection/ code against this; their tests use a fake,
/// `FakeTransportLink`).
/// Synchronous and single-owner: every call happens on the core's owner, between two driver steps. The layers above
/// exist only once the first exchange finished (`TransportEvent.established`), so `sessionID` and `hostKey` are
/// always valid here.
///
/// Re-exchanges as seen from above: nothing changes but latency. `send` keeps working; while an exchange runs the
/// payloads wait unencrypted, in order, and leave under the new keys (RFC 4253 §7.1). No message for the layers above
/// is delivered mid-exchange (`MessagePolicy`). The session id, host key and extensions never change; a re-exchange
/// with another host key ends the connection (`SSHError.hostKeyChangedAtRekey`).
public protocol TransportLink: AnyObject {
  /// The first exchange's hash `H`, for the connection's life (RFC 4253 §7.2): what userauth signatures cover.
  var sessionID: [UInt8] { get }
  /// The trusted host key (the pin every re-exchange is held to).
  var hostKey: HostKey { get }
  /// nil until the first packet after the server's first NEWKEYS arrived (RFC 8308 puts EXT_INFO there, so then it
  /// is known whether one came); then the extensions, empty if none. A second EXT_INFO (before USERAUTH_SUCCESS)
  /// updates it. An RSA signature waits for this to be non-nil (`ServerExtensions.rsaAlgorithm`), which costs no round
  /// trip: the server sends it right behind its NEWKEYS.
  var serverExtensions: ServerExtensions? { get }
  /// Bytes queued for the stream that the driver has not taken yet, payloads held for a re-exchange included. The
  /// channel layer takes no more of the app's writes while this is above `Limits.outboundBacklogBytes`.
  var outboundBacklog: Int { get }
  /// False once the connection ended or is ending: `send` throws from then on.
  var isOpen: Bool { get }

  /// Queues one payload (message number first). The layers above may send SERVICE_REQUEST (5), userauth (50-79) and
  /// channel messages (90-127) only (global requests are the transport's); anything else, or a payload too large for
  /// one packet, throws `SSHError.usage(.invalidArgument)`. After the end it throws `.closed(.alreadyEnded)`.
  func send(_ payload: [UInt8]) throws(SSHError)

  /// `send` for a payload holding a secret (a password request, keyboard-interactive answers): the transport wipes
  /// every plaintext copy it makes once the packet is sealed.
  func send(secret payload: SecretBytes) throws(SSHError)

  /// Ends the connection because of `error` (a layer above found a protocol violation, or the client closes): queues
  /// DISCONNECT with `error.disconnectReason` and no description, sends and delivers nothing more, and reports
  /// `TransportEvent.ended(error)`. The first end wins; later calls change nothing.
  func end(_ error: SSHError)
}

/// One inbound payload the policy routed to the layers above.
public struct InboundMessage: Sendable, Equatable {
  public let number: MessageNumber
  /// The whole payload, the number first.
  public let payload: [UInt8]

  /// nil for an empty payload (the transport never delivers one).
  public init?(payload: [UInt8]) {
    guard let first = payload.first else { return nil }
    number = MessageNumber(first)
    self.payload = payload
  }

  /// Decodes the fields after the number: `body` reads them, then the payload must be at its end. A `WireError`
  /// becomes `ProtocolViolation.malformed(number, error)`.
  public func decode<T>(_ body: (inout WireReader) throws(WireError) -> T) throws(SSHError) -> T {
    do {
      var reader = WireReader(payload)
      _ = try reader.readByte()
      let value = try body(&reader)
      try reader.expectEnd()
      return value
    } catch {
      throw .protocolViolation(.malformed(number, error))
    }
  }
}

/// What the server announced in EXT_INFO (RFC 8308).
public struct ServerExtensions: Sendable, Hashable {
  /// Every extension, by name, its value as sent (within `Limits`). A later EXT_INFO's value replaces an earlier one.
  public var values: [String: [UInt8]]

  public init(values: [String: [UInt8]] = [:]) { self.values = values }

  public static let serverSignatureAlgorithmsName = "server-sig-algs"

  /// `server-sig-algs` as a name-list, unknown names included; nil when absent or not a valid name-list.
  public var serverSignatureAlgorithms: [String]? {
    guard let value = values[Self.serverSignatureAlgorithmsName] else { return nil }
    // The value is the list's bytes, without a length prefix of its own (as OpenSSH sends it).
    if value.isEmpty { return [] }
    var names: [String] = []
    for element in value.split(separator: UInt8(ascii: ","), omittingEmptySubsequences: false) {
      guard names.count < Limits.nameListCount, let name = WireReader.name(element) else { return nil }
      names.append(name)
    }
    return names
  }

  /// The algorithm an RSA user key signs with: rsa-sha2-256 when `server-sig-algs` lists it and not rsa-sha2-512,
  /// else rsa-sha2-512 (never ssh-rsa), as the russh engine chose.
  public var rsaAlgorithm: SignatureAlgorithm {
    guard let names = serverSignatureAlgorithms else { return .rsaSHA512 }
    return names.contains(SignatureAlgorithm.rsaSHA256.rawValue) && !names.contains(SignatureAlgorithm.rsaSHA512.rawValue)
      ? .rsaSHA256 : .rsaSHA512
  }
}

/// Timers the core asks the driver to run: the core has no clock. One timer per kind; `schedule` replaces a pending
/// one of the same kind. The handshake deadline is the driver's own (it spans the TCP connect and pauses while the
/// trust callback decides).
public enum CoreTimer: Sendable, Hashable {
  /// Silence before the next keepalive (`ConnectOptions.keepaliveInterval`); the transport reschedules it whenever a
  /// packet arrives (which also clears the unanswered count). When it fires with `keepaliveCountMax` keepalives already
  /// unanswered the connection ends (`timedOut(.keepalive)`); otherwise one more is sent and it is scheduled again.
  case keepalive
  /// Time-based re-exchange (`Limits.rekeyInterval`).
  case rekey
  /// A direct public key request's answer (`ConnectOptions.directAnswer`), from when it was sent.
  case directAnswer
}

public enum TimerRequest: Sendable, Equatable {
  case schedule(CoreTimer, after: Duration)
  case cancel(CoreTimer)
}

/// The transport's driving side (T implements it in Transport/; the composed client core drives it): version exchange,
/// framing, the message policy, key exchanges with the host key's trust and pin, EXT_INFO, keepalive (it owns
/// `keepalive@openssh.com` and the replies to it, and refuses the server's global requests), re-exchanges.
/// Sans-I/O: bytes and timer firings in, events and bytes out; no sockets, clocks or tasks. Every failure surfaces
/// as `TransportEvent.ended`, never as a throw.
public protocol TransportCore: TransportLink {
  /// Queues the identification line and the first KEXINIT. Called once, first.
  func start()

  /// Bytes read from the stream, in order. The owner then calls `poll` until it returns nil. Bytes beyond what
  /// `Limits.inboundBufferBytes` allows end the connection (`.packet(.bufferOverflow)`).
  func receive(_ bytes: [UInt8])

  /// The stream reached its end (EOF): pending events drain, then `ended(.closed(.connectionLost))` unless a
  /// DISCONNECT already ended it.
  func receiveEnd()

  /// The next event, decoding at most one packet. `service` is the upper layers' phase now: the policy checks the
  /// next packet against it, and it may change after each delivered message, hence one event at a time.
  func poll(service: MessagePolicy.ServicePhase) -> TransportEvent?

  /// The trust callback's answer for the key of `hostKeyNeedsTrust`. The client's NEWKEYS, and everything after it,
  /// is sent only once this said yes; no ends the connection with `SSHError.hostKeyRejected`.
  func answerHostKey(trusted: Bool)

  /// A timer this core scheduled fired (`.keepalive`, `.rekey`).
  func timerFired(_ timer: CoreTimer)

  /// Everything queued for the stream, sealed, in order; empty when nothing is. The driver writes it as one chunk.
  func takeOutbound() -> [UInt8]
}

public enum TransportEvent: Sendable, Equatable {
  /// The first exchange's host key, its signature verified. Exactly once, only for the first exchange.
  case hostKeyNeedsTrust(HostKey)
  /// The first exchange completed both ways with a trusted key: the layers above may start.
  case established
  /// A re-exchange completed with the pinned key.
  case rekeyed
  /// A message for the layers above, already checked by the policy against the phase given to `poll`.
  case message(InboundMessage)
  case timer(TimerRequest)
  /// The connection ended. Exactly once and last: `poll` returns nil afterwards. `takeOutbound` may still hold a
  /// DISCONNECT for the driver to write before it closes the stream.
  case ended(SSHError)
}

extension SSHError {
  /// The reason code a DISCONNECT the client sends for this error carries.
  public var disconnectReason: DisconnectReason {
    switch self {
    case .protocolViolation(.packet(.integrity)): .macError
    case .protocolViolation(.negotiation), .protocolViolation(.keyExchange), .protocolViolation(.strictKeyExchange):
      .keyExchangeFailed
    case .protocolViolation(.version): .protocolVersionNotSupported
    case .protocolViolation: .protocolError
    case .hostKeyRejected, .hostKeyChangedAtRekey: .hostKeyNotVerifiable
    case .cancelled: .authCancelledByUser
    case .timedOut: .connectionLost
    default: .byApplication
    }
  }
}
