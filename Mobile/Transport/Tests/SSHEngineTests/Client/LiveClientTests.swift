#if os(macOS)
import CryptoKit
import Foundation
import XCTest
@testable import SSHEngine

/// The whole engine against the real OpenSSH server on this Mac, through `SSHClient.connector()` (Network.framework
/// stream, production verifier, system randomness): every user key kind, asked and direct; exec with every stream and
/// exit kind; megabytes both ways with a slow reader and a slow server; many channels; a PTY shell with resize;
/// re-exchanges under load from both sides; keepalives; close orderings. One sshd per class (its own root, keys and
/// port; stopped in `tearDown`), real commands under a private HOME.
final class LiveClientTests: XCTestCase {
  nonisolated(unsafe) static var sshd: LiveSSHD?
  nonisolated(unsafe) static var startFailure: String?
  nonisolated(unsafe) static var keys: [(String, any UserKey)] = []

  static let user = NSUserName()

  override class func setUp() {
    super.setUp()
    do {
      var keys: [(String, any UserKey)] = []
      var lines: [String] = []
      for (type, bits) in [("ed25519", nil), ("ecdsa", 256), ("ecdsa", 384), ("ecdsa", 521), ("rsa", 3072)] as [(String, Int?)] {
        let made = try TestKeyFiles.make(type: type, bits: bits)
        keys.append(("file \(type)\(bits.map { "-\($0)" } ?? "")", made.key))
        lines.append(made.publicLine)
      }
      let ed = try cryptoKitEd25519()
      let p256 = try cryptoKitP256()
      keys.append(("CryptoKit ed25519", ed))
      keys.append(("CryptoKit p256", p256))
      lines += [ed.line, p256.line]
      self.keys = keys
      sshd = try LiveSSHD(.init(authorizedKeys: lines, logLevel: "VERBOSE", commands: .shell, maxSessions: 64))
    } catch {
      startFailure = "\(error)"
    }
  }

  override class func tearDown() {
    sshd?.stop()
    sshd = nil
    super.tearDown()
  }

  func server() throws -> LiveSSHD {
    guard let sshd = Self.sshd else { throw XCTSkip("sshd could not be started: \(Self.startFailure ?? "unknown")") }
    return sshd
  }

  func options(_ sshd: LiveSSHD, handshake: Duration = .seconds(10), keepalive: Duration? = .seconds(15),
               count: Int = 3) -> ConnectOptions {
    ConnectOptions(host: "127.0.0.1", port: UInt16(sshd.port), handshakeTimeout: handshake, keepaliveInterval: keepalive,
                   keepaliveCountMax: count)
  }

  /// Connected and logged in with the first key, asked first.
  func session(_ connector: any SSHConnector = SSHClient.connector(), options: ConnectOptions? = nil) async throws
    -> any SSHSession
  {
    let sshd = try server()
    let session = try await connector.connect(options ?? self.options(sshd)) { _ in true }
    let outcome = try await session.authenticate(user: Self.user, with: .publicKey(Self.keys[0].1, direct: false))
    XCTAssertEqual(outcome, .success)
    return session
  }

  func run(_ session: any SSHSession, _ command: String, input: [UInt8]? = nil) async throws -> (Collected, ChannelExit) {
    let exec = try await session.exec(command)
    if let input {
      try await exec.write(input)
      await exec.finishInput()
    }
    let output = try await Collected.all(exec)
    return (output, await exec.exit())
  }

  // MARK: Logins

