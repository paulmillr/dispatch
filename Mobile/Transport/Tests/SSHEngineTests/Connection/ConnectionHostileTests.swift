import SSHEngine
import XCTest

/// A server breaking the connection protocol: every case ends the connection with a named violation (never a trap,
/// never a stuck channel), and every channel ends with it. Then a deterministic mutation loop per channel state.
final class ConnectionHostileTests: XCTestCase {
  typealias W = ChannelWire

  func assertViolation(_ harness: ChannelHarness, _ expected: ChannelProblemMatch, _ what: String,
                       file: StaticString = #filePath, line: UInt = #line) {
    guard case .protocolViolation(let violation)? = harness.link.endedWith, expected.matches(violation) else {
      return XCTFail("\(what): \(String(describing: harness.link.endedWith))", file: file, line: line)
    }
    XCTAssertEqual(harness.core.endedWith, harness.link.endedWith, what, file: file, line: line)
    XCTAssertEqual(harness.core.channelCount, 0, what, file: file, line: line)
  }

  enum ChannelProblemMatch {
    case channel(ProtocolViolation.ChannelProblem)
    case malformed(MessageNumber)
    case unexpected(MessageNumber)

    func matches(_ violation: ProtocolViolation) -> Bool {
      switch (self, violation) {
      case (.channel(let problem), .channel(let actual)): problem == actual
      case (.malformed(let number), .malformed(let actual, _)): number == actual
      case (.unexpected(let number), .unexpectedMessage(let actual, _)): number == actual
      default: false
      }
    }
  }

  func testMessagesForAChannelWeDidNotOpen() {
    let messages: [[UInt8]] = [
      W.confirmation(5, sender: 1, window: 1, maximumPacket: 1), W.openFailure(5, reason: 1, []), W.adjust(5, 1),
      W.data(5, [1]), W.extended(5, [1]), W.eof(5), W.close(5), W.exitStatus(5, 0), W.success(5), W.failure(5),
    ]
    for message in messages {
      let harness = ChannelHarness()
      let id = harness.exec(remote: 5)
      XCTAssertNotEqual(id.rawValue, 5)
      harness.server(message)
      assertViolation(harness, .channel(.unknownChannel(5)), "\(message[0])")
      XCTAssertEqual(harness.take(), [.closed(id, .lost)], "the open channel ends with it")
    }
  }

  func testMessagesTheChannelsStateDoesNotAllow() {
    // Before the confirmation: only the open's answer.
    for message: (UInt32) -> [UInt8] in [{ W.adjust($0, 1) }, { W.data($0, [1]) }, { W.extended($0, [1]) }, { W.eof($0) },
                                          { W.close($0) }, { W.exitStatus($0, 0) }, { W.success($0) }, { W.failure($0) }] {
      let harness = ChannelHarness()
      let id = try! harness.core.openExec("x")
      let payload = message(id.rawValue)
      harness.server(payload)
      assertViolation(harness, .channel(.unexpectedInState(MessageNumber(payload[0]))), "\(payload[0]) while opening")
      XCTAssertEqual(harness.take(), [.openFailed(id, harness.link.endedWith!)])
    }
    // The open's answer once it was answered.
    for answer: (UInt32) -> [UInt8] in [{ W.confirmation($0, sender: 2, window: 1, maximumPacket: 1) },
                                         { W.openFailure($0, reason: 1, []) }] {
      let harness = ChannelHarness()
      let id = harness.exec(remote: 2)
      let payload = answer(id.rawValue)
      harness.server(payload)
      assertViolation(harness, .channel(.unexpectedInState(MessageNumber(payload[0]))), "a second \(payload[0])")
    }
    // A reply with nothing pending.
    for reply in [W.success, W.failure] {
      let harness = ChannelHarness()
      let id = harness.exec(remote: 3)
      harness.server(W.success(id.rawValue))
      let payload = reply(id.rawValue)
      harness.server(payload)
      assertViolation(harness, .channel(.unexpectedInState(MessageNumber(payload[0]))), "a reply to nothing")
    }
    // A second EOF.
    let harness = ChannelHarness()
    let id = harness.exec(remote: 4)
    harness.server(W.eof(id.rawValue))
    harness.server(W.eof(id.rawValue))
    assertViolation(harness, .channel(.unexpectedInState(.channelEOF)), "a second EOF")
  }

