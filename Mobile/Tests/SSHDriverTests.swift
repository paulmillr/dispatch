import MobileTransport
import XCTest
@testable import DispatchMobile

/// The SSH driver's pure parts: the transport's states as host links, the links as Spaces states, the multiplexer it
/// follows, the multiplexer rows the host session gets, and the first-topology gate. The live parts run against the
/// fixture sshd in `SSHDriverLiveTests`.
@MainActor
final class SSHDriverTests: XCTestCase {
    /// The driver keeps the key it read (one Face ID per run), but a key deleted since is never used for another login.
    func testADeletedKeyIsNeverUsedAgain() async throws {
        let keys = KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none, secureEnclaveAvailable: false)
        let key = try keys.generateED25519(label: "phone")
        let host = HostRecord(name: "studio", address: "studio.local", user: "alex", auth: .key(key.id))
        let driver = ContextRecorder()
        let sessions = HostSessions(store: HostStore(url: nil, hosts: [host]), keys: keys, knownHosts: KnownHostStore(url: nil),
                                    driver: driver)
        sessions.ordered[0].connect()
        let context = try XCTUnwrap(driver.context)
        let cache = KeyCache()
        let first = try await cache.key(context)
        XCTAssertTrue(key.publicKey.hasPrefix(first.publicKey + " "), first.publicKey)
        let again = try await cache.key(context)
        XCTAssertEqual(again.publicKey, first.publicKey, "kept for the run's reconnects")

