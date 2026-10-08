import AppKit
import SwiftUI
import Vision
import XCTest
@testable import DispatchApp

@MainActor
final class ClaudeQuestionTests: XCTestCase {
    /// The helper's questionnaire: one choice question, the first option with a preview.
    private func questions() -> ClaudeQuestions {
        ClaudeQuestions([.init(text: "Which example?", header: "Example", options: [
            .init(label: "Swift", description: "Native", preview: "let example = true"),
            .init(label: "Rust", description: "Helper", preview: nil)], multiple: false)])
    }
    func testAnswersPreserveQuestionsAndRejectInvalidOrStaleReplies() throws {
        // The hook reply shape and questionnaire validation are the claude harness's; the app accepts only
        // a complete, printable answer per question and never answers through a generic approval.
        let questions = questions()
        XCTAssertFalse(questions.accepts([:]))
        XCTAssertFalse(questions.accepts(["Which example?": " "]))
        XCTAssertFalse(questions.accepts(["Which example?": String(repeating: "a", count: 8193)]))
        XCTAssertFalse(questions.accepts(["foreign": "Swift"]))
        XCTAssertTrue(questions.accepts(["Which example?": "Python λ\nwith examples"]))
        let draft = ClaudeQuestionDraft(questions)
        draft.type("answer\u{0}hidden")
        XCTAssertTrue(draft.answers.isEmpty, "The form must not enable Send for an answer the agent cannot accept")
        var completed: [PendingApproval.Decision?] = []
        let approval = PendingApproval(key: "question", operation: "AskUserQuestion", questions: questions) { completed.append($0.decision) }
        approval.resolve(.allow)
        XCTAssertTrue(approval.pending, "A generic approval must not answer questions")
        approval.answer([:]); XCTAssertTrue(approval.pending)
        approval.answer(["Which example?": "Swift"])
        XCTAssertEqual(approval.decision, .allow); XCTAssertEqual(approval.answers, ["Which example?": "Swift"])
        XCTAssertEqual(completed, [.allow])
        let stale = PendingApproval(key: "stale", operation: "AskUserQuestion", questions: questions) { completed.append($0.decision) }
        stale.retire()
        stale.answer(["Which example?": "Swift"])
        XCTAssertEqual(stale.decision, .expired); XCTAssertNil(stale.answers)
        XCTAssertEqual(completed, [.allow], "An expired question sends nothing")
    }
    func testMalformedQuestionnairesDoNotBecomeAnswerableTools() {
        // Validation of the native questionnaire is the claude harness's (moved); what reaches the app
        // answers only its own questions.
        let questions = questions()
        XCTAssertFalse(questions.accepts(["Which example?": "Swift", "command": "arbitrary"]))
        XCTAssertFalse(questions.accepts(["Which example?": "a\u{0}b"]))
    }

