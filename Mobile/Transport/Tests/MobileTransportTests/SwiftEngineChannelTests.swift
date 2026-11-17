import Darwin
import Foundation
@testable import MobileTransport
import SSHEngine
import XCTest

/// The Swift engine adapter's channel descriptors (`SwiftEngineBridge`, `SwiftEngineSocket`) against scripted facade
/// channels: the socket the seam states, data both ways with backpressure, every order of the ends, stderr, the exits,
/// and no descriptor or thread left behind.
final class SwiftEngineChannelTests: XCTestCase {
  /// Unread output the adapter may hold for a caller that stopped reading: the socket's two 1 MiB buffers and the chunk
  /// in flight, with room to spare.
  private static let socketBound = 4 << 20

  private struct Opened {
    let session: SwiftEngineSession
    let events: RecordedChannel
    let fd: Int32
    let parked: Watched<[SwiftEngineSocketWait]>
  }

  private func session(exec core: ScriptedChannel? = nil, shell: ScriptedChannel? = nil) -> (ScriptedSession, SwiftEngineSession, Watched<[SwiftEngineSocketWait]>) {
    let fake = ScriptedSession()
    if let core { fake.exec = { _, _ in ScriptedExec(core) } }
    if let shell { fake.shell = { _, _, _ in ScriptedShell(shell) } }
    let parked = Watched<[SwiftEngineSocketWait]>([])
    return (fake, SwiftEngineSession(fake, parked: { wait in parked.change { $0.append(wait) } }), parked)
  }

  private func openExec(_ core: ScriptedChannel, file: StaticString = #filePath, line: UInt = #line) async throws -> Opened {
    let (_, session, parked) = session(exec: core)
    let events = RecordedChannel()
    session.exec("cat", events: events)
    await wait(events.calls, "opened", file: file, line: line) { !$0.isEmpty }
    let fd = try XCTUnwrap(events.descriptor, "\(events.calls.value)", file: file, line: line)
    return Opened(session: session, events: events, fd: fd, parked: parked)
  }

  private func openShell(_ core: ScriptedChannel, file: StaticString = #filePath, line: UInt = #line) async throws -> (Opened, any EngineShell) {
    let (_, session, parked) = session(shell: core)
    let events = RecordedChannel()
    let control = session.shell(term: "xterm-256color", columns: 80, rows: 24, events: events)
    await wait(events.calls, "opened", file: file, line: line) { !$0.isEmpty }
    let fd = try XCTUnwrap(events.descriptor, "\(events.calls.value)", file: file, line: line)
    return (Opened(session: session, events: events, fd: fd, parked: parked), control)
  }

  private func exited(_ opened: Opened, file: StaticString = #filePath, line: UInt = #line) async -> EngineExit? {
    await wait(opened.events.calls, "exited", file: file, line: line) { calls in
      calls.contains { if case .exited = $0 { true } else { false } }
    }
    XCTAssertEqual(opened.events.late.value, 0, "calls after the last one", file: file, line: line)
    XCTAssertEqual(opened.events.mainThread.value, 0, "a callback on the main thread", file: file, line: line)
    return opened.events.exit
  }

  // MARK: The socket

