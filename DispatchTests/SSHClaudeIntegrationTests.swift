import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class SSHClaudeIntegrationTests: XCTestCase {
    func testRemotePlainDiscoveryMessagesHistoryAndExit() async throws { try await walkthrough("plain") }
    func testRemoteTmuxDiscoveryMessagesHistoryAndExit() async throws { try await walkthrough("tmux") }
    func testRemoteHerdrDiscoveryMessagesHistoryAndExit() async throws { try await walkthrough("herdr") }
    func testRemotePlainTransportModelQueueAndExit() async throws { try await walkthrough("plain", transportOnly: true) }
    func testRemoteTmuxTransportModelQueueAndExit() async throws { try await walkthrough("tmux", transportOnly: true) }
    func testRemoteHerdrTransportModelQueueAndExit() async throws { try await walkthrough("herdr", transportOnly: true) }
    func testRemotePlainApprovalAllowDenyAndRevocation() async throws { try await walkthrough("plain", approvals: true) }
    func testRemoteTmuxApprovalAllowDenyAndRevocation() async throws { try await walkthrough("tmux", approvals: true) }
    func testRemoteHerdrApprovalAllowDenyAndRevocation() async throws { try await walkthrough("herdr", approvals: true) }
    func testRemotePlainQuestionsAnswersSkipAndRevocation() async throws { try await walkthrough("plain", approvals: true, questions: true) }
    func testRemoteTmuxQuestionsAnswersSkipAndRevocation() async throws { try await walkthrough("tmux", approvals: true, questions: true) }
    func testRemoteHerdrQuestionsAnswersSkipAndRevocation() async throws { try await walkthrough("herdr", approvals: true, questions: true) }
    func testRemoteTmuxClaudeReattachmentRejectsOldApprovalAndRecoversQuestions() async throws { try await walkthrough("tmux", approvals: true, reattach: true) }
    func testRemoteHerdrClaudeReattachmentRejectsOldApprovalAndRecoversQuestions() async throws { try await walkthrough("herdr", approvals: true, reattach: true) }
    func testRemoteTmuxClaudeChatSurvivesInPlaceReconnect() async throws { try await walkthrough("tmux", reconnectInPlace: true) }

    func testRemoteIntegrationRevocationRejectsPendingApprovals() async throws {
        for backend in ["plain", "tmux", "herdr"] {
            try await walkthrough(backend, approvals: true, integrationRevocation: true)
        }
    }

    private func walkthrough(_ backend: String, approvals: Bool = false, questions: Bool = false, reattach: Bool = false, integrationRevocation: Bool = false, transportOnly: Bool = false, reconnectInPlace: Bool = false) async throws {
        let phaseTimings = WalkthroughTimings(test: name, agent: "claude", transport: "ssh-" + backend)
        phaseTimings.begin("endpoint_startup")
        var passed = false
        defer { phaseTimings.save(passed: passed && testRun?.failureCount == 0) }
        let fm = FileManager.default
        // A fresh SSH login with hooks already opted in also installs the
        // account-default handler. Restore that VM account file after this
        // reconnect fixture; conversations remain in the private profile.
        let accountSettings = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json")
        let savedAccountSettings = reattach ? try? Data(contentsOf: accountSettings) : nil
        let savedMode = reattach ? (try? fm.attributesOfItem(atPath: accountSettings.path)[.posixPermissions]) : nil
        defer {
            if reattach {
                do {
                    if let savedAccountSettings {
                        try savedAccountSettings.write(to: accountSettings, options: .atomic)
                        if let savedMode { try fm.setAttributes([.posixPermissions: savedMode], ofItemAtPath: accountSettings.path) }
                    } else if fm.fileExists(atPath: accountSettings.path) { try fm.removeItem(at: accountSettings) }
                } catch { XCTFail("Cannot restore test VM Claude account settings: " + error.localizedDescription) }
            }
        }
        let claude = try XCTUnwrap([TestSupport.tool("claude")].first { fm.isExecutableFile(atPath: $0) })
        let state = URL(fileURLWithPath: "/tmp/dispatch-ssh-claude-" + UUID().uuidString)
        let script = CodexTestSupport.root.appendingPathComponent("scripts/claude_fixture.py").path
        let fixture = Process(); fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // Approval/question cases assert completed messages and hook decisions;
        // only the detailed walkthrough needs paced streaming for interruption.
        fixture.arguments = [script, "serve", "--state", state.path, "--delay", (transportOnly || approvals) ? "0" : "0.025"]
        fixture.standardOutput = FileHandle.nullDevice; fixture.standardError = FileHandle.nullDevice
        try fixture.run()
        defer {
            if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() }
            print("SSH Claude \(backend) fixture: " + state.path)
        }
        try await TestSupport.eventually { fm.fileExists(atPath: state.appendingPathComponent("endpoint.json").path) }
        phaseTimings.begin("SSH_setup")
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(server: backend != "tmux"); defer { app.close() }
        func finish() async {
            phaseTimings.begin("teardown")
            await app.close().value
            passed = testRun?.failureCount == 0
        }
        do {
            let ssh = try await SSHTestServer(grant: .init(profile: .full, hooks: approvals)); defer { ssh.stop() }
            let socket = state.appendingPathComponent("herdr.sock").path
            defer { if backend == "herdr" { _ = try? HerdrSocket(path: socket).request("server.stop") } }
            let origin = try XCTUnwrap(app.workspace.activeSurfaceID)
            try await app.wait { runtime.views[origin].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
            let original = try XCTUnwrap(runtime.views[origin])
            TerminalTestSupport.send("ssh " + (ssh.options + [ssh.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: original)
            do {
                try await TestSupport.eventually(timeout: .seconds(20)) { runtime.ssh.links.values.contains { $0.launch.tabID == origin && $0.shellPID != nil } }
            } catch { print("Claude SSH bootstrap: " + TerminalTestSupport.screen(terminal: original)); throw error }
            if backend == "tmux" {
                TerminalTestSupport.send(app.attachCommand(login: true), to: original)
                try await app.wait { app.workspace.current?.structured == true }
            } else if backend == "herdr" {
                TerminalTestSupport.send("export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(state.path)
                    + "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr", to: original)
                try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.current?.shows("herdr") == true }
            }
            // Claude reads the configuration the remote helper installs its integration into (the server's own).
            let launch = "TZ=Asia/Kathmandu " + ["python3", script, "launch", "--state", state.path, "--claude", claude, "--integration",
                "--config", ssh.agents.appendingPathComponent("claude").path].map(HerdrLaunch.quote).joined(separator: " ")
            phaseTimings.begin("agent_readiness")
            if reconnectInPlace {
                try await exerciseInPlaceReconnect(app: app, origin: origin, launch: launch)
                await finish()
                return
            }
            if approvals {
                // Enable discovery-time installation only after login, so all
                // configuration changes target this CLI's disposable profile.
                runtime.chat.stop()
                runtime.chat = ChatCoordinator(enabled: true)
                runtime.chat.start()
                try await TestSupport.integrations(["claude"], enabled: true, chat: runtime.chat)
                let id = try XCTUnwrap(app.workspace.activeSurfaceID)
                try await app.wait {
                    runtime.views[id].map { $0.surface != nil && !$0.agentMenuScreen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
                }
                let terminal = try XCTUnwrap(runtime.views[id]), session = runtime.chat.session(for: id)
                defer { print("Remote Claude approval \(backend): \(session.status ?? "none") / \(runtime.chat.error ?? "none")\n\(terminal.agentMenuScreen)") }
                session.manualViewChoice = true
                TerminalTestSupport.send(launch, to: terminal)
                let settings = ssh.agents.appendingPathComponent("claude/settings.json")
                try await TestSupport.eventually(timeout: .seconds(20)) {
                    session.active && session.agentID == "claude" && terminal.agentMenuScreen.contains("for shortcuts") &&
                        (try? String(contentsOf: settings, encoding: .utf8))?.contains("PermissionRequest") == true
                }
                let installed = try Data(contentsOf: settings)
                XCTAssertTrue(String(decoding: installed, as: UTF8.self).contains("PermissionRequest"))
                // Hook settings are explicitly loaded when the fixture restarts.
                // The real application's installer also supports subsequent logins.
                TerminalTestSupport.send("/exit", to: terminal)
                try await TestSupport.eventually(timeout: .seconds(15)) { !session.active }
                TerminalTestSupport.send(launch + " --hooks", to: terminal)
                try await TestSupport.eventually(timeout: .seconds(20)) {
                    session.active && session.agentID == "claude" && !session.loadingHistory && !session.busy &&
                        terminal.agentMenuScreen.contains("for shortcuts")
                }
                runtime.chat.chooseChat(true, session: session)
                if reattach {
                    try await exerciseReattachment(backend, app: app, server: ssh, origin: origin, session: session, state: state, socket: socket)
                    XCTAssertEqual(try Data(contentsOf: settings), installed)
                    await finish()
                    return
                }
                if questions {
                    XCTAssertTrue(String(decoding: installed, as: UTF8.self).contains("AskUserQuestion"))
                    session.draft = "multiple questions please"; runtime.chat.submit(session)
                    try await TestSupport.eventually(timeout: .seconds(20)) { session.approvals.contains { $0.pending && $0.questions != nil } }
                    let request = try XCTUnwrap(session.approvals.last(where: \.pending))
                    XCTAssertEqual(request.questions?.questions.count, 3)
                    if let turn = request.turnID {
                        XCTAssertEqual(turn, session.turns.last(where: { $0.items.contains { $0.kind == .user && $0.text == "multiple questions please" } })?.id)
                    }
                    let custom = "Python λ\n" + String(repeating: "complete example ", count: 100)
                    let answers = ["How much detail should the reply include?": "Detailed",
                                   "Which checks should be included?": "Tests, Documentation",
                                   "Which language should the example use?": custom]
                    request.answer(answers)
                    try await TestSupport.eventually(timeout: .seconds(20)) {
                        !session.busy && session.turns.flatMap(\.items).contains { $0.kind == .assistant && $0.text.contains("Answers received:") && $0.text.contains("Python λ") }
                    }
                    XCTAssertEqual(request.answers, answers)
                    session.draft = "question skip"; runtime.chat.submit(session)
                    try await TestSupport.eventually(timeout: .seconds(20)) { session.approvals.contains { $0.pending && $0.questions != nil } }
                    let skipped = try XCTUnwrap(session.approvals.last(where: \.pending))
                    skipped.resolve(.deny)
                    try await TestSupport.eventually(timeout: .seconds(20)) {
                        !session.busy && session.turns.last?.items.contains { $0.kind == .assistant && $0.text.contains("denied or failed.") } == true
                    }
                    XCTAssertEqual(skipped.decision, .deny)
                    session.draft = "question revoke"; runtime.chat.submit(session)
                    try await TestSupport.eventually(timeout: .seconds(20)) { session.approvals.contains { $0.pending && $0.questions != nil } }
                    let revoked = try XCTUnwrap(session.approvals.last(where: \.pending))
                    runtime.chat.setHelperIntegration("claude", enabled: false)
                    XCTAssertFalse(revoked.pending)
                    revoked.answer(["How much detail should the reply include?": "Compact"])
                    XCTAssertNil(revoked.answers)
                    try await TestSupport.eventually(timeout: .seconds(10)) { ClaudeScreen.question(terminal.agentMenuScreen) }
                    XCTAssertEqual(try Data(contentsOf: settings), installed)
                    await finish()
                    return
                }
                let marker = state.appendingPathComponent("work/dispatch-approval-marker")
                // Revoking the integration grant needs only one pending approval; the
                // ApprovalAllowDenyAndRevocation cases own the deny and allow loop.
                if !integrationRevocation {
                    for decision in [PendingApproval.Decision.deny, .allow] {
                        session.draft = "permission tool " + decision.rawValue; runtime.chat.submit(session)
                        try await TestSupport.eventually(timeout: .seconds(20)) { session.approvals.contains(where: \.pending) }
                        let approval = try XCTUnwrap(session.approvals.last(where: \.pending))
                        XCTAssertTrue(approval.operation.contains("dispatch-approval-marker"))
                        // The live hook may arrive before Claude persists its tool.
                        if let turn = approval.turnID {
                            XCTAssertEqual(turn, session.turns.last(where: { $0.items.contains { $0.kind == .user && $0.text == "permission tool " + decision.rawValue } })?.id)
                        }
                        XCTAssertFalse(fm.fileExists(atPath: marker.path))
                        approval.resolve(decision)
                        let expected = decision == .allow ? "completed." : "denied or failed."
                        try await TestSupport.eventually(timeout: .seconds(20)) {
                            !session.busy && session.turns.flatMap(\.items).contains { $0.kind == .assistant && $0.text.contains("Tool result received: " + expected) }
                        }
                        XCTAssertEqual(fm.fileExists(atPath: marker.path), decision == .allow)
                    }
                    try fm.removeItem(at: marker)
                }
                session.draft = "permission tool revoke"; runtime.chat.submit(session)
                try await TestSupport.eventually(timeout: .seconds(20)) { session.approvals.contains(where: \.pending) }
                let revoked = try XCTUnwrap(session.approvals.last(where: \.pending))
                if integrationRevocation {
                    let connection = try XCTUnwrap(runtime.ssh.links.values.first { $0.launch.tabID == origin })
                    let before = try Data(contentsOf: state.appendingPathComponent("requests.jsonl"))
                    session.draft = "Keep draft while permission is revoked"
                    let feature: SSHIntegrationFeature = backend == "plain" ? .chat : (backend == "tmux" ? .tmux : .herdr)
                    runtime.ssh.permissions.save(.init(helperEnabled: true,
                        features: Set(SSHIntegrationFeature.allCases).subtracting([feature])), for: connection.scope)
                    XCTAssertFalse(session.active)
                    XCTAssertFalse(revoked.pending)
                    revoked.resolve(.allow)
                    XCTAssertNotEqual(revoked.decision, .allow)
                    try await Task.sleep(for: .seconds(1))
                    XCTAssertFalse(fm.fileExists(atPath: marker.path))
                    XCTAssertEqual(session.draft, "Keep draft while permission is revoked")
                    XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent("requests.jsonl")), before)
                    await finish()
                    return
                }
                runtime.chat.setHelperIntegration("claude", enabled: false)
                XCTAssertFalse(revoked.pending); revoked.resolve(.allow)
                XCTAssertFalse(fm.fileExists(atPath: marker.path))
                try await TestSupport.eventually(timeout: .seconds(10)) {
                    session.terminalAttention != nil && ClaudeScreen.permission(terminal.agentMenuScreen)
                }
                XCTAssertEqual(try Data(contentsOf: settings), installed)
                await finish()
                return
            }
            try await Self.exercise(backend, app: app, launch: launch, transportOnly: transportOnly, timings: phaseTimings,
                settings: { try? Data(contentsOf: ssh.agents.appendingPathComponent("claude/settings.json")) },
                requests: { try Data(contentsOf: state.appendingPathComponent("requests.jsonl")) })
            await finish()
        } catch {
            phaseTimings.begin("teardown")
            await app.close().value
            throw error
        }
    }

    /// The Reconnect button keeps the space and its panes, unlike reattaching from a
    /// new terminal: the pane's chat must stay available and return to its conversation.
    private func exerciseInPlaceReconnect(app: TmuxWalkthrough, origin: UUID, launch: String) async throws {
        let runtime = TerminalRuntime.shared
        let id = try XCTUnwrap(app.workspace.activeSurfaceID), pane = try XCTUnwrap(app.workspace.activeTab.flatMap { app.target($0) })
        try await app.wait { runtime.views[id]?.surface != nil }
        let terminal = try XCTUnwrap(runtime.views[id]), session = runtime.chat.session(for: id)
        TerminalTestSupport.send(launch, to: terminal)
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: session.status ?? terminal.agentMenuScreen) {
            session.active && session.agentID == "claude" && session.sessionID != nil && !session.loadingHistory
        }
        runtime.chat.chooseChat(true, session: session)
        let conversation = try XCTUnwrap(session.sessionID)
        let process = try XCTUnwrap(session.remoteAgent).pid
        // Drop the connection as a network loss would; the tmux server and Claude keep running.
        let connection = try XCTUnwrap(runtime.ssh.links.values.first { $0.launch.tabID == origin })
        let closed = try await SSHCommand.run(executable: connection.launch.master.executable,
                                              arguments: connection.launch.master.controlArguments("exit"))
        XCTAssertEqual(closed.status, 0)
        try await TestSupport.eventually(timeout: .seconds(20)) { runtime.hosts.reconnect.state(for: id) != nil && !session.active }
        let host = try XCTUnwrap(app.workspace.hosts.terminals[id]).host
        runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: id)
        try await TestSupport.eventually(timeout: .seconds(30), diagnostic: runtime.hosts.reconnect.state(for: id)?.error ?? "reconnecting") {
            runtime.hosts.reconnect.state(for: id) == nil
        }
        let tab = try XCTUnwrap(app.workspace.current?.tabs.first { app.target($0) == pane }, "The pane must survive reconnecting")
        let restored = runtime.chat.session(for: tab.id)
        func diagnostic() -> String {
            "surface kept=\(tab.id == id) same session=\(restored === session) opened=\(restored.hasConversation) "
                + "active=\(restored.active) blocked=\(restored.discoveryBlocked) conversation=\(restored.sessionID ?? "none") "
                + "context=\(runtime.link(of: tab.id) != nil) status=\(restored.status ?? "none")"
        }
        XCTAssertTrue(runtime.chat.canEnterChat(restored), "Chat must stay available after reconnecting: " + diagnostic())
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: diagnostic()) {
            restored.active && restored.sessionID == conversation && restored.remoteAgent?.pid == process
        }
    }

    private func exerciseReattachment(_ backend: String, app: TmuxWalkthrough, server: SSHTestServer,
                                      origin: UUID, session: ChatSession, state: URL, socket: String) async throws {
        let runtime = TerminalRuntime.shared
        let connection = try XCTUnwrap(runtime.ssh.links.values.first { $0.launch.tabID == origin })
        session.draft = "permission tool before reconnect"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(20)) { session.approvals.contains(where: \.pending) }
        let oldApproval = try XCTUnwrap(session.approvals.last(where: \.pending))
        let identity = try XCTUnwrap(session.remoteAgent), conversation = try XCTUnwrap(session.sessionID)
        let process = try XCTUnwrap(AgentProcess.capture(identity.pid))
        let draft = "Keep the unsent reconnect draft λ\nsecond line"
        session.draft = draft
        let requests = try Data(contentsOf: state.appendingPathComponent("requests.jsonl"))
        let marker = state.appendingPathComponent("work/dispatch-approval-marker")
        let control = connection.launch.master
        let closed = try await SSHCommand.run(executable: control.executable, arguments: control.controlArguments("exit"))
        XCTAssertEqual(closed.status, 0)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            runtime.ssh.links[connection.launch.connectionID] == nil && !session.active && !oldApproval.pending
        }
        oldApproval.resolve(.allow)
        XCTAssertNotEqual(oldApproval.decision, .allow)
        XCTAssertEqual(session.draft, draft)
        XCTAssertTrue(process.alive, "Persistent Claude must survive the SSH connection")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent("requests.jsonl")), requests)

        app.workspace.newLocalSpace()
        let source = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { runtime.views[source].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let terminal = try XCTUnwrap(runtime.views[source])
        TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.shellPID != nil }
        }
        let reconnected = try XCTUnwrap(runtime.ssh.links.values.first { $0.launch.tabID == source })
        XCTAssertNotEqual(reconnected.launch.connectionID, connection.launch.connectionID)
        let command = backend == "tmux" ? "\(HerdrLaunch.quote(TestSupport.tool("tmux"))) -u -L \(app.socket) -CC attach -t edge" :
            "export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(state.path) +
            "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr"
        TerminalTestSupport.send(command, to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            backend == "tmux" ? app.workspace.current?.structured == true : app.workspace.current?.shows("herdr") == true
        }
        func restoredSession() -> ChatSession? {
            app.workspace.current?.tabs.flatMap(\.surfaceIDs).compactMap { id in
                let candidate = runtime.chat.session(for: id)
                return candidate.active && candidate.remoteAgent == identity && candidate.sessionID == conversation && !candidate.loadingHistory ? candidate : nil
            }.first
        }
        try await TestSupport.eventually(timeout: .seconds(20)) { restoredSession() != nil }
        let restored = try XCTUnwrap(restoredSession())
        app.workspace.selectSurface(restored.id)
        try await app.wait { runtime.views[restored.id]?.surface != nil }
        let view = try XCTUnwrap(runtime.views[restored.id])
        defer { print("Claude \(backend) reconnect: \(restored.status ?? "none")\n\(view.agentMenuScreen)") }
        XCTAssertEqual(restored.draft, draft)
        XCTAssertFalse(restored.approvals.contains(where: \.pending), "Old connection approvals must never become answerable again")
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent("requests.jsonl")), requests, "Reattachment must not replay input or tool decisions")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        try await TestSupport.eventually(timeout: .seconds(15)) {
            restored.terminalAttention != nil && ClaudeScreen.permission(view.agentMenuScreen)
        }
        runtime.chat.chooseChat(false, session: restored)
        app.window.makeKeyAndOrderFront(nil)
        try await TestSupport.eventually(diagnostic: "presented=\(view.isPresented), parked=\(view.inputParked), mounted=\(view.window === app.window), key=\(app.window.isKeyWindow), responder=\(String(describing: app.window.firstResponder)), active=\(String(describing: app.workspace.activeSurfaceID)), expected=\(restored.id), currentView=\(runtime.views[restored.id] === view)") {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true); app.window.makeKeyAndOrderFront(nil)
            app.window.makeFirstResponder(view)
            return view.isPresented && view.window === app.window && !view.inputParked &&
                app.window.isKeyWindow && app.window.firstResponder === view
        }
        // Let the terminal-mode layout and its native focus update reach the
        // reattached renderer before exercising keyboard input.
        try await Task.sleep(for: .milliseconds(250))
        TerminalTestSupport.key(53, "\u{1b}", view)
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic:
            "Escape after \(backend) reconnect: active=\(restored.active) blocked=\(restored.discoveryBlocked) busy=\(restored.busy) parked=\(view.inputParked) presented=\(view.isPresented) currentView=\(runtime.views[restored.id] === view) responder=\(app.window.firstResponder === view) status=\(restored.status ?? "none")\n\(view.agentMenuScreen)") {
            !restored.busy && ClaudeModelMenu.isEmptyComposer(view.agentMenuScreen) &&
                restored.turns.last?.items.contains { $0.kind == .tool && $0.completed && $0.exitCode == 1 } == true
        }
        // Native Escape interrupts the turn without another model request;
        // a hook Deny instead returns a tool error for the model to discuss.
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent("requests.jsonl")), requests)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(restored.draft, draft)
        runtime.chat.chooseChat(true, session: restored)
        restored.draft = "permission tool after reconnect"; runtime.chat.sendFromComposer(restored)
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: restored.submissionFailure ?? restored.status ?? "Waiting for approval after reconnect") { restored.approvals.contains(where: \.pending) }
        let approval = try XCTUnwrap(restored.approvals.last(where: \.pending))
        approval.resolve(.allow)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            !restored.busy && !restored.awaitingPromptAck && restored.submissionID == nil &&
                ClaudeModelMenu.isEmptyComposer(view.agentMenuScreen) && FileManager.default.fileExists(atPath: marker.path)
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "approved")
        restored.draft = "question after reconnect"; runtime.chat.sendFromComposer(restored)
        try await TestSupport.eventually(timeout: .seconds(20)) { restored.approvals.contains { $0.pending && $0.questions != nil } }
        let question = try XCTUnwrap(restored.approvals.last(where: \.pending))
        question.answer(["How much detail should the reply include?": "Detailed"])
        try await TestSupport.eventually(timeout: .seconds(20)) {
            !restored.busy && restored.turns.last?.items.contains { $0.kind == .assistant && $0.text.contains("Answers received:") && $0.text.contains("Detailed") } == true
        }
        XCTAssertEqual(restored.sessionID, conversation)
        XCTAssertEqual(restored.remoteAgent, identity)
        XCTAssertFalse(restored.turns.flatMap(\.items).contains { $0.kind == .user && $0.text == draft })
    }

    static func exercise(_ backend: String, app: TmuxWalkthrough, launch: String, transportOnly: Bool = false, timings: WalkthroughTimings? = nil,
                         settings readSettings: () async throws -> Data?, requests readRequests: () async throws -> Data) async throws {
        let runtime = TerminalRuntime.shared
        let id = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait {
            runtime.views[id].map { $0.surface != nil && !$0.agentMenuScreen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
        }
        let terminal = try XCTUnwrap(runtime.views[id]), session = runtime.chat.session(for: id)
        func waitForInputReady() async throws {
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic:
                "Claude \(backend) input: active=\(session.active) blocked=\(session.inputBlocked) busy=\(session.busy) activityCheck=\(session.activityCheck != nil) ack=\(session.awaitingPromptAck) status=\(session.status ?? "none")") {
                session.modelPicker == nil && !session.awaitingPromptAck && runtime.chat.canPickModel(session)
                    && ClaudeModelMenu.isEmptyComposer(terminal.agentMenuScreen)
            }
        }
        defer { print("SSH Claude \(backend): \(session.status ?? "none") / \(session.submissionFailure ?? "none") active=\(session.active) blocked=\(session.discoveryBlocked) busy=\(session.busy) ack=\(session.awaitingPromptAck) draft=\(session.draft)\n\(terminal.agentMenuScreen)") }
        session.manualViewChoice = true
        // A distinct TZ verifies that remote process birth validation does not
        // accidentally use the helper broker's timezone.
        TerminalTestSupport.send(launch, to: terminal)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            session.active && session.agentID == "claude" && session.remoteAgent != nil && !session.loadingHistory && !session.busy
                && terminal.agentMenuScreen.contains("for shortcuts")
        }
        XCTAssertNil(session.process)
        let identity = try XCTUnwrap(session.remoteAgent), helper = try XCTUnwrap(session.helper)
        let conversation = try XCTUnwrap(session.sessionID)
        runtime.chat.chooseChat(true, session: session)
        timings?.begin("scenario")
        let greeting = (transportOnly ? "hello over SSH " : "thinking hello over SSH ") + backend + "\nwith λ"
        session.draft = greeting; runtime.chat.submit(session)
        var submissionStates = Set<String>()
        try await TestSupport.eventually(timeout: .seconds(20)) {
            let state = "active=\(session.active) blocked=\(session.discoveryBlocked) busy=\(session.busy) ack=\(session.awaitingPromptAck) pending=\(session.submissionID != nil) history=\(session.loadingHistory) key=\(session.remoteAgent?.key ?? "none") conversation=\(session.sessionID ?? "none") status=\(session.status ?? "none") failure=\(session.submissionFailure ?? "none")"
            if submissionStates.insert(state).inserted { print("Claude SSH \(backend) first send: " + state) }
            return !session.busy && session.turns.flatMap(\.items).contains { $0.kind == .assistant && $0.text.contains("Local Claude fixture reply: " + greeting) }
        }
        if !transportOnly {
            XCTAssertTrue(session.turns.flatMap(\.items).contains { $0.kind == .reasoning })
            for text in ["SSH queued first", "SSH queued second\nwith newline"] { session.draft = text; runtime.chat.queue(session) }
            try await TestSupport.eventually(timeout: .seconds(20)) {
                !session.busy && session.queuedMessages.isEmpty && session.turns.flatMap(\.items).contains { $0.text == "Local Claude fixture reply: SSH queued second\nwith newline" }
            }
            session.draft = "tool check over SSH"; runtime.chat.submit(session)
            try await TestSupport.eventually(timeout: .seconds(20)) { !session.busy && session.turns.flatMap(\.items).contains { $0.kind == .tool && $0.output.contains("DISPATCH_CLAUDE_TOOL_OK") } }
            // "Send now" on a queued message reaches Claude while it is still working.
            try await waitForInputReady()
            session.draft = "thinking long response to steer over SSH " + backend; runtime.chat.submit(session)
            // The prompt must be acknowledged first; until then the app refuses any further input.
            try await TestSupport.eventually(timeout: .seconds(15)) {
                session.busy && !session.awaitingPromptAck
                    && runtime.chat.canInterrupt(session) && session.nativeActivity == "busy"
            }
            let steer = "steered over SSH " + backend
            session.draft = steer; runtime.chat.queue(session)
            runtime.chat.sendNow(session, queuedID: try XCTUnwrap(session.queuedMessages.first?.id))
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic:
                "steer: busy=\(session.busy) queued=\(session.queuedMessages.count) paused=\(String(describing: session.queuePaused)) failure=\(session.submissionFailure ?? "none")") {
                session.queuedMessages.isEmpty || !session.busy
            }
            XCTAssertTrue(session.queuedMessages.isEmpty, "Send now left the message queued: \(session.submissionFailure ?? "no failure")")
            XCTAssertTrue(session.busy, "The long turn ended before the steered message was delivered")
            XCTAssertNil(session.submissionFailure)
            try await TestSupport.eventually(timeout: .seconds(60)) {
                !session.busy && session.turns.flatMap(\.items).contains { $0.text == "Local Claude fixture reply: " + steer }
            }
        }
        timings?.begin("model_selection")
        let settings = try await readSettings()
        runtime.chat.openModelPicker(session, column: .model)
        let picker = try XCTUnwrap(session.modelPicker)
        try await TestSupport.eventually(timeout: .seconds(20)) { !picker.loading }
        XCTAssertNil(picker.error)
        let model = try XCTUnwrap(picker.models.first { $0.name != "dispatch-fixture" && !$0.isDefault })
        picker.selectModel(model.name)
        try await TestSupport.eventually(timeout: .seconds(15)) { !picker.loading }
        XCTAssertNil(picker.error)
        picker.selectEffort(try XCTUnwrap(picker.efforts.first { $0.effort == "low" }))
        try await TestSupport.eventually(timeout: .seconds(15)) { !picker.loading && !picker.scope.isEmpty }
        picker.selectScope(try XCTUnwrap(picker.scope.first { $0.number == 1 }))
        var pickerStates = Set<String>()
        try await TestSupport.eventually(timeout: .seconds(15)) {
            let state = "attached=\(session.modelPicker === picker) presented=\(picker.presented) loading=\(picker.loading) error=\(picker.error ?? "none") active=\(session.active) blocked=\(session.discoveryBlocked) chat=\(session.showChat) busy=\(session.busy) status=\(session.status ?? "none") model=\(session.model) effort=\(session.effort ?? "none")"
            if pickerStates.insert(state).inserted { print("Claude SSH \(backend) model confirmation: " + state) }
            return session.modelPicker == nil && !session.busy
        }
        guard session.model == ClaudeModelMenu.modelID(detail: model.detail) ?? model.name, session.effort == "low" else {
            XCTFail("Claude closed the picker without confirming \(model.name)/low: \(pickerStates.sorted().joined(separator: "; "))\n" + terminal.agentMenuScreen)
            throw CancellationError()
        }
        let finalSettings = try await readSettings()
        XCTAssertEqual(finalSettings, settings)

        if transportOnly {
            timings?.begin("queued_delivery")
            let messages = ["SSH transport queued first", "SSH transport queued second\nwith λ"]
            for message in messages { session.draft = message; runtime.chat.queue(session) }
            session.draft = "preserved transport draft"
            try await TestSupport.eventually(timeout: .seconds(20)) {
                !session.busy && session.queuedMessages.isEmpty && session.submissionID == nil
                    && session.turns.flatMap(\.items).contains { $0.text == "Local Claude fixture reply: " + messages[1] }
            }
            XCTAssertEqual(session.draft, "preserved transport draft")
            XCTAssertNil(session.queuePaused)
            XCTAssertEqual(Array(session.turns.flatMap(\.items).filter { $0.kind == .user }.map(\.text).suffix(2)), messages)
            // The picker publishes its display label immediately; subsequent
            // transcript records carry the provider's canonical model ID.
            // Check that actual deliveries use that ID, not the old fixture model.
            let requests = try await readRequests().split(separator: 10).map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
            }.filter { ($0["path"] as? String)?.split(separator: "?").first == "/v1/messages" }
            let delivered = Array(requests.suffix(2))
            XCTAssertEqual(delivered.count, 2)
            for request in delivered {
                let body = try XCTUnwrap(request["body"] as? [String: Any])
                XCTAssertEqual(body["model"] as? String, session.model)
                XCTAssertNotEqual(body["model"] as? String, "dispatch-fixture")
            }
            XCTAssertEqual(session.effort, "low")
        } else {
            // Reading settings above crosses actor turns. An idle transcript
            // alone does not prove the application's activity check has settled.
            try await waitForInputReady()
            let turnsBeforeStop = session.turns.count
            session.draft = "thinking long response to stop over SSH " + backend; runtime.chat.submit(session)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic:
                "Waiting for Claude's streamed response before Stop via \(backend)\n\(terminal.agentMenuScreen)") {
                let screen = terminal.agentMenuScreen
                // Busy includes pre-query cancellation, which restores the prompt without
                // an interrupted record. Exercise Stop after this turn's stream has begun.
                return runtime.chat.canInterrupt(session) && session.nativeActivity == "busy" && screen.utf8.count <= 65_536
                    && screen.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                        .contains("Local Claude fixture reply: thinking long response to stop over SSH " + backend)
                    && screen.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        .suffix(4).contains { $0.lowercased().contains("esc to interrupt") }
            }
            session.draft = "do not send after stop"; runtime.chat.queue(session)
            session.draft = "keep my SSH draft λ"
            XCTAssertTrue(runtime.chat.interrupt(session))
            XCTAssertFalse(runtime.chat.interrupt(session))
            try await TestSupport.eventually(timeout: .seconds(10), diagnostic:
                "Stop via \(backend): busy=\(session.busy) interruption=\(String(describing: session.interruptionID)) activity=\(session.nativeActivity ?? "none") failure=\(session.submissionFailure ?? "none") transcript=\(session.transcriptPath ?? "none") interrupted=\(session.seen.filter { $0.hasSuffix(":interrupted") })\n\(terminal.agentMenuScreen)") {
                !session.busy && session.interruptionID == nil && session.seen.contains { $0.hasSuffix(":interrupted") }
            }
            XCTAssertFalse(session.turns.dropFirst(turnsBeforeStop).flatMap(\.items).contains { $0.text.contains("80. Local fixture paragraph") })
            XCTAssertEqual(session.sessionID, conversation); XCTAssertEqual(session.draft, "keep my SSH draft λ")
            XCTAssertEqual(session.queuedMessages.count, 1); XCTAssertNotNil(session.queuePaused)
            XCTAssertFalse(runtime.chat.interrupt(session))
            runtime.chat.removeQueued(try XCTUnwrap(session.queuedMessages.first?.id), from: session)
            try await waitForInputReady()
            session.draft = "recovered after SSH stop " + backend; runtime.chat.submit(session)
            try await TestSupport.eventually(timeout: .seconds(15)) {
                !session.busy && session.turns.flatMap(\.items).contains { $0.text == "Local Claude fixture reply: recovered after SSH stop " + backend }
            }
        }
        let foreign = await helper.refuses("foreign conversation", conversation: UUID().uuidString)
        XCTAssertTrue(foreign, "A different conversation must not authorize remote input")
        try await waitForInputReady()
        session.draft = "/exit"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(10)) { !session.active }
        XCTAssertFalse(session.showChat, "A delivered remote exit returns to the terminal")
        XCTAssertNil(session.terminalAttention)
        XCTAssertTrue(session.draft.isEmpty)
        XCTAssertFalse(session.turns.isEmpty)
        let exited = await helper.refuses("must not reach shell", conversation: conversation)
        XCTAssertTrue(exited, "An exited remote agent must not authorize input")
    }
}
