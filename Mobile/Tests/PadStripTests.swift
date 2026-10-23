import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// The iPad's strip layout (docs/ios.md, iPad windows): the five modes per tab and host (`PadMode`), the strip's pills,
/// the sidebar's space rows, the shown tab's neighbour after a close, the panes of Review and Commits, and the mode kept
/// across launches. On the Spaces sample (`TabsSample`: mba2's app space holds claude, dev and a split zsh tab).
@MainActor
final class PadStripTests: XCTestCase {
    private let mba2 = TabsSample.mba2.id, studio = TabsSample.studio.id
    private func tab(_ host: UUID, _ key: String) -> TabRef { TabRef(host: host, key: key) }
    private func space(_ host: UUID, _ key: String) -> SpaceRef { SpaceRef(host: host, key: key) }

    /// The iPad's navigator in the split, its sidebar hideable, as `MobileRoot` sets it on an iPad.
    private func navigator(_ model: MobileTabs = TabsSample.model(), memory: UserDefaults? = nil) -> SpacesNavigator {
        let navigator = SpacesNavigator(model: model, memory: memory)
        navigator.sidebarHides = true
        navigator.split = true
        return navigator
    }

    /// Terminal always; Chat unless the tab is a plain shell; Files where the host serves it; Review and Commits inside a
    /// repository, and while that is unknown only for a tab that shows one of them (no frame of Files first).
    func testTheModesFollowTheHostAndTheRepository() throws {
        let model = TabsSample.model()
        let facts = SpaceGitFacts()
        let claude = try XCTUnwrap(model.tab(tab(mba2, "herdr:app:1")))
        XCTAssertEqual(model.modes(claude, facts: facts).available, [.terminal, .chat, .files], "Not known yet")
        XCTAssertEqual(model.modes(claude, facts: facts).shown, .chat, "An agent's tab opens on Chat")
        model.setMode(.review, for: claude.ref)
        XCTAssertEqual(model.modes(claude, facts: facts).available, PadMode.allCases, "Review kept while unknown")
        XCTAssertEqual(model.modes(claude, facts: facts).shown, .review)
        TabsSample.gitFacts(facts, model: model)
        XCTAssertEqual(model.modes(claude, facts: facts).available, PadMode.allCases)
        facts.seed(SpaceGitFacts.Key(host: mba2, key: claude.ref.key),
                   SpaceGitFacts.Facts(directory: "/Users/alex/src/app", root: nil, branch: nil))
        XCTAssertEqual(model.modes(claude, facts: facts).available, [.terminal, .chat, .files], "Outside a repository")
        XCTAssertEqual(model.modes(claude, facts: facts).shown, .files, "A git mode outside one shows Files")

        var plain = TabsSample.mba2
        plain.plain = true
        XCTAssertEqual(PadMode.available(tab: claude, host: plain, repository: true), [.terminal, .chat], "No helper: no Files")
        var denied = TabsSample.mba2
        denied.files = false
        XCTAssertEqual(PadMode.available(tab: claude, host: denied, repository: true), [.terminal, .chat], "No grant")
        var offline = TabsSample.mba2
        offline.state = .offline
        XCTAssertEqual(PadMode.available(tab: claude, host: offline, repository: true), PadMode.allCases, "Offline: dimmed, not gone")
    }

    /// While the repository is not known the switch keeps five slots, Review and Commits disabled, so it never changes
    /// its width when a repository answers; a no takes them away; a remembered answer (the split memory) counts.
    func testTheSwitchKeepsItsSlotsWhileTheRepositoryIsUnknown() throws {
        let model = TabsSample.model()
        let facts = SpaceGitFacts()
        let claude = try XCTUnwrap(model.tab(tab(mba2, "herdr:app:1")))
        model.setMode(.chat, for: claude.ref)
        var modes = model.modes(claude, facts: facts)
        XCTAssertEqual(modes.slots, PadMode.allCases, "Five places while unknown")
        XCTAssertEqual(modes.available, [.terminal, .chat, .files], "the git two disabled")
        model.knownRepositories[MobileTabs.repositoryKey(claude.ref)] = true
        modes = model.modes(claude, facts: facts)
        XCTAssertEqual(modes.available, PadMode.allCases, "Remembered from the last run")
        model.knownRepositories = [:]
        facts.seed(SpaceGitFacts.Key(host: mba2, key: claude.ref.key),
                   SpaceGitFacts.Facts(directory: "/Users/alex/src/app", root: nil, branch: nil))
        modes = model.modes(claude, facts: facts)
        XCTAssertEqual(modes.slots, [.terminal, .chat, .files], "Not a repository: three")
        let navigator = self.navigator(model)
        navigator.rememberRepository(claude.ref, false)
        XCTAssertEqual(model.knownRepositories[MobileTabs.repositoryKey(claude.ref)], false)
    }

