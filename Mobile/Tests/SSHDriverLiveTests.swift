import XCTest
@testable import DispatchMobile

/// `SSHHostSessionDriver` against this Mac's fixture sshd (`scripts/mobile-live-fixture.py start /tmp/sim-…`, passed as
/// `TEST_RUNNER_DISPATCH_LIVE_FIXTURE=/tmp/sim-…/live.json`; skipped without it): trust on first use, key login, the
/// bundled helper's install and hello, the private tmux server's topology, latency, and a reconnect after the sshd
/// drops (with `scripts/mobile-live-fixture.py serve` running). Full suite: it needs the fixture.
@MainActor
final class SSHDriverLiveTests: XCTestCase {
    struct Live: Decodable {
        let host: String
        let port: Int
        let user: String
        let keyFile: String
        let root: String
        let home: String
    }

    private func live() throws -> Live {
        guard let path = ProcessInfo.processInfo.environment["DISPATCH_LIVE_FIXTURE"] else {
            throw XCTSkip("No live fixture (TEST_RUNNER_DISPATCH_LIVE_FIXTURE)")
        }
        return try JSONDecoder().decode(Live.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func sessions(_ live: Live, helper: Bool = true) throws -> (HostSessions, HostRecord) {
        let keys = KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none, secureEnclaveAvailable: false)
        let key = try keys.importKey(Data(contentsOf: URL(fileURLWithPath: live.keyFile)), label: "fixture")
        let record = HostRecord(name: "this-mac", address: live.host, port: live.port, user: live.user, auth: .key(key.id),
                                helper: helper)
        let sessions = HostSessions(store: HostStore(url: nil), keys: keys, knownHosts: KnownHostStore(url: nil),
                                    driver: SSHHostSessionDriver(pingInterval: .seconds(1)), active: true)
        return (sessions, record)
    }

    /// Asks the fixture's `serve` loop to run `command` and waits until it did.
    private func ask(_ command: String, live: Live) async throws {
        let requests = URL(fileURLWithPath: live.root).appendingPathComponent("requests")
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(command)"
        try Data().write(to: requests.appendingPathComponent(name))
        try await TestSupport.eventually(timeout: .seconds(15)) {
            FileManager.default.fileExists(atPath: requests.appendingPathComponent(name + ".done").path)
        }
    }

    func testConnectsTrustsInstallsAndFollowsTheTopology() async throws {
        let live = try live()
        let (sessions, record) = try sessions(live)
        let started = ContinuousClock.now
        let probe = sessions.probe(record)
        probe.connect()
        try await TestSupport.eventually(timeout: .seconds(15)) { sessions.trustRequest != nil }
        let asked = ContinuousClock.now - started
        let request = try XCTUnwrap(sessions.trustRequest)
        XCTAssertEqual(request.kind, .unknown)
        XCTAssertEqual(request.offer.algorithm, "ssh-ed25519")
        sessions.resolve(request, trust: true)
        let trusted = ContinuousClock.now
        try await TestSupport.eventually(timeout: .seconds(30), diagnostic: "link: \(probe.link)") { probe.link == .connected }
        let connected = ContinuousClock.now - trusted
        print("MEASURE live.connect_to_trust_question \(asked)")
        print("MEASURE live.trust_to_connected \(connected)")
        let hello = try XCTUnwrap(probe.hello)
        XCTAssertEqual(hello.identity?.os, "Darwin")
        XCTAssertTrue(hello.identity?.os_label?.hasPrefix("macOS ") == true)
        XCTAssertEqual(Set(hello.features ?? []), Set(SSHHostSessionDriver.features))
        XCTAssertTrue(probe.multiplexers.contains { $0.name == "tmux" })
        XCTAssertEqual(probe.following, "tmux", "the running tmux server, never a herdr server started for the phone")
        XCTAssertNotNil(probe.multiplexerVersions["tmux"])
        let spaces = Set(probe.topology?.nodes.filter { $0.kind == .workspace }.map(\.key) ?? [])
        XCTAssertFalse(spaces.isEmpty, "the private tmux server's spaces arrive with .ready")
        try await TestSupport.eventually(timeout: .seconds(5)) { probe.latency != nil }
        print("MEASURE live.latency \(probe.latency!)")
        sessions.add(record, probe: probe)
        XCTAssertTrue(sessions.session(record.id) === probe)

        // The sshd and its sessions go away: reconnecting, then connected again once it is back.
        let requests = URL(fileURLWithPath: live.root).appendingPathComponent("requests")
        guard FileManager.default.fileExists(atPath: requests.path) else {
            probe.disconnect()
            throw XCTSkip("No `mobile-live-fixture.py serve`: the reconnect half needs it")
        }
        let firstClient = probe.client
        try await ask("stop-sshd", live: live)
        let dropped = ContinuousClock.now
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "link: \(probe.link)") {
            if case .reconnecting = probe.link { true } else { false }
        }
        print("MEASURE live.drop_to_reconnecting \(ContinuousClock.now - dropped)")
        XCTAssertNil(probe.client)
        XCTAssertNotNil(probe.topology, "the spaces stay listed while reconnecting")
        try await ask("start-sshd", live: live)
        let restarted = ContinuousClock.now
        probe.retryNow()
        try await TestSupport.eventually(timeout: .seconds(30), diagnostic: "link: \(probe.link)") { probe.link == .connected }
        print("MEASURE live.restart_to_connected \(ContinuousClock.now - restarted)")
        XCTAssertNotNil(probe.client)
        XCTAssertFalse(probe.client === firstClient, "a new helper connection")
        XCTAssertEqual(Set(probe.topology?.nodes.filter { $0.kind == .workspace }.map(\.key) ?? []), spaces,
                       "the same spaces, by key, through the new helper")
        probe.disconnect()
    }

