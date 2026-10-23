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

    /// Claude's sparkle, Codex's angle brackets, Pi's π, a terminal otherwise; by key or by the thread's label.
    func testAgentMarks() {
        XCTAssertEqual(AgentsGlyph.agent("claude"), .symbol("sparkle"))
        XCTAssertEqual(AgentsGlyph.agent("Claude Code"), .symbol("sparkle"))
        XCTAssertEqual(AgentsGlyph.agent("Codex"), .symbol("chevron.left.forwardslash.chevron.right"))
        XCTAssertEqual(AgentsGlyph.agent("pi"), .letter("π"))
        XCTAssertEqual(AgentsGlyph.agent(nil), .symbol("apple.terminal"))
        XCTAssertEqual(AgentsGlyph.agent("aider"), .symbol("apple.terminal"))
        XCTAssertEqual(AgentsGlyph.agent("pipeline"), .symbol("apple.terminal"))
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

    func testToolLinesAndTheirSymbols() {
        var tool = WatchItem(id: "t", kind: .tool, text: "cargo test", tool: "Run", detail: "ok")
        XCTAssertEqual(ThreadItemRow.toolLine(tool), "Run · cargo test · ok")
        XCTAssertEqual(ThreadItemRow.symbol(for: tool), "checkmark.circle.fill")
        XCTAssertEqual(ThreadItemRow.accessibilityLabel(tool, agent: nil), "Run · cargo test · ok, done")
        tool.failed = true
        XCTAssertEqual(ThreadItemRow.symbol(for: tool), "xmark.circle.fill")
        tool.running = true
        XCTAssertEqual(ThreadItemRow.symbol(for: tool), "ellipsis.circle")
        XCTAssertEqual(ThreadItemRow.accessibilityLabel(tool, agent: nil), "Run · cargo test · ok, running")
        XCTAssertEqual(ThreadItemRow.toolLine(WatchItem(id: "u", kind: .tool, text: "lookup")), "Tool · lookup")
        XCTAssertNil(ThreadItemRow.symbol(for: WatchItem(id: "m", kind: .agent, text: "Hi")))
    }

    func testItemsSayWhoSpeaks() {
        XCTAssertEqual(ThreadItemRow.accessibilityLabel(WatchItem(id: "1", kind: .user, text: "Go"), agent: "Codex"), "You: Go")
        XCTAssertEqual(ThreadItemRow.accessibilityLabel(WatchItem(id: "2", kind: .agent, text: "Done.", caption: "2 steps · 4s"), agent: "Codex"),
                       "Codex: Done., 2 steps · 4s")
        XCTAssertEqual(ThreadItemRow.accessibilityLabel(WatchItem(id: "3", kind: .thinking, text: "Hmm"), agent: nil), "Thinking: Hmm")
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
        // Working with steps after its last message: the newest step, its bottom.
        XCTAssertEqual(ThreadScreen.anchor(threads[WatchFixtures.working]!)?.id, "w3")
        XCTAssertEqual(ThreadScreen.anchor(threads[WatchFixtures.working]!)?.top, false)
        XCTAssertNil(ThreadScreen.anchor(WatchThread(key: WatchFixtures.notes, generated: now, title: "t")))
    }

    /// The card is the newest agent message unless the user wrote after it.
    func testTheSummaryCardIsTheNewestAnswer() {
        var thread = WatchFixtures.threads(now: now)[WatchFixtures.notes]!
        XCTAssertEqual(ThreadScreen.card(thread), "n2")
        thread.items.append(WatchItem(id: "n3", kind: .tool, text: "README.md", tool: "Read"))
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
        let reply = ReplyConfirmContent(draft: ReplyDraft(text: "Use the sidebar header", steer: false), route: "Queued until this turn ends") {}
        XCTAssertNotNil(ImageRenderer(content: reply.frame(width: 205, height: 251)).cgImage)
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
                try render(ThreadDrawing(thread: thread), name: "thread-\(scenario.rawValue)-\(thread.title.prefix(12))", to: shots)
            }
        }
        if let shots {
            let question = WatchFixtures.threads(now: now)[WatchFixtures.question]!.questions[0]
            try render(QuestionDrawing(question: question), name: "question-form", to: shots)
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

/// A thread page as `ThreadScreen` lists it, in a stack (a `List` does not draw in `ImageRenderer`): header, items,
/// working line, cards and their chips, queue, composer.
private struct ThreadDrawing: View {
    let thread: WatchThread

    var body: some View {
        let (queued, sending) = ThreadComposer.split(thread.queue)
        VStack(alignment: .leading, spacing: 6) {
            ThreadHeader(thread: thread)
            if thread.earlier {
                Text("Earlier messages are on your iPhone").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            ForEach(thread.items) { item in
                if item.id == ThreadScreen.card(thread) {
                    ThreadSummaryCard(item: item, agent: thread.agent)
                } else {
                    ThreadItemRow(item: item, agent: thread.agent)
                }
            }
            ForEach(sending) { item in ThreadBubble(side: .user, faded: true) { Text(item.text) } }
            if thread.working { ThreadWorkingRow(activity: thread.activity, since: thread.workingSince) }
            ForEach(thread.approvals) { approval in
                ApprovalCard(approval: approval, agent: thread.agent)
                ForEach(ApprovalCard.ordered(approval.choices)) { choice in
                    let style = ApprovalButtonStyle.of(choice)
                    CapsuleLabel(title: choice.label, style: style == .prominent ? .accent : style == .destructive ? .destructive : .glass)
                }
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
            CapsuleLabel(title: "Reply", symbol: "mic.fill", style: .accent)
            if ThreadComposer.canSteer(thread) { CapsuleLabel(title: "Steer", symbol: "arrow.turn.down.right") }
            if thread.canStop { CapsuleLabel(title: "Stop", symbol: "stop.fill", style: .destructive) }
            CapsuleLabel(title: "Open on iPhone", symbol: "iphone")
        }
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
