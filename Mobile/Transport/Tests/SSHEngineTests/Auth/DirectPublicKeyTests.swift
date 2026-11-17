import SSHEngine
import XCTest

/// Direct public key logins (docs/ios.md, Transport): the signed request without the query, pipelined right behind
/// SERVICE_REQUEST as the connection's first request; the `.directAnswer` timer from when the request left; the
/// connection's end while it is pending; and the server orders of `Core/tests/hostile.rs`.
final class DirectPublicKeyTests: XCTestCase {
  typealias S = ServerAuth
  typealias C = ClientAuth

  static let deadline = Duration.milliseconds(300)

  /// Starts a direct login with `key` on a new connection and answers the signer; the harness then has the signed
  /// request on the wire.
  func pipelined(_ key: TestKey = .ed25519, user: String = "phone") -> AuthHarness {
    let harness = AuthHarness(directAnswer: Self.deadline)
    harness.start(user, .publicKey(key, direct: true))
    guard let (question, data, algorithm) = harness.signRequest() else { return harness }
    harness.sign(key, question, data, algorithm)
    return harness
  }

  func testTheSignedRequestFollowsServiceRequestAtOnce() {
    for key in [TestKey.ed25519, .p256] {
      let harness = AuthHarness(directAnswer: Self.deadline)
      harness.start(.publicKey(key, direct: true))
      XCTAssertEqual(harness.sent, [C.serviceRequest], "SERVICE_REQUEST goes before the signer is done")
      XCTAssertEqual(harness.phase, .serviceRequested)
      guard let (question, data, algorithm) = harness.signRequest() else { return }
      XCTAssertEqual(data, C.signedData(sessionID: harness.link.sessionID, "phone", key.algorithm.rawValue, key.publicKeyBlob))
      harness.sign(key, question, data, algorithm)
      // No query, no wait for the accept: two payloads, back to back, before any answer.
      XCTAssertEqual(harness.sent.count, 2)
      let fields = C.signedFields("phone", key.algorithm.rawValue, key.publicKeyBlob)
      XCTAssertEqual(Array(harness.sent[1].prefix(fields.count)), fields)
      let signature = try! WireReader.decode(Array(harness.sent[1].dropFirst(fields.count))) {
        (reader: inout WireReader) throws(WireError) in try reader.readString(limit: 4096)
      }
      XCTAssertTrue(key.verifies(signature, over: data))
      // The deadline starts once the request left.
      XCTAssertEqual(harness.take(), [.timer(.schedule(.directAnswer, after: Self.deadline))])
      XCTAssertEqual(harness.phase, .serviceRequested)
      harness.server(S.accept)
      XCTAssertEqual(harness.phase, .userauth(.publicKeySigned))
      harness.server(S.success)
      XCTAssertEqual(harness.take(), [.timer(.cancel(.directAnswer)), .outcome(.success)])
      XCTAssertEqual(harness.phase, .connection)
      XCTAssertEqual(harness.sent.count, 2)
    }
  }

  /// A direct attempt that is not the connection's first: the service is accepted, so the signed request goes at
  /// once, still without the query.
  func testALaterDirectRequestGoesWithoutTheQuery() {
    let harness = AuthHarness(directAnswer: Self.deadline)
    harness.start(.password(SecretBytes(utf8: "pw")))
    harness.server(S.accept)
    harness.server(S.failure())
    _ = harness.take()
    harness.start(.publicKey(TestKey.ed25519, direct: true))
    XCTAssertEqual(harness.phase, .userauth(.idle))
    guard let (question, data, algorithm) = harness.signRequest() else { return }
    harness.sign(.ed25519, question, data, algorithm)
    XCTAssertEqual(harness.sent.count, 3)
    XCTAssertEqual(Array(harness.sent[2].prefix(5)), [50] + Raw.u32(5))
    XCTAssertEqual(harness.phase, .userauth(.publicKeySigned))
    XCTAssertEqual(harness.take(), [.timer(.schedule(.directAnswer, after: Self.deadline))])
    harness.server(S.failure("password"))
    XCTAssertEqual(harness.take(), [.timer(.cancel(.directAnswer)),
                                    .outcome(.refused(remaining: [.password], partialSuccess: false))])
  }

