import Foundation
import UIKit
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

    /// A command goes at once whenever the agent can take input, even with messages queued (the Mac's
    /// sendFromComposer); while it works it queues as a command, never as a fenced prompt.
    func testCommandsGoAtOnceWhenIdleAndQueueAsCommandsWhileWorking() async throws {
        let helper = ScriptedHelper()
        script(helper) { request in
            switch request.method {
            case "queue.add": .result(ChatFixture.queued("held-\(request.id)", request.params["text"] as! String))
            case "chat.command": .result(["kind": "sent", "sent": ChatFixture.sent()])
            default: nil
            }
        }
        let chat = try await opened(helper, records: [], state: ChatFixture.state(busy: true))
        chat.drafts.edit(text: "/compact")
        XCTAssertEqual(chat.route(steer: true, command: true), .queue, "A command never steers")
        chat.send(steer: true)
        try await TestSupport.eventually { helper.requests("queue.add").count == 1 && chat.queueItems.first?.helperID != nil }
        XCTAssertEqual(helper.requests("queue.add").first?.params["command"] as? Bool, true)
        XCTAssertTrue(helper.requests("chat.send").isEmpty)
        // Idle with a message still queued: the next command goes now.
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        helper.notify(id, "chat.state", ["terminal": 7, "session": conversation, "state": ChatFixture.state(busy: false)])
        try await TestSupport.eventually { !chat.working }
        XCTAssertFalse(chat.queueRows.isEmpty)
        chat.drafts.edit(text: "/model")
        XCTAssertEqual(chat.route(steer: false, command: true), .prompt)
        chat.send()
        try await TestSupport.eventually { helper.requests("chat.command").count == 1 && !chat.sending }
        XCTAssertEqual(helper.requests("chat.command").first?.params["text"] as? String, "/model")
    }

    /// The helper's queue refuses shell commands: a `!` command typed while the agent works waits on the device and
    /// runs by `chat.command` once the agent is idle and nothing is ahead of it.
    func testAQueuedShellCommandRunsWhenTheAgentIsIdle() async throws {
        let helper = ScriptedHelper()
        script(helper) { request in
            request.method == "chat.command" ? .result(["kind": "shell", "command": "ls", "output": "a\nb", "sent": ChatFixture.sent()]) : nil
        }
        let chat = try await opened(helper, records: [], state: ChatFixture.state(busy: true))
        chat.drafts.edit(text: "!ls")
        chat.send()
        try await TestSupport.eventually { chat.queueItems.count == 1 }
        XCTAssertTrue(helper.requests("queue.add").isEmpty, "Never put into the helper's queue")
        XCTAssertTrue(helper.requests("chat.command").isEmpty, "Not while the agent works")
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        helper.notify(id, "chat.state", ["terminal": 7, "session": conversation, "state": ChatFixture.state(busy: false)])
        try await TestSupport.eventually { helper.requests("chat.command").count == 1 && chat.queueItems.isEmpty }
        XCTAssertEqual(helper.requests("chat.command").first?.params["text"] as? String, "!ls")
        XCTAssertEqual(chat.commandResult?.text, "a\nb")
    }

    /// Stop pauses what the device still holds until Resume, as the Mac's stopQueue; Send now refuses a paused row.
    func testStopPausesTheDeviceQueueAndSendNowRefusesPausedRows() async throws {
        let helper = ScriptedHelper()
        script(helper) { request in request.method == "chat.stop" ? .result(ChatFixture.sent()) : nil }
        let outbox = ChatOutbox(store: ChatOutboxMemoryStore())
        let chat = try await opened(helper, records: [], state: ChatFixture.state(busy: true), outbox: outbox)
        // Held on the device: its add is refused as not sent, so it waits.
        _ = outbox.add(ChatOutboxItem(key: chat.key, conversation: conversation, text: "later"))
        chat.stop()
        try await TestSupport.eventually { helper.requests("chat.stop").count == 1 && !chat.stopping }
        XCTAssertEqual(chat.queueItems.first?.state, .paused(MobileChatSession.stopped))
        XCTAssertTrue(chat.queueStopped)
        let row = try XCTUnwrap(chat.queueRows.first)
        XCTAssertFalse(chat.canSendNow(row), "A paused row is not sent by Send now")
        chat.sendQueuedNow(row)
        XCTAssertTrue(helper.requests("chat.send").isEmpty)
    }

    /// A message queued for one agent process is never delivered to another in the same pane (the Mac's
    /// ChatQueuedMessage.matches): it pauses for the user; one queued before any agent was bound adopts this one.
    func testAMessageQueuedForAnotherProcessIsPaused() async throws {
        let helper = ScriptedHelper()
        script(helper) { request in
            request.method == "queue.add" ? .result(ChatFixture.queued("held-\(request.id)", request.params["text"] as! String)) : nil
        }
        let outbox = ChatOutbox(store: ChatOutboxMemoryStore())
        let chat = try await opened(helper, records: [], state: ChatFixture.state(busy: true), outbox: outbox)
        let other = ChatOutboxItem.Process(HelperTopology.Binding(session: "", transcript: nil, pid: 1, start: [1, 0],
                                                                  executable: "/usr/local/bin/claude"))
        _ = outbox.add(ChatOutboxItem(key: chat.key, conversation: conversation, text: "for the old one", state: .paused("x"),
                                      process: other))
        _ = outbox.add(ChatOutboxItem(key: chat.key, conversation: conversation, text: "unbound", state: .paused("x")))
        for row in chat.queueRows { chat.resendQueued(row) }
        try await TestSupport.eventually { chat.queueItems.first?.state == .paused(MobileChatSession.otherProcess) }
        try await TestSupport.eventually { chat.queueItems.last?.helperID != nil }
        XCTAssertEqual(chat.queueItems.last?.process, ChatOutboxItem.Process(ChatFixture.topologyBinding))
        XCTAssertEqual(helper.requests("queue.add").map { $0.params["text"] as? String }, ["unbound"])
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

    /// The host's queue store outlives its helper: a new helper lists the same items under the same ids, and the
    /// device adds nothing again.
    func testANewHelperFindsTheStoredQueueByItsIDs() async throws {
        let first = ScriptedHelper()
        script(first) { request in
            request.method == "queue.add" ? .result(ChatFixture.queued("q-\(request.id)", request.params["text"] as! String)) : nil
        }
        let chat = try await opened(first, records: runningTurn, state: ChatFixture.state(busy: true))
        try await queueTwo(first, chat)
        let ids = chat.queueItems.compactMap(\.helperID)
        first.close()
        chat.update(link: .reconnecting(attempt: 1, since: Date()), client: nil)
        XCTAssertEqual(chat.queueRows.count, 2, "The queue stays visible while the link is down")
        let stored = zip(ids, ["Also cover invoice.paid", "Add a unit test"]).map { ChatFixture.queued($0, $1) }
        let second = try await reconnect(chat, records: runningTurn, busy: true, queue: stored)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(second.requests("queue.add").isEmpty && second.requests("queue.hold").isEmpty)
        XCTAssertEqual(chat.queueItems.compactMap(\.helperID), ids)
        XCTAssertEqual(chat.queueRows.map(\.text), ["Also cover invoice.paid", "Add a unit test"])
    }

    /// A held queue never starts the agent: a release the helper refuses is tried once more, then the queue says so.
    /// (Messages typed while the link was down are the ones mirrored after a reconnect.)
    func testAFailedQueueReleaseIsRetriedAndThenShown() async throws {
        let first = ScriptedHelper()
        script(first)
        let chat = try await opened(first, records: runningTurn, state: ChatFixture.state(busy: true))
        first.close()
        chat.update(link: .reconnecting(attempt: 1, since: Date()), client: nil)
        for text in ["Also cover invoice.paid", "Add a unit test"] {
            chat.drafts.edit(text: text)
            chat.send()
        }
        XCTAssertEqual(chat.queueItems.count, 2)
        let second = try await reconnect(chat, records: runningTurn, busy: true) { request in
            request.method == "queue.hold" && request.params["held"] as? Bool == false ? .error(code: "busy", message: "Try again") : nil
        }
        try await TestSupport.eventually { second.requests("queue.hold").count == 3 && chat.queueError != nil }
        XCTAssertEqual(second.requests("queue.hold").map { $0.params["held"] as? Bool }, [true, false, false])
        XCTAssertEqual(second.requests("queue.add").count, 2)
        XCTAssertEqual(chat.failure, chat.queueError, "The thread shows it")
    }

    /// What the host's queue store no longer holds was sent or removed there: the device lets it go and never adds it
    /// again, whatever the transcript shows yet.
    func testAStoredMessageTheHostNoLongerHoldsLeavesTheDevice() async throws {
        let first = ScriptedHelper()
        script(first) { request in
            request.method == "queue.add" ? .result(ChatFixture.queued("q-\(request.id)", request.params["text"] as! String)) : nil
        }
        let chat = try await opened(first, records: runningTurn, state: ChatFixture.state(busy: true))
        try await queueTwo(first, chat)
        first.close()
        chat.update(link: .reconnecting(attempt: 1, since: Date()), client: nil)
        let second = try await reconnect(chat, records: runningTurn, busy: false)
        try await TestSupport.eventually { chat.queueItems.isEmpty }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(second.requests("queue.add").isEmpty, "Never added again: the host may have sent it")
    }

    func testAMessageTheTranscriptShowsAsSentIsNotQueuedAgain() async throws {
        let first = ScriptedHelper()
        script(first) { request in
            request.method == "queue.add" ? .result(ChatFixture.queued("q-\(request.id)", request.params["text"] as! String)) : nil
        }
        let chat = try await opened(first, records: runningTurn, state: ChatFixture.state(busy: true))
        try await queueTwo(first, chat)
        let ids = chat.queueItems.compactMap(\.helperID)
        first.close()
        chat.update(link: .reconnecting(attempt: 1, since: Date()), client: nil)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let delivered = runningTurn + [
            ChatFixture.record("f1:ended", "turn_ended", turn: "p1", time: now - 2000),
            ChatFixture.record("p2:started", "turn_started", turn: "p2", time: now - 1000),
            ChatFixture.record("user-p2", "user", turn: "p2", text: "Also cover invoice.paid", time: now - 1000)]
        // The host sent the first; the second is still in its store.
        let second = try await reconnect(chat, records: delivered, busy: true, queue: [ChatFixture.queued(ids[1], "Add a unit test")])
        try await TestSupport.eventually { chat.queueItems.count == 1 }
        XCTAssertEqual(chat.queueItems.first?.helperID, ids[1])
        XCTAssertTrue(second.requests("queue.add").isEmpty)
    }

    /// A conversation the agent had not named when the message was queued is held in its helper's memory only: after
    /// a reconnect the head, which that helper may have been sending, waits for the user; what is behind it is added again.
    func testAQueueOfAnUnnamedConversationIsAddedAgainBehindItsUncertainHead() async throws {
        let key = ChatConversationKey(host: UUID(), node: ChatFixture.node)
        let gone = UUID()
        let outbox = ChatOutbox(store: ChatOutboxMemoryStore([
            ChatOutboxItem(key: key, conversation: nil, text: "Also cover invoice.paid", state: .queued(id: "q-1", revision: 1, helper: gone)),
            ChatOutboxItem(key: key, conversation: nil, text: "Add a unit test", state: .queued(id: "q-2", revision: 2, helper: gone))]))
        let helper = ScriptedHelper()
        script(helper) { request in
            switch request.method {
            case "queue.list": .result([[String: Any]]())
            case "queue.add": .result(ChatFixture.queued("q-\(request.id)", request.params["text"] as! String))
            default: nil
            }
        }
        let chat = MobileChatSession.scripted(helper, host: key.host, outbox: outbox)
        try await TestSupport.eventually { helper.subscription("chat.open") != nil }
        helper.notify(helper.subscription("chat.open")!, "chat.history", ChatFixture.history(state: ChatFixture.state(busy: false), pending: true))
        helper.notify(helper.subscription("chat.open")!, "chat.history", ChatFixture.history())
        try await TestSupport.eventually { helper.requests("queue.add").count == 1 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(helper.requests("queue.add").map { $0.params["text"] as? String }, ["Add a unit test"],
                       "Only the message behind the head is certainly unsent")
        guard case .uncertain = chat.queueItems.first?.state else { return XCTFail("The head waits for the user") }
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

    /// A helper that reads the terminal's screen itself (`screens.host`) still needs the terminal attached: the
    /// conversation retains it with the features its hello accepted (so the feed publishes nothing and may hold its
    /// output), counts it as attached, and sends at once.
    func testATerminalOfAHelperReadingItsScreensIsRetainedWithTheHellosFeatures() async throws {
        let presence = ChatTerminalPresenceStub()
        let helper = ScriptedHelper()
        script(helper)
        let chat = MobileChatSession.scripted(helper, presence: presence)
        let features: Set<String> = [HelperSession.screensHost, HelperSession.terminalsFollow, ChatAttachment.feature]
        chat.update(link: .connected, client: helper.client, features: features)
        try await TestSupport.eventually { helper.subscription("chat.open") != nil }
        helper.notify(helper.subscription("chat.open")!, "chat.history", ChatFixture.history())
        try await TestSupport.eventually { chat.phase == .verified }
        XCTAssertEqual(presence.retained, [chat.key: 7])
        XCTAssertEqual(presence.features[chat.key], features)
        XCTAssertTrue(chat.terminalAttached)
        XCTAssertEqual(chat.route(steer: false), .prompt)
        XCTAssertTrue(helper.requests("terminals.publish").isEmpty)
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
        XCTAssertEqual(chat.modelLabel, "sonnet")
        // Claude reports the model's ID (a /model in its terminal, a fresh session): the Mac's label, never the raw ID.
        helper.notify(helper.subscription("chat.open")!, "chat.state",
                      ["terminal": 7, "session": conversation, "state": ChatFixture.state(busy: false, model: "claude-opus-5-5")])
        try await TestSupport.eventually { chat.model == "claude-opus-5-5" }
        XCTAssertEqual(chat.modelLabel, "opus-5.5")
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

    // MARK: Attachments (docs/ios.md, Attachments)

    /// A small PNG, as a pasted screenshot carries.
    private static let png = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).pngData { context in
        UIColor.systemPink.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    }
    private static let stored = "/Users/sam/.dispatch/attachments/0123456789abcdef0123456789abcdef/screenshot.png"

    /// An open conversation whose helper accepted `chat.attachments`; `attachments.put` stores under the request's id.
    private func attachable(_ helper: ScriptedHelper, state: [String: Any]? = nil, outbox: ChatOutbox = ChatOutbox(store: ChatOutboxMemoryStore()),
                            _ extra: @escaping (ScriptedHelper.Request) -> ScriptedHelper.Reply? = { _ in nil }) async throws -> MobileChatSession {
        script(helper) { request in
            if let reply = extra(request) { return reply }
            guard request.method == "attachments.put" else { return nil }
            let name = request.params["name"] as? String ?? ""
            let image = name.hasSuffix(".png") || name.hasSuffix(".jpg")
            return .result(["path": "/Users/sam/.dispatch/attachments/\(String(format: "%032llx", request.id))/\(name)", "name": name,
                            "kind": image ? "image" : "file", "size": (request.params["bytes"] as? Data)?.count ?? 0])
        }
        let chat = try await opened(helper, records: [], state: state, outbox: outbox)
        XCTAssertFalse(chat.attachmentsAvailable, "Not without the hello feature")
        chat.update(link: .connected, client: helper.client, features: [ChatAttachment.feature])
        XCTAssertTrue(chat.attachmentsAvailable)
        return chat
    }

    /// Picked bytes are prepared, stored on the host and kept in the draft with a thumbnail; the send names the copy.
    func testAnAttachmentUploadsThenSendsByPath() async throws {
        let helper = ScriptedHelper()
        let chat = try await attachable(helper) { $0.method == "chat.send" ? .result(ChatFixture.sent()) : nil }
        XCTAssertTrue(chat.canAttach)
        chat.attach([.data(Self.png, name: "screenshot.png", kind: .image)])
        XCTAssertEqual(chat.uploads.map(\.name), ["screenshot.png"], "The strip shows it at once")
        try await TestSupport.eventually { chat.uploads.isEmpty && chat.drafts.current.attachments.count == 1 }
        let put = try XCTUnwrap(helper.requests("attachments.put").first)
        XCTAssertEqual(put.params["name"] as? String, "screenshot.png")
        XCTAssertEqual(put.params["bytes"] as? Data, Self.png, "A PNG goes as it is")
        let attachment = chat.drafts.current.attachments[0]
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertNotNil(attachment.thumbnail)
        XCTAssertTrue(attachment.path?.hasSuffix("/screenshot.png") == true)
        XCTAssertTrue(chat.drafts.shape.hasAttachments)
        chat.drafts.edit(text: "Why is this button grey?")
        chat.send()
        XCTAssertEqual(chat.optimisticPrompt?.attachments, [attachment], "The bubble shows the thumbnail at once")
        try await TestSupport.eventually { helper.requests("chat.send").count == 1 && !chat.sending }
        let send = try XCTUnwrap(helper.requests("chat.send").first)
        XCTAssertEqual(send.params["text"] as? String, "Why is this button grey?")
        XCTAssertEqual(send.params["attachments"] as? [String], [try XCTUnwrap(attachment.path)])
        XCTAssertTrue(chat.drafts.current.attachments.isEmpty, "The draft leaves with its attachments")
    }

    /// Attachments without text send; the record (its text empty, an image block naming the copy) takes the bubble's
    /// place and keeps the thumbnail.
    func testAnAttachmentOnlyMessageBecomesItsTranscriptRowInPlace() async throws {
        let helper = ScriptedHelper()
        let chat = try await attachable(helper) { $0.method == "chat.send" ? .result(ChatFixture.sent()) : nil }
        let image = ChatAttachment(id: "a1", name: "screenshot.png", kind: .image, size: 2048, path: Self.stored,
                                   thumbnail: ChatAttachmentImage.thumbnail(Self.png))
        chat.drafts.attach([image])
        XCTAssertEqual(CodeComposer.slot(text: "", working: false, attached: true), .send)
        chat.send()
        let pendingID = try XCTUnwrap(chat.optimisticPrompt?.id)
        try await TestSupport.eventually { helper.requests("chat.send").count == 1 && !chat.sending }
        let send = try XCTUnwrap(helper.requests("chat.send").first)
        XCTAssertEqual(send.params["text"] as? String, "")
        XCTAssertEqual(send.params["attachments"] as? [String], [Self.stored])
        var record = ChatFixture.record("user-p1", "user", turn: "p1", text: "", time: 946_719_200_000)
        record["blocks"] = [["kind": "image", "language": NSNull(), "text": "screenshot.png", "path": Self.stored]]
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        helper.notify(id, "chat.records", ["terminal": 7, "session": conversation, "records": [
            ChatFixture.record("p1:started", "turn_started", turn: "p1", time: 946_719_200_000), record]])
        try await TestSupport.eventually { chat.optimisticPrompt == nil }
        let row = try XCTUnwrap(chat.transcript.rows.last)
        XCTAssertEqual(row.id, pendingID, "The confirmed record keeps the bubble's identity")
        XCTAssertEqual(row.item.attachments.map(\.path), [Self.stored])
        XCTAssertEqual(row.item.attachments.first?.thumbnail, image.thumbnail, "and the composer's thumbnail")
        XCTAssertEqual(row.item.attachments.first?.id, "a1")
    }

    /// A send that fails puts the draft back with its attachments (they are still on the host).
    func testAFailedSendPutsTheAttachmentsBackInTheDraft() async throws {
        let helper = ScriptedHelper()
        let chat = try await attachable(helper) {
            $0.method == "chat.send" ? .error(code: "terminal_unavailable", message: "Not attached.") : nil
        }
        let image = ChatAttachment(id: "a1", name: "screenshot.png", kind: .image, size: 2048, path: Self.stored)
        chat.drafts.attach([image])
        chat.drafts.edit(text: "Compare with this")
        chat.send()
        XCTAssertTrue(chat.drafts.current.attachments.isEmpty)
        try await TestSupport.eventually { chat.failure != nil && !chat.sending }
        XCTAssertNil(chat.optimisticPrompt)
        XCTAssertEqual(chat.drafts.current.text, "Compare with this")
        XCTAssertEqual(chat.drafts.current.attachments.map(\.path), [Self.stored])
    }

    /// Queued while the agent works: `queue.add` carries the paths, the row shows the attachments and is not edited in
    /// place, and the helper's preview (which names attachments by type) does not replace what was typed.
    func testAQueuedMessageCarriesItsAttachments() async throws {
        let helper = ScriptedHelper()
        let chat = try await attachable(helper, state: ChatFixture.state(busy: true)) { request in
            guard request.method == "queue.add" else { return nil }
            var queued = ChatFixture.queued("held-1", request.params["text"] as! String)
            queued["preview"] = [["kind": "text", "text": request.params["text"] as! String], ["kind": "attachment", "type": "image"]]
            queued["editable"] = false
            return .result(queued)
        }
        chat.drafts.attach([ChatAttachment(id: "a1", name: "screenshot.png", kind: .image, size: 2048, path: Self.stored)])
        chat.drafts.edit(text: "Then this one")
        XCTAssertEqual(chat.route(steer: false), .queue)
        chat.send()
        try await TestSupport.eventually { chat.queueItems.first?.helperID != nil }
        XCTAssertEqual(helper.requests("queue.add").first?.params["attachments"] as? [String], [Self.stored])
        let row = try XCTUnwrap(chat.queueRows.first)
        XCTAssertEqual(row.text, "Then this one")
        XCTAssertEqual(row.attachments.map(\.path), [Self.stored])
        XCTAssertFalse(row.editable, "Not edited in place")
        XCTAssertEqual(ChatQueueCard.accessibilityLabel(row), "Then this one, Image")
        helper.notify(try XCTUnwrap(helper.subscription("chat.open")), "chat.queue", ["terminal": 7, "session": conversation, "items": [
            ["id": "held-1", "mode": "prompt", "revision": 2, "editable": false, "editing": false, "paused": NSNull(), "error": NSNull(),
             "preview": [["kind": "text", "text": "Then this one"], ["kind": "attachment", "type": "image"]]]], "error": NSNull()])
        try await TestSupport.eventually { chat.queue.first?.revision == 2 }
        XCTAssertEqual(chat.queueItems.first?.text, "Then this one", "The preview's attachment line is not the text")
        // A row only the helper holds (added on the Mac): its attachments by kind, the text without them.
        let mac = try JSONDecoder().decode(HelperChat.Queued.self, from: JSONSerialization.data(withJSONObject: [
            "id": "mac-1", "mode": "prompt", "revision": 1, "editable": false, "editing": false, "paused": NSNull(), "error": NSNull(),
            "preview": [["kind": "text", "text": "From the Mac"], ["kind": "attachment", "type": "localImage"],
                        ["kind": "attachment", "type": "file"]]]))
        XCTAssertEqual(mac.typedText, "From the Mac")
        XCTAssertEqual(mac.previewAttachments.map(\.kind), [.image, .file])
    }

    /// The queue file keeps attachments without their thumbnails; a file written before attachments reads as before.
    func testTheQueueFileKeepsAttachmentsWithoutThumbnailsAndReadsOlderFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("chat-queue.json")
        let key = ChatConversationKey(host: UUID(), node: ChatFixture.node)
        let image = ChatAttachment(id: "a1", name: "screenshot.png", kind: .image, size: 2048, path: Self.stored, thumbnail: Self.png)
        let item = ChatOutboxItem(key: key, conversation: conversation, text: "", attachments: [image])
        let outbox = ChatOutbox(store: ChatOutboxFileStore(url: url))
        XCTAssertTrue(outbox.add(item))
        XCTAssertEqual(outbox.items.first?.attachments.first?.thumbnail, Self.png, "In memory the thumbnail stays")
        let loaded = try ChatOutboxFileStore(url: url).load()
        var expected = image
        expected.thumbnail = nil
        XCTAssertEqual(loaded.first?.attachments, [expected])
        XCTAssertEqual(loaded.first?.text, "")
        // An older file: no `attachments` key.
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var items = try XCTUnwrap(document["items"] as? [[String: Any]])
        items[0].removeValue(forKey: "attachments")
        items[0]["text"] = "Older"
        document["items"] = items
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        let older = try ChatOutboxFileStore(url: url).load()
        XCTAssertEqual(older.map(\.text), ["Older"])
        XCTAssertEqual(older.first?.attachments, [])
    }

    /// More than a message carries, a file that cannot be read, a command draft and a helper without the feature
    /// upload nothing; a failed upload stays in the strip until Retry stores it.
    func testUploadsRefuseWhatCannotGoAndRetryAFailure() async throws {
        let helper = ScriptedHelper()
        // The first upload fails; the helper's script runs on its own thread.
        final class Failures: @unchecked Sendable {
            private let lock = NSLock()
            private var left = 1
            func next() -> Bool { lock.withLock { defer { left -= 1 }; return left > 0 } }
        }
        let failures = Failures()
        let chat = try await attachable(helper) { request in
            guard request.method == "attachments.put" else { return nil }
            return failures.next() ? .error(code: "io", message: "The host's disk is full.") : nil
        }
        chat.attach((0...ChatAttachment.maximumCount).map { .data(Self.png, name: "shot \($0).png", kind: .image) })
        XCTAssertEqual(chat.attachmentError, ChatAttachmentError.tooMany.localizedDescription)
        XCTAssertTrue(chat.uploads.isEmpty)
        chat.attach([MobileAttachmentSource(name: "notes.txt") { throw ChatAttachmentError.unreadable("notes.txt") }])
        try await TestSupport.eventually { chat.uploads.isEmpty && chat.attachmentError != nil }
        XCTAssertEqual(chat.attachmentError, ChatAttachmentError.unreadable("notes.txt").localizedDescription)
        XCTAssertTrue(helper.requests("attachments.put").isEmpty, "Nothing was uploaded")

        chat.attach([.data(Data("Sam Example's notes\n".utf8), name: "notes.txt", kind: .file)])
        try await TestSupport.eventually { chat.uploads.first?.error != nil }
        XCTAssertEqual(chat.uploads.first?.error, "The host's disk is full.")
        chat.drafts.edit(text: "see the notes")
        chat.send()
        XCTAssertTrue(helper.requests("chat.send").isEmpty, "Not without the attachment that failed")
        XCTAssertEqual(chat.drafts.current.text, "see the notes")
        chat.retryUpload(try XCTUnwrap(chat.uploads.first?.id))
        try await TestSupport.eventually { chat.uploads.isEmpty && chat.drafts.current.attachments.count == 1 }
        XCTAssertEqual(chat.drafts.current.attachments.first?.kind, .file)
        XCTAssertEqual(helper.requests("attachments.put").count, 2)
        chat.removeAttachment(try XCTUnwrap(chat.drafts.current.attachments.first?.id))
        XCTAssertTrue(chat.drafts.current.attachments.isEmpty)

        chat.drafts.edit(text: "/compact")
        XCTAssertFalse(chat.canAttach, "A command takes none")
        chat.drafts.edit(text: "")
        chat.update(link: .connected, client: helper.client, features: [])
        XCTAssertFalse(chat.canAttach, "Nor a helper without the feature")
    }

    /// An image the device has no thumbnail for is read from the host (`attachments.read`), a few at a time, and kept
    /// in memory by host and path.
    func testThumbnailsAreReadFromTheHostTwoAtATime() async throws {
        let helper = ScriptedHelper()
        let chat = try await attachable(helper) { request in
            request.method == "attachments.read" ? .result(["bytes": Self.png, "size": Self.png.count]) : nil
        }
        let bytes = try await chat.attachmentBytes(Self.stored)
        XCTAssertEqual(bytes, Self.png)
        XCTAssertEqual(helper.requests("attachments.read").first?.params["path"] as? String, Self.stored)

        final class Reads { var paths: [String] = []; var active = 0; var peak = 0 }
        let reads = Reads()
        let read: @MainActor (String) async throws -> Data? = { path in
            reads.paths.append(path); reads.active += 1; reads.peak = max(reads.peak, reads.active)
            try await Task.sleep(for: .milliseconds(40))
            reads.active -= 1
            return Self.png
        }
        let cache = MobileAttachmentThumbnails()
        let host = UUID()
        let images = (0..<5).map { ChatAttachment(id: "r\($0)", name: "shot.png", kind: .image, size: 0, path: "/stored/\($0)/shot.png") }
        for image in images { XCTAssertNil(cache.image(image, host: host, read: read)) }
        for image in images { _ = cache.image(image, host: host, read: read) }
        try await TestSupport.eventually { images.allSatisfy { cache.image($0, host: host, read: nil) != nil } }
        XCTAssertEqual(reads.paths.count, 5, "Each read once")
        XCTAssertLessThanOrEqual(reads.peak, MobileAttachmentThumbnails.concurrency)
        XCTAssertNil(cache.image(images[0], host: UUID(), read: nil), "Keyed by host")
        XCTAssertNil(cache.image(ChatAttachment(name: "notes.txt", kind: .file, size: 1, path: "/stored/n.txt"), host: host, read: read))
    }

    /// An upload lands in the draft it was started for, though the user switched drafts meanwhile; the strip shows
    /// uploads of the draft on screen only.
    func testAnUploadLandsInTheDraftItWasStartedFor() async throws {
        let helper = ScriptedHelper()
        let chat = try await attachable(helper)
        chat.drafts.edit(text: "About the chart")
        let first = chat.drafts.current.id
        chat.attach([.data(Self.png, name: "screenshot.png", kind: .image)])
        XCTAssertEqual(chat.draftUploads.count, 1)
        // Switched before the host answers (the upload runs after this turn of the main actor).
        chat.drafts.keep()
        XCTAssertNotEqual(chat.drafts.current.id, first)
        XCTAssertTrue(chat.draftUploads.isEmpty, "The new draft's strip is empty")
        XCTAssertTrue(ComposerAttachments.chips(chat).isEmpty)
        try await TestSupport.eventually { chat.uploads.isEmpty }
        XCTAssertTrue(chat.drafts.current.attachments.isEmpty, "Not the draft on screen")
        XCTAssertEqual(chat.drafts.saved.first { $0.id == first }?.attachments.map(\.name), ["screenshot.png"])
        chat.drafts.select(first)
        XCTAssertEqual(ComposerAttachments.chips(chat).map(\.name), ["screenshot.png"])

        // That draft gone before the host answers: the chip comes to the current draft, failed, for Retry.
        chat.attach([.data(Self.png, name: "second.png", kind: .image)])
        chat.drafts.discard()
        try await TestSupport.eventually { chat.uploads.first?.error != nil }
        XCTAssertEqual(chat.draftUploads.map(\.name), ["second.png"])
        XCTAssertTrue(chat.drafts.current.attachments.isEmpty)
        chat.retryUpload(try XCTUnwrap(chat.uploads.first?.id))
        try await TestSupport.eventually { chat.uploads.isEmpty }
        XCTAssertEqual(chat.drafts.current.attachments.map(\.name), ["second.png"])
    }

    /// After a reconnect, a queued attachment message is not taken for an earlier attachment-only message of the
    /// transcript, nor for a helper row with its text but without attachments; one the transcript shows is sent.
    func testAQueuedAttachmentMessageIsNotTakenForAnother() async throws {
        let key = ChatConversationKey(host: UUID(), node: ChatFixture.node)
        let gone = UUID()
        let chart = "/Users/sam/.dispatch/attachments/0123456789abcdef0123456789abcdef/chart.png"
        let deck = "/Users/sam/.dispatch/attachments/fedcba9876543210fedcba9876543210/deck.png"
        let outbox = ChatOutbox(store: ChatOutboxMemoryStore([
            ChatOutboxItem(key: key, conversation: nil, text: "Look", state: .queued(id: "q-1", revision: 1, helper: gone),
                           attachments: [ChatAttachment(id: "a1", name: "deck.png", kind: .image, size: 1, path: deck)]),
            ChatOutboxItem(key: key, conversation: nil, text: "", state: .queued(id: "q-2", revision: 1, helper: gone),
                           attachments: [ChatAttachment(id: "a2", name: "chart.png", kind: .image, size: 1, path: chart)])]))
        let helper = ScriptedHelper()
        script(helper) { request in
            request.method == "queue.list" ? .result([ChatFixture.queued("h-1", "Look")]) : nil
        }
        let chat = MobileChatSession.scripted(helper, host: key.host, outbox: outbox)
        try await TestSupport.eventually { helper.subscription("chat.open") != nil }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var sent = ChatFixture.record("user-e3b0", "user", turn: "p1", text: "", time: now - 1000)
        sent["blocks"] = [["kind": "image", "language": NSNull(), "text": "chart.png", "path": chart]]
        helper.notify(helper.subscription("chat.open")!, "chat.history", ChatFixture.history(state: ChatFixture.state(busy: false), pending: true))
        helper.notify(helper.subscription("chat.open")!, "chat.history", ChatFixture.history(records: [
            ChatFixture.record("p1:started", "turn_started", turn: "p1", time: now - 1000), sent]))
        try await TestSupport.eventually { chat.queueItems.count == 1 }
        let left = try XCTUnwrap(chat.queueItems.first)
        XCTAssertEqual(left.text, "Look", "The image-only message the transcript shows was sent; the other was not")
        XCTAssertNil(left.helperID, "A helper row without attachments is another message")
        XCTAssertNotNil(left.pauseReason, "The head may have been sending: the user decides")
        XCTAssertTrue(helper.requests("queue.add").isEmpty)
    }

    /// A message with attachments waiting on the device is not edited in place, but "send now" steers it like any other.
    func testADeviceRowWithAttachmentsCanBeSentNow() async throws {
        let key = ChatConversationKey(host: UUID(), node: ChatFixture.node)
        let outbox = ChatOutbox(store: ChatOutboxMemoryStore([
            ChatOutboxItem(key: key, conversation: conversation, text: "First"),
            ChatOutboxItem(key: key, conversation: conversation, text: "",
                           attachments: [ChatAttachment(id: "a1", name: "screenshot.png", kind: .image, size: 1, path: Self.stored)])]))
        let helper = ScriptedHelper()
        script(helper) { request in
            switch request.method {
            // The first is refused: the drain stops there, and the second waits on the device.
            case "queue.add": .error(code: "invalid_input", message: "Refused.")
            case "chat.send": .result(ChatFixture.sent())
            default: nil
            }
        }
        let chat = MobileChatSession.scripted(helper, host: key.host, outbox: outbox)
        try await TestSupport.eventually { helper.subscription("chat.open") != nil }
        let open = try XCTUnwrap(helper.subscription("chat.open"))
        helper.notify(open, "chat.history", ChatFixture.history(state: ChatFixture.state(busy: true), pending: true))
        helper.notify(open, "chat.history", ChatFixture.history(records: runningTurn))
        try await TestSupport.eventually { chat.queueItems.first?.pauseReason != nil && chat.working }
        let row = try XCTUnwrap(chat.queueRows.last)
        XCTAssertNil(row.status)
        XCTAssertFalse(row.editable, "Not edited in place")
        XCTAssertTrue(row.steerable)
        XCTAssertTrue(chat.canSendNow(row), "Send now steers it")
        chat.sendQueuedNow(row)
        try await TestSupport.eventually { helper.requests("chat.send").count == 1 && chat.queueItems.count == 1 }
        let send = try XCTUnwrap(helper.requests("chat.send").first)
        XCTAssertEqual(send.params["mode"] as? String, "steer")
        XCTAssertEqual(send.params["attachments"] as? [String], [Self.stored])
    }

    /// Thumbnails read from the host: an answer that will not change (`not_found`, `invalid_request`) is not asked
    /// again; a lost link is, after a wait that doubles; an image dropped from the cache is read again when shown.
    func testThumbnailReadsRetryTransientFailuresAndAfterEviction() async throws {
        let cache = MobileAttachmentThumbnails()
        let now = Date(timeIntervalSince1970: 1_000_000)
        cache.finish("flaky", .failure(HelperFailure(code: "unavailable", message: "Not connected.")), now: now)
        XCTAssertFalse(cache.asks("flaky", now: now.addingTimeInterval(4)))
        XCTAssertTrue(cache.asks("flaky", now: now.addingTimeInterval(5)))
        cache.finish("flaky", .failure(CancellationError()), now: now)
        XCTAssertFalse(cache.asks("flaky", now: now.addingTimeInterval(9)), "The wait doubles")
        XCTAssertTrue(cache.asks("flaky", now: now.addingTimeInterval(10)))
        XCTAssertEqual(MobileAttachmentThumbnails.backoff(20), 300)

        // Through image(): a not_found answer is final, a transient one is asked again later.
        final class Reads { var count = 0 }
        let reads = Reads()
        let host = UUID()
        let missing = ChatAttachment(id: "m", name: "gone.png", kind: .image, size: 0, path: "/stored/gone.png")
        let notFound: @MainActor (String) async throws -> Data? = { _ in
            reads.count += 1; throw HelperFailure(code: "not_found", message: "Gone.")
        }
        XCTAssertNil(cache.image(missing, host: host, read: notFound))
        try await TestSupport.eventually { reads.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        _ = cache.image(missing, host: host, read: notFound)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(reads.count, 1, "Gone for good")
        XCTAssertFalse(cache.asks(MobileAttachmentThumbnails.key(host: host, path: "/stored/gone.png")))

        let first = ChatAttachment(id: "f", name: "shot.png", kind: .image, size: 0, path: "/stored/0/shot.png")
        let read: @MainActor (String) async throws -> Data? = { _ in reads.count += 1; return Self.png }
        _ = cache.image(first, host: host, read: read)
        try await TestSupport.eventually { cache.image(first, host: host, read: nil) != nil }
        let firstKey = MobileAttachmentThumbnails.key(host: host, path: "/stored/0/shot.png")
        XCTAssertFalse(cache.asks(firstKey))
        for index in 0..<MobileAttachmentThumbnails.capacity { cache.store(UIImage(), for: "other-\(index)") }
        XCTAssertNil(cache.image(first, host: host, read: nil), "Dropped from the cache")
        XCTAssertTrue(cache.asks(firstKey), "and read again when shown")
    }
}

extension ChatThreadRow.Kind {
    var label: String {
        switch self { case .user: "user"; case .agent: "agent"; case .thinking: "thinking"; case .notice: "notice" }
    }
    var summary: ChatTurnSummary? {
        if case .agent(let summary) = self { return summary }
        return nil
    }
}
