import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// Opening a long thread draws its end only (`ChatThreadView.firstShown`): older rows draw as the top of what is drawn
/// comes near on the user's scroll, without moving the rows being read, and the helper's earlier page is asked for only at the very top.
@MainActor
final class ChatThreadWindowTests: XCTestCase {
    /// `turns` turns of a question and its answer, each text unique ("Question 07.", "Answer 07.").
    private static func records(turns: Range<Int>, prefix: String = "w", word: String = "", sentences: Int = 5) -> [[String: Any]] {
        turns.flatMap { index -> [[String: Any]] in
            let turn = "\(prefix)\(index)", time = Int64(946_719_000_000 + (index + (word.isEmpty ? 10 : 0)) * 60_000)
            let number = String(format: "%02d", index)
            return [
                ChatFixture.record("\(turn):started", "turn_started", turn: turn, time: time, completed: false),
                ChatFixture.record("user-\(turn)", "user", turn: turn, text: "\(word)Question \(number).", time: time),
                ChatFixture.record("claude-\(turn)", "assistant", turn: turn,
                                   text: "\(word)Answer \(number). " + String(repeating: "The handler writes the invoice before it checks the event id. ", count: sentences),
                                   time: time + 1000),
                ChatFixture.record("\(turn):ended", "turn_ended", turn: turn, time: time + 2000),
            ]
        }
    }

