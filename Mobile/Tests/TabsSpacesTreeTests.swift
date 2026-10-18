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
}