    /// The Helper switch off: connected after the login with nothing installed or started, and a PTY shell on the
    /// connection that runs commands at its size and reports its exit status.
    func testAHostWithoutTheHelperOpensShells() async throws {
        let live = try live()
        let (sessions, record) = try sessions(live, helper: false)
        let probe = sessions.probe(record)
        probe.connect()
        try await TestSupport.eventually(timeout: .seconds(15)) { sessions.trustRequest != nil }
        sessions.resolve(try XCTUnwrap(sessions.trustRequest), trust: true)
        try await TestSupport.eventually(timeout: .seconds(30), diagnostic: "link: \(probe.link)") { probe.link == .connected }
        XCTAssertEqual(probe.mode, .plain(reason: nil))
        XCTAssertNil(probe.client)
        XCTAssertNil(probe.hello)
        XCTAssertNil(probe.multiplexerLine)

        let shell = try await XCTUnwrap(probe.shellOpener).open(term: "xterm-256color", columns: 91, rows: 27)
        let screen = Recorder<Data>()
        let reading = Task.detached { for await data in shell.output { screen.append(data) } }
        defer { reading.cancel() }
        let seen = { String(decoding: screen.values.reduce(Data(), +), as: UTF8.self) }
        try await shell.write(Data("stty size; echo dispatch-$((40 + 2))\n".utf8))
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: seen()) {
            seen().contains("dispatch-42") && seen().contains("27 91")
        }
        try await shell.write(Data("exit 3\n".utf8))
        let exit = await shell.exit()
        XCTAssertEqual(exit, .status(3))
        probe.disconnect()
    }

    func testAnUntrustedHostKeyFailsWithoutRetrying() async throws {
        let live = try live()
        let (sessions, record) = try sessions(live)
        let probe = sessions.probe(record)
        probe.connect()
        try await TestSupport.eventually(timeout: .seconds(15)) { sessions.trustRequest != nil }
        sessions.resolve(try XCTUnwrap(sessions.trustRequest), trust: false)
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "link: \(probe.link)") {
            if case .failed = probe.link { true } else { false }
        }
        XCTAssertNil(probe.client)
    }

    func testAKeyTheHostDoesNotKnowIsRefused() async throws {
        let live = try live()
        let keys = KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none, secureEnclaveAvailable: false)
        let key = try keys.generateED25519(label: "stranger")
        let record = HostRecord(name: "this-mac", address: live.host, port: live.port, user: live.user, auth: .key(key.id))
        let known = KnownHostStore(url: nil)
        let sessions = HostSessions(store: HostStore(url: nil), keys: keys, knownHosts: known,
                                    driver: SSHHostSessionDriver(), active: true)
        let probe = sessions.probe(record)
        probe.connect()
        try await TestSupport.eventually(timeout: .seconds(15)) { sessions.trustRequest != nil }
        sessions.resolve(try XCTUnwrap(sessions.trustRequest), trust: true)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "link: \(probe.link)") {
            if case .failed = probe.link { true } else { false }
        }
        guard case .failed(let reason) = probe.link else { return }
        XCTAssertTrue(reason.contains("Authentication failed"), reason)
    }
}
