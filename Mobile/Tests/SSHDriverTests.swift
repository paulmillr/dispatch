@testable import MobileTransport
import Synchronization
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


/// The driver's decision after the login, with a scripted login and helper (`ScriptedLogin`): a host without the helper
/// stays plain SSH; a helper that cannot start leaves the connection up as plain SSH with the failure's text; login, host
/// key and network failures stay refusals and reconnects.
extension SSHDriverTests {
    /// What the driver yielded, comparable.
    enum Seen: Equatable, Sendable {
        case link(HostLink)
        case ready
        case plain(String?)
        case other
    }

    private func host(helper: Bool = true) -> HostRecord {
        HostRecord(name: "studio", address: "studio.local", user: "alex", auth: .password, helper: helper)
    }

    private func context(retries: AsyncStream<Void>) -> HostSessionContext {
        HostSessionContext(verifyHostKey: { _ in true }, key: { nil }, password: { "correct horse" }, retries: retries)
    }

    /// Runs `host` through a driver whose logins are `login`'s; returns what it yielded and the opener of each `.plain`.
    private func run(_ host: HostRecord, login: @escaping HostLoginStep, retries: AsyncStream<Void> = AsyncStream { _ in })
        -> (events: Recorder<Seen>, openers: Recorder<ScriptedShellOpener>, task: Task<Void, Never>) {
        var driver = SSHHostSessionDriver(pingInterval: .seconds(3600))
        driver.firstTopology = .milliseconds(50)
        driver.exitWait = .seconds(1)
        driver.login = login
        let events = Recorder<Seen>(), openers = Recorder<ScriptedShellOpener>()
        let stream = driver.run(host, context: context(retries: retries))
        let task = Task.detached {
            for await event in stream {
                switch event {
                case .link(let link): events.append(.link(link))
                case .ready: events.append(.ready)
                case .plain(let reason, let shells):
                    if let opener = shells as? ScriptedShellOpener { openers.append(opener) }
                    events.append(.plain(reason))
                default: events.append(.other)
                }
            }
        }
        return (events, openers, task)
    }

    private func plain(_ events: Recorder<Seen>) -> String?? {
        for case .plain(let reason) in events.values { return .some(reason) }
        return nil
    }

    /// The Helper switch off: the connection stops after the login, nothing is installed or started.
    func testAHostWithoutTheHelperIsPlainWithoutABootstrap() async throws {
        let login = ScriptedLogin { _, _ in XCTFail("bootstrapped"); throw CancellationError() }
        let (events, openers, task) = run(host(helper: false), login: login.step)
        defer { task.cancel() }
        try await TestSupport.eventually(diagnostic: "\(events.values)") { plain(events) != nil }
        XCTAssertEqual(plain(events), .some(nil))
        XCTAssertTrue(login.roots.isEmpty)
        XCTAssertTrue(login.isOpen, "kept: shells open on it")
        XCTAssertFalse(events.values.contains(.link(.bootstrapping)))
        XCTAssertTrue(openers.values.first === login.opener, "the login's shells")
    }

