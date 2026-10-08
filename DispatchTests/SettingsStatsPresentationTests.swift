import AppKit
import SwiftUI
import Vision
import XCTest
@testable import DispatchApp

private struct ResizingStatsPopoverFixture: View {
    let stats: HostStats
    @State private var presented = false

    var body: some View {
        Button("host") { presented = true }
            .frame(width: 140, height: 32)
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                LocalHostStatsPopover(stats: stats, samplesAutomatically: false)
            }
    }
}

private struct ResizingHostInformationPopoverFixture: View {
    let host: HostRecord
    let preferred: SSHConnectionID
    @State private var presented = false

    var body: some View {
        Button("host") { presented = true }
            .frame(width: 140, height: 32)
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                HostInformationView(host: host, state: .connected, preferred: preferred)
                    .fittedPopoverPresentation()
            }
    }
}

@MainActor
final class SettingsStatsPresentationTests: XCTestCase {
    func testMonospacedFontDiscoveryPreservesAvailableFamilies() {
        AppFont.register()
        let expected = NSFontManager.shared.availableFontFamilies.filter { family in
            guard !["Andale Mono", "Courier New"].contains(family) else { return false }
            guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13) else { return false }
            return font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(SettingsView.monospacedFontFamilies, expected)
    }

    func testStatsPopoverKeepsTheRightInformationVisible() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let stats = HostStats()
        var sample = HostSample()
        sample.cpu = 34; sample.load = [2.71, 1.98, 1.42]
        sample.memoryTotal = 32 * 1_073_741_824; sample.memoryUsed = 11 * 1_073_741_824
        sample.diskTotal = 460 * 1_073_741_824; sample.diskFree = 48 * 1_073_741_824
        sample.cores = [41, 72, 18, 55, 88, 29, 34, 12, 63, 47, 21, 9, 35, 67, 14, 57, 86, 22, 41, 9, 56, 46, 28, 11]
        let processNames = ["node", "cargo", "rust-analyzer", "postgres", "fixture-helper"]
        for (index, name) in processNames.enumerated() {
            sample.processes.append(HostProcess(id: 48211 + index, name: name, cpu: Double(50 - index * 9), memory: UInt64(index + 1) * 500_000_000))
        }
        stats.latest = sample; stats.state = .ready; stats.disksStale = false
        stats.history = (0..<61).map { minute in
            var point = sample
            point.date = sample.date.addingTimeInterval(Double(minute - 60) * 60)
            point.cpu = Double(20 + minute % 35)
            return point
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 356, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: HostStatsView(stats: stats, samplesAutomatically: false).preferredColorScheme(.dark))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let initial = try await capture(window, "stats-popover-unselected").text()
        XCTAssertFalse(initial.contains("top processes"), initial)
        XCTAssertFalse(initial.contains("rust-analyzer"), initial)
        XCTAssertTrue(initial.contains("15-min history"), initial)
        try await selectCPU(in: window)
        let compact = try await capture(window, "stats-popover").text()
        XCTAssertTrue(compact.contains("rust-analyzer"), compact)
        XCTAssertFalse(compact.contains("postgres"), "The popover shows only the top three processes: \(compact)")
        XCTAssertFalse(compact.contains("fixture-helper"), compact)
        XCTAssertTrue(compact.contains("15-min history"), compact)
        XCTAssertFalse(compact.contains("peak"), compact)
        XCTAssertFalse(compact.contains("48211"), "The compact process table omits PIDs: \(compact)")
        XCTAssertFalse(compact.contains("Terminal view"), compact)
        let root = try XCTUnwrap(window.contentView)
        let memoryRows = try await PresentationTestSupport.capture(window).recognizedText()
        let memoryLabel = try XCTUnwrap(memoryRows
            .first { $0.topCandidates(1).first?.string == "mem" })
        let box = memoryLabel.boundingBox
        let point = root.convert(NSPoint(x: box.midX * root.bounds.width,
            y: (root.isFlipped ? 1 - box.midY : box.midY) * root.bounds.height), to: nil)
        try PresentationTestSupport.click(window, at: point)
        let memory = try await capture(window, "stats-popover-memory").text()
        XCTAssertTrue(memory.contains("fixture-helper"), memory)
        XCTAssertTrue(memory.contains("postgres"), memory)
        XCTAssertFalse(memory.contains("node"), memory)
        XCTAssertFalse(memory.contains("cargo"), memory)
        XCTAssertFalse(memory.contains("peak"), memory)
        try PresentationTestSupport.click(window, at: point)
        let deselected = try await capture(window, "stats-popover-deselected").text()
        XCTAssertFalse(deselected.contains("top processes"), deselected)
        XCTAssertFalse(deselected.contains("fixture-helper"), deselected)
        let large = AppTypography(contentSize: 22)
        window.setContentSize(NSSize(width: large.expanded(356), height: large.popoverHeight(420)))
        window.contentView = NSHostingView(rootView: HostStatsView(stats: stats, samplesAutomatically: false)
            .environment(\.appTypography, large).preferredColorScheme(.dark))
        let enlarged = try await capture(window, "stats-popover-large-font").text()
        // Vision sometimes recognizes the short CPU label as Cyrillic; the
        // load detail verifies that column remains visible at larger sizes.
        for label in ["2.71 load", "mem", "disk"] {
            XCTAssertTrue(enlarged.contains(label), "Missing \(label) with larger text: \(enlarged)")
        }
    }

    func testStatsPopoverGrowsOnCPUSelectionAndStaysOnScreenAtEverySidebarHeight() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let screen = try XCTUnwrap(NSScreen.main)
        let visible = screen.visibleFrame
        let stats = HostStats()
        var sample = HostSample()
        sample.cpu = 34; sample.load = [2.71, 1.98, 1.42]
        sample.memoryTotal = 32 * 1_073_741_824; sample.memoryUsed = 11 * 1_073_741_824
        sample.diskTotal = 460 * 1_073_741_824; sample.diskFree = 48 * 1_073_741_824
        sample.processes = (1...3).map {
            HostProcess(id: $0, name: "worker-\($0)", cpu: Double(4 - $0), memory: UInt64($0) * 1_073_741_824)
        }
        stats.latest = sample; stats.state = .ready; stats.disksStale = false

        for anchorY in [visible.maxY - 70, visible.midY - 25, visible.minY + 20] {
            let existing = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
            let window = NSWindow(contentRect: NSRect(x: visible.minX + 20, y: anchorY, width: 160, height: 50),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ResizingStatsPopoverFixture(stats: stats))
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil }
            try await Task.sleep(for: .milliseconds(200))
            try PresentationTestSupport.click(window, at: NSPoint(x: 80, y: 25))
            var popover: NSWindow?
            try await TestSupport.eventually {
                popover = nil
                for candidate in NSApp.windows {
                    guard !existing.contains(candidate.windowNumber), candidate !== window, candidate.isVisible else { continue }
                    if try await PresentationTestSupport.capture(candidate).text().contains("15-min history") { popover = candidate; break }
                }
                return popover != nil
            }
            let popup = try XCTUnwrap(popover)
            try await Task.sleep(for: .milliseconds(350))
            let collapsedFrame = popup.frame
            let collapsedHeight = collapsedFrame.height
            try await selectCPU(in: popup, waitForExpansion: false)
            var expansionFrames: [NSRect] = []
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(20))
                expansionFrames.append(popup.frame)
            }
            try await TestSupport.eventually(diagnostic: "Popover did not resize from \(collapsedHeight): \(popup.frame)") {
                guard popup.frame.height > collapsedHeight + 20 else { return false }
                return try await PresentationTestSupport.capture(popup).text().contains("top processes")
            }
            try await Task.sleep(for: .milliseconds(350))
            if anchorY > visible.midY - 30 {
                // Whether the expanded popover fits below its top depends on the
                // screen height (1920×1080 or 1280×832 test desktops), not the anchor.
                if collapsedFrame.maxY - popup.frame.height >= visible.minY {
                    XCTAssertEqual(popup.frame.maxY, collapsedFrame.maxY, accuracy: 1,
                                   "The popover should grow downward without moving its top when there is room")
                }
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    XCTAssertTrue(expansionFrames.contains {
                        $0.height > collapsedHeight + 1 && $0.height < popup.frame.height - 1
                    }, "Process expansion should include intermediate window sizes: \(expansionFrames)")
                }
            }
            XCTAssertTrue(visible.insetBy(dx: -2, dy: -2).contains(popup.frame),
                          "Expanded popover escaped the visible screen for anchor y=\(anchorY): \(popup.frame), screen: \(visible)")
            window.orderOut(nil)
            try await TestSupport.eventually { !popup.isVisible }
            window.contentView = nil
        }
    }

    func testRemoteHostPopoverGrowsWithProcessesNearBottomOfScreen() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let provider = RemoteProcessProvider(), store = SSHStatisticsStore.shared
        let host = HostRecord(id: .authenticated(provider.host), name: "Remote height fixture",
                              hostname: provider.host, destinations: ["fixture@" + provider.host], order: 0)
        let key = try XCTUnwrap(store.register(provider, grant: .init(profile: .statistics), hostID: host.id))
        defer { store.remove(provider.id) }
        let entry = try XCTUnwrap(store.series[key])
        entry.state = .ready
        entry.processes = (1...3).map {
            HostProcess(id: $0, name: "remote-worker-\($0)", cpu: Double(4 - $0), memory: UInt64($0) * 1_073_741_824)
        }

        let screen = try XCTUnwrap(NSScreen.main), visible = screen.visibleFrame
        let existing = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        let window = NSWindow(contentRect: NSRect(x: visible.minX + 20, y: visible.minY + 20, width: 160, height: 50),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ResizingHostInformationPopoverFixture(host: host, preferred: provider.id))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(200))
        try PresentationTestSupport.click(window, at: NSPoint(x: 80, y: 25))
        var popover: NSWindow?
        try await TestSupport.eventually {
            popover = nil
            for candidate in NSApp.windows {
                guard !existing.contains(candidate.windowNumber), candidate !== window, candidate.isVisible else { continue }
                if try await PresentationTestSupport.capture(candidate).text().contains("15-min history") { popover = candidate; break }
            }
            return popover != nil
        }
        let popup = try XCTUnwrap(popover), collapsedHeight = popup.frame.height
        try await selectCPU(in: popup)
        try await TestSupport.eventually(diagnostic: "Remote popover did not resize from \(collapsedHeight): \(popup.frame)") {
            guard popup.frame.height > collapsedHeight + 20 else { return false }
            return try await PresentationTestSupport.capture(popup).text().contains("top processes")
        }
        XCTAssertTrue(visible.insetBy(dx: -2, dy: -2).contains(popup.frame),
                      "Expanded remote popover escaped the visible screen: \(popup.frame), screen: \(visible)")
    }

    func testRemoteHostCardShowsConnectionWithoutLocalMetrics() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let host = HostRecord(id: .authenticated("fixture"), name: "homelab",
                              hostname: "homelab", system: HostSystem(os: "Linux", distribution: "ubuntu", name: "Ubuntu 26.04"),
                              destinations: ["ssh://ops@homelab.test"], order: 0)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 356, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HostInformationView(host: host, state: .connected, disconnect: {}))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentView = nil }
        let text = try await capture(window, "host-information").text()
        for label in ["homelab", "Ubuntu", "connected", "ssh", "ops@homelab.test", "Integration unavailable", "Disconnect"] {
            XCTAssertTrue(text.replacingOccurrences(of: " ", with: "").contains(label.replacingOccurrences(of: " ", with: "")),
                          "Missing \(label): \(text)")
        }
        XCTAssertFalse(text.contains("cpu"), text)
        XCTAssertFalse(text.contains("Reconnect"), text)

        var reconnects = 0, forgotten = 0
        window.contentView = NSHostingView(rootView: HostInformationView(host: host, state: .disconnected,
            reconnect: { reconnects += 1 }, forget: { forgotten += 1 }))
        let disconnected = try await capture(window, "host-information-disconnected")
        let disconnectedText = try disconnected.text()
        XCTAssertTrue(disconnectedText.contains("Reconnect"), disconnectedText)
        XCTAssertFalse(disconnectedText.contains("Disconnect"), disconnectedText)
        let root = try XCTUnwrap(window.contentView)
        let label = try XCTUnwrap(try disconnected.recognizedText()
            .first { $0.topCandidates(1).first?.string == "Reconnect" })
        let box = label.boundingBox
        try PresentationTestSupport.click(window, at: root.convert(NSPoint(x: box.midX * root.bounds.width,
            y: (root.isFlipped ? 1 - box.midY : box.midY) * root.bounds.height), to: nil))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reconnects, 1)
        XCTAssertTrue(disconnectedText.contains("Forget host"), disconnectedText)
        let forgetLabel = try XCTUnwrap(try disconnected.recognizedText()
            .first { $0.topCandidates(1).first?.string == "Forget host" })
        let forgetBox = forgetLabel.boundingBox
        try PresentationTestSupport.click(window, at: root.convert(NSPoint(x: forgetBox.midX * root.bounds.width,
            y: (root.isFlipped ? 1 - forgetBox.midY : forgetBox.midY) * root.bounds.height), to: nil))
        try await TestSupport.eventually { forgotten == 1 }

        // An offline host without a reconnect recipe still has one removal action.
        window.contentView = NSHostingView(rootView: HostInformationView(host: host, state: .disconnected,
            forget: { forgotten += 1 }))
        let forgetOnly = try await capture(window, "host-information-forget-only").text()
        XCTAssertTrue(forgetOnly.contains("Forget host"), forgetOnly)
        XCTAssertFalse(forgetOnly.contains("Reconnect"), forgetOnly)

        let workspace = Workspace()
        workspace.hosts.restore([host])
        window.setContentSize(NSSize(width: 500, height: 320))
        // Settings gives the card its width; unconstrained, wrapped details size the window.
        window.contentView = NSHostingView(rootView: SSHHostsSettings(workspace: workspace, permissions: SSHIntegrationPermissions(defaults: nil)).frame(width: 500))
        let troubleshooting = try await capture(window, "settings-offline-host-troubleshooting").text()
        for label in ["Remote hosts", "On new hosts", "Remote programs can copy", "homelab", "Reset all"] {
            XCTAssertTrue(troubleshooting.contains(label), troubleshooting)
        }
        XCTAssertFalse(troubleshooting.contains("Forget host…"), "Host actions stay in the collapsed editor")

        // Logins nest under the machine they reached; unmatched ones stay listed.
        let permissions = SSHIntegrationPermissions(defaults: nil)
        let reached = try XCTUnwrap(SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "homelab.test", configuration: "user ops\n"))
        let unmatched = try XCTUnwrap(SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "archive.test", configuration: "user carol\n"))
        permissions.save(.init(profile: .statistics), for: reached)
        permissions.save(.init(profile: .full, hooks: true), for: unmatched)
        window.setContentSize(NSSize(width: 500, height: 360))
        let settings = NSHostingView(rootView: SSHHostsSettings(workspace: workspace, permissions: permissions,
            logins: { $0 == host.id ? [reached.key] : [] }).frame(width: 500))
        window.contentView = settings
        let groupedSnapshot = try await capture(window, "settings-ssh-hosts-grouped")
        let grouped = try groupedSnapshot.text()
        for label in ["homelab", "ops@homelab.test", "stats", "OTHER LOGINS", "archive.test"] {
            XCTAssertTrue(grouped.contains(label), grouped)
        }
        let homelab = try XCTUnwrap(grouped.range(of: "homelab")), carol = try XCTUnwrap(grouped.range(of: "archive.test"))
        XCTAssertTrue(homelab.lowerBound < carol.lowerBound, "Unmatched logins follow the hosts: \(grouped)")

        // Clicking a host edits its login in place, and each change is saved at once.
        func click(_ title: String, in snapshot: PresentationTestSupport.Snapshot) throws {
            let observation = try XCTUnwrap(snapshot.recognizedText().first { $0.topCandidates(1).first?.string.contains(title) == true })
            let recognized = try XCTUnwrap(observation.topCandidates(1).first)
            let box = try XCTUnwrap(recognized.boundingBox(for: XCTUnwrap(recognized.string.range(of: title)))).boundingBox
            try PresentationTestSupport.click(window, at: settings.convert(NSPoint(x: box.midX * settings.bounds.width,
                y: (settings.isFlipped ? 1 - box.midY : box.midY) * settings.bounds.height), to: nil))
        }
        window.setContentSize(NSSize(width: 500, height: 640))
        try click("homelab", in: await capture(window, "settings-ssh-hosts-collapsed"))
        let editor = try await capture(window, "settings-ssh-hosts-editor")
        let editorText = try editor.text()
        for label in ["Dispatch helper", "Stats", "File access", "Agent hooks", "Codex", "Forget host"] {
            XCTAssertTrue(editorText.contains(label), editorText)
        }
        XCTAssertNil(permissions.agentHooks(reached)[.codex])
        try click("Codex", in: editor)
        try await TestSupport.eventually { permissions.agentHooks(reached)[.codex] == true }
        let saved = try XCTUnwrap(permissions.remembered(reached))
        XCTAssertEqual(saved.selectedFeatures, [.statistics, .chat, .tmux, .herdr, .hooks])
        XCTAssertEqual(permissions.agentHooks(reached)[.claude], false)
    }

    func testCompactConnectionRowsKeepBackendBadgesAndHelperActionsVisible() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let host = HostRecord(id: .authenticated("compact-connection"), name: "homelab", destinations: ["ops@homelab.test"], order: 0)
        let scope = SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "homelab.test", configuration: "hostname homelab.test\nuser ops\n")!
        var changes = 0, resets = 0
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 356, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close(); window.contentView = nil }
        for (profile, title, size, width) in [
            (SSHIntegrationProfile.ordinary, "no helper", 12.5, 356.0),
            (.statistics, "stats only", 12.5, 356.0),
            (.full, "6 features", 12.5, 280.0),
            (.full, "6 features", 22.0, 626.0)
        ] {
            let typography = AppTypography(contentSize: size)
            let entry = SSHIntegrationPermissions.Entry(scope: scope, grant: .init(profile: profile))
            func content(_ backends: Set<SpaceBackend>?) -> some View {
                HostConnectionDetails(host: host, backends: backends, checkingBackends: true, integrations: [entry],
                    changeIntegration: { selected in XCTAssertEqual(selected.id, entry.id); changes += 1 },
                    resetIntegration: { selected in XCTAssertEqual(selected.id, entry.id); resets += 1 })
                    .padding(18).background(StatsStyle.popover).environment(\.appTypography, typography).preferredColorScheme(.dark)
            }
            let root = NSHostingView(rootView: content(nil))
            window.setContentSize(NSSize(width: width, height: typography.expanded(100)))
            window.contentView = root
            window.makeKeyAndOrderFront(nil)
            _ = try await capture(window, "host-details-loading")
            let loadingHeight = root.fittingSize.height
            root.rootView = content([.native, .tmux, .herdr])
            let snapshot = try await capture(window, "host-details-\(profile.rawValue)-\(Int(width))")
            let text = try snapshot.text()
            // Vision can interleave right-aligned words with badges above and
            // misclassify the case of individual lowercase glyphs.
            for label in ["ssh", "tmux", "herdr", "integration"] {
                XCTAssertTrue(text.lowercased().contains(label), text)
            }
            // Full-image OCR can merge the isolated feature count with the
            // backend badges above. Read the status row separately, retaining
            // the exact count assertion against the actual rendered pixels.
            let statusText = try snapshot.text(in: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.55), corrected: false)
            XCTAssertTrue(statusText.lowercased().contains(title), statusText)
            XCTAssertFalse(text.lowercased().contains("reset"), text)
            XCTAssertFalse(text.contains("Available backends"), text)
            XCTAssertFalse(text.contains(".dispatch"), text)
            XCTAssertEqual(root.fittingSize.height, loadingHeight, accuracy: 0.5)
            for title in ["Integration"] {
                let observation = try XCTUnwrap(snapshot.recognizedText().first { $0.topCandidates(1).first?.string.contains(title) == true })
                let recognized = try XCTUnwrap(observation.topCandidates(1).first)
                let range = try XCTUnwrap(recognized.string.range(of: title))
                let box = try XCTUnwrap(recognized.boundingBox(for: range)).boundingBox
                let point = NSPoint(x: box.midX * root.bounds.width, y: (root.isFlipped ? 1 - box.midY : box.midY) * root.bounds.height)
                try PresentationTestSupport.click(window, at: root.convert(point, to: nil))
                // SwiftUI handles the posted mouse-up on the next event turn.
                try await Task.sleep(for: .milliseconds(50))
            }
            if width == 280 {
                for (backends, expected, absent) in [
                    (Set<SpaceBackend>([.native]), "no tmux or herdr", ""),
                    ([.native, .tmux], "tmux", "herdr"),
                    ([.native, .herdr], "herdr", "tmux")
                ] {
                    root.rootView = content(backends)
                    let snapshot = try await capture(window, "host-backends-\(expected.replacingOccurrences(of: " ", with: "-"))")
                    let text = try snapshot.text()
                    try PresentationTestSupport.assertText(expected, in: snapshot, rendered: window.contentView)
                    if !absent.isEmpty { XCTAssertFalse(text.contains(absent), text) }
                    XCTAssertEqual(root.fittingSize.height, loadingHeight, accuracy: 0.5)
                }
            }
        }
        XCTAssertEqual(changes, 4)
        XCTAssertEqual(resets, 0, "Changing the profile must not reset integration permissions")
    }

    func testRemoteHostLatencyKeepsPopupSizeWhileLoadingReadyAndStale() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        final class Provider: SSHStatisticsSampling {
            let id = SSHConnectionID()
            let scope = SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "homelab", configuration: "hostname homelab\nuser ops\n")!
            let host = "latency-presentation"
            let uid: UInt32 = 1000
            let supportsStatistics = true
            let supportsLatency = true
            var pingFails = false
            var finish: CheckedContinuation<Void, Never>?
            func ping() async throws {
                await withCheckedContinuation { finish = $0 }
                if pingFails { throw HerdrFailure("Latency timeout") }
            }
            func sample() async throws -> SSHStatisticsCounters {
                .init(boot: "boot", monotonic: 1, memoryTotal: 8_589_934_592, memoryUsed: 4_294_967_296, load: [1.25])
            }
            func disks() async throws -> [SSHStatisticsDisk] { [] }
        }
        let provider = Provider(), store = SSHStatisticsStore.shared
        let host = HostRecord(id: .authenticated(UUID().uuidString), name: "homelab", hostname: "homelab",
                              system: .init(os: "Linux", distribution: "ubuntu", name: "Ubuntu 26.04"),
                              destinations: ["ops@homelab.test"], order: 0)
        let key = try XCTUnwrap(store.register(provider, grant: .init(profile: .statistics), hostID: host.id))
        let latency = try XCTUnwrap(store.series[key]?.latency)
        try await TestSupport.eventually { provider.finish != nil }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 356, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSHostingView(rootView: HostInformationView(host: host, state: .connected, disconnect: {}, preferred: provider.id))
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer {
            window.close(); window.contentView = nil
            store.remove(provider.id)
            provider.finish?.resume(); provider.finish = nil
        }
        // Opening during the first probe cancels and drains it before refreshing.
        try await TestSupport.eventually { provider.finish != nil }
        provider.finish?.resume(); provider.finish = nil
        try await TestSupport.eventually { provider.finish != nil }
        _ = try await capture(window, "host-latency-loading")
        let loadingSize = root.fittingSize
        provider.finish?.resume(); provider.finish = nil
        try await TestSupport.eventually { latency.state == .ready }
        let ready = try await capture(window, "host-latency-ready").text()
        XCTAssertTrue(ready.contains("ms"), ready)
        XCTAssertTrue(ready.contains("Integration unavailable"), ready)
        XCTAssertFalse(ready.contains("Available backends"), ready)
        XCTAssertEqual(root.fittingSize, loadingSize)
        XCTAssertTrue(latency.help.contains("Last measured"))
        provider.pingFails = true
        try await TestSupport.eventually { provider.finish != nil }
        provider.finish?.resume(); provider.finish = nil
        try await TestSupport.eventually { latency.state == .stale }
        let stale = try await capture(window, "host-latency-stale").text()
        XCTAssertTrue(stale.contains("stale"), stale)
        XCTAssertEqual(root.fittingSize, loadingSize)
        let large = AppTypography(contentSize: 22)
        window.setContentSize(NSSize(width: large.expanded(356), height: large.popoverHeight(700)))
        window.contentView = NSHostingView(rootView: HostInformationView(host: host, state: .connected, preferred: provider.id)
            .environment(\.appTypography, large))
        let enlarged = try await capture(window, "host-latency-large-font").text()
        XCTAssertTrue(enlarged.contains("ms"), enlarged)
        XCTAssertTrue(enlarged.contains("stale"), enlarged)
        window.contentView = NSHostingView(rootView: HostInformationView(host: host, state: .disconnected, preferred: provider.id)
            .environment(\.appTypography, large))
        let disconnected = try await capture(window, "host-latency-disconnected").text()
        XCTAssertTrue(disconnected.contains("disconnected"), disconnected)
        XCTAssertFalse(disconnected.contains("ms"), disconnected)
        XCTAssertFalse(disconnected.contains("stale"), disconnected)
    }

    func testRemoteStatsPreferCurrentAccountShowUnknownRatesAndStayStaleAfterDisconnect() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        final class Provider: SSHStatisticsSampling {
            let id = SSHConnectionID()
            let scope: SSHIntegrationScope
            let host = "remote-stats-fixture"
            let hostname: String? = "remote-orion"
            let uid: UInt32 = 1000
            let supportsStatistics = true
            var samples = 0
            init(_ account: String) {
                scope = SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "orion", configuration: "hostname orion\nuser \(account)\n")!
            }
            func sample() async throws -> SSHStatisticsCounters {
                samples += 1
                return .init(boot: "boot", monotonic: Double(samples), memoryTotal: 8 * 1_073_741_824,
                             memoryUsed: 4 * 1_073_741_824, swapUsed: 0, load: [1.25, 1, 1], uptime: 345)
            }
            func disks() async throws -> [SSHStatisticsDisk] {
                [.init(paths: ["/", "/home/bob"], identity: "disk", total: 100 * 1_073_741_824, free: 80 * 1_073_741_824)]
            }
        }
        let host = HostRecord(id: .authenticated("stats-presentation-" + UUID().uuidString), name: "Orion",
                              hostname: "remote-orion", system: .init(os: "Linux"), destinations: ["alice@orion", "bob@orion"], order: 0)
        let alice = Provider("alice"), bob = Provider("bob"), store = SSHStatisticsStore.shared
        let aliceKey = try XCTUnwrap(store.register(alice, grant: .init(profile: .statistics), hostID: host.id))
        let bobKey = try XCTUnwrap(store.register(bob, grant: .init(profile: .statistics), hostID: host.id))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 356, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.close(); window.contentView = nil
            store.remove(alice.id); store.remove(bob.id)
        }
        window.contentView = NSHostingView(rootView: HostStatsView(host: host, preferred: bob.id).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        let text = try await capture(window, "stats-remote-account").text()
        XCTAssertTrue(text.contains("remote-orion"), text)
        XCTAssertTrue(text.contains("bob"), text)
        XCTAssertTrue(text.contains("50"), text)
        XCTAssertGreaterThan(alice.samples, 0)
        XCTAssertGreaterThan(bob.samples, 0)
        XCTAssertNil(store.series[bobKey]?.latest?.cpu)
        XCTAssertNotNil(store.series[aliceKey]?.latest)
        store.remove(bob.id)
        let stale = try await capture(window, "stats-remote-stale").text()
        XCTAssertTrue(stale.contains("Disconnected or paused"), stale)
        XCTAssertTrue(stale.contains("50"), stale)
        XCTAssertNotNil(store.series[aliceKey]?.latest, "Background sampling must not replace the explicitly selected account")
    }

    func testDiagnosticsCheckboxShowsCopyableFullPathOnlyWhenEnabled() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(file: directory.appendingPathComponent("settings.json"))
        let diagnostics = ChatViewportTrace(writer: ChatViewportTraceWriter(directory: directory.appendingPathComponent("Diagnostics")))
        defer { diagnostics.setEnabled(false) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 550), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSHostingView(rootView: SettingsView(store: store, workspace: app.workspace, diagnostics: diagnostics))
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentView = nil }
        let pasteboard = NSPasteboard.general
        let originalClipboard = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { pasteboard.clearContents(); pasteboard.writeObjects(originalClipboard) }
        func bottom() async throws {
            try await Task.sleep(for: .milliseconds(300))
            let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: root).first { !$0.isHiddenOrHasHiddenAncestor })
            let document = try XCTUnwrap(scroll.documentView)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        func click(_ label: String) async throws {
            let snapshot = try await capture(window, "settings-diagnostics-control")
            let text = try XCTUnwrap(try snapshot.recognizedText().compactMap { $0.topCandidates(1).first }
                .first { $0.string.contains(label) })
            let range = try XCTUnwrap(text.string.range(of: label))
            let box = try XCTUnwrap(text.boundingBox(for: range)).boundingBox
            try PresentationTestSupport.click(window, at: root.convert(NSPoint(x: box.midX * root.bounds.width,
                y: (root.isFlipped ? 1 - box.midY : box.midY) * root.bounds.height), to: nil))
        }
        // Diagnostics is a switch in the Extra page's Troubleshooting group.
        try await click("Extra")
        try await Task.sleep(for: .milliseconds(200))
        func toggleDiagnostics() async throws {
            try await bottom()
            let snapshot = try await capture(window, "settings-diagnostics-control")
            let row = try XCTUnwrap(try snapshot.recognizedText().first { $0.topCandidates(1).first?.string == "Diagnostics" })
            try PresentationTestSupport.click(window, at: root.convert(NSPoint(x: root.bounds.width - 60,
                y: (root.isFlipped ? 1 - row.boundingBox.midY : row.boundingBox.midY) * root.bounds.height), to: nil))
        }
        try await bottom()
        let disabled = try await capture(window, "settings-diagnostics-disabled").text()
        XCTAssertTrue(disabled.contains("Diagnostics"), disabled)
        XCTAssertFalse(disabled.contains("Copy path"), disabled)
        XCTAssertFalse(store.values.enableDiagnostics)
        XCTAssertFalse(FileManager.default.fileExists(atPath: diagnostics.directory.path))
        try await toggleDiagnostics()
        try await TestSupport.eventually { store.values.enableDiagnostics && diagnostics.isEnabled }
        XCTAssertTrue(SettingsStore(file: directory.appendingPathComponent("settings.json")).values.enableDiagnostics)
        try await bottom()
        let enabled = try await capture(window, "settings-diagnostics-enabled").text()
        XCTAssertTrue(enabled.contains("Copy path"), enabled)
        try await click("Copy path")
        try await TestSupport.eventually { pasteboard.string(forType: .string) == diagnostics.directory.path }
        try await TestSupport.eventually { FileManager.default.fileExists(atPath: diagnostics.directory.appendingPathComponent("diagnostics.json").path) }
        try await toggleDiagnostics()
        try await TestSupport.eventually { !store.values.enableDiagnostics && !diagnostics.isEnabled }
        try await bottom()
        let stopped = try await capture(window, "settings-diagnostics-stopped").text()
        XCTAssertFalse(stopped.contains("Copy path"), stopped)
    }

    func testSettingsNativeControlsRemainVisibleWithImplementedOptions() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(file: directory.appendingPathComponent("settings.json"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 550), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(store: store, workspace: Workspace(),
            sshPermissions: SSHIntegrationPermissions(defaults: nil)))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentView = nil }
        let root = try XCTUnwrap(window.contentView)
        for (tab, labels) in [
            ("Appearance", ["Terminal font", "Chat font", "Size", "Theme", "Custom terminal", "Liquid Glass", "Sidebar & tabs", "Large space list", "Hide Git branches", "Hide with one space", "Automatic tab names"]),
            ("Keys", ["Number keys", "Spaces", "Tabs", "Splits", "Keyboard", "Use Option as Alt"]),
            ("Integrations", ["Agents", "show coding agent CLIs as chat", "Codex", "Claude", "Pi", "tmux & herdr", "Open tmux sessions as spaces", "tmux -CC attach", "Open herdr sessions as spaces"]),
            ("Hosts", ["Remote hosts", "On new hosts", "Ask"]),
            ("Extra", ["Startup", "Starting folder", "Reopen spaces on launch", "Restore tab history", "Notifications", "Notify", "Dock badge", "Sound", "Troubleshooting", "Diagnostics"])
        ] {
            if tab != "Appearance" { try await PresentationTestSupport.selectSettingsTab(tab, in: window) }
            var snapshots = [try await capture(window, "settings-\(tab)")]
            var text = try snapshots[0].text()
            let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: root).first { !$0.isHiddenOrHasHiddenAncestor })
            let document = try XCTUnwrap(scroll.documentView)
            let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
            var offset: CGFloat = 0
            while offset < bottom {
                offset = min(bottom, offset + max(1, scroll.contentView.bounds.height * 0.75))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
                snapshots.append(try await capture(window, "settings-\(tab)-scroll"))
                text += "\n" + (try snapshots.last!.text())
            }
            // 40a2a2d variant-aware reading (uncorrected, enlarged, tiles) for every expected label.
            for label in labels {
                XCTAssertTrue(try snapshots.contains { try $0.reads([label]) }, "Missing \(label) in \(tab):\n\(text)")
            }
            if tab == "Extra" {
                // Extra fits a 1280×832 screen's usable height without scrolling; Appearance scrolls there.
                let needed = document.bounds.height + root.bounds.height - scroll.contentView.bounds.height
                XCTAssertLessThanOrEqual(needed, 795, "\(tab) needs \(needed) pt")
            }
            if tab == "Appearance" {
                XCTAssertFalse(text.contains("Use Option as Alt"), "Keyboard behaviour lives under Keys")
                XCTAssertFalse(text.contains("Remote hosts"), "Hosts have their own page")
                XCTAssertFalse(text.contains("Improve text contrast"), "Custom colors start collapsed")
            }
            if tab == "Keys" {
                // OCR misreads ⌃ and ⌘; the recorders report their shortcuts to accessibility.
                let recorders = PresentationTestSupport.views(of: KeyGroupRecorder.RecorderView.self, in: root)
                XCTAssertEqual(recorders.map { $0.accessibilityValue() as? String }, ["⇧⌘1…9", "⌘1…9", "⌃1…4"])
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("settings.json").path), "Opening Settings must not save or change preferences")
    }

    func testSettingsListsDisconnectedHostIntegrationsAndResetsAll() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(file: directory.appendingPathComponent("settings.json"))
        let permissions = SSHIntegrationPermissions(defaults: nil)
        let scopes = [
            SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "build.example", configuration: "hostname build.example\nuser alice\n")!,
            SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "build.example", configuration: "hostname build.example\nuser bob\n")!,
            SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "archive.example", configuration: "hostname archive.example\nuser carol\n")!
        ]
        for (scope, profile) in zip(scopes, [SSHIntegrationProfile.full, .statistics, .ordinary]) {
            permissions.save(.init(profile: profile), for: scope)
        }
        var revoked: Set<String> = []
        permissions.onChange = { scope, grant in
            XCTAssertEqual(grant.profile, .ordinary)
            revoked.insert(scope.key)
        }
        // Fits a 1280×832 desktop, so clicks land on screen; the page scrolls.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var resets = 0
        var connected = true
        let root = NSHostingView(rootView: SettingsView(store: store, workspace: Workspace(), sshPermissions: permissions,
            hasActiveSSHConnections: { connected }, resetSSHState: { resets += 1 }))
        window.contentView = root
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentView = nil }
        func click(_ title: String, in snapshot: PresentationTestSupport.Snapshot) throws {
            // 40a2a2d variant-aware reading: same retries and tiles as Snapshot.reads.
            let box = try XCTUnwrap(snapshot.box(of: title), title)
            let point = NSPoint(x: box.midX * root.bounds.width, y: (root.isFlipped ? 1 - box.midY : box.midY) * root.bounds.height)
            try PresentationTestSupport.click(window, at: root.convert(point, to: nil))
        }
        try click("Hosts", in: await capture(window, "settings-host-list-tabs"))
        // The hosts list ends the page.
        @MainActor func scrollToBottom() throws {
            let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: root).first { !$0.isHiddenOrHasHiddenAncestor })
            let document = try XCTUnwrap(scroll.documentView)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        // SwiftUI can reset the scroll position during layout; retry until the
        // last listed login is on screen.
        try await TestSupport.eventually {
            try scrollToBottom()
            return try await PresentationTestSupport.capture(window).text().lowercased().contains("carol")
        }
        let snapshot = try await capture(window, "settings-host-integrations")
        // Vision may insert a space after punctuation in monospaced hostnames.
        let text = try snapshot.text().lowercased().replacingOccurrences(of: ". ", with: ".")
        for label in ["remote hosts", "reset all", "other logins", "plain ssh", "stats", "files", "alice", "bob", "carol", "build.example", "archive.example"] {
            XCTAssertTrue(text.contains(label), text)
        }
        // All entries remain listed even though this workspace has no remote hosts.
        XCTAssertEqual(permissions.entries.count, 3)
        try click("Reset all", in: snapshot)
        try await TestSupport.eventually { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        let cancel = try XCTUnwrap(PresentationTestSupport.views(of: NSButton.self, in: XCTUnwrap(sheet.contentView)).first { $0.title == "Cancel" })
        cancel.performClick(nil)
        try await TestSupport.eventually { window.attachedSheet == nil }
        XCTAssertEqual(resets, 0)
        XCTAssertEqual(permissions.entries.count, 3)
        try click("Reset all", in: await capture(window, "settings-host-reset-cancelled"))
        try await TestSupport.eventually { window.attachedSheet != nil }
        let confirm = try XCTUnwrap(PresentationTestSupport.views(of: NSButton.self, in: XCTUnwrap(window.attachedSheet?.contentView)).first { $0.title == "Forget all" })
        confirm.performClick(nil)
        try await TestSupport.eventually { permissions.entries.isEmpty }
        XCTAssertEqual(resets, 1)
        XCTAssertEqual(revoked, Set(scopes.map(\.key)))
        connected = false
        try scrollToBottom()
        let emptySnapshot = try await capture(window, "settings-host-integrations-empty")
        let empty = try emptySnapshot.text()
        XCTAssertFalse(empty.lowercased().contains("carol"), empty)
        // With nothing listed or connected, Reset all clears saved state at once.
        try click("Reset all", in: emptySnapshot)
        try await TestSupport.eventually { resets == 2 }
        XCTAssertNil(window.attachedSheet)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("settings.json").path))
    }

    func testSettingsFitsAppearancePageAndPreservesVerticalResizing() async throws {
        try DesktopTestSupport.requireUnlocked()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = AppDelegate(settings: SettingsStore(file: directory.appendingPathComponent("settings.json")))
        let existing = Set(NSApp.windows.map(\.windowNumber))
        controller.showSettings()
        let window = try XCTUnwrap(NSApp.windows.first { !existing.contains($0.windowNumber) && $0.title == "Settings" })
        defer { window.close(); window.contentView = nil }
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.minSize.width, 560)
        XCTAssertEqual(window.maxSize.width, 560)
        XCTAssertGreaterThan(window.maxSize.height, window.minSize.height)
        try await TestSupport.eventually {
            guard let root = window.contentView,
                  let scroll = PresentationTestSupport.views(of: NSScrollView.self, in: root).first,
                  let document = scroll.documentView, let screen = window.screen else { return false }
            let text = try await PresentationTestSupport.capture(window, named: "settings-default-height").text()
            let fitsPage = document.bounds.height <= scroll.contentView.bounds.height + 1
            let fillsScreen = window.frame.height >= screen.visibleFrame.height - 2
            return (fitsPage || fillsScreen)
                // Settings opens on Appearance.
                && text.contains("Terminal font") && text.contains("Theme")
                // The last row is below the fold when a short screen caps the window.
                && (!fitsPage || text.contains("Liquid Glass"))
                && !text.contains("Improve text contrast")
                && window.frame.height <= screen.visibleFrame.height + 2
        }
        _ = try await capture(window, "settings-default-height")
        let initial = window.frame
        var resized = initial
        // The fitted window may already fill the screen, so the manual resize shrinks it.
        resized.size.height = max(window.minSize.height, initial.height - 120)
        resized.origin.y -= resized.height - initial.height
        window.setFrame(resized, display: true)
        _ = try await capture(window, "settings-resized-height")
        XCTAssertLessThan(window.frame.height, initial.height)
        XCTAssertEqual(window.frame.height, resized.height, accuracy: 1, "Initial fitting must not undo a manual resize")
        XCTAssertEqual(window.frame.width, initial.width)
        window.close()
        controller.showSettings()
        _ = try await capture(window, "settings-reopened-height")
        XCTAssertEqual(window.frame.height, resized.height, accuracy: 1, "Reopening must preserve the user's height")
    }

    private func selectCPU(in window: NSWindow, waitForExpansion: Bool = true) async throws {
        try await Task.sleep(for: .milliseconds(300))
        let root = try XCTUnwrap(window.contentView)
        // The load detail avoids OCR ambiguity between Latin and Cyrillic CPU labels.
        let snapshot = try await PresentationTestSupport.capture(window, named: "before-select-cpu", in: "stats-validation")
        let observed = try snapshot.text()
        let label = try XCTUnwrap(try snapshot.recognizedText()
            .first { $0.topCandidates(1).first?.string.contains("load") == true }, observed)
        let box = label.boundingBox
        try PresentationTestSupport.click(window, at: root.convert(NSPoint(x: box.midX * root.bounds.width,
            y: (root.isFlipped ? 1 - box.midY : box.midY) * root.bounds.height), to: nil))
        if waitForExpansion { try await Task.sleep(for: .milliseconds(350)) }
    }

    private func capture(_ window: NSWindow, _ name: String) async throws -> PresentationTestSupport.Snapshot {
        try await Task.sleep(for: .milliseconds(300))
        return try await PresentationTestSupport.capture(window, named: name)
    }
}

