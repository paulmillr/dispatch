import CryptoKit
import XCTest
@testable import SSHEngine

/// The composed core driven synchronously against the scripted server, with no driver, clock or task: what a fuzzer
/// will do. Password and keyboard-interactive logins are covered here (and through the driver in memory), not
/// against the live sshd, which would need a real account password.
final class CoreHarness {
  let core: ClientCore
  let server: ScriptedServer
  let script: ServerScript
  /// Every event, in order.
  private(set) var events: [ClientEvent] = []
  /// Answers the host key question; nil leaves it open.
  var trust: Bool? = true
  /// Answers sign questions with this key (Ed25519, CryptoKit) unless nil.
  var signer: Curve25519.Signing.PrivateKey?
  /// Answers prompts with these (per round), unless nil.
  var answers: [[String]] = []
  private(set) var serverError: Error?

  init(options: ConnectOptions = MemoryWorld.options, configuration: ScriptedServer.Configuration = .init(),
       script: ServerScript = ServerScript(), seed: UInt64 = 0xC0DE) throws {
    core = try ClientCore(options: options, verifier: SSHSignatureVerifier(), random: SeededRandom(seed: seed))
    server = ScriptedServer(configuration: configuration)
    self.script = script
  }

  /// Starts both sides and runs until nothing moves.
  @discardableResult
  func connect() -> [ClientEvent] {
    core.start()
    server.start()
    return pump()
  }

  /// Moves bytes both ways and drains events until nothing moves; returns this call's events.
  @discardableResult
  func pump() -> [ClientEvent] {
    let first = events.count
    for _ in 0..<500 {
      var moved = drain()
      let fromClient = core.takeOutbound()
      moved = drain() || moved
      if !fromClient.isEmpty, serverError == nil {
        moved = true
        let before = server.received.count
        do { try server.receive(fromClient) } catch { serverError = error }
        for payload in server.received[before...] {
          for reply in script.respond(to: payload) { server.send(reply) }
        }
      }
      let fromServer = server.takeOutbound()
      if !fromServer.isEmpty {
        moved = true
        core.receive(fromServer)
      }
      if !drain() && !moved { break }
    }
    return Array(events[first...])
  }

  /// Polls until nil, answering the questions the harness can.
  @discardableResult
  func drain() -> Bool {
    var any = false
    while let event = core.poll() {
      any = true
      events.append(event)
      switch event {
      case .hostKeyNeedsTrust:
        if let trust { core.answerHostKey(trusted: trust) }
      case .sign(let question, let data, _):
        if let signer {
          let blob = Raw.string("ssh-ed25519") + Raw.string(Array(try! signer.signature(for: data)))
          core.signed(question, signature: blob)
        }
      case .prompt(let question, _):
        if !answers.isEmpty { core.answered(question, with: answers.removeFirst().map { SecretBytes(utf8: $0) }) }
      default:
        break
      }
    }
    return any
  }

  var authResults: [Result<AuthOutcome, SSHError>] {
    events.compactMap { if case .authFinished(let result) = $0 { result } else { nil } }
  }

  var ends: [SSHError] { events.compactMap { if case .ended(let error) = $0 { error } else { nil } } }

  /// The client's upper-layer payloads the server got with these numbers.
  func sent(_ number: UInt8) -> [[UInt8]] { server.received.filter { $0.first == number } }
}

final class ClientCoreTests: XCTestCase {
  func testTheHandshakeThenAPasswordLoginThenAnExec() throws {
    let script = ServerScript()
    script.commands["hello"] = [.stdout(Array("hi".utf8)), .exitStatus(0), .eof, .close]
    let harness = try CoreHarness(script: script)
    let events = harness.connect()
    XCTAssertEqual(events.filter { if case .hostKeyNeedsTrust = $0 { true } else { false } }.count, 1)
    XCTAssertTrue(events.contains(.established))
    XCTAssertTrue(harness.core.isEstablished)
    try harness.core.authenticate(user: "phone", credential: .password(SecretBytes(utf8: "fictional")))
    harness.pump()
    XCTAssertEqual(harness.authResults, [.success(.success)])
    XCTAssertEqual(harness.sent(50).first, ClientAuth.password("phone", "fictional"))
    XCTAssertTrue(harness.core.isAuthenticated)
    let id = try harness.core.openExec("hello")
    let channelEvents = harness.pump().filter {
      switch $0 {
      case .opened, .output, .eof, .closed: true
      default: false
      }
    }
    XCTAssertEqual(channelEvents, [.opened(id), .output(id, .stdout(Array("hi".utf8))), .eof(id),
                                   .closed(id, .status(0), lostWith: nil)])
    harness.core.end(.closed(.byClient))
    XCTAssertEqual(harness.pump().last, .ended(.closed(.byClient)))
    XCTAssertEqual(harness.server.disconnectReason, DisconnectReason.byApplication.rawValue)
  }

