import CryptoKit
import Foundation
import MobileTransport
import XCTest
@testable import SSHEngine

/// Core/tests/engine.rs restated against MobileTransport's public API, so the same tests run on either engine
/// (`SSHTransportEngine.preferred`: the Swift engine, or with `DISPATCH_RUSSH=1 DISPATCH_SSH_ENGINE=russh swift test`
/// russh). Each connects to a
/// `ParityServer` (the scripted server on a loopback port) with `SSHConnection.connect` and asserts what the API shows
/// and what the server recorded. Holds (`ScriptedServer.Configuration.holdAt`) replace the Rust tests' proxies and
/// sleeps: the server keeps an answer back until the test releases it, and records which client messages came
/// meanwhile.
///
/// | engine.rs | Here |
/// | --- | --- |
/// | host_key_reports_keygen_fingerprint | testHostKeyReportsKeygenFingerprint |
/// | rejected_host_key_fails_connect_without_disconnect | testARejectedHostKeyFailsTheConnect ("no disconnected" is internal; the server sees no login) |
/// | a_closed_port_is_refused | testAClosedPortIsRefused |
/// | a_name_that_does_not_resolve_is_not_found | testANameThatDoesNotResolveIsNotFound |
/// | a_key_exchange_finishing_after_the_deadline_never_asks | testAKeyExchangeFinishingAfterTheDeadlineNeverAsks |
/// | password | testPassword |
/// | keyboard_interactive_two_rounds | testKeyboardInteractiveTwoRounds |
/// | keyboard_interactive_cancel | testKeyboardInteractiveCancel |
/// | key_files_of_every_type | testKeyFilesOfEveryType |
/// | wrong_or_missing_passphrase | testWrongOrMissingPassphrase |
/// | external_signer | testExternalSigner |
/// | exec_over_socketpair | testExecOverTheSocket (8 MiB each way, past the server's 2 MiB window) |
/// | shell_starts_and_echoes | testShellStartsAndEchoes |
/// | shell_resize_reaches_the_server | testShellResizeReachesTheServer (each change awaited at the server: `resize` returns at once) |
/// | rapid_resizes_arrive_in_order_and_the_last_wins | testRapidResizesArriveInOrderAndTheLastWins (no resize before the start: `shell` returns started) |
/// | shell_exit_status_propagates | testShellExitStatusPropagates |
/// | closing_the_socket_closes_the_shell_channel | testClosingTheShellClosesItsChannel |
/// | a_refused_pty_request_is_refused | testARefusedTerminalIsRefused |
/// | a_lost_connection_ends_the_shell_as_lost | testALostConnectionEndsTheShellAsLost |
/// | abi::keyboard_interactive_and_password_through_the_c_abi | not expressible: the C ABI (its logins: testPassword, testKeyboardInteractiveTwoRounds) |
/// | abi::shell_through_the_c_abi | the C ABI; what the API shows of it: testARefusedTerminalLeavesTheConnectionUsable |
/// | abi::a_direct_key_through_the_c_abi | not expressible: the C ABI (its logins: testARefusedDirectKeyFallsThroughToTheNextCredential) |
/// | abi::the_version_names_the_staged_russh | not expressible: the engine's version string is internal and russh's |
/// | many_rekeys_with_the_trusted_key_keep_the_stream_whole | testManyRekeysWithTheTrustedKeyKeepTheStreamWhole |
/// | rsa_keys_sign_with_sha2_512 | testRSAKeysSignWithSHA2512 |
/// | a_direct_key_login_is_signed_before_any_answer | testADirectKeyLoginIsSignedBeforeAnyAnswer |
/// | a_queried_key_login_waits_for_the_server | testAQueriedKeyLoginWaitsForTheServer |
/// | a_direct_signer_login_signs_before_any_answer | testADirectSignerLoginSignsBeforeAnyAnswer |
/// | a_refused_direct_key_falls_through_to_the_next_credential | testARefusedDirectKeyFallsThroughToTheNextCredential |
/// | a_declined_direct_signature_leaves_the_connection_usable | testADeclinedDirectSignatureEndsTheConnect (the API ends the connect at a declined signature: no next credential) |
/// | a_direct_rsa_key_signs_what_the_server_lists | testADirectRSAKeySignsWhatTheServerLists |
/// | bytes_written_before_the_exec_reply_reach_the_command | testBytesWrittenBeforeTheExecReplyReachTheCommand |
/// | output_before_the_exec_reply_is_kept | testOutputBeforeTheExecReplyIsKept |
/// | a_refused_exec_ends_as_refused | testARefusedExecEndsAsRefused |
/// | exec_abi::a_refused_exec_through_the_c_abi | not expressible: the C ABI ("exited runs once"); the refusal: testARefusedExecEndsAsRefused |
///
/// 35 Rust tests: 31 ported (4 of them in part, as noted), 4 not expressible. Beyond engine.rs:
/// testAnExitSignalReportsAs128, testServerRekeysDuringAShell.
final class EngineParityTests: XCTestCase {
  override class func tearDown() {
    ParityKeys.remove()
    super.tearDown()
  }

