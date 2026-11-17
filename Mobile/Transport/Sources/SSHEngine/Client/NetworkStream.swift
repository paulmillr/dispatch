import Foundation
import Network
import Synchronization

/// `StreamConnector` over Network.framework: plain TCP (no TLS), TCP_NODELAY, proxies not used.
///
/// Stages, so a slow one is named: a host that is an IP address literal is not looked up. A name is resolved with
/// `getaddrinfo` (on a system queue; past the deadline or on cancellation the lookup is abandoned and its result
/// discarded when it comes, since `getaddrinfo` cannot be interrupted), then each address is tried in the order the
/// resolver gave, until one connects (as the russh engine did). Failures: no address `hostNotFound`; a lookup still
/// running at the deadline `timedOut(.lookup)`; a connection still being established at the deadline `noAnswer`;
/// ECONNREFUSED `connectionRefused`; no route, a network that is down, or (iOS) Local Network access denied
/// `unreachable`; anything else `network` with the OS's text. With several addresses the last failure is reported.
/// Every `NWConnection` made is either handed over in a stream or cancelled before this returns.
struct NetworkStreamConnector: StreamConnector {
  func connect(host: String, port: UInt16, deadline: ContinuousClock.Instant) async throws(SSHError) -> any ByteStream {
    guard !Task.isCancelled else { throw .cancelled }
    guard let nwPort = NWEndpoint.Port(rawValue: port), port != 0 else {
      throw .usage(.invalidArgument("port 0"))
    }
    let addresses: [NWEndpoint.Host]
    if let literal = Self.literal(host) {
      addresses = [literal]
    } else {
      addresses = try await HostLookup.resolve(host, deadline: deadline)
    }
    var failure = SSHError.hostNotFound
    for address in addresses {
      do {
        let connection = try await ConnectAttempt.connect(to: .hostPort(host: address, port: nwPort), deadline: deadline)
        return NetworkByteStream(connection)
      } catch {
        // Past the deadline no other address gets a chance; before it (a refusal, a route) the next one does.
        if error == .cancelled || ContinuousClock.now >= deadline { throw error }
        failure = error
      }
    }
    throw failure
  }

  /// An IPv4 or IPv6 address literal (an IPv6 one may be bracketed and carry a zone), else nil.
  static func literal(_ host: String) -> NWEndpoint.Host? {
    var text = Substring(host)
    if text.hasPrefix("["), text.hasSuffix("]") { text = text.dropFirst().dropLast() }
    if let address = IPv4Address(String(text)), text.allSatisfy({ $0.isNumber || $0 == "." }) { return .ipv4(address) }
    if text.contains(":"), let address = IPv6Address(String(text)) { return .ipv6(address) }
    return nil
  }

  /// The error for a failed or waiting connection attempt.
  static func error(_ error: NWError, path: NWPath?) -> SSHError {
    if path?.unsatisfiedReason == .localNetworkDenied { return .unreachable }
    switch error {
    case .posix(let code):
      switch code {
      case .ECONNREFUSED: return .connectionRefused
      case .ENETUNREACH, .EHOSTUNREACH, .ENETDOWN, .EHOSTDOWN, .EADDRNOTAVAIL: return .unreachable
      case .ETIMEDOUT: return .noAnswer
      case .ECONNRESET, .ECONNABORTED, .EPIPE, .ENOTCONN: return .closed(.connectionLost)
      case .ECANCELED: return .cancelled
      default: return .network(Self.text(code))
      }
    case .dns(let code):
      // kDNSServiceErr_PolicyDenied: Local Network access denied.
      if code == -65570 { return .unreachable }
      return .hostNotFound
    default:
      return .network(error.localizedDescription)
    }
  }

  static func text(_ code: POSIXErrorCode) -> String {
    String(cString: strerror(code.rawValue))
  }

  static func parameters() -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters = NWParameters(tls: nil, tcp: tcp)
    parameters.preferNoProxies = true
    return parameters
  }
}

