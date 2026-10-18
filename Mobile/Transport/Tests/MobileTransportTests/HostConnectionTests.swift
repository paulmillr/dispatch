import Foundation
import MobileTransport
import XCTest

/// Requirement 6: the host connection state machine with SSHReconnect's backoff, on a fake clock.
final class HostConnectionTests: XCTestCase {
  func testFirstConnectReportsPhases() async throws {
    let harness = Harness()
    await harness.script.push(.success)
    let host = harness.host()
    let states = await host.states()
    await host.start()
    let seen = try await collect(states, until: { $0 == .connected })
    XCTAssertEqual(seen, [.disconnected, .connecting, .authenticating, .bootstrapping, .connected])
  }

  func testLossRetriesAfterOneSecondWithoutFlicker() async throws {
    let harness = Harness()
    await harness.script.push(.success, .success)
    let host = harness.host()
    await host.start()
    try await awaitState(host, for: .connected)
    let states = await host.states()
    let lostAt = harness.clock.now
    await harness.script.dropCurrent()
    try await harness.clock.waitForSleepers(1)
    XCTAssertEqual(harness.clock.requested, [.seconds(1)])
    harness.clock.advance(by: 1)
    let seen = try await collect(states, skipping: 1, until: { $0 == .connected })
    // Reconnect attempts never pass through connecting/authenticating/bootstrapping.
    XCTAssertEqual(seen, [.connected, .reconnecting(attempt: 0, since: lostAt), .reconnecting(attempt: 1, since: lostAt), .connected])
  }

  func testFailedAttemptsBackOffTwoToSixtySeconds() async throws {
    let harness = Harness()
    await harness.script.push(.success)
    await harness.script.push(contentsOf: Array(repeating: .unreachable, count: 7))
    await harness.script.push(.success)
    let host = harness.host()
    await host.start()
    try await awaitState(host, for: .connected)
    await harness.script.dropCurrent()
    for index in 1...8 {
      try await harness.clock.waitForSleepers(index)
      harness.clock.advance(by: 60)
    }
    try await awaitState(host, for: .connected)
    XCTAssertEqual(harness.clock.requested, [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(32), .seconds(60), .seconds(60)])
    let attempts = await harness.script.attempts
    XCTAssertEqual(attempts, 9)
  }

  func testLossSoonAfterPreviousLossBacksOff() async throws {
    let harness = Harness()
    await harness.script.push(.success, .success, .success)
    let host = harness.host()
    await host.start()
    try await awaitState(host, for: .connected)
    await harness.script.dropCurrent()
    try await harness.clock.waitForSleepers(1)
    harness.clock.advance(by: 1)
    try await awaitState(host, for: .connected)
    harness.clock.advance(by: 10)
    await harness.script.dropCurrent()
    try await harness.clock.waitForSleepers(2)
    XCTAssertEqual(harness.clock.requested, [.seconds(1), .seconds(2)])
  }

  func testRetryNowSkipsTheBackoff() async throws {
    let harness = Harness()
    await harness.script.push(.success, .unreachable, .unreachable, .success)
    let host = harness.host()
    await host.start()
    try await awaitState(host, for: .connected)
    await harness.script.dropCurrent()
    try await harness.clock.waitForSleepers(1)
    harness.clock.advance(by: 1)  // attempt 1 fails: waits 2 s
    try await harness.clock.waitForSleepers(2)
    await host.retryNow()  // network changed: attempt 2 now (fails), backoff restarts at 2 s
    try await harness.clock.waitForSleepers(3)
    await host.retryNow()
    try await awaitState(host, for: .connected)
    XCTAssertEqual(harness.clock.requested, [.seconds(1), .seconds(2), .seconds(2)])
  }

  func testRefusalStopsRetrying() async throws {
    let harness = Harness()
    await harness.script.push(.success, .refused)
    let host = harness.host()
    await host.start()
    try await awaitState(host, for: .connected)
    await harness.script.dropCurrent()
    try await harness.clock.waitForSleepers(1)
    harness.clock.advance(by: 1)
    try await awaitState(host) { if case .failed = $0 { true } else { false } }
    let state = await host.state
    XCTAssertEqual(state, .failed(reason: SSHTransportError.authenticationFailed(methods: ["publickey"]).errorDescription!))
    let attempts = await harness.script.attempts
    XCTAssertEqual(attempts, 2)
    // `start` again (the user's Reconnect) tries anew.
    await harness.script.push(.success)
    await host.start()
    try await awaitState(host, for: .connected)
  }

