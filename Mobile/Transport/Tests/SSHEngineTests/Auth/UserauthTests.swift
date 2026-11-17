import SSHEngine
import XCTest

/// The userauth core's logins other than direct ones: the exact bytes it sends (hand-built encodings), the phase it
/// reports, each outcome, refusal, partial success, decline and cancellation.
final class UserauthTests: XCTestCase {
  typealias S = ServerAuth
  typealias C = ClientAuth

  // MARK: Password

  func testPasswordLogsIn() {
    let harness = AuthHarness()
    XCTAssertEqual(harness.phase, .serviceNotRequested)
    harness.start(.password(SecretBytes(utf8: "correct horse")))
    XCTAssertEqual(harness.sent, [C.serviceRequest])
    XCTAssertEqual(harness.phase, .serviceRequested)
    XCTAssertTrue(harness.auth.isAttemptInProgress)
    harness.server(S.accept)
    XCTAssertEqual(harness.sent, [C.serviceRequest, C.password("phone", "correct horse")])
    // The request holding the password went as a secret.
    XCTAssertEqual(harness.link.secretIndices, [1])
    XCTAssertEqual(harness.phase, .userauth(.password))
    XCTAssertEqual(harness.take(), [])
    harness.server(S.success)
    XCTAssertEqual(harness.take(), [.outcome(.success)])
    XCTAssertEqual(harness.phase, .connection)
    XCTAssertTrue(harness.auth.isAuthenticated)
    XCTAssertFalse(harness.auth.isAttemptInProgress)
    XCTAssertNil(harness.link.endedWith)
  }

  func testPasswordRefusalsAndPartialSuccess() {
    let harness = AuthHarness.accepted(.password(SecretBytes(utf8: "wrong")))
    harness.server(S.failure("publickey,keyboard-interactive,gssapi-with-mic"))
    XCTAssertEqual(harness.take(), [.outcome(.refused(remaining: [.publicKey, .keyboardInteractive], partialSuccess: false))])
    XCTAssertEqual(harness.phase, .userauth(.idle))
    // The next attempt goes at once: the service is accepted.
    harness.start(.password(SecretBytes(utf8: "first factor")))
    XCTAssertEqual(harness.sent.last, C.password("phone", "first factor"))
    harness.server(S.failure("keyboard-interactive", partial: true))
    XCTAssertEqual(harness.take(), [.outcome(.refused(remaining: [.keyboardInteractive], partialSuccess: true))])
    XCTAssertEqual(harness.sent.count, 3, "one SERVICE_REQUEST for the connection")
    // A refusal naming no method is a refusal (the russh engine took it for the connection's end).
    harness.start(.password(SecretBytes(utf8: "again")))
    harness.server(S.failure(""))
    XCTAssertEqual(harness.take(), [.outcome(.refused(remaining: [], partialSuccess: false))])
    XCTAssertNil(harness.link.endedWith)
  }

  func testPasswordChangeRequestEndsTheAttempt() {
    let harness = AuthHarness.accepted(.password(SecretBytes(utf8: "expired")))
    // A Latin-1 prompt ("Kennwort ändern"): display text, never a reason to fail.
    harness.server(S.passwordChange([0x4B, 0x65, 0x6E, 0x6E, 0x77, 0x6F, 0x72, 0x74, 0x20, 0xE4, 0x6E, 0x64, 0x65, 0x72, 0x6E]))
    XCTAssertEqual(harness.take(), [.outcome(.passwordChangeRequested)])
    XCTAssertEqual(harness.phase, .userauth(.idle))
    harness.start(.password(SecretBytes(utf8: "other")))
    harness.server(S.success)
    XCTAssertEqual(harness.take(), [.outcome(.success)])
  }

  func testAMalformedAnswerEndsTheConnection() {
    for answer: [UInt8] in [[52, 0], [51] + Raw.string("password") + [2], [51] + Raw.string("pass word") + [0],
                            [60] + Raw.string("prompt")] {
      let harness = AuthHarness.accepted(.password(SecretBytes(utf8: "pw")))
      harness.server(answer)
      guard case .protocolViolation(.malformed)? = harness.link.endedWith else {
        XCTFail("\(answer): \(String(describing: harness.link.endedWith))")
        continue
      }
      XCTAssertEqual(harness.take(), [.failed(harness.link.endedWith!)])
      XCTAssertThrows(SSHError.closed(.alreadyEnded)) { () throws(SSHError) in
        try harness.auth.start(user: "phone", credential: .password(SecretBytes(utf8: "pw")))
      }
    }
  }