  /// Every key kind, asked first and direct: each logs in, and sshd's VERBOSE log shows a query ("Postponed
  /// publickey") for the asked login only, so the direct one went without it.
  func testEveryKeyAskedAndDirect() async throws {
    let sshd = try server()
    let connector = SSHClient.connector()
    for (name, key) in Self.keys {
      for direct in [false, true] {
        let (postponed, accepted) = (sshd.count("Postponed publickey"), sshd.count("Accepted publickey"))
        let session = try await connector.connect(options(sshd)) { _ in true }
        XCTAssertEqual(session.hostKey.blob, sshd.hostKeyBlobs[session.hostKey.keyType], name)
        let outcome = try await session.authenticate(user: Self.user, with: .publicKey(key, direct: direct))
        XCTAssertEqual(outcome, .success, "\(name) direct \(direct)")
        let (output, exit) = try await run(session, "id -un")
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), Self.user + "\n", name)
        XCTAssertEqual(exit, .status(0), name)
        await session.close()
        let logged = await sshd.waitForLog("Accepted publickey", count: accepted + 1)
        XCTAssertTrue(logged, "\(name): sshd logged the login")
        XCTAssertEqual(sshd.count("Postponed publickey") - postponed, direct ? 0 : 1, "\(name) direct \(direct)")
      }
    }
  }

  /// A key sshd does not take, asked and direct, refused with the methods left; then the right key on the same
  /// connection.
  func testARefusedKeyThenAnAcceptedOne() async throws {
    let sshd = try server()
    let session = try await SSHClient.connector().connect(options(sshd)) { _ in true }
    let stranger = try cryptoKitEd25519()
    for direct in [false, true] {
      let refused = try await session.authenticate(user: Self.user, with: .publicKey(stranger, direct: direct))
      guard case .refused(let remaining, false) = refused else { return XCTFail("\(refused)") }
      XCTAssertTrue(remaining.contains(.publicKey))
    }
    let outcome = try await session.authenticate(user: Self.user, with: .publicKey(Self.keys[1].1, direct: true))
    XCTAssertEqual(outcome, .success)
    let (output, _) = try await run(session, "echo ok")
    XCTAssertEqual(output.stdout, Array("ok\n".utf8))
    await session.close()
  }

  // MARK: Exec

  func testExecStreamsAndExits() async throws {
    let session = try await session()
    let (mixed, status) = try await run(session, "printf out; printf err >&2; printf more; exit 3")
    XCTAssertEqual(mixed.stdout, Array("outmore".utf8))
    XCTAssertEqual(mixed.stderr, Array("err".utf8))
    XCTAssertEqual(status, .status(3))
    let (upper, upperStatus) = try await run(session, "tr a-z A-Z", input: Array("fictional input\n".utf8))
    XCTAssertEqual(upper.stdout, Array("FICTIONAL INPUT\n".utf8))
    XCTAssertEqual(upperStatus, .status(0))
    let (_, signal) = try await run(session, "kill -TERM $$")
    guard case .signal(let name, _, _) = signal else { return XCTFail("\(signal)") }
    XCTAssertEqual(name, "TERM")
    // End of input before any byte.
    let (empty, emptyStatus) = try await run(session, "wc -c", input: [])
    XCTAssertEqual(String(decoding: empty.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "0")
    XCTAssertEqual(emptyStatus, .status(0))
    await session.close()
  }

  /// 16 MiB up: the server hashes what it got.
  func testMegabytesUp() async throws {
    let session = try await session()
    let data = Self.pseudoRandom(16 << 20, seed: 1)
    let (output, exit) = try await run(session, "shasum -a 256", input: data)
    XCTAssertEqual(String(decoding: output.stdout.prefix(64), as: UTF8.self), sha256Hex(data))
    XCTAssertEqual(exit, .status(0))
    await session.close()
  }

  /// 16 MiB down: the server's hash of the file it sends arrives on stderr.
  func testMegabytesDown() async throws {
    let session = try await session()
    let command = "f=$HOME/down.$$; head -c 16777216 /dev/urandom > $f && shasum -a 256 < $f >&2 && cat $f; rm -f $f"
    let (output, exit) = try await run(session, command)
    XCTAssertEqual(output.stdout.count, 16 << 20)
    XCTAssertEqual(String(decoding: output.stderr.prefix(64), as: UTF8.self), sha256Hex(output.stdout))
    XCTAssertEqual(exit, .status(0))
    let stats = await session.driver.stats
    XCTAssertLessThanOrEqual(stats.maximumBufferedOutput, Int(Limits.channelWindow))
    await session.close()
  }

  /// 8 MiB through `cat` both ways, with a reader that pauses between reads: the window the engine grants holds the
  /// server back, so what the engine buffers never exceeds it, and every byte arrives in order.
  func testASlowReaderStopsTheServer() async throws {
    let session = try await session()
    let exec = try await session.exec("cat")
    let data = Self.pseudoRandom(8 << 20, seed: 2)
    let writer = Task {
      try await exec.write(data)
      await exec.finishInput()
    }
    var received: [UInt8] = []
    received.reserveCapacity(data.count)
    var reads = 0
    while let chunk = try await exec.read() {
      received += chunk.bytes
      reads += 1
      if reads % 4 == 0 { try await Task.sleep(for: .milliseconds(5)) }
    }
    try await writer.value
    XCTAssertTrue(received == data, "\(received.count) of \(data.count)")
    let stats = await session.driver.stats
    XCTAssertLessThanOrEqual(stats.maximumBufferedOutput, Int(Limits.channelWindow))
    XCTAssertGreaterThan(stats.maximumBufferedOutput, Int(Limits.channelWindow) / 2,
                         "the reader was slow enough for the window to hold sshd back: \(stats)")
    await session.close()
  }

  /// A server that reads nothing for a while (the command sleeps first): the writer is held by the window and the
  /// backlog, the engine's memory stays bounded, and the hash still matches.
  func testASlowServerStopsTheWriter() async throws {
    let session = try await session()
    let data = Self.pseudoRandom(8 << 20, seed: 3)
    let (output, exit) = try await run(session, "sleep 1; shasum -a 256", input: data)
    XCTAssertEqual(String(decoding: output.stdout.prefix(64), as: UTF8.self), sha256Hex(data))
    XCTAssertEqual(exit, .status(0))
    let stats = await session.driver.stats
    XCTAssertLessThanOrEqual(stats.maximumBacklog, Limits.outboundBacklogBytes + 64 * 1024)
    XCTAssertGreaterThan(stats.writeSuspensions, 0, "the writer was held back: \(stats)")
    await session.close()
  }

  /// The app writes slowly, in small pieces, while reading the echo.
  func testASlowWriter() async throws {
    let session = try await session()
    let exec = try await session.exec("cat")
    let data = Self.pseudoRandom(1 << 20, seed: 4)
    let writer = Task {
      var offset = 0
      while offset < data.count {
        let end = min(data.count, offset + 4096)
        try await exec.write(Array(data[offset..<end]))
        offset = end
        if offset % (64 * 1024) == 0 { try await Task.sleep(for: .milliseconds(2)) }
      }
      await exec.finishInput()
    }
    let output = try await Collected.all(exec)
    try await writer.value
    XCTAssertTrue(output.stdout == data)
    await session.close()
  }

  func testManyConcurrentChannels() async throws {
    let session = try await session()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<40 {
        group.addTask {
          let data = Self.pseudoRandom(128 * 1024 + index * 997, seed: UInt64(100 + index))
          let exec = try await session.exec(index % 2 == 0 ? "cat" : "cat; echo done-\(index) >&2")
          let writer = Task {
            try await exec.write(data)
            await exec.finishInput()
          }
          let output = try await Collected.all(exec)
          try await writer.value
          XCTAssertTrue(output.stdout == data, "channel \(index)")
          if index % 2 == 1 { XCTAssertEqual(output.stderr, Array("done-\(index)\n".utf8)) }
          let exit = await exec.exit()
          XCTAssertEqual(exit, .status(0), "channel \(index)")
        }
      }
      try await group.waitForAll()
    }
    await session.close()
  }

  // MARK: Shell

  func testAPTYShellWithResize() async throws {
    let session = try await session()
    let shell = try await session.shell(term: "vt100", size: .init(columns: 80, rows: 24))
    try await shell.write(Array("stty size\n".utf8))
    try await Self.readUntil(shell, contains: "24 80")
    try shell.resize(.init(columns: 100, rows: 40))
    try shell.resize(.init(columns: 132, rows: 43))
    try await shell.write(Array("stty size\n".utf8))
    try await Self.readUntil(shell, contains: "43 132")
    try await shell.write(Array("exit 5\n".utf8))
    while try await shell.read() != nil {}
    let exit = await shell.exit()
    XCTAssertEqual(exit, .status(5))
    XCTAssertThrows(SSHError.usage(.channelClosed)) { () throws(SSHError) in try shell.resize(.init(columns: 1, rows: 1)) }
    await session.close()
  }

  /// Closing a shell ends it at once; the connection goes on.
  func testClosingAShell() async throws {
    let session = try await session()
    let shell = try await session.shell(term: "vt100", size: .init(columns: 80, rows: 24))
    try await shell.write(Array("echo ready\n".utf8))
    try await Self.readUntil(shell, contains: "ready")
    let reading = Task { while try await shell.read() != nil {} }
    await shell.close()
    try await bounded(5, "the read after the close") { try await reading.value }
    let exit = await shell.exit()
    XCTAssertEqual(exit, .lost)
    let (output, _) = try await run(session, "echo still")
    XCTAssertEqual(output.stdout, Array("still\n".utf8))
    await session.close()
  }

  // MARK: Orderings

  func testCloseAndEndOfInputOrderings() async throws {
    let session = try await session()
    // Closing an exec while it runs: exit is what arrived (nothing), the session goes on.
    let long = try await session.exec("cat")
    try await long.write(Array("x".utf8))
    _ = try await long.read()
    await long.close()
    let longExit = await long.exit()
    XCTAssertEqual(longExit, .lost)
    await assertThrows(.usage(.channelClosed)) { try await long.write([1]) }
    // End of input, then output after it.
    let later = try await session.exec("cat > /dev/null; echo after")
    try await later.write(Array("ignored".utf8))
    await later.finishInput()
    await assertThrows(.usage(.channelClosed)) { try await later.write([1]) }
    let output = try await Collected.all(later)
    XCTAssertEqual(output.stdout, Array("after\n".utf8))
    // The session's close with a channel open: the channel ends, its reads throw the close.
    let open = try await session.exec("cat")
    await session.close()
    let openExit = await open.exit()
    XCTAssertEqual(openExit, .lost)
    await assertThrows(.closed(.byClient)) { try await open.read() }
    await assertThrows(.closed(.byClient)) { try await open.write([1]) }
    let end = await session.ended()
    XCTAssertEqual(end, .closed(.byClient))
    await assertThrows(.closed(.alreadyEnded)) { try await session.exec("true") }
  }

  // MARK: Keepalive

  /// No keepalive before the login (RFC 4252 §6: the timer starts with it); after it sshd answers each
  /// (REQUEST_FAILURE): with a count of 1 the connection outlives many of them.
  func testKeepalivesAreAnswered() async throws {
    let sshd = try server()
    let session = try await SSHClient.connector().connect(options(sshd, keepalive: .milliseconds(150), count: 1)) { _ in true }
    try await Task.sleep(for: .seconds(1))
    let early = await session.driver.stats.keepalivesFired
    XCTAssertEqual(early, 0, "keepalives before the login")
    let outcome = try await session.authenticate(user: Self.user, with: .publicKey(Self.keys[0].1, direct: true))
    XCTAssertEqual(outcome, .success)
    let stats = try await bounded(20, "keepalives after the login") {
      await session.driver.waitForStats { $0.keepalivesFired >= 8 }
    }
    XCTAssertGreaterThanOrEqual(stats.keepalivesFired, 8)
    let end = await session.driver.endReason
    XCTAssertNil(end)
    let (output, _) = try await run(session, "echo alive")
    XCTAssertEqual(output.stdout, Array("alive\n".utf8))
    await session.close()
  }

  /// 32 MiB each way, timed and printed (a measurement: it asserts only that the bytes arrived; debug builds are
  /// several times slower than release).
  func testThroughput() async throws {
    let session = try await session()
    let size = 32 << 20
    let data = Self.pseudoRandom(size, seed: 9)
    var started = ContinuousClock.now
    let (counted, _) = try await run(session, "wc -c", input: data)
    let up = ContinuousClock.now - started
    XCTAssertEqual(String(decoding: counted.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), String(size))
    started = ContinuousClock.now
    let (down, _) = try await run(session, "head -c \(size) /dev/zero")
    let downTime = ContinuousClock.now - started
    XCTAssertEqual(down.stdout.count, size)
    print("LiveClientTests throughput: \(size >> 20) MiB up in \(up), down in \(downTime)")
    await session.close()
  }

  // MARK: Helpers

  static func readUntil(_ shell: any ShellChannel, contains text: String) async throws {
    var seen: [UInt8] = []
    while !String(decoding: seen, as: UTF8.self).contains(text) {
      guard let chunk = try await bounded(10, "shell output containing \(text)", { try await shell.read() }) else {
        throw LiveSSHD.Failure("the shell ended before \(text): \(String(decoding: seen, as: UTF8.self))")
      }
      seen += chunk
    }
  }

  static func pseudoRandom(_ count: Int, seed: UInt64) -> [UInt8] {
    let random = SeededRandom(seed: seed)
    var bytes = [UInt8](repeating: 0, count: count)
    var index = 0
    while index < count {
      var value = random.next()
      for _ in 0..<8 where index < count {
        bytes[index] = UInt8(truncatingIfNeeded: value)
        value >>= 8
        index += 1
      }
    }
    return bytes
  }
}

