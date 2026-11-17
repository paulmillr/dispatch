import XCTest
@testable import SSHEngine

/// The scripted server's login and channel layers in memory (`TransportHarness`, the engine's `ClientTransport` with
/// messages built by hand): what the parity suite cannot reach through the public API, chiefly a re-exchange the client
/// starts during a session, and the rule that no upper-layer message leaves between the server's KEXINIT and NEWKEYS.
final class ScriptedSessionTests: XCTestCase {
  private func loggedIn(_ configure: (inout ScriptedServer.Configuration) -> Void = { _ in }) throws -> TransportHarness {
    var configuration = ScriptedServer.Configuration()
    configuration.session = ParityServer.script
    configure(&configuration)
    let harness = try TransportHarness(server: ScriptedServer(configuration: configuration))
    harness.connect()
    XCTAssertTrue(harness.isEstablished)
    try harness.client.send([MessageNumber.serviceRequest.rawValue] + Raw.string("ssh-userauth"))
    harness.service = .serviceRequested
    harness.pump()
    XCTAssertEqual(harness.messages.last?.number, .serviceAccept)
    harness.service = .userauth(.password)
    try harness.client.send([MessageNumber.userauthRequest.rawValue] + Raw.string("phone") + Raw.string("ssh-connection")
      + Raw.string("password") + [0] + Raw.string("s3cret"))
    harness.pump()
    XCTAssertEqual(harness.messages.last?.number, .userauthSuccess)
    harness.service = .connection
    return harness
  }

  /// Opens a session channel (ours: 5) and starts `command`; returns the server's channel number.
  private func exec(_ command: String, on harness: TransportHarness) throws -> UInt32 {
    try harness.client.send([MessageNumber.channelOpen.rawValue] + Raw.string("session") + Raw.u32(5) + Raw.u32(1 << 20)
      + Raw.u32(32 * 1024))
    harness.pump()
    let confirmation = try XCTUnwrap(harness.messages.last)
    XCTAssertEqual(confirmation.number, .channelOpenConfirmation)
    XCTAssertEqual(Array(confirmation.payload[1..<5]), Raw.u32(5))
    let server = confirmation.payload[5..<9].reduce(0) { $0 << 8 | UInt32($1) }
    try harness.client.send([MessageNumber.channelRequest.rawValue] + Raw.u32(server) + Raw.string("exec") + [1]
      + Raw.string(command))
    harness.pump()
    XCTAssertEqual(harness.messages.last?.number, .channelSuccess)
    return server
  }

  private func data(_ bytes: [UInt8], to channel: UInt32) -> [UInt8] {
    [MessageNumber.channelData.rawValue] + Raw.u32(channel) + Raw.string(bytes)
  }

  /// What the client got as channel data, in order.
  private func echoed(_ harness: TransportHarness) -> [UInt8] {
    harness.messages.filter { $0.number == .channelData }.flatMap { $0.payload.dropFirst(9) }
  }

  /// The server's messages between each of its KEXINITs and its next NEWKEYS: transport messages only.
  private func assertNothingUpperDuringExchanges(_ log: ServerLog, file: StaticString = #filePath, line: UInt = #line) {
    var exchanging = false
    for item in log.traffic where !item.inbound {
      if item.number == MessageNumber.kexInit.rawValue { exchanging = true }
      if item.number == MessageNumber.newKeys.rawValue { exchanging = false }
      if exchanging, item.number >= 50 {
        XCTFail("message \(item.number) between the server's KEXINIT and NEWKEYS", file: file, line: line)
      }
    }
  }

  func testAClientRekeyDuringAStream() throws {
    let harness = try loggedIn()
    let channel = try exec("cat", on: harness)
    let first = [UInt8](repeating: 1, count: 20_000), second = [UInt8](repeating: 2, count: 20_000)
    try harness.client.send(data(first, to: channel))
    harness.client.timerFired(.rekey)
    // Held by the client until its exchange completed.
    try harness.client.send(data(second, to: channel))
    XCTAssertTrue(harness.pump().contains(.rekeyed))
    harness.pump()
    XCTAssertEqual(echoed(harness), first + second)
    XCTAssertEqual(harness.server.exchanges, 2)
    XCTAssertEqual(harness.server.log.value.rekeysStartedByServer, 0)
    XCTAssertEqual(harness.server.log.value.violations, [])
    assertNothingUpperDuringExchanges(harness.server.log.value)
    XCTAssertNil(harness.serverError)
  }

  /// Data the client sent before it saw the server's KEXINIT is echoed only after the server's NEWKEYS.
  func testEchoWaitsForTheServersExchange() throws {
    let harness = try loggedIn()
    let channel = try exec("cat", on: harness)
    harness.server.startRekey()
    // Reaches the server before its KEXINIT reaches the client.
    try harness.client.send(data(Array("crossing".utf8), to: channel))
    XCTAssertTrue(harness.pump().contains(.rekeyed))
    XCTAssertEqual(echoed(harness), Array("crossing".utf8))
    let log = harness.server.log.value
    XCTAssertEqual(log.traffic.filter { !$0.inbound }.suffix(4).map(\.number), [20, 31, 21, 94], "the echo after NEWKEYS")
    assertNothingUpperDuringExchanges(log)
    XCTAssertNil(harness.serverError)
  }

  /// `rekeyAfterBytes` in memory: the server's own exchanges fall between its output, and EOF ends `cat` with 0.
  func testServerRekeysAfterItsBytes() throws {
    let harness = try loggedIn { $0.rekeyAfterBytes = 4096 }
    let channel = try exec("cat", on: harness)
    var sent: [UInt8] = []
    for round in 0..<8 {
      let chunk = [UInt8](repeating: UInt8(round), count: 6000)
      sent += chunk
      try harness.client.send(data(chunk, to: channel))
      harness.pump()
    }
    try harness.client.send([MessageNumber.channelEOF.rawValue] + Raw.u32(channel))
    harness.pump()
    XCTAssertEqual(echoed(harness), sent)
    XCTAssertGreaterThanOrEqual(harness.server.log.value.rekeysStartedByServer, 8)
    XCTAssertEqual(harness.server.exchanges, 1 + harness.server.log.value.rekeysStartedByServer)
    let exit = harness.messages.first { $0.number == .channelRequest }
    XCTAssertEqual(exit?.payload, [MessageNumber.channelRequest.rawValue] + Raw.u32(5) + Raw.string("exit-status") + [0]
      + Raw.u32(0))
    XCTAssertEqual(harness.messages.suffix(2).map(\.number), [.channelEOF, .channelClose])
    assertNothingUpperDuringExchanges(harness.server.log.value)
  }

  /// The hold in memory: the service accept and all after it wait for `release`.
  func testAHeldAnswerWaitsForRelease() throws {
    var configuration = ScriptedServer.Configuration()
    configuration.session = ParityServer.script
    configuration.holdAt = [MessageNumber.serviceAccept.rawValue]
    let harness = try TransportHarness(server: ScriptedServer(configuration: configuration))
    harness.connect()
    try harness.client.send([MessageNumber.serviceRequest.rawValue] + Raw.string("ssh-userauth"))
    harness.service = .serviceRequested
    harness.pump()
    XCTAssertTrue(harness.server.log.value.holding)
    XCTAssertFalse(harness.messages.contains { $0.number == .serviceAccept })
    harness.server.release()
    harness.pump()
    XCTAssertEqual(harness.messages.last?.number, .serviceAccept)
    XCTAssertEqual(harness.server.log.value.sent(MessageNumber.serviceAccept.rawValue).map(\.held), [true])
  }
}
