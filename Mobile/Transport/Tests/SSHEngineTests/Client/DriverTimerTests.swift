import Foundation
import XCTest
@testable import SSHEngine

/// The timers the cores ask for, run by the driver (keepalive, rekey), their cost in tasks, and the outbound side's
/// backpressure: a peer that stops reading stops the app's writer with the engine's memory bounded.
final class DriverTimerTests: XCTestCase {
  private func options(keepalive: Duration?, count: Int = 2) -> ConnectOptions {
    var options = MemoryWorld.options
    options.keepaliveInterval = keepalive
    options.keepaliveCountMax = count
    return options
  }

  func testAnsweredKeepalivesKeepTheConnection() async throws {
    var configuration = ScriptedServer.Configuration()
    configuration.keepaliveAnswer = .failure
    let world = await MemoryWorld.make(configuration: configuration)
    let session = try await world.loggedIn(options(keepalive: .milliseconds(50), count: 1))
    let stats = try await bounded(20, "six keepalives") { await session.driver.waitForStats { $0.keepalivesFired >= 6 } }
    XCTAssertGreaterThanOrEqual(stats.keepalivesFired, 6)
    let ended = await session.driver.endReason
    XCTAssertNil(ended)
    // Every firing after the login sends one; the last may still be on its way to the peer.
    let received = try await bounded(20, "six keepalives at the peer") {
      await world.peer.waitFor { $0.numbered(MessageNumber.globalRequest.rawValue).count >= 6 }
    }
    XCTAssertGreaterThanOrEqual(received.numbered(MessageNumber.globalRequest.rawValue).count, 6)
    await session.close()
  }

  /// A login held open for many keepalive intervals (the user before the first attempt, then a signer that takes its
  /// time, the server silent meanwhile, as at a Face ID prompt): no global request goes before the login (RFC 4252 §6;
  /// Dropbear ends such a connection), and with a count of 1 the silence ends nothing. The timer starts at the
  /// success: keepalives go and are answered after it.
  func testNoKeepaliveWhileTheLoginWaits() async throws {
    var configuration = ScriptedServer.Configuration()
    configuration.keepaliveAnswer = .failure
    let world = await MemoryWorld.make(configuration: configuration)
    let session = try await world.connect(options(keepalive: .milliseconds(50), count: 1))
    try await Task.sleep(for: .milliseconds(300))
    let slow = try cryptoKitEd25519(before: { try? await Task.sleep(for: .milliseconds(400)) })
    let outcome = try await session.authenticate(user: "phone", with: .publicKey(slow, direct: false))
    XCTAssertEqual(outcome, .success)
    let stats = try await bounded(20, "keepalives after the login") { await session.driver.waitForStats { $0.keepalivesFired >= 4 } }
    XCTAssertGreaterThanOrEqual(stats.keepalivesFired, 4)
    let numbers = await world.peer.received.compactMap(\.first)
    let lastLogin = try XCTUnwrap(numbers.lastIndex(of: MessageNumber.userauthRequest.rawValue))
    let firstKeepalive = try XCTUnwrap(numbers.firstIndex(of: MessageNumber.globalRequest.rawValue))
    XCTAssertGreaterThan(firstKeepalive, lastLogin, "a global request before the login: \(numbers)")
    XCTAssertGreaterThanOrEqual(numbers.filter { $0 == MessageNumber.globalRequest.rawValue }.count, 3)
    let ended = await session.driver.endReason
    XCTAssertNil(ended)
    await session.close()
  }

  /// A timer far away (the hourly re-exchange) sleeps in slices: a cancelled `Task.sleep` keeps its wake-up job in the
  /// runtime until the time it was given, so a single sleep for the whole hour would leave one behind for an hour
  /// after every connection that closed.
  func testLongTimersSleepInSlices() async throws {
    let world = await MemoryWorld.make()
    let session = try await world.loggedIn()
    // The handshake deadline (10 s here) sleeps less than a slice; the re-exchange timer's first sleep is longer.
    let stats = try await bounded(20, "the re-exchange timer's sleep") {
      await session.driver.waitForStats { $0.longestSleep > .seconds(11) }
    }
    XCTAssertLessThanOrEqual(stats.longestSleep, .seconds(60))
    await session.close()
  }

