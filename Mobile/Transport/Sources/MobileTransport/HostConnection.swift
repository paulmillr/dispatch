import Foundation

/// What the UI shows for one host (M1f status, M4c reconnecting banner).
public enum HostConnectionState: Sendable, Equatable {
  case disconnected
  /// First connection: TCP and key exchange (including the host key decision).
  case connecting
  case authenticating
  /// Installing or checking the helper and greeting it.
  case bootstrapping
  case connected
  /// The connection was lost at `since` (or the first connection failed then); `attempt` counts tries since then.
  /// Stays put through each attempt's phases, so the banner and its elapsed counter never flicker. `reason` is why
  /// the link is down: the latest attempt's failure, else why the connection was lost.
  case reconnecting(attempt: Int, since: Date, reason: String? = nil)
  /// Refused (host key, credentials, incompatible helper): no automatic retry until `start` again.
  case failed(reason: String)
}

/// Time for the reconnect policy; tests drive a fake one.
public protocol ReconnectClock: Sendable {
  var now: Date { get }
  func sleep(for duration: Duration) async throws
}

public struct SystemReconnectClock: ReconnectClock {
  public init() {}
  public var now: Date { Date() }
  public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

/// A live connection the state machine watches: `closed()` returns when it is lost.
public protocol HostSession: Sendable {
  func closed() async
  func close() async
  /// Why the connection ended, once `closed()` returned; nil when not known.
  var lossReason: String? { get }
}

extension HostSession {
  public var lossReason: String? { nil }
}

public enum HostConnectionPhase: Sendable {
  case authenticating
  case bootstrapping
}

/// The reconnect policy of the Mac's SSHReconnect: a loss retries after 1 s, or backs off when it
/// follows the previous loss within a minute; failed attempts back off 2, 4, 8 … 60 s. A network
/// change or foregrounding (`retryNow`) tries at once and resets the backoff. Refusals stop.
public actor HostConnection<Session: HostSession> {
  public typealias Establish = @Sendable (_ phase: @escaping @Sendable (HostConnectionPhase) async -> Void) async throws -> Session

  public private(set) var state: HostConnectionState = .disconnected {
    didSet {
      guard state != oldValue else { return }
      for continuation in observers.values { continuation.yield(state) }
    }
  }
  public private(set) var session: Session?

  private let clock: any ReconnectClock
  private let establish: Establish
  private let refused: @Sendable (any Error) -> Bool
  private var task: Task<Void, Never>?
  private var failures = 0
  private var lastDrop: Date?
  /// The pause in progress: its continuation and the timer that ends it (cancelled when something else does).
  private var waiting: (id: UUID, continuation: CheckedContinuation<Void, Never>, timer: Task<Void, Never>)?
  private var observers: [UUID: AsyncStream<HostConnectionState>.Continuation] = [:]

  /// `refused` classifies an error as final (no retry); by default SSH refusals and bootstrap failures.
  public init(
    clock: any ReconnectClock = SystemReconnectClock(),
    refused: @escaping @Sendable (any Error) -> Bool = HostConnectionPolicy.refused,
    establish: @escaping Establish
  ) {
    self.clock = clock
    self.establish = establish
    self.refused = refused
  }

  /// Every state change, starting with the current state.
  public func states() -> AsyncStream<HostConnectionState> {
    let (stream, continuation) = AsyncStream<HostConnectionState>.makeStream()
    let id = UUID()
    observers[id] = continuation
    continuation.yield(state)
    continuation.onTermination = { _ in Task { await self.unobserve(id) } }
    return stream
  }

  private func unobserve(_ id: UUID) { observers.removeValue(forKey: id) }

  /// Connects (again, after `failed` or `disconnected`). Ignored while connecting or connected.
  public func start() {
    switch state {
    case .disconnected, .failed: break
    default: return
    }
    failures = 0
    let generation = UUID()
    self.generation = generation
    task = Task { await self.run(generation) }
  }

  /// A network change or the app coming to the foreground: a pending retry runs now, with fresh backoff.
  public func retryNow() {
    guard case .reconnecting = state else { return }
    failures = 0
    wake()
  }

  /// Stops retrying and drops the connection.
  public func cancel() async {
    generation = nil
    task?.cancel()
    wake()
    task = nil
    let session = self.session
    self.session = nil
    state = .disconnected
    await session?.close()
  }

  private var generation: UUID?

  private func run(_ generation: UUID) async {
    var attempt = 0
    var since: Date?
    var reason: String?
    while self.generation == generation, !Task.isCancelled {
      if let since {
        attempt += 1
        state = .reconnecting(attempt: attempt, since: since, reason: reason)
      } else {
        state = .connecting
      }
      let reconnecting = since != nil
      do {
        let session = try await establish { phase in
          await self.report(phase, reconnecting: reconnecting, generation: generation)
        }
        guard self.generation == generation, !Task.isCancelled else {
          await session.close()
          return
        }
        self.session = session
        state = .connected
        failures = 0
        attempt = 0
        await session.closed()
        guard self.generation == generation, !Task.isCancelled else { return }
        self.session = nil
        // A loss: retry soon, unless it follows the previous loss within a minute.
        let now = clock.now
        let recent = lastDrop.map { now.timeIntervalSince($0) < 60 } ?? false
        lastDrop = now
        since = now
        attempt = 0
        reason = session.lossReason ?? "The connection was lost."
        state = .reconnecting(attempt: 0, since: now, reason: reason)
        if recent { await pause(backoff()) } else { failures = 0; await pause(.seconds(1)) }
      } catch {
        guard self.generation == generation, !Task.isCancelled else { return }
        if refused(error) {
          state = .failed(reason: HostConnectionPolicy.describe(error))
          self.generation = nil
          return
        }
        // Waiting for the next try shows as reconnecting, never as the failed attempt's last phase.
        if since == nil { since = clock.now }
        reason = HostConnectionPolicy.describe(error)
        state = .reconnecting(attempt: attempt, since: since!, reason: reason)
        await pause(backoff())
      }
    }
  }

  private func report(_ phase: HostConnectionPhase, reconnecting: Bool, generation: UUID) {
    guard !reconnecting, self.generation == generation else { return }
    switch phase {
    case .authenticating: state = .authenticating
    case .bootstrapping: state = .bootstrapping
    }
  }

  /// 2, 4, 8 … seconds after consecutive failures, at most a minute.
  private func backoff() -> Duration {
    failures += 1
    return .seconds(min(60, 1 << min(failures, 6)))
  }

  /// Sleeps on the clock, or until `retryNow`/`cancel` wakes it; then its timer is cancelled, so no sleeping task
  /// outlives the pause.
  private func pause(_ duration: Duration) async {
    let clock = clock
    let id = UUID()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let timer = Task {
        try? await clock.sleep(for: duration)
        self.wake(id)
      }
      waiting = (id, continuation, timer)
    }
  }

  /// Ends the current pause (only the pause `id`, when given: a stale timer must not cut a later one short).
  private func wake(_ id: UUID? = nil) {
    guard let waiting, id == nil || id == waiting.id else { return }
    self.waiting = nil
    waiting.timer.cancel()
    waiting.continuation.resume()
  }
}

public enum HostConnectionPolicy: Sendable {
  /// SSH refusals and bootstrap failures need the user; everything else (network) is retried.
  public static func refused(_ error: any Error) -> Bool {
    guard let error = error as? SSHTransportError else { return false }
    switch error {
    case .hostKeyRejected, .hostKeyMismatch, .authenticationFailed, .unsupportedAuthentication, .invalidKey,
      .wrongPassphrase, .bootstrap, .cancelled:
      return true
    case .timedOut, .channelClosed, .commandFailed, .outputLimit, .network, .connectFailed, .protocolError:
      return false
    }
  }

  public static func describe(_ error: any Error) -> String {
    (error as? any LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription
  }
}
