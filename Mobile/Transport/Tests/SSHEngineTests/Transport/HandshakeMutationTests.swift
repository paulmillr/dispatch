import XCTest
@testable import SSHEngine

/// "Never traps, never hangs": a deterministic mutation loop over everything a server sent in a recorded session (its
/// version line, KEXINIT, the reply, NEWKEYS, EXT_INFO, SERVICE_ACCEPT, channel data, a re-exchange of its own, more
/// data), replayed into a fresh client with the recording's seed, in random read sizes, then EOF. Whatever the
/// mutation, the client must end exactly once, with `ended` last, and `poll` must then return nil. Reaching the end
/// of the loop is the proof that no input traps.
final class HandshakeMutationTests: XCTestCase {
  static let iterations = 10_000
  static let clientSeed: UInt64 = 0xF022
  static let algorithms = AlgorithmPolicy.Preferences(keyExchange: [.curve25519], hostKey: [.ed25519],
                                                      cipher: [.chacha20Poly1305], mac: [])

  /// The client's side of the session, the same in the recording and every replay: trust the key, ask for the
  /// userauth service once established, and move to the connection phase at its accept.
  final class Replay {
    let client: ClientTransport
    var service = MessagePolicy.ServicePhase.serviceNotRequested
    var events: [TransportEvent] = []

    init() throws {
      client = try ClientTransport(options: TransportHarness.options(Self.algorithms), verifier: TestSignatureVerifier(),
                                   random: SeededRandom(seed: HandshakeMutationTests.clientSeed))
      client.start()
    }

    static var algorithms: AlgorithmPolicy.Preferences { HandshakeMutationTests.algorithms }

    func drain() {
      var count = 0
      while let event = client.poll(service: service) {
        count += 1
        precondition(count < 10_000, "poll never returned nil")
        events.append(event)
        switch event {
        case .hostKeyNeedsTrust: client.answerHostKey(trusted: true)
        case .established: try? client.send([MessageNumber.serviceRequest.rawValue] + Raw.string("ssh-userauth")); service = .serviceRequested
        case .message(let message) where message.number == .serviceAccept: service = .connection
        default: break
        }
      }
    }
  }

  /// The server's bytes of one session, recorded against the replay's own client logic.
  static func record() throws -> [UInt8] {
    let replay = try Replay()
    let server = ScriptedServer()
    server.start()
    var stream: [UInt8] = []
    func pump() throws {
      for _ in 0..<100 {
        let fromClient = replay.client.takeOutbound()
        if !fromClient.isEmpty { try server.receive(fromClient) }
        let fromServer = server.takeOutbound()
        stream += fromServer
        replay.client.receive(fromServer)
        replay.drain()
        if fromClient.isEmpty && fromServer.isEmpty { return }
      }
    }
    try pump()
    for index in 0..<3 { server.send(TransportExchangeTests.channelData([UInt8](repeating: UInt8(index), count: 50 * index))) }
    try pump()
    server.startRekey()
    try pump()
    server.send([MessageNumber.ignore.rawValue] + Raw.string("after"))
    server.send(TransportExchangeTests.channelData(Array("last".utf8)))
    try pump()
    XCTAssertTrue(replay.events.contains(.rekeyed))
    XCTAssertNil(replay.events.first { if case .ended = $0 { true } else { false } })
    return stream
  }

  static func run(_ stream: [UInt8], chunks random: SeededRandom?) throws -> Replay {
    let replay = try Replay()
    var offset = 0
    while offset < stream.count {
      let size = random.map { 1 + $0.below($0.below(4) == 0 ? 4096 : 64) } ?? stream.count
      replay.client.receive(Array(stream[offset..<min(stream.count, offset + size)]))
      offset += size
      replay.drain()
    }
    replay.client.receiveEnd()
    replay.drain()
    return replay
  }

  func testTheRecordingReplaysCleanly() throws {
    let stream = try Self.record()
    for random in [nil, SeededRandom(seed: 3)] {
      let replay = try Self.run(stream, chunks: random)
      XCTAssertTrue(replay.events.contains(.rekeyed))
      XCTAssertEqual(replay.events.last, .ended(.closed(.connectionLost)))
      XCTAssertEqual(replay.events.filter { if case .message = $0 { true } else { false } }.count, 5)
    }
  }

  func testMutatedServerStreamsEndExactlyOnce() throws {
    let stream = try Self.record()
    let random = SeededRandom(seed: 0x0BAD_5EED)
    var outcomes: [String: Int] = [:]
    for _ in 0..<Self.iterations {
      let mutated = MutationTests.mutate(stream, random)
      let replay = try Self.run(mutated, chunks: random)
      let ends = replay.events.enumerated().filter { if case .ended = $0.element { true } else { false } }
      XCTAssertEqual(ends.count, 1)
      XCTAssertEqual(ends.first?.offset, replay.events.count - 1)
      XCTAssertNil(replay.client.poll(service: replay.service))
      XCTAssertFalse(replay.client.isOpen)
      if case .ended(let error) = replay.events.last {
        let key: String = switch error {
        case .protocolViolation(.packet(let problem)): "packet \(problem)"
        case .protocolViolation(.version(let problem)): "version \(problem)"
        case .protocolViolation(.unexpectedMessage(let number, _)): "unexpected \(number)"
        case .protocolViolation(.malformed(let number, _)): "malformed \(number)"
        case .protocolViolation(let violation): "\(violation)"
        default: "\(error)"
        }
        outcomes[key, default: 0] += 1
      }
    }
    print("HandshakeMutationTests outcomes: \(outcomes.sorted { $0.value > $1.value })")
    // The loop must reach every stage, or it tests only the first bytes.
    XCTAssertGreaterThan(outcomes["packet integrity"] ?? 0, Self.iterations / 10, "\(outcomes)")
    XCTAssertGreaterThan(outcomes.count, 8, "\(outcomes)")
  }
}
