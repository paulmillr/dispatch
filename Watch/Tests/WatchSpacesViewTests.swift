import SwiftUI
import XCTest
@testable import DispatchWatch

/// Spaces on the watch: the words of its headers and rows, where a row leads, and the screens rendering every scripted
/// phone.
@MainActor
final class WatchSpacesViewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func model(_ scenario: ScriptedWatchLink.Scenario = .demo) -> WatchModel {
        let now = now
        return WatchModel(link: ScriptedWatchLink(scenario: scenario, now: { now }), now: { now })
    }

    private func host(_ state: WatchHostState, problem: String? = nil, blocked: WatchHostBlock? = nil,
                      lastConnected: Date? = nil) -> WatchHost {
        WatchHost(id: WatchFixtures.lab, name: "lab", order: 0, state: state, problem: problem, blocked: blocked, lastConnected: lastConnected)
    }

    // MARK: Hosts

    func testTheHeaderSaysTheHostsState() {
        XCTAssertNil(SpacesText.state(host(.connected)))
        XCTAssertEqual(SpacesText.state(host(.connecting)), "Connecting…")
        XCTAssertEqual(SpacesText.state(host(.offline)), "Offline")
        XCTAssertEqual(SpacesText.state(host(.unknown)), "Offline")
    }

    /// The demo's pi: its key is behind Face ID, so the phone's screen is needed; it says when it last connected.
    func testABlockedHostSaysOpenThePhoneAndWhenItLastConnected() throws {
        let pi = try XCTUnwrap(model().host(WatchFixtures.pi))
        let problem = try XCTUnwrap(SpacesText.problem(pi, now: now))
        XCTAssertEqual(problem.symbol, "iphone")
        XCTAssertEqual(problem.text, "Open Dispatch on your iPhone to connect pi.")
        XCTAssertEqual(problem.detail, "Last connected 2 hr ago")
    }

    func testAnOfflineHostShowsItsProblem() throws {
        let problem = try XCTUnwrap(SpacesText.problem(host(.offline, problem: "Connection refused", lastConnected: now.addingTimeInterval(-3 * 86400)), now: now))
        XCTAssertEqual(problem.symbol, "exclamationmark.triangle.fill")
        XCTAssertEqual(problem.text, "Connection refused")
        XCTAssertEqual(problem.detail, "Last connected 3 days ago")
    }

    /// A connected host has nothing to say, even with a problem left from before; an offline one without a problem says
    /// nothing either (its grey dot and "Offline" do).
    func testAConnectedHostHasNoProblemLine() {
        XCTAssertNil(SpacesText.problem(host(.connected, problem: "Connection refused"), now: now))
        XCTAssertNil(SpacesText.problem(host(.offline), now: now))
    }

    /// Under "Unlock your iPhone" every host blocked by the lock would repeat it: they say nothing more. A host blocked
    /// for another reason still says so.
    func testLockedHostsDoNotRepeatTheLockedNotice() throws {
        let locked = host(.offline, blocked: .phoneLocked, lastConnected: now)
        XCTAssertNil(SpacesText.problem(locked, now: now, notice: .phoneLocked))
        XCTAssertEqual(SpacesText.problem(locked, now: now)?.symbol, "lock.fill")
        XCTAssertEqual(SpacesText.problem(host(.offline, blocked: .login), now: now, notice: .phoneLocked)?.text,
                       "Open Dispatch on your iPhone to connect lab.")
    }

    func testASecondHostOnTheSameMachineSaysWhere() {
        XCTAssertEqual(SpacesText.sameMachine("studio"), "Same machine as studio: its spaces show there.")
    }

    // MARK: Rows

    func testTheDemosSectionsKeepThePhonesOrder() {
        let sections = model().sections
        XCTAssertEqual(sections.map(\.host.name), ["studio", "lab", "pi"])
        XCTAssertEqual(sections[0].spaces.map(\.space.name), ["dispatch", "notes"])
        XCTAssertEqual(sections[0].spaces[0].tabs.map(\.name), ["Fix the flaky replay test", "Refactor the queue drainer", "zsh"])
    }

    func testASpacesDotIsBlueBeforeAmber() {
        let space = WatchSpace(host: WatchFixtures.lab, key: "ws_1", name: "train")
        XCTAssertNil(SpacesText.dot(space))
        XCTAssertEqual(SpacesText.dot(WatchSpace(host: space.host, key: space.key, name: space.name, working: true)), .working)
        XCTAssertEqual(SpacesText.dot(WatchSpace(host: space.host, key: space.key, name: space.name, unread: 2, working: true)), .unread)
        XCTAssertEqual(SpacesText.value(WatchSpace(host: space.host, key: space.key, name: space.name, unread: 2, working: true)), "2 unread, Working")
    }

    func testATabsDotFollowsItsUrgency() {
        func tab(_ urgency: WatchUrgency?) -> WatchTab {
            WatchTab(host: WatchFixtures.lab, space: "ws_1", key: "tab_1", name: "claude", urgency: urgency)
        }
        XCTAssertEqual(SpacesText.dot(tab(.needsYou)), .unread)
        XCTAssertEqual(SpacesText.dot(tab(.unseen)), .unread)
        XCTAssertEqual(SpacesText.dot(tab(.working)), .working)
        XCTAssertNil(SpacesText.dot(tab(nil)))
        XCTAssertNil(SpacesText.dot(tab(.unknown)))
    }

    /// Line two as the phone's: the agent's status, else the program when the name is not already it.
    func testATabsLineIsItsStatusElseItsProgram() {
        let lab = WatchFixtures.lab
        XCTAssertEqual(SpacesText.line(WatchTab(host: lab, space: "s", key: "t", name: "claude", program: "claude", status: "opus-5.5 · thinking")),
                       "opus-5.5 · thinking")
        XCTAssertEqual(SpacesText.line(WatchTab(host: lab, space: "s", key: "t", name: "train", program: "python")), "python")
        XCTAssertNil(SpacesText.line(WatchTab(host: lab, space: "s", key: "t", name: "zsh", program: "zsh")))
        XCTAssertNil(SpacesText.line(WatchTab(host: lab, space: "s", key: "t", name: "zsh", status: "")))
    }

    /// An agent's tab opens its thread; any other tab (a chat tab whose agent pane is unknown too) its own screen.
    func testATabLeadsToItsThreadOrItsScreen() {
        let lab = WatchFixtures.lab
        let agent = WatchTab(host: lab, space: "ws_1", key: "tab_2", name: "Tune", chat: true, conversation: "term_4")
        XCTAssertEqual(SpacesText.destination(agent), .thread(WatchConversationKey(host: lab, node: "term_4")))
        XCTAssertEqual(SpacesText.symbol(agent), "bubble.left.fill")
        let shell = WatchTab(host: lab, space: "ws_1", key: "tab_5", name: "htop", program: "htop")
        XCTAssertEqual(SpacesText.destination(shell), .tab(WatchTabRoute(host: lab, tab: "tab_5")))
        XCTAssertEqual(SpacesText.symbol(shell), "apple.terminal")
        let unbound = WatchTab(host: lab, space: "ws_1", key: "tab_6", name: "claude", chat: true)
        XCTAssertEqual(SpacesText.destination(unbound), .tab(WatchTabRoute(host: lab, tab: "tab_6")))
    }

    func testDeepFoldersKeepTheirLastTwoComponents() {
        XCTAssertEqual(SpacesText.folder("~"), "~")
        XCTAssertEqual(SpacesText.folder("~/src/dispatch"), "~/src/dispatch")
        XCTAssertEqual(SpacesText.folder("~/src/work/dispatch"), "…/work/dispatch")
        XCTAssertEqual(SpacesText.folder("/srv/data/models/run-7"), "…/models/run-7")
        XCTAssertNil(SpacesText.folder(""))
        XCTAssertNil(SpacesText.folder(nil))
    }

    func testATabsScreenListsWhatThePhoneKnows() throws {
        let model = model()
        let tab = try XCTUnwrap(model.tab(host: WatchFixtures.studio, key: "tmux:s:$1:@6"))
        let space = model.snapshot?.spaces.first { $0.key == tab.space && $0.host == tab.host }
        XCTAssertEqual(TabDetailScreen.facts(tab, host: model.host(tab.host), space: space, now: now), [
            TabDetailScreen.Fact(label: "System", value: "macOS 26.1"),
            TabDetailScreen.Fact(label: "Space", value: "dispatch"),
            TabDetailScreen.Fact(label: "Folder", value: "~/src/dispatch"),
            TabDetailScreen.Fact(label: "Program", value: "zsh"),
            TabDetailScreen.Fact(label: "Activity", value: "40 min ago"),
        ])
    }

    // MARK: The host screen (K6)

    /// The strip's numbers: CPU in percent, memory used and disk free in the phone's units; "—" without a reading.
    func testTheHostsStripReadsAsThePhones() throws {
        let gib: Int64 = 1_073_741_824
        XCTAssertEqual(HostStatsText.cpu(WatchHostStats(cpu: 33.6)).value, "34")
        XCTAssertEqual(HostStatsText.cpu(nil).value, "—")
        XCTAssertEqual(HostStatsText.bytes(11 * gib).value, "11")
        XCTAssertEqual(HostStatsText.bytes(11 * gib).unit, "GB")
        XCTAssertEqual(HostStatsText.bytes(gib * 15 / 2).value, "7.5")
        XCTAssertEqual(HostStatsText.bytes(gib / 2).value, "512")
        XCTAssertEqual(HostStatsText.bytes(gib / 2).unit, "MB")
        XCTAssertEqual(HostStatsText.bytes(1200 * gib).value, "1.2")
        XCTAssertEqual(HostStatsText.bytes(1200 * gib).unit, "TB")
        XCTAssertEqual(HostStatsText.bytes(nil).value, "—")
        XCTAssertEqual(HostStatsText.counts(spaces: 2, tabs: 5), "2 spaces · 5 tabs")
        XCTAssertEqual(HostStatsText.counts(spaces: 1, tabs: 1), "1 space · 1 tab")
        let stats = WatchFixtures.mockup(now: now).hosts[0].stats
        XCTAssertEqual(HostStatsText.accessibilityLabel(stats),
                       "CPU 34 percent, Memory 11 GB used, Disk 48 GB free, peak 82 percent in 15 minutes")
        XCTAssertEqual(HostStatsText.accessibilityLabel(nil), "No statistics")
        var stale = try XCTUnwrap(stats)
        stale.stale = true
        XCTAssertEqual(HostStatsText.accessibilityLabel(stale),
                       "CPU 34 percent, Memory 11 GB used, Disk 48 GB free, peak 82 percent in 15 minutes, not current")
    }

    /// The phone's stale flag travels only when set; an older phone's statistics (none) decode as current, and a gap
    /// as nil.
    func testTheStaleFlagCrossesTheWire() throws {
        let host = WatchHost(id: "h", name: "studio", order: 0, state: .connected,
                             stats: WatchHostStats(cpu: 12, history: [10, nil, 12], stale: true))
        let snapshot = WatchSnapshot(generated: now, phone: WatchPhone(), hosts: [host])
        let decoded = try XCTUnwrap(try WatchCodec.value(WatchSnapshot.self, in: try WatchCodec.message(snapshot)))
        XCTAssertEqual(decoded.hosts.first?.stats, host.stats)
        var current = host
        current.stats?.stale = false
        let older = WatchSnapshot(generated: now, phone: WatchPhone(), hosts: [current])
        let plain = try XCTUnwrap(try WatchCodec.value(WatchSnapshot.self, in: try WatchCodec.message(older)))
        XCTAssertEqual(plain.hosts.first?.stats?.stale, false)
        XCTAssertEqual(plain.hosts.first?.stats?.history, [10, nil, 12])
    }

    /// The header's state: the latency while connected, else the state; offline since a time today, a weekday this
    /// week, a date before.
    func testTheHostSaysItsLatencyOrSinceWhenItIsOffline() throws {
        var mba2 = WatchFixtures.mockup(now: now).hosts[0]
        XCTAssertEqual(HostStatsText.state(mba2), "18 ms")
        XCTAssertNil(HostStatsText.offlineSince(mba2, now: now))
        mba2.latency = 0.4
        XCTAssertEqual(HostStatsText.state(mba2), "1 ms")
        mba2.latency = nil
        XCTAssertEqual(HostStatsText.state(mba2), "Connected")
        mba2.state = .connecting
        XCTAssertEqual(HostStatsText.state(mba2), "Connecting…")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let offline = WatchFixtures.mockup(now: now, offline: true).hosts[0]
        XCTAssertEqual(HostStatsText.state(offline), "Offline")
        let since = try XCTUnwrap(offline.offlineSince)
        XCTAssertEqual(HostStatsText.offlineSince(offline, now: since.addingTimeInterval(60), calendar: calendar),
                       "Offline since " + since.formatted(date: .omitted, time: .shortened))
        XCTAssertEqual(HostStatsText.offlineSince(offline, now: since.addingTimeInterval(2 * 86_400), calendar: calendar),
                       "Offline since " + since.formatted(.dateTime.weekday(.wide)))
        XCTAssertEqual(HostStatsText.offlineSince(offline, now: since.addingTimeInterval(30 * 86_400), calendar: calendar),
                       "Offline since " + since.formatted(date: .abbreviated, time: .omitted))
        // Not known (the phone has not seen it drop since its launch): no line, whatever the last connection.
        var unknown = offline
        unknown.offlineSince = nil
        XCTAssertNotNil(unknown.lastConnected)
        XCTAssertNil(HostStatsText.offlineSince(unknown, now: since))
        var connecting = offline
        connecting.state = .connecting
        XCTAssertNil(HostStatsText.offlineSince(connecting, now: since), "connecting is not offline")
    }

    /// The sparkline skips gaps and keeps its points inside the frame.
    func testTheSparklineSkipsGaps() throws {
        let points = try XCTUnwrap(Sparkline.points([10, nil, 50, 100, 140], in: CGSize(width: 100, height: 40), ceiling: 100))
        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(points.map(\.x), [0, 50, 75, 100])
        XCTAssertTrue(points.allSatisfy { $0.y >= 3 && $0.y <= 37 })
        XCTAssertNil(Sparkline.points([5], in: CGSize(width: 100, height: 40), ceiling: 100))
    }

    // MARK: Rendering

    /// Every host of the scripted phones draws its screen (connected, offline, blocked, without statistics), and a
    /// route whose host has gone says so.
    func testEveryHostRenders() {
        for scenario in ScriptedWatchLink.Scenario.allCases {
            let model = model(scenario)
            for host in model.hosts {
                XCTAssertNotNil(render(HostScreen(model: model, route: WatchHostRoute(host: host.id))), "\(scenario) \(host.name)")
            }
            XCTAssertNotNil(render(HostScreen(model: model, route: WatchHostRoute(host: "gone"))))
        }
    }

    private func render(_ view: some View) -> CGImage? {
        ImageRenderer(content: view.frame(width: 205, height: 251)).cgImage
    }

    /// Spaces draws for every scripted phone (a smoke test; the screenshots in docs/watch.md are the visual check).
    func testSpacesRendersEveryScenario() {
        for scenario in ScriptedWatchLink.Scenario.allCases {
            XCTAssertNotNil(render(SpacesScreen(model: model(scenario), router: WatchRouter())), scenario.rawValue)
        }
    }

    /// Every space of the scripted phones draws, and a route whose space has gone says so instead of failing.
    func testEverySpaceRenders() {
        for scenario in ScriptedWatchLink.Scenario.allCases {
            let model = model(scenario)
            for space in model.sections.flatMap(\.spaces) {
                XCTAssertNotNil(render(SpaceScreen(model: model, route: WatchSpaceRoute(host: space.space.host, space: space.space.key))))
            }
            XCTAssertNotNil(render(SpaceScreen(model: model, route: WatchSpaceRoute(host: "gone", space: "gone"))))
        }
    }

    /// Every tab of the scripted phones draws, and a route whose tab has gone says so.
    func testEveryTabRenders() {
        for scenario in ScriptedWatchLink.Scenario.allCases {
            let model = model(scenario)
            for tab in model.sections.flatMap(\.spaces).flatMap(\.tabs) {
                XCTAssertNotNil(render(TabDetailScreen(model: model, route: WatchTabRoute(host: tab.host, tab: tab.key))))
            }
            XCTAssertNotNil(render(TabDetailScreen(model: model, route: WatchTabRoute(host: "gone", tab: "gone"))))
        }
    }
}
