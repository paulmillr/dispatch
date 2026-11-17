#if os(macOS)
import Foundation
import MobileTransport
import XCTest
@testable import SSHEngine

/// MobileTransport's public API (`SSHConnection`) against every server in the interop profile (InteropSupport.swift),
/// on every engine of the build in one run (`SSHTransportEngine.preferred`, restored after each test;
/// `SSHENGINE_INTEROP_ENGINES` picks one): the Swift engine, and in a `DISPATCH_RUSSH` build russh too, so a failure on
/// the Swift engine reads against russh's result with the same server. Where the Swift
/// engine's policy refuses a server (no strict key exchange and no AES-GCM), its run checks the refusal and its text
/// instead. Logins (every key kind asked and direct, password, keyboard-interactive, wrong ones, two methods in
/// sequence, the attempt limit, a login that waits), sessions (exec with status, streams, a signal and closed input;
/// 16 MiB each way with checksums; a PTY shell with resize; 20 channels at once; a command that never reads; the
/// server's refusals), keepalives both ways, and the server ending, killing or freezing its side.
final class InteropSessionTests: XCTestCase {
  override class func tearDown() {
    InteropRecord.shared.flush("InteropSessionTests (public API)")
    super.tearDown()
  }

  /// The engines `SSHENGINE_INTEROP_ENGINES` names (default: every one the build has); naming one the build lacks
  /// (`russh` without `DISPATCH_RUSSH=1`) fails the test rather than running nothing.
  static func engines(file: StaticString = #filePath, line: UInt = #line) -> [SSHTransportEngine] {
    guard let names = ProcessInfo.processInfo.environment["SSHENGINE_INTEROP_ENGINES"] else {
      return SSHTransportEngine.allCases
    }
    return names.split(separator: ",").compactMap { name in
      let engine = SSHTransportEngine(rawValue: String(name))
      if engine == nil {
        XCTFail("SSHENGINE_INTEROP_ENGINES names \(name), which this build lacks (russh needs DISPATCH_RUSSH=1)",
                file: file, line: line)
      }
      return engine
    }
  }

  /// Runs `body` on every server with each engine. The Swift engine's runs on a server its policy refuses check that
  /// refusal instead.
  /// `russhLimitation`: a case the russh engine is known to fail; its failure is recorded with that note, not failed.
  /// `serverBug`: a server release's documented bug that the case can trigger (its note), recorded the same way.
  static func each(_ test: String, seconds: Double = 120, russhLimitation: String? = nil,
                   serverBug: @escaping @Sendable (InteropProfile.Server) -> String? = { _ in nil },
                   file: StaticString = #filePath, line: UInt = #line,
                   _ body: @escaping @Sendable (InteropProfile, InteropProfile.Server) async throws -> String) async throws {
    let profile = try InteropProfile.load()
    let saved = SSHTransportEngine.preferred
    defer { SSHTransportEngine.preferred = saved }
    for engine in engines(file: file, line: line) {
      SSHTransportEngine.preferred = engine
      let bug: @Sendable (InteropProfile.Server) -> String? = { server in
        serverBug(server) ?? (engine == .swift ? KnownServerBug.swiftEngine(server) : russhLimitation)
      }
      await forEachServer(profile, test, engine: engine.rawValue, seconds: seconds, serverBug: bug, file: file,
                          line: line) { server in
        if engine == .swift, let refusal = try await policyRefusal(profile, server) { return refusal }
        return try await body(profile, server)
      }
    }
  }

  /// nil when the Swift engine connects to `server`; else the checked refusal.
  static func policyRefusal(_ profile: InteropProfile, _ server: InteropProfile.Server) async throws -> String? {
    let offer = try InteropProbe.offer(port: server.port)
    guard !offer.engineConnects, let mode = offer.mode() else { return nil }
    let named = mode.mac.map { "\(mode.cipher.rawValue) with \($0.rawValue)" } ?? mode.cipher.rawValue
    let expected = SSHTransportError.incompatibleServer(
      "The server's SSH is too old for a safe connection (it offers \(named) without strict key exchange); update the "
        + "SSH server.")
    do {
      let connection = try await connect(profile, server, [.password(profile.password)])
      await connection.close()
      throw InteropFailure("connected to a server without strict key exchange or AES-GCM")
    } catch let error as SSHTransportError {
      try require(error == expected, "refused with \(error), expected \(expected)")
      return "refused by policy: \(error.localizedDescription)"
    }
  }

