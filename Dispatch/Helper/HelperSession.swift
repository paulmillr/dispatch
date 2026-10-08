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

    struct Shell: Codable, Equatable, Sendable {
      let pid: UInt64
    }

    struct Account: Codable, Equatable, Sendable {
      let uid: UInt32
      let home: String
    }

    struct Identity: Codable, Equatable, Sendable {
      let host: String
      let boot: String
      let hostname: String
      let os: String
      let distribution: String?
      let os_name: String?

      enum CodingKeys: String, CodingKey { case host, boot, hostname, os, distribution, os_name }

      func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(host, forKey: .host)
        try fields.encode(boot, forKey: .boot)
        try fields.encode(hostname, forKey: .hostname)
        try fields.encode(os, forKey: .os)
        try fields.encode(distribution, forKey: .distribution)
        try fields.encode(os_name, forKey: .os_name)
      }
    }

    enum CodingKeys: String, CodingKey {
      case version, os, arch, plugins, unavailable_harnesses, ops, account, identity, terminal, process
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
    }
  }

  let connection: HelperConnection
  let info: Info
  let exited: AsyncStream<Int32>
  fileprivate let process: Process
  private final class Identifier: @unchecked Sendable {
    let lock = NSLock()
    var value: Int32 = 0
  }
  private let identifier: Identifier
  fileprivate var pid: Int32 { identifier.lock.withLock { identifier.value } }

  init(process: Process) async throws {
    let ticket = try AppReplay.open(kind: "helper", input: JSONEncoder().encode(AppReplay.Launch(process)))
    let identifier = Identifier()
    self.identifier = identifier
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    let (exited, continuation) = AsyncStream<Int32>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    process.terminationHandler = { process in
      try? ticket?.emit(kind: "exit", data: JSONEncoder().encode(process.terminationStatus))
      continuation.yield(process.terminationStatus)
      continuation.finish()
    }
    if ticket?.replaying != true {
      do {
        try process.run()
        identifier.lock.withLock { identifier.value = process.processIdentifier }
        try ticket?.emit(kind: "started", data: JSONEncoder().encode(process.processIdentifier))
      } catch {
        try ticket?.emit(kind: "error", data: JSONEncoder().encode(AppReplay.Failure(error)))
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
          let value = try JSONDecoder().decode(Int32.self, from: event.data)
          if event.kind == "in.started" { identifier.lock.withLock { identifier.value = value } }
          else { continuation.yield(value); continuation.finish() }
        } catch {
          AppReplay.fail(error)
          continuation.finish()
        }
      })
    self.process = process
    self.connection = connection
    self.exited = exited
    do {
      info = try await connection.request("hello", params: [String: String]())
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
      connection.close()
      if process.isRunning { process.terminate() }
      throw error
    }
  }

  deinit {
    close()
  }

  /// EOF on its stdin is the helper's orderly shutdown (replies and capture flushed; SIGTERM would
  /// lose the capture's last rows); one still running a second later is terminated.
  func close() {
    connection.close()
    let process = process
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(1)) {
      if process.isRunning { process.terminate() }
    }
  }
}

/// All local feature families borrow the same helper process and connection; remote
/// helpers are lent by the SSH connection that owns and closes them.
actor HelperApp {
  static let shared = HelperApp()
  private var pending: (UUID, Task<HelperSession, any Error>)?
  private var closing: Task<(pid: Int32, status: Int32)?, Never>?
  private var remote: [SSHConnectionID: HelperConnection] = [:]

  func borrow(_ connection: HelperConnection, for provider: SSHConnectionID) {
    remote[provider] = connection
  }

  func forget(_ provider: SSHConnectionID) {
    remote.removeValue(forKey: provider)
  }

  func connection(_ endpoint: HelperWorkspace.Endpoint) async throws -> HelperConnection {
    guard let provider = endpoint.connection else { return try await connection() }
    guard let connection = remote[provider] else {
      throw HelperFailure(code: "unavailable", message: "SSH helper is unavailable.")
    }
    return connection
  }

  /// The local helper: the bundled binary. Only a Debug build's test run may substitute another
  /// (DISPATCH_HELPER4_EXECUTABLE); the same variable in a terminal's environment names that
  /// terminal's helper, and an app launched from there must not adopt it.
  static var executable: URL? {
    #if DEBUG
    if Home.testing, let path = ProcessInfo.processInfo.environment["DISPATCH_HELPER4_EXECUTABLE"] {
      return URL(fileURLWithPath: path)
    }
    #endif
    return Bundle.main.url(forResource: "dispatch-helper", withExtension: nil)
  }


  func connection() async throws -> HelperConnection {
    try await session().connection
  }

  func session() async throws -> HelperSession {
    if pending == nil { await closing?.value }
    if pending == nil {
      closing = nil
      pending = (
        UUID(),
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