  func testAnotherServiceIsRefused() {
    let harness = AuthHarness()
    harness.start(.password(SecretBytes(utf8: "pw")))
    harness.server([6] + Raw.string("ssh-connection"))
    XCTAssertEqual(harness.link.endedWith, .protocolViolation(.authentication(.unexpectedService)))
    XCTAssertEqual(harness.take(), [.failed(.protocolViolation(.authentication(.unexpectedService)))])
  }

  // MARK: Public key, queried

  func testAQueriedKeyIsSignedAfterPKOK() {
    for key in [TestKey.ed25519, .p256] {
      let harness = AuthHarness()
      let blob = key.publicKeyBlob
      let name = key.algorithm.rawValue
      harness.start(.publicKey(key, direct: false))
      XCTAssertEqual(harness.sent, [C.serviceRequest])
      harness.server(S.accept)
      XCTAssertEqual(harness.sent.last, C.query("phone", name, blob))
      XCTAssertEqual(harness.phase, .userauth(.publicKeyQuery))
      XCTAssertEqual(harness.take(), [], "never signed before PK_OK")
      harness.server(S.pkOK(name, blob))
      XCTAssertEqual(harness.phase, .userauth(.idle))
      guard let (question, data, algorithm) = harness.signRequest() else { return }
      XCTAssertEqual(algorithm, key.algorithm)
      XCTAssertEqual(data, C.signedData(sessionID: harness.link.sessionID, "phone", name, blob))
      harness.sign(key, question, data, algorithm)
      let request = harness.sent.last!
      let fields = C.signedFields("phone", name, blob)
      XCTAssertEqual(Array(request.prefix(fields.count)), fields)
      // The signature is the last field, and CryptoKit verifies it over exactly the RFC 4252 §7 bytes.
      let signature = try! WireReader.decode(Array(request.dropFirst(fields.count))) {
        (reader: inout WireReader) throws(WireError) in try reader.readString(limit: 4096)
      }
      XCTAssertTrue(key.verifies(signature, over: data), "\(name)")
      XCTAssertEqual(harness.phase, .userauth(.publicKeySigned))
      XCTAssertEqual(harness.take(), [], "no deadline for a queried key")
      harness.server(S.success)
      XCTAssertEqual(harness.take(), [.outcome(.success)])
      XCTAssertEqual(harness.sent.count, 3)
    }
  }

  func testAKeyTheServerDoesNotTakeIsNeverSigned() {
    let harness = AuthHarness.accepted(.publicKey(TestKey.ed25519, direct: false))
    harness.server(S.failure("password"))
    XCTAssertEqual(harness.take(), [.outcome(.refused(remaining: [.password], partialSuccess: false))])
  }

  func testPKOKMustNameWhatWasAsked() {
    let key = TestKey.ed25519
    for answer in [S.pkOK("ssh-ed25519", TestKey.otherEd25519.publicKeyBlob), S.pkOK("ecdsa-sha2-nistp256", key.publicKeyBlob)] {
      let harness = AuthHarness.accepted(.publicKey(key, direct: false))
      harness.server(answer)
      XCTAssertEqual(harness.link.endedWith, .protocolViolation(.authentication(.pkOKMismatch)))
      XCTAssertEqual(harness.take(), [.failed(.protocolViolation(.authentication(.pkOKMismatch)))])
    }
  }

  func testASignatureOfAnotherAlgorithmIsRefusedAndNothingIsSent() {
    let harness = AuthHarness.accepted(.publicKey(TestKey.ed25519, direct: false))
    harness.server(S.pkOK("ssh-ed25519", TestKey.ed25519.publicKeyBlob))
    guard let (question, data, _) = harness.signRequest() else { return }
    let count = harness.sent.count
    harness.auth.signed(question, signature: TestKey.p256.signatureBlob(for: data))
    harness.drain()
    XCTAssertEqual(harness.take(), [.failed(.invalidKey("the signature is not one of the key's algorithm"))])
    XCTAssertEqual(harness.sent.count, count)
    // Not a blob at all.
    harness.start(.publicKey(TestKey.ed25519, direct: false))
    harness.server(S.pkOK("ssh-ed25519", TestKey.ed25519.publicKeyBlob))
    guard let (again, _, _) = harness.signRequest() else { return }
    harness.auth.signed(again, signature: [1, 2, 3])
    harness.drain()
    XCTAssertEqual(harness.take(), [.failed(.invalidKey("the signature is not one of the key's algorithm"))])
    XCTAssertNil(harness.link.endedWith, "the session stays usable")
  }

