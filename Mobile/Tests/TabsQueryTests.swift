import Foundation
import SwiftUI
import XCTest
@testable import DispatchMobile

/// M2a's menu: sorting, filters, the needs-you count and the row times.
@MainActor
final class TabsQueryTests: XCTestCase {
    private func model(_ urgency: [String: TabUrgency] = [:]) -> (MobileTabs, [UInt64: String]) {
        let defaults = UserDefaults(suiteName: "tabs-query-tests")!
        defaults.removePersistentDomain(forName: "tabs-query-tests")
        let store = TabActivityStore(url: nil)
        let model = MobileTabs(activity: store, defaults: defaults)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let other = TabsHost(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!, name: "ai", tint: .purple, home: "/home/alex")
        let mine = TabsFixtures.app()
        let theirs = TopologySketch(backend: 1, first: 700, spaces: [
            .init(key: "herdr:curves", name: "curves", tabs: [
                .init(key: "herdr:curves:1", name: "codex", panes: [.init(key: "p:codex", cwd: "/home/alex/curves", agent: "s9")]),
                .init(key: "herdr:curves:2", name: "btop", panes: [.init(key: "p:btop", cwd: "/home/alex")]),
            ]),
        ])
        for (key, minutes) in [("p:claude", 1.0), ("p:dev", 5), ("p:zsh1", 30), ("p:docs", 50)] {
            store.note(host: TabsFixtures.host.id, key: key, at: base.addingTimeInterval(-minutes * 60))
        }
        store.note(host: other.id, key: "p:codex", at: base.addingTimeInterval(-3 * 60))
        let first = MobileWorkspace(host: TabsFixtures.host, activity: store, now: { base })
        first.apply(mine.topology)
        let second = MobileWorkspace(host: other, activity: store, now: { base })
        second.apply(theirs.topology)
        model.insert(first)
        model.insert(second)
        var keys: [UInt64: String] = [:]
        for (key, id) in mine.ids { keys[id] = key }
        for (key, id) in theirs.ids { keys[id] = key }
        model.urgency = { _, terminal in keys[terminal].flatMap { urgency[$0] } }
        return (model, keys)
    }

    func testActivitySortPutsUnseenTabsLast() {
        let (model, _) = model()
        XCTAssertEqual(model.rows.map(\.tab.ref.key),
                       ["herdr:app:1", "herdr:curves:1", "herdr:app:2", "herdr:app:3", "herdr:docs:1", "herdr:curves:2"])
    }

    func testNameAndHostSorts() {
        let (model, _) = model()
        model.query.sort = .name
        XCTAssertEqual(model.rows.map(\.tab.name), ["btop", "claude", "codex", "dev", "zsh", "zsh"])
        XCTAssertEqual(model.rows.suffix(2).map { $0.space?.name }, ["app", "docs"], "same names by space")
        model.query.sort = .host
        XCTAssertEqual(model.rows.map(\.host.name), ["ai", "ai", "mba2", "mba2", "mba2", "mba2"])
        XCTAssertEqual(model.rows.prefix(2).map(\.tab.name), ["codex", "btop"], "by activity within a host")
    }

    func testFilters() {
        let (model, _) = model(["p:dev": .needsYou, "p:codex": .working])
        model.query.filter = .chats
        XCTAssertEqual(Set(model.rows.map(\.tab.name)), ["claude", "codex"])
        model.query.filter = .terminals
        XCTAssertEqual(Set(model.rows.map(\.tab.name)), ["dev", "zsh", "btop"])
        model.query.filter = .needsYou
        XCTAssertEqual(model.rows.map(\.tab.name), ["dev"])
        XCTAssertTrue(model.query.filtering)
        model.query.filter = .all
        XCTAssertFalse(model.query.filtering)
    }

    /// A chat tab's time is its agent's newest record (what Agents shows) when that is later than the last change the
    /// phone saw in the tab; a terminal tab's is only what the phone saw. The rows and the Activity sort use it.
    func testChatTabsTakeTheirAgentsTime() throws {
        let (model, keys) = model()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let agents = ["p:codex": base, "p:claude": base.addingTimeInterval(-600), "p:dev": base]
        model.agentActivity = { _, terminal in keys[terminal].flatMap { agents[$0] } }
        XCTAssertEqual(model.rows.map(\.tab.ref.key),
                       ["herdr:curves:1", "herdr:app:1", "herdr:app:2", "herdr:app:3", "herdr:docs:1", "herdr:curves:2"])
        XCTAssertEqual(model.rows.first?.activity, base, "codex's newest record")
        let claude = try XCTUnwrap(model.tab(TabRef(host: TabsFixtures.host.id, key: "herdr:app:1")))
        XCTAssertEqual(model.activity(of: claude), base.addingTimeInterval(-60), "the later of the two")
        let dev = try XCTUnwrap(model.tab(TabRef(host: TabsFixtures.host.id, key: "herdr:app:2")))
        XCTAssertEqual(model.activity(of: dev), base.addingTimeInterval(-300), "no agent: what the phone saw")
        XCTAssertEqual(model.activity(of: model.space(claude.space)!), base.addingTimeInterval(-60))
    }

