import SSHEngine
import XCTest

/// Session channels from open to close: the exact requests, exec's hand-over and refusal, the shell's two
/// confirmations and refusals, resize ordering, every close ordering, the server's requests, exit status and signal.
/// The server addresses our numbers (`id.rawValue`); what we send names the server's (`remote`).
final class ChannelLifecycleTests: XCTestCase {
  typealias W = ChannelWire

  // MARK: Exec

  func testExecIsHandedOverOnceItsRequestIsSent() {
    let harness = ChannelHarness()
    let id = try! harness.core.openExec("echo hi")
    let n = id.rawValue
    XCTAssertEqual(harness.sent, [W.open(n)])
    harness.drain()
    XCTAssertEqual(harness.take(), [], "nothing before the confirmation")
    harness.server(W.confirmation(n, sender: 7, window: 0, maximumPacket: 32768))
    XCTAssertEqual(harness.sent.last, W.exec(7, "echo hi"))
    XCTAssertEqual(harness.take(), [.opened(id)], "before the reply")
    // Output before the reply reads as usual; the reply changes nothing.
    harness.server(W.data(n, Array("hi\n".utf8)))
    harness.server(W.success(n))
    harness.server(W.exitStatus(n, 0))
    harness.server(W.eof(n))
    harness.server(W.close(n))
    XCTAssertEqual(harness.take(), [.data(id, Array("hi\n".utf8)), .eof(id), .closed(id, .status(0))])
    XCTAssertEqual(harness.sent.last, W.close(7))
    XCTAssertEqual(harness.core.channelCount, 0)
    XCTAssertNil(harness.link.endedWith)
  }

  func testARefusedExecEndsTheChannel() {
    let harness = ChannelHarness()
    let id = harness.exec(remote: 9)
    let n = id.rawValue
    harness.server(W.data(n, [1, 2]))
    harness.server(W.failure(n))
    XCTAssertEqual(harness.take(), [.data(id, [1, 2]), .closed(id, .refused)])
    XCTAssertEqual(harness.sent.last, W.close(9), "closed rather than left open on the server")
    XCTAssertThrows(SSHError.usage(.channelClosed)) { () throws(SSHError) in try harness.core.write([1], to: id) }
    // The server's answering CLOSE frees the number; nothing more is reported.
    harness.server(W.close(n))
    XCTAssertEqual(harness.take(), [])
    XCTAssertEqual(harness.core.channelCount, 0)
    XCTAssertEqual(harness.sent.filter { $0 == W.close(9) }.count, 1)
  }

  func testStderrAndExitSignal() {
    let harness = ChannelHarness()
    let id = harness.exec(remote: 3)
    let n = id.rawValue
    harness.server(W.extended(n, Array("warning\n".utf8)))
    harness.server(W.data(n, Array("out".utf8)))
    // A Latin-1 message with an escape sequence: display text, sanitized.
    harness.server(W.exitSignal(n, "TERM", core: true, Array("killed by ".utf8) + [0xE9] + Array("\u{1B}[2J\nnow".utf8)))
    harness.server(W.exitStatus(n, 1))
    harness.server(W.close(n))
    XCTAssertEqual(harness.take(), [.stderr(id, Array("warning\n".utf8)), .data(id, Array("out".utf8)),
                                    .closed(id, .signal(name: "TERM", coreDumped: true, message: "killed by [2J now"))])
  }

  func testAChannelClosingWithoutStatusIsLost() {
    let harness = ChannelHarness()
    let id = harness.exec(remote: 4)
    harness.server(W.close(id.rawValue))
    XCTAssertEqual(harness.take(), [.closed(id, .lost)], "before any reply, too")
    XCTAssertEqual(harness.sent.last, W.close(4))
  }

  // MARK: Close orderings

  func testServerEOFThenClose() {
    let harness = ChannelHarness()
    let id = harness.exec(remote: 1)
    harness.server(W.eof(id.rawValue))
    XCTAssertEqual(harness.take(), [.eof(id)])
    // Half-closed: our input still goes.
    XCTAssertEqual(harness.write([5], to: id), 1)
    XCTAssertEqual(harness.sent.last, W.data(1, [5]))
    harness.server(W.close(id.rawValue))
    XCTAssertEqual(harness.take(), [.closed(id, .lost)])
    XCTAssertEqual(harness.sent.last, W.close(1))
  }

