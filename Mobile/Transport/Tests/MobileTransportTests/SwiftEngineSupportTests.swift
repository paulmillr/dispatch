import CryptoKit
import Darwin
import Foundation
@testable import MobileTransport
import SSHEngine
import XCTest

// Scripted fakes of the Swift engine's facade (SSHEngine/Contract), and recorders for the seam's events, for the
// adapter's tests (SwiftEngine*Tests). Nothing here sleeps to synchronise: every wait is on a state change, with a
// deadline only so that a broken adapter fails instead of hanging.

/// Waits for conditions over a lock-guarded state; every change re-checks the waiters. Conditions run under the lock:
/// they read only the state they are given.
final class Watched<State: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var state: State
  private var waiters: [UUID: (condition: @Sendable (State) -> Bool, continuation: CheckedContinuation<Bool, Never>)] = [:]

  init(_ state: State) { self.state = state }

  var value: State { lock.withLock { state } }

  @discardableResult
  func change<T>(_ body: (inout State) -> T) -> T {
    let (result, ready) = lock.withLock { () -> (T, [CheckedContinuation<Bool, Never>]) in
      let result = body(&state)
      let ready = waiters.filter { $0.value.condition(state) }
      ready.keys.forEach { waiters.removeValue(forKey: $0) }
      return (result, ready.values.map(\.continuation))
    }
    ready.forEach { $0.resume(returning: true) }
    return result
  }

  /// True once `condition` holds; false when it did not within `timeout` (a failure, never a synchronisation).
  func until(_ timeout: Duration = .seconds(20), _ condition: @escaping @Sendable (State) -> Bool) async -> Bool {
    let id = UUID()
    return await withCheckedContinuation { continuation in
      let now = lock.withLock { () -> Bool in
        if condition(state) { return true }
        waiters[id] = (condition, continuation)
        return false
      }
      if now { return continuation.resume(returning: true) }
      Task.detached { [weak self] in
        try? await Task.sleep(for: timeout)
        guard let self else { return }
        let expired = lock.withLock { waiters.removeValue(forKey: id) }
        expired?.continuation.resume(returning: false)
      }
    }
  }
}

extension Watched {
  /// A fake's wait for the test to act: true once `condition` holds. After `timeout` it fails the running test, naming
  /// what it waited for, and returns false; a fake must never turn a slow or stuck test into an answer of its own (as
  /// an exit of `.lost`, which reads like the adapter's).
  func waitForTest(_ what: String, timeout: Duration = .seconds(600), _ condition: @escaping @Sendable (State) -> Bool) async -> Bool {
    let held = await until(timeout, condition)
    if !held { XCTFail("a fake waited \(timeout) for the test (\(what)): it is stuck or too slow") }
    return held
  }
}

extension XCTestCase {
  func wait<State>(_ watched: Watched<State>, _ what: String, timeout: Duration = .seconds(20),
                   file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping @Sendable (State) -> Bool) async {
    let held = await watched.until(timeout, condition)
    XCTAssertTrue(held, "timed out waiting for \(what): \(watched.value)", file: file, line: line)
  }
}

// MARK: - Facade fakes

/// A host key for the fakes: an Ed25519 key made now.
func fakeHostKey() -> SSHEngine.HostKey {
  let key = SSHKey(ed25519: Curve25519.Signing.PrivateKey())
  return try! SSHEngine.HostKey(algorithm: .ed25519, blob: Array(publicKeyBlob(key)))
}

/// Connects as `script` says, recording the options.
final class ScriptedConnector: SSHConnector, @unchecked Sendable {
  typealias Script = @Sendable (ConnectOptions, @escaping SSHEngine.HostKeyTrust) async throws(SSHError) -> any SSHSession
  private let script: Script
  let options = Watched<[ConnectOptions]>([])

  init(_ script: @escaping Script) { self.script = script }

  /// Asks `trust` about `session`'s key and connects when it says yes, else throws `hostKeyRejected`.
  convenience init(_ session: ScriptedSession) {
    self.init { _, trust throws(SSHError) in
      guard await trust(session.hostKey) else { throw .hostKeyRejected }
      return session
    }
  }

