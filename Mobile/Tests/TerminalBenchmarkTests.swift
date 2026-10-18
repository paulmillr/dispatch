import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// Throughput and frame times while a large file is catted through the scripted feed into a full-screen terminal,
/// and the parser alone; plus the screenshot harness for comparing the terminal and the key capsule with M6a.
/// Both are in the full suite: they measure, or wait for a person.
@MainActor
final class TerminalBenchmarkTests: XCTestCase {
    struct Summary: CustomStringConvertible {
        var bytes: Int, seconds: Double, frames: Int, build: [Double], total: [Double]
        var events = 0, batches = 0, grid = ""
        static func percentile(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        }
        var description: String {
            let mb = Double(bytes) / 1_048_576
            return "\(grid) grid; " + String(format: "%.0f MiB in %.2f s = %.1f MiB/s; %d events in %d parse batches; %d frames (%.0f/s); "
                          + "build median %.2f ms p95 %.2f ms max %.2f ms; to GPU done median %.2f ms p95 %.2f ms max %.2f ms",
                          mb, seconds, mb / seconds, events, batches, frames, Double(frames) / seconds,
                          Self.percentile(build, 0.5), Self.percentile(build, 0.95), build.max() ?? 0,
                          Self.percentile(total, 0.5), Self.percentile(total, 0.95), total.max() ?? 0)
        }
    }

    /// `cat` of a 256 MiB file into a full-screen terminal while it draws at the display's rate, in 64 KiB
    /// notifications (herdr and the native multiplexer send large frames): the host's ceiling.
    func testCatLargeFileThroughputAndFrameTime() async throws {
        let summary = try await cat(bytes: 256 << 20, chunk: 65_536)
        print("Terminal benchmark (cat 256 MiB in 64 KiB notifications): \(summary)")
        add(XCTAttachment(string: summary.description))
        XCTAssertGreaterThan(summary.frames, 3, "Frames keep coming while output streams")
    }

    /// Frame times while output streams for 4 s at 8 MiB/s (several times what the spike measured through tmux):
    /// the display's pace, and how long each frame takes.
    func testFrameTimeWhileStreaming() async throws {
        let rate = 8 << 20
        let summary = try await cat(bytes: 4 * rate, chunk: 16_384, rate: rate)
        print("Terminal benchmark (32 MiB streamed at 8 MiB/s in 16 KiB notifications): \(summary)")
        add(XCTAttachment(string: summary.description))
        XCTAssertGreaterThan(Double(summary.frames) / summary.seconds, 30, "Frames keep the display's pace while output streams")
    }

    /// The same with tmux's notification size: one per `%output` line, 29 bytes on average (the helper spike's
    /// `yes` run: 2.9 million frames for 78.6 MB). The presence coalesces them into parse batches.
    func testCatInSmallNotificationsIsCoalesced() async throws {
        let summary = try await cat(bytes: 4 << 20, chunk: 29)
        print("Terminal benchmark (cat 4 MiB in 29-byte notifications): \(summary)")
        add(XCTAttachment(string: summary.description))
        XCTAssertLessThan(summary.batches, summary.events / 2)
    }

    private func cat(bytes size: Int, chunk: Int, rate: Int? = nil) async throws -> Summary {
        let data = TerminalFixtures.largeFile(bytes: size)
        let feed = ScriptedTerminalFeed(output: data, options: .init(chunk: chunk, rate: rate))
        let controller = TerminalController(feed: feed, configuration: TerminalConfiguration())
        let view = controller.hostView
        let window = TerminalTestWindow.show(view, size: CGSize(width: 402, height: 874))
        defer {
            window.isHidden = true
            controller.disappear()
        }
        try await Task.sleep(for: .milliseconds(200))
        _ = view.session.frameStats(reset: true)
        let start = ContinuousClock.now
        controller.appear()
        try await TestSupport.eventually(timeout: .seconds(300), interval: .milliseconds(2)) { view.session.frameStats().bytesFed >= size }
        let seconds = Double((ContinuousClock.now - start) / .microseconds(1)) / 1_000_000
        try await Task.sleep(for: .milliseconds(100))
        let stats = view.session.frameStats()
        let grid = view.session.currentSize
        return Summary(bytes: size, seconds: seconds, frames: stats.frames, build: stats.build, total: stats.total,
                       events: (size + chunk - 1) / chunk, batches: stats.batches, grid: "\(grid.columns)x\(grid.rows)")
    }

