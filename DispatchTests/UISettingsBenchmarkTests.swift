import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class UISettingsBenchmarkTests: XCTestCase {
    /// Run this class alone in a fresh test process to retain the cold-open sample.
    func testRepeatedSettingsLifecycle() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let root = URL(fileURLWithPath: "/tmp/ui-settings-lifecycle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(file: root.appendingPathComponent("settings.json"))
        let workspace = Workspace()
        var reports: [[String: Double]] = []
        for index in 0..<12 {
            let before = resident(), start = ContinuousClock.now
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 550),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(store: store, workspace: workspace))
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<2 {
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                window.contentView?.layoutSubtreeIfNeeded(); window.contentView?.displayIfNeeded()
            }
            let duration = start.duration(to: .now)
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            let opened = resident()
            window.orderOut(nil); window.contentView = nil; window.close()
            try await Task.sleep(for: .milliseconds(100))
            let closed = resident()
            reports.append(["iteration": Double(index), "seconds": seconds,
                            "residentBefore": before, "residentOpened": opened, "residentClosed": closed])
            print("UI SETTINGS \(index): open=\(seconds)s RSS=\(before)→\(opened)→\(closed)")
        }
        let output = ProcessInfo.processInfo.environment["DISPATCH_BENCHMARK_OUTPUT"].map {
            URL(fileURLWithPath: $0).appendingPathComponent("settings")
        } ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ui-settings-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("settings-lifecycle.json"))
    }

    private func resident() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) : 0
    }
}