  func connect(_ options: ConnectOptions, trust: @escaping SSHEngine.HostKeyTrust) async throws(SSHError) -> any SSHSession {
    self.options.change { $0.append(options) }
    return try await script(options, trust)
  }
}

/// A session whose logins and channels the test scripts. `ended()` is decided once (`end`); after it every operation
/// throws `closed(.alreadyEnded)`.
final class ScriptedSession: SSHSession, @unchecked Sendable {
  typealias Login = @Sendable (ScriptedSession, String, Credential) async throws(SSHError) -> AuthOutcome
  typealias Exec = @Sendable (ScriptedSession, String) async throws(SSHError) -> any ExecChannel
  typealias Shell = @Sendable (ScriptedSession, String, TerminalSize) async throws(SSHError) -> any ShellChannel

  struct State: Sendable {
    var ending: SSHError?
    var closes = 0
    var logins: [String] = []
  }

  let hostKey = fakeHostKey()
  let state = Watched(State())
  var login: Login = { _, _, _ in .success }
  var exec: Exec = { _, _ throws(SSHError) in throw .channelOpenFailed(.administrativelyProhibited, description: "") }
  var shell: Shell = { _, _, _ throws(SSHError) in throw .channelOpenFailed(.administrativelyProhibited, description: "") }

  /// Ends the connection; the first reason stands.
  func end(_ reason: SSHError) {
    state.change { if $0.ending == nil { $0.ending = reason } }
  }

  /// Throws once the connection ended (`closed`, as the facade's operations in flight do).
  func pending() async throws(SSHError) -> Never {
    _ = await ended()
    throw .closed(.alreadyEnded)
  }

  private func checkOpen() throws(SSHError) {
    if state.value.ending != nil { throw .closed(.alreadyEnded) }
  }

  func authenticate(user: String, with credential: Credential) async throws(SSHError) -> AuthOutcome {
    try checkOpen()
    state.change { $0.logins.append(user) }
    return try await login(self, user, credential)
  }

  func exec(_ command: String) async throws(SSHError) -> any ExecChannel {
    try checkOpen()
    return try await exec(self, command)
  }

  func shell(term: String, size: TerminalSize) async throws(SSHError) -> any ShellChannel {
    try checkOpen()
    return try await shell(self, term, size)
  }

  func close() async {
    state.change { $0.closes += 1 }
    end(.closed(.byClient))
  }

  func ended() async -> SSHError {
    _ = await state.waitForTest("the session's end") { $0.ending != nil }
    return state.value.ending!
  }
}

/// One fake channel's state, shared by the exec and shell faces. Output is pulled from `supply` one chunk per read
/// (so the test sees exactly how much the adapter consumed), input collected; `stallWrites` holds every write until
/// released.
final class ScriptedChannel: @unchecked Sendable {
  struct State: Sendable {
    /// Output queued by the test, then the end of output (`eof`).
    var queued: [ChannelOutput] = []
    var eof = false
    var reads = 0
    var readBytes = 0
    var received: [UInt8] = []
    var writes = 0
    var pendingWrites = 0
    var stallWrites = false
    var inputFinished = false
    var closed = false
    /// Set by the test, or the connection's end: then `read` throws and `exit` is `.lost` (or the status).
    var connectionEnded = false
    var exit: ChannelExit?
    var resizes: [TerminalSize] = []
    var readsAfterClose = 0
    /// End of output handed to the adapter, and `exit()` asked: where a stuck channel's pump is.
    var endsRead = 0
    var exitAsked = false
  }

  let state = Watched(State())
  /// Output made on demand when nothing is queued (megabyte tests); nil: wait for queued output.
  var supply: (@Sendable () -> ChannelOutput?)?

  init(supply: (@Sendable () -> ChannelOutput?)? = nil) { self.supply = supply }

