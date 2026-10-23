import DispatchMobileSSHCore
import Foundation

/// One authenticated SSH connection to a host (the russh engine). Channels are opened on it; closing it
/// closes them all. A dropped connection (network loss, keepalive timeout, remote disconnect) is not
/// revived: `closed()` returns and `HostConnection` makes a new one.
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
  let session: SessionHandle
  let link: SessionLink

  /// Connects, verifies the host key through `trust`, and authenticates with `credentials` in order
  /// (each one the server still allows). Keepalives detect a dead connection after
  /// `keepalive * keepaliveMax` of silence.
  public static func connect(
    to endpoint: SSHEndpoint, credentials: [SSHCredential], trust: any HostKeyTrust,
    timeout: Duration = .seconds(15), keepalive: Duration = .seconds(15), keepaliveMax: Int = 3,
    authenticating: (@Sendable () async -> Void)? = nil
  ) async throws -> SSHConnection {
    let clock = ContinuousClock()
    let start = clock.now
    let link = SessionLink(host: endpoint.host, port: endpoint.port, trust: trust, trusted: authenticating)
    let completion = Completion<SessionHandle>()
    let callbacks = dms_session_callbacks(
      context: Engine.retain(link),
      host_key: { context, key, reply in
        let link = Engine.borrow(context, as: SessionLink.self)
        link.decide(key!.pointee, reply: EngineReply(pointer: reply))
      },
      disconnected: { context, code, message in
        Engine.release(context, as: SessionLink.self).ended(Engine.error(code, message))
      })
    endpoint.host.withCString { host in
      var options = dms_connect_options(
        host: host, port: UInt16(clamping: endpoint.port), timeout_ms: milliseconds(timeout),
        keepalive_interval_ms: milliseconds(keepalive), keepalive_max: UInt32(max(0, keepaliveMax)))
      dms_connect(&options, callbacks, Engine.retain(completion)) { context, session, code, message in
        let completion = Engine.release(context, as: Completion<SessionHandle>.self)
        if let session {
          completion.finish(.success(SessionHandle(session)))
        } else {
          completion.finish(.failure(Engine.error(code, message)))
        }
      }
    }
    // Cancelling the connect withdraws the questions it asks (host key, login prompts, signatures): their tasks are
    // not children of this one, so without this a sheet would outlive the connection that asked.
    let session: SessionHandle
    do {
      session = try await withTaskCancellationHandler { try await completion.value } onCancel: { link.withdraw() }
    } catch {
      // A failed connect never calls `disconnected`: the session context is ours to drop.
      Unmanaged.passUnretained(link).release()
      throw link.explain(error)
    }
    let connected = clock.now
    do {
      try await withTaskCancellationHandler {
        try await authenticate(session, link: link, user: endpoint.username, credentials: credentials)
      } onCancel: { link.withdraw() }
      try Task.checkCancellation()
    } catch {
      dms_session_close(session.pointer)
      throw error
    }
    guard let (info, _) = link.decision else { throw SSHTransportError.channelClosed }
    return SSHConnection(
      endpoint: endpoint, hostKey: info, session: session, link: link,
      timings: Timings(handshake: connected - start - link.deciding, authentication: clock.now - connected))
  }

  private init(endpoint: SSHEndpoint, hostKey: HostKeyInfo, session: SessionHandle, link: SessionLink, timings: Timings) {
    self.endpoint = endpoint
    self.hostKey = hostKey
    self.session = session
    self.link = link
    self.timings = timings
  }

  /// Whether the connection is still up.
  public var isActive: Bool { link.ending == nil }

  /// Why the connection ended, once it has.
  public var endReason: SSHTransportError? { link.ending }

  /// Returns when the connection has ended, for any reason.
  public func closed() async { await link.closed() }

  public func close() async {
    dms_session_close(session.pointer)
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

  fileprivate enum Outcome: Sendable {
    case success
    case failure(remaining: UInt32)
  }

  private static func authenticate(_ session: SessionHandle, link: SessionLink, user: String, credentials: [SSHCredential]) async throws {
    var remaining: UInt32?
    for credential in credentials {
      try Task.checkCancellation()
      if let remaining, remaining & credential.method == 0 { continue }
      switch try await attempt(credential, session: session, link: link, user: user) {
      case .success: return
      case .failure(let methods): remaining = methods
      }
    }
    throw SSHTransportError.authenticationFailed(methods: Engine.methods(remaining ?? 0))
  }

  private static func attempt(_ credential: SSHCredential, session: SessionHandle, link: SessionLink, user: String) async throws -> Outcome {
    let completion = Completion<Outcome>()
    let done: dms_auth_fn = { context, code, remaining, _, message in
      let box = Engine.release(context, as: AuthBox.self)
      if code == DMS_OK {
        box.completion.finish(.success(.success))
      } else if code == DMS_AUTH_FAILED {
        box.completion.finish(.success(.failure(remaining: remaining)))
      } else {
        box.completion.finish(.failure(Engine.error(code, message)))
      }
    }
    switch credential {
    case .password(let password):
      let box = AuthBox(completion, link: link)
      withCStrings(user, password) { dms_auth_password(session.pointer, $0, $1, Engine.retain(box), done) }
    case .key(let key):
      switch key.backing {
      case .engine(let handle):
        let box = AuthBox(completion, link: link, keep: handle)
        user.withCString { dms_auth_key(session.pointer, $0, handle.pointer, Engine.retain(box), done) }
      case .signer(let blob, let sign):
        let box = AuthBox(completion, link: link, sign: sign)
        blob.withUnsafeBytes { bytes in
          user.withCString {
            dms_auth_signer(session.pointer, $0, bytes.bindMemory(to: UInt8.self).baseAddress, blob.count, Engine.retain(box), { context, data, length, reply in
              let box = Engine.borrow(context, as: AuthBox.self)
              box.sign(Data(bytes: data!, count: length), reply: EngineReply(pointer: reply))
            }, done)
          }
        }
      }
    case .keyboardInteractive(let respond):
      let box = AuthBox(completion, link: link, respond: respond)
      user.withCString {
        dms_auth_keyboard_interactive(session.pointer, $0, Engine.retain(box), { context, name, instruction, prompts, count, reply in
          let box = Engine.borrow(context, as: AuthBox.self)
          let challenge = KeyboardInteractiveChallenge(
            name: name.map { String(cString: $0) } ?? "", instruction: instruction.map { String(cString: $0) } ?? "",
            prompts: (0..<count).map { KeyboardInteractiveChallenge.Prompt(text: String(cString: prompts![$0].text), echo: prompts![$0].echo) })
          box.prompt(challenge, reply: EngineReply(pointer: reply))
        }, done)
      }
    }
    return try await completion.value
  }
}

