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

    /// P2 with a long space name and its branch: the title truncates beside "‹ Spaces", and the space's ⋯ stays in the
    /// bar as the 44 point circle the title's room assumes, at every iPhone's width (the stack's column is its window's).
    /// The bar's margins follow the window, not the device (16 up to 402 points, 20 from 420), so every simulator checks
    /// every width. A ⋯ the bar drew as its own 56 by 36 point menu button left the title 12 points too many: at 375
    /// and on the iPhone Air's 420 the bar folded the ⋯ into its "…".
    func testALongSpaceNameStaysInTheBar() async throws {
        AccessibilityLabelTests.enableAccessibility()
        let helper = ScriptedHelper()
        let (model, _, space) = headerModel(space: "sha3-keccak-speedups-without-writing-new-code", tab: "claude",
                                            client: helper.client)
        let facts = SpaceGitFacts()
        facts.seed(SpaceGitFacts.Key(host: space.host, key: space.key),
                   SpaceGitFacts.Facts(directory: "/Users/alex/src/ciphers", root: "/Users/alex/src/ciphers",
                                       branch: "feature/a-very-long-branch-name-for-the-chip"))
        let plain = SpacesNavigator(model: model)
        let navigator = SpacesNavigator(model: model)
        navigator.gitFacts = facts
        // The iPhone SE and mini, 16e and 17e, 17 and 17 Pro, Air, Pro Max.
        for width in [CGFloat(375), 390, 402, 420, 440] {
            for (name, navigator) in [("space without branch", plain), ("space", navigator)] {
                let screen = SpaceTabsScreen(navigator: navigator, ref: space, path: .constant([.space(space)]))
                    .environment(\.tabsColumnWidth, width)
                let (window, bar) = try assertInTheBar(screen, "\(name), \(width)", width: width, keep: true)
                defer { window.isHidden = true }
                let edges = bar.convert(bar.bounds, to: window)
                var frames: [String: CGRect] = [:]
                try await TestSupport.eventually(timeout: .seconds(3), diagnostic: "\(name), \(width): \(frames)") {
                    frames = [:]
                    for element in AccessibilityLabelTests.elements(in: window) {
                        guard let label = element.accessibilityLabel, ["Back to Spaces", "Space menu"].contains(label) else { continue }
                        frames[label] = window.convert(element.accessibilityFrame, from: window.screen.coordinateSpace)
                    }
                    return frames.count == 2
                }
                let back = try XCTUnwrap(frames["Back to Spaces"]), menu = try XCTUnwrap(frames["Space menu"])
                XCTAssertEqual(menu.width, 44, accuracy: 0.5, "\(name), \(width): the ⋯ is the mockup's circle, \(menu)")
                XCTAssertGreaterThanOrEqual(back.minX, edges.minX, "\(name), \(width): \(back)")
                XCTAssertLessThanOrEqual(menu.maxX, edges.maxX, "\(name), \(width): \(menu)")
                XCTAssertLessThan(back.maxX, menu.minX, "\(name), \(width)")
            }
        }
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

    /// The bar at the device's width (or `width`) keeps every item: no "More" button (the overflow menu's "…").
    /// `keep` leaves its window showing and returns it with the bar, for the caller to probe and hide.
    @discardableResult
    private func assertInTheBar(_ screen: some View, _ name: String, width: CGFloat? = nil, keep: Bool = false,
                                file: StaticString = #filePath, line: UInt = #line) throws -> (UIWindow, UINavigationBar) {
        let scene = try XCTUnwrap(TestSupport.windowScene())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width ?? scene.screen.bounds.width, height: 700)
        window.rootViewController = UIHostingController(rootView: NavigationStack { screen })
        window.isHidden = false
        defer { if !keep { window.isHidden = true } }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        let found = views(window).first { $0 is UINavigationBar } as? UINavigationBar
        let bar = try XCTUnwrap(found, name, file: file, line: line)
        let more = views(bar).filter { $0.accessibilityLabel == "More" && !$0.isHidden && $0.alpha > 0 }
        XCTAssertTrue(more.isEmpty, "\(name): the bar overflowed into its menu", file: file, line: line)
        return (window, bar)
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

    /// P1: the chosen chip is on the app tint, the others are not. Each chip is found by its accessibility frame and
    /// probed inside its leading padding (before its glyph), so the check holds on any device and glass.
    func testTheChosenFilterChipIsTinted() async throws {
        AccessibilityLabelTests.enableAccessibility()
        let found = await TestSupport.windowScene()
        let scene = try XCTUnwrap(found)
        func shot(_ filter: TabsQuery.Filter) async throws -> (UIImage, [String: CGRect]) {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 80)
            window.overrideUserInterfaceStyle = .dark
            let host = UIHostingController(rootView: SpacesFilterRow(filter: .constant(filter), needsYou: 2)
                .padding(.horizontal, 16).frame(width: 402, height: 80).background(.black).environment(\.colorScheme, .dark))
            host.view.backgroundColor = .black
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            var frames: [String: CGRect] = [:]
            try await TestSupport.eventually(timeout: .seconds(3)) {
                frames = [:]
                for element in AccessibilityLabelTests.elements(in: window) {
                    guard let label = element.accessibilityLabel, ["All", "Needs you", "Agents"].contains(label) else { continue }
                    frames[label] = window.convert(element.accessibilityFrame, from: window.screen.coordinateSpace)
                }
                return frames.count == 3
            }
            try await Task.sleep(for: .milliseconds(300))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            return (image, frames)
        }
        func isAccent(_ c: (red: Int, green: Int, blue: Int)) -> Bool { c.red > c.green + 40 && c.blue > c.green + 30 }
        for chosen in TabsQuery.Filter.allCases {
            let (image, frames) = try await shot(chosen)
            try write(image, "filter-\(chosen.rawValue)")
            for filter in TabsQuery.Filter.allCases {
                let frame = try XCTUnwrap(frames[filter.title])
                let probe = color(image, around: CGPoint(x: frame.minX + 5, y: frame.midY))
                if filter == chosen {
                    XCTAssertTrue(isAccent(probe), "\(filter.title) chosen: the app tint, \(probe)")
                } else {
                    XCTAssertFalse(isAccent(probe), "\(filter.title) beside \(chosen.title): not the tint, \(probe)")
                }
            }
        }
    }

    /// P2's rows: the mark and two lines, about 63 points each as drawn; every tab of the mockup's space has a line
    /// (an agent's state, a terminal's title or its folder).
    func testSpaceRowsHaveTheMockupHeight() throws {
        let model = TabsSample.spacesMockup(variant: "P1")
        let space = try XCTUnwrap(model.space(SpaceRef(host: TabsSample.mba2.id, key: "herdr:app")))
        let rows = model.rows(in: space)
        XCTAssertEqual(rows.map(\.label), ["Sidebar theme toggle", "pnpm dev", "zsh", "Rate limiter for the API", "Docs site migration"])
        XCTAssertEqual(rows.map { SpaceTabRow.line($0, model: model)?.text },
                       ["Editing Sidebar.tsx", "vite ready · localhost:5173", "~/src/app", "Allow cargo test --workspace?",
                        "Moved the docs to Starlight; the old MkDocs config is gone."])
        XCTAssertEqual(rows.map { model.agent(of: $0.tab) }, ["claude", nil, nil, "codex", "claude"])
        for entry in rows {
            let row = SpaceTabRow(entry: entry, line: SpaceTabRow.line(entry, model: model), agent: model.agent(of: entry.tab))
                .frame(width: 370)
            let height = UIHostingController(rootView: row).sizeThatFits(in: CGSize(width: 370, height: 400)).height
            XCTAssertGreaterThan(height, 56, entry.label)
            XCTAssertLessThan(height, 72, entry.label)
        }
        let list = VStack(spacing: 0) {
            ForEach(rows) { SpaceTabRow(entry: $0, line: SpaceTabRow.line($0, model: model), agent: model.agent(of: $0.tab)) }
        }
        try write(try render(list.frame(width: 370).background(.black), size: CGSize(width: 370, height: 360)), "space-rows")
    }
}

