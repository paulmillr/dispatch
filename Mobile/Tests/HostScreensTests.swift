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
        XCTAssertEqual(summary.spaces, [.init(id: 3, name: "docs", folder: "~/src/docs"), .init(id: 8, name: "billing", folder: "/srv/api")])

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

        _ = registry.hostDetail(b.id) { session in Text(session.host.name) }
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

    /// Host detail (default and injected spaces), New host, Edit, the trust sheets and the hint lay out in a window.
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
            ("M1f", AnyView(NavigationStack { HostDetail(hostID: session.id) })),
            ("M1f-injected", AnyView(NavigationStack { HostDetail(hostID: session.id) { _ in Text("injected") } })),
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

    func testHintNamesBothMultiplexers() {
        XCTAssertTrue(MultiplexerHint.herdr.allSatisfy { $0.text.contains("herdrdev/herdr/releases/download/v0.9.3") })
        XCTAssertEqual(MultiplexerHint.tmux.map(\.text).first, "brew install tmux")
        XCTAssertTrue(String(NewHostSheet.helperStatement.characters).contains("~/.dispatch"))
        XCTAssertNotNil(NewHostSheet.helperStatement.runs.compactMap(\.link).first { $0.absoluteString.hasSuffix("docs/security.md#ssh-integration") })
    }
}
