import Foundation
import XCTest
@testable import DispatchMobile

/// A conversation as a watch thread page (docs/watch.md, "The page"), from `MobileChatSession` against the scripted
/// helper and the real helper's recorded transcript.
@MainActor
final class WatchThreadBuilderTests: XCTestCase {
    private let conversation = "00000000-0000-4000-8000-000000000201"

    private func opened(_ helper: ScriptedHelper, records: [[String: Any]], state: [String: Any] = ChatFixture.state(busy: false),
                        presence: (any ChatTerminalPresence)? = nil) async throws -> MobileChatSession {
        helper.script { request in
            switch request.method {
            case "chat.open": .open
            case "queue.list": .result([Any]())
            default: .result(NSNull())
            }
        }
        let chat = MobileChatSession.scripted(helper, presence: presence)
        try await TestSupport.eventually { helper.subscription("chat.open") != nil }
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        helper.notify(id, "chat.history", ChatFixture.history(records: records, state: state))
        try await TestSupport.eventually { chat.phase == .verified && !chat.loadingHistory }
        return chat
    }

    /// Every user, agent and notice row the phone shows, with the phone's row ids; each tool as one line; the turn's
    /// caption under its last agent message.
    func testTheRealTranscriptBecomesRowsToolLinesAndCaptions() async throws {
        let helper = ScriptedHelper()
        let chat = try await opened(helper, records: ChatFixture.records("claude-thread"))
        let page = WatchThreadBuilder.page(chat, row: nil)
        XCTAssertEqual(page.items.map(\.kind), [.user, .tool, .tool, .tool, .tool, .tool, .agent,
                                                .user, .tool, .tool, .tool, .tool, .agent])
        XCTAssertEqual(page.items.compactMap(\.tool), ["Read", "Search", "Patch", "Run", "Read", "Read", "Read", "Patch", "Patch"])
        XCTAssertEqual(page.items.compactMap(\.caption), ["5 steps · 1m 26s", "4 steps · 52s"])
        XCTAssertEqual(page.items.filter { $0.kind == .agent }.map(\.caption), ["5 steps · 1m 26s", "4 steps · 52s"],
                       "on the ended turn's last agent message")
        let run = try XCTUnwrap(page.items.first { $0.tool == "Run" })
        XCTAssertEqual(run.text, "pnpm test billing")
        XCTAssertFalse(run.running)
        // The phone's row ids, so the watch's cache keys hold across pages.
        let rows = chat.transcript.rows
        XCTAssertEqual(page.items.filter { $0.kind != .tool }.map(\.id), rows.map(\.id))
        XCTAssertEqual(Set(page.items.map(\.id)).count, page.items.count, "ids are unique")
        XCTAssertEqual(page.items.first?.text, rows.first?.item.text)
        XCTAssertTrue(page.items.allSatisfy { $0.turn != nil })
        XCTAssertEqual(page.phase, .live)
        XCTAssertEqual(page.agent, "Claude Code")
        XCTAssertEqual(page.model, chat.modelLabel)
        XCTAssertEqual(page.route, .send)
        XCTAssertFalse(page.canStop)
        XCTAssertFalse(page.earlier)
        XCTAssertEqual(page.title, ChatFixture.node, "no row: the key")
        XCTAssertEqual(page.lastActivity, chat.transcript.lastActivity)

        // The cards' summaries (K2): the caption's steps and time, and the files the turn's patches changed with their
        // lines, as the Patch lines of the same turn add up.
        let agents = page.items.filter { $0.kind == .agent }
        XCTAssertEqual(agents.compactMap(\.summary).map(\.steps), [5, 4])
        XCTAssertEqual(agents.compactMap(\.summary).map { $0.seconds.map { Int($0.rounded()) } }, [86, 52])
        for agent in agents {
            let summary = try XCTUnwrap(agent.summary)
            let patches = page.items.filter { $0.turn == agent.turn && $0.tool == "Patch" && !$0.failed }
            var additions = 0, deletions = 0
            for detail in patches.compactMap(\.detail) {
                let counts = detail.split(separator: " ").compactMap { Int($0.dropFirst()) }
                if counts.count == 2 { additions += counts[0]; deletions += counts[1] }
            }
            XCTAssertEqual(summary.additions, additions)
            XCTAssertEqual(summary.deletions, deletions)
            XCTAssertEqual(summary.files > 0, !patches.isEmpty)
            XCTAssertLessThanOrEqual(summary.files, patches.count * 4)
        }
    }