  func send(_ output: ChannelOutput) { state.change { $0.queued.append(output) } }
  func sendEOF() { state.change { $0.eof = true } }
  /// The server's close: the end of output, then the exit, then the channel closed.
  func finish(_ exit: ChannelExit) { state.change { $0.eof = true; $0.exit = exit; $0.closed = true } }
  /// The exit status arrives (before any close).
  func status(_ exit: ChannelExit) { state.change { $0.exit = exit } }
  func endConnection() { state.change { $0.connectionEnded = true; $0.closed = true } }
  func releaseWrites() { state.change { $0.stallWrites = false } }

  func read() async throws(SSHError) -> ChannelOutput? {
    while true {
      if await !state.waitForTest("output to read", { !$0.queued.isEmpty || $0.eof || $0.closed || $0.connectionEnded || self.supply != nil }) {
        return nil
      }
      let next = state.change { state -> Result<ChannelOutput?, SSHError>? in
        if state.closed && !state.eof { state.readsAfterClose += 1 }
        if state.connectionEnded { return .failure(.closed(.connectionLost)) }
        if !state.queued.isEmpty {
          state.reads += 1
          let output = state.queued.removeFirst()
          if case .stdout(let bytes) = output { state.readBytes += bytes.count }
          return .success(output)
        }
        if state.eof || state.closed {
          state.endsRead += 1
          return .success(nil)
        }
        return nil
      }
      if let next { return try next.get() }
      if let supply {
        guard let output = supply() else {
          sendEOF()
          continue
        }
        state.change {
          $0.reads += 1
          if case .stdout(let bytes) = output { $0.readBytes += bytes.count }
        }
        return output
      }
    }
  }

  func write(_ bytes: [UInt8]) async throws(SSHError) {
    let open = state.change { state -> Bool in
      guard !state.inputFinished, !state.closed else { return false }
      state.pendingWrites += 1
      return true
    }
    guard open else { throw .usage(.channelClosed) }
    _ = await state.waitForTest("the stalled write's release") { !$0.stallWrites || $0.closed }
    let taken = state.change { state -> Bool in
      state.pendingWrites -= 1
      guard !state.closed else { return false }
      state.received += bytes
      state.writes += 1
      return true
    }
    guard taken else { throw .usage(.channelClosed) }
  }

  func finishInput() async { state.change { $0.inputFinished = true } }

  func close() async { state.change { $0.closed = true } }

  func exit() async -> ChannelExit {
    state.change { $0.exitAsked = true }
    _ = await state.waitForTest("the channel's close") { $0.closed }
    return state.value.exit ?? .lost
  }
}

final class ScriptedExec: ExecChannel {
  let core: ScriptedChannel
  init(_ core: ScriptedChannel) { self.core = core }
  func write(_ bytes: [UInt8]) async throws(SSHError) { try await core.write(bytes) }
  func finishInput() async { await core.finishInput() }
  func read() async throws(SSHError) -> ChannelOutput? { try await core.read() }
  func close() async { await core.close() }
  func exit() async -> ChannelExit { await core.exit() }
}

final class ScriptedShell: ShellChannel {
  let core: ScriptedChannel
  init(_ core: ScriptedChannel) { self.core = core }
  func write(_ bytes: [UInt8]) async throws(SSHError) { try await core.write(bytes) }
  func read() async throws(SSHError) -> [UInt8]? {
    switch try await core.read() {
    case .stdout(let bytes)?, .stderr(let bytes)?: bytes
    case nil: nil
    }
  }
  func resize(_ size: TerminalSize) throws(SSHError) {
    let open = core.state.change { state -> Bool in
      guard !state.closed else { return false }
      if state.resizes.last != size { state.resizes.append(size) }
      return true
    }
    guard open else { throw .usage(.channelClosed) }
  }
  func close() async { await core.close() }
  func exit() async -> ChannelExit { await core.exit() }
}

// MARK: - Seam recorders

/// Every call a channel's events got, in order.
final class RecordedChannel: EngineChannelEvents, @unchecked Sendable {
  enum Call: Sendable, Equatable {
    case opened(Result<Int32, SSHTransportError>)
    case stderr(Data)
    case exited(EngineExit)
  }

