import Foundation
import SwiftUI
import XCTest
@testable import DispatchMobile

/// The Spaces tree (M2b) and host editing (M1e): host sections in the store's order, spaces in the phone's order
/// within their host, Mail-style unread counts with the collapsed roll-up, and the injected host actions.
@MainActor
final class TabsSpacesTreeTests: XCTestCase {
    private let ai = TabsHost(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!, name: "ai", tint: .purple, order: 0)

    private func model(_ urgency: [String: TabUrgency] = [:], suite: String = #function,
                       deviceState: SpacesDeviceState? = nil) -> MobileTabs {
        let defaults = UserDefaults(suiteName: "tabs-tree-\(suite)")!
        defaults.removePersistentDomain(forName: "tabs-tree-\(suite)")
        let store = TabActivityStore(url: nil)
        let model = MobileTabs(activity: store, defaults: defaults, deviceState: deviceState)
        let mine = TabsFixtures.app()
        let theirs = TopologySketch(backend: 1, first: 700, spaces: [
            .init(key: "herdr:curves", name: "curves", tabs: [
                .init(key: "herdr:curves:1", name: "claude", panes: [.init(key: "p:curves", cwd: "/home/alex", agent: "s9")]),
            ]),
        ])
        var host = TabsFixtures.host
        host.order = 1
        model.sync([TabsHostInput(host: host, client: nil, topology: mine.topology),
                    TabsHostInput(host: ai, client: nil, topology: theirs.topology)])
        var keys: [UInt64: String] = [:]
        for (key, id) in mine.ids { keys[id] = key }
        for (key, id) in theirs.ids { keys[id] = key }
        model.urgency = { _, terminal in keys[terminal].flatMap { urgency[$0] } }
        return model
    }

    /// Sections follow the host store's order; within a host, spaces keep server order until the user moves them.
    func testSectionsFollowHostOrderAndSpaceOrder() {
        let model = model()
        XCTAssertEqual(model.sections.map(\.host.name), ["ai", "mba2"])
        XCTAssertEqual(model.sections[1].spaces.map(\.space.name), ["app", "docs"])
        model.moveSpaces(of: TabsFixtures.host.id, from: [1], to: 0)
        XCTAssertEqual(model.sections[1].spaces.map(\.space.name), ["docs", "app"])
    }

    /// Dragging while a filter hides spaces moves the rows shown: their offsets are not the host's whole list, and the
    /// hidden spaces keep their places.
    func testMovingSpacesUnderAFilterMovesTheRowsShown() {
        let defaults = UserDefaults(suiteName: "tabs-tree-\(#function)")!
        defaults.removePersistentDomain(forName: "tabs-tree-\(#function)")
        let model = MobileTabs(activity: TabActivityStore(url: nil), defaults: defaults)
        let sketch = TopologySketch(backend: 1, first: 10, spaces: ["a", "b", "c"].map { name in
            .init(key: "s:\(name)", name: name, tabs: [.init(key: "t:\(name)", name: name, panes: [.init(key: "p:\(name)", cwd: "/")])])
        })
        model.sync([TabsHostInput(host: ai, client: nil, topology: sketch.topology)])
        let needsYou = Set(["p:a", "p:c"].compactMap { sketch.ids[$0] })
        model.urgency = { _, terminal in needsYou.contains(terminal) ? .needsYou : nil }
        model.query.filter = .needsYou
        XCTAssertEqual(model.sections[0].spaces.map(\.space.name), ["a", "c"])
        model.moveSpaces(of: ai.id, visible: model.sections[0].spaces.map(\.id.key), from: [1], to: 0)
        XCTAssertEqual(model.sections[0].spaces.map(\.space.name), ["c", "a"], "The dragged row moved")
        model.query.filter = .all
        XCTAssertEqual(model.sections[0].spaces.map(\.space.name), ["c", "b", "a"], "The hidden space kept its place")
    }