  // MARK: Connecting and the host key

  func testHostKeyReportsKeygenFingerprint() async throws {
    let server = try ParityServer.start(self)
    let connection = try await server.loggedIn()
    let asked = server.trust.asked.value
    XCTAssertEqual(asked.count, 1)
    XCTAssertEqual(connection.hostKey.algorithm, "ssh-ed25519")
    XCTAssertEqual(connection.hostKey.openSSH, server.openSSH)
    let tool = try KeyTool()
    defer { tool.remove() }
    try tool.write("host.pub", server.openSSH + "\n")
    XCTAssertEqual(connection.hostKey.fingerprint, try tool.fingerprint("host"))
    XCTAssertEqual(asked.first, connection.hostKey)
    await connection.close()
    XCTAssertEqual(connection.endReason, .channelClosed)
    XCTAssertFalse(connection.isActive)
    try await server.log().wait("the server seeing the end") { $0.ended }
  }

  func testARejectedHostKeyFailsTheConnect() async throws {
    let server = try ParityServer.start(self)
    let trust = RecordingTrust(expected: server.openSSH, decision: .reject)
    do {
      _ = try await server.connect([.password("s3cret")], trust: trust)
      XCTFail("connected")
    } catch let SSHTransportError.hostKeyRejected(info) {
      XCTAssertEqual(info, trust.asked.value.first)
      XCTAssertEqual(info.openSSH, server.openSSH)
    }
    let log = try await server.log().wait("the connection's end") { $0.ended }
    XCTAssertEqual(trust.asked.value.count, 1)
    XCTAssertEqual(log.received(MessageNumber.serviceRequest.rawValue), [], "nothing past the key exchange")
    XCTAssertEqual(log.logins, [])
  }

  func testAClosedPortIsRefused() async throws {
    let server = try ParityServer.start(self)
    let port = server.endpoint.port
    XCTAssertTrue(server.server.shutdown())
    let trust = RecordingTrust(expected: server.openSSH)
    await XCTAssertThrowsAsync(.connectFailed(.refused, host: "127.0.0.1", port: port)) {
      try await SSHConnection.connect(to: server.endpoint, credentials: [.password("s3cret")], trust: trust)
    }
    XCTAssertEqual(trust.asked.value.count, 0)
  }

  func testANameThatDoesNotResolveIsNotFound() async throws {
    // RFC 6761: .invalid never resolves.
    let trust = RecordingTrust(expected: "")
    await XCTAssertThrowsAsync(.connectFailed(.hostNotFound, host: "dispatch-test.invalid", port: 22)) {
      try await SSHConnection.connect(to: SSHEndpoint(host: "dispatch-test.invalid", username: "phone"),
                                      credentials: [.password("s3cret")], trust: trust)
    }
    XCTAssertEqual(trust.asked.value.count, 0)
  }

  /// The server's KEXINIT is held past the connect's deadline: the connect fails as the handshake's timeout, and once
  /// the exchange can go on nothing asks about the host key (whatever the engine does with the connection meanwhile).
  func testAKeyExchangeFinishingAfterTheDeadlineNeverAsks() async throws {
    let server = try ParityServer.start(self) { $0.holdAt = [MessageNumber.kexInit.rawValue] }
    await XCTAssertThrowsAsync(.timedOut("the SSH handshake")) {
      try await server.connect([.password("s3cret")], timeout: .milliseconds(300))
    }
    let connection = try await server.server.connection()
    connection.release()
    let log = try await connection.log.wait("the client leaving the connection") { $0.ended }
    XCTAssertEqual(server.trust.asked.value, [], "the host key was asked after the connect had failed")
    // russh sends its NEWKEYS before it decides about the key (on the server's NEWKEYS); nothing goes past it.
    XCTAssertEqual(log.received(MessageNumber.serviceRequest.rawValue), [], "nothing past the key exchange")
  }

  // MARK: Logins