    private func thread(sentences: Int = 5, queue: [[String: Any]] = []) async throws -> (MobileChatSession, ScriptedHelper, UIWindow) {
        let earlier = Self.records(turns: 0..<3, prefix: "e", word: "Earlier ")
        let helper = ScriptedHelper()
        helper.script { request in
            switch request.method {
            case "chat.open": return .open
            case "queue.list": return .result(queue)
            case "chat.page": return .result(["records": earlier, "earlier": NSNull()])
            default: return .result(NSNull())
            }
        }
        let chat = MobileChatSession.scripted(helper)
        try await TestSupport.eventually { helper.subscription("chat.open") != nil }
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        helper.notify(id, "chat.history", ChatFixture.history(state: ChatFixture.state(busy: false), pending: true))
        helper.notify(id, "chat.history", ChatFixture.history(records: Self.records(turns: 0..<40, sentences: sentences), earlier: "cursor-1"))
        try await TestSupport.eventually { chat.phase == .verified && !chat.loadingHistory }
        XCTAssertEqual(chat.transcript.rows.count, 80)

        AccessibilityLabelTests.enableAccessibility()
        let found = await TestSupport.windowScene()
        let window = UIWindow(windowScene: try XCTUnwrap(found))
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ChatThreadView(session: chat, space: "app", directory: "/work/app")
        })
        window.isHidden = false
        return (chat, helper, window)
    }

    /// The rows drawn, by their text's label.
    private func drawn(_ window: UIWindow) -> [String: CGRect] {
        var drawn: [String: CGRect] = [:]
        for element in AccessibilityLabelTests.elements(in: window) {
            guard let label = element.accessibilityLabel,
                  let range = label.range(of: #"(Earlier )?(Question|Answer) \d\d\."#, options: .regularExpression) else { continue }
            drawn[String(label[range])] = element.accessibilityFrame
        }
        return drawn
    }

    /// The user's drag to `offset` (the top by default).
    private func drag(_ scroll: UIScrollView, to offset: CGFloat? = nil) {
        scroll.delegate?.scrollViewWillBeginDragging?(scroll)
        scroll.setContentOffset(CGPoint(x: 0, y: offset ?? -scroll.adjustedContentInset.top), animated: false)
        scroll.delegate?.scrollViewDidEndDragging?(scroll, willDecelerate: false)
    }

    /// The rows drawn once their frames stop changing (accessibility frames follow a scroll a moment later).
    private func settled(_ window: UIWindow) async throws -> [String: CGRect] {
        var last: [String: CGRect] = [:]
        try await TestSupport.eventually {
            let now = drawn(window)
            defer { last = now }
            return !now.isEmpty && now == last
        }
        return last
    }

    /// The thread's scroll view: the tallest content (the composer's text view scrolls too).
    private func scrollView(_ view: UIView) -> UIScrollView? {
        var views: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, !(scroll is UITextView) { views.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return views.max { $0.contentSize.height < $1.contentSize.height }
    }

    func testAThreadOpensOnItsEndAndDrawsOlderRowsInPlaceNearItsTop() async throws {
        let (chat, helper, window) = try await thread()
        defer { window.isHidden = true }
        var shown: [String: CGRect] = [:]
        try await TestSupport.eventually(diagnostic: "\(shown.keys.sorted())") {
            shown = drawn(window)
            return shown["Answer 39."] != nil
        }
        XCTAssertLessThan(shown.count, 40, "only the end is drawn: \(shown.keys.sorted())")
        let opened = shown.count
        XCTAssertNil(shown["Question 00."])
        XCTAssertTrue(helper.requests("chat.page").isEmpty, "opening asks for no earlier page")

        // A screen from the top, nothing more draws; dragged on to the top, older rows draw above, and the rows in view
        // move by the drag alone.
        let scroll = try XCTUnwrap(scrollView(window))
        let below = scroll.bounds.height - scroll.adjustedContentInset.top
        drag(scroll, to: below)
        let before = try await settled(window)
        XCTAssertEqual(before.count, opened, "a screen from the top draws nothing more")
        let row = try XCTUnwrap(before.filter { $0.value.minY > 0 && $0.value.maxY < window.bounds.height }
            .min { $0.value.minY < $1.value.minY }, "a row in view: \(before)")
        drag(scroll)
        try await TestSupport.eventually(diagnostic: "offset \(scroll.contentOffset.y) of \(scroll.contentSize.height)") {
            drawn(window).count > opened
        }
        let after = try await settled(window)
        XCTAssertEqual(after[row.key]?.minY ?? -1, row.value.minY + scroll.bounds.height, accuracy: 1,
                       "\(row.key) moves by the drag only while older rows draw above it")
        XCTAssertTrue(helper.requests("chat.page").isEmpty, "older rows the phone has draw without a page")

        // At the very top, the earlier page is asked for once and its rows draw on.
        try await TestSupport.eventually(timeout: .seconds(10)) {
            drag(scroll)
            return drawn(window)["Question 00."] != nil && !helper.requests("chat.page").isEmpty
        }
        try await TestSupport.eventually(timeout: .seconds(10)) {
            drag(scroll)
            return drawn(window)["Earlier Question 00."] != nil
        }
        XCTAssertEqual(helper.requests("chat.page").count, 1)
        XCTAssertFalse(chat.hasEarlier)
    }

    func testShortRowsOpenWithAScreenFullOfThem() async throws {
        let (_, helper, window) = try await thread(sentences: 0)
        defer { window.isHidden = true }
        var shown: [String: CGRect] = [:]
        try await TestSupport.eventually(diagnostic: "\(shown.keys.sorted())") {
            shown = drawn(window)
            return shown["Answer 39."] != nil
        }
        XCTAssertGreaterThan(shown.count, 20, "rows a third the height: three times as many")
        XCTAssertLessThan(shown.count, 80, "the thread draws what fills the screen, not the page")
        XCTAssertTrue(helper.requests("chat.page").isEmpty)
    }

    func testOpeningAgainAsksForNoEarlierPage() async throws {
        let (_, helper, window) = try await thread()
        defer { window.isHidden = true }
        for _ in 0..<3 {
            try await TestSupport.eventually { drawn(window)["Answer 39."] != nil }
            let root = window.rootViewController
            window.rootViewController = nil
            try await TestSupport.eventually { drawn(window).isEmpty }
            window.rootViewController = root
        }
        try await TestSupport.eventually { drawn(window)["Answer 39."] != nil }
        XCTAssertTrue(helper.requests("chat.page").isEmpty, "each open drew from the page it had")
    }

    /// The thread's end is in view: its last point sits at the bottom of what the bars leave.
    private func atEnd(_ scroll: UIScrollView) -> Bool {
        scroll.contentOffset.y + scroll.bounds.height - scroll.adjustedContentInset.bottom >= scroll.contentSize.height - 2
    }

    func testOpeningAgainShowsTheEnd() async throws {
        let (chat, _, window) = try await thread()
        defer { window.isHidden = true }
        // The space's screen and the tab's chat pushed over it, as Spaces does: each push is a new thread view, laid out
        // before the navigation bar's inset arrives.
        let pushed = PushedThread()
        window.rootViewController = UIHostingController(rootView: PushedThreadRoot(pushed: pushed, chat: chat))
        for open in 0..<3 {
            pushed.open = true
            try await TestSupport.eventually { drawn(window)["Answer 39."] != nil }
            _ = try await settled(window)
            try await Task.sleep(for: .milliseconds(800))
            let scroll = try XCTUnwrap(scrollView(window))
            XCTAssertTrue(atEnd(scroll), "open \(open): offset \(scroll.contentOffset.y) + \(scroll.bounds.height) − \(scroll.adjustedContentInset.bottom) of \(scroll.contentSize.height)")
            pushed.open = false
            try await TestSupport.eventually { drawn(window).isEmpty }
            try await Task.sleep(for: .milliseconds(500))
        }
    }
}

@Observable @MainActor private final class PushedThread { var open = false }

private struct PushedThreadRoot: View {
    @Bindable var pushed: PushedThread
    let chat: MobileChatSession
    var body: some View {
        NavigationStack {
            Text("Space")
                .navigationDestination(isPresented: $pushed.open) {
                    ChatThreadView(session: chat, space: "app", directory: "/work/app").id("conversation")
                }
        }
    }
}

/// Leaving a conversation's tab and opening it again keeps the place (`MobileChatSession.readingPosition`).
extension ChatThreadWindowTests {
    /// Read back a screen and a half, then left for the space and opened again: the row read sits where it was, the
    /// thread does not follow its end, and the turn that came meanwhile counts into the jump pill.
    func testOpeningAgainKeepsThePlaceRead() async throws {
        let (chat, helper, window) = try await thread()
        defer { window.isHidden = true }
        let pushed = PushedThread()
        window.rootViewController = UIHostingController(rootView: PushedThreadRoot(pushed: pushed, chat: chat))
        pushed.open = true
        try await TestSupport.eventually { drawn(window)["Answer 39."] != nil }
        _ = try await settled(window)
        try await Task.sleep(for: .milliseconds(800))
        let scroll = try XCTUnwrap(scrollView(window))
        drag(scroll, to: scroll.contentOffset.y - scroll.bounds.height * 1.5)
        let before = try await settled(window)
        let read = try XCTUnwrap(before.filter { $0.value.minY > 140 && $0.value.maxY < window.bounds.height - 140 }
            .min { $0.value.minY < $1.value.minY }, "a row in view: \(before)")
        XCTAssertNotNil(chat.readingPosition, "the place is kept when the scroll stops")

        pushed.open = false
        try await TestSupport.eventually { drawn(window).isEmpty }
        // A turn comes while the tab is away.
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        helper.notify(id, "chat.records", ["terminal": 7, "session": ChatFixture.binding["session"] as Any,
                                           "records": Self.records(turns: 40..<41)])
        try await TestSupport.eventually { chat.transcript.rows.count == 82 }

        pushed.open = true
        try await TestSupport.eventually { drawn(window)[read.key] != nil }
        try await Task.sleep(for: .milliseconds(1200))
        let after = try await settled(window)
        let again = try XCTUnwrap(scrollView(window))
        XCTAssertEqual(after[read.key]?.minY ?? -1, read.value.minY, accuracy: 2, "\(read.key) where it was read")
        XCTAssertFalse(atEnd(again), "not at the end")
        XCTAssertGreaterThan(after["Answer 40."]?.minY ?? .infinity, window.bounds.height, "the new turn is below the screen")
        let labels = AccessibilityLabelTests.elements(in: window).compactMap(\.accessibilityLabel)
        XCTAssertTrue(labels.contains { $0.hasPrefix("Jump to latest") }, "the pill for the new turn: \(labels)")
    }

    /// Left at its end with a message queued under it: it opens at its end again, the queue in view, and the place
    /// read before is forgotten.
    func testOpeningAgainAtTheEndShowsTheEndAndTheQueue() async throws {
        let (chat, _, window) = try await thread(queue: [ChatFixture.queued("q1", "Also cover invoice.paid")])
        defer { window.isHidden = true }
        try await TestSupport.eventually { !chat.queueRows.isEmpty }
        let pushed = PushedThread()
        window.rootViewController = UIHostingController(rootView: PushedThreadRoot(pushed: pushed, chat: chat))
        pushed.open = true
        try await TestSupport.eventually { drawn(window)["Answer 39."] != nil }
        _ = try await settled(window)
        try await Task.sleep(for: .milliseconds(800))
        // Up, then back down to the end.
        let scroll = try XCTUnwrap(scrollView(window))
        let end = scroll.contentOffset.y
        drag(scroll, to: end - scroll.bounds.height)
        _ = try await settled(window)
        XCTAssertNotNil(chat.readingPosition)
        drag(scroll, to: end)
        _ = try await settled(window)
        try await TestSupport.eventually { chat.readingPosition == nil }

        pushed.open = false
        try await TestSupport.eventually { drawn(window).isEmpty }
        pushed.open = true
        try await TestSupport.eventually { drawn(window)["Answer 39."] != nil }
        _ = try await settled(window)
        try await Task.sleep(for: .milliseconds(800))
        let again = try XCTUnwrap(scrollView(window))
        XCTAssertTrue(atEnd(again), "offset \(again.contentOffset.y) of \(again.contentSize.height)")
        let labels = AccessibilityLabelTests.elements(in: window).compactMap(\.accessibilityLabel)
        XCTAssertTrue(labels.contains { $0.contains("Also cover invoice.paid") }, "the queue in view: \(labels)")
    }
}