  func testOurEOFThenTheServersAnswer() {
    let harness = ChannelHarness()
    let id = harness.exec(remote: 2)
    let n = id.rawValue
    harness.write([1, 2, 3], to: id)
    harness.core.finishInput(id)
    harness.core.finishInput(id)
    XCTAssertEqual(harness.sent.suffix(2), [W.data(2, [1, 2, 3]), W.eof(2)], "EOF after the data, once")
    XCTAssertEqual(harness.sent.filter { $0 == W.eof(2) }.count, 1)
    XCTAssertThrows(SSHError.usage(.channelClosed)) { () throws(SSHError) in try harness.core.write([4], to: id) }
    harness.server(W.data(n, [9]))
    harness.server(W.exitStatus(n, 3))
    harness.server(W.eof(n))
    harness.server(W.close(n))
    XCTAssertEqual(harness.take(), [.data(id, [9]), .eof(id), .closed(id, .status(3))])
    XCTAssertEqual(harness.sent.last, W.close(2))
  }

  func testOurCloseFirst() {
    let harness = ChannelHarness()
    let id = harness.exec(remote: 3)
    let n = id.rawValue
    harness.server(W.exitStatus(n, 0))
    harness.core.close(id)
    harness.core.close(id)
    harness.drain()
    XCTAssertEqual(harness.take(), [.closed(id, .status(0))], "at once, with the status that arrived before")
    XCTAssertEqual(harness.sent.last, W.close(3))
    let count = harness.sent.count
    harness.server(W.data(n, [1]))
    harness.server(W.extended(n, [2]))
    harness.server(W.exitStatus(n, 1))
    harness.server(W.request(n, "keepalive@openssh.com", wantReply: true))
    harness.server(W.eof(n))
    harness.server(W.close(n))
    XCTAssertEqual(harness.take(), [])
    XCTAssertEqual(harness.sent.count, count, "no reply and no second CLOSE once ours went")
    XCTAssertEqual(harness.core.channelCount, 0)
    XCTAssertNil(harness.link.endedWith)
    // The number is free: a message for it now is for no channel.
    harness.server(W.close(n))
    XCTAssertEqual(harness.link.endedWith, .protocolViolation(.channel(.unknownChannel(n))))
  }

  func testClosingDropsInputThatWaitedForTheWindow() {
    let harness = ChannelHarness()
    let id = harness.exec(remote: 4, window: 0)
    XCTAssertEqual(harness.write(pattern(100), to: id), 100)
    harness.core.close(id)
    harness.drain()
    XCTAssertEqual(harness.take(), [.closed(id, .lost)])
    harness.server(W.adjust(id.rawValue, 1000))
    XCTAssertEqual(harness.dataSent(to: 4).bytes, [], "nothing after our CLOSE")
    XCTAssertThrows(SSHError.usage(.channelClosed)) { () throws(SSHError) in try harness.core.write([1], to: id) }
  }

  func testClosingWhileOpening() {
    let harness = ChannelHarness()
    let confirmed = try! harness.core.openExec("a")
    let refused = try! harness.core.openExec("b")
    harness.core.close(confirmed)
    harness.core.close(refused)
    harness.drain()
    XCTAssertEqual(harness.take(), [.openFailed(confirmed, .cancelled), .openFailed(refused, .cancelled)])
    harness.server(W.confirmation(confirmed.rawValue, sender: 50, window: 10, maximumPacket: 10))
    XCTAssertEqual(harness.sent.last, W.close(50), "no exec request: closed at once")
    harness.server(W.openFailure(refused.rawValue, reason: 2, []))
    harness.server(W.close(confirmed.rawValue))
    XCTAssertEqual(harness.take(), [])
    XCTAssertEqual(harness.core.channelCount, 0)
    XCTAssertNil(harness.link.endedWith)
  }

  // MARK: Shell

  func testAShellIsHandedOverAfterBothConfirmations() {
    let harness = ChannelHarness()
    let id = try! harness.core.openShell(term: "xterm-256color", size: TerminalSize(columns: 120, rows: 40))
    let n = id.rawValue
    harness.server(W.confirmation(n, sender: 11, window: 4096, maximumPacket: 1024))
    XCTAssertEqual(harness.sent.last, W.ptyRequest(11, term: "xterm-256color", columns: 120, rows: 40))
    XCTAssertThrows(SSHError.usage(.invalidArgument("the channel is not open yet"))) { () throws(SSHError) in
      try harness.core.write([1], to: id)
    }
    harness.server(W.success(n))
    XCTAssertEqual(harness.sent.last, W.shell(11), "shell only once pty-req was confirmed")
    // Output before the shell's confirmation (stderr too: a PTY merges it) is held until the hand-over.
    harness.server(W.data(n, Array("motd ".utf8)))
    harness.server(W.extended(n, Array("err".utf8)))
    XCTAssertEqual(harness.take(), [])
    harness.server(W.success(n))
    XCTAssertEqual(harness.take(), [.opened(id), .data(id, Array("motd err".utf8))])
    harness.server(W.extended(n, Array("!".utf8)))
    XCTAssertEqual(harness.take(), [.data(id, Array("!".utf8))])
    XCTAssertEqual(harness.write(Array("ls\r".utf8), to: id), 3)
    XCTAssertEqual(harness.sent.last, W.data(11, Array("ls\r".utf8)))
    harness.server(W.exitStatus(n, 0))
    harness.server(W.close(n))
    XCTAssertEqual(harness.take(), [.closed(id, .status(0))])
  }

