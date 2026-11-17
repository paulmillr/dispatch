import Foundation
import XCTest
@testable import SSHEngine

/// Channels through the driver and the facade, in memory: exec output, stderr and every exit kind, input and its
/// end, the window stopping a writer, shells with resize, close orderings, many channels at once, and every call
/// after the channel or the connection ended.
final class DriverChannelTests: XCTestCase {
  func testExecOutputStderrAndStatus() async throws {
    let script = ServerScript()
    script.commands["report"] = [.stdout(Array("out".utf8)), .stderr(Array("err".utf8)), .stdout(Array("put".utf8)),
                                 .exitStatus(3), .eof, .close]
    let world = await MemoryWorld.make(script: script)
    let session = try await world.loggedIn()
    let exec = try await session.exec("report")
    var chunks: [ChannelOutput] = []
    while let chunk = try await exec.read() { chunks.append(chunk) }
    XCTAssertEqual(chunks, [.stdout(Array("out".utf8)), .stderr(Array("err".utf8)), .stdout(Array("put".utf8))])
    let exit = await exec.exit()
    XCTAssertEqual(exit, .status(3))
    await session.close()
  }

  func testASignalARefusalAndALoss() async throws {
    let (_, session) = try await MemoryWorld.loggedIn {
      $0.commands["killed"] = [.exitSignal("TERM"), .eof, .close]
      $0.commands["vanish"] = [.close]
      $0.execReply = { $0 != "refused" }
    }
    let killed = try await session.exec("killed")
    let killedOutput = try await killed.read()
    XCTAssertNil(killedOutput)
    let killedExit = await killed.exit()
    XCTAssertEqual(killedExit, .signal(name: "TERM", coreDumped: false, message: "killed"))
    let refused = try await session.exec("refused")
    let refusedOutput = try await refused.read()
    XCTAssertNil(refusedOutput)
    let refusedExit = await refused.exit()
    XCTAssertEqual(refusedExit, .refused)
    let vanish = try await session.exec("vanish")
    let vanishOutput = try await vanish.read()
    XCTAssertNil(vanishOutput)
    let vanishExit = await vanish.exit()
    XCTAssertEqual(vanishExit, .lost)
    await session.close()
  }

  func testInputAndItsEnd() async throws {
    let world = await MemoryWorld.make()
    let session = try await world.loggedIn()
    let exec = try await session.exec("cat")
    try await exec.write(Array("hello ".utf8))
    try await exec.write(Array("world".utf8))
    await exec.finishInput()
    await exec.finishInput()
    await assertThrows(.usage(.channelClosed)) { try await exec.write([1]) }
    let output = try await Collected.all(exec)
    XCTAssertEqual(output.stdout, Array("hello world".utf8))
    let exit = await exec.exit()
    XCTAssertEqual(exit, .status(0))
    await session.close()
  }

  func testChannelsNeedALogin() async throws {
    let world = await MemoryWorld.make()
    let session = try await world.connect()
    await assertThrows(.usage(.notAuthenticated)) { try await session.exec("cat") }
    await assertThrows(.usage(.notAuthenticated)) { try await session.shell(term: "xterm", size: .init(columns: 80, rows: 24)) }
    await session.close()
  }

  func testARefusedOpen() async throws {
    let (_, session) = try await MemoryWorld.loggedIn { $0.refuseOpen = true }
    await assertThrows(.channelOpenFailed(.administrativelyProhibited, description: "no channels here")) {
      try await session.exec("cat")
    }
    await session.close()
  }

