import CryptoKit
import Foundation
import XCTest
@testable import SSHEngine

/// The network cases of `Core/tests/hostile.rs`, through the async driver and its in-memory scripted server. Every
/// hostile input has a typed end, and no connect, login, channel open or changed-key re-exchange is reported as a
/// success. (The key-file case in that file has no connection to drive; Swift refuses certificates by their type.)
final class DriverHostileTests: XCTestCase {
  private let password = Credential.password(SecretBytes(utf8: "fictional"))

  private func options(directAnswer: Duration = .seconds(10)) -> ConnectOptions {
    var options = MemoryWorld.options
    options.directAnswer = directAnswer
    return options
  }

  private static func extInfo(_ count: Int) -> [UInt8] {
    var writer = WireWriter(.extInfo, capacity: 5 + count * 14)
    writer.writeUInt32(UInt32(count))
    for index in 0..<count {
      writer.writeName(String(format: "x%05d", index))
      writer.writeString([])
    }
    return (try? writer.finish()) ?? []
  }

  private static var serverSigAlgs: [UInt8] {
    var writer = WireWriter(.extInfo, capacity: 96)
    writer.writeUInt32(1)
    writer.writeName(ServerExtensions.serverSignatureAlgorithmsName)
    writer.writeString("ssh-ed25519,ecdsa-sha2-nistp256,rsa-sha2-512,rsa-sha2-256")
    return (try? writer.finish()) ?? []
  }

  private static func authFailure() -> [UInt8] {
    [MessageNumber.userauthFailure.rawValue] + Raw.string("publickey,password") + [0]
  }

  /// The recursive certificate shape from `Core/tests/hostile.rs`. Swift never decodes past the type, and its KEX
  /// reply bound refuses the 2,000-level value before reserving space for it.
  private static func nestedCertificate(depth: Int) -> [UInt8] {
    var inner = Raw.string("a@b") + Raw.string([])
    let type = "ssh-ed25519-cert-v01@openssh.com"
    let signature = Raw.string("ssh-ed25519") + Raw.string([0])
    for _ in 0..<depth {
      var level = Raw.string(type) + Raw.string([]) + Raw.string([])
      level += [UInt8](repeating: 0, count: 8) + Raw.u32(1)
      level += Raw.string([]) + Raw.string([])
      level += [UInt8](repeating: 0, count: 8) + [UInt8](repeating: 0xFF, count: 8)
      level += Raw.string([]) + Raw.string([]) + Raw.string([])
      level += Raw.string(inner) + Raw.string(signature)
      inner = level
    }
    return inner
  }

  private func assertConnectFails(
    _ configuration: ScriptedServer.Configuration, as expected: SSHError,
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    let world = await MemoryWorld.make(configuration: configuration)
    let trustCalls = Locked(0)
    do {
      _ = try await world.connect(trust: { _ in trustCalls.update { $0 += 1 }; return true })
      XCTFail("the hostile handshake connected", file: file, line: line)
    } catch {
      XCTAssertEqual(error, expected, file: file, line: line)
    }
    XCTAssertEqual(trustCalls.current, 0, "an unproved key reached trust", file: file, line: line)
  }

  // MARK: Host key and pre-authentication bounds

  func testANestedCertificateHostKeyNeverReachesTrust() async {
    for (depth, expected) in [
      (9, SSHError.protocolViolation(.keyExchange(.hostKeyCertificate))),
      (2_000, SSHError.protocolViolation(.malformed(.kexECDHReply, .tooLong(limit: Limits.publicKeyBlobBytes)))),
    ] {
      var configuration = ScriptedServer.Configuration()
      configuration.hostKeyBlob = Self.nestedCertificate(depth: depth)
      await assertConnectFails(configuration, as: expected)
    }
  }

  func testAHostKeyWithoutItsSignatureNeverReachesTrust() async {
    var configuration = ScriptedServer.Configuration()
    configuration.hostKeyBlob = ServerHostKey.ed25519(seed: 0x62).publicBlob
    await assertConnectFails(configuration, as: .protocolViolation(.keyExchange(.invalidSignature)))
  }