  func testPassword() async throws {
    let server = try ParityServer.start(self)
    await XCTAssertThrowsAsync(.authenticationFailed(methods: ["publickey", "password", "keyboard-interactive"])) {
      try await server.connect([.password("wrong")])
    }
    let connection = try await server.connect([.password("wrong"), .password("s3cret")])
    XCTAssertEqual(connection.credential, 1)
    let log = try await server.log(1).value
    XCTAssertEqual(log.logins.map(\.method), ["password", "password"], "one connection, both tried")
    XCTAssertEqual(log.logins.map(\.answer), [51, 52])
    await connection.close()
  }

  func testKeyboardInteractiveTwoRounds() async throws {
    let server = try ParityServer.start(self)
    let asked = Recorder<MobileTransport.KeyboardInteractiveChallenge>()
    let connection = try await server.connect([.keyboardInteractive { challenge in
      asked.record(challenge)
      return [challenge.prompts.first?.text.hasPrefix("Password") == true ? "s3cret" : "123456"]
    }])
    let challenges = asked.all
    XCTAssertEqual(challenges.count, 2)
    XCTAssertEqual(challenges.first.map { [$0.name, $0.instruction] }, ["Login", "Two steps"])
    XCTAssertEqual(challenges.first?.prompts.map(\.text), ["Password: "])
    XCTAssertEqual(challenges.first?.prompts.map(\.echo), [false])
    XCTAssertEqual(challenges.last?.prompts.map(\.text), ["Code: "])
    XCTAssertEqual(challenges.last?.prompts.map(\.echo), [true])
    assertEqual(try await server.log().value.keyboardResponses, [["s3cret"], ["123456"]])
    await connection.close()
  }

  func testKeyboardInteractiveCancel() async throws {
    let server = try ParityServer.start(self)
    await XCTAssertThrowsAsync(.cancelled) {
      try await server.connect([.keyboardInteractive { _ in nil }])
    }
    let log = try await server.log().wait("the connection's end") { $0.ended }
    XCTAssertEqual(log.keyboardResponses, [], "a cancelled round sends no answers")
  }

  func testKeyFilesOfEveryType() async throws {
    let keys = try ParityKeys.shared()
    var script = ParityServer.script
    script.authorizedKeys = try ParityKeys.names.map(keys.blob)
    let server = try ParityServer.start(self, script: script)
    var index = 0
    for name in ParityKeys.names {
      for file in [name, name + "-encrypted"] {
        let key = try keys.key(file)
        XCTAssertEqual(key.fingerprint, try keys.fingerprint(file), file)
        let connection = try await server.connect([.key(key)])
        XCTAssertEqual(connection.credential, 0, file)
        let log = try await server.log(index).value
        XCTAssertEqual(log.logins.map(\.method), ["publickey-query", "publickey-signed"], file)
        XCTAssertEqual(log.signatures.map(\.accepted), [true], file)
        await connection.close()
        index += 1
      }
    }
  }

  func testWrongOrMissingPassphrase() throws {
    let keys = try ParityKeys.shared()
    for name in ["ed25519-encrypted", "ecdsa256-encrypted", "rsa-encrypted"] {
      for passphrase in [KeyTool.wrongPassphrase, nil] {
        XCTAssertThrowsError(try SSHKey.openSSH(keys.file(name), passphrase: passphrase), name) {
          XCTAssertEqual($0 as? SSHTransportError, .wrongPassphrase, "\(name) \(passphrase == nil ? "missing" : "wrong")")
        }
      }
    }
  }

  /// The Secure Enclave path: the engine asks for a raw signature and builds the SSH signature itself.
  func testExternalSigner() async throws {
    let ed25519 = Curve25519.Signing.PrivateKey(), p256 = P256.Signing.PrivateKey(), p384 = P384.Signing.PrivateKey()
    let keys: [(String, SSHKey, [UInt8])] = [
      ("ed25519", SSHKey(ed25519: ed25519), SignerKeys.ed25519Blob(ed25519.publicKey)),
      ("p256", SSHKey(p256: p256), SignerKeys.p256Blob(p256.publicKey)),
      ("p384", SSHKey(kind: .ecdsaP384, publicKeyBlob: Data(SignerKeys.p384Blob(p384.publicKey)), hardwareBacked: false) {
        try p384.signature(for: $0).rawRepresentation
      }, SignerKeys.p384Blob(p384.publicKey)),
    ]
    var script = ParityServer.script
    script.authorizedKeys = keys.map(\.2)
    let server = try ParityServer.start(self, script: script)
    for (index, (name, key, blob)) in keys.enumerated() {
      let connection = try await server.connect([.key(key)])
      let log = try await server.log(index).value
      XCTAssertEqual(log.signatures.map(\.keyBlob), [blob], name)
      XCTAssertEqual(log.signatures.map(\.accepted), [true], name)
      await connection.close()
    }
  }

