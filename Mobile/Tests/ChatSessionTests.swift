import Foundation
import XCTest
@testable import DispatchMobile

/// `MobileChatSession` against a scripted helper replaying the real helper's recorded pages (Fixtures/Chat).
@MainActor
final class ChatSessionTests: XCTestCase {
    private let conversation = "00000000-0000-4000-8000-000000000201"

    /// Opens the session: `chat.open`, the pending history with its state, then the page.
    private func opened(_ helper: ScriptedHelper, records: [[String: Any]], earlier: String? = nil, state: [String: Any]? = nil,
                        key: String = "claude", session: String? = nil,
                        outbox: ChatOutbox = ChatOutbox(store: ChatOutboxMemoryStore())) async throws -> MobileChatSession {
        let chat = MobileChatSession.scripted(helper, outbox: outbox)
        try await TestSupport.eventually { helper.subscription("chat.open") != nil }
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        let name = session ?? conversation
        helper.notify(id, "chat.history", ChatFixture.history(session: name, key: key, state: state ?? ChatFixture.state(busy: false), pending: true))
        helper.notify(id, "chat.history", ChatFixture.history(session: name, key: key, records: records, earlier: earlier))
        try await TestSupport.eventually { chat.phase == .verified && !chat.loadingHistory }
        return chat
    }

    private func script(_ helper: ScriptedHelper, _ extra: @escaping (ScriptedHelper.Request) -> ScriptedHelper.Reply? = { _ in nil }) {
        helper.script { request in
            if let reply = extra(request) { return reply }
            switch request.method {
            case "chat.open": return .open
            case "queue.list": return .result([Any]())
            default: return .result(NSNull())
            }
        }
    }

    func testOpenPagesTheRealClaudeTranscriptIntoBubblesAndStepCaptions() async throws {
        let helper = ScriptedHelper()
        script(helper)
        let chat = try await opened(helper, records: ChatFixture.records("claude-thread"))
        let rows = chat.transcript.rows
        XCTAssertEqual(rows.map(\.kind.label), ["user", "agent", "user", "agent"])
        XCTAssertEqual(rows.map { String($0.item.text.prefix(12)) }, ["Make billing", "Stripe retri", "Also cover i", "Right, the i"])
        XCTAssertEqual(rows.compactMap(\.kind.summary?.caption), ["5 steps · 1m 26s", "4 steps · 52s"], "M4a's captions")
        XCTAssertEqual(chat.agentKey, "claude")
        XCTAssertEqual(chat.model, "fable-5.1")
        XCTAssertEqual(chat.effort, "high")
        XCTAssertFalse(chat.working)
        XCTAssertEqual(helper.requests("chat.open").first?.params["terminal"] as? UInt64, 7)
        XCTAssertNil(helper.requests("chat.open").first?.params["session"], "The open names no conversation: discovery's binding decides")
    }

    func testRealCodexTranscriptsKeepTheirToolAsAStep() async throws {
        for name in ["codex-formatting-0.154.0", "codex-observed-0.153.2"] {
            let helper = ScriptedHelper()
            script(helper)
            let chat = try await opened(helper, records: ChatFixture.records(name), key: "codex")
            let rows = chat.transcript.rows
            XCTAssertEqual(rows.first?.kind.label, "user", name)
            XCTAssertEqual(rows.last?.kind.label, "agent", name)
            XCTAssertEqual(rows.last?.kind.summary?.steps.count, 1, name)
            XCTAssertTrue(chat.transcript.turns.allSatisfy { $0.ended != nil }, name)
        }
    }

    func testAnEarlierPagePrependsInOrder() async throws {
        let records = try ChatFixture.records("claude-thread")
        let split = try XCTUnwrap(records.firstIndex { $0["turn"] as? String == "p2" })
        let helper = ScriptedHelper()
        script(helper) { request in
            request.method == "chat.page" ? .result(["records": Array(records[..<split]), "earlier": NSNull()]) : nil
        }
        let chat = try await opened(helper, records: Array(records[split...]), earlier: "cursor-1")
        XCTAssertEqual(chat.transcript.rows.count, 2)
        XCTAssertTrue(chat.hasEarlier)
        chat.loadEarlier()
        try await TestSupport.eventually { !chat.hasEarlier && !chat.loadingEarlier }
        XCTAssertEqual(helper.requests("chat.page").first?.params["earlier"] as? String, "cursor-1")
        XCTAssertEqual(helper.requests("chat.page").first?.params["session"] as? String, conversation)
        XCTAssertEqual(chat.transcript.rows.map { String($0.item.text.prefix(12)) }, ["Make billing", "Stripe retri", "Also cover i", "Right, the i"])
    }

