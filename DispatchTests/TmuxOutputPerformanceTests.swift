import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class TmuxOutputPerformanceTests: XCTestCase {
    func testFindAndLargeOutputKeepNativePaneResponsive() async throws {
        let app = try TmuxWalkthrough()
        defer { app.close() }
        try await app.attach(); try await app.ready()
        let tab = try XCTUnwrap(app.workspace.activeTab)
        let terminal = try XCTUnwrap(app.runtime.views[tab.id])
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let artifacts = root.appendingPathComponent("build/tmux-output-validation")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let fixture = artifacts.appendingPathComponent("paths.txt")
        // A repeatable ~20 MiB burst, matching a find of the developer checkout.
        let row = "./build/Build/Intermediates.noindex/Dispatch.build/Debug/Dispatch.build/Objects-normal/arm64/" + String(repeating: "x", count: 40) + ".swift\n"
        let bytes = Data(String(repeating: row, count: 164_549).utf8)
        try bytes.write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }

        var report: [String] = []
        for (name, command) in [
            ("find", "cd \(HerdrLaunch.quote(root.path)) && /usr/bin/find . -print"),
            ("burst", "/bin/cat \(HerdrLaunch.quote(fixture.path))")
        ] {
            var gaps: [Double] = []
            let heartbeat = Task { @MainActor in
                var previous = ContinuousClock.now
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { break }
                    let now = ContinuousClock.now
                    gaps.append(Self.seconds(previous.duration(to: now))); previous = now
                }
            }
            defer { heartbeat.cancel() }
            let started = ContinuousClock.now
            TerminalTestSupport.send("\(command); printf '\\nTMUX_\(name)_%s\\n' DONE", to: terminal)
            try await TestSupport.eventually(timeout: .seconds(60), interval: .milliseconds(100),
                diagnostic: "\(name): \(app.runtime.helpers[.local]?.error ?? "No bridge error"); \(TerminalTestSupport.viewport(terminal: terminal))") {
                TerminalTestSupport.viewport(terminal: terminal).contains("TMUX_\(name)_DONE")
            }
            heartbeat.cancel()
            let elapsed = Self.seconds(started.duration(to: .now))
            let sorted = gaps.sorted()
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
            let line = "\(name): elapsed=\(elapsed)s, main queue p95=\(p95)s, max=\(sorted.last ?? 0)s, ticks=\(gaps.count), fixture=\(bytes.count) bytes"
            print("TMUX OUTPUT PERFORMANCE: " + line); report.append(line)
            XCTAssertLessThan(p95, 0.2, "Output must yield to the main queue regularly")
            if name == "burst" {
                XCTAssertLessThan(sorted.last ?? 0, 0.25, "A steady output burst must not starve input or rendering")
            }
            XCTAssertNil(app.runtime.helpers[.local]?.error)
            XCTAssertTrue(app.workspace.current?.structured == true, "The control session stays attached")
            TerminalTestSupport.send("printf 'TMUX_\(name)_INPUT_%s\\n' OK", to: terminal)
            try await app.wait { TerminalTestSupport.viewport(terminal: terminal).contains("TMUX_\(name)_INPUT_OK") }
        }
        try report.joined(separator: "\n").write(to: artifacts.appendingPathComponent("timings.txt"), atomically: true, encoding: .utf8)
        // Attaching a sampling profiler can suspend the target. Collect its
        // trace in a separate pass so those pauses do not enter UI timings.
        let sampler = Process()
        sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sampler.arguments = [String(ProcessInfo.processInfo.processIdentifier), "5", "1", "-file", artifacts.appendingPathComponent("sample.txt").path]
        sampler.standardOutput = FileHandle.nullDevice; sampler.standardError = FileHandle.nullDevice
        try sampler.run()
        defer { if sampler.isRunning { sampler.terminate() } }
        TerminalTestSupport.send("/bin/cat \(HerdrLaunch.quote(fixture.path)); printf '\\nTMUX_PROFILE_%s\\n' DONE", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(60), interval: .milliseconds(100)) {
            TerminalTestSupport.viewport(terminal: terminal).contains("TMUX_PROFILE_DONE")
        }
        while sampler.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(sampler.terminationStatus, 0)
        _ = try await PresentationTestSupport.capture(app.window, named: "output-complete", in: "tmux-output-validation")
    }

    func testContinuousOutputCanBeInterrupted() async throws {
        let app = try TmuxWalkthrough()
        defer { app.close() }
        try await app.attach(); try await app.ready()
        let terminal = try XCTUnwrap(app.runtime.views[try XCTUnwrap(app.workspace.activeTab).id])
        TerminalTestSupport.send("/usr/bin/yes DISPATCH_CONTINUOUS_OUTPUT", to: terminal)
        try await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        TerminalTestSupport.key(8, "c", terminal, modifiers: .control)
        TerminalTestSupport.send("printf '\\nTMUX_INTERRUPTED_%s\\n' OK", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(3), interval: .milliseconds(50),
            diagnostic: app.runtime.helpers[.local]?.error ?? TerminalTestSupport.viewport(terminal: terminal)) {
            TerminalTestSupport.viewport(terminal: terminal).contains("TMUX_INTERRUPTED_OK")
        }
        print("TMUX OUTPUT PERFORMANCE: interrupt-to-prompt=\(Self.seconds(started.duration(to: .now)))s")
        XCTAssertNil(app.runtime.helpers[.local]?.error)
        XCTAssertTrue(app.workspace.current?.structured == true, "The control session stays attached")
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
