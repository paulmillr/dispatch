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

    func testTheBannerSaysWhereTheLinkIs() {
        XCTAssertNil(ChatLinkBanner.title(.connected, host: "mba2"))
        XCTAssertEqual(ChatLinkBanner.title(.reconnecting(attempt: 2, since: Date()), host: "mba2"), "Reconnecting to mba2")
        XCTAssertEqual(ChatLinkBanner.title(.bootstrapping, host: "mba2"), "Connecting to mba2")
        XCTAssertEqual(ChatLinkBanner.title(.failed("refused"), host: "mba2"), "Can’t reach mba2")
        XCTAssertEqual(size(ChatLinkBanner(link: .connected, host: "mba2")).height, 0, "No banner while connected")
        XCTAssertEqual(size(ChatLinkBanner(link: .reconnecting(attempt: 1, since: Date()), host: "mba2")).height, 38, "32 pt and 6 below (M4c)")
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