  func testShellRefusals() {
    for refusePTY in [true, false] {
      let harness = ChannelHarness()
      let id = try! harness.core.openShell(term: "vt100", size: TerminalSize(columns: 80, rows: 24))
      harness.server(W.confirmation(id.rawValue, sender: 12, window: 0, maximumPacket: 1))
      if !refusePTY { harness.server(W.success(id.rawValue)) }
      harness.server(W.failure(id.rawValue))
      XCTAssertEqual(harness.take(), [.openFailed(id, .requestRefused(refusePTY ? .ptyRequest : .shell))])
      XCTAssertEqual(harness.sent.last, W.close(12))
      XCTAssertEqual(harness.sent.contains(W.shell(12)), !refusePTY)
      XCTAssertNil(harness.link.endedWith, "the connection stays up")
      harness.server(W.close(id.rawValue))
      XCTAssertEqual(harness.core.channelCount, 0)
      XCTAssertThrows(SSHError.usage(.channelClosed)) { () throws(SSHError) in
        try harness.core.resize(id, to: TerminalSize(columns: 1, rows: 1))
      }
    }
  }

  func testAShellTheServerClosesBeforeConfirmingDidNotOpen() {
    let harness = ChannelHarness()
    let id = try! harness.core.openShell(term: "vt100", size: TerminalSize(columns: 80, rows: 24))
    harness.server(W.confirmation(id.rawValue, sender: 13, window: 0, maximumPacket: 1))
    harness.server(W.data(id.rawValue, [1]))
    harness.server(W.close(id.rawValue))
    XCTAssertEqual(harness.take(), [.openFailed(id, .closed(.channelClosed))])
    XCTAssertEqual(harness.sent.last, W.close(13))
    XCTAssertNil(harness.link.endedWith)
  }

  func testResizeRules() {
    let harness = ChannelHarness()
    let id = try! harness.core.openShell(term: "xterm", size: TerminalSize(columns: 0, rows: 0))
    let n = id.rawValue
    harness.server(W.confirmation(n, sender: 14, window: 1 << 20, maximumPacket: 1 << 15))
    // Each at least 1.
    XCTAssertEqual(harness.sent.last, W.ptyRequest(14, term: "xterm", columns: 1, rows: 1))
    // Asked before the hand-over: held, the latest wins, sent once the shell is open.
    try! harness.core.resize(id, to: TerminalSize(columns: 50, rows: 10))
    try! harness.core.resize(id, to: TerminalSize(columns: 60, rows: 20))
    let before = harness.sent.count
    harness.server(W.success(n))
    harness.server(W.success(n))
    XCTAssertEqual(harness.sent(from: before), [W.shell(14), W.windowChange(14, columns: 60, rows: 20)])
    // The size in effect is not sent again.
    try! harness.core.resize(id, to: TerminalSize(columns: 60, rows: 20))
    XCTAssertEqual(harness.sent.count, before + 2)
    // In call order.
    try! harness.core.resize(id, to: TerminalSize(columns: 70, rows: 20))
    try! harness.core.resize(id, to: TerminalSize(columns: 60, rows: 20))
    XCTAssertEqual(harness.sent.suffix(2), [W.windowChange(14, columns: 70, rows: 20), W.windowChange(14, columns: 60, rows: 20)])
    // While the transport's backlog is full: held, superseded sizes skipped.
    harness.link.outboundBacklog = Limits.outboundBacklogBytes + 1
    try! harness.core.resize(id, to: TerminalSize(columns: 90, rows: 30))
    try! harness.core.resize(id, to: TerminalSize(columns: 100, rows: 30))
    XCTAssertEqual(harness.sent.count, before + 4)
    harness.link.outboundBacklog = 0
    harness.core.transportDrained()
    XCTAssertEqual(harness.sent.count, before + 5)
    XCTAssertEqual(harness.sent.last, W.windowChange(14, columns: 100, rows: 30))
    // Sizes superseded back to the one in effect send nothing.
    harness.link.outboundBacklog = Limits.outboundBacklogBytes + 1
    try! harness.core.resize(id, to: TerminalSize(columns: 10, rows: 10))
    try! harness.core.resize(id, to: TerminalSize(columns: 100, rows: 30))
    harness.link.outboundBacklog = 0
    harness.core.transportDrained()
    XCTAssertEqual(harness.sent.count, before + 5)
    // An opening size asked again before the hand-over sends nothing either.
    let other = try! harness.core.openShell(term: "xterm", size: TerminalSize(columns: 80, rows: 24))
    harness.server(W.confirmation(other.rawValue, sender: 16, window: 0, maximumPacket: 1))
    try! harness.core.resize(other, to: TerminalSize(columns: 81, rows: 24))
    try! harness.core.resize(other, to: TerminalSize(columns: 80, rows: 24))
    harness.server(W.success(other.rawValue))
    harness.server(W.success(other.rawValue))
    XCTAssertEqual(harness.sent.last, W.shell(16))
    XCTAssertEqual(harness.take(), [.opened(id), .opened(other)])
    // Not for exec; not once closed.
    let exec = harness.exec(remote: 15)
    XCTAssertThrows(SSHError.usage(.invalidArgument("resizing an exec channel"))) { () throws(SSHError) in
      try harness.core.resize(exec, to: TerminalSize(columns: 1, rows: 1))
    }
    harness.core.close(id)
    XCTAssertThrows(SSHError.usage(.channelClosed)) { () throws(SSHError) in
      try harness.core.resize(id, to: TerminalSize(columns: 2, rows: 2))
    }
  }

