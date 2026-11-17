import Foundation
import XCTest
@testable import SSHEngine

/// The driver's connect, in memory against the scripted server: the host key question, the handshake deadline and its
/// pause, cancellation at each stage, failures, and that a failed connect leaves its stream closed.
final class DriverConnectTests: XCTestCase {
  private func options(handshake: Duration = .seconds(10)) -> ConnectOptions {
    var options = MemoryWorld.options
    options.handshakeTimeout = handshake
    return options
  }

  func testConnectAsksTrustOnceAndReturnsTheKey() async throws {
    let world = await MemoryWorld.make()
    let asked = Locked<[HostKey]>([])
    let session = try await world.connect { key in
      asked.update { $0.append(key) }
      return true
    }
    let identity = await world.peer.identityBlob
    XCTAssertEqual(asked.current.map(\.blob), [identity])
    XCTAssertEqual(session.hostKey.blob, identity)
    XCTAssertEqual(session.hostKey.algorithm, .ed25519)
    // Nothing past the key exchange went before the connect returned.
    let received = await world.peer.received
    XCTAssertTrue(received.allSatisfy { ($0.first ?? 0) < 50 && $0.first != 5 }, "\(received.map { $0.first ?? 0 })")
    await session.close()
    let end = await session.ended()
    XCTAssertEqual(end, .closed(.byClient))
  }

  func testARejectedKeyFailsTheConnectAndClosesTheStream() async throws {
    let world = await MemoryWorld.make()
    do {
      _ = try await world.connect { _ in false }
      XCTFail("connected with a rejected key")
    } catch {
      XCTAssertEqual(error, .hostKeyRejected)
    }
    let received = await world.peer.waitFor { $0.contains { $0.first == 1 } }
    XCTAssertEqual(received.numbered(1).count, 1, "one DISCONNECT")
    let newKeys = received.numbered(MessageNumber.newKeys.rawValue)
    XCTAssertTrue(newKeys.isEmpty, "no NEWKEYS for a key nobody trusted")
    try await bounded(5, "the client's close") { await world.peer.waitUntilClientClosed() }
  }

