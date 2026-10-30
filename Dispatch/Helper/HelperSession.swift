import Foundation

/// Owns the helper command and its bus. Terminal ownership stays inside the helper.
final class HelperSession: @unchecked Sendable {
  struct Info: Codable, Equatable, Sendable {
    let version: UInt64
    let os: String
    let arch: String
    let plugins: [String]
    let unavailable_harnesses: [String]
    let ops: [String]
    let limit: UInt32?
    let chunkKind: UInt8?
    let chunkLimit: UInt32?
    /// The account and machine the helper runs on (absent from older helpers).
    let account: Account?
    let identity: Identity?
    /// The SSH login terminal a remote helper wraps and its shell process (absent locally).
    let terminal: UInt64?
    let process: Shell?
    /// The opt-in features the hello request named and this helper accepted (helper/PROTOCOL.md, Features); absent
    /// from older helpers and for clients that named none.
    var features: [String]? = nil

    struct Shell: Codable, Equatable, Sendable {
      let pid: UInt64
    }

    struct Account: Codable, Equatable, Sendable {
      let uid: UInt32
      let home: String
      /// The login environment's HOME, when the helper reports it (the iPhone app's "~"; absent from current helpers).
      var login_home: String? = nil
    }

    struct Identity: Codable, Equatable, Sendable {
      let host: String
      let boot: String
      let hostname: String
      let os: String
      let distribution: String?
      let os_name: String?
      /// "26.1", "24.04" and "macOS 26.1", "Ubuntu 24.04" (newer helpers; the iPhone app's host rows show the label).
      var os_version: String? = nil
      var os_label: String? = nil

      enum CodingKeys: String, CodingKey { case host, boot, hostname, os, distribution, os_name, os_version, os_label }

      func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(host, forKey: .host)
        try fields.encode(boot, forKey: .boot)
        try fields.encode(hostname, forKey: .hostname)
        try fields.encode(os, forKey: .os)
        try fields.encode(distribution, forKey: .distribution)
        try fields.encode(os_name, forKey: .os_name)
        // Absent from older helpers' records: written only when the helper sent them.
        try fields.encodeIfPresent(os_version, forKey: .os_version)
        try fields.encodeIfPresent(os_label, forKey: .os_label)
      }
    }

    enum CodingKeys: String, CodingKey {
      // `features` is written only when the helper accepted some; the iPhone's launch cache keeps them with the hello.
      case version, os, arch, plugins, unavailable_harnesses, ops, account, identity, terminal, process, features
      case limit = "frame_limit"
      case chunkKind = "chunk_kind"
      case chunkLimit = "chunk_limit"
    }

