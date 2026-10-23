import XCTest
@testable import DispatchMobile

/// The background refresh: scheduled 15 minutes or more ahead, nothing without the setting or permission, only hosts
/// with Chat on, one notification per conversation that newly needs the user (never for a muted one), seen markers
/// untouched, the cache updated, and a tap opening the thread.
@MainActor
final class BackgroundRefreshTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_001_000)
    private let studio = ResilienceFixture.host("studio")

    private func refresh(hosts: [HostRecord], source: FakeRefreshSource, notifier: FakeNotifier = FakeNotifier(),
                         scheduler: RecordingScheduler = RecordingScheduler(), cache: HostCache = HostCache(url: nil),
                         markers: ChatMarkers = ChatMarkers(store: ChatMarkerMemoryStore()), enabled: Bool = true) -> BackgroundRefresh {
        let settings = MobileSettings(defaults: UserDefaults(suiteName: "refresh-\(UUID().uuidString)")!)
        settings.backgroundRefresh = enabled
        let now = now
        return BackgroundRefresh(identifier: "yachts.dispatch.mobile.refresh", scheduler: scheduler, notifier: notifier,
                                 settings: settings, cache: cache, markers: markers, clock: { now }, hosts: { hosts },
                                 source: source)
    }

    /// The fixture's agents as a refresh finds them: billing waits for an approval, docs has finished.
    private func found(billing attention: String? = "approval") -> HostRefresh {
        var result = HostRefresh(hello: ResilienceFixture.hello(), following: "tmux", topology: HostFixture.topology())
        result.conversations = [
            ResilienceFixture.docsAgent: ChatConversationSummary(preview: "Docs are rebuilt.", finished: true,
                                                                 lastActivity: Date(timeIntervalSince1970: 1_800_000_900)),
            ResilienceFixture.billingAgent: ChatConversationSummary(attention: attention, preview: "Plan ready. Run the migration?",
                                                                    lastActivity: Date(timeIntervalSince1970: 1_800_000_950)),
        ]
        result.texts = [ResilienceFixture.billingAgent: "Plan ready.\n\nRun the migration?\n"]
        return result
    }

    func testSchedulesFifteenMinutesAheadAndCancelsWhenOff() {
        let scheduler = RecordingScheduler()
        let on = refresh(hosts: [studio], source: FakeRefreshSource(), scheduler: scheduler)
        on.schedule()
        XCTAssertEqual(scheduler.submitted.map(\.identifier), ["yachts.dispatch.mobile.refresh"])
        XCTAssertEqual(scheduler.submitted.first?.earliest, now.addingTimeInterval(15 * 60))
        XCTAssertGreaterThanOrEqual(BackgroundRefresh.interval, 15 * 60)

        on.settings.backgroundRefresh = false
        on.schedule()
        XCTAssertEqual(scheduler.cancelled, ["yachts.dispatch.mobile.refresh"])
        let noChat = refresh(hosts: [ResilienceFixture.host("vps", chat: false)], source: FakeRefreshSource(), scheduler: scheduler)
        noChat.schedule()
        XCTAssertEqual(scheduler.cancelled.count, 2, "no host with Chat on: nothing to refresh")
        XCTAssertEqual(scheduler.submitted.count, 1)
        XCTAssertTrue(BackgroundRefresh.identifier.hasSuffix(".refresh"))
    }

    func testDoesNothingWithoutPermissionOrTheSetting() async {
        let source = FakeRefreshSource(results: [studio.id: found()])
        let denied = FakeNotifier(authorized: false)
        let posted = await refresh(hosts: [studio], source: source, notifier: denied).run()
        XCTAssertTrue(posted.isEmpty)
        let off = await refresh(hosts: [studio], source: source, enabled: false).run()
        XCTAssertTrue(off.isEmpty)
        XCTAssertTrue(source.asked.isEmpty, "no host was even connected")
        XCTAssertTrue(denied.posted.isEmpty)
    }

    func testNotifiesConversationsThatNewlyNeedYou() async throws {
        let notifier = FakeNotifier(), scheduler = RecordingScheduler(), cache = HostCache(url: nil)
        let markers = ChatMarkers(store: ChatMarkerMemoryStore())
        markers.markSeen(host: studio.id, conversation: "fixture-5", through: 1)
        let seen = markers.document
        let vps = ResilienceFixture.host("vps", chat: false, order: 1)
        let source = FakeRefreshSource(results: [studio.id: found(), vps.id: found()])
        let task = refresh(hosts: [studio, vps], source: source, notifier: notifier, scheduler: scheduler, cache: cache,
                           markers: markers)

        let posted = await task.run()
        XCTAssertEqual(source.asked, [studio.id], "Chat off: the host is not refreshed")
        XCTAssertEqual(posted.count, 1)
        let notification = try XCTUnwrap(posted.first)
        XCTAssertEqual(notification.title, "zsh · studio", "the conversation's tab and host")
        XCTAssertEqual(notification.body, "Run the migration?", "the last line")
        XCTAssertEqual(notification.key, ChatConversationKey(host: studio.id, node: ResilienceFixture.billingAgent))
        XCTAssertEqual(RefreshNotification.key(notification.userInfo), notification.key)
        XCTAssertEqual(notifier.posted, posted)
        XCTAssertEqual(markers.document, seen, "seen markers change only when a thread opens")
        XCTAssertEqual(scheduler.submitted.count, 1, "the next run is asked for")
        XCTAssertEqual(cache.entry(studio.id)?.conversations[ResilienceFixture.billingAgent]?.attention, "approval")
        XCTAssertEqual(cache.entry(studio.id)?.topology, HostFixture.topology())

        let again = await task.run()
        XCTAssertTrue(again.isEmpty, "still waiting: already notified (the cache knows)")
        source.results[studio.id] = found(billing: nil)
        _ = await task.run()
        source.results[studio.id] = found()
        let anew = await task.run()
        XCTAssertEqual(anew.count, 1, "needs you again after it was answered")
    }

    func testAConversationTheAppAlreadyShowedAsNeedingYouIsNotNotified() async {
        let cache = HostCache(url: nil)
        cache.replace(ResilienceFixture.entry(), for: studio.id)
        let posted = await refresh(hosts: [studio], source: FakeRefreshSource(results: [studio.id: found()]), cache: cache).run()
        XCTAssertTrue(posted.isEmpty, "the cached row already needed you")
    }

    /// A host removed while the run was connected to it (Remove all data, or removing the host) gets no notification and
    /// no cache entry back; neither does any host once the setting went off during the run.
    func testChangesDuringARunWin() async {
        let cache = HostCache(url: nil), notifier = FakeNotifier()
        let source = FakeRefreshSource(results: [studio.id: found()])
        let settings = MobileSettings(defaults: UserDefaults(suiteName: "refresh-\(UUID().uuidString)")!)
        settings.backgroundRefresh = true
        var hosts = [studio]
        let task = BackgroundRefresh(identifier: "yachts.dispatch.mobile.refresh", scheduler: RecordingScheduler(),
                                     notifier: notifier, settings: settings, cache: cache,
                                     markers: ChatMarkers(store: ChatMarkerMemoryStore()), clock: { [now] in now },
                                     hosts: { hosts }, source: source)
        source.during = { hosts = [] }
        let removed = await task.run()
        XCTAssertTrue(removed.isEmpty)
        XCTAssertNil(cache.entry(studio.id), "a removed host's data does not come back")

        hosts = [studio]
        source.during = { settings.backgroundRefresh = false }
        let off = await task.run()
        XCTAssertTrue(off.isEmpty)
        XCTAssertTrue(notifier.posted.isEmpty)
        XCTAssertNil(cache.entry(studio.id))
    }

    func testMutedConversationsAreNotNotified() async {
        let markers = ChatMarkers(store: ChatMarkerMemoryStore())
        markers.setMuted(true, host: studio.id, node: ResilienceFixture.billingAgent)
        let posted = await refresh(hosts: [studio], source: FakeRefreshSource(results: [studio.id: found()]), markers: markers).run()
        XCTAssertTrue(posted.isEmpty)
    }

    func testTurningItOnAsksForPermission() async {
        let notifier = FakeNotifier(authorized: false, grants: false), scheduler = RecordingScheduler()
        let task = refresh(hosts: [studio], source: FakeRefreshSource(), notifier: notifier, scheduler: scheduler, enabled: false)
        let refused = await task.setEnabled(true)
        XCTAssertFalse(refused)
        XCTAssertFalse(task.settings.backgroundRefresh)
        XCTAssertEqual(notifier.requests, 1)
        XCTAssertTrue(scheduler.submitted.isEmpty)
        notifier.grants = true
        let allowed = await task.setEnabled(true)
        XCTAssertTrue(allowed)
        XCTAssertTrue(task.settings.backgroundRefresh)
        XCTAssertEqual(scheduler.submitted.count, 1)
        _ = await task.setEnabled(false)
        XCTAssertEqual(scheduler.cancelled.count, 2)
    }

    /// The app's source: a session that asks nothing, `chat.list` once, the previews' last lines, then disconnected.
    func testTheSourceConnectsReadsAndDisconnects() async throws {
        let helper = ScriptedHelper.scripted { request in
            guard request.method == "chat.list" else { return nil }
            return .result([["terminal": 10, "busy": false, "attention": "approval", "preview": "Plan ready.\nRun the migration?",
                             "time_ms": 1_800_000_950_000] as [String: Any],
                            ["terminal": 5, "busy": true, "attention": NSNull(), "preview": "Rebuilding", "time_ms": 1_800_000_900_000]])
        }
        let driver = ClientDriver { _ in helper }
        let hosts = ResilienceFixture.sessions([studio], driver: driver, active: false)
        let source = HostSessionsRefreshSource(hosts: hosts)
        let result = try await XCTUnwrapAsync(await source.refresh(studio, until: .now + .seconds(5)))
        XCTAssertEqual(result.conversations[ResilienceFixture.billingAgent]?.attention, "approval")
        XCTAssertEqual(result.conversations[ResilienceFixture.docsAgent]?.busy, true)
        XCTAssertEqual(result.texts[ResilienceFixture.billingAgent], "Plan ready.\nRun the migration?")
        XCTAssertEqual(helper.requests("chat.list").count, 1, "one request for the whole host")
        XCTAssertEqual(driver.runs, 1)
        XCTAssertTrue(hosts.trustRequests.isEmpty)
        XCTAssertNil(hosts.session(studio.id)?.client, "the app's own session was never connected")

        let refresh = refresh(hosts: [studio], source: FakeRefreshSource())
        let notifications = refresh.apply(result, to: studio)
        XCTAssertEqual(notifications.map(\.body), ["Run the migration?"])
    }

    /// Plain SSH hosts are never refreshed (docs/ios.md): a host with its Helper switch off (its Chat is off with it) is
    /// neither scheduled for nor connected, and a connection that fell back to plain SSH reads nothing.
    func testPlainSSHHostsAreSkipped() async throws {
        var pi = ResilienceFixture.host("pi", order: 1)
        pi.helper = false
        pi.chat = true
        XCTAssertFalse(pi.chat, "the record keeps Chat off without the helper")
        XCTAssertFalse(BackgroundRefresh.refreshes(pi))
        XCTAssertTrue(BackgroundRefresh.refreshes(studio))

        let scheduler = RecordingScheduler()
        refresh(hosts: [pi], source: FakeRefreshSource(), scheduler: scheduler).schedule()
        XCTAssertEqual(scheduler.cancelled, ["yachts.dispatch.mobile.refresh"], "only a plain host: nothing to refresh")
        XCTAssertTrue(scheduler.submitted.isEmpty)

        let source = FakeRefreshSource(results: [studio.id: found(), pi.id: found()])
        let posted = await refresh(hosts: [studio, pi], source: source).run()
        XCTAssertEqual(source.asked, [studio.id], "the plain host is not connected")
        XCTAssertEqual(posted.map(\.key.host), [studio.id])

        let fallback = ScriptedHostSessionDriver { _ in [.event(.link(.connecting)), .plain(reason: "unsupported system"), .hold] }
        let hosts = ResilienceFixture.sessions([studio], driver: fallback, active: false)
        let result = await HostSessionsRefreshSource(hosts: hosts).refresh(studio, until: .now + .seconds(5))
        XCTAssertNil(result, "connected without a helper: nothing to read")
    }

    /// A background session never asks: a host key that is not trusted yet fails it, with no sheet queued.
    func testABackgroundSessionAsksNothing() async throws {
        let offer = HostKeyOffer(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: Data([1, 2, 3]))
        let driver = ScriptedHostSessionDriver { host in [.hostKey(offer)] + ScriptedHostSessionDriver.connects(host) }
        let hosts = ResilienceFixture.sessions([studio], driver: driver, active: false)
        let session = hosts.backgroundSession(studio)
        session.connect()
        try await TestSupport.eventually { if case .failed = session.link { true } else { false } }
        XCTAssertTrue(hosts.trustRequests.isEmpty)
        hosts.knownHosts.trust(host: offer.host, port: offer.port, algorithm: offer.algorithm, key: offer.key)
        let trusted = hosts.backgroundSession(studio)
        trusted.connect()
        try await TestSupport.eventually { trusted.link == .connected }
        trusted.disconnect()
    }

    /// The background session reads the Keychain without interaction: a key behind Face ID fails at once (no prompt is
    /// attempted) and the host is skipped; the app's own session reads it as before.
    func testABackgroundSessionNeverPromptsForAFaceIDKey() async throws {
        let keys = KeyStore(url: nil, vault: MemoryVault(), keyProtection: .biometry, secureEnclaveAvailable: false)
        let key = try keys.generateED25519(label: "phone")
        var record = studio
        record.auth = .key(key.id)
        /// Reads the host's key through the context it is given and reports the outcome as the link.
        struct KeyReader: HostSessionDriver {
            func run(_ host: HostRecord, context: HostSessionContext) -> AsyncStream<HostSessionEvent> {
                AsyncStream { continuation in
                    Task {
                        do {
                            let material = try await context.key()
                            continuation.yield(.link(.failed(material == nil ? "none" : "read")))
                        } catch {
                            continuation.yield(.link(.failed(error.localizedDescription)))
                        }
                        continuation.finish()
                    }
                }
            }
        }
        let hosts = HostSessions(store: HostStore(url: nil, hosts: [record]), keys: keys, knownHosts: KnownHostStore(url: nil),
                                 driver: KeyReader())
        let background = hosts.backgroundSession(record)
        background.connect()
        try await TestSupport.eventually { if case .failed = background.link { true } else { false } }
        XCTAssertEqual(background.link, .failed(SecretVaultError.interactionNotAllowed.localizedDescription))
        let foreground = try XCTUnwrap(hosts.session(record.id))
        foreground.connect()
        try await TestSupport.eventually { foreground.link == .failed("read") }
    }

    /// With previews hidden, the lock screen shows the category's placeholder: not the agent's last line, and not the
    /// title (the tab and host), since the category does not ask to show it.
    func testHiddenPreviewsShowOnlyThePlaceholder() {
        let notification = RefreshNotification(id: "x", title: "claude · studio", body: "Run the migration?",
                                               key: ChatConversationKey(host: UUID(), node: "n"))
        let content = notification.content
        XCTAssertEqual(content.categoryIdentifier, RefreshNotification.category.identifier)
        XCTAssertEqual(RefreshNotification.category.hiddenPreviewsBodyPlaceholder, "An agent needs you")
        XCTAssertFalse(RefreshNotification.category.options.contains(.hiddenPreviewsShowTitle))
        XCTAssertFalse(RefreshNotification.category.options.contains(.hiddenPreviewsShowSubtitle))
        XCTAssertEqual(content.body, "Run the migration?")
        XCTAssertEqual(content.userInfo as? [String: String], notification.userInfo)
    }

    /// A tapped notification opens its conversation's tab on Chat, also when it arrives before the app is ready.
    func testATapOpensTheThread() async throws {
        let route = NotificationRoute()
        var opened: [ChatConversationKey] = []
        let key = ChatConversationKey(host: studio.id, node: ResilienceFixture.billingAgent)
        route.route(RefreshNotification(id: "x", title: "t", body: "b", key: key).userInfo)
        XCTAssertTrue(opened.isEmpty)
        route.open = { opened.append($0) }
        XCTAssertEqual(opened, [key], "the pending tap is delivered once the app can open it")
        route.route(["host": "nonsense"])
        XCTAssertEqual(opened.count, 1)

        let hosts = ResilienceFixture.sessions([studio])
        let app = ResilienceFixture.composition(hosts)
        try await TestSupport.eventually { !app.conversations.conversations.isEmpty }
        let target = ChatConversationKey(host: studio.id, node: ResilienceFixture.billingAgent)
        NotificationRoute.shared.route(RefreshNotification(id: "y", title: "t", body: "b", key: target).userInfo)
        let ref = try XCTUnwrap(app.tab(for: target))
        XCTAssertEqual(app.navigator.path, [.tab(ref)])
        XCTAssertEqual(app.tabs.segments[ref], .chat)
    }
}

