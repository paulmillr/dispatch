import XCTest
@testable import SSHEngine

/// A `ClientTransport` wired to a `ScriptedServer` in memory, standing in for the driver: it moves bytes both ways
/// (server bytes in chunks of `chunk` to exercise the framer's partial reads), drains `poll` after every input, and
/// answers the host key question with `trust` (nil: leave it open).
final class TransportHarness {
  let client: ClientTransport
  let server: ScriptedServer
  /// Every event the client produced, in order.
  private(set) var events: [TransportEvent] = []
  var service = MessagePolicy.ServicePhase.serviceNotRequested
  var trust: Bool? = true
  /// Server bytes go to the client in chunks of this many (0: all at once).
  var chunk = 0
  private(set) var serverError: Error?
  /// Everything the server sent, in order (the mutation test replays it).
  private(set) var serverStream: [UInt8] = []

  static func options(_ algorithms: AlgorithmPolicy.Preferences = .standard, keepalive: Duration? = .seconds(15),
                      count: Int = 3) -> ConnectOptions {
    ConnectOptions(host: "test.invalid", keepaliveInterval: keepalive, keepaliveCountMax: count, algorithms: algorithms)
  }

  init(options: ConnectOptions = TransportHarness.options(), server: ScriptedServer = ScriptedServer(),
       seed: UInt64 = 0xC11E) throws {
    client = try ClientTransport(options: options, verifier: TestSignatureVerifier(), random: SeededRandom(seed: seed))
    self.server = server
  }

  /// Starts both sides and runs until nothing moves (the first exchange, normally).
  @discardableResult
  func connect() -> [TransportEvent] {
    client.start()
    server.start()
    return pump()
  }

  /// Moves bytes and drains events until nothing moves. Returns the events of this call.
  @discardableResult
  func pump(rounds: Int = 200) -> [TransportEvent] {
    let first = events.count
    for _ in 0..<rounds {
      var moved = false
      let fromClient = client.takeOutbound()
      if !fromClient.isEmpty, serverError == nil {
        moved = true
        do { try server.receive(fromClient) } catch { serverError = error }
      }
      let fromServer = server.takeOutbound()
      if !fromServer.isEmpty {
        moved = true
        serverStream += fromServer
        deliver(fromServer)
      }
      if drain() { moved = true }
      // Polling may queue bytes without an event (a re-exchange that was due).
      let queued = client.takeOutbound()
      if !queued.isEmpty, serverError == nil {
        moved = true
        do { try server.receive(queued) } catch { serverError = error }
      }
      if !moved { break }
    }
    return Array(events[first...])
  }

  /// Hands bytes to the client in `chunk`-sized reads, draining after each.
  func deliver(_ bytes: [UInt8]) {
    guard chunk > 0 else {
      client.receive(bytes)
      return
    }
    var offset = 0
    while offset < bytes.count {
      let end = min(bytes.count, offset + chunk)
      client.receive(Array(bytes[offset..<end]))
      offset = end
      drain()
    }
  }

  /// Polls until nil, answering the host key question. Whether anything came.
  @discardableResult
  func drain() -> Bool {
    var any = false
    var guardCount = 0
    while let event = client.poll(service: service) {
      any = true
      events.append(event)
      guardCount += 1
      precondition(guardCount < 100_000, "poll never returned nil")
      if case .hostKeyNeedsTrust = event, let trust { client.answerHostKey(trusted: trust) }
    }
    return any
  }

  /// The error of the `ended` event, if one came; fails the test when more than one did.
  func endReason(file: StaticString = #filePath, line: UInt = #line) -> SSHError? {
    let ends = events.compactMap { event -> SSHError? in
      if case .ended(let error) = event { return error }
      return nil
    }
    XCTAssertLessThanOrEqual(ends.count, 1, "ended more than once", file: file, line: line)
    if let last = events.last, case .ended = last {} else if !ends.isEmpty {
      XCTFail("ended was not the last event", file: file, line: line)
    }
    return ends.first
  }

  /// Messages delivered to the layers above.
  var messages: [InboundMessage] {
    events.compactMap { event in
      if case .message(let message) = event { return message }
      return nil
    }
  }

  var isEstablished: Bool { events.contains(.established) }

  /// Client payloads the server got with these message numbers.
  func serverReceived(_ numbers: Set<UInt8>) -> [[UInt8]] {
    server.received.filter { numbers.contains($0.first ?? 0) }
  }
}

extension SSHError {
  /// Whether this is `unexpectedMessage` for `number` (the context in it is not compared).
  func isUnexpected(_ number: MessageNumber) -> Bool {
    if case .protocolViolation(.unexpectedMessage(let got, _)) = self { return got == number }
    return false
  }
}
