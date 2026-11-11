import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// The phone's tab header (B7): Back in its own circle, then one capsule with the host's disc, the title and host ·
/// folder under it (one line each), which opens the tab's sheet, and the mode button. Rendered in
/// a window of the test host's scene at each width, the column the stack's bar is in (`tabsColumnWidth`), with the
/// app's Chat header (`TabsContent.chatHeader`: `ChatHeaderControls` with the disc as the tab's menu) and the stack's
/// navigator (`tabsNavigator`), as `MobileComposition` and `MobileRoot` give the tab screen.
@MainActor
final class TabsHeaderTests: XCTestCase {
    /// The iPhone SE and mini (the narrowest), the iPhone 17 and 17 Pro, the Air, and the folded Duo's cover screen
    /// (466 points wide, `MobileSplit`).
    static let widths: [CGFloat] = [375, 402, 420, 466]
    static let short = "ciphers"
    static let long = "See how we can speed-up sha3 without writing new code yet, and keep the tests green."

    /// The title capsule holds the title and the host line under it, one line each whatever the title's length (a long
    /// one truncates; VoiceOver reads all of it), and stays in the bar.
    func testTheTitleCapsuleHoldsTheTitleAndTheHostLine() async throws {
        AccessibilityLabelTests.enableAccessibility()
        for width in Self.widths {
            var heights: [CGFloat] = []
            for title in [Self.short, Self.long] {
                let name = "\(title == Self.short ? "short" : "long"), \(width)"
                let (model, tab, space) = headerModel(tab: title)
                let (window, bar) = try assertInTheBar(screen(model, tab: tab, space: space, width: width), name, width: width)
                defer { window.isHidden = true }
                var labels: [String: CGRect] = [:]
                try await TestSupport.eventually(timeout: .seconds(3), diagnostic: "\(name): \(labels.keys.sorted())") {
                    labels = Self.labels(in: window)
                    return Self.capsule(labels, title: title) != nil
                }
                let capsule = try XCTUnwrap(Self.capsule(labels, title: title))
                XCTAssertTrue(capsule.label.contains("mba2"), "\(name): the host line, \(capsule.label)")
                XCTAssertNil(labels["Tab menu"], "\(name): the capsule is the menu's way in, no disc beside Back")
                XCTAssertLessThanOrEqual(capsule.frame.maxX, bar.convert(bar.bounds, to: window).maxX, "\(name)")
                heights.append(capsule.frame.height)
                try write(window, "header-\(title == Self.short ? "short" : "long")-\(Int(width))")
            }
            XCTAssertEqual(heights[0], heights[1], accuracy: 1, "\(width): one line each, long title or short")
        }
    }

    /// The title capsule: its accessibility label begins with the title (the host line follows it).
    private static func capsule(_ labels: [String: CGRect], title: String) -> (label: String, frame: CGRect)? {
        labels.first { $0.key.hasPrefix(title + ",") || $0.key == title }.map { ($0.key, $0.value) }
    }

    /// The subtitle's folder is the path's last component, the home folder "~".
    func testTheSubtitleNamesTheFolder() {
        let host = TabsFixtures.host
        XCTAssertEqual(TabScreenHeader.folder("/Users/alex/src/ciphers", host: host), "ciphers")
        XCTAssertNil(TabScreenHeader.distinct("ciphers", from: "Ciphers"), "Never the folder under a title that names it")
        XCTAssertEqual(TabScreenHeader.distinct("ciphers", from: "Speed up sha3"), "ciphers")
        XCTAssertEqual(TabScreenHeader.distinct("ciphers", from: nil), "ciphers")
        XCTAssertEqual(TabScreenHeader.folder("/Users/alex", host: host), "~")
        XCTAssertEqual(TabScreenHeader.folder("/srv/app/", host: host), "app")
        XCTAssertEqual(TabScreenHeader.folder("/", host: host), "/")
        XCTAssertNil(TabScreenHeader.folder(nil, host: host))
    }

    /// The menu's pane picker offers the panes the segment can show: Chat shows a pane running an agent, so a split
    /// with one agent offers no pick on Chat and both panes on Terminal; with two agents the pick follows Chat.
    func testThePanePickerOffersThePanesTheSegmentShows() throws {
        let model = MobileTabs(activity: TabActivityStore(url: nil), deviceState: SpacesDeviceState(url: nil))
        let sketch = TopologySketch(spaces: [.init(key: "herdr:ciphers", name: "ciphers", tabs: [
            .init(key: "herdr:ciphers:1", name: "split", renamed: true, panes: [
                .init(key: "p:shell", cwd: "/Users/alex/src/ciphers"),
                .init(key: "p:claude", cwd: "/Users/alex/src/ciphers", agent: "s1"),
            ]),
        ])])
        model.sync([TabsHostInput(host: TabsFixtures.host, client: nil, topology: sketch.topology)])
        let tab = try XCTUnwrap(model.workspace(TabsFixtures.host.id)?.tabs.first)
        XCTAssertEqual(TabScreenHeader.panes(tab, segment: .terminal).map(\.key), ["p:shell", "p:claude"])
        XCTAssertEqual(TabScreenHeader.panes(tab, segment: .chat).map(\.key), ["p:claude"], "no pick on Chat")
        XCTAssertEqual(tab.agentPane?.key, "p:claude")
    }

