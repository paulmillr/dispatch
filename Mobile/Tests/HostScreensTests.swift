import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

@MainActor
final class HostScreensTests: XCTestCase {
    private func sessions(_ steps: [ScriptedHostSessionDriver.Step], record: HostRecord? = nil) -> (HostSessions, HostSession) {
        let record = record ?? HostRecord(name: "studio", address: "studio.tail3f.ts.net", user: "alex", auth: .password)
        let sessions = HostSessions(store: HostStore(url: nil, hosts: [record]),
                                    keys: KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none, secureEnclaveAvailable: false),
                                    knownHosts: KnownHostStore(url: nil), driver: ScriptedHostSessionDriver { _ in steps })
        return (sessions, sessions.ordered[0])
    }

    private var ready: ScriptedHostSessionDriver.Step {
        .ready(hello: HostFixture.hello(home: "/Users/alex"), multiplexers: HostFixture.multiplexers(["tmux"]),
               versions: ["tmux": "3.7"],
               topology: HostFixture.topology([.init(name: "docs", cwd: "/Users/alex/src/docs", tabs: 2, agents: 1),
                                               .init(name: "billing", cwd: "/srv/api", tabs: 1, agents: 1)]))
    }

    /// M1f's status follows the link: "Connected · mosh · 38 ms" (the mockup's word, kept by decision), offline
    /// hosts in gray with their last OS.
    func testStatusFollowsTheLink() async throws {
        let (registry, session) = sessions([.event(.link(.connecting)), .sleep(.milliseconds(200)), ready, .event(.latency(.milliseconds(38))), .hold])
        var summary = HostSummary(session: session)
        XCTAssertEqual(summary.status, "Offline")
        XCTAssertTrue(summary.offline)
        XCTAssertNil(summary.osLabel)

        session.connect()
        XCTAssertEqual(HostSummary(session: session).status, "Connecting…")
        XCTAssertFalse(HostSummary(session: session).offline, "A connecting host keeps its colour")
        try await TestSupport.eventually { session.latency != nil }
        summary = HostSummary(session: session)
        XCTAssertEqual(summary.status, "Connected · mosh · 38 ms")
        XCTAssertEqual(summary.osLabel, "macOS 26.1")

        session.disconnect()
        summary = HostSummary(session: session)
        XCTAssertEqual(summary.status, "Offline")
        XCTAssertEqual(summary.osLabel, "macOS 26.1", "Offline hosts keep their OS")
        XCTAssertEqual(registry.store.hosts.first?.osLabel, "macOS 26.1")
    }

    func testReconnectingAndFailedStatus() async throws {
        let since = Date()
        let (_, session) = sessions([ready, .event(.link(.reconnecting(attempt: 3, since: since))), .hold])
        session.connect()
        try await TestSupport.eventually { session.link == .reconnecting(attempt: 3, since: since) }
        XCTAssertEqual(HostSummary(session: session).status, "Reconnecting · attempt 3")
        let (_, failing) = sessions([.event(.link(.failed("Connection refused")))])
        failing.connect()
        try await TestSupport.eventually { HostSummary(session: failing).status == "Connection refused" }
        XCTAssertTrue(HostSummary(session: failing).offline)
    }

    /// On a bad network a retrying host says why (the transport's reason), and an offline iPhone says so first: the
    /// host is not to blame. Connected, or refused (the status is the reason), there is nothing more to say.
    func testRetryingHostsSayWhyAndAnOfflineIPhoneSaysSo() async throws {
        let since = Date(), reason = "Can’t find studio.tail3f.ts.net. Check the name, and that Tailscale is on."
        let (registry, session) = sessions([.event(.link(.reconnecting(attempt: 2, since: since, reason: reason))), .hold])
        session.connect()
        try await TestSupport.eventually { session.link == .reconnecting(attempt: 2, since: since, reason: reason) }
        XCTAssertEqual(HostSummary(session: session).problem, reason)
        XCTAssertEqual(HostSummary(session: session).status, "Reconnecting · attempt 2")

        registry.networkPath(satisfied: false)
        XCTAssertEqual(HostSummary(session: session).status, "Waiting for the network…")
        XCTAssertEqual(HostSummary(session: session).problem, "This \(MobileDevice.name) is offline. Dispatch reconnects when the network is back.")
        // A host verified in New host gets the reading too.
        let probe = registry.probe(HostRecord(name: "new", address: "new.local", user: "alex", auth: .password))
        XCTAssertTrue(probe.networkUnavailable)
        registry.networkPath(satisfied: true)
        XCTAssertFalse(probe.networkUnavailable)
        XCTAssertEqual(HostSummary(session: session).problem, reason)

        let (_, failing) = sessions([.event(.link(.failed("Connection refused")))])
        failing.connect()
        try await TestSupport.eventually { HostSummary(session: failing).status == "Connection refused" }
        XCTAssertNil(HostSummary(session: failing).problem)
    }

    /// What Spaces (Tabs) drives: the host list in order with its link, removal with its question, reordering,
    /// and the embedded screens.
    func testHostManagement() async throws {
        let a = HostRecord(name: "a", address: "a.local", user: "alex", auth: .password)
        let b = HostRecord(name: "b", address: "b.local", user: "alex", auth: .password)
        let registry = HostSessions(store: HostStore(url: nil, hosts: [a, b]),
                                    keys: KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none, secureEnclaveAvailable: false),
                                    knownHosts: KnownHostStore(url: nil), driver: ScriptedHostSessionDriver(), active: true)
        let actions: any SpacesHostActions = registry
        let hosts = { registry.ordered.map(TabsHost.init) }
        XCTAssertEqual(hosts().map(\.name), ["a", "b"])
        XCTAssertEqual(hosts().map(\.order), [0, 1])
        XCTAssertTrue(hosts().allSatisfy { $0.state == .connecting })
        try await TestSupport.eventually { hosts().allSatisfy { $0.state == .connected } }

        actions.reorderHosts([b.id, a.id])
        XCTAssertEqual(hosts().map(\.name), ["b", "a"])
        XCTAssertEqual(registry.store.hosts.map(\.name), ["b", "a"], "Host order lives in HostStore")

        let question = try XCTUnwrap(actions.removalConfirmation(for: a.id))
        XCTAssertEqual(question.title, "Remove a?")
        XCTAssertEqual(question.button, "Remove host")
        XCTAssertTrue(question.message.contains("Nothing changes on the host"))
        actions.removeHost(a.id)
        XCTAssertEqual(hosts().map(\.name), ["b"])
        XCTAssertNil(actions.removalConfirmation(for: a.id))

        _ = registry.editHostSheet(b.id)
        _ = registry.newHostSheet { _ in }
    }

    /// Mail-style dots: in a roll-up, unread (needs you or an unseen result) outranks working.
    func testUrgencyDots() {
        XCTAssertEqual([MobileRowDot.working, .unread].max(), .unread, "Unread outranks working in a roll-up")
    }

    func testLatencyLabels() {
        XCTAssertEqual(HostSummary.milliseconds(.milliseconds(38)), "38 ms")
        XCTAssertEqual(HostSummary.milliseconds(.microseconds(160)), "0.2 ms")
        XCTAssertEqual(HostSummary.milliseconds(.microseconds(9_960)), "10.0 ms")
    }

    /// The host sheet (both detents), New host, Edit host, the trust sheets and the hint lay out in a window.
    /// Each screen is attached to the result; `DISPATCH_MOBILE_HOSTS_PNG` also names a folder to write them to.
    func testScreensRender() async throws {
        let (sessions, session) = sessions([ready, .event(.latency(.milliseconds(38))), .hold])
        try sessions.keys.generateED25519(label: "id_ed25519")
        session.connect()
        try await TestSupport.eventually { session.latency != nil }
        let offer = HostKeyOffer(host: "studio.tail3f.ts.net", port: 22, algorithm: "ssh-ed25519",
                                 key: SSHKeyEncoding.string("ssh-ed25519") + SSHKeyEncoding.string(Array(repeating: UInt8(3), count: 32)))
        let trusted = KnownHostStore.Entry(algorithm: "ssh-ed25519", key: SSHKeyEncoding.string("ssh-ed25519")
            + SSHKeyEncoding.string(Array(repeating: UInt8(4), count: 32)), firstSeen: Date(timeIntervalSince1970: 1_790_000_000))
        let screens: [(String, AnyView)] = [
            ("W1a", AnyView(HostStatsSheet(hostID: session.id))),
            ("W1", AnyView(HostStatsSheet(hostID: session.id, launch: HostStatsLaunch(detent: .large)))),
            ("M8a", AnyView(NewHostSheet())),
            ("M8a-edit", AnyView(NewHostSheet(editing: session.host))),
            ("trust", AnyView(HostTrustSheet(request: HostTrustRequest(hostID: session.id, hostName: "studio", offer: offer, kind: .unknown)))),
            ("mismatch", AnyView(HostTrustSheet(request: HostTrustRequest(hostID: session.id, hostName: "studio", offer: offer,
                                                                          kind: .mismatch(trusted: trusted))))),
            ("hint", AnyView(NavigationStack { MultiplexerHint(hostID: session.id) })),
        ]
        let folder = ProcessInfo.processInfo.environment["DISPATCH_MOBILE_HOSTS_PNG"].map { URL(fileURLWithPath: $0) }
        // The host app's scene may still be connecting when this runs first.
        try await TestSupport.eventually { UIApplication.shared.connectedScenes.contains { $0 is UIWindowScene } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)
        for (name, screen) in screens {
            let controller = UIHostingController(rootView: screen.environment(sessions).tint(.dispatchPink))
            controller.overrideUserInterfaceStyle = .dark
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(controller.view.bounds.width, 402, name)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            // In the result bundle (xcresulttool export attachments) for comparing against the mockups.
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            if let folder { try image.pngData()?.write(to: folder.appendingPathComponent(name + ".png")) }
            window.isHidden = true
        }
    }

    // MARK: Plain SSH (docs/ios.md)

    /// Hosts `view` in a tall window with the accessibility runtime on and returns what VoiceOver reads of it (labels
    /// and values), polled until `until` holds.
    private func spoken(_ view: some View, sessions: HostSessions, until: @escaping ([NSObject]) -> Bool) async throws -> [NSObject] {
        AccessibilityLabelTests.enableAccessibility()
        let found = await TestSupport.windowScene()
        let scene = try XCTUnwrap(found)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 2000)
        window.rootViewController = UIHostingController(rootView: view.environment(sessions).tint(.dispatchPink))
        window.isHidden = false
        windows.append(window)
        var elements: [NSObject] = []
        try await TestSupport.eventually(diagnostic: "Elements: \(elements.map { $0.accessibilityLabel ?? "?" })") {
            // The walk meets an element once per path to it: each once.
            var seen: Set<ObjectIdentifier> = []
            elements = AccessibilityLabelTests.elements(in: window).filter { seen.insert(ObjectIdentifier($0)).inserted }
            return until(elements)
        }
        return elements
    }

    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true }
        windows = []
        try await super.tearDown()
    }

    private static func labels(_ elements: [NSObject]) -> [String] { elements.compactMap(\.accessibilityLabel) }

    /// New host's Helper switch (default on) under the multiplexer: off hides the multiplexer and Chat and the helper's
    /// words, and says what plain SSH does instead; on again gives Chat back as it was (the sheet's own draft).
    func testNewHostHelperSwitchHidesChatAndTheMultiplexer() async throws {
        var draft = HostFeatureDraft()
        XCTAssertTrue(draft.helper, "the helper is on by default")
        XCTAssertTrue(draft.chat)
        XCTAssertTrue(draft.showsHelperRows)
        draft.helper = false
        XCTAssertFalse(draft.showsHelperRows, "no multiplexer or Chat without the helper")
        var record = HostRecord(name: "studio", address: "studio.tail3f.ts.net", user: "alex", auth: .password)
        draft.apply(to: &record)
        XCTAssertFalse(record.helper)
        XCTAssertFalse(record.chat, "the record keeps Chat off without the helper")
        draft.helper = true
        XCTAssertTrue(draft.chat, "on again: Chat as it was")
        draft.apply(to: &record)
        XCTAssertTrue(record.helper)
        XCTAssertTrue(record.chat)
        draft.chat = false
        draft.multiplexer = .tmux
        draft.apply(to: &record)
        XCTAssertEqual(record.multiplexer, .tmux)
        XCTAssertFalse(record.chat)
        var plain = record
        plain.helper = false
        let reopened = HostFeatureDraft(plain)
        XCTAssertFalse(reopened.helper)
        XCTAssertEqual(reopened.multiplexer, .tmux)
        XCTAssertTrue(reopened.chat, "a host saved without the helper gets Chat on with it")

        XCTAssertTrue(String(NewHostSheet.statement(helper: true).characters).hasPrefix("Dispatch installs its helper"))
        let plainWords = String(NewHostSheet.statement(helper: false).characters)
        XCTAssertEqual(plainWords, NewHostSheet.plainStatement)
        XCTAssertFalse(plainWords.contains("Dispatch installs its helper"))
        XCTAssertTrue(plainWords.contains("installs nothing"))

        let (sessions, _) = sessions([.hold])
        let helperOn = Self.labels(try await spoken(NewHostSheet(), sessions: sessions) { elements in
            Self.labels(elements).contains { $0.hasPrefix("Dispatch installs its helper") }
        })
        XCTAssertTrue(helperOn.contains("Helper"), "\(helperOn)")
        XCTAssertTrue(helperOn.contains("Chat"), "\(helperOn)")
        XCTAssertTrue(helperOn.contains("Multiplexer, Automatic"), "\(helperOn)")
        XCTAssertFalse(helperOn.contains(NewHostSheet.plainStatement))

        let off = Self.labels(try await spoken(NewHostSheet(editing: plain), sessions: sessions) { elements in
            Self.labels(elements).contains(NewHostSheet.plainStatement)
        })
        XCTAssertTrue(off.contains("Helper"), "\(off)")
        XCTAssertFalse(off.contains("Chat"), "\(off)")
        XCTAssertFalse(off.contains { $0.hasPrefix("Multiplexer") }, "\(off)")
        XCTAssertFalse(off.contains { $0.contains("Dispatch installs its helper") }, "\(off)")
    }

    /// Edit host holds every setting of the host: the switches, Color (Automatic until picked) and, last, Remove host;
    /// New host has neither Color nor Remove.
    func testEditHostHasColorAndRemove() async throws {
        let (sessions, session) = sessions([.hold])
        let edit = Self.labels(try await spoken(NewHostSheet(editing: session.host), sessions: sessions) { elements in
            Self.labels(elements).contains("Remove host")
        })
        XCTAssertTrue(edit.contains { $0.hasPrefix("Color") && $0.contains("Automatic") }, "\(edit)")
        for row in ["Helper", "Chat", "Files & git"] { XCTAssertTrue(edit.contains(row), "\(row) in \(edit)") }
        let new = Self.labels(try await spoken(NewHostSheet(), sessions: sessions) { elements in
            Self.labels(elements).contains("Helper")
        })
        XCTAssertFalse(new.contains("Remove host"), "\(new)")
        XCTAssertFalse(new.contains { $0.hasPrefix("Color") }, "\(new)")
    }

    /// A host whose Helper switch is off shows no spaces, mark or multiplexer from an earlier helper while it is not
    /// connected: the cache's are ignored and a kept snapshot goes when the switch goes off; Spaces marks it Plain SSH.
    func testAHostWithoutTheHelperShowsNoCachedSpacesOffline() async throws {
        let record = HostRecord(name: "studio", address: "studio.tail3f.ts.net", user: "alex", auth: .password)
        let (registry, session) = sessions([.hold], record: record)
        session.restore(hello: HostFixture.hello(), multiplexers: HostFixture.multiplexers(["tmux"]), versions: ["tmux": "3.7"],
                        following: "tmux", topology: HostFixture.topology())
        XCTAssertNotNil(session.topology)
        XCTAssertEqual(TabsHost(session).multiplexer, "tmux")
        XCTAssertFalse(TabsHost(session).plain)

        registry.setHelper(false, host: record.id)
        XCTAssertEqual(session.link, .disconnected, "not connected by the edit")
        XCTAssertNil(session.topology, "the kept spaces go with the switch")
        XCTAssertNil(session.spacesMultiplexer)
        XCTAssertNil(session.multiplexerLine)
        XCTAssertTrue(session.plainSSH)
        let host = TabsHost(session)
        XCTAssertTrue(host.plain, "Spaces marks it Plain SSH while offline")
        XCTAssertNil(host.multiplexer)

        var plain = record
        plain.helper = false
        let (_, cached) = sessions([.hold], record: plain)
        cached.restore(hello: HostFixture.hello(), multiplexers: HostFixture.multiplexers(["tmux"]), versions: [:],
                       following: "tmux", topology: HostFixture.topology())
        XCTAssertNil(cached.topology, "the cache's spaces are an earlier helper's")
        XCTAssertNil(cached.following)
        XCTAssertNotNil(cached.hello, "kept for the host's labels")
        XCTAssertTrue(TabsHost(cached).plain)
    }

    /// Spaces' host header marks a plain SSH host where the multiplexer goes, and says so to VoiceOver.
    func testSpacesHeaderMarksAPlainHost() async throws {
        let (registry, _) = sessions([.hold])
        var host = TabsHost(id: UUID(), name: "studio", tint: .blue, multiplexer: "tmux")
        host.plain = true
        let section = SpacesSection(host: host, spaces: [], unread: 0, collapsed: false)
        let elements = try await spoken(SpacesHostHeader(section: section, editing: false, toggle: {}, remove: {}), sessions: registry) {
            $0.contains { $0.accessibilityLabel == "studio" }
        }
        let row = try XCTUnwrap(elements.first { $0.accessibilityLabel == "studio" })
        XCTAssertEqual(row.accessibilityValue, "Plain SSH, Expanded", "the mark replaces the multiplexer's")
        XCTAssertEqual(SpacesHostHeader.value(collapsed: false, unread: 0, multiplexer: HostSummary.plainSSH), "Plain SSH, Expanded")
    }

    func testHintNamesBothMultiplexers() {
        XCTAssertTrue(MultiplexerHint.herdr.allSatisfy { $0.text.contains("herdrdev/herdr/releases/download/v0.9.5") })
        XCTAssertEqual(MultiplexerHint.tmux.map(\.text).first, "brew install tmux")
        XCTAssertTrue(String(NewHostSheet.helperStatement.characters).contains("~/.dispatch"))
        XCTAssertNotNil(NewHostSheet.helperStatement.runs.compactMap(\.link).first { $0.absoluteString.hasSuffix("docs/security.md#ssh-integration") })
    }
}