/// Against sshd too, each needing a daemon or a network of its own: re-exchanges under load (sshd's `RekeyLimit`, and
/// the client's lowered threshold), connect failures by stage, host key decisions, and a connection cut or frozen
/// under a live session (through `LoopbackRelay`).
final class LiveConnectionTests: XCTestCase {
  private func daemon(rekeyLimit: String = "default none") throws -> (LiveSSHD, any UserKey) {
    let key = try cryptoKitEd25519()
    do {
      return (try LiveSSHD(.init(authorizedKeys: [key.line], rekeyLimit: rekeyLimit, commands: .shell)), key)
    } catch {
      throw XCTSkip("sshd could not be started: \(error)")
    }
  }

  private func options(port: Int, handshake: Duration = .seconds(10), keepalive: Duration? = nil, count: Int = 3)
    -> ConnectOptions
  {
    ConnectOptions(host: "127.0.0.1", port: UInt16(port), handshakeTimeout: handshake, keepaliveInterval: keepalive,
                   keepaliveCountMax: count)
  }

  private func login(_ connector: any SSHConnector, port: Int, key: any UserKey, keepalive: Duration? = nil,
                     count: Int = 3) async throws -> any SSHSession {
    let session = try await connector.connect(options(port: port, keepalive: keepalive, count: count)) { _ in true }
    let outcome = try await session.authenticate(user: NSUserName(), with: .publicKey(key, direct: true))
    XCTAssertEqual(outcome, .success)
    return session
  }

