import WatchConnectivity
import XCTest
@testable import DispatchMobile

/// Runs each host on its own driver, by name.
struct NamedHostDriver: HostSessionDriver {
    let drivers: [String: any HostSessionDriver]
    func run(_ host: HostRecord, context: HostSessionContext) -> AsyncStream<HostSessionEvent> {
        drivers[host.name, default: ScriptedHostSessionDriver()].run(host, context: context)
    }
}

/// The phone's state as the watch gets it (docs/watch.md, Pushing the snapshot): the hosts, the Agents rows in the phone's
/// order, the spaces and tabs, and what blocks a host from connecting without the phone's screen.
@MainActor
final class WatchSnapshotTests: XCTestCase {
    static let docs = ResilienceFixture.docsAgent, billing = ResilienceFixture.billingAgent

    /// "studio" connected with two agents (billing waits for an approval, docs is muted) and "lab" offline.
    static func fixture(_ test: XCTestCase, active: Bool = true) async throws -> (MobileComposition, studio: HostRecord, lab: HostRecord) {
        let studio = ResilienceFixture.host("studio", order: 0), lab = ResilienceFixture.host("lab", order: 1)
        let helper = ScriptedHelper.scripted { request in
            guard request.method == "chat.list" else { return nil }
            return .result([["terminal": 10, "busy": false, "attention": NSNull(), "preview": "Plan ready.\n**Run** the migration?",
                             "time_ms": 1_800_000_950_000, "waiting": true, "title": "Billing migration"] as [String: Any],
                            ["terminal": 5, "busy": false, "attention": NSNull(), "preview": "Docs are rebuilt.",
                             "time_ms": 1_800_000_900_000, "waiting": false]])
        }
        let lost = ScriptedHostSessionDriver { _ in [.event(.link(.connecting)), .event(.link(.failed("Connection timed out")))] }
        let driver = NamedHostDriver(drivers: ["studio": ClientDriver { _ in helper }, "lab": lost])
        let hosts = ResilienceFixture.sessions([studio, lab], driver: driver, active: active)
        let suite = "watch-\(UUID().uuidString)"
        test.addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let app = ResilienceFixture.composition(hosts, settings: MobileSettings(defaults: defaults),
                                                tabs: MobileTabs(activity: TabActivityStore(url: nil), defaults: defaults))
        app.conversations.markers.setMuted(true, host: studio.id, node: docs)
        if active {
            try await TestSupport.eventually { app.conversations.conversations.count == 2 && app.conversations.conversations.allSatisfy { !$0.stale } }
            try await TestSupport.eventually { if case .failed = hosts.session(lab.id)?.link { true } else { false } }
        }
        return (app, studio, lab)
    }