    /// Mail's counts: tabs that need you or hold an unseen result; amber when something works; a collapsed section
    /// rolls them up.
    func testUnreadCountsWorkingDotAndRollUp() {
        let model = model(["p:claude": .working, "p:zsh2": .needsYou, "p:dev": .unseen, "p:curves": .unseen])
        let mba2 = model.sections[1]
        XCTAssertEqual(mba2.spaces[0].unread, 2, "dev unseen and zsh needing you")
        XCTAssertTrue(mba2.spaces[0].working)
        XCTAssertEqual(mba2.spaces[1].unread, 0)
        XCTAssertFalse(mba2.spaces[1].working)
        XCTAssertEqual(mba2.unread, 2)
        XCTAssertFalse(mba2.collapsed)
        model.toggle(ai.id)
        XCTAssertTrue(model.sections[0].collapsed)
        XCTAssertEqual(model.sections[0].unread, 1)
        model.toggle(ai.id)
        XCTAssertFalse(model.sections[0].collapsed)
    }

    /// The filter applies at the spaces level too; hosts stay as sections.
    func testFilterKeepsHostsAndMatchingSpaces() {
        let model = model(["p:zsh2": .needsYou])
        model.query.filter = .needsYou
        XCTAssertEqual(model.sections.map(\.host.name), ["ai", "mba2"])
        XCTAssertEqual(model.sections.map { $0.spaces.map(\.space.name) }, [[], ["app"]])
    }

    /// Collapsed sections, the space order and the recent space are kept on the device in a private file out of
    /// backups (`spaces.json`), not in UserDefaults; an older build's UserDefaults values move there once.
    func testTreeStateIsRememberedInAPrivateFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("spaces.json")
        let suite = "tabs-tree-remembered"
        let first = model(suite: suite, deviceState: SpacesDeviceState(url: url))
        first.toggle(ai.id)
        first.moveSpaces(of: TabsFixtures.host.id, from: [1], to: 0)
        first.visited(SpaceRef(host: TabsFixtures.host.id, key: "herdr:docs"))
        let defaults = UserDefaults(suiteName: "tabs-tree-\(suite)")!
        XCTAssertTrue(SpacesDeviceState.legacyKeys.allSatisfy { defaults.object(forKey: $0) == nil }, "nothing per host in UserDefaults")
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let second = MobileTabs(activity: TabActivityStore(url: nil), defaults: defaults, deviceState: SpacesDeviceState(url: url))
        XCTAssertTrue(second.collapsed.contains(ai.id))
        XCTAssertEqual(second.spaceOrder[TabsFixtures.host.id], ["herdr:docs", "herdr:app"])
        XCTAssertEqual(second.recent, SpaceRef(host: TabsFixtures.host.id, key: "herdr:docs"))

        // An older build's values: moved into the file and out of UserDefaults.
        let old = UserDefaults(suiteName: "tabs-tree-legacy")!
        old.removePersistentDomain(forName: "tabs-tree-legacy")
        old.set([ai.id.uuidString], forKey: "tabs.collapsed")
        old.set(try JSONEncoder().encode([ai.id: ["tmux:s:2", "tmux:s:1"]]), forKey: "tabs.spaceOrder")
        old.set(try JSONEncoder().encode(SpaceRef(host: ai.id, key: "tmux:s:1")), forKey: "tabs.recent")
        let migratedURL = folder.appendingPathComponent("migrated.json")
        let migrated = SpacesDeviceState(url: migratedURL, migrating: old)
        XCTAssertEqual(migrated.collapsed, [ai.id])
        XCTAssertEqual(migrated.spaceOrder[ai.id], ["tmux:s:2", "tmux:s:1"])
        XCTAssertEqual(migrated.recent?.key, "tmux:s:1")
        XCTAssertTrue(SpacesDeviceState.legacyKeys.allSatisfy { old.object(forKey: $0) == nil })
        XCTAssertEqual(SpacesDeviceState(url: migratedURL).collapsed, [ai.id], "written to the file")

