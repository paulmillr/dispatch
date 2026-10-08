import AppKit
import Term
import XCTest
@testable import DispatchApp

@MainActor
final class SSHChatIntegrationTests: XCTestCase {
    func testRemotePlainAgentDiscoveryHistoryAndSourcePreview() async throws { try await walkthrough("plain") }
    func testRemoteTmuxAgentDiscoveryHistoryAndSourcePreview() async throws { try await walkthrough("tmux") }
    func testRemoteTmuxControlModeInSSHCommand() async throws { try await walkthrough("tmux-command") }
    func testRemoteTmuxRespawnRediscoversAgent() async throws { try await walkthrough("tmux", respawn: true) }
    func testRemoteTmuxSetupPrecedesAgentLaunchWithoutChatDiscovery() async throws {
        try await walkthrough("tmux", withoutDiscovery: true)
    }
    func testRemoteTmuxCanLaunchWithoutHooksOrChatDiscovery() async throws {
        try await walkthrough("tmux", withoutDiscovery: true, grant: .init(profile: .full, hooks: false))
    }
    func testRemoteHerdrAgentDiscoveryHistoryAndSourcePreview() async throws { try await walkthrough("herdr") }
    func testRemotePlainApprovalHooks() async throws { try await walkthrough("plain", hooks: true) }
    func testRemoteTmuxRepeatedCodeModeApprovals() async throws { try await walkthrough("tmux", hooks: true, codeModeApprovals: true) }
    func testRemoteTmuxAsyncQuestionsCanAnswerAndSkipWithoutConsumingDraft() async throws {
        try await walkthrough("tmux", asynchronous: true)
    }
    func testRemoteHerdrApprovalHooks() async throws { try await walkthrough("herdr", hooks: true) }

    func testRemoteHerdrSideConversationsKeepParentRunning() async throws { try await walkthrough("herdr", sideConversations: true) }
    func testRemotePlainSideConversationsKeepParentRunning() async throws { try await walkthrough("plain", sideConversations: true) }
    func testRemoteTmuxSideConversationsKeepParentRunning() async throws { try await walkthrough("tmux", sideConversations: true) }
    func testRemoteTmuxCommandSideConversationsKeepParentRunning() async throws { try await walkthrough("tmux-command", sideConversations: true) }

