import XCTest
@testable import SSHEngine

/// Keepalives (`ConnectOptions.keepaliveCountMax`): one falls due after each interval of silence; one falling due
/// while `keepaliveCountMax` are unanswered ends the connection instead; any packet resets the count. The answers a
/// server gives: REQUEST_FAILURE or _SUCCESS, or UNIMPLEMENTED naming the keepalive's sequence number. None goes before
/// the connection phase (RFC 4252 §6), so `harness` starts in it.
final class TransportKeepaliveTests: XCTestCase {
  static func harness(answer: ScriptedServer.KeepaliveAnswer, count: Int = 3, interval: Duration? = .seconds(15))
    throws -> TransportHarness
  {
    var configuration = ScriptedServer.Configuration()
    configuration.keepaliveAnswer = answer
    let harness = try TransportHarness(options: TransportHarness.options(keepalive: interval, count: count),
                                       server: ScriptedServer(configuration: configuration))
    harness.connect()
    XCTAssertTrue(harness.isEstablished)
    harness.service = .connection
    harness.pump()
    return harness
  }

  /// No keepalive timer before the login, and a stray firing sends and counts nothing: a global request (80) before
  /// authentication is an error the server must disconnect for (RFC 4252 §6), and Dropbear does ("Received message 80
  /// before userauth", found by InteropEngineTests against Dropbear 2025.89). The timer starts when the connection
  /// phase does; then keepalives go and count as usual.
  func testNoKeepaliveBeforeTheConnectionPhase() throws {
    var configuration = ScriptedServer.Configuration()
    configuration.keepaliveAnswer = .none
    let harness = try TransportHarness(options: TransportHarness.options(keepalive: .seconds(15), count: 1),
                                       server: ScriptedServer(configuration: configuration))
    XCTAssertFalse(harness.connect().contains { if case .timer(.schedule(.keepalive, _)) = $0 { true } else { false } },
                   "a keepalive timer at the first exchange")
    XCTAssertTrue(harness.isEstablished)
    // `.userauth(.idle)`: the user at a password prompt or a Face ID sheet, the server silent meanwhile.
    for phase: MessagePolicy.ServicePhase in [.serviceNotRequested, .serviceRequested, .userauth(.idle),
                                               .userauth(.password)] {
      harness.service = phase
      harness.pump()
      for round in 1...3 {
        harness.client.timerFired(.keepalive)
        XCTAssertEqual(harness.pump(), [], "\(phase) round \(round)")
      }
    }
    XCTAssertEqual(harness.serverReceived([80]), [], "a global request before the login")
    XCTAssertEqual(harness.client.keepalivesOutstanding, 0)
    XCTAssertNil(harness.endReason(), "silence before the login is not a keepalive timeout")
    harness.service = .connection
    XCTAssertEqual(harness.pump(), [.timer(.schedule(.keepalive, after: .seconds(15)))], "the timer starts at the login")
    harness.client.timerFired(.keepalive)
    harness.pump()
    XCTAssertEqual(harness.serverReceived([80]).count, 1)
    harness.client.timerFired(.keepalive)
    harness.pump()
    XCTAssertEqual(harness.endReason(), .timedOut(.keepalive), "unanswered after the login, with a count of 1")
  }

  func testASilentServerIsGivenUpAfterCountPlusOneIntervals() throws {
    let harness = try Self.harness(answer: .none, count: 3)
    for round in 1...3 {
      harness.client.timerFired(.keepalive)
      let events = harness.pump()
      XCTAssertEqual(events, [.timer(.schedule(.keepalive, after: .seconds(15)))], "round \(round)")
      XCTAssertEqual(harness.serverReceived([80]).count, round)
    }
    harness.client.timerFired(.keepalive)
    harness.pump()
    XCTAssertEqual(harness.endReason(), .timedOut(.keepalive))
    XCTAssertEqual(harness.serverReceived([80]).count, 3)
    XCTAssertEqual(harness.server.disconnectReason, DisconnectReason.connectionLost.rawValue)
    // The request is OpenSSH's: keepalive@openssh.com, want reply.
    XCTAssertEqual(harness.serverReceived([80]).first, [80] + Raw.string("keepalive@openssh.com") + [1])
  }