        // Remove all data: the file goes; the menu and the tree toggle stay.
        second.tree = true
        second.removeDeviceState()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(second.collapsed.isEmpty)
        XCTAssertNil(second.recent)
        XCTAssertTrue(second.tree)
    }

    /// Dragging hosts reorders the list at once and hands the order to the host store; removing a host (after the
    /// confirmation) drops it with its spaces.
    func testHostActions() {
        let model = model()
        let actions = FakeSpacesHostActions(model: model)
        model.moveHost(TabsFixtures.host.id, before: ai.id, actions: actions)
        XCTAssertEqual(model.sections.map(\.host.name), ["mba2", "ai"])
        XCTAssertEqual(actions.orders, [[TabsFixtures.host.id, ai.id]])
        XCTAssertEqual(model.workspaces.map(\.host.order), [0, 1])
        actions.removeHost(ai.id)
        XCTAssertEqual(actions.removed, [ai.id])
        XCTAssertEqual(model.sections.map(\.host.name), ["mba2"])
        XCTAssertNil(model.workspace(ai.id))
    }

    /// The urgency the rows draw: needs you and unseen are unread (blue), working amber; precedence as PaneUrgency.
    func testUrgencyIsMailUnread() {
        XCTAssertTrue(TabUrgency.needsYou.unread)
        XCTAssertTrue(TabUrgency.unseen.unread)
        XCTAssertFalse(TabUrgency.working.unread)
        XCTAssertEqual([TabUrgency.unseen, .needsYou, .working].max(), .needsYou)
        XCTAssertEqual([TabUrgency.unseen, .working].max(), .working)
    }

    /// The host's connection state and order come with the host list; a sync keeps each host's workspace object.
    func testSyncKeepsWorkspacesAndTakesState() {
        let model = model()
        let workspace = model.workspace(ai.id)
        var offline = ai
        offline.state = .offline
        var host = TabsFixtures.host
        host.order = 1
        model.sync([TabsHostInput(host: offline, client: nil, topology: nil), TabsHostInput(host: host, client: nil, topology: nil)])
        XCTAssertTrue(model.workspace(ai.id) === workspace)
        XCTAssertEqual(model.workspace(ai.id)?.host.state, .offline)
        XCTAssertEqual(model.sections[0].spaces.map(\.space.name), ["curves"], "last-known spaces stay listed")
    }

    /// The whole host row toggles (not only its disclosure): outside edit mode it is one VoiceOver button named after
    /// the host, a heading whose value is its state and the unread it rolls up; activating it toggles.
    func testTheWholeHostRowToggles() async throws {
        AccessibilityLabelTests.enableAccessibility()
        XCTAssertEqual(SpacesHostHeader.value(collapsed: false, unread: 3), "Expanded")
        XCTAssertEqual(SpacesHostHeader.value(collapsed: true, unread: 3), "Collapsed, 3 unread")
        XCTAssertEqual(SpacesHostHeader.value(collapsed: true, unread: 0), "Collapsed")
        XCTAssertEqual(SpacesHostHeader.value(collapsed: true, unread: 2, multiplexer: "tmux"), "tmux, Collapsed, 2 unread",
                       "where its spaces come from, when known")
        let found = await TestSupport.windowScene()
        let scene = try XCTUnwrap(found)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 200)
        let section = SpacesSection(host: ai, spaces: [], unread: 2, collapsed: true)
        var toggled = 0
        window.rootViewController = UIHostingController(rootView: SpacesHostHeader(section: section, editing: false,
                                                                                   toggle: { toggled += 1 }, remove: {}))
        window.isHidden = false
        defer { window.isHidden = true }
        var row: NSObject?
        try await TestSupport.eventually {
            row = AccessibilityLabelTests.elements(in: window).first { $0.accessibilityLabel == "ai" }
            return row != nil
        }
        let element = try XCTUnwrap(row)
        XCTAssertEqual(AccessibilityLabelTests.elements(in: window).count, 1, "one element: the disclosure is not a second button")
        XCTAssertEqual(element.accessibilityValue, "Collapsed, 2 unread")
        XCTAssertTrue(element.accessibilityTraits.contains(.button))
        XCTAssertTrue(element.accessibilityTraits.contains(.header))
        _ = element.accessibilityActivate()
        try await TestSupport.eventually { toggled == 1 }
    }

    /// A connected host whose spaces are known to be none offers New space below it, unless collapsed, filtered or in
    /// edit mode; not while its spaces are the cache's, or a multiplexer switch is on its way, or it is offline.
    func testZeroSpaceHostsOfferNewSpace() {
        let empty = SpacesSection(host: ai, spaces: [], unread: 0, collapsed: false)
        XCTAssertTrue(empty.offersNewSpace(editing: false, filter: .all))
        XCTAssertFalse(empty.offersNewSpace(editing: true, filter: .all))
        XCTAssertFalse(empty.offersNewSpace(editing: false, filter: .needsYou))
        XCTAssertFalse(SpacesSection(host: ai, spaces: [], unread: 0, collapsed: true).offersNewSpace(editing: false, filter: .all))
        var stale = ai
        stale.live = false
        XCTAssertFalse(SpacesSection(host: stale, spaces: [], unread: 0, collapsed: false).offersNewSpace(editing: false, filter: .all))
        var offline = ai
        offline.state = .offline
        XCTAssertFalse(SpacesSection(host: offline, spaces: [], unread: 0, collapsed: false).offersNewSpace(editing: false, filter: .all))
        let model = model()
        XCTAssertFalse(model.sections[0].offersNewSpace(editing: false, filter: .all), "a host with spaces")
        model.sync([TabsHostInput(host: ai, client: nil, topology: TopologySketch(backend: 1, first: 5, spaces: []).topology)])
        XCTAssertTrue(model.sections[0].offersNewSpace(editing: false, filter: .all), "its last space went")
    }

    /// The quick menu's entries: connected hosts only, in host order, each with its installed multiplexers, the one it
    /// shows first; another one switches the host. A host's own menu has only its own.
    func testQuickMenuEntries() {
        let helper = ScriptedHelper.scripted { _ in nil }
        defer { helper.close() }
        let herdr = MultiplexerChoice(mux: 2, name: "herdr", route: .init(mux: 2, key: "herdr"))
        let tmux = MultiplexerChoice(mux: 1, name: "tmux", route: .init(mux: 1, key: "tmux"))
        let mba2 = MobileWorkspace(host: TabsFixtures.host, client: helper.client, activity: TabActivityStore(url: nil))
        mba2.multiplexers = [herdr, tmux]
        mba2.choice = tmux
        let studio = MobileWorkspace(host: ai, client: helper.client, activity: TabActivityStore(url: nil))
        studio.choice = herdr
        let offline = MobileWorkspace(host: TabsHost(id: UUID(), name: "vps", tint: .green), activity: TabActivityStore(url: nil))
        offline.multiplexers = [tmux]
        offline.choice = tmux
        let all = NewSpaceDestination.all([mba2, studio, offline])
        XCTAssertEqual(all.map(\.id), ["\(mba2.id.uuidString):tmux", "\(mba2.id.uuidString):herdr", "\(ai.id.uuidString):herdr"])
        XCTAssertEqual(all.map(\.switches), [false, true, false])
        XCTAssertEqual(all.map { $0.title(host: nil) }, ["mba2", "mba2", "ai"])
        XCTAssertEqual(all.map { $0.subtitle(host: nil) }, ["tmux", "Switches mba2 to herdr", "herdr"])
        XCTAssertEqual(all[1].spoken(host: nil), "New space on mba2, Switches mba2 to herdr")
        let own = NewSpaceDestination.all([mba2, studio, offline], host: mba2.id)
        XCTAssertEqual(own.map { $0.title(host: mba2.id) }, ["New tmux space", "New herdr space"])
        XCTAssertEqual(own.map { $0.subtitle(host: mba2.id) }, [nil, "Switches mba2 to herdr"])
        XCTAssertEqual(NewSpaceDestination.all([offline], host: offline.id), [], "nothing to make a space on offline")
    }

    /// The Mac's naming rule: a new space is called after its folder's last component ("/" for the root); "~" is the
    /// host's home, and nothing is guessed while the home is unknown.
    func testNewSpacesAreNamedAfterTheirFolder() {
        let host = TabsFixtures.host
        XCTAssertEqual(NewSpaceName.automatic("~", host: host), "alex")
        XCTAssertEqual(NewSpaceName.automatic(nil, host: host), "alex", "no folder: home")
        XCTAssertEqual(NewSpaceName.automatic("~/src/billing", host: host), "billing")
        XCTAssertEqual(NewSpaceName.automatic("/srv/billing/", host: host), "billing")
        XCTAssertEqual(NewSpaceName.automatic("/", host: host), "/")
        var homeless = host
        homeless.home = nil
        XCTAssertNil(NewSpaceName.automatic("~/src", host: homeless))
        XCTAssertEqual(NewSpaceName.automatic("/srv/app", host: homeless), "app")
    }

    /// The quick menu makes its space without a name (the server names it after its folder) and the host's New space
    /// rows wait meanwhile; one at a time per host.
    func testQuickSpacesAreMadeWithoutAName() async throws {
        let fresh = TopologySketch(backend: 7, first: 300, spaces: [
            .init(key: "herdr:new", name: "alex", tabs: [.init(key: "herdr:new:1", name: "zsh", panes: [.init(key: "p:fresh", cwd: "/Users/alex")])]),
        ])
        let helper = ScriptedHelper.scripted { request in
            switch request.method {
            case "backends.create": .value(UInt64(7))
            case "terminals.create": .value(fresh.ids["p:fresh"]!)
            default: nil
            }
        }
        defer { helper.close() }
        let model = model()
        let workspace = MobileWorkspace(host: TabsFixtures.host, client: helper.client, activity: TabActivityStore(url: nil))
        let herdr = MultiplexerChoice(mux: 2, name: "herdr", route: .init(mux: 2, key: "herdr"))
        workspace.multiplexers = [herdr]
        workspace.choice = herdr
        model.insert(workspace)
        let navigator = SpacesNavigator(model: model)
        let destination = try XCTUnwrap(NewSpaceDestination.all(model.workspaces, host: workspace.id).first)
        async let made = navigator.makeSpace(destination)
        try await TestSupport.eventually { helper.methods.contains("terminals.create") }
        XCTAssertEqual(navigator.creatingSpace, [workspace.id])
        do {
            _ = try await navigator.makeSpace(destination)
            XCTFail("a second one while the first is being made")
        } catch { XCTAssertNotNil(error as? TabsFailure) }
        workspace.apply(fresh.topology)
        let tab = try await made
        XCTAssertEqual(tab.space, SpaceRef(host: workspace.id, key: "herdr:new"))
        XCTAssertEqual(navigator.creatingSpace, [])
        XCTAssertEqual(helper.methods, ["backends.create", "terminals.create"], "no entities.rename")
    }

    /// New space's Multiplexer: the host's installed ones, the shown one picked; another one says Create switches the host.
    func testTheFormsMultiplexerChoice() {
        let herdr = MultiplexerChoice(mux: 2, name: "herdr", route: .init(mux: 2, key: "herdr"))
        let tmux = MultiplexerChoice(mux: 1, name: "tmux", route: .init(mux: 1, key: "tmux"), version: "3.6a",
                                     warning: MultiplexerChoice.tmuxWarning)
        let options = NewSpaceMultiplexers(choices: [herdr, tmux], shown: tmux)
        XCTAssertEqual(options.chosen(nil), tmux, "the one the host shows")
        XCTAssertEqual(options.chosen("herdr"), herdr)
        XCTAssertEqual(options.chosen("native"), tmux, "never offered, so never picked")
        XCTAssertNil(options.note(for: tmux, host: "mba2"))
        XCTAssertEqual(options.note(for: herdr, host: "mba2"),
                       "mba2 shows one multiplexer’s spaces at a time. Create switches it from tmux to herdr, as Multiplexer in its details does.")
        let workspace = MobileWorkspace(host: ai, activity: TabActivityStore(url: nil))
        workspace.choice = herdr
        XCTAssertEqual(NewSpaceMultiplexers(workspace).choices, [herdr], "detected before the list was kept")
        XCTAssertEqual(NewSpaceMultiplexers(nil).choices, [])
    }
}
