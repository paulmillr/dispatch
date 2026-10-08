import AppKit
import SwiftUI
import XCTest
import Term
@testable import DispatchApp

@MainActor
final class ChatEndToEndTests: XCTestCase {
    private var observedTerminal: TerminalView?
    func testOfflineDemoResumePublishesHistoryThroughInstalledCodexLauncher() async throws {
        try DesktopTestSupport.requireUnlocked()
        let installed = TestSupport.tool("codex")
        guard FileManager.default.isExecutableFile(atPath: installed) else { throw XCTSkip("Requires the installed Codex launcher") }
        let fixture = try CodexEndpointFixture(prefix: "dispatch-offline-resume-", delay: 0.001, hooks: false)
        var passed = false
        defer { fixture.stop(removeState: passed) }
        let seed = Process()
        seed.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        seed.arguments = [CodexTestSupport.root.appendingPathComponent("scripts/seed-codex-history.py").path,
                          "--state", fixture.state.path, "--turns", "3", "--paragraphs", "2", "--codex", fixture.binary]
        seed.standardOutput = FileHandle.nullDevice; seed.standardError = FileHandle.nullDevice
        try seed.run()
        defer { if seed.isRunning { seed.terminate() } }
        try await TestSupport.eventually(timeout: .seconds(30)) { !seed.isRunning }
        XCTAssertEqual(seed.terminationStatus, 0)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.state.appendingPathComponent("history.json"))) as? [String: Any])
        let conversation = try XCTUnwrap(metadata["session_id"] as? String)
        try await fixture.start(timeout: .seconds(10))
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(autoClose: true)
        defer { app.close() }
        let id = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { runtime.views[id]?.surface != nil }
        let terminal = try XCTUnwrap(runtime.views[id]), session = runtime.chat.session(for: id)
        defer {
            if !passed {
                print("Offline resume: \(session.sessionID ?? "none") / \(session.status ?? "none") / binding=\(session.binding.map { String(describing: $0) } ?? "none")\n\(terminal.agentMenuScreen)")
            }
        }
        let command = ["/usr/bin/python3", CodexTestSupport.root.appendingPathComponent("scripts/offline-codex-demo.py").path,
                       "resume", "--state", fixture.state.path, "--codex", installed].map(HerdrLaunch.quote).joined(separator: " ")
        TerminalTestSupport.send("env PATH=\(TestSupport.path):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin " + command, to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15)) { session.active && AgentModelMenu.containsModel(terminal.agentMenuScreen, slug: "dispatch-fixture", name: "Dispatch fixture") }
        runtime.chat.chooseChat(true, session: session)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Offline resume must publish existing history without a new prompt") {
            session.sessionID == conversation && session.turns.flatMap(\.items).contains {
                $0.kind == .assistant && $0.text.contains("Local fixture reply: history message 2")
            }
        }
        XCTAssertNil(session.status)
        XCTAssertTrue(session.showChat)
        passed = true
    }

    func testRealCodexLocalEndpointThroughShippingBridgeAndTerminalComposer() async throws {
        try await shippingBridgeWalkthrough()
    }

    func testRepeatedCodeModeApprovalsStayInChat() async throws {
        try await shippingBridgeWalkthrough(codeModeApprovals: true)
    }

    private func shippingBridgeWalkthrough(codeModeApprovals: Bool = false) async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        let fixture = try CodexEndpointFixture(prefix: "dispatch-e2e-", delay: 0.005)
        let state = fixture.state
        var passed = false
        defer { fixture.stop(removeState: passed) }
        try await fixture.start(timeout: .seconds(10))
        if codeModeApprovals {
            let catalog = state.appendingPathComponent("models.json")
            let model: [String: Any] = ["slug": "dispatch-fixture", "tool_mode": "code_mode_only", "base_instructions": "You are an offline test fixture.",
                "display_name": "Dispatch fixture", "supported_reasoning_levels": [["effort": "medium", "description": "Fixture"]],
                "shell_type": "unified_exec", "visibility": "list", "supported_in_api": true, "priority": 1,
                "support_verbosity": false, "truncation_policy": ["mode": "bytes", "limit": 10000], "experimental_supported_tools": []]
            try JSONSerialization.data(withJSONObject: ["models": [model]]).write(to: catalog)
            let config = state.appendingPathComponent("codex-home/config.toml")
            let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
            let setting = String(decoding: try encoder.encode(catalog.path), as: UTF8.self)
            try ("model_catalog_json = " + setting + "\n" + String(contentsOf: config, encoding: .utf8)).write(to: config, atomically: true, encoding: .utf8)
        }
        let runtime = TerminalRuntime.shared, controller = AppDelegate()
        let previousChat = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        runtime.workspace = controller.workspace
        runtime.start(preferences: Preferences())
        let workspace = controller.workspace
        workspace.defaultDirectory = state.appendingPathComponent("work").path
        workspace.onCloseTabs = { runtime.close($0) }; workspace.newSpace()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentView = nil; runtime.stop(); runtime.chat = previousChat; observedTerminal = nil }
        let id = workspace.activeTab!.id
        try await eventually { runtime.views[id]?.surface != nil }
        let terminal = runtime.views[id]!
        observedTerminal = terminal
        let surface = terminal.surface
        let launch = CodexTestSupport.command(state: state, binary: fixture.binary)
        TerminalTestSupport.send(launch, to: terminal)
        try await eventually { self.screen(terminal).contains("Hooks need review") }
        try await Task.sleep(for: .milliseconds(250))
        key(36, "\r", terminal)
        try await eventually { self.screen(terminal).contains("trust all") }
        try await Task.sleep(for: .milliseconds(250))
        key(17, "t", terminal)
        try await eventually { ["Press enter to view hooks", "enter details"].contains { self.screen(terminal).contains($0) } }
        try await eventually {
            let config = try? String(contentsOf: state.appendingPathComponent("codex-home/config.toml"), encoding: .utf8)
            return (config?.components(separatedBy: "trusted_hash").count ?? 0) == 11
        }
        key(53, "\u{1b}", terminal)
        // Hook trust applies to the next CLI launch; do not bypass or synthesize it.
        try await eventually { AgentModelMenu.containsModel(self.screen(terminal), slug: "dispatch-fixture default", name: "Dispatch fixture default") }
        // Trust-review dismissal can leave native composer input behind. Clear
        // this isolated fixture prompt before issuing the lifecycle command.
        key(32, "u", terminal, modifiers: .control)
        try await Task.sleep(for: .milliseconds(150))
        // Process identity is helper-owned (session.process); paste and submit like submitChat, through the visible terminal.
        try await eventually { runtime.chat.session(for: id).process != nil }
        let old = try XCTUnwrap(runtime.chat.session(for: id).process)
        terminal.surface?.text("/quit"); key(36, "\r", terminal)
        try await eventually { !old.alive }
        TerminalTestSupport.send(launch, to: terminal)
        try await eventually { AgentModelMenu.containsModel(self.screen(terminal), slug: "dispatch-fixture default", name: "Dispatch fixture default") }
        try await Task.sleep(for: .milliseconds(250))
        terminal.surface?.text("initial local turn"); key(36, "\r", terminal)
        let session = runtime.chat.session(for: id)
        try await eventually { session.active && session.showChat && session.sessionID != nil && session.version != nil }
        XCTAssertTrue(session.showChat)
        try await eventually { !session.busy && session.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: initial local turn" } }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await eventually { window.isKeyWindow }
        // Crossfading never transfers ownership or drops a draft. Interrupt a
        // transition, then verify the real native first responder at each end.
        session.draft = "draft survives animation"
        runtime.chat.chooseChat(false, session: session)
        try await Task.sleep(for: .milliseconds(60))
        runtime.chat.chooseChat(true, session: session)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(window.firstResponder is NSTextView)
        XCTAssertEqual(session.draft, "draft survives animation")
        runtime.chat.chooseChat(false, session: session)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(window.firstResponder === terminal, "Expected terminal focus; got \(String(describing: window.firstResponder)), key=\(window.isKeyWindow), mounted=\(terminal.window === window)")
        XCTAssertTrue(terminal.surface === surface)
        runtime.chat.chooseChat(true, session: session)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(window.firstResponder is NSTextView)
        session.draft = "line one\nline two"
        runtime.chat.sendFromComposer(session)
        try await eventually { !session.busy && session.turns.contains { $0.items.contains { $0.kind == .assistant && $0.text.contains("Local fixture reply: line one\nline two") } } }
        XCTAssertEqual(session.draft, "")
        try await eventually { session.turns.flatMap(\.items).filter { $0.kind == .user }.count == 2 }
        if codeModeApprovals {
            session.draft = "DISPATCH_CODE_APPROVAL approval"
            runtime.chat.sendFromComposer(session)
            for count in 1...2 {
                try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Missing code-mode approval \(count)\n\(self.screen(terminal))") {
                    session.approvals.count == count && session.approvals.last?.pending == true
                }
                let card = try XCTUnwrap(session.approvals.last)
                XCTAssertTrue(card.operation.contains("DISPATCH_LOCAL_TOOL_OK"))
                XCTAssertTrue(session.transcriptRows.contains { $0.approval === card })
                XCTAssertTrue(session.showChat)
                if count == 2 {
                    XCTAssertEqual(card.operation, session.approvals[0].operation)
                    XCTAssertEqual(card.turnID, session.approvals[0].turnID)
                    XCTAssertEqual(card.key, session.approvals[0].key, "Identical hook metadata must still receive separate decisions")
                    try await Task.sleep(for: .milliseconds(350))
                    let visible = try await PresentationTestSupport.capture(window, named: "repeated-code-mode-approval", in: "chat-validation").text()
                    XCTAssertTrue(visible.contains("Allow once"), visible)
                }
                card.resolve(.allow)
            }
            try await eventually { !session.busy }
            XCTAssertTrue(session.approvals.allSatisfy { $0.decision == .allow })
            let hooks = try String(contentsOf: state.appendingPathComponent("hooks.jsonl"), encoding: .utf8)
                .split(separator: "\n").compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            XCTAssertEqual(hooks.filter { $0["hook_event_name"] as? String == "PermissionRequest" }.count, 2)
            passed = true
            return
        }
        for decision in [PendingApproval.Decision.allow, .deny, .terminal] {
            session.draft = "approval " + decision.rawValue
            runtime.chat.sendFromComposer(session)
            try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "decision=\(decision.rawValue), chat=\(session.showChat), active=\(session.active), blocked=\(session.discoveryBlocked), status=\(session.status ?? "none"), approvals=\(session.approvals.map { String(describing: $0.decision) })\n\(self.screen(terminal))") { session.approvals.contains { $0.pending } }
            let card = session.approvals.last!
            if decision == .terminal {
                runtime.chat.chooseChat(false, session: session)
                try await eventually { self.screen(terminal).contains("Would you like to run") }
                key(16, "y", terminal)
            } else { card.resolve(decision) }
            try await eventually { !session.busy }
            XCTAssertFalse(card.pending)
            runtime.chat.chooseChat(true, session: session)
        }
        let originalPrompts = session.turns.flatMap(\.items).filter { $0.kind == .user }.map(\.text)
        session.draft = "patch source preview"
        runtime.chat.sendFromComposer(session)
        try await eventually { !session.busy && session.turns.flatMap(\.items).contains { $0.patch?.documents.isEmpty == false } }
        let patch = try XCTUnwrap(session.turns.flatMap(\.items).flatMap { $0.patch?.documents ?? [] }.first)
        XCTAssertEqual(patch.path, "dispatch-fixture.swift")
        XCTAssertTrue(patch.diff.contains("+let fixture = true"))
        let source = try await patch.source(in: workspace.activeTab!.directory)
        XCTAssertEqual(source, "let fixture = true\n")
        for prompt in originalPrompts {
            XCTAssertTrue(session.turns.flatMap(\.items).contains { $0.kind == .user && $0.text == prompt }, "Sending a later message must retain earlier turns")
        }
        let firstSessionID = session.sessionID
        session.draft = "formatting preview"
        runtime.chat.sendFromComposer(session)
        try await eventually { !session.busy && session.turns.flatMap(\.items).contains { $0.kind == .assistant && $0.text.contains("## Formatting preview") } }
        let failedTool = try XCTUnwrap(session.turns.flatMap(\.items).filter { $0.kind == .tool }.map(ToolPresentation.init).first { $0.exitCode == 7 })
        XCTAssertEqual(failedTool.title, "Shell")
        XCTAssertTrue(failedTool.failed)
        XCTAssertTrue(failedTool.completed)
        XCTAssertTrue(failedTool.input.contains("exit 7"))
        XCTAssertFalse(failedTool.input.contains("/bin/zsh"))
        XCTAssertEqual(failedTool.output, "Formatting fixture: intentional failure\n")
        workspace.newTab()
        let secondID = workspace.activeTab!.id
        try await eventually { runtime.views[secondID]?.surface != nil }
        let second = runtime.views[secondID]!
        TerminalTestSupport.send(launch, to: second)
        try await eventually { AgentModelMenu.containsModel(self.screen(second), slug: "dispatch-fixture default", name: "Dispatch fixture default") }
        try await Task.sleep(for: .milliseconds(250))
        second.surface?.text("initial second turn"); key(36, "\r", second)
        let secondSession = runtime.chat.session(for: secondID)
        try await eventually { secondSession.active && secondSession.version != nil }
        XCTAssertNotEqual(secondSession.sessionID, firstSessionID)
        try await eventually { !secondSession.busy && !secondSession.turns.isEmpty }
        secondSession.draft = "second terminal"
        runtime.chat.sendFromComposer(secondSession)
        try await eventually { !secondSession.busy && secondSession.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: second terminal" } }
        XCTAssertFalse(session.turns.flatMap(\.items).contains { $0.text.contains("second terminal") })
        XCTAssertTrue(terminal.surface === surface)
        workspace.selectTab(id)
        session.draft = "/quit"; runtime.chat.sendFromComposer(session)
        try await eventually { !session.active }
        XCTAssertFalse(session.showChat, "Explicit /quit returns to the terminal")
        XCTAssertFalse(session.turns.isEmpty)
        runtime.chat.chooseChat(true, session: session)
        XCTAssertTrue(session.showChat, "An exited agent's retained transcript can be reopened")
        XCTAssertTrue(terminal.surface === surface)
        XCTAssertTrue(workspace.allTabIDs.contains(id))
        passed = testRun?.failureCount == 0
    }
    private func key(_ code: UInt16, _ text: String, _ terminal: TerminalView, modifiers: NSEvent.ModifierFlags = []) {
        TerminalTestSupport.key(code, text, terminal, modifiers: modifiers)
    }
    private func screen(_ terminal: TerminalView) -> String {
        TerminalTestSupport.screen(terminal: terminal)
    }
    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        try await TestSupport.eventually(timeout: .seconds(10), file: file, line: line,
                                         diagnostic: "Local Codex condition timed out: " + (observedTerminal.map(screen) ?? ""), condition)
    }
}