    private func walkthrough(_ backend: String, hooks: Bool = false, respawn: Bool = false, sideConversations: Bool = false, asynchronous: Bool = false, codeModeApprovals: Bool = false, withoutDiscovery: Bool = false, grant: SSHIntegrationGrant = .init(profile: .full, hooks: true)) async throws {
        let fixture = try CodexEndpointFixture(prefix: "dispatch-ssh-chat-", delay: 0.01, hooks: false)
        var passed = false
        defer { fixture.stop(removeState: passed) }
        try await fixture.start(timeout: .seconds(15))
        if asynchronous || codeModeApprovals {
            let catalog = fixture.state.appendingPathComponent("models.json")
            let model: [String: Any] = ["slug": "dispatch-fixture", "tool_mode": "code_mode_only", "base_instructions": "You are an offline test fixture.",
                "display_name": "Dispatch fixture", "supported_reasoning_levels": [["effort": "medium", "description": "Fixture"]],
                "shell_type": "unified_exec", "visibility": "list", "supported_in_api": true, "priority": 1,
                "support_verbosity": false, "truncation_policy": ["mode": "bytes", "limit": 10000], "experimental_supported_tools": ["send_user_message_async"]]
            try JSONSerialization.data(withJSONObject: ["models": [model]]).write(to: catalog)
            let config = fixture.state.appendingPathComponent("codex-home/config.toml")
            let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
            let setting = String(decoding: try encoder.encode(catalog.path), as: UTF8.self)
            try ("model_catalog_json = " + setting + "\n" + String(contentsOf: config, encoding: .utf8))
                .write(to: config, atomically: true, encoding: .utf8)
        }
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        if hooks { try await TestSupport.integrations(["codex"], enabled: true, chat: runtime.chat) }
        let app = try TmuxWalkthrough(autoClose: true, server: backend != "tmux" && backend != "tmux-command", liquidGlass: false); defer { app.close() }
        if withoutDiscovery { runtime.chat.stop() }
        let server = try await SSHTestServer(grant: grant)
        defer { server.stop(herdr: server.root.appendingPathComponent("herdr.sock").path) }
        let socket = server.root.appendingPathComponent("herdr.sock").path
        let origin = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { runtime.views[origin].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let original = try XCTUnwrap(runtime.views[origin])
        let tmuxCommand = app.attachCommand(login: true)
        let sshArguments = server.options + (backend == "tmux-command" ? ["-tt", server.destination, tmuxCommand] : [server.destination])
        TerminalTestSupport.send("ssh " + sshArguments.map(HerdrLaunch.quote).joined(separator: " "), to: original)
        try await TestSupport.eventually(timeout: .seconds(20)) { runtime.ssh.links.values.contains { $0.launch.tabID == origin && $0.shellPID != nil } }
        if backend == "tmux" {
            TerminalTestSupport.send(tmuxCommand, to: original)
            try await app.wait { app.workspace.current?.structured == true }
        } else if backend == "tmux-command" {
            try await app.wait { app.workspace.current?.structured == true }
        } else if backend == "herdr" {
            TerminalTestSupport.send("export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(server.root.path) + "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr", to: original)
            try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.current?.shows("herdr") == true }
        }
        let id = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { runtime.views[id]?.surface != nil }
        let terminal = try XCTUnwrap(runtime.views[id])
        let command = CodexTestSupport.command(state: fixture.state, binary: fixture.binary)
        TerminalTestSupport.send(command, to: terminal)
        if withoutDiscovery {
            try await TestSupport.eventually(timeout: .seconds(10), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
                let screen = TerminalTestSupport.screen(terminal: terminal)
                return grant.hooks ? screen.contains("Hooks need review")
                    : AgentModelMenu.containsModel(screen, slug: "dispatch-fixture", name: "Dispatch fixture")
            }
            if grant.hooks {
                let configuration = try String(contentsOf: fixture.state.appendingPathComponent("codex-home/config.toml"), encoding: .utf8)
                XCTAssertEqual(configuration.components(separatedBy: "trusted_hash").count - 1, 0,
                               "Installation must leave native hook review to the user")
                XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("codex-home/hooks.json").path))
            } else {
                let path = fixture.state.appendingPathComponent("codex-home/hooks.json").path
                let exists = try TestSupport.fixture("file.exists", input: path) {
                    FileManager.default.fileExists(atPath: path)
                }
                XCTAssertFalse(exists)
            }
            runtime.chat.start()
        }
        let session = runtime.chat.session(for: id)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "\(session.status ?? "No agent")\n\(TerminalTestSupport.screen(terminal: terminal))") {
            session.active && session.remoteAgent != nil
        }
        XCTAssertNil(session.process, "A remote PID must never become a local process identity")
        if respawn {
            let oldIdentity = try XCTUnwrap(session.remoteAgent)
            let pane = try XCTUnwrap(app.workspace.activeTab.flatMap { app.target($0) })
            _ = try app.server(["respawn-pane", "-k", "-t", pane, "/bin/sh"])
            try await app.wait { !session.active }
            TerminalTestSupport.send(command, to: terminal)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: session.status ?? "Agent not rediscovered after respawn") {
                session.active && session.remoteAgent != nil && session.remoteAgent?.key != oldIdentity.key
            }
            XCTAssertNil(session.process)
        }
        if grant.hooks {
            try await SSHChatTestSupport.trustHooks(state: fixture.state, command: command, session: session, terminal: terminal)
        }
        try await TestSupport.eventually(timeout: .seconds(10)) { AgentModelMenu.containsModel(TerminalTestSupport.screen(terminal: terminal), slug: "dispatch-fixture", name: "Dispatch fixture") }
        let prompt = "remote \(backend) history\nsecond line · λ"
        runtime.chat.chooseChat(true, session: session)
        session.draft = prompt
        runtime.chat.sendFromComposer(session)
        XCTAssertTrue(session.draft.isEmpty, "Submitting must clear the composer before SSH delivery completes")
        session.draft = prompt // Re-typing even identical text belongs to the next message.
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "\(session.status ?? "No remote transcript")\n\(TerminalTestSupport.screen(terminal: terminal))") {
            session.showChat && session.sessionID != nil && session.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: " + prompt }
        }
        try await TestSupport.eventually { session.submissionID == nil }
        XCTAssertEqual(session.draft, prompt, "Delivery must preserve the next draft, even if it matches the sent text")
        session.draft = ""
        XCTAssertNotNil(runtime.ssh.tint(for: try XCTUnwrap(app.workspace.activeTab)))
        if !hooks {
            try await Task.sleep(for: .milliseconds(300))
            _ = try await PresentationTestSupport.capture(app.window, named: "tint-chat-\(backend)", in: "host-tint-validation")
        }
        let identity = try XCTUnwrap(session.remoteAgent), helper = try XCTUnwrap(session.helper)
        // The agent is bound by the SSH host's helper, not this Mac's.
        XCTAssertEqual(helper.endpoint, .remote(identity.connection))
        try await TestSupport.eventually { !session.busy && !session.loadingHistory && session.activityCheck == nil }
        if asynchronous {
            for skip in [false, true] {
                session.draft = "DISPATCH_ASYNC_QUESTION " + (skip ? "ongoing" : "main")
                runtime.chat.sendFromComposer(session)
                try await TestSupport.eventually(timeout: .seconds(15), diagnostic: session.submissionFailure ?? "Remote question missing") {
                    session.questions.contains { !$0.blocking }
                }
                let question = try XCTUnwrap(session.questions.first { !$0.blocking })
                if !skip {
                    try await TestSupport.eventually { !session.busy }
                    question.select("Detailed")
                }
                session.draft = "preserve this draft"
                runtime.chat.answerQuestion(question, skip: skip, session: session)
                try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "Remote answer: \(question.submissionError ?? session.submissionFailure ?? "pending")") {
                    session.questions.isEmpty && session.submissionID == nil && !session.busy
                        && session.turns.flatMap(\.items).contains {
                            $0.kind == .user && $0.text.hasPrefix("Answers to your questions:")
                                && $0.text.contains(skip ? "Skipped" : "Detailed")
                        }
                }
                XCTAssertEqual(session.draft, "preserve this draft")
                XCTAssertNil(question.submissionError)
                XCTAssertTrue(session.queuedMessages.isEmpty)
            }
            passed = true
            return
        }
        if sideConversations {
            let parent = try XCTUnwrap(session.sessionID)
            for mode in [ChatSideMode.btw, .side] {
                let question = "remote side-only \(mode.rawValue) question λ"
                session.clearDraft() // Leave the multiline draft mode used by the history probe.
                session.draft = "/\(mode.rawValue) " + question
                XCTAssertTrue(session.draftIsCommand)
                runtime.chat.sendFromComposer(session)
                let side = try XCTUnwrap(session.sideConversation, session.submissionFailure ?? "Side command did not open")
                try await TestSupport.eventually(timeout: .seconds(30), diagnostic: side.failure ?? "Waiting for remote side reply") {
                    side.failure != nil || (!side.busy && side.messages.contains { !$0.user })
                }
                XCTAssertNil(side.failure)
                XCTAssertTrue(side.messages.contains { !$0.user && $0.text.contains(question) })
                if mode == .btw {
                    let body = try XCTUnwrap(CodexTestSupport.conversationRequests(in: fixture.state).last?["body"] as? [String: Any])
                    func toolNames(_ value: Any) -> [String] {
                        if let values = value as? [Any] { return values.flatMap(toolNames) }
                        if let object = value as? [String: Any] {
                            return ((object["name"] as? String).map { [$0] } ?? []) + object.values.flatMap(toolNames)
                        }
                        return []
                    }
                    let tools = toolNames(body["tools"] ?? [])
                    for forbidden in ["exec_command", "write_stdin", "shell", "shell_command", "apply_patch", "spawn_agent"] {
                        XCTAssertFalse(tools.contains(forbidden), "Remote /btw exposed \(forbidden)")
                    }
                }
                session.draft = "preserve main draft"
                runtime.chat.closeSideConversation(session)
                XCTAssertNil(session.sideConversation)
                XCTAssertFalse(side.ready)
                XCTAssertEqual(session.draft, "preserve main draft")
                XCTAssertEqual(session.sessionID, parent)
                XCTAssertEqual(session.remoteAgent, identity)
                XCTAssertTrue(session.active, "Closing the side chat keeps the parent agent")
                XCTAssertFalse(session.turns.flatMap(\.items).contains { $0.text.contains(question) })
            }
        }
        let second = "second remote \(backend) message\nwith 'quotes', \\slashes and λ"
        session.draft = second
        func submissionState() -> String {
            "active=\(session.active) busy=\(session.busy) submit=\(session.submissionID != nil) ack=\(session.awaitingPromptAck) " +
            "loading=\(session.loadingHistory) activity=\(session.activityCheck != nil) blocked=\(session.discoveryBlocked) " +
            "native=\(session.nativeInputInFlight)/\(session.nativePrompt != nil) picker=\(session.modelPicker != nil) " +
            "command=\(session.command != nil)/\(session.commandEditor != nil) draft=\(session.draft.debugDescription) status=\(session.status ?? "nil")"
        }
        print("SSH chat \(backend) before second submit: " + submissionState())
        runtime.chat.sendFromComposer(session)
        var transitions: [String] = []
        do {
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Second remote reply missing: " + submissionState()) {
                let state = submissionState()
                if transitions.last != state && transitions.count < 32 {
                    transitions.append(state); print("SSH chat \(backend) second submit: " + state)
                }
                return session.draft.isEmpty && !session.busy && session.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: " + second }
            }
        } catch {
            print("SSH chat \(backend) viewport after failure:\n" + TerminalTestSupport.viewport(terminal: terminal))
            _ = try? await PresentationTestSupport.capture(app.window, named: "second-submit-failed-" + backend, in: "ssh-chat-validation")
            throw error
        }
        if hooks {
            session.draft = codeModeApprovals ? "DISPATCH_CODE_APPROVAL approval" : "remote \(backend) approval check"
            runtime.chat.sendFromComposer(session)
            for count in 1...(codeModeApprovals ? 2 : 1) {
                try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Missing remote approval \(count)\n\(session.status ?? "No remote approval")\n\(TerminalTestSupport.screen(terminal: terminal))") {
                    session.approvals.count == count && session.approvals.last?.pending == true
                }
                let approval = try XCTUnwrap(session.approvals.last)
                XCTAssertTrue(approval.operation.contains("DISPATCH_LOCAL_TOOL_OK"))
                XCTAssertTrue(session.transcriptRows.contains { $0.approval === approval })
                XCTAssertTrue(session.showChat)
                if count == 2 {
                    XCTAssertEqual(approval.operation, session.approvals[0].operation)
                    XCTAssertEqual(approval.turnID, session.approvals[0].turnID)
                    XCTAssertEqual(approval.key, session.approvals[0].key, "Identical remote hook metadata must still receive separate decisions")
                    try await Task.sleep(for: .milliseconds(350))
                    let visible = try await PresentationTestSupport.capture(app.window, named: "ssh-tmux-repeated-approval", in: "chat-validation").text()
                    XCTAssertTrue(visible.contains("Allow once"), visible)
                }
                approval.resolve(.allow)
            }
            try await TestSupport.eventually(timeout: .seconds(15)) {
                !session.busy && session.turns.flatMap(\.items).contains { $0.kind == .tool && $0.output.contains("DISPATCH_LOCAL_TOOL_OK") }
            }
        }
        let work = fixture.state.appendingPathComponent("work")
        let path = work.appendingPathComponent("preview.txt")
        let source = try TestSupport.fixture("file.write", input: path) {
            let source = "Remote source · \(UUID().uuidString)"
            try source.write(to: path, atomically: true, encoding: .utf8)
            return source
        }
        let text = try await ToolDocument(path: "preview.txt", diff: "").source(in: work.path, endpoint: helper.endpoint)
        XCTAssertEqual(text, source)
        session.draft = "Preserve this remote draft"
        runtime.chat.chooseChat(false, session: session)
        try await app.wait { terminal.isPresented }
        try await sendToAgent("/quit", terminal: terminal)
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: TerminalTestSupport.screen(terminal: terminal)) { !session.active }
        XCTAssertEqual(session.draft, "Preserve this remote draft")
        XCTAssertFalse(session.turns.isEmpty)
        let stale = await helper.refuses("printf DISPATCH_STALE_DRAFT_SHOULD_NOT_RUN", conversation: try XCTUnwrap(session.sessionID))
        XCTAssertTrue(stale, "A retained agent identity must not submit into its shell after exit")
        XCTAssertFalse(TerminalTestSupport.screen(terminal: terminal).contains("DISPATCH_STALE_DRAFT_SHOULD_NOT_RUN"))
        passed = true
    }

    private func sendToAgent(_ text: String, terminal: TerminalView) async throws {
        let surface = try XCTUnwrap(terminal.surface)
        surface.text(text)
        // Codex batches bursts of unbracketed key events as paste. Use the real
        // paste encoder and allow its editor to process the paste before Return.
        try await Task.sleep(for: .milliseconds(100))
        TerminalTestSupport.key(36, "\r", terminal)
    }
}
