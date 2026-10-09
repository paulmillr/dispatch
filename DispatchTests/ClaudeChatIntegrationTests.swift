import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class ClaudeChatIntegrationTests: XCTestCase {
    func testLocalDiscoveryComposerThinkingToolsAndExit() async throws { try await walkthrough(exitOnly: false) }
    func testQuitReturnsKeyboardFocusToShell() async throws { try await walkthrough(exitOnly: true, exitCommand: "/quit") }
    func testTypingBeforeChatOpensMovesToTheChatDraft() async throws { try await walkthrough(exitOnly: true, typeahead: true) }

    private func walkthrough(exitOnly: Bool, exitCommand: String = "/exit", typeahead: Bool = false) async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        let phaseTimings = WalkthroughTimings(test: name, agent: "claude", transport: "local")
        phaseTimings.begin("endpoint_startup")
        var passed = false
        defer { phaseTimings.save(passed: passed && testRun?.failureCount == 0) }
        try DesktopTestSupport.requireUnlocked()
        let fm = FileManager.default
        let binary = [TestSupport.tool("claude")].first { fm.isExecutableFile(atPath: $0) }
        let claude = try XCTUnwrap(binary, "Run ./run.sh --test to prepare Claude Code")
        let state = fm.temporaryDirectory.appendingPathComponent("dispatch-claude-chat-" + UUID().uuidString)
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = [CodexTestSupport.root.appendingPathComponent("scripts/claude_fixture.py").path,
                             "serve", "--state", state.path, "--delay", "0.08"]
        fixture.standardOutput = FileHandle.nullDevice; fixture.standardError = FileHandle.nullDevice
        try fixture.run()
        defer {
            if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() }
            print("Claude Chat fixture: " + state.path)
        }
        try await TestSupport.eventually { fm.fileExists(atPath: state.appendingPathComponent("endpoint.json").path) }
        phaseTimings.begin("runtime_setup")
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
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { runtime.chat = previousChat }
        func finish() async {
            phaseTimings.begin("teardown")
            window.close(); window.contentView = nil
            await runtime.stop().value
        }
        do {
            let id = workspace.activeTab!.id
            try await TestSupport.eventually { runtime.views[id]?.surface != nil }
            let terminal = try XCTUnwrap(runtime.views[id])
            let session = runtime.chat.session(for: id)
            session.manualViewChoice = true
            let args = ["python3", CodexTestSupport.root.appendingPathComponent("scripts/claude_fixture.py").path,
                        "launch", "--state", state.path, "--claude", claude, "--integration"]
            phaseTimings.begin("agent_readiness")
            TerminalTestSupport.send(args.map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
            func screen() -> String { terminal.agentMenuScreen }
            func wait(_ text: String) async throws {
                try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Expected \(text)\n\(screen())") { screen().contains(text) }
            }
            try await wait("for shortcuts")
            try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "Claude discovery: \(session.status ?? "none")\n\(screen())") {
                session.active && session.agentID == "claude" && session.sessionID != nil && !session.loadingHistory
            }
            phaseTimings.begin("scenario")
            let process = try XCTUnwrap(session.process)
            func exitToShell() async throws {
                // Transcript completion can precede the terminal's next idle frame.
                try await TestSupport.eventually(diagnostic: "Native idle: \(screen())") {
                    !session.busy && session.activityCheck == nil && ClaudeModelMenu.isEmptyComposer(screen())
                }
                // Dispatch returns focus only to its key window (TerminalRuntime.focusActive);
                // another app may have become active during the walkthrough.
                try await TestSupport.eventually(diagnostic: "The test window must be key before exit") {
                    if !window.isKeyWindow { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
                    return window.isKeyWindow
                }
                session.draft = exitCommand
                runtime.chat.submit(session)
                try await TestSupport.eventually(diagnostic: "Exit: \(session.submissionFailure ?? "pending")\n\(screen())") { !process.alive && !session.active }
                XCTAssertFalse(session.showChat, "An explicit exit returns to the shell")
                XCTAssertNil(session.terminalAttention)
                XCTAssertTrue(session.draft.isEmpty)
                try await TestSupport.eventually { terminal.isPresented && window.firstResponder === terminal }
                TerminalTestSupport.send("printf 'CHAT_EXIT_%s\\n' OK", to: terminal)
                try await wait("CHAT_EXIT_OK")
                let refused = try await XCTUnwrap(session.helper).refuses("must not reach shell", conversation: try XCTUnwrap(session.sessionID))
                XCTAssertTrue(refused, "An exited agent must not take input")
                XCTAssertTrue(runtime.chat.canEnterChat(session))
                XCTAssertTrue(session.turns.flatMap(\.items).contains { $0.kind == .assistant })
            }
            XCTAssertEqual(session.agentID, "claude")
            XCTAssertEqual(session.agentTitle, "Claude Code")
            if typeahead {
                // Typed into Claude's prompt while Terminal still shows, then discovery opens Chat.
                terminal.insertText("thinking hello", replacementRange: NSRange(location: NSNotFound, length: 0))
                try await TestSupport.eventually(diagnostic: "Typed in Terminal\n\(screen())") {
                    ClaudeModelMenu.composerText(screen()) == "thinking hello"
                }
                runtime.chat.setChatVisible(true, session: session)
                runtime.chat.adoptTerminalTypeahead(session)
                try await TestSupport.eventually(diagnostic: "Typeahead: \(session.draft)\n\(screen())") { session.draft == "thinking hello" }
                XCTAssertNil(terminal.typeahead)
                session.draft += " from chat"
            }
            runtime.chat.chooseChat(true, session: session)
            // Ready for input: the helper's binding of this agent is live and it reports idle (the agent runs on
            // the helper's pty, not the app view's, so the view's foreground process does not name it).
            try await TestSupport.eventually(diagnostic: "Claude input readiness: active=\(session.active), process=\(process.alive), busy=\(session.busy), activity=\(String(describing: session.activityCheck))\n\(screen())") {
                session.active && process.alive && !session.busy && session.activityCheck == nil &&
                    ClaudeModelMenu.isEmptyComposer(screen())
            }
            if !typeahead { session.draft = "thinking hello from chat" }
            XCTAssertEqual(session.draft, "thinking hello from chat")
            runtime.chat.submit(session)
            XCTAssertNotNil(session.optimisticPrompt)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Claude reply: \(session.status ?? "none") \(session.submissionFailure ?? "none")\n\(screen())") {
                !session.busy && session.turns.flatMap(\.items).contains { $0.kind == .assistant && $0.text == "Local Claude fixture reply: thinking hello from chat" }
            }
            XCTAssertNil(session.optimisticPrompt)
            XCTAssertEqual(session.turns.flatMap(\.items).filter { $0.kind == .user }.count, 1)
            XCTAssertTrue(session.turns.flatMap(\.items).contains { $0.kind == .reasoning && $0.text.contains("Synthetic fixture trace") })
            XCTAssertEqual(session.model, "dispatch-fixture")
            if exitOnly { try await exitToShell(); await finish(); passed = testRun?.failureCount == 0; return }
            let settingsPath = state.appendingPathComponent("claude-home/settings.json")
            let savedSettings = try? Data(contentsOf: settingsPath)
            runtime.chat.openModelPicker(session, column: .model)
            try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "Claude picker: \(session.modelPicker?.error ?? "none") busy=\(session.busy)\n\(screen())") {
                session.modelPicker.map { !$0.loading && !$0.models.isEmpty } == true
            }
            let picker = try XCTUnwrap(session.modelPicker)
            XCTAssertNil(picker.error)
            let model = try XCTUnwrap(picker.models.first { $0.name != "dispatch-fixture" && !$0.isDefault })
            picker.selectModel(model.name)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Claude model: \(picker.error ?? "none")\n\(screen())") { !picker.loading }
            XCTAssertNil(picker.error)
            let low = try XCTUnwrap(picker.efforts.first { $0.effort == "low" })
            picker.selectEffort(low)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Claude confirmation: \(picker.error ?? "none")\n\(screen())") { !picker.loading && !picker.scope.isEmpty }
            XCTAssertEqual(picker.scopeTitle, "Switch model?")
            try await Task.sleep(for: .milliseconds(250))
            var capturedConfirmation = false
            for popup in NSApp.windows where popup.isVisible && popup !== window && popup.contentView != nil {
                let snapshot = try await PresentationTestSupport.capture(popup)
                if try snapshot.text().contains("Switch model") {
                    try PresentationTestSupport.save(snapshot.bitmap, named: "claude-model-confirmation", in: "claude-chat-audit")
                    capturedConfirmation = true
                }
            }
            XCTAssertTrue(capturedConfirmation, "The model-switch confirmation must be visible in the actual popover")
            NSApp.sendEvent(TerminalTestSupport.keyEvent(36, "\r", in: NSApp.keyWindow))
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Claude apply: \(picker.error ?? "none")\n\(screen())") { session.modelPicker == nil }
            XCTAssertEqual(session.model, ClaudeModelMenu.modelID(detail: model.detail) ?? model.name); XCTAssertEqual(session.effort, "low")
            XCTAssertEqual(try? Data(contentsOf: settingsPath), savedSettings, "Chat selection must not change Claude's saved defaults")
            try await TestSupport.eventually { runtime.chat.canPickModel(session) }
            runtime.chat.openModelPicker(session, column: .effort)
            let cached = try XCTUnwrap(session.modelPicker)
            XCTAssertFalse(cached.loading); XCTAssertFalse(cached.efforts.isEmpty)
            XCTAssertNil(ClaudeModelMenu(screen()), "Browsing cached choices must not open the native menu")
            cached.close()
            XCTAssertNil(session.modelPicker)
            runtime.chat.openModelPicker(session, column: .effort)
            let effortOnly = try XCTUnwrap(session.modelPicker)
            effortOnly.selectEffort(try XCTUnwrap(effortOnly.efforts.first { $0.effort == "high" }))
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Effort-only: \(effortOnly.error ?? "none")\n\(screen())") { session.modelPicker == nil }
            XCTAssertEqual(session.model, ClaudeModelMenu.modelID(detail: model.detail) ?? model.name); XCTAssertEqual(session.effort, "high")
            try await TestSupport.eventually { runtime.chat.canPickModel(session) }
            session.draft = "tool check\nsecond line"
            runtime.chat.submit(session)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: screen()) {
                !session.busy && session.turns.flatMap(\.items).contains { $0.kind == .assistant && $0.text.contains("Tool result received: completed.") }
            }
            XCTAssertTrue(session.turns.flatMap(\.items).contains { $0.kind == .tool && $0.completed && $0.output.contains("DISPATCH_CLAUDE_TOOL_OK") })
            XCTAssertEqual(session.turns.flatMap(\.items).filter { $0.kind == .user }.count, 2)
            let beforeDecline = session.model
            runtime.chat.openModelPicker(session, column: .model)
            let declined = try XCTUnwrap(session.modelPicker)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: declined.error ?? "none") { !declined.loading && !declined.models.isEmpty }
            let alternative = try XCTUnwrap(declined.models.first { !$0.isDefault && $0.name != declined.selectedModel && $0.name != "dispatch-fixture" })
            declined.selectModel(alternative.name)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: declined.error ?? "none") { !declined.loading }
            declined.selectEffort(try XCTUnwrap(declined.efforts.first { $0.effort == "high" }))
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Decline switch: \(declined.error ?? "none")\n\(screen())") { !declined.loading && !declined.scope.isEmpty }
            declined.selectScope(try XCTUnwrap(declined.scope.first { $0.number == 2 }))
            try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "Decline: \(declined.error ?? "none")\n\(screen())") { session.modelPicker == nil }
            XCTAssertEqual(session.model, beforeDecline); XCTAssertEqual(session.effort, "high")
            XCTAssertEqual(try? Data(contentsOf: settingsPath), savedSettings)
            try await TestSupport.eventually { !session.busy }
            _ = try await PresentationTestSupport.capture(window, named: "claude-chat", in: "claude-chat-audit")
            session.draft = "thinking first queued turn"
            runtime.chat.submit(session)
            session.draft = "second queued turn"
            runtime.chat.queue(session)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "queue=\(session.queuedMessages.count) busy=\(session.busy) paused=\(session.queuePaused ?? "none") failure=\(session.submissionFailure ?? "none") \(screen())") {
                !session.busy && session.queuedMessages.isEmpty && session.turns.flatMap(\.items).contains {
                    $0.kind == .assistant && $0.text == "Local Claude fixture reply: second queued turn"
                }
            }
            let originalID = try XCTUnwrap(session.sessionID)
            session.draft = "/clear"
            runtime.chat.submit(session)
            try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "clear id=\(session.sessionID ?? "nil") \(screen())") {
                session.active && session.sessionID != originalID && !session.loadingHistory
            }
            XCTAssertTrue(session.turns.flatMap(\.items).isEmpty)
            runtime.chat.chooseChat(true, session: session)
            session.draft = "new conversation"
            runtime.chat.submit(session)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: screen()) {
                !session.busy && session.turns.flatMap(\.items).contains { $0.kind == .assistant && $0.text == "Local Claude fixture reply: new conversation" }
            }
            // Claude answers each slash command with a turn, output, or a menu.
            func userTexts() -> [String] { session.turns.flatMap(\.items).filter { $0.kind == .user }.map(\.text) }
            func command(_ text: String, until done: () -> Bool) async throws {
                session.draft = text
                runtime.chat.submit(session)
                XCTAssertTrue(session.awaitingPromptAck, text)
                try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "\(text) attention=\(session.terminalAttention ?? "none") result=\(session.commandResult?.text ?? "none")\n\(screen())") {
                    !session.awaitingPromptAck && session.observedCommand == nil && done()
                }
            }
            try await command("/init") {
                !session.busy && session.turns.flatMap(\.items).contains { $0.kind == .assistant && $0.text.hasPrefix("Local Claude fixture reply: Please analyze this codebase") }
            }
            XCTAssertTrue(session.showChat); XCTAssertNil(session.terminalAttention); XCTAssertNil(session.commandResult)
            XCTAssertEqual(userTexts(), ["new conversation", "/init"])
            try await command("/mcp") { session.commandResult?.title == "/mcp" }
            XCTAssertTrue(session.commandResult?.text.hasPrefix("No MCP servers configured") == true)
            XCTAssertTrue(session.showChat); XCTAssertNil(session.terminalAttention)
            // Compaction waits on the model; its command and summary are not prompts.
            try await command("/compact") { session.commandResult?.title == "/compact" }
            XCTAssertTrue(session.commandResult?.text.hasPrefix("Compacted") == true)
            XCTAssertTrue(session.turns.flatMap(\.items).contains { $0.kind == .notice && $0.text == "Conversation compacted" })
            XCTAssertEqual(userTexts(), ["new conversation", "/init"])
            try await command("/help") { session.terminalAttention != nil }
            XCTAssertTrue(screen().contains("Esc to cancel"))
            TerminalTestSupport.key(53, "\u{1b}", terminal)
            try await TestSupport.eventually(diagnostic: screen()) { ClaudeModelMenu.isEmptyComposer(screen()) }
            runtime.chat.chooseChat(true, session: session)
            session.draft = "/resume " + originalID
            runtime.chat.submit(session)
            try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "resume id=\(session.sessionID ?? "nil") \(screen())") {
                session.sessionID == originalID && !session.loadingHistory && session.turns.flatMap(\.items).contains {
                    $0.kind == .assistant && $0.text == "Local Claude fixture reply: second queued turn"
                }
            }
            XCTAssertEqual(session.turns.flatMap(\.items).filter { $0.kind == .user }.count, 4)
            // A bare /resume opens Claude's own session picker: Chat switches to Terminal, which takes the keys.
            try await TestSupport.eventually(diagnostic: "The test window must be key before /resume") {
                if !window.isKeyWindow { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
                return window.isKeyWindow
            }
            session.draft = "/resume"
            runtime.chat.sendFromComposer(session)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Resume: \(session.submissionFailure ?? "pending")\n\(screen())") {
                !session.showChat && session.submissionID == nil
            }
            XCTAssertTrue(session.manualViewChoice)
            XCTAssertEqual(session.draft, "")
            XCTAssertNil(session.command); XCTAssertNil(session.observedCommand); XCTAssertNil(session.commandResult)
            XCTAssertFalse(session.awaitingPromptAck); XCTAssertNil(session.submissionFailure); XCTAssertNil(session.terminalAttention)
            // The picker lists the other conversations: the one /clear started is selected.
            try await TestSupport.eventually(diagnostic: screen()) {
                let lines = screen().components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                guard let title = lines.lastIndex(where: { $0.lowercased() == "resume session" }) else { return false }
                return lines[title...].contains { $0.hasPrefix("❯ ") } && window.firstResponder === terminal
            }
            TerminalTestSupport.key(36, "\r", terminal)
            try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "Picked \(session.sessionID ?? "nil") \(screen())") {
                session.sessionID != originalID && session.sessionID != nil && !session.loadingHistory && session.turns.flatMap(\.items).contains {
                    $0.kind == .assistant && $0.text == "Local Claude fixture reply: new conversation"
                }
            }
            XCTAssertFalse(session.showChat, "Chat follows the resumed conversation without leaving Terminal")
            let resumedID = try XCTUnwrap(session.sessionID)
            // As the user's typing does, sending follows the composer's focus (and the terminal's focus-out report).
            runtime.chat.chooseChat(true, session: session)
            try await TestSupport.eventually { window.firstResponder is ChatComposer.ComposerTextView }
            for source in ["/terminal\nλ😀", "!printf LITERAL_PREFIX_SAMPLE\n```\n~~~"] {
                session.draft = source
                // What Claude receives for a command-looking message: a code fence longer than any inside it.
                let delivered = AgentInput.fenced(source)
                runtime.chat.sendFromComposer(session)
                XCTAssertTrue(session.showChat)
                try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Literal delivery: \(session.queuePaused ?? session.submissionFailure ?? "pending")\n\(screen())") {
                    !session.busy && session.queuedMessages.isEmpty && session.turns.flatMap(\.items).contains {
                        $0.kind == .assistant && $0.text == "Local Claude fixture reply: " + delivered
                    }
                }
                XCTAssertEqual(session.sessionID, resumedID)
                XCTAssertTrue(session.turns.flatMap(\.items).contains { $0.kind == .user && $0.text == delivered })
                XCTAssertNil(session.optimisticPrompt)
                XCTAssertNil(session.queuePaused)
            }
            try await exitToShell()
            await finish()
            passed = testRun?.failureCount == 0
        } catch { await finish(); throw error }
    }

}
