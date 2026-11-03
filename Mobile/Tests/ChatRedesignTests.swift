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

    // MARK: S6d corner

    /// A calendar with fixed zone and locale (no wall clock, no device settings).
    private static func calendar(_ locale: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: locale)
        return calendar
    }

    /// 2026-10-29 (a Thursday) at `hour`:`minute` UTC, `days` later.
    private static func date(days: Int = 0, hour: Int, minute: Int, year: Int = 2026, month: Int = 10, day: Int = 29) -> Date {
        calendar("en_GB").date(from: DateComponents(year: year, month: month, day: day + days, hour: hour, minute: minute))!
    }

    func testTheCornerSaysWhatTheTurnChangedAndWhenItEnded() async throws {
        let chat = try await opened(helper(), records: ChatFixture.records("claude-thread"))
        let summaries = chat.transcript.rows.compactMap(\.kind.summary)
        let gb = Self.calendar("en_GB")
        // The fixture's turns end on 2000-01-01 at 09:31:26 and 09:32:52 UTC.
        let now = gb.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: 18))!
        XCTAssertEqual(summaries.map { $0.corner(now: now, calendar: gb) }, ["idempotent.ts +2 −1 · 09:31", "2 files +4 −4 · 09:32"],
                       "One file by its name, several by their count")
        XCTAssertEqual(summaries.map { $0.spokenCorner(now: now, calendar: gb) },
                       ["idempotent.ts, 2 added, 1 removed, 09:31", "2 files, 4 added, 4 removed, 09:32"])
        XCTAssertEqual(summaries.last?.files, ["/work/app/src/lib/idempotent.ts", "/work/app/src/routes/invoices.ts"],
                       "Distinct paths, in the order first touched")
        XCTAssertEqual(summaries.last?.additions, 4)
        XCTAssertEqual(summaries.last?.deletions, 4)
        XCTAssertEqual(summaries.first?.seconds, 86)
        XCTAssertEqual(summaries.map(\.caption), ["5 steps · 1m 26s", "4 steps · 52s"], "Message details keep their heading")
    }

    func testTheCornerSaysWhatItKnows() {
        let gb = Self.calendar("en_GB"), now = Self.date(hour: 15, minute: 0), ended = Self.date(hour: 10, minute: 17)
        let tool = ChatItem(id: "t", kind: .tool, text: "{}", title: "Bash")
        XCTAssertNil(ChatTurnSummary(steps: [], duration: 3, ended: ended).corner(now: now, calendar: gb), "a plain answer")
        XCTAssertNil(ChatTurnSummary(steps: [tool, tool], duration: 52, ended: ended).corner(now: now, calendar: gb),
                     "two steps that changed nothing are still a plain answer")
        XCTAssertEqual(ChatTurnSummary(steps: [tool, tool, tool], duration: 52, ended: ended).corner(now: now, calendar: gb),
                       "3 steps · 10:17")
        XCTAssertEqual(ChatTurnSummary(steps: Array(repeating: tool, count: 40), duration: nil, ended: ended).corner(now: now, calendar: gb),
                       "40 steps · 10:17", "the duration leaves the thread")
        XCTAssertEqual(ChatTurnSummary(steps: [tool, tool, tool], duration: nil).corner(now: now, calendar: gb), "3 steps",
                       "no end time: no time")

        var many = ChatTurnSummary(steps: [tool], duration: 300, ended: ended)
        many.files = (1...14).map { "/work/app/src/file\($0).ts" }
        many.additions = 1_204
        many.deletions = 380
        XCTAssertEqual(many.corner(now: now, calendar: gb), "14 files +1,204 −380 · 10:17", "grouped digits")
        XCTAssertEqual(many.spokenCorner(now: now, calendar: gb), "14 files, 1,204 added, 380 removed, 10:17")
        var one = ChatTurnSummary(steps: [tool], duration: 300)
        one.files = ["/work/app/src/lib/idempotent.ts"]
        one.additions = 38
        one.deletions = 4
        XCTAssertEqual(one.corner(now: now, calendar: gb), "idempotent.ts +38 −4", "a single step that changed a file counts")
    }

    func testTheCornersTimeIsTheDayAsAMessengerSaysIt() {
        let gb = Self.calendar("en_GB"), us = Self.calendar("en_US"), now = Self.date(hour: 15, minute: 0)
        let tool = ChatItem(id: "t", kind: .tool, text: "{}", title: "Bash")
        func corner(_ ended: Date, _ calendar: Calendar) -> String? {
            ChatTurnSummary(steps: [tool, tool, tool], duration: nil, ended: ended).corner(now: now, calendar: calendar)
        }
        XCTAssertEqual(corner(Self.date(hour: 10, minute: 17), gb), "3 steps · 10:17", "today: the time alone")
        let twelveHour = corner(Self.date(hour: 10, minute: 17), us)
        XCTAssertTrue(twelveHour?.hasPrefix("3 steps · 10:17") == true && twelveHour?.hasSuffix("AM") == true,
                      "the locale's short time: \(twelveHour ?? "nil")")
        XCTAssertEqual(corner(Self.date(hour: 0, minute: 5), gb), "3 steps · 00:05", "just after midnight is today")
        XCTAssertEqual(corner(Self.date(days: -1, hour: 23, minute: 59), gb), "3 steps · Yesterday 23:59")
        XCTAssertEqual(corner(Self.date(days: -1, hour: 10, minute: 17), gb), "3 steps · Yesterday 10:17")
        XCTAssertEqual(corner(Self.date(days: -2, hour: 10, minute: 17), gb), "3 steps · Tue 10:17", "within a week: the weekday")
        XCTAssertEqual(corner(Self.date(days: -6, hour: 10, minute: 17), gb), "3 steps · Fri 10:17")
        XCTAssertEqual(corner(Self.date(days: -7, hour: 10, minute: 17), us), "3 steps · Oct 22", "older: the date")
        XCTAssertEqual(corner(Self.date(hour: 10, minute: 17, year: 2025, month: 10, day: 12), us), "3 steps · Oct 12, 2025",
                       "another year names it")
        XCTAssertEqual(corner(Self.date(days: 1, hour: 10, minute: 17), us), "3 steps · Oct 30",
                       "a clock a day ahead of the phone's: the date, never a negative day")
        let late = Self.date(hour: 23, minute: 58)
        let ahead = ChatTurnSummary(steps: [tool, tool, tool], duration: nil, ended: Self.date(days: 1, hour: 0, minute: 3))
        XCTAssertEqual(ahead.corner(now: late, calendar: gb), "3 steps · 00:03", "a host's clock minutes ahead past midnight: today")
        let german = corner(Self.date(days: -1, hour: 10, minute: 17), Self.calendar("de_DE"))
        XCTAssertEqual(german?.lowercased(), "3 steps · gestern 10:17", "the locale's word for yesterday")
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
        let gb = Self.calendar("en_GB")
        let now = gb.date(from: DateComponents(year: 1970, month: 1, day: 1, hour: 12))!
        XCTAssertEqual(transcript.rows.last?.kind.summary?.corner(now: now, calendar: gb), "Read 3 files · 00:00")
        XCTAssertEqual(transcript.rows.last?.kind.summary?.caption, "3 steps · 12s")
    }

    func testATurnReadWithoutTimesHasACornerWithoutTime() throws {
        var transcript = MobileTranscript()
        let tools = try ChatFixture.records("claude-thread").filter { ["tool-c1", "tool-d1", "tool-d2"].contains($0["id"] as? String) }
            .map { record in
                var record = record
                record["turn"] = "t1"
                record["time_ms"] = NSNull()
                return record
            }
        transcript.apply(try ([ChatFixture.record("s", "turn_started", turn: "t1"),
                               ChatFixture.record("u", "user", turn: "t1", text: "hi")] + tools
                              + [ChatFixture.record("a", "assistant", turn: "t1", text: "hello"),
                                 ChatFixture.record("e", "turn_ended", turn: "t1")]).map(Self.record), historical: true)
        let summary = try XCTUnwrap(transcript.rows.last?.kind.summary)
        XCTAssertNil(summary.ended, "the epoch a timeless record reads as is no end time")
        XCTAssertEqual(summary.corner(now: Self.date(hour: 15, minute: 0), calendar: Self.calendar("en_GB")), "Read 3 files")
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
        state["agents"] = [["id": "goal-explorer", "kind": "explorer"],
                           ["id": "goal-worker", "kind": "worker"]]
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

/// S6d: the turn's summary sits in its last bubble's corner, where messengers put a message's time, and the text keeps
/// its room; Claude's thinking is an agent bubble of its own.
extension ChatRedesignTests {
    func testTheSummarySitsInTheReplysCornerAndThinkingIsABubble() async throws {
        var records = try ChatFixture.records("claude-thread")
        let question = try XCTUnwrap(records.firstIndex { $0["kind"] as? String == "user" })
        let thought = "Checking how retries reach the handler."
        var thinking = ChatFixture.record("claude-thinking-1", "reasoning", turn: try XCTUnwrap(records[question]["turn"] as? String),
                                          text: thought, time: (records[question]["time_ms"] as? Int64).map { $0 + 1 })
        thinking["inline_reasoning"] = true
        records.insert(thinking, at: question + 1)
        let chat = try await opened(helper(), records: records)
        XCTAssertTrue(chat.transcript.rows.contains { $0.kind == .thinking && $0.item.text == thought })
        let summary = try XCTUnwrap(chat.transcript.rows.compactMap(\.kind.summary).first)
        let spoken = try XCTUnwrap(summary.spokenCorner(now: Date(), calendar: .autoupdatingCurrent))

        AccessibilityLabelTests.enableAccessibility()
        let found = await TestSupport.windowScene()
        let window = UIWindow(windowScene: try XCTUnwrap(found))
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 2600)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ChatThreadView(session: chat, space: "app", directory: "/work/app", startsAtTop: true)
        }.environment(\.colorScheme, .dark))
        window.isHidden = false
        defer { window.isHidden = true }
        var elements: [NSObject] = []
        try await TestSupport.eventually(diagnostic: "\(elements.compactMap(\.accessibilityLabel))") {
            elements = AccessibilityLabelTests.elements(in: window)
            return elements.contains { $0.accessibilityLabel?.hasPrefix("Stripe retries the same event") == true && $0.accessibilityValue == spoken }
                && elements.contains { $0.accessibilityLabel == thought }
        }
        let reply = try XCTUnwrap(elements.first { $0.accessibilityLabel?.hasPrefix("Stripe retries the same event") == true })
        let label = try XCTUnwrap(reply.accessibilityLabel)
        XCTAssertFalse(label.contains("idempotent") || label.contains("\u{2060}") || label.hasSuffix(" "),
                       "the text alone, the corner's room is not read: \(label)")
        XCTAssertEqual(reply.accessibilityValue, spoken, "the corner is the reply's value")
        XCTAssertEqual(reply.accessibilityHint, "Shows the steps")
        XCTAssertFalse(elements.contains { $0.accessibilityLabel?.contains("+2 −1") == true }, "no element of its own")
        XCTAssertFalse(elements.contains { $0.accessibilityLabel == thought && $0.accessibilityValue?.isEmpty == false },
                       "thinking has no corner")

        // The thinking's text sits on an agent bubble: the bubble's grey shows in its padding, left of the text.
        let text = try XCTUnwrap(elements.first { $0.accessibilityLabel == thought }).accessibilityFrame
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let probe = CGPoint(x: text.minX - 7, y: text.midY)
        let canvas = UIColor(Color.canvas).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        XCTAssertNotEqual(Self.pixel(image, at: probe), Self.rgb(canvas), "a bubble behind the thinking, not the canvas")
    }

    func testEveryReplyHasItsTimeAndTheTurnsLastOneItsSummary() {
        let metrics = ChatCornerMetrics(column: 370, measure: ChatMeasure.standard, size: .large)
        let now = Date(), written = now.addingTimeInterval(-60)
        let time = ChatTurnSummary.time(written, now: now, calendar: .autoupdatingCurrent)
        let reply = ChatCorner.reply(time: written, summary: nil, now: now, metrics: metrics)
        XCTAssertEqual(reply?.room, time)
        XCTAssertEqual(reply?.spoken, time)
        XCTAssertNil(reply?.hint)
        let plain = ChatTurnSummary(steps: [], duration: 3, ended: written)
        XCTAssertEqual(ChatCorner.reply(time: written, summary: plain, now: now, metrics: metrics)?.room, time,
                       "a plain answer, the turn's last reply, has its time")
        let tool = ChatItem(id: "t", kind: .tool, text: "", title: "Bash", completed: true)
        let busy = ChatTurnSummary(steps: [tool, tool, tool], duration: 52, ended: written)
        let summary = ChatCorner.reply(time: written, summary: busy, now: now, metrics: metrics)
        XCTAssertEqual(summary?.room, busy.corner(now: now, calendar: .autoupdatingCurrent))
        XCTAssertEqual(summary?.hint, "Shows the steps")
        XCTAssertNil(ChatCorner.reply(time: nil, summary: nil, now: now, metrics: metrics), "read without a time")
    }

    /// The 0...255 channels of `image` at `point`.
    private static func pixel(_ image: UIImage, at point: CGPoint) -> [Int] {
        let cg = image.cgImage!
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: -point.x * image.scale, y: -(CGFloat(cg.height) - point.y * image.scale),
                                    width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return pixel.prefix(3).map(Int.init)
    }

    private static func rgb(_ color: UIColor) -> [Int] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue].map { Int(($0 * 255).rounded()) }
    }
}

