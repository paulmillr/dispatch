import CryptoKit
import Foundation
@testable import MobileTransport
import SSHEngine
import XCTest

/// The Swift engine adapter's connections and logins (`SwiftEngine`, `SwiftEngineSession`) against a scripted facade:
/// the seam's rules for callbacks (exactly once, nothing after the last, never on the caller's thread), questions
/// (answered once, withdrawn at once), the end of a connection at every stage, and each login's outcomes and errors.
final class SwiftEngineSessionTests: XCTestCase {
  private static let options = EngineConnectOptions(
    host: "studio.example", port: 2222, timeout: .seconds(15), keepalive: .seconds(15), keepaliveMax: 3)

  private func connect(_ fake: ScriptedSession, decide: Bool? = true, file: StaticString = #filePath, line: UInt = #line)
    async -> (ConnectResult, RecordedSession, ScriptedConnector) {
    let connector = ScriptedConnector(fake)
    let events = RecordedSession(decide: decide)
    let result = ConnectResult()
    SwiftEngine(connector: connector).connect(Self.options, events: events, connected: result.callback)
    await wait(result.results, "connected", file: file, line: line) { !$0.isEmpty }
    return (result, events, connector)
  }

  private func connected(_ fake: ScriptedSession = ScriptedSession(), file: StaticString = #filePath, line: UInt = #line)
    async throws -> (any EngineSession, RecordedSession) {
    let (result, events, _) = await connect(fake, file: file, line: line)
    return (try XCTUnwrap(result.session, "\(String(describing: result.error))", file: file, line: line), events)
  }

  private func login(_ start: (@escaping @Sendable (Result<EngineAuthOutcome, SSHTransportError>) -> Void) -> Void,
                     file: StaticString = #filePath, line: UInt = #line) async -> Result<EngineAuthOutcome, SSHTransportError>? {
    let result = LoginResult()
    start(result.done)
    await wait(result.results, "done", file: file, line: line) { !$0.isEmpty }
    XCTAssertEqual(result.results.value.count, 1, "done more than once", file: file, line: line)
    return result.results.value.first
  }

  // MARK: Connecting

  func testConnectAsksTheHostKeyAndEndsOnce() async throws {
    let fake = ScriptedSession()
    let (result, events, connector) = await connect(fake)
    XCTAssertNotNil(result.session)
    let key = try XCTUnwrap(events.state.value.keys.first)
    XCTAssertEqual(events.state.value.keys.count, 1)
    XCTAssertEqual(key.algorithm, "ssh-ed25519")
    XCTAssertEqual(key.openSSH, "ssh-ed25519 " + Data(fake.hostKey.blob).base64EncodedString())
    XCTAssertEqual(key.fingerprint, SSHFingerprint.sha256(blob: Data(fake.hostKey.blob)))
    let options = try XCTUnwrap(connector.options.value.first)
    XCTAssertEqual(options.host, "studio.example")
    XCTAssertEqual(options.port, 2222)
    XCTAssertEqual(options.handshakeTimeout, .seconds(15))
    XCTAssertEqual(options.keepaliveInterval, .seconds(15))
    XCTAssertEqual(options.keepaliveCountMax, 3)
    XCTAssertEqual(options.directAnswer, .seconds(10))
    XCTAssertTrue(events.state.value.disconnects.isEmpty)

    result.session?.close()
    await wait(events.state, "disconnected") { !$0.disconnects.isEmpty }
    XCTAssertEqual(events.state.value.disconnects, [.channelClosed])
    // Safe after the end: a second close and a login change nothing, and the login fails.
    result.session?.close()
    let after = await login { result.session!.authenticate(user: "sam", password: "pw", done: $0) }
    XCTAssertEqual(after, .failure(.channelClosed))
    XCTAssertEqual(events.state.value.disconnects.count, 1)
    XCTAssertEqual(events.state.value.callsAfterEnd, 0)
    XCTAssertEqual(events.state.value.mainThread, 0)
  }

  /// What russh clamps the facade refuses (`ConnectOptions.validate`): the adapter maps each onto a valid option.
  func testOptionsTheFacadeTakes() throws {
    func mapped(timeout: Duration = .seconds(15), keepalive: Duration = .seconds(15), max: Int = 3, port: Int = 22) -> ConnectOptions {
      SwiftEngine.options(EngineConnectOptions(host: "studio", port: port, timeout: timeout, keepalive: keepalive, keepaliveMax: max))
    }
    XCTAssertEqual(mapped(timeout: .zero).handshakeTimeout, .milliseconds(1))
    XCTAssertNil(mapped(keepalive: .zero).keepaliveInterval)
    XCTAssertEqual(mapped(max: 0).keepaliveCountMax, Limits.keepaliveCountMax)
    XCTAssertEqual(mapped(max: -1).keepaliveCountMax, Limits.keepaliveCountMax)
    XCTAssertEqual(mapped(max: 500).keepaliveCountMax, Limits.keepaliveCountMax)
    XCTAssertEqual(mapped(max: 2).keepaliveCountMax, 2)
    XCTAssertEqual(mapped(port: 70_000).port, 65_535)
    for options in [mapped(timeout: .zero), mapped(keepalive: .zero), mapped(max: 0), mapped(max: 500), mapped(port: 70_000)] {
      XCTAssertNoThrow(try options.validate())
    }
    XCTAssertEqual(SwiftEngine(connector: ScriptedConnector(ScriptedSession())).version, "dispatch-mobile-ssh (SSHEngine, Swift)")
  }

  /// A refused key fails the connect as russh's does (its text, which the wrappers replace from the app's decision), and
  /// a failed connect calls nothing more.
  func testARejectedHostKeyFailsTheConnect() async throws {
    let (result, events, _) = await connect(ScriptedSession(), decide: false)
    XCTAssertEqual(result.error, .protocolError("Unknown server key"))
    XCTAssertTrue(events.state.value.disconnects.isEmpty)

    // With the wrappers' link, the app's decision explains it.
    let link = SessionLink(host: "studio", port: 22, trust: Decided(.reject), trusted: nil)
    let linked = ConnectResult()
    SwiftEngine(connector: ScriptedConnector(ScriptedSession())).connect(Self.options, events: link, connected: linked.callback)
    await wait(linked.results, "connected") { !$0.isEmpty }
    guard case SSHTransportError.hostKeyRejected(let info)? = linked.error.map(link.explain) else {
      return XCTFail("\(String(describing: linked.error))")
    }
    XCTAssertEqual(info.algorithm, "ssh-ed25519")
  }

  func testConnectFailures() async throws {
    let cases: [(SSHError, SSHTransportError)] = [
      (.hostNotFound, .connectFailed(.hostNotFound, host: "", port: 0)),
      (.connectionRefused, .connectFailed(.refused, host: "", port: 0)),
      (.unreachable, .connectFailed(.unreachable, host: "", port: 0)),
      (.noAnswer, .connectFailed(.noAnswer, host: "", port: 0)),
      (.timedOut(.lookup), .timedOut("looking up the host's address")),
      (.timedOut(.handshake), .timedOut("the SSH handshake")),
      (.network("Socket is not connected"), .network("Socket is not connected")),
      (.closed(.connectionLost), .channelClosed),
      (.protocolViolation(.version(.notSSH2)), .protocolError("the server's identification line: notSSH2")),
      (.protocolViolation(.keyExchange(.hostKeyCertificate)), .protocolError("key exchange: hostKeyCertificate")),
      (.usage(.invalidArgument("port 0")), .protocolError(SSHError.usage(.invalidArgument("port 0")).description)),
    ]
    for (thrown, expected) in cases {
      let events = RecordedSession()
      let result = ConnectResult()
      SwiftEngine(connector: ScriptedConnector { _, _ throws(SSHError) in throw thrown })
        .connect(Self.options, events: events, connected: result.callback)
      await wait(result.results, "connected") { !$0.isEmpty }
      XCTAssertEqual(result.error, expected)
      XCTAssertTrue(events.state.value.keys.isEmpty)
      XCTAssertTrue(events.state.value.disconnects.isEmpty)
    }
    // The wrappers name the endpoint.
    let link = SessionLink(host: "studio.local", port: 2222, trust: Decided(.trust), trusted: nil)
    XCTAssertEqual(link.explain(SSHError.noAnswer.transportError) as? SSHTransportError,
                   .connectFailed(.noAnswer, host: "studio.local", port: 2222))
  }

  /// The facade abandons the connect (its trust task cancelled) while the question is open: the question answers no at
  /// once, and the app's answer, when it comes, does nothing. A question withdrawn before it was asked is never asked.
  func testTheFacadeWithdrawsTheHostKeyQuestion() async throws {
    let fake = ScriptedSession()
    let answered = Watched<Bool?>(nil)
    let events = RecordedSession(decide: nil)
    let connector = ScriptedConnector { _, trust throws(SSHError) in
      let asking = Task { await trust(fake.hostKey) }
      _ = await events.state.until { !$0.keys.isEmpty }
      asking.cancel()
      let trusted = await asking.value
      answered.change { $0 = trusted }
      throw .cancelled
    }
    let result = ConnectResult()
    SwiftEngine(connector: connector).connect(Self.options, events: events, connected: result.callback)
    await wait(result.results, "connected") { !$0.isEmpty }
    XCTAssertEqual(answered.value, false)
    XCTAssertEqual(result.error, .cancelled)
    events.state.value.answers.first?(true)  // late: nothing happens
    XCTAssertEqual(result.results.value.count, 1)

    let never = RecordedSession(decide: nil)
    let cancelledFirst = ScriptedConnector { _, trust throws(SSHError) in
      let asking = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await trust(fake.hostKey)
      }
      guard await asking.value else { throw .hostKeyRejected }
      return fake
    }
    let second = ConnectResult()
    SwiftEngine(connector: cancelledFirst).connect(Self.options, events: never, connected: second.callback)
    await wait(second.results, "connected") { !$0.isEmpty }
    XCTAssertEqual(second.error, .protocolError("Unknown server key"))
    XCTAssertTrue(never.state.value.keys.isEmpty, "a withdrawn question was asked")
  }

  /// The wrappers withdraw the question (the connect's task cancelled): `SessionLink` answers no, the connect fails, and
  /// the wrappers explain it from the app's decision.
  func testTheWrappersWithdrawTheHostKeyQuestion() async throws {
    let trust = Pending()
    let link = SessionLink(host: "studio", port: 22, trust: trust, trusted: nil)
    let result = ConnectResult()
    SwiftEngine(connector: ScriptedConnector(ScriptedSession())).connect(Self.options, events: link, connected: result.callback)
    await wait(trust.asked, "the question") { $0 }
    link.withdraw()
    await wait(result.results, "connected") { !$0.isEmpty }
    guard case SSHTransportError.hostKeyRejected? = result.error.map(link.explain) else {
      return XCTFail("\(String(describing: result.error))")
    }
  }

  /// `disconnected` exactly once whatever races to end the connection: closes from many tasks, the server's end, the
  /// release of the session.
  func testDisconnectedExactlyOnceUnderRaces() async throws {
    for round in 0..<40 {
      let fake = ScriptedSession()
      let (result, events, _) = await connect(fake)
      let session = try XCTUnwrap(result.session)
      await withTaskGroup(of: Void.self) { group in
        for index in 0..<8 {
          group.addTask {
            if index == round % 8 { fake.end(.closed(.byServer(.byApplication, description: "bye"))) } else { session.close() }
          }
        }
      }
      result.results.change { $0 = [] }
      await wait(events.state, "disconnected") { !$0.disconnects.isEmpty }
      // A round trip through the facade after the end, then the count again.
      _ = await fake.ended()
      XCTAssertEqual(events.state.value.disconnects, [.channelClosed])
      XCTAssertEqual(events.state.value.callsAfterEnd, 0)
    }
  }

  /// Releasing the last reference closes the connection; `disconnected` follows.
  func testReleasingTheSessionClosesIt() async throws {
    let fake = ScriptedSession()
    let (result, events, _) = await connect(fake)
    weak let released = result.session as AnyObject?
    XCTAssertNotNil(released)
    result.results.change { $0 = [] }
    XCTAssertNil(released, "something kept the session")
    await wait(fake.state, "the facade's close") { $0.closes == 1 }
    await wait(events.state, "disconnected") { !$0.disconnects.isEmpty }
    XCTAssertEqual(events.state.value.disconnects, [.channelClosed])
  }

  /// After the end every call is safe: no second `disconnected`, channels and logins fail with `channelClosed`, a
  /// signer is not asked.
  func testEverythingIsSafeAfterTheEnd() async throws {
    let fake = ScriptedSession()
    let (session, events) = try await connected(fake)
    fake.end(.timedOut(.keepalive))
    await wait(events.state, "disconnected") { !$0.disconnects.isEmpty }
    XCTAssertEqual(events.state.value.disconnects, [.timedOut("the host stopped answering")])
    session.close()
    let exec = RecordedChannel()
    session.exec("true", events: exec)
    let shell = RecordedChannel()
    let control = session.shell(term: "vt100", columns: 80, rows: 24, events: shell)
    control.resize(columns: 100, rows: 30)
    await wait(exec.calls, "exec opened") { !$0.isEmpty }
    await wait(shell.calls, "shell opened") { !$0.isEmpty }
    XCTAssertEqual(exec.calls.value, [.opened(.failure(.channelClosed))])
    XCTAssertEqual(shell.calls.value, [.opened(.failure(.channelClosed))])
    let signer = Signer(Curve25519.Signing.PrivateKey())
    for result in [
      await login { session.authenticate(user: "sam", password: "pw", done: $0) },
      await login { session.authenticateKeyboardInteractive(user: "sam", prompt: { _, answer in answer([]) }, done: $0) },
      await login { session.authenticate(user: "sam", signer: signer.blob, direct: true, sign: signer.sign, done: $0) },
    ] {
      XCTAssertEqual(result, .failure(.channelClosed))
    }
    XCTAssertEqual(signer.asked.value, 0)
    XCTAssertEqual(events.state.value.disconnects.count, 1)
  }

  // MARK: Logins

  func testPasswordOutcomes() async throws {
    let cases: [(Result<AuthOutcome, SSHError>, Result<EngineAuthOutcome, SSHTransportError>)] = [
      (.success(.success), .success(.loggedIn)),
      (.success(.refused(remaining: [.password, .keyboardInteractive], partialSuccess: false)),
       .success(.refused(remaining: [.password, .keyboardInteractive]))),
      (.success(.refused(remaining: [.publicKey, .hostBased], partialSuccess: true)), .success(.refused(remaining: [.publicKey, .hostbased]))),
      (.success(.refused(remaining: [], partialSuccess: false)), .success(.refused(remaining: []))),
      (.success(.passwordChangeRequested), .success(.refused(remaining: [.password]))),
      (.failure(.closed(.connectionLost)), .failure(.channelClosed)),
      (.failure(.protocolViolation(.authentication(.unexpectedService))), .failure(.protocolError("authentication: unexpectedService"))),
      (.failure(.usage(.authenticationInProgress)), .failure(.protocolError("authenticationInProgress"))),
    ]
    for (scripted, expected) in cases {
      let fake = ScriptedSession()
      let seen = Watched<[String]>([])
      fake.login = { _, user, credential throws(SSHError) in
        guard case .password(let secret) = credential else { throw .cancelled }
        seen.change { $0.append(user + ":" + secret.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }) }
        return try scripted.get()
      }
      let (session, _) = try await connected(fake)
      let result = await login { session.authenticate(user: "sam", password: "correct horse", done: $0) }
      XCTAssertEqual(result, expected)
      XCTAssertEqual(seen.value, ["sam:correct horse"])
      session.close()
    }
  }

