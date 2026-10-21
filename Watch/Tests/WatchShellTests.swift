import SwiftUI
import XCTest
@testable import DispatchWatch

/// The app shell's pure parts: times, tints, the notices' words, the notification route and the debug arguments, and
/// the root rendering every scripted phone.
@MainActor
final class WatchShellTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    // MARK: Times

    func testRelativeTimesAbbreviateAsWatchListsDo() {
        XCTAssertEqual(WatchTime.relative(ago(30), now: now), "now")
        XCTAssertEqual(WatchTime.relative(ago(5 * 60 + 20), now: now), "5m")
        XCTAssertEqual(WatchTime.relative(ago(59 * 60), now: now), "59m")
        XCTAssertEqual(WatchTime.relative(ago(2 * 3600 + 59), now: now), "2h")
        XCTAssertEqual(WatchTime.relative(ago(3 * 86400), now: now), "3d")
        XCTAssertEqual(WatchTime.relative(ago(15 * 86400), now: now), "2w")
        XCTAssertEqual(WatchTime.relative(ago(400 * 86400), now: now), "1y")
        XCTAssertEqual(WatchTime.relative(ago(3 * 365 * 86400), now: now), "3y")
    }

    /// A time ahead of the watch's clock (the phone's clock runs ahead) reads as now, never a negative.
    func testAFutureTimeReadsAsNow() {
        XCTAssertEqual(WatchTime.relative(now.addingTimeInterval(90), now: now), "now")
        XCTAssertEqual(WatchTime.relative(now.addingTimeInterval(86400 * 400), now: now), "now")
        XCTAssertEqual(WatchTime.ago(now.addingTimeInterval(600), now: now), "just now")
    }

    func testAgoSpellsTheNoticesTimes() {
        XCTAssertEqual(WatchTime.ago(ago(20), now: now), "just now")
        XCTAssertEqual(WatchTime.ago(ago(25 * 60), now: now), "25 min ago")
        XCTAssertEqual(WatchTime.ago(ago(130 * 60), now: now), "2 hr ago")
        XCTAssertEqual(WatchTime.ago(ago(30 * 3600), now: now), "1 day ago")
        XCTAssertEqual(WatchTime.ago(ago(3 * 86400), now: now), "3 days ago")
    }

    // MARK: Tints

    func testHostTintsParseFromThePhonesHex() {
        XCTAssertEqual(Color(watchHex: "#C98BD9"), Color(.sRGB, red: 0xC9 / 255, green: 0x8B / 255, blue: 0xD9 / 255))
        XCTAssertEqual(Color(watchHex: "#6fb7a8"), Color(.sRGB, red: 0x6F / 255, green: 0xB7 / 255, blue: 0xA8 / 255))
        XCTAssertEqual(Color(watchHex: "#000000"), Color(.sRGB, red: 0, green: 0, blue: 0))
    }

    /// Nil (a host not reached yet) and anything but `#RRGGBB` draw grey.
    func testAnUnreadableTintIsGrey() {
        for hex in [nil, "", "C98BD9", "#C98BD", "#C98BD9FF", "#GGGGGG", "red"] {
            XCTAssertEqual(Color(watchHex: hex), .gray, hex ?? "nil")
        }
    }

    func testHostMarksUseTheSystemsGlyph() {
        XCTAssertEqual(WatchHostMark.symbol("macos"), "apple.logo")
        XCTAssertEqual(WatchHostMark.symbol("linux"), "server.rack")
        XCTAssertNil(WatchHostMark.symbol(nil))
        XCTAssertNil(WatchHostMark.symbol("plan9"))
    }

    func testDotsAreThePhonesColours() {
        XCTAssertEqual(WatchDots.color(.unread), WatchDots.needsYou)
        XCTAssertEqual(WatchDots.color(.working), WatchDots.working)
        XCTAssertNil(WatchDots.color(nil))
        XCTAssertNil(WatchDots.color(.unknown))
        XCTAssertEqual(WatchDots.unseen, WatchDots.needsYou)
    }

    // MARK: Notices

    func testEveryNoticeSaysWhatToDo() {
        let since = ago(25 * 60)
        XCTAssertEqual(WatchNotice.waiting.content(now: now),
                       WatchNoticeContent(symbol: "iphone.radiowaves.left.and.right", title: "Waiting for your iPhone",
                                          detail: "Keep it nearby with Dispatch installed.", caution: false))
        XCTAssertEqual(WatchNotice.unreachable(since: since).content(now: now),
                       WatchNoticeContent(symbol: "iphone.slash", title: "iPhone out of reach", detail: "Updated 25 min ago",
                                          short: "Updated 25 min ago"))
        XCTAssertEqual(WatchNotice.phoneLocked.content(now: now),
                       WatchNoticeContent(symbol: "lock.fill", title: "Unlock your iPhone",
                                          detail: "Dispatch can't reach your hosts while it's locked."))
        XCTAssertEqual(WatchNotice.openPhone.content(now: now),
                       WatchNoticeContent(symbol: "iphone", title: "Open Dispatch on your iPhone",
                                          detail: "It can't read its trusted host keys.", short: "Open Dispatch on iPhone"))
        XCTAssertEqual(WatchNotice.phoneOffline.content(now: now),
                       WatchNoticeContent(symbol: "wifi.slash", title: "iPhone offline", detail: "Hosts connect when it's back online."))
        XCTAssertEqual(WatchNotice.noHosts.content(now: now),
                       WatchNoticeContent(symbol: "server.rack", title: "No hosts", detail: "Add a host on your iPhone.",
                                          short: "Add a host on your iPhone", caution: false))
        XCTAssertEqual(WatchNotice.stale(since: ago(3 * 3600)).content(now: now),
                       WatchNoticeContent(symbol: "clock", title: "Updated 3 hr ago", detail: "Open Dispatch on your iPhone to update.",
                                          caution: false))
    }

    /// The scripted phones' notices, as the root shows them.
    func testEachScenarioHasItsNotice() {
        let expected: [ScriptedWatchLink.Scenario: WatchNotice?] = [
            .demo: nil, .empty: .noHosts, .unreachable: .unreachable(since: ago(25 * 60)), .locked: nil, .waiting: .waiting,
        ]
        for scenario in ScriptedWatchLink.Scenario.allCases {
            let now = now
            let model = WatchModel(link: ScriptedWatchLink(scenario: scenario, now: { now }), now: { now })
            XCTAssertEqual(model.notice(at: now), expected[scenario] ?? nil, scenario.rawValue)
        }
    }

    // MARK: Routing

    func testARouteIsTakenOnce() {
        let router = WatchRouter()
        XCTAssertNil(router.take())
        let key = WatchConversationKey(host: WatchFixtures.lab, node: "term_4")
        router.open(key)
        XCTAssertEqual(router.pending, key)
        XCTAssertEqual(router.take(), key)
        XCTAssertNil(router.pending)
        XCTAssertNil(router.take())
    }

    /// The newest tap wins over one not yet taken.
    func testALaterTapReplacesAPendingOne() {
        let router = WatchRouter()
        router.open(WatchConversationKey(host: WatchFixtures.lab, node: "term_4"))
        router.open(WatchConversationKey(host: WatchFixtures.studio, node: "tmux:s:$1:%3"))
        XCTAssertEqual(router.take(), WatchConversationKey(host: WatchFixtures.studio, node: "tmux:s:$1:%3"))
    }

    /// The debug arguments name a conversation as `host/node`; the node keeps any later slash, the host must be a UUID
    /// as the phone's `userInfo` requires.
    func testDebugArgumentsNameAConversation() {
        XCTAssertEqual(WatchNotifications.key(argument: "\(WatchFixtures.studio)/tmux:s:$1:%3"),
                       WatchConversationKey(host: WatchFixtures.studio, node: "tmux:s:$1:%3"))
        XCTAssertEqual(WatchNotifications.key(argument: "\(WatchFixtures.lab)/a/b"), WatchConversationKey(host: WatchFixtures.lab, node: "a/b"))
        XCTAssertNil(WatchNotifications.key(argument: "studio/term_4"))
        XCTAssertNil(WatchNotifications.key(argument: "\(WatchFixtures.lab)/"))
        XCTAssertNil(WatchNotifications.key(argument: WatchFixtures.lab))
    }

    func testTheNotificationCategoryIsThePhones() {
        XCTAssertEqual(WatchNotifications.category.identifier, "agent")
        XCTAssertTrue(WatchNotifications.category.actions.isEmpty)
    }

    func testDebugShowArgumentsOpenSpacesScreens() {
        XCTAssertEqual(WatchRouter.Show(argument: "spaces"), .spaces(host: nil))
        XCTAssertEqual(WatchRouter.Show(argument: "spaces:\(WatchFixtures.lab)"), .spaces(host: WatchFixtures.lab))
        XCTAssertEqual(WatchRouter.Show(argument: "space:\(WatchFixtures.studio)/tmux:s:$1"),
                       .space(WatchSpaceRoute(host: WatchFixtures.studio, space: "tmux:s:$1")))
        XCTAssertEqual(WatchRouter.Show(argument: "tab:\(WatchFixtures.studio)/tmux:s:$1:@6"),
                       .tab(WatchTabRoute(host: WatchFixtures.studio, tab: "tmux:s:$1:@6")))
        XCTAssertNil(WatchRouter.Show(argument: "agents"))
        XCTAssertNil(WatchRouter.Show(argument: "tab:nothing"))
    }

    /// `simctl launch … -DispatchWatchScripted <value>` reaches the model through the process arguments.
    func testTheScriptedLaunchArgumentPicksTheScenario() {
        func scenario(_ value: String) -> ScriptedWatchLink.Scenario? {
            WatchModel.scripted(environment: [:], arguments: ["DispatchWatch", "-DispatchWatchScripted", value])
        }
        XCTAssertEqual(scenario("1"), .demo)
        XCTAssertEqual(scenario("locked"), .locked)
        XCTAssertEqual(scenario("waiting"), .waiting)
        XCTAssertNil(scenario("0"))
        XCTAssertEqual(WatchModel.app(environment: [:], arguments: ["DispatchWatch", "-DispatchWatchScripted", "unreachable"])
            .notice(at: .now).map { if case .unreachable = $0 { true } else { false } }, true)
    }

    // MARK: Rendering

    /// The root draws for every scripted phone (a smoke test: lists render through UIKit, so the image is not compared).
    func testTheRootRendersEveryScenario() {
        for scenario in ScriptedWatchLink.Scenario.allCases {
            let now = now
            let model = WatchModel(link: ScriptedWatchLink(scenario: scenario, now: { now }), now: { now })
            let renderer = ImageRenderer(content: WatchRoot(model: model, router: WatchRouter()).frame(width: 205, height: 251))
            XCTAssertNotNil(renderer.cgImage, scenario.rawValue)
        }
    }

    func testNoticeBannersRender() {
        let notices: [WatchNotice] = [.waiting, .unreachable(since: ago(60)), .phoneLocked, .openPhone, .phoneOffline, .noHosts,
                                      .stale(since: ago(3600))]
        for notice in notices {
            for compact in [false, true] {
                let banner = WatchNoticeBanner(content: notice.content(now: now), compact: compact).frame(width: 190)
                XCTAssertNotNil(ImageRenderer(content: banner).cgImage, "\(notice)")
            }
        }
    }
}