final class RecordingScheduler: RefreshScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var submissions: [(identifier: String, earliest: Date)] = []
    private var cancellations: [String] = []
    var submitted: [(identifier: String, earliest: Date)] { lock.withLock { submissions } }
    var cancelled: [String] { lock.withLock { cancellations } }
    func submit(_ identifier: String, earliest: Date) throws { lock.withLock { submissions.append((identifier, earliest)) } }
    func cancel(_ identifier: String) { lock.withLock { cancellations.append(identifier) } }
}

@MainActor final class FakeNotifier: RefreshNotifying {
    var isAuthorized: Bool
    var grants: Bool
    private(set) var requests = 0
    private(set) var posted: [RefreshNotification] = []
    private(set) var cleared = 0

    init(authorized: Bool = true, grants: Bool = true) {
        isAuthorized = authorized
        self.grants = grants
    }

    func authorized() async -> Bool { isAuthorized }
    func requestAuthorization() async -> Bool {
        requests += 1
        isAuthorized = grants
        return grants
    }
    func post(_ notification: RefreshNotification) { posted.append(notification) }
    func removeAll() { cleared += 1 }
}

@MainActor final class FakeRefreshSource: RefreshSource {
    var results: [UUID: HostRefresh]
    private(set) var asked: [UUID] = []
    /// Runs while a host is being refreshed (the app changing things meanwhile).
    var during: (() -> Void)?
    init(results: [UUID: HostRefresh] = [:]) { self.results = results }
    func refresh(_ host: HostRecord, until deadline: ContinuousClock.Instant) async -> HostRefresh? {
        asked.append(host.id)
        during?()
        return results[host.id]
    }
}

/// `XCTUnwrap` for an async expression's value.
func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