  func testADeclinedSignatureSendsNothingAndTheSessionGoesOn() {
    let harness = AuthHarness.accepted(.publicKey(TestKey.ed25519, direct: false))
    harness.server(S.pkOK("ssh-ed25519", TestKey.ed25519.publicKeyBlob))
    guard let (question, _, _) = harness.signRequest() else { return }
    let count = harness.sent.count
    harness.auth.signingFailed(question, error: .cancelled)
    harness.drain()
    XCTAssertEqual(harness.take(), [.failed(.cancelled)])
    XCTAssertEqual(harness.sent.count, count)
    XCTAssertEqual(harness.phase, .userauth(.idle))
    // A late answer to the withdrawn question changes nothing, and is never taken for the next question.
    harness.start(.publicKey(TestKey.ed25519, direct: false))
    harness.server(S.pkOK("ssh-ed25519", TestKey.ed25519.publicKeyBlob))
    guard let (next, data, algorithm) = harness.signRequest() else { return }
    XCTAssertNotEqual(next, question)
    harness.auth.signed(question, signature: TestKey.ed25519.signatureBlob(for: data))
    harness.auth.signingFailed(question, error: .cancelled)
    harness.drain()
    XCTAssertEqual(harness.take(), [])
    harness.sign(.ed25519, next, data, algorithm)
    harness.server(S.success)
    XCTAssertEqual(harness.take(), [.outcome(.success)])
  }

  func testKeysTheEngineCannotUseAreRefusedAtTheStart() {
    let harness = AuthHarness()
    struct Blob: UserKey {
      let publicKeyBlob: [UInt8]
      func sign(_ data: [UInt8], algorithm: SignatureAlgorithm) async throws(SSHError) -> [UInt8] { [] }
    }
    XCTAssertThrows(SSHError.invalidKey("the public key blob is not a key the engine accepts")) { () throws(SSHError) in
      try harness.auth.start(user: "phone", credential: .publicKey(Blob(publicKeyBlob: Fixture.ed25519Blob + [0]), direct: true))
    }
    let certificate = Raw.string("ssh-ed25519-cert-v01@openssh.com") + Raw.string([UInt8](repeating: 0, count: 32))
    XCTAssertThrows(SSHError.unsupported("user certificates")) { () throws(SSHError) in
      try harness.auth.start(user: "phone", credential: .publicKey(Blob(publicKeyBlob: certificate), direct: false))
    }
    XCTAssertThrows(SSHError.unsupported("the key type ssh-dss")) { () throws(SSHError) in
      try harness.auth.start(user: "phone", credential: .publicKey(Blob(publicKeyBlob: Raw.string("ssh-dss")), direct: false))
    }
    XCTAssertEqual(harness.sent, [], "nothing starts")
    XCTAssertFalse(harness.auth.isAttemptInProgress)
  }

  // MARK: RSA's hash

  func testRSAPicksItsHashFromServerSigAlgs() {
    let cases: [(ServerExtensions, SignatureAlgorithm)] = [
      (ServerExtensions(), .rsaSHA512),
      (ServerExtensions(values: ["server-sig-algs": Array("ssh-ed25519,rsa-sha2-256".utf8)]), .rsaSHA256),
      (ServerExtensions(values: ["server-sig-algs": Array("rsa-sha2-256,rsa-sha2-512".utf8)]), .rsaSHA512),
      (ServerExtensions(values: ["server-sig-algs": Array("ssh-rsa".utf8)]), .rsaSHA512),
    ]
    for (extensions, expected) in cases {
      let harness = AuthHarness(extensions: extensions)
      harness.start(.publicKey(TestKey.rsa, direct: false))
      harness.server(S.accept)
      XCTAssertEqual(harness.sent.last, C.query("phone", expected.rawValue, Fixture.rsaBlob))
      harness.server(S.pkOK(expected.rawValue, Fixture.rsaBlob))
      guard let (question, data, algorithm) = harness.signRequest() else { return }
      XCTAssertEqual(algorithm, expected)
      XCTAssertEqual(data, C.signedData(sessionID: harness.link.sessionID, "phone", expected.rawValue, Fixture.rsaBlob))
      harness.sign(.rsa, question, data, algorithm)
      XCTAssertEqual(harness.sent.last, C.signedFields("phone", expected.rawValue, Fixture.rsaBlob)
        + Raw.string(TestKey.rsa.signatureBlob(for: data, algorithm: expected)))
      // A signature naming the other hash is refused.
      let other = AuthHarness(extensions: extensions)
      other.start(.publicKey(TestKey.rsa, direct: true))
      guard let (q, d, a) = other.signRequest() else { return }
      other.auth.signed(q, signature: TestKey.rsa.signatureBlob(for: d, algorithm: a == .rsaSHA512 ? .rsaSHA256 : .rsaSHA512))
      other.drain()
      XCTAssertEqual(other.take(), [.failed(.invalidKey("the signature is not one of the key's algorithm"))])
    }
  }

