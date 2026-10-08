import AppKit
import Term
import XCTest
@testable import DispatchApp

@MainActor
final class SSHRecoveryIntegrationTests: XCTestCase {
    func testRemoteShellExitDrainsOutputAndRejectsForgedLifecycleEvents() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let id = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { app.runtime.views[id].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let terminal = try XCTUnwrap(app.runtime.views[id])
        let command = "ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " ")
        TerminalTestSupport.send(command + "; printf 'DIRECT_STATUS_%s\\n' \"$?\"", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == id && $0.shellPID != nil }
        }
        let connection = try XCTUnwrap(app.runtime.ssh.links.values.first { $0.launch.tabID == id })
        let helper = try XCTUnwrap(connection.helperPath)
        // Same authenticated account/executable, outside the registered shell
        // tree: a public session ID cannot authorize forged lifecycle events.
        for event in [#"{"kind":"shellCommand","command":"forged command"}"#,
                      #"{"kind":"shellExit","status":0}"#] {
            let forged = try await SSHTestCommand.run(master: connection.launch.master,
                argv: [helper, "event", connection.launch.sessionID], input: Data(event.utf8))
            XCTAssertNotEqual(forged.status, 0)
            XCTAssertTrue(forged.output.isEmpty)
        }
        let environment = """
        import os
        assert 'DISPATCH_SSH_TOKEN' not in os.environ
        assert 'DISPATCH_SSH_SOCKET' not in os.environ
        assert os.environ['DISPATCH_SSH_SESSION'] == '\(connection.launch.sessionID)'
        print('PRIVATE_SESSION_'+'VERIFIED')
        """
        TerminalTestSupport.send("python3 -c " + HerdrLaunch.quote(environment), to: terminal)
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            TerminalTestSupport.screen(terminal: terminal).contains("PRIVATE_SESSION_VERIFIED")
        }
        XCTAssertNotNil(app.runtime.ssh.links[connection.launch.connectionID])
        TerminalTestSupport.send("printf 'FINAL_REMOTE_%s\\n' OUTPUT; exit 17", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            let screen = TerminalTestSupport.screen(terminal: terminal)
            return app.runtime.ssh.machine(for: id) == nil && screen.contains("FINAL_REMOTE_OUTPUT") && screen.contains("DIRECT_STATUS_17")
        }
        let explicit = "printf 'EXPLICIT_REMOTE_%s\\n' OUTPUT; exit 23"
        TerminalTestSupport.send("ssh -tt " + (server.options + [server.destination, explicit]).map(HerdrLaunch.quote).joined(separator: " ") +
            "; printf 'EXPLICIT_STATUS_%s\\n' \"$?\"", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            let screen = TerminalTestSupport.screen(terminal: terminal)
            return app.runtime.ssh.machine(for: id) == nil && screen.contains("EXPLICIT_REMOTE_OUTPUT") && screen.contains("EXPLICIT_STATUS_23")
        }
    }

    func testRemoteHerdrMasterLossPreservesDraftLayoutAndPendingApprovalWithoutReplay() async throws {
        try await recovery("herdr")
    }

    func testRemoteTmuxMasterLossPreservesDraftLayoutAndPendingApprovalWithoutReplay() async throws {
        try await recovery("tmux")
    }

    func testRemoteTmuxReconnectPreservesDraftBeforeFirstTurn() async throws {
        let fixture = try CodexEndpointFixture(prefix: "dispatch-ssh-first-draft-", delay: 0.01, hooks: false)
        var passed = false
        defer { fixture.stop(removeState: passed) }
        try await fixture.start(timeout: .seconds(15))
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let server = try await SSHTestServer(grant: .init(profile: .full, hooks: false)); defer { server.stop() }
        let sshCommand = "ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " ")
        func connect() async throws -> SSHCoordinator.Link {
            let source = try XCTUnwrap(app.workspace.activeTab?.id)
            try await app.wait { runtime.views[source].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
            let terminal = try XCTUnwrap(runtime.views[source])
            TerminalTestSupport.send(sshCommand, to: terminal)
            try await TestSupport.eventually(timeout: .seconds(20)) {
                runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.shellPID != nil }
            }
            let connection = try XCTUnwrap(runtime.ssh.links.values.first { $0.launch.tabID == source })
            TerminalTestSupport.send("\(HerdrLaunch.quote(TestSupport.tool("tmux"))) -u -L \(app.socket) -CC attach -t edge", to: terminal)
            try await app.wait { app.workspace.current?.structured == true }
            return connection
        }
        func requests() -> Data { (try? Data(contentsOf: fixture.state.appendingPathComponent("requests.jsonl"))) ?? Data() }
        let connection = try await connect()
        let originalID = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { runtime.views[originalID]?.surface != nil }
        let terminal = try XCTUnwrap(runtime.views[originalID]), session = runtime.chat.session(for: originalID)
        TerminalTestSupport.send(CodexTestSupport.command(state: fixture.state, binary: fixture.binary), to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15)) { session.active && session.remoteAgent != nil }
        XCTAssertNil(session.sessionID)
        XCTAssertTrue(requests().isEmpty, "Discovery must precede the first model request")
        let identity = try XCTUnwrap(session.remoteAgent), process = try XCTUnwrap(CodexProcess.capture(identity.pid))
        runtime.chat.chooseChat(true, session: session)
        let draft = "Unsent first prompt \(UUID().uuidString)\nSecond line"
        session.draft = draft
        try await interruptMaster(connection)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            runtime.ssh.links[connection.launch.connectionID] == nil && !session.active && app.workspace.allSurfaceIDs.contains(originalID)
        }
        XCTAssertTrue(process.alive)
        XCTAssertEqual(session.draft, draft)
        XCTAssertTrue(requests().isEmpty)
        let host = try XCTUnwrap(app.workspace.hosts.terminals[session.id]).host
        runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: session.id)
        try await TestSupport.eventually(timeout: .seconds(30), diagnostic: runtime.hosts.reconnect.state(for: session.id)?.error ?? "Host recovery did not complete") { runtime.hosts.reconnect.state(for: session.id) == nil }
        let reconnected = try XCTUnwrap(runtime.ssh.links.values.first { $0.launch.connectionID != connection.launch.connectionID })
        XCTAssertNotEqual(reconnected.launch.connectionID, connection.launch.connectionID)
        let restoredID = try XCTUnwrap(app.workspace.activeSurfaceID)
        XCTAssertEqual(restoredID, originalID, "Recovery must retain the native tmux surface")
        let restored = runtime.chat.session(for: restoredID)
        try await TestSupport.eventually(timeout: .seconds(15)) { restored.active && restored.remoteAgent == identity }
        XCTAssertNil(restored.sessionID)
        XCTAssertEqual(restored.draft, draft)
        XCTAssertTrue(restored.showChat)
        XCTAssertTrue(restored.manualViewChoice)
        XCTAssertTrue(requests().isEmpty, "Reattaching must leave the first draft unsent")
        runtime.chat.submit(restored)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: restored.status ?? "First restored prompt did not finish") {
            !restored.busy && restored.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: " + draft }
        }
        XCTAssertEqual(restored.turns.flatMap(\.items).filter { $0.kind == .user && $0.text == draft }.count, 1)
        passed = testRun?.failureCount == 0
    }

    private func interruptMaster(_ connection: SSHCoordinator.Link) async throws {
        let control = connection.launch.master
        let command = "exec " + ([control.executable] + control.controlArguments("check")).map(HerdrLaunch.quote).joined(separator: " ") + " 2>&1"
        let checked = try await SSHCommand.run(executable: "/bin/sh", arguments: ["-c", command])
        let output = String(decoding: checked.output, as: UTF8.self)
        XCTAssertEqual(checked.status, 0, output)
        let marker = try XCTUnwrap(output.range(of: "pid="), output)
        let pid = try XCTUnwrap(Int32(output[marker.upperBound...].prefix(while: \.isNumber)), output)
        let master = try XCTUnwrap(AgentProcess.capture(pid))
        XCTAssertEqual(master.executable, control.executable)
        // ControlPersist rewrites the background process's argv. Its private
        // socket reports the actual owner PID even while a foreground client
        // has the original command line and shares the same control path.
        let attributes = try FileManager.default.attributesOfItem(atPath: control.controlPath)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSocket)
        XCTAssertEqual((attributes[.ownerAccountID] as? NSNumber)?.uint32Value, getuid())
        XCTAssertTrue(master.alive)
        XCTAssertEqual(kill(master.pid, SIGKILL), 0)
    }

    private func recovery(_ backend: String) async throws {
        let fixture = try CodexEndpointFixture(prefix: "dispatch-ssh-recovery-", delay: 0.01, hooks: false)
        var passed = false
        defer { fixture.stop(removeState: passed) }
        try await fixture.start(timeout: .seconds(15))
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        try await TestSupport.integrations(["codex"], enabled: true, chat: runtime.chat)
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let sshd = try await SSHTestServer(); defer { sshd.stop() }
        let socket = sshd.root.appendingPathComponent("herdr.sock").path
        defer { if let api = try? HerdrSocket(path: socket) { try? api.request("server.stop") } }
        let sshCommand = "ssh " + (sshd.options + [sshd.destination]).map(HerdrLaunch.quote).joined(separator: " ")
        let backendCommand = backend == "tmux"
            ? "\(HerdrLaunch.quote(TestSupport.tool("tmux"))) -u -L \(app.socket) -CC attach -t edge"
            : "export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(sshd.root.path) +
                "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr"

        func connect() async throws -> SSHCoordinator.Link {
            let id = try XCTUnwrap(app.workspace.activeTab?.id)
            try await app.wait { runtime.views[id].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
            let view = try XCTUnwrap(runtime.views[id])
            TerminalTestSupport.send(sshCommand, to: view)
            try await TestSupport.eventually(timeout: .seconds(20), diagnostic: TerminalTestSupport.screen(terminal: view)) {
                runtime.ssh.links.values.contains { $0.launch.tabID == id && $0.shellPID != nil }
            }
            let connection = try XCTUnwrap(runtime.ssh.links.values.first { $0.launch.tabID == id })
            TerminalTestSupport.send(backendCommand, to: view)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: view)) {
                backend == "tmux" ? app.workspace.current?.structured == true : app.workspace.current?.shows("herdr") == true
            }
            return connection
        }

        let connection = try await connect()
        let originalSpace = try XCTUnwrap(app.workspace.current)
        let id = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { runtime.views[id]?.surface != nil }
        let terminal = try XCTUnwrap(runtime.views[id]), chat = runtime.chat
        let session = chat.session(for: id)
        let command = CodexTestSupport.command(state: fixture.state, binary: fixture.binary)
        TerminalTestSupport.send(command, to: terminal)
        try await SSHChatTestSupport.trustHooks(state: fixture.state, command: command, session: session, terminal: terminal)
        chat.chooseChat(true, session: session)
        session.draft = "history before \(backend) interruption"
        chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: session.status ?? "No recovery history") {
            !session.busy && session.sessionID != nil && session.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: history before \(backend) interruption" }
        }
        let identity = try XCTUnwrap(session.remoteAgent), conversation = try XCTUnwrap(session.sessionID)
        let process = try XCTUnwrap(CodexProcess.capture(identity.pid))
        XCTAssertEqual(process.executable, identity.executable, "The private SSH daemon runs in this test VM")
        // The chat of this connection generation; nothing may reach the agent through it after the loss.
        let oldHelper = try XCTUnwrap(session.helper)

        if backend == "tmux" {
            app.workspace.newTab()
            try await app.wait { app.workspace.current?.tabs.count == 2 && app.workspace.current?.tabs.allSatisfy({ !$0.isConnecting }) == true }
            app.workspace.split(.columns)
            try await app.wait { app.workspace.current?.panes.count == 2 }
            app.workspace.selectTab(id)
        } else {
            app.workspace.newTab()
            try await app.wait { app.workspace.current?.tabs.count == 2 && app.workspace.current?.tabs.allSatisfy({ !$0.isConnecting }) == true }
            XCTAssertTrue(app.workspace.applyLayout(.columns))
            app.workspace.selectSurface(id)
        }
        app.workspace.renameSpace(try XCTUnwrap(app.workspace.current?.id), to: "Recovery \(backend)")
        try await app.wait { app.workspace.current?.name == "Recovery \(backend)" }
        let layout = try XCTUnwrap(app.workspace.current?.layout)
        let serverPanes = backend == "tmux" ? try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]) : ""
        session.draft = "\(backend) approval before interruption"
        chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: session.status ?? "No pending recovery approval") {
            session.approvals.contains(where: \.pending)
        }
        let approval = try XCTUnwrap(session.approvals.first(where: \.pending))
        let draft = "UNSENT_\(backend)_\(UUID().uuidString)"
        session.draft = draft
        let requests = try Data(contentsOf: fixture.state.appendingPathComponent("requests.jsonl"))
        let before = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(session.transcriptPath)))
        try await interruptMaster(connection)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            !runtime.ssh.links.keys.contains(connection.launch.connectionID) && !session.active && !approval.pending
        }
        XCTAssertEqual(session.draft, draft)
        XCTAssertNotEqual(approval.decision, .allow)
        approval.resolve(.allow)
        XCTAssertNotEqual(approval.decision, .allow, "An abandoned approval cannot be granted after disconnect")
        do {
            var input = HelperChat.Input(oldHelper.route); input.text = "MUST_NOT_REPLAY"
            let _: HelperChat.Sent = try await oldHelper.call("chat.send", input: input)
            XCTFail("The disconnected generation accepted an operation")
        } catch { }
        XCTAssertTrue(process.alive)
        XCTAssertEqual(try Data(contentsOf: fixture.state.appendingPathComponent("requests.jsonl")), requests)
        XCTAssertFalse(String(decoding: try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(session.transcriptPath))), as: UTF8.self).contains(draft))
        if backend == "herdr" {
            XCTAssertEqual(app.workspace.spaces.first(where: { $0.id == originalSpace.id })?.layout, layout)
            XCTAssertNotEqual(originalSpace.hostID, .local)
            XCTAssertEqual(app.workspace.spaces.first(where: { $0.id == originalSpace.id })?.hostID, originalSpace.hostID)
            XCTAssertEqual(app.workspace.hosts.terminals[id]?.host, originalSpace.hostID)
            XCTAssertEqual(app.workspace.hosts.state(originalSpace.hostID), .disconnected)
        } else {
            XCTAssertTrue(app.workspace.allSurfaceIDs.contains(id))
            XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), serverPanes)
        }

        let host = try XCTUnwrap(app.workspace.hosts.terminals[session.id]).host
        runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: session.id)
        try await TestSupport.eventually(timeout: .seconds(30), diagnostic: runtime.hosts.reconnect.state(for: session.id)?.error ?? "Host recovery did not complete") { runtime.hosts.reconnect.state(for: session.id) == nil }
        let reconnected = try XCTUnwrap(runtime.ssh.links.values.first { $0.launch.connectionID != connection.launch.connectionID })
        XCTAssertNotEqual(reconnected.launch.connectionID, connection.launch.connectionID)
        func restoredSurface() -> UUID? {
            app.workspace.current?.tabs.flatMap(\.surfaceIDs).first { candidate in
                runtime.link(of: candidate) != nil && (backend == "tmux" ? app.workspace.current?.tabs.first { $0.id == candidate }.flatMap { app.target($0) } == "%0" : candidate == id)
            }
        }
        try await TestSupport.eventually(timeout: .seconds(15)) { restoredSurface() != nil }
        let restoredID = try XCTUnwrap(restoredSurface())
        app.workspace.selectSurface(restoredID)
        try await app.wait { runtime.views[restoredID]?.surface != nil }
        let restored = chat.session(for: restoredID)
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: restored.status ?? "No restored remote agent") {
            restored.active && restored.remoteAgent == identity && restored.sessionID == conversation && !restored.loadingHistory
        }
        XCTAssertEqual(restoredID, id)
        XCTAssertTrue(runtime.views[restoredID] === terminal)
        XCTAssertEqual(restored.draft, draft, "Reconnect preserves the existing draft")
        XCTAssertTrue(restored.showChat, "Reattach restores the selected chat presentation")
        XCTAssertEqual(app.workspace.current?.name, "Recovery \(backend)")
        XCTAssertEqual(app.workspace.current?.layout.paneIDs.count, 2)
        XCTAssertFalse(restored.approvals.contains(where: \.pending))
        XCTAssertTrue(restored.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: history before \(backend) interruption" })
        XCTAssertEqual(try Data(contentsOf: fixture.state.appendingPathComponent("requests.jsonl")), requests, "Reattachment never replays a prompt or permission")
        let after = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(restored.transcriptPath)))
        XCTAssertTrue(after.starts(with: before), "Recovery must retain the existing transcript")
        XCTAssertFalse(String(decoding: after, as: UTF8.self).contains(draft))
        XCTAssertFalse(restored.turns.flatMap(\.items).contains { $0.kind == .tool && $0.output.contains("DISPATCH_LOCAL_TOOL_OK") })
        _ = try await PresentationTestSupport.capture(app.window, named: "recovery-" + backend, in: "ssh-recovery-validation")
        passed = testRun?.failureCount == 0
    }

}