  /// 24 MiB through `cat` while re-exchanges run: started by sshd (`RekeyLimit 1M`), then by the client (its byte
  /// threshold lowered to 1 MiB). Every byte arrives, the re-exchanges are counted.
  func testReexchangesUnderLoadFromBothSides() async throws {
    for side in ["server", "client"] {
      let (sshd, key) = try daemon(rekeyLimit: side == "server" ? "1M none" : "default none")
      defer { sshd.stop() }
      var tuning = DriverTuning()
      if side == "client" { tuning.rekeyBytes = 1 << 20 }
      let connector = ClientConnector(streams: NetworkStreamConnector(), tuning: tuning)
      let session = try await login(connector, port: sshd.port, key: key)
      let exec = try await session.exec("cat")
      let data = LiveClientTests.pseudoRandom(24 << 20, seed: 7)
      let writer = Task {
        try await exec.write(data)
        await exec.finishInput()
      }
      let output = try await Collected.all(exec)
      try await writer.value
      XCTAssertTrue(output.stdout == data, side)
      let stats = await session.driver.stats
      XCTAssertGreaterThanOrEqual(stats.rekeys, 10, "\(side): \(stats)")
      await session.close()
    }
  }

  func testConnectFailuresByStage() async throws {
    let connector = SSHClient.connector()
    let refusedPort = try SilentListener.closedPort()
    await assertThrows(.connectionRefused) { try await connector.connect(self.options(port: refusedPort)) { _ in true } }
    let silent = try SilentListener()
    let started = ContinuousClock.now
    await assertThrows(.timedOut(.handshake)) {
      try await connector.connect(self.options(port: silent.port, handshake: .milliseconds(500))) { _ in true }
    }
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    var unresolvable = options(port: 22)
    unresolvable.host = "no-such-host.invalid"
    await assertThrows(.hostNotFound) { try await connector.connect(unresolvable) { _ in true } }
    // A deadline already gone names the stage that was due: the lookup for a name, the connection for an address.
    let streams = NetworkStreamConnector()
    await assertThrows(.timedOut(.lookup)) { try await streams.connect(host: "localhost", port: 22, deadline: .now) }
    await assertThrows(.noAnswer) { try await streams.connect(host: "127.0.0.1", port: 22, deadline: .now) }
    // TEST-NET-1 has no host: depending on the network the SYN is dropped (no answer) or refused by a router.
    var blackHole = options(port: 22, handshake: .seconds(1))
    blackHole.host = "192.0.2.1"
    do {
      _ = try await connector.connect(blackHole) { _ in true }
      XCTFail("connected to TEST-NET-1")
    } catch {
      XCTAssertTrue([.noAnswer, .unreachable].contains(error), "\(error)")
    }
  }

