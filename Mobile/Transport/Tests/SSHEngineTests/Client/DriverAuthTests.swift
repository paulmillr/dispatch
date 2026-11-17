import CryptoKit
import Foundation
import XCTest
@testable import SSHEngine

/// Logins through the driver, in memory: outcomes, one attempt at a time, the signer and the prompt run outside the
/// core, a direct login pipelined behind SERVICE_REQUEST, its answer deadline (the signer's time not counted), and
/// cancellation at each stage of an attempt.
final class DriverAuthTests: XCTestCase {
  private let password = Credential.password(SecretBytes(utf8: "fictional"))

  private func options(directAnswer: Duration = .seconds(10)) -> ConnectOptions {
    var options = MemoryWorld.options
    options.directAnswer = directAnswer
    return options
  }

  func testAPasswordLogin() async throws {
    let world = await MemoryWorld.make()
    let session = try await world.connect()
    let outcome = try await session.authenticate(user: "phone", with: password)
    XCTAssertEqual(outcome, .success)
    await assertThrows(.usage(.alreadyAuthenticated), "logged in twice") {
      try await session.authenticate(user: "phone", with: password)
    }
    await session.close()
  }

  func testARefusalThenAnotherCredentialOnTheSameConnection() async throws {
    let script = ServerScript()
    script.login = { request in
      request.method == "password" ? [[51] + Raw.string("publickey,keyboard-interactive") + [1]] : ServerScript.acceptEverything(request)
    }
    let world = await MemoryWorld.make(script: script)
    let session = try await world.connect()
    let refused = try await session.authenticate(user: "phone", with: password)
    XCTAssertEqual(refused, .refused(remaining: [.publicKey, .keyboardInteractive], partialSuccess: true))
    let key = try cryptoKitEd25519()
    let outcome = try await session.authenticate(user: "phone", with: .publicKey(key, direct: false))
    XCTAssertEqual(outcome, .success)
    let requests = await world.peer.received.numbered(50).compactMap(UserauthRequest.parse)
    XCTAssertEqual(requests.map(\.method), ["password", "publickey", "publickey"])
    XCTAssertEqual(requests.map(\.signed), [false, false, true], "queried, then signed after PK_OK")
    await session.close()
  }

  func testAttemptsRunOneAtATime() async throws {
    let script = ServerScript()
    script.login = { _ in [] }
    let world = await MemoryWorld.make(script: script)
    let session = try await world.connect()
    let first = Task { [password] in try await session.authenticate(user: "phone", with: password) }
    _ = await world.peer.waitFor { !$0.numbered(50).isEmpty }
    await assertThrows(.usage(.authenticationInProgress), "two attempts at once") {
      try await session.authenticate(user: "phone", with: password)
    }
    await session.close()
    let failure = await first.sshError
    XCTAssertEqual(failure, .closed(.byClient), "an attempt pending at the close ends with it")
  }

  /// The direct request leaves right behind SERVICE_REQUEST: the peer holds every byte (SERVICE_ACCEPT included)
  /// until it has the signed request, so a client that waited for the accept would never log in.
  func testADirectLoginIsPipelined() async throws {
    for key in [try cryptoKitEd25519(), try cryptoKitP256()] {
      let world = await MemoryWorld.make()
      let session = try await world.connect()
      await world.peer.setGate { received in
        received.numbered(50).contains { UserauthRequest.parse($0)?.signed == true }
      }
      let outcome = try await bounded(10, "the direct login") {
        try await session.authenticate(user: "phone", with: .publicKey(key, direct: true))
      }
      XCTAssertEqual(outcome, .success)
      let upper = await world.peer.received.filter { ($0.first ?? 0) == 5 || ($0.first ?? 0) >= 50 }
      XCTAssertEqual(upper.map { $0.first ?? 0 }, [5, 50])
      await session.close()
    }
  }

  func testADirectRequestNobodyAnswersTimesOut() async throws {
    let script = ServerScript()
    script.login = { _ in [] }
    let world = await MemoryWorld.make(script: script)
    let session = try await world.connect(options(directAnswer: .milliseconds(300)))
    let key = try cryptoKitEd25519()
    await assertThrows(.timedOut(.directAnswer), "logged in") {
      try await session.authenticate(user: "phone", with: .publicKey(key, direct: true))
    }
    let end = await session.ended()
    XCTAssertEqual(end, .timedOut(.directAnswer))
  }

  /// The signer takes three times the direct-answer deadline: its time does not count.
  func testTheSignersTimeIsNotTheDirectAnswers() async throws {
    let world = await MemoryWorld.make()
    let session = try await world.connect(options(directAnswer: .milliseconds(200)))
    let slow = try cryptoKitEd25519(before: { () async throws(SSHError) in
      try? await Task.sleep(for: .milliseconds(600))
    })
    let outcome = try await session.authenticate(user: "phone", with: .publicKey(slow, direct: true))
    XCTAssertEqual(outcome, .success)
    await session.close()
  }

