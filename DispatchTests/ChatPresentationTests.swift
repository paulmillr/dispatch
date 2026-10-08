import XCTest
import AppKit
import SwiftUI
@testable import DispatchApp

@MainActor
final class ChatPresentationTests: XCTestCase {
    func testTmuxCompatibilityWarningKeepsComposerAvailable() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let coordinator = ChatCoordinator(enabled: false, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { coordinator.stop() }
        let session = coordinator.session(for: UUID())
        session.sessionID = "legacy-tmux"; session.active = true; session.showChat = true
        session.helper = HelperChat(terminal: 0); session.draft = "Preserved draft"
        coordinator.receiveHelper(.records([.init(id: "compatibility", turn: "connection", kind: "notice",
            text: "tmux 3.7 or newer is recommended. Chat uses compatibility mode and cannot verify paste readiness.", title: "", output: "", blocks: [],
            completed: true, exit_code: nil, patch: nil, time_ms: nil, documents: [], tool: nil,
            inline_reasoning: false)]), session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: true, floatingSwitch: false))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        let text = try await PresentationTestSupport.capture(window, named: "tmux-compatibility-warning", in: "chat-validation").text().lowercased()
        XCTAssertTrue(text.contains("tmux 3.7"), text)
        XCTAssertTrue(text.contains("compatibility mode"), text)
        XCTAssertTrue(text.contains("preserved draft"), text)
        XCTAssertNil(session.status, "The recommendation must not become a submission failure")
        session.resetConversation()
        XCTAssertTrue(session.turns.isEmpty, "A replacement connection must discover its own capability")
    }

    func testSplitComposerFocusPreservesEditorsDraftsAndReadingGeometry() async throws {
        let glass = LiquidGlassStore.shared.enabled
        defer { LiquidGlassStore.shared.enabled = glass }
        let restore = TestSupport.preserveRuntime()
        defer { restore() }
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let runtime = TerminalRuntime.shared, oldChat = runtime.chat
        let coordinator = ChatCoordinator(enabled: false, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        runtime.chat = coordinator
        let controller = AppDelegate(), workspace = controller.workspace
        // This case checks the classic inactive Reply line and its click target.
        controller.settings.values = Preferences.flat
        runtime.workspace = workspace
        runtime.start(preferences: controller.settings.values)
        defer { runtime.stop(); runtime.chat = oldChat }
        coordinator.stop() // Keep process discovery from expiring the fixture's synthetic agents.
        workspace.onCloseTabs = { runtime.close($0) }
        workspace.newLocalSpace()
        for _ in 0..<3 { workspace.newTab() }
        _ = try XCTUnwrap(workspace.applyLayout(.grid) ? true : nil, "Four tabs must form the grid")
        let panes = try XCTUnwrap(workspace.current).numberedPaneIDs
        let tabs = try panes.map { id in try XCTUnwrap(workspace.current?.panes.first { $0.id == id }?.selected) }
        let sessions = tabs.enumerated().map { index, id in
            let session = coordinator.session(for: id)
            session.sessionID = "split-\(index)"; session.showChat = true; session.active = true
            session.model = "gpt-6-astra"; session.effort = "high"
            session.turns = (0..<12).map { turn in
                ChatTurn(id: "turn-\(turn)", items: [.init(id: "answer-\(turn)", kind: .assistant,
                    text: "Pane \(index + 1), answer \(turn).\n\nTranscript remains steady during focus changes.")])
            }
            return session
        }
        sessions[3].busy = true; sessions[3].submittedThinkingAt = .now.addingTimeInterval(-41)
        sessions[3].draft = "Preserve working draft"
        workspace.selectPane(at: 3)
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 900),
                                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentView = nil }
        try await TestSupport.eventually { (window.firstResponder as? ChatComposer.ComposerTextView)?.session === sessions[3] }
        try await Task.sleep(for: .milliseconds(500))
        let root = try XCTUnwrap(window.contentView)
        let editors = try sessions.map { session in
            try XCTUnwrap(PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: root).first { $0.session === session })
        }
        func frames() throws -> [CGRect] {
            try editors.map { editor in
                let scroll = try XCTUnwrap(editor.enclosingScrollView)
                return scroll.convert(scroll.bounds, to: root)
            }
        }
        let originalFrames = try frames()
        editors[3].setSelectedRange(NSRange(location: 3, length: 5))
        let initial = try await PresentationTestSupport.capture(window, named: "split-composer-focused-4", in: "chat-validation")
        XCTAssertTrue(try initial.text().contains("Preserve working draft"))
        workspace.selectPane(at: 2)
        try await TestSupport.eventually { window.firstResponder === editors[2] }
        try await Task.sleep(for: .milliseconds(350))
        let changed = try await PresentationTestSupport.capture(window, named: "split-composer-focused-3", in: "chat-validation")
        let text = try changed.text().lowercased()
        XCTAssertTrue(text.contains("thinking"), text)
        XCTAssertEqual(text.components(separatedBy: "reply").count - 1, 3,
                       "Both idle panes and the focused editor must show Reply: \(text)")
        XCTAssertFalse(text.contains("preserve working draft"), text)
        XCTAssertEqual(sessions[3].draft, "Preserve working draft")
        XCTAssertEqual(editors[3].selectedRange(), NSRange(location: 3, length: 5))
        for (before, after) in zip(originalFrames, try frames()) {
            XCTAssertEqual(before.minX, after.minX, accuracy: 1)
            XCTAssertEqual(before.minY, after.minY, accuracy: 1, "Reply stays on the same line when focus changes")
            XCTAssertEqual(before.height, after.height, accuracy: 1)
        }
        XCTAssertEqual(PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: root).count, 4)
        let sendRows = try changed.recognizedText().filter {
            $0.topCandidates(1).first?.string.lowercased().contains("send") == true
        }
        XCTAssertEqual(sendRows.count, 1, "Only the focused pane shows composer actions")
        // Click the old input's position: the one-line prompt selects its pane
        // and returns to the same editor instead of constructing a new one.
        let point = editors[0].convert(NSPoint(x: 20, y: 10), to: nil)
        try PresentationTestSupport.click(window, at: point)
        try await TestSupport.eventually { workspace.activeSurfaceID == tabs[0] && window.firstResponder === editors[0] }
        // Rapid keyboard reversals settle on the final target, including drafts.
        workspace.selectPane(at: 3); workspace.selectPane(at: 2); workspace.selectPane(at: 3)
        try await TestSupport.eventually { window.firstResponder === editors[3] }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(editors[3].string, "Preserve working draft")
        XCTAssertEqual(editors[3].selectedRange(), NSRange(location: 3, length: 5))
    }

    func testNewMessagesPillPreservesPositionAndJumpsByClickOrEmptyReturn() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let coordinator = ChatCoordinator(enabled: false, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { coordinator.stop() }
        let session = coordinator.session(for: UUID())
        session.sessionID = "new-messages-pill"; session.showChat = true; session.active = true
        session.setPresented(true, by: UUID())
        session.turns = (0..<30).map { index in
            ChatTurn(id: "turn-\(index)", items: [.init(id: "answer-\(index)", kind: .assistant,
                text: "Earlier answer \(index)\n\n" + String(repeating: "Transcript content stays in place.\n\n", count: 3))])
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 550),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { session.scrollPosition.disconnect(); window.orderOut(nil); window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: true, floatingSwitch: false))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        let root = try XCTUnwrap(window.contentView)
        let editor = try XCTUnwrap(PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: root).first)
        let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: root)
            .max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
        func receiveWhileReading(_ index: Int) async throws -> PresentationTestSupport.Snapshot {
            session.scrollPosition.userWillScroll(deltaY: 240)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: try XCTUnwrap(scroll.documentView).bounds.height / 2))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await TestSupport.eventually { !session.atBottom }
            try await Task.sleep(for: .milliseconds(250))
            let anchor = try XCTUnwrap(session.scrollPosition.visibleAnchor())
            session.insert(ChatItem(id: "new-\(index)", kind: .assistant, text: "New response \(index)"), turnID: "latest")
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertTrue(session.hasNewMessages)
            let after = try XCTUnwrap(session.scrollPosition.visibleAnchor())
            XCTAssertEqual(after.id, anchor.id)
            XCTAssertEqual(after.offset, anchor.offset, accuracy: 2)
            let snapshot = try await PresentationTestSupport.capture(window, named: "new-messages-pill-\(index)", in: "chat-validation")
            XCTAssertTrue(try snapshot.text().lowercased().contains("new messages"))
            return snapshot
        }
        func assertLatest() async throws {
            try await TestSupport.eventually {
                session.atBottom && !session.hasNewMessages && session.scrollPosition.isAtBottom(tolerance: 24) == true
            }
            try await Task.sleep(for: .milliseconds(150))
            let snapshot = try await PresentationTestSupport.capture(window)
            XCTAssertFalse(try snapshot.text().lowercased().contains("new messages"))
        }
        // The floating pill neither reflows the transcript nor consumes a draft.
        session.draft = "Keep this draft"
        let snapshot = try await receiveWhileReading(1)
        let bounds = try XCTUnwrap(snapshot.recognizedText().first {
            $0.topCandidates(1).first?.string.lowercased().contains("new messages") == true
        }).boundingBox
        let point = NSPoint(x: bounds.midX * root.bounds.width,
                           y: (root.isFlipped ? 1 - bounds.midY : bounds.midY) * root.bounds.height)
        try PresentationTestSupport.click(window, at: root.convert(point, to: nil))
        try await assertLatest()
        XCTAssertEqual(session.draft, "Keep this draft")

        _ = try await receiveWhileReading(2)
        window.makeFirstResponder(editor)
        var submissions = 0
        editor.submit = { submissions += 1 }
        editor.keyDown(with: TerminalTestSupport.keyEvent(36, "\r", in: window))
        XCTAssertEqual(submissions, 1, "Return with a draft must retain its send behavior")
        XCTAssertFalse(session.atBottom)
        session.draft = ""
        session.drafts.edit(multiline: true)
        try await TestSupport.eventually { editor.string.isEmpty && editor.multiline }
        editor.keyDown(with: TerminalTestSupport.keyEvent(36, "\r", in: window))
        XCTAssertEqual(editor.string, "\n", "Editor mode retains newline behavior")
        XCTAssertFalse(session.atBottom)
        session.drafts.edit(text: "", multiline: false)
        try await TestSupport.eventually { editor.string.isEmpty && !editor.multiline }
        editor.submit = { submissions += 1 }
        editor.keyDown(with: TerminalTestSupport.keyEvent(36, "\r", in: window))
        try await assertLatest()
        XCTAssertEqual(submissions, 1, "Empty Return jumps without submitting")
        XCTAssertTrue(window.firstResponder === editor)
        session.insert(ChatItem(id: "new-3", kind: .assistant, text: "Following the next response"), turnID: "latest")
        try await assertLatest()
    }

    func testNarrowComposerKeepsModelAndDraftActions() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let previousTheme = ChatThemeStore.shared.current
        defer { ChatThemeStore.shared.current = previousTheme }
        ChatThemeStore.shared.current = .standard
        let coordinator = ChatCoordinator(enabled: false, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { coordinator.stop() }
        let session = coordinator.session(for: UUID())
        session.sessionID = "compact-composer"; session.active = true; session.showChat = true
        session.agentID = "codex"; session.model = "gpt-6-astra"; session.effort = "high"
        session.draft = "Ready to send"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 450), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: true, floatingSwitch: false))
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(NSSize(width: 300, height: 450))
        try await Task.sleep(for: .milliseconds(250))
        let emptyDrafts = try await PresentationTestSupport.capture(window, named: "composer-no-saved-drafts", in: "chat-validation").text().lowercased()
        XCTAssertFalse(emptyDrafts.contains("draft"), emptyDrafts)
        XCTAssertFalse(emptyDrafts.contains("drafts"), emptyDrafts)
        XCTAssertFalse(emptyDrafts.contains("keep"), emptyDrafts)
        let editor = try XCTUnwrap(PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: XCTUnwrap(window.contentView)).first)
        window.makeFirstResponder(editor)
        let save = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, characters: "s",
                                                charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        XCTAssertTrue(editor.performKeyEquivalent(with: save))
        try await TestSupport.eventually { editor.string.isEmpty }
        XCTAssertEqual(session.drafts.saved.map(\.text), ["Ready to send"])
        XCTAssertTrue(window.firstResponder === editor)
        for width in [1000, 480, 300, 1000] {
            window.setContentSize(NSSize(width: width, height: 450))
            try await Task.sleep(for: .milliseconds(250))
            let snapshot = try await PresentationTestSupport.capture(window, named: "composer-width-\(width)", in: "chat-validation")
            let text = try snapshot.text().lowercased()
            for label in ["astra", "drafts", "send"] { XCTAssertTrue(text.contains(label), text) }
            XCTAssertFalse(text.contains("keep"), text)
            let lines = try snapshot.recognizedText()
            let drafts = try XCTUnwrap(lines.first { $0.topCandidates(1).first?.string.lowercased().contains("drafts") == true })
            let send = try XCTUnwrap(lines.first { $0.topCandidates(1).first?.string.lowercased().hasPrefix("send") == true })
            XCTAssertEqual(drafts.boundingBox.midY, send.boundingBox.midY, accuracy: 0.025, "Drafts must share the Send button's footer row")
            XCTAssertFalse(text.contains("codex"), text)
            XCTAssertFalse(text.contains("gpt-6-astra"), text)
            XCTAssertTrue(text.contains("high"), text)
            for label in ["editor", "steer"] { XCTAssertFalse(text.contains(label), text) }
        }
        editor.insertText("Multiline draft", replacementRange: editor.selectedRange())
        let enterEditor = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                       charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.keyDown(with: enterEditor)
        XCTAssertTrue(session.drafts.current.multiline)
        for width in [1000, 300] {
            window.setContentSize(NSSize(width: width, height: 450))
            try await Task.sleep(for: .milliseconds(250))
            let text = try await PresentationTestSupport.capture(window, named: "composer-editor-\(width)", in: "chat-validation").text().lowercased()
            XCTAssertTrue(text.contains("editor"), text)
            XCTAssertFalse(text.contains("newline"), text)
            XCTAssertFalse(text.contains("steer"), text)
            XCTAssertTrue(window.firstResponder === editor,
                          "Responder: \(String(describing: window.firstResponder)); editor window: \(String(describing: editor.window)); key: \(String(describing: NSApp.keyWindow)); visible: \(NSApp.windows.filter(\.isVisible).map { String(describing: type(of: $0)) })")
        }
        XCTAssertTrue(editor.performKeyEquivalent(with: save))
        try await TestSupport.eventually { editor.string.isEmpty && !session.drafts.current.multiline }
        let compact = try await PresentationTestSupport.capture(window, named: "composer-editor-exited", in: "chat-validation").text().lowercased()
        XCTAssertFalse(compact.contains("editor"), compact)
    }

    func testReplyButtonKeepsSizeAcrossSendSteerAndQueueStates() {
        AppFont.register()
        for fontSize in [14.0, 32.0] {
            var preferences = Preferences(); preferences.fontSize = fontSize
            var theme = ChatTheme.standard
            theme.typography = ChatTypography(preferences: preferences)
            var expected: NSSize?
            for (optionHeld, busy, editingQueued, multiline) in [
                (false, false, false, false), (true, false, false, false),
                (false, true, false, false), (false, true, true, false),
                (false, false, false, true), (true, true, true, true),
            ] {
                let host = NSHostingView(rootView:
                    ChatReplyButton(canSubmit: true, optionHeld: optionHeld, busy: busy,
                                    editingQueued: editingQueued, multiline: multiline) {}
                        .environment(\.chatTheme, theme))
                let size = host.fittingSize
                XCTAssertGreaterThan(size.width, 0)
                if let expected {
                    XCTAssertEqual(size.width, expected.width, accuracy: 0.5)
                    XCTAssertEqual(size.height, expected.height, accuracy: 0.5)
                } else { expected = size }
            }
        }
    }

    func testComposerFooterStatesShortcutsAndFirstQueueTip() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let domain = "dispatch-queue-tip-" + UUID().uuidString, tips = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { tips.removePersistentDomain(forName: domain) }
        let coordinator = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()), defaults: tips)
        defer { coordinator.stop() }
        let session = coordinator.session(for: UUID())
        session.sessionID = "footer-states"; session.active = true; session.showChat = true
        session.model = "gpt-6-astra"; session.effort = "high"
        session.process = try XCTUnwrap(AgentProcess.capture(getpid()))
        // Queueing belongs to a helper chat; terminal 0 is no helper terminal (only the app's queue state is shown).
        session.helper = HelperChat(terminal: 0)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func mount() {
            window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: true, floatingSwitch: false))
        }
        mount(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        func snapshot(_ name: String) async throws -> PresentationTestSupport.Snapshot {
            try await Task.sleep(for: .milliseconds(200))
            return try await PresentationTestSupport.capture(window, named: name, in: "chat-footer-validation")
        }
        func capture(_ name: String) async throws -> String { try await snapshot(name).text().lowercased() }
        let idleSnapshot = try await snapshot("idle-empty")
        let idle = try idleSnapshot.text().lowercased()
        try PresentationTestSupport.assertText("Send", in: idleSnapshot)
        XCTAssertTrue(idle.contains("high"), idle)
        session.draft = "Also cover invoice.paid"
        _ = try await capture("idle-draft")
        session.busy = true; session.submittedThinkingAt = .now.addingTimeInterval(-12)
        let working = try await capture("working-draft")
        XCTAssertTrue(working.contains("queue")); XCTAssertTrue(working.contains("thinking"))
        XCTAssertTrue(working.contains("high"), working)
        session.draft = ""
        let empty = try await capture("working-empty")
        XCTAssertFalse(empty.contains("stop")); XCTAssertTrue(empty.contains("queue"))
        let editor = try XCTUnwrap(window.firstResponder as? ChatComposer.ComposerTextView)
        let shortcut = TerminalTestSupport.keyEvent(44, "/", in: window, modifiers: .command)
        XCTAssertTrue(editor.performKeyEquivalent(with: shortcut))
        var popover: NSWindow?
        try await TestSupport.eventually {
            for candidate in NSApp.windows where candidate !== window && candidate.isVisible && candidate.contentView != nil {
                if (try? await PresentationTestSupport.capture(candidate).text().contains("save draft")) == true {
                    popover = candidate
                    return true
                }
            }
            return false
        }
        let sheet = try await PresentationTestSupport.capture(XCTUnwrap(popover), named: "shortcut-sheet", in: "chat-footer-validation").text()
        XCTAssertTrue(sheet.contains("redirects")); XCTAssertTrue(sheet.contains("current turn"))
        popover?.performClose(nil)
        // Remounting also proves the onboarding state is persisted, not tied to a view instance.
        mount()
        try await Task.sleep(for: .milliseconds(150))
        session.draft = "Queued first"; coordinator.queue(session, drain: false)
        let tip = try await capture("first-queue-tip")
        XCTAssertTrue(tip.contains("interrupt and redirect"), tip)
        XCTAssertTrue(tips.bool(forKey: "chatQueueSteerTipShown"))
        mount()
        try await Task.sleep(for: .milliseconds(150))
        session.draft = "Queued second"; coordinator.queue(session, drain: false)
        let again = try await capture("second-queue")
        XCTAssertFalse(again.contains("interrupt and redirect"), again)
        window.setContentSize(NSSize(width: 300, height: 480))
        let narrow = try await capture("narrow-working")
        XCTAssertTrue(narrow.contains("astra")); XCTAssertTrue(narrow.contains("queue"))
        XCTAssertFalse(narrow.contains("high"), narrow)
        window.setContentSize(NSSize(width: 1000, height: 480))
        let expanded = try await capture("expanded-working")
        XCTAssertTrue(expanded.contains("high"), expanded)
        XCTAssertTrue(expanded.contains("thinking"), expanded)

        var meterSize: NSSize?
        for effort in ["minimal", "low", "medium", "high", "ultra"] {
            session.effort = effort
            let meter = NSHostingView(rootView: ChatEffortMeter(effort: effort))
            if let meterSize { XCTAssertEqual(meter.fittingSize, meterSize) }
            else { meterSize = meter.fittingSize }
            _ = try await capture("effort-" + effort)
        }
    }

    func testLiveDiffLineArrivalsKeepScrollPositionAndSourceStable() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let state = CodeDocumentState()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "let source = true\n".write(to: directory.appendingPathComponent("fixture.swift"), atomically: true, encoding: .utf8)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil }
        func view(_ diff: String) -> some View {
            CodeDocumentView(document: .init(path: "fixture.swift", diff: diff), directory: directory.path,
                             presentation: state, animatesChanges: true)
                .environment(\.chatTheme, ChatThemeStore.shared.current).padding(20)
                .foregroundStyle(ChatThemeStore.shared.current.ink).preferredColorScheme(.dark)
        }
        let initial = "@@ -1 +1 @@\n-let old = true\n+let replacement = true"
        let host = NSHostingView(rootView: view(initial))
        window.contentView = host; window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        let originalIDs = state.diffLines.lines.map(\.id)
        let updated = initial + "\n+let next = 2"
        host.rootView = view(updated)
        try await Task.sleep(for: .milliseconds(100))
        let arrival = try XCTUnwrap(state.diffLines.lines.last?.arrival)
        XCTAssertTrue(arrival.consumed, "The real diff renderer must start the new line's animation")
        XCTAssertEqual(Array(state.diffLines.lines.prefix(3).map(\.id)), originalIDs)
        try await Task.sleep(for: .milliseconds(200))
        let shot = try await PresentationTestSupport.capture(window, named: "live-diff-lines", in: "chat-validation")
        let text = try shot.text()
        XCTAssertTrue(text.contains("next"), text)

        let long = updated + "\n" + (0..<100).map { "+let value\($0) = \($0)" }.joined(separator: "\n")
        host.rootView = view(long)
        try await Task.sleep(for: .milliseconds(300))
        let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: host).first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 180)); scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(50))
        let position = scroll.contentView.bounds.origin
        host.rootView = view(long + "\n+let final = true")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(PresentationTestSupport.views(of: NSScrollView.self, in: host).first === scroll)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, position.y, accuracy: 1)
        XCTAssertEqual(scroll.contentView.bounds.origin.x, position.x, accuracy: 1)

        state.sourceMode = true
        try await TestSupport.eventually { state.source == "let source = true\n" }
        host.rootView = view(long + "\n+let hidden = true")
        try await Task.sleep(for: .milliseconds(100))
        state.sourceMode = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.diffLines.lines.allSatisfy { $0.arrival == nil }, "Switching from Source must not animate unseen diff updates")
    }

    func testLargeFontComposerKeepsOneFullLineInShortPane() async throws {
        try DesktopTestSupport.requireUnlocked()
        let previousTheme = ChatThemeStore.shared.current
        var preferences = Preferences(); preferences.fontSize = 32
        ChatThemeStore.shared.current.typography = ChatTypography(preferences: preferences)
        defer { ChatThemeStore.shared.current = previousTheme }
        let chat = ChatCoordinator(enabled: false, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { chat.stop() }
        let session = chat.session(for: UUID())
        session.sessionID = "large-font"; session.active = true; session.showChat = true
        session.draft = "A large draft wraps across this narrow pane"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 220),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: chat, focused: true, floatingSwitch: false))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        let editor = try XCTUnwrap(PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: XCTUnwrap(window.contentView)).first)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        XCTAssertGreaterThanOrEqual(scroll.bounds.height, ChatThemeStore.shared.current.typography.replyLineHeight + 10,
                                    "The composer must fit one complete line even when its proportional height budget is smaller")
        XCTAssertEqual(editor.string, session.draft)
        _ = try await PresentationTestSupport.capture(window, named: "large-font-short-pane", in: "chat-validation")
        window.makeFirstResponder(editor)
        for width in [360.0, 600.0, 480.0] {
            window.setContentSize(NSSize(width: width, height: 220))
            try await Task.sleep(for: .milliseconds(150))
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            editor.insertText(" more wrapped words", replacementRange: editor.selectedRange())
            try await TestSupport.eventually(diagnostic: "Typing must keep the insertion point visible in a short composer") {
                let caret = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
                let viewport = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
                return caret.minY >= viewport.minY - 1 && caret.maxY <= viewport.maxY + 1
            }
            XCTAssertEqual(editor.string, session.draft)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertGreaterThanOrEqual(scroll.bounds.height, ChatThemeStore.shared.current.typography.replyLineHeight + 10)
        }
        _ = try await PresentationTestSupport.capture(window, named: "large-font-short-pane-edited", in: "chat-validation")
        let savedText = editor.string, savedSelection = editor.selectedRange()
        session.drafts.keep()
        let saved = try XCTUnwrap(session.drafts.saved.first)
        try await TestSupport.eventually { editor.string.isEmpty }
        editor.insertText("Another draft", replacementRange: editor.selectedRange())
        session.drafts.select(saved.id)
        try await TestSupport.eventually { editor.string == savedText && editor.selectedRange() == savedSelection }
        try await TestSupport.eventually(diagnostic: "Restoring a draft must reveal its saved insertion point") {
            let caret = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
            let viewport = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
            return caret.minY >= viewport.minY - 1 && caret.maxY <= viewport.maxY + 1
        }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let browsingOrigin = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(editor.bounds.height, scroll.contentView.bounds.height)
        for index in 0..<3 {
            session.busy = index % 2 == 0
            session.insert(ChatItem(id: "stream-\(index)", kind: .assistant, text: "Incoming response \(index)"), turnID: "stream")
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(scroll.contentView.bounds.origin.y, browsingOrigin, accuracy: 1,
                           "Incoming chat updates must preserve manual draft scrolling")
            XCTAssertEqual(editor.selectedRange(), savedSelection)
            XCTAssertEqual(editor.string, savedText)
        }
        editor.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        editor.didChangeText()
        XCTAssertTrue(editor.hasMarkedText())
        let composingText = editor.string
        try await TestSupport.eventually { session.draft == composingText }
        session.drafts.select(nil)
        try await TestSupport.eventually(diagnostic: "Switching drafts must end composition and display the selected draft") {
            editor.string == "Another draft" && !editor.hasMarkedText()
        }
        editor.insertText("!", replacementRange: editor.selectedRange())
        XCTAssertEqual(session.draft, "Another draft!")
        XCTAssertEqual(session.drafts.saved.first { $0.id == saved.id }?.text, composingText)
    }

    func testAttentionPreservesMountedComposerFocusSelectionAndDraft() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { chat.stop() }
        let session = chat.session(for: UUID())
        session.sessionID = "attention-ui"; session.active = true
        chat.chooseChat(true, session: session)
        session.draft = "My unfinished thought"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: chat, focused: true, floatingSwitch: false))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 3, length: 4))
        for failure in ["Approval needs attention", "Command timed out", "Helper unavailable"] {
            chat.requireTerminalAttention(session, status: failure)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(session.showChat)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 4))
            XCTAssertEqual(session.draft, "My unfinished thought")
        }
        editor.insertText("edited", replacementRange: editor.selectedRange())
        XCTAssertEqual(session.draft, "My editednished thought")
        let text = try await PresentationTestSupport.capture(window, named: "attention-keeps-chat", in: "chat-validation").text().lowercased()
        XCTAssertTrue(text.contains("retry chat"), text)
        XCTAssertTrue(text.contains("open in terminal"), text)
    }

    func testUserMessagesRenderMarkdownAndHighlightedCode() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let previous = ChatThemeStore.shared.current
        defer { ChatThemeStore.shared.current = previous }
        var theme = ChatTheme.standard
        theme.keyword = Color(red: 1, green: 0, blue: 1)
        ChatThemeStore.shared.current = theme
        let chat = ChatCoordinator(enabled: false, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = chat.session(for: UUID())
        session.sessionID = "user-markdown"; session.active = true; session.showChat = true
        session.insert(ChatItem(id: "user-markdown", kind: .user,
            text: "# Message heading\n\n**Important** and `inline`.\n\n```swift\nlet amount = 42\n```\n\n- First entry"), turnID: "turn")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: chat, focused: false, floatingSwitch: false))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        let snapshot = try await PresentationTestSupport.capture(window, named: "user-markdown", in: "chat-validation")
        let text = try snapshot.text()
        XCTAssertTrue(text.contains("Message heading"), text)
        XCTAssertTrue(text.contains("Important"), text)
        XCTAssertTrue(text.contains("First entry"), text)
        XCTAssertTrue(text.contains("swift"), text)
        XCTAssertFalse(text.contains("**"), text)
        XCTAssertFalse(text.contains("```"), text)
        let bitmap = snapshot.bitmap
        var highlightedPixels = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                // Use chroma rather than exact channels: display profiles and
                // antialiasing can lift the green component of magenta ink.
                if color.redComponent > color.greenComponent + 0.3 && color.blueComponent > color.greenComponent + 0.3 { highlightedPixels += 1 }
            }
        }
        XCTAssertGreaterThan(highlightedPixels, 5, "The user code block must render the keyword color")
    }

    func testModeSwitchDoesNotInheritChatFont() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let previous = ChatThemeStore.shared.current
        defer { ChatThemeStore.shared.current = previous }
        ChatThemeStore.shared.current = .standard
        let chat = ChatCoordinator(enabled: false, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = chat.session(for: UUID())
        session.sessionID = "switch-font"; session.active = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 48), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: ChatModeSwitch(session: session, coordinator: chat)
            .fixedSize().frame(width: 240, height: 48))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        let before = try await PresentationTestSupport.capture(window).bitmap.representation(using: .png, properties: [:])
        var changed = ChatThemeStore.shared.current
        changed.typography.fontName = "HelveticaNeue"
        changed.typography.size = 24
        ChatThemeStore.shared.current = changed
        try await Task.sleep(for: .milliseconds(200))
        let after = try await PresentationTestSupport.capture(window).bitmap.representation(using: .png, properties: [:])
        XCTAssertNotNil(before); XCTAssertEqual(before, after, "Chat font changes must not change the switch's glyphs or size")
    }

    func testChatUsesResolvedThemeAndUpdatesWithoutRemounting() async throws {
        let restore = TestSupport.preserveRuntime()
        defer { restore() }
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let runtime = TerminalRuntime.shared
        let previousTheme = ChatThemeStore.shared.current
        let previousSidebar = SidebarThemeStore.shared.current
        var preferences = Preferences(); preferences.appTheme = .dark; preferences.theme = "Dracula"
        runtime.start(preferences: preferences)
        defer { runtime.stop(); ChatThemeStore.shared.current = previousTheme; SidebarThemeStore.shared.current = previousSidebar }
        XCTAssertNil(runtime.error)
        let coordinator = ChatCoordinator(enabled: false)
        defer { coordinator.stop() }
        let session = coordinator.session(for: UUID())
        session.sessionID = "theme-test"; session.active = true; session.showChat = true
        session.draft = "A draft survives theme changes"
        session.turns = [.init(id: "turn", items: [
            .init(id: "user", kind: .user, text: "Check the selected theme"),
            .init(id: "reply", kind: .assistant, text: "A **themed reply** with `inline code`.\n\n```swift\nlet message = \"hello\"\n// Comment\n```"),
            .init(id: "tool", kind: .tool, text: #"{"cmd":"git status"}"#, title: "shell", output: "Working tree clean", completed: true)
        ])]
        session.expanded = Set(session.transcriptRows.filter { $0.item?.kind == .tool }.map(\.id))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: true, floatingSwitch: false))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        let composer = try XCTUnwrap(PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: XCTUnwrap(window.contentView)).first)
        func rgb(_ color: NSColor) -> [CGFloat] {
            let c = color.usingColorSpace(.sRGB)!
            return [c.redComponent, c.greenComponent, c.blueComponent]
        }
        for light in [false, true, false] {
            preferences.fontFamily = light ? "Menlo" : "Source Code Pro"
            preferences.chatFont = light ? .sameAsCode : .comicSans
            preferences.fontSize = light ? 20 : 12.5
            composer.setSelectedRange(NSRange(location: 2, length: 4))
            preferences.appTheme = light ? .light : .dark
            preferences.lightTheme = "Gruvbox Light"
            try runtime.apply(preferences)
            try await Task.sleep(for: .milliseconds(250))
            let theme = ChatThemeStore.shared.current
            XCTAssertEqual(theme.isDark, !light)
            XCTAssertEqual(theme.typography.size, preferences.fontSize)
            let scale = preferences.chatFont.sizeScale
            XCTAssertEqual(theme.typography.detailSize, (preferences.fontSize - 2) * scale, accuracy: 0.001)
            let editorFont = try XCTUnwrap(composer.font)
            XCTAssertEqual(editorFont.familyName, light ? preferences.fontFamily : "Comic Sans MS")
            XCTAssertEqual(editorFont.pointSize, (preferences.fontSize + 1) * scale, accuracy: 0.001)
            XCTAssertEqual(composer.selectedRange(), NSRange(location: 2, length: 4))
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(composer.enclosingScrollView).bounds.height,
                theme.typography.replyLineHeight + 10)

            let expected = light ? [251, 241, 199] : [40, 42, 54]
            for (actual, value) in zip(rgb(NSColor(theme.terminal)), expected) { XCTAssertEqual(actual, CGFloat(value) / 255, accuracy: 0.001) }
            let expectedGreen = light ? [152, 151, 26] : [80, 250, 123]
            for (actual, value) in zip(rgb(NSColor(theme.green)), expectedGreen) { XCTAssertEqual(actual, CGFloat(value) / 255, accuracy: 0.001) }
            XCTAssertEqual(rgb(try XCTUnwrap(composer.textColor)), rgb(NSColor(theme.ink)))
            XCTAssertEqual(rgb(composer.insertionPointColor), rgb(NSColor(theme.ink)))
            XCTAssertEqual(composer.string, "A draft survives theme changes")
            XCTAssertTrue(PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: try XCTUnwrap(window.contentView)).first === composer)
            XCTAssertEqual(SyntaxHighlight.text("let", language: "swift", theme: theme).foregroundColor, theme.keyword)
            let snapshot = try await PresentationTestSupport.capture(window, named: light ? "light" : "dark", in: "chat-theme-validation")
            let pixel = try XCTUnwrap(snapshot.bitmap.colorAt(x: 3, y: snapshot.bitmap.pixelsHigh / 2))
            // Compare against a rendered swatch: cacheDisplay's device channels
            // depend on the display profile, while the source RGB is checked above.
            let swatch = NSHostingView(rootView: theme.terminal.frame(width: 8, height: 8))
            swatch.frame = NSRect(x: 0, y: 0, width: 8, height: 8)
            window.contentView?.addSubview(swatch)
            defer { swatch.removeFromSuperview() }
            try await Task.sleep(for: .milliseconds(50))
            let swatchSnapshot = try await PresentationTestSupport.capture(swatch)
            let reference = try XCTUnwrap(swatchSnapshot.bitmap.colorAt(x: 2, y: 2))
            let channels = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent]
            let referenceChannels = [reference.redComponent, reference.greenComponent, reference.blueComponent]
            for (actual, value) in zip(channels, referenceChannels) { XCTAssertEqual(actual, value, accuracy: 0.01) }
        }
    }

    func testUpdatedMockupFullWidthTranscriptAndUserBubble() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let coordinator = ChatCoordinator(enabled: false)
        let session = coordinator.session(for: UUID())
        session.sessionID = "mockup-layout"; session.active = true; session.atBottom = false
        session.model = "gpt-6-astra"; session.effort = "high"
        session.insert(ChatItem(id: "user", kind: .user, text: String(repeating: "User message content ", count: 20)), turnID: "turn")
        session.insert(ChatItem(id: "assistant", kind: .assistant, text: "Full width transcript"), turnID: "turn")
        for index in 0..<2 {
            session.insert(ChatItem(id: "shell-\(index)", kind: .tool, text: #"{"cmd":"swift test"}"#,
                title: "exec_command", output: "Passed", completed: true, exitCode: 0), turnID: "turn")
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: false, floatingSwitch: false)
            .foregroundStyle(Chrome.ink).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        let snapshot = try await PresentationTestSupport.capture(window, named: "updated-full-width", in: "chat-validation")
        let rows = try snapshot.recognizedText()
        let assistant = try XCTUnwrap(rows.first { $0.topCandidates(1).first?.string.lowercased().contains("transcript") == true })
        let assistantLine = rows.filter { abs($0.boundingBox.midY - assistant.boundingBox.midY) < assistant.boundingBox.height / 2 }
        XCTAssertLessThan(assistantLine.map(\.boundingBox.minX).min() ?? 1, 0.04,
                          "Assistant text starts at the pane margin inside its bubble")
        let user = try XCTUnwrap(rows.first { $0.topCandidates(1).first?.string.contains("User message") == true })
        XCTAssertGreaterThan(user.boundingBox.minX, 0.39, "User bubbles stay within 60 percent of the pane and 80 characters")
        let visibleText = rows.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(visibleText.contains("2 steps"), visibleText)
    }

    func testLivePatchAndGoalInfoWithoutComposerStats() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let previousTheme = ChatThemeStore.shared.current
        let previousSidebar = SidebarThemeStore.shared.current
        defer { ChatThemeStore.shared.current = previousTheme; SidebarThemeStore.shared.current = previousSidebar }
        ChatThemeStore.shared.current = .standard
        SidebarThemeStore.shared.current = .dark
        let coordinator = ChatCoordinator(enabled: false)
        defer { coordinator.stop() }
        let session = coordinator.session(for: UUID())
        session.sessionID = "live-patch"; session.active = true; session.showChat = true
        session.busy = true; session.activeTurnID = "turn"; session.atBottom = false
        session.turns = [.init(id: "turn", items: [
            .init(id: "user", kind: .user, text: "Also cover invoice.paid."),
            .init(id: "assistant", kind: .assistant, text: "Moving the check into a shared middleware so both routes use it."),
            .init(id: "read", kind: .tool, text: #"{"cmd":"cat src/invoices.swift"}"#, title: "exec_command", completed: true),
            .init(id: "patch", kind: .tool, text: "*** Begin Patch\n*** Update File: src/billing.swift\n@@\n-let key = attempt.id\n+let key = event.id\n*** End Patch", title: "apply_patch")])]
        session.usage = ChatUsage(["info": ["total_token_usage": ["input_tokens": 142000, "output_tokens": 6940],
                                          "last_token_usage": ["total_tokens": 19000], "model_context_window": 100000]])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: true, floatingSwitch: false))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(500))
        var text = try await PresentationTestSupport.capture(window, named: "live-patch", in: "chat-validation").text()
        XCTAssertTrue(text.replacingOccurrences(of: " ", with: "").contains("event.id"), text)
        XCTAssertTrue(text.contains("Diff"), text)
        XCTAssertTrue(text.contains("Source"), text)
        XCTAssertFalse(text.contains("142"), "Session statistics appear only in expanded activity")
        session.goal = ChatGoal(["objective": "Cover invoice.paid", "status": "active", "timeUsedSeconds": 6240])
        session.goalUpdatedAt = .now
        try await Task.sleep(for: .milliseconds(250))
        text = try await PresentationTestSupport.capture(window, named: "goal-info", in: "chat-validation").text()
        XCTAssertFalse(text.contains("81%"), text)
        XCTAssertTrue(text.contains("44m"), text)
        XCTAssertFalse(text.contains("142"), text)
        XCTAssertFalse(text.contains("Cover invoice.paid"), "The goal summary belongs in its popover: \(text)")
        XCTAssertFalse(text.contains("Pause"), text)
        let activeControls = try await PresentationTestSupport.openGoalControls(in: window)
        let activeSnapshot = try await PresentationTestSupport.capture(activeControls, named: "goal-controls-active", in: "chat-validation")
        // macOS 27 Vision can insert a space after the objective's dot.
        try PresentationTestSupport.assertText("Cover invoice.paid", ["Cover invoice. paid"], in: activeSnapshot)
        let activeText = try activeSnapshot.text()
        for label in ["Pause", "Resume", "Stop"] { XCTAssertTrue(activeText.contains(label), activeText) }
        try await PresentationTestSupport.dismissGoalControls(activeControls)
        XCTAssertTrue(session.busy)

        session.command = ChatCommandRequest(.goal("pause"))
        try await Task.sleep(for: .milliseconds(100))
        text = try await PresentationTestSupport.capture(window, named: "goal-pausing", in: "chat-validation").text()
        XCTAssertTrue(text.lowercased().contains("pausing"), text)
        session.goal = ChatGoal(["objective": "Cover invoice.paid", "status": "paused", "timeUsedSeconds": 9])
        session.goalUpdatedAt = .now.addingTimeInterval(-60)
        session.command = nil
        session.draft = "Keep this draft"
        session.drafts.edit(multiline: true)
        try await Task.sleep(for: .milliseconds(1100))
        let paused = try await PresentationTestSupport.capture(window, named: "goal-paused-response-active", in: "chat-validation")
        text = try paused.text()
        XCTAssertTrue(text.contains("goal paused"), text)
        XCTAssertTrue(text.contains("9s"), "A paused goal's timer must not accrue elapsed time: \(text)")
        XCTAssertFalse(text.contains("Resume"), text)
        XCTAssertFalse(text.contains("Goal paused."), text)
        let pausedControls = try await PresentationTestSupport.openGoalControls(in: window)
        let explanationText = try await PresentationTestSupport.capture(pausedControls, named: "goal-controls-paused", in: "chat-validation").text()
        XCTAssertTrue(explanationText.contains("current response is still running"), explanationText)
        try await PresentationTestSupport.dismissGoalControls(pausedControls)
        XCTAssertEqual(session.draft, "Keep this draft")
        XCTAssertTrue(session.drafts.current.multiline)
        XCTAssertTrue(AgentWorkingState(session).visible, "Pausing a goal must not hide an active response")
        session.busy = false
        try await Task.sleep(for: .milliseconds(100))
        text = try await PresentationTestSupport.capture(window, named: "goal-paused-idle", in: "chat-validation").text()
        XCTAssertFalse(text.contains("current response is still running"), text)
        XCTAssertFalse(text.contains("Goal paused."), text)
        XCTAssertFalse(AgentWorkingState(session).visible)
        XCTAssertFalse(text.contains("$"), "Unknown cost is never estimated")
        let group = try XCTUnwrap(session.transcriptRows.compactMap(\.group).first)
        session.setGroupExpanded(group, false)
        try await Task.sleep(for: .milliseconds(200))
        let completed = try await PresentationTestSupport.capture(window)
        XCTAssertFalse(try completed.text().replacingOccurrences(of: " ", with: "").contains("event.id"))
        session.setGroupExpanded(group, true)
        window.setContentSize(NSSize(width: 476, height: 900))
        try await Task.sleep(for: .milliseconds(250))
        text = try await PresentationTestSupport.capture(window, named: "goal-info-narrow", in: "chat-validation").text()
        XCTAssertFalse(text.contains("81%"), text)
        XCTAssertTrue(text.contains("goal paused"), text)
        XCTAssertTrue(text.contains("9s"), text)
        XCTAssertFalse(text.contains("142"), text)
    }

    func testSixNativeChatStatesAndKeyboardComposer() async throws {
        try DesktopTestSupport.requireUnlocked()
        let coordinator = ChatCoordinator(enabled: true)
        let session = coordinator.session(for: UUID())
        session.sessionID = UUID().uuidString; session.version = "0.153.2"
        session.active = true; session.showChat = true; session.model = "test-model"
        let date = Date().addingTimeInterval(-86)
        session.insert(ChatItem(id: "user", kind: .user, text: "Make billing webhook retries idempotent."), turnID: "turn", at: date)
        session.insert(ChatItem(id: "thinking", kind: .reasoning, text: "The supplied summary appears here.", title: "Reasoning summary"), turnID: "turn")
        session.insert(ChatItem(id: "assistant", kind: .assistant, text: "Retries now use the **event ID**.\n\n```swift\nlet key = event.id\n```"), turnID: "turn")
        session.insert(ChatItem(id: "patch", kind: .tool, text: "--- billing.swift\n+++ billing.swift\n@@ retries @@\n- attempt.id\n+ event.id", title: "Patch", output: "Applied"), turnID: "turn")
        session.turns[0].ended = Date()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 916, height: 702), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        func mount(_ floating: Bool = false) {
            window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: true, floatingSwitch: floating)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Chrome.ink).preferredColorScheme(.dark)
                .overlay(alignment: .topTrailing) { if floating { ChatModeSwitch(session: session, coordinator: coordinator).padding(8) } })
            window.makeKeyAndOrderFront(nil)
        }
        @discardableResult
        func capture(_ name: String) async throws -> PresentationTestSupport.Snapshot {
            try await Task.sleep(for: .milliseconds(100))
            return try await PresentationTestSupport.capture(window, named: name, in: "chat-validation")
        }
        mount(); try await capture("1a-chat")
        session.busy = true
        let working = try await capture("working")
        XCTAssertTrue(try working.text().contains("thinking"))
        session.busy = false
        let idle = try await capture("idle")
        XCTAssertFalse(try idle.text().contains("thinking"))
        XCTAssertTrue(window.firstResponder is NSTextView)
        let composer = try XCTUnwrap(window.firstResponder as? NSTextView)
        composer.insertText("draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        let newline = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        composer.keyDown(with: newline)
        XCTAssertEqual(session.draft, "draft\n")
        try await capture("reply-typed")
        session.draft = ""
        try await capture("reply-cleared")
        XCTAssertTrue(window.firstResponder === composer, "Hiding Send must preserve the native editor and focus")
        session.draft = "draft\n"
        session.approvals.append(PendingApproval(key: "permission", operation: "Bash\nswift build", turnID: "turn") { _ in })
        let approval = try await capture("1b-approval")
        XCTAssertTrue(try approval.text().contains("Allow once"), "The pending approval must be actionable in Chat")
        session.approvals[0].resolve(.deny)
        let patchGroup = try XCTUnwrap(session.transcriptRows.compactMap(\.group).first)
        session.expandedToolGroups.insert(patchGroup.id)
        let patchRowID = try XCTUnwrap(patchGroup.children.first { $0.item?.id == "patch" }?.id)
        session.expanded.insert(patchRowID); session.draft = "/"
        let diff = try await capture("1c-diff-commands")
        XCTAssertTrue(try diff.text().replacingOccurrences(of: " ", with: "").contains("attempt.id"), "An expanded patch must show its removed lines")
        coordinator.chooseChat(false, session: session)
        XCTAssertFalse(session.showChat)
        coordinator.chooseChat(true, session: session)
        XCTAssertEqual(session.draft, "/"); XCTAssertTrue(session.expanded.contains(patchRowID))
        try await capture("1d-return-to-chat")
        let retainedTurns = session.turns
        session.sessionID = nil; session.active = false; session.turns = []; session.approvals = []; session.draft = ""
        let unavailable = try await capture("1e-unavailable")
        // The blinking caret sits on the placeholder's first letter; match past it.
        XCTAssertTrue(try unavailable.text().contains(coordinator.agents + " in this terminal"), "Without an agent the opened composer says how to start one")
        session.sessionID = UUID().uuidString; session.turns = retainedTurns; session.active = true
        mount(true); try await capture("1f-reduced-chrome")
        XCTAssertNotNil(composer.accessibilityLabel())
    }
}