  let calls = Watched<[Call]>([])
  /// Calls that came after `exited` or a failed `opened` (each a broken rule).
  let late = Watched<Int>(0)
  let mainThread = Watched<Int>(0)

  private func record(_ call: Call) {
    if Thread.isMainThread { mainThread.change { $0 += 1 } }
    calls.change { calls in
      if let last = calls.last, case .exited = last { late.change { $0 += 1 } }
      if let last = calls.last, case .opened(.failure) = last { late.change { $0 += 1 } }
      calls.append(call)
    }
  }

  func opened(_ result: Result<Int32, SSHTransportError>) { record(.opened(result)) }
  func stderr(_ data: Data) { record(.stderr(data)) }
  func exited(_ exit: EngineExit) { record(.exited(exit)) }

  var descriptor: Int32? {
    if case .opened(.success(let fd))? = calls.value.first { return fd }
    return nil
  }

  var exit: EngineExit? {
    for call in calls.value { if case .exited(let exit) = call { return exit } }
    return nil
  }

  var stderrBytes: Data { Self.stderr(in: calls.value) }

  /// For conditions, which run under `calls`' lock and must not read it again.
  static func stderr(in calls: [Call]) -> Data {
    calls.reduce(into: Data()) { if case .stderr(let data) = $1 { $0.append(data) } }
  }
}

/// A session's events: the host key questions (answered by `decide`, or later through `answers`) and the ends.
final class RecordedSession: EngineSessionEvents, @unchecked Sendable {
  struct State: Sendable {
    var keys: [EngineHostKey] = []
    var answers: [@Sendable (Bool) -> Void] = []
    var disconnects: [SSHTransportError] = []
    var callsAfterEnd = 0
    var mainThread = 0
  }

  let state = Watched(State())
  /// Answers each question at once when set; else the test answers through `state.value.answers`.
  let decide: Bool?

  init(decide: Bool? = true) { self.decide = decide }

  func hostKey(_ key: EngineHostKey, answer: @escaping @Sendable (Bool) -> Void) {
    state.change {
      if !$0.disconnects.isEmpty { $0.callsAfterEnd += 1 }
      if Thread.isMainThread { $0.mainThread += 1 }
      $0.keys.append(key)
      $0.answers.append(answer)
    }
    if let decide { answer(decide) }
  }

  func disconnected(_ reason: SSHTransportError) {
    state.change {
      if !$0.disconnects.isEmpty { $0.callsAfterEnd += 1 }
      if Thread.isMainThread { $0.mainThread += 1 }
      $0.disconnects.append(reason)
    }
  }
}

/// `connected`'s result.
final class ConnectResult: @unchecked Sendable {
  let results = Watched<[Result<any EngineSession, SSHTransportError>]>([])
  var callback: @Sendable (Result<any EngineSession, SSHTransportError>) -> Void {
    { result in self.results.change { $0.append(result) } }
  }

  var session: (any EngineSession)? {
    if case .success(let session)? = results.value.first { return session }
    return nil
  }

  var error: SSHTransportError? {
    if case .failure(let error)? = results.value.first { return error }
    return nil
  }
}

/// A login's `done`.
final class LoginResult: @unchecked Sendable {
  let results = Watched<[Result<EngineAuthOutcome, SSHTransportError>]>([])
  var done: @Sendable (Result<EngineAuthOutcome, SSHTransportError>) -> Void {
    { result in self.results.change { $0.append(result) } }
  }
}

// MARK: - Process facts

enum ProcessCounts {
  /// Open descriptors of this process.
  static var descriptors: Int {
    (0..<min(Int(getdtablesize()), 1 << 16)).reduce(0) { $0 + (fcntl(Int32($1), F_GETFD) != -1 ? 1 : 0) }
  }

  /// Threads of this process.
  static var threads: Int {
    var list: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
    for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[index]) }
    vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                  vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
    return Int(count)
  }
}

/// Blocking socket calls on the caller's side, off the cooperative pool (as `Descriptor` makes them).
enum CallerSide {
  /// The longest a caller-side call waits for the adapter to make progress: then it fails (ETIMEDOUT), so a broken
  /// adapter fails the test with a message instead of blocking it forever. Not a synchronisation: every wait is on
  /// the socket (poll), and returns as soon as it can go on.
  static let deadline: Duration = .seconds(60)

