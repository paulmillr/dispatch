import Foundation
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// What a chat record or state costs the thread (docs/ios.md, Thread updates): rows built once per revision and each
/// ended turn's summary once per change, streamed records presented together, a state that changes nothing changing
/// nothing, the step line read only for tool changes, and a stream's parses kept out of the finished bubbles' cache.
@MainActor
final class ChatThreadUpdatesTests: XCTestCase {
    private let conversation = "00000000-0000-4000-8000-000000000201"

    /// Set once anything `read` read is assigned (`withObservationTracking`).
    private final class Changed: @unchecked Sendable { var changed = false }
    private func watch(_ read: () -> Void) -> Changed {
        let flag = Changed()
        withObservationTracking(read) { flag.changed = true }
        return flag
    }

    /// The presentations a session asked for, run by hand.
    private final class Timers {
        var pending: [(delay: TimeInterval, run: @MainActor @Sendable () -> Void)] = []
    }

    private static func turns(_ range: Range<Int>) -> [[String: Any]] {
        range.flatMap { index -> [[String: Any]] in
            let turn = "w\(index)", time = Int64(946_719_000_000 + index * 60_000)
            let number = String(format: "%02d", index)
            return [
                ChatFixture.record("\(turn):started", "turn_started", turn: turn, time: time, completed: false),
                ChatFixture.record("user-\(turn)", "user", turn: turn, text: "Question \(number).", time: time),
                ChatFixture.record("tool-\(turn)", "tool", turn: turn, text: "ls", time: time + 500),
                ChatFixture.record("claude-\(turn)", "assistant", turn: turn, text: "Answer \(number).", time: time + 1000),
                ChatFixture.record("\(turn):ended", "turn_ended", turn: turn, time: time + 2000),
            ]
        }
    }

    private func opened(turns: Range<Int> = 0..<3, key: String = "codex") async throws -> (MobileChatSession, ScriptedHelper, UInt64) {
        let helper = ScriptedHelper()
        helper.script { request in
            switch request.method {
            case "chat.open": return .open
            case "queue.list": return .result([Any]())
            default: return .result(NSNull())
            }
        }
        let chat = MobileChatSession.scripted(helper)
        try await TestSupport.eventually { helper.subscription("chat.open") != nil }
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        helper.notify(id, "chat.history", ChatFixture.history(key: key, state: ChatFixture.state(busy: false), pending: true))
        helper.notify(id, "chat.history", ChatFixture.history(key: key, records: Self.turns(turns)))
        try await TestSupport.eventually { chat.phase == .verified && !chat.loadingHistory }
        return (chat, helper, id)
    }

    private func send(_ helper: ScriptedHelper, _ id: UInt64, _ records: [[String: Any]]) {
        helper.notify(id, "chat.records", ["terminal": 7, "session": conversation, "records": records])
    }

    private func delta(_ text: String, turn: String = "live", completed: Bool = false) -> [String: Any] {
        ChatFixture.record("codex-reply-\(turn)", "assistant", turn: turn, text: text, time: 946_800_000_000, completed: completed)
    }

    private func start(_ turn: String = "live") -> [[String: Any]] {
        [ChatFixture.record("\(turn):started", "turn_started", turn: turn, time: 946_800_000_000, completed: false),
         ChatFixture.record("user-\(turn)", "user", turn: turn, text: "Retry the billing job \(turn).", time: 946_800_000_000)]
    }

    // MARK: Rows

