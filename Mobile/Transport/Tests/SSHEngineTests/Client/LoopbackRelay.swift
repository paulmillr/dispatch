#if os(macOS)
import Darwin
import Foundation

/// A loopback TCP relay in front of a test's own sshd, so a test can break the network under a live session without
/// touching the daemon: `cut` resets every relayed connection (both ends see the connection go), `freeze` stops
/// forwarding while keeping the sockets open (a network that went silent). One thread accepts; each direction of each
/// connection has its own thread. `stop` ends them all and closes every socket; nothing outlives it.
final class LoopbackRelay: @unchecked Sendable {
  let port: Int
  private let target: Int
  private let listener: Int32
  /// Written once at `cut`/`stop` and never drained: every thread's poll sees it from then on.
  private let terminal: (read: Int32, write: Int32)
  /// Written once at `freeze`, likewise.
  private let frozen: (read: Int32, write: Int32)
  private let lock = NSLock()
  private var pairs: [Pair] = []
  private var stopped = false
  private let threads = DispatchGroup()

  private final class Pair: @unchecked Sendable {
    let client: Int32
    let server: Int32
    private let lock = NSLock()
    private var remaining = 2

    init(client: Int32, server: Int32) {
      self.client = client
      self.server = server
    }

    /// Unblocks both directions (a thread blocked in read or write returns).
    func shut() {
      Darwin.shutdown(client, SHUT_RDWR)
      Darwin.shutdown(server, SHUT_RDWR)
    }

    /// One direction ended; the second closes both sockets, with a reset.
    func directionEnded() {
      let last = lock.withLock { () -> Bool in
        remaining -= 1
        return remaining == 0
      }
      guard last else { return }
      var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
      for fd in [client, server] {
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        Darwin.close(fd)
      }
    }
  }

  /// Relays connections on a free loopback port to `target`.
  init(to target: Int) throws {
    self.target = target
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { throw LiveSSHD.Failure("pipe") }
    terminal = (fds[0], fds[1])
    guard pipe(&fds) == 0 else { throw LiveSSHD.Failure("pipe") }
    frozen = (fds[0], fds[1])
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { throw LiveSSHD.Failure("socket") }
    self.listener = listener
    var on: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafeMutablePointer(to: &address) { pointer -> Int in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard bind(listener, raw, length) == 0, getsockname(listener, raw, &length) == 0 else { return -1 }
        return Int(UInt16(bigEndian: pointer.pointee.sin_port))
      }
    }
    guard bound > 0, listen(listener, 16) == 0 else {
      Darwin.close(listener)
      throw LiveSSHD.Failure("bind")
    }
    port = bound
    spawn { [self] in acceptLoop() }
  }

  deinit { stop() }

  /// Resets every connection relayed so far (both sides see it end); new connections are still relayed.
  func cut() {
    let current = lock.withLock { () -> [Pair] in
      defer { pairs = [] }
      return pairs
    }
    for pair in current { pair.shut() }
  }

  /// Stops forwarding in both directions for good, sockets left open.
  func freeze() {
    var byte: UInt8 = 1
    _ = Darwin.write(frozen.write, &byte, 1)
  }

  /// Ends every thread and closes every socket; returns once all are gone. Idempotent.
  func stop() {
    let first = lock.withLock { () -> Bool in
      defer { stopped = true }
      return !stopped
    }
    guard first else { return }
    var byte: UInt8 = 1
    _ = Darwin.write(terminal.write, &byte, 1)
    cut()
    threads.wait()
    for fd in [listener, terminal.read, terminal.write, frozen.read, frozen.write] { Darwin.close(fd) }
  }

  private func spawn(_ body: @escaping @Sendable () -> Void) {
    threads.enter()
    let thread = Thread { [threads] in
      body()
      threads.leave()
    }
    thread.start()
  }

  private func acceptLoop() {
    while true {
      var descriptors = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                         pollfd(fd: terminal.read, events: Int16(POLLIN), revents: 0)]
      guard Darwin.poll(&descriptors, 2, -1) >= 0 || errno == EINTR else { return }
      if descriptors[1].revents != 0 { return }
      guard descriptors[0].revents != 0 else { continue }
      let client = accept(listener, nil, nil)
      guard client >= 0 else { continue }
      guard let server = try? LiveSSHD.connect(port: target) else {
        Darwin.close(client)
        continue
      }
      var on: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      let pair = Pair(client: client, server: server)
      let accepted = lock.withLock { () -> Bool in
        guard !stopped else { return false }
        pairs.append(pair)
        return true
      }
      guard accepted else {
        pair.directionEnded()
        pair.directionEnded()
        return
      }
      spawn { [self] in forward(from: client, to: server, pair) }
      spawn { [self] in forward(from: server, to: client, pair) }
    }
  }

  private func forward(from source: Int32, to destination: Int32, _ pair: Pair) {
    defer { pair.directionEnded() }
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      var descriptors = [pollfd(fd: terminal.read, events: Int16(POLLIN), revents: 0),
                         pollfd(fd: frozen.read, events: Int16(POLLIN), revents: 0),
                         pollfd(fd: source, events: Int16(POLLIN), revents: 0)]
      guard Darwin.poll(&descriptors, 3, -1) >= 0 || errno == EINTR else { return }
      if descriptors[0].revents != 0 { return }
      if descriptors[1].revents != 0 {
        // Frozen: wait for the end only (the terminal pipe), reading nothing.
        var end = [pollfd(fd: terminal.read, events: Int16(POLLIN), revents: 0)]
        while Darwin.poll(&end, 1, -1) < 0 && errno == EINTR {}
        return
      }
      guard descriptors[2].revents != 0 else { continue }
      let count = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, $0.count) }
      guard count > 0 else {
        // EOF or an error: pass the half-close on.
        Darwin.shutdown(destination, SHUT_WR)
        return
      }
      var offset = 0
      while offset < count {
        let written = buffer.withUnsafeBytes { Darwin.write(destination, $0.baseAddress! + offset, count - offset) }
        guard written > 0 else { return }
        offset += written
      }
    }
  }
}

/// A loopback TCP listener that accepts connections and never says anything: an SSH server that never answers.
final class SilentListener: @unchecked Sendable {
  let port: Int
  private let fd: Int32

  init() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw LiveSSHD.Failure("socket") }
    self.fd = fd
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafeMutablePointer(to: &address) { pointer -> Int in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard bind(fd, raw, length) == 0, getsockname(fd, raw, &length) == 0 else { return -1 }
        return Int(UInt16(bigEndian: pointer.pointee.sin_port))
      }
    }
    // The kernel completes the TCP handshake for queued connections; nothing ever accepts or writes.
    guard bound > 0, listen(fd, 16) == 0 else {
      Darwin.close(fd)
      throw LiveSSHD.Failure("listen")
    }
    port = bound
  }

  deinit { Darwin.close(fd) }

  /// A port nothing listens on (bound, then closed at once).
  static func closedPort() throws -> Int {
    let listener = try SilentListener()
    return listener.port
  }
}
#endif