  func testASilentServerTimesOutTheHandshake() async throws {
    let world = await MemoryWorld.make(start: .not)
    let started = ContinuousClock.now
    do {
      _ = try await world.connect(options(handshake: .milliseconds(300)))
      XCTFail("connected to a silent server")
    } catch {
      XCTAssertEqual(error, .timedOut(.handshake))
    }
    let elapsed = ContinuousClock.now - started
    XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(300))
    XCTAssertLessThan(elapsed, .seconds(5))
  }

  func testAServerThatStopsAfterItsVersionTimesOut() async throws {
    var configuration = ScriptedServer.Configuration()
    configuration.holdFirstKexInit = true
    let world = await MemoryWorld.make(configuration: configuration, start: .stallingAfterVersion)
    do {
      _ = try await world.connect(options(handshake: .milliseconds(300)))
      XCTFail("connected without a key exchange")
    } catch {
      XCTAssertEqual(error, .timedOut(.handshake))
    }
  }

  /// The trust callback takes three times the handshake timeout: the deadline is paused meanwhile.
  func testTheDeadlinePausesWhileTrustDecides() async throws {
    let world = await MemoryWorld.make()
    let session = try await world.connect(options(handshake: .milliseconds(300))) { _ in
      try? await Task.sleep(for: .milliseconds(900))
      return true
    }
    XCTAssertTrue(session.hostKey.blob.count > 0)
    await session.close()
  }

  /// Cancelling the connect while the trust callback decides cancels the callback, fails with `cancelled`, and its
  /// late answer changes nothing.
  func testCancellingDuringTrustCancelsTheQuestion() async throws {
    let world = await MemoryWorld.make()
    let asked = Signal()
    let sawCancel = Signal()
    let connect = Task { () async throws -> any SSHSession in
      try await world.connect { _ in
        asked.fire()
        await withTaskCancellationHandler {
          await untilCancelled()
        } onCancel: {
          sawCancel.fire()
        }
        return true
      }
    }
    await asked.wait()
    connect.cancel()
    let result = await connect.sshError
    XCTAssertEqual(result, .cancelled)
    try await bounded(5, "the trust callback's cancellation") { await sawCancel.wait() }
    let closed = await world.peer.waitFor { $0.contains { $0.first == 1 } }
    XCTAssertFalse(closed.numbered(1).isEmpty, "DISCONNECT sent")
  }

  func testCancellingDuringTheKeyExchange() async throws {
    let world = await MemoryWorld.make(start: .stallingAfterVersion)
    let connect = Task { () async throws -> any SSHSession in try await world.connect() }
    // The client's version and KEXINIT are written at once; the peer reads nothing, so wait on the driver instead.
    _ = try await bounded(5, "the client's first write") { [world] in
      await world.drivers.first().waitForStats { $0.writes > 0 }
    }
    connect.cancel()
    let failure = await connect.sshError
    XCTAssertEqual(failure, .cancelled)
  }

  func testCancellingBeforeTheStreamConnects() async throws {
    let connector = ClientConnector(streams: HangingConnector(), random: { SeededRandom(seed: 1) })
    let connect = Task { () async throws -> any SSHSession in
      try await connector.connect(MemoryWorld.options) { _ in true }
    }
    connect.cancel()
    let failure = await connect.sshError
    XCTAssertEqual(failure, .cancelled)
  }

  func testTheStreamConnectorsFailurePassesThrough() async throws {
    for failure in [SSHError.hostNotFound, .connectionRefused, .unreachable, .noAnswer, .timedOut(.lookup), .network("x")] {
      let connector = ClientConnector(streams: MemoryConnector(result: .failure(failure)), random: { SeededRandom(seed: 1) })
      do {
        _ = try await connector.connect(MemoryWorld.options) { _ in true }
        XCTFail("connected")
      } catch {
        XCTAssertEqual(error, failure)
      }
    }
  }

  func testInvalidOptionsAreRefusedBeforeConnecting() async throws {
    let world = await MemoryWorld.make()
    var options = MemoryWorld.options
    options.port = 0
    do {
      _ = try await world.connect(options)
      XCTFail("connected to port 0")
    } catch {
      XCTAssertEqual(error, .usage(.invalidArgument("port 0")))
    }
  }

  func testEOFDuringTheHandshake() async throws {
    var configuration = ScriptedServer.Configuration()
    configuration.holdFirstKexInit = true
    let world = await MemoryWorld.make(configuration: configuration, start: .stallingAfterVersion)
    let connect = Task { () async throws -> any SSHSession in try await world.connect() }
    await world.peer.finishWriting()
    let failure = await connect.sshError
    XCTAssertEqual(failure, .closed(.connectionLost))
  }

  func testAResetDuringTrustFailsTheConnect() async throws {
    let world = await MemoryWorld.make()
    let asked = Signal()
    let connect = Task { () async throws -> any SSHSession in
      try await world.connect { _ in
        asked.fire()
        await untilCancelled()
        return true
      }
    }
    await asked.wait()
    await world.peer.reset()
    let failure = await connect.sshError
    XCTAssertEqual(failure, .closed(.connectionLost))
  }
}

/// A connector that never connects until cancelled.
struct HangingConnector: StreamConnector {
  func connect(host: String, port: UInt16, deadline: ContinuousClock.Instant) async throws(SSHError) -> any ByteStream {
    await untilCancelled()
    throw .cancelled
  }
}

extension Task where Failure == any Error {
  /// The task's error as the engine's, nil when it succeeded (another error type fails the test's comparison).
  var sshError: SSHError? {
    get async {
      switch await result {
      case .success: return nil
      case .failure(let error): return (error as? SSHError) ?? .network("not an SSHError: \(error)")
      }
    }
  }
}
