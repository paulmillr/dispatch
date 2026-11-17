import Foundation

/// One authenticated SSH connection to a host, on the engine `SSHTransportEngine.preferred` named when it started.
/// Channels are opened on it; closing it closes them all. A dropped connection (network loss, keepalive timeout, remote
/// disconnect) is not revived: `closed()` returns and `HostConnection` makes a new one.
public final class SSHConnection: Sendable {
  public struct Timings: Sendable {
    /// TCP, version exchange and key exchange, without the time the host key decision took.
    public let handshake: Duration
    /// User authentication, every credential tried.
    public let authentication: Duration
    public var total: Duration { handshake + authentication }
  }

  public let endpoint: SSHEndpoint
  public let hostKey: HostKeyInfo
  public let timings: Timings
  /// Which credential logged in: its index in the `credentials` given to `connect`.
  public let credential: Int
  let session: any EngineSession
  let link: SessionLink

  /// Connects, verifies the host key through `trust`, and authenticates with `credentials` in order
  /// (each one the server still allows). Keepalives detect a dead connection after
  /// `keepalive * (keepaliveMax + 1)` of silence.
  public static func connect(
    to endpoint: SSHEndpoint, credentials: [SSHCredential], trust: any HostKeyTrust,
    timeout: Duration = .seconds(15), keepalive: Duration = .seconds(15), keepaliveMax: Int = 3,
    authenticating: (@Sendable () async -> Void)? = nil
  ) async throws -> SSHConnection {
    let engine = SSHTransportEngine.preferred.backend
    let clock = ContinuousClock()
    let start = clock.now
    let link = SessionLink(host: endpoint.host, port: endpoint.port, trust: trust, trusted: authenticating)
    let completion = Once<Result<any EngineSession, SSHTransportError>>()
    let options = EngineConnectOptions(
      host: endpoint.host, port: endpoint.port, timeout: timeout, keepalive: keepalive, keepaliveMax: keepaliveMax)
    engine.connect(options, events: link) { completion.set($0) }
    // Cancelling the connect withdraws the questions it asks (host key, login prompts, signatures): their tasks are
    // not children of this one, so without this a sheet would outlive the connection that asked.
    let session: any EngineSession
    do {
      session = try await withTaskCancellationHandler { try await completion.value.get() } onCancel: { link.withdraw() }
    } catch {
      throw link.explain(error)
    }
    let connected = clock.now
    let credential: Int
    do {
      credential = try await withTaskCancellationHandler {
        try await authenticate(session, link: link, user: endpoint.username, credentials: credentials)
      } onCancel: { link.withdraw() }
      try Task.checkCancellation()
    } catch {
      session.close()
      throw error
    }
    guard let (info, _) = link.decision else { throw SSHTransportError.channelClosed }
    return SSHConnection(
      endpoint: endpoint, hostKey: info, session: session, link: link, credential: credential,
      timings: Timings(handshake: connected - start - link.deciding, authentication: clock.now - connected))
  }

  private init(endpoint: SSHEndpoint, hostKey: HostKeyInfo, session: any EngineSession, link: SessionLink, credential: Int,
               timings: Timings) {
    self.endpoint = endpoint
    self.hostKey = hostKey
    self.session = session
    self.link = link
    self.credential = credential
    self.timings = timings
  }

  /// Whether the connection is still up.
  public var isActive: Bool { link.ending == nil }

  /// Why the connection ended, once it has.
  public var endReason: SSHTransportError? { link.ending }

  /// Returns when the connection has ended, for any reason.
  public func closed() async { await link.closed() }

  public func close() async {
    session.close()
    await link.closed()
  }

  /// Starts `command` on a new session channel (no PTY). See `SSHExec`.
  public func exec(_ command: String) async throws -> SSHExec {
    try await SSHExec.start(command, on: session)
  }

  /// Runs `command` to completion, feeding it `input` and collecting at most `limit` bytes of output.
  public func run(_ command: String, input: Data = Data(), limit: Int = 1 << 20) async throws -> SSHCommandResult {
    let exec = try await exec(command)
    async let fed: Void = {
      if !input.isEmpty { try await exec.write(input) }
      try await exec.finishInput()
    }()
    var stdout = Data(), stderr = Data()
    do {
      for try await chunk in exec {
        switch chunk {
        case .stdout(let data): stdout.append(data)
        case .stderr(let data): stderr.append(data)
        }
        guard stdout.count + stderr.count <= limit else {
          await exec.close()
          throw SSHTransportError.outputLimit(limit)
        }
      }
      try? await fed
    } catch {
      try? await fed
      throw error
    }
    return SSHCommandResult(status: try await exec.exitStatus(), stdout: stdout, stderr: stderr)
  }

  /// The index of the credential that logged in.
  private static func authenticate(_ session: any EngineSession, link: SessionLink, user: String, credentials: [SSHCredential]) async throws -> Int {
    var remaining: EngineMethods?
    for (index, credential) in credentials.enumerated() {
      try Task.checkCancellation()
      if let remaining, remaining.isDisjoint(with: credential.method) { continue }
      let answered: (@Sendable (DirectKeyAnswer) -> Void)? = if case .directKey(_, let answered) = credential { answered } else { nil }
      let outcome: EngineAuthOutcome
      do {
        outcome = try await attempt(credential, session: session, link: link, user: user)
      } catch {
        if case SSHTransportError.cancelled = error { answered?(.withdrawn) } else { answered?(.unanswered) }
        throw error
      }
      switch outcome {
      case .loggedIn:
        answered?(.loggedIn)
        return index
      case .refused(let methods):
        answered?(.refused)
        remaining = methods
      }
    }
    throw SSHTransportError.authenticationFailed(methods: (remaining ?? []).names)
  }

