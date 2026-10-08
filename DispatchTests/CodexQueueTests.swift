import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class CodexQueueTests: XCTestCase {
    /// A row of the helper's queue (chat.queue / queue.list), as the helper sends it.
    private func entry(_ id: String, text: String, editable: Bool = true) throws -> HelperChat.Queued {
        try JSONDecoder().decode(HelperChat.Queued.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "mode": "prompt", "revision": 1, "preview": [["kind": "text", "text": text]],
            "editable": editable, "editing": false, "paused": NSNull(), "error": NSNull()]))
    }

    /// Keeps app-owned pending rows from draining during these local state checks.
    private func queueHeld(_ chat: ChatCoordinator, _ session: ChatSession) {
        session.queueBusy = true; chat.queue(session); session.queueBusy = false
    }

    private func helperSession(_ chat: ChatCoordinator) throws -> ChatSession {
        let session = chat.session(for: UUID()); session.active = true; session.busy = true
        session.process = try XCTUnwrap(AgentProcess.capture(getpid()))
        // Terminal 0 belongs to no helper terminal: these cases only reach the app's own queue state.
        session.helper = HelperChat(terminal: 0)
        return session
    }

    func testNativeSnapshotsPreserveIdentityOrderAndDrafts() throws {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = try helperSession(chat); session.sessionID = "thread"
        session.draft = "local"; queueHeld(chat, session)
        let local = try XCTUnwrap(session.queuedMessages.first)
        XCTAssertNotNil(local.delivery)
        let first = try entry("one", text: "native first")
        let second = try entry("two", text: "terminal")
        chat.receiveHelperQueue([first, second], session: session)
        XCTAssertEqual(session.queuedMessages.map(\.text), ["native first", "terminal", "local"])
        XCTAssertEqual(session.queuedMessages.last?.id, local.id)
        XCTAssertEqual(session.queuedMessages.last?.delivery?.id, local.delivery?.id)
        XCTAssertNil(session.queuedMessages.last?.native)
        let firstID = session.queuedMessages[0].id, secondID = session.queuedMessages[1].id
        chat.receiveHelperQueue([second, first], session: session)
        XCTAssertEqual(session.queuedMessages.map(\.id), [secondID, firstID, local.id])
        XCTAssertFalse(chat.canReorderQueue(session))
        chat.editQueued(secondID, in: session); session.draft = "unfinished edit"
        chat.receiveHelperQueue([first], session: session)
        XCTAssertEqual(session.draft, "unfinished edit")
        XCTAssertNil(session.editingQueuedID)
        XCTAssertEqual(session.queuedMessages.map(\.text), ["native first", "local"])
        XCTAssertEqual(session.queuedMessages.last?.delivery?.id, local.delivery?.id)
        session.resetConversation()
        XCTAssertEqual(session.queuedMessages.map(\.id), [local.id])
        XCTAssertEqual(session.queuedMessages.first?.pause, .destinationChanged)
        XCTAssertEqual(session.queuedMessages.first?.delivery?.id, local.delivery?.id)
        XCTAssertEqual(session.draft, "unfinished edit")
    }

    func testDisconnectedNativeQueueNeverFallsBackToTerminalDelivery() throws {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = try helperSession(chat); session.sessionID = "thread"; session.busy = false; session.showChat = true
        chat.receiveHelperQueue([try entry("one", text: "native")], session: session)
        // The helper connection went away.
        session.helper = nil
        chat.drainQueue(session)
        chat.sendNow(session, queuedID: session.queuedMessages[0].id)
        XCTAssertNil(session.submissionID)
        XCTAssertEqual(session.queuedMessages.map(\.text), ["native"])
        XCTAssertNotNil(session.queuedMessages[0].native)
        XCTAssertFalse(chat.canReorderQueue(session))
    }

    func testLocalReorderPreservesMessagesDraftsAndPauseState() throws {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = try helperSession(chat)
        for text in ["one", "two", "three"] { session.draft = text; queueHeld(chat, session) }
        let original = session.queuedMessages, ids = original.map(\.id)
        session.draft = "unfinished composer"; session.stopQueue()
        XCTAssertTrue(chat.moveQueued(ids[0], to: ids[2], in: session, expectedOrder: ids))
        XCTAssertEqual(session.queuedMessages.map(\.id), [ids[1], ids[2], ids[0]])
        chat.moveQueued(ids[0], by: -1, in: session)
        XCTAssertEqual(session.queuedMessages.map(\.id), [ids[1], ids[0], ids[2]])
        XCTAssertEqual(session.queuedMessages.map { $0.delivery?.id }, [original[1].delivery?.id, original[0].delivery?.id, original[2].delivery?.id])
        XCTAssertTrue(session.queuedMessages.allSatisfy { $0.pause == .stopped })
        XCTAssertEqual(session.draft, "unfinished composer")
        chat.moveQueued(ids[1], by: -1, in: session)
        XCTAssertEqual(session.queuedMessages.map(\.id), [ids[1], ids[0], ids[2]])
    }

    func testReorderRejectsStaleDragsAndInFlightOrMixedQueues() throws {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = try helperSession(chat)
        for text in ["one", "two"] { session.draft = text; queueHeld(chat, session) }
        let ids = session.queuedMessages.map(\.id)
        session.draft = "three"; queueHeld(chat, session)
        session.stopQueue()
        XCTAssertFalse(chat.moveQueued(ids[0], to: ids[1], in: session, expectedOrder: ids))
        session.queuedSubmissionID = ids[0]
        XCTAssertFalse(chat.moveQueued(ids[0], to: ids[1], in: session))
        session.queuedSubmissionID = nil
        chat.editQueued(ids[0], in: session)
        XCTAssertFalse(chat.canReorderQueue(session))
        chat.cancelQueuedEdit(session)
        session.queuedMessages[0].native = try entry("server", text: "one")
        XCTAssertFalse(chat.canReorderQueue(session), "Native entries cannot be moved across local commands awaiting delivery")
        XCTAssertEqual(session.queuedMessages.prefix(2).map(\.id), ids)
    }

    func testAttachmentsAndMentionsArePreservedAndCannotBeEditedAsPlainText() throws {
        let preview: [[String: Any]] = [["kind": "text", "text": "look"], ["kind": "attachment", "type": "localImage"]]
        let entry = try JSONDecoder().decode(HelperChat.Queued.self, from: JSONSerialization.data(withJSONObject: [
            "id": "one", "mode": "prompt", "revision": 1, "preview": preview,
            "editable": false, "editing": false, "paused": NSNull(), "error": NSNull()]))
        XCTAssertFalse(entry.editable)
        XCTAssertEqual(entry.text, "look\n[localImage]")
        var row = ChatQueuedMessage(text: entry.text, process: nil); row.native = entry
        XCTAssertFalse(row.editable)
        XCTAssertThrowsError(try JSONDecoder().decode(HelperChat.Queued.self, from: Data(#"{"id":"one"}"#.utf8)))
    }

    func testFailedSteerRecoveryKeepsTheComposerAndOriginalConversation() throws {
        let drafts = ChatDraftCollection(repository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        drafts.bind(host: "local", agent: "codex", conversation: "first")
        drafts.edit(text: "composer draft")
        let recovery = try XCTUnwrap(drafts.prepareRecovery(ChatDraft(text: "claimed queue entry")))
        XCTAssertEqual(drafts.current.text, "composer draft")
        drafts.bind(host: "local", agent: "codex", conversation: "second")
        drafts.edit(text: "second conversation")
        drafts.finish(recovery, success: false)
        XCTAssertEqual(drafts.current.text, "second conversation")
        drafts.bind(host: "local", agent: "codex", conversation: "first")
        XCTAssertEqual(drafts.current.text, "composer draft")
        XCTAssertEqual(drafts.saved.map(\.text), ["claimed queue entry"])
    }

    func testRealCodexQueueSynchronizesEditsDeletesInterruptAndResume() async throws {
        try await exerciseQueue(native: false)
    }

    func testRealCodexNativeQueueSynchronizesEditsDeletesInterruptAndResume() async throws {
        try await exerciseQueue(native: true)
    }

    private func exerciseQueue(native: Bool) async throws {
        let fixture = try CodexEndpointFixture(prefix: "dispatch-native-queue-", delay: 0.04, hooks: false)
        var passed = false
        defer { fixture.stop(removeState: passed) }
        try await fixture.start(timeout: .seconds(15))
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let id = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { runtime.views[id].map { $0.surface != nil && !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let terminal = try XCTUnwrap(runtime.views[id])
        TerminalTestSupport.send(CodexTestSupport.command(state: fixture.state, binary: fixture.binary) + " --dispatch", to: terminal)
        let session = runtime.chat.session(for: id)
        try await TestSupport.eventually(timeout: .seconds(15)) { session.active && AgentModelMenu.containsModel(TerminalTestSupport.screen(terminal: terminal), slug: "dispatch-fixture", name: "Dispatch fixture") }
        runtime.chat.chooseChat(true, session: session)
        session.draft = "FIXTURE_BARRIER_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + " hold queue test"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "Queue error: \(session.queueError ?? "none"); native=\(session.helperNativeQueue) busy=\(session.busy) thread=\(session.sessionID ?? "none") turn=\(session.activeTurnID ?? "none") blocked=\(session.inputBlocked) submitting=\(session.submissionID != nil) ack=\(session.awaitingPromptAck)") { session.helperNativeQueue && runtime.chat.canInterrupt(session) }
        let helper = try XCTUnwrap(session.helper)
        let external = HelperChat(terminal: helper.route.terminal, session: helper.route.session, endpoint: helper.endpoint)
        defer { external.close() }
        func enqueue(_ text: String) async throws {
            if native {
                var input = HelperChat.Input(external.route); input.text = text; input.mode = "prompt"
                let _: HelperChat.Queued = try await external.call("queue.add", input: input)
            } else { session.draft = text; runtime.chat.queue(session) }
        }
        for text in ["queue first", "queue second"] { try await enqueue(text) }
        try await TestSupport.eventually(timeout: .seconds(10)) { session.queuedMessages.count == 2 && session.queuedMessages.allSatisfy { ($0.native != nil) == native } && !session.queueBusy }
        let first = session.queuedMessages[0].id, second = session.queuedMessages[1].id
        runtime.chat.editQueued(second, in: session); session.draft = "edited second"; runtime.chat.queue(session)
        try await TestSupport.eventually(timeout: .seconds(10)) { session.queuedMessages.last?.text == "edited second" && !session.queueBusy }
        XCTAssertEqual(session.draft, "")
        runtime.chat.removeQueued(first, from: session)
        try await TestSupport.eventually(timeout: .seconds(10)) { session.queuedMessages.count == 1 && !session.queueBusy }

        // Reorder within the same owner. Mixed queues remain explicitly non-reorderable.
        try await enqueue("external queued message")
        try await TestSupport.eventually(timeout: .seconds(10)) { session.queuedMessages.map(\.text) == ["edited second", "external queued message"] }
        XCTAssertTrue(runtime.chat.moveQueued(try XCTUnwrap(session.queuedMessages.last?.id), to: second, in: session))
        try await TestSupport.eventually(timeout: .seconds(10)) {
            session.queuedMessages.map(\.text) == ["external queued message", "edited second"] && !session.queueBusy
        }
        // Let the queue's 0.2-second row transition finish before capturing pixels.
        try await Task.sleep(for: .milliseconds(350))
        _ = try await PresentationTestSupport.capture(app.window, named: "queue-reordering", in: "chat-queue-validation")
        XCTAssertTrue(runtime.chat.interrupt(session))
        try await TestSupport.eventually(timeout: .seconds(10)) { !session.busy && session.interruptionID == nil }
        XCTAssertEqual(session.queuedMessages.count, 2)
        runtime.chat.resumeQueue(session)
        try await TestSupport.eventually(timeout: .seconds(20)) { session.queuedMessages.isEmpty && !session.busy && !session.queueBusy }
        let requests = try CodexTestSupport.conversationRequests(in: fixture.state)
        func prompt(_ request: [String: Any]) -> String? {
            let body = request["body"] as? [String: Any]
            let input = body?["input"] as? [[String: Any]]
            let user = input?.last { $0["role"] as? String == "user" }
            let content = user?["content"] as? [[String: Any]]
            return content?.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        XCTAssertEqual(requests.filter { prompt($0) == "edited second" }.count, 1)
        XCTAssertEqual(requests.filter { prompt($0) == "external queued message" }.count, 1)
        XCTAssertEqual(requests.compactMap(prompt).filter { ["external queued message", "edited second"].contains($0) }, ["external queued message", "edited second"])

        let barrier = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        session.draft = "FIXTURE_BARRIER_" + barrier + " hold for steer"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(10)) {
            runtime.chat.canInterrupt(session) && FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("barriers/\(barrier)/accepted.json").path)
        }
        try await enqueue("steer from native queue")
        try await TestSupport.eventually(timeout: .seconds(10)) { session.queuedMessages.count == 1 && (session.queuedMessages[0].native != nil) == native && !session.queueBusy }
        runtime.chat.sendNow(session, queuedID: try XCTUnwrap(session.queuedMessages.first?.id))
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: session.submissionFailure ?? "Steer did not remove its native entry") {
            session.queuedMessages.isEmpty && !session.queueBusy
        }
        XCTAssertNil(session.submissionFailure)
        try Data().write(to: fixture.state.appendingPathComponent("barriers/\(barrier)/release"))
        try await TestSupport.eventually(timeout: .seconds(15)) {
            !session.busy && session.turns.flatMap(\.items).contains { $0.kind == .user && $0.text == "steer from native queue" }
        }
        XCTAssertEqual(session.turns.flatMap(\.items).filter { $0.kind == .user && $0.text == "steer from native queue" }.count, 1)

        // Stop keeps the entry with its producer, paused, and preserves the unfinished draft.
        let stopBarrier = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        session.draft = "FIXTURE_BARRIER_" + stopBarrier + " hold for terminal stop"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(10)) {
            session.busy && !session.awaitingPromptAck && session.submissionID == nil
                && FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("barriers/\(stopBarrier)/accepted.json").path)
        }
        try await enqueue("keep queued after terminal stop")
        try await TestSupport.eventually(timeout: .seconds(10)) { session.queuedMessages.count == 1 && (session.queuedMessages[0].native != nil) == native && !session.queueBusy }
        session.draft = "keep this unfinished draft"
        XCTAssertTrue(runtime.chat.canInterrupt(session))
        XCTAssertTrue(runtime.chat.interrupt(session))
        XCTAssertFalse(runtime.chat.interrupt(session), "A pending Stop must not send a second Ctrl+C")
        try await TestSupport.eventually(timeout: .seconds(10)) { !session.busy && session.interruptionID == nil }
        XCTAssertNil(session.submissionFailure)
        XCTAssertTrue(session.active, "Ctrl+C should stop the turn without exiting Codex")
        XCTAssertEqual(session.draft, "keep this unfinished draft")
        XCTAssertEqual(session.queuedMessages.map(\.text), ["keep queued after terminal stop"])
        XCTAssertEqual(session.queuedMessages.first?.pause, .stopped)
        passed = testRun?.failureCount == 0
    }
}