@MainActor
enum SSHChatTestSupport {
    /// The helper channel of a live SSH connection dies while its master stays (the remote helper's connection).
    static func dropHelper(_ ssh: SSHCoordinator, _ id: SSHConnectionID, reason: String) async throws {
        try await HelperApp.shared.connection(.remote(id)).close()
    }

    static func launch(_ command: String, session: ChatSession, terminal: TerminalView,
                       replacing previousIdentity: String? = nil) async throws {
        let generation = UUID().uuidString
        let marker = "DISPATCH_AGENT_LAUNCH_" + generation
        // The command's echo cannot contain the complete marker. Observing it
        // proves the old editor and scrollback were cleared before this launch.
        let clear = "printf '\\033[2J\\033[3J\\033[H%s%s\\n' DISPATCH_AGENT_LAUNCH_ " + HerdrLaunch.quote(generation)
        TerminalTestSupport.send(clear, to: terminal)
        try await TestSupport.eventually(diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            TerminalTestSupport.screen(terminal: terminal).contains(marker)
        }
        TerminalTestSupport.send(command, to: terminal)
        try await TestSupport.eventually(timeout: .seconds(25), diagnostic: "\(session.status ?? "No remote agent")\nPrevious: \(previousIdentity ?? "none")\nCurrent: \(session.remoteAgent?.key ?? "none")\n\(TerminalTestSupport.screen(terminal: terminal))") {
            session.active && session.remoteAgent != nil && session.remoteAgent?.key != previousIdentity
        }
    }