  /// Trusts the server's own host keys only.
  final class ProfileTrust: MobileTransport.HostKeyTrust {
    let blobs: Set<String>
    init(_ server: InteropProfile.Server) { blobs = server.hostKeyBlobs }
    func evaluate(_ key: HostKeyInfo) async -> HostKeyDecision {
      let blob = key.openSSH.split(separator: " ").dropFirst().first.map(String.init) ?? ""
      return blobs.contains(blob) ? .trust : .reject
    }
  }

  static func connect(_ profile: InteropProfile, _ server: InteropProfile.Server, user: String? = nil,
                      _ credentials: [SSHCredential], keepalive: Duration = .seconds(60), keepaliveMax: Int = 3)
    async throws -> SSHConnection
  {
    try await SSHConnection.connect(
      to: SSHEndpoint(host: "127.0.0.1", port: server.port, username: user ?? profile.user), credentials: credentials,
      trust: ProfileTrust(server), timeout: .seconds(20), keepalive: keepalive, keepaliveMax: keepaliveMax)
  }

  static func key(_ profile: InteropProfile, _ name: String) throws -> SSHKey {
    try SSHKey.openSSH(try profile.keyFile(name))
  }

  /// The pid of the process in the guest that serves `connection` (the parent of a command's shell).
  static func servingPid(_ connection: SSHConnection) async throws -> Int {
    let result = try await connection.run("echo $PPID")
    return try XCTUnwrap(Int(result.text.trimmingCharacters(in: .whitespacesAndNewlines)), result.text)
  }

  /// Fails unless `body` throws `authenticationFailed`; returns the methods the server still allows.
  static func refusedLogin(_ what: String, _ body: () async throws -> SSHConnection) async throws -> [String] {
    do {
      let connection = try await body()
      await connection.close()
      throw InteropFailure("\(what) logged in")
    } catch SSHTransportError.authenticationFailed(let methods) {
      return methods
    } catch let error as InteropFailure {
      throw error
    } catch {
      throw InteropFailure("\(what): \(error), expected authenticationFailed")
    }
  }

  // MARK: Logins

  func testPasswordAndHostKey() async throws {
    try await Self.each("password") { profile, server in
      let connection = try await Self.connect(profile, server, [.password(profile.password)])
      let user = try await connection.run("id -un")
      try require(user.text == profile.user + "\n" && user.status == 0, "id -un: \(user.text)")
      await connection.close()
      return "ok, host key \(connection.hostKey.algorithm)"
    }
  }

  /// Every key, as `.key` (asked first) and `.directKey`: the kinds the server takes log in, the others are refused.
  func testEveryUserKeyAskedAndDirect() async throws {
    try await Self.each("user keys", seconds: 300) { profile, server in
      var refused: [String] = []
      for name in profile.keyNames {
        let key = try Self.key(profile, name)
        for direct in [false, true] {
          let answers = Recorder<DirectKeyAnswer>()
          let credential: SSHCredential = direct ? .directKey(key, answered: { answers.record($0) }) : .key(key)
          if server.acceptsKey(name) {
            let connection = try await Self.connect(profile, server, [credential])
            let user = try await connection.run("id -un")
            try require(user.text == profile.user + "\n", "\(name): \(user.text)")
            try require(!direct || answers.all == [.loggedIn], "\(name) direct: \(answers.all)")
            await connection.close()
          } else {
            let methods = try await Self.refusedLogin(name) { try await Self.connect(profile, server, [credential]) }
            refused.append("\(name)\(direct ? " direct" : ""): \(methods)")
          }
        }
      }
      return refused.isEmpty ? "ok, every key" : "ok; refused " + refused.joined(separator: "; ")
    }
  }