  func testTheCallersEndIsTheSocketTheSeamStates() async throws {
    let core = ScriptedChannel()
    let opened = try await openExec(core)
    defer { Darwin.close(opened.fd) }
    var type: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
    XCTAssertEqual(getsockopt(opened.fd, SOL_SOCKET, SO_TYPE, &type, &size), 0)
    XCTAssertEqual(type, SOCK_STREAM)
    var address = sockaddr_storage(), length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(opened.fd, $0, &length) } }
    XCTAssertEqual(Int32(address.ss_family), AF_UNIX)
    XCTAssertTrue(CallerSide.isBlocking(opened.fd))
    XCTAssertEqual(fcntl(opened.fd, F_GETFD) & FD_CLOEXEC, FD_CLOEXEC)
    var flag: Int32 = 0
    XCTAssertEqual(getsockopt(opened.fd, SOL_SOCKET, SO_NOSIGPIPE, &flag, &size), 0)
    XCTAssertNotEqual(flag, 0)
    for option in [SO_SNDBUF, SO_RCVBUF] {
      var buffer: Int32 = 0
      XCTAssertEqual(getsockopt(opened.fd, SOL_SOCKET, option, &buffer, &size), 0)
      XCTAssertEqual(buffer, 1 << 20)
    }
    core.finish(.status(0))
    _ = await exited(opened)
  }

  // MARK: Data both ways

  /// 8 MiB each way through an exec, output in chunks of every size up to the maximum packet with stderr between them:
  /// everything arrives, in order, stderr through the events and before `exited`.
  func testExecMegabytesEachWay() async throws {
    let size = 8 << 20
    let output = Self.random(size), input = Self.random(size)
    let supply = Supply(output, chunk: { 1 + ($0 * 7919) % 32_768 }, stderrEvery: 7)
    let core = ScriptedChannel(supply: supply.next)
    let opened = try await openExec(core)
    defer { Darwin.close(opened.fd) }
    async let wrote = Self.writeThenFinish(opened.fd, input)
    let read = await CallerSide.readAll(opened.fd, limit: size)
    let finished = await wrote
    XCTAssertTrue(finished)
    XCTAssertEqual(read.error, 0)
    XCTAssertEqual(read.bytes.count, size)
    XCTAssertEqual(sha256(read.bytes), sha256(output))
    try await endOfFileFollows(opened, core)
    await wait(core.state, "the input and its end") { $0.inputFinished }
    XCTAssertEqual(core.state.value.received.count, size)
    XCTAssertEqual(sha256(core.state.value.received), sha256(input))
    core.finish(.status(0))
    let exit = await exited(opened)
    XCTAssertEqual(exit, .status(0))
    XCTAssertEqual(opened.events.stderrBytes, Data(supply.stderr))
    XCTAssertEqual(supply.stderr.isEmpty, false)
    guard case .opened? = opened.events.calls.value.first, case .exited? = opened.events.calls.value.last else {
      return XCTFail("opened first, exited last: \(opened.events.calls.value.count) calls")
    }
  }

  func testShellMegabytesEachWay() async throws {
    let size = 8 << 20
    let output = Self.random(size), input = Self.random(size)
    let supply = Supply(output, chunk: { 1 + ($0 * 104_729) % 32_768 }, stderrEvery: 0)
    let core = ScriptedChannel(supply: supply.next)
    let (opened, _) = try await openShell(core)
    defer { Darwin.close(opened.fd) }
    async let wrote = CallerSide.write(opened.fd, input)
    let read = await CallerSide.readAll(opened.fd, limit: size)
    let finished = await wrote
    XCTAssertTrue(finished)
    XCTAssertEqual(read.error, 0)
    XCTAssertEqual(sha256(read.bytes), sha256(output))
    try await endOfFileFollows(opened, core)
    await wait(core.state, "the input") { $0.received.count == size }
    XCTAssertEqual(sha256(core.state.value.received), sha256(input))
    XCTAssertFalse(core.state.value.closed, "the shell's output ended, its input did not")
    core.finish(.status(0))
    let exit = await exited(opened)
    XCTAssertEqual(exit, .status(0))
    XCTAssertTrue(opened.events.stderrBytes.isEmpty)
  }

  // MARK: Backpressure

  /// A caller that stops reading: the adapter stops taking output from the channel once the socket is full (it waits
  /// for room, parked on the socket), so what it took is bounded by the socket's buffers while the channel offers
  /// 12 MiB; once the caller reads again everything arrives intact.
  func testAStalledReaderStopsTheAdapterConsuming() async throws {
    let size = 12 << 20
    let supply = PatternSupply(total: size)
    let core = ScriptedChannel(supply: supply.next)
    let opened = try await openExec(core)
    defer { Darwin.close(opened.fd) }
    await wait(opened.parked, "the output parked on a full socket") { $0.contains(.writable) }
    let taken = core.state.value.readBytes
    report("swift engine adapter: \(taken) bytes taken from the channel while the caller read nothing")
    XCTAssertLessThanOrEqual(taken, Self.socketBound)
    XCTAssertGreaterThan(taken, 0)
    // Parked on the socket, the output side takes nothing more until the caller reads.
    await Task.yield()
    XCTAssertEqual(core.state.value.readBytes, taken)
    let read = await CallerSide.readAll(opened.fd, limit: size)
    XCTAssertEqual(read.error, 0)
    XCTAssertEqual(read.bytes.count, size)
    XCTAssertTrue(PatternSupply.check(read.bytes, from: 0))
    try await endOfFileFollows(opened, core)
    core.finish(.status(0))
    let exit = await exited(opened)
    XCTAssertEqual(exit, .status(0))
  }

  /// A channel whose window is shut (its writes stall): the adapter stops reading the socket while its write is pending,
  /// so the caller's writes stop once the socket's buffers are full (a blocking caller blocks), never buffered without
  /// bound; once the window opens every byte arrives in order.
  func testAStalledChannelBlocksTheWriter() async throws {
    let core = ScriptedChannel()
    core.state.change { $0.stallWrites = true }
    let opened = try await openExec(core)
    defer { Darwin.close(opened.fd) }
    XCTAssertTrue(CallerSide.isBlocking(opened.fd), "the caller's end is blocking")
    // Non-blocking for this probe only, to see where a blocking write would block.
    let input = Self.random(12 << 20)
    var offset = 0
    let flags = fcntl(opened.fd, F_GETFL)
    XCTAssertEqual(fcntl(opened.fd, F_SETFL, flags | O_NONBLOCK), 0)
    func fill() {
      while offset < input.count {
        let written = input.withUnsafeBytes { Darwin.write(opened.fd, $0.baseAddress! + offset, min(64 * 1024, $0.count - offset)) }
        guard written > 0 else {
          XCTAssertEqual(errno, EAGAIN)
          return
        }
        offset += written
      }
    }
    fill()
    await wait(core.state, "the adapter's write pending on the stalled channel") { $0.pendingWrites == 1 }
    fill()
    let accepted = offset
    fill()
    XCTAssertEqual(offset, accepted, "the adapter read on while its write was stalled")
    report("swift engine adapter: the caller's writes stopped after \(accepted) bytes into a stalled channel")
    XCTAssertLessThanOrEqual(accepted, Self.socketBound)
    XCTAssertLessThan(accepted, input.count)
    XCTAssertEqual(core.state.value.writes, 0)
    XCTAssertEqual(fcntl(opened.fd, F_SETFL, flags), 0)
    // The rest from a blocking writer, which goes on once the window opens.
    async let wrote = Self.writeThenFinish(opened.fd, Array(input[accepted...]))
    core.releaseWrites()
    let finished = await wrote
    XCTAssertTrue(finished)
    await wait(core.state, "all the input") { $0.inputFinished }
    XCTAssertEqual(sha256(core.state.value.received), sha256(input))
    core.finish(.status(0))
    _ = await exited(opened)
  }

  // MARK: Exec: the ends in every order

  func testExecCallerFinishesInputFirst() async throws {
    let core = ScriptedChannel()
    let opened = try await openExec(core)
    defer { Darwin.close(opened.fd) }
    let wrote = await CallerSide.write(opened.fd, Array("input".utf8))
    XCTAssertTrue(wrote)
    XCTAssertEqual(shutdown(opened.fd, SHUT_WR), 0)
    await wait(core.state, "EOF after the input") { $0.inputFinished }
    XCTAssertEqual(core.state.value.received, Array("input".utf8))
    XCTAssertFalse(core.state.value.closed, "EOF leaves the channel open for output")
    core.send(.stdout(Array("output".utf8)))
    core.finish(.status(0))
    let read = await CallerSide.readAll(opened.fd)
    XCTAssertEqual(read.bytes, Array("output".utf8))
    let exit = await exited(opened)
    XCTAssertEqual(exit, .status(0))
  }

  func testExecRemoteEOFFirstLeavesInputOpen() async throws {
    let core = ScriptedChannel()
    let opened = try await openExec(core)
    defer { Darwin.close(opened.fd) }
    core.send(.stdout(Array("early".utf8)))
    core.sendEOF()
    let read = await CallerSide.readAll(opened.fd, limit: 5)
    XCTAssertEqual(read.bytes, Array("early".utf8))
    try await endOfFileFollows(opened, core)
    let wrote = await CallerSide.write(opened.fd, Array("late".utf8))
    XCTAssertTrue(wrote, "the caller still writes after the remote's EOF")
    XCTAssertEqual(shutdown(opened.fd, SHUT_WR), 0)
    await wait(core.state, "the late input and its EOF") { $0.inputFinished && $0.received == Array("late".utf8) }
    XCTAssertNil(opened.events.exit, "the channel has not closed")
    core.finish(.status(5))
    let exit = await exited(opened)
    XCTAssertEqual(exit, .status(5))
  }

  /// A caller that closes its socket entirely: EOF goes at once; the channel closes when the command next writes, and
  /// `exited` reports what came before (here a status, else `.lost`).
  func testExecCallerClosesEntirely() async throws {
    for status in [nil, ChannelExit.status(9)] {
      let core = ScriptedChannel()
      let opened = try await openExec(core)
      Darwin.close(opened.fd)
      await wait(core.state, "EOF") { $0.inputFinished }
      XCTAssertFalse(core.state.value.closed)
      if let status { core.status(status) }
      core.send(.stdout(Array("nobody reads this".utf8)))
      await wait(core.state, "the adapter closing the channel") { $0.closed }
      let exit = await exited(opened)
      XCTAssertEqual(exit, status.map(SwiftEngineBridge.exit) ?? .lost)
    }
  }

  /// The channel closing without the remote's EOF, and the connection's end (reads throw): the caller reads end of
  /// file, its writes then fail, and the exit is `.lost`.
  func testExecChannelOrConnectionEndsFirst() async throws {
    for connection in [false, true] {
      let core = ScriptedChannel()
      let opened = try await openExec(core)
      defer { Darwin.close(opened.fd) }
      core.send(.stdout(Array("before".utf8)))
      if connection { core.endConnection() } else { core.state.change { $0.closed = true } }
      let read = await CallerSide.readAll(opened.fd)
      let exit = await exited(opened)
      XCTAssertEqual(exit, .lost)
      if !connection { XCTAssertEqual(read.bytes, Array("before".utf8)) }
      let wrote = await CallerSide.write(opened.fd, Array("x".utf8))
      XCTAssertFalse(wrote, "writes fail once the engine closed its end")
    }
  }

  /// No data lost at close: output written before the channel ended is read in full after `exited`, even with input the
  /// channel never took still in the socket.
  func testOutputWrittenBeforeTheEndIsReadAfterIt() async throws {
    let output = Self.random(900 * 1024)
    let core = ScriptedChannel()
    core.state.change { $0.stallWrites = true }
    let opened = try await openExec(core)
    defer { Darwin.close(opened.fd) }
    let wrote = await CallerSide.write(opened.fd, Self.random(300 * 1024))
    XCTAssertTrue(wrote)
    core.send(.stdout(output))
    core.finish(.status(0))
    let exit = await exited(opened)
    XCTAssertEqual(exit, .status(0))
    let read = await CallerSide.readAll(opened.fd)
    XCTAssertEqual(read.error, 0)
    XCTAssertEqual(sha256(read.bytes), sha256(output))
  }

  /// A refused exec request: the socket reads end of file and `exited` carries the seam's text, which `SSHExec` throws.
  func testARefusedExec() async throws {
    let core = ScriptedChannel()
    let opened = try await openExec(core)
    defer { Darwin.close(opened.fd) }
    core.finish(.refused)
    let read = await CallerSide.readAll(opened.fd)
    XCTAssertEqual(read.bytes, [])
    let exit = await exited(opened)
    XCTAssertEqual(exit, .refused("the server refused the exec request"))

    let wrapped = ScriptedChannel()
    let (_, session, _) = session(exec: wrapped)
    let exec = try await SSHExec.start("helper", on: session)
    wrapped.finish(.refused)
    do {
      _ = try await exec.exitStatus()
      XCTFail("a refused exec reported a status")
    } catch let error as SSHTransportError {
      XCTAssertEqual(error, .commandFailed(status: -1, stderr: "the server refused the exec request"))
      XCTAssertEqual(error.errorDescription, "The remote command failed (-1): the server refused the exec request")
    }
    XCTAssertEqual(exec.refusal, .commandFailed(status: -1, stderr: "the server refused the exec request"))
    await exec.close()
    withExtendedLifetime(session) {}
  }

  // MARK: Shell: the ends

  /// The caller's end of input closes the shell's channel (after what it wrote), leaving the session; the exit is a
  /// status only if one arrived first.
  func testShellCallerEndsInput() async throws {
    for (whole, status) in [(false, nil), (true, nil), (false, ChannelExit.status(2))] {
      let core = ScriptedChannel()
      let (opened, _) = try await openShell(core)
      if let status { core.status(status) }
      let wrote = await CallerSide.write(opened.fd, Array("typed".utf8))
      XCTAssertTrue(wrote)
      if whole { Darwin.close(opened.fd) } else { XCTAssertEqual(shutdown(opened.fd, SHUT_WR), 0) }
      await wait(core.state, "the channel closed") { $0.closed }
      XCTAssertEqual(core.state.value.received, Array("typed".utf8), "input before the close")
      XCTAssertFalse(core.state.value.inputFinished, "a PTY gets no EOF")
      let exit = await exited(opened)
      XCTAssertEqual(exit, status.map(SwiftEngineBridge.exit) ?? .lost)
      if !whole { Darwin.close(opened.fd) }
    }
  }

  func testShellServerEndsAndConnectionEnds() async throws {
    let core = ScriptedChannel()
    let (opened, _) = try await openShell(core)
    defer { Darwin.close(opened.fd) }
    core.send(.stdout(Array("bye\r\n".utf8)))
    core.finish(.status(3))
    let read = await CallerSide.readAll(opened.fd)
    XCTAssertEqual(read.bytes, Array("bye\r\n".utf8))
    let exit = await exited(opened)
    XCTAssertEqual(exit, .status(3))

    let lost = ScriptedChannel()
    let (second, _) = try await openShell(lost)
    defer { Darwin.close(second.fd) }
    lost.endConnection()
    _ = await CallerSide.readAll(second.fd)
    let lostExit = await exited(second)
    XCTAssertEqual(lostExit, .lost)
  }

  /// Through the wrappers: `SSHShell` reads output, writes input and ends with the exit status.
  func testShellThroughTheWrapper() async throws {
    let core = ScriptedChannel()
    let (_, session, _) = session(shell: core)
    let shell = try await SSHShell.start(term: "xterm-256color", columns: 80, rows: 24, on: session)
    try await shell.write(Data("exit 3\r".utf8))
    await wait(core.state, "the typed line") { $0.received == Array("exit 3\r".utf8) }
    core.send(.stdout(Array("logout\r\n".utf8)))
    core.finish(.status(3))
    var output = Data()
    for try await chunk in shell { output.append(chunk) }
    XCTAssertEqual(output, Data("logout\r\n".utf8))
    let status = try await shell.exitStatus()
    XCTAssertEqual(status, 3)
    await shell.close()
    withExtendedLifetime(session) {}
  }

  // MARK: Exits and stderr

  func testEveryExitVariant() async throws {
    let cases: [(ChannelExit, EngineExit, EngineExit)] = [
      (.status(0), .status(0), .status(0)),
      (.status(UInt32.max), .status(UInt32.max), .status(UInt32.max)),
      (.signal(name: "TERM", coreDumped: true, message: "terminated"), .signal("TERM"), .signal("TERM")),
      (.lost, .lost, .lost),
      // A shell's refusal cannot come after its confirmations: reported lost.
      (.refused, .refused("the server refused the exec request"), .lost),
    ]
    for (exit, exec, shell) in cases {
      let core = ScriptedChannel()
      let opened = try await openExec(core)
      core.finish(exit)
      let reported = await exited(opened)
      XCTAssertEqual(reported, exec, "\(exit)")
      Darwin.close(opened.fd)

      let shellCore = ScriptedChannel()
      let (shellOpened, _) = try await openShell(shellCore)
      shellCore.finish(exit)
      let shellReported = await exited(shellOpened)
      XCTAssertEqual(shellReported, shell, "\(exit)")
      Darwin.close(shellOpened.fd)
    }
    // As `SSHExec` reports them.
    for (exit, status) in [(ChannelExit.status(UInt32.max), Int32(-1)), (.signal(name: "KILL", coreDumped: false, message: ""), 128)] {
      let core = ScriptedChannel()
      let (_, session, _) = session(exec: core)
      let exec = try await SSHExec.start("true", on: session)
      core.finish(exit)
      let reported = try await exec.exitStatus()
      XCTAssertEqual(reported, status)
      await exec.close()
      withExtendedLifetime(session) {}
    }
  }

  /// stderr arrives as it comes, not paced by a caller that reads no stdout, every chunk before `exited`; and through
  /// `SSHExec` it is iterated apart from stdout.
  func testStderrAsItComes() async throws {
    let core = ScriptedChannel()
    let opened = try await openExec(core)
    defer { Darwin.close(opened.fd) }
    var expected = Data()
    for index in 0..<64 {
      let chunk = Self.random(16 * 1024 + index)
      expected.append(contentsOf: chunk)
      core.send(.stderr(chunk))
    }
    await wait(opened.events.calls, "all of stderr while nobody reads") { [expected] in RecordedChannel.stderr(in: $0).count == expected.count }
    XCTAssertEqual(opened.events.stderrBytes, expected)
    core.finish(.status(1))
    let exit = await exited(opened)
    XCTAssertEqual(exit, .status(1))

    let wrapped = ScriptedChannel()
    let (_, session, _) = session(exec: wrapped)
    let exec = try await SSHExec.start("printf out; printf err >&2; exit 7", on: session)
    wrapped.send(.stdout(Array("out".utf8)))
    wrapped.send(.stderr(Array("err".utf8)))
    wrapped.finish(.status(7))
    var stdout = Data(), stderr = Data()
    for try await chunk in exec {
      switch chunk {
      case .stdout(let data): stdout.append(data)
      case .stderr(let data): stderr.append(data)
      }
    }
    XCTAssertEqual(stdout, Data("out".utf8))
    XCTAssertEqual(stderr, Data("err".utf8))
    let status = try await exec.exitStatus()
    XCTAssertEqual(status, 7)
    await exec.close()
    withExtendedLifetime(session) {}
  }

  // MARK: Opening

  func testFailedOpensAreTheLastCall() async throws {
    let execCases: [(SSHError, SSHTransportError)] = [
      (.channelOpenFailed(.administrativelyProhibited, description: "no sessions"),
       .protocolError(SSHError.channelOpenFailed(.administrativelyProhibited, description: "no sessions").description)),
      (.closed(.alreadyEnded), .channelClosed),
      (.protocolViolation(.channel(.maximumPacketTooSmall)), .protocolError("channel: maximumPacketTooSmall")),
    ]
    for (thrown, expected) in execCases {
      let fake = ScriptedSession()
      fake.exec = { _, _ throws(SSHError) in throw thrown }
      let events = RecordedChannel()
      // Held to the end: releasing it closes the connection, which would race the open (the next test forces both orders).
      let session = SwiftEngineSession(fake, parked: nil)
      session.exec("true", events: events)
      await wait(events.calls, "opened") { !$0.isEmpty }
      XCTAssertEqual(events.calls.value, [.opened(.failure(expected))])
      XCTAssertNil(fake.state.value.ending, "the connection ended during the open")
      withExtendedLifetime(session) {}
    }
    let shellCases: [(SSHError, SSHTransportError)] = [
      (.requestRefused(.ptyRequest), .commandFailed(status: -1, stderr: "the server refused the terminal (pty-req)")),
      (.requestRefused(.shell), .commandFailed(status: -1, stderr: "the server refused the shell request")),
      (.closed(.channelClosed), .channelClosed),
    ]
    for (thrown, expected) in shellCases {
      let fake = ScriptedSession()
      fake.shell = { _, _, _ throws(SSHError) in throw thrown }
      let events = RecordedChannel()
      let session = SwiftEngineSession(fake, parked: nil)
      let control = session.shell(term: "vt100", columns: 80, rows: 24, events: events)
      await wait(events.calls, "opened") { !$0.isEmpty }
      XCTAssertEqual(events.calls.value, [.opened(.failure(expected))])
      XCTAssertNil(fake.state.value.ending, "the connection ended during the open")
      control.resize(columns: 100, rows: 30)  // dropped after a failed open
      withExtendedLifetime(session) {}
    }
    // Through the wrapper: a refused terminal throws what a refused exec does.
    let fake = ScriptedSession()
    fake.shell = { _, _, _ throws(SSHError) in throw .requestRefused(.ptyRequest) }
    let session = SwiftEngineSession(fake, parked: nil)
    do {
      _ = try await SSHShell.start(term: "xterm", columns: 80, rows: 24, on: session)
      XCTFail("a refused terminal opened")
    } catch SSHTransportError.commandFailed(let status, _) {
      XCTAssertEqual(status, -1)
    }
    withExtendedLifetime(session) {}
  }

  /// A failed open reports its own error once, whatever the connection's end does around it, in both orders forced:
  /// the open reached the facade, then the session was released (closing the connection) and the connection ended, and
  /// only then the open failed: its own error, not `channelClosed`. The connection ended before the open reached the
  /// facade: `channelClosed`, and the open never ran.
  func testAnOpenReportsItsOwnErrorWhateverTheEnd() async throws {
    let refusal = SSHError.channelOpenFailed(.resourceShortage, description: "busy")
    for shell in [false, true] {
      let fake = ScriptedSession()
      let entered = Watched(false), gate = Watched(false)
      let open: @Sendable () async throws(SSHError) -> Never = {
        entered.change { $0 = true }
        _ = await gate.until(.seconds(20)) { $0 }
        throw refusal
      }
      fake.exec = { _, _ throws(SSHError) in try await open() }
      fake.shell = { _, _, _ throws(SSHError) in try await open() }
      let events = RecordedChannel()
      var session: SwiftEngineSession? = SwiftEngineSession(fake, parked: nil)
      if shell {
        _ = session?.shell(term: "vt100", columns: 80, rows: 24, events: events)
      } else {
        session?.exec("true", events: events)
      }
      await wait(entered, "the open in the facade") { $0 }
      session = nil
      await wait(fake.state, "the release closing the connection") { $0.ending != nil }
      XCTAssertEqual(fake.state.value.closes, 1)
      XCTAssertTrue(events.calls.value.isEmpty, "opened before the open failed")
      gate.change { $0 = true }
      await wait(events.calls, "opened") { !$0.isEmpty }
      XCTAssertEqual(events.calls.value, [.opened(.failure(refusal.transportError))], "shell: \(shell)")
      XCTAssertEqual(events.late.value, 0)

      let ended = ScriptedSession()
      let ran = Watched(false)
      ended.exec = { _, _ throws(SSHError) in
        ran.change { $0 = true }
        throw refusal
      }
      ended.shell = { _, _, _ throws(SSHError) in
        ran.change { $0 = true }
        throw refusal
      }
      let second = SwiftEngineSession(ended, parked: nil)
      ended.end(.closed(.connectionLost))
      let lost = RecordedChannel()
      if shell {
        _ = second.shell(term: "vt100", columns: 80, rows: 24, events: lost)
      } else {
        second.exec("true", events: lost)
      }
      await wait(lost.calls, "opened") { !$0.isEmpty }
      XCTAssertEqual(lost.calls.value, [.opened(.failure(.channelClosed))], "shell: \(shell)")
      XCTAssertFalse(ran.value, "an open after the end reached the facade's script")
      withExtendedLifetime(second) {}
    }
  }

  /// The shell opens with the asked TERM and size (at least one cell each); changes asked before it opened go once
  /// open (the latest only), equal sizes are skipped, and changes after the end are dropped.
  func testShellResizes() async throws {
    let core = ScriptedChannel()
    let gate = Watched(false)
    let opening = Watched<[String]>([])
    let fake = ScriptedSession()
    fake.shell = { _, term, size in
      opening.change { $0.append("\(term) \(size.columns)x\(size.rows)") }
      _ = await gate.until(.seconds(20)) { $0 }
      return ScriptedShell(core)
    }
    let events = RecordedChannel()
    let resized = SwiftEngineSession(fake, parked: nil)
    let control = resized.shell(term: "xterm-256color", columns: 0, rows: 24, events: events)
    control.resize(columns: 100, rows: 30)
    control.resize(columns: 120, rows: 40)
    gate.change { $0 = true }
    await wait(events.calls, "opened") { !$0.isEmpty }
    XCTAssertEqual(opening.value, ["xterm-256color 1x24"])
    XCTAssertEqual(core.state.value.resizes, [TerminalSize(columns: 120, rows: 40)])
    control.resize(columns: 120, rows: 40)
    control.resize(columns: 90, rows: 20)
    XCTAssertEqual(core.state.value.resizes, [TerminalSize(columns: 120, rows: 40), TerminalSize(columns: 90, rows: 20)])
    core.finish(.status(0))
    await wait(events.calls, "exited") { $0.count == 2 }
    control.resize(columns: 10, rows: 10)
    XCTAssertEqual(core.state.value.resizes.count, 2)
    if let fd = events.descriptor { Darwin.close(fd) }

    // A change back to the opening size before the shell opened sends nothing.
    let quiet = ScriptedChannel()
    let (_, session, _) = session(shell: quiet)
    let quietEvents = RecordedChannel()
    let quietControl = session.shell(term: "vt100", columns: 80, rows: 24, events: quietEvents)
    quietControl.resize(columns: 80, rows: 24)
    await wait(quietEvents.calls, "opened") { !$0.isEmpty }
    XCTAssertEqual(quiet.state.value.resizes, [])
    quiet.finish(.lost)
    await wait(quietEvents.calls, "exited") { $0.count == 2 }
    if let fd = quietEvents.descriptor { Darwin.close(fd) }
    withExtendedLifetime((resized, session)) {}
  }

  // MARK: Many at once, and nothing left behind

  /// 64 channels at once, each stalled on a caller that does not read: no thread waits per channel (the thread count
  /// stays far below one per channel), every byte then arrives on each, and afterwards no descriptor is left open.
  func testManyChannelsParkNoThreadAndLeakNoDescriptor() async throws {
    // Warm up (dispatch's kqueue, the cooperative pool), then count.
    let warm = ScriptedChannel()
    let first = try await openExec(warm)
    warm.finish(.status(0))
    _ = await exited(first)
    Darwin.close(first.fd)
    let descriptors = ProcessCounts.descriptors, threads = ProcessCounts.threads

    let count = 64, size = 3 << 20
    let (fake, session, parked) = session()
    var cores: [ScriptedChannel] = []
    var opened: [RecordedChannel] = []
    let made = (0..<count).map { _ in ScriptedChannel(supply: PatternSupply(total: size).next) }
    // Opens run at once, in no order: the command names the channel.
    fake.exec = { _, command in ScriptedExec(made[Int(command.split(separator: " ")[1])!]) }
    for index in 0..<count {
      let events = RecordedChannel()
      session.exec("channel \(index)", events: events)
      cores.append(made[index])
      opened.append(events)
    }
    for events in opened { await wait(events.calls, "opened") { !$0.isEmpty } }
    await wait(parked, "every output parked on its full socket") { $0.filter { $0 == .writable }.count >= count }
    let during = ProcessCounts.threads
    report("swift engine adapter: \(count) stalled channels: threads \(threads) before, \(during) while stalled")
    // The cooperative pool may widen to the processor count; a thread per channel (or per direction) would be 64 or 128.
    XCTAssertLessThan(during - threads, ProcessInfo.processInfo.activeProcessorCount + 8, "threads grew with the channels")
    XCTAssertEqual(ProcessCounts.descriptors, descriptors + 2 * count, "both ends of each socketpair, nothing else")

    let fds = opened.compactMap(\.descriptor)
    XCTAssertEqual(fds.count, count)
    // A watchdog instead of a hang: what each unfinished channel's pumps had reached, then every channel ended (the
    // engine closing its end wakes any reader).
    let read = Watched<Set<Int>>([])
    let watchdog = Task { [cores] in
      guard await !read.until(.seconds(120), { $0.count == count }) else { return }
      let stuck = (0..<count).filter { !read.value.contains($0) }.map { index -> String in
        let state = cores[index].state.value
        return "channel \(index) (fd \(fds[index])): \(state.readBytes) bytes out, end read \(state.endsRead)x, "
          + "exit asked \(state.exitAsked), at end of file \(CallerSide.atEndOfFile(fds[index]))"
      }
      XCTFail("callers not done after 120 s: \(stuck.joined(separator: "; "))")
      for core in cores { core.finish(.lost) }
    }
    await withTaskGroup(of: Bool.self) { group in
      for (index, fd) in fds.enumerated() {
        group.addTask {
          let bytes = await CallerSide.readAll(fd, limit: size).bytes
          read.change { _ = $0.insert(index) }
          return bytes.count == size && PatternSupply.check(bytes, from: 0)
        }
      }
      for await intact in group { XCTAssertTrue(intact) }
    }
    watchdog.cancel()
    for (index, core) in cores.enumerated() {
      await wait(core.state, "channel \(index)'s adapter past its shutdown") { $0.exitAsked }
      XCTAssertTrue(CallerSide.atEndOfFile(fds[index]), "channel \(index): end of file after all the data")
    }
    for (index, core) in cores.enumerated() { core.finish(.status(UInt32(index))) }
    for (index, events) in opened.enumerated() {
      await wait(events.calls, "exited") { calls in calls.contains { if case .exited = $0 { true } else { false } } }
      XCTAssertEqual(events.exit, .status(UInt32(index)))
    }
    fds.forEach { Darwin.close($0) }
    XCTAssertEqual(ProcessCounts.descriptors, descriptors, "descriptors left open")
    withExtendedLifetime(session) {}
  }

  // MARK: Helpers

  /// The remote's EOF reaches the caller after all the data: once the adapter took the end of output from the channel
  /// and shut its end down (it then waits for the exit), the caller reads end of file. Checked by a read that cannot
  /// block, not by a reader left blocked across the shutdown (`CallerSide.readAll`).
  private func endOfFileFollows(_ opened: Opened, _ core: ScriptedChannel, file: StaticString = #filePath, line: UInt = #line) async throws {
    await wait(core.state, "the adapter past its shutdown", file: file, line: line) { $0.exitAsked }
    XCTAssertTrue(CallerSide.atEndOfFile(opened.fd), "end of file after all the data", file: file, line: line)
  }

  static func random(_ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    arc4random_buf(&bytes, count)
    return bytes
  }

  /// Writes `data` in pieces of varying size, then shuts the socket down for writing.
  static func writeThenFinish(_ fd: Int32, _ data: [UInt8]) async -> Bool {
    var offset = 0, piece = 1
    while offset < data.count {
      let end = min(data.count, offset + piece)
      guard await CallerSide.write(fd, Array(data[offset..<end])) else { return false }
      offset = end
      piece = piece * 3 % 400_000 + 1
    }
    return shutdown(fd, SHUT_WR) == 0
  }
}