  func testAPasswordChangeRequestAndARefusal() throws {
    let script = ServerScript()
    var answers: [[[UInt8]]] = [[[60] + Raw.string("expired") + Raw.string("")], [ServerAuth.failure("publickey")]]
    script.login = { _ in answers.removeFirst() }
    let harness = try CoreHarness(script: script)
    harness.connect()
    try harness.core.authenticate(user: "phone", credential: .password(SecretBytes(utf8: "old")))
    harness.pump()
    try harness.core.authenticate(user: "phone", credential: .password(SecretBytes(utf8: "old")))
    harness.pump()
    XCTAssertEqual(harness.authResults, [.success(.passwordChangeRequested),
                                         .success(.refused(remaining: [.publicKey], partialSuccess: false))])
    XCTAssertTrue(harness.ends.isEmpty)
  }

  /// Keyboard-interactive over several rounds, a round with no prompts answered without asking, then success.
  func testKeyboardInteractiveRounds() throws {
    let script = ServerScript()
    var rounds: [[[UInt8]]] = [
      [ServerAuth.infoRequest(name: Array("second".utf8), prompts: [(Array("Token: ".utf8), true)])],
      [ServerAuth.infoRequest(prompts: [])],
      [ServerAuth.success],
    ]
    script.login = { request in
      request.method == "keyboard-interactive"
        ? [ServerAuth.infoRequest(instruction: Array("two prompts".utf8), prompts: [(Array("Password: ".utf8), false), (Array("Code: ".utf8), true)])]
        : []
    }
    script.infoResponse = { _ in rounds.removeFirst() }
    let harness = try CoreHarness(script: script)
    harness.answers = [["fictional", "1234"], ["5678"]]
    harness.connect()
    try harness.core.authenticate(user: "phone", credential: .keyboardInteractive { _ in nil })
    harness.pump()
    XCTAssertEqual(harness.authResults, [.success(.success)])
    let prompts = harness.events.compactMap { if case .prompt(_, let challenge) = $0 { challenge } else { nil } }
    XCTAssertEqual(prompts.map(\.prompts.count), [2, 1], "the empty round was not asked")
    XCTAssertEqual(prompts.first?.instruction, "two prompts")
    XCTAssertEqual(prompts.last?.name, "second")
    XCTAssertEqual(harness.sent(61), [ClientAuth.infoResponse(["fictional", "1234"]), ClientAuth.infoResponse(["5678"]),
                                      ClientAuth.infoResponse([])])
  }

  /// A direct login: SERVICE_REQUEST and the `.sign` question come at once; the signed request follows in the very
  /// next write, before the server said anything.
  func testADirectLoginNeedsNoRoundTrip() throws {
    let key = Curve25519.Signing.PrivateKey()
    let user = try cryptoKitEd25519(key)
    let harness = try CoreHarness()
    harness.connect()
    try harness.core.authenticate(user: "phone", credential: .publicKey(user, direct: true))
    let first = harness.core.takeOutbound()
    XCTAssertFalse(first.isEmpty, "SERVICE_REQUEST")
    guard case .sign(let question, let data, .ed25519) = harness.core.poll() else { return XCTFail("no sign question") }
    XCTAssertEqual(Array(data.prefix(4 + harness.core.sessionID.count)), Raw.string(harness.core.sessionID))
    harness.core.signed(question, signature: Raw.string("ssh-ed25519") + Raw.string(Array(try key.signature(for: data))))
    let second = harness.core.takeOutbound()
    XCTAssertFalse(second.isEmpty, "the signed request")
    // The server sees both before it answered anything.
    try harness.server.receive(first + second)
    let upper = harness.server.received.filter { $0.first == 5 || $0.first == 50 }
    XCTAssertEqual(upper.map { $0.first }, [5, 50])
    for payload in harness.server.received.suffix(1) { for reply in harness.script.respond(to: payload) { harness.server.send(reply) } }
    harness.pump()
    XCTAssertEqual(harness.authResults, [.success(.success)])
    let timers = harness.events.compactMap { if case .timer(let request) = $0 { request } else { nil } }
    XCTAssertTrue(timers.contains(.schedule(.directAnswer, after: MemoryWorld.options.directAnswer)))
    XCTAssertTrue(timers.contains(.cancel(.directAnswer)))
  }

