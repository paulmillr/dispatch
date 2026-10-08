import AppKit
import Term
import XCTest
@testable import DispatchApp

@MainActor
final class SSHCompatibilityTests: XCTestCase {
    func testConfiguredJumpHostKeepsIntegrationAndExplicitCommandStatus() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let jump = try await SSHTestServer(); defer { jump.stop() }
        let target = try await SSHTestServer(); defer { target.stop() }
        let marker = target.root.appendingPathComponent("jump-used")
        let configuration = target.root.appendingPathComponent("config")
        func host(_ name: String, _ server: SSHTestServer) -> String {
            """
            Host \(name)
              HostName 127.0.0.1
              Port \(server.port)
              User \(NSUserName())
              IdentityFile \(server.root.appendingPathComponent("key").path)
              UserKnownHostsFile \(server.root.appendingPathComponent("known_hosts").path)
              StrictHostKeyChecking yes
              IdentitiesOnly yes
              BatchMode yes
              LogLevel ERROR

            """
        }
        let proxy = "printf reached > \"$1\"; exec /usr/bin/nc \"$2\" \"$3\""
        try (host("dispatch-test-jump", jump) + "  ProxyCommand /bin/sh -c " + HerdrLaunch.quote(proxy) +
             " jump-proxy " + marker.path + " %h %p\n" + host("dispatch-test-target", target) +
             "  ProxyJump dispatch-test-jump\n").write(to: configuration, atomically: true, encoding: .utf8)
        let source = try XCTUnwrap(app.workspace.activeTab?.id)
        let terminal = try await origin(app, id: source)
        let arguments = ["-F", configuration.path, "dispatch-test-target"]
        try await target.authorize(arguments: arguments)
        TerminalTestSupport.send("ssh " + arguments.map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
        try await connected(app, source: source)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "reached", "The authenticated connection must actually traverse its configured jump host")
        TerminalTestSupport.send("printf 'JUMP_INTEGRATION_%s\\n' \"${DISPATCH_SSH_HELPER:+yes}\"", to: terminal)
        try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("JUMP_INTEGRATION_yes") }
        TerminalTestSupport.send("exit", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            app.runtime.ssh.machine(for: source) == nil
        }
        let command = "printf 'JUMP_COMMAND_%s\\n' OK; exit 23"
        TerminalTestSupport.send("ssh -tt " + (arguments + [command]).map(HerdrLaunch.quote).joined(separator: " ") +
            "; printf 'JUMP_STATUS_%s\\n' \"$?\"", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            let screen = TerminalTestSupport.screen(terminal: terminal)
            return screen.contains("JUMP_COMMAND_OK") && screen.contains("JUMP_STATUS_23")
        }
        XCTAssertNotEqual(app.workspace.current?.shows("tmux"), true)
        XCTAssertNotEqual(app.workspace.current?.shows("herdr"), true)
    }

    func testNestedSSHDoesNotAdoptTheInnerAgentAsAnOuterHostAgent() async throws {
        let fixture = try CodexEndpointFixture(prefix: "dispatch-nested-ssh-", delay: 0.01, hooks: false)
        var passed = false
        defer { fixture.stop(removeState: passed) }
        try await fixture.start(timeout: .seconds(15))
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(); defer { app.close() }
        let outer = try await SSHTestServer(); defer { outer.stop() }
        let inner = try await SSHTestServer(); defer { inner.stop() }
        let source = try XCTUnwrap(app.workspace.activeTab?.id)
        let terminal = try await origin(app, id: source)
        TerminalTestSupport.send(ssh(outer), to: terminal)
        try await connected(app, source: source)
        let link = try XCTUnwrap(runtime.link(of: source))
        let command = CodexTestSupport.command(state: fixture.state, binary: fixture.binary)
        TerminalTestSupport.send("ssh " + (["-tt"] + inner.options + [inner.destination, command]).map(HerdrLaunch.quote).joined(separator: " ") +
            "; printf 'NESTED_%s\\n' RETURNED", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            TerminalTestSupport.screen(terminal: terminal).contains("dispatch-fixture default")
        }
        // The foreground nested ssh client suppresses discovery on the outer host: no chat binds there.
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(runtime.ssh.links.count, 1, "Nested SSH must not create a second enhanced connection")
        XCTAssertFalse(runtime.chat.session(for: source).active)
        try await sendAgent("/quit", to: terminal)
        try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("NESTED_RETURNED") }
        TerminalTestSupport.send(command, to: terminal)
        let session = runtime.chat.session(for: source)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: session.status ?? "No outer agent") {
            session.active && session.remoteAgent != nil
        }
        XCTAssertEqual(session.remoteAgent?.host, link.greeting.hostID)
        passed = true
    }

    func testRemoteTmuxDiscoversAgentsStartedBeforeSSHInInactiveWindows() async throws {
        let fixture = try CodexEndpointFixture(prefix: "dispatch-inactive-ssh-", delay: 0.01, hooks: false)
        var passed = false
        defer { fixture.stop(removeState: passed) }
        try await fixture.start(timeout: .seconds(15))
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(); defer { app.close() }
        let command = CodexTestSupport.command(state: fixture.state, binary: fixture.binary)
        _ = try app.server(["send-keys", "-t", "%0", command, "Enter"])
        try await TestSupport.eventually(timeout: .seconds(15)) {
            try app.server(["capture-pane", "-p", "-t", "%0"]).contains("dispatch-fixture default")
        }
        _ = try app.server(["new-window", "-t", "edge", "/bin/sh"])
        _ = try app.server(["send-keys", "-t", "%1", command, "Enter"])
        try await TestSupport.eventually(timeout: .seconds(15)) {
            try app.server(["capture-pane", "-p", "-t", "%1"]).contains("dispatch-fixture default")
        }
        let server = try await SSHTestServer(); defer { server.stop() }
        let source = try XCTUnwrap(app.workspace.activeTab?.id)
        let terminal = try await origin(app, id: source)
        TerminalTestSupport.send(ssh(server), to: terminal)
        try await connected(app, source: source)
        try await app.attach()
        func tab(_ pane: Int) -> TerminalTab? { app.workspace.spaces.flatMap(\.tabs).first { app.target($0) == "%\(pane)" } }
        let first = try XCTUnwrap(tab(0)), second = try XCTUnwrap(tab(1))
        let a = runtime.chat.session(for: first.id), b = runtime.chat.session(for: second.id)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "\(a.status ?? "first") / \(b.status ?? "second")") {
            a.active && b.active && a.remoteAgent != nil && b.remoteAgent != nil
        }
        XCTAssertNil(runtime.views[first.id], "Discover a remote agent in a window that has never been mounted")
        XCTAssertNotEqual(a.remoteAgent?.pid, b.remoteAgent?.pid)
        XCTAssertNil(a.process); XCTAssertNil(b.process)
        XCTAssertFalse(runtime.chat.session(for: source).active)
        app.workspace.selectTab(first.id)
        try await app.ready()
        runtime.chat.chooseChat(true, session: a)
        a.draft = "Previously inactive remote window\nsecond line"
        runtime.chat.submit(a)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: a.status ?? "No inactive-window reply") {
            a.draft.isEmpty && !a.busy && a.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: Previously inactive remote window\nsecond line" }
        }
        XCTAssertNil(b.sessionID, "Submitting in the activated window must not route to its neighbor")
        passed = true
    }

    func testIntegrationTogglesApplyInsideAnAlreadyOpenSSHShell() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let stub = server.root.appendingPathComponent("herdr"), socket = server.root.appendingPathComponent("herdr.sock").path
        defer { _ = try? HerdrSocket(path: socket).request("server.stop") }
        try "#!/bin/sh\nprintf 'REMOTE_HERDR_%s\\n' PASSTHROUGH\nexit 17\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        let source = try XCTUnwrap(app.workspace.activeTab?.id)
        let terminal = try await origin(app, id: source)
        TerminalTestSupport.send(ssh(server), to: terminal)
        try await connected(app, source: source)
        let identity = try XCTUnwrap(app.runtime.ssh.links.values.first { $0.launch.tabID == source }?.launch.connectionID)
        var preferences = app.runtime.preferences
        preferences.spaces[on: "herdr"] = false
        try app.runtime.apply(preferences)
        TerminalTestSupport.send("export PATH=" + HerdrLaunch.quote(server.root.path) +
            ":\(TestSupport.path):/usr/bin:/bin; herdr; printf 'REMOTE_HERDR_STATUS_%s\\n' \"$?\"", to: terminal)
        try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("REMOTE_HERDR_STATUS_17") }
        XCTAssertTrue(TerminalTestSupport.screen(terminal: terminal).contains("REMOTE_HERDR_PASSTHROUGH"))
        XCTAssertNotEqual(app.workspace.current?.shows("herdr"), true)
        try await app.attach()
        let tmuxSpace = try XCTUnwrap(app.workspace.current?.id)
        app.workspace.detachSpace(tmuxSpace)
        try await app.wait { app.workspace.spaces.allSatisfy { !$0.shows("tmux") } }
        app.workspace.selectTab(source)
        preferences.spaces[on: "tmux"] = false; preferences.spaces[on: "herdr"] = true
        try app.runtime.apply(preferences)
        TerminalTestSupport.send("\(HerdrLaunch.quote(TestSupport.tool("tmux"))) -u -L " + app.socket +
            " -CC attach -t edge; printf 'REMOTE_TMUX_%s\\n' RETURNED", to: terminal)
        try await TestSupport.eventually { !(try app.server(["list-clients", "-F", "#{client_pid}"])).isEmpty }
        XCTAssertTrue(app.workspace.spaces.allSatisfy { !$0.shows("tmux") }, "Disabled tmux integration keeps control-mode output in its terminal")
        _ = try app.server(["detach-client", "-s", "edge"])
        try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("REMOTE_TMUX_RETURNED") }
        TerminalTestSupport.send("export PATH=\(TestSupport.path):/usr/bin:/bin; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(server.root.path) +
            "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: terminal)) { app.workspace.current?.shows("herdr") == true }
        XCTAssertNotNil(app.runtime.ssh.links[identity], "Toggling either backend must retain the original SSH connection")
        app.workspace.detachSpace(try XCTUnwrap(app.workspace.current?.id))
        app.workspace.selectTab(source)
        TerminalTestSupport.send("printf 'REMOTE_SHELL_%s\\n' ALIVE", to: terminal)
        try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("REMOTE_SHELL_ALIVE") }
    }

    private func ssh(_ server: SSHTestServer) -> String {
        "ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " ")
    }
    private func origin(_ app: TmuxWalkthrough, id: UUID) async throws -> TerminalView {
        try await app.wait { app.runtime.views[id].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        return try XCTUnwrap(app.runtime.views[id])
    }
    private func connected(_ app: TmuxWalkthrough, source: UUID) async throws {
        try await TestSupport.eventually(timeout: .seconds(20)) {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.shellPID != nil }
        }
    }
    private func sendAgent(_ text: String, to terminal: TerminalView) async throws {
        let surface = try XCTUnwrap(terminal.surface)
        surface.text(text)
        try await Task.sleep(for: .milliseconds(100))
        TerminalTestSupport.key(36, "\r", terminal)
    }
}