    /// From send to the end of the turn the thread never shows the prompt twice, never loses it, and never shows the
    /// agent idle in between (frame-level: every state the session passes through is checked).
    func testAPromptStaysOneBubbleAndWorkingAcrossTheTurnBoundary() async throws {
        let helper = ScriptedHelper()
        script(helper) { request in request.method == "chat.send" ? .result(ChatFixture.sent()) : nil }
        let chat = try await opened(helper, records: ChatFixture.records("claude-thread"))
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        let text = "Then run the full suite and paste the summary"
        func check(_ step: String, working: Bool) {
            let prompts = chat.transcript.rows.filter { $0.item.text == text }.count + (chat.optimisticPrompt?.text == text ? 1 : 0)
            XCTAssertEqual(prompts, 1, step)
            XCTAssertEqual(chat.working, working, step)
        }
        chat.drafts.edit(text: text)
        XCTAssertEqual(chat.route(steer: false), .prompt)
        chat.send()
        check("sent", working: true)
        XCTAssertEqual(chat.drafts.current.text, "", "The composer clears as the bubble appears")
        try await TestSupport.eventually { helper.requests("chat.send").count == 1 && !chat.sending }
        let send = try XCTUnwrap(helper.requests("chat.send").first)
        XCTAssertEqual(send.params["mode"] as? String, "prompt")
        XCTAssertEqual(send.params["text"] as? String, text)
        XCTAssertEqual(send.params["session"] as? String, conversation)
        check("accepted", working: true)
        let pendingID = try XCTUnwrap(chat.optimisticPrompt?.id)
        // The helper's state can still say idle before the turn starts: the prompt keeps the agent working.
        helper.notify(id, "chat.state", ["terminal": 7, "session": conversation, "state": ChatFixture.state(busy: false)])
        try await Task.sleep(for: .milliseconds(150))
        check("stale idle state", working: true)
        helper.notify(id, "chat.records", ["terminal": 7, "session": conversation, "records": [
            ChatFixture.record("p3:started", "turn_started", turn: "p3", time: 946_719_200_000),
            ChatFixture.record("user-p3", "user", turn: "p3", text: text, time: 946_719_200_000)]])
        try await TestSupport.eventually { chat.optimisticPrompt == nil }
        check("acknowledged", working: true)
        XCTAssertEqual(chat.transcript.rows.last?.id, pendingID, "The confirmed record keeps the bubble's identity")
        helper.notify(id, "chat.state", ["terminal": 7, "session": conversation, "state": ChatFixture.state(busy: true, activity: "working")])
        try await TestSupport.eventually { chat.busy }
        check("busy", working: true)
        helper.notify(id, "chat.records", ["terminal": 7, "session": conversation, "records": [
            ChatFixture.record("claude-f3-0", "assistant", turn: "p3", text: "Suite green: 214 passed.", time: 946_719_230_000),
            ChatFixture.record("f3:ended", "turn_ended", turn: "p3", time: 946_719_230_000)]])
        try await TestSupport.eventually { chat.transcript.rows.last?.kind.summary != nil }
        helper.notify(id, "chat.state", ["terminal": 7, "session": conversation, "state": ChatFixture.state(busy: false)])
        try await TestSupport.eventually { !chat.working }
        check("finished", working: false)
        XCTAssertEqual(chat.transcript.rows.last?.kind.summary?.caption, "30s")
    }

    func testAnUncertainSendIsNeverRetriedAndKeepsTheDraft() async throws {
        let helper = ScriptedHelper()
        script(helper) { request in
            request.method == "chat.send" ? .result(ChatFixture.sent(written: false, mayHaveSent: true, reason: "Delivery could not be confirmed.")) : nil
        }
        let chat = try await opened(helper, records: [])
        chat.drafts.edit(text: "deploy it")
        chat.send()
        try await TestSupport.eventually { chat.failure != nil }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(helper.requests("chat.send").count, 1)
        XCTAssertEqual(chat.failure, "Delivery could not be confirmed.")
        XCTAssertEqual(chat.drafts.current.text, "deploy it")
        XCTAssertNil(chat.optimisticPrompt)
        XCTAssertFalse(chat.working)
    }

    func testSendingWhileWorkingQueuesAndLongPressSteers() async throws {
        let helper = ScriptedHelper()
        script(helper) { request in
            switch request.method {
            case "queue.add": .result(ChatFixture.queued("held-1", request.params["text"] as! String))
            case "chat.send": .result(ChatFixture.sent())
            default: nil
            }
        }
        let chat = try await opened(helper, records: [], state: ChatFixture.state(busy: true))
        XCTAssertTrue(chat.working)
        chat.drafts.edit(text: "Also cover invoice.paid")
        XCTAssertEqual(chat.route(steer: false), .queue)
        chat.send()
        try await TestSupport.eventually { chat.queue.count == 1 && !chat.queueBusy }
        XCTAssertEqual(helper.requests("queue.add").first?.params["mode"] as? String, "prompt")
        XCTAssertEqual(chat.queue.first?.text, "Also cover invoice.paid")
        chat.drafts.edit(text: "keep it short")
        XCTAssertEqual(chat.route(steer: true), .steer)
        chat.send(steer: true)
        try await TestSupport.eventually { helper.requests("chat.send").count == 1 && !chat.sending }
        XCTAssertEqual(helper.requests("chat.send").first?.params["mode"] as? String, "steer")
        XCTAssertNil(chat.optimisticPrompt, "A steer joins the running turn; it opens no new bubble of its own")
    }

    func testStopSendsChatStop() async throws {
        let helper = ScriptedHelper()
        script(helper) { request in request.method == "chat.stop" ? .result(ChatFixture.sent()) : nil }
        let chat = try await opened(helper, records: [], state: ChatFixture.state(busy: true))
        chat.stop()
        try await TestSupport.eventually { helper.requests("chat.stop").count == 1 && !chat.stopping }
        XCTAssertEqual(helper.requests("chat.stop").first?.params["session"] as? String, conversation)
    }

    func testApprovalChipsComeFromTheAdvertisedOptions() throws {
        func interaction(_ options: [String]) throws -> HelperChat.Interaction {
            try JSONDecoder().decode(HelperChat.Interaction.self, from: JSONSerialization.data(withJSONObject: ChatFixture.approval(options: options)))
        }
        XCTAssertEqual(MobileChatSession.choices(for: try interaction(["Allow", "Deny", "Terminal"])).map(\.label), ["Deny", "Allow"],
                       "Today's hooks: no session-scoped choice, no This session chip")
        let offered = MobileChatSession.choices(for: try interaction(["Allow", "Deny", "Terminal", "Allow for this session"]))
        XCTAssertEqual(offered.map(\.label), ["Deny", "This session", "Allow"])
        XCTAssertEqual(offered.map(\.index), [1, 3, 0])
        let presentation = try interaction(["Allow", "Deny"]).approvalPresentation
        XCTAssertEqual(presentation.text, "Allow the local fixture to print its test marker?")
        XCTAssertEqual(presentation.code, "printf 'DISPATCH_LOCAL_TOOL_OK\\n'")
    }