  func testCancellingWhileTheSignerDecidesKeepsTheSession() async throws {
    let world = await MemoryWorld.make()
    let session = try await world.connect()
    let asked = Signal()
    let stuck = try cryptoKitEd25519(before: { () async throws(SSHError) in
      asked.fire()
      await untilCancelled()
      throw .cancelled
    })
    let attempt = Task { try await session.authenticate(user: "phone", with: .publicKey(stuck, direct: true)) }
    await asked.wait()
    attempt.cancel()
    let failure = await attempt.sshError
    XCTAssertEqual(failure, .cancelled)
    // Nothing more went for the attempt: no USERAUTH_REQUEST at all (direct: it waited for the signature).
    let outcome = try await session.authenticate(user: "phone", with: password)
    XCTAssertEqual(outcome, .success)
    let methods = await world.peer.received.numbered(50).compactMap(UserauthRequest.parse).map(\.method)
    XCTAssertEqual(methods, ["password"])
    await session.close()
  }

  func testADecliningSignerCancelsTheAttemptOnly() async throws {
    let world = await MemoryWorld.make()
    let session = try await world.connect()
    let declining = try cryptoKitEd25519(before: { () async throws(SSHError) in throw .cancelled })
    for direct in [false, true] {
      await assertThrows(.cancelled, "logged in with a declined signature") {
        try await session.authenticate(user: "phone", with: .publicKey(declining, direct: direct))
      }
    }
    let outcome = try await session.authenticate(user: "phone", with: password)
    XCTAssertEqual(outcome, .success)
    await session.close()
  }

  func testKeyboardInteractive() async throws {
    let script = ServerScript()
    let answers = Locked<[[UInt8]]>([])
    script.infoResponse = { payload in
      answers.update { $0.append(payload) }
      return [[52]]
    }
    let world = await MemoryWorld.make(script: script)
    let session = try await world.connect()
    let challenges = Locked<[KeyboardInteractiveChallenge]>([])
    let outcome = try await session.authenticate(user: "phone", with: .keyboardInteractive { challenge in
      challenges.update { $0.append(challenge) }
      return [SecretBytes(utf8: "424242")]
    })
    XCTAssertEqual(outcome, .success)
    XCTAssertEqual(challenges.current, [KeyboardInteractiveChallenge(name: "login", instruction: "",
                                                                     prompts: [.init(text: "Code: ", echo: false)])])
    XCTAssertEqual(answers.current, [[61] + Raw.u32(1) + Raw.string("424242")])
    await session.close()
  }

  func testCancellingWhileAPromptIsOpenKeepsTheSession() async throws {
    let world = await MemoryWorld.make()
    let session = try await world.connect()
    let asked = Signal()
    let attempt = Task {
      try await session.authenticate(user: "phone", with: .keyboardInteractive { _ in
        asked.fire()
        await untilCancelled()
        return nil
      })
    }
    await asked.wait()
    attempt.cancel()
    let failure = await attempt.sshError
    XCTAssertEqual(failure, .cancelled)
    let outcome = try await session.authenticate(user: "phone", with: password)
    XCTAssertEqual(outcome, .success)
    await session.close()
  }

  func testAWrongNumberOfAnswersCancels() async throws {
    let world = await MemoryWorld.make()
    let session = try await world.connect()
    await assertThrows(.cancelled, "logged in") {
      try await session.authenticate(user: "phone", with: .keyboardInteractive { _ in [] })
    }
    let outcome = try await session.authenticate(user: "phone", with: password)
    XCTAssertEqual(outcome, .success)
    await session.close()
  }

  /// Once the request is on the wire, cancelling ends the connection: a late answer could not be told from the next
  /// attempt's.
  func testCancellingARequestOnTheWireEndsTheConnection() async throws {
    let script = ServerScript()
    script.login = { _ in [] }
    let world = await MemoryWorld.make(script: script)
    let session = try await world.connect()
    let attempt = Task { [password] in try await session.authenticate(user: "phone", with: password) }
    _ = await world.peer.waitFor { !$0.numbered(50).isEmpty }
    attempt.cancel()
    let failure = await attempt.sshError
    XCTAssertEqual(failure, .cancelled)
    let end = await session.ended()
    XCTAssertEqual(end, .cancelled)
    await assertThrows(.closed(.alreadyEnded), "a login after the end") {
      try await session.authenticate(user: "phone", with: password)
    }
  }

  func testTheConnectionEndingDuringALogin() async throws {
    let script = ServerScript()
    script.login = { _ in [] }
    let world = await MemoryWorld.make(script: script)
    let session = try await world.connect()
    let attempt = Task {
      try await session.authenticate(user: "phone", with: .publicKey(try cryptoKitEd25519(), direct: true))
    }
    _ = await world.peer.waitFor { !$0.numbered(50).isEmpty }
    await world.peer.reset()
    let failure = await attempt.sshError
    XCTAssertEqual(failure, .closed(.connectionLost), "a direct request the server never answered is the end, not a refusal")
    let end = await session.ended()
    XCTAssertEqual(end, .closed(.connectionLost))
  }

  func testAnRSAKeyFileSignsWithTheServersHash() async throws {
    // A fictional key made here; the scripted server takes any signature, so this checks the request's algorithm.
    let key = try TestKeyFiles.parse(type: "rsa", bits: 2048)
    var configuration = ScriptedServer.Configuration()
    configuration.extensions = [("server-sig-algs", Array("ssh-ed25519,rsa-sha2-256".utf8))]
    let world = await MemoryWorld.make(configuration: configuration)
    let session = try await world.connect()
    let outcome = try await session.authenticate(user: "phone", with: .publicKey(key, direct: true))
    XCTAssertEqual(outcome, .success)
    let request = await world.peer.received.numbered(50).compactMap(UserauthRequest.parse).first
    XCTAssertEqual(request?.algorithm, "rsa-sha2-256")
    await session.close()
  }
}
