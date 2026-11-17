import Darwin
import Foundation
@testable import SSHEngine

/// `ScriptedServer` on a TCP port of 127.0.0.1: an accept thread and one thread per connection, each owning its own
/// `ScriptedServer` (made from the shared configuration and host key) and driving it with non-blocking I/O under
/// `poll`, so reading goes on while output waits for the client (both sides' windows bound what queues). Tests reach a
/// connection through `connection(_:)`: its `log`, and commands run on its thread (`release`, `startRekey`, `drop`).
/// A message the server cannot take ends the connection with a DISCONNECT (protocol error) and `ServerLog.failure`.
/// `shutdown` closes the listener and every socket and joins every thread; afterwards nothing of the server is left
/// running. The accept thread holds the server until then, so a test must call it (a teardown block).
final class LoopbackServer: @unchecked Sendable {
  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  /// One accepted connection: its log, and a queue of work for its thread.
  final class Connection: @unchecked Sendable {
    let index: Int
    let log: Watched<ServerLog>
    fileprivate let wake: (read: Int32, write: Int32)
    private let lock = NSLock()
    private var work: [(ScriptedServer) -> Void] = []
    private var stopping = false
    fileprivate let finished = DispatchSemaphore(value: 0)

    fileprivate init(index: Int) throws {
      self.index = index
      log = Watched(ServerLog())
      wake = try makePipe()
    }

    deinit {
      Darwin.close(wake.read)
      Darwin.close(wake.write)
    }

    /// Runs `body` on the connection's thread, with its server, before it next reads.
    func perform(_ body: @escaping (ScriptedServer) -> Void) {
      lock.withLock { work.append(body) }
      signal(wake.write)
    }

    /// Lets the held output go (`ScriptedServer.Configuration.holdAt`).
    func release() { perform { $0.release() } }

    /// Starts a key re-exchange from the server's side.
    func startRekey() { perform { $0.startRekey() } }

    /// Closes the TCP connection without a DISCONNECT (a lost link).
    func drop() {
      lock.withLock { stopping = true }
      signal(wake.write)
    }

    fileprivate func take() -> (work: [(ScriptedServer) -> Void], stop: Bool) {
      lock.withLock {
        defer { work = [] }
        return (work, stopping)
      }
    }
  }

  let port: Int
  let configuration: ScriptedServer.Configuration
  let identity: ServerHostKey
  private let listener: Int32
  private let wake: (read: Int32, write: Int32)
  private let accepting = DispatchSemaphore(value: 0)
  private let accepted = Watched<[Connection]>([])
  private let lock = NSLock()
  private var stopped = false