/// S6d's layout: the corner shares the last line when it leaves room, else takes a short line of its own; after code,
/// a table, a rule or a cut preview, beside text running the other way, or when it is too wide for a line, it takes
/// trailing lines of its own. The search never sees the room.
extension ChatRedesignTests {
    /// A summary corner as the thread builds it, at `size` in a `width` point column.
    static func summaryCorner(_ text: String, width: CGFloat = 370, size: DynamicTypeSize = .large) -> ChatCorner {
        let metrics = ChatCornerMetrics(column: width, measure: ChatMeasure.standard, size: size)
        return ChatCorner(room: text, fits: metrics.fits(text), view: { AnyView(ChatTurnCorner(text: text, wrapped: $0)) },
                          spoken: text)
    }

    /// The agent bubble's size in a `width` point column, with `corner` in its corner.
    static func bubbleSize(_ text: String, corner: String?, width: CGFloat = 370, size: DynamicTypeSize = .large,
                           direction: LayoutDirection = .leftToRight) -> CGSize {
        let bubble = ChatBubble(side: .agent) {
            MobileChatMarkdownView(text: text, corner: corner.map { summaryCorner($0, width: width, size: size) })
        }
        .environment(\.chatColumnWidth, width)
        .environment(\.dynamicTypeSize, size)
        .environment(\.layoutDirection, direction)
        let host = UIHostingController(rootView: bubble)
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    func testTheCornerSharesTheLastLineOrTakesAShortLineOfItsOwn() {
        let corner = "3 files +127 −22 · 10:17"
        let short = "Done, tests pass."
        let line = Self.bubbleSize(short, corner: nil).height
        XCTAssertEqual(Self.bubbleSize(short, corner: corner).height, line, accuracy: 0.5, "one line, the corner on it")

        let twoLines = "Right, the invoice.paid path has its own handler and bypasses the guard. Both routes get it."
        let two = Self.bubbleSize(twoLines, corner: nil).height
        XCTAssertGreaterThan(two, line + 10)
        XCTAssertEqual(Self.bubbleSize(twoLines, corner: corner).height, two, accuracy: 0.5, "a short last line keeps the corner")

        // The longest text that still fits one line: the corner cannot share it.
        var full = "Moving"
        for word in String(repeating: "the check into shared middleware ", count: 4).split(separator: " ") {
            let longer = full + " " + word
            if Self.bubbleSize(longer, corner: nil).height > line + 0.5 { break }
            full = longer
        }
        let wrapped = Self.bubbleSize(full, corner: corner).height
        XCTAssertGreaterThan(wrapped, line + 5, "a full last line: the corner wraps to a line of its own")
        XCTAssertLessThan(wrapped, two, "a short line, the corner's height, not a line of text")
    }

    func testAfterCodeATableOrARuleTheCornerTakesALineOfItsOwn() {
        let corner = "3 files +127 −22 · 10:17"
        for text in ["Run this:\n\n```sh\npnpm test billing\n```", "| file | lines |\n|---|---|\n| a.ts | 3 |", "Done.\n\n---"] {
            let plain = Self.bubbleSize(text, corner: nil).height
            let after = Self.bubbleSize(text, corner: corner).height
            XCTAssertGreaterThan(after, plain + 5, "a line of its own after: \(text)")
            XCTAssertLessThan(after, plain + 30, text)
        }
        let fits = Self.summaryCorner(corner)
        var marker = ChatSearchMarker(query: "", current: nil)
        let blocks = MobileChatMarkdownView.contents("Done.", marker: &marker).blocks
        XCTAssertTrue(MobileChatMarkdownView.sharesLine(fits, blocks: blocks, truncated: false, layout: .leftToRight))
        XCTAssertFalse(MobileChatMarkdownView.sharesLine(fits, blocks: blocks, truncated: true, layout: .leftToRight),
                       "after a cut preview's note")
    }

    func testALongFileNameIsShortenedAndALargeTextCornerWrapsInsideTheBubble() {
        let tool = ChatItem(id: "t", kind: .tool, text: "{}", title: "Bash")
        var summary = ChatTurnSummary(steps: [tool], duration: 300, ended: Self.date(days: -1, hour: 10, minute: 17))
        summary.files = ["/work/app/src/routes/PaymentWebhookIdempotencyMiddleware.test.ts"]
        summary.additions = 38
        summary.deletions = 4
        let gb = Self.calendar("en_GB"), now = Self.date(hour: 15, minute: 0)
        XCTAssertEqual(summary.corner(now: now, calendar: gb), "PaymentWebhookIdempotencyMiddleware.test.ts +38 −4 · Yesterday 10:17")
        let metrics = ChatCornerMetrics(column: 370, measure: ChatMeasure.standard, size: .large)
        let short = try? XCTUnwrap(summary.corner(now: now, calendar: gb, fits: metrics.fits))
        XCTAssertTrue(short?.contains("…") == true && short?.hasSuffix(".ts +38 −4 · Yesterday 10:17") == true
                      && short?.hasPrefix("Payment") == true, "the name's middle goes, counts and time stay: \(short ?? "")")
        XCTAssertTrue(metrics.fits(short ?? ""))
        let drawn = UIHostingController(rootView: ChatTurnCorner(text: short ?? "")).sizeThatFits(in: CGSize(width: 1000, height: 100)).width
        XCTAssertLessThanOrEqual(drawn, metrics.column, "never wider than the bubble's text")

        // The largest text size: no name to shorten, too wide for a line; it wraps on lines of its own inside the bubble.
        let many = "14 files +1,204 −380 · Yesterday 10:17"
        XCTAssertFalse(Self.summaryCorner(many, size: .accessibility5).fits)
        let plain = Self.bubbleSize("Done.", corner: nil, size: .accessibility5)
        let wrapped = Self.bubbleSize("Done.", corner: many, size: .accessibility5)
        XCTAssertLessThanOrEqual(wrapped.width, 370)
        XCTAssertGreaterThan(wrapped.height, plain.height * 2, "the corner's own lines under the text: \(plain) \(wrapped)")
    }

    func testTextRunningAgainstTheLayoutGivesTheCornerALineOfItsOwn() {
        XCTAssertEqual(MobileChatMarkdownView.direction(of: "שלום, הבדיקה עברה."), .rightToLeft)
        XCTAssertEqual(MobileChatMarkdownView.direction(of: "42 — تم."), .rightToLeft, "digits and dashes are not letters")
        XCTAssertEqual(MobileChatMarkdownView.direction(of: "Done, שלום."), .leftToRight)
        XCTAssertNil(MobileChatMarkdownView.direction(of: "42 + 7"))
        let corner = "3 files +127 −22 · 10:17"
        let hebrew = "הבדיקה עברה."
        let line = Self.bubbleSize(hebrew, corner: nil).height
        XCTAssertGreaterThan(Self.bubbleSize(hebrew, corner: corner).height, line + 5,
                             "a right-to-left reply in a left-to-right thread: the corner never overdraws its end")
        XCTAssertEqual(Self.bubbleSize(hebrew, corner: corner, direction: .rightToLeft).height,
                       Self.bubbleSize(hebrew, corner: nil, direction: .rightToLeft).height, accuracy: 0.5,
                       "running the layout's way it shares the line")
        let english = "Done, tests pass."
        XCTAssertGreaterThan(Self.bubbleSize(english, corner: corner, direction: .rightToLeft).height,
                             Self.bubbleSize(english, corner: nil, direction: .rightToLeft).height + 5, "and the mirror case")
    }

    func testTheSearchNeverMarksTheCornersRoom() throws {
        var marker = ChatSearchMarker(query: "files", current: 0)
        let blocks = MobileChatMarkdownView.contents("Checked 3 files.", marker: &marker).blocks
        XCTAssertEqual(marker.count, 1)
        guard case .text(_, let text)? = blocks.last else { return XCTFail("a paragraph") }
        let joined = MobileChatMarkdownView.joined(text, room: "3 files +2 −1 · 10:17")
        let marked = joined.runs.filter { $0.backgroundColor != nil }.map { String(joined[$0.range].characters) }
        XCTAssertEqual(marked, ["files"], "the text's match only, not the room's")
        let room = try XCTUnwrap(joined.runs.last)
        XCTAssertNil(room.backgroundColor)
        XCTAssertEqual(room.foregroundColor, .clear)
        XCTAssertTrue(String(joined.characters).hasPrefix("Checked 3 files."))
    }
}

/// M5a with S6d: the working row stays under the thread for as long as the agent works, its answer begun or not, and
/// counts the steps since the agent last wrote (the Mac's live tool group); a reply's corner has its time until the
/// turn's end puts the summary on its last one, in the same update as the row goes. State and records arrive apart, in
/// either order: no state in between shows (neither row nor summary, the row back), checked at every turn of the main
/// loop. The hold that rides that out (`chatSettle`) is set per test, so no check depends on the wall clock.
extension ChatRedesignTests {
    /// The thread in a window, the fixture's second turn still open: its steps in, `answered` with its answer.
    private func openTurnThread(answered: Bool, busy: Bool = true, hold: TimeInterval = 600)
        async throws -> (MobileChatSession, ScriptedHelper, UInt64, UIWindow) {
        let helper = helper()
        let records = try ChatFixture.records("claude-thread").filter {
            $0["id"] as? String != "f2:ended" && (answered || $0["id"] as? String != "claude-f2-0")
        }
        let chat = try await opened(helper, records: records, state: ChatFixture.state(busy: busy))
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        try await TestSupport.eventually { chat.working == busy && chat.transcript.openTurn != nil }
        AccessibilityLabelTests.enableAccessibility()
        let found = await TestSupport.windowScene()
        let window = UIWindow(windowScene: try XCTUnwrap(found))
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 1400)
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ChatThreadView(session: chat, space: "app", directory: "/work/app")
        }.environment(\.chatSettle, hold))
        window.isHidden = false
        return (chat, helper, id, window)
    }

    /// What the thread shows of the open turn: the answer's corner as VoiceOver reads it, the working row's label and
    /// steps.
    private struct Shown: Equatable {
        var corner: String?
        var row: String?
        var steps: String?
        var hint: String? = nil
        var workingRow: Bool { row != nil }
    }

    private func shown(_ window: UIWindow) -> Shown {
        let elements = AccessibilityLabelTests.elements(in: window)
        let reply = elements.first { $0.accessibilityLabel?.hasPrefix("Right, the invoice.paid path") == true }
        let row = elements.first { label in
            [" is thinking", " is waiting for your"].contains { label.accessibilityLabel?.contains($0) == true }
        }
        return Shown(corner: reply?.accessibilityValue.flatMap { $0.isEmpty ? nil : $0 },
                     row: row?.accessibilityLabel.map { $0.contains(" is thinking") ? "thinking" : $0 },
                     steps: row?.accessibilityValue, hint: reply?.accessibilityHint.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Samples the thread at every turn of the main loop until `done`, returning each state seen.
    private func sample(_ window: UIWindow, until done: (Shown) -> Bool) async throws -> [Shown] {
        var seen: [Shown] = []
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let now = shown(window)
            if seen.last != now { seen.append(now) }
            if done(now) { return seen }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("never settled: \(seen)")
        return seen
    }

    /// The states seen over `duration`, sampled at every turn of the main loop.
    private func sample(_ window: UIWindow, for duration: Duration) async throws -> [Shown] {
        var seen: [Shown] = []
        let clock = ContinuousClock(), end = clock.now + duration
        while clock.now < end {
            let now = shown(window)
            if seen.last != now { seen.append(now) }
            try await Task.sleep(for: .milliseconds(2))
        }
        return seen
    }

    private func end(_ helper: ScriptedHelper, _ id: UInt64) {
        helper.notify(id, "chat.records", ["terminal": 7, "session": conversation, "records": [
            ChatFixture.record("f2:ended", "turn_ended", turn: "p2", time: 946_719_172_000)]])
    }

    private func state(_ helper: ScriptedHelper, _ id: UInt64, busy: Bool) {
        helper.notify(id, "chat.state", ["terminal": 7, "session": conversation, "state": ChatFixture.state(busy: busy)])
    }

    /// The open turn's answer's corner: when it was written.
    private var answerTime: String {
        ChatTurnSummary.time(Date(timeIntervalSince1970: 946_719_172), now: Date(), calendar: .autoupdatingCurrent)
    }

    /// A step of the open turn after its answer.
    private func step(_ helper: ScriptedHelper, _ id: UInt64) throws {
        var tool = try XCTUnwrap(ChatFixture.records("claude-thread").first { $0["id"] as? String == "tool-d1" })
        tool["id"] = "tool-d5"
        tool["time_ms"] = 946_719_173_000
        helper.notify(id, "chat.records", ["terminal": 7, "session": conversation, "records": [tool]])
    }

    func testTheWorkingRowStaysThroughTheTurnCountingTheStepsSinceTheAgentWrote() async throws {
        let (chat, helper, id, window) = try await openTurnThread(answered: false)
        defer { window.isHidden = true }
        try await TestSupport.eventually(diagnostic: "\(shown(window))") { self.shown(window).steps?.hasPrefix("4 steps") == true }

        // The answer arrives: the row stays, its count starts again as the Mac's next tool group, the corner has its time.
        let answer = try XCTUnwrap(ChatFixture.records("claude-thread").first { $0["id"] as? String == "claude-f2-0" })
        helper.notify(id, "chat.records", ["terminal": 7, "session": conversation, "records": [answer]])
        var seen = try await sample(window) { $0.steps == "No steps yet" }
        XCTAssertFalse(seen.contains { !$0.workingRow || $0.corner.map { $0 != answerTime } == true }, "the row all along: \(seen)")
        XCTAssertEqual(seen.last?.corner, answerTime)
        try step(helper, id)
        seen = try await sample(window) { $0.steps?.hasPrefix("1 step,") == true }
        XCTAssertFalse(seen.contains { !$0.workingRow || $0.corner != answerTime }, "\(seen)")

        // The state says idle before the turn's end comes: the row stays all through the hold, the corner its time.
        state(helper, id, busy: false)
        try await TestSupport.eventually { !chat.working }
        seen = try await sample(window, for: .milliseconds(1_000))
        XCTAssertFalse(seen.contains { !$0.workingRow || $0.corner != answerTime }, "the row while the end is on its way: \(seen)")

        end(helper, id)
        seen = try await sample(window) { !$0.workingRow }
        let summary = try XCTUnwrap(chat.transcript.rows.compactMap(\.kind.summary).last?.spokenCorner(now: Date(), calendar: .autoupdatingCurrent))
        XCTAssertEqual(seen.last?.corner, summary, "the row goes as the summary comes, in one update: \(seen)")
        XCTAssertEqual(seen.last?.hint, "Shows the steps")
    }

    func testATurnsEndBeforeTheIdleStateNeverBringsTheWorkingRowBack() async throws {
        let (chat, helper, id, window) = try await openTurnThread(answered: true)
        defer { window.isHidden = true }
        _ = try await sample(window) { $0.workingRow }
        end(helper, id)
        try await TestSupport.eventually { chat.transcript.openTurn == nil }
        XCTAssertTrue(chat.working, "the state still says busy")
        let seen = try await sample(window, for: .milliseconds(1_000))
        XCTAssertFalse(seen.contains { $0.workingRow }, "the working row stays away while the idle state is on its way: \(seen)")
        XCTAssertNotNil(seen.last?.corner)
        state(helper, id, busy: false)
        try await TestSupport.eventually { !chat.working }
        XCTAssertFalse(shown(window).workingRow)
    }

    func testTheHeldWorkingRowReturnsWhenTheHoldEndsOrNewWorkStarts() async throws {
        // A short hold: the busy state that ran through the turn's end outlives it (a subagent still working).
        let (chat, helper, id, window) = try await openTurnThread(answered: true, hold: 0.3)
        defer { window.isHidden = true }
        _ = try await sample(window) { $0.workingRow }
        end(helper, id)
        try await TestSupport.eventually { chat.transcript.openTurn == nil }
        try await TestSupport.eventually(diagnostic: "\(shown(window))") { self.shown(window).workingRow }

        // A long hold: another device's prompt makes the agent busy again before its turn starts; the row shows at once.
        let (other, otherHelper, otherID, otherWindow) = try await openTurnThread(answered: true)
        defer { otherWindow.isHidden = true }
        _ = try await sample(otherWindow) { $0.workingRow }
        end(otherHelper, otherID)
        state(otherHelper, otherID, busy: false)
        try await TestSupport.eventually { !other.working && other.transcript.openTurn == nil }
        XCTAssertFalse(shown(otherWindow).workingRow)
        state(otherHelper, otherID, busy: true)
        try await TestSupport.eventually { other.working }
        try await TestSupport.eventually(diagnostic: "\(shown(otherWindow))") { self.shown(otherWindow).workingRow }
    }

    func testWaitingTheRowSaysForWhat() async throws {
        let (chat, helper, id, window) = try await openTurnThread(answered: true)
        defer { window.isHidden = true }
        _ = try await sample(window) { $0.workingRow }
        helper.notify(id, "interaction.opened", ["terminal": 7, "session": conversation, "interaction": ChatFixture.approval()])
        try await TestSupport.eventually { chat.waitingForUser }
        let seen = try await sample(window) { $0.row?.hasSuffix("is waiting for your approval") == true }
        XCTAssertEqual(seen.last?.corner, answerTime, "\(seen)")
    }

    func testAnOpenTurnOfAnIdleAgentShowsNoRowAndTheReplysTime() async throws {
        // A turn left open (interrupted, its end never written) by an agent that is idle.
        let (_, _, _, window) = try await openTurnThread(answered: true, busy: false)
        defer { window.isHidden = true }
        try await TestSupport.eventually(diagnostic: "\(shown(window))") {
            AccessibilityLabelTests.elements(in: window).contains { $0.accessibilityLabel?.hasPrefix("Right, the invoice.paid path") == true }
        }
        let seen = try await sample(window, for: .milliseconds(300))
        XCTAssertEqual(seen, [Shown(corner: answerTime)], "the reply's time, no hint, no row")
    }

    // MARK: Background shells

    func testRunningShellsShowOverTheComposerUntilTheyEnd() async throws {
        var reported = ChatFixture.state(busy: false)
        reported["shells"] = [["id": "b1", "name": "Serve the docs", "command": "python3 -m http.server 8000", "started_ms": 946_719_000_000],
                              ["id": "b2", "command": "make test"]]
        let helper = helper()
        let chat = try await opened(helper, records: [], state: reported)
        XCTAssertEqual(chat.shells.map(\.title), ["Serve the docs", "make test"])
        XCTAssertEqual(chat.shells.map(\.detail), ["python3 -m http.server 8000", nil])
        XCTAssertEqual(chat.shells[0].started, Date(timeIntervalSince1970: 946_719_000))
        XCTAssertEqual(ChatShellsLine.label(chat.shells), "2 shells running")
        XCTAssertEqual(ChatShellsLine.label(Array(chat.shells.prefix(1))), "Serve the docs")
        XCTAssertFalse(chat.working, "A running shell is not the agent's work")
        chat.showingShells = true
        // The next state without them ends them, and the list closes with the last.
        state(helper, try XCTUnwrap(helper.subscription("chat.open")), busy: false)
        try await TestSupport.eventually { chat.shells.isEmpty }
        XCTAssertFalse(chat.showingShells)
    }
}

/// Times on swipe (`ChatReveal`): the corners leave the bubbles, the text keeps no room for them and VoiceOver still
/// reads them; the swipe slides the thread up to the times' column, then a fifth as far.
extension ChatRedesignTests {
    func testWithTimesOnSwipeTheBubbleKeepsNoRoomAndStillSaysItsTime() async throws {
        let metrics = ChatCornerMetrics(column: 370, measure: ChatMeasure.standard, size: .large)
        let now = Date()
        let corner = try XCTUnwrap(ChatCorner.reply(time: now.addingTimeInterval(-60), summary: nil, now: now, metrics: metrics))
        // A last line the time shares in the corner, and one the room pushes onto a line of its own.
        for text in ["The guard skips a repeated event.", String(repeating: "The guard skips a repeated event id ", count: 3)] {
            func size<V: View>(_ view: V) -> CGSize {
                UIHostingController(rootView: view.environment(\.chatColumnWidth, 370).frame(width: 300))
                    .sizeThatFits(in: CGSize(width: 300, height: 1000))
            }
            XCTAssertEqual(size(MobileChatMarkdownView(text: text, corner: corner.spokenOnly)), size(MobileChatMarkdownView(text: text)),
                           "no room kept: \(text)")
        }

        AccessibilityLabelTests.enableAccessibility()
        let found = await TestSupport.windowScene()
        let window = UIWindow(windowScene: try XCTUnwrap(found))
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 400)
        window.rootViewController = UIHostingController(rootView: ChatBubble(side: .agent) {
            MobileChatMarkdownView(text: "The guard skips a repeated event.", corner: corner.spokenOnly)
        }.environment(\.chatColumnWidth, 370))
        window.isHidden = false
        defer { window.isHidden = true }
        try await TestSupport.eventually(diagnostic: "\(AccessibilityLabelTests.elements(in: window).map { ($0.accessibilityLabel, $0.accessibilityValue) })") {
            AccessibilityLabelTests.elements(in: window).contains {
                $0.accessibilityLabel == "The guard skips a repeated event." && $0.accessibilityValue == corner.spoken
            }
        }
    }

    func testTheSwipeSlidesUpToTheColumnThenAFifthAsFar() {
        XCTAssertEqual(ChatReveal.offset(-50, width: 112), 50)
        XCTAssertEqual(ChatReveal.offset(30, width: 112), 0, "toward the trailing edge it stays")
        XCTAssertEqual(ChatReveal.offset(-212, width: 112), 132)
        XCTAssertEqual(ChatRevealDetail.lines("2 files +4 −4 · 10:17"), "2 files +4 −4\n10:17", "the time under the summary")
        XCTAssertEqual(ChatRevealDetail.lines("10:17"), "10:17")
    }

    /// As in Messages, a reply stays where it is while its time fades in beside it, in the room the bubble leaves (two
    /// lines where it needs them), under the turn's step count on its last reply; nothing is drawn in its corner.
    func testARepliesTimeFadesInBesideItWithTheTurnsSteps() {
        let reveal = ChatReveal()
        reveal.drag(-44, width: 88)
        XCTAssertEqual(reveal.progress, 0.5)
        reveal.drag(-400, width: 88)
        XCTAssertEqual(reveal.progress, 1, "past the column, all the way in")
        XCTAssertEqual(ChatRevealReceived<EmptyView>.room(column: 370, bubble: 200), 164)
        XCTAssertEqual(ChatRevealReceived<EmptyView>.room(column: 370, bubble: 318), ChatRevealReceived<EmptyView>.narrowest,
                       "beside a reply at 86% of the column: a day's word still on a line")

        let now = Date()
        let metrics = ChatCornerMetrics(column: 370, measure: ChatMeasure.standard, size: .large)
        let plain = ChatCorner.swiped(time: now.addingTimeInterval(-60), summary: nil, now: now, metrics: metrics)
        XCTAssertEqual(plain.corner?.drawn, false, "nothing drawn in the corner")
        XCTAssertEqual(plain.time, plain.corner?.spoken)
        XCTAssertFalse(plain.time?.contains("step") ?? true)
    }
}