    func testTheSnapshotIsThePhonesListsInItsOrder() async throws {
        let (app, studio, lab) = try await Self.fixture(self)
        let now = Date(timeIntervalSince1970: 1_800_001_000)
        let snapshot = WatchSnapshotBuilder(composition: app).build(at: now)
        XCTAssertEqual(snapshot.generated, now)
        XCTAssertEqual(snapshot.phone, WatchPhone(foreground: true, needsYou: 1))

        XCTAssertEqual(snapshot.hosts.map(\.name), ["studio", "lab"], "the user's order")
        let host = snapshot.hosts[0], offline = snapshot.hosts[1]
        XCTAssertEqual(host.id, studio.id.uuidString)
        XCTAssertEqual(host.state, .connected)
        XCTAssertEqual(host.system, "macos")
        XCTAssertEqual(host.osLabel, "macOS 26.1")
        XCTAssertTrue(host.live)
        XCTAssertTrue(host.chat)
        XCTAssertNil(host.blocked)
        XCTAssertNotNil(host.lastConnected)
        let tint = try XCTUnwrap(host.tint)
        XCTAssertNotNil(WatchTint.components(tint), "#RRGGBB")
        XCTAssertEqual(tint, WatchSnapshotBuilder.tint(studio.tint))
        XCTAssertEqual(offline.id, lab.id.uuidString)
        XCTAssertEqual(offline.state, .offline)
        XCTAssertNil(offline.tint, "grey, as the phone draws an offline host")
        XCTAssertEqual(offline.problem, "Connection timed out")
        XCTAssertNil(offline.blocked, "a password host in the foreground just failed")

        XCTAssertEqual(snapshot.conversations.map(\.node), [Self.billing, Self.docs], "newest first, as Agents")
        let billing = snapshot.conversations[0], docs = snapshot.conversations[1]
        XCTAssertEqual(billing.host, studio.id.uuidString)
        XCTAssertEqual(billing.name, "Billing migration")
        XCTAssertEqual(billing.space, "billing")
        XCTAssertEqual(billing.tab, "tmux:fixture:9")
        XCTAssertEqual(billing.preview, "Plan ready. Run the migration?", "flattened onto one line")
        XCTAssertTrue(billing.needsYou)
        XCTAssertEqual(billing.dot, .unread)
        XCTAssertFalse(billing.muted)
        XCTAssertFalse(billing.stale)
        XCTAssertEqual(billing.lastActivity, Date(timeIntervalSince1970: 1_800_000_950))
        XCTAssertTrue(docs.muted)
        XCTAssertNil(docs.dot, "muted: only needs you keeps a dot")
        XCTAssertFalse(docs.needsYou)
        XCTAssertEqual(docs.tab, "tmux:fixture:4")

        XCTAssertEqual(snapshot.spaces.map(\.name), ["docs", "billing"])
        XCTAssertEqual(snapshot.spaces.map(\.folder), ["~/src/docs", "~/src/api"])
        XCTAssertEqual(snapshot.spaces.map(\.unread), [0, 1])
        XCTAssertEqual(snapshot.spaces.map(\.working), [false, false])
        XCTAssertEqual(snapshot.spaces[1].activity, billing.lastActivity, "its latest tab's time, the agent's newest record")

        XCTAssertEqual(snapshot.tabs.map(\.key), ["tmux:fixture:4", "tmux:fixture:6", "tmux:fixture:9"], "server order per space")
        XCTAssertEqual(snapshot.tabs.map(\.space), ["tmux:fixture:3", "tmux:fixture:3", "tmux:fixture:8"])
        XCTAssertEqual(snapshot.tabs.map(\.chat), [true, false, true])
        XCTAssertEqual(snapshot.tabs.map(\.conversation), [Self.docs, nil, Self.billing])
        XCTAssertEqual(snapshot.tabs.map(\.urgency), [nil, nil, .needsYou])
        XCTAssertEqual(snapshot.tabs[2].status, "needs you")
        XCTAssertEqual(snapshot.tabs[2].name, "Billing migration", "the agent's title names an unrenamed tab")
        XCTAssertNil(snapshot.tabs[1].status, "a shell at its prompt says nothing")
        XCTAssertEqual(snapshot.tabs[1].folder, "~/src/docs")

        XCTAssertEqual(WatchCodec.fit(snapshot), snapshot, "far under the limit: nothing left out")
        let decoded = try XCTUnwrap(try WatchCodec.value(WatchSnapshot.self, in: try WatchCodec.message(snapshot)))
        XCTAssertEqual(decoded, snapshot)
    }

