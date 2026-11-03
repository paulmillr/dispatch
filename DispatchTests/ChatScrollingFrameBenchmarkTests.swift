import AppKit
import CoreMedia
import Darwin
import QuartzCore
import SwiftUI
@preconcurrency import ScreenCaptureKit
import XCTest
@testable import DispatchApp

/// Identical production-view workloads in the old and native container checkouts. Counts changes in the
/// transcript's composited pixels, independently of input/display-link callbacks. Opt-in, optimized builds only.
@MainActor
final class ChatScrollingFrameBenchmarkTests: XCTestCase {
    func testSustainedScrollingFrameDelivery() async throws {
        guard let path = System.environment("DISPATCH_SCROLL_FRAMES_OUTPUT") else {
            throw XCTSkip("Run scripts/benchmark-chat-frames.py")
        }
        guard #available(macOS 14.4, *) else { throw XCTSkip("Requires window capture") }
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let typing = ChatTypingReveals.enabled
        ChatTypingReveals.enabled = true
        defer { ChatTypingReveals.enabled = typing }
        let output = URL(fileURLWithPath: path)
        let seconds = Double(System.environment("DISPATCH_SCROLL_FRAMES_SECONDS") ?? "10") ?? 10
        let inputHz = Double(System.environment("DISPATCH_SCROLL_FRAMES_INPUT_HZ") ?? "120") ?? 120
        if System.environment("DISPATCH_SCROLL_FRAMES_PROFILE") == "1" {
            try JSONSerialization.data(withJSONObject: ["pid": getpid()]).write(to: output.appendingPathComponent("ready.json"))
            try await TestSupport.eventually(timeout: .seconds(60)) {
                FileManager.default.fileExists(atPath: output.appendingPathComponent("go").path)
            }
        }
        for shape in ["mixed", "expanded", "streaming"] {
            for speed in [2400.0, 6000.0] {
                ToolPresentationCache.shared.removeAll()
                let coordinator = ChatCoordinator(enabled: false)
                defer { coordinator.stop() }
                let session = coordinator.session(for: System.uuid())
                session.sessionID = "scroll-frames-" + shape; session.showChat = true
                session.turns = fixture(expanded: shape == "expanded")
                if shape == "expanded" {
                    session.expandedToolGroups.formUnion(session.transcriptRows.compactMap { $0.group?.id })
                    session.expanded.formUnion(session.visibleTranscriptRows.filter { $0.item?.kind == .tool }.map(\.id))
                }
                let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 740),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                if let screen = NSScreen.screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }) {
                    window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - window.frame.width / 2,
                                                  y: screen.visibleFrame.midY - window.frame.height / 2))
                }
                window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator,
                    focused: false, floatingSwitch: false).preferredColorScheme(.dark))
                NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
                defer {
                    session.scrollPosition.disconnect()
                    window.orderOut(nil); window.contentView = nil; window.close()
                }
                try await TestSupport.eventually {
                    session.scrollPosition.showsRows() && session.scrollPosition.isAtBottom(tolerance: 40) == true
                }
                let rows = session.visibleTranscriptRows
                let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: XCTUnwrap(window.contentView))
                    .max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
                // Begin from the same visible latest message, as a reader does. A far item-ID restoration also
                // exercises an unrelated old lazy-stack failure, which would prevent the scrolling comparison.
                try await Task.sleep(for: .seconds(1))
                try await TestSupport.eventually { session.scrollPosition.isAtBottom(tolerance: 40) == true }
                session.scrollPosition.userWillScroll(deltaY: 1)
                session.atBottom = false; session.followRevision = nil
                if shape == "streaming" {
                    let anchor = rows[max(0, rows.count - 100)].id
                    session.scrollPosition.restore(.init(id: anchor, offset: 0))
                    try await TestSupport.eventually {
                        !session.scrollPosition.isRestoring && session.scrollPosition.visibleAnchor(retaining: [anchor]) != nil
                    }
                }
                let content = try await SCShareableContent.currentProcess
                let source = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
                let config = SCStreamConfiguration()
                config.width = Int(window.frame.width * window.backingScaleFactor)
                config.height = Int(window.frame.height * window.backingScaleFactor)
                config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
                config.pixelFormat = kCVPixelFormatType_32BGRA; config.queueDepth = 3
                config.showsCursor = false; config.ignoreShadowsSingleWindow = true
                let reader = ChatCompositedFrames()
                let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: source), configuration: config, delegate: nil)
                try stream.addStreamOutput(reader, type: .screen, sampleHandlerQueue: DispatchQueue(label: "dispatch.chat.frames"))
                try await stream.startCapture()
                var updates = 0
                let streaming: Task<Void, Never>? = shape == "streaming" ? Task { @MainActor in
                    session.active = true; session.busy = true; session.activeTurnID = "live"
                    var text = ""
                    while !Task.isCancelled {
                        text += "Streaming **reply** with `code` and results. "
                        session.insert(.init(id: "live-reply", kind: .assistant, text: text), turnID: "live")
                        updates += 1
                        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    }
                } : nil
                defer { streaming?.cancel() }
                try await TestSupport.eventually { reader.count > 0 }
                let sampler = ScrollFrames(scroll: scroll, window: window, position: session.scrollPosition,
                    measureContinuity: false, pauseBetweenGestures: false, speed: speed, inputHz: inputHz)
                #if DISPATCH_BENCHMARK
                let resetMetrics = NSSelectorFromString("resetTranscriptBenchmarkMetrics")
                if scroll.documentView?.responds(to: resetMetrics) == true {
                    _ = scroll.documentView?.perform(resetMetrics)
                }
                #endif
                let start = CACurrentMediaTime()
                var report = await sampler.run(seconds: seconds)
                let end = CACurrentMediaTime()
                #if DISPATCH_BENCHMARK
                if scroll.documentView?.responds(to: NSSelectorFromString("transcriptBenchmarkMetrics")) == true {
                    report["nativeLayout"] = scroll.documentView?.value(forKey: "transcriptBenchmarkMetrics")
                }
                #endif
                streaming?.cancel()
                try await stream.stopCapture()
                let samples = reader.snapshot().filter { $0.arrival >= start && $0.arrival <= end }
                var unique: [ChatCompositedFrames.Sample] = []
                for sample in samples where sample.hash != unique.last?.hash { unique.append(sample) }
                let intervals = zip(unique.dropFirst(), unique).map { $0.pts - $1.pts }
                let elapsed = (unique.last?.pts ?? 0) - (unique.first?.pts ?? 0)
                report.merge(["shape": shape, "rows": rows.count, "streamUpdates": updates,
                    "captureSamples": samples.count, "uniqueFrames": unique.count,
                    "compositedFPS": elapsed > 0 ? Double(unique.count - 1) / elapsed : 0,
                    "presentationIntervals": intervals,
                    "frames": unique.map { ["pts": $0.pts, "arrival": $0.arrival, "hash": String($0.hash, radix: 16)] as [String: Any] },
                    "note": "Own-window composited transcript pixels; duplicate hashes excluded; excludes composer/chrome. Capture overhead included. Display refresh limits observed FPS; no claim of panel scanout."] as [String: Any]) { _, value in value }
                let name = shape + "-" + String(Int(speed))
                try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: output.appendingPathComponent(name + ".json"))
                print("CHAT_SCROLL_FRAMES \(name) fps=\(report["compositedFPS"]!) p95=\(report["workP95Ms"]!) CPU=\(report["cpuSeconds"]!) distance=\(sampler.distance)")
                XCTAssertGreaterThan(sampler.distance, speed * seconds * 0.4, "The workload must sustain real scrolling")
                XCTAssertGreaterThan(unique.count, 10, "Must capture changing transcript pixels")
                if shape == "streaming" { XCTAssertGreaterThan(updates, Int(seconds * 10)) }
            }
        }
    }

    private func fixture(expanded: Bool) -> [ChatTurn] {
        (0..<(expanded ? 120 : 400)).map { turn in
            let prose = (0..<(turn % 5 + 3)).map {
                "Paragraph \(turn)/\($0): inspect the queued changes, retain the reading position, and verify **formatted text** with `inline code`."
            }.joined(separator: "\n\n")
            let code = "\n\n```swift\n" + (0..<16).map { "let result\($0) = queue.flush(batch: \(turn + $0))" }.joined(separator: "\n") + "\n```"
            let table = "\n\n| Component | Result |\n|---|---|\n| Queue \(turn) | Checked |\n| Connection | Ready |\n| Renderer | Visible |"
            var items: [ChatItem] = [.init(id: "prompt-\(turn)", kind: .user, text: "Investigate change \(turn) and verify the result."),
                .init(id: "reply-\(turn)", kind: .assistant, text: prose + (turn % 3 == 0 ? code : "") + (turn % 5 == 0 ? table : ""))]
            for step in 0..<(expanded ? 6 : 1) {
                let output = (0..<(expanded ? 160 : 12)).map { "Sources/Queue\(turn).swift:\($0 + 1): result \(turn)/\(step)/\($0)" }.joined(separator: "\n")
                items.append(.init(id: "tool-\(turn)-\(step)", kind: .tool, text: #"{"cmd":"rg result Sources"}"#,
                    title: "exec_command", output: output, completed: true, exitCode: 0))
            }
            items.append(.init(id: "done-\(turn)", kind: .assistant, text: "Change \(turn) checked. The next task can proceed."))
            return ChatTurn(id: "turn-\(turn)", items: items)
        }
    }
}

private final class ChatCompositedFrames: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Sample { let pts: Double; let arrival: Double; let hash: UInt64 }
    private let lock = NSLock()
    private var samples: [Sample] = []
    var count: Int { lock.withLock { samples.count } }
    func snapshot() -> [Sample] { lock.withLock { samples } }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        // Only transcript content, excluding the title bar, scroller, composer and thinking animation.
        // Sparse native pixels keep capture analysis off the main thread and cheap in both implementations.
        var hash: UInt64 = 14695981039346656037
        for y in Swift.stride(from: height / 10, to: height * 3 / 4, by: 8) {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            for x in Swift.stride(from: width / 20, to: width * 19 / 20, by: 8) {
                hash = (hash ^ UInt64(row[x] & 0x00ffffff)) &* 1099511628211
            }
        }
        let sample = Sample(pts: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer)),
                            arrival: CACurrentMediaTime(), hash: hash)
        lock.withLock { samples.append(sample) }
    }
}
