import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// Dynamic Type: the row grammar, bubbles, captions, chips, the thinking row, the banner and the key capsules grow with
/// the text size (accessibility sizes included) instead of clipping; the bars' pills and the capsules stop at a cap.
@MainActor
final class DynamicTypeTests: XCTestCase {
    static let sizes: [DynamicTypeSize] = [.large, .xxxLarge, .accessibility5]

    static func size(_ view: some View, _ type: DynamicTypeSize, width: CGFloat? = 402) -> CGSize {
        let host = UIHostingController(rootView: view.environment(\.dynamicTypeSize, type).frame(width: width))
        return host.sizeThatFits(in: CGSize(width: width ?? 1000, height: .greatestFiniteMagnitude))
    }

    private func heights(_ view: some View, width: CGFloat = 402) -> [CGFloat] {
        Self.sizes.map { Self.size(view, $0, width: width).height }
    }

    private func assertGrows(_ view: some View, width: CGFloat = 402, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let h = heights(view, width: width)
        XCTAssertGreaterThan(h[1], h[0], "\(what) grows at xxxLarge: \(h)", file: file, line: line)
        XCTAssertGreaterThan(h[2], h[1], "\(what) grows at the accessibility sizes: \(h)", file: file, line: line)
    }

    private static func row(lines: Int = 2) -> some View {
        MobileRow(dot: .unread, tint: .purple, name: "claude", detail: "app · mba2", time: "Yesterday",
                  subtitle: "Moving the check into a shared middleware so both routes get it.", lines: lines) {
            Image(systemName: "apple.logo")
        }
    }

    /// M2a, M3a: the row grows; at the accessibility sizes it stacks, taking at least the height of all its texts.
    func testRowsGrowAndStackWithoutOverlap() {
        assertGrows(Self.row(), "The row")
        let text = { (string: String, font: Font, lines: Int) in
            Self.size(Text(string).font(font).lineLimit(lines).fixedSize(horizontal: false, vertical: true), .accessibility5, width: 340).height
        }
        let parts = text("claude", .headline, 3) + text("app · mba2", .footnote, 2) + text("Yesterday", .subheadline, 1)
            + text("Moving the check into a shared middleware so both routes get it.", .subheadline, 4)
        XCTAssertGreaterThanOrEqual(Self.size(Self.row(), .accessibility5).height, parts, "Every text has its own room")
    }

    func testBubblesCaptionsAndChipsGrow() {
        assertGrows(ChatBubble(side: .agent) { Text("Stripe retries the same event with a new attempt counter.") }, "An agent bubble")
        assertGrows(ChatBubble(side: .user) { Text("Make billing webhook retries idempotent.") }, "Your bubble")
        assertGrows(ChatCaption(text: "5 steps · 1m 26s"), "A caption")
        assertGrows(ChatChip(title: "This session") {}, width: 200, "A chip")
        assertGrows(ChatLinkBanner(link: .reconnecting(attempt: 1, since: Date()), host: "mba2"), "M4c's banner")
    }

    /// Chips that no longer fit side by side wrap onto more lines on the user's side; none is wider than the column.
    func testChipsWrapInsteadOfSqueezing() {
        let choices = [ApprovalChoice(role: .allow, index: 0), ApprovalChoice(role: .session, index: 2),
                       ApprovalChoice(role: .deny, index: 1)]
        let chips = ChatChips(choices: choices) { _ in }
        let one = Self.size(ChatChip(title: "Allow") {}, .accessibility5).height
        let all = Self.size(chips, .accessibility5, width: 370)
        XCTAssertGreaterThan(all.height, one * 1.8, "On two lines or more")
        XCTAssertLessThanOrEqual(all.width, 370)
        XCTAssertEqual(Self.size(chips, .large, width: 370).height, Self.size(ChatChip(title: "Allow") {}, .large).height,
                       accuracy: 1, "One line at the default size (M4b)")
    }

    /// The bars keep their height: the header pills grow to xxxLarge and stop; the key capsules to accessibility1.
    func testBarItemsAndCapsulesStopAtTheirCap() {
        let pill = TabsBackPill(label: "Spaces") {}
        XCTAssertEqual(Self.size(pill, .xxxLarge, width: nil).height, Self.size(pill, .accessibility5, width: nil).height, accuracy: 0.5)
        XCTAssertEqual(Self.size(pill, .xxxLarge, width: nil).width, Self.size(pill, .accessibility5, width: nil).width, accuracy: 0.5)
        XCTAssertGreaterThan(Self.size(pill, .xxxLarge, width: nil).width, Self.size(pill, .large, width: nil).width)
        let keys = CodeKeyRow { _ in }
        XCTAssertGreaterThan(Self.size(keys, .accessibility1).height, Self.size(keys, .large).height)
        XCTAssertEqual(Self.size(keys, .accessibility1).height, Self.size(keys, .accessibility5).height, accuracy: 0.5)
        XCTAssertEqual(Self.size(keys, .large).height, CodeKeyRow.height, accuracy: 0.5, "M5e's 44 points by default")
    }

