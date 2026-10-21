import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// The split (`MobileSplit`) on the unfolded iPhone Duo and an iPad: Spaces in a sidebar column, the tab they open beside
/// it. Both columns show the navigator's one path, so folding the phone (or narrowing the iPad's window) shows the same
/// screens as a stack. Renders go to
/// `DISPATCH_TABS_PNG` (`TEST_RUNNER_DISPATCH_TABS_PNG` through xcodebuild) when it names a folder.
@MainActor
final class MobileSplitTests: XCTestCase {
    private let host = UUID(uuidString: "00000000-0000-0000-0000-00000000D001")!
    private func tab(_ key: String) -> TabRef { TabRef(host: host, key: key) }
    private func space(_ key: String) -> SpaceRef { SpaceRef(host: host, key: key) }

    private func navigator() -> SpacesNavigator {
        let suite = "mobile-split-\(UUID().uuidString)"
        return SpacesNavigator(model: MobileTabs(activity: TabActivityStore(url: nil), defaults: UserDefaults(suiteName: suite)!))
    }

    /// The sizes that split: the unfolded Duo either way up; not its cover screen, an iPhone in landscape or upright.
    func testOnlyAWindowWideAndTallEnoughSplits() {
        XCTAssertTrue(MobileSplit.applies(to: CGSize(width: 669, height: 951)))
        XCTAssertTrue(MobileSplit.applies(to: CGSize(width: 951, height: 669)))
        XCTAssertFalse(MobileSplit.applies(to: CGSize(width: 466, height: 678)), "The Duo's cover screen")
        XCTAssertFalse(MobileSplit.applies(to: CGSize(width: 956, height: 440)), "A Pro Max in landscape")
        XCTAssertFalse(MobileSplit.applies(to: CGSize(width: 420, height: 912)))
        XCTAssertEqual(MobileSplit.sidebarWidth(for: CGSize(width: 669, height: 951)), 263, "Laptop: the tab keeps a phone's width")
        XCTAssertTrue(MobileSplit.narrow(sidebar: 263))
        XCTAssertFalse(MobileSplit.narrow(sidebar: 475), "Book: rows and tab bar as on the phone")
        XCTAssertEqual(MobileSplit.sidebarWidth(for: CGSize(width: 820, height: 1000)), 414, "Laptop, wider: the tab keeps a phone's width")
        XCTAssertEqual(MobileSplit.columns(width: 951, height: 669), .init(sidebar: 475.25, gap: 0.5, tab: 475.25),
                       "Book without a reported fold: halves")
        XCTAssertEqual(MobileSplit.columns(width: 951, height: 669, fold: 517.5), .init(sidebar: 517.25, gap: 0.5, tab: 433.25),
                       "Book: the hairline on the Duo's fold, off centre")
        XCTAssertEqual(MobileSplit.columns(width: 951, height: 669, fold: 100).sidebar, 475.25, "A fold too near an edge: halves")
        XCTAssertEqual(MobileSplit.columns(width: 669, height: 951, fold: 334.5).sidebar, 263, "Laptop: the fold runs across")
    }

    /// The sidebar shows the path up to the last tab without tabs; the detail column that tab and what it pushed.
    func testThePathSplitsAtItsLastTab() {
        typealias Split = SpacesNavigator.SplitPath
        XCTAssertEqual(SpacesNavigator.split([]), Split(sidebar: [], tab: nil, detail: []))
        XCTAssertEqual(SpacesNavigator.split([.space(space("s"))]), Split(sidebar: [.space(space("s"))], tab: nil, detail: []))
        XCTAssertEqual(SpacesNavigator.split([.space(space("s")), .tab(tab("a")), .details(space("s"))]),
                       Split(sidebar: [.space(space("s"))], tab: tab("a"), detail: [.details(space("s"))]))
        XCTAssertEqual(SpacesNavigator.split([.tab(tab("a")), .space(space("s")), .tab(tab("b"))]),
                       Split(sidebar: [.space(space("s"))], tab: tab("b"), detail: []), "An earlier tab is not the sidebar's")
    }