    func testAnApprovalAnswersItsOwnRequestWithTheChosenOption() async throws {
        let helper = ScriptedHelper()
        script(helper) { request in request.method == "interactions.answer" ? .result(ChatFixture.sent()) : nil }
        let chat = try await opened(helper, records: [])
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        helper.notify(id, "interaction.opened", ["terminal": 7, "session": conversation,
                                                 "interaction": ChatFixture.approval(options: ["Allow", "Deny", "Terminal", "Allow for this session"])])
        try await TestSupport.eventually { chat.approvals.count == 1 }
        XCTAssertTrue(chat.waitingForUser)
        XCTAssertFalse(chat.working, "Needs you is not working")
        let approval = try XCTUnwrap(chat.approvals.first)
        let session = try XCTUnwrap(MobileChatSession.choices(for: approval.interaction).first { $0.role == .session })
        chat.answer(approval, with: session)
        try await TestSupport.eventually { helper.requests("interactions.answer").count == 1 }
        let answer = try XCTUnwrap(helper.requests("interactions.answer").first)
        XCTAssertEqual(answer.params["interaction"] as? String, "approval-1")
        XCTAssertEqual((answer.params["answers"] as? [String: Any])?["approval"] as? [UInt64], [3])
        XCTAssertFalse(chat.waitingForUser)
        XCTAssertEqual(chat.approvals.first?.chosen?.label, "This session")
        // A second tap cannot answer again.
        chat.answer(approval, with: MobileChatSession.choices(for: approval.interaction)[0])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(helper.requests("interactions.answer").count, 1)
    }

    func testARequestFromALostLinkIsRetiredNotAnswered() async throws {
        let helper = ScriptedHelper()
        script(helper)
        let chat = try await opened(helper, records: [])
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        helper.notify(id, "interaction.opened", ["terminal": 7, "session": conversation, "interaction": ChatFixture.approval()])
        try await TestSupport.eventually { chat.approvals.count == 1 }
        chat.update(link: .reconnecting(attempt: 1, since: Date()), client: nil)
        XCTAssertEqual(chat.phase, .detached)
        let approval = try XCTUnwrap(chat.approvals.first)
        XCTAssertEqual(approval.pending.decision, .expired)
        chat.answer(approval, with: ApprovalChoice(role: .allow, index: 0))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(helper.requests("interactions.answer").isEmpty)
        XCTAssertFalse(chat.waitingForUser)
    }

    func testAQuestionFormAnswersByOptionIndex() async throws {
        let helper = ScriptedHelper()
        script(helper) { request in request.method == "interactions.answer" ? .result(ChatFixture.sent()) : nil }
        let chat = try await opened(helper, records: [])
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        helper.notify(id, "interaction.opened", ["terminal": 7, "session": conversation, "interaction": [
            "id": "question-1", "key": NSNull(), "approval": false, "blocking": true, "turn": NSNull(), "record": NSNull(),
            "questions": [["id": "q1", "header": "Runner", "text": "Which runner should the e2e use?", "secret": false,
                           "multiple": false, "custom": false, "blocks": NSNull(),
                           "options": [["id": "a", "label": "headed", "detail": NSNull()], ["id": "b", "label": "headless", "detail": NSNull()]]]]]])
        try await TestSupport.eventually { chat.approvals.count == 1 }
        let form = try XCTUnwrap(chat.approvals.first)
        XCTAssertNotNil(form.pending.questions)
        XCTAssertTrue(MobileChatSession.choices(for: form.interaction).isEmpty, "A question is not an approval")
        let draft = try XCTUnwrap(form.pending.questionDraft)
        draft.select("headless")
        chat.answer(form, answers: draft.answers)
        try await TestSupport.eventually { helper.requests("interactions.answer").count == 1 }
        let answers = helper.requests("interactions.answer").first?.params["answers"] as? [String: Any]
        XCTAssertEqual(answers?["q1"] as? [UInt64], [1])
    }