  func testKeyboardInteractive() async throws {
    try await Self.each("keyboard-interactive") { profile, server in
      let prompts = Recorder<String>()
      let password = profile.password
      let credential = SSHCredential.keyboardInteractive { challenge in
        for prompt in challenge.prompts { prompts.record(prompt.text) }
        return challenge.prompts.map { _ in password }
      }
      guard server.keyboardInteractive else {
        let methods = try await Self.refusedLogin("keyboard-interactive") {
          try await Self.connect(profile, server, [credential])
        }
        try require(!methods.contains("keyboard-interactive"), "\(methods)")
        return "refused (no such method on the server): \(methods)"
      }
      let connection = try await Self.connect(profile, server, [credential])
      await connection.close()
      return "ok, prompts \(prompts.all)"
    }
  }

  func testWrongPasswordAndWrongKey() async throws {
    try await Self.each("wrong password, wrong key") { profile, server in
      let password = try await Self.refusedLogin("a wrong password") {
        try await Self.connect(profile, server, [.password("wrong-" + profile.password)])
      }
      try require(password.contains("password") && password.contains("publickey"), "\(password)")
      let stranger = try Self.key(profile, "stranger")
      let key = try await Self.refusedLogin("an unknown key") { try await Self.connect(profile, server, [.key(stranger)]) }
      let direct = try await Self.refusedLogin("an unknown direct key") {
        try await Self.connect(profile, server, [.directKey(stranger, answered: { _ in })])
      }
      try require(key.contains("publickey") && direct == key, "\(key) \(direct)")
      return "authenticationFailed(\(password)), key \(key)"
    }
  }

  func testTwoMethodsInSequence() async throws {
    try await Self.each("two methods") { profile, server in
      guard let user = server.multiFactorUser else { throw XCTSkip("Dropbear has no AuthenticationMethods") }
      let key = try Self.key(profile, "ed25519")
      let password = profile.password
      var connection = try await Self.connect(profile, server, user: user, [.key(key), .password(password)])
      try require(connection.credential == 1, "credential \(connection.credential)")
      await connection.close()
      connection = try await Self.connect(profile, server, user: user, [.directKey(key, answered: { _ in }),
        .keyboardInteractive { challenge in challenge.prompts.map { _ in password } }])
      try require(connection.credential == 1, "credential \(connection.credential)")
      await connection.close()
      let first = try await Self.refusedLogin("a password alone") {
        try await Self.connect(profile, server, user: user, [.password(password)])
      }
      let partial = try await Self.refusedLogin("a key alone") {
        try await Self.connect(profile, server, user: user, [.key(key)])
      }
      return "ok; password alone \(first), key alone \(partial)"
    }
  }

  /// As many wrong passwords as the server's limit (MaxAuthTries 3, dropbear -T 3), then the right one: the server
  /// ends the connection at the limit (OpenSSH with a DISCONNECT, Dropbear by closing), and the login fails as
  /// `authenticationFailed`, final for the app (no reconnect resubmitting it), on both engines.
  func testTheServersLimitOnAttempts() async throws {
    try await Self.each("attempt limit") { profile, server in
      let credentials = (1...server.maxAuthTries).map { SSHCredential.password("wrong-\($0)") } + [.password(profile.password)]
      do {
        let connection = try await Self.connect(profile, server, credentials)
        await connection.close()
        throw InteropFailure("logged in past the limit with credential \(connection.credential)")
      } catch let error as SSHTransportError {
        try require(error == .authenticationFailed(methods: []), "\(error)")
        try require(HostConnectionPolicy.refused(error), "the app retries \(error)")
        return "\(error) (\(error.localizedDescription)); final for the app"
      }
    }
  }

  /// A pre-login banner with a Latin-1 byte (OpenSSH's `Banner` for one account): display text, so the login goes on.
  func testALatin1Banner() async throws {
    try await Self.each("Latin-1 banner", russhLimitation: "russh decodes the banner as strict UTF-8") { profile, server in
      guard let user = server.latin1BannerUser else { throw XCTSkip("Dropbear's banner is per server (UTF-8 here)") }
      let connection = try await Self.connect(profile, server, user: user, [.password(profile.password)])
      let result = try await connection.run("id -un")
      try require(result.text == user + "\n", result.text)
      await connection.close()
      return "ok"
    }
  }