  /// A server whose window is 0 stops the writer once the channel holds `Limits.channelInputBytes`; its adjust lets
  /// the write finish, and everything arrives in order.
  func testTheWindowStopsTheWriter() async throws {
    let (world, session) = try await MemoryWorld.loggedIn {
      $0.window = 0
      $0.commands["sink"] = []
    }
    let exec = try await session.exec("sink")
    let data = (0..<(Limits.channelInputBytes + 100_000)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
    let write = Task { try await exec.write(data) }
    let stats = try await bounded(10, "the writer waits") { await session.driver.waitForStats { $0.waitingWriters == 1 } }
    XCTAssertEqual(stats.waitingWriters, 1)
    let sentBefore = await world.peer.received.numbered(94).count
    XCTAssertEqual(sentBefore, 0, "nothing beyond a zero window")
    await world.peer.send([93] + Raw.u32(0) + Raw.u32(UInt32(data.count)))
    try await bounded(10, "the write") { try await write.value }
    _ = await world.peer.waitFor { received in
      received.numbered(94).reduce(0) { $0 + $1.count - 9 } >= data.count
    }
    let input = await world.peer.input(0)
    XCTAssertEqual(input, data)
    await session.close()
  }

  func testAShellResizesAndCloses() async throws {
    let world = await MemoryWorld.make()
    let session = try await world.loggedIn()
    let shell = try await session.shell(term: "xterm-256color", size: .init(columns: 80, rows: 24))
    try await shell.write(Array("ls\n".utf8))
    let echoed = try await shell.read()
    XCTAssertEqual(echoed, Array("ls\n".utf8))
    try shell.resize(.init(columns: 80, rows: 24))
    try shell.resize(.init(columns: 100, rows: 30))
    try shell.resize(.init(columns: 120, rows: 40))
    _ = try await bounded(10, "the window change") { [world] in
      await world.peer.waitFor { $0.numbered(98).contains { Array($0[5..<min($0.count, 22)]) == Array(Raw.string("window-change")) } }
    }
    try await shell.write(Array("x".utf8))
    _ = try await shell.read()
    let changes = await world.peer.windowChanges
    XCTAssertEqual(changes.last?.columns, 120)
    XCTAssertEqual(changes.last?.rows, 40)
    XCTAssertFalse(changes.contains { $0.columns == 80 }, "none for the size in effect")
    let ptyRequests = await world.peer.received.numbered(98).filter { $0.count > 20 && $0[9..<16] == Array("pty-req".utf8)[...] }
    XCTAssertEqual(ptyRequests.count, 1)
    await shell.close()
    let exit = await shell.exit()
    XCTAssertEqual(exit, .lost)
    XCTAssertThrows(SSHError.usage(.channelClosed)) { () throws(SSHError) in try shell.resize(.init(columns: 1, rows: 1)) }
    await assertThrows(.usage(.channelClosed)) { try await shell.write([1]) }
    let after = try await shell.read()
    XCTAssertNil(after)
    await session.close()
  }

  func testRefusedShellRequests() async throws {
    let (world, session) = try await MemoryWorld.loggedIn { $0.ptyReply = false }
    await assertThrows(.requestRefused(.ptyRequest)) { try await session.shell(term: "xterm", size: .init(columns: 80, rows: 24)) }
    await world.peer.edit { $0.ptyReply = true; $0.shellReply = false }
    await assertThrows(.requestRefused(.shell)) { try await session.shell(term: "xterm", size: .init(columns: 80, rows: 24)) }
    // The connection stays up.
    let exec = try await session.exec("cat")
    await exec.finishInput()
    let exit = await exec.exit()
    XCTAssertEqual(exit, .status(0))
    await session.close()
  }

  func testClosingAnExecDropsItsOutput() async throws {
    let (_, session) = try await MemoryWorld.loggedIn {
      $0.commands["chatty"] = [.stdout(Array("one".utf8)), .stdout(Array("two".utf8))]
    }
    let exec = try await session.exec("chatty")
    let first = try await exec.read()
    XCTAssertEqual(first, .stdout(Array("one".utf8)))
    await exec.close()
    await exec.close()
    let after = try await exec.read()
    XCTAssertNil(after)
    let exit = await exec.exit()
    XCTAssertEqual(exit, .lost)
    await assertThrows(.usage(.channelClosed)) { try await exec.write([1]) }
    await session.close()
  }

  func testManyChannelsAtOnce() async throws {
    let world = await MemoryWorld.make()
    let session = try await world.loggedIn()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<40 {
        group.addTask {
          let exec = try await session.exec("cat")
          let data = Array("channel \(index) ".utf8) + [UInt8](repeating: UInt8(index), count: 5000 + index * 37)
          try await exec.write(data)
          await exec.finishInput()
          let output = try await Collected.all(exec)
          XCTAssertEqual(output.stdout, data, "channel \(index)")
          let exit = await exec.exit()
          XCTAssertEqual(exit, .status(0))
        }
      }
      try await group.waitForAll()
    }
    await session.close()
  }

