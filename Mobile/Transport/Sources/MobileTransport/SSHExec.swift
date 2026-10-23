import DispatchMobileSSHCore
import Foundation

/// A remote command on its own session channel. The engine hands over one end of a socketpair: stdin
/// is written to it, stdout read from it, and the engine pumps both with backpressure (it reads the
/// socket only as fast as the SSH window allows, and the channel only as fast as the socket drains).
/// Iterate the exec for output (each `next()` is one read: a slow reader stops the remote writer),
/// `write` stdin, `finishInput` for EOF, then `exitStatus()`. Or take the descriptor itself
/// (`takeFileDescriptor`) and hand it to `HelperConnection`.
public final class SSHExec: AsyncSequence, Sendable {
  public enum Output: Sendable, Equatable {
    case stdout(Data)
    case stderr(Data)
  }
  public typealias Element = Output

  let state: ExecState
  let descriptor: Descriptor

  static func start(_ command: String, on session: SessionHandle) async throws -> SSHExec {
    let state = ExecState()
    command.withCString { command in
      dms_exec(session.pointer, command, Engine.retain(state), { context, fd, code, message in
        let state = Engine.borrow(context, as: ExecState.self)
        if fd >= 0 {
          state.started.finish(.success(fd))
        } else {
          state.started.finish(.failure(Engine.error(code, message)))
          // No `exited` follows a failed start: release the context here.
          _ = Engine.release(context, as: ExecState.self)
        }
      }, { context, bytes, length in
        Engine.borrow(context, as: ExecState.self).stderr(Data(bytes: bytes!, count: length))
      }, { context, kind, status, signal in
        Engine.release(context, as: ExecState.self).exited(kind: kind, status: status, signal: signal.map { String(cString: $0) } ?? "")
      })
    }
    let fd = try await state.started.value
    return SSHExec(state: state, fd: fd)
  }

  private init(state: ExecState, fd: Int32) {
    self.state = state
    descriptor = Descriptor(fd)
  }

  /// Writes stdin; suspends while the socket (and so the SSH window) is full.
  public func write(_ data: Data) async throws {
    try await descriptor.write(data)
  }

  /// Sends EOF on stdin.
  public func finishInput() async throws {
    descriptor.finishWriting()
  }

  /// The exit status once the command ended (a signal reports 128).
  public func exitStatus() async throws -> Int32 {
    switch await state.exit {
    case .status(let status): return Int32(bitPattern: status)
    case .signal: return 128
    case .lost: throw SSHTransportError.channelClosed
    }
  }

  /// The first 64 KiB of stderr.
  public var stderr: String { String(decoding: state.collectedStderr, as: UTF8.self) }

  /// Abandons the command: closes the socket, which closes the channel once the remote writes again.
  public func close() async {
    descriptor.close()
  }

  /// Hands the socket over (for `HelperConnection(read:write:)`): this exec no longer reads or closes it. Nothing
  /// iterates it any more, so stderr is no longer queued for iteration; `stderr` keeps its first 64 KiB. nil once
  /// closed, and while a read or write is in flight (take it before using the exec).
  public func takeFileDescriptor() -> Int32? {
    let fd = descriptor.take()
    if fd != nil { state.stopQueueing() }
    return fd
  }

  public struct AsyncIterator: AsyncIteratorProtocol, Sendable {
    let exec: SSHExec
    public mutating func next() async throws -> Output? {
      if let chunk = exec.state.nextStderr() { return .stderr(chunk) }
      if !exec.state.stdoutEnded, let data = try await exec.descriptor.read() {
        if !data.isEmpty { return .stdout(data) }
        exec.state.stdoutEnded = true
      }
      // stdout ended: every stderr chunk arrives before the exit callback.
      _ = await exec.state.exit
      if let chunk = exec.state.nextStderr() { return .stderr(chunk) }
      return nil
    }
  }

  public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(exec: self) }
}

/// The exec's context for the engine's callbacks; released by `exited` (or a failed start).
final class ExecState: @unchecked Sendable {
  enum Exit: Sendable { case status(UInt32), signal(String), lost }

  let started = Completion<Int32>()
  private let lock = NSLock()
  private var pendingStderr: [Data] = []
  /// Off once the descriptor is handed over: a channel that lives as long as the connection (the helper's) would
  /// otherwise keep every byte the host writes to stderr.
  private var queueing = true
  private var allStderr = Data()
  private var ending: Exit?
  private var waiters: [CheckedContinuation<Exit, Never>] = []
  private var ended = false

  var stdoutEnded: Bool {
    get { lock.withLock { ended } }
    set { lock.withLock { ended = newValue } }
  }

  var collectedStderr: Data { lock.withLock { allStderr } }

  func stopQueueing() {
    lock.withLock {
      queueing = false
      pendingStderr = []
    }
  }