    /// A retry (network change, foregrounding) on a plain link checks the connection itself: one that answers stays
    /// connected; one that does not is closed and reconnects, plain again.
    func testARetryChecksAPlainLink() async throws {
        let logins = Recorder<ScriptedLogin>()
        let step: HostLoginStep = { _, _, _, _, _, phase in
            await phase(.authenticating)
            let login = ScriptedLogin { _, _ in throw CancellationError() }
            logins.append(login)
            return login
        }
        let (retries, retry) = AsyncStream<Void>.makeStream()
        let (events, _, task) = run(host(helper: false), login: step, retries: retries)
        defer { task.cancel() }
        let plains = { events.values.filter { $0 == .plain(nil) }.count }
        try await TestSupport.eventually(diagnostic: "\(events.values)") { plains() == 1 }
        let first = try XCTUnwrap(logins.values.first)

        retry.yield()
        try await TestSupport.eventually { first.probes == 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(first.isOpen, "it answered: kept")
        XCTAssertFalse(events.values.contains { if case .link(.reconnecting) = $0 { true } else { false } })
        XCTAssertEqual(logins.values.count, 1)

        first.probe = .failure(SSHTransportError.timedOut("probe"))
        retry.yield()
        try await TestSupport.eventually(diagnostic: "\(events.values)") {
            events.values.contains { if case .link(.reconnecting) = $0 { true } else { false } }
        }
        XCTAssertFalse(first.isOpen, "the silent connection is closed")
        try await TestSupport.eventually(diagnostic: "\(events.values)") { plains() == 2 }
        XCTAssertEqual(logins.values.count, 2, "a new connection, plain again")
        XCTAssertTrue(try XCTUnwrap(logins.values.last).isOpen)
    }

    /// A host that refuses exec channels is a typical plain one: its refused probe is still the server answering, so a
    /// retry keeps the link.
    func testARefusedProbeKeepsAPlainLink() async throws {
        let login = ScriptedLogin { _, _ in throw SSHTransportError.commandFailed(status: -1, stderr: "exec request refused") }
        login.probe = .failure(SSHTransportError.commandFailed(status: -1, stderr: "exec request refused"))
        let (retries, retry) = AsyncStream<Void>.makeStream()
        let (events, _, task) = run(host(), login: login.step, retries: retries)
        defer { task.cancel() }
        try await TestSupport.eventually(diagnostic: "\(events.values)") { plain(events) != nil }
        XCTAssertEqual(plain(events), .some("The host refused to run the helper: exec request refused"))
        retry.yield()
        try await TestSupport.eventually { login.probes == 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(login.isOpen, "a refusal is an answer: kept")
        XCTAssertFalse(events.values.contains { if case .link(.reconnecting) = $0 { true } else { false } })
    }

    /// A helper channel that ends with no status (or closes) while the connection is going is a loss, not a helper
    /// failure: the connection is asked first, and only one that answers goes on as plain SSH.
    func testAChannelEndingWithTheConnectionIsNotAHelperFailure() async throws {
        let dying = ScriptedLogin { root, _ in ScriptedHelperProcess(root: root, lost: true) }
        dying.probe = .failure(SSHTransportError.channelClosed)
        let (events, _, task) = run(host(), login: dying.step)
        try await TestSupport.eventually(diagnostic: "\(events.values)") {
            events.values.contains { if case .link(.reconnecting) = $0 { true } else { false } }
        }
        XCTAssertNil(plain(events), "no plain notice for a connection that went")
        XCTAssertEqual(dying.probes, 1)
        task.cancel()

        let closing = ScriptedLogin { _, _ in throw SSHTransportError.channelClosed }
        closing.probe = .failure(SSHTransportError.network("reset"))
        let (closed, _, again) = run(host(), login: closing.step)
        try await TestSupport.eventually(diagnostic: "\(closed.values)") {
            closed.values.contains { if case .link(.reconnecting) = $0 { true } else { false } }
        }
        XCTAssertNil(plain(closed))
        again.cancel()

        let alive = ScriptedLogin { root, _ in ScriptedHelperProcess(root: root, lost: true) }
        let (kept, _, last) = run(host(), login: alive.step)
        defer { last.cancel() }
        try await TestSupport.eventually(diagnostic: "\(kept.values)") { plain(kept) != nil }
        XCTAssertEqual(plain(kept), .some(HelperBootstrap.launchFailure(
            status: nil, stderr: "", installed: ScriptedHelperProcess.installed(root: .home, runtime: nil))))
        XCTAssertEqual(alive.probes, 1, "the connection answered: the helper's failure")
        XCTAssertTrue(alive.isOpen)
    }

    /// Every bootstrap failure on a live connection goes on as plain SSH with the failure's text; the connection stays
    /// and nothing reconnects.
    func testBootstrapFailuresGoOnAsPlainSSH() async throws {
        let failures: [(SSHTransportError, String)] = [
            (.bootstrap("SSH integration requires Linux on ARM64 or x86-64, or macOS on Apple silicon."),
             "SSH integration requires Linux on ARM64 or x86-64, or macOS on Apple silicon."),
            (.bootstrap("Could not identify the SSH host platform."), "Could not identify the SSH host platform."),
            (.bootstrap("Could not install the SSH helper in the remote cache (1):\ndispatch-setup: unsafe-cache"),
             "Could not install the SSH helper in the remote cache (1):\ndispatch-setup: unsafe-cache"),
            (.commandFailed(status: -1, stderr: "exec request refused"), "The host refused to run the helper: exec request refused"),
        ]
        for (error, reason) in failures {
            let login = ScriptedLogin { _, _ in throw error }
            let (events, _, task) = run(host(), login: login.step)
            try await TestSupport.eventually(diagnostic: "\(events.values)") { plain(events) != nil }
            XCTAssertEqual(plain(events), .some(reason))
            XCTAssertTrue(login.isOpen, "\(error): the connection is kept")
            XCTAssertEqual(login.roots, [.home])
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertFalse(events.values.contains { if case .link(.reconnecting) = $0 { true } else { false } }, "\(error)")
            task.cancel()
            try await TestSupport.eventually { !login.isOpen }
        }
    }

    /// A helper that answers but cannot be used (another protocol version, no transport limits) is closed; the
    /// connection goes on as plain SSH.
    func testAnIncompatibleHelperGoesOnAsPlainSSH() async throws {
        let cases: [([String: Any], String)] = [
            (ScriptedHelperProcess.hello(version: HelperBinary.version + 1),
             "The helper on studio speaks another protocol version. Update Dispatch."),
            (ScriptedHelperProcess.hello(limits: false), "The helper on studio did not report its transport limits."),
        ]
        for (hello, reason) in cases {
            nonisolated(unsafe) let hello = hello
            let process = Recorder<ScriptedHelperProcess>()
            let login = ScriptedLogin { root, _ in
                let made = ScriptedHelperProcess(root: root, hello: hello)
                process.append(made)
                return made
            }
            let (events, _, task) = run(host(), login: login.step)
            try await TestSupport.eventually(diagnostic: "\(events.values)") { plain(events) != nil }
            XCTAssertEqual(plain(events), .some(reason))
            XCTAssertTrue(login.isOpen)
            XCTAssertTrue(try XCTUnwrap(process.values.first).isClosed, "the helper's channel is closed")
            XCTAssertEqual(login.roots, [.home], "an answering helper is not installed again")
            task.cancel()
        }
    }

    /// The helper at the home folder exits 126 before greeting (a home mounted noexec): installed and started again under
    /// the runtime folder the probe found, on the same connection, which greets.
    func testAHelperTheHomeCannotRunStartsFromTheRuntimeFolder() async throws {
        let processes = Recorder<ScriptedHelperProcess>()
        let login = ScriptedLogin { root, _ in
            let made = root == .home
                ? ScriptedHelperProcess(root: root, runtime: "/run/user/1000", exit: 126, stderr: "sh: ./dispatch-helper: Permission denied\n")
                : ScriptedHelperProcess(root: root, runtime: "/run/user/1000", hello: ScriptedHelperProcess.hello())
            processes.append(made)
            return made
        }
        let (events, _, task) = run(host(), login: login.step)
        defer { task.cancel() }
        try await TestSupport.eventually(diagnostic: "\(events.values)") { events.values.contains(.ready) }
        XCTAssertEqual(login.roots, [.home, .runtimeDirectory])
        XCTAssertNil(plain(events))
        let first = try XCTUnwrap(processes.values.first), second = try XCTUnwrap(processes.values.last)
        XCTAssertTrue(first.isClosed)
        XCTAssertFalse(second.isClosed)
        XCTAssertTrue(second.command.contains(#"cd -P "$XDG_RUNTIME_DIR""#), "the runtime folder's launch: \(second.command)")
        XCTAssertFalse(first.command.contains("XDG_RUNTIME_DIR"), first.command)
        XCTAssertTrue(second.installed.path.hasPrefix("/run/user/1000/dispatch/bin/versions/"), second.installed.path)
        XCTAssertTrue(login.isOpen)
    }

    /// The runtime folder cannot run it either: plain SSH with the bootstrap's text about running programs, no reconnect.
    func testAHelperNoFolderCanRunIsPlainSSHWithWhy() async throws {
        let login = ScriptedLogin { root, _ in
            ScriptedHelperProcess(root: root, runtime: "/run/user/1000", exit: 126, stderr: "sh: ./dispatch-helper: Permission denied\n")
        }
        let (events, _, task) = run(host(), login: login.step)
        defer { task.cancel() }
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "\(events.values)") { plain(events) != nil }
        XCTAssertEqual(login.roots, [.home, .runtimeDirectory])
        let reason = try XCTUnwrap(plain(events) ?? nil)
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("run programs"), reason)
        XCTAssertTrue(login.isOpen)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(events.values.contains { if case .link(.reconnecting) = $0 { true } else { false } })
    }

    /// A helper that exits 1 before greeting says why on stderr: plain SSH with that text. Without a runtime folder from
    /// the probe a 126 gets no second attempt.
    func testAHelperThatExitsBeforeGreetingIsPlainSSHWithItsStderr() async throws {
        let login = ScriptedLogin { root, _ in
            ScriptedHelperProcess(root: root, runtime: "/run/user/1000", exit: 1, stderr: "dispatch-helper: cannot open the socket folder\n")
        }
        let (events, _, task) = run(host(), login: login.step)
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "\(events.values)") { plain(events) != nil }
        let reason = try XCTUnwrap(plain(events) ?? nil)
        XCTAssertTrue(reason.contains("dispatch-helper: cannot open the socket folder"), reason)
        XCTAssertEqual(login.roots, [.home], "only a 126 tries the runtime folder")
        task.cancel()

        let homeOnly = ScriptedLogin { root, _ in
            ScriptedHelperProcess(root: root, runtime: nil, exit: 126, stderr: "sh: ./dispatch-helper: Permission denied\n")
        }
        let (more, _, again) = run(host(), login: homeOnly.step)
        defer { again.cancel() }
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "\(more.values)") { plain(more) != nil }
        XCTAssertEqual(homeOnly.roots, [.home], "no runtime folder: no second attempt")
        XCTAssertTrue(homeOnly.isOpen)
    }

