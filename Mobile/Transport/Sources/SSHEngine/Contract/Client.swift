/// The engine's top-level facade: what MobileTransport's Swift engine (`SwiftEngine`) calls where the russh engine calls
/// the C ABI. Declared here as the contract; the async driver that implements it (`ConnectionDriver` in Client/,
/// reached through `SSHClient.connector()`) owns one connection's state and its I/O, timers and callbacks, and runs
/// the sans-I/O core (transport, auth, connection) on that single owner.
///
/// | C ABI (`dispatch_mobile_ssh.h`) | Here |
/// | --- | --- |
/// | `dms_connect` + `dms_connect_options` | `SSHConnector.connect(_:trust:)` + `ConnectOptions` |
/// | `host_key` callback + `dms_reply_bool` later | `HostKeyTrust` (async, may take as long as the user needs) |
/// | `connected` with a code | the returned session, or the thrown `SSHError` |
/// | `disconnected`, exactly once per connected session | `SSHSession.ended()` (one reason, decided once) |
/// | `dms_session_close` / `dms_session_free` | `SSHSession.close()` / releasing the session (closes it too) |
/// | `dms_auth_password`, `_key`, `_signer`, `_keyboard_interactive` (`direct`) | `authenticate(user:with:)`, `Credential` |
/// | `dms_auth_fn` code, `remaining_methods`, `partial` | `AuthOutcome` or the thrown `SSHError` |
/// | `dms_exec` + `exited` kinds (incl. `DMS_EXIT_REFUSED`) | `exec(_:)`, `ExecChannel`, `ChannelExit` |
/// | `dms_shell_open`, `dms_shell_resize` | `shell(term:size:)`, `ShellChannel.resize` |
/// | `keepalive_interval_ms`, `keepalive_max` | `ConnectOptions.keepaliveInterval`, `.keepaliveCountMax` |
/// | `dms_key_parse` | `KeyFile.parse(_:passphrase:)` (Keys/): a `FileKey`, a `UserKey`, from a key file |
public protocol SSHConnector: Sendable {
  /// Connects to `options.host`:`options.port`, exchanges versions and keys, and asks `trust` about the host key
  /// (once; the handshake deadline pauses while it decides). Returns once the first exchange completed with a trusted
  /// key; nothing past the key exchange is sent before. Throws the connect's failure (`hostNotFound` ... `noAnswer`,
  /// `timedOut(.lookup / .handshake)`, `hostKeyRejected`, `protocolViolation`, `closed`, `cancelled` when the task
  /// was cancelled, which also cancels a pending `trust`). A failed connect has no session and no `ended()`.
  func connect(_ options: ConnectOptions, trust: @escaping HostKeyTrust) async throws(SSHError) -> any SSHSession
}

/// One connection. Operations on a session that ended throw `SSHError.closed(.alreadyEnded)`; `ended()` has why.
public protocol SSHSession: Sendable {
  /// The trusted host key (the first exchange's; every re-exchange matched it).
  var hostKey: HostKey { get }

  /// One login attempt as `user` (UTF-8). Attempts run one at a time (`usage(.authenticationInProgress)`); after a
  /// success `usage(.alreadyAuthenticated)`. Returns how the server answered; throws when it did not: `cancelled` (a
  /// signer declined, a prompt was cancelled), `timedOut(.directAnswer)`, `closed`, `protocolViolation`. Cancelling
  /// the task while the engine waits for the signer or a prompt withdraws the question and sends nothing more for the
  /// attempt (the session stays usable); cancelling it once the request is on the wire ends the connection
  /// (`cancelled`), since a late answer could not be told from the next attempt's.
  func authenticate(user: String, with credential: Credential) async throws(SSHError) -> AuthOutcome

  /// Runs `command` on a new session channel (`ExecChannel`). Needs a successful login (`usage(.notAuthenticated)`).
  /// Throws `channelOpenFailed` when the server refuses the channel, `protocolViolation(.channel(
  /// .maximumPacketTooSmall))` when it announces a maximum packet size below `Limits.peerMinimumPacket`.
  func exec(_ command: String) async throws(SSHError) -> any ExecChannel