  /// RSA signs rsa-sha2-512 (the server lists both SHA-2 algorithms), never ssh-rsa (SHA-1).
  func testRSAKeysSignWithSHA2512() async throws {
    let keys = try ParityKeys.shared()
    var script = ParityServer.script
    script.authorizedKeys = [try keys.blob("rsa")]
    let server = try ParityServer.start(self, script: script)
    let connection = try await server.connect([.key(try keys.key("rsa"))])
    assertEqual(try await server.log().value.verifiedAlgorithms, ["rsa-sha2-512"])
    await connection.close()
  }

  // MARK: Direct key logins

  /// The signed request leaves without an answer from the server: with the service accept (and all after it) held,
  /// the server verifies the signature, and the login succeeds once it is released. RSA signs rsa-sha2-512 (the
  /// EXT_INFO with `server-sig-algs` comes before the held accept).
  func testADirectKeyLoginIsSignedBeforeAnyAnswer() async throws {
    let keys = try ParityKeys.shared()
    for (name, algorithm) in [("ed25519", "ssh-ed25519"), ("ecdsa256", "ecdsa-sha2-nistp256"), ("rsa", "rsa-sha2-512")] {
      var script = ParityServer.script
      script.authorizedKeys = [try keys.blob(name)]
      let server = try ParityServer.start(self, script: script) { $0.holdAt = [MessageNumber.serviceAccept.rawValue] }
      let answers = Recorder<DirectKeyAnswer>()
      let key = try keys.key(name)
      let finished = Recorder<Bool>()
      let attempt = Task {
        defer { finished.record(true) }
        return try await server.connect([.directKey(key, answered: { answers.record($0) })])
      }
      let connection = try await server.server.connection()
      let log = try await connection.log.wait("\(name): the server verifying the signed request") { $0.signatures.count == 1 }
      XCTAssertTrue(log.holding, name)
      XCTAssertEqual(log.signatures.map(\.whileHeld), [true], "\(name): signed before the service accept")
      XCTAssertEqual(log.logins.map(\.method), ["publickey-signed"], "\(name): no query")
      XCTAssertEqual(finished.all, [], "\(name): answered while the answers were held")
      connection.release()
      let connected = try await attempt.value
      XCTAssertEqual(connected.credential, 0, name)
      XCTAssertEqual(answers.all, [.loggedIn], name)
      assertEqual(try await server.log().value.verifiedAlgorithms, [algorithm], name)
      await connected.close()
    }
  }

  /// Without `direct` nothing reaches the server's key checks while the service accept is held: the query waits for
  /// the accept, the signature for the PK_OK.
  func testAQueriedKeyLoginWaitsForTheServer() async throws {
    let keys = try ParityKeys.shared()
    var script = ParityServer.script
    script.authorizedKeys = [try keys.blob("ed25519")]
    let server = try ParityServer.start(self, script: script) { $0.holdAt = [MessageNumber.serviceAccept.rawValue] }
    let key = try keys.key("ed25519")
    let attempt = Task { try await server.connect([.key(key)]) }
    let connection = try await server.server.connection()
    try await connection.log.wait("the held service accept") { $0.holding }
    connection.release()
    let connected = try await attempt.value
    let log = connection.log.value
    let request = MessageNumber.userauthRequest.rawValue
    XCTAssertEqual(log.traffic.filter { $0.inbound && $0.number == request && $0.held }, [],
                   "a userauth request came while the accept was held")
    XCTAssertEqual(log.logins.map(\.method), ["publickey-query", "publickey-signed"])
    XCTAssertEqual(log.logins.map(\.answer), [60, 52])
    XCTAssertEqual(log.verifiedAlgorithms, ["ssh-ed25519"])
    await connected.close()
  }