/// A plain shell's tab once its shell ended (docs/ios.md, Plain SSH).
extension TabsRenderTests {
    /// The ended card replaces the key capsule under the last screen: "Session ended", how it ended, New shell and
    /// Close; it shows as soon as the connection is known gone (`ended`), before the presence says so. A helper
    /// terminal that ended shows no card.
    func testAnEndedShellShowsItsCard() async throws {
        AccessibilityLabelTests.enableAccessibility()
        final class Taps { var newShell = 0, close = 0 }
        let taps = Taps()
        let card = TerminalEndedCard(newShell: { taps.newShell += 1 }, close: { taps.close += 1 })
        let exited = TerminalPresence(feed: ScriptedTerminalFeed([.output(Data("$ exit\r\n".utf8)), .attached, .exit(3)]))
        exited.start()
        try await TestSupport.eventually { exited.ended == .exited(3) }
        let running = TerminalPresence(feed: ScriptedTerminalFeed([.output(Data("$ ".utf8)), .attached]))
        running.start()

        let found = await TestSupport.windowScene()
        let scene = try XCTUnwrap(found)
        func shown(_ view: TerminalSegmentView) async throws -> [NSObject] {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
            window.rootViewController = UIHostingController(rootView: view)
            window.isHidden = false
            defer { window.isHidden = true }
            var elements: [NSObject] = []
            try await TestSupport.eventually(timeout: .seconds(2)) {
                elements = AccessibilityLabelTests.elements(in: window)
                return elements.contains { $0.accessibilityLabel == "Control" || $0.accessibilityLabel == "New shell" }
            }
            return elements
        }

        let ended = try await shown(TerminalSegmentView(presence: exited, ended: card))
        let labels = ended.compactMap(\.accessibilityLabel)
        XCTAssertTrue(labels.contains { $0.contains("Session ended") && $0.contains("Exited with status 3") }, "\(labels)")
        let newShell = try XCTUnwrap(ended.first { $0.accessibilityLabel == "New shell" })
        XCTAssertNotNil(ended.first { $0.accessibilityLabel == "Close" })
        XCTAssertNil(ended.first { $0.accessibilityLabel == "Control" }, "no keys for a shell that ended")
        _ = newShell.accessibilityActivate()
        try await TestSupport.eventually { taps.newShell == 1 }

        var dropped = card
        dropped.ended = true
        let gone = try await shown(TerminalSegmentView(presence: running, ended: dropped))
        XCTAssertNotNil(gone.first { $0.accessibilityLabel == "New shell" }, "the connection went: the card shows")

        let helper = try await shown(TerminalSegmentView(presence: exited))
        XCTAssertNil(helper.first { $0.accessibilityLabel == "New shell" }, "a helper terminal shows no card")
        XCTAssertNotNil(helper.first { $0.accessibilityLabel == "Control" })
        XCTAssertEqual(taps.close, 0)
    }
}
