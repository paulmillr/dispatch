/// The whole client protocol as one synchronous state machine: the transport (`ClientTransport`), the userauth service
/// (`UserauthCore`, from the first exchange on) and the connection protocol (`ConnectionCore`, from the login on),
/// wired together. Sans-I/O and single-owner like its parts: bytes, timer firings, answers and the app's requests in;
/// events, timer requests and sealed bytes out. No sockets, clocks, tasks or callbacks, so tests and a fuzzer drive it
/// in memory exactly as the driver does.
///
/// Driving it: after every call, drain `poll` until nil, then write `takeOutbound()` (taking it also lets the channels
/// queue what waited for the backlog, so call it again after each write until it is empty). Stop reading the stream
/// while `readsPaused`. Each input call runs the parts to quiescence itself: the transport is polled with the upper
/// layers' current phase before every packet (`servicePhase`), each delivered message goes to the auth core before
/// the login and to the connection core after it, the auth core hears of every transport event until logged in (an
/// RSA key waits for the server's extensions), and every part's own events are drained into `poll`'s queue in order.
///
/// Invariants:
/// - `.ended` is emitted exactly once and last; every input after it is ignored, every request throws
///   `closed(.alreadyEnded)`. A login in progress ends (`.authFinished(.failure)`) and every channel ends (`.closed`
///   or `.openFailed`) before it.
/// - `.hostKeyNeedsTrust` comes at most once, before `.established`; nothing past the key exchange is sent before
///   `answerHostKey(trusted: true)`.
/// - Each `authenticate` that did not throw ends with one `.authFinished`; each `openExec`/`openShell` that did not
///   throw with one `.openFailed`, or `.opened` and later one `.closed`.
/// - Nothing here traps on server data: the parts turn every violation into the connection's end.
public final class ClientCore {
  private let transport: ClientTransport
  private let directAnswer: Duration
  private var auth: UserauthCore?
  private var connection: ConnectionCore?
  private var events: [ClientEvent] = []
  private var eventStart = 0
  /// The connection's end, once `.ended` was queued.
  public private(set) var endedWith: SSHError?
  private var started = false

  /// `options` supplies the algorithms, keepalive and direct-answer settings (validated: `ConnectOptions.validate`'s
  /// error is thrown); host, port and the handshake deadline are the driver's.
  public init(options: ConnectOptions, verifier: any HostKeySignatureVerifier, random: any RandomSource)
    throws(SSHError)
  {
    transport = try ClientTransport(options: options, verifier: verifier, random: random)
    directAnswer = options.directAnswer
  }

  // MARK: State

  /// The first exchange completed with a trusted key (`.established` was emitted).
  public private(set) var isEstablished = false
  /// The login succeeded: channels may open.
  public var isAuthenticated: Bool { auth?.isAuthenticated ?? false }
  /// A login attempt started and not yet finished.
  public var isAuthenticating: Bool { auth?.isAttemptInProgress ?? false }
  /// The trusted host key; meaningful once `.established` was emitted.
  public var hostKey: HostKey { transport.hostKey }
  /// The first exchange's hash; empty before it.
  public var sessionID: [UInt8] { transport.sessionID }
  /// Bytes queued for the stream and not taken yet.
  public var outboundBacklog: Int { transport.outboundBacklog }
  /// Whether the driver should stop reading the stream: the outbound backlog is over twice
  /// `Limits.outboundBacklogBytes`. The channels stop taking the app's writes at the limit itself (one packet past it
  /// at most), so the app's own uploads never pause the downloads; only what the server makes the client answer
  /// (window adjusts, refusals, keepalive replies) can push the backlog this far, and a server that does so faster
  /// than it reads must not grow the client's memory.
  public var readsPaused: Bool { transport.outboundBacklog > 2 * Limits.outboundBacklogBytes }
  /// Channels holding a number (open, opening, or closed by us and waiting for the server's close).
  public var channelCount: Int { connection?.channelCount ?? 0 }
  /// The upper layers' phase, as the transport's policy checks the next packet against it.
  public var servicePhase: MessagePolicy.ServicePhase {
    guard let auth else { return .serviceNotRequested }
    return auth.servicePhase
  }

  // MARK: The stream and the clock

  /// Queues the identification line and the first KEXINIT. Called once, first.
  public func start() {
    guard !started else { return }
    started = true
    transport.start()
    pump()
  }