  /// hostile.rs `a_zero_maximum_packet_size_fails_the_channel`: the open fails at once with the connection, exec
  /// and shell alike; no writer can block on it.
  func testAZeroMaximumPacketFailsTheOpen() {
    for terminal in [false, true] {
      let harness = ChannelHarness()
      let id = terminal ? try! harness.core.openShell(term: "xterm", size: TerminalSize(columns: 80, rows: 24))
        : try! harness.core.openExec("cat")
      let other = harness.exec(remote: 9)
      harness.server(W.confirmation(id.rawValue, sender: 1, window: 1 << 20, maximumPacket: 0))
      assertViolation(harness, .channel(.maximumPacketTooSmall), "terminal \(terminal)")
      XCTAssertEqual(harness.take(), [.openFailed(id, .protocolViolation(.channel(.maximumPacketTooSmall))), .closed(other, .lost)])
      XCTAssertEqual(harness.sent.count, 3, "nothing sent for the refused channel: its open, the other's open and exec")
    }
    // The smallest the limit allows works.
    let harness = ChannelHarness()
    let id = harness.exec(remote: 1, window: 3, maximumPacket: Limits.peerMinimumPacket)
    XCTAssertEqual(harness.write([1, 2, 3], to: id), 3)
    XCTAssertEqual(harness.dataSent(to: 1).sizes, [1, 1, 1])
  }

  func testExtendedDataOfAnotherTypeIsRefused() {
    for type: UInt32 in [0, 2, .max] {
      let harness = ChannelHarness()
      let id = harness.exec(remote: 6)
      harness.server(W.extended(id.rawValue, type: type, [1]))
      assertViolation(harness, .channel(.unknownExtendedDataType), "type \(type)")
    }
  }

  func testMalformedChannelMessages() {
    let malformed: [[UInt8]] = [
      [91] + Raw.u32(0) + Raw.u32(1) + Raw.u32(1),  // short confirmation
      W.confirmation(0, sender: 1, window: 1, maximumPacket: 1) + [0],  // trailing
      [92] + Raw.u32(0) + Raw.u32(1) + Raw.string(""),  // no language tag
      [92] + Raw.u32(0) + Raw.u32(1) + Raw.string([UInt8](repeating: 0x41, count: Limits.channelMessageBytes + 1)) + Raw.string(""),
      [93] + Raw.u32(0),
      [94] + Raw.u32(0) + Raw.u32(10) + [1, 2],  // a length past the end
      [94] + Raw.u32(0) + Raw.u32(.max),
      [96],
    ]
    for (index, payload) in malformed.enumerated() {
      let harness = ChannelHarness()
      let id = try! harness.core.openExec("x")
      XCTAssertEqual(id.rawValue, 0)
      if payload[0] != 91 && payload[0] != 92 {
        harness.server(W.confirmation(0, sender: 1, window: 100, maximumPacket: 100))
      }
      harness.server(payload)
      assertViolation(harness, .malformed(MessageNumber(payload[0])), "case \(index)")
    }
  }

  func testThePolicyKeepsOtherNumbersAway() {
    for number: UInt8 in [50, 52, 60, 101, 127, 128, 255] {
      let harness = ChannelHarness()
      _ = harness.exec(remote: 7)
      harness.server([number] + Raw.u32(0))
      assertViolation(harness, .unexpected(MessageNumber(number)), "\(number)")
    }
    // And a driver that hands the core something else anyway.
    let harness = ChannelHarness()
    harness.core.receive(InboundMessage(payload: [52])!)
    assertViolation(harness, .unexpected(.userauthSuccess), "52 handed over directly")
  }