    func encode(to encoder: any Encoder) throws {
      var fields = encoder.container(keyedBy: CodingKeys.self)
      try fields.encode(version, forKey: .version)
      try fields.encode(os, forKey: .os)
      try fields.encode(arch, forKey: .arch)
      try fields.encode(plugins, forKey: .plugins)
      try fields.encode(unavailable_harnesses, forKey: .unavailable_harnesses)
      try fields.encode(ops, forKey: .ops)
      try fields.encode(limit, forKey: .limit)
      try fields.encode(chunkKind, forKey: .chunkKind)
      try fields.encode(chunkLimit, forKey: .chunkLimit)
      try fields.encode(account, forKey: .account)
      try fields.encode(identity, forKey: .identity)
      try fields.encode(terminal, forKey: .terminal)
      try fields.encode(process, forKey: .process)
      try fields.encodeIfPresent(features, forKey: .features)
    }
  }

  /// The opt-in hello features the Mac names (docs/ios.md lists the iPhone's). `terminals.window` only with
  /// `outputWindow` on.
  static var features: [String] {
    ["terminals.coalesce", ChatAttachment.feature, screensHost, terminalsFollow, requestsBacklog]
      + (outputWindow ? [terminalsWindow] : [])
  }
  /// `requests.backlog`: the helper keeps reading this app's requests (keystrokes, cancels, `terminals.follow`,
  /// pings) while terminal output to it is backed up, instead of reading nothing until the output drains.
  static let requestsBacklog = "requests.backlog"
  /// `terminals.window`: the helper keeps at most 256 KB of terminal output unacknowledged in flight to this app, and
  /// the app acknowledges what it handed to its terminals (`HelperOutputWindow`), so a reply never waits behind
  /// megabytes parked in SSH and TCP buffers. Off: named only while `outputWindow` is set.
  static let terminalsWindow = "terminals.window"
  /// Names `terminals.window` in the hello of helpers started from now on: Settings › Experimental › Slow connection mode
  /// (`Preferences.outputWindow`, applied by AppDelegate on every save); off by default, and tests turn it on directly.
  nonisolated(unsafe) static var outputWindow = false
  /// The Mac publishes no screens for the tmux and herdr terminals of a helper that accepted this: it reads them from
  /// the multiplexer itself (`HelperWorkspace.publishes`).
  static let screensHost = "screens.host"
  /// `terminals.follow`: a chat tab whose terminal is not on screen stops that terminal's output stream
  /// (`HelperWorkspace.reconsider`); showing it again gets a whole repaint.
  static let terminalsFollow = "terminals.follow"
  /// `login.release`: named only by the SSH greeting probe, whose helper then releases the waiting login
  /// (`SSHBootstrap.startHelper`); a helper that is not such a probe accepts nothing for it.
  static let loginRelease = "login.release"
  private struct Hello: Encodable, Sendable { let features: [String] }

  // The Mac app runs its helper as a child process; the iPhone app reaches helpers over SSH channels only.
  #if canImport(AppKit)
  let connection: HelperConnection
  let info: Info
  let exited: AsyncStream<Int32>
  fileprivate let process: Process
  fileprivate final class Identifier: @unchecked Sendable {
    let lock = NSLock()
    var value: Int32 = 0
  }
  private let identifier: Identifier
  fileprivate var pid: Int32 { identifier.lock.withLock { identifier.value } }

  /// A helper started, its hello sent, not yet greeted (`start`; `init(started:)` waits for the greeting): a caller can
  /// send something on another connection between the two, in a fixed order. One dropped before it became a session
  /// is closed.
  final class Started: @unchecked Sendable {
    fileprivate let connection: HelperConnection
    fileprivate let process: Process
    fileprivate let exited: AsyncStream<Int32>
    fileprivate let identifier: Identifier
    fileprivate let hello: HelperConnection.Call<Info>
    private let lock = NSLock()
    private var adopted = false

    fileprivate init(connection: HelperConnection, process: Process, exited: AsyncStream<Int32>, identifier: Identifier,
                     hello: HelperConnection.Call<Info>) {
      self.connection = connection
      self.process = process
      self.exited = exited
      self.identifier = identifier
      self.hello = hello
    }

    /// Taken by the session it becomes (`init(started:)`), once; false when it was closed or taken before.
    fileprivate func adopt() -> Bool {
      lock.withLock {
        defer { adopted = true }
        return !adopted
      }
    }

    /// Closes the helper unless it became a session (which closes it itself). Idempotent.
    func close() {
      if adopt() { HelperSession.close(connection, process) }
    }

    deinit { close() }
  }

  /// `features`: what the hello names (the Mac's own list unless a caller adds one, as the SSH greeting probe does).
  convenience init(process: Process, features: [String] = HelperSession.features) async throws {
    try await self.init(started: Self.start(process: process, features: features))
  }

  /// Starts `process` and sends its hello (`Started`).
  static func start(process: Process, features: [String] = HelperSession.features) async throws -> Started {
    let ticket = try AppReplay.open(kind: "helper", input: AppReplay.value(AppReplay.Launch(process)))
    let identifier = Identifier()
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    let (exited, continuation) = AsyncStream<Int32>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    process.terminationHandler = { process in
      try? ticket?.emit(kind: "exit", value: AppReplay.value(process.terminationStatus))
      continuation.yield(process.terminationStatus)
      continuation.finish()
    }
    if ticket?.replaying != true {
      do {
        try process.run()
        identifier.lock.withLock { identifier.value = process.processIdentifier }
        try ticket?.emit(kind: "started", value: AppReplay.value(process.processIdentifier))
      } catch {
        try ticket?.emit(kind: "error", value: AppReplay.value(AppReplay.Failure(error)))
        throw error
      }
    }
    try? input.fileHandleForReading.close()
    try? output.fileHandleForWriting.close()
    let connection = HelperConnection(
      read: output.fileHandleForReading, write: input.fileHandleForWriting, ticket: ticket,
      exited: { result in
        do {
          let event = try result.get()
          let value = try AppReplay.decode(Int32.self, event.value)
          if event.kind == "in.started" { identifier.lock.withLock { identifier.value = value } }
          else { continuation.yield(value); continuation.finish() }
        } catch {
          AppReplay.fail(error)
          continuation.finish()
        }
      })
    // Features the Mac asks for (helper/PROTOCOL.md, Features). `terminals.coalesce`: the helper joins a terminal's
    // output notifications for up to 4 ms, so a redrawing agent costs one frame per batch instead of one per tmux
    // output line (fewer wakeups here, fewer packets over SSH). `chat.attachments`: `attachments.put`/`.read` and
    // attachment paths on `chat.send`/`queue.add` (ChatAttachment). `screens.host`: the helper reads the screens of
    // the tmux and herdr terminals this app attaches from the multiplexer (capture-pane, herdr observe) instead of
    // having them published 30 times a second (HelperWorkspace.publishes). `terminals.follow`: the output of a hidden
    // chat tab's terminal is held on the host and repainted when it shows (HelperWorkspace.reconsider).
    // `requests.backlog`: requests are read while output to this app is backed up. `terminals.window` (only with
    // `outputWindow`): acknowledged output (HelperOutputWindow). `login.release` (the SSH greeting probe only):
    // SSHBootstrap.startHelper releases the waiting login through it. A helper that knows no feature answers as before.
    let hello: HelperConnection.Call<Info> = await connection.submit("hello", params: Hello(features: features))
    return Started(connection: connection, process: process, exited: exited, identifier: identifier, hello: hello)
  }

  /// Waits for `started`'s greeting; a helper that fails it is closed.
  init(started: Started) async throws {
    guard started.adopt() else { throw CancellationError() }
    identifier = started.identifier
    process = started.process
    connection = started.connection
    exited = started.exited
    do {
      info = try await started.hello.value
      if info.features?.contains(Self.terminalsWindow) == true { HelperOutputWindow.enable(connection) }
      guard info.version == HelperBinary.version else {
        throw HelperFailure(
          code: "protocol_version", message: "The helper protocol is incompatible.")
      }
      guard let limit = info.limit, let chunkKind = info.chunkKind,
        let chunkLimit = info.chunkLimit
      else {
        throw HelperFailure(
          code: "protocol_version", message: "The helper transport limits are missing.")
      }
      try await connection.configure(
        limit: limit, chunkKind: chunkKind, chunkLimit: chunkLimit, ops: info.ops)
    } catch {
      Self.close(connection, process)
      throw error
    }
  }

  deinit {
    close()
  }

  func close() { Self.close(connection, process) }

  /// EOF on its stdin is the helper's orderly shutdown (replies and capture flushed; SIGTERM would
  /// lose the capture's last rows, all of them while it starts); one still running a second later
  /// is terminated. Also when its hello failed.
  fileprivate static func close(_ connection: HelperConnection, _ process: Process) {
    connection.close()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(1)) {
      if process.isRunning { process.terminate() }
    }
  }
  #endif
}