  /// Bytes read from the stream, in order.
  public func receive(_ bytes: [UInt8]) {
    guard endedWith == nil else { return }
    transport.receive(bytes)
    pump()
  }

  /// The stream reached its end: what is buffered is still delivered, then the connection ends
  /// (`closed(.connectionLost)`) unless it already had.
  public func receiveEnd() {
    guard endedWith == nil else { return }
    transport.receiveEnd()
    pump()
  }

  /// A timer this core asked for (`.timer(.schedule(...))`) fired. Stale firings do nothing.
  public func timerFired(_ timer: CoreTimer) {
    guard endedWith == nil else { return }
    switch timer {
    case .directAnswer:
      auth?.timerFired(timer)
      drainAuth()
    case .keepalive, .rekey:
      transport.timerFired(timer)
    }
    pump()
  }

  /// Ends the connection for `error` (the client closes: `closed(.byClient)`; the stream failed; a deadline the
  /// driver owns passed; the connect was cancelled). DISCONNECT is queued unless the error says the stream is gone.
  /// The first end wins.
  public func end(_ error: SSHError) {
    guard endedWith == nil else { return }
    transport.end(error)
    pump()
  }

  /// Everything queued for the stream, sealed, in order. Taking it empties the transport's backlog, so the channels
  /// then queue what waited for room (and writers may get `.writable`): poll, and take again after the write.
  public func takeOutbound() -> [UInt8] {
    let bytes = transport.takeOutbound()
    if !bytes.isEmpty, endedWith == nil, let connection {
      connection.transportDrained()
      drainConnection()
      pump()
    }
    return bytes
  }

  // MARK: The host key

  /// The trust decision for `.hostKeyNeedsTrust`'s key: yes sends NEWKEYS and goes on, no ends the connection
  /// (`hostKeyRejected`). Ignored unless the question is open.
  public func answerHostKey(trusted: Bool) {
    guard endedWith == nil else { return }
    transport.answerHostKey(trusted: trusted)
    pump()
  }

  // MARK: Logins

  /// Starts one login attempt (`UserauthCore.start`): `.sign` and `.prompt` ask for what takes time, `.authFinished`
  /// ends it. Throws, starting nothing: `closed(.alreadyEnded)` after the end, `usage(.invalidArgument)` before the
  /// first exchange, and `UserauthCore.start`'s errors.
  public func authenticate(user: String, credential: Credential) throws(SSHError) {
    guard endedWith == nil else { throw .closed(.alreadyEnded) }
    guard let auth else { throw .usage(.invalidArgument("a login before the key exchange completed")) }
    try auth.start(user: user, credential: credential)
    drainAuth()
    pump()
  }

  /// The signature for `.sign(question, ...)` (a `SignatureBlob`).
  public func signed(_ question: AuthQuestion, signature: [UInt8]) {
    guard endedWith == nil, let auth else { return }
    auth.signed(question, signature: signature)
    drainAuth()
    pump()
  }

  /// The signer did not sign (`cancelled` when declined): the attempt ends with `error`, the session stays usable.
  public func signingFailed(_ question: AuthQuestion, error: SSHError) {
    guard endedWith == nil, let auth else { return }
    auth.signingFailed(question, error: error)
    drainAuth()
    pump()
  }

  /// The answers for `.prompt(question, ...)`, or nil to cancel.
  public func answered(_ question: AuthQuestion, with answers: [SecretBytes]?) {
    guard endedWith == nil, let auth else { return }
    auth.answered(question, with: answers)
    drainAuth()
    pump()
  }

  /// The attempt's task was cancelled (`UserauthCore.cancel`): before its request is on the wire the attempt ends
  /// with `cancelled` and the session stays usable; once it waits for the server's answer the connection ends.
  public func cancelAuthentication() {
    guard endedWith == nil, let auth else { return }
    auth.cancel()
    drainAuth()
    pump()
  }

  // MARK: Channels

  /// Opens an exec channel (`ConnectionCore.openExec`). Throws `closed(.alreadyEnded)`, `usage(.notAuthenticated)`,
  /// and the connection core's errors.
  public func openExec(_ command: String) throws(SSHError) -> ChannelID {
    let connection = try openableConnection()
    let id = try connection.openExec(command)
    drainConnection()
    pump()
    return id
  }

