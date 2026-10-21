import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// The unfolded iPhone Duo's split (`MobileSplit`): Spaces in a sidebar column, the tab they open beside it. Both
/// columns show the navigator's one path, so folding the phone shows the same screens as a stack. Renders go to
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

    private func composition() -> MobileComposition {
        let hosts = HostSessions(store: HostStore(url: nil, hosts: []),
                                 keys: KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none, secureEnclaveAvailable: false),
                                 knownHosts: KnownHostStore(url: nil), driver: ScriptedHostSessionDriver(), active: false)
        return MobileComposition(hosts: hosts, tabs: TabsSample.model(), presences: TerminalPresences(),
                                 markers: ChatMarkers(store: ChatMarkerMemoryStore()), outbox: ChatOutbox(store: ChatOutboxMemoryStore()),
                                 drafts: ChatDraftRepository(store: ChatDraftMemoryStore()), feedsTabs: false)
    }

    /// The visible navigation bars' frames in the window, left to right.
    private func bars(_ app: MobileComposition, size: CGSize, png: String) throws -> [CGRect] {
        let scene = try XCTUnwrap(TestSupport.windowScene())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: MobileRoot(composition: app).environment(app.hosts))
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
        return views(window)
            .filter { $0 is UINavigationBar && !$0.isHidden && $0.alpha > 0 && $0.window != nil }
            .map { $0.convert($0.bounds, to: window) }
            .filter { $0.width > 0 && window.bounds.intersects($0) }
            .sorted { $0.minX < $1.minX }
    }
}
