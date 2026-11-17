/// Knobs the tests turn; the app uses the defaults.
struct DriverTuning: Sendable {
  /// The most bytes one stream read asks for.
  var readSize = 64 * 1024
  /// How long the last bytes (a DISCONNECT) may take to leave once the connection ended, before the stream is closed
  /// regardless (a peer that stopped reading must not keep a closed session's socket open).
  var disconnectGrace: Duration = .seconds(2)
  /// The transport's re-exchange thresholds, lowered by tests to make the client start re-exchanges under load.
  var rekeyBytes: UInt64?
  var rekeyInterval: Duration?
  /// Called from the driver's deinit (tests: nothing keeps a finished connection alive).
  var released: (@Sendable () -> Void)?
}

/// Counters the tests read (`ConnectionDriver.stats`, `waitForStats`): nothing in the engine acts on them.
struct DriverStats: Sendable, Equatable {
  var reads = 0
  var bytesRead = 0
  var writes = 0
  var bytesWritten = 0
  var rekeys = 0
  var keepalivesFired = 0
  /// Times the read loop waited for the outbound backlog to drain.
  var readPauses = 0
  /// The largest outbound backlog seen after a step (bytes the transport held for the stream).
  var maximumBacklog = 0
  /// The most output one channel held that the app had not read (bounded by the window the engine grants).
  var maximumBufferedOutput = 0
  /// Timer tasks started (a reschedule to a later deadline reuses the sleeping task).
  var timerTasks = 0
  /// The longest single sleep a timer asked for (`ConnectionDriver.sleepSlice` at most).
  var longestSleep: Duration = .zero
  /// Writes that had to wait for the window or the backlog.
  var writeSuspensions = 0
  /// Writes waiting for the window or the backlog, and reads waiting for output, over all channels (updated while a
  /// test waits on the stats).
  var waitingWriters = 0
  var waitingReaders = 0
}