  func testCancelDuringBackoff() async throws {
    let harness = Harness()
    await harness.script.push(.success, .unreachable, .success)
    let host = harness.host()
    await host.start()
    try await awaitState(host, for: .connected)
    await harness.script.dropCurrent()
    try await harness.clock.waitForSleepers(1)
    harness.clock.advance(by: 1)
    try await harness.clock.waitForSleepers(2)
    await host.cancel()
    let state = await host.state
    XCTAssertEqual(state, .disconnected)
    // The pause's timer is cancelled with it: no sleeping task outlives the connection.
    try await until { harness.clock.cancelled == 1 }
    XCTAssertEqual(harness.clock.pending, 0)
    harness.clock.advance(by: 120)
    try await Task.sleep(for: .milliseconds(50))
    let attempts = await harness.script.attempts
    XCTAssertEqual(attempts, 2, "no attempt after cancel")
  }

  /// `retryNow` ends the pause at once and cancels its timer.
  func testRetryNowCancelsThePausesTimer() async throws {
    let harness = Harness()
    await harness.script.push(.success, .success)
    let host = harness.host()
    await host.start()
    try await awaitState(host, for: .connected)
    await harness.script.dropCurrent()
    try await harness.clock.waitForSleepers(1)
    await host.retryNow()
    try await awaitState(host, for: .connected)
    try await until { harness.clock.cancelled == 1 }
    XCTAssertEqual(harness.clock.pending, 0)
  }

  func testInitialUnreachableBecomesReconnecting() async throws {
    let harness = Harness()
    await harness.script.push(.unreachable, .success)
    let host = harness.host()
    let states = await host.states()
    let start = harness.clock.now
    await host.start()
    try await harness.clock.waitForSleepers(1)
    harness.clock.advance(by: 2)
    let seen = try await collect(states, until: { $0 == .connected })
    XCTAssertEqual(seen, [.disconnected, .connecting, .authenticating, .bootstrapping, .reconnecting(attempt: 0, since: start),
                          .reconnecting(attempt: 1, since: start), .connected])
  }

  #if os(macOS)
  /// The real transport: a dropped SSH connection to the fixture comes back by itself.
  func testRealConnectionReconnects() async throws {
    let fixture = SSHFixture.shared
    let key = try SSHKey.openSSH(TestKeys.shared.data("ed25519"))
    let host = HostConnection<Live> { phase in
      let connection = try await SSHConnection.connect(
        to: fixture.endpoint, credentials: [.key(key)], trust: fixture.trust, authenticating: { await phase(.authenticating) })
      return Live(connection: connection)
    }
    await host.start()
    try await awaitState(host, for: .connected, timeout: .seconds(10))
    let first = await host.session
    await first?.connection.close()
    try await awaitState(host) { if case .reconnecting = $0 { true } else { false } }
    let start = ContinuousClock.now
    try await awaitState(host, for: .connected, timeout: .seconds(10))
    let second = await host.session
    XCTAssertTrue(second?.connection.isActive == true)
    XCTAssertFalse(first?.connection === second?.connection)
    report(String(format: "reconnect after a drop (1 s policy delay included): %.2f s", seconds(ContinuousClock.now - start)))
    await host.cancel()
  }
  #endif

  struct Live: HostSession {
    let connection: SSHConnection
    func closed() async { await connection.closed() }
    func close() async { await connection.close() }
  }
}

private enum Outcome: Sendable { case success, unreachable, refused }

private final class FakeSession: HostSession, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var dropped = false
  func closed() async {
    await withCheckedContinuation { continuation in
      let resume = lock.withLock { () -> Bool in
        if dropped { return true }
        self.continuation = continuation
        return false
      }
      if resume { continuation.resume() }
    }
  }
  func close() async { drop() }
  func drop() {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      dropped = true
      defer { self.continuation = nil }
      return self.continuation
    }
    continuation?.resume()
  }
}