/// Hands out `bytes` as stdout in chunks of `chunk(index)` bytes, with a stderr chunk after every `stderrEvery`.
final class Supply: @unchecked Sendable {
  private let lock = NSLock()
  private let bytes: [UInt8]
  private let chunk: (Int) -> Int
  private let stderrEvery: Int
  private var offset = 0, index = 0
  private(set) var stderr: [UInt8] = []

  init(_ bytes: [UInt8], chunk: @escaping (Int) -> Int, stderrEvery: Int) {
    self.bytes = bytes
    self.chunk = chunk
    self.stderrEvery = stderrEvery
  }

  var next: @Sendable () -> ChannelOutput? {
    { [self] in
      lock.withLock {
        index += 1
        if stderrEvery > 0, index % stderrEvery == 0 {
          let text = Array("stderr \(index)\n".utf8)
          stderr += text
          return .stderr(text)
        }
        guard offset < bytes.count else { return nil }
        let end = min(bytes.count, offset + chunk(index))
        defer { offset = end }
        return .stdout(Array(bytes[offset..<end]))
      }
    }
  }
}

/// `total` bytes of a pattern a reader checks by offset, in 32 KiB chunks.
final class PatternSupply: @unchecked Sendable {
  private let lock = NSLock()
  private let total: Int
  private var offset = 0

  init(total: Int) { self.total = total }

  static func byte(_ offset: Int) -> UInt8 { UInt8(truncatingIfNeeded: (offset &* 2_654_435_761) >> 11) }

  /// A plain loop over the buffer: the generic per-element path costs a heap allocation per byte in an unoptimised
  /// build, which under the address sanitizer made 64 x 3 MiB of checking take from seconds to over an hour.
  static func check(_ bytes: [UInt8], from start: Int) -> Bool {
    bytes.withUnsafeBufferPointer { buffer in
      var index = 0
      while index < buffer.count {
        if buffer[index] != byte(start + index) { return false }
        index += 1
      }
      return true
    }
  }

  static func bytes(_ range: Range<Int>) -> [UInt8] {
    [UInt8](unsafeUninitializedCapacity: range.count) { buffer, count in
      var index = 0
      while index < range.count {
        buffer[index] = byte(range.lowerBound + index)
        index += 1
      }
      count = range.count
    }
  }

  var next: @Sendable () -> ChannelOutput? {
    { [self] in
      lock.withLock {
        guard offset < total else { return nil }
        let end = min(total, offset + 32 * 1024)
        defer { offset = end }
        return .stdout(Self.bytes(offset..<end))
      }
    }
  }
}