  func testTwoMaximumExtInfosAreBoundedAndAThirdEndsTheLogin() async throws {
    var configuration = ScriptedServer.Configuration()
    configuration.extensions = (0..<Limits.extInfoExtensions).map { ("a\($0)", [UInt8]()) }
    let script = ServerScript()
    script.login = { _ in [] }
    let world = await MemoryWorld.make(script: script, configuration: configuration)
    let session = try await world.connect()
    let attempt = Task { [password] in try await session.authenticate(user: "phone", with: password) }
    _ = await world.peer.waitFor { !$0.numbered(MessageNumber.userauthRequest.rawValue).isEmpty }

    await world.peer.send(Self.extInfo(Limits.extInfoExtensions))
    await world.peer.send(Self.extInfo(0))

    let expected = SSHError.protocolViolation(.tooManyExtInfo)
    let attemptError = await attempt.sshError
    let ended = await session.ended()
    XCTAssertEqual(attemptError, expected, "the login was not reported as successful")
    XCTAssertEqual(ended, expected)
  }

  func testAnExtInfoCountPastItsInputEndsBeforeAllocating() async throws {
    var configuration = ScriptedServer.Configuration()
    configuration.extInfo = false
    let world = await MemoryWorld.make(configuration: configuration)
    let session = try await world.connect()
    let payload = [MessageNumber.extInfo.rawValue] + Raw.u32(.max)
      + Raw.string(ServerExtensions.serverSignatureAlgorithmsName) + Raw.string("ssh-ed25519")
    await world.peer.send(payload)

    let expected = SSHError.protocolViolation(.malformed(.extInfo, .tooMany(limit: Limits.extInfoExtensions)))
    let ended = await session.ended()
    XCTAssertEqual(ended, expected)
    await assertThrows(.closed(.alreadyEnded), "no login succeeded") {
      try await session.authenticate(user: "phone", with: self.password)
    }
  }

  func testAnOversizedPacketIsRefusedFromItsLengthAlone() async throws {
    let world = await MemoryWorld.make()
    let session = try await world.connect()
    await world.peer.sendRaw(Raw.u32(1 << 30))

    let expected = SSHError.protocolViolation(.packet(.lengthOutOfRange))
    let ended = await session.ended()
    XCTAssertEqual(ended, expected)
    let stats = await session.driver.stats
    XCTAssertLessThan(stats.bytesRead, 1 << 20, "the driver did not read the announced packet")
    await assertThrows(.closed(.alreadyEnded), "no login succeeded") {
      try await session.authenticate(user: "phone", with: self.password)
    }
  }

  // MARK: Channels

  func testAZeroMaximumPacketFailsExecAndShellWithoutOpeningEither() async throws {
    for shell in [false, true] {
      let script = ServerScript()
      script.maximumPacket = 0
      let world = await MemoryWorld.make(script: script)
      let session = try await world.loggedIn()
      let expected = SSHError.protocolViolation(.channel(.maximumPacketTooSmall))
      if shell {
        await assertThrows(expected, "the shell was not opened") {
          try await session.shell(term: "xterm-256color", size: TerminalSize(columns: 80, rows: 24))
        }
      } else {
        await assertThrows(expected, "the exec was not opened") { try await session.exec("cat") }
      }
      let ended = await session.ended()
      XCTAssertEqual(ended, expected)
    }
  }

  // MARK: Host key at every re-exchange

  func testRekeysWithTheSameKeyKeepTheDriverSession() async throws {
    let world = await MemoryWorld.make()
    let trustCalls = Locked(0)
    let session = try await world.connect(trust: { _ in trustCalls.update { $0 += 1 }; return true })
    let login = try await session.authenticate(user: "phone", with: password)
    XCTAssertEqual(login, .success)
    let channel = try await session.exec("cat")
    for round in 1...3 {
      await world.peer.startRekey()
      _ = try await bounded(10, "rekey \(round)") {
        await session.driver.waitForStats { $0.rekeys == round }
      }
      _ = await world.peer.waitFor {
        $0.numbered(MessageNumber.newKeys.rawValue).count >= round + 1
      }
      let bytes = Array("after rekey \(round)\n".utf8)
      try await channel.write(bytes)
      let echoed = try await channel.read()?.bytes
      XCTAssertEqual(echoed, bytes)
    }
    XCTAssertEqual(trustCalls.current, 1, "a rekey never asks for trust")
    await session.close()
  }

