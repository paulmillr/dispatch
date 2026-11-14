#if os(macOS)
import Darwin
import Foundation

/// A loopback TCP relay to `target` that models a slow link: every byte waits `oneWay` in each direction, in order,
/// and a new connection waits a round trip before anything passes (the TCP handshake such a link costs, which a
/// loopback connect does not). No loss and no bandwidth limit: what an exchange takes through it, beyond what it
/// takes at `oneWay` zero, is the round trips it waits for.
final class DelayRelay: @unchecked Sendable {
  let port: Int
  private let listener: Int32
  private let target: Int
  private let oneWay: TimeInterval
  private let lock = NSLock()
  private var pairs: [Pair] = []
  private var stopped = false

  init(to target: Int, oneWay: Duration) throws {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { throw POSIXError(.EIO) }
    var address = Self.loopback(port: 0)
    let bound = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw -> Bool in
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        return bind(listener, raw, length) == 0 && listen(listener, 16) == 0 && getsockname(listener, raw, &length) == 0
      }
    }
    guard bound else {
      Darwin.close(listener)
      throw POSIXError(.EIO)
    }
    self.listener = listener
    self.target = target
    self.oneWay = seconds(oneWay)
    port = Int(UInt16(bigEndian: address.sin_port))
    Thread.detachNewThread { [self] in
      while true {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        Thread.detachNewThread { [self] in relay(client) }
      }
    }
  }

  /// Ends every connection and stops accepting. The sockets close once their threads are done with them.
  func stop() {
    let pairs = lock.withLock { () -> [Pair] in
      stopped = true
      return self.pairs
    }
    Darwin.close(listener)
    for pair in pairs { pair.cut() }
  }

  private func relay(_ client: Int32) {
    // The handshake: a SYN and its answer cross the link before the client's first byte leaves.
    Thread.sleep(forTimeInterval: 2 * oneWay)
    let server = socket(AF_INET, SOCK_STREAM, 0)
    var address = Self.loopback(port: target)
    let connected = server >= 0 && withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
    }
    let pair = Pair(client: client, server: server)
    let kept = connected && lock.withLock { () -> Bool in
      if !stopped { pairs.append(pair) }
      return !stopped
    }
    guard kept else {
      Darwin.close(client)
      if server >= 0 { Darwin.close(server) }
      return
    }
    for socket in [client, server] {
      var one: Int32 = 1
      setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
      setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
    let up = Line(to: server, delay: oneWay, pair: pair), down = Line(to: client, delay: oneWay, pair: pair)
    Thread.detachNewThread { Self.read(client, into: up, pair: pair) }
    Thread.detachNewThread { Self.read(server, into: down, pair: pair) }
  }

  private static func read(_ socket: Int32, into line: Line, pair: Pair) {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = buffer.withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress, $0.count) }
      guard count > 0 else { break }
      line.push(Array(buffer[..<count]))
    }
    line.push(nil)
    pair.finished()
  }

  private static func loopback(port: Int) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = UInt16(port).bigEndian
    return address
  }

  /// One relayed connection's two sockets, closed once its four threads (a reader and a writer each way) are done: no
  /// thread ever touches a number another socket may have taken.
  private final class Pair: @unchecked Sendable {
    let client: Int32
    let server: Int32
    private let lock = NSLock()
    private var running = 4

    init(client: Int32, server: Int32) {
      self.client = client
      self.server = server
    }

    /// Ends both directions: the readers see the end and the writers follow.
    func cut() {
      lock.withLock {
        guard running > 0 else { return }
        shutdown(client, SHUT_RDWR)
        shutdown(server, SHUT_RDWR)
      }
    }

    func finished() {
      lock.withLock {
        running -= 1
        guard running == 0 else { return }
        Darwin.close(client)
        Darwin.close(server)
      }
    }
  }

  /// One direction: what was read, written `delay` later in the order it came, by one thread.
  private final class Line: @unchecked Sendable {
    private let socket: Int32
    private let delay: TimeInterval
    private let pair: Pair
    private let condition = NSCondition()
    private var queue: [(due: TimeInterval, bytes: [UInt8]?)] = []

    init(to socket: Int32, delay: TimeInterval, pair: Pair) {
      self.socket = socket
      self.delay = delay
      self.pair = pair
      Thread.detachNewThread { [self] in write() }
    }

    /// nil: the reader's end, passed on as a half close.
    func push(_ bytes: [UInt8]?) {
      condition.lock()
      queue.append((ProcessInfo.processInfo.systemUptime + delay, bytes))
      condition.signal()
      condition.unlock()
    }

    private func write() {
      var broken = false
      while true {
        condition.lock()
        while queue.isEmpty { condition.wait() }
        let (due, bytes) = queue.removeFirst()
        condition.unlock()
        let wait = due - ProcessInfo.processInfo.systemUptime
        if wait > 0, !broken { Thread.sleep(forTimeInterval: wait) }
        guard let bytes else { break }
        var sent = 0
        while !broken, sent < bytes.count {
          let count = bytes.withUnsafeBytes { Darwin.write(socket, $0.baseAddress! + sent, bytes.count - sent) }
          if count > 0 { sent += count } else { broken = true }
        }
        // The receiver went: end the other direction too, and drain what the reader still sends until its end.
        if broken { pair.cut() }
      }
      if !broken { shutdown(socket, SHUT_WR) }
      pair.finished()
    }
  }
}
#endif
