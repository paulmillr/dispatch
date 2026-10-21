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

    // MARK: Rendering

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
