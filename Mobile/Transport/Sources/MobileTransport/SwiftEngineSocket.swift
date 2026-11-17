import Darwin
import Dispatch
import Foundation

/// A channel's socketpair, as the seam states it (`EngineSession`, Channels): AF_UNIX stream, FD_CLOEXEC and
/// SO_NOSIGPIPE on both ends, 1 MiB send and receive buffers; the caller's end blocking, the engine's non-blocking.
enum SwiftEngineSocketPair {
  /// The engine's end and the caller's. Fails with `network(<the OS's text>)`, leaving nothing open.
  static func make() throws(SSHTransportError) -> (engine: Int32, caller: Int32) {
    var fds: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw .network(String(cString: strerror(errno))) }
    var one: Int32 = 1, buffer: Int32 = 1 << 20
    let size = socklen_t(MemoryLayout<Int32>.size)
    for fd in fds {
      // The caller's end must not reach a child the app spawns; the engine's never leaves this process either.
      guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, size) == 0,
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buffer, size) == 0, setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, size) == 0
      else { try fail(fds) }
    }
    // O_NONBLOCK is per open file: the caller's end stays blocking.
    let flags = fcntl(fds[0], F_GETFL)
    guard flags >= 0, fcntl(fds[0], F_SETFL, flags | O_NONBLOCK) == 0 else { try fail(fds) }
    return (fds[0], fds[1])
  }

  private static func fail(_ fds: [Int32]) throws(SSHTransportError) -> Never {
    let error = SSHTransportError.network(String(cString: strerror(errno)))
    fds.forEach { _ = Darwin.close($0) }
    throw error
  }
}

/// What a socket waits for, for `SwiftEngine.parked` (tests).
enum SwiftEngineSocketWait: Sendable, Equatable {
  /// The caller wrote nothing yet: input waits for it.
  case readable
  /// The caller's receive buffer is full: output waits for the caller to read.
  case writable
}

/// The engine's end of one channel's socketpair: non-blocking, driven by two dispatch sources (kqueue). A read or
/// write that would block suspends its task until the source fires, so a stalled caller parks no thread and nothing
/// polls: the sources are armed only while a task waits, and disarmed (suspended) as they fire.
///
/// One reader and one writer at a time (the channel's input and output pumps). `close()` wakes both, cancels the
/// sources and closes the number only once both cancellation handlers ran (dispatch's rule: the descriptor stays open
/// until its sources are done with it); every syscall on the number happens under the lock and checks `closed`
/// first, so none can reach a number the system has given to something else.
final class SwiftEngineSocket: @unchecked Sendable {
  enum Read: Sendable, Equatable {
    case data([UInt8])
    /// The caller's end of input (shutdown(SHUT_WR) or close), or an error that is the same for the channel.
    case end
    /// This end was closed (`close()`).
    case closed
  }

  /// Most bytes one `read` returns (russh's chunk too).
  static let readChunk = 256 * 1024

  private static let queue = DispatchQueue(label: "yachts.dispatch.mobile-ssh.swift-sockets")

  private let fd: Int32
  private let parked: (@Sendable (SwiftEngineSocketWait) -> Void)?
  private let retrying: (@Sendable (SwiftEngineSocketWait) -> Void)?
  private let lock = NSLock()
  private let readSource: any DispatchSourceRead
  private let writeSource: any DispatchSourceWrite
  // Each source is inactive until first armed, then running (armed) or suspended. Guarded by `lock`.
  private var activated: (read: Bool, write: Bool) = (false, false)
  private var armed: (read: Bool, write: Bool) = (false, false)
  private var waiters: (read: CheckedContinuation<Void, Never>?, write: CheckedContinuation<Void, Never>?)
  private var closed = false
  private var cancelled = 0
  private var released = false
  private var closeWaiters: [CheckedContinuation<Void, Never>] = []
  /// Reused for every read (one reader at a time): the caller's keystrokes need no 256 KiB allocation each.
  private var buffer = [UInt8](repeating: 0, count: SwiftEngineSocket.readChunk)