    /// Login and host key refusals stay final failures (no plain SSH, no retry); a connection lost while the helper was
    /// being installed reconnects.
    func testLoginFailuresStayRefusalsAndALossReconnects() async throws {
        let refusals: [any Error] = [
            SSHTransportError.authenticationFailed(methods: ["publickey"]),
            SSHTransportError.hostKeyRejected(ScriptedLogin.hostKey),
        ]
        for refusal in refusals {
            let (events, _, task) = run(host(), login: { _, _, _, _, _, _ in throw refusal })
            defer { task.cancel() }
            try await TestSupport.eventually(diagnostic: "\(events.values)") {
                events.values.contains { if case .link(.failed) = $0 { true } else { false } }
            }
            XCTAssertTrue(events.values.contains(.link(.failed(HostConnectionPolicy.describe(refusal)))), "\(events.values)")
            XCTAssertNil(plain(events))
        }

        let dropping = ScriptedLogin { _, login in
            login.drop()
            throw SSHTransportError.bootstrap("Could not use the authenticated SSH connection.")
        }
        let (events, _, task) = run(host(), login: dropping.step)
        defer { task.cancel() }
        try await TestSupport.eventually(diagnostic: "\(events.values)") {
            events.values.contains { if case .link(.reconnecting) = $0 { true } else { false } }
        }
        XCTAssertNil(plain(events))
        XCTAssertFalse(events.values.contains { if case .link(.failed) = $0 { true } else { false } })
    }