    /// A row the sidebar pushes takes the detail column; the sidebar's own pushes and Back leave the tab shown.
    func testTheSidebarOpensTabsBesideItself() {
        let navigator = navigator()
        navigator.setSidebar([.space(space("s"))])
        XCTAssertEqual(navigator.path, [.space(space("s"))])
        navigator.setSidebar([.space(space("s")), .tab(tab("a"))])
        XCTAssertEqual(navigator.splitPath.sidebar, [.space(space("s"))], "The space stays in the sidebar")
        XCTAssertEqual(navigator.splitPath.tab, tab("a"))
        navigator.setDetail([.details(space("s"))])
        navigator.setSidebar([])
        XCTAssertEqual(navigator.path, [.tab(tab("a")), .details(space("s"))], "Back in the sidebar keeps the detail column")
        navigator.setSidebar([.tab(tab("b"))])
        XCTAssertEqual(navigator.path, [.tab(tab("b"))], "Another tab replaces the shown one and what it pushed")
    }

    /// The detail column's stack: space details over the tab and Back; a tab details open takes the column.
    func testTheDetailColumnPushesOverItsTab() {
        let navigator = navigator()
        navigator.path = [.space(space("s")), .tab(tab("a"))]
        navigator.setDetail([.details(space("s"))])
        XCTAssertEqual(navigator.path, [.space(space("s")), .tab(tab("a")), .details(space("s"))])
        navigator.setDetail([])
        XCTAssertEqual(navigator.path, [.space(space("s")), .tab(tab("a"))])
        navigator.setDetail([.details(space("s")), .tab(tab("b"))])
        XCTAssertEqual(navigator.path, [.space(space("s")), .tab(tab("b"))])
    }

    /// New tab, Create and Agents open into the detail column in place of its tab; folded, they push as before.
    func testOpeningATabReplacesTheShownOneOnlyInTheSplit() {
        let navigator = navigator()
        navigator.path = [.space(space("s")), .tab(tab("a")), .details(space("s"))]
        navigator.split = true
        navigator.openChat(tab("b"))
        XCTAssertEqual(navigator.path, [.space(space("s")), .tab(tab("b"))])
        navigator.select(tab("d"))
        XCTAssertEqual(navigator.path, [.space(space("s")), .tab(tab("d"))], "A sidebar row: in place, no push")
        navigator.split = false
        navigator.openChat(tab("c"))
        XCTAssertEqual(navigator.path, [.space(space("s")), .tab(tab("d")), .tab(tab("c"))])
    }

    /// The app at the unfolded Duo's size shows two bars side by side, the sidebar's and the tab's; at an iPhone's, one.
    func testTheUnfoldedDuoShowsTheSidebarBesideTheTab() throws {
        let app = composition()
        let ref = try XCTUnwrap(app.tabs.workspaces.flatMap(\.tabs).first { $0.isChat }?.ref)
        app.navigator.path = [.tab(ref)]
        let unfolded = try bars(app, size: CGSize(width: 669, height: 951), png: "duo-unfolded")
        XCTAssertEqual(unfolded.count, 2, "\(unfolded)")
        let sidebar = MobileSplit.sidebarWidth(for: CGSize(width: 669, height: 951))
        XCTAssertEqual(unfolded.first?.minX ?? -1, 0, accuracy: 1)
        XCTAssertEqual(unfolded.first?.width ?? 0, sidebar, accuracy: 1, "The sidebar's bar")
        XCTAssertEqual(unfolded.last?.minX ?? 0, sidebar + 0.5, accuracy: 1, "The tab's bar beside it")
        XCTAssertTrue(app.navigator.split)

        let folded = try bars(app, size: CGSize(width: 420, height: 912), png: "duo-folded")
        XCTAssertEqual(folded.count, 1, "\(folded)")
        XCTAssertFalse(app.navigator.split)
        XCTAssertEqual(app.navigator.path, [.tab(ref)], "Folding keeps the tab on top")
    }