  // MARK: Mutation loop

  struct State {
    let name: String
    let make: () -> ChannelHarness
  }

  static var states: [State] {
    [
      State(name: "opening") {
        let harness = ChannelHarness()
        _ = try! harness.core.openExec("x")
        return harness
      },
      State(name: "exec, reply pending, input waiting") {
        let harness = ChannelHarness()
        let id = harness.exec(remote: 40, window: 0, maximumPacket: 16)
        harness.write(pattern(1000), to: id)
        return harness
      },
      State(name: "shell, pty-req pending") {
        let harness = ChannelHarness()
        let id = try! harness.core.openShell(term: "xterm", size: TerminalSize(columns: 80, rows: 24))
        harness.server(ChannelWire.confirmation(id.rawValue, sender: 41, window: 1000, maximumPacket: 100))
        return harness
      },
      State(name: "shell open") {
        let harness = ChannelHarness()
        _ = harness.shell(remote: 42, window: 50)
        return harness
      },
      State(name: "closing") {
        let harness = ChannelHarness()
        let id = harness.exec(remote: 43)
        harness.core.close(id)
        harness.drain()
        _ = harness.take()
        return harness
      },
    ]
  }

  /// Valid messages from the server for channel 0, the one each state opened.
  static let seeds: [[UInt8]] = [
    W.confirmation(0, sender: 9, window: 4096, maximumPacket: 512), W.openFailure(0, reason: 2, Array("no".utf8)),
    W.adjust(0, 64), W.data(0, pattern(40)), W.extended(0, Array("err".utf8)), W.eof(0), W.close(0),
    W.exitStatus(0, 1, wantReply: true), W.exitSignal(0, "KILL", core: false, [0xE9]),
    W.request(0, "keepalive@openssh.com", wantReply: true), W.success(0), W.failure(0),
    W.serverOpen("direct-tcpip", sender: 3, extra: Raw.string("h") + Raw.u32(1) + Raw.string("o") + Raw.u32(2)),
  ]

  func testMutatedServerMessagesInEveryChannelState() {
    let random = SeededRandom(seed: 0xC4A2_2E15)
    let iterations = 1500
    for state in Self.states {
      var errors = 0
      var transitions = 0
      for _ in 0..<iterations {
        let harness = state.make()
        _ = harness.take()
        let sentBefore = harness.sent.count
        let channelsBefore = harness.core.channelCount
        for step in 0..<3 where harness.link.endedWith == nil {
          let seed = Self.seeds[random.below(Self.seeds.count)]
          harness.server(step == 0 || random.below(2) == 0 ? MutationTests.mutate(seed, random) : seed)
          // A driver's reads and writes in between.
          harness.core.consumed(random.below(100), on: ChannelID(rawValue: 0))
          _ = try? harness.core.write(pattern(random.below(300)), to: ChannelID(rawValue: 0))
          harness.core.transportDrained()
          harness.drain()
        }
        let events = harness.take()
        XCTAssertNil(harness.core.poll(), state.name)
        // Bounded: a few events, and what was sent is bounded by the window granted and the input taken.
        XCTAssertLessThanOrEqual(events.filter { if case .writable = $0 { false } else { true } }.count, 8, state.name)
        XCTAssertLessThanOrEqual(harness.sent.count - sentBefore, 1300, state.name)
        XCTAssertLessThanOrEqual(harness.core.channelCount, channelsBefore, state.name)
        let last = events.filter {
          switch $0 {
          case .closed, .openFailed: true
          default: false
          }
        }
        XCTAssertLessThanOrEqual(last.count, 1, "\(state.name): one last event per channel")
        if let end = harness.link.endedWith {
          errors += 1
          XCTAssertEqual(harness.core.endedWith, end)
          XCTAssertEqual(harness.core.channelCount, 0)
        } else {
          transitions += 1
        }
      }
      XCTAssertGreaterThan(errors, 0, state.name)
      XCTAssertGreaterThan(transitions, 0, state.name)
    }
  }
}