  /// The external signer is asked as the request is written, before the server said anything about the key; the
  /// request goes once it signed.
  func testADirectSignerLoginSignsBeforeAnyAnswer() async throws {
    let ed25519 = Curve25519.Signing.PrivateKey(), p256 = P256.Signing.PrivateKey()
    let asked = Recorder<String>()
    let keys: [(String, SSHKey, [UInt8])] = [
      ("ed25519", SSHKey(kind: .ed25519, publicKeyBlob: Data(SignerKeys.ed25519Blob(ed25519.publicKey)), hardwareBacked: false) {
        asked.record("ed25519")
        return try ed25519.signature(for: $0)
      }, SignerKeys.ed25519Blob(ed25519.publicKey)),
      ("p256", SSHKey(kind: .ecdsaP256, publicKeyBlob: Data(SignerKeys.p256Blob(p256.publicKey)), hardwareBacked: false) {
        asked.record("p256")
        return try p256.signature(for: $0).rawRepresentation
      }, SignerKeys.p256Blob(p256.publicKey)),
    ]
    for (name, key, blob) in keys {
      var script = ParityServer.script
      script.authorizedKeys = [blob]
      let server = try ParityServer.start(self, script: script) { $0.holdAt = [MessageNumber.serviceAccept.rawValue] }
      let attempt = Task { try await server.connect([.directKey(key, answered: { _ in })]) }
      let connection = try await server.server.connection()
      let log = try await connection.log.wait("\(name): the server verifying the signed request") { $0.signatures.count == 1 }
      XCTAssertEqual(log.signatures.map(\.whileHeld), [true], name)
      XCTAssertEqual(asked.all.filter { $0 == name }.count, 1, name)
      connection.release()
      let connected = try await attempt.value
      XCTAssertEqual(connected.credential, 0, name)
      await connected.close()
    }
  }

  /// A direct key the server refuses is an ordinary failure, and the same connection goes on to the next credential: a
  /// queried key, another direct one, a password.
  func testARefusedDirectKeyFallsThroughToTheNextCredential() async throws {
    let keys = try ParityKeys.shared()
    var script = ParityServer.script
    script.authorizedKeys = [try keys.blob("ed25519")]
    let server = try ParityServer.start(self, script: script)
    let right = try keys.key("ed25519"), stranger = try keys.key("ecdsa256")
    let p384 = P384.Signing.PrivateKey()
    let unknown = SSHKey(kind: .ecdsaP384, publicKeyBlob: Data(SignerKeys.p384Blob(p384.publicKey)), hardwareBacked: false) {
      try p384.signature(for: $0).rawRepresentation
    }
    let answers = Recorder<DirectKeyAnswer>()
    let answered: @Sendable (DirectKeyAnswer) -> Void = { answers.record($0) }

    await XCTAssertThrowsAsync(.authenticationFailed(methods: ["publickey", "password", "keyboard-interactive"])) {
      try await server.connect([.directKey(stranger, answered: answered)])
    }
    var connection = try await server.connect([.directKey(stranger, answered: answered), .key(right)])
    XCTAssertEqual(connection.credential, 1)
    await connection.close()
    assertEqual(try await server.log(1).value.logins.map(\.method), ["publickey-signed", "publickey-query", "publickey-signed"])

    connection = try await server.connect([.directKey(unknown, answered: answered), .directKey(stranger, answered: answered),
                                           .directKey(right, answered: answered)])
    XCTAssertEqual(connection.credential, 2)
    await connection.close()
    assertEqual(try await server.log(2).value.signatures.map(\.accepted), [false, false, true])

    connection = try await server.connect([.directKey(stranger, answered: answered), .password("s3cret")])
    XCTAssertEqual(connection.credential, 1)
    await connection.close()
    XCTAssertEqual(answers.all, [.refused, .refused, .refused, .refused, .loggedIn, .refused])
  }

  /// A signer that declines (Face ID dismissed) before the server heard anything: the attempt is withdrawn and
  /// nothing goes for it, as the first request or later. Through the API a declined signature ends the connect
  /// (`cancelled`), so engine.rs' next login on the same connection is not reachable here.
  func testADeclinedDirectSignatureEndsTheConnect() async throws {
    let ed25519 = Curve25519.Signing.PrivateKey()
    let blob = SignerKeys.ed25519Blob(ed25519.publicKey)
    var script = ParityServer.script
    script.authorizedKeys = [blob]
    let server = try ParityServer.start(self, script: script)
    let declining = SSHKey(kind: .ed25519, publicKeyBlob: Data(blob), hardwareBacked: false) { _ in throw CancellationError() }
    for (index, first) in [true, false].enumerated() {
      let answers = Recorder<DirectKeyAnswer>()
      let direct = SSHCredential.directKey(declining, answered: { answers.record($0) })
      await XCTAssertThrowsAsync(.cancelled, "first \(first)") {
        try await server.connect(first ? [direct] : [.password("wrong"), direct])
      }
      XCTAssertEqual(answers.all, [.withdrawn], "first \(first)")
      let log = try await server.log(index).wait("the connection's end") { $0.ended }
      XCTAssertEqual(log.signatures, [], "first \(first): nothing went for the declined signature")
      XCTAssertEqual(log.logins.map(\.method), first ? [] : ["password"], "first \(first)")
    }
  }