  func testRSAWaitsForTheExtensions() {
    // The extensions are not known yet: a direct RSA request waits (no round trip: the server sends its EXT_INFO
    // right behind NEWKEYS), with SERVICE_REQUEST already out.
    let harness = AuthHarness(extensions: nil)
    harness.start(.publicKey(TestKey.rsa, direct: true))
    XCTAssertEqual(harness.sent, [C.serviceRequest])
    XCTAssertEqual(harness.take(), [])
    harness.auth.linkProgressed()
    harness.drain()
    XCTAssertEqual(harness.take(), [], "still unknown")
    harness.server(S.extInfo([("server-sig-algs", "rsa-sha2-256")]))
    guard let (_, data, algorithm) = harness.signRequest() else { return }
    XCTAssertEqual(algorithm, .rsaSHA256)
    XCTAssertEqual(data, C.signedData(sessionID: harness.link.sessionID, "phone", "rsa-sha2-256", Fixture.rsaBlob))

    // No EXT_INFO at all: the accept is the first packet after NEWKEYS, so the extensions are known (empty) with it.
    let plain = AuthHarness(extensions: nil)
    plain.start(.publicKey(TestKey.rsa, direct: true))
    plain.server(S.accept)
    XCTAssertEqual(plain.signRequest()?.2, .rsaSHA512)

    // A queried RSA key waits the same way, then queries with the hash.
    let queried = AuthHarness(extensions: nil)
    queried.start(.publicKey(TestKey.rsa, direct: false))
    queried.server(S.extInfo([("server-sig-algs", "rsa-sha2-512")]))
    XCTAssertEqual(queried.sent, [C.serviceRequest])
    queried.server(S.accept)
    XCTAssertEqual(queried.sent.last, C.query("phone", "rsa-sha2-512", Fixture.rsaBlob))
  }

  func testCancellingWhileRSAWaitsLeavesTheSessionUsable() {
    let harness = AuthHarness(extensions: nil)
    harness.start(.publicKey(TestKey.rsa, direct: true))
    harness.auth.cancel()
    harness.drain()
    XCTAssertEqual(harness.take(), [.failed(.cancelled)])
    XCTAssertNil(harness.link.endedWith)
    harness.server(S.accept)
    XCTAssertEqual(harness.take(), [], "the extensions arriving later start nothing")
    XCTAssertEqual(harness.phase, .userauth(.idle))
  }

  // MARK: Keyboard-interactive

  func testKeyboardInteractiveRounds() {
    let harness = AuthHarness.accepted(.keyboardInteractive({ _ in nil }))
    XCTAssertEqual(harness.sent.last, C.keyboardInteractive("phone"))
    XCTAssertEqual(harness.phase, .userauth(.keyboardInteractive))
    harness.server(S.infoRequest(name: Array("Login".utf8), instruction: Array("Two factors".utf8),
                                 prompts: [(Array("Password: ".utf8), false), (Array("Code: ".utf8), true)]))
    XCTAssertEqual(harness.phase, .userauth(.idle), "no request outstanding while the user answers")
    guard let (question, challenge) = harness.promptRequest() else { return }
    XCTAssertEqual(challenge, KeyboardInteractiveChallenge(
      name: "Login", instruction: "Two factors", prompts: [.init(text: "Password: ", echo: false), .init(text: "Code: ", echo: true)]))
    harness.answer(question, ["hunter2", "123456"])
    XCTAssertEqual(harness.sent.last, C.infoResponse(["hunter2", "123456"]))
    XCTAssertEqual(harness.link.secretIndices, [2])
    XCTAssertEqual(harness.phase, .userauth(.keyboardInteractive))
    // A round with nothing to ask is answered at once, without asking.
    harness.server(S.infoRequest(prompts: []))
    XCTAssertEqual(harness.take(), [])
    XCTAssertEqual(harness.sent.last, C.infoResponse([]))
    XCTAssertEqual(harness.link.secretIndices, [2, 3])
    harness.server(S.success)
    XCTAssertEqual(harness.take(), [.outcome(.success)])
  }

