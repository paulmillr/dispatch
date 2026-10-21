import WatchConnectivity
import XCTest
@testable import DispatchMobile

/// A WatchConnectivity session the test drives: its state, and what the bridge sent.
@MainActor
final class ScriptedWatchSession: WatchSessioning {
    var isPaired = false
    var isWatchAppInstalled = false
    var isReachable = false
    var activationState: WCSessionActivationState = .notActivated
    private(set) var activations = 0
    private(set) var contexts: [WatchSnapshot] = []
    private(set) var messages: [WatchSnapshot] = []

    func activate(delegate: any WCSessionDelegate) { activations += 1 }

    func updateApplicationContext(_ context: [String: Any]) throws {
        contexts.append(try XCTUnwrap(try WatchCodec.value(WatchSnapshot.self, in: context)))
    }

    func sendMessage(_ message: [String: Any], failed: @escaping @Sendable (any Error) -> Void) {
        if let snapshot = try? WatchCodec.value(WatchSnapshot.self, in: message) { messages.append(snapshot) }
    }
}

/// The phone's side of WatchConnectivity (docs/watch.md, The bridge): activation, when the snapshot is pushed, and how
/// a request is answered.
@MainActor
final class WatchBridgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_001_000)

    private func bridge(_ app: MobileComposition, session: ScriptedWatchSession) -> WatchBridge {
        let now = now
        let bridge = WatchBridge(composition: app, session: session, clock: { now }, backgroundTask: { _ in {} })
        bridge.debounce = .milliseconds(20)
        return bridge
    }

    /// Nothing is sent until a paired watch has the app; then the snapshot goes as the application context, again only
    /// when it changed, and also as a message while the watch app is reachable.
    func testPushesOnlyToAnInstalledWatchAndOnlyChanges() async throws {
        let (app, studio, _) = try await WatchSnapshotTests.fixture(self)
        let session = ScriptedWatchSession()
        let bridge = bridge(app, session: session)
        XCTAssertEqual(session.activations, 1, "activated at once")
        XCTAssertEqual(bridge.skipped, "session not activated")

        session.activationState = .activated
        bridge.activated(.activated, error: nil)
        XCTAssertEqual(bridge.skipped, "no watch paired")
        XCTAssertEqual(bridge.status.pairing, .notPaired)
        session.isPaired = true
        bridge.watchStateChanged()
        XCTAssertEqual(bridge.skipped, "watch app not installed")
        XCTAssertEqual(bridge.status.pairing, .notInstalled)
        XCTAssertTrue(session.contexts.isEmpty)

        session.isWatchAppInstalled = true
        bridge.watchStateChanged()
        XCTAssertEqual(bridge.status.pairing, .installed)
        XCTAssertEqual(session.contexts, [WatchCodec.fit(WatchSnapshotBuilder(composition: app).build(at: now))])
        XCTAssertTrue(session.messages.isEmpty, "the watch app is not running")
        bridge.push(reason: "test")
        XCTAssertEqual(session.contexts.count, 1, "unchanged: not sent again")

        // A change anywhere the snapshot reads is pushed after the debounce.
        let row = try XCTUnwrap(app.conversations.conversations.first { $0.key.node == WatchSnapshotTests.billing })
        app.conversations.setMuted(true, row)
        try await TestSupport.eventually { session.contexts.count == 2 }
        XCTAssertEqual(session.contexts.last?.conversations.first?.muted, true)

        session.isReachable = true
        bridge.reachabilityChanged()
        XCTAssertEqual(session.contexts.count, 3, "reachable: at once, even unchanged")
        XCTAssertEqual(session.messages, [session.contexts[2]])

        bridge.protectedData(available: false)
        XCTAssertEqual(session.contexts.last?.phone.locked, true)
        XCTAssertEqual(session.contexts.last?.hosts.first { $0.id == studio.id.uuidString }?.blocked, nil, "connected")

        bridge.deactivated()
        XCTAssertEqual(session.activations, 2, "activated again for the next watch")
    }

    func testAnswersRequests() async throws {
        let (app, _, _) = try await WatchSnapshotTests.fixture(self)
        let bridge = bridge(app, session: ScriptedWatchSession())

        let missing = await bridge.answer(nil)
        XCTAssertEqual(missing, WatchReply(id: "", .failure(.invalid)))
        struct Garbled: Encodable { let id = "r1"; let kind = 7 }
        let garbled = await bridge.answer(try WatchCodec.encode(Garbled()))
        XCTAssertEqual(garbled, WatchReply(id: "r1", .failure(.invalid)), "answered with its id when that reads")
        let newer = await bridge.answer(try WatchCodec.encode(WatchRequest(.unknown("terminal.screen"), id: "r2")))
        XCTAssertEqual(newer, WatchReply(id: "r2", .failure(.unsupported)))

        let hello = await bridge.answer(try WatchCodec.encode(WatchRequest(.hello, id: "r3")))
        XCTAssertEqual(hello.id, "r3")
        guard case .snapshot(let snapshot) = hello.result else { return XCTFail("\(hello.result)") }
        XCTAssertEqual(snapshot.hosts.map(\.name), ["studio", "lab"])
        XCTAssertEqual(snapshot.conversations.count, 2)
    }

    /// A request runs in a background task, ended once it is answered; a host that does not connect within the budget
    /// is answered `timedOut` before the watch gives up.
    func testARequestIsAnsweredWithinTheBudget() async throws {
        let slow = ResilienceFixture.host("slow")
        let hosts = ResilienceFixture.sessions([slow], driver: ScriptedHostSessionDriver { _ in [.event(.link(.connecting)), .hold] })
        let app = ResilienceFixture.composition(hosts)
        let tasks = Recorder<String>()
        let bridge = WatchBridge(composition: app, session: ScriptedWatchSession(), backgroundTask: { name in
            tasks.append("begin " + name)
            return { tasks.append("end") }
        })
        bridge.budget = .milliseconds(200)
        let replies = Recorder<Data>()
        let request = WatchRequest(.thread(WatchConversationKey(host: slow.id.uuidString, node: "tmux:fixture:5"), limit: 40), id: "t1")
        bridge.received(try WatchCodec.encode(request)) { reply in
            if let data = reply[WatchCodec.key] as? Data { replies.append(data) }
        }
        XCTAssertEqual(tasks.values, ["begin Watch request"])
        try await TestSupport.eventually { !replies.values.isEmpty }
        let reply = try WatchCodec.decode(WatchReply.self, from: try XCTUnwrap(replies.values.first))
        XCTAssertEqual(reply, WatchReply(id: "t1", .failure(.timedOut)))
        try await TestSupport.eventually { tasks.values.count == 2 }
        XCTAssertEqual(tasks.values.last, "end")
    }

    /// Woken by a message in the background, the app may have less time left than the budget (14 s on the simulator):
    /// the reply goes before the system suspends it.
    func testARequestIsAnsweredWithinTheBackgroundTimeLeft() async throws {
        XCTAssertNil(WatchBridge.budget(.seconds(15), remaining: .greatestFiniteMagnitude), "the foreground has the budget")
        XCTAssertNil(WatchBridge.budget(.seconds(15), remaining: 25))
        XCTAssertEqual(WatchBridge.budget(.seconds(15), remaining: 14), .milliseconds(12_500))
        XCTAssertEqual(WatchBridge.budget(.seconds(15), remaining: 0.2), .milliseconds(500))

        let slow = ResilienceFixture.host("slow")
        let hosts = ResilienceFixture.sessions([slow], driver: ScriptedHostSessionDriver { _ in [.event(.link(.connecting)), .hold] })
        let app = ResilienceFixture.composition(hosts)
        let bridge = WatchBridge(composition: app, session: ScriptedWatchSession(), backgroundTask: { _ in {} },
                                 backgroundRemaining: { 2.5 })
        let request = WatchRequest(.thread(WatchConversationKey(host: slow.id.uuidString, node: "tmux:fixture:5"), limit: 40), id: "t2")
        let started = ContinuousClock.now
        let reply = await bridge.answer(try WatchCodec.encode(request))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2), "answered after the background time ran out")
        XCTAssertEqual(reply.id, "t2")
    }
}
