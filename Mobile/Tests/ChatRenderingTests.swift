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
        XCTAssertEqual(CodeComposer.slot(text: "", working: false), .mic)
        XCTAssertEqual(CodeComposer.slot(text: "  ", working: true), .stop, "Stop takes the send slot (M5a)")
        XCTAssertEqual(CodeComposer.slot(text: "next", working: true), .send)
        XCTAssertEqual(CodeComposer.slot(text: "next", working: false), .send)
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

    func testTheWorkingRowFoldsToOneLine() async throws {
        let helper = ScriptedHelper()
        helper.script { $0.method == "chat.open" ? .open : .result([Any]()) }
        let session = MobileChatSession.scripted(helper)
        try await TestSupport.eventually { helper.subscription("chat.open") != nil }
        helper.notify(helper.subscription("chat.open")!, "chat.history", ChatFixture.history(state: ChatFixture.state(busy: true)))
        try await TestSupport.eventually { session.working }
        let row = ChatWorkingRow(session: session, directory: nil, expanded: .constant(true), openStep: { _ in })
        XCTAssertEqual(size(row).height, 45 + 6 + 22, accuracy: 8, "The 44 pt row, its hairline and the hint")
        let folded = ChatWorkingRow(session: session, directory: nil, expanded: .constant(false), openStep: { _ in })
        XCTAssertEqual(size(folded).height, 45, accuracy: 1, "Folded, the row is its hairline and 44 pt")
    }
}
