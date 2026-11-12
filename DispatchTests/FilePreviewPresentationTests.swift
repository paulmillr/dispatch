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
        try PresentationTestSupport.assertText("Download", in: snapshot)
        XCTAssertFalse(try snapshot.reads(["Open in terminal"]), "Files open nothing in the terminal")
        try PresentationTestSupport.assertText("3.3 MB", in: snapshot)

        try click("file-preview-show-head", in: window)
        try await TestSupport.eventually { if case .tooLarge(_, .some) = session.preview?.kind { return true }; return false }
        // OCR misreads the code font's quotes ('"run"' as "''run\""): the rows' words and the bar are what it reads.
        try await TestSupport.eventually {
            let snapshot = try await PresentationTestSupport.capture(window, published: true)
            return try snapshot.reads(["First 64 KB of 3.3 MB", "run", "ms"])
        }
    }

    /// A binary shows as hex at once, its format in the header; a click selects a byte and the inspector reads it, the
    /// end button reaches the last row (read on demand), and Strings lists its text.
    func testBinaryShowsHexSelectsJumpsAndListsStrings() async throws {
        let source = FakeFilesSource.mockupAPI()
        let path = base + "/module.wasm"
        var bytes = Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])
        bytes += Data((8..<300_008).map { UInt8($0 % 251) })
        bytes.replaceSubrange(64..<79, with: Data("BOUNDARY-STRING".utf8))
        bytes.replaceSubrange(79..<80, with: Data([0]))
        bytes.replaceSubrange(63..<64, with: Data([0]))
        source.file(path, bytes)
        let (window, session) = try host(source, preview: path, size: NSSize(width: 820, height: 520))
        try await TestSupport.eventually { if case .binary = session.preview?.kind { return true }; return false }
        let grid = try await frame("file-preview-hex", in: window)
        let snapshot = try await PresentationTestSupport.capture(window, named: "file-preview-hex", in: "files-audit")
        try PresentationTestSupport.assertText("WebAssembly module, version 1", in: snapshot)
        try PresentationTestSupport.assertText("00000000", in: snapshot)
        try PresentationTestSupport.assertText("00 61 73 6d", in: snapshot)
        XCTAssertFalse(try snapshot.reads(["Show first 64 KB"]), "No step before the bytes show")

        // The first row's second byte: under the header row and the inset, past the offset column and byte 0.
        let metrics = FilePreviewMetrics.metrics(ChatTypography())
        let y = grid.maxY - (metrics.rowHeight + 1) - 4 - metrics.rowHeight / 2
        let x = grid.minX + FileHexGridView.padding + CGFloat(8 + 2 + 3) * metrics.digitWidth + metrics.digitWidth
        try PresentationTestSupport.click(window, at: NSPoint(x: x, y: y))
        _ = try await frame("file-preview-hex-inspector", in: window)
        try await TestSupport.eventually {
            let snapshot = try await PresentationTestSupport.capture(window, published: true)
            return try snapshot.reads(["1 byte selected"]) && snapshot.reads(["8-bit"])
        }

        try click("file-preview-hex-end", in: window)
        do {
            try await TestSupport.eventually(diagnostic: "The last row did not show") {
                let snapshot = try await PresentationTestSupport.capture(window, published: true)
                return try snapshot.reads(["000493e0"])
            }
        } catch {
            _ = try? await PresentationTestSupport.capture(window, named: "file-preview-hex-end-failed", in: "files-audit",
                                                           published: true)
            throw error
        }
        _ = try await PresentationTestSupport.capture(window, named: "file-preview-hex-end", in: "files-audit", published: true)

        try click("file-preview-hex-mode-strings", in: window)
        try await TestSupport.eventually(diagnostic: "Strings did not list the text") {
            let snapshot = try await PresentationTestSupport.capture(window, published: true)
            return try snapshot.reads(["BOUNDARY-STRING"])
        }
        _ = try await PresentationTestSupport.capture(window, named: "file-preview-hex-strings", in: "files-audit", published: true)
    }

    /// Markdown opens rendered (Settings › Files › Render Markdown) and set for reading: a centred column of larger
    /// prose whose source lines flow, six sizes of heading. The eye is the tab's choice, for the next file too.
    func testMarkdownOpensRenderedInAReadingColumnAndTheEyeIsTheTabsChoice() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Before macOS 26 the prose is SwiftUI text, with no view to measure") }
        let source = FakeFilesSource.mockupAPI()
        let guide = base + "/GUIDE.md"
        source.file(guide, Self.guide)
        let (window, session) = try host(source, preview: guide, size: NSSize(width: 1_000, height: 620))
        try await TestSupport.eventually { if case .markdown = session.preview?.kind { return true }; return false }
        try await TestSupport.eventually(diagnostic: "Markdown did not open rendered") { text(Self.opening, in: window) != nil }
        XCTAssertNil(session.previewRendered, "Rendered is Settings' choice until the eye says otherwise")

        let reading = FileMarkdownStyle.typography(TerminalRuntime.shared.preferences).prose
        let measure = FileMarkdownStyle.measure(reading)
        // The source breaks this paragraph twice: found whole, its lines flowed into one.
        let paragraph = try XCTUnwrap(text(Self.opening, in: window))
        let frame = paragraph.convert(paragraph.bounds, to: nil)
        // Centred in what scrolls: a scroller always shown takes its width from the pane first.
        let clip = try XCTUnwrap(paragraph.enclosingScrollView?.contentView)
        let area = clip.convert(clip.bounds, to: nil)
        XCTAssertEqual(frame.minX, area.minX + (area.width - measure) / 2, accuracy: 1, "The column is centred in the pane")
        XCTAssertGreaterThan(area.width, measure + 2 * FileMarkdownStyle.margin, "The pane is wider than the column")
        XCTAssertLessThanOrEqual(frame.width, measure + 0.5, "Prose wraps at the column, not the pane")
        XCTAssertGreaterThan(frame.width, measure - 80, "A paragraph fills its column")
        XCTAssertGreaterThan(frame.height, 40, "On more than one line")
        XCTAssertEqual(try size(of: paragraph), reading.pointSize(), accuracy: 0.01, "Prose at the reading size")
        let headings = try ["Guide", "Install", "On a host", "Level four", "Level five", "Level six"].map {
            try size(of: try XCTUnwrap(text($0, in: window), "No heading \($0)"))
        }
        XCTAssertEqual(headings, headings.sorted(by: >), "Each level smaller than the one above it")
        XCTAssertEqual(Set(headings).count, 6, "No two levels alike: \(headings)")
        XCTAssertEqual(headings[0], reading.pointSize(offset: FileMarkdownStyle.headingOffset(1, reading)), accuracy: 0.01)
        XCTAssertFalse(PresentationTestSupport.accessibilityFrames("file-preview-outline", in: window).isEmpty,
                       "The header offers the file's outline")
        XCTAssertTrue(PresentationTestSupport.accessibilityFrames("file-preview-wrap", in: window).isEmpty,
                      "Nothing to wrap while rendered")
        let rendered = try await PresentationTestSupport.capture(window, named: "file-preview-markdown-rendered", in: "files-audit")
        XCTAssertFalse(try rendered.reads(["# Guide"]), "The heading renders without its marker")
        try PresentationTestSupport.assertText("The billing service takes a charge request", in: rendered)

        try click("file-preview-rendered", in: window)
        try await TestSupport.eventually(diagnostic: "The eye did not show the source") { line(1, in: window) != nil }
        XCTAssertEqual(session.previewRendered, false)
        XCTAssertTrue(PresentationTestSupport.accessibilityFrames("file-preview-outline", in: window).isEmpty,
                      "No outline over the source")
        let shown = try await PresentationTestSupport.capture(window, named: "file-preview-markdown-source", in: "files-audit")
        try PresentationTestSupport.assertText("# Guide", in: shown)

        // The next Markdown file on this tab opens as the last was left, and the eye brings it back rendered.
        show(base + "/README.md", from: source, in: session)
        try await TestSupport.eventually(diagnostic: "README.md did not open as source") {
            session.preview?.name == "README.md" && line(1, in: window) != nil && text("The billing service.", in: window) == nil
        }
        try click("file-preview-rendered", in: window)
        try await TestSupport.eventually(diagnostic: "The eye did not render README.md") { text("The billing service.", in: window) != nil }
        XCTAssertEqual(session.previewRendered, true)
    }

    /// A section folds from the chevron beside its heading and stays folded while the tab shows another file; the
    /// mark after a folded heading opens it. The outline's choice scrolls to its heading, opening what is folded
    /// around it.
    func testMarkdownSectionsFoldAndTheOutlineScrollsToAHeading() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Before macOS 26 the prose is SwiftUI text, with no view to measure") }
        let source = FakeFilesSource.mockupAPI()
        let guide = base + "/GUIDE.md"
        source.file(guide, Self.guide)
        let (window, session) = try host(source, preview: guide, size: NSSize(width: 640, height: 460))
        try await TestSupport.eventually(diagnostic: "Markdown did not open rendered") { text("Steps.", in: window) != nil }
        let document = FileMarkdownDocuments.document(Self.guide)
        let install = try XCTUnwrap(document.headings.first { $0.title == "Install" })
        XCTAssertEqual(document.headings.firstIndex(of: install), 1)

        try click("file-markdown-fold-1", in: window)
        try await TestSupport.eventually(diagnostic: "Install did not fold: \(session.previewFolds)") {
            text("Steps.", in: window) == nil && text("On a host", in: window) == nil
        }
        XCTAssertEqual(session.previewFolds[guide], [install.id])
        XCTAssertNotNil(text("Install", in: window), "A folded section keeps its heading")
        XCTAssertNotNil(text("Run it.", in: window), "The next section is untouched")
        XCTAssertFalse(PresentationTestSupport.accessibilityFrames("file-markdown-folded-1", in: window).isEmpty,
                       "A folded heading says there is more")
        _ = try await PresentationTestSupport.capture(window, named: "file-preview-markdown-folded", in: "files-audit")

        show(base + "/README.md", from: source, in: session)
        try await TestSupport.eventually { text("The billing service.", in: window) != nil }
        show(guide, from: source, in: session)
        try await TestSupport.eventually(diagnostic: "GUIDE.md did not come back") { text("Run it.", in: window) != nil }
        XCTAssertNil(text("Steps.", in: window), "The file comes back as it was left")

        try click("file-markdown-folded-1", in: window)
        try await TestSupport.eventually(diagnostic: "The mark did not unfold Install") { text("Steps.", in: window) != nil }
        XCTAssertNil(session.previewFolds[guide])

        // The outline's choice: a heading far down comes to the top of the pane, under the header.
        let height = try XCTUnwrap(window.contentView).bounds.height
        let far = try XCTUnwrap(document.headings.first { $0.title == "Section 6" })
        session.reveal(far, of: document, at: guide)
        var top: CGFloat?
        try await TestSupport.eventually(diagnostic: "Section 6 did not scroll to the top: \(String(describing: top)) pt down") {
            guard session.previewReveal == nil, let heading = text("Section 6", in: window) else { return false }
            top = height - heading.convert(heading.bounds, to: nil).maxY
            // Under the 41 pt header, the heading's own space above it.
            return top.map { (41...100).contains($0) } ?? false
        }
        // And one inside a folded section opens the sections around it.
        session.setFolds([install.id], at: guide)
        let inside = try XCTUnwrap(document.headings.first { $0.title == "On a host" })
        session.reveal(inside, of: document, at: guide)
        try await TestSupport.eventually(diagnostic: "On a host did not show: \(session.previewFolds)") {
            session.previewReveal == nil && text("Copy the helper.", in: window) != nil
        }
        XCTAssertNil(session.previewFolds[guide])
    }

    /// A file's other blocks read as a document's: front matter as a `yaml` block, a list item whole with the line
    /// that continues it, a quote's lines as one quote, and a table and a fenced block in the column.
    func testMarkdownBlocksReadAsADocument() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Before macOS 26 the prose is SwiftUI text, with no view to measure") }
        let source = FakeFilesSource.mockupAPI()
        let notes = base + "/NOTES.md"
        source.file(notes, Self.notes)
        let (window, session) = try host(source, preview: notes, size: NSSize(width: 760, height: 860))
        try await TestSupport.eventually { if case .markdown = session.preview?.kind { return true }; return false }
        let item = "Replay first, record last. After a change, replay the affected classes; the failures are exactly what changed."
        try await TestSupport.eventually(diagnostic: "The list item did not take the line that continues it") {
            text(item, in: window) != nil
        }
        let paragraph = try XCTUnwrap(text("Debug builds replay every helper recording and fail on any mismatch, so a helper "
                                           + "change fails the build until the affected recordings are recorded again.", in: window),
                                      "The paragraph's two source lines flow into one")
        let listed = try XCTUnwrap(text(item, in: window)), nested = try XCTUnwrap(text("Replay the class.", in: window))
        func left(_ view: NSTextView) -> CGFloat { view.convert(view.bounds, to: nil).minX }
        XCTAssertGreaterThan(left(listed), left(paragraph) + 12, "An item is set in from the prose")
        XCTAssertGreaterThan(left(nested), left(listed) + 12, "And a nested one from its item")
        XCTAssertNotNil(text("A quote wrapped over two lines.", in: window), "A quote's lines are one quote")
        XCTAssertNil(text("name: build-notes", in: window), "Front matter is not prose")
        let snapshot = try await PresentationTestSupport.capture(window, named: "file-preview-markdown-blocks", in: "files-audit")
        try PresentationTestSupport.assertText("name: build-notes", in: snapshot)
        try PresentationTestSupport.assertText("Build notes", in: snapshot)
        try PresentationTestSupport.assertText("the desktop's focus", ["the desktop’s focus", "the desktops focus"], in: snapshot)
        try PresentationTestSupport.assertText("bash test/run.sh FilePreviewTests", in: snapshot)
    }

    func testWrapSoftWrapsLongLinesAtThePaneWidth() async throws {
        let source = FakeFilesSource.mockupAPI()
        let path = base + "/long.ts"
        source.file(path, "export const long = '" + String(repeating: "abcdefghij ", count: 40) + "'\nconst short = 1\n")
        let (window, session) = try host(source, preview: path)
        // Settings wraps by default; the tab's wrap button turns it off first.
        session.previewWrap = false
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

    /// A file's view goes when the split shows another tab and comes back when it shows this one: the text and the
    /// rendered Markdown come back where they were scrolled to, not at the top.
    func testScrollComesBackWhenTheViewReturns() async throws {
        let source = FakeFilesSource.mockupAPI()
        let long = base + "/LONG.md"
        source.file(long, (1...80).map { "## Part \($0)\n\nA paragraph for part \($0), long enough to read as prose.\n" }
            .joined(separator: "\n"))
        let (window, session) = try host(source, preview: base + "/src/routes/billing.ts")
        try await TestSupport.eventually { if case .text = session.preview?.kind { return true }; return false }
        try await TestSupport.eventually { line(2, in: window) != nil }
        try await assertScrollReturns(to: 600, in: window, session: session, key: .text)

        show(long, from: source, in: session)
        try await TestSupport.eventually { if case .markdown = session.preview?.kind { return true }; return false }
        try await TestSupport.eventually(diagnostic: "no scroll view for the page") {
            (scrollView(in: window)?.documentView?.frame.height ?? 0) > 1_500
        }
        try await assertScrollReturns(to: 900, in: window, session: session, key: .rendered)
    }

    /// Scrolls the preview to `y`, takes its view out of the window as a tab switch does and puts a new one in.
    private func assertScrollReturns(to y: CGFloat, in window: NSWindow, session: FilesSession,
                                     key: FilePreviewScrollKeeper.Key) async throws {
        let scroll = try XCTUnwrap(scrollView(in: window))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await TestSupport.eventually(diagnostic: "kept: \(String(describing: session.preview?.scroll[key]))") {
            abs((session.preview?.scroll[key]?.y ?? 0) - y) < 1
        }
        window.contentView = NSView()
        try await TestSupport.eventually { scrollView(in: window) == nil }
        window.contentView = NSHostingView(rootView: FilePreviewPane(session: session))
        try await TestSupport.eventually(diagnostic: "came back at \(String(describing: scrollView(in: window)?.contentView.bounds.origin))") {
            guard let clip = scrollView(in: window)?.contentView else { return false }
            return abs(clip.bounds.origin.y - y) < 1
        }
    }

    /// The preview's vertical scroll view: its tallest document.
    private func scrollView(in window: NSWindow) -> NSScrollView? {
        guard let root = window.contentView else { return nil }
        return PresentationTestSupport.views(of: NSScrollView.self, in: root, includingNestedMatches: true)
            .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
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

    /// Selects another file on the tab, as a click on its row does.
    private func show(_ path: String, from source: FakeFilesSource, in session: FilesSession) {
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        session.preview = FilePreviewState(path: path, entry: source.node(parent)?.children[name].map {
            FileEntry(name: name, kind: $0.kind, size: UInt64($0.data.count), modified: $0.modified)
        })
    }

    /// The rendered Markdown's text view that says exactly `string`: a paragraph, a heading, a list item.
    private func text(_ string: String, in window: NSWindow) -> NSTextView? {
        guard let root = window.contentView else { return nil }
        return PresentationTestSupport.views(of: NSTextView.self, in: root, includingNestedMatches: true).first { $0.string == string }
    }

    /// The size of the font a text view's first character is set in.
    private func size(of view: NSTextView) throws -> CGFloat {
        let font = try XCTUnwrap(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        return font.pointSize
    }

    /// Notes as an editor wraps them: front matter, wrapped prose and list items, a quote, a table and a fence.
    private static let notes = """
        ---
        name: build-notes
        description: What the build needs
        ---

        # Build notes

        Debug builds replay every helper recording and fail on any mismatch, so a helper
        change fails the build until the affected recordings are recorded again.

        - **Replay first, record last.** After a change, replay the affected classes; the failures
          are exactly what changed.
        - Record again only what changed on purpose.
          1. Replay the class.
          2. Read the failures.

        > A quote wrapped
        > over two lines.

        | Runner | Where | Takes |
        | --- | --- | --- |
        | `test/run.sh` | this Mac | the desktop's focus |
        | `test/vm.py` | the test VM | nothing |

        ```sh
        bash test/run.sh FilePreviewTests
        ```

        See [the test guide](https://example.com/guide) for the rest.

        """

    /// A guide whose source wraps its first paragraph, with every level of heading and enough sections to scroll.
    private static let opening = "The billing service takes a charge request, checks its idempotency key against the ledger, "
        + "and answers once, however many times the request arrives: a retry gets the first answer back."
    private static let guide = """
        # Guide

        The billing service takes a charge request, checks its idempotency key against the ledger,
        and answers once, however many times the request arrives:
        a retry gets the first answer back.

        ## Install

        Steps.

        ### On a host

        Copy the helper.

        #### Level four

        Text four.

        ##### Level five

        Text five.

        ###### Level six

        Text six.

        ## Use

        Run it.


        """ + (1...12).map { "## Section \($0)\n\n" + String(repeating: "Filler sentence for section \($0). ", count: 8) + "\n\n" }.joined()
        + "## Appendix\n\nThe end.\n"

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
