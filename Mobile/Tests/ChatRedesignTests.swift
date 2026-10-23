import Dictation
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// The chat redesign (C1–C6, S6) against the scripted helper and the real helper's recorded pages (Fixtures/Chat):
/// the turn footnote, search, the slash list, side conversations, the goal, the jump pill's count and conversation
/// mode's state machine (a scripted listener and speaker: no audio).
@MainActor
final class ChatRedesignTests: XCTestCase {
    private let conversation = "00000000-0000-4000-8000-000000000201"

    private func helper(_ extra: @escaping (ScriptedHelper.Request) -> ScriptedHelper.Reply? = { _ in nil }) -> ScriptedHelper {
        let helper = ScriptedHelper()
        helper.script { request in
            if let reply = extra(request) { return reply }
            switch request.method {
            case "chat.open": return .open
            case "queue.list": return .result([Any]())
            case "chat.send", "interactions.answer": return .result(["written": true, "may_have_sent": true, "reason": NSNull()])
            case "chat.command": return .result(["kind": "sent", "sent": ["written": true, "may_have_sent": true, "reason": NSNull()]])
            default: return .result(NSNull())
            }
        }
        return helper
    }

    /// Opens a session on `helper`: the pending history with its state, then the page.
    private func opened(_ helper: ScriptedHelper, records: [[String: Any]], earlier: String? = nil,
                        state: [String: Any] = ChatFixture.state(busy: false), key: String = "claude",
                        commands: [String] = []) async throws -> MobileChatSession {
        let chat = MobileChatSession.scripted(helper)
        try await TestSupport.eventually { helper.subscription("chat.open") != nil }
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        var pending = ChatFixture.history(key: key, state: state, pending: true)
        pending["commands"] = commands
        var page = ChatFixture.history(key: key, records: records, earlier: earlier)
        page["commands"] = commands
        helper.notify(id, "chat.history", pending)
        helper.notify(id, "chat.history", page)
        try await TestSupport.eventually { chat.phase == .verified && !chat.loadingHistory }
        return chat
    }

    // MARK: S6 footnote

    func testTheFootnoteSumsTheTurnsStepsTimeAndChangedFiles() async throws {
        let chat = try await opened(helper(), records: ChatFixture.records("claude-thread"))
        let summaries = chat.transcript.rows.compactMap(\.kind.summary)
        XCTAssertEqual(summaries.compactMap(\.footnote), ["5 steps in 1m 26s · 1 file +2 −1", "4 steps in 52s · 2 files +4 −4"])
        XCTAssertEqual(summaries.last?.files, ["/work/app/src/lib/idempotent.ts", "/work/app/src/routes/invoices.ts"],
                       "Distinct paths, in the order first touched")
        XCTAssertEqual(summaries.last?.additions, 4)
        XCTAssertEqual(summaries.last?.deletions, 4)
        XCTAssertEqual(summaries.first?.seconds, 86)
        XCTAssertEqual(summaries.map(\.caption), ["5 steps · 1m 26s", "4 steps · 52s"], "Message details keep their heading")
    }

    func testTheFootnoteSaysWhatItKnows() {
        XCTAssertEqual(ChatTurnSummary(steps: [], duration: 3).footnote, "3s")
        XCTAssertNil(ChatTurnSummary(steps: [], duration: nil).footnote)
        let tool = ChatItem(id: "t", kind: .tool, text: "{}", title: "Bash")
        XCTAssertEqual(ChatTurnSummary(steps: [tool], duration: nil).footnote, "1 step")
        XCTAssertEqual(ChatTurnSummary(steps: [tool, tool], duration: 52).footnote, "2 steps in 52s")
    }