  func testInvalidArguments() {
    let harness = ChannelHarness()
    for term in ["", "xterm 256", String(repeating: "x", count: 65), "x,y"] {
      XCTAssertThrows(SSHError.usage(.invalidArgument("a terminal type that is not a name"))) { () throws(SSHError) in
        try harness.core.openShell(term: term, size: TerminalSize(columns: 80, rows: 24))
      }
    }
    XCTAssertThrows(SSHError.usage(.invalidArgument("a command too long"))) { () throws(SSHError) in
      try harness.core.openExec(String(repeating: "a", count: Limits.packetLength))
    }
    XCTAssertEqual(harness.sent, [])
    XCTAssertThrows(SSHError.usage(.channelClosed)) { () throws(SSHError) in
      try harness.core.write([1], to: ChannelID(rawValue: 99))
    }
  }

  // MARK: The server's requests and opens

  func testServerRequestsOnOurChannels() {
    let harness = ChannelHarness()
    let id = harness.exec(remote: 21)
    let n = id.rawValue
    let start = harness.sent.count
    harness.server(W.request(n, "keepalive@openssh.com", wantReply: true))
    harness.server(W.request(n, "eow@openssh.com", wantReply: false))
    harness.server(W.request(n, "eow@openssh.com", wantReply: true))
    harness.server(W.request(n, "x11-req", wantReply: true, [0] + Raw.string("MIT") + Raw.string("abc") + Raw.u32(0)))
    harness.server(W.request(n, "unknown@example.invalid", wantReply: false, [1, 2, 3]))
    harness.server(W.exitStatus(n, 7, wantReply: true))
    XCTAssertEqual(harness.sent(from: start), [W.failure(21), W.failure(21), W.failure(21), W.success(21)])
    XCTAssertEqual(harness.take(), [])
    harness.server(W.exitStatus(n, 8))
    harness.server(W.close(n))
    XCTAssertEqual(harness.take(), [.closed(id, .status(7))], "the first status stands")
    XCTAssertNil(harness.link.endedWith)
  }

  func testMalformedRequestsEndTheConnection() {
    let cases: [[UInt8]] = [
      W.request(0, "exit-status", wantReply: false),  // no status
      W.request(0, "exit-status", wantReply: false, Raw.u32(1) + [0]),  // trailing byte
      W.request(0, "exit-signal", wantReply: false, Raw.string("TERM") + [0] + Raw.string("")),  // no language tag
      W.request(0, "exit-signal", wantReply: false, Raw.string("SIG TERM") + [0] + Raw.string("") + Raw.string("")),
      W.request(0, "bad name", wantReply: true),
      W.request(0, "keepalive@openssh.com", wantReply: true) + [],
      [98] + Raw.u32(0) + Raw.string("keepalive@openssh.com") + [2],
    ]
    for (index, payload) in cases.enumerated() {
      let harness = ChannelHarness()
      _ = harness.exec(remote: 22)
      harness.server(payload)
      if index == 5 {
        XCTAssertNil(harness.link.endedWith, "a valid request")
        continue
      }
      guard case .protocolViolation(.malformed(.channelRequest, _))? = harness.link.endedWith else {
        XCTFail("case \(index): \(String(describing: harness.link.endedWith))")
        continue
      }
    }
  }