    /// Rows are built once per revision however often they are read, an ended turn's summary once per change to that
    /// turn, and a copy taken before a change keeps the rows it had.
    func testRowsAreBuiltOncePerRevisionAndSummariesOncePerTurnChange() throws {
        var transcript = MobileTranscript()
        transcript.apply(try JSONDecoder().decode([HelperChat.Record].self,
                                                  from: JSONSerialization.data(withJSONObject: Self.turns(0..<5))), historical: true)
        MobileTranscript.rowBuilds = 0
        MobileTranscript.summaryBuilds = 0
        let rows = transcript.rows
        for _ in 0..<3 { XCTAssertEqual(transcript.rows, rows) }
        XCTAssertEqual(MobileTranscript.rowBuilds, 1, "Read four times, built once")
        XCTAssertEqual(MobileTranscript.summaryBuilds, 5, "One summary per ended turn")
        XCTAssertEqual(rows.compactMap(\.kind.summary).count, 5)

        let before = transcript
        let live = try JSONDecoder().decode([HelperChat.Record].self, from: JSONSerialization.data(withJSONObject:
            start() + [delta("Looking at the retry path.")]))
        transcript.apply(live, historical: false)
        XCTAssertEqual(transcript.rows.count, rows.count + 2)
        XCTAssertEqual(MobileTranscript.rowBuilds, 2, "A new revision builds again")
        XCTAssertEqual(MobileTranscript.summaryBuilds, 5, "The ended turns did not change: their summaries are kept")
        XCTAssertEqual(before.rows, rows, "A copy taken before the change keeps its rows")
        XCTAssertEqual(MobileTranscript.rowBuilds, 2)

        let ended = try JSONDecoder().decode([HelperChat.Record].self, from: JSONSerialization.data(withJSONObject: [
            delta("Looking at the retry path. Fixed.", completed: true),
            ChatFixture.record("live:ended", "turn_ended", turn: "live", time: 946_800_005_000)]))
        transcript.apply(ended, historical: false)
        XCTAssertNotNil(transcript.rows.last?.kind.summary)
        XCTAssertEqual(MobileTranscript.summaryBuilds, 6, "Only the turn that ended is summarized")
    }

    // MARK: Presenting records

    /// With the hold on, a burst of streamed records reaches `transcript` (what views observe) in one presentation, when
    /// its timer fires; a turn's start, the user's message, an approval and a turn's end present at once.
    func testAStreamedBurstReachesTheThreadInOnePresentation() async throws {
        let (chat, helper, id) = try await opened()
        let timers = Timers()
        chat.holdsRecords = true
        chat.presentationTimer = { delay, run in timers.pending.append((delay, run)) }

        let turns = chat.transcript.turns.count
        send(helper, id, start())
        try await TestSupport.eventually { chat.transcript.turns.count == turns + 1 }
        XCTAssertTrue(timers.pending.isEmpty, "A turn's start and the user's message show at once")
        XCTAssertEqual(chat.transcript.revision, chat.latest.revision)

        let presented = chat.transcript.revision
        let shown = watch { _ = chat.transcript }
        let words = (1...20).map { "word\($0)" }
        for count in 1...words.count { send(helper, id, [delta(words.prefix(count).joined(separator: " "))]) }
        let final = words.joined(separator: " ")
        try await TestSupport.eventually { chat.latest.turns.last?.items.last?.text == final }
        XCTAssertFalse(shown.changed, "Nothing reached the thread's views yet")
        XCTAssertEqual(chat.transcript.revision, presented)
        XCTAssertTrue(chat.presentationPending)
        XCTAssertEqual(timers.pending.map(\.delay), [MobileChatSession.readingHold], "One presentation, at the hold of a thread not shown")

        timers.pending[0].run()
        XCTAssertTrue(shown.changed)
        XCTAssertFalse(chat.presentationPending)
        XCTAssertEqual(chat.transcript.revision, chat.latest.revision, "The whole burst in one presentation")
        XCTAssertEqual(chat.transcript.rows.last?.item.text, final)

        // Records held when an approval arrives show with its card.
        let carded = watch { _ = chat.transcript }
        send(helper, id, [delta(final + " more")])
        try await TestSupport.eventually { chat.latest.turns.last?.items.last?.text == final + " more" }
        XCTAssertFalse(carded.changed)
        XCTAssertEqual(timers.pending.count, 2)
        helper.notify(id, "interaction.opened", ["terminal": 7, "session": conversation, "interaction": ChatFixture.approval()])
        try await TestSupport.eventually { !chat.approvals.isEmpty }
        XCTAssertTrue(carded.changed)
        XCTAssertEqual(chat.transcript.rows.last?.item.text, final + " more")

        // The held presentation that the card took over does nothing when it fires.
        let revision = chat.transcript.revision
        let stale = watch { _ = chat.transcript }
        timers.pending[1].run()
        XCTAssertFalse(stale.changed)
        XCTAssertEqual(chat.transcript.revision, revision)

        // A turn's end shows at once.
        send(helper, id, [ChatFixture.record("live:ended", "turn_ended", turn: "live", time: 946_800_005_000)])
        try await TestSupport.eventually { chat.transcript.turns.last?.ended != nil }
        XCTAssertEqual(timers.pending.count, 2)
    }