  /// The server lists only rsa-sha2-256 in `server-sig-algs`: a direct RSA request signs with it, as a queried one
  /// does.
  func testADirectRSAKeySignsWhatTheServerLists() async throws {
    let keys = try ParityKeys.shared()
    var script = ParityServer.script
    script.publicKeyAlgorithms = ["ssh-ed25519", "rsa-sha2-256"]
    script.authorizedKeys = [try keys.blob("rsa")]
    let server = try ParityServer.start(self, script: script)
    let key = try keys.key("rsa")
    var connection = try await server.connect([.directKey(key, answered: { _ in })])
    await connection.close()
    assertEqual(try await server.log(0).value.verifiedAlgorithms, ["rsa-sha2-256"])
    connection = try await server.connect([.key(key)])
    await connection.close()
    assertEqual(try await server.log(1).value.verifiedAlgorithms, ["rsa-sha2-256"])
  }

  // MARK: Exec

  /// Output and stderr as sent, the status; then 8 MiB through `cat` each way, four times the server's window.
  func testExecOverTheSocket() async throws {
    let server = try ParityServer.start(self)
    let connection = try await server.loggedIn()
    let echo = try await connection.run("echo")
    XCTAssertEqual(echo.text, "hello")
    XCTAssertEqual(String(decoding: echo.stderr, as: UTF8.self), "warn")
    XCTAssertEqual(echo.status, 7)

    let payload = Data((0..<(8 << 20)).map { UInt8(truncatingIfNeeded: $0 % 251) })
    let cat = try await within(.seconds(60), "8 MiB through cat") { try await connection.run("cat", input: payload, limit: 16 << 20) }
    XCTAssertTrue(cat.stdout == payload, "echoed \(cat.stdout.count) of \(payload.count) bytes")
    XCTAssertEqual(cat.status, 0)
    let log = try await server.log().value
    XCTAssertEqual(log.commands, ["echo", "cat"])
    await connection.close()
  }

  /// The server never answers the exec request: what the caller writes at once reaches the command (it echoes it),
  /// and the output, all of it before any reply, reaches the caller; EOF ends it as usual.
  func testBytesWrittenBeforeTheExecReplyReachTheCommand() async throws {
    let server = try ParityServer.start(self)
    let connection = try await server.loggedIn()
    let exec = try await within(.seconds(5), "the exec without its reply") { try await connection.exec("noreply") }
    let output = OutputReader(exec)
    try await exec.write(Data("ping".utf8))
    assertEqual(try await output.read(until: "ping"), "ping")
    try await exec.finishInput()
    assertEqual(try await output.readToEnd(), Data("ping".utf8), "nothing after the echo")
    assertEqual(try await exec.exitStatus(), 0)
    assertEqual(try await server.log().value.sent(MessageNumber.channelSuccess.rawValue), [], "never answered")
    await connection.close()
  }

  /// Output the server sends before its success is kept, in order, ahead of the exit.
  func testOutputBeforeTheExecReplyIsKept() async throws {
    let server = try ParityServer.start(self)
    let connection = try await server.loggedIn()
    let exec = try await within(.seconds(5), "the exec") { try await connection.exec("early") }
    assertEqual(try await OutputReader(exec).readToEnd(), Data("early".utf8))
    assertEqual(try await exec.exitStatus(), 5)
    await connection.close()
  }

  /// A refused exec request still hands the socket over (it left before the refusal came), which then reads end of
  /// file; the exec ends refused with the engine's message, and the connection serves the next exec.
  func testARefusedExecEndsAsRefused() async throws {
    let server = try ParityServer.start(self)
    let connection = try await server.loggedIn()
    let exec = try await within(.seconds(5), "the exec") { try await connection.exec("refuse") }
    try? await exec.write(Data("hello".utf8))
    let output = OutputReader(exec)
    assertEqual(try await output.readToEnd(), Data())
    let refusal = SSHTransportError.commandFailed(status: -1, stderr: "the server refused the exec request")
    await XCTAssertThrowsAsync(refusal) { try await exec.exitStatus() }
    XCTAssertEqual(exec.refusal, refusal)
    XCTAssertEqual(exec.stderr, "")
    XCTAssertEqual(output.stderr, Data())
    assertEqual(try await connection.run("echo").text, "hello", "the connection stays up")
    await connection.close()
  }

  func testAnExitSignalReportsAs128() async throws {
    let server = try ParityServer.start(self)
    let connection = try await server.loggedIn()
    let result = try await connection.run("signal")
    XCTAssertEqual(result.text, "bye")
    XCTAssertEqual(result.status, 128)
    await connection.close()
  }