  /// Opens a login shell on a PTY (`ConnectionCore.openShell`). Throws as `openExec`.
  public func openShell(term: String, size: TerminalSize) throws(SSHError) -> ChannelID {
    let connection = try openableConnection()
    let id = try connection.openShell(term: term, size: size)
    drainConnection()
    pump()
    return id
  }

  /// `ConnectionCore.write`: how many bytes of `bytes` the channel took (fewer: wait for `.writable` or its end).
  public func write(_ bytes: some Collection<UInt8>, to id: ChannelID) throws(SSHError) -> Int {
    if let endedWith { throw endedWith }
    guard let connection else { throw .usage(.channelClosed) }
    let taken = try connection.write(bytes, to: id)
    drainConnection()
    pump()
    return taken
  }

  /// The app read `count` bytes of the channel's output: the window is granted back as it reads.
  public func consumed(_ count: Int, on id: ChannelID) {
    guard endedWith == nil, let connection else { return }
    connection.consumed(count, on: id)
    drainConnection()
    pump()
  }

  /// EOF after what the channel took (an exec's end of input).
  public func finishInput(_ id: ChannelID) {
    guard endedWith == nil, let connection else { return }
    connection.finishInput(id)
    drainConnection()
    pump()
  }

  /// Closes the channel; its app side ends at once (`.closed` or `.openFailed(cancelled)`).
  public func closeChannel(_ id: ChannelID) {
    guard endedWith == nil, let connection else { return }
    connection.close(id)
    drainConnection()
    pump()
  }

  /// A `window-change` for a shell (the latest wins; none for the size in effect).
  public func resize(_ id: ChannelID, to size: TerminalSize) throws(SSHError) {
    guard endedWith == nil, let connection else { throw .usage(.channelClosed) }
    try connection.resize(id, to: size)
    drainConnection()
    pump()
  }

  // MARK: Output

  /// The next event, in order; nil when none is queued. Drain after every call.
  public func poll() -> ClientEvent? {
    guard eventStart < events.count else { return nil }
    let event = events[eventStart]
    eventStart += 1
    if eventStart == events.count {
      events.removeAll(keepingCapacity: true)
      eventStart = 0
    }
    return event
  }

  // MARK: Test hooks

  /// The transport's re-exchange thresholds (tests lower them to make the client start re-exchanges under load).
  func setRekeyThresholds(bytes: UInt64? = nil, packets: UInt64? = nil, interval: Duration? = nil) {
    if let bytes { transport.thresholds.bytes = bytes }
    if let packets { transport.thresholds.packets = packets }
    if let interval { transport.thresholds.interval = interval }
  }

  /// Keepalives sent and not answered yet.
  var keepalivesOutstanding: Int { transport.keepalivesOutstanding }

  /// The algorithms of the last exchange (tests check what a real server negotiated).
  var negotiated: NegotiatedAlgorithms? { transport.negotiated }

  /// Bytes received and not decoded yet.
  var inboundBuffered: Int { transport.inboundBuffered }

  // MARK: Wiring

  private func openableConnection() throws(SSHError) -> ConnectionCore {
    guard endedWith == nil else { throw .closed(.alreadyEnded) }
    guard isAuthenticated, let connection else { throw .usage(.notAuthenticated) }
    return connection
  }

  private func emit(_ event: ClientEvent) {
    guard endedWith == nil else { return }
    events.append(event)
  }

  /// Polls the transport until it has nothing more, routing each event, with the phase recomputed before every poll.
  private func pump() {
    guard endedWith == nil else { return }
    while endedWith == nil, let event = transport.poll(service: servicePhase) {
      handle(event)
      if endedWith == nil, let auth, !auth.isAuthenticated {
        auth.linkProgressed()
        drainAuth()
      }
    }
  }

  private func handle(_ event: TransportEvent) {
    switch event {
    case .hostKeyNeedsTrust(let key):
      emit(.hostKeyNeedsTrust(key))
    case .established:
      guard !isEstablished else { return }
      isEstablished = true
      auth = UserauthCore(link: transport, directAnswer: directAnswer)
      emit(.established)
    case .rekeyed:
      emit(.rekeyed)
    case .message(let message):
      deliver(message)
    case .timer(let request):
      emit(.timer(request))
    case .ended(let error):
      finish(error)
    }
  }

