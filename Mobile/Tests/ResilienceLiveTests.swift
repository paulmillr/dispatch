import XCTest
@testable import DispatchMobile

/// Resilience against this Mac's fixture sshd (`scripts/mobile-live-fixture.py start` and `serve`, passed as
/// `TEST_RUNNER_DISPATCH_LIVE_FIXTURE=/tmp/sim-…/live.json`; skipped without it): a first run fills the cache file, a
/// second launch shows the cached spaces before it connects and keeps the same rows when the live data arrives, the
/// sshd going away turns the thread's banner to M4c's "Reconnecting", and a network change after it returns reconnects
/// at once. Full suite: it needs the fixture.
@MainActor
final class ResilienceLiveTests: XCTestCase {
    private struct Live: Decodable {
        let host: String
        let port: Int
        let user: String
        let keyFile: String
        let root: String
    }

    private func live() throws -> Live {
        guard let path = ProcessInfo.processInfo.environment["DISPATCH_LIVE_FIXTURE"] else {
            throw XCTSkip("No live fixture (TEST_RUNNER_DISPATCH_LIVE_FIXTURE)")
        }
        return try JSONDecoder().decode(Live.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func ask(_ command: String, live: Live) async throws {
        let requests = URL(fileURLWithPath: live.root).appendingPathComponent("requests")
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(command)"
        try Data().write(to: requests.appendingPathComponent(name))
        try await TestSupport.eventually(timeout: .seconds(15)) {
            FileManager.default.fileExists(atPath: requests.appendingPathComponent(name + ".done").path)
        }
    }

    func testTheCacheAndAReconnectAgainstTheFixture() async throws {
        let live = try live()
        guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: live.root).appendingPathComponent("requests").path) else {
            throw XCTSkip("No `mobile-live-fixture.py serve`: the reconnect needs it")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("live-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("host-cache.json")
        let keys = KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none, secureEnclaveAvailable: false)
        let key = try keys.importKey(Data(contentsOf: URL(fileURLWithPath: live.keyFile)), label: "fixture")
        let record = HostRecord(name: "this-mac", address: live.host, port: live.port, user: live.user, auth: .key(key.id))
        let known = KnownHostStore(url: nil)
        func sessions(active: Bool) -> HostSessions {
            HostSessions(store: HostStore(url: nil, hosts: [record]), keys: keys, knownHosts: known,
                         driver: SSHHostSessionDriver(pingInterval: .seconds(1)), active: active)
        }

        // First run: trust, connect, and the cache file gets the host's live state.
        let first = sessions(active: true)
        let firstApp = ResilienceFixture.composition(first, cache: HostCache(url: file))
        try await TestSupport.eventually(timeout: .seconds(15)) { first.trustRequest != nil }
        first.resolve(try XCTUnwrap(first.trustRequest), trust: true)
        try await TestSupport.eventually(timeout: .seconds(30)) { first.session(record.id)?.link == .connected }
        let spaces = try XCTUnwrap(firstApp.tabs.workspace(record.id)).spaces.map(\.name)
        XCTAssertFalse(spaces.isEmpty)
        firstApp.scenePhaseChanged(.background)
        XCTAssertEqual(first.session(record.id)?.link, .disconnected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "written when the app went to the background")

        // A second launch: the first frame shows the cached spaces, stale; connecting keeps the same rows.
        let launched = ContinuousClock.now
        let second = sessions(active: false)
        let app = ResilienceFixture.composition(second, cache: HostCache(url: file))
        let workspace = try XCTUnwrap(app.tabs.workspace(record.id))
        print("MEASURE live.launch_to_cached_rows \(ContinuousClock.now - launched)")
        XCTAssertEqual(workspace.spaces.map(\.name), spaces, "from the cache, before any connection")
        XCTAssertNotEqual(workspace.host.state, .connected)
        XCTAssertEqual(second.session(record.id)?.multiplexerLine?.hasPrefix("tmux"), true)
        let rows = workspace.tabs.map(ObjectIdentifier.init)
        let started = ContinuousClock.now
        second.setActive(true)
        let session = try XCTUnwrap(second.session(record.id))
        try await TestSupport.eventually(timeout: .seconds(30)) { session.link == .connected && workspace.host.state == .connected }
        print("MEASURE live.cached_to_live \(ContinuousClock.now - started)")
        XCTAssertEqual(workspace.tabs.map(ObjectIdentifier.init), rows, "the cached rows became the live ones in place")

        // The sshd goes away: M4c's banner; back, a network change reconnects at once.
        let thread = app.conversations.session(for: ChatConversationKey(host: record.id, node: workspace.tabs.first?.panes.first?.key ?? "x"))
        XCTAssertNil(ChatLinkBanner.title(thread.link, host: "this-mac"))
        try await ask("stop-sshd", live: live)
        let dropped = ContinuousClock.now
        try await TestSupport.eventually(timeout: .seconds(10)) { if case .reconnecting = session.link { true } else { false } }
        print("MEASURE live.drop_to_reconnecting \(ContinuousClock.now - dropped)")
        XCTAssertEqual(ChatLinkBanner.title(thread.link, host: "this-mac"), "Reconnecting to this-mac")
        XCTAssertEqual(workspace.tabs.map(ObjectIdentifier.init), rows, "the rows stay while reconnecting")
        try await ask("start-sshd", live: live)
        let restarted = ContinuousClock.now
        second.networkChanged()
        try await TestSupport.eventually(timeout: .seconds(30)) { session.link == .connected }
        print("MEASURE live.network_change_to_connected \(ContinuousClock.now - restarted)")
        XCTAssertNil(ChatLinkBanner.title(thread.link, host: "this-mac"))
        XCTAssertEqual(workspace.tabs.map(ObjectIdentifier.init), rows)
        // A live connection checks itself on a network change and stays up.
        second.networkChanged()
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(session.link, .connected)
        second.setActive(false)
    }
}