    /// The failure → reason mapping: the bootstrap's text, a refused channel, the exited helper's text; nothing for a
    /// connection that is gone or a failure that is not the helper's.
    func testTheFallbackReasons() {
        let installed = ScriptedHelperProcess.installed(root: .home, runtime: nil)
        XCTAssertEqual(SSHHostSessionDriver.fallback(SSHTransportError.bootstrap("SSH helper is missing or invalid."), open: true),
                       "SSH helper is missing or invalid.")
        XCTAssertEqual(SSHHostSessionDriver.fallback(SSHTransportError.commandFailed(status: -1, stderr: ""), open: true),
                       "The host refused to run the helper.")
        XCTAssertEqual(SSHHostSessionDriver.fallback(SSHTransportError.channelClosed, open: true), "The SSH channel closed.")
        XCTAssertEqual(SSHHostSessionDriver.fallback(HelperUnavailable("No."), open: true), "No.")
        let exited = HelperExited(status: 1, stderr: "boom\n", installed: installed)
        XCTAssertEqual(SSHHostSessionDriver.fallback(exited, open: true),
                       HelperBootstrap.launchFailure(status: 1, stderr: "boom\n", installed: installed))
        XCTAssertNil(SSHHostSessionDriver.fallback(SSHTransportError.bootstrap("x"), open: false), "the connection is gone: reconnect")
        XCTAssertNil(SSHHostSessionDriver.fallback(SSHTransportError.network("reset"), open: true))
        XCTAssertNil(SSHHostSessionDriver.fallback(SSHTransportError.timedOut("exec"), open: true))
        XCTAssertNil(SSHHostSessionDriver.fallback(CancellationError(), open: true))
        XCTAssertEqual(SSHHostSessionDriver.fallback(CocoaError(.fileReadNoSuchFile), open: true), "SSH helper is missing or invalid.",
                       "the bundled helper file is missing")
        do {
            _ = try Data(contentsOf: URL(fileURLWithPath: "/nonexistent-dispatch-helper/linux-aarch64"))
        } catch {
            XCTAssertEqual(SSHHostSessionDriver.fallback(error, open: true), "SSH helper is missing or invalid.", "\(error)")
        }

        XCTAssertTrue(SSHHostSessionDriver.ambiguous(HelperExited(status: nil, stderr: "", installed: installed)))
        XCTAssertTrue(SSHHostSessionDriver.ambiguous(SSHTransportError.channelClosed))
        XCTAssertFalse(SSHHostSessionDriver.ambiguous(HelperExited(status: 126, stderr: "", installed: installed)))
        XCTAssertFalse(SSHHostSessionDriver.ambiguous(SSHTransportError.bootstrap("x")))

        // The liveness probe: any answer from the server, a refused exec included, is alive.
        XCTAssertTrue(SSHLogin.answered(.success(())))
        XCTAssertTrue(SSHLogin.answered(.failure(SSHTransportError.commandFailed(status: -1, stderr: "refused"))))
        XCTAssertTrue(SSHLogin.answered(.failure(SSHTransportError.commandFailed(status: 1, stderr: ""))))
        XCTAssertFalse(SSHLogin.answered(.failure(SSHTransportError.channelClosed)))
        XCTAssertFalse(SSHLogin.answered(.failure(SSHTransportError.network("reset"))))
        XCTAssertFalse(SSHLogin.answered(.failure(SSHTransportError.timedOut("probe"))))
        XCTAssertFalse(SSHLogin.answered(.failure(CancellationError())))
    }
}