extension SettingsStatsPresentationTests {
    func testStatisticsPopoverDoesNotEnlargeItsHostingWindow() async throws {
        try DesktopTestSupport.requireUnlocked()
        let provider = RemoteProcessProvider(), store = SSHStatisticsStore.shared
        let record = HostRecord(id: .authenticated(provider.host), name: "Statistics test", destinations: [], order: 0)
        let key = try XCTUnwrap(store.register(provider, grant: .init(profile: .statistics), hostID: record.id))
        defer { store.remove(provider.id) }
        let entry = try XCTUnwrap(store.series[key])
        entry.state = .ready
        entry.processes = [.init(id: 1, name: "yes", cpu: 99.9, memory: 1024)]
        for size: CGFloat in [12.5, 22] {
            let typography = AppTypography(contentSize: size)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 450),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.orderOut(nil); window.contentView = nil }
            window.contentView = NSHostingView(rootView: HostStatsView(host: record, preferred: provider.id, samplesAutomatically: false)
                .environment(\.appTypography, typography))
            window.orderFront(nil)
            try await selectCPU(in: window)
            let root = try XCTUnwrap(window.contentView)
            root.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(root.bounds.height, ceil(typography.popoverHeight(620)),
                                     "The hosting window retained a compressed-width minimum: \(window.contentMinSize)")
        }
    }

    private final class RemoteProcessProvider: SSHStatisticsSampling {
        let id = SSHConnectionID()
        let scope = SSHIntegrationScope(executable: "/usr/bin/ssh", destination: UUID().uuidString, configuration: "user fixture")!
        let host = UUID().uuidString
        let uid: UInt32 = 1000
        let supportsStatistics = true
        func sample() async throws -> SSHStatisticsCounters {
            .init(boot: "boot", monotonic: ProcessInfo.processInfo.systemUptime,
                  memoryTotal: 8_589_934_592, memoryUsed: 4_294_967_296, load: [0.5, 0.5, 0.5])
        }
        func disks() async throws -> [SSHStatisticsDisk] { [] }
    }
    func testProcessSamplingDoesNotChangePopupContentHeight() async throws {
        let provider = RemoteProcessProvider(), store = SSHStatisticsStore.shared
        let record = HostRecord(id: .authenticated(provider.host), name: "Height fixture", destinations: [], order: 0)
        let key = try XCTUnwrap(store.register(provider, grant: .init(profile: .statistics), hostID: record.id))
        defer { store.remove(provider.id) }
        let entry = try XCTUnwrap(store.series[key]); entry.state = .ready
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 356, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil }
        window.orderFront(nil)
        let rows: [HostProcess] = (1...3).map { .init(id: $0, name: "worker-\($0)", cpu: Double($0), memory: 1024) }
        let unknown: [HostProcess] = rows.map { .init(id: $0.id, name: $0.name, cpu: nil, memory: $0.memory) }
        for size: CGFloat in [12.5, 22] {
            entry.processes = nil
            let host = NSHostingView(rootView: HostStatsView(host: record, preferred: provider.id, samplesAutomatically: false, showsIdentity: false)
                .environment(\.appTypography, AppTypography(contentSize: size)))
            window.contentView = host
            try await Task.sleep(for: .milliseconds(100))
            let collapsedHeight = host.fittingSize.height
            window.setContentSize(NSSize(width: 356, height: collapsedHeight))
            host.layoutSubtreeIfNeeded()
            // This embedded view starts with the CPU metric in its top-left corner.
            try PresentationTestSupport.click(window, at: host.convert(NSPoint(x: 30,
                y: host.isFlipped ? 20 : host.bounds.height - 20), to: nil))
            try await Task.sleep(for: .milliseconds(100))
            let initialHeight = host.fittingSize.height
            XCTAssertGreaterThan(initialHeight, collapsedHeight)
            window.setContentSize(NSSize(width: 356, height: initialHeight))
            for processes: [HostProcess]? in [[], unknown, Array(rows.prefix(1)), Array(rows.prefix(2)), rows, nil] {
                entry.processes = processes
                try await Task.sleep(for: .milliseconds(75))
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.height, initialHeight, accuracy: 0.5,
                    "Process availability/count must not resize the popup at font size \(size)")
            }
        }
    }

    func testRemotePartialProcessesShowMemoryBeforeCPUAndRetainStaleRows() async throws {
        try DesktopTestSupport.requireUnlocked()
        let provider = RemoteProcessProvider(), store = SSHStatisticsStore.shared
        let record = HostRecord(id: .authenticated(provider.host), name: "Remote fixture", destinations: [], order: 0)
        let key = try XCTUnwrap(store.register(provider, grant: .init(profile: .statistics), hostID: record.id))
        defer { store.remove(provider.id) }
        let entry = try XCTUnwrap(store.series[key])
        entry.state = .ready; entry.processesPartial = true
        entry.processes = (1...4).map { .init(id: $0, name: "memory-worker-\($0)", cpu: nil, memory: UInt64($0) * 1_073_741_824) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil }
        window.contentView = NSHostingView(rootView: HostStatsView(host: record, preferred: provider.id, samplesAutomatically: false))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        try await selectCPU(in: window)
        try await Task.sleep(for: .milliseconds(150))
        let first = try await PresentationTestSupport.capture(window, named: "remote-partial-unknown-cpu", in: "stats-validation")
        XCTAssertTrue(try first.text().contains("partial")); XCTAssertTrue(try first.text().contains("Measuring process CPU"))
        let root = try XCTUnwrap(window.contentView)
        let label = try XCTUnwrap(try first.recognizedText().first { $0.topCandidates(1).first?.string == "mem" })
        let box = label.boundingBox
        try PresentationTestSupport.click(window, at: root.convert(NSPoint(x: box.midX * root.bounds.width,
            y: (root.isFlipped ? 1 - box.midY : box.midY) * root.bounds.height), to: nil))
        try await Task.sleep(for: .milliseconds(350))
        let memory = try await PresentationTestSupport.capture(window, named: "remote-partial-memory", in: "stats-validation").text()
        XCTAssertTrue(memory.contains("memory-worker-4"), memory); XCTAssertTrue(memory.contains("memory-worker-2"), memory)
        XCTAssertFalse(memory.contains("memory-worker-1"))
        entry.state = .stale
        try await Task.sleep(for: .milliseconds(100))
        let stale = try await PresentationTestSupport.capture(window).text()
        XCTAssertTrue(stale.contains("Disconnected or paused")); XCTAssertTrue(stale.contains("memory-worker-4"))
        entry.processes = nil; entry.processesPartial = false; entry.state = .ready
        try await Task.sleep(for: .milliseconds(100))
        let visible = try await PresentationTestSupport.capture(window).text()
        XCTAssertTrue(visible.contains("Process data unavailable"))
    }
}