  func testTooManyChannels() async throws {
    let (world, session) = try await MemoryWorld.loggedIn { $0.commands["idle"] = [] }
    var open: [any ExecChannel] = []
    for _ in 0..<Limits.channels { open.append(try await session.exec("idle")) }
    await assertThrows(.usage(.tooManyChannels)) { try await session.exec("idle") }
    await open[0].close()
    // The number frees with the server's CLOSE, which the driver reads some time after the peer has ours: until then
    // another open is still refused, so this asks until one is taken.
    _ = await world.peer.waitFor { $0.numbered(97).count == 1 }
    let again = try await bounded(10, "a channel after one closed") {
      while true {
        do {
          return try await session.exec("idle")
        } catch SSHError.usage(.tooManyChannels) {
          try await Task.sleep(for: .milliseconds(5))
        }
      }
    }
    open.append(again)
    await session.close()
  }

  /// The connection ends with operations pending: each ends with the connection's reason, once.
  func testTheEndWhileOperationsArePending() async throws {
    let (world, session) = try await MemoryWorld.loggedIn {
      $0.commands["idle"] = []
      $0.window = 0
    }
    let exec = try await session.exec("idle")
    let reader = Task { try await exec.read() }
    let writer = Task { try await exec.write([UInt8](repeating: 7, count: Limits.channelInputBytes + 1)) }
    let exit = Task { await exec.exit() }
    _ = try await bounded(10, "the writer waits") { await session.driver.waitForStats { $0.waitingWriters == 1 } }
    await world.peer.edit { $0.holdOpen = true }
    let opening = Task { try await session.exec("idle") }
    _ = await world.peer.waitFor { $0.numbered(90).count == 2 }
    let enders = (0..<5).map { _ in Task { await session.ended() } }
    await world.peer.reset()
    let lost = SSHError.closed(.connectionLost)
    let readFailure = await reader.sshError
    XCTAssertEqual(readFailure, lost)
    let writeFailure = await writer.sshError
    XCTAssertEqual(writeFailure, lost)
    let openFailure = await opening.sshError
    XCTAssertEqual(openFailure, lost)
    let exitValue = await exit.value
    XCTAssertEqual(exitValue, .lost)
    for ender in enders {
      let end = await ender.value
      XCTAssertEqual(end, lost)
    }
    // After the end.
    await assertThrows(.closed(.alreadyEnded)) { try await session.exec("idle") }
    await assertThrows(.closed(.alreadyEnded)) { try await session.shell(term: "xterm", size: .init(columns: 1, rows: 1)) }
    await assertThrows(.closed(.alreadyEnded)) { try await session.authenticate(user: "phone", with: .password(SecretBytes(utf8: "x"))) }
    await assertThrows(lost) { try await exec.write([1]) }
    await assertThrows(lost) { try await exec.read() }
    await exec.finishInput()
    await exec.close()
    let laterExit = await exec.exit()
    XCTAssertEqual(laterExit, .lost)
    await session.close()
    let end = await session.ended()
    XCTAssertEqual(end, lost, "the first cause stays")
  }