  init(configuration: ScriptedServer.Configuration, identity: ServerHostKey) throws {
    self.configuration = configuration
    self.identity = identity
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard socket >= 0 else { throw Failure(description: "socket: \(String(cString: strerror(errno)))") }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
        Darwin.bind(socket, address, length) == 0 && Darwin.listen(socket, 64) == 0
          && getsockname(socket, address, &length) == 0
      }
    }
    guard bound, let wake = try? makePipe() else {
      let reason = String(cString: strerror(errno))
      Darwin.close(socket)
      throw Failure(description: "listening on 127.0.0.1: \(reason)")
    }
    _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK)
    listener = socket
    self.wake = wake
    port = Int(UInt16(bigEndian: address.sin_port))
    let thread = Thread { [self] in acceptLoop() }
    thread.name = "loopback-ssh-accept"
    thread.start()
  }

  deinit { shutdown() }

  /// The `index`-th connection accepted (from 0), once it has been.
  func connection(_ index: Int = 0, timeout: Duration = .seconds(10)) async throws -> Connection {
    try await accepted.wait("connection \(index)", timeout: timeout) { $0.count > index }[index]
  }

  /// Connections accepted so far.
  var connections: [Connection] { accepted.value }

  /// Closes the listener and every connection, and waits for every thread to finish (10 s at most each; a thread
  /// that does not is a failure the caller sees as `false`).
  @discardableResult
  func shutdown() -> Bool {
    let first = lock.withLock { () -> Bool in
      defer { stopped = true }
      return !stopped
    }
    guard first else { return true }
    signal(wake.write)
    var joined = accepting.wait(timeout: .now() + 10) == .success
    for connection in accepted.value {
      connection.drop()
      joined = connection.finished.wait(timeout: .now() + 10) == .success && joined
    }
    Darwin.close(listener)
    Darwin.close(wake.read)
    Darwin.close(wake.write)
    return joined
  }

  private var isStopped: Bool { lock.withLock { stopped } }

  private func acceptLoop() {
    defer { accepting.signal() }
    while !isStopped {
      var fds = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0), pollfd(fd: wake.read, events: Int16(POLLIN), revents: 0)]
      guard poll(&fds, 2, -1) >= 0 || errno == EINTR else { return }
      if fds[1].revents != 0 { return }
      guard fds[0].revents != 0 else { continue }
      let socket = Darwin.accept(listener, nil, nil)
      guard socket >= 0 else { continue }
      guard !isStopped, let connection = try? Connection(index: accepted.value.count) else {
        Darwin.close(socket)
        return
      }
      accepted.update { $0.append(connection) }
      let seed = UInt64(0x5E4E + connection.index)
      let thread = Thread { [self] in
        Self.serve(socket, connection: connection, configuration: configuration, identity: identity, seed: seed)
        connection.finished.signal()
      }
      thread.name = "loopback-ssh-\(connection.index)"
      thread.start()
    }
  }

  /// One connection's loop: the server's output written as the socket takes it, input read whenever it comes (unless
  /// 8 MiB of output already wait), commands run between reads. Ends at the client's EOF, an error, a server failure
  /// or `drop`; closes the socket and marks the log ended.
  private static func serve(_ socket: Int32, connection: Connection, configuration: ScriptedServer.Configuration,
                            identity: ServerHostKey, seed: UInt64) {
    var on: Int32 = 1
    _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    _ = setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK)
    let server = ScriptedServer(configuration: configuration, identity: identity, seed: seed, log: connection.log)
    var pending: [UInt8] = []
    var written = 0
    var failure: String?
    server.start()
    pending += server.takeOutbound()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    loop: while true {
      let waiting = pending.count - written
      var events = Int16(waiting > 0 ? POLLOUT : 0)
      if waiting < 8 * 1024 * 1024 { events |= Int16(POLLIN) }
      var fds = [pollfd(fd: socket, events: events, revents: 0), pollfd(fd: connection.wake.read, events: Int16(POLLIN), revents: 0)]
      if poll(&fds, 2, -1) < 0 {
        if errno == EINTR { continue }
        failure = "poll: \(String(cString: strerror(errno)))"
        break
      }
      if fds[1].revents != 0 {
        drain(connection.wake.read)
        let (work, stop) = connection.take()
        if stop { break }
        work.forEach { $0(server) }
      }
      if fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
        let count = buffer.withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress, $0.count) }
        if count == 0 { break }
        if count < 0 {
          if errno != EAGAIN && errno != EINTR { break }
        } else {
          do {
            try server.receive(Array(buffer[0..<count]))
          } catch {
            failure = "\(error)"
            server.sendDisconnect(2, "the scripted server cannot go on")
            pending += server.takeOutbound()
            _ = pending[written...].withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) }
            break
          }
        }
      }
      pending += server.takeOutbound()
      while written < pending.count {
        let count = pending[written...].withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) }
        if count < 0 {
          if errno == EAGAIN || errno == EINTR { break }
          break loop
        }
        written += count
      }
      if written == pending.count {
        pending = []
        written = 0
      } else if written > 1 << 20 {
        pending.removeFirst(written)
        written = 0
      }
    }
    Darwin.close(socket)
    connection.log.update {
      if let failure, $0.failure == nil { $0.failure = failure }
      $0.ended = true
    }
  }
}

private func makePipe() throws -> (read: Int32, write: Int32) {
  var fds: [Int32] = [0, 0]
  guard pipe(&fds) == 0 else { throw LoopbackServer.Failure(description: "pipe: \(String(cString: strerror(errno)))") }
  for fd in fds { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
  return (fds[0], fds[1])
}

private func signal(_ fd: Int32) {
  var byte: UInt8 = 1
  _ = Darwin.write(fd, &byte, 1)
}

private func drain(_ fd: Int32) {
  var bytes = [UInt8](repeating: 0, count: 64)
  while bytes.withUnsafeMutableBytes({ Darwin.read(fd, $0.baseAddress, $0.count) }) > 0 {}
}