  func testPromptTextsAreReadLenientlyAndSanitized() {
    let harness = AuthHarness.accepted(.keyboardInteractive({ _ in nil }))
    // Latin-1 ("für"), an escape sequence, a right-to-left override, a zero-width space, CR LF in the instruction.
    let prompt: [UInt8] = Array("Code f".utf8) + [0xFC] + Array("r \u{1B}[31mroot\u{202E}\u{200B}: ".utf8)
    harness.server(S.infoRequest(name: Array("PAM\r\n".utf8), instruction: Array("Line one\r\nLine\ttwo\u{0007}".utf8),
                                 prompts: [(prompt, false)]))
    guard let (question, challenge) = harness.promptRequest() else { return }
    XCTAssertEqual(challenge.name, "PAM ")
    XCTAssertEqual(challenge.instruction, "Line one\nLine two")
    XCTAssertEqual(challenge.prompts, [.init(text: "Code f\u{FFFD}r [31mroot: ", echo: false)])
    harness.answer(question, ["0"])
    XCTAssertNil(harness.link.endedWith, "the login goes on")
  }

  func testAWrongAnswerCountOrNoAnswerCancels() {
    for answers: [String]? in [nil, [], ["one", "two"]] {
      let harness = AuthHarness.accepted(.keyboardInteractive({ _ in nil }))
      harness.server(S.infoRequest(prompts: [(Array("Password: ".utf8), false)]))
      guard let (question, _) = harness.promptRequest() else { return }
      let count = harness.sent.count
      harness.answer(question, answers)
      XCTAssertEqual(harness.take(), [.failed(.cancelled)], "\(String(describing: answers))")
      XCTAssertEqual(harness.sent.count, count, "nothing more sent")
      XCTAssertNil(harness.link.endedWith)
      XCTAssertEqual(harness.phase, .userauth(.idle))
    }
  }

  func testRoundsAndPromptsAreBounded() {
    let harness = AuthHarness.accepted(.keyboardInteractive({ _ in nil }))
    for _ in 0..<Limits.keyboardInteractiveRounds { harness.server(S.infoRequest(prompts: [])) }
    XCTAssertNil(harness.link.endedWith)
    harness.server(S.infoRequest(prompts: []))
    XCTAssertEqual(harness.link.endedWith, .protocolViolation(.authentication(.tooManyRounds)))
    XCTAssertEqual(harness.take(), [.failed(.protocolViolation(.authentication(.tooManyRounds)))])

    let many = AuthHarness.accepted(.keyboardInteractive({ _ in nil }))
    many.server(S.infoRequest(prompts: Array(repeating: (Array("P".utf8), false), count: Limits.keyboardInteractivePrompts + 1)))
    XCTAssertEqual(many.link.endedWith, .protocolViolation(.malformed(MessageNumber(60), .tooMany(limit: Limits.keyboardInteractivePrompts))))
    // A count the bytes cannot hold is refused before anything is reserved.
    let huge = AuthHarness.accepted(.keyboardInteractive({ _ in nil }))
    huge.server([60] + Raw.string("") + Raw.string("") + Raw.string("") + Raw.u32(.max))
    XCTAssertEqual(huge.link.endedWith, .protocolViolation(.malformed(MessageNumber(60), .tooMany(limit: Limits.keyboardInteractivePrompts))))
  }

  func testAnAnswerWhileTheUserIsAskedEndsTheConnection() {
    let harness = AuthHarness.accepted(.keyboardInteractive({ _ in nil }))
    harness.server(S.infoRequest(prompts: [(Array("Password: ".utf8), false)]))
    _ = harness.take()
    harness.server(S.failure())
    guard case .protocolViolation(.unexpectedMessage(.userauthFailure, _))? = harness.link.endedWith else {
      return XCTFail("\(String(describing: harness.link.endedWith))")
    }
    XCTAssertEqual(harness.take(), [.failed(harness.link.endedWith!)])
  }

  // MARK: Banner and EXT_INFO

