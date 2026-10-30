import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

/// The preview pane on screen (F2a, F2d): each kind's header and body read as the design shows them, and wrap
/// changes the rows' geometry. Desktop cases: they open windows and read pixels.
@MainActor
final class FilePreviewPresentationTests: XCTestCase {
    private let home = "/Users/ivan"
    private var base: String { home + "/src/api" }

    func testTextPreviewShowsHeaderGutterAndHighlightedLines() async throws {
        // Wider than the design's 560 pt pane, where its header too cuts the meta line short: the whole line reads here.
        let (window, session) = try host(FakeFilesSource.mockupAPI(), preview: base + "/src/routes/billing.ts",
                                         size: NSSize(width: 760, height: 420))
        try await TestSupport.eventually { if case .text = session.preview?.kind { return true }; return false }
        try await TestSupport.eventually { line(2, in: window) != nil }
        let snapshot = try await PresentationTestSupport.capture(window, named: "file-preview-text", in: "files-audit")
        try PresentationTestSupport.assertText("billing.ts", in: snapshot)
        try PresentationTestSupport.assertText("3.8 KB", in: snapshot)
        try PresentationTestSupport.assertText("export const billing", in: snapshot)
        XCTAssertEqual(try headerHeight(snapshot, in: window), 40, accuracy: 0.5, "The 40 pt header over its 1 pt rule")
        let first = try XCTUnwrap(line(1, in: window)), second = try XCTUnwrap(line(2, in: window))
        // 12.5 pt code on 20 pt rows at the design base; both grow with the text.
        let row = FilePreviewMetrics.metrics(ChatTypography()).rowHeight
        XCTAssertEqual(first.maxY - second.maxY, row, accuracy: 0.5, "Code rows as tall as the preview's metrics")
        XCTAssertLessThan(first.height, row + 0.5, "One line of text in the row")
        XCTAssertFalse(PresentationTestSupport.accessibilityFrames("file-preview-line-150", in: window)
            .contains { window.contentView!.bounds.intersects($0) }, "Rows below the fold are not drawn")
    }

    func testShortTextStartsUnderTheHeaderInBothWrapModes() async throws {
        let (window, session) = try host(FakeFilesSource.mockupAPI(), preview: base + "/src/routes/health.ts")
        try await TestSupport.eventually { if case .text = session.preview?.kind { return true }; return false }
        let height = try XCTUnwrap(window.contentView).bounds.height
        for wrap in [false, true] {
            session.previewWrap = wrap
            // Window coordinates rise from the bottom: the first line's text sits under the 40 pt header, its 1 pt
            // rule, the 10 pt padding and its row's 2.5 pt inset (53.5 pt down), not halfway down the pane.
            try await TestSupport.eventually(diagnostic: "line 1 at \(String(describing: line(1, in: window))), wrap \(wrap)") {
                guard let first = line(1, in: window) else { return false }
                return abs(height - first.maxY - 53.5) <= 1
            }
        }
        _ = try await PresentationTestSupport.capture(window, named: "file-preview-short", in: "files-audit")
    }

    func testImagePreviewShowsPixelSizeFitAndActualSize() async throws {
        let source = FakeFilesSource.mockupAPI()
        source.file(base + "/assets/logo@2x.png", try Self.gradient(width: 512, height: 512))
        let (window, session) = try host(source, preview: base + "/assets/logo@2x.png")
        try await TestSupport.eventually { if case .image = session.preview?.kind { return true }; return false }
        // The picture decodes off the main actor and then draws on the checker: the test image's 40 % green at its
        // centre, where the checker is two dark greys.
        let area = try await frame("file-preview-image", in: window)
        var shown: NSColor?
        try await TestSupport.eventually(diagnostic: "The picture did not draw: centre \(String(describing: shown)), "
                                         + "said \(PresentationTestSupport.accessibilityLabels("file-preview-image", in: window))") {
            let snapshot = try await PresentationTestSupport.capture(window, published: shown != nil)
            shown = try color(at: NSPoint(x: area.midX, y: area.midY), in: snapshot, window: window)
            return (shown?.greenComponent ?? 0) > 0.3
        }
        let snapshot = try await PresentationTestSupport.capture(window, named: "file-preview-image", in: "files-audit", published: true)
        try PresentationTestSupport.assertText("logo@2x.png", in: snapshot)
        try PresentationTestSupport.assertText("512 × 512", ["512 x 512", "512 X 512"], in: snapshot)
        try PresentationTestSupport.assertText("fit", in: snapshot)
        try PresentationTestSupport.assertText("actual size", in: snapshot)
        let image = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("file-preview-image", in: window).first)
        XCTAssertLessThan(image.height, 512, "Fit never shows a large image at full size")