    func testATurnThatOnlyReadSaysWhatItRead() throws {
        let reads = try ChatFixture.records("claude-thread").filter { ["tool-c1", "tool-d1", "tool-d2"].contains($0["id"] as? String) }
        var transcript = MobileTranscript()
        let records = [ChatFixture.record("s", "turn_started", turn: "s1", time: 1_000)] + reads.map { record in
            var record = record
            record["turn"] = "s1"
            return record
        } + [ChatFixture.record("a", "assistant", turn: "s1", text: "The route handler runs first.", time: 13_000),
             ChatFixture.record("e", "turn_ended", turn: "s1", time: 13_000)]
        transcript.apply(try records.map(Self.record), historical: true)
        XCTAssertEqual(transcript.rows.last?.kind.summary?.footnote, "Read 3 files · 12s")
    }

    private static func record(_ value: [String: Any]) throws -> HelperChat.Record {
        try HelperBinary.decode(HelperChat.Record.self, from: try HelperBinary.value(value))
    }

    // MARK: C1 search

    func testSearchCountsMatchesAsTheBubblesDrawThemAndSteps() async throws {
        let chat = try await opened(helper(), records: ChatFixture.records("claude-thread"))
        let search = chat.search
        search.open()
        search.query = "GUARD"
        search.update(rows: chat.transcript.rows)
        XCTAssertEqual(search.matches.count, 2, "Case ignored; one in each answer")
        XCTAssertEqual(search.label, "2 of 2", "The newest match is shown first")
        search.move(-1)
        XCTAssertEqual(search.label, "1 of 2")
        search.move(-1)
        XCTAssertEqual(search.label, "2 of 2", "Wraps")
        search.query = "nothing like this"
        search.update(rows: chat.transcript.rows)
        XCTAssertEqual(search.label, "No results")
        search.close()
        XCTAssertFalse(search.visible)
        XCTAssertEqual(search.query, "")

        var marker = ChatSearchMarker(query: "guard", current: 0)
        _ = MobileChatMarkdownView.contents("A **guard** and a `guard()` call:\n\n```swift\nlet guard = 1\n```", marker: &marker)
        XCTAssertEqual(marker.count, 3, "Bold, inline code and a code block's line, as drawn")
        var strong = ChatSearchMarker(query: "guard", current: 1)
        let marked = strong.mark("guard and guard")
        let runs = marked.runs.filter { $0.backgroundColor != nil }
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.last?.foregroundColor, Color.black, "The shown match is the strong one")
        XCTAssertNil(runs.first?.foregroundColor)
    }

    func testSearchPagesInEarlierMessages() async throws {
        let records = try ChatFixture.records("claude-thread")
        let split = try XCTUnwrap(records.firstIndex { $0["turn"] as? String == "p2" })
        let helper = helper { request in
            request.method == "chat.page" ? .result(["records": Array(records[..<split]), "earlier": NSNull()]) : nil
        }
        let chat = try await opened(helper, records: Array(records[split...]), earlier: "cursor-1")
        let search = chat.search
        search.open()
        search.query = "counter-based"
        search.update(rows: chat.transcript.rows)
        XCTAssertTrue(search.matches.isEmpty, "Only in the first turn, not loaded yet")
        await search.searchEarlier(in: chat)
        XCTAssertFalse(chat.hasEarlier)
        XCTAssertNil(search.status)
        XCTAssertEqual(helper.requests("chat.page").first?.params["earlier"] as? String, "cursor-1")
        search.update(rows: chat.transcript.rows)
        XCTAssertEqual(search.matches.count, 1)
    }

    func testSearchStopsWhenNoMoreCanLoad() async throws {
        let helper = helper()
        let chat = try await opened(helper, records: ChatFixture.records("claude-thread"), earlier: "cursor-1")
        chat.update(link: .reconnecting(attempt: 1, since: Date()), client: nil)
        XCTAssertTrue(chat.hasEarlier)
        XCTAssertFalse(chat.canLoadEarlier, "Not verified: the cursor stays, nothing pages")
        let search = chat.search
        search.open()
        search.query = "nothing like this"
        search.update(rows: chat.transcript.rows)
        await search.searchEarlier(in: chat)
        XCTAssertNil(search.status, "No spinning \"Searching earlier messages…\"")
        XCTAssertEqual(search.label, "No results")
        XCTAssertTrue(helper.requests("chat.page").isEmpty)
    }

    // MARK: C2 slash commands

    func testTheSlashListFiltersAndNamesWhoRunsEachCommand() {
        let claude = ["/btw", "/side", "/terminal", "/model", "/effort", "/init", "/clear", "/compact", "/resume", "/help"]
        let all = ChatSlashCommand.matching("/", commands: claude, agent: "claude", agentName: "Claude Code")
        XCTAssertEqual(all.map(\.name), claude)
        XCTAssertEqual(all.first { $0.name == "/btw" }?.source, "Dispatch")
        XCTAssertEqual(all.first { $0.name == "/terminal" }?.source, "Dispatch")
        XCTAssertEqual(all.first { $0.name == "/compact" }?.source, "Claude Code")
        XCTAssertEqual(all.first { $0.name == "/compact" }?.detail, "Summarise the conversation to free context")
        XCTAssertEqual(ChatSlashCommand.matching("/C", commands: claude, agent: "claude", agentName: "Claude Code").map(\.name),
                       ["/clear", "/compact"], "Filtered as typed, case ignored")
        XCTAssertTrue(ChatSlashCommand.matching("/compact now", commands: claude, agent: "claude", agentName: "Claude Code").isEmpty,
                      "An argument: the command is chosen")
        XCTAssertTrue(ChatSlashCommand.matching("hello", commands: claude, agent: "claude", agentName: "Claude Code").isEmpty)
        XCTAssertEqual(ChatSlashCommand.matching("/", commands: [], agent: "pi", agentName: "Pi").map(\.name), ["/terminal"],
                       "Terminal always, as the Mac's list")
        let codex = ChatSlashCommand.matching("/", commands: ["/goal", "/compact"], agent: "codex", agentName: "Codex")
        XCTAssertEqual(codex.map(\.name), ["/goal", "/compact", "/terminal", "/fork", "/recap"],
                       "Codex's harness runs /fork and /recap without listing them")
        XCTAssertEqual(codex.first { $0.name == "/goal" }?.source, "Dispatch")
        XCTAssertEqual(codex.first { $0.name == "/fork" }?.source, "Codex")
    }

    // MARK: C3 side conversations

    func testASideQuestionForksReadsAndEndsItsOwnConversation() async throws {
        let side = "side-session"
        var binding = ChatFixture.binding
        binding["session"] = side
        let helper = helper { request in
            if request.method == "chat.side" { return .result(binding) }
            return nil
        }
        let chat = try await opened(helper, records: ChatFixture.records("claude-thread"), commands: ["/btw", "/side"])
        let mainRows = chat.transcript.rows.count
        chat.drafts.edit(text: "/btw Which handler runs first?")
        chat.send()
        let asked = try await helper.wait(for: "chat.side")
        XCTAssertEqual(asked.first?.params["question"] as? String, "Which handler runs first?")
        XCTAssertEqual(asked.first?.params["read_only"] as? Bool, true)
        XCTAssertEqual(asked.first?.params["session"] as? String, conversation, "Forked from the main conversation")
        XCTAssertEqual(chat.drafts.current.text, "", "The command left the composer")
        XCTAssertTrue(chat.showingSide)
        let sideChat = try XCTUnwrap(chat.side)
        XCTAssertTrue(sideChat.readOnly)
        XCTAssertEqual(sideChat.pending.map(\.text), ["Which handler runs first?"])

        try await TestSupport.eventually { helper.requests("chat.open").count == 2 }
        let open = try XCTUnwrap(helper.requests("chat.open").last)
        XCTAssertEqual(open.params["session"] as? String, side)
        helper.notify(open.id, "chat.history", ChatFixture.history(session: side, records: [
            ChatFixture.record("q", "user", turn: "s1", text: "Which handler runs first?", time: 1_000),
            ChatFixture.record("a", "assistant", turn: "s1", text: "The route handler.", time: 3_000),
            ChatFixture.record("e", "turn_ended", turn: "s1", time: 3_000)]))
        try await TestSupport.eventually { sideChat.lastAnswer == "The route handler." }
        XCTAssertTrue(sideChat.pending.isEmpty, "The question's record took its pending bubble")
        XCTAssertEqual(chat.transcript.rows.count, mainRows, "The side's replies stay out of the main thread")

        sideChat.draft = "And the second?"
        sideChat.send()
        let sent = try await helper.wait(for: "chat.send")
        XCTAssertEqual(sent.last?.params["session"] as? String, side)
        XCTAssertEqual(sent.last?.params["text"] as? String, "And the second?")

        chat.bringIntoMain("The route handler.\nThen the guard.")
        XCTAssertEqual(chat.drafts.current.text, "> The route handler.\n> Then the guard.\n\n")

        chat.endSide()
        let closed = try await helper.wait(for: "chat.side.close")
        XCTAssertEqual(closed.last?.params["session"] as? String, side, "Closes the fork, not the main conversation")
        XCTAssertNil(chat.side)
        XCTAssertFalse(chat.showingSide)
        XCTAssertTrue(helper.cancellations.contains(open.id), "Its subscription ends")
    }

    func testAllowChangesReopensTheSideWritable() async throws {
        let helper = helper { request in
            guard request.method == "chat.side" else { return nil }
            var binding = ChatFixture.binding
            binding["session"] = "side-\(request.id)"
            return .result(binding)
        }
        let chat = try await opened(helper, records: [], commands: ["/btw", "/side"])
        XCTAssertTrue(chat.openSide(.btw, question: "Can this be fixed?"))
        try await TestSupport.eventually { chat.side?.session != nil }
        chat.allowChanges()
        let asked = try await helper.wait(for: "chat.side", count: 2)
        XCTAssertEqual(asked.last?.params["read_only"] as? Bool, false)
        XCTAssertEqual(asked.last?.params["question"] as? String, "Can this be fixed?")
        XCTAssertEqual(chat.side?.mode, .side)
        _ = try await helper.wait(for: "chat.side.close")
    }

    func testASideCommandTheAgentDoesNotOfferGoesToTheAgent() async throws {
        let helper = helper()
        let chat = try await opened(helper, records: [], commands: ["/model"])
        chat.drafts.edit(text: "/btw hello")
        chat.send()
        _ = try await helper.wait(for: "chat.command")
        XCTAssertNil(chat.side)
    }

    func testEndingASideConversationWhileItsForkStartsClosesTheForkOnceItAnswers() async throws {
        let helper = helper { request in request.method == "chat.side" ? .open : nil }
        let chat = try await opened(helper, records: [], commands: ["/btw", "/side"])
        XCTAssertTrue(chat.openSide(.btw, question: "Which handler runs first?"))
        let asked = try await helper.wait(for: "chat.side")
        chat.endSide()
        XCTAssertNil(chat.side)
        XCTAssertFalse(helper.cancellations.contains(asked[0].id), "The fork's start is never abandoned")
        XCTAssertTrue(helper.requests("chat.side.close").isEmpty, "No session to close yet")
        var binding = ChatFixture.binding
        binding["session"] = "late-fork"
        helper.reply(asked[0].id, .result(binding))
        let closed = try await helper.wait(for: "chat.side.close")
        XCTAssertEqual(closed.last?.params["session"] as? String, "late-fork", "Closed as soon as it exists")
        XCTAssertEqual(helper.requests("chat.open").count, 1, "and never opened")
    }

    func testAForkLeftByALostLinkIsClosedThroughTheNextConnection() async throws {
        var binding = ChatFixture.binding
        binding["session"] = "orphan-fork"
        let first = helper { request in request.method == "chat.side" ? .result(binding) : nil }
        let chat = try await opened(first, records: [], commands: ["/btw"])
        XCTAssertTrue(chat.openSide(.btw, question: "Which handler runs first?"))
        try await TestSupport.eventually { chat.side?.session == "orphan-fork" }
        XCTAssertEqual(chat.openForks, ["orphan-fork"])
        chat.update(link: .reconnecting(attempt: 1, since: Date()), client: nil)
        XCTAssertTrue(chat.side?.ended == true)
        XCTAssertTrue(first.requests("chat.side.close").isEmpty, "Nothing is sent over the dead link")

        let second = helper()
        chat.update(link: .connected, client: second.client)
        try await TestSupport.eventually { second.subscription("chat.open") != nil }
        let id = try XCTUnwrap(second.subscription("chat.open"))
        second.notify(id, "chat.history", ChatFixture.history(records: []))
        let closed = try await second.wait(for: "chat.side.close")
        XCTAssertEqual(closed.last?.params["session"] as? String, "orphan-fork")
        XCTAssertTrue(chat.openForks.isEmpty, "One try: a helper that does not know it refuses")
    }

    // MARK: C4 goal

    func testTheGoalStripReadsTheStateAndItsControlsAreCodexCommands() async throws {
        var state = ChatFixture.state(busy: false)
        state["goal"] = ["objective": "All webhook routes idempotent", "status": "active", "tokensUsed": 48_210,
                         "timeUsedSeconds": 754, "tokenBudget": 200_000]
        state["usage"] = ["info": ["last_token_usage": ["total_tokens": 158_000], "model_context_window": 250_000]]
        state["agents"] = ["explorer", "worker"]
        // `/goal edit` answers once Codex's editor is done, after its question.
        let helper = helper { request in
            request.method == "chat.command" && request.params["text"] as? String == "/goal edit" ? .open : nil
        }
        let chat = try await opened(helper, records: [], state: state, key: "codex")
        let goal = try XCTUnwrap(chat.goal)
        XCTAssertEqual(goal.objective, "All webhook routes idempotent")
        XCTAssertEqual(ChatGoalStrip.state(goal), "working")
        XCTAssertEqual(chat.goalStatus, ["12m 34s on the goal", "2 subagents", "63% context"])
        XCTAssertEqual(ChatGoalSheet.tokens(goal), "48,210 of 200,000")

        chat.goal("pause")
        let paused = try await helper.wait(for: "chat.command")
        XCTAssertEqual(paused.last?.params["text"] as? String, "/goal pause")

        // A new objective goes through Codex's goal editor, answered with the text when it asks.
        chat.setGoal("All routes idempotent, tests green")
        let edit = try await helper.wait(for: "chat.command", count: 2)
        XCTAssertEqual(edit.last?.params["text"] as? String, "/goal edit")
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        helper.notify(id, "interaction.opened", ["terminal": 7, "session": conversation, "interaction": [
            "id": "command:\(conversation)", "key": NSNull(), "approval": false, "blocking": true, "turn": NSNull(),
            "record": NSNull(), "questions": [["id": "goal", "header": "Edit goal", "text": "Goal objective", "secret": false,
                                               "multiple": false, "custom": true, "options": [], "blocks": []]]]])
        let answered = try await helper.wait(for: "interactions.answer")
        XCTAssertEqual(answered.last?.params["interaction"] as? String, "command:\(conversation)")
        XCTAssertEqual((answered.last?.params["answers"] as? [String: Any])?["goal"] as? String, "All routes idempotent, tests green")
        XCTAssertTrue(chat.questions.isEmpty, "Not shown as a question")
    }

    func testWithoutAGoalTheObjectiveSetsOne() async throws {
        let helper = helper()
        let chat = try await opened(helper, records: [], key: "codex")
        XCTAssertNil(chat.goal)
        XCTAssertTrue(chat.goalStatus.isEmpty)
        chat.setGoal("Ship it")
        let set = try await helper.wait(for: "chat.command")
        XCTAssertEqual(set.last?.params["text"] as? String, "/goal Ship it")
    }

    func testAFailedGoalEditForgetsTheObjective() async throws {
        var state = ChatFixture.state(busy: false)
        state["goal"] = ["objective": "Old", "status": "active", "tokensUsed": 1, "timeUsedSeconds": 1]
        let helper = helper { request in
            request.method == "chat.command" ? .failure(code: "goal", message: "The goal editor changed.") : nil
        }
        let chat = try await opened(helper, records: [], state: state, key: "codex")
        chat.setGoal("New")
        try await TestSupport.eventually { chat.failure != nil }
        // A later goal question is Codex's own, not the failed edit's: it shows as a question.
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        helper.notify(id, "interaction.opened", ["terminal": 7, "session": conversation, "interaction": [
            "id": "command:\(conversation)", "key": NSNull(), "approval": false, "blocking": true, "turn": NSNull(),
            "record": NSNull(), "questions": [["id": "goal", "header": "Edit goal", "text": "Goal objective", "secret": false,
                                               "multiple": false, "custom": true, "options": [], "blocks": []]]]])
        try await TestSupport.eventually { !chat.questions.isEmpty }
        XCTAssertTrue(helper.requests("interactions.answer").isEmpty)
        XCTAssertEqual(ChatGoalSheet.oneLine("Ship it\nand test\n"), "Ship it and test")
    }

    // MARK: C2 Return

    func testReturnFromAHardwareKeyboardPicksTheLitSlashRowThenSends() async throws {
        let helper = helper()
        let chat = try await opened(helper, records: [], commands: ["/btw", "/compact", "/clear"])
        let found = await TestSupport.windowScene()
        let scene = try XCTUnwrap(found)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let view = CodeTextView()
        view.frame = CGRect(x: 0, y: 100, width: 300, height: 40)
        window.rootViewController?.view.addSubview(view)
        view.changed = { chat.drafts.edit(text: $0) }
        view.keyState = { (false, false) }
        view.keyAction = { if $0 == .send { chat.sendFromComposer(showTerminal: nil) } }
        XCTAssertTrue(view.becomeFirstResponder())
        func returnKey() {
            view.hardwareKey(view.keyCommands!.first { $0.input == "\r" && $0.modifierFlags.isEmpty }!)
        }
        chat.drafts.edit(text: "/c")
        XCTAssertEqual(chat.slashCommands.map(\.name), ["/compact", "/clear"])
        returnKey()
        XCTAssertEqual(chat.drafts.current.text, "/compact ", "Return picked the lit row")
        XCTAssertTrue(helper.requests("chat.command").isEmpty, "and sent nothing")
        XCTAssertTrue(chat.slashCommands.isEmpty, "The list is gone once the command is chosen")
        returnKey()
        let sent = try await helper.wait(for: "chat.command")
        XCTAssertEqual(sent.last?.params["text"] as? String, "/compact ")

        chat.drafts.edit(text: "/clear")
        XCTAssertEqual(chat.sendFromComposer(showTerminal: nil), .sent, "The draft is the lit command already: it goes")
        var shown = false
        chat.drafts.edit(text: "/terminal")
        XCTAssertEqual(chat.sendFromComposer(showTerminal: { shown = true }), .terminal)
        XCTAssertTrue(shown)
        XCTAssertEqual(ChatSlashCommand.agentName(label: nil, key: "claude"), "Claude Code")
        XCTAssertEqual(ChatSlashCommand.agentName(label: "claude", key: "claude"), "Claude Code")
        XCTAssertEqual(ChatSlashCommand.agentName(label: "Codex", key: "codex"), "Codex")
    }

    // MARK: C6 jump to latest

    func testTheJumpPillCountsRowsAddedAtTheEndOnly() throws {
        func row(_ id: String) -> ChatThreadRow {
            ChatThreadRow(id: id, kind: .user, item: ChatItem(id: id, kind: .user, text: id), turnID: "t", time: nil)
        }
        let rows = ["a", "b", "c", "d"].map(row)
        XCTAssertEqual(ChatThreadView.appended(rows, after: "b"), 2, "Two came after")
        XCTAssertEqual(ChatThreadView.appended(rows, after: "d"), 0)
        XCTAssertEqual(ChatThreadView.appended(rows, after: nil), 0, "The first load")
        XCTAssertEqual(ChatThreadView.appended(rows, after: "gone"), 0, "A replaced transcript")
        XCTAssertEqual(ChatThreadView.appended([row("z")] + rows, after: "d"), 0, "An earlier page above")
    }

    // MARK: C5 conversation mode

    func testConversationModeCollectsWordsSendsOnAPauseAndReadsTheReply() async throws {
        let helper = helper()
        let chat = try await opened(helper, records: ChatFixture.records("claude-thread"))
        let listener = ScriptedListener(), speaker = ScriptedSpeaker()
        let voice = MobileVoiceConversation(listener: listener, speaker: speaker)
        voice.sendDelay = .milliseconds(20)
        voice.echoDelay = .zero
        voice.start(chat)
        XCTAssertTrue(voice.active(for: chat))
        XCTAssertTrue(listener.listening)
        voice.check()
        XCTAssertTrue(speaker.spoken.isEmpty, "What was there before is not read")

        listener.update?(.heard("add a test"))
        XCTAssertEqual(voice.heard, "add a test")
        listener.update?(.utterance("Add a test"))
        listener.update?(.utterance("for the retry path"))
        XCTAssertEqual(voice.message, "Add a test for the retry path")
        let sent = try await helper.wait(for: "chat.send")
        XCTAssertEqual(sent.last?.params["text"] as? String, "Add a test for the retry path")
        XCTAssertEqual(voice.message, "")
        XCTAssertEqual(voice.note, "Sent")
        XCTAssertEqual(chat.drafts.current.text, "", "The composer's draft is untouched")

        // The reply's turn ends: read aloud, the microphone muted meanwhile.
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        helper.notify(id, "chat.records", ["terminal": 7, "session": conversation, "records": [
            ChatFixture.record("p3:s", "turn_started", turn: "p3", time: 946_719_400_000),
            ChatFixture.record("p3:u", "user", turn: "p3", text: "Add a test for the retry path", time: 946_719_400_000),
            ChatFixture.record("p3:a", "assistant", turn: "p3", text: "Added **one** test.\n\n```ts\nit()\n```", time: 946_719_409_000),
            ChatFixture.record("p3:e", "turn_ended", turn: "p3", time: 946_719_409_000)]])
        try await TestSupport.eventually { chat.transcript.rows.last?.item.text.hasPrefix("Added") == true }
        voice.check()
        XCTAssertEqual(speaker.spoken, ["Added one test.\nThere's a code block on screen."])
        XCTAssertEqual(voice.phase, .speaking)
        XCTAssertEqual(voice.reading?.row, chat.transcript.rows.last?.id, "The footnote goes under the reply")
        XCTAssertTrue(listener.muted, "Half-duplex: it does not hear itself")
        speaker.finish()
        XCTAssertEqual(voice.phase, .listening)
        XCTAssertNil(voice.reading)
        try await TestSupport.eventually { !listener.muted }
        voice.check()
        XCTAssertEqual(speaker.spoken.count, 1, "Read once")
    }

    func testConversationModesCommandsAndStoppingKeepsUnsentWords() async throws {
        let helper = helper()
        let chat = try await opened(helper, records: [])
        let listener = ScriptedListener(), speaker = ScriptedSpeaker()
        let voice = MobileVoiceConversation(listener: listener, speaker: speaker)
        voice.sendDelay = .seconds(60)
        voice.start(chat)
        listener.update?(.utterance("Fix the login bug"))
        listener.update?(.utterance("and the logout one"))
        listener.update?(.utterance("scratch that"))
        XCTAssertEqual(voice.message, "Fix the login bug")
        listener.update?(.utterance("Dispatch, send"))
        let sent = try await helper.wait(for: "chat.send")
        XCTAssertEqual(sent.last?.params["text"] as? String, "Fix the login bug")
        listener.update?(.utterance("Also check the tests. Dispatch, send."))
        // The agent works on the first one now: the second queues, as the composer's would.
        let again = try await helper.wait(for: "queue.add")
        XCTAssertEqual(again.last?.params["text"] as? String, "Also check the tests.", "A trailing command after its words")
        listener.update?(.utterance("send"))
        XCTAssertEqual(voice.note, "Nothing to send")
        listener.update?(.utterance("Dispatch, open the pod bay doors"))
        XCTAssertEqual(voice.note, "Not a chat command")

        listener.update?(.utterance("Half a thought"))
        listener.update?(.heard("and more"))
        voice.stop()
        XCTAssertEqual(voice.phase, .off)
        XCTAssertFalse(listener.listening)
        XCTAssertEqual(chat.drafts.current.text, "Half a thought and more", "Unsent words go to the draft")

        voice.start(chat)
        listener.update?(.utterance("stop listening"))
        XCTAssertEqual(voice.phase, .off)
        voice.start(chat)
        listener.update?(.ended)
        XCTAssertEqual(voice.phase, .off, "The listener stopping ends conversation mode")
    }

    func testAPartialThatNeverFinalizesDoesNotHoldBackTheSendOrTheReading() async throws {
        let helper = helper()
        let chat = try await opened(helper, records: ChatFixture.records("claude-thread"))
        let listener = ScriptedListener(), speaker = ScriptedSpeaker()
        let voice = MobileVoiceConversation(listener: listener, speaker: speaker)
        voice.sendDelay = .milliseconds(20)
        voice.echoDelay = .zero
        voice.heardTimeout = .milliseconds(60)
        voice.start(chat)
        listener.update?(.utterance("Add a test"))
        // A cough the recognizer heard as a word, then finalized as nothing: no utterance follows.
        listener.update?(.heard("uh"))
        XCTAssertEqual(voice.heard, "uh")
        let sent = try await helper.wait(for: "chat.send")
        XCTAssertEqual(sent.last?.params["text"] as? String, "Add a test", "Sent once the stale partial expired")
        XCTAssertEqual(voice.heard, "")

        listener.update?(.heard("hm"))
        voice.readLast()
        XCTAssertTrue(speaker.spoken.isEmpty, "Never over words being spoken")
        try await TestSupport.eventually { !speaker.spoken.isEmpty }
        XCTAssertEqual(voice.phase, .speaking, "Read once the partial went stale")
        voice.stop()
    }

    func testRepliesAreSpokenWithoutMarkdown() {
        XCTAssertEqual(MobileVoiceConversation.spoken("# Done\n\n- one\n- **two**\n\n| a | b |\n|---|---|\n| 1 | 2 |"),
                       "Done\none\ntwo\nThere's a table on screen.")
        XCTAssertEqual(MobileVoiceConversation.clock(8.4), "0:08")
        XCTAssertEqual(MobileVoiceConversation.clock(72), "1:12")
        XCTAssertEqual(MobileVoiceConversation.command("send it"), .send)
        XCTAssertEqual(MobileVoiceConversation.command("Captain, stop listening"), .stopListening)
        XCTAssertNil(MobileVoiceConversation.command("send the email to Sam"))
    }
}

/// Conversation mode's ears in tests: updates are delivered by hand.
@MainActor final class ScriptedListener: VoiceListener {
    var level: Float = 0.5
    var error: String? = nil
    private(set) var listening = false
    private(set) var muted = false
    var update: (@MainActor (DictationUpdate) -> Void)?
    func start(update: @escaping @MainActor (DictationUpdate) -> Void) { listening = true; self.update = update }
    func mute(_ muted: Bool) { self.muted = muted }
    func stop() { listening = false; update = nil }
}

/// Conversation mode's voice in tests: what it was asked to say; `finish` ends the reading.
@MainActor final class ScriptedSpeaker: VoiceSpeaker {
    private(set) var spoken: [String] = []
    private var finished: (@MainActor () -> Void)?
    func speak(_ text: String, finished: @escaping @MainActor () -> Void) { spoken.append(text); self.finished = finished }
    func stop() { finish() }
    func finish() { let finished = finished; self.finished = nil; finished?() }
}