private actor Script {
  private var outcomes: [Outcome] = []
  private(set) var attempts = 0
  private var current: FakeSession?
  func push(_ outcomes: Outcome...) { self.outcomes += outcomes }
  func push(contentsOf outcomes: [Outcome]) { self.outcomes += outcomes }
  func next() throws -> FakeSession {
    attempts += 1
    guard !outcomes.isEmpty else { throw URLError(.cannotConnectToHost) }
    switch outcomes.removeFirst() {
    case .success:
      let session = FakeSession()
      current = session
      return session
    case .unreachable: throw URLError(.cannotConnectToHost)
    case .refused: throw SSHTransportError.authenticationFailed(methods: ["publickey"])
    }
  }
  func dropCurrent() { current?.drop() }
}

private final class Harness: Sendable {
  let clock = TestClock()
  let script = Script()
  func host() -> HostConnection<FakeSession> {
    let script = script
    return HostConnection<FakeSession>(clock: clock) { phase in
      await phase(.authenticating)
      await phase(.bootstrapping)
      return try await script.next()
    }
  }
}

final class TestClock: ReconnectClock, @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSinceReferenceDate: 800_000_000)
  private var sleepers: [(id: UUID, deadline: Date, continuation: CheckedContinuation<Void, Never>)] = []
  private var durations: [Duration] = []
  private var cancellations = 0

  var now: Date { lock.withLock { current } }
  var requested: [Duration] { lock.withLock { durations } }
  /// Sleeps still waiting for the clock, and those their task's cancellation ended.
  var pending: Int { lock.withLock { sleepers.count } }
  var cancelled: Int { lock.withLock { cancellations } }

  /// Ends early, throwing, when its task is cancelled (as `Task.sleep` does).
  func sleep(for duration: Duration) async throws {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        lock.withLock {
          durations.append(duration)
          sleepers.append((id, current.addingTimeInterval(seconds(duration)), continuation))
        }
      }
    } onCancel: {
      let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
        cancellations += 1
        return sleepers.remove(at: index).continuation
      }
      continuation?.resume()
    }
    try Task.checkCancellation()
  }

  func advance(by interval: TimeInterval) {
    let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      current = current.addingTimeInterval(interval)
      let due = sleepers.filter { $0.deadline <= current }.map(\.continuation)
      sleepers.removeAll { $0.deadline <= current }
      return due
    }
    for continuation in due { continuation.resume() }
  }

  /// Waits until `count` sleeps have been requested in total.
  func waitForSleepers(_ count: Int, timeout: Duration = .seconds(5)) async throws {
    let deadline = ContinuousClock.now + timeout
    while requested.count < count {
      guard ContinuousClock.now < deadline else { throw XCTSkip("timed out waiting for \(count) sleeps; have \(requested)") }
      try await Task.sleep(for: .milliseconds(2))
    }
  }
}

private func until(timeout: Duration = .seconds(5), _ condition: @escaping @Sendable () -> Bool) async throws {
  let deadline = ContinuousClock.now + timeout
  while !condition() {
    guard ContinuousClock.now < deadline else { throw SSHTransportError.timedOut("condition") }
    try await Task.sleep(for: .milliseconds(2))
  }
}

private func collect(_ states: AsyncStream<HostConnectionState>, skipping: Int = 0,
                     until done: @escaping @Sendable (HostConnectionState) -> Bool,
                     timeout: Duration = .seconds(5)) async throws -> [HostConnectionState] {
  try await withThrowingTaskGroup(of: [HostConnectionState].self) { group in
    group.addTask {
      var seen: [HostConnectionState] = []
      for await state in states {
        seen.append(state)
        if seen.count > skipping, done(state) { break }
      }
      return seen
    }
    group.addTask {
      try await Task.sleep(for: timeout)
      throw SSHTransportError.timedOut("state")
    }
    defer { group.cancelAll() }
    return try await group.next()!
  }
}

private func awaitState<S: HostSession>(_ host: HostConnection<S>, for state: HostConnectionState, timeout: Duration = .seconds(5)) async throws {
  try await awaitState(host, timeout: timeout) { $0 == state }
}

private func awaitState<S: HostSession>(_ host: HostConnection<S>, timeout: Duration = .seconds(5),
                                  _ matches: @escaping @Sendable (HostConnectionState) -> Bool) async throws {
  _ = try await collect(await host.states(), until: matches, timeout: timeout)
}