    /// With `terminals.activity` a terminal tab's time is the server's (a tmux window's activity) when that is later than
    /// what the phone saw; a chat tab takes the later of that and its agent's newest record. The Activity sort follows.
    func testServerTimesDateTerminalTabsAndAgentsTakeTheLater() throws {
        let (model, keys) = model()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let ms = { (date: Date) in UInt64(date.timeIntervalSince1970 * 1000) }
        let mine = try XCTUnwrap(model.workspace(TabsFixtures.host.id))
        let theirs = try XCTUnwrap(model.workspaces.first { $0.id != TabsFixtures.host.id })
        mine.applyServerActivity([
            TabsServerActivity(node: 1, key: "herdr:app:3", time_ms: ms(base)),
            TabsServerActivity(node: 2, key: "herdr:app:1", time_ms: ms(base.addingTimeInterval(-120))),
            TabsServerActivity(node: 3, key: "herdr:app:2", time_ms: ms(base.addingTimeInterval(-3600))),
            TabsServerActivity(node: 4, key: "herdr:gone:1", time_ms: ms(base)),
        ])
        theirs.applyServerActivity([TabsServerActivity(node: 5, key: "herdr:curves:2", time_ms: ms(base.addingTimeInterval(-30)))])
        model.agentActivity = { _, terminal in keys[terminal] == "p:claude" ? base.addingTimeInterval(-10) : nil }
        let tab = { (key: String) in model.tab(TabRef(host: TabsFixtures.host.id, key: key)) }
        XCTAssertEqual(model.activity(of: try XCTUnwrap(tab("herdr:app:3"))), base, "the server's time")
        XCTAssertEqual(model.activity(of: try XCTUnwrap(tab("herdr:app:2"))), base.addingTimeInterval(-300),
                       "an older server time leaves what the phone saw")
        XCTAssertEqual(model.activity(of: try XCTUnwrap(tab("herdr:app:1"))), base.addingTimeInterval(-10), "the agent's, later")
        XCTAssertEqual(model.rows.map(\.tab.ref.key),
                       ["herdr:app:3", "herdr:app:1", "herdr:curves:2", "herdr:curves:1", "herdr:app:2", "herdr:docs:1"])
        // A later snapshot keeps the server's time (it is kept by key, not on the row).
        mine.apply(TabsFixtures.app(first: 40).topology)
        XCTAssertEqual(model.activity(of: try XCTUnwrap(tab("herdr:app:3"))), base)
    }

    /// The tree's spaces follow the same menu: a filter keeps the spaces with a matching tab.
    func testSpaceRowsFollowTheMenu() {
        let (model, _) = model(["p:codex": .needsYou])
        XCTAssertEqual(model.spaceRows.map(\.space.name), ["app", "curves", "docs"])
        model.query.filter = .needsYou
        XCTAssertEqual(model.spaceRows.map(\.space.name), ["curves"])
        model.query.filter = .terminals
        XCTAssertEqual(model.rows(in: model.space(SpaceRef(host: TabsFixtures.host.id, key: "herdr:app"))!).map(\.tab.name), ["dev", "zsh"])
    }

    /// Dots: a tab shows its most urgent pane, a space its most urgent tab; the back pill counts waiting tabs elsewhere.
    func testDotsAndNeedsYouCount() throws {
        let (model, _) = model(["p:zsh1": .unseen, "p:zsh2": .needsYou, "p:claude": .working, "p:codex": .needsYou])
        let zsh = try XCTUnwrap(model.tab(TabRef(host: TabsFixtures.host.id, key: "herdr:app:3")))
        XCTAssertEqual(model.urgency(of: zsh), .needsYou)
        XCTAssertEqual(model.urgency(of: model.space(zsh.space)!), .needsYou)
        XCTAssertEqual(model.needsYou(), 2)
        XCTAssertEqual(model.needsYou(excluding: zsh.ref), 1)
        XCTAssertGreaterThan(TabUrgency.needsYou, .working)
        XCTAssertGreaterThan(TabUrgency.working, .unseen)
    }