  func testHostKeyDecisions() async throws {
    let (sshd, key) = try daemon()
    defer { sshd.stop() }
    let connector = SSHClient.connector()
    let shown = Locked<[HostKey]>([])
    await assertThrows(.hostKeyRejected) {
      try await connector.connect(self.options(port: sshd.port)) { key in
        shown.update { $0.append(key) }
        return false
      }
    }
    XCTAssertEqual(shown.current.count, 1)
    XCTAssertEqual(shown.current.first?.blob, sshd.hostKeyBlobs[shown.current.first?.keyType ?? ""])
    // A decision three times as long as the handshake timeout: the deadline waits for it.
    let session = try await connector.connect(options(port: sshd.port, handshake: .seconds(1))) { _ in
      try? await Task.sleep(for: .seconds(3))
      return true
    }
    let outcome = try await session.authenticate(user: NSUserName(), with: .publicKey(key, direct: true))
    XCTAssertEqual(outcome, .success)
    await session.close()
  }

  /// The relay resets the connection under a running command: the read throws the loss, the exit is `.lost`, the
  /// session's end is the loss.
  func testAConnectionCutMidSession() async throws {
    let (sshd, key) = try daemon()
    defer { sshd.stop() }
    let relay = try LoopbackRelay(to: sshd.port)
    defer { relay.stop() }
    let session = try await login(SSHClient.connector(), port: relay.port, key: key)
    let exec = try await session.exec("cat")
    try await exec.write(Array("before".utf8))
    let echoed = try await exec.read()
    XCTAssertEqual(echoed, .stdout(Array("before".utf8)))
    let reading = Task { try await exec.read() }
    relay.cut()
    let failure = try await bounded(10, "the read after the cut") { await reading.sshError }
    XCTAssertEqual(failure, .closed(.connectionLost))
    let end = await session.ended()
    XCTAssertEqual(end, .closed(.connectionLost))
    let exit = await exec.exit()
    XCTAssertEqual(exit, .lost)
    await assertThrows(.closed(.alreadyEnded)) { try await session.exec("true") }
  }

  /// The relay stops forwarding: keepalives go unanswered and the connection ends after (count + 1) intervals.
  func testAFrozenNetworkEndsByKeepalive() async throws {
    let (sshd, key) = try daemon()
    defer { sshd.stop() }
    let relay = try LoopbackRelay(to: sshd.port)
    defer { relay.stop() }
    let session = try await login(SSHClient.connector(), port: relay.port, key: key, keepalive: .milliseconds(200), count: 2)
    let exec = try await session.exec("cat")
    let reading = Task { try await exec.read() }
    relay.freeze()
    let started = ContinuousClock.now
    let end = try await bounded(20, "the keepalive timeout") { await session.ended() }
    XCTAssertEqual(end, .timedOut(.keepalive))
    XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(500))
    let failure = await reading.sshError
    XCTAssertEqual(failure, .timedOut(.keepalive))
  }
}
#endif