/// One connection's single owner: the composed core, the stream, the timers, the questions to the app, and every
/// operation waiting on them. Everything mutable lives in this actor; the facade objects hold only its reference and
/// a channel handle (a shell's resize mailbox excepted, see `ShellMailbox`).
///
/// Loops: one read loop (reads the stream unless the core says `readsPaused`, feeds the core, processes its events)
/// and one write loop (takes the core's outbound bytes and writes them, one write in flight at a time, so a slow
/// network leaves bytes in the core, whose backlog then stops the channels' writers). Both suspend on the stream or
/// on a continuation, never on a timer, and end when the stream does. Timers are one sleeping task per kind; a
/// reschedule to a later deadline only moves the deadline (the task sleeps again when it wakes), so a keepalive moved
/// on by every packet costs no task per packet.
///
/// The end: decided once, by the core's `.ended` (stream failures, deadlines, cancellation and `close` all go through
/// `ClientCore.end`). Then every timer, question and helper task is cancelled, the write loop writes what is left (a
/// DISCONNECT) within `DriverTuning.disconnectGrace`, and the stream is closed.
actor ConnectionDriver {
  private let options: ConnectOptions
  private let tuning: DriverTuning
  private let core: ClientCore
  private var stream: (any ByteStream)?
  private let clock = ContinuousClock()

  /// Why the connection ended, decided once.
  private(set) var endReason: SSHError?
  private var endedWaiters: [CheckedContinuation<SSHError, Never>] = []
  private var streamBroken = false
  private var streamClosed = false
  private var streamClosing = false
  private var streamClosedWaiters: [CheckedContinuation<Void, Never>] = []

  private(set) var stats = DriverStats()
  private var statWaiters: [(predicate: @Sendable (DriverStats) -> Bool, continuation: CheckedContinuation<DriverStats, Never>)] = []

  init(options: ConnectOptions, random: @Sendable () -> any RandomSource, tuning: DriverTuning) throws(SSHError) {
    self.options = options
    self.tuning = tuning
    core = try ClientCore(options: options, verifier: SSHSignatureVerifier(), random: random())
    if tuning.rekeyBytes != nil || tuning.rekeyInterval != nil {
      core.setRekeyThresholds(bytes: tuning.rekeyBytes, interval: tuning.rekeyInterval)
    }
  }

  deinit { tuning.released?() }

  // MARK: Connecting

  private var trust: HostKeyTrust?
  private var trustTask: Task<Void, Never>?
  private var handshakeDeadline: ContinuousClock.Instant?
  /// The handshake time left while the trust question is open (the deadline pauses).
  private var handshakeRemaining: Duration?
  private var connectOutcome: Result<HostKey, SSHError>?
  private var connectWaiter: CheckedContinuation<Result<HostKey, SSHError>, Never>?

  /// TCP, the version exchange and the first key exchange under `options.handshakeTimeout` (paused while `trust`
  /// decides); returns the trusted host key once the first exchange completed. On failure the stream is closed before
  /// this throws. Cancelling the calling task ends the connect (`cancelled`) and cancels a pending `trust`.
  func connect(using streams: any StreamConnector, trust: @escaping HostKeyTrust) async throws(SSHError) -> HostKey {
    guard !Task.isCancelled else { throw .cancelled }
    let deadline = clock.now.advanced(by: options.handshakeTimeout)
    let stream = try await streams.connect(host: options.host, port: options.port, deadline: deadline)
    guard !Task.isCancelled else {
      await stream.close()
      throw .cancelled
    }
    self.stream = stream
    self.trust = trust
    handshakeDeadline = deadline
    schedule(.handshake, at: deadline)
    core.start()
    Task { await self.readLoop() }
    Task { await self.writeLoop() }
    process()
    let outcome = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Result<HostKey, SSHError>, Never>) in
        if let connectOutcome {
          continuation.resume(returning: connectOutcome)
        } else {
          connectWaiter = continuation
        }
      }
    } onCancel: {
      Task { await self.cancelConnect() }
    }
    switch outcome {
    case .success(let key):
      return key
    case .failure(let error):
      await waitForStreamClosed()
      throw error
    }
  }

  private func cancelConnect() {
    guard connectOutcome == nil else { return }
    core.end(.cancelled)
    process()
  }

  private func askTrust(_ key: HostKey) {
    guard let deadline = handshakeDeadline, let trust else { return }
    let remaining = clock.now.duration(to: deadline)
    guard remaining > .zero else {
      // The deadline passed and its timer has not run yet: the question is never asked after it.
      core.end(.timedOut(.handshake))
      return
    }
    handshakeRemaining = remaining
    cancelTimer(.handshake)
    trustTask = Task {
      let answer = await trust(key)
      self.trustAnswered(answer)
    }
  }

  private func trustAnswered(_ trusted: Bool) {
    guard trustTask != nil, endReason == nil else { return }
    trustTask = nil
    if trusted, let remaining = handshakeRemaining {
      let deadline = clock.now.advanced(by: remaining)
      handshakeDeadline = deadline
      handshakeRemaining = nil
      schedule(.handshake, at: deadline)
    }
    core.answerHostKey(trusted: trusted)
    process()
  }

  private func established() {
    cancelTimer(.handshake)
    handshakeDeadline = nil
    handshakeRemaining = nil
    trust = nil
    resolveConnect(.success(core.hostKey))
  }

  private func resolveConnect(_ outcome: Result<HostKey, SSHError>) {
    guard connectOutcome == nil else { return }
    connectOutcome = outcome
    connectWaiter?.resume(returning: outcome)
    connectWaiter = nil
  }

  // MARK: The session

  /// Ends the connection by the client (DISCONNECT, by application) unless it already ended, and returns once the
  /// stream is closed.
  func close() async {
    if endReason == nil {
      core.end(.closed(.byClient))
      process()
    }
    await waitForStreamClosed()
  }

  /// Why the connection ended; waits until it has.
  func ended() async -> SSHError {
    if let endReason { return endReason }
    return await withCheckedContinuation { continuation in endedWaiters.append(continuation) }
  }

  // MARK: Logins

  private final class Attempt {
    let number: UInt64
    let credential: Credential
    var waiter: CheckedContinuation<Result<AuthOutcome, SSHError>, Never>?
    var result: Result<AuthOutcome, SSHError>?
    /// The signer or responder at work.
    var helper: Task<Void, Never>?

    init(number: UInt64, credential: Credential) {
      self.number = number
      self.credential = credential
    }
  }

  private var attempt: Attempt?
  private var attempts: UInt64 = 0

  func authenticate(user: String, with credential: Credential) async throws(SSHError) -> AuthOutcome {
    guard endReason == nil else { throw .closed(.alreadyEnded) }
    guard attempt == nil else { throw .usage(.authenticationInProgress) }
    try core.authenticate(user: user, credential: credential)
    attempts &+= 1
    let current = Attempt(number: attempts, credential: credential)
    attempt = current
    process()
    let number = current.number
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Result<AuthOutcome, SSHError>, Never>) in
        if let result = current.result {
          continuation.resume(returning: result)
        } else {
          current.waiter = continuation
        }
      }
    } onCancel: {
      Task { await self.cancelAttempt(number) }
    }
    return try result.get()
  }

  private func cancelAttempt(_ number: UInt64) {
    guard let attempt, attempt.number == number else { return }
    attempt.helper?.cancel()
    core.cancelAuthentication()
    process()
  }

  private func sign(_ question: AuthQuestion, data: [UInt8], algorithm: SignatureAlgorithm) {
    guard let attempt, case .publicKey(let key, _) = attempt.credential else {
      core.signingFailed(question, error: .usage(.invalidArgument("a signature for a login without a key")))
      return
    }
    attempt.helper = Task {
      let result: Result<[UInt8], SSHError>
      do throws(SSHError) {
        result = .success(try await key.sign(data, algorithm: algorithm))
      } catch {
        result = .failure(error)
      }
      self.signerAnswered(question, result)
    }
  }

  private func signerAnswered(_ question: AuthQuestion, _ result: Result<[UInt8], SSHError>) {
    switch result {
    case .success(let signature): core.signed(question, signature: signature)
    case .failure(let error): core.signingFailed(question, error: error)
    }
    process()
  }

  private func prompt(_ question: AuthQuestion, _ challenge: KeyboardInteractiveChallenge) {
    guard let attempt, case .keyboardInteractive(let responder) = attempt.credential else {
      core.answered(question, with: nil)
      return
    }
    attempt.helper = Task {
      let answers = await responder(challenge)
      self.promptAnswered(question, answers)
    }
  }

  private func promptAnswered(_ question: AuthQuestion, _ answers: [SecretBytes]?) {
    core.answered(question, with: answers)
    process()
  }

  private func attemptFinished(_ result: Result<AuthOutcome, SSHError>) {
    guard let finished = attempt else { return }
    attempt = nil
    finished.helper?.cancel()
    finished.helper = nil
    finished.result = result
    finished.waiter?.resume(returning: result)
    finished.waiter = nil
  }

  // MARK: Channels

  enum ChannelKind: Sendable { case exec, shell }

  private final class PendingWrite {
    let number: UInt64
    let bytes: [UInt8]
    var offset = 0
    var waiter: CheckedContinuation<Result<Void, SSHError>, Never>?
    var result: Result<Void, SSHError>?

    init(number: UInt64, bytes: [UInt8]) {
      self.number = number
      self.bytes = bytes
    }

    func finish(_ outcome: Result<Void, SSHError>) {
      guard result == nil else { return }
      result = outcome
      waiter?.resume(returning: outcome)
      waiter = nil
    }
  }

  private final class Channel {
    let kind: ChannelKind
    /// The core's number for it while `live`.
    let id: ChannelID
    let mailbox: ShellMailbox?
    /// The core still reports events for `id` to this record (until `.closed` or `.openFailed`).
    var live = true
    var openResult: Result<Void, SSHError>?
    var opener: CheckedContinuation<Result<Void, SSHError>, Never>?

    var output: [ChannelOutput] = []
    var outputStart = 0
    var buffered = 0
    var eof = false
    var closed = false
    var exit: ChannelExit?
    /// The connection's end, when that is what ended the channel before its output did (what reads throw).
    var lostWith: SSHError?
    /// The connection's end, when that is what ended the channel (what writes throw).
    var endedBy: SSHError?
    var readers: [(number: UInt64, continuation: CheckedContinuation<Result<ChannelOutput?, SSHError>, Never>)] = []

    var writers: [PendingWrite] = []
    var finishRequested = false
    var finishSent = false
    var exitWaiters: [CheckedContinuation<ChannelExit, Never>] = []

    init(kind: ChannelKind, id: ChannelID, mailbox: ShellMailbox?) {
      self.kind = kind
      self.id = id
      self.mailbox = mailbox
    }

    func popOutput() -> ChannelOutput? {
      guard outputStart < output.count else { return nil }
      let chunk = output[outputStart]
      outputStart += 1
      if outputStart == output.count {
        output.removeAll(keepingCapacity: true)
        outputStart = 0
      } else if outputStart >= 64, outputStart * 2 >= output.count {
        output.removeFirst(outputStart)
        outputStart = 0
      }
      buffered -= chunk.byteCount
      return chunk
    }

    func dropOutput() {
      output = []
      outputStart = 0
      buffered = 0
    }
  }

  private var channels: [UInt64: Channel] = [:]
  /// The record of each channel the core reports on, by its number.
  private var live: [ChannelID: UInt64] = [:]
  private var handles: UInt64 = 0
  private var waiters: UInt64 = 0

  /// Opens an exec or a shell channel and returns its handle once the core handed it over (an exec once its request
  /// is sent; a shell once both requests were confirmed). Cancelling the calling task closes the channel and throws
  /// `cancelled`.
  func open(_ kind: ChannelKind, command: String = "", term: String = "", size: TerminalSize? = nil)
    async throws(SSHError) -> (handle: UInt64, mailbox: ShellMailbox?)
  {
    guard endReason == nil else { throw .closed(.alreadyEnded) }
    let id: ChannelID
    let mailbox: ShellMailbox?
    switch kind {
    case .exec:
      id = try core.openExec(command)
      mailbox = nil
    case .shell:
      id = try core.openShell(term: term, size: size ?? TerminalSize(columns: 80, rows: 24))
      mailbox = ShellMailbox()
    }
    handles &+= 1
    let handle = handles
    let channel = Channel(kind: kind, id: id, mailbox: mailbox)
    channels[handle] = channel
    live[id] = handle
    process()
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, SSHError>, Never>) in
        if let result = channel.openResult {
          continuation.resume(returning: result)
        } else {
          channel.opener = continuation
        }
      }
    } onCancel: {
      Task { await self.cancelOpen(handle) }
    }
    switch result {
    case .success:
      return (handle, mailbox)
    case .failure(let error):
      channels[handle] = nil
      throw error
    }
  }

  private func cancelOpen(_ handle: UInt64) {
    guard let channel = channels[handle], channel.openResult == nil, channel.live else { return }
    core.closeChannel(channel.id)
    process()
  }

  func write(_ handle: UInt64, _ bytes: [UInt8]) async throws(SSHError) {
    guard let channel = channels[handle] else { throw .usage(.channelClosed) }
    if channel.closed { throw channel.endedBy ?? .usage(.channelClosed) }
    if let endReason { throw endReason }
    guard !channel.finishRequested else { throw .usage(.channelClosed) }
    guard !bytes.isEmpty else { return }
    waiters &+= 1
    let pending = PendingWrite(number: waiters, bytes: bytes)
    channel.writers.append(pending)
    pumpWriters(channel)
    process()
    if let result = pending.result { return try result.get() }
    stats.writeSuspensions += 1
    let number = pending.number
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, SSHError>, Never>) in
        if let result = pending.result {
          continuation.resume(returning: result)
        } else {
          pending.waiter = continuation
        }
      }
    } onCancel: {
      Task { await self.cancelWrite(handle, number) }
    }
    try result.get()
  }

  private func cancelWrite(_ handle: UInt64, _ number: UInt64) {
    guard let channel = channels[handle], let index = channel.writers.firstIndex(where: { $0.number == number })
    else { return }
    let pending = channel.writers.remove(at: index)
    pending.finish(.failure(.cancelled))
    pumpWriters(channel)
    process()
  }

  /// Hands the queued writes to the core in order, as far as it takes them; EOF once all went, if asked for.
  private func pumpWriters(_ channel: Channel) {
    while let pending = channel.writers.first {
      let taken: Int
      do {
        taken = try core.write(pending.bytes[pending.offset...], to: channel.id)
      } catch {
        failWriters(channel, error)
        return
      }
      pending.offset += taken
      guard pending.offset >= pending.bytes.count else { return }
      channel.writers.removeFirst()
      pending.finish(.success(()))
    }
    if channel.finishRequested, !channel.finishSent, channel.live, !channel.closed {
      channel.finishSent = true
      core.finishInput(channel.id)
    }
  }

  private func failWriters(_ channel: Channel, _ error: SSHError) {
    let failed = channel.writers
    channel.writers = []
    for pending in failed { pending.finish(.failure(error)) }
  }

  func finishInput(_ handle: UInt64) {
    guard let channel = channels[handle], !channel.finishRequested else { return }
    channel.finishRequested = true
    guard !channel.closed, endReason == nil else { return }
    pumpWriters(channel)
    process()
  }

  func read(_ handle: UInt64) async throws(SSHError) -> ChannelOutput? {
    guard let channel = channels[handle] else { return nil }
    if channel.readers.isEmpty, let chunk = channel.popOutput() {
      consumed(chunk, on: channel)
      process()
      return chunk
    }
    if channel.readers.isEmpty, let end = Self.outputEnd(channel) { return try end.get() }
    waiters &+= 1
    let number = waiters
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Result<ChannelOutput?, SSHError>, Never>) in
        channel.readers.append((number, continuation))
        serveReaders(channel)
        checkStatWaiters()
      }
    } onCancel: {
      Task { await self.cancelRead(handle, number) }
    }
    process()
    return try result.get()
  }

  private func cancelRead(_ handle: UInt64, _ number: UInt64) {
    guard let channel = channels[handle], let index = channel.readers.firstIndex(where: { $0.number == number })
    else { return }
    channel.readers.remove(at: index).continuation.resume(returning: .failure(.cancelled))
  }

  /// What a read returns once the buffered output is gone, or nil while more may come: nil (no more output) after
  /// EOF or the channel's end, the connection's end when that ended it first.
  private static func outputEnd(_ channel: Channel) -> Result<ChannelOutput?, SSHError>? {
    if channel.eof { return .success(nil) }
    guard channel.closed else { return nil }
    if let lost = channel.lostWith { return .failure(lost) }
    return .success(nil)
  }

  private func serveReaders(_ channel: Channel) {
    while !channel.readers.isEmpty {
      if let chunk = channel.popOutput() {
        consumed(chunk, on: channel)
        channel.readers.removeFirst().continuation.resume(returning: .success(chunk))
      } else if let end = Self.outputEnd(channel) {
        let readers = channel.readers
        channel.readers = []
        for reader in readers { reader.continuation.resume(returning: end) }
      } else {
        return
      }
    }
  }

  private func consumed(_ chunk: ChannelOutput, on channel: Channel) {
    guard channel.live, !channel.closed else { return }
    core.consumed(chunk.byteCount, on: channel.id)
  }

  /// Closes the channel (the app's side ends at once; unread output is dropped).
  func closeChannel(_ handle: UInt64) {
    guard let channel = channels[handle] else { return }
    channel.mailbox?.markClosed()
    guard !channel.closed else { return }
    channel.dropOutput()
    if channel.live, endReason == nil {
      core.closeChannel(channel.id)
      process()
    }
  }

  func exit(_ handle: UInt64) async -> ChannelExit {
    guard let channel = channels[handle] else { return .lost }
    if channel.closed { return channel.exit ?? .lost }
    return await withCheckedContinuation { continuation in channel.exitWaiters.append(continuation) }
  }

  /// The facade object went away: the channel closes and its record is dropped.
  func release(_ handle: UInt64) {
    closeChannel(handle)
    guard let channel = channels[handle], channel.closed else { return }
    channels[handle] = nil
  }

  /// Sends the size waiting in the shell's mailbox, if any (`ShellChannel.resize`).
  func applyResize(_ handle: UInt64) {
    guard let channel = channels[handle], let size = channel.mailbox?.take() else { return }
    guard channel.live, !channel.closed, endReason == nil else { return }
    try? core.resize(channel.id, to: size)
    process()
  }

  // MARK: Channel events

  private func channelOpened(_ id: ChannelID) {
    guard let handle = live[id], let channel = channels[handle] else { return }
    channel.openResult = .success(())
    channel.opener?.resume(returning: .success(()))
    channel.opener = nil
  }

  private func channelOpenFailed(_ id: ChannelID, _ error: SSHError) {
    guard let handle = live.removeValue(forKey: id), let channel = channels[handle] else { return }
    channel.live = false
    channel.closed = true
    channel.exit = .lost
    channel.mailbox?.markClosed()
    channel.openResult = .failure(error)
    channel.opener?.resume(returning: .failure(error))
    channel.opener = nil
  }

  private func channelOutput(_ id: ChannelID, _ output: ChannelOutput) {
    guard let handle = live[id], let channel = channels[handle] else { return }
    channel.output.append(output)
    channel.buffered += output.byteCount
    stats.maximumBufferedOutput = max(stats.maximumBufferedOutput, channel.buffered)
    serveReaders(channel)
  }

  private func channelEOF(_ id: ChannelID) {
    guard let handle = live[id], let channel = channels[handle] else { return }
    channel.eof = true
    serveReaders(channel)
  }

  private func channelClosed(_ id: ChannelID, _ exit: ChannelExit, lostWith: SSHError?) {
    guard let handle = live.removeValue(forKey: id), let channel = channels[handle] else { return }
    channel.live = false
    channel.closed = true
    channel.exit = exit
    channel.lostWith = channel.eof ? nil : lostWith
    channel.endedBy = lostWith
    channel.mailbox?.markClosed()
    failWriters(channel, lostWith ?? .usage(.channelClosed))
    serveReaders(channel)
    let waiting = channel.exitWaiters
    channel.exitWaiters = []
    for waiter in waiting { waiter.resume(returning: exit) }
  }

  private func channelWritable(_ id: ChannelID) {
    guard let handle = live[id], let channel = channels[handle] else { return }
    pumpWriters(channel)
  }

  // MARK: Processing

  /// Drains the core's events, then lets the loops go on. Every actor method that called into the core ends here.
  private func process() {
    while let event = core.poll() { handle(event) }
    stats.maximumBacklog = max(stats.maximumBacklog, core.outboundBacklog)
    if core.outboundBacklog > 0 || endReason != nil { wakeWriter() }
    if !core.readsPaused { wakeReader() }
    checkStatWaiters()
  }

  private func handle(_ event: ClientEvent) {
    switch event {
    case .hostKeyNeedsTrust(let key): askTrust(key)
    case .established: established()
    case .rekeyed: stats.rekeys += 1
    case .timer(.schedule(let timer, let delay)): schedule(.core(timer), at: clock.now.advanced(by: delay))
    case .timer(.cancel(let timer)): cancelTimer(.core(timer))
    case .sign(let question, let data, let algorithm): sign(question, data: data, algorithm: algorithm)
    case .prompt(let question, let challenge): prompt(question, challenge)
    case .authFinished(let result): attemptFinished(result)
    case .opened(let id): channelOpened(id)
    case .openFailed(let id, let error): channelOpenFailed(id, error)
    case .output(let id, let output): channelOutput(id, output)
    case .eof(let id): channelEOF(id)
    case .closed(let id, let exit, let lostWith): channelClosed(id, exit, lostWith: lostWith)
    case .writable(let id): channelWritable(id)
    case .ended(let error): connectionEnded(error)
    }
  }

  private func connectionEnded(_ error: SSHError) {
    guard endReason == nil else { return }
    endReason = error
    resolveConnect(.failure(error))
    for kind in Array(timers.keys) { cancelTimer(kind) }
    trustTask?.cancel()
    trustTask = nil
    trust = nil
    attempt?.helper?.cancel()
    // The core ended every channel before `.ended`; anything still waiting is answered here all the same.
    for channel in channels.values where !channel.closed {
      channel.closed = true
      channel.live = false
      channel.lostWith = channel.eof ? nil : error
      channel.endedBy = error
      channel.mailbox?.markClosed()
      failWriters(channel, error)
      serveReaders(channel)
      let exits = channel.exitWaiters
      channel.exitWaiters = []
      for waiter in exits { waiter.resume(returning: channel.exit ?? .lost) }
    }
    live.removeAll()
    let waiting = endedWaiters
    endedWaiters = []
    for waiter in waiting { waiter.resume(returning: error) }
    if !streamBroken { schedule(.disconnectGrace, at: clock.now.advanced(by: tuning.disconnectGrace)) }
  }

  // MARK: The stream

  private var readWaiter: CheckedContinuation<Void, Never>?
  private var writeWaiter: CheckedContinuation<Void, Never>?

  private func readLoop() async {
    guard let stream else { return }
    while endReason == nil {
      if core.readsPaused {
        stats.readPauses += 1
        await withCheckedContinuation { continuation in readWaiter = continuation }
        continue
      }
      let result: Result<[UInt8], SSHError>
      do throws(SSHError) {
        result = .success(try await stream.read(maximum: tuning.readSize))
      } catch {
        result = .failure(error)
      }
      guard endReason == nil else { return }
      switch result {
      case .success(let bytes) where bytes.isEmpty:
        core.receiveEnd()
        process()
        return
      case .success(let bytes):
        stats.reads += 1
        stats.bytesRead += bytes.count
        core.receive(bytes)
        process()
      case .failure(let error):
        streamBroken = true
        core.end(error)
        process()
        return
      }
    }
  }

  private func writeLoop() async {
    guard let stream else { return }
    while true {
      let bytes = core.takeOutbound()
      process()
      if bytes.isEmpty {
        if endReason != nil { break }
        await withCheckedContinuation { continuation in writeWaiter = continuation }
        continue
      }
      if streamBroken || streamClosing { break }
      do {
        try await stream.write(bytes)
      } catch {
        streamBroken = true
        core.end(error)
        process()
        break
      }
      stats.writes += 1
      stats.bytesWritten += bytes.count
      process()
    }
    await closeStream()
  }

  private func wakeReader() {
    readWaiter?.resume()
    readWaiter = nil
  }

  private func wakeWriter() {
    writeWaiter?.resume()
    writeWaiter = nil
  }

  private func closeStream() async {
    guard !streamClosing else {
      await waitForStreamClosed()
      return
    }
    streamClosing = true
    cancelTimer(.disconnectGrace)
    await stream?.close()
    streamClosed = true
    wakeReader()
    let waiting = streamClosedWaiters
    streamClosedWaiters = []
    for waiter in waiting { waiter.resume() }
  }

  private func waitForStreamClosed() async {
    guard !streamClosed else { return }
    await withCheckedContinuation { continuation in streamClosedWaiters.append(continuation) }
  }

  // MARK: Timers

  private enum TimerKind: Hashable {
    case core(CoreTimer)
    case handshake
    case disconnectGrace
  }

  private struct TimerSlot {
    var deadline: ContinuousClock.Instant
    var generation: UInt64
    var task: Task<Void, Never>
  }

  private var timers: [TimerKind: TimerSlot] = [:]
  private var timerGenerations: UInt64 = 0

  /// Runs `kind` at `deadline`, replacing a pending one. A later deadline for a sleeping timer only moves it.
  private func schedule(_ kind: TimerKind, at deadline: ContinuousClock.Instant) {
    if var slot = timers[kind], slot.deadline <= deadline {
      slot.deadline = deadline
      timers[kind] = slot
      return
    }
    timers[kind]?.task.cancel()
    timerGenerations &+= 1
    let generation = timerGenerations
    stats.timerTasks += 1
    let task = Task { await self.sleep(kind, generation) }
    timers[kind] = TimerSlot(deadline: deadline, generation: generation, task: task)
  }

  private func cancelTimer(_ kind: TimerKind) {
    timers.removeValue(forKey: kind)?.task.cancel()
  }

  /// The longest one sleep of a timer. A cancelled `Task.sleep` leaves its wake-up job (about 1.3 KB) queued in the
  /// runtime until the time it was given, so a timer far away sleeps in slices: the hourly re-exchange timer every
  /// connection cancels at its end would otherwise outlive it by up to an hour.
  static let sleepSlice: Duration = .seconds(60)

  private func sleep(_ kind: TimerKind, _ generation: UInt64) async {
    while let slot = timers[kind], slot.generation == generation {
      let deadline = slot.deadline
      let remaining = clock.now.duration(to: deadline)
      let wake = remaining > Self.sleepSlice ? clock.now.advanced(by: Self.sleepSlice) : deadline
      noteSleep(clock.now.duration(to: wake))
      do {
        try await Task.sleep(until: wake, tolerance: Self.tolerance(kind, remaining), clock: clock)
      } catch {
        return
      }
      guard let current = timers[kind], current.generation == generation else { return }
      if wake < deadline || current.deadline > deadline { continue }
      timers[kind] = nil
      await fire(kind)
      return
    }
  }

  private func noteSleep(_ duration: Duration) {
    guard duration > stats.longestSleep else { return }
    stats.longestSleep = duration
    checkStatWaiters()
  }

  /// Keepalive and rekey timers may fire a little late so the system can coalesce wake-ups; deadlines may not.
  private static func tolerance(_ kind: TimerKind, _ delay: Duration) -> Duration? {
    switch kind {
    case .core(.keepalive), .core(.rekey): min(delay / 20, .seconds(1))
    default: nil
    }
  }

  private func fire(_ kind: TimerKind) async {
    switch kind {
    case .core(let timer):
      if timer == .keepalive { stats.keepalivesFired += 1 }
      core.timerFired(timer)
      process()
    case .handshake:
      guard connectOutcome == nil, endReason == nil else { return }
      core.end(.timedOut(.handshake))
      process()
    case .disconnectGrace:
      await closeStream()
    }
  }

  // MARK: Test hooks

  /// The algorithms of the last exchange (tests check what a real server negotiated).
  var negotiated: NegotiatedAlgorithms? { core.negotiated }

  /// Returns the stats once `predicate` holds (checked after every step).
  func waitForStats(_ predicate: @escaping @Sendable (DriverStats) -> Bool) async -> DriverStats {
    countWaiters()
    if predicate(stats) { return stats }
    return await withCheckedContinuation { continuation in statWaiters.append((predicate, continuation)) }
  }

  private func checkStatWaiters() {
    guard !statWaiters.isEmpty else { return }
    countWaiters()
    var waiting: [(predicate: @Sendable (DriverStats) -> Bool, continuation: CheckedContinuation<DriverStats, Never>)] = []
    for waiter in statWaiters {
      if waiter.predicate(stats) { waiter.continuation.resume(returning: stats) } else { waiting.append(waiter) }
    }
    statWaiters = waiting
  }

  private func countWaiters() {
    stats.waitingWriters = channels.values.reduce(0) { $0 + $1.writers.count }
    stats.waitingReaders = channels.values.reduce(0) { $0 + $1.readers.count }
  }

  /// Output a channel holds that the app has not read.
  func bufferedOutput(_ handle: UInt64) -> Int { channels[handle]?.buffered ?? 0 }

  var keepalivesOutstanding: Int { core.keepalivesOutstanding }
  var outboundBacklog: Int { core.outboundBacklog }
  var channelRecords: Int { channels.count }
}

extension ChannelOutput {
  var byteCount: Int {
    switch self {
    case .stdout(let bytes), .stderr(let bytes): bytes.count
    }
  }

  var bytes: [UInt8] {
    switch self {
    case .stdout(let bytes), .stderr(let bytes): bytes
    }
  }
}