    func testQueueEditsAddressTheHelpersItemsByRevision() async throws {
        let helper = ScriptedHelper()
        script(helper) { request in request.method == "queue.start" ? .result(ChatFixture.sent()) : nil }
        let chat = try await opened(helper, records: [], state: ChatFixture.state(busy: true))
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        helper.notify(id, "chat.queue", ["terminal": 7, "session": conversation, "error": NSNull(), "items": [
            ChatFixture.queued("held-1", "Also cover invoice.paid", revision: 1),
            ChatFixture.queued("held-2", "Add a unit test", revision: 2),
            ChatFixture.queued("held-3", "Then run the full suite", revision: 3)]])
        try await TestSupport.eventually { chat.queue.count == 3 }
        XCTAssertEqual(chat.queueRows.map(\.id), ["helper:held-1", "helper:held-2", "helper:held-3"], "Rows added elsewhere show too")
        chat.editQueued(chat.queueRows[2], text: "Then run the full suite and paste the summary")
        try await TestSupport.eventually { helper.requests("queue.update").count == 1 && !chat.queueBusy }
        let update = try XCTUnwrap(helper.requests("queue.update").first)
        XCTAssertEqual(update.params["item"] as? String, "held-3")
        XCTAssertEqual(update.params["revision"] as? UInt64, 3)
        XCTAssertEqual(update.params["text"] as? String, "Then run the full suite and paste the summary")
        chat.moveQueued(from: 2, to: 0)
        XCTAssertEqual(chat.queue.map(\.id), ["held-3", "held-1", "held-2"], "The row moves at once")
        try await TestSupport.eventually { helper.requests("queue.reorder").count == 1 && !chat.queueBusy }
        XCTAssertEqual(helper.requests("queue.reorder").first?.params["items"] as? [String], ["held-3", "held-1", "held-2"])
        chat.removeQueued(chat.queueRows[1])
        try await TestSupport.eventually { helper.requests("queue.remove").count == 1 && !chat.queueBusy }
        XCTAssertEqual(helper.requests("queue.remove").first?.params["item"] as? String, "held-1")
        chat.sendQueuedNow(chat.queueRows[0])
        try await TestSupport.eventually { helper.requests("queue.start").count == 1 && !chat.queueBusy }
        XCTAssertEqual(helper.requests("queue.start").first?.params["mode"] as? String, "steer", "Send now interrupts the turn")
    }

    func testAFailedReorderPutsTheRowsBack() async throws {
        let helper = ScriptedHelper()
        script(helper) { request in request.method == "queue.reorder" ? .error(code: "expired", message: "The queued message changed") : nil }
        let chat = try await opened(helper, records: [], state: ChatFixture.state(busy: true))
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        helper.notify(id, "chat.queue", ["terminal": 7, "session": conversation, "error": NSNull(), "items": [
            ChatFixture.queued("held-1", "one"), ChatFixture.queued("held-2", "two")]])
        try await TestSupport.eventually { chat.queue.count == 2 }
        chat.moveQueued(from: 1, to: 0)
        try await TestSupport.eventually { chat.failure != nil }
        XCTAssertEqual(chat.queue.map(\.id), ["held-1", "held-2"])
    }

    func testLosingTheLinkKeepsHistoryAndDraftsAndQueuesTyping() async throws {
        let helper = ScriptedHelper()
        script(helper)
        let outbox = ChatOutbox(store: ChatOutboxMemoryStore())
        let chat = try await opened(helper, records: ChatFixture.records("claude-thread"), outbox: outbox)
        chat.drafts.edit(text: "half typed")
        chat.update(link: .reconnecting(attempt: 1, since: Date()), client: nil)
        XCTAssertEqual(chat.phase, .detached)
        XCTAssertEqual(chat.transcript.rows.count, 4, "The thread stays readable")
        XCTAssertEqual(chat.drafts.current.text, "half typed")
        XCTAssertEqual(chat.route(steer: false), .outbox)
        chat.send()
        XCTAssertEqual(chat.queueItems.map(\.text), ["half typed"])
        XCTAssertEqual(chat.queueItems.first?.conversation, conversation)
        XCTAssertEqual(chat.drafts.current.text, "")
        XCTAssertTrue(helper.requests("chat.send").isEmpty && helper.requests("queue.add").isEmpty)
    }

    func testTheOutboxDrainsIntoTheHelpersQueueOnceTheConversationIsVerifiedAgain() async throws {
        let first = ScriptedHelper()
        script(first)
        let outbox = ChatOutbox(store: ChatOutboxMemoryStore())
        let chat = try await opened(first, records: ChatFixture.records("claude-thread"), outbox: outbox)
        first.close()
        chat.update(link: .reconnecting(attempt: 1, since: Date()), client: nil)
        chat.drafts.edit(text: "Also cover invoice.paid — it has a separate handler.")
        chat.send()
        chat.drafts.edit(text: "Add a unit test for the duplicate-event case.")
        chat.send()
        XCTAssertEqual(chat.queueItems.count, 2)
        // The reconnected host runs a new helper process.
        let second = ScriptedHelper()
        script(second) { request in
            request.method == "queue.add" ? .result(ChatFixture.queued("held-\(request.id)", request.params["text"] as! String)) : nil
        }
        chat.update(link: .connected, client: second.client)
        try await TestSupport.eventually { second.subscription("chat.open") != nil }
        XCTAssertTrue(second.requests("queue.add").isEmpty, "Nothing drains before the conversation is verified")
        let id = try XCTUnwrap(second.subscription("chat.open"))
        second.notify(id, "chat.history", ChatFixture.history(state: ChatFixture.state(busy: false), pending: true))
        try await TestSupport.eventually { chat.queueItems.allSatisfy { $0.helperID != nil } && !chat.queueItems.isEmpty }
        XCTAssertEqual(second.requests.filter { $0.method.hasPrefix("queue.") && $0.method != "queue.list" }.map(\.method),
                       ["queue.hold", "queue.add", "queue.add", "queue.hold"])
        XCTAssertEqual(second.requests("queue.hold").map { $0.params["held"] as? Bool }, [true, false])
        XCTAssertEqual(second.requests("queue.add").map { $0.params["text"] as? String },
                       ["Also cover invoice.paid — it has a separate handler.", "Add a unit test for the duplicate-event case."])
        XCTAssertEqual(chat.queue.count, 2)
        XCTAssertEqual(chat.queueItems.count, 2, "Delivered only when the helper consumes them: the device keeps them meanwhile")
    }