/// A scripted SSH login (`HostLogin`): no network. `bootstrap` answers each `bootstrapHelper` (by root) with a helper or
/// an error; it records the roots asked, and shells come from `opener`.
final class ScriptedLogin: HostLogin, @unchecked Sendable {
    static let hostKey = HostKeyInfo(host: "studio.local", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:fixture",
                                     openSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB")
    let opener = ScriptedShellOpener()
    private let bootstrap: @Sendable (HelperBootstrap.Root, ScriptedLogin) throws -> ScriptedHelperProcess
    private let state = Mutex<(roots: [HelperBootstrap.Root], open: Bool, waiters: [CheckedContinuation<Void, Never>])>(([], true, []))

    init(bootstrap: @escaping @Sendable (HelperBootstrap.Root, ScriptedLogin) throws -> ScriptedHelperProcess) {
        self.bootstrap = bootstrap
    }

    /// The driver's login step: this login, after reporting authenticating.
    var step: HostLoginStep {
        { _, _, _, _, _, phase in
            await phase(.authenticating)
            return self
        }
    }

    private let probing = Mutex<(result: Result<Void, any Error>, count: Int)>((.success(()), 0))

    var roots: [HelperBootstrap.Root] { state.withLock { $0.roots } }
    /// What the liveness probe's command gets (classified as the real login does, `SSHLogin.answered`), and how often it
    /// was asked.
    var probe: Result<Void, any Error> {
        get { probing.withLock { $0.result } }
        set { probing.withLock { $0.result = newValue } }
    }
    var probes: Int { probing.withLock { $0.count } }

    func alive(timeout: Duration) async -> Bool {
        let result = probing.withLock { probing in
            probing.count += 1
            return probing.result
        }
        return SSHLogin.answered(result) && isOpen
    }
    var isOpen: Bool { state.withLock { $0.open } }
    var lossReason: String? { isOpen ? nil : "The connection was lost." }
    var shells: any ShellOpener { opener }

    /// The connection goes (a network loss).
    func drop() {
        let waiters = state.withLock { state in
            state.open = false
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func closed() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let open = state.withLock { state in
                if state.open { state.waiters.append(waiter) }
                return state.open
            }
            if !open { waiter.resume() }
        }
    }

    func close() async { drop() }

    func bootstrapHelper(binaries: URL, capabilities: String, environment: [String: String], root: HelperBootstrap.Root,
                         phase: @escaping @Sendable (HostConnectionPhase) async -> Void) async throws -> any HelperProcess {
        await phase(.bootstrapping)
        state.withLock { $0.roots.append(root) }
        return try bootstrap(root, self)
    }
}

/// A started helper (`HelperProcess`): a `ScriptedHelper` answering `hello` (and the multiplexer requests), or one that
/// exits with `exit` and `stderr` before answering.
final class ScriptedHelperProcess: HelperProcess, @unchecked Sendable {
    let installed: HelperBootstrap.Installed
    /// The launch command the real bootstrap runs for `installed`.
    let command: String
    private let helper: ScriptedHelper
    private let said: String
    private let state = Mutex<(closed: Bool, status: Int32??, waiters: [CheckedContinuation<Int32?, Never>])>((false, nil, []))

