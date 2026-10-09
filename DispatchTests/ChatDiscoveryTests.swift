import AppKit
import Term
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class ChatDiscoveryTests: XCTestCase {
    func testOpenFileReplacementCannotChangeDiscoveredMetadata() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-descriptor-" + UUID().uuidString + ".jsonl")
        try Data("original".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let process = try XCTUnwrap(AgentProcess.capture(getpid()))
        let opened = try XCTUnwrap(process.openFiles?.first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == url.resolvingSymlinksInPath() })
        XCTAssertEqual(opened.prefix(limit: 100), Data("original".utf8))
        try Data("replacement".utf8).write(to: url, options: .atomic)
        XCTAssertNil(opened.prefix(limit: 100), "A pathname must still refer to the process's open inode")
    }



    /// A transcript is read by its own agent's reader: a Claude transcript opens as Claude's, and the
    /// same file asked for as a Codex conversation is not taken for one.
    func testTranscriptReaderUsesAgentSpecificParser() async throws {
        let session = "00000000-0000-4000-8000-000000000201"
        func row(_ type: String, _ id: String, _ message: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["type": type, "uuid": id, "sessionId": session, "message": message,
                "version": "2.1.260", "timestamp": "2000-01-01T10:00:00.123Z"], options: [.sortedKeys]), as: UTF8.self)
        }
        let lines = [try row("user", "u1", ["role": "user", "content": "An agent-specific question"]),
                     try row("assistant", "a1", ["role": "assistant", "model": "fixture", "content": [["type": "text", "text": "An agent-specific answer"]]])]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-adapter-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { chat.stop() }
        let claude = try await chat.archived(lines, agent: "claude", session: session, in: directory)
        XCTAssertEqual(claude.turns.flatMap(\.items).filter { $0.kind == .assistant }.map(\.text), ["An agent-specific answer"])
        let codex = try await chat.archived(directory.appendingPathComponent(session + ".jsonl"), agent: "codex", session: session, opens: false)
        XCTAssertTrue(codex.turns.isEmpty, "A Claude transcript is not a Codex one")
    }

    func testAttentionNeverChangesManualViewPreference() {
        let coordinator = ChatCoordinator(enabled: true)
        let session = coordinator.session(for: UUID())
        defer { coordinator.close(session.id) }
        coordinator.chooseChat(true, session: session)
        session.draft = "keep this draft"
        coordinator.requireTerminalAttention(session, status: "Native menu needs attention")
        XCTAssertTrue(session.showChat)
        XCTAssertTrue(session.manualViewChoice)
        XCTAssertEqual(session.draft, "keep this draft")
        XCTAssertEqual(session.viewTransitions.map(\.reason), ["user"])
        coordinator.chooseChat(false, session: session)
        // An agent the app cannot verify blocks input (the blocked state; its producer is the binding).
        session.discoveryBlocked = true; session.status = "Helper unavailable"
        coordinator.requireTerminalAttention(session, status: "Command timed out")
        XCTAssertFalse(session.showChat)
        XCTAssertTrue(session.manualViewChoice)
        coordinator.chooseChat(true, session: session)
        XCTAssertNil(session.terminalAttention)
        XCTAssertTrue(session.inputBlocked, "Choosing Chat cannot bypass failed identity verification")
    }

    /// Claude registers its session before startup dialogs such as the review of changed hooks;
    /// Chat must not cover them, and opens on its own once the dialog closes.
    func testNativeDialogDefersAutomaticChat() {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = chat.session(for: UUID())
        defer { chat.close(session.id) }
        session.helper = HelperChat(terminal: 0); session.sessionID = "dialog"
        func state(dialog: String?) -> HelperChat.State {
            .init(busy: dialog != nil, activity: dialog == nil ? "idle" : "waiting", model: nil, model_label: nil, effort: nil,
                  usage: nil, goal: nil, draft: nil, attention: nil, dialog: dialog, title: nil, compacting: false, service_tier: nil)
        }
        chat.receiveHelper(.state(state(dialog: "dialog open")), session: session)
        XCTAssertTrue(session.active)
        XCTAssertFalse(session.showChat, "A native dialog keeps Terminal in front")
        chat.receiveHelper(.state(state(dialog: nil)), session: session)
        XCTAssertTrue(session.showChat)
        XCTAssertFalse(session.manualViewChoice)
    }

    /// A helper chat failure blocks the chat like this.
    func testDiscoveryFailureRetainsChatAndDurableDraftWithoutAllowingInput() throws {
        let store = ChatDraftMemoryStore()
        let coordinator = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: store))
        let session = coordinator.session(for: UUID())
        defer { coordinator.close(session.id) }
        session.sessionID = UUID().uuidString
        session.active = true
        session.process = try XCTUnwrap(AgentProcess.capture(getpid()))
        coordinator.chooseChat(true, session: session)
        session.drafts.edit(text: "Unfinished 🧑🏽‍💻\nsecond line", selection: NSRange(location: 3, length: 2))
        let draft = session.drafts.current
        coordinator.suspendDiscovery(session, status: "Cannot inspect session files")
        XCTAssertTrue(session.showChat)
        XCTAssertTrue(session.manualViewChoice)
        XCTAssertTrue(coordinator.canEnterChat(session))
        XCTAssertTrue(session.discoveryBlocked)
        XCTAssertFalse(coordinator.canPickModel(session))
        XCTAssertFalse(coordinator.canInterrupt(session))
        coordinator.sendFromComposer(session)
        XCTAssertTrue(session.queuedMessages.isEmpty)
        XCTAssertEqual(session.drafts.current, draft)
        let restored = ChatDraftRepository(store: store)
        XCTAssertEqual(restored.buckets[session.drafts.scope]?.working, draft, "Failure must flush the latest text and selection immediately")
        coordinator.chooseChat(false, session: session)
        coordinator.toggle(session.id)
        XCTAssertTrue(session.showChat, "Blocked discovery must never prevent returning to the draft")
        coordinator.suspendDiscovery(session, status: "Still unavailable")
        XCTAssertEqual(session.drafts.current, draft)
    }

    func testPreviouslyOpenedEmptyChatRemainsReachableAfterAttachmentEnds() {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = chat.session(for: UUID())
        defer { chat.close(session.id) }
        session.active = true
        chat.chooseChat(true, session: session)
        session.active = false
        chat.chooseChat(false, session: session)
        XCTAssertNil(session.sessionID); XCTAssertTrue(session.draft.isEmpty)
        XCTAssertTrue(chat.canEnterChat(session))
        chat.toggle(session.id)
        XCTAssertTrue(session.showChat)
    }

    func testAttentionSurvivesPollingAndBlocksEveryInputPath() throws {
        let store = ChatDraftMemoryStore()
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: store))
        let session = chat.session(for: UUID())
        defer { chat.close(session.id) }
        session.active = true; session.sessionID = "attention"
        session.process = try XCTUnwrap(AgentProcess.capture(getpid()))
        chat.chooseChat(true, session: session)
        session.drafts.edit(text: "still editing", selection: NSRange(location: 3, length: 2))
        session.queuedMessages = [.init(text: "previously queued", process: session.process)]
        let original = session.drafts.current
        for failure in ["Command timed out", "Model menu incomplete", "Native permission required", "Pi needs an answer"] {
            chat.requireTerminalAttention(session, status: failure)
            session.status = nil // A successful transcript read must not hide the pause.
            session.discoveryBlocked = false // Neither may successful discovery.
            XCTAssertEqual(session.status, failure)
            chat.sendFromComposer(session)
            chat.submit(session)
            XCTAssertEqual(session.queuedMessages.count, 1)
            XCTAssertNil(session.queuePaused, "Untouched messages wait on terminal readiness")
            XCTAssertNil(session.submissionID)
            XCTAssertFalse(chat.canPickModel(session))
            XCTAssertTrue(session.showChat)
            XCTAssertEqual(session.drafts.current, original)
        }
        XCTAssertEqual(store.buckets[session.drafts.scope]?.working, original)
        session.draft += " while paused"
        chat.retryChat(session)
        XCTAssertNil(session.terminalAttention)
        XCTAssertNil(session.queuePaused, "Retry releases untouched queued messages once ready")
        XCTAssertNil(session.submissionID)
        XCTAssertTrue(session.draft.hasSuffix(" while paused"))
    }

    func testConversationResetPreservesExplicitViewChoice() {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = chat.session(for: UUID())
        defer { chat.close(session.id) }
        for selected in [true, false] {
            chat.chooseChat(selected, session: session)
            session.sessionID = UUID().uuidString
            session.draft = "Previous conversation draft"
            let scope = session.drafts.scope
            session.resetConversation()
            session.sessionID = nil
            XCTAssertEqual(session.showChat, selected)
            XCTAssertTrue(session.manualViewChoice)
            XCTAssertTrue(session.draft.isEmpty)
            XCTAssertEqual(session.drafts.repository.buckets[scope]?.working.text, "Previous conversation draft")
        }
    }

    // Helper route, same expectations as before: presentation and drafts follow a remote
    // conversation to the new surface after a reconnect; selection kept; no input authority moves with it.
    func testRemotePresentationSurvivesNewProcessAndSurfaceWithoutTransferringAuthority() {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        // A remote helper chat: its SSH host and the agent process the helper bound.
        func remote(_ session: ChatSession, _ pid: UInt64, host: String = "account@host") {
            session.host = host
            session.binding = .init(session: session.sessionID ?? "", transcript: nil, pid: pid, start: [pid, 0], executable: "/bin/codex")
        }
        let old = chat.session(for: UUID())
        old.sessionID = "conversation"; remote(old, 10)
        chat.chooseChat(true, session: old)
        old.expanded = ["tool"]
        old.drafts.edit(text: "draft across reconnect", selection: NSRange(location: 6, length: 2))
        chat.requireTerminalAttention(old, status: "Old menu")
        chat.close(old.id)
        let wrong = chat.session(for: UUID())
        defer { chat.close(wrong.id) }
        wrong.sessionID = "conversation"; remote(wrong, 20, host: "other@host")
        chat.restoreRemotePresentation(wrong)
        XCTAssertFalse(wrong.showChat); XCTAssertTrue(wrong.draft.isEmpty)
        let next = chat.session(for: UUID())
        defer { chat.close(next.id) }
        next.sessionID = "conversation"; remote(next, 30)
        chat.restoreRemotePresentation(next)
        XCTAssertTrue(next.showChat); XCTAssertTrue(next.manualViewChoice)
        XCTAssertEqual(next.expanded, ["tool"])
        XCTAssertEqual(next.draft, "draft across reconnect")
        XCTAssertEqual(next.drafts.current.selection, NSRange(location: 6, length: 2))
        XCTAssertFalse(next.active); XCTAssertNil(next.terminalAttention)
        XCTAssertTrue(next.approvals.isEmpty); XCTAssertTrue(next.queuedMessages.isEmpty)
        XCTAssertEqual(next.viewTransitions.last?.reason, "conversation-restored")
    }

    func testRemoteInteractionRetirementSurvivesEitherDisconnectCallbackOrder() {
        for subscriptionFirst in [true, false] {
            let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
            let old = chat.session(for: UUID())
            old.host = "account@host"; old.agentID = "claude"; old.sessionID = "conversation"
            old.helper = HelperChat(terminal: 1, session: "conversation", endpoint: .local)
            old.draft = "Unsent reconnect draft λ"
            let approval = PendingApproval(key: "conversation:Bash", interaction: "hook", operation: "Original command") { _ in }
            old.approvals = [approval]
            if subscriptionFirst { chat.suspendDiscovery(old, status: "Connection closed") }
            chat.helperExited(.local, terminal: 1)
            if !subscriptionFirst { chat.suspendDiscovery(old, status: "Connection closed") }
            XCTAssertEqual(approval.decision, .terminal)
            XCTAssertEqual([approval.key, approval.operation], ["conversation:Bash", "Original command"])
            chat.close(old.id)

            let next = chat.session(for: UUID())
            next.host = "account@host"
            next.helper = HelperChat(terminal: 2, session: "conversation", endpoint: .local)
            let question = HelperChat.Question(id: "prompt", header: "Permission", text: "Original command", secret: false,
                options: [.init(id: "1", label: "Yes", detail: nil), .init(id: "2", label: "No", detail: nil)],
                multiple: false, custom: false, blocks: nil)
            let prompt = HelperChat.Interaction(id: "prompt:Permission", key: nil, approval: false, blocking: true,
                questions: [question], turn: nil, record: nil)
            // The helper's first native prompt precedes history and agent identification.
            chat.receiveHelper(.interaction(prompt), session: next)
            XCTAssertTrue(next.retiredInteraction)
            XCTAssertTrue(next.approvals.isEmpty)
            XCTAssertNotNil(next.terminalAttention)
            next.agentID = "claude"; next.sessionID = "conversation"
            chat.restoreRemotePresentation(next)
            XCTAssertEqual(next.draft, "Unsent reconnect draft λ")
            chat.receiveHelper(.interaction(prompt), session: next)
            XCTAssertTrue(next.approvals.isEmpty)
            chat.receiveHelper(.interaction(.init(id: prompt.id, key: nil, approval: false, blocking: true,
                questions: [], turn: nil, record: nil)), session: next)
            XCTAssertFalse(next.retiredInteraction)
            chat.receiveHelper(.interaction(prompt), session: next)
            XCTAssertEqual(next.approvals.filter(\.pending).count, 1, "The next native request regains its own authority")
            next.resetConversation()
            XCTAssertFalse(next.retiredInteraction, "A new conversation must not inherit retired requests")
            chat.close(next.id)
        }
    }

    func testProvisionalRemoteDraftFollowsVerifiedProcessToNewSurface() {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        // The same agent process (no conversation yet), seen again through a new SSH connection.
        func remote(_ session: ChatSession) {
            session.host = "account@host"
            session.binding = .init(session: "", transcript: nil, pid: 10, start: [10, 0], executable: "/bin/codex")
        }
        let old = chat.session(for: UUID()); remote(old)
        chat.chooseChat(true, session: old)
        old.drafts.edit(text: "first prompt, never sent", selection: NSRange(location: 6, length: 3))
        let draft = old.drafts.current, scope = old.drafts.scope
        chat.close(old.id)
        let next = chat.session(for: UUID()); remote(next)
        defer { chat.close(next.id) }
        chat.restoreRemotePresentation(next)
        XCTAssertTrue(next.showChat); XCTAssertNil(next.sessionID)
        XCTAssertEqual(next.drafts.scope, scope)
        XCTAssertEqual(next.drafts.current, draft)
        XCTAssertFalse(next.active, "Restored presentation grants no input authority")
        XCTAssertNil(next.submissionID); XCTAssertTrue(next.queuedMessages.isEmpty)
    }

    func testVerifiedReconnectKeepsReplacementSavedDraftSelected() throws {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        // The same agent process (no conversation yet), seen again through a new SSH connection.
        func remote(_ session: ChatSession) {
            session.host = "account@host"
            session.binding = .init(session: "", transcript: nil, pid: 10, start: [10, 0], executable: "/bin/codex")
        }
        let old = chat.session(for: UUID()); remote(old)
        chat.chooseChat(true, session: old)
        old.drafts.edit(text: "Retained draft")
        let scope = old.drafts.scope
        chat.close(old.id)
        let next = chat.session(for: UUID()); remote(next)
        defer { chat.close(next.id) }
        next.drafts.edit(text: "Replacement draft"); next.drafts.keep()
        let selected = try XCTUnwrap(next.drafts.saved.first).id
        next.drafts.select(selected)
        chat.restoreRemotePresentation(next)
        XCTAssertEqual(next.drafts.scope, scope)
        XCTAssertEqual(next.drafts.selected, selected)
        XCTAssertEqual(next.draft, "Replacement draft")
        XCTAssertEqual(next.drafts.bucket.working.text, "Retained draft")
        XCTAssertFalse(next.active)
        XCTAssertTrue(next.queuedMessages.isEmpty)
    }

    func testRealCodexAttachesBeforeFirstPromptWithoutHooksAndResumesHistory() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        let fixture = try CodexEndpointFixture(prefix: "dispatch-discovery-e2e-", delay: 0.05, hooks: false)
        let state = fixture.state
        var passed = false
        defer { fixture.stop(removeState: passed) }
        try await fixture.start(timeout: .seconds(15))
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("codex-home/hooks.json").path))
        let runtime = TerminalRuntime.shared, controller = AppDelegate()
        let previousChat = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true); runtime.workspace = controller.workspace
        runtime.start(preferences: Preferences())
        let workspace = controller.workspace
        workspace.defaultDirectory = state.appendingPathComponent("work").path
        workspace.onCloseTabs = { runtime.close($0) }; workspace.newSpace()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentView = nil; runtime.stop(); runtime.chat = previousChat }
        func start(resume: String? = nil) async throws -> (TerminalView, ChatSession) {
            let id = workspace.activeTab!.id
            try await eventually {
                runtime.views[id].map { $0.surface != nil && !TerminalTestSupport.screen(terminal: $0).isEmpty } == true
            }
            let terminal = runtime.views[id]!
            TerminalTestSupport.send(CodexTestSupport.command(state: state, binary: fixture.binary, resume: resume), to: terminal)
            let session = runtime.chat.session(for: id)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Codex discovery: \(session.status ?? "no status")\n\(TerminalTestSupport.screen(terminal: terminal))") {
                session.active
            }
            return (terminal, session)
        }
        func requests() -> Int { (try? CodexTestSupport.conversationRequests(in: state).count) ?? 0 }
        let (first, a) = try await start()
        let originalSurface = first.surface
        XCTAssertTrue(a.turns.isEmpty)
        workspace.newTab()
        let (_, b) = try await start()
        XCTAssertTrue(b.turns.isEmpty); XCTAssertEqual(requests(), 0, "Both sessions must attach before any model request")
        XCTAssertNotEqual(a.process, b.process)
        runtime.chat.chooseChat(true, session: b)
        b.draft = "second owns its transcript"; runtime.chat.submit(b)
        XCTAssertTrue(b.busy)
        try await eventually { !b.busy && b.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: second owns its transcript" } }
        // Newer private servers publish the idle client's own thread before its first turn.
        XCTAssertNotNil(b.sessionID); XCTAssertNotEqual(a.sessionID, b.sessionID, "An idle process must not adopt another process's same-directory rollout")
        XCTAssertTrue(a.turns.isEmpty)
        workspace.selectTab(a.id); runtime.chat.chooseChat(true, session: a)
        a.draft = "first line\nsecond line"; runtime.chat.submit(a)
        XCTAssertTrue(a.busy)
        try await eventually { !a.busy && a.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: first line\nsecond line" } }
        let savedID = try XCTUnwrap(a.sessionID), oldProcess = try XCTUnwrap(a.process)
        XCTAssertNotEqual(savedID, b.sessionID)
        XCTAssertEqual(a.turns.flatMap(\.items).filter { $0.kind == .user }.count, 1)
        runtime.chat.chooseChat(false, session: a)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(a.showChat, "Discovery polling must remember manual view choices")
        a.draft = "/quit"; runtime.chat.submit(a)
        try await eventually { !a.active && !oldProcess.alive }
        XCTAssertTrue(first.surface === originalSurface)
        let refused = try await XCTUnwrap(a.helper).refuses("must not reach shell", conversation: savedID)
        XCTAssertTrue(refused)
        XCTAssertFalse(a.turns.isEmpty)
        XCTAssertTrue(runtime.chat.canEnterChat(a), "Retained history remains readable after exit")
        // A second client or an automated shell command can launch a fresh
        // agent while this pane is displaying the retained conversation.
        runtime.chat.chooseChat(true, session: a)
        a.draft = "Draft from the retained conversation"
        let retainedDraftScope = a.drafts.scope
        let (_, replacement) = try await start()
        XCTAssertTrue(replacement === a)
        XCTAssertNotEqual(replacement.sessionID, savedID)
        XCTAssertTrue(replacement.showChat, "Replacing the agent must preserve the selected view; startup menus remain an explicit Terminal action")
        XCTAssertTrue(replacement.draft.isEmpty, "A replacement conversation starts with its own draft")
        XCTAssertTrue(replacement.drafts.recoverable.contains(retainedDraftScope))
        XCTAssertEqual(replacement.drafts.repository.buckets[retainedDraftScope]?.working.text, "Draft from the retained conversation")
        let beforeResume = requests()
        workspace.newTab()
        let (_, resumed) = try await start(resume: savedID)
        try await eventually { resumed.sessionID == savedID && !resumed.loadingHistory && !resumed.turns.isEmpty }
        XCTAssertEqual(requests(), beforeResume, "Loading resumed history must not send a new model request")
        XCTAssertTrue(resumed.showChat)
        XCTAssertEqual(resumed.draft, "Draft from the retained conversation", "Resuming the original conversation restores its draft")
        XCTAssertFalse(resumed.busy, "Historical starts/completions must leave a resumed idle conversation ready")
        XCTAssertTrue(resumed.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: first line\nsecond line" })
        XCTAssertTrue(b.process?.alive == true)
        resumed.draft = "tool check"; runtime.chat.submit(resumed)
        try await eventually { !resumed.busy && resumed.turns.flatMap(\.items).contains { $0.kind == .tool && $0.output.contains("DISPATCH_LOCAL_TOOL_OK") } }
        XCTAssertEqual(resumed.sessionID, savedID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("hooks.jsonl").path))
        passed = testRun?.failureCount == 0
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        try await TestSupport.eventually(timeout: .seconds(15), file: file, line: line,
                                         diagnostic: "Discovery condition timed out", condition)
    }
}