  // MARK: Rekeys

  /// The server re-exchanging after every 16 KiB it sends, with the host key it started with: each exchange passes the
  /// engine's pin, a rekey never asks, and the stream comes through whole. A 32 KiB window paces the input, so the
  /// exchanges fall between the stream's packets in both directions.
  func testManyRekeysWithTheTrustedKeyKeepTheStreamWhole() async throws {
    var script = ParityServer.script
    script.window = 32 * 1024
    script.maximumPacket = 16 * 1024
    let server = try ParityServer.start(self, script: script) { $0.rekeyAfterBytes = 16 * 1024 }
    let connection = try await server.loggedIn()
    let payload = Data((0..<(512 * 1024)).map { UInt8(truncatingIfNeeded: $0 % 251) })
    let cat = try await within(.seconds(30), "512 KiB through cat") { try await connection.run("cat", input: payload, limit: 1 << 20) }
    XCTAssertTrue(cat.stdout == payload, "echoed \(cat.stdout.count) of \(payload.count) bytes")
    XCTAssertEqual(cat.status, 0)
    XCTAssertEqual(server.trust.asked.value.count, 1, "a rekey never asks")
    // The last may still run: each one started completes.
    let log = try await server.log().wait("every rekey completing") { $0.exchanges == 1 + $0.rekeysStartedByServer }
    XCTAssertGreaterThanOrEqual(log.rekeysStartedByServer, 8, "\(log.rekeysStartedByServer) rekeys")
    XCTAssertTrue(connection.isActive)
    XCTAssertNil(connection.endReason)
    await connection.close()
  }

  /// A rekey the test starts while a shell is idle, and another while its output streams.
  func testServerRekeysDuringAShell() async throws {
    let server = try ParityServer.start(self)
    let connection = try await server.loggedIn()
    let shell = try await connection.shell(term: "xterm-256color", columns: 80, rows: 24)
    let output = OutputReader(shell)
    try await output.read(until: "$ ")
    let session = try await server.server.connection()
    session.startRekey()
    try await session.log.wait("the first rekey") { $0.exchanges == 2 }
    let line = String(repeating: "x", count: 100_000) + "\r"
    async let written: Void = shell.write(Data(line.utf8))
    session.startRekey()
    try await output.read(until: line, from: 2)
    try await written
    try await session.log.wait("the second rekey") { $0.exchanges == 3 }
    try await shell.write(Data("exit 0\r".utf8))
    try await output.readToEnd()
    assertEqual(try await shell.exitStatus(), 0)
    XCTAssertEqual(server.trust.asked.value.count, 1)
    await connection.close()
  }

  // MARK: Shells

  func testShellStartsAndEchoes() async throws {
    let server = try ParityServer.start(self)
    let connection = try await server.loggedIn()
    let shell = try await connection.shell(term: "xterm-256color", columns: 80, rows: 24)
    let output = OutputReader(shell)
    assertEqual(try await output.read(until: "$ "), "$ ")
    try await shell.write(Data("echo hi\r".utf8))
    assertEqual(try await output.read(until: "echo hi\r", from: 2), "echo hi\r")
    assertEqual(try await server.log().value.terminal, ["pty xterm-256color 80x24 0x0 modes=0", "shell"],
                   "no pixels, no modes, no env")
    await connection.close()
  }

  func testShellResizeReachesTheServer() async throws {
    let server = try ParityServer.start(self)
    let connection = try await server.loggedIn()
    let shell = try await connection.shell(term: "xterm-256color", columns: 80, rows: 24)
    try await OutputReader(shell).read(until: "$ ")
    // `resize` returns at once, and a size superseded before it went is skipped: each waits for the server here.
    let log = try await server.log()
    try await shell.resize(columns: 120, rows: 40)
    try await log.wait("the first window change") { $0.terminal.count == 3 }
    try await shell.resize(columns: 100, rows: 30)
    try await log.wait("the second window change") { $0.terminal.count == 4 }
    XCTAssertEqual(Array(log.value.terminal[2...]), ["resize 120x40 0x0", "resize 100x30 0x0"])
    await connection.close()
  }