    /// While a thread shows and follows its end, held records wait `followingHold`; scrolled up, `readingHold`, and
    /// following again shows them at once.
    func testTheHoldIsShorterWhileTheThreadFollowsItsEnd() async throws {
        let (chat, helper, id) = try await opened()
        let timers = Timers()
        chat.holdsRecords = true
        chat.presentationTimer = { delay, run in timers.pending.append((delay, run)) }
        send(helper, id, start())
        try await TestSupport.eventually { chat.transcript.turns.last?.id == "live" }

        chat.threadShown(true)
        send(helper, id, [delta("One")])
        try await TestSupport.eventually { timers.pending.count == 1 }
        XCTAssertEqual(timers.pending[0].delay, MobileChatSession.followingHold)
        timers.pending[0].run()

        chat.threadFollowing(false)
        send(helper, id, [delta("One two")])
        try await TestSupport.eventually { timers.pending.count == 2 }
        XCTAssertEqual(timers.pending[1].delay, MobileChatSession.readingHold)
        XCTAssertNotEqual(chat.transcript.rows.last?.item.text, "One two")
        chat.threadFollowing(true)
        XCTAssertEqual(chat.transcript.rows.last?.item.text, "One two", "Following again shows what was held")
        chat.threadShown(false)
        XCTAssertEqual(chat.threadsShown, 0)
    }

    /// Under test the hold is off (`recordsHoldEnabled`): every record reaches the thread as it lands, as recorded tests
    /// expect.
    func testRecordsPresentAsTheyLandWhileTesting() async throws {
        XCTAssertFalse(MobileChatSession.recordsHoldEnabled)
        let (chat, helper, id) = try await opened()
        XCTAssertFalse(chat.holdsRecords)
        send(helper, id, start() + [delta("Streaming")])
        try await TestSupport.eventually { chat.transcript.rows.last?.item.text == "Streaming" }
        XCTAssertFalse(chat.presentationPending)
    }

    // MARK: State

    /// A `chat.state` that repeats what the session holds assigns nothing observed, and a subagent's token update
    /// (about once a second) changes only `subagents`, which the views showing tokens read, never what the thread reads.
    func testAStateWithNothingChangedInvalidatesNothing() async throws {
        let (chat, helper, id) = try await opened()
        var state = ChatFixture.state(busy: true, activity: "working")
        state["agents"] = [["id": "agent-1", "kind": "explore", "tokens": 1_200]]
        helper.notify(id, "chat.state", ["terminal": 7, "session": conversation, "state": state])
        try await TestSupport.eventually { chat.busy && chat.runningSubagents == 1 }

        let observed = watch {
            _ = (chat.busy, chat.starting, chat.awaitingAck, chat.activity, chat.attention, chat.dialog, chat.compacting)
            _ = (chat.runningSubagents, chat.working, chat.goalStatus, chat.shells, chat.showingShells, chat.model, chat.effort)
            _ = (chat.version, chat.usage, chat.goal)
            _ = (chat.managingGoal, chat.submittedAt, chat.workingSince, chat.stoppedWorking, chat.transcript.revision)
        }
        // The same state again, then the subagent's tokens growing: nothing the thread reads changed.
        for _ in 0..<2 { helper.notify(id, "chat.state", ["terminal": 7, "session": conversation, "state": state]) }
        for tokens in [1_300, 1_400, 1_500] {
            state["agents"] = [["id": "agent-1", "kind": "explore", "tokens": tokens]]
            helper.notify(id, "chat.state", ["terminal": 7, "session": conversation, "state": state])
        }
        // The same state with a title, which nothing above reads: once it shows, the repeats before it were applied.
        state["title"] = "Billing retries"
        helper.notify(id, "chat.state", ["terminal": 7, "session": conversation, "state": state])
        try await TestSupport.eventually { chat.title == "Billing retries" }
        XCTAssertFalse(observed.changed, "Repeated state assigns no observed property")
        XCTAssertEqual(chat.subagents.first?.tokens, 1_500, "The tokens reach the subagents' own list")

        state["busy"] = false
        helper.notify(id, "chat.state", ["terminal": 7, "session": conversation, "state": state])
        try await TestSupport.eventually { !chat.busy }
        XCTAssertTrue(observed.changed)
    }

