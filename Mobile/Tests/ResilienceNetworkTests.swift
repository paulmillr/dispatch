import XCTest
@testable import DispatchMobile

/// Network and foreground recovery: a path that becomes usable or changes interfaces retries every session at once;
/// a waiting reconnect tries now, a connected session checks its link.
@MainActor
final class ResilienceNetworkTests: XCTestCase {
    private let wifi = NetworkPath(satisfied: true, interfaces: ["wifi:en0"])
    private let cellular = NetworkPath(satisfied: true, interfaces: ["cellular:pdp_ip0"])
    private let none = NetworkPath(satisfied: false, interfaces: [])

    func testPathChangesThatRetry() {
        var changes = 0
        let watcher = NetworkPathWatcher(source: PushedPaths()) { changes += 1 }
        watcher.receive(wifi)
        XCTAssertEqual(changes, 0, "the first reading is the baseline")
        watcher.receive(wifi)
        XCTAssertEqual(changes, 0, "nothing changed")
        watcher.receive(cellular)
        XCTAssertEqual(changes, 1, "other interfaces: a connected link may be dead")
        watcher.receive(none)
        XCTAssertEqual(changes, 1, "losing the path calls nothing: the links notice")
        watcher.receive(none)
        watcher.receive(cellular)
        XCTAssertEqual(changes, 2, "usable again")
        watcher.receive(NetworkPath(satisfied: true, interfaces: ["wifi:en0", "cellular:pdp_ip0"]))
        XCTAssertEqual(changes, 3, "a new preferred interface")
    }

    func testTheWatcherReadsItsSource() async throws {
        let source = PushedPaths()
        var changes = 0
        let watcher = NetworkPathWatcher(source: source) { changes += 1 }
        watcher.start()
        source.push(wifi)
        source.push(cellular)
        try await TestSupport.eventually { changes == 1 }
        watcher.stop()
        XCTAssertTrue(source.cancelled)
    }

    /// A reconnect waiting out its backoff tries at once when the network changes; in the background nothing retries.
    func testANetworkChangeRetriesAWaitingReconnect() async throws {
        let studio = ResilienceFixture.host("studio")
        let since = Date()
        let driver = ScriptedHostSessionDriver { host in
            [.event(.link(.connecting)), .event(.link(.reconnecting(attempt: 1, since: since))), .awaitRetry]
                + ScriptedHostSessionDriver.connects(host)
        }
        let hosts = ResilienceFixture.sessions([studio], driver: driver)
        let session = try XCTUnwrap(hosts.session(studio.id))
        try await TestSupport.eventually { if case .reconnecting = session.link { true } else { false } }
        hosts.setActive(false)
        hosts.networkChanged()
        XCTAssertEqual(session.link, .disconnected, "in the background sessions stay down")
        hosts.setActive(true)
        try await TestSupport.eventually { if case .reconnecting = session.link { true } else { false } }
        hosts.networkChanged()
        try await TestSupport.eventually { session.link == .connected }
    }

    /// A connected session hands the retry to its driver, which checks the link (`SSHHostSessionDriver.alive`).
    func testRetryWhileConnectedReachesTheDriver() async throws {
        let studio = ResilienceFixture.host("studio")
        let driver = ScriptedHostSessionDriver { _ in
            [.ready(hello: HostFixture.hello(), multiplexers: HostFixture.multiplexers(["tmux"]), versions: [:], topology: nil),
             .awaitRetry, .event(.latency(.milliseconds(7))), .hold]
        }
        let hosts = ResilienceFixture.sessions([studio], driver: driver)
        let session = try XCTUnwrap(hosts.session(studio.id))
        try await TestSupport.eventually { session.link == .connected }
        XCTAssertNil(session.latency)
        hosts.networkChanged()
        try await TestSupport.eventually { session.latency == .milliseconds(7) }
        XCTAssertEqual(driver.runs(studio.id), 1, "no new run: the same connection checked itself")
    }
}

/// Readings pushed by the test.
final class PushedPaths: NetworkPathSource, @unchecked Sendable {
    private let lock = NSLock()
    private var update: (@Sendable (NetworkPath) -> Void)?
    private(set) var cancelled = false

    func start(_ update: @escaping @Sendable (NetworkPath) -> Void) { lock.withLock { self.update = update } }
    func cancel() { lock.withLock { cancelled = true } }
    func push(_ path: NetworkPath) { lock.withLock { update }?(path) }
}