    /// A launch restores Review or Commits only where the tab's folder was a repository last time (else Files), so
    /// no frame shows a mode the strip cannot offer.
    func testARestoredGitModeWaitsForTheRepository() throws {
        let suite = "pad-strip-restore-\(UUID().uuidString)"
        let memory = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { memory.removePersistentDomain(forName: suite) }
        let shown = tab(mba2, "herdr:app:1")
        memory.set(try JSONEncoder().encode(shown), forKey: SpacesNavigator.shownTabKey)
        memory.set("commits", forKey: SpacesNavigator.shownModeKey)
        let unknown = SpacesNavigator(model: TabsSample.model(), memory: memory)
        unknown.restoreSplit(splits: true)
        XCTAssertEqual(unknown.model.chosenMode(try XCTUnwrap(unknown.model.tab(shown))), .files, "Not known: Files")

        memory.set("commits", forKey: SpacesNavigator.shownModeKey)
        memory.set([MobileTabs.repositoryKey(shown): true], forKey: SpacesNavigator.repositoriesKey)
        let known = SpacesNavigator(model: TabsSample.model(), memory: memory)
        known.restoreSplit(splits: true)
        XCTAssertEqual(known.model.chosenMode(try XCTUnwrap(known.model.tab(shown))), .commits, "A repository last time")
        XCTAssertEqual(known.model.knownRepositories[MobileTabs.repositoryKey(shown)], true)
    }

    /// A tab the host closed (another client, its shell's exit) hands the detail column to its strip neighbour, the next
    /// else the one before, and its panes go; with no tab left the column empties and the sidebar comes back.
    func testATabClosedOnTheHostHandsOnTheColumn() throws {
        let model = MobileTabs(activity: TabActivityStore(url: nil), defaults: UserDefaults(suiteName: "pad-strip-host-close")!)
        func sync(_ keys: [String]) {
            let sketch = TopologySketch(spaces: [.init(key: "herdr:app", name: "app", tabs: keys.map { key in
                .init(key: key, name: "zsh", panes: [.init(key: "p:" + key, cwd: "/Users/alex/src/app")])
            })])
            model.sync([TabsHostInput(host: TabsFixtures.host, client: nil, topology: sketch.topology)])
        }
        sync(["herdr:app:1", "herdr:app:2", "herdr:app:3"])
        let navigator = self.navigator(model)
        let host = TabsFixtures.host.id
        navigator.path = [.tab(TabRef(host: host, key: "herdr:app:2"))]
        model.paneRoutes[TabRef(host: host, key: "herdr:app:2")] = [.commits: FilesRoute(mode: .commits, revision: "c81a2f4")]
        sync(["herdr:app:1", "herdr:app:3"])
        XCTAssertEqual(navigator.splitPath.tab, TabRef(host: host, key: "herdr:app:3"), "The next")
        XCTAssertNil(model.paneRoutes[TabRef(host: host, key: "herdr:app:2")], "Its panes go")
        sync(["herdr:app:1"])
        XCTAssertEqual(navigator.splitPath.tab, TabRef(host: host, key: "herdr:app:1"), "The one before, at the end")
        navigator.toggleSidebar()
        XCTAssertTrue(navigator.sidebarIsHidden)
        sync([])
        XCTAssertNil(navigator.splitPath.tab, "No tab left")
        XCTAssertFalse(navigator.sidebarIsHidden, "The sidebar comes back")
        XCTAssertFalse(navigator.canToggleSidebar)
    }

