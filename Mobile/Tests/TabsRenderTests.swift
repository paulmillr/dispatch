import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// What the Spaces screens draw: the M2a capsule takes the app tint only while a filter is active and shows the lens
/// on the tree segment while the tree is on; the rows keep the mockup's size. Renders in a window of the test host's
/// scene (glass samples what is behind it). `DISPATCH_TABS_PNG` (`TEST_RUNNER_DISPATCH_TABS_PNG` through xcodebuild)
/// names a folder to write the renders to.
@MainActor
final class TabsRenderTests: XCTestCase {
    private func render(_ view: some View, size: CGSize) throws -> UIImage {
        let scene = try XCTUnwrap(TestSupport.windowScene())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        let host = UIHostingController(rootView: view.ignoresSafeArea().environment(\.colorScheme, .dark))
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// The segment a tab opened on stays: an agent starting in its shell (the topology binding it) does not switch a
    /// Terminal the user is typing in to Chat.
    func testTheSegmentShownStaysWhenTheTabStartsAnAgent() throws {
        let defaults = UserDefaults(suiteName: "tabs-render-\(#function)")!
        defaults.removePersistentDomain(forName: "tabs-render-\(#function)")
        let model = MobileTabs(activity: TabActivityStore(url: nil), defaults: defaults)
        var sketch = TabsFixtures.app()
        model.sync([TabsHostInput(host: TabsFixtures.host, client: nil, topology: sketch.topology)])
        let ref = try XCTUnwrap(model.workspace(TabsFixtures.host.id)?.tabs.first { $0.panes.contains { $0.key == "p:docs" } }?.ref)
        final class Shown { var segments: [String] = [] }
        let shown = Shown()
        let screen = TabScreen(model: model, ref: ref, path: .constant([]),
                               terminal: { _, _ in shown.segments.append("terminal"); return Text("terminal") },
                               chat: { _, _ in shown.segments.append("chat"); return Text("chat") })
        let scene = try XCTUnwrap(TestSupport.windowScene())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 600)
        window.rootViewController = UIHostingController(rootView: NavigationStack { screen })
        window.isHidden = false
        defer { window.isHidden = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(shown.segments.last, "terminal")
        sketch.spaces[1].tabs[0].panes[0].agent = "s5"
        model.sync([TabsHostInput(host: TabsFixtures.host, client: nil, topology: sketch.topology)])
        XCTAssertTrue(try XCTUnwrap(model.tab(ref)).isChat)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(shown.segments.last, "terminal", "The screen switched to Chat by itself")
        XCTAssertFalse(shown.segments.contains("chat"))
    }

    /// A Claude tab's title is its first prompt. Beside a back pill naming its screen (nothing needs the user) it
    /// overflowed the bar, which then showed only its "…" menu with the back pill inside.
    func testALongTitleBesideANamedBackPillStaysInTheBar() throws {
        let prompt = "See how we can speed-up sha3 without writing new code yet."
        for (space, waiting) in [("ciphers", 0), ("ciphers", 2), ("sha3-keccak-speedups-without-new-code", 0)] {
            let (model, tab, spaceRef) = headerModel(space: space, tab: prompt)
            model.needsYouCount = { _ in waiting }
            let screen = TabScreen(model: model, ref: tab, path: .constant([.space(spaceRef), .tab(tab)]),
                                   terminal: { _, _ in Text("terminal") }, chat: { _, _ in Text("chat") })
            try assertInTheBar(screen, "\(space), \(waiting) waiting")
        }
    }

    /// Beside the split's sidebar the Terminal / Chat switch takes the host pill's place in the header (one row):
    /// a long title still truncates beside it, in either posture's detail column.
    func testALongTitleBesideTheSplitSwitchStaysInTheBar() throws {
        let (model, tab, space) = headerModel(space: "ciphers", tab: "See how we can speed-up sha3 without writing new code yet.")
        for column in [CGFloat(405.5), 433.25, 475.25] {
            let screen = TabScreen(model: model, ref: tab, path: .constant([.space(space), .tab(tab)]),
                                   terminal: { _, _ in Text("terminal") }, chat: { _, _ in Text("chat") })
                .environment(\.tabsSplitDetail, true)
                .environment(\.tabsColumnWidth, column)
            try assertInTheBar(screen, "column \(column)", width: column)
        }
    }

    /// M2c and M4d with a long space name: the title beside "‹ Spaces", the back pill naming the space beside Rename.
    func testALongSpaceNameStaysInTheBar() throws {
        let helper = ScriptedHelper()
        let (model, _, space) = headerModel(space: "sha3-keccak-speedups-without-writing-new-code", tab: "claude",
                                            client: helper.client)
        let actions = TabsActions(model: model)
        try assertInTheBar(SpaceTabsScreen(model: model, actions: actions, ref: space, path: .constant([.space(space)]),
                                           newTab: { _ in }, pick: {}), "space")
        try assertInTheBar(SpaceDetailsScreen(model: model, actions: actions, ref: space,
                                              path: .constant([.space(space), .details(space)])), "details")
    }

    private func headerModel(space: String, tab: String, client: HelperClient? = nil) -> (MobileTabs, TabRef, SpaceRef) {
        let suite = "tabs-render-header"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = MobileTabs(activity: TabActivityStore(url: nil), defaults: defaults)
        let sketch = TopologySketch(spaces: [.init(key: "herdr:ciphers", name: space, tabs: [
            .init(key: "herdr:ciphers:1", name: tab, renamed: true,
                  panes: [.init(key: "p:ciphers", cwd: "/Users/alex/src/ciphers", agent: "s1")]),
        ])])
        model.sync([TabsHostInput(host: TabsFixtures.host, client: client, topology: sketch.topology)])
        let ref = model.workspace(TabsFixtures.host.id)!.tabs[0].ref
        return (model, ref, SpaceRef(host: TabsFixtures.host.id, key: "herdr:ciphers"))
    }

    /// The bar at the device's width keeps every item: no "More" button (the overflow menu's "…").
    private func assertInTheBar(_ screen: some View, _ name: String, width: CGFloat? = nil,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let scene = try XCTUnwrap(TestSupport.windowScene())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width ?? scene.screen.bounds.width, height: 700)
        window.rootViewController = UIHostingController(rootView: NavigationStack { screen })
        window.isHidden = false
        defer { window.isHidden = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        let bar = try XCTUnwrap(views(window).first { $0 is UINavigationBar }, name, file: file, line: line)
        let more = views(bar).filter { $0.accessibilityLabel == "More" && !$0.isHidden && $0.alpha > 0 }
        XCTAssertTrue(more.isEmpty, "\(name): the bar overflowed into its menu", file: file, line: line)
    }

    private func write(_ image: UIImage, _ name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["DISPATCH_TABS_PNG"], let data = image.pngData() else { return }
        try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }

    /// The mean colour of a small square, 0...255 per channel.
    private func color(_ image: UIImage, around point: CGPoint) -> (red: Int, green: Int, blue: Int) {
        let cg = image.cgImage!
        let scale = image.scale, side = 4
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: -(point.x * scale - CGFloat(side) / 2), y: -(CGFloat(cg.height) - point.y * scale - CGFloat(side) / 2))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        var sum = (0, 0, 0)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            sum.0 += Int(pixels[index]); sum.1 += Int(pixels[index + 1]); sum.2 += Int(pixels[index + 2])
        }
        let count = side * side
        return (sum.0 / count, sum.1 / count, sum.2 / count)
    }

    private func capsule(_ query: TabsQuery, tree: Bool = false) -> some View {
        TabsCapsule(tree: .constant(tree), query: .constant(query))
            .frame(width: 140, height: 80)
            .background(.black)
    }

    private let size = CGSize(width: 140, height: 80)

    /// M2a: neutral glass with no filter or with a sort only; the app tint with a filter.
    func testCapsuleTintsOnlyWhileFiltering() throws {
        let plain = try render(capsule(TabsQuery()), size: size)
        let sorted = try render(capsule(TabsQuery(sort: .name)), size: size)
        let filtered = try render(capsule(TabsQuery(filter: .chats)), size: size)
        try write(plain, "capsule-plain")
        try write(filtered, "capsule-filtered")
        // Inside the capsule, clear of both glyphs: just right of the hairline, near the bottom edge.
        let probe = CGPoint(x: 70, y: 54)
        for image in [plain, sorted] {
            let c = color(image, around: probe)
            XCTAssertLessThan(abs(c.red - c.blue), 24, "neutral: \(c)")
            XCTAssertLessThan(abs(c.red - c.green), 24, "neutral: \(c)")
        }
        let pink = color(filtered, around: probe)
        XCTAssertGreaterThan(pink.red, pink.green + 40, "app tint: \(pink)")
        XCTAssertGreaterThan(pink.blue, pink.green + 30, "app tint: \(pink)")
    }

    /// The tree segment is the lens while the tree is on: at least 10 levels lighter than the glass around it. An
    /// iPad's glass draws it exactly 12 over (43 on 31 on iOS 27.0), where the test once asked for more than 12.
    func testTreeSegmentShowsTheLens() throws {
        // The threshold is the iPhone's glass: an iPad renders the lens 12 levels over the capsule, at the threshold.
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("Measured on the iPhone's rendering") }
        let probe = CGPoint(x: 32, y: 52)
        let off = color(try render(capsule(TabsQuery()), size: size), around: probe)
        let image = try render(capsule(TabsQuery(), tree: true), size: size)
        try write(image, "capsule-tree")
        let on = color(image, around: probe)
        XCTAssertGreaterThanOrEqual(on.green, off.green + 10, "lens \(on) over \(off)")
    }

    /// M2a rows: the 46 point disc and two lines, about 66 points each; M2c rows drop the disc but keep the height.
    func testRowsHaveTheMockupHeight() throws {
        let model = TabsSample.model()
        let rows = Array(model.rows.prefix(6))
        XCTAssertEqual(rows.count, 6)
        func height(_ rows: [TabsEntry], detail: Bool) -> CGFloat {
            let list = VStack(spacing: 0) {
                ForEach(rows) { TabsTabRow(model: model, entry: $0, detail: detail, now: Date()) }
            }
            .frame(width: 402)
            return UIHostingController(rootView: list).sizeThatFits(in: CGSize(width: 402, height: CGFloat.greatestFiniteMagnitude)).height / CGFloat(rows.count)
        }
        XCTAssertGreaterThan(height(rows, detail: true), 58)
        XCTAssertLessThan(height(rows, detail: true), 78)
        // Rows with a second line, as in the mockup, match with and without the disc; a bare shell's row is one line
        // (no folder: `TabsTabRow.line`).
        let lined = rows.filter { TabsTabRow.line($0.tab, label: $0.label, status: model.status) != nil }
        let bare = rows.filter { TabsTabRow.line($0.tab, label: $0.label, status: model.status) == nil }
        XCTAssertFalse(lined.isEmpty)
        XCTAssertFalse(bare.isEmpty)
        XCTAssertEqual(height(lined, detail: false), height(lined, detail: true), accuracy: 2)
        // Beside the disc a one-line row is as tall as the others, so its separator runs under the disc, not across it.
        XCTAssertEqual(height(bare, detail: true), height(lined, detail: true), accuracy: 1)
        let list = VStack(spacing: 0) { ForEach(rows) { TabsTabRow(model: model, entry: $0, detail: true, now: Date()) } }
        try write(try render(list.frame(width: 402).background(.black), size: CGSize(width: 402, height: 420)), "rows")
    }
}