    func testAnUncertainDrainPausesAndIsNotRetried() async throws {
        let outbox = ChatOutbox(store: ChatOutboxMemoryStore())
        let helper = ScriptedHelper()
        script(helper) { request in request.method == "queue.add" ? .error(code: "uncertain", message: "The input may have been typed.") : nil }
        let chat = MobileChatSession.scripted(helper, outbox: outbox, connected: false)
        chat.drafts.edit(text: "run it")
        chat.send()
        chat.update(link: .connected, client: helper.client)
        try await TestSupport.eventually { helper.subscription("chat.open") != nil }
        helper.notify(helper.subscription("chat.open")!, "chat.history", ChatFixture.history(state: ChatFixture.state(busy: false), pending: true))
        helper.notify(helper.subscription("chat.open")!, "chat.history", ChatFixture.history())
        try await TestSupport.eventually { chat.queueItems.first?.pauseReason != nil }
        guard case .uncertain = chat.queueItems.first?.state else { return XCTFail("Expected an uncertain pause") }
        // Another reconnect does not send it again; only the user's resend does.
        chat.update(link: .reconnecting(attempt: 1, since: Date()), client: nil)
        chat.update(link: .connected, client: helper.client)
        try await TestSupport.eventually { helper.requests("chat.open").count == 2 }
        helper.notify(helper.subscription("chat.open")!, "chat.history", ChatFixture.history(state: ChatFixture.state(busy: false), pending: true))
        helper.notify(helper.subscription("chat.open")!, "chat.history", ChatFixture.history())
        try await TestSupport.eventually { chat.phase == .verified }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(helper.requests("queue.add").count, 1)
    }

    func testAMessageTypedForAnotherConversationWaitsForTheUser() async throws {
        let outbox = ChatOutbox(store: ChatOutboxMemoryStore([
            ChatOutboxItem(key: ChatConversationKey(host: UUID(), node: ChatFixture.node), conversation: "older", text: "hi")]))
        let helper = ScriptedHelper()
        script(helper)
        let host = try XCTUnwrap(outbox.items.first?.key.host)
        let chat = MobileChatSession.scripted(helper, host: host, outbox: outbox)
        try await TestSupport.eventually { helper.subscription("chat.open") != nil }
        helper.notify(helper.subscription("chat.open")!, "chat.history", ChatFixture.history(state: ChatFixture.state(busy: false), pending: true))
        helper.notify(helper.subscription("chat.open")!, "chat.history", ChatFixture.history())
        try await TestSupport.eventually { chat.queueItems.first?.pauseReason != nil }
        XCTAssertTrue(helper.requests("queue.add").isEmpty)
    }

    /// A queue file that cannot be read is never written over: nothing more is queued (the composer says why) until
    /// Remove all data, which replaces it.
    func testAnUnreadableQueueFileIsNeverWrittenOver() {
        final class Unreadable: ChatOutboxPersistence {
            var saves = 0
            func load() throws -> [ChatOutboxItem] { throw CocoaError(.fileReadCorruptFile) }
            func save(_ items: [ChatOutboxItem]) throws { saves += 1 }
        }
        let store = Unreadable()
        let outbox = ChatOutbox(store: store)
        XCTAssertNotNil(outbox.error)
        let key = ChatConversationKey(host: UUID(), node: ChatFixture.node)
        XCTAssertFalse(outbox.add(ChatOutboxItem(key: key, conversation: nil, text: "hi")))
        XCTAssertTrue(outbox.items.isEmpty)
        XCTAssertEqual(store.saves, 0, "The unreadable file was written over")
        XCTAssertNotNil(outbox.error, "The composer shows why")
        outbox.removeAll()
        XCTAssertEqual(store.saves, 1)
        XCTAssertTrue(outbox.add(ChatOutboxItem(key: key, conversation: nil, text: "hi")))
    }

    func testAMessageInterruptedWhileDrainingComesBackUncertain() throws {
        let item = ChatOutboxItem(key: ChatConversationKey(host: UUID(), node: ChatFixture.node), conversation: nil, text: "x",
                                  state: .adding)
        let outbox = ChatOutbox(store: ChatOutboxMemoryStore([item]))
        XCTAssertEqual(outbox.items.first?.state, .uncertain(ChatOutbox.interrupted))
    }

    func testAHistoryNamingAnotherProcessIsRefused() async throws {
        let helper = ScriptedHelper()
        script(helper)
        let chat = MobileChatSession.scripted(helper)
        try await TestSupport.eventually { helper.subscription("chat.open") != nil }
        var other = ChatFixture.binding
        other["pid"] = 9999
        helper.notify(helper.subscription("chat.open")!, "chat.history",
                      ChatFixture.history(records: try ChatFixture.records("claude-thread"), binding: other))
        try await TestSupport.eventually { chat.phase != .opening }
        guard case .paused = chat.phase else { return XCTFail("Expected input paused, got \(chat.phase)") }
        XCTAssertTrue(chat.transcript.isEmpty)
        XCTAssertEqual(chat.route(steer: false), .outbox)
    }

    func testTheAgentExitingPausesInputAndKeepsTheThread() async throws {
        let helper = ScriptedHelper()
        script(helper)
        let chat = try await opened(helper, records: ChatFixture.records("claude-thread"), state: ChatFixture.state(busy: true))
        helper.notify(helper.subscription("chat.open")!, "terminal.exit", ["terminal": 7, "status": 0])
        try await TestSupport.eventually { chat.phase != .verified }
        XCTAssertEqual(chat.phase, .paused("Claude Code exited. This transcript is read-only."))
        XCTAssertFalse(chat.working)
        XCTAssertEqual(chat.transcript.rows.count, 4)
    }