  /// `parked` (tests) hears each wait once armed; `retrying` (tests) runs after an EAGAIN, before the wait is armed,
  /// the window where the caller's next move must not be lost (the source is level-triggered: arming it then fires at
  /// once when the socket is ready, `SwiftEngineSocketTests`).
  init(_ fd: Int32, parked: (@Sendable (SwiftEngineSocketWait) -> Void)? = nil,
       retrying: (@Sendable (SwiftEngineSocketWait) -> Void)? = nil) {
    self.fd = fd
    self.parked = parked
    self.retrying = retrying
    readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: Self.queue)
    writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: Self.queue)
    // Weak: the sources (and so their handlers) belong to this object, which lives until `close()` returned.
    readSource.setEventHandler { [weak self] in self?.fired(read: true) }
    writeSource.setEventHandler { [weak self] in self?.fired(read: false) }
    readSource.setCancelHandler { [weak self] in self?.sourceCancelled() }
    writeSource.setCancelHandler { [weak self] in self?.sourceCancelled() }
  }

  deinit {
    // `close()` ran (the bridge always closes): both sources are cancelled and resumed, the number closed.
    precondition(released, "a channel socket was released open")
  }

  /// Up to `readChunk` bytes the caller wrote; waits while there are none.
  func read() async -> Read {
    while true {
      let result = lock.withLock { () -> (Read?, Int32) in
        guard !closed else { return (.closed, 0) }
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count > 0 { return (.data(Array(buffer[..<count])), 0) }
        return count == 0 ? (.end, 0) : (nil, errno)
      }
      if let read = result.0 { return read }
      switch result.1 {
      case EINTR: continue
      case EAGAIN: await wait(read: true)
      // ECONNRESET and the like: nothing more comes from the caller.
      default: return .end
      }
    }
  }

  /// Writes all of `bytes`, waiting while the caller's receive buffer is full. False once the caller closed its end
  /// (EPIPE) or this end was closed: the rest is dropped.
  func write(_ bytes: [UInt8]) async -> Bool {
    var offset = 0
    while offset < bytes.count {
      let result = lock.withLock { () -> (Int, Int32) in
        guard !closed else { return (-1, EBADF) }
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset) }
        return (written, written < 0 ? errno : 0)
      }
      if result.0 >= 0 {
        offset += result.0
        continue
      }
      switch result.1 {
      case EINTR: continue
      case EAGAIN: await wait(read: false)
      default: return false
      }
    }
    return true
  }

  /// The remote's end of output: the caller reads end of file after everything written.
  func finishWriting() {
    lock.withLock { if !closed { _ = shutdown(fd, SHUT_WR) } }
  }

  /// Stops both directions (a waiting `read` returns `.closed`, a waiting `write` false) and returns once the number
  /// is closed: the caller's reads then end and its writes fail with EPIPE. Idempotent.
  func close() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let (woken, done) = lock.withLock { () -> ([CheckedContinuation<Void, Never>], Bool) in
        if released { return ([], true) }
        closeWaiters.append(continuation)
        guard !closed else { return ([], false) }
        closed = true
        let woken = [waiters.read, waiters.write].compactMap { $0 }
        waiters = (nil, nil)
        // A cancelled source runs its cancellation handler only once running: start or resume the ones that are not.
        readSource.cancel()
        writeSource.cancel()
        arm(readSource, activated: &activated.read, armed: &armed.read)
        arm(writeSource, activated: &activated.write, armed: &armed.write)
        return (woken, false)
      }
      woken.forEach { $0.resume() }
      if done { continuation.resume() }
    }
  }

  private func wait(read: Bool) async {
    retrying?(read ? .readable : .writable)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let resumeNow = lock.withLock { () -> Bool in
        guard !closed else { return true }
        if read {
          waiters.read = continuation
          arm(readSource, activated: &activated.read, armed: &armed.read)
        } else {
          waiters.write = continuation
          arm(writeSource, activated: &activated.write, armed: &armed.write)
        }
        return false
      }
      if resumeNow {
        continuation.resume()
      } else {
        parked?(read ? .readable : .writable)
      }
    }
  }

  /// Starts or resumes `source` unless it runs. Under `lock`.
  private func arm(_ source: any DispatchSourceProtocol, activated: inout Bool, armed: inout Bool) {
    if !activated {
      source.activate()
    } else if !armed {
      source.resume()
    }
    (activated, armed) = (true, true)
  }

  /// A source fired: disarm it (level-triggered, it would fire again while the condition holds and nobody acts on it)
  /// and wake its waiter, which retries the syscall. Spurious events only cost a retry.
  private func fired(read: Bool) {
    let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      guard !closed else { return nil }
      if read, armed.read {
        armed.read = false
        readSource.suspend()
      } else if !read, armed.write {
        armed.write = false
        writeSource.suspend()
      }
      defer { if read { waiters.read = nil } else { waiters.write = nil } }
      return read ? waiters.read : waiters.write
    }
    waiter?.resume()
  }

  private func sourceCancelled() {
    let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      cancelled += 1
      guard cancelled == 2 else { return [] }
      _ = Darwin.close(fd)
      released = true
      defer { closeWaiters = [] }
      return closeWaiters
    }
    waiters.forEach { $0.resume() }
  }
}