    /// What a row says while the agent works (K1): the open turn's step as a verb and what it acts on; the agent's
    /// activity word without one; while it waits, its approval's command.
    func testTheRowsStepAndQuestionComeFromTheSession() async throws {
        let helper = ScriptedHelper()
        let chat = try await opened(helper, records: ChatFixture.records("claude-thread"))
        let steps = chat.transcript.turns.flatMap { ChatStep.steps($0, directory: nil, reasoning: false) }
        let patch = try XCTUnwrap(steps.first { $0.kind == .patch })
        XCTAssertTrue(WatchSnapshotBuilder.phrase(patch).hasPrefix("Editing "))
        XCTAssertFalse(WatchSnapshotBuilder.phrase(patch).contains("/"), "a file by its name")
        let run = try XCTUnwrap(steps.first { $0.kind == .run })
        XCTAssertEqual(WatchSnapshotBuilder.phrase(run), "Running pnpm test billing")
        let read = try XCTUnwrap(steps.first { $0.kind == .read })
        XCTAssertTrue(WatchSnapshotBuilder.phrase(read).hasPrefix("Reading "))
        XCTAssertNil(WatchSnapshotBuilder.waiting(chat))

        let busy = ScriptedHelper()
        let working = try await opened(busy, records: [], state: ChatFixture.state(busy: true, activity: "reading files"))
        XCTAssertEqual(WatchSnapshotBuilder.step(working, directory: nil), "Reading files")
        XCTAssertNotNil(WatchSnapshotBuilder.started(working))
        let id = try XCTUnwrap(busy.subscription("chat.open"))
        busy.notify(id, "interaction.opened", ["terminal": 7, "session": conversation, "interaction": ChatFixture.approval(options: ["Allow", "Deny"])])
        try await TestSupport.eventually { working.approvals.count == 1 }
        XCTAssertEqual(WatchSnapshotBuilder.waiting(working), "Allow printf 'DISPATCH_LOCAL_TOOL_OK\\n'?")
        XCTAssertEqual(WatchThreadBuilder.page(working, row: nil).approvals.first?.verb, .run, "a command: Claude wants to run")

        // An operation the line cannot name (no command, file, URL or pattern): the approval's own words, never its JSON.
        func line(_ operation: String, header: String = "WebSearch") throws -> String {
            let interaction = try JSONDecoder().decode(HelperChat.Interaction.self, from: JSONSerialization.data(withJSONObject: [
                "id": "a", "key": NSNull(), "approval": true, "blocking": true, "turn": NSNull(), "record": NSNull(),
                "questions": [["id": "q", "header": header, "text": operation, "secret": false, "multiple": false, "custom": false,
                               "blocks": NSNull(), "options": [["id": "allow", "label": "Allow", "detail": NSNull()]]]]]))
            return WatchSnapshotBuilder.approvalLine(interaction)
        }
        XCTAssertEqual(try line(#"{"query":"swift actors","allowed_domains":["example.com"]}"#), "Allow WebSearch?")
        XCTAssertEqual(try line(#"{"command":"cargo test --workspace\nmore"}"#, header: "Bash"), "Allow cargo test --workspace?")
        XCTAssertEqual(try line(#"{"url":"https://example.com/docs"}"#, header: "WebFetch"), "Allow https://example.com/docs?")
        XCTAssertEqual(try line(#"{"query":"x"}"#, header: ""), "Allow a tool call?")
    }

    /// The newest `limit` items; `earlier` when more exist, here or on the host. The page survives the wire and fits a
    /// reply.
    func testTheNewestItemsFitAReply() async throws {
        let helper = ScriptedHelper()
        // Distinct from the start: a binary plist stores equal strings once.
        let long = String(repeating: "A **long** answer with `code`. ", count: 400)
        var records: [[String: Any]] = []
        for turn in 0..<80 {
            records.append(ChatFixture.record("t\(turn):started", "turn_started", turn: "t\(turn)", time: 946_719_000_000 + Int64(turn) * 1000))
            records.append(ChatFixture.record("u\(turn)", "user", turn: "t\(turn)", text: "Question \(turn)", time: 946_719_000_000 + Int64(turn) * 1000))
            records.append(ChatFixture.record("a\(turn)", "assistant", turn: "t\(turn)", text: "Answer \(turn): " + long, time: 946_719_000_500 + Int64(turn) * 1000))
        }
        let chat = try await opened(helper, records: records)
        let page = WatchThreadBuilder.page(chat, row: nil, limit: 10)
        XCTAssertEqual(page.items.count, 10)
        XCTAssertTrue(page.earlier)
        XCTAssertEqual(page.items.last?.text.hasSuffix("…"), true, "clipped to WatchLimits.itemText")
        XCTAssertFalse(page.items.last?.text.contains("**") ?? true, "Markdown flattened")
        XCTAssertEqual(page.items.first?.text, "Question 75")

        let full = WatchThreadBuilder.page(chat, row: nil, limit: 200)
        let reply = WatchReply(id: "r1", .thread(full))
        let message = try WatchCodec.message(reply)
        XCTAssertLessThanOrEqual(WatchCodec.size(reply), WatchLimits.replyBytes + 64)
        XCTAssertLessThanOrEqual(WatchCodec.size(full), WatchLimits.replyBytes)
        let decoded = try XCTUnwrap(try WatchCodec.value(WatchReply.self, in: message))
        XCTAssertEqual(decoded, reply)
        guard case .thread(let back) = decoded.result else { return XCTFail("a thread reply") }
        XCTAssertTrue(back.earlier, "older items left out to fit")
        XCTAssertEqual(back.items.last?.id, full.items.last?.id, "the newest kept")
    }

    /// Claude's thinking is a muted item, other reasoning is left out; the prompt being sent comes last.
    func testThinkingAndTheSendingPromptAreItems() async throws {
        let helper = ScriptedHelper()
        var thinking = ChatFixture.record("claude-r1", "reasoning", turn: "t1", text: "Checking the **retry** path", time: 946_719_000_100)
        thinking["inline_reasoning"] = true
        let hidden = ChatFixture.record("codex-r1", "reasoning", turn: "t1", text: "Hidden summary", time: 946_719_000_200)
        let chat = try await opened(helper, records: [
            ChatFixture.record("t1:started", "turn_started", turn: "t1", time: 946_719_000_000),
            ChatFixture.record("u1", "user", turn: "t1", text: "Fix it", time: 946_719_000_000),
            thinking, hidden,
            ChatFixture.record("a1", "assistant", turn: "t1", text: "Done.", time: 946_719_000_300),
        ])
        chat.send(text: "And add a test", steer: false)
        let page = WatchThreadBuilder.page(chat, row: nil)
        XCTAssertEqual(page.items.map(\.kind), [.user, .thinking, .agent, .user])
        XCTAssertEqual(page.items[1].text, "Checking the retry path")
        XCTAssertEqual(page.items.last?.text, "And add a test")
        XCTAssertEqual(page.items.last?.id, chat.optimisticPrompt?.id)
        XCTAssertNil(page.items[2].caption, "a turn still open has no caption")
    }

    /// Approvals with the phone's chips in its order, question forms and side questions with their parts, the queue
    /// with Send now where the phone allows it, and the composer's route.
    func testRequestsQueueAndRoute() async throws {
        let helper = ScriptedHelper()
        let chat = try await opened(helper, records: [], state: ChatFixture.state(busy: true, activity: "Reading files"))
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        helper.notify(id, "interaction.opened", ["terminal": 7, "session": conversation,
                                                 "interaction": ChatFixture.approval(options: ["Allow", "Deny", "Terminal", "Allow for this session"])])
        helper.notify(id, "interaction.opened", ["terminal": 7, "session": conversation, "interaction": [
            "id": "form-1", "key": NSNull(), "approval": false, "blocking": true, "turn": NSNull(), "record": NSNull(),
            "questions": [["id": "q1", "header": "Runner", "text": "Which runner?", "secret": false, "multiple": true,
                           "custom": false, "blocks": NSNull(),
                           "options": [["id": "a", "label": "headed", "detail": "With a window"], ["id": "b", "label": "headless", "detail": NSNull()]]]]]])
        helper.notify(id, "interaction.opened", ["terminal": 7, "session": conversation, "interaction": [
            "id": "side-1", "key": NSNull(), "approval": false, "blocking": false, "turn": NSNull(), "record": NSNull(),
            "questions": [["id": "s1", "header": "Name", "text": "What should the branch be called?", "secret": false,
                           "multiple": false, "custom": true, "blocks": NSNull(), "options": []],
                          ["id": "s2", "header": "Token", "text": "Paste the token", "secret": true,
                           "multiple": false, "custom": true, "blocks": NSNull(), "options": []]]]])
        helper.notify(id, "chat.queue", ["terminal": 7, "session": conversation, "error": NSNull(), "items": [
            ChatFixture.queued("held-1", "Then run the suite"), ChatFixture.queued("held-2", "Paused one", paused: "stopped")]])
        try await TestSupport.eventually { chat.approvals.count == 2 && chat.questions.count == 1 && chat.queue.count == 2 }

        let page = WatchThreadBuilder.page(chat, row: nil)
        let approval = try XCTUnwrap(page.approvals.first)
        XCTAssertEqual(page.approvals.count, 1)
        XCTAssertEqual(approval.id, "approval-1")
        XCTAssertEqual(approval.title, "Allow the local fixture to print its test marker?")
        XCTAssertEqual(approval.detail, "printf 'DISPATCH_LOCAL_TOOL_OK\\n'")
        XCTAssertEqual(approval.choices.map(\.label), ["Deny", "This session", "Allow"])
        XCTAssertEqual(approval.choices.map(\.role), [.deny, .session, .allow])
        XCTAssertEqual(approval.choices.map(\.index), [1, 3, 0])

        XCTAssertEqual(page.questions.map(\.id), ["form-1", "side-1"])
        let form = page.questions[0]
        XCTAssertTrue(form.blocking)
        XCTAssertEqual(form.parts.first?.options.map(\.label), ["headed", "headless"])
        XCTAssertEqual(form.parts.first?.options.first?.detail, "With a window")
        XCTAssertEqual(form.parts.first?.multiple, true)
        XCTAssertEqual(form.parts.first?.custom, false, "the phone's form offers its options only")
        let side = page.questions[1]
        XCTAssertFalse(side.blocking)
        XCTAssertEqual(side.parts.map(\.custom), [true, true])
        XCTAssertEqual(side.parts.map(\.secret), [false, true])
        XCTAssertFalse(side.answerable, "a secret part is answered on the phone")

        XCTAssertEqual(page.queue.map(\.id), ["helper:held-1", "helper:held-2"])
        XCTAssertEqual(page.queue.map(\.canSendNow), [true, false])
        XCTAssertEqual(page.queue.last?.status, "Paused after Stop.")
        XCTAssertTrue(page.queueStopped)
        XCTAssertTrue(page.working)
        XCTAssertEqual(page.activity, "Reading files")
        XCTAssertNotNil(page.workingSince)
        XCTAssertTrue(page.canStop)
        XCTAssertEqual(page.route, .queue)
        XCTAssertTrue(page.needsYou)
    }

    /// Phases and notes: paused with its reason, detached with the host's problem or the phone's own reason, the terminal
    /// attaching.
    func testPhasesAndNotes() async throws {
        let helper = ScriptedHelper()
        let presence = ChatTerminalPresenceStub()
        presence.publishes = false
        let chat = try await opened(helper, records: [], presence: presence)
        var page = WatchThreadBuilder.page(chat, row: nil)
        XCTAssertEqual(page.notes, ["Attaching the terminal… messages wait in the queue until it shows."])
        XCTAssertEqual(page.route, .queue)

        chat.update(link: .reconnecting(attempt: 2, since: Date(), reason: "Connection refused"), client: nil, problem: "Connection refused")
        page = WatchThreadBuilder.page(chat, row: nil)
        XCTAssertEqual(page.phase, .offline)
        XCTAssertEqual(page.reason, "Connection refused")
        XCTAssertEqual(page.route, .outbox)
        XCTAssertFalse(page.canStop)
        page = WatchThreadBuilder.page(chat, row: nil, offline: WatchFailure.phoneLocked.message)
        XCTAssertEqual(page.reason, WatchFailure.phoneLocked.message)

        chat.update(link: .connected, client: helper.client)
        try await TestSupport.eventually { helper.requests("chat.open").count == 2 }
        chat.update(terminal: nil, binding: nil)
        page = WatchThreadBuilder.page(chat, row: nil)
        XCTAssertEqual(page.phase, .paused)
        XCTAssertEqual(page.reason, "Claude Code exited. This transcript is read-only.")
        XCTAssertEqual(page.notes, [], "the reason is the page's own, not a note too")
    }

    /// The watch shows text only: a user message with attachments starts with a line that names them.
    func testAttachmentsBecomeATextLineOnTheWatch() async throws {
        let helper = ScriptedHelper()
        var withText = ChatFixture.record("user-a", "user", turn: "a", text: "Why is this grey?", time: 946_719_200_000)
        withText["blocks"] = [["kind": "image", "language": NSNull(), "text": "screenshot.png", "path": "/stored/1/screenshot.png"]]
        var only = ChatFixture.record("user-b", "user", turn: "b", text: "", time: 946_719_300_000)
        only["blocks"] = [["kind": "image", "language": NSNull(), "text": "a.png", "path": NSNull()],
                          ["kind": "image", "language": NSNull(), "text": "b.png", "path": NSNull()],
                          ["kind": "file", "language": NSNull(), "text": "notes.txt", "path": "/stored/2/notes.txt"]]
        let chat = try await opened(helper, records: [withText, only])
        let users = WatchThreadBuilder.page(chat, row: nil).items.filter { $0.kind == .user }
        XCTAssertEqual(users.map(\.text), ["📎 Image\nWhy is this grey?", "📎 2 images, 1 file"])
    }
}