public struct SSHCommandResult: Sendable {
  public let status: Int32
  public let stdout: Data
  public let stderr: Data
  public var text: String { String(decoding: stdout, as: UTF8.self) }
}

/// The engine's session; freed (and closed if still open) with the last reference.
final class SessionHandle: @unchecked Sendable {
  let pointer: OpaquePointer
  init(_ pointer: OpaquePointer) { self.pointer = pointer }
  deinit { dms_session_free(pointer) }
}

/// Lives as long as the connection: answers host key questions and records how it ended.
final class SessionLink: @unchecked Sendable {
  private let host: String
  private let port: Int
  private let trust: any HostKeyTrust
  private let trusted: (@Sendable () async -> Void)?
  private let lock = NSLock()
  private var decided: (HostKeyInfo, HostKeyDecision)?
  private var decisionTime: Duration = .zero
  private var end: SSHTransportError?
  private var waiters: [CheckedContinuation<Void, Never>] = []
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
  var ending: SSHTransportError? { lock.withLock { end } }

  func decide(_ key: dms_host_key, reply: EngineReply) {
    let info = HostKeyInfo(
      host: host, port: port, algorithm: String(cString: key.algorithm), fingerprint: String(cString: key.fingerprint),
      openSSH: String(cString: key.openssh))
    let trust = trust, trusted = trusted
    ask {
      let start = ContinuousClock.now
      let decision = await trust.evaluate(info)
      self.lock.withLock {
        self.decided = (info, decision)
        self.decisionTime = ContinuousClock.now - start
      }
      // A connect cancelled while the question was open goes no further, whatever the answer.
      let trusting = decision == .trust && !Task.isCancelled
      if trusting { await trusted?() }
      reply.bool(trusting)
    }
  }

  /// Runs a question to the app on its own task, which `withdraw` cancels (the answer still goes to the engine).
  func ask(_ body: @escaping @Sendable () async -> Void) {
    let id = UUID()
    let task = Task {
      await body()
      self.lock.withLock { _ = self.questions.removeValue(forKey: id) }
    }
    let cancel = lock.withLock { () -> Bool in
      if !withdrawn { questions[id] = task }
      return withdrawn
    }
    if cancel { task.cancel() }
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

  func ended(_ reason: SSHTransportError) {
    let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      if end == nil { end = reason }
      defer { self.waiters = [] }
      return self.waiters
    }
    waiters.forEach { $0.resume() }
  }

  func closed() async {
    await withCheckedContinuation { continuation in
      let done = lock.withLock { () -> Bool in
        if end != nil { return true }
        waiters.append(continuation)
        return false
      }
      if done { continuation.resume() }
    }
  }
}

/// Context of one authentication attempt.
private final class AuthBox: @unchecked Sendable {
  let completion: Completion<SSHConnection.Outcome>
  private let link: SessionLink
  private let keep: KeyHandle?
  private let signer: SSHKey.Signer?
  private let respond: (@Sendable (KeyboardInteractiveChallenge) async -> [String]?)?

  init(_ completion: Completion<SSHConnection.Outcome>, link: SessionLink, keep: KeyHandle? = nil, sign: SSHKey.Signer? = nil,
       respond: (@Sendable (KeyboardInteractiveChallenge) async -> [String]?)? = nil) {
    self.completion = completion
    self.link = link
    self.keep = keep
    signer = sign
    self.respond = respond
  }

  func sign(_ data: Data, reply: EngineReply) {
    guard let signer else { return reply.cancel() }
    link.ask {
      guard !Task.isCancelled else { return reply.cancel() }
      do { reply.bytes(try await signer(data)) } catch { reply.cancel() }
    }
  }

  func prompt(_ challenge: KeyboardInteractiveChallenge, reply: EngineReply) {
    guard let respond else { return reply.cancel() }
    link.ask {
      guard !Task.isCancelled else { return reply.cancel() }
      if let answers = await respond(challenge), !Task.isCancelled { reply.strings(answers) } else { reply.cancel() }
    }
  }
}

private func milliseconds(_ duration: Duration) -> UInt32 {
  UInt32(clamping: duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
}