  func testTheServersChannelOpensAreRefused() {
    let harness = ChannelHarness()
    harness.server(W.serverOpen("forwarded-tcpip", sender: 0xDEAD, extra: Raw.string("127.0.0.1") + Raw.u32(80)
      + Raw.string("192.0.2.1") + Raw.u32(5555)))
    harness.server(W.serverOpen("auth-agent@openssh.com", sender: 3))
    XCTAssertEqual(harness.sent, [[92] + Raw.u32(0xDEAD) + Raw.u32(1) + Raw.string("") + Raw.string(""),
                                  [92] + Raw.u32(3) + Raw.u32(1) + Raw.string("") + Raw.string("")])
    XCTAssertEqual(harness.core.channelCount, 0)
    XCTAssertNil(harness.link.endedWith)
    harness.server([90] + Raw.string("x11") + Raw.u32(1))
    guard case .protocolViolation(.malformed(.channelOpen, _))? = harness.link.endedWith else {
      return XCTFail("\(String(describing: harness.link.endedWith))")
    }
  }

  func testAnOpenFailureCarriesTheServersReason() {
    let harness = ChannelHarness()
    let id = try! harness.core.openExec("x")
    harness.server(W.openFailure(id.rawValue, reason: 4, Array("too many\nsessions \u{1B}[0m".utf8) + [0xFF]))
    XCTAssertEqual(harness.take(), [.openFailed(id, .channelOpenFailed(.resourceShortage, description: "too many sessions [0m"))])
    XCTAssertEqual(harness.core.channelCount, 0)
    XCTAssertNil(harness.link.endedWith)
  }

  // MARK: Limits and the end

  func testTheChannelCountIsBounded() {
    let harness = ChannelHarness()
    var ids: [ChannelID] = []
    for _ in 0..<Limits.channels { ids.append(try! harness.core.openExec("x")) }
    XCTAssertEqual(Set(ids).count, Limits.channels)
    XCTAssertThrows(SSHError.usage(.tooManyChannels)) { () throws(SSHError) in try harness.core.openExec("x") }
    harness.server(W.openFailure(ids[5].rawValue, reason: 1, []))
    let reopened = try? harness.core.openExec("x")
    XCTAssertNotNil(reopened)
    XCTAssertFalse(ids.contains(reopened!), "numbers are not reused at once")
    // A closed channel keeps its number until the server's CLOSE.
    harness.server(W.confirmation(ids[0].rawValue, sender: 1, window: 0, maximumPacket: 1))
    harness.core.close(ids[0])
    XCTAssertThrows(SSHError.usage(.tooManyChannels)) { () throws(SSHError) in try harness.core.openExec("x") }
    harness.server(W.close(ids[0].rawValue))
    XCTAssertNoThrow(try harness.core.openExec("x"))
  }

  func testTheConnectionsEndEndsEveryChannel() {
    let harness = ChannelHarness()
    let opening = try! harness.core.openExec("a")
    let running = harness.exec(remote: 31)
    harness.server(W.exitStatus(running.rawValue, 2))
    let shell = harness.shell(remote: 32)
    let pending = try! harness.core.openShell(term: "xterm", size: TerminalSize(columns: 1, rows: 1))
    harness.server(W.confirmation(pending.rawValue, sender: 33, window: 0, maximumPacket: 1))
    let end = SSHError.closed(.connectionLost)
    harness.link.end(end)
    harness.core.connectionEnded(end)
    harness.core.connectionEnded(.closed(.byClient))
    harness.drain()
    XCTAssertEqual(harness.take(), [.openFailed(opening, end), .closed(running, .status(2)), .closed(shell, .lost),
                                    .openFailed(pending, end)])
    XCTAssertThrows(end) { () throws(SSHError) in try harness.core.write([1], to: running) }
    XCTAssertThrows(SSHError.closed(.alreadyEnded)) { () throws(SSHError) in try harness.core.openExec("b") }
    XCTAssertThrows(SSHError.usage(.channelClosed)) { () throws(SSHError) in
      try harness.core.resize(shell, to: TerminalSize(columns: 2, rows: 2))
    }
    harness.core.close(running)
    harness.core.finishInput(running)
    harness.core.consumed(10, on: running)
    harness.core.transportDrained()
    harness.server(W.data(running.rawValue, [1]))
    XCTAssertEqual(harness.take(), [])
    XCTAssertEqual(harness.core.channelCount, 0)
  }
}