  func testTheDirectAnswerTimerEndsTheConnection() throws {
    let script = ServerScript()
    script.login = { _ in [] }
    let harness = try CoreHarness(script: script)
    harness.signer = Curve25519.Signing.PrivateKey()
    harness.connect()
    let user = try cryptoKitEd25519(harness.signer!)
    try harness.core.authenticate(user: "phone", credential: .publicKey(user, direct: true))
    harness.pump()
    harness.core.timerFired(.keepalive)  // not the auth core's: nothing for the login
    harness.core.timerFired(.directAnswer)
    harness.pump()
    XCTAssertEqual(harness.authResults, [.failure(.timedOut(.directAnswer))])
    XCTAssertEqual(harness.ends, [.timedOut(.directAnswer)])
  }

  /// The end comes last, after the login and every channel ended; nothing after it.
  func testTheEndIsLastAndOnce() throws {
    let script = ServerScript()
    script.commands["idle"] = []
    let harness = try CoreHarness(script: script)
    harness.connect()
    try harness.core.authenticate(user: "phone", credential: .password(SecretBytes(utf8: "x")))
    harness.pump()
    let a = try harness.core.openExec("idle")
    let b = try harness.core.openExec("idle")
    harness.pump()
    harness.core.receiveEnd()
    harness.core.receiveEnd()
    harness.core.end(.closed(.byClient))
    harness.core.timerFired(.keepalive)
    harness.core.receive([1, 2, 3])
    harness.drain()
    let tail = Array(harness.events.suffix(3))
    XCTAssertEqual(tail, [.closed(a, .lost, lostWith: .closed(.connectionLost)), .closed(b, .lost, lostWith: .closed(.connectionLost)),
                          .ended(.closed(.connectionLost))])
    XCTAssertNil(harness.core.poll())
    XCTAssertEqual(harness.ends.count, 1)
    XCTAssertThrows(SSHError.closed(.alreadyEnded)) { () throws(SSHError) in try harness.core.openExec("idle") }
    XCTAssertThrows(SSHError.closed(.alreadyEnded)) { () throws(SSHError) in
      try harness.core.authenticate(user: "phone", credential: .password(SecretBytes(utf8: "x")))
    }
    XCTAssertThrows(SSHError.closed(.connectionLost)) { () throws(SSHError) in try harness.core.write([1], to: a) }
  }

  func testRequestsBeforeTheirPhase() throws {
    let harness = try CoreHarness()
    harness.trust = nil
    harness.connect()
    XCTAssertThrows(SSHError.usage(.invalidArgument("a login before the key exchange completed"))) { () throws(SSHError) in
      try harness.core.authenticate(user: "phone", credential: .password(SecretBytes(utf8: "x")))
    }
    harness.core.end(.hostKeyRejected)
    XCTAssertEqual(harness.core.poll(), .ended(.hostKeyRejected))
    XCTAssertThrows(SSHError.closed(.alreadyEnded)) { () throws(SSHError) in try harness.core.openExec("x") }
  }

  /// Same seed, same server: byte for byte the same client output, so a fuzzer's run can be replayed.
  func testTheCoreIsDeterministic() throws {
    func transcript() throws -> [UInt8] {
      let harness = try CoreHarness(seed: 7)
      var out: [UInt8] = []
      harness.core.start()
      out += harness.core.takeOutbound()
      return out
    }
    XCTAssertEqual(try transcript(), try transcript())
  }

  /// Garbage after the login, in many shapes: the core never traps and ends exactly once.
  func testHostileBytesAfterTheLogin() throws {
    let random = SeededRandom(seed: 0xBAD)
    for round in 0..<200 {
      let harness = try CoreHarness(seed: UInt64(round))
      harness.connect()
      try harness.core.authenticate(user: "phone", credential: .password(SecretBytes(utf8: "x")))
      harness.pump()
      _ = try? harness.core.openExec("cat")
      harness.pump()
      // A sealed payload of random bytes under the real keys, then raw noise.
      let payload = (0..<(1 + random.below(64))).map { _ in UInt8(truncatingIfNeeded: random.next()) }
      harness.server.send([UInt8(90 + random.below(12))] + payload)
      harness.core.receive(harness.server.takeOutbound())
      harness.drain()
      harness.core.receive((0..<random.below(300)).map { _ in UInt8(truncatingIfNeeded: random.next()) })
      harness.drain()
      harness.core.receiveEnd()
      harness.drain()
      XCTAssertEqual(harness.ends.count, 1, "round \(round)")
      XCTAssertEqual(harness.events.last.map { if case .ended = $0 { true } else { false } }, true, "round \(round)")
    }
  }
}