  func stderr(_ data: Data) {
    lock.withLock {
      if queueing { pendingStderr.append(data) }
      if allStderr.count < 65_536 { allStderr.append(data.prefix(65_536 - allStderr.count)) }
    }
  }

  func nextStderr() -> Data? {
    lock.withLock { pendingStderr.isEmpty ? nil : pendingStderr.removeFirst() }
  }

  func exited(kind: Int32, status: UInt32, signal: String) {
    let exit: Exit = kind == DMS_EXIT_STATUS ? .status(status) : kind == DMS_EXIT_SIGNAL ? .signal(signal) : .lost
    let waiters = lock.withLock { () -> [CheckedContinuation<Exit, Never>] in
      ending = exit
      defer { self.waiters = [] }
      return self.waiters
    }
    waiters.forEach { $0.resume(returning: exit) }
  }

  /// How the channel ended, if it has.
  var finished: Exit? { lock.withLock { ending } }

  var exit: Exit {
    get async {
      await withCheckedContinuation { continuation in
        let ready = lock.withLock { () -> Exit? in
          if ending == nil { waiters.append(continuation) }
          return ending
        }
        if let ready { continuation.resume(returning: ready) }
      }
    }
  }
}

/// The socket end Swift owns until it is closed or handed over. Every operation holds the number open while it runs:
/// `close()` shuts the socket down at once (a blocked read or write returns) but frees the number only when the last
/// operation in flight finished. Otherwise a read or write queued on `Blocking` could run after the close, on a
/// number the system has given to the next socket opened (a new shell, another host's channel), and steal its bytes
/// or write keystrokes into it.
final class Descriptor: @unchecked Sendable {
  private let lock = NSLock()
  /// nil once closed or handed over: no operation starts after that.
  private var value: Int32?
  private var users = 0
  /// Closed, but still in use: the last operation closes it.
  private var closing: Int32?

  init(_ fd: Int32) { value = fd }
  /// No operation is in flight here: each one retains the descriptor until it finished.
  deinit { if let fd = value ?? closing { Darwin.close(fd) } }

  var fd: Int32? { lock.withLock { value } }

  /// Hands the number over; nil (and nothing changes) when it is closed or an operation is in flight.
  func take() -> Int32? {
    lock.withLock {
      guard users == 0 else { return nil }
      defer { value = nil }
      return value
    }
  }

  /// Shuts the socket down (a read or write blocked on another thread returns) and closes the number once no
  /// operation uses it. Both happen under the lock, so neither can touch a number that was already reused.
  func close() {
    lock.withLock {
      guard let fd = value else { return }
      value = nil
      _ = shutdown(fd, SHUT_RDWR)
      if users == 0 { Darwin.close(fd) } else { closing = fd }
    }
  }

  /// Runs `body` with the number, which stays open until `body` returns; nil when closed or handed over.
  @discardableResult
  func using<T>(_ body: (Int32) throws -> T) rethrows -> T? {
    guard let fd = acquire() else { return nil }
    defer { release() }
    return try body(fd)
  }

  private func acquire() -> Int32? {
    lock.withLock {
      guard let value else { return nil }
      users += 1
      return value
    }
  }

  private func release() {
    lock.withLock {
      users -= 1
      if users == 0, let fd = closing {
        closing = nil
        Darwin.close(fd)
      }
    }
  }

  /// Sends EOF (`shutdown(SHUT_WR)`).
  func finishWriting() {
    using { _ = shutdown($0, SHUT_WR) }
  }

  /// Writes all of `data`; suspends while the socket (and so the SSH window) is full. Throws `channelClosed` once the
  /// descriptor is closed or handed over, or when the socket is shut down.
  func write(_ data: Data) async throws {
    guard let fd = acquire() else { throw SSHTransportError.channelClosed }
    try await Blocking.run { [self] in
      defer { release() }
      try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          let written = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
          if written < 0 {
            if errno == EINTR { continue }
            throw SSHTransportError.channelClosed
          }
          offset += written
        }
      }
    }
  }

  /// One read of up to 256 KiB: empty at end of file (or on an error), nil once the descriptor is closed or handed over.
  func read() async throws -> Data? {
    guard let fd = acquire() else { return nil }
    return try await Blocking.run { [self] () -> Data in
      defer { release() }
      var buffer = Data(count: 256 * 1024)
      let count = buffer.withUnsafeMutableBytes { bytes in
        var count: Int
        repeat { count = Darwin.read(fd, bytes.baseAddress, bytes.count) } while count < 0 && errno == EINTR
        return count
      }
      return count > 0 ? buffer.prefix(count) : Data()
    }
  }
}

/// Blocking socket calls off the cooperative pool.
enum Blocking {
  private static let queue = DispatchQueue(label: "yachts.dispatch.mobile-ssh.io", attributes: .concurrent)

  static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result { try work() }) }
    }
  }
}