  /// Back-to-back changes (a layout pass, then the keyboard) reach the server in order, and the last one wins.
  func testRapidResizesArriveInOrderAndTheLastWins() async throws {
    let server = try ParityServer.start(self)
    let connection = try await server.loggedIn()
    let shell = try await connection.shell(term: "xterm-256color", columns: 80, rows: 24)
    try await OutputReader(shell).read(until: "$ ")
    let log = try await server.log()
    try await shell.resize(columns: 81, rows: 25)
    try await log.wait("the first change") { $0.resizes.map { [$0.0, $0.1] } == [[81, 25]] }
    for step in 2...300 { try await shell.resize(columns: 80 + step, rows: 24 + step) }
    try await log.wait("the last change") { $0.resizes.last.map { [$0.0, $0.1] } == [380, 324] }
    // The same size again, then another: the repeat is never sent (equal to the last, or superseded).
    try await shell.resize(columns: 380, rows: 324)
    try await shell.resize(columns: 381, rows: 325)
    let seen = try await log.wait("the marker") { $0.resizes.last.map { [$0.0, $0.1] } == [381, 325] }.resizes
    XCTAssertTrue(zip(seen, seen.dropFirst()).allSatisfy { $0.0 < $1.0 }, "out of order or repeated: \(seen)")
    await connection.close()
  }

  func testShellExitStatusPropagates() async throws {
    let server = try ParityServer.start(self)
    let connection = try await server.loggedIn()
    let shell = try await connection.shell(term: "xterm-256color", columns: 80, rows: 24)
    let output = OutputReader(shell)
    try await output.read(until: "$ ")
    try await shell.write(Data("exit 3\r".utf8))
    assertEqual(try await output.readToEnd(), Data("$ exit 3\r".utf8), "the output ends with the channel")
    assertEqual(try await shell.exitStatus(), 3)
    XCTAssertTrue(connection.isActive)
    await connection.close()
  }

  func testClosingTheShellClosesItsChannel() async throws {
    let server = try ParityServer.start(self)
    let connection = try await server.loggedIn()
    let shell = try await connection.shell(term: "xterm-256color", columns: 80, rows: 24)
    try await OutputReader(shell).read(until: "$ ")
    await shell.close()
    try await server.log().wait("the server seeing the close") { $0.terminal.last == "close" }
    await XCTAssertThrowsAsync(.channelClosed, "closed by the caller before any status") { try await shell.exitStatus() }
    await XCTAssertThrowsAsync(.channelClosed) { try await shell.resize(columns: 90, rows: 30) }
    XCTAssertTrue(connection.isActive)
    await connection.close()
  }

  func testARefusedTerminalIsRefused() async throws {
    let server = try ParityServer.start(self)
    let connection = try await server.loggedIn()
    await XCTAssertThrowsAsync(.commandFailed(status: -1, stderr: "the server refused the terminal (pty-req)")) {
      try await connection.shell(term: "refused", columns: 80, rows: 24)
    }
    assertEqual(try await server.log().value.terminal, ["pty refused 80x24 0x0 modes=0"],
                   "no shell request after a refused pty-req")
    await connection.close()
  }

  /// engine.rs' C ABI shell test, as far as the API shows it: a refused terminal, then a shell on the same connection
  /// whose window changes arrive in order, and its exit status.
  func testARefusedTerminalLeavesTheConnectionUsable() async throws {
    let server = try ParityServer.start(self)
    let connection = try await server.loggedIn()
    await XCTAssertThrowsAsync(.commandFailed(status: -1, stderr: "the server refused the terminal (pty-req)")) {
      try await connection.shell(term: "refused", columns: 80, rows: 24)
    }
    let shell = try await connection.shell(term: "xterm-256color", columns: 80, rows: 24)
    let output = OutputReader(shell)
    try await output.read(until: "$ ")
    for columns in 101...132 { try await shell.resize(columns: columns, rows: 50) }
    let log = try await server.log()
    let seen = try await log.wait("the last window change") { $0.resizes.last.map { [$0.0, $0.1] } == [132, 50] }.resizes
    XCTAssertTrue(zip(seen, seen.dropFirst()).allSatisfy { $0.0 < $1.0 }, "out of order: \(seen)")
    try await shell.write(Data("exit 3\r".utf8))
    try await output.readToEnd()
    assertEqual(try await shell.exitStatus(), 3)
    await connection.close()
  }

  func testALostConnectionEndsTheShellAsLost() async throws {
    let server = try ParityServer.start(self)
    let connection = try await server.loggedIn()
    let shell = try await connection.shell(term: "xterm-256color", columns: 80, rows: 24)
    let output = OutputReader(shell)
    try await output.read(until: "$ ")
    await connection.close()
    try await output.readToEnd()
    await XCTAssertThrowsAsync(.channelClosed) { try await shell.exitStatus() }
    XCTAssertEqual(connection.endReason, .channelClosed)
  }
}
