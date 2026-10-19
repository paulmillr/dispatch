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
  private let descriptor: Descriptor

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
    guard let fd = descriptor.fd else { throw SSHTransportError.channelClosed }
    try await Blocking.run {
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

  /// Sends EOF on stdin.
  public func finishInput() async throws {
    if let fd = descriptor.fd { _ = shutdown(fd, SHUT_WR) }
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
  /// iterates it any more, so stderr is no longer queued for iteration; `stderr` keeps its first 64 KiB.
  public func takeFileDescriptor() -> Int32? {
    let fd = descriptor.take()
    if fd != nil { state.stopQueueing() }
    return fd
  }

  public struct AsyncIterator: AsyncIteratorProtocol, Sendable {
    let exec: SSHExec
    public mutating func next() async throws -> Output? {
      if let chunk = exec.state.nextStderr() { return .stderr(chunk) }
      if let fd = exec.descriptor.fd, !exec.state.stdoutEnded {
        let data = try await Blocking.run { () -> Data in
          var buffer = Data(count: 256 * 1024)
          let count = buffer.withUnsafeMutableBytes { bytes in
            var count: Int
            repeat { count = read(fd, bytes.baseAddress, bytes.count) } while count < 0 && errno == EINTR
            return count
          }
          return count > 0 ? buffer.prefix(count) : Data()
        }
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

/// The socket end Swift owns until it is closed or handed over.
final class Descriptor: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Int32?

  init(_ fd: Int32) { value = fd }
  deinit { if let value { Darwin.close(value) } }

  var fd: Int32? { lock.withLock { value } }

  func take() -> Int32? {
    lock.withLock {
      defer { value = nil }
      return value
    }
  }

  /// Shut down first: a read blocked on another thread returns instead of waiting on a closed number.
  func close() {
    if let fd = take() {
      _ = shutdown(fd, SHUT_RDWR)
      Darwin.close(fd)
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