/// One `getaddrinfo` that the caller stops waiting for at its deadline or cancellation.
private final class HostLookup: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Result<[NWEndpoint.Host], SSHError>, Never>?
  private var outcome: Result<[NWEndpoint.Host], SSHError>?

  static func resolve(_ host: String, deadline: ContinuousClock.Instant) async throws(SSHError) -> [NWEndpoint.Host] {
    let lookup = HostLookup()
    let delay = ContinuousClock.now.duration(to: deadline)
    guard delay > .zero else { throw .timedOut(.lookup) }
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Result<[NWEndpoint.Host], SSHError>, Never>) in
        lookup.install(continuation)
        DispatchQueue.global(qos: .userInitiated).async { lookup.finish(Self.getaddrinfo(host)) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay.timeInterval) {
          lookup.finish(.failure(.timedOut(.lookup)))
        }
      }
    } onCancel: {
      lookup.finish(.failure(.cancelled))
    }
    return try result.get()
  }

  private func install(_ continuation: CheckedContinuation<Result<[NWEndpoint.Host], SSHError>, Never>) {
    lock.lock()
    if let outcome {
      lock.unlock()
      continuation.resume(returning: outcome)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  private func finish(_ result: Result<[NWEndpoint.Host], SSHError>) {
    lock.lock()
    guard outcome == nil else {
      lock.unlock()
      return
    }
    outcome = result
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(returning: result)
  }

  /// The addresses of `host` for TCP, in the resolver's order, without repeats.
  private static func getaddrinfo(_ host: String) -> Result<[NWEndpoint.Host], SSHError> {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP
    var list: UnsafeMutablePointer<addrinfo>?
    let status = Darwin.getaddrinfo(host, nil, &hints, &list)
    defer { if let list { freeaddrinfo(list) } }
    guard status == 0 else {
      switch status {
      case EAI_NONAME, EAI_NODATA: return .failure(.hostNotFound)
      default: return .failure(.network(String(cString: gai_strerror(status))))
      }
    }
    var hosts: [NWEndpoint.Host] = []
    var seen = Set<String>()
    var cursor = list
    while let entry = cursor {
      defer { cursor = entry.pointee.ai_next }
      guard let address = entry.pointee.ai_addr,
        entry.pointee.ai_family == AF_INET || entry.pointee.ai_family == AF_INET6
      else { continue }
      var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(address, entry.pointee.ai_addrlen, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0
      else { continue }
      let numeric = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      guard seen.insert(numeric).inserted, let host = NetworkStreamConnector.literal(numeric) else { continue }
      hosts.append(host)
    }
    return hosts.isEmpty ? .failure(.hostNotFound) : .success(hosts)
  }
}

extension NetworkStreamConnector {
  /// Connection attempts alive (tests: none outlives its `connect`).
  static var liveAttempts: Int { ConnectAttempt.live.withLock { $0 } }
}

/// One TCP connection attempt to one address: ready, failed, waiting (refused, no route: not retried), the
/// deadline, or the caller's cancellation, whichever comes first. A connection not handed over is cancelled. Nothing
/// keeps the attempt once it finished: the deadline's work item holds it weakly (a cancelled `DispatchWorkItem` stays
/// queued, with its block, until its time comes), so the connection it hands over goes with its stream.
private final class ConnectAttempt: @unchecked Sendable {
  static let live = Mutex(0)

  // Everything below is touched only on `queue`.
  private let queue = DispatchQueue(label: "SSHEngine.connect")
  private let connection: NWConnection
  private var continuation: CheckedContinuation<Result<NWConnection, SSHError>, Never>?
  private var outcome: Result<NWConnection, SSHError>?
  private var deadlineItem: DispatchWorkItem?

  private init(_ endpoint: NWEndpoint) {
    connection = NWConnection(to: endpoint, using: NetworkStreamConnector.parameters())
    Self.live.withLock { $0 += 1 }
  }

  deinit { Self.live.withLock { $0 -= 1 } }

  static func connect(to endpoint: NWEndpoint, deadline: ContinuousClock.Instant) async throws(SSHError) -> NWConnection {
    let attempt = ConnectAttempt(endpoint)
    let delay = ContinuousClock.now.duration(to: deadline)
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Result<NWConnection, SSHError>, Never>) in
        attempt.queue.async { attempt.start(continuation, delay: delay) }
      }
    } onCancel: {
      attempt.queue.async { attempt.finish(.failure(.cancelled)) }
    }
    return try result.get()
  }

  private func start(_ continuation: CheckedContinuation<Result<NWConnection, SSHError>, Never>, delay: Duration) {
    if let outcome {
      // Cancelled before it started.
      continuation.resume(returning: outcome)
      return
    }
    self.continuation = continuation
    guard delay > .zero else {
      finish(.failure(.noAnswer))
      return
    }
    connection.stateUpdateHandler = { [self] state in
      switch state {
      case .ready: finish(.success(connection))
      case .waiting(let error), .failed(let error):
        finish(.failure(NetworkStreamConnector.error(error, path: connection.currentPath)))
      case .cancelled: finish(.failure(.cancelled))
      default: break
      }
    }
    connection.start(queue: queue)
    let item = DispatchWorkItem { [weak self] in self?.finish(.failure(.noAnswer)) }
    deadlineItem = item
    queue.asyncAfter(deadline: .now() + delay.timeInterval, execute: item)
  }

  private func finish(_ result: Result<NWConnection, SSHError>) {
    guard outcome == nil else { return }
    outcome = result
    deadlineItem?.cancel()
    deadlineItem = nil
    connection.stateUpdateHandler = nil
    if case .failure = result { connection.cancel() }
    continuation?.resume(returning: result)
    continuation = nil
  }
}