  /// Output that arrived before the connection's end is still read, then the end; a channel whose output had ended
  /// reads nil.
  func testBufferedOutputSurvivesTheEnd() async throws {
    let (world, session) = try await MemoryWorld.loggedIn {
      $0.commands["partial"] = [.stdout(Array("kept".utf8))]
      $0.commands["done"] = [.stdout(Array("all".utf8)), .exitStatus(0), .eof]
    }
    let partial = try await session.exec("partial")
    let done = try await session.exec("done")
    _ = try await bounded(10, "the output") {
      await session.driver.waitForStats { $0.maximumBufferedOutput >= 4 }
    }
    // Make sure both commands' output is in before the reset: a round trip on a third channel.
    let probe = try await session.exec("cat")
    await probe.finishInput()
    _ = await probe.exit()
    await world.peer.reset()
    _ = await session.ended()
    let kept = try await partial.read()
    XCTAssertEqual(kept, .stdout(Array("kept".utf8)))
    await assertThrows(.closed(.connectionLost)) { try await partial.read() }
    let all = try await done.read()
    XCTAssertEqual(all, .stdout(Array("all".utf8)))
    let finished = try await done.read()
    XCTAssertNil(finished)
    let status = await done.exit()
    XCTAssertEqual(status, .status(0), "the status that arrived before the end")
  }

  /// A server that sends past the window it was granted breaks the protocol: the connection ends with it.
  func testDataBeyondTheWindowEndsTheConnection() async throws {
    let (world, session) = try await MemoryWorld.loggedIn {
      $0.commands["flood"] = (0..<70).map { _ in .stdout([UInt8](repeating: 1, count: 32 * 1024)) }
    }
    let exec = try await session.exec("flood")
    let violation = SSHError.protocolViolation(.channel(.windowExceeded))
    let end = await session.ended()
    XCTAssertEqual(end, violation)
    var failure: SSHError?
    do {
      while try await exec.read() != nil {}
    } catch {
      failure = error
    }
    XCTAssertEqual(failure, violation)
    let disconnects = await world.peer.waitFor { !$0.numbered(1).isEmpty }.numbered(1)
    XCTAssertEqual(disconnects.first.map { Array($0[1..<5]) }, Raw.u32(DisconnectReason.protocolError.rawValue))
  }

  func testCancellingAnOpen() async throws {
    let (world, session) = try await MemoryWorld.loggedIn { $0.holdOpen = true }
    let opening = Task { try await session.exec("cat") }
    _ = await world.peer.waitFor { !$0.numbered(90).isEmpty }
    opening.cancel()
    let failure = await opening.sshError
    XCTAssertEqual(failure, .cancelled)
    await world.peer.edit { $0.holdOpen = false }
    let exec = try await session.exec("cat")
    await exec.finishInput()
    let exit = await exec.exit()
    XCTAssertEqual(exit, .status(0), "the session goes on")
    await session.close()
  }

  func testCancellingAReadAndAWrite() async throws {
    let (_, session) = try await MemoryWorld.loggedIn {
      $0.window = 0
      $0.commands["idle"] = []
    }
    let exec = try await session.exec("idle")
    let reader = Task { try await exec.read() }
    let writer = Task { try await exec.write([UInt8](repeating: 1, count: Limits.channelInputBytes + 10)) }
    _ = try await bounded(10, "the writer waits") { await session.driver.waitForStats { $0.waitingWriters == 1 } }
    reader.cancel()
    writer.cancel()
    let readFailure = await reader.sshError
    XCTAssertEqual(readFailure, .cancelled)
    let writeFailure = await writer.sshError
    XCTAssertEqual(writeFailure, .cancelled)
    await exec.close()
    await session.close()
  }

  func testReleasingTheSessionClosesTheConnection() async throws {
    let world = await MemoryWorld.make()
    var session: (any SSHSession)? = try await world.loggedIn()
    let driver = session!.driver
    session = nil
    let end = try await bounded(10, "the release") { await driver.ended() }
    XCTAssertEqual(end, .closed(.byClient))
    try await bounded(10, "the stream's close") { await world.peer.waitUntilClientClosed() }
    let disconnect = await world.peer.received.numbered(1)
    XCTAssertEqual(disconnect.count, 1)
    XCTAssertEqual(disconnect.first.map { Array($0[1..<5]) }, Raw.u32(DisconnectReason.byApplication.rawValue))
  }

