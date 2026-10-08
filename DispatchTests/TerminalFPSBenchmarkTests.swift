import AppKit
import CoreMedia
import Term
@preconcurrency import ScreenCaptureKit
import XCTest
@testable import DispatchApp

/// Opt-in Release benchmark: counts distinct frame numbers in composited pixels.
/// A display-link callback or a repeated capture does not count as a new frame.
@MainActor
final class TerminalFPSBenchmarkTests: XCTestCase {
    func testCompositedTerminalFPS() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        let directory = CodexTestSupport.root.appendingPathComponent("build/terminal-fps-benchmark")
        let input = directory.appendingPathComponent("input.json")
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw XCTSkip("Opt in with scripts/benchmark-terminal-fps.py")
        }
        try DesktopTestSupport.requireUnlocked()
        guard #available(macOS 14.4, *) else { throw XCTSkip("Requires own-window capture") }
        let options = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: input)) as? [String: Any])
        let label = try XCTUnwrap(options["label"] as? String)
        let duration = try XCTUnwrap(options["duration"] as? Double)
        let modes = try XCTUnwrap(options["modes"] as? [String])
        let python = try XCTUnwrap(options["python"] as? String)
        let runtime = TerminalRuntime.shared
        var preferences = Preferences()
        preferences.fontSize = 11
        preferences.appTheme = .light
        preferences.lightTheme = "Ayu Light"
        runtime.start(preferences: preferences)
        defer { runtime.stop() }
        XCTAssertNil(runtime.error)

        for mode in modes {
            let producer = directory.appendingPathComponent("\(label)-\(mode)-producer.json")
            let command = [python, CodexTestSupport.root.appendingPathComponent("test/fixtures/terminal_fps.py").path,
                           mode, producer.path].map(HerdrLaunch.quote).joined(separator: " ")
            let terminal = TerminalView(id: UUID(), directory: "/tmp", launchCommand: command, presentation: .standalone)
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Dispatch FPS benchmark: \(mode)"
            window.contentView = terminal
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            defer { terminal.destroy(); window.orderOut(nil); window.contentView = nil; window.close() }
            try await TestSupport.eventually { terminal.surface != nil && FileManager.default.fileExists(atPath: producer.path) }
            let size = try XCTUnwrap(terminal.surface).grid
            let scale = window.backingScaleFactor
            let content = try await SCShareableContent.currentProcess
            let ownWindow = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
            let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 3
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let reader = FPSFrameReader(x: Int(10 * scale),
                y: Int((window.frame.height - terminal.bounds.height + 8) * scale) + Int(size.cellHeight) / 2,
                cellWidth: Int(size.cellWidth))
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(reader, type: .screen, sampleHandlerQueue: DispatchQueue(label: "dispatch.fps.capture"))
            try await stream.startCapture()
            do {
                // Alternating order across fresh processes helps expose drift.
                let order = (options["reverse"] as? Bool == true) ? [true, false] : [false, true]
                for enabled in order {
                    preferences.improveTextContrast = enabled
                    try runtime.apply(preferences)
                    try await Task.sleep(for: .seconds(2))
                    reader.reset()
                    let start = CACurrentMediaTime()
                    try await Task.sleep(for: .seconds(duration))
                    let end = CACurrentMediaTime()
                    let snapshot = reader.snapshot()
                    let samples = snapshot.samples.filter { $0.arrival >= start && $0.arrival <= end }
                    var unique: [FPSFrameReader.Sample] = []
                    for sample in samples where sample.number != unique.last?.number { unique.append(sample) }
                    let gaps = zip(unique.dropFirst(), unique).map { ($0.pts - $1.pts) * 1000 }
                    let sorted = gaps.sorted()
                    func percentile(_ fraction: Double) -> Double {
                        sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
                    }
                    let elapsed = (unique.last?.pts ?? 0) - (unique.first?.pts ?? 0)
                    let fps = elapsed > 0 ? Double(unique.count - 1) / elapsed : 0
                    let report: [String: Any] = ["label": label, "mode": mode, "contrast": enabled,
                        "fps": fps, "uniqueFrames": unique.count, "captureSamples": samples.count,
                        "invalidMarkers": snapshot.invalid, "duration": end - start,
                        "p50FrameMS": percentile(0.5), "p95FrameMS": percentile(0.95), "p99FrameMS": percentile(0.99),
                        "maxFrameMS": sorted.last ?? 0, "gapsOver25MS": gaps.filter { $0 > 25 }.count,
                        "displayMaxFPS": window.screen?.maximumFramesPerSecond ?? 0,
                        "pixelWidth": config.width, "pixelHeight": config.height,
                        "columns": size.columns, "rows": size.rows,
                        "samples": samples.map { ["pts": $0.pts, "arrival": $0.arrival, "number": Double($0.number)] }]
                    let output = directory.appendingPathComponent("\(label)-\(mode)-\(enabled ? "on" : "off").json")
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
                    print("TERMINAL_FPS \(mode) contrast=\(enabled) fps=\(fps) p95=\(percentile(0.95)) invalid=\(snapshot.invalid)")
                    XCTAssertGreaterThan(unique.count, 30, "Must decode changing frame markers from actual pixels")
                    XCTAssertEqual(snapshot.invalid, 0, "Invalid markers indicate capture/geometry problems")
                }
            } catch {
                try? await stream.stopCapture()
                throw error
            }
            try await stream.stopCapture()
        }
    }
}

private final class FPSFrameReader: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Sample { let pts: Double; let arrival: Double; let number: Int }
    private let lock = NSLock()
    private var samples: [Sample] = []
    private var invalid = 0
    private let x: Int, y: Int, cellWidth: Int
    init(x: Int, y: Int, cellWidth: Int) { self.x = x; self.y = y; self.cellWidth = cellWidth }
    func reset() { lock.withLock { samples = []; invalid = 0 } }
    func snapshot() -> (samples: [Sample], invalid: Int) { lock.withLock { (samples, invalid) } }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels), y >= 0, y < CVPixelBufferGetHeight(pixels),
              x + 40 * cellWidth < CVPixelBufferGetWidth(pixels) else { return }
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(pixels)).assumingMemoryBound(to: UInt8.self)
        var marker: UInt64 = 0
        for bit in 0..<40 {
            let offset = (x + bit * cellWidth + cellWidth / 2) * 4
            let value = (Int(row[offset]) + Int(row[offset + 1]) + Int(row[offset + 2])) / 3
            guard value < 30 || value > 225 else { lock.withLock { invalid += 1 }; return }
            marker = marker << 1 | (value > 127 ? 1 : 0)
        }
        let number = Int((marker >> 16) & 65535)
        guard marker >> 32 == 0b10110110, Int(marker & 65535) == (number ^ 65535) else {
            lock.withLock { invalid += 1 }; return
        }
        let sample = Sample(pts: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer)),
                            arrival: CACurrentMediaTime(), number: number)
        lock.withLock { samples.append(sample) }
    }
}