  #if os(macOS)
  func testFileKeyLoginsAndAnotherEnginesKey() async throws {
    let file = try Self.keyFile()
    let engine = SwiftEngine(connector: ScriptedConnector(ScriptedSession()))
    let parsed = try XCTUnwrap(try engine.parseKey(file, passphrase: nil) as? SwiftEngineKey)
    for direct in [false, true] {
      for (scripted, expected) in [
        (Result<AuthOutcome, SSHError>.success(.success), Result<EngineAuthOutcome, SSHTransportError>.success(.loggedIn)),
        (.success(.refused(remaining: [.publicKey], partialSuccess: false)), .success(.refused(remaining: [.publicKey]))),
        // A direct login's answers (`DirectKeyAnswer`): the connection's end and the 10 s deadline.
        (.failure(.closed(.connectionLost)), .failure(.channelClosed)),
        (.failure(.timedOut(.directAnswer)), .failure(.timedOut("the login"))),
      ] {
        let fake = ScriptedSession()
        let seen = Watched<[Bool]>([])
        fake.login = { _, _, credential throws(SSHError) in
          guard case .publicKey(let key, let sentDirect) = credential, (key as? FileKey) === parsed.key else { throw .cancelled }
          seen.change { $0.append(sentDirect) }
          return try scripted.get()
        }
        let (session, _) = try await connected(fake)
        let result = await login { session.authenticate(user: "sam", key: parsed, direct: direct, done: $0) }
        XCTAssertEqual(result, expected)
        XCTAssertEqual(seen.value, [direct])
        session.close()
      }
    }
    // A key another engine parsed (russh's, in a `DISPATCH_RUSSH` build) fails here at once, as a Swift key does on
    // russh's connection.
    let fake = ScriptedSession()
    let (session, _) = try await connected(fake)
    #if DISPATCH_RUSSH
    let foreign = try RusshEngine.shared.parseKey(file, passphrase: nil)
    #else
    let foreign: any EngineKey = ForeignEngineKey()
    #endif
    let done = LoginResult()
    session.authenticate(user: "sam", key: foreign, direct: false, done: done.done)
    XCTAssertEqual(done.results.value, [.failure(.invalidKey("the key was parsed by another SSH engine"))], "inside the call")
    XCTAssertTrue(fake.state.value.logins.isEmpty)
    session.close()
  }
  #endif