  func testARekeyWithAnotherKeyEndsBeforeItSucceeds() async throws {
    let world = await MemoryWorld.make()
    let trustCalls = Locked(0)
    let session = try await world.connect(trust: { _ in trustCalls.update { $0 += 1 }; return true })
    let login = try await session.authenticate(user: "phone", with: password)
    XCTAssertEqual(login, .success)
    let channel = try await session.exec("cat")
    await world.peer.setIdentity(.ed25519(seed: 0x63))
    await world.peer.startRekey()

    let expected = SSHError.hostKeyChangedAtRekey(.differentKey)
    let ended = await session.ended()
    let stats = await session.driver.stats
    let exit = await channel.exit()
    XCTAssertEqual(ended, expected)
    XCTAssertEqual(stats.rekeys, 0, "the changed-key rekey was not reported as successful")
    XCTAssertEqual(exit, .lost)
    XCTAssertEqual(trustCalls.current, 1, "a rekey never asks for trust")
  }

  func testARekeyWithAnotherAlgorithmEndsBeforeItSucceeds() async throws {
    let world = await MemoryWorld.make()
    let session = try await world.loggedIn()
    await world.peer.setIdentity(.ecdsaP256(seed: 0x64))
    await world.peer.startRekey()

    let expected = SSHError.hostKeyChangedAtRekey(.differentAlgorithm(trusted: .ed25519, presented: .ecdsaP256))
    let ended = await session.ended()
    let stats = await session.driver.stats
    XCTAssertEqual(ended, expected)
    XCTAssertEqual(stats.rekeys, 0, "the changed-algorithm rekey was not reported as successful")
  }

  func testAChangedKeyRekeyEndsAWriterWaitingBehindIt() async throws {
    let world = await MemoryWorld.make(capacity: 64 * 1024)
    let session = try await world.loggedIn()
    let channel = try await session.exec("cat")
    for round in 1...2 {
      await world.peer.startRekey()
      _ = try await bounded(10, "good rekey \(round)") {
        await session.driver.waitForStats { $0.rekeys == round }
      }
      _ = await world.peer.waitFor {
        $0.numbered(MessageNumber.newKeys.rawValue).count >= round + 1
      }
    }

    await world.peer.setIdentity(.ed25519(seed: 0x65))
    await world.peer.startRekey()
    let writing = Task { try await channel.write([UInt8](repeating: 0x2E, count: 4 * 1024 * 1024)) }
    let expected = SSHError.hostKeyChangedAtRekey(.differentKey)
    let ended = await session.ended()
    let writerError = await writing.sshError
    let stats = await session.driver.stats
    XCTAssertEqual(ended, expected)
    XCTAssertEqual(writerError, expected, "the writer did not remain suspended")
    XCTAssertEqual(stats.rekeys, 2, "only the two pinned rekeys succeeded")
  }

  // MARK: Direct public-key ordering

  func testAQueriedKeyWaitsForTheHeldServiceAccept() async throws {
    let world = await MemoryWorld.make()
    let session = try await world.connect()
    await world.peer.setGate { _ in false }
    let key = try cryptoKitEd25519()
    let attempt = Task { try await session.authenticate(user: "phone", with: .publicKey(key, direct: false)) }
    _ = await world.peer.waitFor { !$0.numbered(MessageNumber.serviceRequest.rawValue).isEmpty }
    try? await Task.sleep(for: .milliseconds(100))
    let authWasHeld = await world.peer.received.numbered(MessageNumber.userauthRequest.rawValue).isEmpty
    XCTAssertTrue(authWasHeld,
                  "a queried request went before SERVICE_ACCEPT")
    await world.peer.setGate(nil)
    let outcome = try await attempt.value
    XCTAssertEqual(outcome, .success)
    let requests = await world.peer.received.numbered(MessageNumber.userauthRequest.rawValue).compactMap(UserauthRequest.parse)
    XCTAssertEqual(requests.map(\.signed), [false, true])
    await session.close()
  }