  func testBannersAreAcceptedAndDropped() {
    let harness = AuthHarness.accepted(.password(SecretBytes(utf8: "pw")))
    harness.server(S.banner(Array("Authorized use only\r\n".utf8)))
    harness.server(S.banner([0x57, 0x69, 0x6C, 0x6C, 0x6B, 0x6F, 0x6D, 0x6D, 0x65, 0x6E, 0xA0]))
    XCTAssertEqual(harness.take(), [])
    harness.server(S.failure())
    _ = harness.take()
    // Between attempts too (RFC 4252 §5.4: any time before USERAUTH_SUCCESS).
    harness.server(S.banner(Array("again".utf8)))
    XCTAssertNil(harness.link.endedWith)
    harness.server([53] + Raw.string("no language tag"))
    guard case .protocolViolation(.malformed(.userauthBanner, _))? = harness.link.endedWith else {
      return XCTFail("\(String(describing: harness.link.endedWith))")
    }
  }

  func testABannerBeforeTheAcceptIsRefused() {
    let harness = AuthHarness()
    harness.start(.password(SecretBytes(utf8: "pw")))
    harness.server(S.banner(Array("early".utf8)))
    guard case .protocolViolation(.unexpectedMessage(.userauthBanner, _))? = harness.link.endedWith else {
      return XCTFail("\(String(describing: harness.link.endedWith))")
    }
    XCTAssertEqual(harness.take(), [.failed(harness.link.endedWith!)])
  }

  /// RFC 8308 §2.4's second EXT_INFO comes while a request is outstanding, immediately before USERAUTH_SUCCESS (a
  /// failure after it is refused); while no request is (between attempts, while the user or the signer answers) it is
  /// refused.
  func testTheSecondExtInfosPlace() {
    let harness = AuthHarness()
    harness.server(S.serverSigAlgs)
    harness.start(.password(SecretBytes(utf8: "pw")))
    harness.server(S.accept)
    harness.server(S.extInfo([("publickey-hostbound@openssh.com", "0")]))
    XCTAssertNil(harness.link.endedWith)
    harness.server(S.success)
    XCTAssertEqual(harness.take(), [.outcome(.success)])

    let failed = AuthHarness.accepted(.password(SecretBytes(utf8: "pw")))
    failed.server(S.extInfo([]))
    failed.server(S.failure())
    guard case .protocolViolation(.unexpectedMessage(.userauthFailure, _))? = failed.link.endedWith else {
      return XCTFail("\(String(describing: failed.link.endedWith))")
    }
    XCTAssertEqual(failed.take(), [.failed(failed.link.endedWith!)])

    let idle = AuthHarness.accepted(.password(SecretBytes(utf8: "pw")))
    idle.server(S.failure())
    idle.server(S.extInfo([]))
    guard case .protocolViolation(.unexpectedMessage(.extInfo, _))? = idle.link.endedWith else {
      return XCTFail("\(String(describing: idle.link.endedWith))")
    }

    let signing = AuthHarness.accepted(.publicKey(TestKey.ed25519, direct: false))
    signing.server(S.pkOK("ssh-ed25519", TestKey.ed25519.publicKeyBlob))
    _ = signing.take()
    signing.server(S.extInfo([]))
    guard case .protocolViolation(.unexpectedMessage(.extInfo, _))? = signing.link.endedWith else {
      return XCTFail("\(String(describing: signing.link.endedWith))")
    }
    XCTAssertEqual(signing.take(), [.failed(signing.link.endedWith!)], "the open question ends with the connection")

    let third = AuthHarness()
    third.server(S.serverSigAlgs)
    third.start(.password(SecretBytes(utf8: "pw")))
    third.server(S.accept)
    third.server(S.extInfo([]))
    third.server(S.extInfo([]))
    XCTAssertEqual(third.link.endedWith, .protocolViolation(.tooManyExtInfo))
  }

  // MARK: One attempt at a time

  func testAttemptsRunOneAtATime() {
    let harness = AuthHarness()
    harness.start(.password(SecretBytes(utf8: "pw")))
    XCTAssertThrows(SSHError.usage(.authenticationInProgress)) { () throws(SSHError) in
      try harness.auth.start(user: "phone", credential: .keyboardInteractive({ _ in nil }))
    }
    harness.server(S.accept)
    harness.server(S.success)
    XCTAssertThrows(SSHError.usage(.alreadyAuthenticated)) { () throws(SSHError) in
      try harness.auth.start(user: "phone", credential: .password(SecretBytes(utf8: "pw")))
    }
    // After the login the auth core takes nothing: a userauth message is a protocol error.
    harness.auth.receive(InboundMessage(payload: S.success)!)
    XCTAssertNotNil(harness.link.endedWith)
  }