    /// An iPad splits by width alone once both columns fit at their narrowest (280 + 0.5 + 375): every full-screen iPad
    /// either way up, the top halves and a 13-inch's half on its side; the other halves, thirds and Slide Over stack.
    /// The sizes are iPadOS 27's own windows (Window Controls, Move & Resize), measured on the simulators.
    func testAnIPadSplitsWhenBothColumnsFit() {
        let splits: [(CGFloat, CGFloat, String)] = [
            (744, 1133, "mini upright"), (1133, 744, "mini on its side"), (820, 1180, "Air 11-inch upright"),
            (834, 1210, "11-inch upright"), (1210, 834, "11-inch on its side"), (1032, 1376, "13-inch upright"),
            (1376, 1032, "13-inch on its side"), (744, 561.5, "mini upright, top half"), (1133, 486, "mini, top half"),
            (834, 600, "11-inch upright, top half"), (1210, 486, "11-inch, top half"), (1376, 511, "13-inch, top half"),
            (683, 909, "13-inch on its side, left half"), (655.5, 400, "the narrowest split")]
        for (width, height, name) in splits {
            XCTAssertTrue(MobileSplit.applies(to: CGSize(width: width, height: height), device: .pad), name)
        }
        let stacks: [(CGFloat, CGFloat, String)] = [
            (375, 1010, "mini upright, left half"), (561.5, 621, "mini on its side, left half"),
            (412, 1087, "11-inch upright, left half"), (600, 711, "11-inch on its side, left half"),
            (375, 1031, "Slide Over"), (375, 655, "Slide Over on its side"), (458, 1032, "a 13-inch's third"),
            (655, 1000, "just under")]
        for (width, height, name) in stacks {
            XCTAssertFalse(MobileSplit.applies(to: CGSize(width: width, height: height), device: .pad), name)
        }
        XCTAssertEqual(MobileSplit.padMinimumWidth, 655.5)
        XCTAssertTrue(MobileSplit.applies(to: CGSize(width: 669, height: 951)), "The Duo keeps its rule")
        XCTAssertFalse(MobileSplit.applies(to: CGSize(width: 1210, height: 486)), "A phone that short stacks, as an iPhone on its side")
    }

    /// The iPad's sidebar is the system's (`UISplitViewController`'s double-column primary: 320, the window less 448
    /// between 728 and 768), never the rest of the window; narrower windows keep it at 280 down to the split's edge,
    /// where the tab has a phone's 375. No posture and no fold.
    func testTheIPadSidebarIsTheSystemsWidth() {
        func columns(_ width: CGFloat, _ height: CGFloat, fold: CGFloat? = nil) -> MobileSplit.Columns {
            MobileSplit.columns(width: width, height: height, fold: fold, device: .pad)
        }
        XCTAssertEqual(columns(1376, 1032), .init(sidebar: 320, gap: 0.5, tab: 1055.5), "13-inch on its side: not 970")
        XCTAssertEqual(columns(1032, 1376).sidebar, 320, "13-inch upright")
        XCTAssertEqual(columns(1210, 834).sidebar, 320)
        XCTAssertEqual(columns(834, 1210), .init(sidebar: 320, gap: 0.5, tab: 513.5), "11-inch upright: the tab gets the rest")
        XCTAssertEqual(columns(820, 1180).sidebar, 320, "Unlike the Duo's laptop posture, which gives this width a 414 sidebar")
        XCTAssertEqual(MobileSplit.sidebarWidth(for: CGSize(width: 820, height: 1000)), 414)
        XCTAssertEqual(columns(744, 1133).sidebar, 296, "mini upright, as the system's")
        XCTAssertEqual(columns(768, 1000).sidebar, 320)
        XCTAssertEqual(columns(748.5, 1000).sidebar, 300)
        XCTAssertEqual(columns(728, 1000).sidebar, 280, "The system's narrowest tiled sidebar")
        XCTAssertEqual(columns(683, 909), .init(sidebar: 280, gap: 0.5, tab: 402.5), "13-inch's half: a phone's tab")
        XCTAssertEqual(columns(655.5, 909), .init(sidebar: 280, gap: 0.5, tab: 375))
        XCTAssertEqual(columns(951, 669, fold: 517.5).sidebar, 320, "No fold on an iPad")
        XCTAssertFalse(MobileSplit.narrow(sidebar: columns(683, 909).sidebar, device: .pad), "Labels and tab names at 280")
        XCTAssertFalse(MobileSplit.narrow(sidebar: columns(744, 1133).sidebar, device: .pad), "A mini upright keeps its tabs' names")
        XCTAssertTrue(MobileSplit.narrow(sidebar: 280), "The Duo's narrow rule stays")
    }