  private func deliver(_ message: InboundMessage) {
    guard let auth else {
      // The policy delivers nothing to the layers above before the first exchange; refuse it rather than trust that.
      transport.end(.protocolViolation(.unexpectedMessage(message.number, MessagePolicy.Context(transport: .established))))
      return
    }
    if auth.isAuthenticated {
      let connection = connectionCore()
      connection.receive(message)
      drainConnection()
    } else {
      auth.receive(message)
      drainAuth()
    }
  }

  private func connectionCore() -> ConnectionCore {
    if let connection { return connection }
    let created = ConnectionCore(link: transport)
    connection = created
    return created
  }

  private func drainAuth() {
    guard let auth else { return }
    while let event = auth.poll() {
      switch event {
      case .sign(let question, let data, let algorithm):
        emit(.sign(question, data: data, algorithm: algorithm))
      case .prompt(let question, let challenge):
        emit(.prompt(question, challenge))
      case .timer(let request):
        emit(.timer(request))
      case .finished(let result):
        // The connection core exists before the next packet is polled: it is routed there.
        if case .success(.success) = result, auth.isAuthenticated { _ = connectionCore() }
        emit(.authFinished(result))
      }
    }
  }

  private func drainConnection() {
    guard let connection else { return }
    // Events of one call into the connection core: if that call ended the connection, its closes are the end's.
    let ending = connection.endedWith
    while let event = connection.poll() {
      switch event {
      case .opened(let id): emit(.opened(id))
      case .openFailed(let id, let error): emit(.openFailed(id, error))
      case .data(let id, let bytes): emit(.output(id, .stdout(bytes)))
      case .stderr(let id, let bytes): emit(.output(id, .stderr(bytes)))
      case .eof(let id): emit(.eof(id))
      case .closed(let id, let exit): emit(.closed(id, exit, lostWith: ending))
      case .writable(let id): emit(.writable(id))
      }
    }
  }

  /// The transport ended: the login and the channels end first, then `.ended`, last.
  private func finish(_ error: SSHError) {
    guard endedWith == nil else { return }
    auth?.connectionEnded(error)
    drainAuth()
    connection?.connectionEnded(error)
    drainConnection()
    emit(.ended(error))
    endedWith = error
  }
}

/// What the composed core tells its driver, in order.
public enum ClientEvent: Sendable, Equatable {
  /// The first exchange's host key, its signature verified: answer `answerHostKey(trusted:)`. At most once. The
  /// handshake deadline pauses until the answer.
  case hostKeyNeedsTrust(HostKey)
  /// The first exchange completed with a trusted key: logins may start. The handshake is over.
  case established
  /// A re-exchange completed with the pinned key.
  case rekeyed
  /// Run or cancel a timer (`.keepalive`, `.rekey`, `.directAnswer`; one per kind, `schedule` replaces); its firing
  /// goes to `timerFired`.
  case timer(TimerRequest)
  /// Sign `data` with the current attempt's key and `algorithm`, then `signed` or `signingFailed`.
  case sign(AuthQuestion, data: [UInt8], algorithm: SignatureAlgorithm)
  /// Ask the current attempt's responder, then `answered`.
  case prompt(AuthQuestion, KeyboardInteractiveChallenge)
  /// The login attempt ended: the server's answer, or why there was none.
  case authFinished(Result<AuthOutcome, SSHError>)
  /// The channel is the app's (an exec once its request was sent, a shell once both requests were confirmed).
  case opened(ChannelID)
  /// The channel did not open; its last event.
  case openFailed(ChannelID, SSHError)
  /// Output in arrival order (a shell's is always `.stdout`). Report what the app read with `consumed`.
  case output(ChannelID, ChannelOutput)
  /// The server sent EOF: no more output.
  case eof(ChannelID)
  /// The channel ended for the app; its last event. `lostWith` is the connection's end when that is what ended it
  /// (nil for the server's CLOSE, a refused exec or the app's close).
  case closed(ChannelID, ChannelExit, lostWith: SSHError?)
  /// A write that took less than offered may go on.
  case writable(ChannelID)
  /// The connection ended: exactly once, last. `takeOutbound` may still hold a DISCONNECT to write before closing.
  case ended(SSHError)
}