    /// Back names the screen it returns to and reads the waiting conversations as its value.
    func testBackReadsWhereItGoesAndWhoWaits() {
        XCTAssertEqual(TabsBackDisc.value(0), "")
        XCTAssertEqual(TabsBackDisc.value(1), "1 conversation needs you")
        XCTAssertEqual(TabsBackDisc.value(2), "2 conversations need you")
    }

    /// The tab's screen as the app builds it: `TabsContent` with the Chat header hooks, the stack's navigator.
    private func screen(_ model: MobileTabs, tab: TabRef, space: SpaceRef, width: CGFloat,
                        session: MobileChatSession = TabsHeaderTests.session()) -> some View {
        var content = TabsContent(terminal: { _, _ in AnyView(Text("terminal")) }, chat: { _, _ in AnyView(Text("chat")) })
        content.chatHeader { _, _ in session }
        return TabScreen(model: model, ref: tab, path: .constant([.space(space), .tab(tab)]), content: content)
            .environment(\.tabsColumnWidth, width)
            .environment(\.tabsNavigator, SpacesNavigator(model: model))
    }

    private static func session() -> MobileChatSession {
        MobileChatSession(key: ChatConversationKey(host: TabsFixtures.host.id, node: "p:ciphers"), hostName: "mba2",
                          drafts: ChatDraftRepository(store: ChatDraftMemoryStore()), outbox: ChatOutbox(store: ChatOutboxMemoryStore()))
    }

    private func headerModel(tab: String) -> (MobileTabs, TabRef, SpaceRef) {
        let model = MobileTabs(activity: TabActivityStore(url: nil), deviceState: SpacesDeviceState(url: nil))
        let sketch = TopologySketch(spaces: [.init(key: "herdr:ciphers", name: "ciphers", tabs: [
            .init(key: "herdr:ciphers:1", name: tab, renamed: true,
                  panes: [.init(key: "p:ciphers", cwd: "/Users/alex/src/ciphers", agent: "s1")]),
        ])])
        model.sync([TabsHostInput(host: TabsFixtures.host, client: nil, topology: sketch.topology)])
        let ref = model.workspace(TabsFixtures.host.id)!.tabs[0].ref
        return (model, ref, SpaceRef(host: TabsFixtures.host.id, key: "herdr:ciphers"))
    }

    /// `DISPATCH_TABS_PNG` (`TEST_RUNNER_DISPATCH_TABS_PNG` through xcodebuild) names a folder for the renders.
    private func write(_ window: UIWindow, _ name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["DISPATCH_TABS_PNG"] else { return }
        let image = UIGraphicsImageRenderer(bounds: CGRect(x: 0, y: 0, width: window.bounds.width, height: 160)).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try image.pngData()?.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }

    /// Each accessibility element's frame in the window by its label.
    private static func labels(in window: UIWindow) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        for element in AccessibilityLabelTests.elements(in: window) {
            guard let label = element.accessibilityLabel, frames[label] == nil else { continue }
            frames[label] = window.convert(element.accessibilityFrame, from: window.screen.coordinateSpace)
        }
        return frames
    }

    /// The screen in a window `width` points wide; the bar keeps every item: no "More" button (the overflow menu's
    /// "…"). The window stays showing for the caller to probe and hide.
    private func assertInTheBar(_ screen: some View, _ name: String, width: CGFloat,
                                file: StaticString = #filePath, line: UInt = #line) throws -> (UIWindow, UINavigationBar) {
        let scene = try XCTUnwrap(TestSupport.windowScene())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 700)
        window.rootViewController = UIHostingController(rootView: NavigationStack { screen })
        window.isHidden = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        let bar = try XCTUnwrap(views(window).first { $0 is UINavigationBar } as? UINavigationBar, name, file: file, line: line)
        let more = views(bar).filter { $0.accessibilityLabel == "More" && !$0.isHidden && $0.alpha > 0 }
        XCTAssertTrue(more.isEmpty, "\(name): the bar overflowed into its menu", file: file, line: line)
        return (window, bar)
    }
}