  // MARK: The server's attempt limit

  private static let tooMany = SSHError.closed(.byServer(.protocolError, description: "Too many authentication failures"))

  /// OpenSSH at MaxAuthTries: a DISCONNECT while an asked-for request waits is a refusal naming no method (the login
  /// failed, nothing more to try), whatever came before; the DISCONNECT's text stays the connection's end.
  func testADisconnectWhileARequestWaitsIsARefusal() {
    let harness = AuthHarness.accepted(.password(SecretBytes(utf8: "wrong")))
    _ = harness.take()
    harness.endConnection(Self.tooMany)
    XCTAssertEqual(harness.take(), [.outcome(.refused(remaining: [], partialSuccess: false))])
    XCTAssertEqual(harness.auth.endedWith, Self.tooMany)
  }

  /// Dropbear at its limit closes without a DISCONNECT: after a refusal on this connection, the close while the next
  /// request waits is a refusal too; before any refusal (or after a partial success only) it is a lost connection.
  func testACloseWhileARequestWaitsIsARefusalOnlyAfterARefusal() {
    let refused = AuthHarness.accepted(.password(SecretBytes(utf8: "wrong-1")))
    refused.server(S.failure())
    refused.start(.password(SecretBytes(utf8: "wrong-2")))
    _ = refused.take()
    refused.endConnection(.closed(.connectionLost))
    XCTAssertEqual(refused.take(), [.outcome(.refused(remaining: [], partialSuccess: false))])

    let fresh = AuthHarness.accepted(.password(SecretBytes(utf8: "right")))
    _ = fresh.take()
    fresh.endConnection(.closed(.connectionLost))
    XCTAssertEqual(fresh.take(), [.failed(.closed(.connectionLost))], "a drop before any refusal")

    let partial = AuthHarness.accepted(.password(SecretBytes(utf8: "first factor")))
    partial.server(S.failure("password", partial: true))
    partial.start(.password(SecretBytes(utf8: "second")))
    _ = partial.take()
    partial.endConnection(.closed(.connectionLost))
    XCTAssertEqual(partial.take(), [.failed(.closed(.connectionLost))], "a partial success is no refusal")
  }

  /// Every asked-for request counts (keyboard-interactive answers, a key's query, its signature after PK_OK); a direct
  /// key's request, a round with the user, the client's own close, a timeout and a violation never do.
  func testWhichWaitsTheLimitCovers() {
    let kbd = AuthHarness.accepted(.keyboardInteractive({ _ in nil }))
    kbd.server(S.infoRequest(prompts: [(Array("Password: ".utf8), false)]))
    guard let (question, _) = kbd.promptRequest() else { return }
    kbd.answer(question, ["wrong"])
    _ = kbd.take()
    kbd.endConnection(Self.tooMany)
    XCTAssertEqual(kbd.take(), [.outcome(.refused(remaining: [], partialSuccess: false))], "answers on the wire")

    let key = TestKey.ed25519
    let query = AuthHarness.accepted(.publicKey(key, direct: false))
    _ = query.take()
    query.endConnection(Self.tooMany)
    XCTAssertEqual(query.take(), [.outcome(.refused(remaining: [], partialSuccess: false))], "a query on the wire")

    let signed = AuthHarness.accepted(.password(SecretBytes(utf8: "wrong")))
    signed.server(S.failure())
    _ = signed.take()
    signed.start(.publicKey(key, direct: false))
    signed.server(S.pkOK(key.algorithm.rawValue, key.publicKeyBlob))
    guard let (keyQuestion, data, algorithm) = signed.signRequest() else { return }
    signed.sign(key, keyQuestion, data, algorithm)
    _ = signed.take()
    signed.endConnection(.closed(.connectionLost))
    XCTAssertEqual(signed.take(), [.outcome(.refused(remaining: [], partialSuccess: false))], "a signature on the wire")

    let direct = AuthHarness.accepted(.password(SecretBytes(utf8: "wrong")))
    direct.server(S.failure())
    _ = direct.take()
    direct.start(.publicKey(key, direct: true))
    guard let (directQuestion, directData, directAlgorithm) = direct.signRequest() else { return }
    direct.sign(key, directQuestion, directData, directAlgorithm)
    _ = direct.take()
    direct.endConnection(Self.tooMany)
    XCTAssertEqual(direct.take().last, .failed(Self.tooMany), "a direct request is never refused by the end")

    let prompting = AuthHarness.accepted(.keyboardInteractive({ _ in nil }))
    prompting.server(S.infoRequest(prompts: [(Array("Code: ".utf8), true)]))
    _ = prompting.take()
    prompting.endConnection(Self.tooMany)
    XCTAssertEqual(prompting.take(), [.failed(Self.tooMany)], "the user was still answering")

    for error: SSHError in [.closed(.byClient), .timedOut(.directAnswer), .protocolViolation(.tooManyExtInfo)] {
      let harness = AuthHarness.accepted(.password(SecretBytes(utf8: "wrong")))
      harness.server(S.failure())
      harness.start(.password(SecretBytes(utf8: "again")))
      _ = harness.take()
      harness.endConnection(error)
      XCTAssertEqual(harness.take(), [.failed(error)], "\(error)")
    }
  }