    func testQuestionFormNativeEventDelivery() async throws {
        try DesktopTestSupport.requireUnlocked()
        let previousPointer = CGEvent(source: nil)?.location
        defer { if let previousPointer { CGWarpMouseCursorPosition(previousPointer) } }
        AppFont.register()
        let approval = PendingApproval(key: "native-form", operation: "AskUserQuestion", questions: questions()) { _ in }
        let draft = try XCTUnwrap(approval.questionDraft)
        let window = QuestionWindow(contentRect: NSRect(x: 100, y: 100, width: 680, height: 520),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ChatPermissionCard(approval: approval, openTerminal: {})
            .padding(24).background(Color.black))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.close(); window.contentView = nil }
        try await click("Swift", draft: draft, in: window)
        try await TestSupport.eventually { draft.answers["Which example?"] == "Swift" }
        try await click("Send answers", draft: draft, in: window)
        try await TestSupport.eventually { approval.decision == .allow }
        XCTAssertEqual(approval.answers, ["Which example?": "Swift"])
        _ = try await PresentationTestSupport.capture(window, named: "claude-question-native-form", in: "claude-chat-audit")
    }

    func testRealLocalQuestionsChoicesCustomTextSkipAndRevocation() async throws {
        let restore = TestSupport.preserveRuntime()
        defer { restore() }
        try DesktopTestSupport.requireUnlocked()
        let previousPointer = CGEvent(source: nil)?.location
        defer { if let previousPointer { CGWarpMouseCursorPosition(previousPointer) } }
        let fm = FileManager.default
        let claude = try XCTUnwrap([TestSupport.tool("claude")].first { fm.isExecutableFile(atPath: $0) })
        let state = fm.temporaryDirectory.appendingPathComponent("dispatch-claude-questions-" + UUID().uuidString)
        let script = CodexTestSupport.root.appendingPathComponent("scripts/claude_fixture.py").path
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [script, "serve", "--state", state.path, "--delay", "0"]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice; try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() }; print("Claude question fixture: " + state.path) }
        try await TestSupport.eventually { fm.fileExists(atPath: state.appendingPathComponent("endpoint.json").path) }
        let runtime = TerminalRuntime.shared, controller = AppDelegate(), previousChat = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        try await TestSupport.integrations(["claude"], enabled: true, chat: runtime.chat)
        let chat = runtime.chat
        defer { chat.setHelperIntegration("claude", enabled: false) }
        runtime.workspace = controller.workspace; runtime.start(preferences: Preferences())
        let workspace = controller.workspace; workspace.defaultDirectory = state.appendingPathComponent("work").path
        workspace.onCloseTabs = { runtime.close($0) }; workspace.newSpace()
        let window = QuestionWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 850), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.acceptsMouseMovedEvents = true
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentView = nil; runtime.stop(); runtime.chat = previousChat }
        do {
        let id = try XCTUnwrap(workspace.activeSurfaceID)
        try await TestSupport.eventually { runtime.views[id]?.surface != nil }
        let terminal = try XCTUnwrap(runtime.views[id]), session = runtime.chat.session(for: id)
        defer { print("Claude question state: \(session.status ?? "none") / \(session.submissionFailure ?? "none")\n\(terminal.agentMenuScreen)") }
        session.manualViewChoice = true
        // Claude reads the configuration the helper installed its integration into (the test home's).
        try TestSupport.trustClaudeWorkspace(state.appendingPathComponent("work"), config: Home.url.appendingPathComponent(".claude"))
        TerminalTestSupport.send(["python3", script, "launch", "--state", state.path, "--claude", claude, "--integration", "--hooks",
            "--config", Home.url.appendingPathComponent(".claude").path].map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            session.active && session.agentID == "claude" && !session.loadingHistory && !session.busy && terminal.agentMenuScreen.contains("for shortcuts")
        }
        runtime.chat.chooseChat(true, session: session)
        session.draft = "multiple questions please"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(15)) { session.approvals.contains { $0.pending && $0.questions != nil } }
        let question = try XCTUnwrap(session.approvals.last(where: \.pending))
        XCTAssertEqual(question.questions?.questions.count, 3)
        let draft = try XCTUnwrap(question.questionDraft)
        try await click("Detailed", draft: draft, in: window)
        try await TestSupport.eventually { draft.answers["How much detail should the reply include?"] == "Detailed" }
        try await click("Next", draft: draft, in: window)
        try await TestSupport.eventually { draft.index == 1 }
        try await click("Tests", draft: draft, in: window)
        try await TestSupport.eventually(diagnostic: "Question selections: \(draft.selected), index: \(draft.index)") {
            draft.selected["Which checks should be included?"]?.contains("Tests") == true
        }
        try await click("Documentation", draft: draft, in: window)
        try await TestSupport.eventually { question.questionDraft?.selected["Which checks should be included?"] == ["Tests", "Documentation"] }
        try await click("Back", draft: draft, in: window)
        try await TestSupport.eventually { draft.index == 0 }
        XCTAssertEqual(question.questionDraft?.answers["How much detail should the reply include?"], "Detailed")
        try await click("Next", draft: draft, in: window)
        try await TestSupport.eventually { draft.index == 1 }
        try await click("Next", draft: draft, in: window)
        try await TestSupport.eventually { draft.index == 2 }
        try await click("Or type your own answer", draft: draft, in: window)
        try await TestSupport.eventually { window.firstResponder is NSTextView }
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertText("Python λ with examples", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await click("Send answers", draft: draft, in: window)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            !session.busy && session.turns.flatMap(\.items).contains { $0.kind == .assistant && $0.text.contains("Python λ with examples") }
        }
        XCTAssertEqual(question.answers?["How much detail should the reply include?"], "Detailed")
        XCTAssertEqual(question.answers?["Which checks should be included?"], "Tests, Documentation")
        XCTAssertEqual(question.answers?["Which language should the example use?"], "Python λ with examples")
        XCTAssertEqual(question.decision, .allow)
        session.draft = "question skip"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(15)) { session.approvals.contains(where: \.pending) }
        let skipped = try XCTUnwrap(session.approvals.last(where: \.pending))
        try await click("Skip", draft: XCTUnwrap(skipped.questionDraft), in: window)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            !session.busy && session.turns.flatMap(\.items).contains { $0.kind == .assistant && $0.text.contains("denied or failed") }
        }
        XCTAssertEqual(skipped.decision, .deny)
        session.draft = "question revoke"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(15)) { session.approvals.contains(where: \.pending) }
        let revoked = try XCTUnwrap(session.approvals.last(where: \.pending))
        runtime.chat.setHelperIntegration("claude", enabled: false)
        revoked.answer(["How much detail should the reply include?": "Compact"])
        XCTAssertNil(revoked.answers); XCTAssertFalse(revoked.pending)
        try await TestSupport.eventually(timeout: .seconds(10)) {
            session.terminalAttention != nil && terminal.agentMenuScreen.contains("How much detail") && terminal.agentMenuScreen.contains("Compact")
        }
        } catch {
            _ = try? await PresentationTestSupport.capture(window, named: "claude-question-final", in: "claude-chat-audit")
            throw error
        }
        _ = try? await PresentationTestSupport.capture(window, named: "claude-question-final", in: "claude-chat-audit")
    }

    private func click(_ label: String, draft: ClaudeQuestionDraft, in window: NSWindow) async throws {
        let content = try XCTUnwrap(window.contentView)
        let index = draft.index, title = draft.question.text
        var chosen: NSPoint?, observed = "", locator = ""
        var previousBounds: CGRect?
        var lastSnapshot: PresentationTestSupport.Snapshot?
        defer {
            if chosen == nil, let lastSnapshot {
                try? PresentationTestSupport.save(lastSnapshot.bitmap, named: "claude-question-missing-\(index)-\(label)", in: "claude-chat-audit")
            }
        }
        try await TestSupport.eventually(interval: .milliseconds(100), diagnostic: "Question control unavailable: \(label); title: \(title); locator: \(locator); observed: \(observed)") {
            let snapshot = try await PresentationTestSupport.capture(content)
            lastSnapshot = snapshot
            observed = try snapshot.text()
            // Match the current rendered question before clicking. This also
            // waits for navigation to replace the previous SwiftUI form.
            guard observed.contains(title) else { return false }
            let observations = try snapshot.recognizedText()
            func bounds(_ text: String) throws -> [CGRect] {
                let exact = try observations.compactMap { observation -> CGRect? in
                    guard let candidate = observation.topCandidates(1).first,
                          let range = candidate.string.range(of: text),
                          let box = try candidate.boundingBox(for: range) else { return nil }
                    return box.boundingBox
                }
                if !exact.isEmpty { return exact }
                // Vision can split one placeholder into several observations.
                return observations.compactMap { anchor in
                    let row = observations.filter { abs($0.boundingBox.midY - anchor.boundingBox.midY) < anchor.boundingBox.height / 2 }
                        .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                    // A heading can share its row with the question count;
                    // match only the consecutive observations for this label.
                    for first in row.indices {
                        for last in first..<row.count {
                            let parts = row[first...last]
                            let label = parts.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                            if label == text { return parts.reduce(CGRect.null) { $0.union($1.boundingBox) } }
                        }
                    }
                    return nil
                }
            }
            let headings = try bounds("Claude Code has a question"), matches = try bounds(label)
            locator = "headings=\(headings), matches=\(matches), previous=\(String(describing: previousBounds))"
            guard let heading = headings.first,
                  let box = matches.first(where: { $0.midY < heading.midY && $0.minX >= heading.minX - 0.03 }) else {
                return false
            }
            defer { previousBounds = box }
            // OCR can shift a short word by a few pixels when neighboring
            // labels change. Require a settled control within four points.
            guard let previousBounds, abs(previousBounds.midX - box.midX) * content.bounds.width < 4,
                  abs(previousBounds.midY - box.midY) * content.bounds.height < 4 else { return false }
            try PresentationTestSupport.save(snapshot.bitmap, named: "claude-question-\(index)-\(label)", in: "claude-chat-audit")
            let point = NSPoint(x: box.midX * content.bounds.width,
                                y: (content.isFlipped ? 1 - box.midY : box.midY) * content.bounds.height)
            chosen = content.convert(point, to: nil)
            return true
        }
        // Queue the complete native event sequence at the recognized bounds.
        // SwiftUI's gesture recognizers need both events through the app loop.
        let point = try XCTUnwrap(chosen)
        window.makeKeyAndOrderFront(nil)
        let screen = window.convertPoint(toScreen: point), desktop = try XCTUnwrap(NSScreen.screens.first)
        let position = CGPoint(x: screen.x, y: desktop.frame.maxY - screen.y)
        XCTAssertEqual(CGWarpMouseCursorPosition(position), .success)
        let move = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: position, mouseButton: .left))
        move.postToPid(getpid())
        window.sendEvent(try PresentationTestSupport.mouseEvent(.mouseMoved, in: window, at: point))
        print("Claude question click: \(index) \(label) at \(point)")
        let down = try PresentationTestSupport.mouseEvent(.leftMouseDown, in: window, at: point)
        let up = try PresentationTestSupport.mouseEvent(.leftMouseUp, in: window, at: point)
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        // Each caller waits for the resulting selection, focus or hook reply.
        // Posting both events in order also lets nested AppKit tracking consume up.
    }

    private final class QuestionWindow: NSWindow {
        override func sendEvent(_ event: NSEvent) {
            if event.type == .leftMouseDown || event.type == .leftMouseUp {
                print("Claude question event: \(event.type.rawValue) at \(event.locationInWindow), key=\(isKeyWindow)")
            }
            super.sendEvent(event)
        }
    }
}
