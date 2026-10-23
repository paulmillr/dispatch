import UserNotifications
import XCTest
@testable import DispatchMobile

/// Notifications (G5): which agent events notify under which switches, what the banner says and sounds like, the badge,
/// for the background refresh and for what arrives while the app is open.
@MainActor
final class AgentAlertsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_001_000)
    private let studio = ResilienceFixture.host("studio")

    private func settings() -> MobileSettings {
        let name = "alerts-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let settings = MobileSettings(defaults: UserDefaults(suiteName: name)!)
        settings.backgroundRefresh = true
        return settings
    }

    private func summary(busy: Bool = false, attention: String? = nil, waiting: Bool = false, preview: String? = nil) -> ChatConversationSummary {
        ChatConversationSummary(busy: busy, attention: attention, preview: preview, finished: !busy && preview != nil, waiting: waiting)
    }

    // MARK: Policy

    func testEventsBetweenTwoLooks() {
        typealias Alerts = AgentAlerts
        XCTAssertEqual(Alerts.event(previous: summary(busy: true), current: summary(waiting: true)), .needsYou(question: true))
        XCTAssertEqual(Alerts.event(previous: nil, current: summary(attention: "permission")), .needsYou(question: false))
        XCTAssertNil(Alerts.event(previous: summary(waiting: true), current: summary(waiting: true)), "still waiting: said already")
        XCTAssertEqual(Alerts.event(previous: summary(busy: true), current: summary(preview: "Done.")), .finished)
        XCTAssertNil(Alerts.event(previous: summary(), current: summary(preview: "Done.")), "idle before: nothing ended")
        XCTAssertNil(Alerts.event(previous: nil, current: summary(preview: "Done.")), "first sight is no event")
        XCTAssertEqual(Alerts.event(previous: summary(busy: true), current: nil), .stopped)
        XCTAssertNil(Alerts.event(previous: summary(), current: nil), "an idle agent leaving is no failure")
        XCTAssertNil(Alerts.event(previous: summary(busy: true), current: summary(busy: true)))
    }

    func testTheSwitchesGateEventsButQuestionsAlwaysNotify() {
        let off = AgentAlerts.Policy(needsYou: false, finished: false, failed: false)
        XCTAssertTrue(AgentAlerts.notifies(.needsYou(question: true), off), "approvals and questions always notify")
        XCTAssertFalse(AgentAlerts.notifies(.needsYou(question: false), off))
        XCTAssertFalse(AgentAlerts.notifies(.finished, off))
        XCTAssertFalse(AgentAlerts.notifies(.stopped, off))
        let on = AgentAlerts.Policy()
        for event in [AgentAlerts.Event.needsYou(question: false), .finished, .stopped] { XCTAssertTrue(AgentAlerts.notifies(event, on)) }
        XCTAssertEqual(AgentAlerts.badge(waiting: 3, policy: on), 3)
        XCTAssertEqual(AgentAlerts.badge(waiting: 3, policy: off.with(badge: false)), 0)
    }

    func testTheBannerSaysWhatSettingsAllow() {
        let key = ChatConversationKey(host: studio.id, node: "tmux:fixture:5")
        let full = AgentAlerts.notification(.finished, key: key, tab: "docs", host: "studio", text: "Docs are rebuilt.", policy: .init())
        XCTAssertEqual(full.title, "docs · studio")
        XCTAssertEqual(full.body, "Docs are rebuilt.")
        XCTAssertEqual(full.id, studio.id.uuidString + ":tmux:fixture:5", "one per conversation")
        let quiet = AgentAlerts.notification(.needsYou(question: true), key: key, tab: "docs", host: "studio", text: "Run it?",
                                             policy: .init(sound: .none, text: false))
        XCTAssertEqual(quiet.body, "Needs you", "only which conversation needs you")
        XCTAssertNil(quiet.content.sound)
        let stopped = AgentAlerts.notification(.stopped, key: key, tab: "docs", host: "studio", text: "Half done", policy: .init())
        XCTAssertEqual(stopped.body, "Stopped while working")
        XCTAssertEqual(full.content.sound, .default)
        let bell = AgentAlerts.notification(.finished, key: key, tab: "docs", host: "studio", text: nil, policy: .init(sound: .shipsBell))
        XCTAssertEqual(bell.body, "Finished")
        XCTAssertEqual(bell.content.sound, UNNotificationSound(named: UNNotificationSoundName(NotificationSound.bellFile)))
    }

    /// With previews hidden the lock screen says what happened in neutral words, per event.
    func testEachEventHasItsOwnPlaceholder() {
        let key = ChatConversationKey(host: studio.id, node: "tmux:fixture:5")
        let categories = Dictionary(uniqueKeysWithValues: RefreshNotification.categories.map { ($0.identifier, $0.hiddenPreviewsBodyPlaceholder) })
        for (event, placeholder) in [(AgentAlerts.Event.needsYou(question: true), "An agent needs you"),
                                     (.finished, "An agent finished"), (.stopped, "An agent stopped")] {
            let notification = AgentAlerts.notification(event, key: key, tab: "docs", host: "studio", text: nil, policy: .init())
            XCTAssertEqual(categories[notification.content.categoryIdentifier], placeholder)
        }
        XCTAssertEqual(AgentAlerts.notification(.needsYou(question: false), key: key, tab: "docs", host: "studio", text: nil,
                                                policy: .init()).content.categoryIdentifier, "agent", "the watch's long look")
    }

    func testTheShipsBellIsWrittenForTheNotificationCentre() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sounds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("old".utf8).write(to: folder.appendingPathComponent("ships-bell.wav").creatingFolder())
        XCTAssertTrue(NotificationSound.installBell(in: folder))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [NotificationSound.bellFile],
                       "an older synthesis goes")
        XCTAssertNotEqual(NotificationSound.bellName(Data([1])), NotificationSound.bellName(Data([2])), "named by its samples")
        let data = try Data(contentsOf: folder.appendingPathComponent(NotificationSound.bellFile))
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertLessThan(Double(data.count) / (44_100 * 2), 30, "under iOS's 30 s for a notification sound")
        XCTAssertTrue(NotificationSound.installBell(in: folder), "kept")
    }

    // MARK: Background refresh

    /// The fixture's topology with the billing agent gone from its terminal.
    private func topologyWithoutBilling() throws -> HelperTopology {
        let data = try JSONEncoder().encode(HostFixture.topology())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        for index in nodes.indices where nodes[index]["key"] as? String == ResilienceFixture.billingAgent { nodes[index]["agent"] = nil }
        object["nodes"] = nodes
        return try JSONDecoder().decode(HelperTopology.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func run(settings: MobileSettings, cache: HostCache, result: HostRefresh, notifier: FakeNotifier) async -> [RefreshNotification] {
        let now = now, studio = studio
        let refresh = BackgroundRefresh(identifier: "yachts.dispatch.mobile.refresh", scheduler: RecordingScheduler(), notifier: notifier,
                                        settings: settings, cache: cache, markers: ChatMarkers(store: ChatMarkerMemoryStore()),
                                        clock: { now }, hosts: { [studio] }, source: FakeRefreshSource(results: [studio.id: result]))
        return await refresh.run()
    }

    /// Both agents were working: docs finished its turn, billing's agent left its terminal mid-turn.
    private func cacheWithBothWorking() -> HostCache {
        let cache = HostCache(url: nil)
        var entry = ResilienceFixture.entry()
        entry.conversations[ResilienceFixture.docsAgent] = .init(summary(busy: true, preview: "Rebuilding"))
        entry.conversations[ResilienceFixture.billingAgent] = .init(summary(busy: true, preview: "Migrating"))
        cache.replace(entry, for: studio.id)
        return cache
    }

    private func finishedAndStopped() throws -> HostRefresh {
        var result = HostRefresh(hello: ResilienceFixture.hello(), following: "tmux", topology: try topologyWithoutBilling())
        result.conversations = [ResilienceFixture.docsAgent: summary(preview: "Docs are rebuilt.")]
        result.texts = [ResilienceFixture.docsAgent: "All pages built.\nDocs are rebuilt.\n"]
        return result
    }

    func testTheRefreshNotifiesFinishedAndStopped() async throws {
        let notifier = FakeNotifier()
        let posted = await run(settings: settings(), cache: cacheWithBothWorking(), result: try finishedAndStopped(), notifier: notifier)
        XCTAssertEqual(posted.map(\.body).sorted(), ["Docs are rebuilt.", "Stopped while working"])
        XCTAssertEqual(Set(posted.map(\.key.node)), [ResilienceFixture.docsAgent, ResilienceFixture.billingAgent])
        XCTAssertEqual(notifier.badges, [0], "nothing waits for the user")
    }

    /// A stop notifies once: the row whose agent left goes from the cache, so the next run has nothing to compare.
    func testAStopNotifiesOnce() async throws {
        let cache = cacheWithBothWorking(), settings = settings()
        let first = await run(settings: settings, cache: cache, result: try finishedAndStopped(), notifier: FakeNotifier())
        XCTAssertEqual(first.count, 2)
        XCTAssertNil(cache.entry(studio.id)?.conversations[ResilienceFixture.billingAgent], "recorded as gone")
        let again = await run(settings: settings, cache: cache, result: try finishedAndStopped(), notifier: FakeNotifier())
        XCTAssertTrue(again.isEmpty, "said once")
    }

    /// A detached tab's agent goes on working: the refresh reads no detached terminal, and that is no stop.
    func testADetachedTabIsNoStop() async throws {
        let data = try JSONEncoder().encode(HostFixture.topology())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        for index in nodes.indices where nodes[index]["key"] as? String == ResilienceFixture.billingAgent { nodes[index]["detached"] = true }
        object["nodes"] = nodes
        var result = HostRefresh(hello: ResilienceFixture.hello(), following: "tmux",
                                 topology: try JSONDecoder().decode(HelperTopology.self, from: JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(result.topology?.nodes.first { $0.key == ResilienceFixture.billingAgent }?.detached, true)
        result.conversations = [ResilienceFixture.docsAgent: summary(busy: true)]
        let cache = cacheWithBothWorking()
        let posted = await run(settings: settings(), cache: cache, result: result, notifier: FakeNotifier())
        XCTAssertTrue(posted.isEmpty)
        XCTAssertNotNil(cache.entry(studio.id)?.conversations[ResilienceFixture.billingAgent], "kept while its agent is bound")
    }

    /// The badge counts the hosts the run reached: an offline host's last rows are not counted.
    func testTheBadgeCountsReachedHostsOnly() async throws {
        let offline = ResilienceFixture.host("mba2", order: 1)
        let cache = HostCache(url: nil)
        var waiting = ResilienceFixture.entry()
        waiting.conversations[ResilienceFixture.billingAgent] = .init(summary(waiting: true))
        cache.replace(waiting, for: offline.id)
        var result = HostRefresh(hello: ResilienceFixture.hello(), following: "tmux", topology: HostFixture.topology())
        result.conversations = [ResilienceFixture.billingAgent: summary(waiting: true)]
        let notifier = FakeNotifier(), now = now, studio = studio
        let refresh = BackgroundRefresh(identifier: "yachts.dispatch.mobile.refresh", scheduler: RecordingScheduler(), notifier: notifier,
                                        settings: settings(), cache: cache, markers: ChatMarkers(store: ChatMarkerMemoryStore()),
                                        clock: { now }, hosts: { [studio, offline] }, source: FakeRefreshSource(results: [studio.id: result]))
        _ = await refresh.run()
        XCTAssertEqual(notifier.badges, [1])
        XCTAssertEqual(AgentAlerts.waiting([summary(waiting: true), summary(attention: "permission"), summary(busy: true)]), 2)
    }

    func testTheSwitchesSilenceTheRefresh() async throws {
        let settings = settings()
        settings.notifyFinished = false
        settings.notifyFailed = false
        let posted = await run(settings: settings, cache: cacheWithBothWorking(), result: try finishedAndStopped(), notifier: FakeNotifier())
        XCTAssertTrue(posted.isEmpty)
    }

    /// A row the helper left out while the agent is still on its terminal is no stop.
    func testARowLeftOutIsNoStop() async throws {
        var result = HostRefresh(hello: ResilienceFixture.hello(), following: "tmux", topology: HostFixture.topology())
        result.conversations = [ResilienceFixture.docsAgent: summary(busy: true)]
        let posted = await run(settings: settings(), cache: cacheWithBothWorking(), result: result, notifier: FakeNotifier())
        XCTAssertTrue(posted.isEmpty)
    }

    func testQuestionsNotifyWithNeedsYouOffAndTheBadgeCountsThem() async throws {
        let settings = settings()
        settings.notifyNeedsYou = false
        settings.notificationText = false
        var result = HostRefresh(hello: ResilienceFixture.hello(), following: "tmux", topology: HostFixture.topology())
        result.conversations = [ResilienceFixture.billingAgent: summary(waiting: true, preview: "Run the migration?"),
                                ResilienceFixture.docsAgent: summary(attention: "permission")]
        let notifier = FakeNotifier()
        let posted = await run(settings: settings, cache: HostCache(url: nil), result: result, notifier: notifier)
        XCTAssertEqual(posted.map(\.key.node), [ResilienceFixture.billingAgent], "the question; the attention is off")
        XCTAssertEqual(posted.first?.body, "Needs you", "Show message text off")
        XCTAssertEqual(notifier.badges, [2], "both wait for the user")
        settings.notificationBadge = false
        _ = await run(settings: settings, cache: HostCache(url: nil), result: result, notifier: notifier)
        XCTAssertEqual(notifier.badges.last, 0)
    }

    // MARK: While the app is open

    func testArrivalsPostUnlessOnScreenMutedOrNotAllowed() async {
        let notifier = FakeNotifier()
        let alerts = AgentAlerts(notifier: notifier, settings: settings())
        let key = ChatConversationKey(host: studio.id, node: ResilienceFixture.docsAgent)
        await alerts.arrived(key, tab: "docs", host: "studio", previous: summary(busy: true), current: summary(preview: "Built.\nDone."), muted: false)
        XCTAssertEqual(notifier.posted.map(\.body), ["Done."])
        alerts.onScreen.insert(key)
        await alerts.arrived(key, tab: "docs", host: "studio", previous: summary(busy: true), current: summary(preview: "Again."), muted: false)
        alerts.onScreen.remove(key)
        await alerts.arrived(key, tab: "docs", host: "studio", previous: summary(busy: true), current: summary(preview: "Again."), muted: true)
        notifier.isAuthorized = false
        notifier.grants = false
        await alerts.arrived(key, tab: "docs", host: "studio", previous: summary(busy: true), current: summary(preview: "Again."), muted: false)
        XCTAssertEqual(notifier.posted.count, 1, "on screen, muted, or not allowed: no banner")
        XCTAssertEqual(notifier.requests, 1, "asked once")
        await alerts.arrived(key, tab: "docs", host: "studio", previous: summary(busy: true), current: summary(preview: "Again."), muted: false)
        XCTAssertEqual(notifier.requests, 1, "not asked again")
        alerts.badge(waiting: 4)
        alerts.badge(waiting: 4)
        alerts.badge(waiting: 2)
        XCTAssertEqual(notifier.badges, [4, 2], "set only when it changes")
    }

    /// Notifications while the app is open ask for permission the first time one would post, without Background
    /// refresh ever turned on.
    func testTheFirstBannerAsksForPermission() async {
        let notifier = FakeNotifier(authorized: false, grants: true)
        let settings = settings()
        settings.backgroundRefresh = false
        let alerts = AgentAlerts(notifier: notifier, settings: settings)
        await alerts.arrived(ChatConversationKey(host: studio.id, node: "tmux:fixture:5"), tab: "docs", host: "studio",
                             previous: summary(), current: summary(waiting: true), muted: false)
        XCTAssertEqual(notifier.requests, 1)
        XCTAssertEqual(notifier.posted.count, 1)
        let denied = AgentAlerts(notifier: FakeNotifier(authorized: false, grants: false), settings: settings)
        let allowed = await denied.ensureAuthorized()
        XCTAssertFalse(allowed, "the Notifications screen shows the Settings app's switch")
    }

    /// A stop counts only when the agent stays away (a restart rebinds it) and never for the user's own close.
    func testStopsWaitForRebindingAndSkipTheUsersClose() async {
        let notifier = FakeNotifier()
        let alerts = AgentAlerts(notifier: notifier, settings: settings())
        alerts.stopGrace = .zero
        let key = ChatConversationKey(host: studio.id, node: "tmux:fixture:5")
        var back = true
        alerts.stillGone = { _ in !back }
        await alerts.arrived(key, tab: "docs", host: "studio", previous: summary(busy: true), current: nil, muted: false)
        XCTAssertTrue(notifier.posted.isEmpty, "the agent came back within the grace")
        back = false
        alerts.userClosed([key])
        await alerts.arrived(key, tab: "docs", host: "studio", previous: summary(busy: true), current: nil, muted: false)
        XCTAssertTrue(notifier.posted.isEmpty, "the user closed it from the phone")
        let other = ChatConversationKey(host: studio.id, node: "tmux:fixture:10")
        await alerts.arrived(other, tab: "billing", host: "studio", previous: summary(busy: true), current: nil, muted: false)
        XCTAssertEqual(notifier.posted.map(\.body), ["Stopped while working"])
    }

    /// Only live rows are compared; a row gone counts when its host is connected and its agent left the terminal, not
    /// when the host went offline or the tab was detached.
    func testArrivalsCompareLiveRowsOnly() throws {
        let topology = HostFixture.topology()
        let node = try XCTUnwrap(topology.nodes.first { $0.key == ResilienceFixture.docsAgent })
        let binding = try XCTUnwrap(node.agent)
        func row(_ summary: ChatConversationSummary, stale: Bool = false) -> ChatConversation {
            ChatConversation(key: ChatConversationKey(host: studio.id, node: node.key), terminal: node.id, hostName: "studio", name: "docs",
                             space: nil, spaceNode: nil, cwd: nil, binding: binding, summary: summary,
                             urgency: .running, muted: false, unread: false, stale: stale)
        }
        let connected = [studio.id: ChatHostSnapshot(id: studio.id, name: "studio", link: .connected, topology: topology)]
        let changed = ChatConversations.arrivals(from: [row(summary(busy: true))], to: [row(summary(preview: "Done."))], hosts: connected)
        XCTAssertEqual(changed.count, 1)
        XCTAssertTrue(ChatConversations.arrivals(from: [row(summary(busy: true), stale: true)], to: [row(summary(preview: "Done."))],
                                                 hosts: connected).isEmpty, "cached rows coming back live are no arrival")
        XCTAssertTrue(ChatConversations.arrivals(from: [row(summary(busy: true))], to: [], hosts: connected).isEmpty,
                      "the agent is still on its terminal (a detached tab)")
        let gone = [studio.id: ChatHostSnapshot(id: studio.id, name: "studio", link: .connected, topology: try topologyWithoutDocs())]
        XCTAssertEqual(ChatConversations.arrivals(from: [row(summary(busy: true))], to: [], hosts: gone).count, 1)
        let offline = [studio.id: ChatHostSnapshot(id: studio.id, name: "studio", link: .disconnected, topology: try topologyWithoutDocs())]
        XCTAssertTrue(ChatConversations.arrivals(from: [row(summary(busy: true))], to: [], hosts: offline).isEmpty)
    }

    private func topologyWithoutDocs() throws -> HelperTopology {
        let data = try JSONEncoder().encode(HostFixture.topology())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["nodes"] = (object["nodes"] as? [[String: Any]])?.filter { $0["key"] as? String != ResilienceFixture.docsAgent }
        return try JSONDecoder().decode(HelperTopology.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

private extension URL {
    /// Itself, with its folder made.
    func creatingFolder() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}

private extension AgentAlerts.Policy {
    func with(badge: Bool) -> Self {
        var policy = self
        policy.badge = badge
        return policy
    }
}