  /// Opens a login shell on a PTY of `term` and `size` (`ShellChannel`). Throws as `exec`, and `requestRefused` for a
  /// refused `pty-req` or `shell`.
  func shell(term: String, size: TerminalSize) async throws(SSHError) -> any ShellChannel

  /// Sends DISCONNECT (by application) and ends the connection: `ended()` is `closed(.byClient)` unless it had already
  /// ended for another reason. Returns once the stream is closed. Idempotent.
  func close() async

  /// Why the connection ended; returns once it has (a loss, a keepalive timeout, the server's DISCONNECT, a protocol
  /// violation, a host key change at a re-exchange, `close`). The first cause wins and never changes, so every caller
  /// gets the same value: the C ABI's exactly-once `disconnected`.
  func ended() async -> SSHError
}

/// How to connect (`dms_connect_options`).
public struct ConnectOptions: Sendable, Hashable {
  public var host: String
  public var port: UInt16
  /// TCP, version exchange and key exchange, excluding the time the trust callback takes (`timeout_ms`).
  public var handshakeTimeout: Duration
  /// A keepalive after this much silence from the server; nil for none (`keepalive_interval_ms` 0). The timer starts
  /// once logged in (no keepalive before: RFC 4252 §6), as russh and OpenSSH's client do.
  public var keepaliveInterval: Duration?
  /// Unanswered keepalives the connection tolerates, at most `Limits.keepaliveCountMax`. A keepalive falls due after
  /// each `keepaliveInterval` of silence; when one falls due while `keepaliveCountMax` are already unanswered, the
  /// connection ends (`SSHError.timedOut(.keepalive)`) instead. So a silent server is given up after
  /// (`keepaliveCountMax` + 1) × `keepaliveInterval` (15 s × 3: 60 s), as the russh engine did and as OpenSSH's
  /// `ServerAliveCountMax` works; MobileTransport's tests rely on that timing. Any packet from the server resets the
  /// count.
  public var keepaliveCountMax: Int
  /// How long a direct public key request waits for its answer (tests shorten it).
  public var directAnswer: Duration
  /// The algorithms offered, in order (tests restrict them).
  public var algorithms: AlgorithmPolicy.Preferences

  public init(host: String, port: UInt16 = 22, handshakeTimeout: Duration = .seconds(15),
              keepaliveInterval: Duration? = .seconds(15), keepaliveCountMax: Int = 3,
              directAnswer: Duration = Limits.directAnswer, algorithms: AlgorithmPolicy.Preferences = .standard) {
    self.host = host
    self.port = port
    self.handshakeTimeout = handshakeTimeout
    self.keepaliveInterval = keepaliveInterval
    self.keepaliveCountMax = keepaliveCountMax
    self.directAnswer = directAnswer
    self.algorithms = algorithms
  }

  /// Throws `SSHError.usage(.invalidArgument)` for options the engine refuses: an empty host, port 0, a timeout,
  /// interval or answer deadline that is not positive, a keepalive count outside 1...`Limits.keepaliveCountMax` (with
  /// keepalives on), an empty algorithm list, or CTR ciphers without a MAC.
  public func validate() throws(SSHError) {
    func invalid(_ what: String) -> SSHError { .usage(.invalidArgument(what)) }
    guard !host.isEmpty else { throw invalid("an empty host") }
    guard port != 0 else { throw invalid("port 0") }
    guard handshakeTimeout > .zero, directAnswer > .zero else { throw invalid("a deadline that is not positive") }
    if let keepaliveInterval {
      guard keepaliveInterval > .zero else { throw invalid("a keepalive interval that is not positive") }
      guard (1...Limits.keepaliveCountMax).contains(keepaliveCountMax) else { throw invalid("the keepalive count") }
    }
    guard !algorithms.keyExchange.isEmpty, !algorithms.hostKey.isEmpty, !algorithms.cipher.isEmpty else {
      throw invalid("an empty algorithm list")
    }
    guard algorithms.cipher.allSatisfy(\.isAEAD) || !algorithms.mac.isEmpty else {
      throw invalid("a CTR cipher without a MAC")
    }
  }
}
