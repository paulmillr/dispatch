import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import DispatchWatch

/// The Agents screens' words and marks (rows, thread items, approval chips, the question form, the composer) as pure
/// helpers, and every scripted phone's rows and threads drawn once through `ImageRenderer`.
@MainActor
final class WatchAgentsViewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)
    private let studio = WatchHost(id: WatchFixtures.studio, name: "studio", order: 0, state: .connected, tint: "#C98BD9")

    // MARK: Agents rows

    func testARowSaysItsHostAndSpaceAndMutedAsThePhoneDoes() {
        var row = WatchConversation(host: studio.id, node: "n1", name: "Fix the build", space: "dispatch")
        XCTAssertEqual(AgentsRow.subtitle(row, host: studio), "studio · dispatch")
        XCTAssertEqual(AgentsRow.subtitle(row, host: nil), "dispatch")
        row.space = nil
        row.muted = true
        XCTAssertEqual(AgentsRow.subtitle(row, host: studio), "studio · muted")
        row.muted = false
        XCTAssertNil(AgentsRow.subtitle(row, host: nil))
    }

    /// Done: the last message (else the attention line). Needs you: what it asks, else its attention line, else the
    /// preview, else "Needs you".
    func testARowShowsThePreviewOrWhatTheAgentWaitsFor() {
        var row = WatchConversation(host: studio.id, node: "n1", name: "Fix the build", preview: "Done.", attention: "Waiting for input")
        XCTAssertEqual(AgentsRow.line(row, now: now), "Done.")
        row.needsYou = true
        XCTAssertEqual(AgentsRow.line(row, now: now), "Waiting for input")
        row.waitingText = "Allow cargo test --workspace?"
        XCTAssertEqual(AgentsRow.line(row, now: now), "Allow cargo test --workspace?")
        row.waitingText = nil
        row.attention = nil
        XCTAssertEqual(AgentsRow.line(row, now: now), "Done.")
        row.preview = ""
        XCTAssertEqual(AgentsRow.line(row, now: now), "Needs you")
        row.needsYou = false
        XCTAssertNil(AgentsRow.line(row, now: now))
    }

    /// Working: the current step and how long the turn has run (K1's "Editing Sidebar.tsx · 48s"), else "Working".
    func testAWorkingRowSaysItsStepAndElapsedTime() {
        var row = WatchConversation(host: studio.id, node: "n1", name: "Sidebar theme toggle", preview: "Earlier answer.", busy: true,
                                    step: "Editing Sidebar.tsx", workingSince: now.addingTimeInterval(-48))
        XCTAssertEqual(AgentsRow.line(row, now: now), "Editing Sidebar.tsx · 48s")
        row.workingSince = now.addingTimeInterval(-242)
        XCTAssertEqual(AgentsRow.line(row, now: now), "Editing Sidebar.tsx · 4m 2s")
        row.step = nil
        row.workingSince = nil
        XCTAssertEqual(AgentsRow.line(row, now: now), "Working")
        // What it asks wins over its step.
        row.needsYou = true
        row.waitingText = "Which schedule?"
        XCTAssertEqual(AgentsRow.line(row, now: now), "Which schedule?")
    }

    func testARowsAccessibilityLabelNamesItsStateAndTime() {
        let row = WatchConversation(host: studio.id, node: "n1", name: "Fix the build", space: "dispatch", agent: "claude",
                                    preview: "Which test first?", needsYou: true, lastActivity: now.addingTimeInterval(-300))
        XCTAssertEqual(AgentsRow.accessibilityLabel(row, host: studio, now: now),
                       "Fix the build, claude, studio · dispatch, 5 min ago, Needs you, Which test first?")
    }

    /// Blue for needs you or unseen, amber working; a muted row keeps only needs you, as the phone's.
    func testDotsFollowThePhone() {
        func dot(_ dot: WatchDot?, needsYou: Bool = false, busy: Bool = false, muted: Bool = false) -> AgentsDot? {
            AgentsDot.of(WatchConversation(host: studio.id, node: "n", name: "a", dot: dot, needsYou: needsYou, busy: busy, muted: muted))
        }
        XCTAssertEqual(dot(.unread), .unread)
        XCTAssertEqual(dot(.working, busy: true), .working)
        XCTAssertNil(dot(nil))
        XCTAssertEqual(dot(nil, needsYou: true), .unread)
        XCTAssertNil(dot(.unread, muted: true))
        XCTAssertNil(dot(.working, busy: true, muted: true))
        XCTAssertEqual(dot(.unread, needsYou: true, muted: true), .unread)
        XCTAssertEqual(dot(.unknown, busy: true), .working)
        XCTAssertEqual(AgentsDot.unread.accessibilityLabel, "Unread")
        XCTAssertEqual(AgentsDot.working.accessibilityLabel, "Working")
    }

    /// The phone's one bubble for every agent, by key or by the thread's label; the terminal without one.
    func testAgentMarks() {
        for agent in ["claude", "Claude Code", "Codex", "pi", "aider", "pipeline"] {
            XCTAssertEqual(AgentsGlyph.symbol(agent), "dispatch.chat", agent)
        }
        XCTAssertEqual(AgentsGlyph.symbol(nil), "apple.terminal")
        XCTAssertEqual(AgentsGlyph.symbol(""), "apple.terminal")
        XCTAssertEqual(AgentsGlyph.shortName("Claude Code"), "Claude")
        XCTAssertEqual(AgentsGlyph.shortName("codex"), "Codex")
        XCTAssertEqual(AgentsGlyph.shortName("aider"), "aider")
        XCTAssertNil(AgentsGlyph.shortName(nil))
    }

    /// The demo's pi is behind Face ID and has a row: its note shows; a blocked host without rows does not.
    func testBlockedHostsWithRowsSayOpenThePhone() {
        let link = ScriptedWatchLink(scenario: .demo, now: { [now] in now })
        let model = WatchModel(link: link, now: { [now] in now })
        let blocked = AgentsScreen.blocked(hosts: model.hosts, conversations: model.conversations)
        XCTAssertEqual(blocked.map(\.host.name), ["pi"])
        XCTAssertEqual(blocked.first?.message, "Open Dispatch on your iPhone to connect pi.")
        XCTAssertTrue(AgentsScreen.blocked(hosts: model.hosts, conversations: model.conversations.filter { $0.host != WatchFixtures.pi }).isEmpty)
    }

    // MARK: Thread items

    /// Tools are no rows, as on the phone: an older phone's tool lines stay out of the page, its card and its anchor.
    func testToolsAreNotRows() {
        var thread = WatchFixtures.threads(now: now)[WatchFixtures.notes]!
        thread.items.insert(WatchItem(id: "n1t", kind: .tool, text: "CHANGELOG.md", turn: "t1", tool: "Read"), at: 1)
        thread.items.append(WatchItem(id: "n3", kind: .tool, text: "git log", turn: "t1", tool: "Run", running: true))
        XCTAssertEqual(ThreadScreen.items(thread).map(\.id), ["n1", "n2"])
        XCTAssertEqual(ThreadScreen.card(thread), "n2")
        thread.working = true
        XCTAssertEqual(ThreadScreen.anchor(thread)?.id, "n2", "the card, not the hidden step after it")
        XCTAssertEqual(ThreadScreen.anchor(thread)?.top, true)
    }

    /// A thread opens at its newest turn (the one the user's newest message started, by its turn id); the turns before
    /// it wait behind "Earlier". A page where the user wrote nothing shows whole.
    func testTheThreadOpensAtTheNewestTurn() {
        var thread = WatchThread(key: WatchFixtures.notes, generated: now, title: "t", items: [
            WatchItem(id: "a1", kind: .user, text: "Draft the notes", turn: "t1"),
            WatchItem(id: "a2", kind: .agent, text: "Drafted.", turn: "t1"),
            WatchItem(id: "b1", kind: .user, text: "Shorter, please", turn: "t2"),
            WatchItem(id: "b2", kind: .thinking, text: "Trimming", turn: "t2"),
            WatchItem(id: "b3", kind: .tool, text: "notes.md", turn: "t2", tool: "Edit"),
            WatchItem(id: "b4", kind: .user, text: "Keep the links", turn: "t2"),
            WatchItem(id: "b5", kind: .agent, text: "Shorter now.", turn: "t2"),
        ])
        var turns = ThreadScreen.turns(thread)
        XCTAssertEqual(turns.earlier.map(\.id), ["a1", "a2"])
        XCTAssertEqual(turns.newest.map(\.id), ["b1", "b2", "b4", "b5"], "a steer stays in its turn; tools are no rows")
        XCTAssertEqual(ThreadScreen.card(thread), "b5", "the card is in the newest turn")
        // Without turn ids: from the user's newest message.
        thread.items = thread.items.map { WatchItem(id: $0.id, kind: $0.kind, text: $0.text) }
        turns = ThreadScreen.turns(thread)
        XCTAssertEqual(turns.newest.map(\.id), ["b4", "b5"])
        XCTAssertEqual(turns.earlier.count, 4)
        // The user wrote nothing on this page: all of it.
        thread.items = [WatchItem(id: "c1", kind: .agent, text: "Hello"), WatchItem(id: "c2", kind: .notice, text: "Compacted")]
        XCTAssertEqual(ThreadScreen.turns(thread).newest.map(\.id), ["c1", "c2"])
        XCTAssertTrue(ThreadScreen.turns(thread).earlier.isEmpty)
        XCTAssertEqual(ThreadScreen.earlierTitle(6), "Earlier · 6")
        // While the screen is open the split stays where it began: a message sent from here does not hide the answer.
        thread.items = [WatchItem(id: "a1", kind: .user, text: "Draft", turn: "t1"), WatchItem(id: "a2", kind: .agent, text: "Drafted.", turn: "t1")]
        let pinned = ThreadScreen.turns(thread).newest.first?.id
        XCTAssertEqual(pinned, "a1")
        thread.items.append(WatchItem(id: "b1", kind: .user, text: "Shorter", turn: "t2"))
        XCTAssertEqual(ThreadScreen.turns(thread).newest.map(\.id), ["b1"], "split afresh")
        XCTAssertEqual(ThreadScreen.turns(thread, from: pinned).newest.map(\.id), ["a1", "a2", "b1"])
        XCTAssertEqual(ThreadScreen.turns(thread, from: "gone").newest.map(\.id), ["b1"])
        // The fixtures' working thread: its one message is the newest turn.
        XCTAssertTrue(ThreadScreen.turns(WatchFixtures.threads(now: now)[WatchFixtures.working]!).earlier.isEmpty)
    }

    /// While an approval or a question waits, its chips are the answer: no Reply, Open on iPhone alone.
    func testReplyWaitsWhileARequestWaits() {
        let threads = WatchFixtures.threads(now: now)
        XCTAssertFalse(ThreadScreen.offersReply(threads[WatchFixtures.approval]!))
        XCTAssertFalse(ThreadScreen.offersReply(threads[WatchFixtures.question]!))
        XCTAssertTrue(ThreadScreen.offersReply(threads[WatchFixtures.notes]!))
        XCTAssertTrue(ThreadScreen.offersReply(threads[WatchFixtures.working]!))
    }

    /// Double tap: Allow on the first approval card, else Answer on the first question (Reply is hidden then), else Reply.
    func testDoubleTapAllowsTheFirstApprovalElseReplies() {
        let threads = WatchFixtures.threads(now: now)
        XCTAssertEqual(ThreadScreen.primaryAction(threads[WatchFixtures.approval]!), .allow("interaction-7"))
        XCTAssertEqual(ThreadScreen.primaryAction(threads[WatchFixtures.question]!), .answer("interaction-12"))
        XCTAssertEqual(ThreadScreen.primaryAction(threads[WatchFixtures.notes]!), .reply)
        XCTAssertEqual(ThreadScreen.primaryAction(threads[WatchFixtures.working]!), .reply)
        // An approval without Allow (only the phone's own choices): not answered by a double tap.
        var thread = threads[WatchFixtures.approval]!
        thread.approvals[0].choices = [WatchChoice(index: 0, label: "Deny", role: .deny)]
        XCTAssertEqual(ThreadScreen.primaryAction(thread), .none)
    }

    /// While the agent works the header says the host's CPU after the model: is it the machine or the agent?
    func testTheHeaderSaysTheHostsCPUWhileTheAgentWorks() {
        var thread = WatchThread(key: WatchFixtures.working, generated: now, title: "t", agent: "Codex", model: "gpt-5.5", working: true)
        XCTAssertEqual(ThreadHeader.load(thread, cpu: 33.6), "34%")
        XCTAssertNil(ThreadHeader.load(thread, cpu: nil))
        thread.working = false
        XCTAssertNil(ThreadHeader.load(thread, cpu: 34))
        var host = WatchHost(id: WatchFixtures.studio, name: "studio", order: 0, state: .connected,
                             stats: WatchHostStats(cpu: 41, history: [], sampled: now))
        XCTAssertEqual(ThreadHeader.cpu(host), 41)
        host.stats?.stale = true
        XCTAssertNil(ThreadHeader.cpu(host), "not current")
        host.stats?.stale = false
        host.state = .offline
        XCTAssertNil(ThreadHeader.cpu(host))
        host.state = .connected
        host.stats = nil
        XCTAssertNil(ThreadHeader.cpu(host))
    }

    /// An idle row's preview takes one line; working and needs-you rows keep two.
    func testAnIdleRowsPreviewTakesOneLine() {
        var row = WatchConversation(host: studio.id, node: "n1", name: "Fix the build", preview: "Done.")
        XCTAssertEqual(AgentsRow.lineLimit(row), 1)
        row.busy = true
        XCTAssertEqual(AgentsRow.lineLimit(row), 2)
        row.busy = false
        row.needsYou = true
        XCTAssertEqual(AgentsRow.lineLimit(row), 2)
    }

    func testItemsSayWhoSpeaks() {
        XCTAssertEqual(ThreadItemRow.accessibilityLabel(WatchItem(id: "1", kind: .user, text: "Go"), agent: "Codex"), "You: Go")
        XCTAssertEqual(ThreadItemRow.accessibilityLabel(WatchItem(id: "2", kind: .agent, text: "Done.", caption: "2 steps · 4s"), agent: "Codex"),
                       "Codex: Done., 2 steps · 4s")
        XCTAssertEqual(ThreadItemRow.accessibilityLabel(WatchItem(id: "3", kind: .thinking, text: "Hmm"), agent: "Claude Code"),
                       "Claude Code: Hmm", "thinking is the agent's message, as the phone shows it")
    }

    func testTheWorkingLineReadsAsThePhones() {
        XCTAssertEqual(ThreadWorkingRow.text(activity: "thinking", since: now.addingTimeInterval(-48), now: now), "thinking 48s")
        XCTAssertEqual(ThreadWorkingRow.text(activity: nil, since: now.addingTimeInterval(-242), now: now), "Working 4m 2s")
        XCTAssertEqual(ThreadWorkingRow.text(activity: "", since: nil, now: now), "Working")
    }

    func testTheHeaderSaysWhyInputWaits() {
        var thread = WatchThread(key: WatchFixtures.approval, generated: now, title: "t", agent: "Claude Code", model: "opus-5.5")
        XCTAssertEqual(ThreadHeader.detail(thread), "Claude Code · opus-5.5")
        XCTAssertNil(ThreadHeader.status(thread))
        thread.phase = .opening
        XCTAssertEqual(ThreadHeader.status(thread), "Attaching…")
        thread.phase = .paused
        XCTAssertEqual(ThreadHeader.status(thread), "Paused")
        thread.reason = "The agent exited."
        XCTAssertEqual(ThreadHeader.status(thread), "The agent exited.")
        thread.phase = .offline
        thread.reason = nil
        XCTAssertEqual(ThreadHeader.status(thread), "Offline")
        thread.agent = nil
        thread.model = nil
        XCTAssertNil(ThreadHeader.detail(thread))
    }

    /// The watch's failure first, then the phone's own, never twice.
    func testFailureLines() {
        var thread = WatchThread(key: WatchFixtures.approval, generated: now, title: "t")
        XCTAssertEqual(ThreadScreen.failures(thread: thread, failure: nil), [])
        thread.failure = "Couldn't send."
        XCTAssertEqual(ThreadScreen.failures(thread: thread, failure: .timedOut), ["Your iPhone didn't answer in time.", "Couldn't send."])
        XCTAssertEqual(ThreadScreen.failures(thread: thread, failure: WatchFailure(.notSent, "Couldn't send.")), ["Couldn't send."])
    }

    /// A thread opens at what waits for the user, else at the summary card's top (Reply under it), else at its newest
    /// item.
    func testTheThreadOpensAtTheRequest() {
        let threads = WatchFixtures.threads(now: now)
        XCTAssertEqual(ThreadScreen.anchor(threads[WatchFixtures.approval]!)?.id, "interaction-7")
        XCTAssertEqual(ThreadScreen.anchor(threads[WatchFixtures.question]!)?.id, "interaction-12")
        XCTAssertEqual(ThreadScreen.anchor(threads[WatchFixtures.notes]!)?.id, "n2")
        XCTAssertEqual(ThreadScreen.anchor(threads[WatchFixtures.notes]!)?.top, true)
        // Working without an answer yet: the newest item, its bottom.
        XCTAssertEqual(ThreadScreen.anchor(threads[WatchFixtures.working]!)?.id, "w1")
        XCTAssertEqual(ThreadScreen.anchor(threads[WatchFixtures.working]!)?.top, false)
        XCTAssertNil(ThreadScreen.anchor(WatchThread(key: WatchFixtures.notes, generated: now, title: "t")))
    }

    /// The card is the newest agent message unless the user wrote after it.
    func testTheSummaryCardIsTheNewestAnswer() {
        var thread = WatchFixtures.threads(now: now)[WatchFixtures.notes]!
        XCTAssertEqual(ThreadScreen.card(thread), "n2")
        thread.items.append(WatchItem(id: "n3", kind: .notice, text: "Conversation compacted"))
        XCTAssertEqual(ThreadScreen.card(thread), "n2")
        thread.items.append(WatchItem(id: "n4", kind: .user, text: "Shorter, please."))
        XCTAssertNil(ThreadScreen.card(thread))
        XCTAssertNil(ThreadScreen.card(WatchFixtures.threads(now: now)[WatchFixtures.working]!))
    }

    /// K2's footnote: "5 steps in 1m 26s · 4 files" and the counts; without files or time, less.
    func testTheCardsFootnoteSaysWhatTheTurnDid() {
        XCTAssertEqual(ThreadSummaryCard.words(WatchTurnSummary(steps: 5, seconds: 86, files: 4, additions: 61, deletions: 9)),
                       "5 steps in 1m 26s · 4 files")
        XCTAssertEqual(ThreadSummaryCard.words(WatchTurnSummary(steps: 1, seconds: 48)), "1 step in 48s")
        XCTAssertEqual(ThreadSummaryCard.words(WatchTurnSummary(steps: 3, files: 1, additions: 2)), "3 steps · 1 file")
    }

    // MARK: Approvals and questions

    /// The chips affirmative first (Allow, This session) and Deny last; Allow prominent and Deny destructive.
    func testApprovalChipsPutAllowFirstAndDenyLast() {
        let approval = WatchFixtures.threads(now: now)[WatchFixtures.approval]!.approvals[0]
        XCTAssertEqual(approval.choices.map(\.label), ["Deny", "This session", "Allow"])
        XCTAssertEqual(ApprovalCard.titles(approval), ["Allow", "This session", "Deny"])
        XCTAssertEqual(ApprovalCard.ordered(approval.choices).map(ApprovalButtonStyle.of), [.prominent, .secondary, .destructive])
        // Allow and Deny side by side, This session under them; one the watch does not know goes under them too.
        let layout = ApprovalCard.layout(approval.choices)
        XCTAssertEqual(layout.row.map(\.label), ["Allow", "Deny"])
        XCTAssertEqual(layout.below.map(\.label), ["This session"])
        let plain = ApprovalCard.layout([WatchChoice(index: 1, label: "Deny", role: .deny), WatchChoice(index: 0, label: "Allow", role: .allow),
                                         WatchChoice(index: 2, label: "Later", role: .unknown)])
        XCTAssertEqual(plain.row.map(\.label), ["Allow", "Deny"])
        XCTAssertEqual(plain.below.map(\.label), ["Later"])
        XCTAssertTrue(ApprovalCard.layout([WatchChoice(index: 0, label: "Allow", role: .allow)]).below.isEmpty)
        XCTAssertEqual(ApprovalButtonStyle.of(WatchChoice(index: 5, label: "Later", role: .unknown)), .secondary)
        XCTAssertEqual(ApprovalCard.waiting(since: now.addingTimeInterval(-130), now: now), "Waiting · 2m")
        XCTAssertEqual(ApprovalCard.waiting(since: now.addingTimeInterval(-10), now: now), "Waiting")
    }

    /// K3's line: "Codex wants to run" when the phone says the block is a command, else the request's own words; the
    /// command on one line.
    func testAnApprovalSaysWhatTheAgentWantsToDo() {
        var approval = WatchApproval(id: "i", title: "Run cargo test", detail: "cargo test --workspace", arrived: now, choices: [], verb: .run)
        XCTAssertEqual(ApprovalCard.headline(approval, agent: "codex"), "Codex wants to run")
        XCTAssertEqual(ApprovalCard.headline(approval, agent: "Claude Code"), "Claude wants to run")
        XCTAssertEqual(ApprovalCard.headline(approval, agent: nil), "The agent wants to run")
        approval.verb = .fetch
        XCTAssertEqual(ApprovalCard.headline(approval, agent: "pi"), "Pi wants to fetch")
        approval.verb = nil
        XCTAssertEqual(ApprovalCard.headline(approval, agent: "codex"), "Run cargo test")
        approval.verb = .unknown
        XCTAssertEqual(ApprovalCard.headline(approval, agent: "codex"), "Run cargo test")
        XCTAssertEqual(ApprovalCard.oneLine("make\nmake install"), "make …")
        XCTAssertEqual(ApprovalCard.oneLine("cargo test"), "cargo test")
    }

    func testASingleChoiceQuestionKeepsOneOptionAndATypedAnswerReplacesIt() {
        let question = WatchFixtures.threads(now: now)[WatchFixtures.question]!.questions[0]
        let part = question.parts[0]
        var draft = QuestionDraft()
        XCTAssertFalse(draft.canSend(question))
        draft.toggle(part.options[0], in: part)
        draft.toggle(part.options[1], in: part)
        XCTAssertEqual(draft.answer.options, ["schedule": [1]])
        XCTAssertTrue(draft.isSelected(part.options[1], in: part))
        XCTAssertFalse(draft.isSelected(part.options[0], in: part))
        XCTAssertTrue(draft.canSend(question))
        draft.type("  Warmup then cosine ", in: part)
        XCTAssertEqual(draft.answer, WatchAnswer(texts: ["schedule": "Warmup then cosine"]))
        XCTAssertTrue(draft.canSend(question))
        draft.toggle(part.options[2], in: part)
        XCTAssertEqual(draft.answer, WatchAnswer(options: ["schedule": [2]]))
        draft.toggle(part.options[2], in: part)
        XCTAssertFalse(draft.canSend(question))
        draft.type("   ", in: part)
        XCTAssertEqual(draft.answer, WatchAnswer())
    }

    func testAMultipleChoiceQuestionNeedsEveryPart() {
        let first = WatchQuestion.Part(id: "a", text: "Which?", options: [WatchOption(index: 0, label: "x"), WatchOption(index: 1, label: "y")],
                                       multiple: true)
        let second = WatchQuestion.Part(id: "b", text: "And?", options: [WatchOption(index: 0, label: "z")])
        let question = WatchQuestion(id: "q", parts: [first, second])
        var draft = QuestionDraft()
        draft.toggle(first.options[1], in: first)
        draft.toggle(first.options[0], in: first)
        XCTAssertEqual(draft.answer.options["a"], [0, 1])
        XCTAssertFalse(draft.canSend(question))
        draft.toggle(second.options[0], in: second)
        XCTAssertTrue(draft.canSend(question))
        draft.toggle(first.options[0], in: first)
        XCTAssertEqual(draft.answer.options["a"], [1])
        XCTAssertTrue(draft.answer.completes(question))
    }

    /// K4: one part at a time; Next once the part has an answer.
    func testTheFormGoesOnePartAtATime() {
        XCTAssertEqual(QuestionSheet.position(0, of: 2), "1 of 2")
        XCTAssertEqual(QuestionSheet.position(1, of: 2), "2 of 2")
        XCTAssertNil(QuestionSheet.position(0, of: 1))
        let part = WatchQuestion.Part(id: "a", text: "Where?", options: [WatchOption(index: 0, label: "Sidebar header")], custom: true)
        var draft = QuestionDraft()
        XCTAssertFalse(draft.answered(part))
        draft.toggle(part.options[0], in: part)
        XCTAssertTrue(draft.answered(part))
        draft.type("In the toolbar", in: part)
        XCTAssertTrue(draft.answered(part))
        XCTAssertFalse(QuestionDraft().answered(WatchQuestion.Part(id: "s", text: "Password?", secret: true)))
    }

    /// A secret part is answered on the phone: Send never shows enabled.
    func testASecretQuestionCannotBeSentFromTheWatch() {
        let part = WatchQuestion.Part(id: "p", text: "Password?", custom: true, secret: true)
        let question = WatchQuestion(id: "q", parts: [part])
        var draft = QuestionDraft()
        draft.type("hunter2", in: part)
        XCTAssertFalse(draft.canSend(question))
    }

    // MARK: Composer and queue

    func testTheComposerSaysWhereTheMessageGoes() {
        XCTAssertEqual(ThreadComposer.prompt(route: .send, queued: 0), "Message")
        XCTAssertEqual(ThreadComposer.prompt(route: .queue, queued: 0), "Queue a message…")
        XCTAssertEqual(ThreadComposer.prompt(route: .queue, queued: 2), "Queue another…")
        XCTAssertEqual(ThreadComposer.prompt(route: .outbox, queued: 0), "Queued on your iPhone")
        XCTAssertEqual(ThreadComposer.prompt(route: .unknown, queued: 0), "Message")
        XCTAssertEqual(ThreadComposer.title(route: .outbox, queued: 0), "Message")
        XCTAssertEqual(ThreadComposer.title(route: .queue, queued: 1), "Queue another…")
        // K5's confirm screen says where a reply goes; nothing when it is sent at once.
        XCTAssertNil(ThreadComposer.routeLine((.send, 0)))
        XCTAssertNil(ThreadComposer.routeLine(nil))
        XCTAssertEqual(ThreadComposer.routeLine((.queue, 0)), "Queued until this turn ends")
        XCTAssertEqual(ThreadComposer.routeLine((.queue, 2)), "Queued after 2 more")
        XCTAssertEqual(ThreadComposer.routeLine((.outbox, 0)), "Queued on your iPhone")
    }

    func testSteerOnlyWhileALiveAgentWorks() {
        var thread = WatchThread(key: WatchFixtures.working, generated: now, title: "t", working: true)
        XCTAssertTrue(ThreadComposer.canSteer(thread))
        thread.phase = .offline
        XCTAssertFalse(ThreadComposer.canSteer(thread))
        thread.phase = .live
        thread.working = false
        XCTAssertFalse(ThreadComposer.canSteer(thread))
    }

    /// The route is chosen on the confirm screen, once the words exist: Queue (accent) or Steer now while a live agent
    /// works, each saying what it does; otherwise Send with where it goes (sent, queued, queued on the phone).
    func testTheConfirmScreensButtonsFollowTheRoute() {
        typealias Action = ThreadComposer.ReplyAction
        var thread = WatchThread(key: WatchFixtures.working, generated: now, title: "t", working: true, canStop: true, route: .queue)
        let working = ThreadComposer.actions(thread)
        XCTAssertEqual(working.map(\.title), ["Queue", "Steer now"])
        XCTAssertEqual(working.map(\.style), [.accent, .glass])
        XCTAssertEqual(working.map(\.steer), [false, true])
        XCTAssertEqual(working.map(\.line), ["Queued after this turn", "Goes into the running turn"])
        thread.queue = [WatchQueued(id: "a", text: "one"), WatchQueued(id: "b", text: "two"),
                        WatchQueued(id: WatchModel.sendingID + "-1", text: "three", status: "Sending…")]
        XCTAssertEqual(ThreadComposer.actions(thread).first?.line, "Queued after 2 more", "the watch's own one on its way not counted")
        thread.queue[1].status = "Not sent: Claude was not ready for input. Send it again or discard it."
        XCTAssertEqual(ThreadComposer.actions(thread).first?.line, "Queued after 1 more", "a paused one holds nothing back")

        // Idle: sent at once, no line.
        let idle = ThreadComposer.actions(WatchThread(key: WatchFixtures.notes, generated: now, title: "t", route: .send))
        XCTAssertEqual(idle, [Action(title: "Send", symbol: "arrow.up", style: .accent, steer: false, line: nil)])
        // Idle with messages waiting: queued behind them.
        let behind = WatchThread(key: WatchFixtures.notes, generated: now, title: "t", queue: [WatchQueued(id: "a", text: "one")], route: .queue)
        XCTAssertEqual(ThreadComposer.actions(behind).map(\.line), ["Queued after 1 more"])
        // Not live: kept on the phone, even while the agent was working.
        for phase in [WatchPhase.offline, .opening] {
            let away = WatchThread(key: WatchFixtures.working, generated: now, title: "t", phase: phase, working: true, route: .outbox)
            XCTAssertEqual(ThreadComposer.actions(away).map(\.title), ["Send"], "\(phase)")
            XCTAssertEqual(ThreadComposer.actions(away).map(\.line), ["Queued on your iPhone"], "\(phase)")
        }
        // Paused (the agent exited): no steering; the phone's route says where it waits.
        let paused = WatchThread(key: WatchFixtures.working, generated: now, title: "t", phase: .paused, working: true, route: .outbox)
        XCTAssertEqual(ThreadComposer.actions(paused).map(\.title), ["Send"])
        XCTAssertEqual(ThreadComposer.actions(paused).map(\.steer), [false])
        XCTAssertEqual(ThreadComposer.actions(nil).map(\.title), ["Send"], "no page yet")
    }

    /// The confirm screen's buttons are those it opened with: a turn starting or ending while it is up changes only what
    /// their lines say (as the phone will route each), never which button sits where.
    func testTheConfirmScreensButtonsStayPut() {
        var thread = WatchThread(key: WatchFixtures.notes, generated: now, title: "t", route: .send)
        let idle = ThreadComposer.actions(thread)
        thread.working = true
        thread.canStop = true
        thread.route = .queue
        var shown = ThreadComposer.relabel(idle, thread)
        XCTAssertEqual(shown.map(\.title), ["Send"], "no Steer now appears under the finger")
        XCTAssertEqual(shown.map(\.line), ["Queued after this turn"])
        let working = ThreadComposer.actions(thread)
        XCTAssertEqual(working.map(\.title), ["Queue", "Steer now"])
        thread.working = false
        thread.canStop = false
        thread.route = .send
        shown = ThreadComposer.relabel(working, thread)
        XCTAssertEqual(shown.map(\.title), ["Queue", "Steer now"])
        XCTAssertEqual(shown.map(\.steer), [false, true])
        XCTAssertEqual(shown.map(\.line), ["Sent now: the turn ended", "Sent now: the turn ended"])
        thread.route = .outbox
        thread.phase = .offline
        XCTAssertEqual(ThreadComposer.relabel(working, thread).map(\.line), ["Queued on your iPhone", "Queued on your iPhone"])
    }

    /// Stop's confirmation is for the turn it was asked in: it closes, and stops nothing, once that turn is over or
    /// another has begun.
    func testTheStopConfirmationIsForItsTurn() {
        var thread = WatchThread(key: WatchFixtures.working, generated: now, title: "t", working: true,
                                 workingSince: now.addingTimeInterval(-30),
                                 items: [WatchItem(id: "u1", kind: .user, text: "Go")], canStop: true)
        let asked = ThreadScreen.stopKey(thread)
        XCTAssertNotNil(asked)
        XCTAssertTrue(ThreadScreen.stopStillMeant(asked, thread))
        thread.activity = "editing files"
        XCTAssertTrue(ThreadScreen.stopStillMeant(asked, thread), "the same turn going on")
        thread.canStop = false
        XCTAssertNil(ThreadScreen.stopKey(thread))
        XCTAssertFalse(ThreadScreen.stopStillMeant(asked, thread), "the turn ended")
        // The queue started the next turn.
        thread.canStop = true
        thread.items.append(WatchItem(id: "u2", kind: .user, text: "Then lint"))
        thread.workingSince = now
        XCTAssertFalse(ThreadScreen.stopStillMeant(asked, thread))
        XCTAssertFalse(ThreadScreen.stopStillMeant(nil, thread))
    }

    /// Stop is on the working line, only while the phone offers it; it asks first, naming the agent.
    func testStopOnlyWhileThePhoneOffersItAndItAsksFirst() {
        var thread = WatchThread(key: WatchFixtures.working, generated: now, title: "t", working: true, canStop: true)
        XCTAssertNotNil(ThreadScreen.stop(thread) {})
        thread.canStop = false
        XCTAssertNil(ThreadScreen.stop(thread) {}, "a stop on its way, or a conversation not live")
        thread.canStop = true
        thread.working = false
        XCTAssertNil(ThreadScreen.stop(thread) {})
        XCTAssertEqual(ThreadWorkingRow.stopTitle(agent: "Claude Code"), "Stop Claude")
        XCTAssertEqual(ThreadWorkingRow.stopTitle(agent: "claude"), "Stop Claude")
        XCTAssertEqual(ThreadWorkingRow.stopTitle(agent: "codex"), "Stop Codex")
        XCTAssertEqual(ThreadWorkingRow.stopTitle(agent: "pi"), "Stop Pi")
        XCTAssertEqual(ThreadWorkingRow.stopTitle(agent: "aider"), "Stop aider")
        XCTAssertEqual(ThreadWorkingRow.stopTitle(agent: nil), "Stop the agent")
        XCTAssertEqual(ThreadWorkingRow.stopTitle(agent: ""), "Stop the agent")
        XCTAssertEqual(ThreadWorkingRow.stopMessage, "Queued messages wait until Resume.")
    }

    /// Reply's first step: "Dictate or type", then the fixed quick replies, each leading to the confirm screen.
    func testQuickRepliesComeBeforeDictation() throws {
        XCTAssertEqual(QuickReplies.all, ["Continue", "Yes, do it", "Run the tests", "Commit it"])
        let shots = ProcessInfo.processInfo.environment["DISPATCH_WATCH_AGENTS_SHOTS"].map { URL(fileURLWithPath: $0) }
        let picker = VStack(spacing: 6) {
            CapsuleLabel(title: "Dictate or type", symbol: "mic.fill", style: .accent)
            ForEach(QuickReplies.all, id: \.self) { CapsuleLabel(title: $0) }
        }
        if let shots { try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true) }
        try render(picker, name: "quick-replies", to: shots)
    }

    /// The watch's own message on its way is a faded bubble, not a queue row.
    func testTheSendingMessageIsNotAQueueRow() {
        let queue = [WatchQueued(id: "a", text: "one"), WatchQueued(id: WatchModel.sendingID, text: "two", status: "Sending…")]
        let split = ThreadComposer.split(queue)
        XCTAssertEqual(split.queued.map(\.id), ["a"])
        XCTAssertEqual(split.sending.map(\.text), ["two"])
    }

    // MARK: Review sent (K8)

    func testTheReviewCardSaysWhatWentAndForHowLongUndoHolds() {
        let review = WatchReviewSent(id: "r", host: WatchFixtures.studio, node: "n", agent: "claude", title: "Sidebar theme toggle",
                                     comments: 3, files: 2, sent: now, undoUntil: now.addingTimeInterval(8))
        XCTAssertEqual(ReviewSentScreen.counts(review), "3 comments · 2 files")
        XCTAssertEqual(ReviewSentScreen.line(review, now: now.addingTimeInterval(3)), "Sent from your iPhone. Undo for 8 s, then claude reads it.")
        XCTAssertEqual(ReviewSentScreen.line(review, now: now.addingTimeInterval(9)), "Sent from your iPhone. claude has it.")
        var one = review
        one.comments = 1
        one.files = 1
        one.agent = nil
        XCTAssertEqual(ReviewSentScreen.counts(one), "1 comment · 1 file")
        XCTAssertEqual(ReviewSentScreen.line(one, now: now.addingTimeInterval(9)), "Sent from your iPhone. the agent has it.")
        XCTAssertTrue(review.undoable(at: now.addingTimeInterval(7.9)))
        XCTAssertFalse(review.undoable(at: now.addingTimeInterval(8)))
    }

    func testTheReviewAndReplyScreensRender() {
        let model = WatchModel(link: ScriptedWatchLink(scenario: .mockupReview, now: { [now] in now }), now: { [now] in now })
        let review = model.snapshot!.reviews[0]
        XCTAssertNotNil(ImageRenderer(content: ReviewSentContent(model: model, review: review).frame(width: 205, height: 251)).cgImage)
        let working = WatchThread(key: WatchFixtures.working, generated: now, title: "t", working: true, route: .queue)
        for actions in [ThreadComposer.actions(working), ThreadComposer.actions(nil)] {
            let reply = ReplyConfirmContent(draft: ReplyDraft(text: "Use the sidebar header", actions: actions), actions: actions) { _ in }
            XCTAssertNotNil(ImageRenderer(content: reply.frame(width: 205, height: 251)).cgImage)
        }
    }

    // MARK: Rendering

    /// Every scripted phone's rows, empty state and threads draw at watch size. With `DISPATCH_WATCH_AGENTS_SHOTS` set
    /// (`TEST_RUNNER_DISPATCH_WATCH_AGENTS_SHOTS` through xcodebuild) to a directory, the drawings are saved there as PNGs.
    func testEveryScenarioRenders() async throws {
        let shots = ProcessInfo.processInfo.environment["DISPATCH_WATCH_AGENTS_SHOTS"].map { URL(fileURLWithPath: $0) }
        if let shots { try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true) }
        // The real clock: the rows' times and the working line's `TimelineView` then agree in the drawings.
        let now = Date()
        for scenario in ScriptedWatchLink.Scenario.allCases {
            let link = ScriptedWatchLink(scenario: scenario, now: { now })
            let model = WatchModel(link: link, now: { now })
            let rows = VStack(alignment: .leading, spacing: 10) {
                ForEach(model.conversations) { AgentsRow(conversation: $0, host: model.host($0.host), now: now) }
                ForEach(AgentsScreen.blocked(hosts: model.hosts, conversations: model.conversations), id: \.host.id) {
                    AgentsBlockedNote(message: $0.message)
                }
                if model.conversations.isEmpty { AgentsEmptyState(waiting: model.snapshot == nil) }
            }
            try render(rows, name: "rows-\(scenario.rawValue)", to: shots)
            for key in link.threads.keys.sorted(by: { $0.node < $1.node }) {
                await model.loadThread(key)
                guard let thread = model.thread(for: key) ?? link.threads[key] else { continue }
                try render(ThreadDrawing(thread: thread, cpu: model.host(key.host).flatMap(ThreadHeader.cpu)), name: "thread-\(scenario.rawValue)-\(thread.title.prefix(12))", to: shots)
            }
        }
        if let shots {
            let question = WatchFixtures.threads(now: now)[WatchFixtures.question]!.questions[0]
            try render(QuestionDrawing(question: question), name: "question-form", to: shots)
            for (name, thread) in [("working", WatchFixtures.threads(now: now)[WatchFixtures.working]!),
                                   ("idle", WatchFixtures.threads(now: now)[WatchFixtures.notes]!)] {
                let actions = ThreadComposer.actions(thread)
                try render(ReplyConfirmStack(draft: ReplyDraft(text: "Use the sidebar header", actions: actions), actions: actions) { _ in },
                           name: "confirm-\(name)", to: shots)
            }
        }
    }

    private func render(_ view: some View, name: String, to directory: URL?) throws {
        let renderer = ImageRenderer(content: view
            .frame(width: 187)
            .padding(.vertical, 8)
            .background(.black)
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, name)
        XCTAssertGreaterThan(image.height, 20, name)
        guard let directory else { return }
        let url = directory.appendingPathComponent(name.replacingOccurrences(of: " ", with: "-") + ".png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

/// A thread page as `ThreadScreen` lists it, in a stack (a `List` does not draw in `ImageRenderer`): header, the Earlier
/// row and the newest turn's items, working line with its Stop, cards and their chips, queue, composer (Reply, Open on
/// iPhone).
private struct ThreadDrawing: View {
    let thread: WatchThread
    /// The host's CPU for the header.
    var cpu: Double?

    var body: some View {
        let (queued, sending) = ThreadComposer.split(thread.queue)
        VStack(alignment: .leading, spacing: 6) {
            ThreadHeader(thread: thread, cpu: cpu)
            let turns = ThreadScreen.turns(thread)
            if !turns.earlier.isEmpty {
                Label(ThreadScreen.earlierTitle(turns.earlier.count), systemImage: "chevron.up")
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 44)
            } else if thread.earlier {
                Text("Earlier messages are on your iPhone").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            ForEach(turns.newest) { item in
                if item.id == ThreadScreen.card(thread) {
                    ThreadSummaryCard(item: item, agent: thread.agent)
                } else {
                    ThreadItemRow(item: item, agent: thread.agent)
                }
            }
            ForEach(sending) { item in ThreadBubble(side: .user, faded: true) { Text(item.text) } }
            if thread.working { ThreadWorkingRow(activity: thread.activity, since: thread.workingSince, stop: ThreadScreen.stop(thread) {}) }
            ForEach(thread.approvals) { approval in
                let layout = ApprovalCard.layout(approval.choices)
                ApprovalCard(approval: approval, agent: thread.agent)
                HStack(spacing: 6) {
                    ForEach(layout.row) { choice in chip(choice) }
                }
                ForEach(layout.below) { choice in chip(choice) }
            }
            ForEach(thread.questions) { question in
                QuestionCard(question: question)
                CapsuleLabel(title: "Answer", style: .accent)
            }
            if !queued.isEmpty {
                QueueHeader(count: queued.count)
                ForEach(queued) { item in
                    QueuedRow(item: item).padding(.horizontal, 8).modifier(ThreadButtonRow())
                        .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if ThreadScreen.offersReply(thread) { CapsuleLabel(title: "Reply", symbol: "mic.fill", style: .accent) }
            CapsuleLabel(title: "Open on iPhone", symbol: "iphone")
        }
    }

    private func chip(_ choice: WatchChoice) -> some View {
        let style = ApprovalButtonStyle.of(choice)
        return CapsuleLabel(title: choice.label, style: style == .prominent ? .accent : style == .destructive ? .destructive : .glass)
    }
}

/// The question sheet's content as a stack: each part, its options with their marks, the typed answer's row, Send, Skip.
private struct QuestionDrawing: View {
    let question: WatchQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(question.parts.enumerated()), id: \.offset) { index, part in
                Text(part.text).font(.footnote)
                if let position = QuestionSheet.position(index, of: question.parts.count) {
                    Text(position).font(.caption2).foregroundStyle(.tertiary)
                }
                ForEach(part.options) { option in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(option.label)
                            if let detail = option.detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Image(systemName: option.index == 0 ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(option.index == 0 ? AgentsColor.pink : .secondary)
                    }
                    .padding(.horizontal, 10).modifier(ThreadButtonRow())
                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                }
                if part.custom {
                    Label("Dictate or type", systemImage: "mic").padding(.horizontal, 10).modifier(ThreadButtonRow())
                        .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            CapsuleLabel(title: "Send", style: .accent)
            CapsuleLabel(title: "Skip")
        }
    }
}