  /// The signer takes its time and the accept (with EXT_INFO) comes meanwhile: the request leaves once signed, and
  /// only then does its deadline start.
  func testTheAcceptMayComeWhileTheSignerWorks() {
    let harness = AuthHarness(directAnswer: Self.deadline)
    harness.start(.publicKey(TestKey.ed25519, direct: true))
    guard let (question, data, algorithm) = harness.signRequest() else { return }
    harness.server(S.serverSigAlgs)
    harness.server(S.accept)
    XCTAssertEqual(harness.phase, .userauth(.idle))
    XCTAssertEqual(harness.take(), [], "no deadline while the signer works")
    harness.sign(.ed25519, question, data, algorithm)
    XCTAssertEqual(harness.take(), [.timer(.schedule(.directAnswer, after: Self.deadline))])
    XCTAssertEqual(harness.phase, .userauth(.publicKeySigned))
    harness.server(S.extInfo([("publickey-hostbound@openssh.com", "0")]))
    harness.server(S.success)
    XCTAssertEqual(harness.take(), [.timer(.cancel(.directAnswer)), .outcome(.success)])
  }

  /// hostile.rs `a_late_accept_and_ext_info_while_the_direct_request_is_pending`: EXT_INFO before or after the held
  /// accept, or both, while the signed request is pending.
  func testALateAcceptAndExtInfoWhileTheRequestIsPending() {
    let orders = [[S.serverSigAlgs, S.accept], [S.accept, S.serverSigAlgs], [S.serverSigAlgs, S.accept, S.serverSigAlgs]]
    for held in orders {
      let harness = pipelined()
      for payload in held { harness.server(payload) }
      harness.server(S.success)
      XCTAssertNil(harness.link.endedWith, "\(held.count) payloads")
      XCTAssertEqual(harness.take(), [.timer(.schedule(.directAnswer, after: Self.deadline)), .timer(.cancel(.directAnswer)),
                                      .outcome(.success)])
    }
  }

  /// hostile.rs `a_refused_direct_request_before_the_accept_falls_through`: another key, refused once the accept
  /// came; the next credential on the same connection logs in.
  func testARefusedDirectRequestFallsThrough() {
    let harness = pipelined(.p256)
    harness.server(S.serverSigAlgs)
    harness.server(S.accept)
    harness.server(S.failure("publickey,password"))
    XCTAssertEqual(harness.take().last, .outcome(.refused(remaining: [.publicKey, .password], partialSuccess: false)))
    harness.start(.publicKey(TestKey.ed25519, direct: true))
    guard let (question, data, algorithm) = harness.signRequest() else { return }
    harness.sign(.ed25519, question, data, algorithm)
    harness.server(S.success)
    XCTAssertEqual(harness.take().last, .outcome(.success))
    XCTAssertEqual(harness.sent.count, 3, "one SERVICE_REQUEST, two signed requests, no query")
  }

  /// A server answering before its accept breaks the order it must keep: the policy refuses it.
  func testAnAnswerBeforeTheAcceptIsRefused() {
    let harness = pipelined()
    harness.server(S.success)
    guard case .protocolViolation(.unexpectedMessage(.userauthSuccess, _))? = harness.link.endedWith else {
      return XCTFail("\(String(describing: harness.link.endedWith))")
    }
    XCTAssertEqual(harness.take().suffix(2), [.timer(.cancel(.directAnswer)), .failed(harness.link.endedWith!)])
  }

  /// hostile.rs `a_connection_ending_before_the_direct_answer_does_not_hang`: the attempt ends with the connection's
  /// end, never as a refusal; before and after the accept.
  func testTheConnectionEndingWhilePendingIsNeverARefusal() {
    let ends: [SSHError] = [.closed(.connectionLost), .closed(.byServer(.byApplication, description: "bye"))]
    for end in ends {
      for accepted in [false, true] {
        let harness = pipelined()
        if accepted { harness.server(S.accept) }
        harness.link.end(end)
        harness.auth.connectionEnded(end)
        harness.drain()
        XCTAssertEqual(harness.take(), [.timer(.schedule(.directAnswer, after: Self.deadline)), .timer(.cancel(.directAnswer)),
                                        .failed(end)])
        // A late timer firing is stale.
        harness.auth.timerFired(.directAnswer)
        harness.drain()
        XCTAssertEqual(harness.take(), [])
        XCTAssertEqual(harness.link.endedWith, end, "the first end stands")
      }
    }
    // A DISCONNECT from the server, through the policy, ends it the same way.
    let harness = pipelined()
    harness.server([1] + Raw.u32(11) + Raw.string("") + Raw.string(""))
    XCTAssertNil(harness.link.endedWith, "DISCONNECT is the transport's: it reports the end")
    harness.auth.connectionEnded(.closed(.byServer(.byApplication, description: "")))
    harness.drain()
    XCTAssertEqual(harness.take().last, .failed(.closed(.byServer(.byApplication, description: ""))))
  }

