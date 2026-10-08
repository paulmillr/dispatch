import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class SSHProfileIntegrationTests: XCTestCase {
    func testExplicitTmuxControlModeWithOrdinarySSH() async throws { try await controlMode(.ordinary) }
    func testExplicitTmuxControlModeWithStatisticsOnly() async throws { try await controlMode(.statistics) }
    func testExplicitTmuxControlModeWithFullIntegration() async throws { try await controlMode(.full) }

    private func controlMode(_ profile: SSHIntegrationProfile) async throws {
        let grant = SSHIntegrationGrant(profile: profile)
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(grant: grant); defer { server.stop() }
        let origin = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { app.runtime.views[origin].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let terminal = try XCTUnwrap(app.runtime.views[origin])
        let command = "printf 'PROFILE_SHELL_%s\\n' READY; exec /bin/zsh -l"
        let arguments = ["-tt"] + server.options + [server.destination, command]
        try await server.authorize(grant, arguments: arguments)
        // Ordinary SSH preserves the caller's TERM and never installs terminal resources.
        TerminalTestSupport.send("ssh " + arguments.map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            TerminalTestSupport.screen(terminal: terminal).contains("PROFILE_SHELL_READY")
        }
        if profile == .ordinary {
            XCTAssertTrue(app.runtime.ssh.links.isEmpty, "Ordinary SSH must never establish a helper connection")
            TerminalTestSupport.send("test -z \"${DISPATCH_SSH_SESSION-}\" && printf 'PROFILE_NO_%s\\n' HELPER", to: terminal)
            try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("PROFILE_NO_HELPER") }
        } else {
            let session = try XCTUnwrap(app.runtime.ssh.links.values.first { $0.launch.tabID == origin })
            XCTAssertEqual(session.grant.profile, profile)
            XCTAssertEqual(session.greeting.profile, profile)
        }
        try await app.attach()
        try await app.ready()
        let pane = try XCTUnwrap(app.workspace.activeSurfaceID)
        let view = try XCTUnwrap(app.runtime.views[pane])
        TerminalTestSupport.send("printf 'PROFILE_TMUX_%s\\n' ALIVE", to: view)
        try await app.wait { TerminalTestSupport.screen(terminal: view).contains("PROFILE_TMUX_ALIVE") }
        XCTAssertTrue(app.workspace.current?.structured == true)
        if profile == .ordinary { XCTAssertTrue(app.runtime.ssh.links.isEmpty) }
        app.workspace.detachSpace(try XCTUnwrap(app.workspace.current?.id))
        try await app.wait { app.workspace.spaces.allSatisfy { !$0.shows("tmux") } }
        app.workspace.selectTab(origin)
        try await app.wait { terminal.isPresented }
        TerminalTestSupport.send("printf 'PROFILE_AFTER_%s\\n' DETACH", to: terminal)
        try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("PROFILE_AFTER_DETACH") }
        TerminalTestSupport.send("exit", to: terminal)
        try await app.wait { app.runtime.ssh.links.isEmpty }
    }
}