    static func quitAndRelaunch(_ command: String, session: ChatSession, terminal: TerminalView) async throws {
        let previousIdentity = try XCTUnwrap(session.remoteAgent)
        try await sendToAgent("/quit", terminal: terminal)
        try await TestSupport.eventually { !session.active }
        // The chat retains its old identity for draft recovery. Ask the helper for the live
        // foreground binding before sending the next shell command.
        let helper = try XCTUnwrap(session.helper)
        let process = try XCTUnwrap(session.binding?.process)
        struct Current: Decodable { let binding: HelperTopology.Binding }
        try await eventually {
            do {
                let current: Current = try await helper.call("chat.state", input: HelperChat.Input(.init(terminal: helper.route.terminal)))
                return current.binding.process != process
            } catch let failure as HelperFailure where failure.code == "unavailable" {
                return true
            }
        }
        try await launch(command, session: session, terminal: terminal, replacing: previousIdentity.key)
    }

    static func waitForEditor(session: ChatSession, terminal: TerminalView) async throws {
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "\(session.status ?? "No remote editor")\n\(TerminalTestSupport.viewport(terminal: terminal))") {
            session.active && session.remoteAgent != nil &&
                AgentModelMenu.containsModel(TerminalTestSupport.viewport(terminal: terminal), slug: "dispatch-fixture default", name: "Dispatch fixture default") &&
                !session.discoveryBlocked && !session.loadingHistory && session.activityCheck == nil && !session.busy
        }
    }

    static func trustHooks(state: URL, command: String, session: ChatSession, terminal: TerminalView,
                           read: ((String) async throws -> String)? = nil) async throws {
        func contents(_ relative: String) async throws -> String {
            let path = state.appendingPathComponent(relative).path
            if let read { return try await read(path) }
            return try String(contentsOfFile: path, encoding: .utf8)
        }
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: session.status ?? "No remote recovery agent") {
            session.active && session.remoteAgent != nil
        }
        try await eventually {
            (try? await contents("codex-home/hooks.json").contains(".dispatch/h4/bin/dispatch-helper4")) == true
        }
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            let screen = TerminalTestSupport.viewport(terminal: terminal)
            return screen.contains("Hooks need review") || AgentModelMenu.containsModel(screen, slug: "dispatch-fixture default", name: "Dispatch fixture default")
        }
        if !TerminalTestSupport.viewport(terminal: terminal).contains("Hooks need review") {
            try await quitAndRelaunch(command, session: session, terminal: terminal)
        }
        try await TestSupport.eventually { TerminalTestSupport.viewport(terminal: terminal).contains("Hooks need review") }
        try await Task.sleep(for: .milliseconds(250)); TerminalTestSupport.key(36, "\r", terminal)
        try await TestSupport.eventually { TerminalTestSupport.viewport(terminal: terminal).contains("trust all") }
        try await Task.sleep(for: .milliseconds(250)); TerminalTestSupport.key(17, "t", terminal)
        try await eventually {
            let config = try? await contents("codex-home/config.toml")
            return (config?.components(separatedBy: "trusted_hash").count ?? 0) == 11
        }
        TerminalTestSupport.key(53, "\u{1b}", terminal)
        try await TestSupport.eventually { AgentModelMenu.containsModel(TerminalTestSupport.viewport(terminal: terminal), slug: "dispatch-fixture default", name: "Dispatch fixture default") }
        TerminalTestSupport.key(32, "u", terminal, modifiers: .control)
        try await Task.sleep(for: .milliseconds(150))
        try await quitAndRelaunch(command, session: session, terminal: terminal)
        try await waitForEditor(session: session, terminal: terminal)
    }

    static func sendToAgent(_ text: String, terminal: TerminalView) async throws {
        let surface = try XCTUnwrap(terminal.surface)
        surface.text(text)
        try await Task.sleep(for: .milliseconds(100)); TerminalTestSupport.key(36, "\r", terminal)
    }

    static func eventually(timeout: Duration = .seconds(15), file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try XCTUnwrap(nil as Bool?, "Remote condition timed out", file: file, line: line)
    }
}