    /// The parser alone (no frames): what a feed can push through the emulator.
    func testParserThroughput() throws {
        let size = 64 << 20
        let data = TerminalFixtures.largeFile(bytes: size)
        let session = try TerminalSession.testing(columns: 50, rows: 50)
        let chunk = 65_536
        let start = ContinuousClock.now
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            session.feed(data[offset..<end])
            offset = end
        }
        let seconds = Double((ContinuousClock.now - start) / .milliseconds(1)) / 1000
        let rate = Double(size) / 1_048_576 / seconds
        print(String(format: "Terminal parser throughput: 64 MiB in %.2f s = %.1f MiB/s", seconds, rate))
        add(XCTAttachment(string: String(format: "%.1f MiB/s", rate)))
        XCTAssertGreaterThan(rate, 5)
    }

    /// Shows a fixture full screen (`TEST_RUNNER_DISPATCH_TERMINAL_SHOT`: vite, vim, htop, cluster) with a stand-in
    /// for Tabs' header, writes `ready` into `TEST_RUNNER_DISPATCH_TERMINAL_SHOT_DIR` and waits for `release` there,
    /// so `xcrun simctl io <device> screenshot` can capture it. Skipped without the variable.
    func testShowFixtureForScreenshot() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixture = environment["DISPATCH_TERMINAL_SHOT"], let directory = environment["DISPATCH_TERMINAL_SHOT_DIR"] else {
            throw XCTSkip("Screenshot harness: set TEST_RUNNER_DISPATCH_TERMINAL_SHOT and TEST_RUNNER_DISPATCH_TERMINAL_SHOT_DIR")
        }
        // The screen at the segment's grid on an iPhone 17 (50 x 33 with the keyboard down).
        let (columns, rows) = (Int(environment["DISPATCH_TERMINAL_SHOT_COLUMNS"] ?? "") ?? 50, Int(environment["DISPATCH_TERMINAL_SHOT_ROWS"] ?? "") ?? 33)
        let output: Data = switch fixture {
        case "vim": TerminalFixtures.vim(columns: columns, rows: rows)
        case "htop": TerminalFixtures.htop(columns: columns, rows: rows)
        // The mockup's output sits at the bottom, as after a while of running.
        default: Data(String(repeating: "\r\n", count: 60).utf8) + TerminalFixtures.viteDev
        }
        let feed = ScriptedTerminalFeed(output: output)
        let controller = TerminalController(feed: feed, configuration: TerminalConfiguration())
        let root = UIHostingController(rootView: ScreenshotScreen(controller: controller).preferredColorScheme(.dark))
        let scene = (await TestSupport.windowScene())!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await TestSupport.eventually { feed.record.attachments.count == 1 }
        if fixture == "cluster" || fixture == "vite" {
            controller.dpadDown()
            controller.dpadUp()
        }
        if fixture == "keyboard" { controller.toggleKeyboard() }
        let ready = URL(fileURLWithPath: directory).appendingPathComponent("ready")
        let release = URL(fileURLWithPath: directory).appendingPathComponent("release")
        try? FileManager.default.removeItem(at: release)
        try Data("\(controller.hostView.session.currentSize)".utf8).write(to: ready)
        let deadline = Date().addingTimeInterval(300)
        while !FileManager.default.fileExists(atPath: release.path), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        try? FileManager.default.removeItem(at: ready)
    }
}

/// M6a around the Terminal segment: a stand-in for the header Tabs draws (back pill, name, subtitle, host disc,
/// segmented control), so screenshots compare with the mockup as a whole.
private struct ScreenshotScreen: View {
    let controller: TerminalController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                    Text("1").font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(Color.dispatchPink)
                .padding(.leading, 12).padding(.trailing, 14)
                .frame(height: 44)
                .glassEffect(.regular, in: .capsule)
                VStack(alignment: .leading, spacing: 0) {
                    Text("app").font(.system(size: 17, weight: .semibold))
                    Text("\(Text("mba2").foregroundStyle(TabsSample.mba2.tint)) · \(TerminalSubtitle.text(directory: "/Users/paul/src/app", shell: "/bin/zsh", home: "/Users/paul"))")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.92, opacity: 0.6))
                }
                .padding(.leading, 4)
                Spacer()
                Image(systemName: "apple.logo")
                    .font(.system(size: 20))
                    .foregroundStyle(TabsSample.mba2.tint)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: .circle)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Picker("", selection: .constant(0)) {
                Text("Terminal").tag(0)
                Text("Chat").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 10)
            TerminalSegmentView(controller: controller)
        }
        .background(Color.black)
    }
}