    /// Review's pane empties when its change leaves the list (committed or reverted meanwhile); before the list has
    /// read, the pane keeps what was chosen.
    func testReviewsPaneEmptiesWhenItsChangeLeaves() async throws {
        let app = MobileComposition(hosts: HostSessions(store: HostStore(url: nil, hosts: []),
                                                         keys: KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none,
                                                                        secureEnclaveAvailable: false),
                                                         knownHosts: KnownHostStore(url: nil), driver: ScriptedHostSessionDriver(),
                                                         active: false),
                                    tabs: TabsSample.model(), presences: TerminalPresences(),
                                    markers: ChatMarkers(store: ChatMarkerMemoryStore()), outbox: ChatOutbox(store: ChatOutboxMemoryStore()),
                                    drafts: ChatDraftRepository(store: ChatDraftMemoryStore()), feedsTabs: false)
        let claude = tab(mba2, "herdr:app:1")
        let files = app.filesContent
        let change = try XCTUnwrap(ReviewSample.status().changes.first)
        let gone = FilesRoute(mode: .review, path: "src/gone.ts", detail: change.area.rawValue)
        XCTAssertTrue(files.paneShows(claude, gone), "Before the list has read")
        let root = try XCTUnwrap(app.gitFacts.facts(SpaceGitFacts.Key(host: mba2, key: claude.key))?.root)
        await app.review.changes(ReviewPlace(host: mba2, root: root)).refresh(fresh: true)
        XCTAssertTrue(files.paneShows(claude, .review(change)))
        XCTAssertFalse(files.paneShows(claude, gone), "Not among the changes")
        XCTAssertTrue(files.paneShows(claude, FilesRoute(mode: .commits, revision: "c81a2f4")), "Commits keep theirs")
    }

    /// A mode is the phone's segment and Files mode in one: the strip and the phone's capsule show the same view.
    func testAModeIsASegmentAndAFilesMode() throws {
        let model = TabsSample.model()
        let dev = tab(mba2, "herdr:app:2")
        let tab = try XCTUnwrap(model.tab(dev))
        XCTAssertEqual(model.chosenMode(tab), .terminal)
        model.setMode(.commits, for: dev)
        XCTAssertEqual(model.segments[dev], .files)
        XCTAssertEqual(model.filesModes[dev], .commits)
        XCTAssertEqual(model.segmentsBeforeFiles[dev], .terminal, "Files' Not now returns there")
        model.setMode(.chat, for: dev)
        XCTAssertEqual(model.chosenMode(tab), .chat)
        XCTAssertEqual(model.filesModes[dev], .commits, "Files keeps its mode for the next visit")
        for mode in PadMode.allCases {
            XCTAssertEqual(PadMode(segment: mode.segment, files: mode.filesMode ?? .files), mode)
        }
        XCTAssertEqual(PadMode.review.symbol, "pencil.and.list.clipboard")
        XCTAssertEqual(PadMode.commits.symbol, "clock.arrow.circlepath")
        XCTAssertEqual(PadMode.chat.symbol, "text.bubble")
    }

    /// The pills are the shown tab's space's tabs in the space's order; each names its agent for its mark (the
    /// conversation's, else the program), none for a shell.
    func testThePillsAreTheSpacesTabs() {
        let model = TabsSample.model()
        XCTAssertEqual(model.strip(for: tab(mba2, "herdr:app:2")).map(\.ref.key), ["herdr:app:1", "herdr:app:2", "herdr:app:3"])
        XCTAssertEqual(model.strip(for: tab(studio, "tmux:docs:@2")).map(\.ref.key), ["tmux:docs:@1", "tmux:docs:@2"])
        XCTAssertTrue(model.strip(for: tab(mba2, "herdr:gone:1")).isEmpty)
        let agents = model.strip(for: tab(mba2, "herdr:app:1")).map { model.agent(of: $0) }
        XCTAssertEqual(agents, ["claude", nil, nil])
        let claude = model.tab(tab(mba2, "herdr:app:1"))?.agentPane?.id
        model.agentKey = { _, terminal in terminal == claude ? "pi" : nil }
        XCTAssertEqual(model.agent(of: model.tab(tab(mba2, "herdr:app:1"))!), "pi", "The conversation's agent first")
        XCTAssertEqual(AgentGlyph.kind(model.agent(of: model.tab(tab(mba2, "herdr:e2e:1"))!)), .codex)
    }

    /// A space's row in the iPad sidebar shows the tab the space showed last, else its first, beside the sidebar,
    /// which keeps its own screens; the row of the shown space is the marked one.
    func testASpaceRowShowsItsLastTab() {
        let navigator = navigator()
        let app = space(mba2, "herdr:app"), docs = space(studio, "tmux:docs")
        navigator.selectSpace(app)
        XCTAssertEqual(navigator.splitPath.tab, tab(mba2, "herdr:app:1"), "Its first tab")
        XCTAssertEqual(navigator.shownSplitSpace, app)
        navigator.select(tab(mba2, "herdr:app:3"))
        navigator.selectSpace(docs)
        XCTAssertEqual(navigator.splitPath.tab, tab(studio, "tmux:docs:@1"))
        XCTAssertEqual(navigator.shownSplitSpace, docs)
        navigator.selectSpace(app)
        XCTAssertEqual(navigator.splitPath.tab, tab(mba2, "herdr:app:3"), "The tab it showed last")
        XCTAssertEqual(navigator.splitPath.sidebar, [])
        XCTAssertEqual(navigator.model.recentSpace?.ref, app, "New tab goes there")
    }

    /// A stacked window's path (a space's screen, its tab) splits with the tree in the sidebar: the space's screen stays
    /// behind, the tab beside the tree. The Duo's split keeps it.
    func testSplittingKeepsTheTreeInTheSidebar() {
        let navigator = SpacesNavigator(model: TabsSample.model())
        navigator.sidebarHides = true
        let app = space(mba2, "herdr:app"), dev = tab(mba2, "herdr:app:2")
        navigator.path = [.space(app), .tab(dev)]
        navigator.split = true
        XCTAssertEqual(navigator.path, [.tab(dev)])
        let duo = SpacesNavigator(model: TabsSample.model())
        duo.path = [.space(app), .tab(dev)]
        duo.split = true
        XCTAssertEqual(duo.path, [.space(app), .tab(dev)])
    }

    /// Closing the shown tab shows its neighbour in the strip (the next, else the one before), as the Mac's strip does;
    /// the Duo's split and the stack only take it off.
    func testClosingTheShownTabShowsItsNeighbour() {
        let navigator = navigator()
        navigator.path = [.tab(tab(mba2, "herdr:app:1"))]
        navigator.closed(.tab(tab(mba2, "herdr:app:1")))
        XCTAssertEqual(navigator.splitPath.tab, tab(mba2, "herdr:app:2"), "The next")
        navigator.path = [.tab(tab(mba2, "herdr:app:3"))]
        navigator.closed(.tab(tab(mba2, "herdr:app:3")))
        XCTAssertEqual(navigator.splitPath.tab, tab(mba2, "herdr:app:2"), "The one before, at the end")
        navigator.closed(.tab(tab(mba2, "herdr:app:1")))
        XCTAssertEqual(navigator.splitPath.tab, tab(mba2, "herdr:app:2"), "Another tab closing leaves the shown one")

        let duo = SpacesNavigator(model: TabsSample.model())
        duo.split = true
        duo.path = [.tab(tab(mba2, "herdr:app:1"))]
        duo.closed(.tab(tab(mba2, "herdr:app:1")))
        XCTAssertNil(duo.splitPath.tab, "The Duo's detail column empties")
    }

    /// Review's changes and Commits' commits open in the pane beside their list; files, a commit's file and a mode's
    /// other screens are pushed. A closed tab's panes go with it.
    func testPanesHoldDiffsAndCommits() {
        XCTAssertTrue(FilesRoute(mode: .review, path: "src/a.ts", detail: "unstaged").opensInPane)
        XCTAssertTrue(FilesRoute(mode: .commits, revision: "c81a2f4").opensInPane)
        XCTAssertFalse(FilesRoute(mode: .commits, path: "src/a.ts", revision: "c81a2f4").opensInPane, "A commit's file")
        XCTAssertFalse(FilesRoute.preview("src/a.ts").opensInPane)
        XCTAssertFalse(FilesRoute(mode: .review).opensInPane)
        let navigator = navigator()
        let claude = tab(mba2, "herdr:app:1")
        navigator.path = [.tab(claude)]
        navigator.model.paneRoutes[claude] = [.commits: FilesRoute(mode: .commits, revision: "c81a2f4")]
        navigator.closed(.tab(claude))
        XCTAssertNil(navigator.model.paneRoutes[claude])
    }

    /// The iPad keeps the shown tab's mode with the tab across launches, and the next launch opens it on that mode.
    func testTheModeIsKeptWithTheTab() throws {
        let suite = "pad-strip-memory-\(UUID().uuidString)"
        let memory = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { memory.removePersistentDomain(forName: suite) }
        let shown = tab(mba2, "herdr:app:1")
        let first = SpacesNavigator(model: TabsSample.model(), memory: memory)
        first.restoreSplit(splits: true)
        first.path = [.tab(shown)]
        first.rememberRepository(shown, true)
        first.model.setMode(.review, for: shown)
        XCTAssertEqual(memory.string(forKey: SpacesNavigator.shownModeKey), "review")

        let second = SpacesNavigator(model: TabsSample.model(), memory: memory)
        second.restoreSplit(splits: true)
        XCTAssertEqual(second.path, [.tab(shown)])
        XCTAssertEqual(second.model.segments[shown], .files)
        XCTAssertEqual(second.model.filesModes[shown], .review)
    }

    /// A pill keeps its own width up to 200 points, the selected one up to 260 with its ×, the title truncating past
    /// it; the switch of five is a fixed 5 × 40 points and its padding.
    func testPillsShrinkBeforeTheyOverflow() {
        // Fitting: their own widths. Too wide: the widest give way first, none under its minimum.
        XCTAssertEqual(PadPillsLayout.shrink(ideal: [100, 200, 90], minimum: [120, 150, 120], room: 400), [100, 200, 90])
        let shrunk = PadPillsLayout.shrink(ideal: [200, 260, 200], minimum: [120, 150, 120], room: 540)
        XCTAssertLessThanOrEqual(shrunk.reduce(0, +), 540)
        XCTAssertEqual(shrunk[0], shrunk[2])
        XCTAssertGreaterThanOrEqual(shrunk.min() ?? 0, 120)
        XCTAssertLessThanOrEqual(PadPillsLayout.shrink(ideal: [200, 200], minimum: [120, 150], room: 200).reduce(0, +), 200,
                                 "Under the minimums: in proportion, never wider than the room")
        // The track keeps what fits at the minimums, the selected one always; the rest go to the overflow menu.
        let refs = (1...5).map { tab(mba2, "herdr:app:\($0)") }
        XCTAssertEqual(PadPills.visible(refs, selected: refs[1], room: nil).hidden, [], "Not measured yet: all")
        XCTAssertEqual(PadPills.visible(refs, selected: refs[1], room: 1000).hidden, [], "All fit")
        let split = PadPills.visible(refs, selected: refs[4], room: 450)
        XCTAssertEqual(split.shown, [refs[0], refs[4]], "Two fit beside the overflow; the selected one kept")
        XCTAssertEqual(split.hidden, [refs[1], refs[2], refs[3]])
        XCTAssertEqual(PadPills.visible(refs, selected: refs[2], room: 10).shown, [refs[2]], "The selected one at least")
    }

    func testPillsCapTheirWidth() throws {
        let scene = try XCTUnwrap(TestSupport.windowScene())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1200, height: 200)
        final class Frames { var values: [String: CGRect] = [:] }
        let frames = Frames()
        func measured(_ view: some View, _ name: String) -> some View {
            view.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.values[name] = $0 }
        }
        let long = "Rate limiter for the API with a much longer title than fits"
        let row = VStack(alignment: .leading) {
            measured(PadTabPill(title: long, urgency: .needsYou, agent: "codex", shell: false, selected: false, select: {}, close: {})
                .fixedSize(), "long")
            measured(PadTabPill(title: long, urgency: nil, agent: "claude", shell: false, selected: true, select: {}, close: {})
                .fixedSize(), "selected")
            measured(PadTabPill(title: "zsh", urgency: nil, agent: nil, shell: false, selected: false, select: {}, close: {})
                .fixedSize(), "short")
            measured(PadModeSwitch(modes: PadMode.allCases, selected: .files, review: 3) { _ in }, "modes")
        }
        window.rootViewController = UIHostingController(rootView: row)
        window.isHidden = false
        defer { window.isHidden = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        // A truncated title ends at a glyph: the pill comes to its cap or a few points short of it.
        let capped = frames.values["long"]?.width ?? 0, selected = frames.values["selected"]?.width ?? 0
        XCTAssertTrue((PadPills.width - 16...PadPills.width + 0.5).contains(capped), "\(capped)")
        XCTAssertTrue((PadPills.selectedWidth - 16...PadPills.selectedWidth + 0.5).contains(selected), "\(selected)")
        XCTAssertLessThan(frames.values["short"]?.width ?? .infinity, 120, "A short title keeps a short pill")
        XCTAssertEqual(frames.values["modes"]?.width ?? 0, 5 * 40 + 4 * 2 + 6, accuracy: 1)
    }

    /// The sidebar's filter is Spaces' query (All, Needs you, Agents); its title gives way beside window controls.
    func testTheSidebarsFilterAndTitle() {
        let model = TabsSample.model()
        model.query.filter = .agents
        XCTAssertEqual(model.sections().flatMap(\.spaces).map(\.space.name).sorted(), ["app", "billing", "curves", "docs", "e2e"])
        model.query.filter = .needsYou
        XCTAssertEqual(model.sections().flatMap(\.spaces).map(\.space.name).sorted(), ["docs", "e2e"])
        XCTAssertTrue(PadSidebar.showsTitle(width: 320, controls: 0), "Full screen: the title beside the controls")
        XCTAssertFalse(PadSidebar.showsTitle(width: 320, controls: 78), "Beside the window controls it gives way")
        XCTAssertFalse(PadSidebar.showsTitle(width: 280, controls: 78))
    }
}