  /// Rounds in order, each asked once its predecessor's answers were used, with the prompts as the server sent them;
  /// the answers reach the engine as secrets. nil and a wrong count cancel the login.
  func testKeyboardInteractiveRounds() async throws {
    let rounds = [
      SSHEngine.KeyboardInteractiveChallenge(name: "PAM", instruction: "Two factors", prompts: [
        .init(text: "Password: ", echo: false), .init(text: "Code: ", echo: true),
      ]),
      SSHEngine.KeyboardInteractiveChallenge(name: "", instruction: "", prompts: [.init(text: "Again: ", echo: false)]),
    ]
    let fake = ScriptedSession()
    let got = Watched<[[String]?]>([])
    fake.login = { _, _, credential throws(SSHError) in
      guard case .keyboardInteractive(let respond) = credential else { throw .cancelled }
      for round in rounds {
        // The facade cancels on nil (and on a wrong count, which the adapter turns into nil).
        guard let answers = await respond(round), answers.count == round.prompts.count else { throw .cancelled }
        got.change { $0.append(answers.map { $0.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } }) }
      }
      return .success
    }
    let (session, _) = try await connected(fake)
    let asked = Watched<[MobileTransport.KeyboardInteractiveChallenge]>([])
    let replies: [[String]] = [["pw", "123456"], ["pw"]]
    let result = await login { done in
      session.authenticateKeyboardInteractive(user: "sam", prompt: { challenge, answer in
        let index = asked.change { asked -> Int in
          asked.append(challenge)
          return asked.count - 1
        }
        DispatchQueue.global().async { answer(replies[index]) }
      }, done: done)
    }
    XCTAssertEqual(result, .success(.loggedIn))
    XCTAssertEqual(got.value, [["pw", "123456"], ["pw"]])
    XCTAssertEqual(asked.value.map(\.name), ["PAM", ""])
    XCTAssertEqual(asked.value.first?.instruction, "Two factors")
    XCTAssertEqual(asked.value.first?.prompts.map(\.text), ["Password: ", "Code: "])
    XCTAssertEqual(asked.value.first?.prompts.map(\.echo), [false, true])
    session.close()