    /// The menu and the tree toggle are kept on the device.
    func testMenuIsRemembered() {
        let defaults = UserDefaults(suiteName: "tabs-menu-tests")!
        defaults.removePersistentDomain(forName: "tabs-menu-tests")
        let first = MobileTabs(activity: TabActivityStore(url: nil), defaults: defaults)
        first.query = TabsQuery(sort: .host, filter: .chats)
        first.tree = true
        let second = MobileTabs(activity: TabActivityStore(url: nil), defaults: defaults)
        XCTAssertEqual(second.query, TabsQuery(sort: .host, filter: .chats))
        XCTAssertTrue(second.tree)
    }

    /// The remembered menu of an older or newer build: a missing or unknown value takes its default, the other stays.
    func testAMenuOfAnotherShapeKeepsWhatItCanRead() throws {
        XCTAssertEqual(try JSONDecoder().decode(TabsQuery.self, from: Data(#"{"sort":"name"}"#.utf8)),
                       TabsQuery(sort: .name, filter: .all))
        XCTAssertEqual(try JSONDecoder().decode(TabsQuery.self, from: Data(#"{"sort":"recent","filter":"chats"}"#.utf8)),
                       TabsQuery(sort: .activity, filter: .chats))
    }

    /// New space (M7a) chooses its host before the first frame: the one asked for while it is listed, else the first
    /// connected one, else the first.
    func testNewSpaceChoosesItsHostBeforeTheFirstFrame() {
        let helper = ScriptedHelper.scripted { _ in nil }
        defer { helper.close() }
        let offline = MobileWorkspace(host: TabsHost(id: UUID(), name: "a", tint: .blue), activity: TabActivityStore(url: nil))
        let online = MobileWorkspace(host: TabsHost(id: UUID(), name: "b", tint: .blue), client: helper.client,
                                     activity: TabActivityStore(url: nil))
        XCTAssertEqual(NewSpaceSheet.initialHost([offline, online], asked: offline.id), offline.id)
        XCTAssertEqual(NewSpaceSheet.initialHost([offline, online], asked: UUID()), online.id, "asked for a host not listed")
        XCTAssertEqual(NewSpaceSheet.initialHost([offline, online], asked: nil), online.id)
        XCTAssertEqual(NewSpaceSheet.initialHost([offline], asked: nil), offline.id)
        XCTAssertNil(NewSpaceSheet.initialHost([], asked: nil))
    }

    /// New tab goes to the last space opened on the phone, else the most active one, on a connected host.
    func testRecentSpace() {
        let (model, _) = model()
        XCTAssertNil(model.recentSpace, "no connected host")
        let helper = ScriptedHelper.scripted { _ in nil }
        defer { helper.close() }
        model.workspace(TabsFixtures.host.id)?.connect(helper.client)
        XCTAssertEqual(model.recentSpace?.name, "app")
        model.visited(SpaceRef(host: TabsFixtures.host.id, key: "herdr:docs"))
        XCTAssertEqual(model.recentSpace?.name, "docs")
    }

    /// Messages' times: now, the time today, Yesterday, the weekday, a date.
    func testTimeLabels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_GB")
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 9, minute: 40))!
        func label(_ seconds: TimeInterval) -> String? {
            TabsTime.label(now.addingTimeInterval(-seconds), now: now, calendar: calendar, locale: locale)
        }
        XCTAssertNil(TabsTime.label(nil, now: now))
        XCTAssertEqual(label(20), "now")
        XCTAssertEqual(label(9 * 60), "9:31")
        XCTAssertEqual(label(12 * 3600), "Yesterday")
        XCTAssertEqual(label(3 * 86400), "Thu")
        XCTAssertEqual(label(30 * 86400), "18/09/2026")
    }
}

/// M7a's folder times ("2h ago", "Yesterday", "Mon").
final class TabsFolderTimeTests: XCTestCase {
    func testAgoLabels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 15, minute: 0))!
        func ago(_ seconds: TimeInterval) -> String? {
            TabsTime.ago(now.addingTimeInterval(-seconds), now: now, calendar: calendar, locale: Locale(identifier: "en_GB"))
        }
        XCTAssertEqual(ago(30), "now")
        XCTAssertEqual(ago(12 * 60), "12m ago")
        XCTAssertEqual(ago(2 * 3600 + 100), "2h ago")
        XCTAssertEqual(ago(20 * 3600), "Yesterday")
        XCTAssertEqual(ago(6 * 86400), "Mon")
    }
}