  func testAnswersAfterTheEndDoNothing() {
    let harness = AuthHarness.accepted(.keyboardInteractive({ _ in nil }))
    harness.server(S.infoRequest(prompts: [(Array("Password: ".utf8), false)]))
    guard let (question, _) = harness.promptRequest() else { return }
    harness.link.end(.closed(.connectionLost))
    harness.auth.connectionEnded(.closed(.connectionLost))
    harness.auth.connectionEnded(.closed(.byClient))
    harness.drain()
    XCTAssertEqual(harness.take(), [.failed(.closed(.connectionLost))], "once, with the first cause")
    harness.answer(question, ["late"])
    harness.auth.cancel()
    harness.auth.timerFired(.directAnswer)
    harness.drain()
    XCTAssertEqual(harness.take(), [])
    XCTAssertEqual(harness.auth.endedWith, .closed(.connectionLost))
  }

  // MARK: Cancellation

  func testCancellingBeforeTheRequestLeavesKeepsTheSession() {
    // Waiting for SERVICE_ACCEPT: only SERVICE_REQUEST is on the wire; its accept is taken later.
    let accept = AuthHarness()
    accept.start(.password(SecretBytes(utf8: "pw")))
    accept.auth.cancel()
    accept.drain()
    XCTAssertEqual(accept.take(), [.failed(.cancelled)])
    XCTAssertEqual(accept.phase, .serviceRequested)
    accept.server(S.accept)
    XCTAssertEqual(accept.sent, [C.serviceRequest])
    accept.start(.password(SecretBytes(utf8: "pw2")))
    XCTAssertEqual(accept.sent.last, C.password("phone", "pw2"), "the next attempt goes at once")

    // The signer is asked.
    let signing = AuthHarness.accepted(.publicKey(TestKey.ed25519, direct: false))
    signing.server(S.pkOK("ssh-ed25519", TestKey.ed25519.publicKeyBlob))
    _ = signing.take()
    signing.auth.cancel()
    signing.drain()
    XCTAssertEqual(signing.take(), [.failed(.cancelled)])
    XCTAssertNil(signing.link.endedWith)

    // The user is asked.
    let prompting = AuthHarness.accepted(.keyboardInteractive({ _ in nil }))
    prompting.server(S.infoRequest(prompts: [(Array("Password: ".utf8), false)]))
    _ = prompting.take()
    prompting.auth.cancel()
    prompting.drain()
    XCTAssertEqual(prompting.take(), [.failed(.cancelled)])
    XCTAssertNil(prompting.link.endedWith)
    XCTAssertEqual(prompting.phase, .userauth(.idle))
  }

  func testCancellingWithTheRequestOnTheWireEndsTheConnection() {
    let requests: [Credential] = [.password(SecretBytes(utf8: "pw")), .publicKey(TestKey.ed25519, direct: false),
                                  .keyboardInteractive({ _ in nil })]
    for credential in requests {
      let harness = AuthHarness.accepted(credential)
      XCTAssertNotEqual(harness.phase, .userauth(.idle))
      harness.auth.cancel()
      harness.drain()
      XCTAssertEqual(harness.take(), [.failed(.cancelled)])
      XCTAssertEqual(harness.link.endedWith, .cancelled)
      harness.auth.cancel()
      harness.drain()
      XCTAssertEqual(harness.take(), [], "idempotent")
    }
  }
}