    /// The redesign's fields: a row's own title, the hosts' statistics from the stats source (the phone's store; here
    /// the sample's), the latency of a connected host and since when one is offline, the reviews whose Undo is open.
    func testRowsTitlesHostStatisticsAndReviews() async throws {
        let (app, studio, lab) = try await Self.fixture(self)
        let now = Date(timeIntervalSince1970: 1_800_001_000)
        let stats = WatchSampleStats(now: { now })
        let studioStats = WatchHostStats(cpu: 34, memoryUsed: 11 << 30, diskFree: 48 << 30, warnings: [.disk],
                                         history: [20, nil, 34], sampled: now)
        stats.overrides[studio.id] = studioStats
        let reviews = WatchReviewEvents(clock: { now })
        reviews.post(key: ChatConversationKey(host: studio.id, node: Self.billing), agent: "claude", title: "Billing migration",
                     comments: 3, files: 2, window: 8) { true }
        let snapshot = WatchSnapshotBuilder(composition: app, stats: stats, reviews: reviews).build(at: now)

        XCTAssertEqual(snapshot.conversations[0].title, "Billing migration", "the conversation's own title")
        XCTAssertNil(snapshot.conversations[1].title)
        XCTAssertNil(snapshot.conversations[0].step, "not working")
        XCTAssertNil(snapshot.conversations[0].waitingText, "no session open and no attention line: the watch says Needs you")

        XCTAssertEqual(snapshot.hosts[0].stats, studioStats)
        let sample = try XCTUnwrap(snapshot.hosts[1].stats, "the sample's derived numbers")
        XCTAssertEqual(sample.history.count, WatchHostStats.historyCount)
        XCTAssertEqual(sample, stats.stats(for: lab.id), "the same each time")
        XCTAssertEqual(snapshot.hosts[0].latency, app.hosts.session(studio.id)?.latency.map(WatchSnapshotBuilder.milliseconds))
        XCTAssertNil(snapshot.hosts[0].offlineSince)
        XCTAssertNil(snapshot.hosts[1].latency, "offline")
        XCTAssertNil(snapshot.hosts[1].offlineSince, "never connected in this run: not known")

        // A connection that ends says when.
        let session = try XCTUnwrap(app.hosts.session(studio.id))
        XCTAssertNil(session.droppedAt)
        let before = Date()
        session.disconnect()
        let dropped = try XCTUnwrap(session.droppedAt)
        XCTAssertGreaterThanOrEqual(dropped, before.addingTimeInterval(-1))
        XCTAssertEqual(WatchSnapshotBuilder(composition: app).build(at: now).hosts[0].offlineSince, dropped)
        XCTAssertNil(WatchSnapshotBuilder(composition: app).build(at: now).hosts[0].stats, "no source: none sent")

        XCTAssertEqual(snapshot.reviews.count, 1)
        XCTAssertEqual(snapshot.reviews[0].node, Self.billing)
        XCTAssertEqual(snapshot.reviews[0].undoUntil, now.addingTimeInterval(8))
        XCTAssertTrue(WatchSnapshotBuilder(composition: app, reviews: reviews).build(at: now.addingTimeInterval(9)).reviews.isEmpty)
        XCTAssertEqual(WatchSnapshotBuilder.milliseconds(.milliseconds(18)), 18, accuracy: 0.001)
    }

    /// The agent's glyph: the thread's key once it named one, else the bound executable's name.
    func testTheAgentIsTheBindingsExecutable() async throws {
        let (app, studio, _) = try await Self.fixture(self)
        let builder = WatchSnapshotBuilder(composition: app)
        let binding = try JSONDecoder().decode(HelperTopology.Binding.self, from: Data("""
            {"session": "s", "transcript": null, "pid": 1, "start": null, "executable": "/opt/homebrew/bin/codex"}
            """.utf8))
        XCTAssertEqual(builder.agent(ChatConversationKey(host: studio.id, node: Self.docs), binding: binding), "codex")
        XCTAssertNil(builder.agent(ChatConversationKey(host: studio.id, node: Self.docs), binding: nil))
    }

    /// In the background a host whose key is behind Face ID cannot connect (no prompt can show); the locked phone blocks
    /// nothing more (passwords read after first unlock) and is only reported.
    func testBlockedHostsInTheBackground() throws {
        let keys = KeyStore(url: nil, vault: MemoryVault(), keyProtection: .biometry, secureEnclaveAvailable: false)
        let key = try keys.generateED25519(label: "phone")
        var pi = ResilienceFixture.host("pi")
        pi.auth = .key(key.id)
        let studio = ResilienceFixture.host("studio", order: 1)
        let hosts = HostSessions(store: HostStore(url: nil, hosts: [pi, studio]), keys: keys, knownHosts: KnownHostStore(url: nil),
                                 driver: ScriptedHostSessionDriver(), active: false)
        let app = ResilienceFixture.composition(hosts)
        let background = WatchSnapshotBuilder(composition: app).build()
        XCTAssertFalse(background.phone.foreground)
        XCTAssertEqual(background.hosts.map(\.blocked), [.faceID, nil])
        XCTAssertEqual(background.hosts.map(\.state), [.offline, .offline])

        let locked = WatchSnapshotBuilder(composition: app, protectedDataAvailable: false).build()
        XCTAssertTrue(locked.phone.locked)
        XCTAssertEqual(locked.hosts.map(\.blocked), [.faceID, nil], "never phoneLocked")

        hosts.setActive(true)
        XCTAssertEqual(WatchSnapshotBuilder(composition: app).build().hosts.map(\.blocked), [nil, nil],
                       "in the foreground Face ID can ask")
    }

