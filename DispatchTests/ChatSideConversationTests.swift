import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class ChatSideConversationTests: XCTestCase {

    func testBlockingQuestionsPreserveChoiceAndCustomAnswers() throws {
        let chat = ChatCoordinator(enabled: true)
        defer { chat.stop() }
        let session = chat.session(for: UUID())
        session.sessionID = "parent"
        session.helper = HelperChat(terminal: 0)
        let questions = ["approach", "detail"].map { id in
            HelperChat.Question(id: id, header: id, text: id, secret: false,
                options: [.init(id: "small", label: "Small", detail: nil), .init(id: "broad", label: "Broad", detail: nil)],
                multiple: false, custom: true, blocks: nil)
        }
        chat.receiveHelper(.interaction(.init(id: "question", key: nil, approval: false,
            blocking: true, questions: questions, turn: nil, record: nil)), session: session)
        XCTAssertTrue(session.approvals.isEmpty)
        let form = try XCTUnwrap(session.questions.first)
        XCTAssertEqual(form.questions.map(\.id), ["approach", "detail"])
        form.select("Small")
        form.index = 1
        form.type("Main custom answer λ")
        XCTAssertEqual(form.answers, ["approach": .options([0]), "detail": .text("Main custom answer λ")])
    }

    func testPermissionDisplaysCompleteOperationAndRejectsMissingDetails() throws {
        let side = ChatSideConversation(mode: .side, parentID: "parent", agentID: "fixture", model: "fixture")
        let operations = [
            ("command", "Allow command?", #"{"command":"rm -rf /tmp/dispatch-target","cwd":"/tmp","reason":"cleanup"}"#),
            ("files", "Allow files?", #"{"changes":[{"path":"/tmp/dispatch-target","diff":"@@ -1 +1 @@\n-old\n+new"}]}"#),
            ("bash", "Allow Bash?", #"{"input":{"command":"touch /tmp/dispatch-claude-target"}}"#)
        ]
        for (id, title, operation) in operations {
            let question = HelperChat.Question(id: "decision", header: title, text: operation, secret: false,
                options: [.init(id: "allow", label: "Allow", detail: nil), .init(id: "deny", label: "Deny", detail: nil)],
                multiple: false, custom: false, blocks: [.init(kind: "code", language: "json", text: operation, path: nil)])
            side.receive(.interaction(.init(id: id, key: nil, approval: true, blocking: true, questions: [question], turn: nil, record: nil)))
            XCTAssertEqual(side.permission, .init(title: title, operation: operation, language: "json"))
            side.receive(.interaction(.init(id: id, key: nil, approval: true, blocking: true, questions: [], turn: nil, record: nil)))
            XCTAssertNil(side.permission)
        }
        let incomplete = HelperChat.Question(id: "decision", header: "Bash", text: "", secret: false,
            options: [], multiple: false, custom: false, blocks: nil)
        side.receive(.interaction(.init(id: "missing", key: nil, approval: true, blocking: true, questions: [incomplete], turn: nil, record: nil)))
        XCTAssertNil(side.permission)
        side.close()
    }

    func testLateRepliesCannotReopenClosedSheetOrEnterParent() {
        let chat = ChatCoordinator(enabled: true)
        defer { chat.stop() }
        let parent = chat.session(for: UUID())
        let side = ChatSideConversation(mode: .btw, parentID: "parent", agentID: "fixture", model: "fixture")
        parent.sideConversation = side
        func reply(_ id: String, _ text: String) -> HelperChat.Record {
            .init(id: id, turn: "side", kind: "assistant", text: text, title: "", output: "", blocks: [],
                  completed: true, exit_code: nil, patch: nil, time_ms: nil, documents: [], tool: nil, inline_reasoning: false)
        }
        side.receive(.records([reply("reply", "Side answer")]))
        XCTAssertEqual(side.messages.map(\.text), ["Side answer"])
        side.close()
        side.receive(.records([reply("late", "Late answer")]))
        side.receive(.state(.init(busy: true, activity: nil, model: nil, model_label: nil, effort: nil,
            usage: nil, goal: nil, draft: nil, attention: nil, title: nil, compacting: false, service_tier: nil)))
        XCTAssertTrue(side.messages.isEmpty); XCTAssertFalse(side.ready); XCTAssertFalse(side.busy)
        XCTAssertTrue(parent.turns.isEmpty)
    }

    func testEscapeClosesOnlyTheActiveSideSheetWithAndWithoutComposerFocus() async throws {
        for ready in [false, true] {
            for enabled in [false, true] {
                let side = ChatSideConversation(mode: .side, parentID: "parent", agentID: "codex", model: "model")
                side.ready = ready
                var closes = 0
                let host = NSHostingView(rootView: ChatSideSheet(side: side, close: { closes += 1 },
                    maximumHeight: 300, shortcutsEnabled: enabled))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                defer { window.contentView = nil; window.close() }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                let escape = TerminalTestSupport.keyEvent(53, "\u{1b}", in: window)
                let handled = host.performKeyEquivalent(with: escape)
                XCTAssertEqual(handled, enabled, "Escape binding must follow the active pane")
                XCTAssertEqual(closes, enabled ? 1 : 0, "Escape must close exactly one side sheet")
            }
        }
    }

    func testModesHaveSeparatePermissionBoundaries() throws {
        XCTAssertEqual(ChatSideMode.parse("/btw what happened?")?.mode, .btw)
        XCTAssertEqual(ChatSideMode.parse("/side change it")?.mode, .side)
        XCTAssertNil(ChatSideMode.parse("/sideways question"))
    }

    func testRealCodexForkKeepsSideReplyOutOfMainThread() async throws {
        let fixture = try CodexEndpointFixture(prefix: "dispatch-side-", delay: 0.01, hooks: false,
            state: URL(fileURLWithPath: "/tmp/dispatch-q-" + UUID().uuidString.prefix(8)))
        var passed = false
        defer { fixture.stop(removeState: passed) }
        try await fixture.start(timeout: .seconds(15))
        let configURL = fixture.state.appendingPathComponent("codex-home/config.toml")
        let config = try String(contentsOf: configURL, encoding: .utf8)
        try config.replacingOccurrences(of: "[features]\n", with: "[features]\ndefault_mode_request_user_input = true\n")
            .write(to: configURL, atomically: true, encoding: .utf8)
        let socket = fixture.state.appendingPathComponent("codex.sock")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [CodexTestSupport.root.appendingPathComponent("scripts/codex_fixture.py").path,
            "app-server", "--state", fixture.state.path, "--codex", fixture.binary, "--remote", "unix://" + socket.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        try await TestSupport.eventually(timeout: .seconds(10)) { FileManager.default.fileExists(atPath: socket.path) }
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(autoClose: true, liquidGlass: false)
        defer { app.close() }
        try await app.attach(); try await app.ready()
        let id = try XCTUnwrap(app.workspace.activeSurfaceID)
        let terminal = try XCTUnwrap(runtime.views[id])
        let session = runtime.chat.session(for: id)
        TerminalTestSupport.send(CodexTestSupport.command(state: fixture.state, binary: fixture.binary) + " --remote " + HerdrLaunch.quote("unix://" + socket.path), to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            session.active && terminal.agentMenuScreen.contains("dispatch-fixture default")
        }
        // Typed in Codex itself, before Chat is involved.
        terminal.surface?.text("main conversation seed"); TerminalTestSupport.key(36, "\r", terminal)
        try await TestSupport.eventually(timeout: .seconds(15)) { terminal.agentMenuScreen.contains("Local fixture reply: main conversation seed") }
        runtime.chat.chooseChat(true, session: session)
        session.draft = "/status"; runtime.chat.sendFromComposer(session)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Codex status: session=\(session.sessionID ?? "none") command=\(session.command.map { String(describing: $0) } ?? "none") helper=\(session.helper != nil) status=\(session.status ?? "none")\n\(terminal.agentMenuScreen)") {
            session.sessionID != nil && session.command == nil && session.helper != nil
        }
        try await TestSupport.eventually(timeout: .seconds(15)) {
            !session.busy && session.turns.flatMap(\.items).contains { $0.text.contains("Local fixture reply: main conversation seed") }
        }
        let parent = try XCTUnwrap(session.sessionID)
        for mode in [ChatSideMode.btw, .side] {
            session.draft = "/\(mode.rawValue) side-only question"
            runtime.chat.sendFromComposer(session)
            let side = try XCTUnwrap(session.sideConversation)
            try await TestSupport.eventually(timeout: .seconds(30), diagnostic: side.failure ?? "Waiting for side fork") {
                side.failure != nil || (!side.busy && side.messages.contains { !$0.user })
            }
            XCTAssertNil(side.failure)
            XCTAssertTrue(side.messages.contains { !$0.user && $0.text.contains("side-only question") })
            if mode == .btw {
                let body = try XCTUnwrap(CodexTestSupport.conversationRequests(in: fixture.state).last?["body"] as? [String: Any])
                func names(_ value: Any) -> [String] {
                    if let values = value as? [Any] { return values.flatMap(names) }
                    if let object = value as? [String: Any] {
                        return ((object["name"] as? String).map { [$0] } ?? []) + object.values.flatMap(names)
                    }
                    return []
                }
                let tools = names(body["tools"] ?? [])
                let artifact = CodexTestSupport.root.appendingPathComponent("build/btw-readonly-tools.json")
                try JSONSerialization.data(withJSONObject: body["tools"] ?? [], options: [.prettyPrinted, .sortedKeys]).write(to: artifact)
                for forbidden in ["exec_command", "write_stdin", "shell", "shell_command", "apply_patch", "spawn_agent"] {
                    XCTAssertFalse(tools.contains(forbidden), "Read-only side exposed \(forbidden)")
                }
            }
            XCTAssertEqual(session.sessionID, parent)
            XCTAssertFalse(session.turns.flatMap(\.items).contains { $0.text.contains("side-only question") })
            try await Task.sleep(for: .milliseconds(400))
            let capture = try await PresentationTestSupport.capture(app.window, named: "side-\(mode.rawValue)", in: "btw-queue-validation")
            XCTAssertTrue(try capture.text().contains("back to main"))
            side.draft = "DISPATCH_SIDE_QUESTION " + mode.rawValue + "\nPlease clarify."
            let sideEditor = try XCTUnwrap(PresentationTestSupport.views(of: ChatSideComposer.SideTextView.self,
                in: try XCTUnwrap(app.window.contentView)).first)
            try await TestSupport.eventually { sideEditor.string == side.draft }
            app.window.makeFirstResponder(sideEditor)
            XCTAssertTrue(sideEditor.performKeyEquivalent(with: TerminalTestSupport.keyEvent(36, "\n", in: app.window, modifiers: .control)))
            XCTAssertTrue(side.draft.isEmpty)
            XCTAssertFalse(side.draftMultiline)
            try await TestSupport.eventually(timeout: .seconds(15)) {
                !side.questions.isEmpty || side.failure != nil || !side.busy
            }
            XCTAssertNil(side.failure)
            let question = try XCTUnwrap(side.questions.first)
            XCTAssertEqual(question.questions.count, 2)
            question.select("Small change (Recommended)")
            question.index = 1
            XCTAssertTrue(question.question.allowsCustom)
            question.type("Custom side answer λ")
            side.draft = "preserved side draft"
            try await Task.sleep(for: .milliseconds(300))
            let questionCapture = try await PresentationTestSupport.capture(app.window, named: "question-\(mode.rawValue)", in: "btw-queue-validation")
            XCTAssertTrue(try questionCapture.text().contains("Codex has a question"))
            side.answerQuestion(question)
            side.answerQuestion(question) // Repeated clicks must be harmless.
            try await TestSupport.eventually(timeout: .seconds(15)) { !side.busy && side.questions.isEmpty }
            XCTAssertEqual(side.draft, "preserved side draft")
            XCTAssertEqual(side.messages.filter { $0.user && $0.text.contains("Custom side answer λ") }.count, 1)
            let answered = try XCTUnwrap(CodexTestSupport.conversationRequests(in: fixture.state).last?["body"] as? [String: Any])
            let input = String(decoding: try JSONSerialization.data(withJSONObject: answered["input"] ?? []), as: UTF8.self)
            XCTAssertTrue(input.contains("Custom side answer λ"))
            XCTAssertFalse(session.turns.flatMap(\.items).contains { $0.text.contains("DISPATCH_SIDE_QUESTION") || $0.text.contains("Custom side answer") })

            side.draft = "DISPATCH_SIDE_QUESTION skip " + mode.rawValue
            side.send()
            try await TestSupport.eventually(timeout: .seconds(15)) { !side.questions.isEmpty || !side.busy }
            let skipped = try XCTUnwrap(side.questions.first)
            side.answerQuestion(skipped, skip: true)
            try await TestSupport.eventually(timeout: .seconds(15)) { !side.busy && side.questions.isEmpty }
            XCTAssertTrue(side.messages.contains { $0.user && $0.text.contains("Skipped") })

            runtime.chat.closeSideConversation(session)
            XCTAssertTrue(side.questions.isEmpty)
            XCTAssertNil(session.sideConversation)
            XCTAssertTrue(side.messages.isEmpty)
        }
        try await TestSupport.eventually(timeout: .seconds(15)) { session.helper != nil && !session.busy }
        session.draft = "DISPATCH_SIDE_QUESTION main"
        runtime.chat.sendFromComposer(session)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Main question: session=\(session.sessionID ?? "none") helper=\(session.helper != nil) questions=\(session.questions.count) approvals=\(session.approvals.count) busy=\(session.busy) failure=\(session.submissionFailure ?? "none")\n\(terminal.agentMenuScreen)") { !session.questions.isEmpty || session.submissionFailure != nil }
        let mainQuestion = try XCTUnwrap(session.questions.first)
        mainQuestion.select("Small change (Recommended)")
        mainQuestion.index = 1; mainQuestion.type("Main custom answer λ")
        session.draft = "unfinished main draft"
        try await Task.sleep(for: .milliseconds(450))
        let capture = try await PresentationTestSupport.capture(app.window, named: "main-question", in: "btw-queue-validation")
        XCTAssertTrue(try capture.text().contains("Codex has a question"))
        NSApp.sendEvent(TerminalTestSupport.keyEvent(36, "\r", in: app.window, modifiers: .command))
        try await TestSupport.eventually(timeout: .seconds(3)) { mainQuestion.submitted }
        try await TestSupport.eventually(timeout: .seconds(15)) { session.questions.isEmpty && !session.busy }
        XCTAssertEqual(session.draft, "unfinished main draft")
        try await TestSupport.eventually(timeout: .seconds(15)) {
            session.turns.flatMap(\.items).contains { $0.output.contains("Main custom answer λ") }
        }
        session.draft = "DISPATCH_PLAN_QUESTION answer in Terminal"
        runtime.chat.sendFromComposer(session)
        try await TestSupport.eventually(timeout: .seconds(15)) { session.questions.contains { $0.questions.count == 1 } }
        let terminalQuestion = try XCTUnwrap(session.questions.first)
        // Answered in Codex's own menu: option 2.
        runtime.chat.chooseChat(false, session: session)
        TerminalTestSupport.key(19, "2", terminal)
        try await TestSupport.eventually(timeout: .seconds(15)) { session.questions.isEmpty && !session.busy }
        runtime.chat.answerQuestion(terminalQuestion, skip: false, session: session)
        XCTAssertFalse(terminalQuestion.submitted)
        passed = true
    }

    func testReviewAndCoordinatorStopCloseSideOwnership() {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = chat.session(for: UUID())
        session.active = true; session.sessionID = "parent"
        chat.apply([.init(key: "review-start", turnID: "review", date: Date(), action: .started, reviewing: true)],
                   to: session, earlier: false, historical: false)
        XCTAssertTrue(session.reviewing)
        XCTAssertFalse(chat.openSideConversation(.btw, question: "question", session: session))
        chat.apply([.init(key: "review-end", turnID: "review", date: Date(), action: .ended, reviewing: false)],
                   to: session, earlier: false, historical: false)
        XCTAssertFalse(session.reviewing)
        let side = ChatSideConversation(mode: .btw, parentID: "parent", agentID: "codex", model: "fixture")
        side.ready = true; session.sideConversation = side
        chat.stop()
        XCTAssertNil(session.sideConversation)
        XCTAssertFalse(side.ready)
    }
}
