import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// The phone's tab header (X9b): the chevron Back, the title block two lines tall (host · folder under a title that
/// fits on one line, else the title on two lines and no subtitle) and the host disc that is the tab's menu. Rendered in
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

    /// A title that fits on one line keeps "mba2 · ciphers" under it; a long one takes two lines and drops it.
    func testATitleThatFitsKeepsTheHostLineALongOneTakesTwoLines() async throws {
        AccessibilityLabelTests.enableAccessibility()
        for width in Self.widths {
            var heights: [String: CGFloat] = [:]
            for title in [Self.short, Self.long] {
                let name = "\(title == Self.short ? "short" : "long"), \(width)"
                let (model, tab, space) = headerModel(tab: title)
                let (window, _) = try assertInTheBar(screen(model, tab: tab, space: space, width: width), name, width: width)
                defer { window.isHidden = true }
                var labels: [String: CGRect] = [:]
                try await TestSupport.eventually(timeout: .seconds(3), diagnostic: "\(name): \(labels.keys.sorted())") {
                    labels = Self.labels(in: window)
                    return labels[title] != nil && labels["Tab menu"] != nil
                }
                XCTAssertEqual(labels["mba2 · ciphers"] != nil, title == Self.short, "\(name): the host line, \(labels.keys.sorted())")
                heights[title] = labels[title]?.height
                try write(window, "header-\(title == Self.short ? "short" : "long")-\(Int(width))")
            }
            let one = try XCTUnwrap(heights[Self.short]), two = try XCTUnwrap(heights[Self.long])
            XCTAssertGreaterThan(two, one * 1.6, "\(width): the long title takes two lines (\(one), \(two))")
        }
    }

    /// Short or long title, with or without the needs-you badge, on Chat (the app's Chat controls, and conversation
    /// mode's waveform in the disc's place) or Terminal: Back, the title and the trailing control stay in the bar (no
    /// "…" overflow menu), Back at the leading edge, the 44 point disc or waveform at the trailing one.
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
                    let trailing = listening ? "End conversation mode" : "Tab menu"
                    let (window, bar) = try assertInTheBar(screen(model, tab: tab, space: space, width: width, session: session), name, width: width)
                    defer { window.isHidden = true }
                    let edges = bar.convert(bar.bounds, to: window)
                    var labels: [String: CGRect] = [:]
                    try await TestSupport.eventually(timeout: .seconds(3), diagnostic: "\(name): \(labels.keys.sorted())") {
                        labels = Self.labels(in: window)
                        return labels["Back to ciphers"] != nil && labels[trailing] != nil && labels[title] != nil
                    }
                    XCTAssertEqual(labels["Tab menu"] == nil, listening, "\(name): the waveform takes the disc's place")
                    let back = try XCTUnwrap(labels["Back to ciphers"]), menu = try XCTUnwrap(labels[trailing])
                    let shown = try XCTUnwrap(labels[title])
                    // The needs-you badge reaches 6 points past the circle's upper trailing edge.
                    XCTAssertEqual(back.width, waiting > 0 ? 50 : 44, accuracy: 1, "\(name): Back is the chevron circle, \(back)")
                    // The ⋯ badge reaches 3 points past the disc's lower trailing edge.
                    XCTAssertEqual(menu.width, 44, accuracy: 3.5, "\(name): the disc, \(menu)")
                    XCTAssertGreaterThanOrEqual(back.minX, edges.minX, "\(name): \(back)")
                    XCTAssertLessThanOrEqual(menu.maxX, edges.maxX, "\(name): \(menu)")
                    XCTAssertLessThan(back.maxX, shown.minX, "\(name): the title after Back")
                    XCTAssertLessThan(shown.maxX, menu.minX, "\(name): the title before the disc")
                    XCTAssertGreaterThan(menu.minX, edges.midX, "\(name): the disc at the trailing edge, \(menu)")
                }
            }
        }
    }

    /// The subtitle's folder is the path's last component, the home folder "~".
    func testTheSubtitleNamesTheFolder() {
        let host = TabsFixtures.host
        XCTAssertEqual(TabScreenHeader.folder("/Users/alex/src/ciphers", host: host), "ciphers")
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