  func testAnyPacketResetsTheCount() throws {
    let harness = try Self.harness(answer: .none, count: 2)
    for _ in 0..<5 {
      harness.client.timerFired(.keepalive)
      harness.client.timerFired(.keepalive)
      harness.pump()
      // Anything from the server, here an IGNORE: the count starts again, and the timer is rescheduled.
      harness.server.send([MessageNumber.ignore.rawValue] + Raw.string(""))
      XCTAssertEqual(harness.pump(), [.timer(.schedule(.keepalive, after: .seconds(15)))])
    }
    XCTAssertNil(harness.endReason())
  }

  func testTheTimerIsRescheduledOncePerBatchOfPackets() throws {
    let harness = try Self.harness(answer: .failure)
    for index in 0..<10 { harness.server.send(TransportExchangeTests.channelData([UInt8(index)])) }
    harness.service = .connection
    let events = harness.pump()
    XCTAssertEqual(events.filter { if case .timer = $0 { true } else { false } }, [.timer(.schedule(.keepalive, after: .seconds(15)))])
    XCTAssertEqual(events.filter { if case .message = $0 { true } else { false } }.count, 10)
  }

  func testEveryKindOfAnswer() throws {
    for answer in [ScriptedServer.KeepaliveAnswer.failure, .success, .unimplemented] {
      let harness = try Self.harness(answer: answer, count: 1)
      for _ in 0..<5 {
        harness.client.timerFired(.keepalive)
        harness.pump()
      }
      XCTAssertNil(harness.endReason(), "\(answer)")
      XCTAssertEqual(harness.serverReceived([80]).count, 5)
    }
  }

  func testAReplyWithNoKeepaliveOutIsAProtocolError() throws {
    for reply: [UInt8] in [[MessageNumber.requestSuccess.rawValue], [MessageNumber.requestFailure.rawValue]] {
      let harness = try Self.harness(answer: .failure)
      harness.server.send(reply)
      harness.pump()
      XCTAssertEqual(harness.endReason(), .protocolViolation(.channel(.unexpectedGlobalReply)))
    }
  }

  func testUnimplementedForAnythingButAKeepaliveIsAProtocolError() throws {
    let harness = try Self.harness(answer: .none)
    harness.client.timerFired(.keepalive)
    harness.pump()
    // The keepalive went as packet 0 under the new keys (strict); 7 is not it.
    harness.server.send([MessageNumber.unimplemented.rawValue] + Raw.u32(7))
    harness.pump()
    XCTAssertEqual(harness.endReason(), .protocolViolation(.unimplemented(sequence: 7)))
  }

  func testKeepalivesAreOffWithoutAnInterval() throws {
    let harness = try Self.harness(answer: .failure, interval: nil)
    XCTAssertFalse(harness.events.contains { $0 == .timer(.schedule(.keepalive, after: .seconds(15))) })
    harness.client.timerFired(.keepalive)
    harness.server.send([MessageNumber.ignore.rawValue] + Raw.string(""))
    XCTAssertEqual(harness.pump(), [])
    XCTAssertTrue(harness.serverReceived([80]).isEmpty)
  }

  func testAKeepaliveDuringAReexchangeWaitsForTheNewKeys() throws {
    let harness = try Self.harness(answer: .failure)
    harness.service = .connection
    harness.drain()
    harness.client.timerFired(.rekey)
    harness.client.timerFired(.keepalive)
    XCTAssertTrue(harness.pump().contains(.rekeyed))
    XCTAssertNil(harness.endReason())
    let numbers = harness.server.received.map { $0.first ?? 0 }
    XCTAssertGreaterThan(try XCTUnwrap(numbers.lastIndex(of: 80)), try XCTUnwrap(numbers.lastIndex(of: 21)))
  }

  func testNoKeepaliveBeforeTheFirstExchange() throws {
    let harness = try TransportHarness()
    harness.trust = nil
    harness.connect()
    harness.client.timerFired(.keepalive)
    XCTAssertTrue(harness.client.takeOutbound().isEmpty)
  }
}
