import SwiftUI
import XCTest
@testable import DispatchMobile

/// What the thread draws: bubbles, the banner, the composer's slot and the steps, rendered off screen.
@MainActor
final class ChatRenderingTests: XCTestCase {
    private func size<V: View>(_ view: V, width: CGFloat = 402) -> CGSize {
        let renderer = ImageRenderer(content: view.frame(width: width).environment(\.colorScheme, .dark))
        renderer.scale = 1
        return renderer.uiImage?.size ?? .zero
    }

    /// The drawn extent (non-transparent pixels) of `view` laid out in a column `width` wide.
    private func extent<V: View>(_ view: V, width: CGFloat) -> CGRect {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        guard let image = renderer.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return .zero }
        var box = CGRect.null
        let alpha = image.alphaInfo == .premultipliedFirst || image.alphaInfo == .first ? 0 : 3
        for y in 0..<image.height {
            for x in 0..<image.width where bytes[y * image.bytesPerRow + x * image.bitsPerPixel / 8 + alpha] > 0 {
                box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return box
    }

    func testBubblesHugShortTextAndWrapAtTheirShareOfTheColumn() {
        func bubble(_ side: ChatBubble<Text>.Side, _ text: String) -> some View {
            ChatBubble(side: side) { Text(text) }.environment(\.chatColumnWidth, 370)
        }
        let short = extent(bubble(.user, "Yes"), width: 370)
        XCTAssertLessThan(short.width, 120, "A short reply hugs its text")
        XCTAssertEqual(short.maxX, 370, accuracy: 1, "The user's bubble sits on the right")
        let long = String(repeating: "Make billing webhook retries idempotent. ", count: 4)
        let user = extent(bubble(.user, long), width: 370), agent = extent(bubble(.agent, long), width: 370)
        // Wrapped at word boundaries, within 78% of the column for the user and 86% for the agent.
        XCTAssertLessThanOrEqual(user.width, 370 * 0.78 + 1)
        XCTAssertGreaterThan(user.width, 370 * 0.6)
        XCTAssertLessThanOrEqual(agent.width, 370 * 0.86 + 1)
        let unbroken = extent(bubble(.agent, String(repeating: "x", count: 120)), width: 370)
        XCTAssertLessThanOrEqual(unbroken.width, 370 * 0.86 + 1)
        XCTAssertGreaterThan(unbroken.width, 370 * 0.78 + 1, "The agent's bubble may be wider than the user's")
        XCTAssertEqual(agent.minX, 0, accuracy: 1, "The agent's bubble sits on the left")
        XCTAssertGreaterThan(agent.height, 60, "Long text wraps onto more lines")
    }

    func testLargeQuestionDetailsDropTo8pt() {
        let short = "Keeps the current layout"
        let long = String(repeating: "Moves the sidebar below the editor. ", count: 6)
        XCTAssertFalse(ChatQuestionDetail.isLarge(short))
        XCTAssertTrue(ChatQuestionDetail.isLarge(long))
        XCTAssertTrue(ChatQuestionDetail.isLarge("+------+\n| tabs |\n+------+"), "A layout is large however short")
        let line = size(ChatQuestionDetail(text: short), width: 300).height
        // 216 characters: four lines of 8 pt mono in 300 pt, six of footnote mono.
        XCTAssertLessThan(size(ChatQuestionDetail(text: long), width: 300).height, line * 3)
    }

    func testTheBannerSaysWhereTheLinkIs() {
        XCTAssertNil(ChatLinkBanner.title(.connected, host: "mba2"))
        XCTAssertEqual(ChatLinkBanner.title(.reconnecting(attempt: 2, since: Date()), host: "mba2"), "Reconnecting to mba2")
        XCTAssertEqual(ChatLinkBanner.title(.bootstrapping, host: "mba2"), "Connecting to mba2")
        XCTAssertEqual(ChatLinkBanner.title(.failed("refused"), host: "mba2"), "Can’t reach mba2")
        XCTAssertEqual(size(ChatLinkBanner(link: .connected, host: "mba2")).height, 0, "No banner while connected")
        XCTAssertEqual(size(ChatLinkBanner(link: .reconnecting(attempt: 1, since: Date()), host: "mba2")).height, 38, "32 pt and 6 below (M4c)")
        // Why it is down, on a second line: the banner grows to hold it.
        let problem = "mba2.tail3f.ts.net didn’t answer on port 22. Check that Tailscale is on and the host is awake."
        XCTAssertGreaterThan(size(ChatLinkBanner(link: .reconnecting(attempt: 1, since: Date()), host: "mba2", problem: problem)).height, 50)
    }

    func testAgentMarkdownKeepsOnlyCredentialFreeWebLinks() {
        let value = MobileChatMarkdown.text(
            "[secure](https://example.com/docs) [web](http://example.com) [file](file:///etc/passwd) " +
            "[shell](ssh://host.test) [script](javascript:alert%281%29) [credential](https://user:pass@example.com)")
        XCTAssertEqual(value.runs.compactMap { $0.link?.absoluteString },
                       ["https://example.com/docs", "http://example.com"])
        for label in ["secure", "web", "file", "shell", "script", "credential"] {
            XCTAssertTrue(String(value.characters).contains(label))
        }
    }

    func testTheComposerSlotFollowsTheDraftAndTheAgent() {
        XCTAssertEqual(CodeComposer.slot(text: ""), .mic)
        XCTAssertEqual(CodeComposer.slot(text: "  "), .mic, "Stop is on the working row, not in the send slot")
        XCTAssertEqual(CodeComposer.slot(text: "next"), .send)
        XCTAssertEqual(CodeComposer.slot(text: "next", dictating: true), .mic)
    }

    func testReducedMotionElapsedStepsByFive() {
        XCTAssertEqual(ChatElapsed.text(7, reduceMotion: true), "7s")
        XCTAssertEqual(ChatElapsed.text(14, reduceMotion: true), "10s")
        XCTAssertEqual(ChatElapsed.text(86, reduceMotion: true), "1m 25s")
        XCTAssertEqual(ChatElapsed.text(86, reduceMotion: false), "1m 26s")
    }

    func testStepsReadAsTheMockupsLog() throws {
        var transcript = MobileTranscript()
        transcript.apply(try JSONDecoder().decode([HelperChat.Record].self, from: JSONSerialization.data(
            withJSONObject: try ChatFixture.records("claude-thread"))), historical: true)
        let steps = ChatStep.steps(transcript.turns[0], directory: "/work/app", reasoning: false)
        XCTAssertEqual(steps.map(\.kind.label), ["Read", "Search", "Patch", "Run", "Read"])
        XCTAssertEqual(steps.map(\.title), ["src/routes/billing.ts", "attempt · in src", "src/lib/idempotent.ts",
                                           "pnpm test billing", "src/lib/stripe.ts"])
        XCTAssertEqual(steps[2].detail, "+2 −1")
        XCTAssertEqual(steps[3].detail, "12 passed")
        // Another directory: paths fall back to the one the agent recorded.
        XCTAssertEqual(ChatStep.steps(transcript.turns[1], directory: "/Users/me/elsewhere", reasoning: false).first?.title,
                       "src/routes/invoices.ts")
        // A patch that did not apply shows its state, not its counts (the Mac's tool card).
        var declined = try XCTUnwrap(transcript.turns[0].items.first { ChatStep($0, directory: nil).kind == .patch })
        declined.patch = ChatPatch(documents: declined.patch?.documents ?? [], state: .declined)
        let step = ChatStep(declined, directory: "/work/app")
        XCTAssertEqual([step.additions, step.deletions], [0, 0])
        XCTAssertEqual(step.detail, "Patch declined")
        // A shell search reads as Search, as the Mac titles it.
        let rg = ChatItem(id: "rg", kind: .tool, text: #"{"command":"rg -n retry src"}"#, title: "Bash", completed: true)
        XCTAssertEqual(ChatStep(rg, directory: nil).kind.label, "Search")
    }

    /// Every kind badge is as wide as the widest word, at any text size: what each step acted on starts at one place.
    func testStepBadgesShareOneWidth() {
        for size in [DynamicTypeSize.large, .accessibility2] {
            let widths = Set([ChatStep.Kind.read, .patch, .run, .search, .think, .web, .tool].map { kind in
                self.size(ChatStepBadge(kind: kind).environment(\.dynamicTypeSize, size).fixedSize(), width: 402).width
            })
            XCTAssertEqual(widths.count, 1, "\(size): \(widths)")
        }
    }

    func testTheWorkingRowFoldsToOneLine() async throws {
        let helper = ScriptedHelper()
        helper.script { $0.method == "chat.open" ? .open : .result([Any]()) }
        let session = MobileChatSession.scripted(helper)
        try await TestSupport.eventually { helper.subscription("chat.open") != nil }
        helper.notify(helper.subscription("chat.open")!, "chat.history", ChatFixture.history(state: ChatFixture.state(busy: true)))
        try await TestSupport.eventually { session.working }
        let row = ChatWorkingRow(session: session, directory: nil, expanded: .constant(true), openStep: { _ in })
        let step = size(ChatStepLogRow(step: nil)).height
        XCTAssertEqual(size(row).height, 45 + 26 + 4 * step + 3 * ChatStepWindow.rule + 6, accuracy: 1,
                       "The 44 pt row and its hairline, the steps line, a window four steps tall with no step in it yet")
        let folded = ChatWorkingRow(session: session, directory: nil, expanded: .constant(false), openStep: { _ in })
        XCTAssertEqual(size(folded).height, 45, accuracy: 1, "Folded, the row is its hairline and 44 pt")
    }

    /// Every step of the live log is two lines tall, with a result or without, at any text size: the window over them
    /// never changes height.
    func testEveryLogStepIsTwoLinesTall() {
        let read = ChatStep(ChatItem(id: "r", kind: .tool, text: #"{"file_path":"/w/a.ts"}"#, title: "Read", completed: true), directory: "/w")
        var item = ChatItem(id: "c", kind: .tool, text: #"{"command":"cargo test"}"#, title: "Bash", completed: true)
        item.exitCode = 1
        let failed = ChatStep(item, directory: "/w")
        XCTAssertNil(read.detail)
        XCTAssertTrue(failed.failed)
        for typeSize in [DynamicTypeSize.large, .accessibility2] {
            let heights = [ChatStepLogRow(step: nil), ChatStepLogRow(step: read), ChatStepLogRow(step: failed, live: true)]
                .map { size($0.environment(\.dynamicTypeSize, typeSize)).height }
            XCTAssertEqual(Set(heights.map { $0.rounded() }).count, 1, "\(typeSize): \(heights)")
        }
    }

    /// The steps line's limits (N4a): the week, the longest window still running, with when it resets; an account that
    /// still reports the 5-hour window shows that one in the reset's place. Dim under 80%.
    func testTheStepsLineShowsTheWeekAndTheFiveHourWindowInItsResetsPlace() {
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let week = ChatLimitWindow(name: "seven_day", used: 83, resets_at: now.timeIntervalSince1970 + 3 * 86_400)
        let hours = ChatLimitWindow(name: "five_hour", used: 42, resets_at: now.timeIntervalSince1970 + 8_280)
        let gone = ChatLimitWindow(name: "five_hour", used: 99, resets_at: now.timeIntervalSince1970 - 60)
        XCTAssertEqual(ChatLimitsLine.windows([hours, week], now: now)?.main, week)
        XCTAssertEqual(ChatLimitsLine.windows([hours, week], now: now)?.short, hours)
        XCTAssertNil(ChatLimitsLine.windows([week, gone], now: now)?.short, "a window past its reset is not shown")
        XCTAssertNil(ChatLimitsLine.windows([], now: now))
        let codex = ChatLimitWindow(name: "window_10080", used: 10, resets_at: now.timeIntervalSince1970 + 86_400 * 2)
        XCTAssertEqual(codex.minutes, 10080)
        XCTAssertEqual(ChatLimitsLine.resets(hours, now: now), "resets in 2h 18m")
        XCTAssertTrue(ChatLimitsLine.resets(week, now: now).hasPrefix("resets "), ChatLimitsLine.resets(week, now: now))
        // "64% weekly · resets mon 11pm": the share, then the window's name, all lowercase.
        XCTAssertEqual(ChatLimitsLine.resets(week, now: now), ChatLimitsLine.resets(week, now: now).lowercased())
        XCTAssertEqual(ChatLimitsLine.share(week), "\(week.used)% weekly")
        XCTAssertEqual(ChatLimitsLine.share(hours), "42% 5-hour")
        XCTAssertEqual(ChatLimitsLine.share(week, named: false), "\(week.used)%")
        XCTAssertEqual(ChatLimitsLine.spoken([hours, week], now: now).components(separatedBy: ". ").count, 2)
        XCTAssertEqual(ChatUsageText.text(nil, cost: false), nil)
        let counted = ChatUsage(["info": ["total_token_usage": ["input_tokens": 182_400, "output_tokens": 12_350],
                                          "total_cost_usd": 0.042]])
        XCTAssertEqual(ChatUsageText.text(counted, cost: false), "182.4K in · 12.3K out")
        XCTAssertEqual(ChatUsageText.text(counted, cost: true), "182.4K in · 12.3K out · $0.042", "Pi's cost")
        let off = ChatUsage(["info": ["last_token_usage": ["total_tokens": 64_000], "model_context_window": 200_000]])
        XCTAssertNotNil(off)
        XCTAssertNil(ChatUsageText.text(off, cost: false), "token counter off: nothing said of it")
    }

    /// The limits are read only after the user agreed for that agent, then at most every 10 minutes per host and agent; a
    /// failure is not kept, Not Now holds for the run.
    func testLimitsAreReadOnlyAfterConsentAndAtMostEveryTenMinutes() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "limits-\(UUID().uuidString)"))
        var now = Date(timeIntervalSince1970: 1_794_000_000)
        let reader = ChatLimitsReader(defaults: defaults, clock: { now })
        let key = ChatLimitsReader.Key(host: UUID(), agent: "claude")
        var reads = 0
        let read: @MainActor () async throws -> [ChatLimitWindow] = {
            reads += 1
            return [ChatLimitWindow(name: "seven_day", used: 18, resets_at: 1_794_866_400)]
        }
        reader.open(key, read: read)
        XCTAssertNil(reader.phases[key], "nothing asked before Show Limits")
        reader.decline("claude")
        XCTAssertTrue(reader.declined("claude"))
        reader.accept("claude")
        XCTAssertTrue(ChatLimitsReader(defaults: defaults).consented("claude"), "kept on this device")
        reader.open(key, read: read)
        try await TestSupport.eventually { if case .shown = reader.phases[key] { true } else { false } }
        reader.open(key, read: read)
        XCTAssertEqual(reads, 1, "within the minute, the reading answers")
        now += 300
        reader.open(key, read: read)
        XCTAssertEqual(reads, 1, "and within 10 minutes")
        now += 301
        reader.open(key, read: read)
        try await TestSupport.eventually { reads == 2 }
        try await TestSupport.eventually { if case .shown = reader.phases[key] { true } else { false } }
        now += 601
        reader.open(key) { throw HelperFailure(code: "expired", message: "Claude Code did not run its status line") }
        try await TestSupport.eventually { reader.phases[key] == .failed("Claude Code did not run its status line") }
        reader.open(key, read: read)
        try await TestSupport.eventually { reads == 3 }
    }

    /// Running subagents take one step's place in the unfolded log, over the steps line: the log keeps its height, at
    /// any text size. Their row says how many, their tasks (else types) and their tokens together.
    func testTheAgentsRowTakesAStepsPlace() {
        let start = Date(timeIntervalSince1970: 1_000)
        let agents = [ChatSubagent(id: "a1", kind: "Explore", name: "Find every webhook handler", tokens: 18_400, started: start),
                      ChatSubagent(id: "a2", kind: "general-purpose", tokens: 6_200, started: start)]
        for typeSize in [DynamicTypeSize.large, .accessibility2] {
            let plain = size(ChatStepWindow(steps: [], openStep: { _ in }).environment(\.dynamicTypeSize, typeSize)).height
            let with = size(ChatStepWindow(steps: [], agents: agents, openStep: { _ in }).environment(\.dynamicTypeSize, typeSize)).height
            XCTAssertEqual(with, plain, accuracy: 1, "\(typeSize)")
        }
        XCTAssertEqual(ChatAgentsLogRow.title(1), "1 agent running")
        XCTAssertEqual(ChatAgentsLogRow.title(2), "2 agents running")
        XCTAssertEqual(ChatAgentsLogRow.detail(agents), "Find every webhook handler · general-purpose")
        XCTAssertEqual(ChatAgentsLogRow.tokens(agents), "24.6K tokens")
        XCTAssertNil(ChatAgentsLogRow.tokens([ChatSubagent(id: "x", kind: "Explore", started: start)]))
        XCTAssertTrue(ChatStepWindow.hidden(count: 5, offset: 0, pitch: 50, visible: 3) == (0, 2), "three shown under the agents")
    }

    /// The log's line counts the steps and, once they outnumber the window, what lies above and below it.
    func testTheLogLineSaysWhatTheWindowHides() {
        func read(_ id: String) -> ChatStep {
            ChatStep(ChatItem(id: id, kind: .tool, text: #"{"file_path":"/w/\#(id).ts"}"#, title: "Read", completed: true), directory: "/w")
        }
        let thought = ChatStep(ChatItem(id: "t", kind: .reasoning, text: "Checking the guard", title: "", completed: true), directory: nil)
        XCTAssertEqual(ChatStepWindow.caption([], above: 0, below: 0), "No steps yet")
        XCTAssertEqual(ChatStepWindow.caption([read("a"), thought], above: 0, below: 0), "1 step · 1 thought")
        let twelve = (0..<12).map { read("\($0)") }
        XCTAssertEqual(ChatStepWindow.caption(twelve, above: 5, below: 3), "12 steps · 5 above · 3 below")
        XCTAssertTrue(ChatStepWindow.hidden(count: 3, offset: 0, pitch: 50) == (0, 0), "Three fit")
        XCTAssertTrue(ChatStepWindow.hidden(count: 12, offset: 0, pitch: 50) == (0, 8), "At the top")
        XCTAssertTrue(ChatStepWindow.hidden(count: 12, offset: 260, pitch: 50) == (5, 3))
        XCTAssertTrue(ChatStepWindow.hidden(count: 12, offset: 900, pitch: 50) == (8, 0), "At the foot, bounced past it")
    }

    /// A user message's images sit above its bubble on the user's side, within the bubble's share: one large, else up
    /// to four a row; the composer's strip is one row of chips.
    func testAttachmentsSitAboveTheBubbleWithinItsShare() {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 40)).pngData { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        }
        func image(_ index: Int) -> ChatAttachment {
            ChatAttachment(id: "i\(index)", name: "shot.png", kind: .image, size: 1, path: nil, thumbnail: png)
        }
        func message(_ attachments: [ChatAttachment], text: String = "Like this") -> some View {
            ChatUserMessage(text: text, attachments: attachments).environment(\.chatColumnWidth, 370)
        }
        let share = 370 * 0.78
        XCTAssertEqual(ChatMessageAttachments.tile(count: 1, width: share), 220)
        XCTAssertEqual(ChatMessageAttachments.tile(count: 4, width: share), 69)
        let one = extent(message([image(0)]), width: 370)
        XCTAssertEqual(one.maxX, 370, accuracy: 1, "On the user's side")
        XCTAssertGreaterThan(one.height, 220 + 30, "The image, then the bubble")
        let four = extent(message((0..<4).map(image)), width: 370)
        XCTAssertLessThanOrEqual(four.width, share + 1)
        let five = extent(message((0..<5).map(image), text: ""), width: 370)
        XCTAssertEqual(five.height, 69 * 2 + 4, accuracy: 2, "Two rows, no bubble without text")
        let file = ChatAttachment(name: "notes.txt", kind: .file, size: 2048, path: "/stored/n.txt")
        XCTAssertLessThanOrEqual(extent(message([file]), width: 370).width, share + 1)
        let strip = ComposerAttachmentStrip(attachments: ComposerAttachments(chips: [
            .init(id: "a", name: "shot.png", kind: .image, thumbnail: png),
            .init(id: "b", name: "notes.txt", kind: .file, detail: "2 KB", uploading: true)]))
        XCTAssertEqual(size(strip).height, ComposerAttachmentStrip.height, accuracy: 1)
    }
}

extension ChatRenderingTests {
    /// Message details' steps (M1): up to eight show as they are; past that the patches, the failed steps and the last
    /// stay, runs of two or more between them fold into a row saying what they did, and a run of one shows.
    func testMessageDetailsFoldLongStepLists() {
        func read(_ id: String) -> ChatStep {
            ChatStep(ChatItem(id: id, kind: .tool, text: #"{"file_path":"/w/\#(id).ts"}"#, title: "Read", completed: true), directory: "/w")
        }
        func run(_ id: String, exit: Int = 0) -> ChatStep {
            var item = ChatItem(id: id, kind: .tool, text: #"{"command":"cargo test"}"#, title: "Bash", completed: true)
            item.exitCode = exit
            return ChatStep(item, directory: "/w")
        }
        func search(_ id: String) -> ChatStep {
            ChatStep(ChatItem(id: id, kind: .tool, text: #"{"command":"rg -n \#(id) src"}"#, title: "Bash", completed: true), directory: "/w")
        }
        let short = [read("a"), read("b"), run("c")]
        XCTAssertEqual(ChatStepFold.entries(short), [.step(0), .step(1), .step(2)])
        XCTAssertEqual([read("a"), run("b")].map(\.kind), [.read, .run])
        XCTAssertEqual(search("s").kind, .search)
        XCTAssertTrue(run("f", exit: 1).failed)

        let steps = [read("r1"), search("s1"), read("r2"), search("s2"),  // 0–3 fold
                     run("bad", exit: 2),                                 // 4 failed: stays
                     read("r3"),                                          // 5 a run of one: shows
                     run("fail", exit: 1),                                // 6 stays
                     run("b1"), read("r4"), run("b2"),                    // 7–9 fold
                     run("last")]                                         // 10 the last: stays
        XCTAssertEqual(ChatStepFold.entries(steps), [
            .fold(0..<4, "Read 2 files, searched twice"), .step(4), .step(5), .step(6),
            .fold(7..<10, "Ran 2 commands, read 1 file"), .step(10),
        ])
        XCTAssertEqual(ChatStepFold.summary(steps[0..<1]), "Read 1 file")
        XCTAssertEqual(ChatStepFold.summary([search("a"), search("b"), search("c")][...]), "Searched 3 times")
    }

    /// The outcome line's span: start and end the same day, the end with its day when it changed, and nothing for a turn
    /// read without times.
    func testMessageDetailsSpanSaysWhenTheTurnRan() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15 08:00 UTC
        func turn(_ start: TimeInterval, _ end: TimeInterval?) -> ChatTurn {
            var turn = ChatTurn(id: "t")
            turn.started = now.addingTimeInterval(start)
            turn.ended = end.map { now.addingTimeInterval($0) }
            return turn
        }
        XCTAssertEqual(ChatMessageDetails.span(turn(-300, -48), duration: 252, now: now, calendar: calendar), "07:55 – 07:59 · 4m 12s")
        XCTAssertEqual(ChatMessageDetails.span(turn(-60, nil), duration: nil, now: now, calendar: calendar), "07:59",
                       "while working: when it started")
        XCTAssertEqual(ChatMessageDetails.span(turn(-8.5 * 3600, -7.9 * 3600), duration: nil, now: now, calendar: calendar),
                       "Yesterday 23:30 – 00:06")
        XCTAssertEqual(ChatMessageDetails.span(turn(-40 * 86400, -40 * 86400 + 52), duration: 52, now: now, calendar: calendar),
                       "6 Dec 2026, 08:00 – 08:00 · 52s", "past a week: the date and the time of day")
        var historical = ChatTurn(id: "h")
        historical.started = Date(timeIntervalSince1970: 0)
        XCTAssertNil(ChatMessageDetails.span(historical, duration: nil, now: now, calendar: calendar))
    }
}