#if canImport(AppKit)
/// All local feature families borrow the same helper process and connection; remote
/// helpers are lent by the SSH connection that owns and closes them.
actor HelperApp {
  static let shared = HelperApp()
  private var pending: (UUID, Task<HelperSession, any Error>)?
  private var closing: Task<(pid: Int32, status: Int32)?, Never>?
  private var remote: [SSHConnectionID: HelperConnection] = [:]
  private var remoteFeatures: [SSHConnectionID: Set<String>] = [:]

  /// `features`: what the remote helper's hello accepted (`Info.features`).
  func borrow(_ connection: HelperConnection, for provider: SSHConnectionID, features: [String]? = nil) {
    remote[provider] = connection
    remoteFeatures[provider] = Set(features ?? [])
  }

  func forget(_ provider: SSHConnectionID) {
    remote.removeValue(forKey: provider)
    remoteFeatures.removeValue(forKey: provider)
  }

  /// The opt-in features `endpoint`'s helper accepted in its hello; none while it is unavailable.
  func features(_ endpoint: HelperWorkspace.Endpoint) async -> Set<String> {
    guard let provider = endpoint.connection else { return Set((try? await session().info.features) ?? []) }
    return remoteFeatures[provider] ?? []
  }

  func connection(_ endpoint: HelperWorkspace.Endpoint) async throws -> HelperConnection {
    guard let provider = endpoint.connection else { return try await connection() }
    guard let connection = remote[provider] else {
      throw HelperFailure(code: "unavailable", message: "SSH helper is unavailable.")
    }
    return connection
  }

  /// The local helper: the bundled binary. Only a Debug build's test run may substitute another
  /// (DISPATCH_HELPER_EXECUTABLE); the same variable in a terminal's environment names that
  /// terminal's helper, and an app launched from there must not adopt it.
  static var executable: URL? {
    #if DEBUG
    if System.testing, let path = System.environment("DISPATCH_HELPER_EXECUTABLE") {
      return URL(fileURLWithPath: path)
    }
    #endif
    return System.resources.appendingPathComponent("dispatch-helper")
  }


  func connection() async throws -> HelperConnection {
    try await session().connection
  }

  func session() async throws -> HelperSession {
    if pending == nil { await closing?.value }
    if pending == nil {
      closing = nil
      pending = (
        System.uuid(),
        Task {
          let process = Process()
          process.executableURL = Self.executable
          guard process.executableURL != nil else {
            throw HelperFailure(
              code: "unavailable", message: "The bundled helper is missing.")
          }
          process.arguments = ["--stdio"]
          let session = try await HelperSession(process: process)
          if Task.isCancelled {
            session.close()
            throw CancellationError()
          }
          return session
        }
      )
    }
    let (id, task) = pending!
    do {
      return try await task.value
    } catch {
      if pending?.0 == id { pending = nil }
      throw error
    }
  }

  @discardableResult
  func stop() async -> (pid: Int32, status: Int32)? {
    if closing == nil {
      let task = pending?.1
      pending = nil
      task?.cancel()
      closing = Task {
        if let session = try? await task?.value {
          session.close()
          // Keep the observed result for cleanup callers that stop the same lifetime again.
          for await status in session.exited { return (session.pid, status) }
        }
        return nil
      }
    }
    return await closing?.value
  }
}
#endif
