import Foundation
import SwiftUI
import XCTest
@testable import DispatchMobile

/// P1's filter, the needs-you count, a tab's line and the row times.
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

    /// The filters: Agents keeps the tabs running one, Needs you the ones waiting for the user.
    func testFilters() {
        let (model, _) = model(["p:dev": .needsYou, "p:codex": .working])
        let entries = model.workspaces.flatMap { workspace in workspace.spaces.flatMap { model.rows(in: $0) } }
        XCTAssertEqual(Set(entries.filter { $0.matches(.agents) }.map(\.tab.name)), ["claude", "codex"])
        XCTAssertEqual(entries.filter { $0.matches(.needsYou) }.map(\.tab.name), ["dev"])
        XCTAssertEqual(entries.filter { $0.matches(.all) }.count, 6)
        model.query.filter = .needsYou
        XCTAssertTrue(model.query.filtering)
        model.query.filter = .all
        XCTAssertFalse(model.query.filtering)
    }

    /// A space's tabs come in server order (the Mac strip's), whatever their times.
    func testASpacesRowsAreInServerOrder() throws {
        let (model, _) = model()
        let app = try XCTUnwrap(model.space(SpaceRef(host: TabsFixtures.host.id, key: "herdr:app")))
        XCTAssertEqual(model.rows(in: app).map(\.tab.ref.key), ["herdr:app:1", "herdr:app:2", "herdr:app:3"])
    }

    /// A chat tab's time is its agent's newest record (what Agents shows) when that is later than the last change the
    /// phone saw in the tab; a terminal tab's is only what the phone saw. The rows use it.
    func testChatTabsTakeTheirAgentsTime() throws {
        let (model, keys) = model()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let agents = ["p:codex": base, "p:claude": base.addingTimeInterval(-600), "p:dev": base]
        model.agentActivity = { _, terminal in keys[terminal].flatMap { agents[$0] } }
        let curves = try XCTUnwrap(model.workspaces.first { $0.id != TabsFixtures.host.id }?.spaces.first)
        XCTAssertEqual(model.rows(in: curves).first?.activity, base, "codex's newest record")
        let claude = try XCTUnwrap(model.tab(TabRef(host: TabsFixtures.host.id, key: "herdr:app:1")))
        XCTAssertEqual(model.activity(of: claude), base.addingTimeInterval(-60), "the later of the two")
        let dev = try XCTUnwrap(model.tab(TabRef(host: TabsFixtures.host.id, key: "herdr:app:2")))
        XCTAssertEqual(model.activity(of: dev), base.addingTimeInterval(-300), "no agent: what the phone saw")
        XCTAssertEqual(model.activity(of: model.space(claude.space)!), base.addingTimeInterval(-60))
    }

    /// With `terminals.activity` a terminal tab's time is the server's (a tmux window's activity) when that is later than
    /// what the phone saw; a chat tab takes the later of that and its agent's newest record.
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
        XCTAssertEqual(model.activity(of: try XCTUnwrap(model.workspace(theirs.id)?.tab("herdr:curves:2"))), base.addingTimeInterval(-30))
        // A later snapshot keeps the server's time (it is kept by key, not on the row).
        mine.apply(TabsFixtures.app(first: 40).topology)
        XCTAssertEqual(model.activity(of: try XCTUnwrap(tab("herdr:app:3"))), base)
    }

    /// A tab's line on the watch (`TabsTabLine`): the agent's status, else the program unless the tab is already named
    /// after it; never the host or the folder.
    func testATabsLineIsItsAgentOrProgramNeverWhereItRuns() throws {
        let (model, _) = model()
        let tab = { (key: String) in try XCTUnwrap(model.tab(TabRef(host: TabsFixtures.host.id, key: key))) }
        let claude = try tab("herdr:app:1"), dev = try tab("herdr:app:2"), zsh = try tab("herdr:app:3")
        let quiet: @MainActor (UUID, UInt64) -> TabsStatus? = { _, _ in nil }
        let working = TabsStatus(text: "Editing Sidebar.tsx", since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(TabsTabLine.line(claude, label: "claude", status: { _, _ in working }), "Editing Sidebar.tsx",
                       "the watch gets the words, never a time that changes every second")
        XCTAssertEqual(TabsTabLine.line(claude, label: "Make billing webhook retries idempotent", status: quiet), "claude")
        XCTAssertNil(TabsTabLine.line(claude, label: "claude", status: quiet), "Named after its program already")
        XCTAssertNil(TabsTabLine.line(zsh, label: "zsh", status: quiet), "A bare shell: one line, no folder")
        XCTAssertNil(TabsTabLine.line(dev, label: "dev", status: quiet), "A renamed tab names no program")
    }

    /// P2's line: the agent's state from Chat; a terminal's own title; else the program; else the folder.
    func testASpaceScreensLineSaysWhatTheTabIsDoing() throws {
        let (model, keys) = model()
        model.status = { _, terminal in keys[terminal] == "p:claude" ? TabsStatus(text: "Allow cargo test --workspace?") : nil }
        model.paneTitle = { _, key in key == "p:zsh2" ? "vite ready · localhost:5173" : nil }
        let app = try XCTUnwrap(model.space(SpaceRef(host: TabsFixtures.host.id, key: "herdr:app")))
        XCTAssertEqual(model.rows(in: app).map { SpaceTabRow.line($0, model: model)?.text },
                       ["Allow cargo test --workspace?", "~/src/app", "vite ready · localhost:5173"])
        let docs = try XCTUnwrap(model.space(SpaceRef(host: TabsFixtures.host.id, key: "herdr:docs")))
        XCTAssertEqual(model.rows(in: docs).map { SpaceTabRow.line($0, model: model)?.text }, ["~/src/docs"], "a shell: its folder")
    }

    /// The agent's mark: Chat's key when it knows, else the bound process's or the topology's names.
    func testTheAgentMarkComesFromChatOrTheNames() throws {
        let (model, keys) = model()
        let claude = try XCTUnwrap(model.tab(TabRef(host: TabsFixtures.host.id, key: "herdr:app:1")))
        let dev = try XCTUnwrap(model.tab(TabRef(host: TabsFixtures.host.id, key: "herdr:app:2")))
        let codex = try XCTUnwrap(model.workspaces.first { $0.id != TabsFixtures.host.id }?.tab("herdr:curves:1"))
        XCTAssertEqual(model.agent(of: claude), "claude", "the tab's name")
        XCTAssertEqual(model.agent(of: codex), "codex")
        XCTAssertNil(model.agent(of: dev), "no agent")
        model.agentKey = { _, terminal in keys[terminal] == "p:claude" ? "pi" : nil }
        XCTAssertEqual(model.agent(of: claude), "pi", "Chat's key first")
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

    /// The filter and the OFFLINE group's state are kept on the device; "Show offline hosts" is on by default.
    func testFilterAndOfflineGroupAreRemembered() {
        let defaults = UserDefaults(suiteName: "tabs-menu-tests")!
        defaults.removePersistentDomain(forName: "tabs-menu-tests")
        let first = MobileTabs(activity: TabActivityStore(url: nil), defaults: defaults)
        XCTAssertTrue(first.showOffline)
        XCTAssertFalse(first.offlineFolded)
        first.query = TabsQuery(filter: .agents)
        first.showOffline = false
        first.offlineFolded = true
        let second = MobileTabs(activity: TabActivityStore(url: nil), defaults: defaults)
        XCTAssertEqual(second.query, TabsQuery(filter: .agents))
        XCTAssertFalse(second.showOffline)
        XCTAssertTrue(second.offlineFolded)
    }

    /// The remembered filter of an older build ("chats" is Agents now) or one this build does not know (All); a
    /// missing one is All, other keys are left.
    func testAMenuOfAnotherShapeKeepsWhatItCanRead() throws {
        XCTAssertEqual(try JSONDecoder().decode(TabsQuery.self, from: Data(#"{"other":1}"#.utf8)), TabsQuery())
        XCTAssertEqual(try JSONDecoder().decode(TabsQuery.self, from: Data(#"{"filter":"chats"}"#.utf8)), TabsQuery(filter: .agents))
        XCTAssertEqual(try JSONDecoder().decode(TabsQuery.self, from: Data(#"{"filter":"later"}"#.utf8)), TabsQuery())
        XCTAssertEqual(try JSONDecoder().decode(TabsQuery.self, from: Data(#"{"filter":"needsYou"}"#.utf8)),
                       TabsQuery(filter: .needsYou))
    }

    /// Needs you counts and filters live rows only, as the app's badge does: a host not reached now says nothing.
    func testNeedsYouIsTheLiveRows() throws {
        let (model, _) = model(["p:dev": .needsYou, "p:codex": .needsYou])
        XCTAssertEqual(model.needsYou(), 2)
        let ai = try XCTUnwrap(model.workspaces.first { $0.id != TabsFixtures.host.id })
        var offline = ai.host
        offline.state = .offline
        ai.update(host: offline)
        XCTAssertEqual(model.needsYou(), 1, "the offline host's waiting agent is not counted")
        let rows = model.workspaces.flatMap { workspace in workspace.spaces.flatMap { model.rows(in: $0) } }
        XCTAssertEqual(rows.filter { $0.matches(.needsYou) }.map(\.tab.name), ["dev"], "nor listed under Needs you")
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