  /// Once closed and released, nothing keeps the driver alive: no loop, timer or task holds it.
  func testAClosedReleasedSessionFreesItsDriver() async throws {
    let released = Signal()
    var tuning = DriverTuning()
    tuning.released = { released.fire() }
    var options = MemoryWorld.options
    options.keepaliveInterval = .seconds(30)
    let world = await MemoryWorld.make(tuning: tuning)
    do {
      let session = try await world.loggedIn(options)
      let exec = try await session.exec("cat")
      try await exec.write([1, 2, 3])
      _ = try await exec.read()
      let shell = try await session.shell(term: "vt100", size: .init(columns: 80, rows: 24))
      try shell.resize(.init(columns: 81, rows: 25))
      await session.close()
    }
    try await bounded(10, "the driver's release") { await released.wait() }
  }

  func testReleasingAChannelClosesIt() async throws {
    let (world, session) = try await MemoryWorld.loggedIn { $0.commands["idle"] = [] }
    var exec: (any ExecChannel)? = try await session.exec("idle")
    _ = exec
    exec = nil
    _ = try await bounded(10, "the channel's close") { await world.peer.waitFor { !$0.numbered(97).isEmpty } }
    let records = try await bounded(10, "the record's release") { () async -> Int in
      _ = await session.driver.waitForStats { _ in true }
      return await session.driver.channelRecords
    }
    XCTAssertEqual(records, 0)
    await session.close()
  }
}

/// What the MobileTransport adapter relies on beyond the protocol's text: a closed channel never leaves a read or a
/// write waiting, and one ordered output stream that keeps everything sent before the server's CLOSE.
final class DriverChannelGuaranteeTests: XCTestCase {
  /// The client's own close ends a pending read at once (nil), and every later one, though the server never answers
  /// the CLOSE.
  func testTheClientsCloseEndsAPendingRead() async throws {
    let (world, session) = try await MemoryWorld.loggedIn {
      $0.commands["idle"] = []
      $0.answerClose = false
    }
    let exec = try await session.exec("idle")
    let shell = try await session.shell(term: "vt100", size: .init(columns: 80, rows: 24))
    let execRead = Task { try await exec.read() }
    let shellRead = Task { try await shell.read() }
    _ = try await bounded(10, "both reads wait") { await session.driver.waitForStats { $0.waitingReaders == 2 } }
    await exec.close()
    await shell.close()
    let execOutput = try await bounded(5, "the exec read") { try await execRead.value }
    XCTAssertNil(execOutput)
    let shellOutput = try await bounded(5, "the shell read") { try await shellRead.value }
    XCTAssertNil(shellOutput)
    let laterExec = try await exec.read()
    XCTAssertNil(laterExec)
    let laterShell = try await shell.read()
    XCTAssertNil(laterShell)
    // The CLOSEs reach the peer through the write loop and the peer's read, after `close` returned: wait for them.
    let closes = try await bounded(10, "both CLOSEs at the peer") {
      await world.peer.waitFor { $0.numbered(97).count >= 2 }.numbered(97).count
    }
    XCTAssertEqual(closes, 2, "both CLOSEs went; the server answered neither")
    await session.close()
  }

  /// The client's close drops unread output also when the server had closed the channel first: a later read is nil.
  func testTheClientsCloseAfterTheServersDropsUnreadOutput() async throws {
    let (_, session) = try await MemoryWorld.loggedIn {
      $0.commands["said"] = [.stdout(Array("unread".utf8)), .exitStatus(0), .eof, .close]
    }
    let exec = try await session.exec("said")
    let exit = try await bounded(10, "the exit") { await exec.exit() }
    XCTAssertEqual(exit, .status(0))
    await exec.close()
    let after = try await exec.read()
    XCTAssertNil(after)
    await session.close()
  }