  /// Waits until `fd` is ready for `events` (POLLIN or POLLOUT); false when `deadline` passed first.
  private static func ready(_ fd: Int32, _ events: Int16, by deadline: ContinuousClock.Instant) -> Bool {
    while true {
      let left = deadline - .now
      guard left > .zero else { return false }
      var entry = pollfd(fd: fd, events: events, revents: 0)
      let milliseconds = Int32(clamping: left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000 + 1)
      let result = poll(&entry, 1, milliseconds)
      if result > 0 { return true }
      if result < 0 && errno != EINTR { return true }  // the next call reports the error
    }
  }

  /// Writes all of `data` (waiting while the socket is full, as a blocking write would, each wait bounded by
  /// `deadline`); false on an error (EPIPE) or when the adapter took nothing for `deadline`.
  static func write(_ fd: Int32, _ data: [UInt8]) async -> Bool {
    (try? await Blocking.run {
      data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          guard ready(fd, Int16(POLLOUT), by: .now + deadline) else { return false }
          let written = send(fd, bytes.baseAddress! + offset, bytes.count - offset, MSG_DONTWAIT)
          if written < 0 {
            if errno == EINTR || errno == EAGAIN { continue }
            return false
          }
          offset += written
        }
        return true
      }
    }) ?? false
  }

  /// Reads until end of file (or `limit` bytes); the bytes, and the errno of a failed read (0 at end of file or the
  /// limit, ETIMEDOUT when nothing came for `deadline`).
  ///
  /// To check the end of file that follows the remote's EOF, read the bytes expected (`limit`), wait until the
  /// adapter shut its end down, then `atEndOfFile`: a reader already blocked in read() when the engine's
  /// shutdown(SHUT_WR) lands can miss that wakeup (Darwin, under load; the engine's close still wakes it), so a test
  /// that holds the channel's close until the caller saw end of file would hang.
  static func readAll(_ fd: Int32, limit: Int = .max) async -> (bytes: [UInt8], error: Int32) {
    (try? await Blocking.run {
      var bytes: [UInt8] = []
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      while bytes.count < limit {
        guard ready(fd, Int16(POLLIN), by: .now + deadline) else { return (bytes, ETIMEDOUT) }
        let count = recv(fd, &buffer, min(buffer.count, limit - bytes.count), MSG_DONTWAIT)
        if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
        if count < 0 { return (bytes, errno) }
        if count == 0 { break }
        bytes += buffer[..<count]
      }
      return (bytes, 0)
    }) ?? ([], -1)
  }

  /// Whether the caller reads end of file now: a read that cannot block finds no data and the end.
  static func atEndOfFile(_ fd: Int32) -> Bool {
    var byte: UInt8 = 0
    return recv(fd, &byte, 1, MSG_DONTWAIT | MSG_PEEK) == 0
  }

  static func isBlocking(_ fd: Int32) -> Bool { fcntl(fd, F_GETFL) & O_NONBLOCK == 0 }
}

/// SHA-256 in lowercase hex, as `HelperBootstrap` names a helper and `shasum -a 256` prints it.
func sha256(_ bytes: some DataProtocol) -> String {
  SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }

/// The fakes themselves, so a broken fake fails here rather than as an adapter failure.
final class SwiftEngineSupportTests: XCTestCase {
  func testFakeChannelQueuesThenEnds() async throws {
    let core = ScriptedChannel()
    core.send(.stdout([1, 2]))
    core.finish(.status(4))
    let first = try await core.read()
    let second = try await core.read()
    XCTAssertEqual(first, .stdout([1, 2]))
    XCTAssertNil(second)
    let exit = await core.exit()
    XCTAssertEqual(exit, .status(4))
  }

  func testWatchedTimesOutWithoutHanging() async {
    let watched = Watched(0)
    let held = await watched.until(.milliseconds(50)) { $0 == 1 }
    XCTAssertFalse(held)
  }
}