    for reply in [nil, ["only one"], ["one", "two", "three"]] as [[String]?] {
      let fake = ScriptedSession()
      fake.login = { _, _, credential throws(SSHError) in
        guard case .keyboardInteractive(let respond) = credential, await respond(rounds[0]) != nil else { throw .cancelled }
        return .success
      }
      let (session, _) = try await connected(fake)
      let result = await login { session.authenticateKeyboardInteractive(user: "sam", prompt: { _, answer in answer(reply) }, done: $0) }
      XCTAssertEqual(result, .failure(.cancelled), "\(String(describing: reply))")
      session.close()
    }
  }

  /// The facade withdraws a prompt (its task cancelled): the responder returns nil at once; the app's answer later
  /// does nothing.
  func testTheFacadeWithdrawsAPrompt() async throws {
    let fake = ScriptedSession()
    let late = Watched<[@Sendable ([String]?) -> Void]>([])
    fake.login = { _, _, credential throws(SSHError) in
      guard case .keyboardInteractive(let respond) = credential else { throw .cancelled }
      let asking = Task { await respond(SSHEngine.KeyboardInteractiveChallenge(name: "", instruction: "", prompts: [.init(text: "Code: ", echo: true)])) }
      _ = await late.until { !$0.isEmpty }
      asking.cancel()
      guard await asking.value == nil else { return .success }
      throw .cancelled
    }
    let (session, _) = try await connected(fake)
    let result = await login { session.authenticateKeyboardInteractive(user: "sam", prompt: { _, answer in late.change { $0.append(answer) } }, done: $0) }
    XCTAssertEqual(result, .failure(.cancelled))
    late.value.first?(["123456"])
    session.close()
  }

  /// External signers (CryptoKit Ed25519 and P-256, as `SSHKey(ed25519:)` and `SSHKey(p256:)` sign): asked with the
  /// facade's bytes, their raw signature becomes a blob that verifies; declining, a wrong length and another key's
  /// signature fail the login; an empty, undecodable or RSA blob fails it inside the call without asking.
  func testSignerLogins() async throws {
    let ed25519 = Signer(Curve25519.Signing.PrivateKey())
    let p256 = Signer(P256.Signing.PrivateKey())
    for (signer, algorithm) in [(ed25519, SignatureAlgorithm.ed25519), (p256, .ecdsaP256)] {
      for direct in [false, true] {
        let fake = ScriptedSession()
        let signed = Watched<[UInt8]?>(nil)
        fake.login = { _, _, credential throws(SSHError) in
          guard case .publicKey(let key, direct) = credential, key.publicKeyBlob == Array(signer.blob) else { throw .cancelled }
          let blob = try await key.sign(Array("session id and request".utf8), algorithm: algorithm)
          signed.change { $0 = blob }
          return .success
        }
        let (session, _) = try await connected(fake)
        let result = await login { session.authenticate(user: "sam", signer: signer.blob, direct: direct, sign: signer.sign, done: $0) }
        XCTAssertEqual(result, .success(.loggedIn))
        XCTAssertEqual(signer.data.value.last, Data("session id and request".utf8))
        let blob = try XCTUnwrap(signed.value)
        XCTAssertEqual(try SignatureBlob(decoding: blob).algorithm, algorithm.rawValue)
        session.close()
      }
    }
    let refusals: [(Signer, SSHTransportError)] = [
      (Signer(Curve25519.Signing.PrivateKey(), answer: { _ in nil }), .cancelled),
      (Signer(Curve25519.Signing.PrivateKey(), answer: { _ in Data(count: 63) }), .invalidKey("Ed25519 signatures are 64 bytes")),
      (Signer(P256.Signing.PrivateKey(), answer: { _ in Data(count: 63) }), .invalidKey("ECDSA signature has the wrong length")),
      (Signer(Curve25519.Signing.PrivateKey(), answer: { try? Curve25519.Signing.PrivateKey().signature(for: $0) }),
       .invalidKey("the signer's signature does not verify with its public key")),
    ]
    for (signer, expected) in refusals {
      let fake = ScriptedSession()
      fake.login = { _, _, credential throws(SSHError) in
        guard case .publicKey(let key, _) = credential else { throw .cancelled }
        _ = try await key.sign([1, 2, 3], algorithm: signer.algorithm)
        return .success
      }
      let (session, _) = try await connected(fake)
      let result = await login { session.authenticate(user: "sam", signer: signer.blob, direct: true, sign: signer.sign, done: $0) }
      XCTAssertEqual(result, .failure(expected))
      session.close()
    }
    let fake = ScriptedSession()
    let (session, _) = try await connected(fake)
    for (blob, expected) in [
      (Data(), SSHTransportError.protocolError("invalid arguments")),
      (Data([0, 0, 0, 3, 1, 2]), .invalidKey("the signer's public key blob is not a key the engine takes")),
      (Self.rsaBlob(), .unsupportedAuthentication("external signing for ssh-rsa is unsupported")),
    ] {
      let done = LoginResult()
      let signer = Signer(Curve25519.Signing.PrivateKey())
      session.authenticate(user: "sam", signer: blob, direct: false, sign: signer.sign, done: done.done)
      XCTAssertEqual(done.results.value, [.failure(expected)], "inside the call")
      XCTAssertEqual(signer.asked.value, 0)
    }
    XCTAssertTrue(fake.state.value.logins.isEmpty)
    session.close()
  }

  /// The wrappers withdraw a signature (`SessionLink.withdraw`, the connect cancelled): the sign question answers nil,
  /// the login ends `cancelled` (a direct one reported withdrawn by the wrappers).
  func testTheWrappersWithdrawASignature() async throws {
    let fake = ScriptedSession()
    fake.login = { _, _, credential throws(SSHError) in
      guard case .publicKey(let key, _) = credential else { throw .cancelled }
      _ = try await key.sign([1], algorithm: .ed25519)
      return .success
    }
    let link = SessionLink(host: "studio", port: 22, trust: Decided(.trust), trusted: nil)
    let result = ConnectResult()
    SwiftEngine(connector: ScriptedConnector(fake)).connect(Self.options, events: link, connected: result.callback)
    await wait(result.results, "connected") { !$0.isEmpty }
    let session = try XCTUnwrap(result.session)
    let faceID = Watched(false)
    let key = Curve25519.Signing.PrivateKey()
    let signer = Signer(key)
    let outcome = await login { done in
      // As `SSHConnection.attempt` asks: on a task `link` withdraws.
      session.authenticate(user: "sam", signer: signer.blob, direct: true, sign: { data, answer in
        link.ask {
          faceID.change { $0 = true }
          await withTaskCancellationHandler {
            _ = await faceID.waitForTest("the withdrawal") { !$0 }
          } onCancel: { faceID.change { $0 = false } }
          guard !Task.isCancelled else { return answer(nil) }
          answer(try? key.signature(for: data))
        }
      }, done: done)
      Task {
        _ = await faceID.until { $0 }
        link.withdraw()
      }
    }
    XCTAssertEqual(outcome, .failure(.cancelled))
    session.close()
  }

  /// A connection that ends while a login waits (for the server, or for the app's signature): the login ends once,
  /// `channelClosed`, never a refusal; the app's late signature does nothing.
  func testTheEndDuringAPendingLogin() async throws {
    let fake = ScriptedSession()
    fake.login = { session, _, credential throws(SSHError) in
      if case .publicKey(let key, _) = credential {
        // (A typed-throws task closure crashes this compiler: the result is not needed.)
        let signing = Task { _ = try? await key.sign([1], algorithm: .ed25519) }
        _ = await session.ended()
        signing.cancel()
        await signing.value
      }
      try await session.pending()
    }
    let (session, events) = try await connected(fake)
    let password = LoginResult()
    session.authenticate(user: "sam", password: "pw", done: password.done)
    await wait(fake.state, "the login sent") { $0.logins.count == 1 }
    session.close()
    await wait(password.results, "done") { !$0.isEmpty }
    XCTAssertEqual(password.results.value, [.failure(.channelClosed)])

    let other = ScriptedSession()
    other.login = fake.login
    let (second, secondEvents) = try await connected(other)
    let pending = Watched<[@Sendable (Data?) -> Void]>([])
    let signer = Signer(Curve25519.Signing.PrivateKey())
    let direct = LoginResult()
    second.authenticate(user: "sam", signer: signer.blob, direct: true, sign: { _, answer in pending.change { $0.append(answer) } },
                        done: direct.done)
    await wait(pending, "the signature asked") { !$0.isEmpty }
    other.end(.closed(.connectionLost))
    await wait(direct.results, "done") { !$0.isEmpty }
    XCTAssertEqual(direct.results.value, [.failure(.channelClosed)])
    pending.value.first?(Data(count: 64))
    await wait(secondEvents.state, "disconnected") { !$0.disconnects.isEmpty }
    XCTAssertEqual(direct.results.value.count, 1)
    XCTAssertEqual(events.state.value.disconnects, [.channelClosed])
    XCTAssertEqual(secondEvents.state.value.disconnects, [.channelClosed])
  }

  /// Callbacks never run on the caller's actor: here the main actor starts everything.
  @MainActor
  func testCallbacksRunOffTheCallersActor() async throws {
    let events = RecordedSession()
    let result = ConnectResult()
    let threads = Watched<[Bool]>([])
    SwiftEngine(connector: ScriptedConnector(ScriptedSession())).connect(Self.options, events: events) { outcome in
      threads.change { $0.append(Thread.isMainThread) }
      result.callback(outcome)
    }
    let connected = await result.results.until { !$0.isEmpty }
    XCTAssertTrue(connected)
    let session = try XCTUnwrap(result.session)
    let login = LoginResult()
    session.authenticate(user: "sam", password: "pw") { outcome in
      threads.change { $0.append(Thread.isMainThread) }
      login.done(outcome)
    }
    let done = await login.results.until { !$0.isEmpty }
    XCTAssertTrue(done)
    XCTAssertEqual(login.results.value, [.success(.loggedIn)])
    session.close()
    let ended = await events.state.until { !$0.disconnects.isEmpty }
    XCTAssertTrue(ended)
    XCTAssertEqual(threads.value, [false, false])
    XCTAssertEqual(events.state.value.mainThread, 0)
  }

  // MARK: Helpers

  #if os(macOS)
  /// An Ed25519 key file made with ssh-keygen (fictional comment).
  static func keyFile() throws -> Data {
    try XCTUnwrap(SwiftEngineKeyTests.made.first { $0.name == "ed25519-openssh" }).file
  }
  #endif

  /// A 2048-bit RSA public key blob.
  static func rsaBlob() -> Data {
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
    let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
    let der = [UInt8](SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil)! as Data)
    // PKCS#1 RSAPublicKey: SEQUENCE { INTEGER n, INTEGER e }; both are minimal positive DER integers, as mpints are.
    var reader = der[...]
    func length() -> Int {
      let first = Int(reader.removeFirst())
      guard first & 0x80 != 0 else { return first }
      return (0..<(first & 0x7F)).reduce(0) { value, _ in value << 8 | Int(reader.removeFirst()) }
    }
    func integer() -> Data {
      reader.removeFirst()
      let count = length()
      defer { reader = reader.dropFirst(count) }
      return Data(reader.prefix(count))
    }
    reader.removeFirst()
    _ = length()
    let modulus = integer(), exponent = integer()
    var blob = Data()
    blob.appendSSHString(Data("ssh-rsa".utf8))
    blob.appendSSHString(exponent)
    blob.appendSSHString(modulus)
    return blob
  }
}