/// `ByteStream` over a ready `NWConnection`. The peer's FIN reads as EOF (writes go on: TCP's half-close); a reset
/// is `closed(.connectionLost)`; `close` cancels the connection (both directions at once) and returns once it is
/// cancelled. Cancelling the task of a read or write cancels the connection too (Network.framework cannot withdraw
/// one receive or send), so the stream is unusable afterwards and that call throws `cancelled`.
final class NetworkByteStream: ByteStream, @unchecked Sendable {
  private let connection: NWConnection
  // Guarded by `lock`.
  private let lock = NSLock()
  private var closed = false
  private var cancelledByTask = false
  private var eof = false
  private var finalState = false
  private var closeWaiters: [CheckedContinuation<Void, Never>] = []

  init(_ connection: NWConnection) {
    self.connection = connection
    connection.stateUpdateHandler = { [weak self] state in
      if case .cancelled = state { self?.reachedFinalState() }
    }
  }

  deinit {
    connection.stateUpdateHandler = nil
    connection.cancel()
  }

  func read(maximum: Int) async throws(SSHError) -> [UInt8] {
    if locked({ closed || eof }) { return [] }
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Result<[UInt8], SSHError>, Never>) in
        connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, maximum)) { [self] data, _, isComplete, error in
          if let data, !data.isEmpty {
            if isComplete { locked { eof = true } }
            continuation.resume(returning: .success([UInt8](data)))
          } else if let error {
            continuation.resume(returning: mapped(error, reading: true))
          } else {
            if isComplete { locked { eof = true } }
            continuation.resume(returning: .success([]))
          }
        }
      }
    } onCancel: {
      cancelForTask()
    }
    return try result.get()
  }

  func write(_ bytes: [UInt8]) async throws(SSHError) {
    if locked({ closed }) { throw .closed(.byClient) }
    guard !bytes.isEmpty else { return }
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Result<[UInt8], SSHError>, Never>) in
        connection.send(content: Data(bytes), completion: .contentProcessed { [self] error in
          if let error {
            continuation.resume(returning: mapped(error, reading: false))
          } else {
            continuation.resume(returning: .success([]))
          }
        })
      }
    } onCancel: {
      cancelForTask()
    }
    _ = try result.get()
  }

  func close() async {
    let first = locked { () -> Bool in
      defer { closed = true }
      return !closed
    }
    if first { connection.cancel() }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let done = locked { () -> Bool in
        if finalState { return true }
        closeWaiters.append(continuation)
        return false
      }
      if done { continuation.resume() }
    }
  }

  private func reachedFinalState() {
    let waiting = locked { () -> [CheckedContinuation<Void, Never>] in
      finalState = true
      defer { closeWaiters = [] }
      return closeWaiters
    }
    for waiter in waiting { waiter.resume() }
  }

  private func cancelForTask() {
    locked { cancelledByTask = true }
    connection.cancel()
  }

  /// A read or write error: after our own close a read is EOF and a write `closed(.byClient)`.
  private func mapped(_ error: NWError, reading: Bool) -> Result<[UInt8], SSHError> {
    let (closed, cancelled) = locked { (self.closed, cancelledByTask) }
    if cancelled { return .failure(.cancelled) }
    if closed { return reading ? .success([]) : .failure(.closed(.byClient)) }
    switch NetworkStreamConnector.error(error, path: nil) {
    case .connectionRefused, .unreachable, .noAnswer, .cancelled: return .failure(.closed(.connectionLost))
    case let other: return .failure(other)
    }
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

extension Duration {
  /// Seconds as a `TimeInterval`, for Dispatch.
  var timeInterval: TimeInterval {
    let (seconds, attoseconds) = components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }
}