        try click("file-preview-actual-size", in: window)
        try await TestSupport.eventually {
            let snapshot = try await PresentationTestSupport.capture(window, published: true)
            return try snapshot.reads(["100%"])
        }
    }

    /// The zoom: + and − step through Preview's stops, a pinch (the scroll view's magnification) is reported back,
    /// fit returns at the fit scale, ⌘0's button shows actual size, and the full-screen button opens the image in a
    /// window of its own that esc closes.
    func testImageZoomsByStepsAndPinchAndOpensFullScreen() async throws {
        let source = FakeFilesSource.mockupAPI()
        source.file(base + "/assets/hero.png", try Self.gradient(width: 1_024, height: 768))
        let (window, session) = try host(source, preview: base + "/assets/hero.png")
        try await TestSupport.eventually { if case .image = session.preview?.kind { return true }; return false }
        let root = try XCTUnwrap(window.contentView)
        var scroll: NSScrollView?
        try await TestSupport.eventually(diagnostic: "no image scroll view") {
            root.layoutSubtreeIfNeeded()
            scroll = PresentationTestSupport.views(of: NSScrollView.self, in: root).first { $0.allowsMagnification }
            return scroll != nil
        }
        let magnified = try XCTUnwrap(scroll)
        func scale() -> String { PresentationTestSupport.accessibilityLabels("file-preview-image-scale", in: window).first ?? "" }
        func expect(_ label: String, magnification: CGFloat? = nil, line: UInt = #line) async throws {
            try await TestSupport.eventually(line: line, diagnostic: "scale \(scale()), magnification \(magnified.magnification)") {
                scale() == label && magnification.map { abs(magnified.magnification - $0) < 0.001 } ?? true
            }
        }
        // 1,024 × 768 in a 560 × 420 window: fit between the 25 % and 50 % stops.
        try await TestSupport.eventually(diagnostic: "scale \(scale())") { scale().hasPrefix("fit · ") }
        let fit = magnified.magnification
        XCTAssert((0.25...0.5).contains(fit), "fit at \(fit)")
        try await expect("fit · \(FileImagePreview.percent(fit))", magnification: fit)

        try click("file-preview-zoom-in", in: window)
        try await expect("zoom · 50%", magnification: 0.5)
        try click("file-preview-zoom-in", in: window)
        try await expect("zoom · 75%", magnification: 0.75)
        // A pinch sets the magnification under the fingers; the footer follows it.
        magnified.setMagnification(2, centeredAt: NSPoint(x: 512, y: 384))
        try await expect("zoom · 200%", magnification: 2)
        _ = try await PresentationTestSupport.capture(window, named: "file-preview-image-zoomed", in: "files-audit")
        // Pinched back to the fit scale, it fits again.
        magnified.setMagnification(fit / 2, centeredAt: NSPoint(x: 512, y: 384))
        try await expect("fit · \(FileImagePreview.percent(fit))", magnification: fit)
        try click("file-preview-actual-size", in: window)
        try await expect("actual size · 100%", magnification: 1)
        try click("file-preview-zoom-out", in: window)
        try await expect("zoom · 75%", magnification: 0.75)
        try click("file-preview-zoom-out", in: window)
        try await expect("zoom · 50%", magnification: 0.5)
        try click("file-preview-zoom-out", in: window)
        try await expect("fit · \(FileImagePreview.percent(fit))", magnification: fit)

        try click("file-preview-full-screen", in: window)
        var viewer: NSWindow?
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "no full-screen viewer") {
            viewer = NSApp.windows.first { $0 !== window && $0.isVisible && $0.title == "hero.png" }
            return viewer.map { $0.styleMask.contains(.fullScreen) } ?? false
        }
        let shown = try XCTUnwrap(viewer)
        addTeardownBlock { @MainActor in shown.close() }
        XCTAssertFalse(PresentationTestSupport.accessibilityFrames("file-image-full-screen", in: shown).isEmpty)
        _ = try await PresentationTestSupport.capture(shown, named: "file-image-full-screen", in: "files-audit")
        shown.cancelOperation(nil)
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "esc left the viewer up, full screen: \(shown.styleMask.contains(.fullScreen))") { !shown.isVisible }
    }

    func testFolderPreviewShowsSummaryAndActions() async throws {
        let (window, session) = try host(FakeFilesSource.mockupAPI(), preview: base + "/src")
        try await TestSupport.eventually { if case .folder(.some) = session.preview?.kind { return true }; return false }
        // The model has the summary before the window draws it: wait for the frame that shows it, not "counting…".
        try await TestSupport.eventually {
            try await PresentationTestSupport.capture(window, published: true).reads(["on disk"])
        }
        let snapshot = try await PresentationTestSupport.capture(window, named: "file-preview-folder", in: "files-audit")
        // OCR reads the middle dot as "•", "-" or nothing.
        try PresentationTestSupport.assertText("folder · 7 items", ["folder • 7 items", "folder - 7 items", "folder 7 items"],
                                               in: snapshot)
        try PresentationTestSupport.assertText("5 files · 2 folders",
                                               ["5 files • 2 folders", "5 files - 2 folders", "5 files 2 folders"], in: snapshot)
        try PresentationTestSupport.assertText("on disk", in: snapshot)
        try PresentationTestSupport.assertText("/Users/ivan/src/api/src", in: snapshot)
        try PresentationTestSupport.assertText("Open folder", in: snapshot)
        try PresentationTestSupport.assertText("cd here", in: snapshot)
        try PresentationTestSupport.assertText("Copy path", in: snapshot)

        try click("file-preview-open-folder", in: window)
        try await TestSupport.eventually { session.pinnedRoot == base + "/src" }
    }

    func testLargeTextOffersItsFirst64KB() async throws {
        let source = FakeFilesSource.mockupAPI()
        let path = base + "/bench-2026-10-17.json"
        source.file(path, (0..<130_000).map { "{\"run\": \($0), \"ms\": 12}\n" }.joined())
        let (window, session) = try host(source, preview: path)
        try await TestSupport.eventually { if case .tooLarge(_, nil) = session.preview?.kind { return true }; return false }
        let snapshot = try await PresentationTestSupport.capture(window, named: "file-preview-too-large", in: "files-audit")
        try PresentationTestSupport.assertText("Too large to preview here", in: snapshot)
        try PresentationTestSupport.assertText("Show first 64 KB", in: snapshot)
        try PresentationTestSupport.assertText("Open in terminal", in: snapshot)
        try PresentationTestSupport.assertText("3.3 MB", in: snapshot)

        try click("file-preview-show-head", in: window)
        try await TestSupport.eventually { if case .tooLarge(_, .some) = session.preview?.kind { return true }; return false }
        try await TestSupport.eventually {
            let snapshot = try await PresentationTestSupport.capture(window, published: true)
            return try snapshot.reads(["\"run\": 0", "\"run\": 1"])
        }
    }

    func testMarkdownShowsSourceThenRendered() async throws {
        let (window, session) = try host(FakeFilesSource.mockupAPI(), preview: base + "/README.md")
        try await TestSupport.eventually { if case .markdown = session.preview?.kind { return true }; return false }
        let source = try await PresentationTestSupport.capture(window, named: "file-preview-markdown-source", in: "files-audit")
        try PresentationTestSupport.assertText("# api", in: source)
        try click("file-preview-rendered", in: window)
        try await TestSupport.eventually { !PresentationTestSupport.accessibilityFrames("file-preview-markdown", in: window).isEmpty }
        let rendered = try await PresentationTestSupport.capture(window, named: "file-preview-markdown-rendered", in: "files-audit")
        XCTAssertFalse(try rendered.reads(["# api"]), "The heading renders without its marker")
        try PresentationTestSupport.assertText("The billing service.", in: rendered)
    }

    func testWrapSoftWrapsLongLinesAtThePaneWidth() async throws {
        let source = FakeFilesSource.mockupAPI()
        let path = base + "/long.ts"
        source.file(path, "export const long = '" + String(repeating: "abcdefghij ", count: 40) + "'\nconst short = 1\n")
        let (window, session) = try host(source, preview: path)
        try await TestSupport.eventually { if case .text = session.preview?.kind { return true }; return false }
        try await TestSupport.eventually { line(2, in: window) != nil }
        let width = try XCTUnwrap(window.contentView).bounds.width

        let unwrapped = try XCTUnwrap(line(1, in: window)), short = try XCTUnwrap(line(2, in: window))
        XCTAssertEqual(unwrapped.maxY - short.maxY, FilePreviewMetrics.metrics(ChatTypography()).rowHeight, accuracy: 0.5,
                       "One row while wrap is off")
        XCTAssertGreaterThan(unwrapped.width, width, "A long line scrolls sideways")
        _ = try await PresentationTestSupport.capture(window, named: "file-preview-wrap-off", in: "files-audit")

        session.previewWrap = true
        try await TestSupport.eventually(diagnostic: "Line 1 did not wrap: \(String(describing: line(1, in: window)))") {
            (line(1, in: window)?.height ?? 0) > 40
        }
        let wrapped = try XCTUnwrap(line(1, in: window))
        XCTAssertLessThanOrEqual(wrapped.maxX, width + 0.5, "Wrapped rows fit the pane")
        let next = try XCTUnwrap(line(2, in: window))
        XCTAssertLessThan(next.height, FilePreviewMetrics.metrics(ChatTypography()).rowHeight + 0.5, "Short lines keep one row")
        let snapshot = try await PresentationTestSupport.capture(window, named: "file-preview-wrap-on", in: "files-audit")
        try PresentationTestSupport.assertText("const short", in: snapshot)
    }

    // MARK: Support

    private func host(_ source: FakeFilesSource, preview path: String,
                      size: NSSize = NSSize(width: 560, height: 420)) throws -> (NSWindow, FilesSession) {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let session = FilesSession(id: System.uuid())
        session.availability = .available(source)
        session.home = source.home
        session.pinnedRoot = base
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        let node = source.node(parent)?.children[name]
        session.preview = FilePreviewState(path: path, entry: node.map {
            FileEntry(name: name, kind: $0.kind, size: $0.kind == .directory ? 0 : UInt64($0.data.count), modified: $0.modified)
        })
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FilePreviewPane(session: session))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // A teardown block, not tearDown(): blocks run first, before the shared state check that reports a window
        // still showing.
        addTeardownBlock { @MainActor in
            window.close()
            window.contentView = nil
        }
        return (window, session)
    }

    /// A line's frame in window coordinates. The row's identifier reaches its gutter number and its text, so the
    /// line is their union: its top is the row's top plus the row's inset, its height the text's.
    private func line(_ number: Int, in window: NSWindow) -> NSRect? {
        let frames = PresentationTestSupport.accessibilityFrames("file-preview-line-\(number)", in: window)
        return frames.dropFirst().reduce(frames.first) { $0?.union($1) }
    }

    /// An opaque PNG: red across, blue down, 40 % green. (`FilePreviewTests.png` sets sRGB colours on a device RGB
    /// bitmap, which leaves every pixel transparent: enough for its pixel size, but nothing draws.)
    private static func gradient(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<width {
            for y in 0..<height {
                bitmap.setColor(NSColor(deviceRed: CGFloat(x) / CGFloat(max(1, width - 1)), green: 0.4,
                                        blue: CGFloat(y) / CGFloat(max(1, height - 1)), alpha: 1), atX: x, y: y)
            }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func frame(_ identifier: String, in window: NSWindow) async throws -> NSRect {
        try await TestSupport.eventually(diagnostic: "No \(identifier)") {
            !PresentationTestSupport.accessibilityFrames(identifier, in: window).isEmpty
        }
        return try XCTUnwrap(PresentationTestSupport.accessibilityFrames(identifier, in: window).first)
    }

    /// The captured colour at `point` in window coordinates (the content view's, bottom-left origin).
    private func color(at point: NSPoint, in snapshot: PresentationTestSupport.Snapshot, window: NSWindow) throws -> NSColor? {
        let bounds = try XCTUnwrap(window.contentView).bounds
        let scale = CGFloat(snapshot.bitmap.pixelsHigh) / bounds.height
        return snapshot.bitmap.colorAt(x: Int(point.x * scale), y: Int((bounds.height - point.y) * scale))?
            .usingColorSpace(.sRGB)
    }

    /// The header's height as drawn: how far the pane's background runs down the left margin (clear of the header's
    /// icon and text) before the 1 pt rule under the header.
    private func headerHeight(_ snapshot: PresentationTestSupport.Snapshot, in window: NSWindow) throws -> CGFloat {
        let bitmap = snapshot.bitmap
        let scale = CGFloat(bitmap.pixelsHigh) / (try XCTUnwrap(window.contentView).bounds.height)
        let x = Int(4 * scale), top = Int(2 * scale)
        func color(_ y: Int) throws -> NSColor { try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)) }
        let background = try color(top)
        for y in top..<min(bitmap.pixelsHigh, Int(80 * scale)) {
            let pixel = try color(y)
            let difference = max(abs(pixel.redComponent - background.redComponent),
                                 abs(pixel.greenComponent - background.greenComponent),
                                 abs(pixel.blueComponent - background.blueComponent))
            if difference > 0.01 { return CGFloat(y) / scale }
        }
        return .infinity
    }

    private func click(_ identifier: String, in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) throws {
        let frame = try XCTUnwrap(PresentationTestSupport.accessibilityFrames(identifier, in: window).first,
                                  "No \(identifier)", file: file, line: line)
        try PresentationTestSupport.click(window, at: NSPoint(x: frame.midX, y: frame.midY), file: file, line: line)
    }
}