/// The mode button (B7): Back, the title capsule, the mode button at the trailing end, no capsule under the header.
extension TabsHeaderTests {
    /// A tap goes where the Mac strip's button goes: Terminal to Chat with an agent, else to Files; Chat and Files back
    /// to Terminal. The glyph is the bubble on Chat or toward it; on Files the shown mode's (Files' modes are in its
    /// menu, no capsule names them), filled where the symbol has a filled form.
    func testTheModeButtonGoesWhereTheMacsDoes() {
        let all = TabSegment.allCases, shell: [TabSegment] = [.terminal, .files]
        XCTAssertEqual(TabModeButton.next(shown: .terminal, agent: true, segments: all), .chat)
        XCTAssertEqual(TabModeButton.next(shown: .terminal, agent: false, segments: all), .files)
        XCTAssertEqual(TabModeButton.next(shown: .terminal, agent: false, segments: shell), .files)
        XCTAssertEqual(TabModeButton.next(shown: .chat, agent: true, segments: all), .terminal)
        XCTAssertEqual(TabModeButton.next(shown: .files, agent: true, segments: all), .terminal)
        XCTAssertNil(TabModeButton.next(shown: .terminal, agent: false, segments: [.terminal]))
        XCTAssertEqual(TabModeButton.symbol(shown: .chat, agent: true), "dispatch.chat")
        XCTAssertEqual(TabModeButton.symbol(shown: .terminal, agent: true), "dispatch.chat")
        XCTAssertEqual(TabModeButton.symbol(shown: .terminal, agent: false), "folder")
        XCTAssertEqual(TabModeButton.symbol(shown: .files, agent: true), "folder")
        XCTAssertEqual(TabModeButton.symbol(shown: .files, agent: true, filesMode: .review), "pencil.and.list.clipboard")
        XCTAssertEqual(TabModeButton.symbol(shown: .files, agent: false, filesMode: .commits), "clock.arrow.circlepath")
        XCTAssertEqual(TabModeButton.filled("dispatch.chat"), "dispatch.chat.fill")
        XCTAssertEqual(TabModeButton.filled("folder"), "folder.fill")
        XCTAssertEqual(TabModeButton.filled("clock.arrow.circlepath"), "clock.arrow.circlepath", "No filled clock")
    }

    /// Short or long title, with or without the needs-you badge, on Chat (the app's Chat controls, and conversation
    /// mode's waveform in the mode button's place) or Terminal: Back leads, the title capsule after it, the mode button
    /// (or waveform) at the trailing edge, all in the bar (no "…" overflow menu), and no capsule under it.
    func testTheHeaderNeverOverflowsTheBar() async throws {
        AccessibilityLabelTests.enableAccessibility()
        let shared = MobileVoiceConversation.shared
        let voice = MobileVoiceConversation(listener: ScriptedListener(), speaker: ScriptedSpeaker())
        MobileVoiceConversation.shared = voice
        defer { voice.stop(); MobileVoiceConversation.shared = shared }
        for width in Self.widths {
            for title in [Self.short, Self.long] {
                for (waiting, segment, listening) in [(0, TabSegment.chat, false), (2, .terminal, false), (2, .chat, true)] {
                    let name = "\(title == Self.short ? "short" : "long"), \(waiting) waiting, \(segment)\(listening ? " listening" : ""), \(width)"
                    let (model, tab, space) = headerModel(tab: title)
                    model.needsYouCount = { _ in waiting }
                    model.segments[tab] = segment
                    let session = Self.session()
                    if listening { voice.start(session) } else { voice.stop() }
                    let trailing = listening ? "End conversation mode" : "Mode"
                    let (window, bar) = try assertInTheBar(screen(model, tab: tab, space: space, width: width, session: session), name, width: width)
                    defer { window.isHidden = true }
                    let edges = bar.convert(bar.bounds, to: window)
                    var labels: [String: CGRect] = [:]
                    try await TestSupport.eventually(timeout: .seconds(3), diagnostic: "\(name): \(labels.keys.sorted())") {
                        labels = Self.labels(in: window)
                        return labels["Back to ciphers"] != nil && Self.capsule(labels, title: title) != nil && labels[trailing] != nil
                    }
                    XCTAssertNil(labels["View"], "\(name): no capsule under the header")
                    XCTAssertEqual(labels["Mode"] == nil, listening,
                                   "\(name): the waveform takes the mode button's place")
                    let back = try XCTUnwrap(labels["Back to ciphers"]), capsule = try XCTUnwrap(Self.capsule(labels, title: title))
                    let mode = try XCTUnwrap(labels[trailing]), shown = capsule.frame
                    XCTAssertGreaterThanOrEqual(back.minX, edges.minX, "\(name): \(back)")
                    XCTAssertLessThanOrEqual(back.maxX, shown.minX, "\(name): the capsule after Back, \(back) \(shown)")
                    XCTAssertLessThan(shown.maxX, mode.minX, "\(name): the capsule before the mode button")
                    // A system bar item: the bar sizes it (36 points on iOS 26 and 27); the waveform's disc is 44.
                    XCTAssertEqual(mode.width, 40, accuracy: 8, "\(name): the mode button, \(mode)")
                    XCTAssertLessThanOrEqual(mode.maxX, edges.maxX, "\(name): \(mode)")
                    XCTAssertGreaterThan(mode.minX, edges.midX, "\(name): the mode button at the trailing edge, \(mode)")
                    XCTAssertTrue(capsule.label.contains("mba2"), "\(name): the host line, \(capsule.label)")
                    try write(window, "header-\(title == Self.short ? "short" : "long")-\(segment)\(listening ? "-listening" : "")-\(Int(width))")
                }
            }
        }
    }
}