  /// One login. The questions it asks (signatures, prompts) go to the app on tasks `link` withdraws when the connect is
  /// cancelled; each answers the engine exactly once.
  private static func attempt(_ credential: SSHCredential, session: any EngineSession, link: SessionLink, user: String) async throws -> EngineAuthOutcome {
    let completion = Once<Result<EngineAuthOutcome, SSHTransportError>>()
    let done: @Sendable (Result<EngineAuthOutcome, SSHTransportError>) -> Void = { completion.set($0) }
    switch credential {
    case .password(let password):
      session.authenticate(user: user, password: password, done: done)
    case .key(let key), .directKey(let key, _):
      let direct = if case .directKey = credential { true } else { false }
      switch key.backing {
      case .engine(let parsed):
        session.authenticate(user: user, key: parsed, direct: direct, done: done)
      case .signer(let blob, let signer):
        session.authenticate(user: user, signer: blob, direct: direct, sign: { data, answer in
          link.ask {
            guard !Task.isCancelled else { return answer(nil) }
            do { answer(try await signer(data)) } catch { answer(nil) }
          }
        }, done: done)
      }
    case .keyboardInteractive(let respond):
      session.authenticateKeyboardInteractive(user: user, prompt: { challenge, answer in
        link.ask {
          guard !Task.isCancelled else { return answer(nil) }
          if let answers = await respond(challenge), !Task.isCancelled { answer(answers) } else { answer(nil) }
        }
      }, done: done)
    }
    return try await completion.value.get()
  }
}

public struct SSHCommandResult: Sendable {
  public let status: Int32
  public let stdout: Data
  public let stderr: Data
  public var text: String { String(decoding: stdout, as: UTF8.self) }
}

/// Lives as long as the connection: answers host key questions and records how it ended.
final class SessionLink: EngineSessionEvents, @unchecked Sendable {
  private let host: String
  private let port: Int
  private let trust: any HostKeyTrust
  private let trusted: (@Sendable () async -> Void)?
  private let lock = NSLock()
  private var decided: (HostKeyInfo, HostKeyDecision)?
  private var decisionTime: Duration = .zero
  private let end = Once<SSHTransportError>()
  /// The open questions to the app (host key, login prompts, signatures), and whether the connect was cancelled.
  private var questions: [UUID: Task<Void, Never>] = [:]
  private var withdrawn = false

  init(host: String, port: Int, trust: any HostKeyTrust, trusted: (@Sendable () async -> Void)?) {
    self.host = host
    self.port = port
    self.trust = trust
    self.trusted = trusted
  }

  var decision: (HostKeyInfo, HostKeyDecision)? { lock.withLock { decided } }
  var deciding: Duration { lock.withLock { decisionTime } }
  var ending: SSHTransportError? { end.current }

  func hostKey(_ key: EngineHostKey, answer: @escaping @Sendable (Bool) -> Void) {
    let info = HostKeyInfo(host: host, port: port, algorithm: key.algorithm, fingerprint: key.fingerprint, openSSH: key.openSSH)
    let trust = trust, trusted = trusted
    ask {
      // Asked after the connect was cancelled: the app is not asked (no sheet for a connection nobody wants).
      guard !Task.isCancelled else { return answer(false) }
      let start = ContinuousClock.now
      let decision = await trust.evaluate(info)
      self.lock.withLock {
        self.decided = (info, decision)
        self.decisionTime = ContinuousClock.now - start
      }
      // A connect cancelled while the question was open goes no further, whatever the answer.
      let trusting = decision == .trust && !Task.isCancelled
      if trusting { await trusted?() }
      answer(trusting)
    }
  }

  /// Runs a question to the app on its own task, which `withdraw` cancels (the answer still goes to the engine).
  func ask(_ body: @escaping @Sendable () async -> Void) {
    let id = UUID()
    // Started under the lock, so its end (which takes the lock) comes after it was kept.
    lock.withLock {
      let task = Task {
        await body()
        self.lock.withLock { _ = self.questions.removeValue(forKey: id) }
      }
      if withdrawn { task.cancel() } else { questions[id] = task }
    }
  }

  /// The connect was cancelled: open questions are cancelled (a sheet waiting for the user goes away and answers no),
  /// and later ones start cancelled.
  func withdraw() {
    let open = lock.withLock { () -> [Task<Void, Never>] in
      withdrawn = true
      defer { questions = [:] }
      return Array(questions.values)
    }
    open.forEach { $0.cancel() }
  }

  /// A refused host key explains a failed connect better than the engine's error does.
  func explain(_ error: any Error) -> any Error {
    if case SSHTransportError.connectFailed(let failure, _, _) = error {
      return SSHTransportError.connectFailed(failure, host: host, port: port)
    }
    guard let (info, decision) = decision else { return error }
    switch decision {
    case .trust: return error
    case .reject: return SSHTransportError.hostKeyRejected(info)
    case .mismatch(let expected): return SSHTransportError.hostKeyMismatch(info, expected: expected)
    }
  }

  /// The first reason stands.
  func disconnected(_ reason: SSHTransportError) { end.set(reason) }

  func closed() async { _ = await end.value }
}
