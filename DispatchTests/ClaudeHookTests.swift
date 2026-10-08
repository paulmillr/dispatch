import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class ClaudeHookTests: XCTestCase {

    // Claude's hook events reach the app as the claude harness's interactions (hooks.rs): id
    // "<conversation>:<tool_use_id>" (or the operation without a tool id), one approval question whose text is
    // the operation "<tool>\n<printable input>", or the AskUserQuestion questionnaire. Event validation, matching
    // against Claude's transcript and the hook reply are the harness's own tests; the app
    // owns the card, its turn, receipts and expiry.

    private func permission(_ conversation: String, call: String?, tool: String, input: [String: Any]) -> [String: Any] {
        let operation = tool + "\n" + TranscriptParser.printable(input)
        return ["id": conversation + ":" + (call ?? operation), "approval": true, "blocking": true, "questions": [[
            "id": "approval", "header": tool, "text": operation, "secret": false, "multiple": false, "custom": false,
            "options": ["Allow", "Deny", "Terminal"].map { ["id": $0, "label": $0] },
            "blocks": [["kind": "code", "language": "json", "text": operation]]]]]
    }

    /// The harness withdrew the interaction (answered elsewhere, expired, revoked).
    private func withdrawn(_ id: String) -> [String: Any] { ["id": id, "approval": true, "blocking": true, "questions": []] }

    private func deliver(_ interaction: [String: Any], to session: ChatSession, chat: ChatCoordinator) throws {
        let value = try JSONDecoder().decode(HelperChat.Interaction.self, from: JSONSerialization.data(withJSONObject: interaction))
        chat.receiveHelper(.interaction(value), session: session)
    }

    private func session(_ chat: ChatCoordinator, conversation: String) -> ChatSession {
        let session = chat.session(for: UUID())
        session.helper = HelperChat(terminal: 0); session.sessionID = conversation
        return session
    }

    func testLivePermissionDoesNotRequirePersistedToolButRejectsContradictions() throws {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { chat.stop() }
        let conversation = UUID().uuidString, input: [String: Any] = ["file_path": "/work/test.txt"]
        let arguments = TranscriptParser.printable(input)
        let interaction = permission(conversation, call: "call", tool: "Edit", input: input)
        let tool = ChatItem(id: "tool-call", kind: .tool, text: arguments, title: "Edit")
        // Contradicting tools (completed, renamed, other arguments) are refused by the harness: no interaction.
        let cases: [(items: [ChatItem], awaiting: Bool, turn: String?)] = [
            ([], false, nil), ([ChatItem(id: "user", kind: .user, text: "Edit the file")], false, nil),
            ([tool], false, "turn"), ([tool], true, nil)
        ]
        for test in cases {
            let session = session(chat, conversation: conversation)
            session.activeTurnID = "turn"; session.awaitingPromptAck = test.awaiting
            session.turns = [ChatTurn(id: "turn", items: test.items)]
            // The harness names the acknowledged turn holding the matching tool, and the tool record it found.
            var interaction = interaction
            interaction["turn"] = test.turn
            interaction["record"] = test.items.contains { $0.id == tool.id } ? tool.id : nil
            try deliver(interaction, to: session, chat: chat)
            XCTAssertEqual(session.approvals.map { [$0.key, $0.operation, $0.turnID] }, [[conversation + ":call", "Edit\n" + arguments, test.turn]])
            XCTAssertEqual(session.approvals.map { [$0.item?.id, $0.item?.title, $0.item?.text] }, [[conversation + ":call", "Edit", arguments]])
            XCTAssertEqual(session.transcriptRows.compactMap(\.approval).map(\.id), session.approvals.map(\.id))
            XCTAssertEqual(session.turns.map { $0.items.map(\.id) }, [test.items.map(\.id)], "A hook must not invent transcript records")
            try deliver(interaction, to: session, chat: chat)
            XCTAssertEqual(session.approvals.count, 1, "A repeated request is the same card")
            try deliver(withdrawn(conversation + ":call"), to: session, chat: chat)
            session.approvals[0].resolve(.allow)
            XCTAssertEqual(session.approvals[0].decision, .expired)
            XCTAssertEqual(session.approvals[0].item?.text, arguments, "Receipts retain the exact requested input")
        }
    }

    func testLiveQuestionsAssociateOnlyWithTheAcknowledgedMatchingTool() throws {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { chat.stop() }
        let conversation = UUID().uuidString
        let input: [String: Any] = ["questions": [["question": "Which example?", "header": "Example",
            "options": [["label": "Swift"], ["label": "Rust"]]]]]
        let interaction: [String: Any] = ["id": conversation + ":call", "record": "tool-call", "approval": false, "blocking": true, "questions": [[
            "id": "Which example?", "header": "Example", "text": "Which example?", "secret": false, "multiple": false, "custom": true,
            "options": [["id": "Swift", "label": "Swift"], ["id": "Rust", "label": "Rust"]]]]]
        let expected = ClaudeQuestions([.init(text: "Which example?", header: "Example", options: [
            .init(label: "Swift", description: "", preview: nil), .init(label: "Rust", description: "", preview: nil)], multiple: false)])
        let user = ChatItem(id: "user", kind: .user, text: "multiple questions please")
        let tool = ChatItem(id: "tool-call", kind: .tool, text: TranscriptParser.printable(input), title: "AskUserQuestion")
        for awaiting in [false, true] {
            for items in [[], [user], [user, tool]] {
                let session = session(chat, conversation: conversation)
                session.activeTurnID = "turn"; session.awaitingPromptAck = awaiting
                session.turns = [ChatTurn(id: "turn", items: items)]
                var interaction = interaction
                interaction["turn"] = !awaiting && items.count == 2 ? "turn" : nil
                try deliver(interaction, to: session, chat: chat)
                XCTAssertEqual(session.approvals.map(\.turnID), [!awaiting && items.count == 2 ? "turn" : nil])
                XCTAssertEqual(session.approvals.compactMap(\.questions), [expected])
                XCTAssertEqual(session.turns.map { $0.items.map(\.id) }, [items.map(\.id)])
                // Once the transcript reads the call, its card stays with that
                // turn instead of following every later turn.
                session.turns = [ChatTurn(id: "turn", items: [user, tool]),
                                 ChatTurn(id: "next", items: [ChatItem(id: "later", kind: .user, text: "later")])]
                let rows = session.transcriptRows.map { $0.approval != nil ? "approval" : $0.item?.id ?? $0.id }
                XCTAssertEqual(rows.suffix(2), ["approval", "later"], rows.description)
            }
        }
    }

    func testPermissionEventValidationAndRequestWithoutToolID() throws {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { chat.stop() }
        let conversation = UUID().uuidString
        let session = session(chat, conversation: conversation)
        try deliver(permission(conversation, call: nil, tool: "Edit", input: ["file_path": "/work/test.txt"]), to: session, chat: chat)
        XCTAssertEqual(session.transcriptRows.compactMap(\.approval).map(\.turnID), [nil])
        // Without a call ID, a pending card stays last even beside an earlier identical call; once resolved, its
        // receipt follows the call's turn instead of sitting above the composer after every later turn.
        let call = { (id: String) in ChatItem(id: id, kind: .tool, text: TranscriptParser.printable(["file_path": "/work/test.txt"]), title: "Edit") }
        let rows = { session.transcriptRows.map { $0.approval != nil ? "approval" : $0.item?.id ?? $0.id } }
        session.turns = [ChatTurn(id: "earlier", items: [call("tool-earlier")])]
        XCTAssertEqual(rows().last, "approval")
        session.approvals[0].resolve(.deny)
        XCTAssertEqual(session.approvals[0].decision, .deny)
        session.turns += [ChatTurn(id: "turn", items: [call("tool-call")]),
                          ChatTurn(id: "next", items: [ChatItem(id: "later", kind: .user, text: "later")])]
        XCTAssertEqual(rows().suffix(3), ["tool-call", "approval", "later"], rows().description)
        // The deny reply's shape and the rejected event variants (foreign session, subagent, other hook,
        // blank tool, non-object input, empty tool id) are tested with the claude harness.
    }

    // Installation (the old AgentHookSetup) is the claude harness's installation.install into the test home's
    // Claude settings; the app installs through HelperChat.setup, as setHelperIntegration does.

    private var config: URL { Home.url.appendingPathComponent(".claude/settings.json") }

    /// Runs `body` on the test home's Claude settings, restoring the previous file and installation after.
    private func settings(_ body: () async throws -> Void) async throws {
        let fm = FileManager.default, previous = try? Data(contentsOf: config)
        try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { if let previous { try? previous.write(to: config) } else { try? fm.removeItem(at: config) } }
        try await body()
    }

    @discardableResult
    private func install(_ enabled: Bool?) async throws -> HelperChat.Installation {
        let installation = try await HelperChat.setup(.local, key: "claude", enabled: enabled, terminal: nil)
        return try XCTUnwrap(installation)
    }

    /// The helper's own hook command, as it installs it.
    private func command() async throws -> String {
        try? FileManager.default.removeItem(at: config)
        try await install(true)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? NSDictionary)
        let command = try XCTUnwrap(root.value(forKeyPath: "hooks.PermissionRequest") as? [NSDictionary])
        return try XCTUnwrap((command.first?["hooks"] as? [NSDictionary])?.first?["command"] as? String)
    }

    func testLifecycleUpgradePreservesDecisionAndUnrelatedConfiguration() async throws {
        try await settings {
            let command = try await command()
            let original: [String: Any] = ["model": "custom", "hooks": ["PermissionRequest": [
                ["matcher": "Bash", "hooks": [["type": "command", "command": "other hook", "timeout": 7]]],
                ["hooks": [["type": "command", "command": command, "timeout": 60]]]
            ]]]
            try JSONSerialization.data(withJSONObject: original).write(to: config)
            let audit = try await install(nil)
            XCTAssertEqual(audit.installed, true, "An earlier approval opt-in counts as installed")
            try await install(true)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
            let hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
            XCTAssertEqual(Set(hooks.keys), ["PermissionRequest", "PreToolUse", "SessionStart", "SessionEnd",
                                           "UserPromptSubmit", "PostToolUse", "SubagentStart", "SubagentStop", "Stop"])
            let once = try Data(contentsOf: config)
            try await install(true)
            XCTAssertEqual(try Data(contentsOf: config), once)
            try await install(false)
            let expected: [String: Any] = ["model": "custom", "hooks": ["PermissionRequest": [
                ["matcher": "Bash", "hooks": [["type": "command", "command": "other hook", "timeout": 7]]]
            ]]]
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? NSDictionary, expected as NSDictionary)
        }
    }

    func testSettingsPreserveHandlersPermissionsAndTrust() async throws {
        try await settings {
            _ = try await command()
            let original = Data(#"{"model":"mine","permissions":{"deny":["Read(secret)"]},"hooks":{"PermissionRequest":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo mine","timeout":7}]}]}}"#.utf8)
            try original.write(to: config)
            let trust = Home.url.appendingPathComponent(".claude.json"), previousTrust = try? Data(contentsOf: trust)
            defer { if let previousTrust { try? previousTrust.write(to: trust) } else { try? FileManager.default.removeItem(at: trust) } }
            let trustData = Data(#"{"projects":{"mine":{"hasTrustDialogAccepted":false}}}"#.utf8)
            try trustData.write(to: trust)
            try await install(true)
            let audit = try await install(nil)
            XCTAssertEqual(audit.installed, true)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? NSDictionary)
            let questions = try XCTUnwrap(root.value(forKeyPath: "hooks.PreToolUse") as? [NSDictionary])
            XCTAssertEqual(questions.first?["matcher"] as? String, "AskUserQuestion", "Questions are installed too")
            let installed = try Data(contentsOf: config)
            try await install(true)
            XCTAssertEqual(try Data(contentsOf: config), installed)
            try await install(false)
            let removed = try await install(nil)
            XCTAssertEqual(removed.installed, false)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? NSDictionary,
                           try JSONSerialization.jsonObject(with: original) as? NSDictionary)
            XCTAssertEqual(try Data(contentsOf: trust), trustData)
            let malformed = Data(#"{"hooks":[]}"#.utf8)
            try malformed.write(to: config)
            do { try await install(true); XCTFail("Malformed settings must not be repaired") } catch {}
            XCTAssertEqual(try Data(contentsOf: config), malformed)
        }
    }

    func testPreviousApprovalOptInSurvivesQuestionHookUpgrade() async throws {
        try await settings {
            let command = try await command()
            let legacy: [String: Any] = ["hooks": ["PermissionRequest": [["hooks": [["type": "command", "command": command, "timeout": 60]]]]]]
            try JSONSerialization.data(withJSONObject: legacy).write(to: config)
            let audit = try await install(nil)
            XCTAssertEqual(audit.installed, true)
            try await install(true)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
            let hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
            XCTAssertEqual(hooks["PreToolUse"]?.first?["matcher"] as? String, "AskUserQuestion")
        }
    }

    func testRealLocalClaudeAllowsDeniesAndRevokesApproval() async throws {
        let restore = TestSupport.preserveRuntime()
        defer { restore() }
        try DesktopTestSupport.requireUnlocked()
        let fm = FileManager.default
        let claude = try XCTUnwrap([TestSupport.tool("claude")].first { fm.isExecutableFile(atPath: $0) })
        let state = fm.temporaryDirectory.appendingPathComponent("dispatch-claude-approval-" + UUID().uuidString)
        let script = CodexTestSupport.root.appendingPathComponent("scripts/claude_fixture.py").path
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [script, "serve", "--state", state.path, "--delay", "0.01"]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer {
            if server.isRunning { server.terminate(); server.waitUntilExit() }
            print("Claude approval fixture: " + state.path)
        }
        try await TestSupport.eventually { fm.fileExists(atPath: state.appendingPathComponent("endpoint.json").path) }
        let runtime = TerminalRuntime.shared, controller = AppDelegate(), previousChat = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        try await TestSupport.integrations(["claude"], enabled: true, chat: runtime.chat)
        let chat = runtime.chat
        // Turned off within the test (revocation, awaited); the fallback only runs when the test stops earlier.
        // An unawaited turn-off would still be writing the settings the next test installs into.
        var revokedIntegration = false
        defer { if !revokedIntegration { chat.setHelperIntegration("claude", enabled: false) } }
        runtime.workspace = controller.workspace; runtime.start(preferences: Preferences())
        let workspace = controller.workspace
        workspace.defaultDirectory = state.appendingPathComponent("work").path
        workspace.onCloseTabs = { runtime.close($0) }; workspace.newSpace()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentView = nil; runtime.stop(); runtime.chat = previousChat }
        let id = workspace.activeTab!.id
        try await TestSupport.eventually { runtime.views[id]?.surface != nil }
        let terminal = try XCTUnwrap(runtime.views[id]), session = runtime.chat.session(for: id)
        defer { print("Claude approval final state: \(session.status ?? "none") / \(session.submissionFailure ?? "none")\n\(terminal.agentMenuScreen)") }
        session.manualViewChoice = true
        // Claude reads the configuration the helper installed its integration into (the test home's).
        try TestSupport.trustClaudeWorkspace(state.appendingPathComponent("work"), config: Home.url.appendingPathComponent(".claude"))
        TerminalTestSupport.send(["python3", script, "launch", "--state", state.path, "--claude", claude, "--integration", "--hooks",
            "--config", Home.url.appendingPathComponent(".claude").path].map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: terminal.agentMenuScreen) {
            session.active && session.agentID == "claude" && !session.loadingHistory && !session.busy && terminal.agentMenuScreen.contains("for shortcuts")
        }
        runtime.chat.chooseChat(true, session: session)
        // Events a real, owned process cannot route (a foreign conversation, a subagent request, an event that
        // would change transcript identity) and a hook for a tool Claude never ran are refused or carried by the
        // claude harness (its hook socket checks the sender); injecting them is the harness's test.
        runtime.chat.chooseChat(true, session: session)
        let marker = state.appendingPathComponent("work/dispatch-approval-marker")
        for decision in [PendingApproval.Decision.deny, .allow] {
            session.draft = "permission tool " + decision.rawValue
            runtime.chat.submit(session)
            XCTAssertNotNil(session.optimisticPrompt, session.submissionFailure ?? "First prompt was not submitted")
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Claude permission: \(terminal.agentMenuScreen)") {
                session.approvals.contains(where: \.pending)
            }
            let approval = try XCTUnwrap(session.approvals.last(where: \.pending))
            XCTAssertTrue(approval.operation.contains("dispatch-approval-marker"))
            // The live hook may arrive before Claude persists its tool.
            if let turn = approval.turnID {
                XCTAssertEqual(turn, session.turns.last(where: { $0.items.contains { $0.kind == .user && $0.text == "permission tool " + decision.rawValue } })?.id)
            }
            XCTAssertFalse(fm.fileExists(atPath: marker.path))
            if decision == .deny {
                var visible = false
                for _ in 0..<12 where !visible {
                    try await Task.sleep(for: .milliseconds(100))
                    let snapshot = try await PresentationTestSupport.capture(window)
                    if try snapshot.text().contains("Allow once") {
                        try PresentationTestSupport.save(snapshot.bitmap, named: "claude-permission", in: "claude-chat-audit")
                        visible = true
                    }
                }
                XCTAssertTrue(visible, "The actual approval card must be readable after its arrival animation")
            }
            approval.resolve(decision)
            let expected = decision == .allow ? "completed." : "denied or failed."
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: terminal.agentMenuScreen) {
                !session.busy && session.turns.flatMap(\.items).contains { $0.kind == .assistant && $0.text.contains("Tool result received: " + expected) }
            }
            XCTAssertEqual(fm.fileExists(atPath: marker.path), decision == .allow)
        }
        // Revoke an already-held request; its previous card cannot approve.
        try fm.removeItem(at: marker)
        session.draft = "permission tool revoke"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: terminal.agentMenuScreen) { session.approvals.contains(where: \.pending) }
        let revoked = try XCTUnwrap(session.approvals.last(where: \.pending))
        runtime.chat.setHelperIntegration("claude", enabled: false)
        XCTAssertFalse(revoked.pending); revoked.resolve(.allow)
        XCTAssertFalse(fm.fileExists(atPath: marker.path))
        try await TestSupport.eventually { runtime.chat.hookStatus("claude") == .off }
        revokedIntegration = true
        // The unanswered request returns to Claude's native permission UI.
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: terminal.agentMenuScreen) {
            session.terminalAttention != nil && ClaudeScreen.permission(terminal.agentMenuScreen)
        }
    }
}