    func testTerminalCapsuleLabelsScale() {
        let controller = TerminalController(feed: ScriptedTerminalFeed(output: Data()), configuration: TerminalConfiguration())
        let capsule = TerminalKeyCapsule(controller: controller)
        XCTAssertEqual(Self.size(capsule, .large).height, TerminalKeyCapsule.height, accuracy: 0.5, "M6a's 52 points by default")
        XCTAssertGreaterThan(Self.size(capsule, .accessibility1).height, Self.size(capsule, .large).height)
        XCTAssertEqual(Self.size(capsule, .accessibility1).height, Self.size(capsule, .accessibility5).height, accuracy: 0.5)
    }

    /// M5a: the thinking row is 44 points by default and grows with its line.
    func testTheThinkingRowGrows() async throws {
        let helper = ScriptedHelper()
        helper.script { $0.method == "chat.open" ? .open : .result([Any]()) }
        let session = MobileChatSession.scripted(helper)
        try await TestSupport.eventually { helper.subscription("chat.open") != nil }
        helper.notify(helper.subscription("chat.open")!, "chat.history", ChatFixture.history(state: ChatFixture.state(busy: true)))
        try await TestSupport.eventually { session.working }
        let row = ChatWorkingRow(session: session, directory: nil, expanded: .constant(false), openStep: { _ in })
        let h = heights(row)
        XCTAssertEqual(h[0], 45, accuracy: 1)
        XCTAssertGreaterThanOrEqual(h[1], h[0], "Its 44 points hold the line up to xxxLarge")
        XCTAssertGreaterThan(h[2], h[1] + 20, "and grow with it at the accessibility sizes")
    }
}

/// VoiceOver: what the main rows, the thinking row and the queue say.
@MainActor
final class AccessibilityLabelTests: XCTestCase {
    /// A tab's back pill counts the conversations that need the user elsewhere; with none it names where Back goes,
    /// never a bare "0".
    func testATabsBackPillCountsWaitingConversationsOrNamesTheScreenBehind() {
        let none = TabsBackPill.needsYou(0, back: "app") {}
        XCTAssertEqual(none.label, "app")
        XCTAssertFalse(none.count)
        let two = TabsBackPill.needsYou(2, back: "app") {}
        XCTAssertEqual(two.label, "2")
        XCTAssertTrue(two.count)
    }

    func testRowsReadNameDetailTimeAndLineWithTheDotAsValue() {
        let row = MobileRow(dot: .unread, tint: .blue, name: "e2e", detail: "mba2", time: "9:31",
                            subtitle: "Run playwright test --headed? It opens a browser on the host.", lines: 2) { EmptyView() }
        XCTAssertEqual(row.accessibilityText, "e2e, mba2, 9:31, Run playwright test --headed? It opens a browser on the host.")
        XCTAssertEqual(MobileRowDot.unread.accessibilityLabel, "Unread")
        XCTAssertEqual(MobileRowDot.working.accessibilityLabel, "Working")
        let bare = MobileRow(dot: nil, tint: .blue, name: "zsh", detail: nil, time: nil, subtitle: "", disc: false) { EmptyView() }
        XCTAssertEqual(bare.accessibilityText, "zsh")
    }

    func testTreeLinesSayTheirCountAndWork() {
        XCTAssertEqual(SpacesSpaceLine.value(unread: 2, working: true), "2 unread, Working")
        XCTAssertEqual(SpacesSpaceLine.value(unread: 0, working: false), "")
    }

    /// The thinking row speaks in ten-second steps, so a focused VoiceOver user is not read a new number every second.
    func testTheThinkingRowSpeaksAtATenSecondCadence() {
        XCTAssertEqual(ChatWorkingAccessibility.label(agent: "claude", elapsed: 4), "claude is thinking, less than 10 seconds")
        XCTAssertEqual(ChatWorkingAccessibility.spoken(48), ChatWorkingAccessibility.spoken(41))
        XCTAssertEqual(ChatWorkingAccessibility.spoken(48), "40 seconds")
        XCTAssertEqual(ChatWorkingAccessibility.spoken(86), "1 minute, 20 seconds")
        XCTAssertEqual(ChatWorkingAccessibility.spoken(754), "12 minutes")
        let spoken = Set((0..<600).map { ChatWorkingAccessibility.spoken(TimeInterval($0)) })
        XCTAssertEqual(spoken.count, 60, "One phrase per ten seconds")
        XCTAssertEqual(ChatWorkingAccessibility.value(steps: 4, current: "Patch"), "4 steps, now Patch")
        XCTAssertEqual(ChatWorkingAccessibility.value(steps: 0, current: nil), "No steps yet")
    }

    func testTheBannerSaysWhereTheLinkIsOnce() {
        XCTAssertEqual(ChatLinkBanner.spoken(.reconnecting(attempt: 2, since: Date()), title: "Reconnecting to mba2"), "Reconnecting to mba2")
        XCTAssertEqual(ChatLinkBanner.spoken(.failed("refused"), title: "Can’t reach mba2"), "Can’t reach mba2, refused")
        XCTAssertEqual(ChatLinkBanner.spoken(.reconnecting(attempt: 2, since: Date()), title: "Reconnecting to mba2", problem: "This iPhone is offline."),
                       "Reconnecting to mba2, This iPhone is offline.")
    }