    /// Opens on a second helper after a drop with the records and state given; returns that helper.
    private func reconnect(_ chat: MobileChatSession, records: [[String: Any]], busy: Bool,
                           queue: [[String: Any]] = [], extra: @escaping (ScriptedHelper.Request) -> ScriptedHelper.Reply? = { _ in nil }) async throws -> ScriptedHelper {
        let second = ScriptedHelper()
        second.script { request in
            if let reply = extra(request) { return reply }
            switch request.method {
            case "chat.open": return .open
            case "queue.list": return .result(queue)
            case "queue.add": return .result(ChatFixture.queued("new-\(request.id)", request.params["text"] as! String))
            default: return .result(NSNull())
            }
        }
        chat.update(link: .connected, client: second.client)
        try await TestSupport.eventually { second.subscription("chat.open") != nil }
        let id = try XCTUnwrap(second.subscription("chat.open"))
        second.notify(id, "chat.history", ChatFixture.history(state: ChatFixture.state(busy: busy), pending: true))
        second.notify(id, "chat.history", ChatFixture.history(records: records))
        try await TestSupport.eventually { second.requests("queue.list").count == 1 }
        return second
    }

    private func queueTwo(_ helper: ScriptedHelper, _ chat: MobileChatSession) async throws {
        for text in ["Also cover invoice.paid", "Add a unit test"] {
            chat.drafts.edit(text: text)
            XCTAssertEqual(chat.route(steer: false), .queue)
            chat.send()
        }
        try await TestSupport.eventually { chat.queueItems.count == 2 && chat.queueItems.allSatisfy { $0.helperID != nil } }
        XCTAssertEqual(chat.queueRows.map(\.text), ["Also cover invoice.paid", "Add a unit test"])
    }

    private var runningTurn: [[String: Any]] {
        [ChatFixture.record("p1:started", "turn_started", turn: "p1", time: 946_719_000_000),
         ChatFixture.record("user-p1", "user", turn: "p1", text: "Make billing webhook retries idempotent.", time: 946_719_000_000)]
    }

    func testQueuedMessagesGoBackIntoANewHelperWhenTheTurnStillRuns() async throws {
        let first = ScriptedHelper()
        script(first) { request in
            request.method == "queue.add" ? .result(ChatFixture.queued("held-\(request.id)", request.params["text"] as! String)) : nil
        }
        let chat = try await opened(first, records: runningTurn, state: ChatFixture.state(busy: true))
        try await queueTwo(first, chat)
        first.close()
        chat.update(link: .reconnecting(attempt: 1, since: Date()), client: nil)
        XCTAssertEqual(chat.queueRows.count, 2, "The queue stays visible while the link is down")
        // The same turn still runs on the host: the old helper never started on its queue.
        let second = try await reconnect(chat, records: runningTurn, busy: true)
        try await TestSupport.eventually { second.requests("queue.add").count == 2 && chat.queueItems.allSatisfy { $0.helperID?.hasPrefix("new-") == true } }
        XCTAssertEqual(second.requests("queue.add").map { $0.params["text"] as? String }, ["Also cover invoice.paid", "Add a unit test"])
        XCTAssertEqual(second.requests("queue.hold").map { $0.params["held"] as? Bool }, [true, false])
    }

    /// A held queue never starts the agent: a release the helper refuses is tried once more, then the queue says so.
    func testAFailedQueueReleaseIsRetriedAndThenShown() async throws {
        let first = ScriptedHelper()
        script(first) { request in
            request.method == "queue.add" ? .result(ChatFixture.queued("held-\(request.id)", request.params["text"] as! String)) : nil
        }
        let chat = try await opened(first, records: runningTurn, state: ChatFixture.state(busy: true))
        try await queueTwo(first, chat)
        first.close()
        chat.update(link: .reconnecting(attempt: 1, since: Date()), client: nil)
        let second = try await reconnect(chat, records: runningTurn, busy: true) { request in
            request.method == "queue.hold" && request.params["held"] as? Bool == false ? .error(code: "busy", message: "Try again") : nil
        }
        try await TestSupport.eventually { second.requests("queue.hold").count == 3 && chat.queueError != nil }
        XCTAssertEqual(second.requests("queue.hold").map { $0.params["held"] as? Bool }, [true, false, false])
        XCTAssertEqual(second.requests("queue.add").count, 2)
        XCTAssertEqual(chat.failure, chat.queueError, "The thread shows it")
    }