  /// hostile.rs `a_direct_request_nobody_answers_ends_the_connection`: the timer fires, the core ends the
  /// connection with `timedOut(.directAnswer)`. A signer that takes longer than the deadline does not count.
  func testNoAnswerWithinTheDeadlineEndsTheConnection() {
    for acceptFirst in [false, true] {
      let harness = AuthHarness(directAnswer: Self.deadline)
      harness.start(.publicKey(TestKey.ed25519, direct: true))
      guard let (question, data, algorithm) = harness.signRequest() else { return }
      // The signer is slow: a firing now (a timer of another attempt) is stale, nothing is scheduled yet.
      harness.auth.timerFired(.directAnswer)
      if acceptFirst { harness.server(S.accept) }
      harness.drain()
      XCTAssertEqual(harness.take(), [])
      XCTAssertNil(harness.link.endedWith)
      harness.sign(.ed25519, question, data, algorithm)
      if !acceptFirst { harness.server(S.accept) }
      XCTAssertEqual(harness.take(), [.timer(.schedule(.directAnswer, after: Self.deadline))])
      harness.auth.timerFired(.keepalive)
      harness.auth.timerFired(.directAnswer)
      harness.drain()
      XCTAssertEqual(harness.link.endedWith, .timedOut(.directAnswer))
      XCTAssertEqual(SSHError.timedOut(.directAnswer).disconnectReason, .connectionLost)
      XCTAssertEqual(harness.take(), [.timer(.cancel(.directAnswer)), .failed(.timedOut(.directAnswer))])
      // The transport then reports the same end; nothing more happens.
      harness.auth.connectionEnded(.timedOut(.directAnswer))
      harness.drain()
      XCTAssertEqual(harness.take(), [])
    }
  }

  func testATimerFiringAfterTheAnswerIsStale() {
    let harness = pipelined()
    harness.server(S.accept)
    harness.server(S.failure())
    _ = harness.take()
    harness.auth.timerFired(.directAnswer)
    harness.drain()
    XCTAssertNil(harness.link.endedWith)
    XCTAssertEqual(harness.take(), [])
  }

  /// Declining sends nothing more for the attempt: SERVICE_REQUEST is already out, its accept is taken later, and
  /// the next attempt works as usual.
  func testADeclinedDirectSignatureSendsNothingMore() {
    let harness = AuthHarness(directAnswer: Self.deadline)
    harness.start(.publicKey(TestKey.ed25519, direct: true))
    guard let (question, _, _) = harness.signRequest() else { return }
    harness.auth.signingFailed(question, error: .cancelled)
    harness.drain()
    XCTAssertEqual(harness.take(), [.failed(.cancelled)])
    XCTAssertEqual(harness.sent, [C.serviceRequest])
    XCTAssertEqual(harness.phase, .serviceRequested)
    harness.start(.publicKey(TestKey.ed25519, direct: false))
    XCTAssertEqual(harness.sent, [C.serviceRequest], "a query waits for the accept")
    harness.server(S.accept)
    XCTAssertEqual(harness.sent.last, C.query("phone", "ssh-ed25519", TestKey.ed25519.publicKeyBlob))
  }

  /// Cancelling the task once the direct request is on the wire ends the connection; before (while signing), not.
  func testCancellingADirectAttempt() {
    let pending = pipelined()
    pending.auth.cancel()
    pending.drain()
    XCTAssertEqual(pending.link.endedWith, .cancelled)
    XCTAssertEqual(pending.take().suffix(2), [.timer(.cancel(.directAnswer)), .failed(.cancelled)])

    let signing = AuthHarness(directAnswer: Self.deadline)
    signing.start(.publicKey(TestKey.ed25519, direct: true))
    _ = signing.take()
    signing.auth.cancel()
    signing.drain()
    XCTAssertEqual(signing.take(), [.failed(.cancelled)])
    XCTAssertNil(signing.link.endedWith)
  }

  /// A PK_OK cannot answer a signed request: the policy refuses 60 for it.
  func testPKOKForASignedRequestIsRefused() {
    let harness = pipelined()
    harness.server(S.accept)
    harness.server(S.pkOK("ssh-ed25519", TestKey.ed25519.publicKeyBlob))
    guard case .protocolViolation(.unexpectedMessage(MessageNumber(60), _))? = harness.link.endedWith else {
      return XCTFail("\(String(describing: harness.link.endedWith))")
    }
  }

  /// The user name and session id are what the signature covers; another session id gives other bytes.
  func testTheSignedDataHoldsTheSessionID() {
    let sessionID = Array(0..<48).map(UInt8.init)
    let harness = AuthHarness(sessionID: sessionID)
    harness.start("ünïcode user", .publicKey(TestKey.ed25519, direct: true))
    guard let (_, data, _) = harness.signRequest() else { return }
    XCTAssertEqual(Array(data.prefix(52)), Raw.u32(48) + sessionID)
    XCTAssertEqual(data, C.signedData(sessionID: sessionID, "ünïcode user", "ssh-ed25519", TestKey.ed25519.publicKeyBlob))
  }
}