    /// The elements a hosted view exposes, depth first.
    static func elements(in root: NSObject) -> [NSObject] {
        var found: [NSObject] = []
        func walk(_ object: NSObject) {
            if object.isAccessibilityElement { found.append(object) }
            for child in (object.accessibilityElements as? [NSObject]) ?? [] { walk(child) }
            if let view = object as? UIView { for sub in view.subviews { walk(sub) } }
        }
        walk(root)
        return found
    }

    /// Turns on the app's accessibility runtime (as VoiceOver does) so SwiftUI builds its element tree in a unit test.
    static func enableAccessibility() {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "_AXSApplicationAccessibilitySetEnabled") else { return }
        unsafeBitCast(symbol, to: (@convention(c) (Bool) -> Void).self)(true)
    }

    /// M3a: an Agents row is one element whose swipe actions are VoiceOver actions (no duplicates).
    func testSwipeActionsAreCustomActions() async throws {
        Self.enableAccessibility()
        let found = await TestSupport.windowScene()
        let scene = try XCTUnwrap(found)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 400)
        let list = List {
            Button {} label: {
                MobileRow(dot: .working, tint: .blue, name: "app", detail: "mba2", time: "now", subtitle: "Moving the check.", lines: 2) {
                    Image(systemName: "apple.logo")
                }
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {} label: { Label("Close", systemImage: "xmark") }
                Button {} label: { Label("Mute", systemImage: "bell.slash") }
            }
        }
        .listStyle(.plain)
        window.rootViewController = UIHostingController(rootView: list)
        window.isHidden = false
        defer { window.isHidden = true }
        var row: NSObject?
        var labels: [String] = []
        try await TestSupport.eventually(diagnostic: "Elements: \(labels)") {
            let elements = Self.elements(in: window)
            labels = elements.map { $0.accessibilityLabel ?? "?" }
            row = elements.first { ($0.accessibilityLabel ?? "").hasPrefix("app, mba2, now") }
            return row != nil
        }
        XCTAssertEqual(row?.accessibilityValue, "Working")
        let actions = (row?.accessibilityCustomActions ?? []).map(\.name)
        XCTAssertEqual(actions.filter { $0 == "Mute" }.count, 1, "Mute once: \(actions)")
        XCTAssertEqual(actions.filter { $0 == "Close" }.count, 1, "Close once: \(actions)")
    }
}

/// Reduce Motion: every looping animation of the thread draws the same frame at any moment (static variants); without
/// it they move. The cluster and the composer's offer cross-fade (their transitions are `.opacity`).
@MainActor
final class ReduceMotionTests: XCTestCase {
    private func pixels(_ view: some View, reduceMotion: Bool, scheme: ColorScheme, at date: Date) -> Data? {
        let renderer = ImageRenderer(content: view.environment(\.reduceMotionOverride, reduceMotion)
            .environment(\.animationDateOverride, date)
            .environment(\.colorScheme, scheme).frame(width: 160, height: 24))
        renderer.scale = 2
        return renderer.cgImage?.dataProvider?.data as Data?
    }

    /// Twelve chosen instants 0.2 s apart (no clock, so no load can make two samples fall on the same frame): 2.2 s
    /// covers every loop's period but the shimmer's 2.4 s, whose gradient is flat for only about 0.95 s of it.
    private func frames(_ view: some View, reduceMotion: Bool, scheme: ColorScheme) -> Set<Data> {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return Set((0..<12).compactMap { step in
            pixels(view, reduceMotion: reduceMotion, scheme: scheme, at: start.addingTimeInterval(Double(step) * 0.2))
        })
    }

    func testLoopingAnimationsStandStillWithReduceMotion() throws {
        let views: [(String, AnyView)] = [
            ("the thinking glyph", AnyView(ChatThinkingGlyph())),
            ("the shimmer", AnyView(ChatShimmerText(text: "thinking"))),
            ("the accent scan", AnyView(ChatAccentScan().frame(height: 2))),
            ("the waiting dots", AnyView(ChatWaitingDots(color: .caution))),
        ]
        for (name, view) in views {
            for scheme in [ColorScheme.light, .dark] {
                let still = frames(view, reduceMotion: true, scheme: scheme)
                XCTAssertEqual(still.count, 1, "\(name) is static with Reduce Motion (\(scheme))")
                let moving = frames(view, reduceMotion: false, scheme: scheme)
                XCTAssertGreaterThan(moving.count, 1, "\(name) moves without Reduce Motion (\(scheme))")
                let instant = Date(timeIntervalSinceReferenceDate: 800_000_000.3)
                let same = Set((0..<3).compactMap { _ in pixels(view, reduceMotion: false, scheme: scheme, at: instant) })
                XCTAssertEqual(same.count, 1, "\(name) draws the instant it is given, not the clock (\(scheme))")
            }
        }
    }

    func testTheElapsedTimeStepsByFiveWithReduceMotion() {
        XCTAssertEqual(Set((10..<15).map { ChatElapsed.text(TimeInterval($0), reduceMotion: true) }).count, 1)
    }
}