  /// The login waits 3.5 s with keepalives due every second (count 3, as the app's 15 s x 3 scaled down): the signer
  /// (a Face ID prompt), and on OpenSSH also a keyboard-interactive answer (a person typing). The login must survive
  /// the wait and a command run.
  func testKeepalivesWhileTheLoginWaits() async throws {
    try await Self.each("keepalives during the login") { profile, server in
      let file = try profile.fileKey("ed25519")
      let slow = SSHKey(kind: .ed25519, publicKeyBlob: Data(file.publicKeyBlob), hardwareBacked: false) { data in
        try await Task.sleep(for: .milliseconds(3500))
        do {
          return Data(try await file.sign(Array(data), algorithm: .ed25519).suffix(64))
        } catch {
          throw InteropFailure("sign: \(error)")
        }
      }
      let connection = try await Self.connect(profile, server, [.key(slow)], keepalive: .seconds(1), keepaliveMax: 3)
      let alive = try await connection.run("echo alive")
      try require(alive.text == "alive\n", alive.text)
      await connection.close()
      guard server.keyboardInteractive else { return "ok (a held signature)" }
      let password = profile.password
      let typing = try await Self.connect(profile, server, [.keyboardInteractive { challenge in
        try? await Task.sleep(for: .milliseconds(3500))
        return challenge.prompts.map { _ in password }
      }], keepalive: .seconds(1), keepaliveMax: 3)
      let still = try await typing.run("echo alive")
      try require(still.text == "alive\n", still.text)
      await typing.close()
      return "ok (a held signature, a held keyboard-interactive answer)"
    }
  }

  // MARK: Sessions

  func testExecStatusStreamsSignalAndClosedInput() async throws {
    try await Self.each("exec") { profile, server in
      let connection = try await Self.connect(profile, server, [.password(profile.password)])
      let mixed = try await connection.run("printf out; printf err >&2; printf more; exit 3")
      try require(mixed.text == "outmore" && String(decoding: mixed.stderr, as: UTF8.self) == "err" && mixed.status == 3,
                  "\(mixed.text) \(mixed.stderr) \(mixed.status)")
      let signal = try await connection.run("kill -TERM $$")
      try require(signal.status == 128, "a signal: \(signal.status)")
      let empty = try await connection.run("wc -c")
      try require(empty.text.trimmingCharacters(in: .whitespacesAndNewlines) == "0", "wc -c: \(empty.text)")
      let echoed = try await connection.run("tr a-z A-Z", input: Data("fictional input\n".utf8))
      try require(echoed.text == "FICTIONAL INPUT\n" && echoed.status == 0, echoed.text)
      await connection.close()
      return "ok"
    }
  }

  func testSixteenMiBUpAndDown() async throws {
    try await Self.each("16 MiB up and down", seconds: 300) { profile, server in
      let connection = try await Self.connect(profile, server, [.password(profile.password)])
      let data = Data(LiveClientTests.pseudoRandom(16 << 20, seed: 31))
      let started = ContinuousClock.now
      let up = try await connection.run("sha256sum", input: data)
      let upTime = ContinuousClock.now - started
      try require(String(up.text.prefix(64)) == sha256Hex(data), "up: \(up.text)")
      let command = "f=$(mktemp); head -c 16777216 /dev/urandom > $f && sha256sum < $f >&2 && cat $f; rm -f $f"
      let downStarted = ContinuousClock.now
      let down = try await connection.run(command, limit: 17 << 20)
      let downTime = ContinuousClock.now - downStarted
      try require(down.stdout.count == 16 << 20, "down: \(down.stdout.count) bytes")
      try require(String(decoding: down.stderr.prefix(64), as: UTF8.self) == sha256Hex(down.stdout), "down: checksum")
      await connection.close()
      return "ok (up \(upTime.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))), "
        + "down \(downTime.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))))"
    }
  }