    /// Plain SSH hosts (docs/ios.md) are not the watch's: a host with its Helper switch off and one whose connection fell
    /// back to plain SSH are left out of the hosts, and their spaces and tabs with them; a host on its helper stays.
    func testPlainSSHHostsAreSkipped() async throws {
        let studio = ResilienceFixture.host("studio", order: 0)
        var pi = ResilienceFixture.host("pi", order: 1)
        pi.helper = false
        let lab = ResilienceFixture.host("lab", order: 2)
        let driver = NamedHostDriver(drivers: [
            "studio": ScriptedHostSessionDriver(),
            "pi": ScriptedHostSessionDriver { _ in [.plain(reason: nil), .hold] },
            "lab": ScriptedHostSessionDriver { _ in [.plain(reason: "unsupported system"), .hold] },
        ])
        let hosts = ResilienceFixture.sessions([studio, pi, lab], driver: driver)
        let app = ResilienceFixture.composition(hosts)
        try await TestSupport.eventually { hosts.ordered.allSatisfy { $0.link == .connected } }
        XCTAssertEqual(hosts.ordered.map(\.plainSSH), [false, true, true])
        try await TestSupport.eventually { app.tabs.workspaces.contains { $0.id == studio.id && !$0.spaces.isEmpty } }
        let snapshot = WatchSnapshotBuilder(composition: app).build()
        XCTAssertEqual(snapshot.hosts.map(\.name), ["studio"])
        XCTAssertFalse(snapshot.spaces.isEmpty)
        XCTAssertTrue(snapshot.spaces.allSatisfy { $0.host == studio.id.uuidString }, "\(snapshot.spaces.map(\.host))")
        XCTAssertTrue(snapshot.tabs.allSatisfy { $0.host == studio.id.uuidString })
        XCTAssertTrue(snapshot.conversations.allSatisfy { $0.host == studio.id.uuidString })
    }

    /// The phone's connection failures name the host's address, port and user (docs/security.md, Apple Watch: none of
    /// them crosses); its display name stands in.
    func testAHostsAddressNeverReachesTheWatch() async throws {
        var lab = ResilienceFixture.host("lab")
        lab.address = "10.0.0.7"
        lab.port = 2222
        XCTAssertEqual(WatchSnapshotBuilder.redact("10.0.0.7 didn’t answer on port 2222. Check that it’s awake.", host: lab),
                       "lab didn’t answer on its SSH port. Check that it’s awake.")
        XCTAssertEqual(WatchSnapshotBuilder.redact("The host key of [10.0.0.7]:2222 changed.", host: lab), "The host key of lab changed.")
        XCTAssertEqual(WatchSnapshotBuilder.redact("alex@10.0.0.7: Permission denied", host: lab), "lab: Permission denied")
        var pi = ResilienceFixture.host("raspberry")
        pi.address = "pi"
        XCTAssertEqual(WatchSnapshotBuilder.redact("Can’t find pi. The pipe closed.", host: pi), "Can’t find raspberry. The pipe closed.",
                       "whole names only")

        let failing = ScriptedHostSessionDriver { _ in [.event(.link(.connecting)), .event(.link(.failed("Can’t find 10.0.0.7. Check the address.")))] }
        let hosts = ResilienceFixture.sessions([lab], driver: failing)
        let app = ResilienceFixture.composition(hosts)
        try await TestSupport.eventually { if case .failed = hosts.session(lab.id)?.link { true } else { false } }
        XCTAssertEqual(WatchSnapshotBuilder(composition: app).build().hosts.first?.problem, "Can’t find lab. Check the address.")
    }
}