    // MARK: The step line

    /// `currentStep` is read again only when the open turn, its tool items or its last message change, never for
    /// streamed words; the note the rows show follows the words.
    func testTheStepLineIsReadOnlyForToolChanges() async throws {
        let (chat, helper, id) = try await opened()
        // The reply's first words end the steps counted so far: read once.
        send(helper, id, start() + [delta("word ")])
        try await TestSupport.eventually { chat.latest.openTurn?.items.last?.text == "word " }
        let before = chat.stepRefreshes
        for count in 2...5 { send(helper, id, [delta(String(repeating: "word ", count: count))]) }
        try await TestSupport.eventually { chat.latest.turns.last?.items.last?.text == String(repeating: "word ", count: 5) }
        XCTAssertEqual(chat.stepRefreshes, before, "Streamed words read no steps")
        XCTAssertEqual(chat.currentNote, "word word word word word")
        send(helper, id, [ChatFixture.record("tool-live", "tool", turn: "live", text: "ls", time: 946_800_001_000, completed: false)])
        try await TestSupport.eventually { chat.latest.turns.last?.items.contains { $0.kind == .tool } == true }
        XCTAssertEqual(chat.stepRefreshes, before + 1)
    }

    // MARK: Bubbles

    /// A stream's parses (text that may still grow) never enter the finished bubbles' cache, so they never start it
    /// over; the stream's own cache stays a few entries.
    func testAStreamLeavesTheFinishedBubblesParsesAlone() {
        for index in 0..<8 { _ = MobileChatMarkdownView.contents("Finished reply \(index) with `code`.", code: nil, emphasis: nil) }
        let finished = MobileChatMarkdownView.cached.finished
        var text = ""
        for index in 0..<300 {
            text += "word\(index) "
            _ = MobileChatMarkdownView.contents(text, code: nil, emphasis: nil, partial: true)
        }
        XCTAssertEqual(MobileChatMarkdownView.cached.finished, finished, "300 streamed updates left the finished parses alone")
        XCTAssertLessThanOrEqual(MobileChatMarkdownView.cached.partial, 4)
    }

    /// A reply's corner is plain values, told once per what it is told from: the same row on the next pass gives an
    /// equal corner, so its bubble is not drawn again.
    func testACornerIsEqualFromPassToPass() {
        let now = Date(timeIntervalSince1970: 946_800_000)
        let metrics = ChatCornerMetrics(column: 370, measure: ChatMeasure.standard, size: .large)
        let summary = ChatTurnSummary(steps: [ChatItem(id: "a", kind: .tool, text: "ls"), ChatItem(id: "b", kind: .tool, text: "ls"),
                                              ChatItem(id: "c", kind: .tool, text: "ls")], duration: 30,
                                      ended: now.addingTimeInterval(-86_400))
        let first = ChatCorner.swiped(time: now.addingTimeInterval(-86_400), summary: summary, now: now, metrics: metrics)
        let again = ChatCorner.swiped(time: now.addingTimeInterval(-86_400), summary: summary, now: now, metrics: metrics)
        XCTAssertEqual(first.corner, again.corner)
        XCTAssertEqual(first.time, again.time)
        XCTAssertEqual(ChatCorner.reply(time: now, summary: summary, now: now, metrics: metrics),
                       ChatCorner.reply(time: now, summary: summary, now: now, metrics: metrics))
        // The day's word is asked once per locale, calendar and time zone, and stays the word.
        let calendar = Calendar(identifier: .gregorian)
        for _ in 0..<2 { XCTAssertEqual(ChatTurnSummary.yesterday(locale: Locale(identifier: "en_US"), calendar: calendar), "Yesterday") }
    }