  /// A server that answers nothing is given up after (count + 1) intervals of silence.
  func testUnansweredKeepalivesEndTheConnection() async throws {
    let world = await MemoryWorld.make()
    let session = try await world.loggedIn(options(keepalive: .milliseconds(100), count: 2))
    let started = ContinuousClock.now
    await world.peer.setSilent(true)
    let end = try await bounded(20, "the keepalive timeout") { await session.ended() }
    let elapsed = ContinuousClock.now - started
    XCTAssertEqual(end, .timedOut(.keepalive))
    XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(280), "three intervals of silence, less a timer's tolerance")
    XCTAssertLessThan(elapsed, .seconds(10))
  }

  /// The transport reschedules the keepalive with every batch of packets; the driver moves the sleeping timer instead
  /// of starting a task each time.
  func testBusyTrafficStartsFewTimerTasks() async throws {
    let world = await MemoryWorld.make()
    let session = try await world.loggedIn(options(keepalive: .seconds(30), count: 3))
    let before = await session.driver.stats.timerTasks
    let exec = try await session.exec("cat")
    for index in 0..<300 {
      try await exec.write([UInt8(truncatingIfNeeded: index)])
      _ = try await exec.read()
    }
    let after = await session.driver.stats
    XCTAssertGreaterThan(after.reads, 250)
    XCTAssertLessThan(after.timerTasks - before, 10, "\(after)")
    await session.close()
  }

  /// A time-based re-exchange of the client's runs while a channel is busy; the traffic is not disturbed.
  func testTimedReexchangesUnderTraffic() async throws {
    var tuning = DriverTuning()
    tuning.rekeyInterval = .milliseconds(100)
    let world = await MemoryWorld.make(tuning: tuning)
    let session = try await world.loggedIn()
    let exec = try await session.exec("cat")
    var expected: [UInt8] = []
    var received: [UInt8] = []
    var index = 0
    let deadline = ContinuousClock.now + .seconds(20)
    while await session.driver.stats.rekeys < 3 {
      guard ContinuousClock.now < deadline else {
        let stats = await session.driver.stats
        return XCTFail("no re-exchanges: \(stats)")
      }
      let chunk = [UInt8](repeating: UInt8(truncatingIfNeeded: index), count: 1000 + index % 500)
      index += 1
      expected += chunk
      do {
        try await bounded(5, "write") { try await exec.write(chunk) }
        while received.count < expected.count, let output = try await bounded(5, "read", { try await exec.read() }) {
          received += output.bytes
        }
      } catch {
        let stats = await session.driver.stats
        let numbers = await world.peer.received.map { $0.first ?? 0 }.suffix(30)
        let failure = await world.peer.failure
        return XCTFail("\(error) at \(index): \(stats) peer: \(Array(numbers)) \(failure ?? "-") end \(String(describing: await session.driver.endReason))")
      }
    }
    XCTAssertEqual(received, expected)
    await session.close()
  }

  /// The server's own re-exchanges, between packets of channel data.
  func testServerReexchangesUnderTraffic() async throws {
    let world = await MemoryWorld.make()
    let session = try await world.loggedIn()
    let exec = try await session.exec("cat")
    var expected: [UInt8] = []
    var received: [UInt8] = []
    for round in 0..<5 {
      await world.peer.startRekey()
      for index in 0..<20 {
        let chunk = [UInt8](repeating: UInt8(truncatingIfNeeded: round * 20 + index), count: 3000)
        expected += chunk
        try await exec.write(chunk)
      }
      while received.count < expected.count, let output = try await exec.read() { received += output.bytes }
    }
    XCTAssertEqual(received, expected)
    let rekeys = await session.driver.stats.rekeys
    XCTAssertEqual(rekeys, 5)
    await session.close()
  }

  /// The peer stops reading: the stream's write stalls, the core's backlog fills to its limit, the channel stops
  /// taking the app's writes, and nothing grows past those bounds. Once the peer reads again, all of it arrives.
  func testAPeerThatStopsReadingStopsTheWriter() async throws {
    let script = ServerScript()
    script.window = 64 * 1024 * 1024
    script.commands["sink"] = []
    let world = await MemoryWorld.make(script: script, capacity: 64 * 1024)
    let session = try await world.loggedIn()
    let exec = try await session.exec("sink")
    await world.peer.setSilent(true)
    let data = (0..<(4 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 13) }
    let write = Task { try await exec.write(data) }
    let stalled = try await bounded(20, "the writer stops") {
      await session.driver.waitForStats { $0.waitingWriters == 1 && $0.maximumBacklog > Limits.outboundBacklogBytes / 2 }
    }
    XCTAssertLessThanOrEqual(stalled.maximumBacklog, Limits.outboundBacklogBytes + 64 * 1024)
    await world.peer.setSilent(false)
    try await bounded(30, "the write") { try await write.value }
    await exec.finishInput()
    _ = try await bounded(30, "the data") {
      await world.peer.waitFor { !$0.numbered(96).isEmpty }
    }
    let input = await world.peer.input(0)
    XCTAssertEqual(input.count, data.count)
    XCTAssertTrue(input == data)
    let final = await session.driver.stats
    XCTAssertLessThanOrEqual(final.maximumBacklog, Limits.outboundBacklogBytes + 64 * 1024)
    await session.close()
  }
}