    func testTheHeadOfALostQueueWaitsForTheUserWhenTheHelperMayHaveSentIt() async throws {
        let first = ScriptedHelper()
        script(first) { request in
            request.method == "queue.add" ? .result(ChatFixture.queued("held-\(request.id)", request.params["text"] as! String)) : nil
        }
        let chat = try await opened(first, records: runningTurn, state: ChatFixture.state(busy: true))
        try await queueTwo(first, chat)
        // The turn ends; the old helper may start draining before the link drops.
        let id = try XCTUnwrap(first.subscription("chat.open"))
        first.notify(id, "chat.records", ["terminal": 7, "session": conversation, "records": [
            ChatFixture.record("f1:ended", "turn_ended", turn: "p1", time: 946_719_030_000)]])
        first.notify(id, "chat.state", ["terminal": 7, "session": conversation, "state": ChatFixture.state(busy: false)])
        try await TestSupport.eventually { !chat.working }
        first.close()
        chat.update(link: .reconnecting(attempt: 1, since: Date()), client: nil)
        let second = try await reconnect(chat, records: runningTurn + [ChatFixture.record("f1:ended", "turn_ended", turn: "p1", time: 946_719_030_000)], busy: false)
        try await TestSupport.eventually { second.requests("queue.add").count == 1 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(second.requests("queue.add").map { $0.params["text"] as? String }, ["Add a unit test"],
                       "Only the message behind the head is certainly unsent")
        guard case .uncertain = chat.queueItems.first?.state else { return XCTFail("The head waits for the user") }
        XCTAssertNotNil(chat.queueRows.first?.status)
        // The user's own decision sends it.
        chat.resendQueued(chat.queueRows[0])
        try await TestSupport.eventually { second.requests("queue.add").count == 2 }
    }

    func testAMessageTheTranscriptShowsAsSentIsNotQueuedAgain() async throws {
        let first = ScriptedHelper()
        script(first) { request in
            request.method == "queue.add" ? .result(ChatFixture.queued("held-\(request.id)", request.params["text"] as! String)) : nil
        }
        let chat = try await opened(first, records: runningTurn, state: ChatFixture.state(busy: true))
        try await queueTwo(first, chat)
        first.close()
        chat.update(link: .reconnecting(attempt: 1, since: Date()), client: nil)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let delivered = runningTurn + [
            ChatFixture.record("f1:ended", "turn_ended", turn: "p1", time: now - 2000),
            ChatFixture.record("p2:started", "turn_started", turn: "p2", time: now - 1000),
            ChatFixture.record("user-p2", "user", turn: "p2", text: "Also cover invoice.paid", time: now - 1000)]
        let second = try await reconnect(chat, records: delivered, busy: true)
        try await TestSupport.eventually { chat.queueItems.count == 1 && second.requests("queue.add").count == 1 }
        XCTAssertEqual(second.requests("queue.add").first?.params["text"] as? String, "Add a unit test")
    }

    func testAMessageTheHelperConsumedLeavesTheDevice() async throws {
        let helper = ScriptedHelper()
        script(helper) { request in
            request.method == "queue.add" ? .result(ChatFixture.queued("held-1", request.params["text"] as! String)) : nil
        }
        let chat = try await opened(helper, records: [], state: ChatFixture.state(busy: true))
        chat.drafts.edit(text: "next")
        chat.send()
        try await TestSupport.eventually { chat.queueItems.first?.helperID == "held-1" }
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        helper.notify(id, "chat.queue", ["terminal": 7, "session": conversation, "error": NSNull(), "items": []])
        try await TestSupport.eventually { chat.queueItems.isEmpty }
        XCTAssertTrue(chat.queueRows.isEmpty)
    }

    func testInputWaitsForThePublishedScreenOfItsTerminal() async throws {
        let presence = ChatTerminalPresenceStub()
        presence.publishes = false
        let helper = ScriptedHelper()
        script(helper) { request in request.method == "queue.add" ? .result(ChatFixture.queued("held-1", "hi")) : nil }
        let chat = MobileChatSession.scripted(helper, presence: presence)
        try await TestSupport.eventually { helper.subscription("chat.open") != nil }
        XCTAssertTrue(presence.retained.isEmpty, "Nothing attaches before ownership is verified")
        helper.notify(helper.subscription("chat.open")!, "chat.history", ChatFixture.history(state: ChatFixture.state(busy: false), pending: true))
        helper.notify(helper.subscription("chat.open")!, "chat.history", ChatFixture.history())
        try await TestSupport.eventually { chat.phase == .verified }
        XCTAssertEqual(presence.retained, [chat.key: 7], "A verified conversation keeps its terminal attached")
        XCTAssertFalse(chat.terminalAttached)
        XCTAssertEqual(chat.route(steer: false), .queue, "No screen yet: the message queues instead of failing")
        presence.publishes = true
        XCTAssertEqual(chat.route(steer: false), .prompt)
        chat.update(link: .reconnecting(attempt: 1, since: Date()), client: nil)
        XCTAssertTrue(presence.retained.isEmpty)
    }

    func testAPromptRefusedWhileTheAgentStartsIsSentOnceMore() async throws {
        let helper = ScriptedHelper()
        script(helper) { request in
            guard request.method == "chat.send" else { return nil }
            return request.id == helper.requests("chat.send").first?.id
                ? .error(code: "input", message: "The current prompt or session does not allow input.") : .result(ChatFixture.sent())
        }
        let chat = try await opened(helper, records: [])
        chat.drafts.edit(text: "hello")
        chat.send()
        try await TestSupport.eventually { helper.requests("chat.send").count == 2 && !chat.sending }
        XCTAssertNil(chat.failure)
        XCTAssertEqual(chat.drafts.current.text, "")
    }

    /// The once-more send after an `input` refusal revalidates its destination: after a reconnect in between, the old
    /// helper's terminal id would name another helper's node, so nothing is sent, the draft comes back, and the
    /// conversation can send again (its sending flag is not left set by the old generation).
    func testARetryAfterAReconnectIsNotSentToTheNewHelper() async throws {
        let helper = ScriptedHelper()
        script(helper) { request in
            request.method == "chat.send" ? .error(code: "input", message: "The current prompt or session does not allow input.") : nil
        }
        let chat = try await opened(helper, records: [])
        chat.drafts.edit(text: "hello")
        chat.send()
        try await TestSupport.eventually { helper.requests("chat.send").count == 1 }
        // The link drops and a new helper answers while the send waits to try once more.
        helper.close()
        chat.update(link: .reconnecting(attempt: 1, since: Date()), client: nil)
        let second = ScriptedHelper()
        script(second) { request in request.method == "chat.send" ? .result(ChatFixture.sent()) : nil }
        chat.update(link: .connected, client: second.client)
        try await TestSupport.eventually(timeout: .seconds(3)) { !chat.sending }
        XCTAssertTrue(second.requests("chat.send").isEmpty, "The retry went to another helper")
        XCTAssertEqual(chat.drafts.current.text, "hello", "The draft comes back")
        XCTAssertNotNil(chat.failure)
    }

    func testAnUnattachedTerminalSaysSoInsteadOfARawError() async throws {
        let helper = ScriptedHelper()
        script(helper) { request in
            request.method == "chat.send" ? .error(code: "terminal_unavailable", message: "The terminal shows no screen to act on") : nil
        }
        let chat = try await opened(helper, records: [])
        chat.drafts.edit(text: "hello")
        chat.send()
        try await TestSupport.eventually { chat.failure != nil }
        XCTAssertEqual(chat.failure, "The terminal is not attached yet, so Claude Code cannot take input. Your draft is preserved.")
        XCTAssertEqual(helper.requests("chat.send").count, 1)
    }

    func testACodexConversationFollowsItsThreadIdAndAsksForHookTrust() async throws {
        let helper = ScriptedHelper()
        script(helper)
        var provisional = ChatFixture.binding
        provisional["session"] = ""
        let chat = MobileChatSession(key: ChatConversationKey(host: UUID(), node: ChatFixture.node), hostName: "mba2",
                                     drafts: ChatDraftRepository(store: ChatDraftMemoryStore()),
                                     outbox: ChatOutbox(store: ChatOutboxMemoryStore()))
        let binding = try JSONDecoder().decode(HelperTopology.Binding.self, from: JSONSerialization.data(withJSONObject: provisional))
        chat.update(terminal: 7, binding: binding)
        chat.update(link: .connected, client: helper.client)
        try await TestSupport.eventually { helper.subscription("chat.open") != nil }
        helper.notify(helper.subscription("chat.open")!, "chat.history",
                      ChatFixture.history(session: "", key: "codex", state: ChatFixture.state(busy: false), binding: provisional))
        try await TestSupport.eventually { chat.phase == .verified }
        XCTAssertNil(chat.conversation)
        XCTAssertTrue(chat.needsHookTrust)
        // The first prompt names the thread: the topology's binding changes and the chat reopens on it.
        chat.update(terminal: 7, binding: ChatFixture.topologyBinding)
        try await TestSupport.eventually { helper.requests("chat.open").count == 2 }
        helper.notify(helper.subscription("chat.open")!, "chat.history",
                      ChatFixture.history(key: "codex", records: try ChatFixture.records("codex-formatting-0.154.0")))
        try await TestSupport.eventually { chat.conversation == self.conversation && !chat.transcript.isEmpty }
        helper.notify(helper.subscription("chat.open")!, "interaction.opened", ["terminal": 7, "session": conversation, "interaction": ChatFixture.approval()])
        try await TestSupport.eventually { !chat.needsHookTrust }
    }

    func testModelsEffortsAndSettingsGoThroughTheHelpersMenus() async throws {
        let helper = ScriptedHelper()
        script(helper) { request in
            switch request.method {
            case "chat.models": .result(["choices": [["id": "fable-5.1", "label": "Fable 5.1", "detail": NSNull()],
                                                     ["id": "sonnet", "label": "Sonnet", "detail": NSNull()]],
                                         "current": "fable-5.1", "default": "sonnet"])
            case "chat.settings": .result(["choices": [["id": "low", "label": "low", "detail": NSNull()],
                                                       ["id": "high", "label": "high", "detail": NSNull()]],
                                           "current": "high", "default": NSNull()])
            case "chat.settings.set": .result(ChatFixture.sent())
            default: nil
            }
        }
        let chat = try await opened(helper, records: [])
        let models = try await chat.models()
        XCTAssertEqual(models.map(\.name), ["fable-5.1", "sonnet"])
        XCTAssertEqual(models.first { $0.current }?.name, "fable-5.1")
        _ = try await chat.models()
        XCTAssertEqual(helper.requests("chat.models").count, 1, "Fresh menus come from the cache")
        let efforts = try await chat.efforts(for: "sonnet")
        XCTAssertEqual(efforts.map(\.name), ["low", "high"])
        XCTAssertEqual(helper.requests("chat.settings").first?.params["model"] as? String, "sonnet")
        try await chat.select(model: "sonnet", effort: "low")
        XCTAssertEqual(helper.requests("chat.settings.set").first?.params["effort"] as? String, "low")
        XCTAssertEqual(chat.model, "sonnet")
        XCTAssertEqual(chat.modelLabel, "Sonnet")
    }

    func testAStepsFullOutputComesFromChatTools() async throws {
        var full = try XCTUnwrap(ChatFixture.records("claude-thread").first { $0["id"] as? String == "tool-c4" })
        full["output"] = String(repeating: "✓ billing retries keyed on event id\n", count: 12) + "12 passed"
        let reply = full
        let helper = ScriptedHelper()
        script(helper) { request in request.method == "chat.tools" ? .result(reply) : nil }
        let chat = try await opened(helper, records: ChatFixture.records("claude-thread"))
        let step = try XCTUnwrap(chat.transcript.rows[1].kind.summary?.steps.first { $0.id == "tool-c4" })
        let record = try await chat.fullOutput(of: step)
        XCTAssertEqual(helper.requests("chat.tools").first?.params["record"] as? String, "tool-c4")
        XCTAssertTrue(record.output.hasSuffix("12 passed"))
        XCTAssertTrue(chat.transcript.turns[0].items.first { $0.id == "tool-c4" }?.output.hasSuffix("12 passed") == true)
    }
}

extension ChatThreadRow.Kind {
    var label: String {
        switch self { case .user: "user"; case .agent: "agent"; case .notice: "notice" }
    }
    var summary: ChatTurnSummary? {
        if case .agent(let summary) = self { return summary }
        return nil
    }
}