  /// A write suspended for the window throws once the channel closes, whichever side closed it; so does every later
  /// write. (The connection's end: `DriverChannelTests.testTheEndWhileOperationsArePending`.)
  func testASuspendedWriteThrowsWhenTheChannelCloses() async throws {
    let (world, session) = try await MemoryWorld.loggedIn {
      $0.window = 0
      $0.commands["idle"] = []
    }
    let big = [UInt8](repeating: 9, count: Limits.channelInputBytes + 1)

    let ours = try await session.exec("idle")
    let oursWrite = Task { try await ours.write(big) }
    _ = try await bounded(10, "the first writer waits") { await session.driver.waitForStats { $0.waitingWriters == 1 } }
    await ours.close()
    let oursFailure = try await bounded(5, "the first write") { await oursWrite.sshError }
    XCTAssertEqual(oursFailure, .usage(.channelClosed))
    await assertThrows(.usage(.channelClosed)) { try await ours.write([1]) }

    let theirs = try await session.shell(term: "vt100", size: .init(columns: 80, rows: 24))
    let theirsWrite = Task { try await theirs.write(big) }
    _ = try await bounded(10, "the second writer waits") { await session.driver.waitForStats { $0.waitingWriters == 1 } }
    // The shell is the client's channel 1 (0 is still taken until the server answers its CLOSE).
    let opens = await world.peer.received.numbered(90)
    let shellNumber = UInt32(opens.count - 1)
    await world.peer.send([97] + Raw.u32(shellNumber))
    let theirsFailure = try await bounded(5, "the second write") { await theirsWrite.sshError }
    XCTAssertEqual(theirsFailure, .usage(.channelClosed))
    await assertThrows(.usage(.channelClosed)) { try await theirs.write([1]) }
    let exit = await theirs.exit()
    XCTAssertEqual(exit, .lost)
    await session.close()
  }

  /// stdout and stderr interleaved, a status, EOF and CLOSE: `exit()` resolves first, then every chunk still reads,
  /// in arrival order, through one stream.
  func testNothingSentBeforeTheServersCloseIsDropped() async throws {
    let script = ServerScript()
    var steps: [CommandStep] = []
    var expected: [ChannelOutput] = []
    for index in 0..<24 {
      let bytes = [UInt8](repeating: UInt8(index), count: 100 + index * 50)
      let chunk: ChannelOutput = index % 3 == 1 ? .stderr(bytes) : .stdout(bytes)
      expected.append(chunk)
      switch chunk {
      case .stdout(let data): steps.append(.stdout(data))
      case .stderr(let data): steps.append(.stderr(data))
      }
    }
    script.commands["mixed"] = steps + [.exitStatus(7), .eof, .close]
    let world = await MemoryWorld.make(script: script)
    let session = try await world.loggedIn()
    let exec = try await session.exec("mixed")
    let exit = try await bounded(10, "the exit") { await exec.exit() }
    XCTAssertEqual(exit, .status(7))
    var chunks: [ChannelOutput] = []
    while let chunk = try await exec.read() { chunks.append(chunk) }
    XCTAssertEqual(chunks, expected)

    // A shell the server ends: its output before the CLOSE reads after the exit.
    let shell = try await session.shell(term: "vt100", size: .init(columns: 80, rows: 24))
    let number = UInt32(await world.peer.received.numbered(90).count - 1)
    await world.peer.send([94] + Raw.u32(number) + Raw.string(Array("last words".utf8)))
    await world.peer.send([98] + Raw.u32(number) + Raw.string("exit-status") + [0] + Raw.u32(0))
    await world.peer.send([97] + Raw.u32(number))
    let shellExit = try await bounded(10, "the shell's exit") { await shell.exit() }
    XCTAssertEqual(shellExit, .status(0))
    let words = try await shell.read()
    XCTAssertEqual(words, Array("last words".utf8))
    let end = try await shell.read()
    XCTAssertNil(end)
    await session.close()
  }
}

extension MemoryWorld {
  /// A world whose script `configure` set up, connected and logged in with a password.
  static func loggedIn(_ configure: (ServerScript) -> Void) async throws -> (MemoryWorld, any SSHSession) {
    let script = ServerScript()
    configure(script)
    let world = await MemoryWorld.make(script: script)
    return (world, try await world.loggedIn())
  }
}