    /// Wherever the system tiles its sidebar (728 points and wider), the split's iPad sidebar is exactly what
    /// `UISplitViewController` gives its double-column primary in a window that size. iPad only: the system's split
    /// view decides by idiom too.
    func testTheIPadSidebarMatchesUISplitViewController() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("UISplitViewController lays out by idiom") }
        let scene = try XCTUnwrap(TestSupport.windowScene())
        for width in [728, 744, 760, 768, 834, 1032, 1210, 1376] as [CGFloat] {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1000)
            let split = UISplitViewController(style: .doubleColumn)
            split.preferredDisplayMode = .oneBesideSecondary
            split.preferredSplitBehavior = .tile
            split.setViewController(UIViewController(), for: .primary)
            split.setViewController(UIViewController(), for: .secondary)
            window.rootViewController = split
            window.isHidden = false
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertEqual(MobileSplit.columns(width: width, height: 1000, device: .pad).sidebar, split.primaryColumnWidth,
                           "\(width) points wide")
            XCTAssertEqual(split.viewController(for: .primary)?.traitCollection.horizontalSizeClass, .compact,
                           "The system's sidebar is compact, as `mobileCompactWidth` makes the split's")
            window.isHidden = true
        }
    }

    /// The app at iPad sizes: the system's sidebar width beside the tab either way up, the sidebar's tab bar at its foot
    /// (the phone's, not iPadOS's floating top bar); a third and Slide Over are the phone's one stack. iPad only: the
    /// tab bar's style follows the idiom.
    func testAnIPadShowsTheSidebarBesideTheTab() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("The tab bar's style follows the idiom") }
        let app = composition()
        let ref = try XCTUnwrap(app.tabs.workspaces.flatMap(\.tabs).first { $0.isChat }?.ref)
        app.navigator.path = [.tab(ref)]
        for (size, name) in [(CGSize(width: 834, height: 1210), "ipad-portrait"), (CGSize(width: 1210, height: 834), "ipad-landscape"),
                             (CGSize(width: 683, height: 909), "ipad-13-half")] {
            let shown = try bars(app, size: size, png: name, device: .pad)
            let sidebar = MobileSplit.columns(width: size.width, height: size.height, device: .pad).sidebar
            XCTAssertEqual(shown.bars.count, 2, "\(name): \(shown.bars)")
            XCTAssertEqual(shown.bars.first?.width ?? 0, sidebar, accuracy: 1, name)
            XCTAssertEqual(shown.bars.last?.minX ?? 0, sidebar + 0.5, accuracy: 1, name)
            XCTAssertEqual(shown.tabBars.count, 1, "\(name): \(shown.tabBars)")
            XCTAssertLessThanOrEqual(shown.tabBars.first?.maxX ?? .infinity, sidebar + 1, "\(name): in the sidebar")
            XCTAssertGreaterThan(shown.tabBars.first?.minY ?? 0, size.height / 2, "\(name): at the sidebar's foot")
            XCTAssertTrue(app.navigator.split)
        }
        let narrow = try bars(app, size: CGSize(width: 375, height: 1031), png: "ipad-slide-over", device: .pad)
        XCTAssertEqual(narrow.bars.count, 1, "\(narrow.bars)")
        XCTAssertFalse(app.navigator.split)
        XCTAssertEqual(app.navigator.path, [.tab(ref)], "The tab on top")
    }

    /// The iPad split's sidebar hides only beside a tab, stays hidden across a narrow spell, comes back when no tab is
    /// left, and the next tab then arrives with it.
    func testTheSidebarHidesOnlyBesideATab() {
        let navigator = navigator()
        navigator.split = true
        navigator.toggleSidebar()
        XCTAssertFalse(navigator.sidebarIsHidden, "Nothing to give the window to")
        navigator.path = [.space(space("s")), .tab(tab("a"))]
        XCTAssertTrue(navigator.canToggleSidebar)
        navigator.toggleSidebar()
        XCTAssertTrue(navigator.sidebarIsHidden)
        navigator.split = false
        XCTAssertFalse(navigator.sidebarIsHidden, "The stack has no sidebar")
        navigator.split = true
        XCTAssertTrue(navigator.sidebarIsHidden, "Wide again: still the tab's window")
        navigator.toggleSidebar()
        XCTAssertFalse(navigator.sidebarIsHidden)
        navigator.toggleSidebar()
        navigator.closed(.tab(tab("a")))
        XCTAssertFalse(navigator.sidebarIsHidden)
        navigator.path = [.tab(tab("b"))]
        XCTAssertFalse(navigator.sidebarIsHidden, "The next tab arrives beside the sidebar")
    }

    /// An iPad keeps the tab on screen and the sidebar's state across launches: the next launch whose window splits
    /// shows that tab with the sidebar as it was left, if the host still has the tab; a stacked window opens on the tab
    /// bar. The phone keeps nothing.
    func testAnIPadRemembersItsTabAndSidebar() throws {
        let suite = "mobile-split-memory-\(UUID().uuidString)"
        let memory = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { memory.removePersistentDomain(forName: suite) }
        let model = TabsSample.model()
        let shown = TabRef(host: TabsSample.mba2.id, key: "herdr:app:2")
        func launch() -> SpacesNavigator { SpacesNavigator(model: model, memory: memory) }

        let phone = launch()
        phone.split = true
        phone.path = [.tab(shown)]
        phone.toggleSidebar()
        XCTAssertNil(memory.object(forKey: SpacesNavigator.shownTabKey), "The phone keeps nothing")

        let first = launch()
        first.restoreSplit(splits: true)
        XCTAssertEqual(first.path, [], "Nothing kept yet")
        first.path = [.space(SpaceRef(host: shown.host, key: "herdr:app")), .tab(shown)]
        first.toggleSidebar()
        XCTAssertTrue(first.sidebarIsHidden)

        let second = launch()
        second.restoreSplit(splits: true)
        XCTAssertEqual(second.path, [.tab(shown)])
        XCTAssertTrue(second.split, "Known before the first frame")
        XCTAssertTrue(second.sidebarIsHidden, "As it was left")
        second.restoreSplit(splits: true)
        XCTAssertEqual(second.path, [.tab(shown)], "Once a launch")
        second.toggleSidebar()

        let third = launch()
        third.restoreSplit(splits: true)
        XCTAssertEqual(third.path, [.tab(shown)])
        XCTAssertFalse(third.sidebarIsHidden, "Shown when it was left shown")
        third.closed(.tab(shown))
        XCTAssertNil(memory.object(forKey: SpacesNavigator.shownTabKey), "No tab left")

        memory.set(try JSONEncoder().encode(shown), forKey: SpacesNavigator.shownTabKey)
        let narrow = launch()
        narrow.restoreSplit(splits: false)
        XCTAssertEqual(narrow.path, [], "A stacked window opens on the tab bar")

        memory.set(try JSONEncoder().encode(TabRef(host: shown.host, key: "herdr:gone:1")), forKey: SpacesNavigator.shownTabKey)
        let gone = launch()
        gone.restoreSplit(splits: true)
        XCTAssertEqual(gone.path, [], "A tab the host no longer has")
    }

    /// The launch's first frame already has the remembered layout: the sidebar out of the window, the tab across it.
    func testALaunchWithTheSidebarHiddenStartsWithoutIt() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("The sidebar hides on an iPad") }
        let suite = "mobile-split-launch-\(UUID().uuidString)"
        let memory = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { memory.removePersistentDomain(forName: suite) }
        let shown = TabRef(host: TabsSample.mba2.id, key: "herdr:app:2")
        memory.set(try JSONEncoder().encode(shown), forKey: SpacesNavigator.shownTabKey)
        memory.set(true, forKey: SpacesNavigator.sidebarHiddenKey)
        let app = composition(memory: memory)
        let size = MobileSplit.initialSize
        let scene = try XCTUnwrap(TestSupport.windowScene())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: MobileRoot(composition: app, device: .pad).environment(app.hosts))
        window.isHidden = false
        defer { window.isHidden = true }
        // One layout pass, no run loop turn: what the first frame shows.
        window.layoutIfNeeded()
        XCTAssertEqual(app.navigator.path, [.tab(shown)])
        XCTAssertTrue(app.navigator.sidebarIsHidden)
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func frames<Bar: UIView>(_ type: Bar.Type) -> [CGRect] {
            views(window).filter { $0 is Bar && !$0.isHidden && $0.window != nil }.map { $0.convert($0.bounds, to: window) }
        }
        let bars = frames(UINavigationBar.self).filter { window.bounds.intersects($0) }
        XCTAssertEqual(bars.count, 1, "Only the tab's bar in the window: \(bars)")
        XCTAssertEqual(bars.first?.width ?? 0, size.width, accuracy: 1, "Across the window")
        XCTAssertTrue(frames(UITabBar.self).allSatisfy { !window.bounds.intersects($0) }, "The sidebar's tab bar is out of the window")
    }

    /// The sidebar's slide keeps the tab at the wider of its two widths until it ends (`sidebarSliding`), as the Mac's
    /// split does, so the terminal's grid changes once a slide, not every frame: shown again, the tab's bar still spans
    /// the window while the sidebar slides in, and takes its column once it is in.
    func testTheTabKeepsItsWidthForTheSlide() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("The sidebar hides on an iPad") }
        let app = composition()
        let ref = try XCTUnwrap(app.tabs.workspaces.flatMap(\.tabs).first { $0.isChat }?.ref)
        app.navigator.path = [.tab(ref)]
        app.navigator.split = true
        app.navigator.toggleSidebar()
        let size = CGSize(width: 1210, height: 834)
        let scene = try XCTUnwrap(TestSupport.windowScene())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: MobileRoot(composition: app, device: .pad).environment(app.hosts))
        window.isHidden = false
        defer { window.isHidden = true }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(app.navigator.sidebarSliding)
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func tabBar() -> CGRect? {
            views(window).filter { $0 is UINavigationBar && !$0.isHidden && $0.window != nil }
                .map { $0.convert($0.bounds, to: window) }.max { $0.width < $1.width }
        }
        app.navigator.toggleSidebar()
        XCTAssertTrue(app.navigator.sidebarSliding, "At once, before the slide starts on the next turn")
        // The slide frozen where it starts (its timing depends on whether animations run): shown, still sliding.
        app.navigator.sidebarSlides += 1
        app.navigator.sidebarSliding = true
        app.navigator.sidebarDrawnHidden = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(app.navigator.sidebarIsHidden)
        XCTAssertEqual(tabBar()?.width ?? 0, size.width, accuracy: 1, "The tab keeps the window's width while the sidebar slides in")
        app.navigator.sidebarSliding = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let columns = MobileSplit.columns(width: size.width, height: size.height, device: .pad)
        XCTAssertEqual(tabBar()?.width ?? 0, columns.tab, accuracy: 1, "Its column once the sidebar is in")
    }

    /// Hidden, the sidebar leaves the window and the tab's bar spans it, its leading item the sidebar button.
    func testAHiddenSidebarGivesTheTabTheWindow() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("The sidebar hides on an iPad") }
        let app = composition()
        let ref = try XCTUnwrap(app.tabs.workspaces.flatMap(\.tabs).first { $0.isChat }?.ref)
        app.navigator.path = [.tab(ref)]
        app.navigator.split = true
        app.navigator.toggleSidebar()
        let shown = try bars(app, size: CGSize(width: 1210, height: 834), png: "ipad-sidebar-hidden", device: .pad)
        XCTAssertEqual(shown.bars.count, 1, "\(shown.bars)")
        XCTAssertEqual(shown.bars.first?.minX ?? -1, 0, accuracy: 1)
        XCTAssertEqual(shown.bars.first?.width ?? 0, 1210, accuracy: 1)
        XCTAssertTrue(shown.tabBars.isEmpty, "The sidebar's tab bar is out of the window: \(shown.tabBars)")
    }

    private func composition(memory: UserDefaults? = nil) -> MobileComposition {
        let hosts = HostSessions(store: HostStore(url: nil, hosts: []),
                                 keys: KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none, secureEnclaveAvailable: false),
                                 knownHosts: KnownHostStore(url: nil), driver: ScriptedHostSessionDriver(), active: false)
        return MobileComposition(hosts: hosts, tabs: TabsSample.model(), presences: TerminalPresences(),
                                 markers: ChatMarkers(store: ChatMarkerMemoryStore()), outbox: ChatOutbox(store: ChatOutboxMemoryStore()),
                                 drafts: ChatDraftRepository(store: ChatDraftMemoryStore()), feedsTabs: false, splitMemory: memory)
    }

    /// The visible navigation bars' frames in the window, left to right.
    private func bars(_ app: MobileComposition, size: CGSize, png: String) throws -> [CGRect] {
        try bars(app, size: size, png: png, device: .phone).bars
    }

    /// The visible navigation and tab bars' frames in the window, left to right, the app laid out for `device`.
    private func bars(_ app: MobileComposition, size: CGSize, png: String, device: MobileSplit.Device) throws -> (bars: [CGRect], tabBars: [CGRect]) {
        let scene = try XCTUnwrap(TestSupport.windowScene())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: MobileRoot(composition: app, device: device).environment(app.hosts))
        window.isHidden = false
        defer { window.isHidden = true }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        if let folder = ProcessInfo.processInfo.environment["DISPATCH_TABS_PNG"] {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: URL(fileURLWithPath: folder).appendingPathComponent(png + ".png"))
        }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func frames<Bar: UIView>(_ type: Bar.Type) -> [CGRect] {
            views(window)
                .filter { $0 is Bar && !$0.isHidden && $0.alpha > 0 && $0.window != nil }
                .map { $0.convert($0.bounds, to: window) }
                .filter { $0.width > 0 && window.bounds.intersects($0) }
                .sorted { $0.minX < $1.minX }
        }
        return (frames(UINavigationBar.self), frames(UITabBar.self))
    }
}