    // MARK: A thread on screen

    /// A thread of 40 ended turns on screen while a reply streams in 60 records, the thread laid out after each one as
    /// frames would: how many times its rows and its turns' summaries are built, records presented as they land (as
    /// before the hold) and held. Rows are built at most once per presented revision, the 40 unchanged summaries never
    /// again, and with the hold the stream is one presentation.
    func testAStreamOnScreenBuildsRowsOncePerPresentation() async throws {
        let (chat, helper, id) = try await opened(turns: 0..<40)
        AccessibilityLabelTests.enableAccessibility()
        let found = await TestSupport.windowScene()
        let window = UIWindow(windowScene: try XCTUnwrap(found))
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ChatThreadView(session: chat, space: "app", directory: "/work/app")
        })
        window.isHidden = false
        defer { window.isHidden = true }
        func drawn(_ text: String) -> Bool {
            AccessibilityLabelTests.elements(in: window).contains { $0.accessibilityLabel?.contains(text) == true }
        }
        try await TestSupport.eventually { drawn("Answer 39.") }
        XCTAssertEqual(chat.threadsShown, 1)

        func stream(_ turn: String) async throws -> (rows: Int, summaries: Int) {
            MobileTranscript.rowBuilds = 0
            MobileTranscript.summaryBuilds = 0
            send(helper, id, start(turn))
            try await TestSupport.eventually { chat.latest.turns.last?.id == turn }
            window.layoutIfNeeded()
            for count in 1...60 {
                let text = (1...count).map { "w\($0)" }.joined(separator: " ") + " end of \(turn)."
                send(helper, id, [delta(text, turn: turn)])
                try await TestSupport.eventually { chat.latest.turns.last?.items.last?.text == text }
                // A frame: the hosted thread lays out what it observes now.
                window.rootViewController?.view.setNeedsLayout()
                window.layoutIfNeeded()
            }
            return (MobileTranscript.rowBuilds, MobileTranscript.summaryBuilds)
        }

        // As the thread was before the hold: every record presented as it lands.
        let landing = try await stream("first")
        try await TestSupport.eventually { drawn("w60 end of first.") }
        send(helper, id, [ChatFixture.record("first:ended", "turn_ended", turn: "first", time: 946_800_005_000)])
        try await TestSupport.eventually { chat.transcript.turns.last?.ended != nil }

        // Held: the stream reaches the thread when its presentation runs.
        let timers = Timers()
        chat.holdsRecords = true
        chat.presentationTimer = { delay, run in timers.pending.append((delay, run)) }
        let held = try await stream("second")
        XCTAssertEqual(timers.pending.map(\.delay), [MobileChatSession.followingHold], "One presentation, the thread following its end")
        timers.pending[0].run()
        try await TestSupport.eventually { drawn("w60 end of second.") }
        let heldRows = MobileTranscript.rowBuilds

        print("Thread updates: 61 records as they land built rows \(landing.rows) times and \(landing.summaries) summaries;"
              + " held, \(held.rows) before the presentation and \(heldRows) with it, \(MobileTranscript.summaryBuilds) summaries")
        XCTAssertLessThanOrEqual(landing.rows, 62, "At most once per presented revision")
        XCTAssertLessThanOrEqual(landing.summaries, 1, "The 40 ended turns' summaries are never built again")
        XCTAssertLessThanOrEqual(heldRows, 3, "The turn's start and the one presentation of the stream")
        XCTAssertLessThanOrEqual(MobileTranscript.summaryBuilds, 1)
        XCTAssertLessThanOrEqual(held.rows, 2)
    }
}
