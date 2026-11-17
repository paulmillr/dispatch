import SSHEngine
import XCTest

/// "Never crashes, never hangs, never grows": mutated server messages in each userauth phase, through the policy and
/// the auth core. Each ends either the connection with an error (and the attempt with it, once) or is a valid
/// transition; the events and the requests sent stay few; reaching the end is the proof that nothing trapped.
final class AuthMutationTests: XCTestCase {
  typealias S = ServerAuth
  static let iterationsPerPhase = 1500

  struct Phase {
    let name: String
    let make: () -> AuthHarness
    let seeds: [[UInt8]]
  }

  static let latin1Prompt: [UInt8] = [0x50, 0x61, 0xDF, 0x77, 0xF6, 0x72, 0x74, 0x3A, 0x20]

  static var phases: [Phase] { [
    Phase(name: "service requested", make: {
      let harness = AuthHarness()
      harness.start(.password(SecretBytes(utf8: "pw")))
      return harness
    }, seeds: [S.accept, S.serverSigAlgs, S.banner(Array("hi".utf8)), S.failure(), S.success]),
    Phase(name: "password", make: {
      let harness = AuthHarness()
      harness.start(.password(SecretBytes(utf8: "pw")))
      harness.server(S.accept)
      return harness
    }, seeds: [S.failure("publickey,password,keyboard-interactive", partial: true), S.success,
               S.passwordChange(latin1Prompt), S.banner(latin1Prompt), S.extInfo([("server-sig-algs", "rsa-sha2-256")])]),
    Phase(name: "publickey query", make: {
      let harness = AuthHarness()
      harness.start(.publicKey(TestKey.p256, direct: false))
      harness.server(S.accept)
      return harness
    }, seeds: [S.pkOK("ecdsa-sha2-nistp256", TestKey.p256.publicKeyBlob), S.failure(), S.success, S.banner([])]),
    Phase(name: "direct, before the accept", make: {
      let harness = AuthHarness(extensions: nil)
      harness.start(.publicKey(TestKey.rsa, direct: true))
      return harness
    }, seeds: [S.accept, S.serverSigAlgs, S.success, S.failure()]),
    Phase(name: "direct, signed", make: {
      let harness = AuthHarness()
      harness.start(.publicKey(TestKey.ed25519, direct: true))
      if let (question, data, algorithm) = harness.signRequest() { harness.sign(.ed25519, question, data, algorithm) }
      harness.server(S.accept)
      return harness
    }, seeds: [S.failure(), S.success, S.extInfo([("ping@openssh.com", "0")]), S.banner(Array("x".utf8))]),
    Phase(name: "keyboard-interactive", make: {
      let harness = AuthHarness()
      harness.start(.keyboardInteractive({ _ in nil }))
      harness.server(S.accept)
      return harness
    }, seeds: [S.infoRequest(name: Array("n".utf8), instruction: latin1Prompt, prompts: [(latin1Prompt, false), (Array("OTP".utf8), true)]),
               S.infoRequest(prompts: []), S.failure(), S.success, S.banner(latin1Prompt)]),
    Phase(name: "prompting", make: {
      let harness = AuthHarness()
      harness.start(.keyboardInteractive({ _ in nil }))
      harness.server(S.accept)
      harness.server(S.infoRequest(prompts: [(Array("Password: ".utf8), false)]))
      return harness
    }, seeds: [S.banner(Array("b".utf8)), S.failure(), S.infoRequest(prompts: [])]),
    Phase(name: "between attempts", make: {
      let harness = AuthHarness()
      harness.start(.password(SecretBytes(utf8: "pw")))
      harness.server(S.accept)
      harness.server(S.failure())
      return harness
    }, seeds: [S.banner(Array("b".utf8)), S.success, S.accept]),
  ] }

  func testMutatedServerMessagesInEveryPhase() {
    let random = SeededRandom(seed: 0xA17C_0DE5)
    for phase in Self.phases {
      var errors = 0
      var transitions = 0
      for _ in 0..<Self.iterationsPerPhase {
        let harness = phase.make()
        var events = harness.take()
        // Two messages: a mutated one, and (if the connection is still up) another, after answering any question.
        for step in 0..<2 where harness.link.endedWith == nil {
          let seed = phase.seeds[random.below(phase.seeds.count)]
          harness.server(step == 0 || random.below(2) == 0 ? MutationTests.mutate(seed, random) : seed)
          let new = harness.take()
          events += new
          answerQuestions(new, harness, random)
          events += harness.take()
        }
        XCTAssertLessThanOrEqual(events.count, 10, phase.name)
        XCTAssertLessThanOrEqual(harness.sent.count, 8, phase.name)
        let finished = events.filter { if case .finished = $0 { true } else { false } }.count
        XCTAssertLessThanOrEqual(finished, 1, "\(phase.name): one end per attempt")
        if let end = harness.link.endedWith {
          errors += 1
          XCTAssertEqual(harness.auth.endedWith, end, phase.name)
          XCTAssertFalse(harness.auth.isAttemptInProgress, "\(phase.name): the attempt ended with the connection")
          XCTAssertThrows(SSHError.closed(.alreadyEnded)) { () throws(SSHError) in
            try harness.auth.start(user: "phone", credential: .password(SecretBytes(utf8: "pw")))
          }
        } else {
          transitions += 1
          // A valid state: the phase is one the policy knows, and an attempt in progress waits for something.
          if harness.auth.isAuthenticated { XCTAssertEqual(harness.phase, .connection, phase.name) }
        }
      }
      XCTAssertGreaterThan(errors, 0, phase.name)
      XCTAssertGreaterThan(transitions, 0, phase.name)
    }
  }

  /// Answers an open question the way a driver might: sign, decline, answer, or a wrong count.
  private func answerQuestions(_ events: [AuthEvent], _ harness: AuthHarness, _ random: SeededRandom) {
    for event in events {
      switch event {
      case .sign(let question, let data, let algorithm):
        if random.below(3) == 0 {
          harness.auth.signingFailed(question, error: .cancelled)
        } else {
          let key: TestKey = algorithm == .ecdsaP256 ? .p256 : algorithm == .ed25519 ? .ed25519 : .rsa
          harness.auth.signed(question, signature: key.signatureBlob(for: data, algorithm: algorithm))
        }
      case .prompt(let question, let challenge):
        let count = random.below(3) == 0 ? challenge.prompts.count + 1 : challenge.prompts.count
        harness.auth.answered(question, with: (0..<count).map { _ in SecretBytes(utf8: "answer") })
      case .timer, .finished:
        break
      }
    }
    harness.drain()
  }
}