  func testPTYShellWithResize() async throws {
    try await Self.each("PTY shell") { profile, server in
      let connection = try await Self.connect(profile, server, [.password(profile.password)])
      let shell = try await connection.shell(term: "xterm-256color", columns: 80, rows: 24)
      let output = OutputReader(shell)
      try await shell.write(Data("stty size; echo $TERM\r".utf8))
      try await output.read(until: "24 80")
      try await output.read(until: "xterm-256color")
      try await shell.resize(columns: 132, rows: 43)
      // The change goes on its own: ask until the shell sees it.
      var seen = false
      for _ in 0..<20 where !seen {
        let mark = output.stdout.count
        try await shell.write(Data("stty size\r".utf8))
        seen = (try? await output.read(until: "43 132", from: mark, timeout: .seconds(1))) != nil
      }
      try require(seen, "the resize never reached the shell")
      try await shell.write(Data("exit 5\r".utf8))
      try await output.readToEnd()
      let status = try await shell.exitStatus()
      try require(status == 5, "exit status \(status)")
      await connection.close()
      return "ok"
    }
  }

  func testManyChannelsAtOnce() async throws {
    try await Self.each("20 channels", seconds: 180, serverBug: {
      $0.release == "dropbear-2022.83" ? "Dropbear before 2024.86 can fail its assertion common-channel.c:705 "
        + "!channel->sent_close on concurrent channel open and close" : nil
    }) { profile, server in
      let connection = try await Self.connect(profile, server, [.password(profile.password)])
      try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<20 {
          group.addTask {
            let data = Data(LiveClientTests.pseudoRandom(128 * 1024 + index * 997, seed: UInt64(200 + index)))
            let command = index % 2 == 0 ? "cat" : "cat; echo done-\(index) >&2"
            let result = try await connection.run(command, input: data, limit: 1 << 20)
            try require(result.stdout == data, "channel \(index): \(result.stdout.count) bytes")
            if index % 2 == 1 {
              try require(result.stderr == Data("done-\(index)\n".utf8), "channel \(index) stderr")
            }
            try require(result.status == 0, "channel \(index): \(result.status)")
          }
        }
        try await group.waitForAll()
      }
      await connection.close()
      return "ok"
    }
  }

  /// The command never reads its input and exits after a second: the write held by the window ends with the channel,
  /// and the output and status arrive.
  func testACommandThatNeverReadsItsInput() async throws {
    try await Self.each("a command that never reads") { profile, server in
      let connection = try await Self.connect(profile, server, [.password(profile.password)])
      let exec = try await connection.exec("sleep 1; echo done; exit 4")
      let writer = Task { () -> String in
        do {
          try await exec.write(Data(count: 8 << 20))
          return "the write finished"
        } catch {
          return "the write ended: \(error)"
        }
      }
      let output = OutputReader(exec)
      let stdout = try await output.readToEnd(timeout: .seconds(30))
      try require(stdout == Data("done\n".utf8), "stdout \(String(decoding: stdout, as: UTF8.self))")
      let status = try await exec.exitStatus()
      try require(status == 4, "status \(status)")
      let written = try await bounded(15, "the held write") { await writer.value }
      try require(connection.isActive, "the connection ended: \(String(describing: connection.endReason))")
      let next = try await connection.run("echo next")
      try require(next.text == "next\n", next.text)
      await connection.close()
      return "ok (\(written))"
    }
  }

  /// OpenSSH's `MaxSessions 1` and `PermitTTY no` for the two-method account: a second channel and a PTY refused.
  func testTheServerRefusesAChannelAndATerminal() async throws {
    try await Self.each("refused channel and PTY") { profile, server in
      guard let user = server.multiFactorUser else {
        throw XCTSkip("Dropbear has no per-account session limit (MAX_CHANNELS is a build constant)")
      }
      let key = try Self.key(profile, "ed25519")
      let connection = try await Self.connect(profile, server, user: user, [.key(key), .password(profile.password)])
      let first = try await connection.exec("sleep 30")
      var refusal = ""
      do {
        let second = try await connection.exec("echo second")
        let result = try await second.exitStatus()
        throw InteropFailure("a second channel ran: \(result)")
      } catch let error as SSHTransportError {
        refusal = "\(error)"
      }
      await first.close()
      try require(connection.isActive, "the refusal ended the connection")
      await connection.close()
      let fresh = try await Self.connect(profile, server, user: user, [.key(key), .password(profile.password)])
      do {
        _ = try await fresh.shell(term: "xterm-256color", columns: 80, rows: 24)
        throw InteropFailure("a PTY was granted")
      } catch let error as SSHTransportError {
        try require(error == .commandFailed(status: -1, stderr: "the server refused the terminal (pty-req)"), "\(error)")
      }
      await fresh.close()
      return "ok: channel \(refusal); pty-req refused"
    }
  }

  // MARK: Keepalives and the server's end

  /// The server's own keepalives (ClientAliveInterval 2 / dropbear -K 2), as a global request with no channel open
  /// and a channel request with one: answered, so the server keeps the idle connection.
  func testTheServersKeepalivesAreAnswered() async throws {
    try await Self.each("server keepalives", seconds: 60) { profile, server in
      let connection = try await Self.connect(profile, server, [.password(profile.password)])
      try await Task.sleep(for: .seconds(3 * server.serverKeepaliveSeconds + 2))
      try require(connection.isActive, "ended idle: \(String(describing: connection.endReason))")
      let busy = try await connection.run("sleep \(3 * server.serverKeepaliveSeconds + 2); echo still")
      try require(busy.text == "still\n", busy.text)
      await connection.close()
      return "ok"
    }
  }

  func testClientKeepalivesAreAnswered() async throws {
    try await Self.each("client keepalives", serverBug: {
      $0.release == "dropbear-2022.83" ? "Dropbear before 2024.84 answers no global request when remote forwarding "
        + "is disabled (-k)" : nil
    }) { profile, server in
      let connection = try await Self.connect(profile, server, [.password(profile.password)],
                                              keepalive: .milliseconds(300), keepaliveMax: 1)
      try await Task.sleep(for: .seconds(4))
      try require(connection.isActive, "ended: \(String(describing: connection.endReason))")
      let alive = try await connection.run("echo alive")
      try require(alive.text == "alive\n", alive.text)
      await connection.close()
      return "ok"
    }
  }

  /// The server's processes for the connection get SIGTERM (it closes its side) or SIGKILL (the kernel does): the
  /// connection ends, a running command's output ends, its status is `channelClosed`.
  func testTheServerEndsTheConnection() async throws {
    for signal in ["TERM", "KILL"] {
      try await Self.each("server ends (\(signal))") { profile, server in
        let connection = try await Self.connect(profile, server, [.password(profile.password)])
        let pid = try await Self.servingPid(connection)
        let exec = try await connection.exec("cat")
        let reading = Task { try await OutputReader(exec).readToEnd(timeout: .seconds(20)) }
        let pids = try profile.signal(server, pid: pid, signal)
        try await bounded(15, "the end") { await connection.closed() }
        let read: String
        do { read = "output ended with \(try await reading.value.count) bytes" } catch { read = "read threw \(error)" }
        do {
          let status = try await exec.exitStatus()
          throw InteropFailure("exit status \(status) after the connection ended")
        } catch let error as SSHTransportError {
          try require(error == .channelClosed, "exit: \(error)")
        }
        return "ended \(String(describing: connection.endReason)); \(read) (signalled \(pids))"
      }
    }
  }

  /// The server's processes are stopped (SIGSTOP) mid-session: client keepalives go unanswered and the connection
  /// ends as a timeout after (count + 1) intervals.
  func testTheServerStoppedMidSession() async throws {
    try await Self.each("server stopped") { profile, server in
      let connection = try await Self.connect(profile, server, [.password(profile.password)],
                                              keepalive: .milliseconds(500), keepaliveMax: 2)
      let pid = try await Self.servingPid(connection)
      let pids = try profile.signal(server, pid: pid, "STOP")
      defer { _ = try? profile.signal(server, pid: pid, "KILL") }
      let started = ContinuousClock.now
      try await bounded(20, "the keepalive timeout") { await connection.closed() }
      let took = ContinuousClock.now - started
      let end = connection.endReason
      try require(end.map { if case .timedOut = $0 { true } else { false } } ?? false, "ended \(String(describing: end))")
      return "\(String(describing: end)) after \(took.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))) (stopped \(pids))"
    }
  }
}
#endif
