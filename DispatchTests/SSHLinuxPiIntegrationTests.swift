import AppKit
import XCTest
@testable import DispatchApp

/// The real Linux Pi process and its existing package remain on the separate
/// SSH VM; only disposable fixture scripts are copied from the macOS client.
@MainActor
final class SSHLinuxPiIntegrationTests: XCTestCase {
    func testLinuxPlainPiChat() async throws { try await walkthrough("plain") }
    func testLinuxTmuxPiChat() async throws { try await walkthrough("tmux") }
    func testLinuxHerdrPiChat() async throws { try await walkthrough("herdr") }

    func testLinuxPlainTransportAndSessionLifecycle() async throws { try await walkthrough("plain", transportOnly: true) }
    func testLinuxTmuxTransportAndSessionLifecycle() async throws { try await walkthrough("tmux", transportOnly: true) }
    func testLinuxHerdrTransportAndSessionLifecycle() async throws { try await walkthrough("herdr", transportOnly: true) }

    private func walkthrough(_ backend: String, transportOnly: Bool = false) async throws {
        let phaseTimings = WalkthroughTimings(test: name, agent: "pi", transport: "linux-" + backend)
        phaseTimings.begin("SSH_setup")
        var passed = false
        defer { phaseTimings.save(passed: passed && testRun?.failureCount == 0) }
        let profile = try JSONDecoder().decode(SSHLinuxTestProfile.self,
            from: Data(contentsOf: SSHLinuxTestProfile.configurationURL()))
        let pi = try XCTUnwrap(profile.pi, "Add --pi PATH to the Linux test profile; no package is downloaded")
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let origin = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { runtime.views[origin].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let terminal = try XCTUnwrap(runtime.views[origin])
        try await SSHTestServer.authorize(arguments: profile.options + [profile.destination], grant: .init(profile: .full, hooks: true))
        TerminalTestSupport.send("ssh " + (profile.options + [profile.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
        try await TestSupport.eventually(timeout: .seconds(25)) {
            runtime.ssh.links.values.contains { $0.launch.tabID == origin && $0.shellPID != nil }
        }
        let ssh = try XCTUnwrap(runtime.ssh.links.values.first { $0.launch.tabID == origin })
        let root = "/tmp/dispatch-pi-linux-" + UUID().uuidString, state = root + "/state"
        let socket = root + "/" + backend + ".sock"
        @discardableResult
        func remote(_ argv: [String], input: Data = Data()) async throws -> Data {
            let result = try await SSHTestCommand.run(master: ssh.launch.master, argv: argv, input: input)
            guard result.status == 0 else { throw HerdrFailure("Linux Pi fixture command failed: " + String(decoding: result.output, as: UTF8.self)) }
            return result.output
        }
        phaseTimings.begin("endpoint_startup")
        try await remote(["/bin/mkdir", "-m", "700", root])
        for (source, destination) in [("scripts/claude_fixture.py", "claude_fixture.py"), ("scripts/pi_fixture.py", "pi_fixture.py"),
            ("scripts/fixture_barriers.py", "fixture_barriers.py"),
            ("helper/harnesses/pi/resources/bridge.js", "pi-chat.js"), ("scripts/fixtures/pi-navigation.js", "pi-navigation.js")] {
            try await remote(["/usr/bin/tee", root + "/" + destination], input: Data(contentsOf: CodexTestSupport.root.appendingPathComponent(source)))
        }
        let fixture = try SSHTestDaemon(master: ssh.launch.master,
            argv: ["/usr/bin/python3", root + "/claude_fixture.py", "serve", "--state", state, "--delay", transportOnly ? "0" : "0.035"], pidFile: root + "/fixture.pid")
        func cleanup() async {
            // Ending tmux control mode closes this SSH session: stop the fixture first.
            await fixture.stop()
            if backend == "herdr" {
                do { try await SSHTestCommand.stopHerdr(master: ssh.launch.master, socket: socket) }
                catch { XCTFail("Cannot stop isolated Linux Pi herdr fixture: " + error.localizedDescription) }
            }
            if backend == "tmux" { _ = try? await remote([profile.supportedTmuxPath, "-S", socket, "kill-server"]) }
            print("Linux Pi \(backend) fixture retained at " + root)
        }
        do {
            try await fixture.waitUntilReady(marker: "Local Claude endpoint:")
            if backend == "tmux" {
                TerminalTestSupport.send(HerdrLaunch.quote(profile.supportedTmuxPath) + " -u -S " + HerdrLaunch.quote(socket) + " -f /dev/null -CC new-session -s pi /bin/bash", to: terminal)
                try await app.wait { app.workspace.current?.structured == true }
            } else if backend == "herdr" {
                TerminalTestSupport.send("export PATH=" + HerdrLaunch.quote(profile.path) + "; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(root)
                    + "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr", to: terminal)
                try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: terminal)) { app.workspace.current?.shows("herdr") == true }
            }
            let launch = ["/usr/bin/env", "TZ=Asia/Kathmandu", "python3", root + "/pi_fixture.py", "--state", state, "--pi", pi,
                          "--extension", root + "/pi-chat.js", "--extension", root + "/pi-navigation.js"].map(HerdrLaunch.quote).joined(separator: " ")
            phaseTimings.begin("agent_readiness")
            let exercised = try await SSHPiIntegrationTests.exercise("Linux " + backend, app: app, launch: launch, transportOnly: transportOnly, timings: phaseTimings)
            let session = exercised.session, conversation = try XCTUnwrap(session.sessionID)
            let view = try XCTUnwrap(runtime.views[session.id])
            runtime.chat.chooseChat(false, session: session)
            TerminalTestSupport.send("/dispatch-test-branch " + exercised.firstLeaf, to: view)
            _ = try await SSHPiIntegrationTests.waitForState(session) { $0.leafID == exercised.firstLeaf && !$0.busy }
            try await TestSupport.eventually(timeout: .seconds(15)) {
                !session.loadingHistory && session.turns.flatMap(\.items).filter { $0.kind == .user }.count == 1
            }
            XCTAssertFalse(SSHPiIntegrationTests.reply("recovered SSH Pi", in: session))
            runtime.chat.chooseChat(true, session: session)
            try await SSHPiIntegrationTests.waitForInputReady(session)
            session.draft = "/new"; runtime.chat.submit(session)
            try await TestSupport.eventually(timeout: .seconds(15)) { session.active && session.sessionID != conversation && !session.loadingHistory && !session.busy }
            XCTAssertTrue(session.turns.isEmpty)
            runtime.chat.chooseChat(true, session: session)
            session.draft = "Linux replacement Pi"; runtime.chat.submit(session)
            try await TestSupport.eventually(timeout: .seconds(20)) { !session.busy && SSHPiIntegrationTests.reply("Local Claude fixture reply: Linux replacement Pi", in: session) }
            session.draft = "/quit"; runtime.chat.submit(session)
            try await TestSupport.eventually(timeout: .seconds(15)) { !session.active }
            XCTAssertTrue(runtime.chat.canEnterChat(session))
            phaseTimings.begin("teardown")
            await cleanup(); await app.close().value
            passed = testRun?.failureCount == 0
        } catch {
            phaseTimings.begin("teardown")
            await cleanup(); await app.close().value
            throw error
        }
    }
}
