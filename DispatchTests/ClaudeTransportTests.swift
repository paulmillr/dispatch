import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class ClaudeTransportTests: XCTestCase {
    func testLocalStopAndRecovery() async throws { try await walkthrough("local") }
    func testTmuxChatStopAndPicker() async throws { try await walkthrough("tmux") }
    func testHerdrChatStopAndPicker() async throws { try await walkthrough("herdr") }

    private func walkthrough(_ backend: String) async throws {
        let fm = FileManager.default
        let claude = try XCTUnwrap([TestSupport.tool("claude")].first { fm.isExecutableFile(atPath: $0) })
        // herdr's Unix socket must fit sockaddr_un even on macOS's long TMPDIR.
        let state = URL(fileURLWithPath: "/tmp/dispatch-claude-transport-" + UUID().uuidString)
        let script = CodexTestSupport.root.appendingPathComponent("scripts/claude_fixture.py").path
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [script, "serve", "--state", state.path, "--delay", "0.025"]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer {
            if server.isRunning { server.terminate(); server.waitUntilExit() }
            print("Claude \(backend) fixture: " + state.path)
        }
        try await TestSupport.eventually { fm.fileExists(atPath: state.appendingPathComponent("endpoint.json").path) }
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(); defer { app.close() }
        let socket = state.appendingPathComponent("herdr.sock").path
        defer { if backend == "herdr" { _ = try? HerdrSocket(path: socket).request("server.stop") } }
        if backend == "tmux" {
            try await app.attach(); try await app.ready()
        } else if backend == "herdr" {
            let id = try XCTUnwrap(app.workspace.activeSurfaceID)
            try await app.wait { runtime.views[id]?.surface != nil }
            let terminal = try XCTUnwrap(runtime.views[id])
            defer { if app.workspace.current?.shows("herdr") != true { print("herdr launch: " + terminal.agentMenuScreen) } }
            TerminalTestSupport.send("export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(state.path)
                + "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr", to: terminal)
            try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.current?.shows("herdr") == true }
        }
        let id = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { runtime.views[id]?.surface != nil }
        let terminal = try XCTUnwrap(runtime.views[id]), session = runtime.chat.session(for: id)
        defer { print("Claude \(backend) final: \(session.status ?? "none") / \(session.submissionFailure ?? "none") / \(session.modelPicker?.error ?? "none")\n\(terminal.agentMenuScreen)") }
        session.manualViewChoice = true
        TerminalTestSupport.send(["python3", script, "launch", "--state", state.path, "--claude", claude, "--integration"].map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            session.active && session.agentID == "claude" && !session.loadingHistory && !session.busy
                && terminal.agentMenuScreen.contains("for shortcuts")
        }
        runtime.chat.chooseChat(true, session: session)
        let process = try XCTUnwrap(session.process), conversation = try XCTUnwrap(session.sessionID)
        let helper = try XCTUnwrap(session.helper)
        // Input addressed to another conversation is refused on every backend (the helper checks the binding).
        let foreign = await helper.refuses("foreign conversation", conversation: UUID().uuidString)
        XCTAssertTrue(foreign, "A foreign conversation must not authorize \(backend) input")
        terminal.insertText("unsent native input", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await TestSupport.eventually { terminal.agentMenuScreen.contains("unsent native input") }
        session.draft = "preserve Chat draft"; runtime.chat.submit(session)
        // The helper refuses input while Claude's composer holds unsent text; the refusal is its reply.
        try await TestSupport.eventually(timeout: .seconds(10)) { session.submissionFailure != nil && session.submissionID == nil }
        XCTAssertEqual(session.draft, "preserve Chat draft")
        XCTAssertNil(session.optimisticPrompt, "Chat must not append to existing native input")
        // The user clears Claude's line (the old clearLine key: C-u) in the terminal.
        TerminalTestSupport.key(32, "u", terminal, modifiers: .control)
        try await TestSupport.eventually { ClaudeModelMenu.isEmptyComposer(terminal.agentMenuScreen) }
        func reply(_ text: String) -> Bool {
            !session.busy && session.turns.flatMap(\.items).contains { $0.kind == .assistant && $0.text.contains(text) }
        }
        session.draft = "thinking hello via " + backend; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(15)) { reply("Local Claude fixture reply: thinking hello via " + backend) }
        XCTAssertTrue(session.turns.flatMap(\.items).contains { $0.kind == .reasoning })
        if backend == "local" {
            for mode in [ChatSideMode.btw, .side] {
                session.draft = "/\(mode.rawValue) multiple questions in Claude side"
                runtime.chat.sendFromComposer(session)
                let side = try XCTUnwrap(session.sideConversation)
                try await TestSupport.eventually(timeout: .seconds(20)) { !side.questions.isEmpty || side.failure != nil || !side.busy }
                let question = try XCTUnwrap(side.questions.first)
                question.select("Detailed"); question.index += 1
                question.select("Tests"); question.select("Documentation"); question.index += 1
                question.type("Custom Claude answer λ")
                side.draft = "preserve my follow-up"
                side.answerQuestion(question)
                try await TestSupport.eventually(timeout: .seconds(20)) { !side.busy }
                XCTAssertNil(side.failure)
                XCTAssertTrue(side.questions.isEmpty)
                XCTAssertEqual(side.draft, "preserve my follow-up")
                XCTAssertTrue(side.messages.contains { $0.user && $0.text.contains("Tests, Documentation") && $0.text.contains("Custom Claude answer λ") })
                XCTAssertTrue(side.messages.contains { !$0.user && $0.text.contains("multiple questions in Claude side") })
                side.draft = "question skip in side"
                side.send()
                try await TestSupport.eventually(timeout: .seconds(15)) { !side.questions.isEmpty || !side.busy }
                let skipped = try XCTUnwrap(side.questions.first)
                side.answerQuestion(skipped, skip: true)
                try await TestSupport.eventually(timeout: .seconds(15)) { !side.busy }
                XCTAssertTrue(side.questions.isEmpty)
                XCTAssertTrue(side.messages.contains { $0.user && $0.text.contains("Skipped") })
                XCTAssertEqual(session.sessionID, conversation)
                XCTAssertFalse(session.turns.flatMap(\.items).contains { $0.text.contains("multiple questions in Claude side") })
                let requests = try String(contentsOf: state.appendingPathComponent("requests.jsonl"), encoding: .utf8)
                func strings(_ value: Any) -> [String] {
                    if let text = value as? String { return text.components(separatedBy: .newlines) }
                    if let array = value as? [Any] { return array.flatMap(strings) }
                    if let object = value as? [String: Any] { return object.values.flatMap(strings) }
                    return []
                }
                let directories = try requests.split(separator: "\n").flatMap { line -> [String] in
                    let request = try JSONSerialization.jsonObject(with: Data(line.utf8))
                    return strings(request).filter { $0.hasPrefix(" - Primary working directory: ") }
                }
                let paths = directories.map { URL(fileURLWithPath: String($0.dropFirst(" - Primary working directory: ".count))).resolvingSymlinksInPath().path }
                XCTAssertEqual(Set(paths), [state.appendingPathComponent("work").resolvingSymlinksInPath().path],
                               "Side agents must keep the parent's cwd, not scan the terminal's initial directory")
                runtime.chat.closeSideConversation(session)
            }
        }
        let messages = ["queued one via " + backend, "queued two\nwith newline via " + backend]
        for message in messages { session.draft = message; runtime.chat.queue(session) }
        session.draft = "keep draft while queue drains"
        try await TestSupport.eventually(timeout: .seconds(15)) { reply("Local Claude fixture reply: " + messages[1]) && session.queuedMessages.isEmpty }
        XCTAssertEqual(Array(session.turns.flatMap(\.items).filter { $0.kind == .user }.map(\.text).suffix(2)), messages)
        XCTAssertEqual(session.draft, "keep draft while queue drains"); XCTAssertNil(session.queuePaused)
        session.draft = "tool check via " + backend; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(15)) { reply("Tool result received: completed.") }
        XCTAssertTrue(session.turns.flatMap(\.items).contains { $0.kind == .tool && $0.output.contains("DISPATCH_CLAUDE_TOOL_OK") })

        var selectedModel = false
        if backend != "local" {
            // Selection travels through tmux or herdr menu keys; it must apply to
            // this conversation only and leave Claude's saved settings untouched.
            let settingsPath = state.appendingPathComponent("claude-home/settings.json")
            let settings = try? Data(contentsOf: settingsPath)
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
            try await TestSupport.eventually(timeout: .seconds(15)) { session.modelPicker == nil && !session.busy }
            selectedModel = true
            XCTAssertEqual(session.model, ClaudeModelMenu.modelID(detail: model.detail) ?? model.name)
            XCTAssertEqual(session.effort, "low")
            XCTAssertEqual(try? Data(contentsOf: settingsPath), settings)
            // Direct submission does not retry while Claude settles the confirmation.
            try await TestSupport.eventually(timeout: .seconds(15)) {
                !session.awaitingPromptAck && runtime.chat.canPickModel(session) && ClaudeModelMenu.isEmptyComposer(terminal.agentMenuScreen)
            }
        }

        session.draft = "thinking long response to stop via " + backend; runtime.chat.submit(session)
        // Whether Claude's footer allows a stop is the claude harness's (moved: testInterruptRequiresWorkingNativeFooter).
        var stopStates = Set<String>()
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic:
            "Waiting for Claude's streamed response before Stop via \(backend)\n\(terminal.agentMenuScreen)") {
            let state = "busy=\(session.busy) ack=\(session.awaitingPromptAck) history=\(session.loadingHistory) canStop=\(runtime.chat.canInterrupt(session))"
            if stopStates.insert(state).inserted { print("Claude \(backend) stop readiness \(state)\n" + terminal.agentMenuScreen.components(separatedBy: .newlines).suffix(9).joined(separator: "\n")) }
            let screen = terminal.agentMenuScreen
            // Busy includes pre-query cancellation, which restores the prompt without
            // an interrupted record. Exercise Stop after this turn's stream has begun.
            return runtime.chat.canInterrupt(session) && session.nativeActivity == "busy" && screen.utf8.count <= 65_536
                && screen.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    .contains("Local Claude fixture reply: thinking long response to stop via " + backend)
                && screen.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .suffix(4).contains { $0.lowercased().contains("esc to interrupt") }
        }
        session.draft = "do not automatically send after stop"; runtime.chat.queue(session)
        session.draft = "keep my draft λ"
        try await TestSupport.eventually { app.window.firstResponder is ChatComposer.ComposerTextView }
        let editor = try XCTUnwrap(app.window.firstResponder as? ChatComposer.ComposerTextView)
        editor.keyDown(with: TerminalTestSupport.keyEvent(53, "\u{1b}", in: app.window))
        XCTAssertNotNil(session.interruptionID)
        XCTAssertFalse(runtime.chat.interrupt(session), "Repeated Escape must not enqueue a second interrupt")
        try await TestSupport.eventually(timeout: .seconds(10)) {
            !session.busy && session.interruptionID == nil && session.seen.contains { $0.hasSuffix(":interrupted") }
        }
        XCTAssertFalse(session.turns.flatMap(\.items).contains { $0.text.contains("80. Local fixture paragraph") }, "Stop must truncate the response, not wait for all 80 paragraphs")
        XCTAssertTrue(process.alive); XCTAssertEqual(session.sessionID, conversation)
        XCTAssertEqual(session.draft, "keep my draft λ"); XCTAssertEqual(session.queuedMessages.count, 1)
        XCTAssertNotNil(session.queuePaused)
        XCTAssertFalse(runtime.chat.interrupt(session), "Idle Escape must not open rewind")
        runtime.chat.removeQueued(try XCTUnwrap(session.queuedMessages.first?.id), from: session)
        session.draft = "recovered after stop via " + backend; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(15)) { reply("Local Claude fixture reply: recovered after stop via " + backend) }
        XCTAssertEqual(session.sessionID, conversation)
        if selectedModel {
            let requests = try String(contentsOf: state.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n").map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }.filter { ($0["path"] as? String)?.split(separator: "?").first == "/v1/messages" }
            let body = try XCTUnwrap(requests.last?["body"] as? [String: Any])
            // The picker shows a display label at first; later transcript records
            // carry the provider's canonical ID, which deliveries must use.
            XCTAssertEqual(body["model"] as? String, session.model)
            XCTAssertNotEqual(body["model"] as? String, "dispatch-fixture", "Delivery must use the model chosen through \(backend)")
        }
        session.draft = "/exit"; runtime.chat.submit(session)
        try await TestSupport.eventually { !process.alive && !session.active }
        XCTAssertFalse(session.showChat, "An explicit exit returns to the shell")
        XCTAssertFalse(runtime.chat.interrupt(session), "Escape must not reach the shell after exit")
        let exited = await helper.refuses("must not reach shell", conversation: conversation)
        XCTAssertTrue(exited, "An exited agent must not authorize input")
        TerminalTestSupport.send("printf 'CLAUDE_TRANSPORT_%s\\n' READY", to: terminal)
        try await TestSupport.eventually { terminal.agentMenuScreen.contains("CLAUDE_TRANSPORT_READY") }
    }
}
