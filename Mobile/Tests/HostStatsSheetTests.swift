import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// The stats sheet's states (W1a–W7), host detail's stats block (W4) and the popover's content (I5), read through
/// what VoiceOver gets, on scripted hosts whose helper answers as the demo's mba2.
@MainActor
final class HostStatsSheetTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true }
        windows = []
        try await super.tearDown()
    }

    /// Keeps each connection's scripted helper alive (a client alone does not keep its peer). The helpers answer as the
    /// demo's mba2, CPU from `cpus` when set (one per sample, the last repeating), so live numbers differ from the seed.
    private final class Peers: @unchecked Sendable {
        private let lock = NSLock()
        private var helpers: [ScriptedHelper] = []
        var cpus: [Double] = []
        private var served = 0

        private func cpu() -> Double? {
            lock.withLock {
                guard !cpus.isEmpty else { return nil }
                defer { served += 1 }
                return cpus[min(served, cpus.count - 1)]
            }
        }

        func make() -> HelperClient {
            let helper = ScriptedHelper { [unowned self] request in
                guard var value = HostStatsDemo.answer(request.method, host: "mba2", home: "/Users/alex") else { return .open }
                if request.method == "stats.sample", var sample = value as? [String: Any], let cpu = self.cpu() {
                    sample["cpu"] = cpu
                    value = sample
                }
                return .result(value)
            }
            lock.withLock { helpers.append(helper) }
            return helper.client
        }
    }

    private let peers = Peers()

    private func registry(helper: Bool = true, plainReason: String? = nil, cpus: [Double] = []) -> (HostSessions, HostSession) {
        let peers = peers
        peers.cpus = cpus
        var record = HostRecord(name: "mba2", address: "mba2.tail3f.ts.net", user: "alex", auth: .password)
        record.helper = helper
        let driver = ScriptedHostSessionDriver { record in
            if !record.helper || plainReason != nil { return [.plain(reason: plainReason), .hold] }
            return [.readyWith(client: { peers.make() }, hello: HostFixture.hello(), multiplexers: HostFixture.multiplexers(["herdr"]), versions: ["herdr": "0.9.5"],
                topology: nil), .event(.latency(.milliseconds(18))), .hold]
        }
        let sessions = HostSessions(store: HostStore(url: nil, hosts: [record]),
                                    keys: KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none, secureEnclaveAvailable: false),
                                    knownHosts: KnownHostStore(url: nil), driver: driver, active: true)
        let session = sessions.ordered[0]
        HostStatsDemo.seed(session.stats, host: "mba2", home: "/Users/alex")
        return (sessions, session)
    }

    private func spoken(_ view: some View, sessions: HostSessions, height: CGFloat = 1400,
                        until: @escaping ([NSObject]) -> Bool) async throws -> [NSObject] {
        AccessibilityLabelTests.enableAccessibility()
        let found = await TestSupport.windowScene()
        let scene = try XCTUnwrap(found)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: height)
        window.rootViewController = UIHostingController(rootView: view.environment(sessions).tint(.dispatchPink))
        window.isHidden = false
        windows.append(window)
        var elements: [NSObject] = []
        try await TestSupport.eventually(diagnostic: "Elements: \(Self.labels(elements))") {
            var seen: Set<ObjectIdentifier> = []
            elements = AccessibilityLabelTests.elements(in: window).filter { seen.insert(ObjectIdentifier($0)).inserted }
            return until(elements)
        }
        return elements
    }

    private static func labels(_ elements: [NSObject]) -> [String] { elements.compactMap(\.accessibilityLabel) }
    private static func element(_ label: String, in elements: [NSObject]) -> NSObject? {
        elements.first { $0.accessibilityLabel == label }
    }

    /// W1: the strip's numbers, the processes by CPU and the connection list, with Edit and Disconnect; Memory orders
    /// the processes by memory (W2). Disconnect keeps the host off.
    func testLargeSheetLive() async throws {
        let (sessions, session) = registry()
        try await TestSupport.eventually { session.link.isConnected && session.latency != nil }
        let sheet = HostStatsSheet(hostID: session.id, launch: HostStatsLaunch(detent: .large))
        let elements = try await spoken(sheet, sessions: sessions) { Self.labels($0).contains("Disconnect") }
        let labels = Self.labels(elements)
        for label in ["Close", "CPU", "Memory", "Disk", "Top processes", "Edit", "Disconnect", "CPU, last 15 minutes"] {
            XCTAssertTrue(labels.contains(label), "\(label) in \(labels)")
        }
        XCTAssertTrue(labels.contains { $0.contains("mba2") && $0.contains("macOS 26.1 · 18 ms") }, "\(labels)")
        XCTAssertEqual(Self.element("CPU", in: elements)?.accessibilityValue, "34 %, 2.71 load")
        XCTAssertEqual(Self.element("Disk", in: elements)?.accessibilityValue, "48 GB free · 90% used")
        XCTAssertTrue(labels.contains { $0.hasPrefix("node") && $0.contains("50%") }, "\(labels)")
        XCTAssertTrue(labels.contains { $0.hasPrefix("Address") && $0.contains("alex@mba2.tail3f.ts.net") }, "\(labels)")
        XCTAssertTrue(labels.contains { $0.hasPrefix("Helper") && $0.contains("Full features") }, "\(labels)")
        XCTAssertTrue(labels.contains { $0.hasPrefix("Color") && $0.contains("Automatic") }, "\(labels)")
        XCTAssertTrue(session.stats.viewing, "the sheet asks for 2 s samples")

        _ = Self.element("Memory", in: elements)?.accessibilityActivate()
        let window = try XCTUnwrap(windows.last)
        var byMemory: [String] = []
        try await TestSupport.eventually(diagnostic: "\(byMemory)") {
            byMemory = Self.labels(AccessibilityLabelTests.elements(in: window))
            return byMemory.contains("by memory")
        }
        XCTAssertTrue(byMemory.contains { $0.hasPrefix("fixture-helper") && $0.contains("2.3 GB") }, "\(byMemory)")

        _ = Self.element("Disconnect", in: elements)?.accessibilityActivate()
        try await TestSupport.eventually { session.parked && session.link == .disconnected }
    }

    /// The sheet shows the helper's numbers, not the seeded ones it opened with.
    func testLiveNumbersReplaceTheSeed() async throws {
        let (sessions, session) = registry(cpus: [77])
        try await TestSupport.eventually { session.link.isConnected }
        XCTAssertEqual(session.stats.sample?.cpu, 34, "the seed")
        let sheet = HostStatsSheet(hostID: session.id, launch: HostStatsLaunch(detent: .large))
        let elements = try await spoken(sheet, sessions: sessions) { elements in
            Self.element("CPU", in: elements)?.accessibilityValue == "77 %, 2.71 load"
        }
        XCTAssertTrue(session.stats.live)
        XCTAssertTrue(Self.element("CPU, last 15 minutes", in: elements)?.accessibilityValue?.hasPrefix("now 77%") == true,
                      "\(String(describing: Self.element("CPU, last 15 minutes", in: elements)?.accessibilityValue))")
    }

    /// While the sheet is open the chart moves with every 2 s sample, not only on the 15 s grid's tick.
    func testChartFollowsTwoSecondSamples() async throws {
        let (sessions, session) = registry(cpus: [70, 80, 95])
        let sleeper = SteppedSleeper()
        session.stats.sleep = { try await sleeper.sleep($0) }
        try await TestSupport.eventually { session.link.isConnected }
        let sheet = HostStatsSheet(hostID: session.id, launch: HostStatsLaunch(detent: .large))
        func chart(_ elements: [NSObject]) -> String? { Self.element("CPU, last 15 minutes", in: elements)?.accessibilityValue }
        _ = try await spoken(sheet, sessions: sessions) { chart($0)?.hasPrefix("now 70%") == true }
        let window = try XCTUnwrap(windows.last)
        try await TestSupport.eventually { sleeper.pending == 1 }
        XCTAssertEqual(sleeper.durations.last, .seconds(2), "the sheet's cadence")
        sleeper.step()
        try await TestSupport.eventually(diagnostic: "\(String(describing: chart(AccessibilityLabelTests.elements(in: window))))") {
            chart(AccessibilityLabelTests.elements(in: window))?.hasPrefix("now 80%") == true
        }
        XCTAssertGreaterThanOrEqual(StatStripCard.chartDate(.distantPast, stats: session.stats), try XCTUnwrap(session.stats.sample?.date))
    }

    /// An edit that replaces the session (a new address) while the sheet is open moves its 2 s request to the new one.
    func testViewerFollowsAReplacedSession() async throws {
        let (sessions, session) = registry()
        try await TestSupport.eventually { session.link.isConnected }
        _ = try await spoken(HostStatsSheet(hostID: session.id, launch: HostStatsLaunch(detent: .large)), sessions: sessions) {
            Self.labels($0).contains("Disconnect")
        }
        try await TestSupport.eventually { session.stats.viewing }
        var edited = session.host
        edited.address = "mba2.local"
        sessions.update(edited)
        let replacement = try XCTUnwrap(sessions.session(session.id))
        XCTAssertFalse(replacement === session)
        try await TestSupport.eventually { replacement.stats.viewing && !session.stats.viewing }
        XCTAssertEqual(replacement.stats.cadence, .seconds(2))
    }

    /// Every Reconnect the user asks for lifts a Disconnect: the multiplexer hint's too.
    func testHintReconnectLiftsDisconnect() async throws {
        let (sessions, session) = registry()
        try await TestSupport.eventually { session.link.isConnected }
        session.park()
        let elements = try await spoken(NavigationStack { MultiplexerHint(hostID: session.id) }, sessions: sessions) {
            Self.labels($0).contains("Reconnect")
        }
        _ = Self.element("Reconnect", in: elements)?.accessibilityActivate()
        try await TestSupport.eventually { !session.parked && session.link.isConnected }
    }

    /// W1a: the small detent shows the strip and Disconnect; what is below waits for the large one.
    func testSmallSheetLive() async throws {
        let (sessions, session) = registry()
        try await TestSupport.eventually { session.link.isConnected }
        let labels = Self.labels(try await spoken(HostStatsSheet(hostID: session.id), sessions: sessions) {
            Self.labels($0).contains("Disconnect")
        })
        XCTAssertTrue(labels.contains("CPU"), "\(labels)")
        XCTAssertFalse(labels.contains("Edit"), "\(labels)")
        XCTAssertFalse(labels.contains("Top processes"), "\(labels)")
        XCTAssertFalse(labels.contains { $0.hasPrefix("Address") }, "\(labels)")
    }

    /// W1c and W5: offline, the small sheet lists the connection facts with Connect; the large one the last numbers
    /// dimmed under "Offline · last sample …", Forget host and Connect, which connects again.
    func testOfflineSheets() async throws {
        let (sessions, session) = registry()
        try await TestSupport.eventually { session.link.isConnected }
        session.park()
        let small = Self.labels(try await spoken(HostStatsSheet(hostID: session.id), sessions: sessions) {
            Self.labels($0).contains("Connect")
        })
        for prefix in ["Address", "Port", "User", "Key", "Multiplexer"] {
            XCTAssertTrue(small.contains { $0.hasPrefix(prefix) }, "\(prefix) in \(small)")
        }
        XCTAssertTrue(small.contains { $0.contains("Offline since") }, "\(small)")
        XCTAssertFalse(small.contains("CPU"), "no stale numbers on the small sheet: \(small)")

        let sample = try XCTUnwrap(session.stats.sample)
        let large = try await spoken(HostStatsSheet(hostID: session.id, launch: HostStatsLaunch(detent: .large)), sessions: sessions) {
            Self.labels($0).contains("Forget host")
        }
        let labels = Self.labels(large)
        XCTAssertTrue(labels.contains("Offline · last sample \(HostStatsFormat.time(sample.date))"), "\(labels)")
        XCTAssertTrue(labels.contains("CPU"), "\(labels)")
        XCTAssertTrue(labels.contains("Edit"), "the pencil: \(labels)")
        XCTAssertTrue(labels.contains { $0.hasPrefix("Latency") && $0.contains("—") }, "\(labels)")
        _ = Self.element("Connect", in: large)?.accessibilityActivate()
        try await TestSupport.eventually { !session.parked && session.link.isConnected }
    }

    /// W6: without the helper there are no stats; "Install helper…" turns its switch on and connects with it.
    func testPlainSheet() async throws {
        let (sessions, session) = registry(helper: false)
        try await TestSupport.eventually { session.isPlain }
        let presentation = HostStatsPresentation(session: session)
        XCTAssertEqual(presentation.phase, .plain)
        XCTAssertEqual(presentation.line, "Plain SSH", "no OS: no helper ever reported one")
        XCTAssertEqual(presentation.helper, "Plain SSH")
        let elements = try await spoken(HostStatsSheet(hostID: session.id, launch: HostStatsLaunch(detent: .large)), sessions: sessions) {
            Self.labels($0).contains("Install helper…")
        }
        let labels = Self.labels(elements)
        XCTAssertTrue(labels.contains("Stats need the helper"), "\(labels)")
        XCTAssertFalse(labels.contains("CPU"), "\(labels)")
        XCTAssertTrue(labels.contains("Disconnect"), "\(labels)")
        _ = Self.element("Install helper…", in: elements)?.accessibilityActivate()
        try await TestSupport.eventually { session.host.helper && session.mode == .helper }
        XCTAssertEqual(HostStatsPresentation(session: session).phase, .live)
    }

    /// A connection that fell back says why, and tries again.
    func testFallbackSaysWhy() async throws {
        let (_, session) = registry(plainReason: "the host’s system (Plan 9) is not supported")
        try await TestSupport.eventually { session.isPlain }
        let presentation = HostStatsPresentation(session: session)
        XCTAssertEqual(presentation.phase, .plain)
        XCTAssertEqual(presentation.plainText, "The helper could not start on mba2: the host’s system (Plan 9) is not supported")
        XCTAssertEqual(presentation.plainAction, "Try again")
    }

    /// W7: Low Power Mode samples every 30 s, and the sheet says so.
    func testLowPowerBanner() async throws {
        let (sessions, session) = registry()
        try await TestSupport.eventually { session.link.isConnected }
        session.stats.readLowPower = { true }
        session.stats.powerStateChanged()
        XCTAssertEqual(session.stats.cadence, .seconds(30))
        XCTAssertEqual(HostStatsPresentation(session: session).lowPowerBanner, "Low Power Mode · sampling every 30 s")
        let labels = Self.labels(try await spoken(HostStatsSheet(hostID: session.id, launch: HostStatsLaunch(detent: .large)),
                                                  sessions: sessions) { Self.labels($0).contains("Disconnect") })
        XCTAssertTrue(labels.contains("Low Power Mode · sampling every 30 s"), "\(labels)")
    }

    /// The title's line follows the link.
    func testStatusLines() async throws {
        let (_, session) = registry()
        try await TestSupport.eventually { session.latency != nil }
        XCTAssertEqual(HostStatsPresentation(session: session).line, "macOS 26.1 · 18 ms")
        XCTAssertEqual(HostStatsPresentation(session: session).address, "alex@mba2.tail3f.ts.net")
        XCTAssertEqual(HostStatsPresentation(session: session).multiplexer, "herdr 0.9.5")
        XCTAssertNil(HostStatsPresentation(session: session).offlineBanner)
        session.park()
        XCTAssertEqual(HostStatsPresentation(session: session).line, "macOS 26.1 · offline")
        let updated = try XCTUnwrap(session.updated)
        XCTAssertEqual(HostStatsPresentation(session: session).offlineLine, "Offline since \(HostStatsFormat.time(updated))")
    }

    /// W4: host detail shows the strip between its header and Connection, and its disc opens the stats.
    func testHostDetailShowsTheStrip() async throws {
        let (sessions, session) = registry()
        try await TestSupport.eventually { session.link.isConnected }
        let elements = try await spoken(NavigationStack { HostDetail(hostID: session.id) }, sessions: sessions) {
            Self.labels($0).contains("Remove host")
        }
        let labels = Self.labels(elements)
        XCTAssertTrue(labels.contains("CPU"), "\(labels)")
        XCTAssertTrue(labels.contains("mba2 stats"), "\(labels)")
        XCTAssertTrue(labels.contains { $0.hasPrefix("Port") && $0.contains("22") }, "\(labels)")
        XCTAssertTrue(labels.contains("Helper"), "\(labels)")
        XCTAssertTrue(labels.contains("Multiplexer"), "\(labels)")
    }

    /// I5: the popover's content, for the iPad's host glyph.
    func testPopoverContent() async throws {
        let (sessions, session) = registry()
        try await TestSupport.eventually { session.link.isConnected }
        let labels = Self.labels(try await spoken(HostStatsPopoverContent(hostID: session.id), sessions: sessions) {
            Self.labels($0).contains("Disconnect")
        })
        for label in ["CPU", "Top processes", "Edit", "Disconnect"] { XCTAssertTrue(labels.contains(label), "\(label) in \(labels)") }
        XCTAssertTrue(labels.contains { $0.hasPrefix("Helper") }, "\(labels)")
        XCTAssertFalse(labels.contains { $0.hasPrefix("Latency") }, "the popover's list is shorter: \(labels)")
    }
}