#if !DISPATCH_RUSSH
/// A key file as another engine would hand it over (a build without russh has no other engine to parse one).
private final class ForeignEngineKey: EngineKey {
  let algorithm = "ssh-ed25519"
  let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  let fingerprint = "SHA256:fictional"
}
#endif

/// A host key decision given at once.
private struct Decided: MobileTransport.HostKeyTrust {
  let decision: HostKeyDecision
  init(_ decision: HostKeyDecision) { self.decision = decision }
  func evaluate(_ key: HostKeyInfo) async -> HostKeyDecision { decision }
}

/// Asks until cancelled, then rejects.
private final class Pending: MobileTransport.HostKeyTrust, @unchecked Sendable {
  let asked = Watched(false)
  func evaluate(_ key: HostKeyInfo) async -> HostKeyDecision {
    asked.change { $0 = true }
    let cancelled = Watched(false)
    await withTaskCancellationHandler {
      _ = await cancelled.waitForTest("the cancellation") { $0 }
    } onCancel: { cancelled.change { $0 = true } }
    return .reject
  }
}

/// An external signer as the app's `SSHKey.Signer`s answer, recording what it was asked.
final class Signer: @unchecked Sendable {
  let blob: Data
  let algorithm: SignatureAlgorithm
  let asked = Watched(0)
  let data = Watched<[Data]>([])
  private let answer: @Sendable (Data) -> Data?

  init(_ key: Curve25519.Signing.PrivateKey, answer: (@Sendable (Data) -> Data?)? = nil) {
    var blob = Data()
    blob.appendSSHString(Data("ssh-ed25519".utf8))
    blob.appendSSHString(key.publicKey.rawRepresentation)
    self.blob = blob
    algorithm = .ed25519
    self.answer = answer ?? { try? key.signature(for: $0) }
  }

  init(_ key: P256.Signing.PrivateKey, answer: (@Sendable (Data) -> Data?)? = nil) {
    var blob = Data()
    blob.appendSSHString(Data("ecdsa-sha2-nistp256".utf8))
    blob.appendSSHString(Data("nistp256".utf8))
    blob.appendSSHString(key.publicKey.x963Representation)
    self.blob = blob
    algorithm = .ecdsaP256
    self.answer = answer ?? { try? key.signature(for: $0).rawRepresentation }
  }

  /// The seam's `sign`: answers later, from another thread.
  var sign: @Sendable (Data, @escaping @Sendable (Data?) -> Void) -> Void {
    { [self] data, reply in
      asked.change { $0 += 1 }
      self.data.change { $0.append(data) }
      DispatchQueue.global().async { reply(self.answer(data)) }
    }
  }
}