    var connection: HelperConnection { helper.client.connection }
    var isClosed: Bool { state.withLock { $0.closed } }

    /// `lost`: the channel ends with no exit status before answering (a signal, or the connection going).
    init(root: HelperBootstrap.Root, runtime: String? = nil, hello: [String: Any]? = nil, exit: Int32? = nil, lost: Bool = false,
         stderr: String = "") {
        installed = Self.installed(root: root, runtime: runtime)
        command = HelperBootstrap.launchCommand(installed)
        said = stderr
        nonisolated(unsafe) let hello = hello
        helper = ScriptedHelper.scripted { request in
            switch request.method {
            case "hello": hello.map { .result($0) }
            case "multiplexers.list": .result([["mux": 0, "name": "tmux", "external": true, "installed": true]])
            case "backends.list": .result([["mux": 0, "key": "tmux", "label": "tmux", "default": true]])
            default: nil
            }
        }
        if exit != nil || lost {
            // The helper ends before answering: its status first, then its channel closes under the request.
            end(exit)
            helper.close()
        }
    }

    private func end(_ status: Int32?) {
        let waiters = state.withLock { state -> [CheckedContinuation<Int32?, Never>] in
            guard state.status == nil else { return [] }
            state.status = .some(status)
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: status) }
    }

    func exitStatus() async -> Int32? {
        await withCheckedContinuation { (waiter: CheckedContinuation<Int32?, Never>) in
            let status = state.withLock { state -> Int32?? in
                if let status = state.status { return status }
                state.waiters.append(waiter)
                return nil
            }
            if let status { waiter.resume(returning: status) }
        }
    }

    func stderr() async -> String { said }

    func close() async {
        state.withLock { $0.closed = true }
        helper.close()
        end(nil)
    }

    /// A `hello` as the helper sends it.
    static func hello(version: UInt64 = HelperBinary.version, limits: Bool = true) -> [String: Any] {
        var hello: [String: Any] = [
            "version": version, "os": "linux", "arch": "aarch64", "plugins": ["files", "stats"],
            "unavailable_harnesses": [String](),
            "ops": ["hello", "echo", "multiplexers.list", "backends.list", "backends.open", "stats.processes"],
            "account": ["uid": 1000, "home": "/home/alex"] as [String: Any],
        ]
        if limits {
            hello["frame_limit"] = 12_000_013
            hello["chunk_kind"] = 5
            hello["chunk_limit"] = 65_536
        }
        return hello
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

extension ScriptedHelperProcess {
    /// What the bootstrap reports for a fixture helper under `root`, the probe having seen `runtime` as a usable
    /// `$XDG_RUNTIME_DIR` (nil: none).
    static func installed(root: HelperBootstrap.Root, runtime: String?) -> HelperBootstrap.Installed {
        HelperBootstrap.Installed(platform: "linux-aarch64", digest: String(repeating: "ab", count: 32), size: 4_096, root: root,
                                  uploaded: false, runtimeDirectory: runtime)
    }
}