  func testDirectKeyTakesLateAcceptAndExtInfoInEveryHostileOrder() async throws {
    let orders = [(before: [Self.serverSigAlgs], after: [[UInt8]]()),
                  (before: [[UInt8]](), after: [Self.serverSigAlgs]),
                  (before: [Self.serverSigAlgs], after: [Self.serverSigAlgs])]
    for order in orders {
      var configuration = ScriptedServer.Configuration()
      configuration.extInfo = false
      configuration.beforeServiceAccept = order.before
      configuration.afterServiceAccept = order.after
      let world = await MemoryWorld.make(configuration: configuration)
      let session = try await world.connect()
      await world.peer.setGate { received in
        received.numbered(MessageNumber.userauthRequest.rawValue).contains { UserauthRequest.parse($0)?.signed == true }
      }
      let outcome = try await bounded(10, "the held direct login") {
        try await session.authenticate(user: "phone", with: .publicKey(try cryptoKitEd25519(), direct: true))
      }
      XCTAssertEqual(outcome, .success, "before \(order.before.count), after \(order.after.count)")
      await session.close()
    }
  }

  func testARefusedDirectRequestBeforeTheAcceptFallsThrough() async throws {
    let right = try cryptoKitEd25519()
    let stranger = try cryptoKitP256()
    let script = ServerScript()
    script.login = { request in
      guard request.blob == right.publicKeyBlob else { return [Self.authFailure()] }
      return ServerScript.acceptEverything(request)
    }
    let world = await MemoryWorld.make(script: script)
    let session = try await world.connect()
    await world.peer.setGate { received in !received.numbered(MessageNumber.userauthRequest.rawValue).isEmpty }
    let refused = try await session.authenticate(user: "phone", with: .publicKey(stranger, direct: true))
    XCTAssertEqual(refused, .refused(remaining: [.publicKey, .password], partialSuccess: false))
    let accepted = try await session.authenticate(user: "phone", with: .publicKey(right, direct: true))
    XCTAssertEqual(accepted, .success)
    await session.close()
  }

  func testAConnectionEndingBeforeTheDirectAnswerDoesNotReportARefusalOrSuccess() async throws {
    let script = ServerScript()
    script.login = { _ in [] }
    let world = await MemoryWorld.make(script: script)
    let session = try await world.connect()
    let attempt = Task {
      try await session.authenticate(user: "phone", with: .publicKey(try cryptoKitEd25519(), direct: true))
    }
    _ = await world.peer.waitFor { !$0.numbered(MessageNumber.userauthRequest.rawValue).isEmpty }
    await world.peer.reset()
    let attemptError = await attempt.sshError
    let ended = await session.ended()
    XCTAssertEqual(attemptError, .closed(.connectionLost))
    XCTAssertEqual(ended, .closed(.connectionLost))
  }

  func testAnUnansweredDirectRequestTimesOutAfterTheSignerReturns() async throws {
    let script = ServerScript()
    script.login = { _ in [] }
    let world = await MemoryWorld.make(script: script)
    let session = try await world.connect(options(directAnswer: .milliseconds(200)))
    let slow = try cryptoKitEd25519(before: { () async throws(SSHError) in
      try? await Task.sleep(for: .milliseconds(400))
    })
    let started = ContinuousClock.now
    let attempt = Task { try await session.authenticate(user: "phone", with: .publicKey(slow, direct: true)) }
    let attemptError = await attempt.sshError
    let ended = await session.ended()
    XCTAssertEqual(attemptError, .timedOut(.directAnswer))
    XCTAssertGreaterThanOrEqual(started.duration(to: .now), .milliseconds(600), "signing time did not consume the answer deadline")
    XCTAssertEqual(ended, .timedOut(.directAnswer))
  }
}
