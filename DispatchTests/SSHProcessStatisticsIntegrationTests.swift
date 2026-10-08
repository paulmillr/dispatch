import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor final class SSHProcessStatisticsIntegrationTests: XCTestCase {
    func testMacOSStatisticsProfileProcessRowsAndTerminalTraffic() async throws {
        let server = try await SSHTestServer(grant: .init(profile: .statistics)); defer { server.stop() }
        try await smoke(options: server.options, destination: server.destination, profile: .statistics, platform: "macos")
    }
    func testMacOSFullProfileProcessRowsAndTerminalTraffic() async throws {
        let server = try await SSHTestServer(grant: .init(profile: .full)); defer { server.stop() }
        try await smoke(options: server.options, destination: server.destination, profile: .full, platform: "macos")
    }
    func testLinuxProcessRowsAndTerminalTraffic() async throws {
        let url = SSHLinuxTestProfile.configurationURL()
        let target = try JSONDecoder().decode(SSHLinuxTestProfile.self, from: Data(contentsOf: url))
        for profile in [SSHIntegrationProfile.statistics, .full] {
            try await smoke(options: target.options, destination: target.destination, profile: profile, platform: "linux")
        }
    }
    private func smoke(options: [String], destination: String, profile: SSHIntegrationProfile, platform: String) async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let origin = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { app.runtime.views[origin].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let terminal = try XCTUnwrap(app.runtime.views[origin])
        try await SSHTestServer.authorize(arguments: options + [destination], grant: .init(profile: profile))
        TerminalTestSupport.send("ssh " + (options + [destination]).map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
        try await TestSupport.eventually(timeout: .seconds(30), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == origin && $0.shellPID != nil }
        }
        let session = try XCTUnwrap(app.runtime.ssh.links.values.first { $0.launch.tabID == origin })
        // The visible facts below (process rows, latency) cover these; capability names differ by route.
        // Keep the real CPU/process-name probe, but bound it even if the SSH transport disappears.
        let launch = "import os, signal; signal.alarm(60); os.execv('/usr/bin/yes', ['yes'])"
        TerminalTestSupport.send("/usr/bin/python3 -c " + HerdrLaunch.quote(launch)
            + " >/dev/null & dispatch_stats_pid=$!; printf 'STATS_PID=%s\\n' \"$dispatch_stats_pid\"", to: terminal)
        func cleanup() async throws {
            TerminalTestSupport.send("kill \"$dispatch_stats_pid\" 2>/dev/null; wait \"$dispatch_stats_pid\" 2>/dev/null; printf 'STATS_CLEANED_%s\\n' READY", to: terminal)
            try await TestSupport.eventually(timeout: .seconds(5), diagnostic: "CPU fixture cleanup did not complete") {
                TerminalTestSupport.screen(terminal: terminal).contains("STATS_CLEANED_READY")
            }
        }
        do {
            var pid: Int?
            try await TestSupport.eventually(diagnostic: "CPU fixture PID missing") {
                let screen = TerminalTestSupport.screen(terminal: terminal)
                if let match = screen.range(of: #"STATS_PID=[0-9]+"#, options: .regularExpression) { pid = Int(screen[match].dropFirst(10)) }
                return pid != nil
            }
            let store = HostStatisticsStore.shared
            let source = store.source(host: .authenticated(session.greeting.host), preferred: session.launch.connectionID)
            let subscription = try XCTUnwrap(store.subscribe(source, preferred: session.launch.connectionID))
            defer { store.unsubscribe(subscription) }
            guard case .ssh(let key) = source else {
                try await cleanup()
                return XCTFail("Expected a remote statistics source")
            }
            try await TestSupport.eventually(timeout: .seconds(5)) { store.remote.series[key]?.latency.state == .ready }
            XCTAssertNotNil(store.remote.series[key]?.latency.milliseconds)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "CPU fixture \(String(describing: pid)): \(String(describing: store.snapshot(source).processes?.first { $0.id == pid }))") {
                let snapshot = store.snapshot(source)
                return snapshot.processes?.contains { $0.id == pid && ($0.cpu ?? 0) > 10 && ($0.cpu ?? 1000) < 200 && $0.memory > 0 } == true
            }
            let sample = store.snapshot(source)
            XCTAssertNotNil(sample.memoryTotal); XCTAssertNotNil(sample.cpu)
            XCTAssertTrue(sample.topCPU.prefix(3).contains { $0.id == pid })
            let record = HostRecord(id: .authenticated(session.greeting.host), name: "Statistics test", destinations: [destination], order: 0)
            let view = NSHostingView(rootView: HostStatsView(host: record, preferred: session.launch.connectionID, samplesAutomatically: false))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil }
            try await Task.sleep(for: .milliseconds(100))
            // Process rows are disclosed by selecting the CPU metric.
            let metrics = try await PresentationTestSupport.capture(window, named: "metrics-\(platform)-\(profile.rawValue)", in: "stats-validation")
                .recognizedText()
            print("Statistics metrics \(platform) \(profile.rawValue): \(metrics.compactMap { $0.topCandidates(1).first?.string })")
            let load = try XCTUnwrap(metrics
                .first { $0.topCandidates(1).first?.string.contains("load") == true }).boundingBox
            try PresentationTestSupport.click(window, at: view.convert(NSPoint(x: load.midX * view.bounds.width,
                y: (view.isFlipped ? 1 - load.midY : load.midY) * view.bounds.height), to: nil))
            try await Task.sleep(for: .milliseconds(300))
            let image = try await PresentationTestSupport.capture(window, named: "processes-\(platform)-\(profile.rawValue)", in: "stats-validation")
            XCTAssertTrue(try image.text().contains("yes"))
            for index in 0..<3 {
                let started = ContinuousClock.now
                TerminalTestSupport.send("printf 'STATS_TRAFFIC_%s\\n' \(index)", to: terminal)
                try await TestSupport.eventually(timeout: .seconds(3)) { TerminalTestSupport.screen(terminal: terminal).contains("STATS_TRAFFIC_\(index)") }
                XCTAssertLessThan(started.duration(to: .now), .seconds(3))
            }
            print("Verified \(platform) \(profile.rawValue): fixture PID \(pid!), CPU \(sample.processes!.first { $0.id == pid }!.cpu!), RSS present; terminal responsive")
        } catch {
            try? await cleanup()
            throw error
        }
        try await cleanup()
    }
}
