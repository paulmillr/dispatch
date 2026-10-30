import XCTest
import os

@testable import DispatchApp

/// The app's side of `terminals.window` (HelperOutputWindow): delivered output is acknowledged per attach subscription,
/// in batches while it streams and whole once quiet or once the connection's pending total nears the helper's window,
/// and only on a connection whose helper accepted the feature. No helper runs: a pipe peer reads what the app sends.
final class HelperOutputWindowTests: XCTestCase {
    struct Ack: Decodable, Equatable, Sendable { let terminal: UInt64; let bytes: UInt64; let subscription: UInt64 }
    private struct Request: Decodable { let method: String; let params: Ack }

    /// A connection whose sent `terminals.ack` requests the peer collects and answers: null, or the error `answer`.
    private final class Peer: @unchecked Sendable {
        let connection: HelperConnection
        let transport: HelperTransport
        let acks = OSAllocatedUnfairLock(initialState: [Ack]())

        init(answer: String? = nil) {
            let incoming = Pipe(), outgoing = Pipe()
            connection = HelperConnection(read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting)
            transport = HelperTransport(read: outgoing.fileHandleForReading, write: incoming.fileHandleForWriting)
            var decoder = HelperWire.Decoder()
            transport.start(receive: { [acks, transport] bytes in
                do {
                    try decoder.feed(bytes) { message in
                        guard message.kind == .request else { return }
                        let request = try HelperClientTests.decode(Request.self, message.body)
                        XCTAssertEqual(request.method, "terminals.ack")
                        acks.withLock { $0.append(request.params) }
                        let reply: HelperBinary.Value = answer.map {
                            .object(["error": .object(["code": .string($0), "message": .string("refused")])])
                        } ?? .object(["result": .null])
                        transport.send(try HelperWire.encode(.init(kind: .response, id: message.id,
                                                                    body: HelperBinary.encode(reply))))
                    }
                } catch { XCTFail(String(describing: error)) }
            }, closed: { _ in })
        }

        var sent: [Ack] { acks.withLock { $0 }.sorted { ($0.subscription, $0.terminal) < ($1.subscription, $1.terminal) } }
        func close() { connection.close(); transport.close() }
    }

    private func output(_ terminal: UInt64, _ count: Int) -> Result<HelperClient.Update, any Error> {
        .success(.output(.init(terminal: terminal, bytes: Data(repeating: 0x79, count: count))))
    }

    private func subscription(_ id: UInt64) -> HelperOutputWindow.Subscription {
        let subscription = HelperOutputWindow.Subscription()
        subscription.identify(id)
        return subscription
    }

    func testFeatureIsOffByDefaultAndNamedOnlyWithTheSwitch() {
        XCTAssertFalse(HelperSession.outputWindow)
        XCTAssertFalse(HelperSession.features.contains(HelperSession.terminalsWindow))
        XCTAssertTrue(HelperSession.features.contains(HelperSession.requestsBacklog))
        HelperSession.outputWindow = true
        defer { HelperSession.outputWindow = false }
        XCTAssertEqual(HelperSession.features.last, HelperSession.terminalsWindow)
    }

    func testAStreamIsAcknowledgedInBatchesNamingItsSubscriptionOnlyOnceEnabled() async throws {
        let peer = Peer()
        defer { peer.close() }
        let stream = subscription(41)
        // A connection whose helper did not accept the feature acknowledges nothing; what it got does not count later.
        HelperOutputWindow.delivered(output(7, 200_000), on: peer.connection, subscription: stream)
        XCTAssertNil(HelperOutputWindow.pending(on: peer.connection))
        HelperOutputWindow.enable(peer.connection)
        HelperOutputWindow.delivered(output(7, 40_000), on: peer.connection, subscription: stream)
        HelperOutputWindow.delivered(.success(.attached), on: peer.connection, subscription: stream)
        HelperOutputWindow.delivered(.failure(CancellationError()), on: peer.connection, subscription: stream)
        XCTAssertEqual(HelperOutputWindow.pending(on: peer.connection), 40_000)
        HelperOutputWindow.delivered(output(7, 30_000), on: peer.connection, subscription: stream)
        // A batch goes out at once, before any quiet period.
        XCTAssertEqual(HelperOutputWindow.pending(on: peer.connection), 0)
        try await TestSupport.eventually { peer.sent.count == 1 }
        XCTAssertEqual(peer.sent, [Ack(terminal: 7, bytes: 70_000, subscription: 41)])
    }

    func testIdleTerminalsUnderABatchAreAcknowledgedWithoutFurtherOutput() async throws {
        let peer = Peer()
        defer { peer.close() }
        HelperOutputWindow.enable(peer.connection)
        // Five terminals that each stop just under a batch: 300 000 bytes, more than the helper's window. Waiting for
        // more output to fill a batch would leave the helper paused for good.
        for index in 0..<5 as Range<UInt64> {
            HelperOutputWindow.delivered(output(10 + index, 60_000), on: peer.connection, subscription: subscription(50 + index))
        }
        XCTAssertLessThan(HelperOutputWindow.pending(on: peer.connection) ?? 0, HelperOutputWindow.limit,
                          "past half the window everything pending goes out")
        try await TestSupport.eventually { peer.sent.count == 5 }
        XCTAssertEqual(peer.sent, (0..<5 as Range<UInt64>).map { Ack(terminal: 10 + $0, bytes: 60_000, subscription: 50 + $0) })
        XCTAssertEqual(HelperOutputWindow.pending(on: peer.connection), 0)
    }

    func testOutputBeforeTheSubscriptionIsKnownWaitsForItsIdentifier() async throws {
        let peer = Peer()
        defer { peer.close() }
        HelperOutputWindow.enable(peer.connection)
        // Two subscriptions of the same terminal (a re-attach): each acknowledgement names its own.
        let early = HelperOutputWindow.Subscription(), other = subscription(61)
        HelperOutputWindow.delivered(output(7, 70_000), on: peer.connection, subscription: early)
        HelperOutputWindow.delivered(output(7, 70_000), on: peer.connection, subscription: other)
        try await TestSupport.eventually { peer.sent.count == 1 }
        XCTAssertEqual(HelperOutputWindow.pending(on: peer.connection), 70_000, "no id yet: nothing to name")
        early.identify(60)
        try await TestSupport.eventually { peer.sent.count == 2 }
        XCTAssertEqual(peer.sent, [Ack(terminal: 7, bytes: 70_000, subscription: 60), Ack(terminal: 7, bytes: 70_000, subscription: 61)])
    }

    func testARefusedAcknowledgementIsCounted() async throws {
        let peer = Peer(answer: "invalid_input")
        defer { peer.close() }
        HelperOutputWindow.enable(peer.connection)
        let before = HelperOutputWindow.failed
        HelperOutputWindow.delivered(output(7, HelperOutputWindow.batch), on: peer.connection, subscription: subscription(70))
        try await TestSupport.eventually { HelperOutputWindow.failed == before + 1 }
    }
}