        keys.delete(key.id)
        do {
            _ = try await cache.key(context)
            XCTFail("A deleted key logged in again")
        } catch let refusal as HostRefusal {
            XCTAssertEqual(refusal.message, KeyCache.missing)
        }
    }

    func testTransportStatesMapOneToOne() {
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let pairs: [(MobileTransport.HostConnectionState, HostLink)] = [
            (.disconnected, .disconnected), (.connecting, .connecting), (.authenticating, .authenticating),
            (.bootstrapping, .bootstrapping), (.connected, .connected),
            (.reconnecting(attempt: 2, since: since), .reconnecting(attempt: 2, since: since)),
            (.failed(reason: "Authentication failed"), .failed("Authentication failed")),
        ]
        for (state, link) in pairs { XCTAssertEqual(HostLink(state), link, "\(state)") }
    }

    func testLinksAsSpacesStates() {
        XCTAssertEqual(SpacesHostState(.connected), .connected)
        for link: HostLink in [.connecting, .authenticating, .bootstrapping, .reconnecting(attempt: 1, since: Date())] {
            XCTAssertEqual(SpacesHostState(link), .connecting, "\(link)")
        }
        XCTAssertEqual(SpacesHostState(.disconnected), .offline)
        XCTAssertEqual(SpacesHostState(.failed("x")), .offline)
    }

    private let rows = [
        TabsMultiplexer(mux: 0, name: "tmux", external: true, program: "tmux", installed: true, version: "3.7"),
        TabsMultiplexer(mux: 1, name: "native", external: false),
        TabsMultiplexer(mux: 2, name: "herdr", external: true, program: "herdr", installed: true, version: "0.9.3"),
    ]
    private let backends = [HelperBackend(mux: 0, key: "tmux", label: "tmux", isDefault: true),
                            HelperBackend(mux: 1, key: "native", label: "native", isDefault: true),
                            HelperBackend(mux: 2, key: "herdr", label: "herdr", isDefault: true)]

    /// Connecting never starts a server: herdr is followed while it runs (or when the host asks for it), else tmux,
    /// whose open just fails without one.
    func testTheFollowedMultiplexerNeverStartsAServer() {
        XCTAssertEqual(SSHHostSessionDriver.choose(rows: rows, backends: backends, override: nil, herdrRunning: true)?.name, "herdr")
        XCTAssertEqual(SSHHostSessionDriver.choose(rows: rows, backends: backends, override: nil, herdrRunning: false)?.name, "tmux")
        XCTAssertEqual(SSHHostSessionDriver.choose(rows: rows, backends: backends, override: "tmux", herdrRunning: true)?.name, "tmux")
        XCTAssertEqual(SSHHostSessionDriver.choose(rows: rows, backends: backends, override: "herdr", herdrRunning: false)?.name, "herdr")
        let herdrOnly = rows.filter { $0.name != "tmux" }
        XCTAssertEqual(SSHHostSessionDriver.choose(rows: herdrOnly, backends: backends, override: nil, herdrRunning: false)?.name, "herdr",
                       "the only multiplexer is named (New space starts it); the driver opens it once it runs")
        var notInstalled = rows
        notInstalled[0].installed = false
        XCTAssertEqual(SSHHostSessionDriver.choose(rows: notInstalled, backends: backends, override: nil, herdrRunning: false)?.name, "herdr")
    }

    func testInstalledMultiplexersAndVersions() {
        var rows = rows
        rows[2].installed = false
        XCTAssertEqual(HelperLink.installed(rows).map(\.name), ["tmux"], "native and what is not installed are left out")
        XCTAssertEqual(HelperLink.versions(self.rows), ["tmux": "3.7", "herdr": "0.9.3"])
    }

    func testReadyWaitsForTheFirstTopologyAndPassesLaterOnes() async {
        let first = HostFixture.topology(), second = HostFixture.topology([.init(name: "x", cwd: "/x", tabs: 1, agents: 0)])
        let gate = ReadyGate()
        let offering = Task.detached {
            try? await Task.sleep(for: .milliseconds(50))
            XCTAssertFalse(gate.offer(first))
            XCTAssertFalse(gate.offer(second), "held until .ready went out")
        }
        let got = await gate.first(timeout: .seconds(5))
        XCTAssertEqual(got, first)
        // Both offers made before the gate opens (the first resumes the waiter before the second arrives).
        await offering.value
        XCTAssertEqual(gate.open(), .topology(second))
        XCTAssertTrue(gate.offer(first), "open: the caller yields it")

        let empty = ReadyGate()
        let none = await empty.first(timeout: .milliseconds(30))
        XCTAssertNil(none, "no topology yet: ready without one")
        XCTAssertNil(empty.open())
    }

    /// A first topology that arrives after the wait expired but before the gate opens is not lost: `.ready` went out
    /// without it, so opening hands it over.
    func testATopologyArrivingJustAfterTheWaitIsNotLost() async {
        let topology = HostFixture.topology()
        let gate = ReadyGate()
        let none = await gate.first(timeout: .milliseconds(10))
        XCTAssertNil(none)
        XCTAssertFalse(gate.offer(topology), "still closed")
        XCTAssertEqual(gate.open(), .topology(topology))
        XCTAssertNil(gate.open())
    }

    /// A disconnect cancels the drive loop while it waits for the first topology: the wait ends at once, so the link
    /// does not outlive `disconnect()` by the rest of the 2 s.
    func testCancellingTheWaitForTheFirstTopologyEndsItAtOnce() async {
        let gate = ReadyGate()
        let started = ContinuousClock.now
        let waiting = Task { await gate.first(timeout: .seconds(30)) }
        try? await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        let first = await waiting.value
        XCTAssertNil(first)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        let already = Task { await gate.first(timeout: .seconds(30)) }
        already.cancel()
        let again = await already.value
        XCTAssertNil(again, "an expired gate answers at once")
    }

    /// The helper saying it has no backend (no tmux server) ends the wait at once: `.ready` goes out without a topology
    /// and `.noBackend` right after it, so the host's kept spaces go; once open, the caller yields it itself.
    func testNoBackendEndsTheWaitAndFollowsReady() async {
        let gate = ReadyGate()
        let started = ContinuousClock.now
        let telling = Task.detached {
            try? await Task.sleep(for: .milliseconds(20))
            XCTAssertFalse(gate.none())
        }
        let first = await gate.first(timeout: .seconds(5))
        XCTAssertNil(first)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2), "no wait for the timeout")
        await telling.value
        XCTAssertEqual(gate.open(), ReadyGate.Pending.noBackend)
        XCTAssertTrue(gate.none(), "open: the caller yields .noBackend")

        let later = ReadyGate()
        XCTAssertFalse(later.offer(HostFixture.topology()))
        XCTAssertFalse(later.none(), "the server went away before ready went out")
        let kept = await later.first(timeout: .seconds(5))
        XCTAssertEqual(kept, HostFixture.topology())
        XCTAssertEqual(later.open(), ReadyGate.Pending.noBackend, "the kept first snapshot is followed by its end")
    }

    /// The phone's hello (docs/ios.md, Helper contract, and helper/PROTOCOL.md Features): with `stdio.liveness` the helper
    /// ends after 45 s without a frame, so the latency ping keeps it alive at most every 15 s.
    func testHelloFeaturesAndTheLivenessPing() {
        XCTAssertEqual(SSHHostSessionDriver.features, ["interaction.options", "chat.list", "projects.recent", "multiplexers.versions",
                                                       "terminals.coalesce", "launch.names", "stdio.liveness",
                                                       "terminals.activity", "chat.attachments"])
        XCTAssertLessThanOrEqual(SSHHostSessionDriver().pingInterval, SSHHostSessionDriver.livenessPing)
        XCTAssertEqual(SSHHostSessionDriver.livenessPing, .seconds(15))
    }

    /// `multiplexers.list` rows carry `running` under `multiplexers.versions` (true, false, null for native).
    func testRowsDecodeRunning() throws {
        let json = #"[{"mux":0,"name":"tmux","external":true,"installed":true,"version":"3.7","paste_state":true,"running":false},"#
            + #"{"mux":1,"name":"native","external":false,"installed":null,"running":null},"#
            + #"{"mux":2,"name":"herdr","external":true,"installed":true,"version":"0.9.3","running":true}]"#
        let rows = try JSONDecoder().decode([TabsMultiplexer].self, from: Data(json.utf8))
        XCTAssertEqual(rows.map(\.running), [false, nil, true])
        XCTAssertTrue(MultiplexerFollower.reportsRunning(rows))
        XCTAssertFalse(MultiplexerFollower.reportsRunning(self.rows), "older helpers leave it out")
    }

    /// herdr is followed while its server runs: the helper's `running` answers when present (no process list asked),
    /// else a process named herdr in `stats.processes`.
    func testRunningDecidesHerdrWithoutProcessNames() async {
        let asked = Recorder<Int>()
        var rows = rows
        rows[2].running = true
        let running = await MultiplexerFollower.herdrRunning(rows) { asked.append(1); return [] }
        XCTAssertTrue(running)
        rows[2].running = false
        let stopped = await MultiplexerFollower.herdrRunning(rows) { asked.append(1); return ["herdr"] }
        XCTAssertFalse(stopped, "the field wins over a process that only looks like herdr")
        XCTAssertEqual(asked.values.count, 0)

        let fallback = await MultiplexerFollower.herdrRunning(self.rows) { asked.append(1); return ["zsh", "herdr"] }
        XCTAssertTrue(fallback)
        XCTAssertEqual(asked.values.count, 1, "without the field: stats.processes")
        var notInstalled = self.rows
        notInstalled[2].installed = false
        let absent = await MultiplexerFollower.herdrRunning(notInstalled) { asked.append(1); return ["herdr"] }
        XCTAssertFalse(absent)
    }

    /// A new preference while connected: the follower leaves tmux's subscription and opens herdr's on the same client.
    func testTheFollowerSwitchesOnTheLiveConnection() async throws {
        var rows = rows
        rows[2].running = true
        nonisolated(unsafe) let listed = rows.map { row -> [String: Any] in
            var object: [String: Any] = ["mux": row.mux, "name": row.name, "external": row.external]
            if let running = row.running { object["running"] = running }
            if let installed = row.installed { object["installed"] = installed }
            return object
        }
        let helper = ScriptedHelper.scripted { request in
            switch request.method {
            case "multiplexers.list": .result(listed)
            case "backends.list": .result([["mux": 0, "key": "tmux", "label": "tmux", "default": true],
                                           ["mux": 2, "key": "herdr", "label": "herdr", "default": true]])
            default: nil
            }
        }
        let preference = FollowPreference(.tmux)
        let follower = MultiplexerFollower(client: helper.client, rows: rows, backends: backends, preference: preference,
                                           reopenDelay: .milliseconds(50))
        let followed = Recorder<String?>()
        let task = Task { await follower.run(following: { followed.append($0) }, topology: { _ in }) }
        defer { task.cancel() }
        try await TestSupport.eventually { helper.requests("backends.open").count == 1 }
        XCTAssertEqual(helper.requests("backends.open").first?.params["mux"] as? Int, 0)
        preference.set(.herdr)
        try await TestSupport.eventually { helper.requests("backends.open").count == 2 }
        XCTAssertEqual(helper.requests("backends.open").last?.params["mux"] as? Int, 2)
        let tmux = try XCTUnwrap(helper.requests("backends.open").first?.id)
        try await TestSupport.eventually { helper.cancellations.contains(tmux) }
        XCTAssertEqual(followed.values, ["tmux", "herdr"])
        XCTAssertTrue(helper.requests("stats.processes").isEmpty, "running came with the rows")
    }

    /// After a network change a connected link must answer `echo` within the timeout, else it is closed and reconnects.
    func testTheLivenessProbe() async {
        let answering = ScriptedHelper.scripted { $0.method == "echo" ? .result([String: String]()) : nil }
        let silent = ScriptedHelper.scripted { _ in nil }
        let alive = await SSHHostSessionDriver.alive(answering.client, timeout: .seconds(2))
        XCTAssertTrue(alive)
        let started = ContinuousClock.now
        let dead = await SSHHostSessionDriver.alive(silent.client, timeout: .milliseconds(200))
        XCTAssertFalse(dead)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }
}

/// Records the context a session lends its driver; connects nothing.
final class ContextRecorder: HostSessionDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: HostSessionContext?
    var context: HostSessionContext? { lock.withLock { recorded } }
    func run(_ host: HostRecord, context: HostSessionContext) -> AsyncStream<HostSessionEvent> {
        lock.withLock { recorded = context }
        return AsyncStream { _ in }
    }
}
