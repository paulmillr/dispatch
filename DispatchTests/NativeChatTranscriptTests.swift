import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class NativeChatTranscriptTests: XCTestCase {
    @MainActor private final class Fixture {
        let position = ChatScrollPosition()
        let scroll = ChatTranscriptScrollView.TranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let document: ChatTranscriptDocument
        let window: NSWindow
        var ids: [String]
        var heights: [String: CGFloat] = [:]
        var following: Bool
        var rendered: [String] = []
        /// With items, rows have revisions (`ChatTranscriptRowRevision`) and keep their roots while unchanged.
        var items: [String: ChatItem]?

        init(count: Int = 100, following: Bool = false, heights: [String: CGFloat] = [:], elastic: Bool = false) throws {
            try DesktopTestSupport.requireUnlocked()
            self.following = following
            self.heights = heights
            ids = (0..<count).map { "row-\($0)" }
            document = ChatTranscriptDocument(position: position, initiallyAtBottom: following)
            window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            position.bottomPadding = 22
            position.followsBottom = { [weak self] in self?.following == true }
            position.userScrolled = { [weak self] in self?.following = false }
            if elastic { scroll.contentView = ElasticClipView() }
            scroll.documentView = document
            window.contentView = scroll
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            update()
        }
        func update() {
            let revision: ((String) -> ChatTranscriptRowRevision?)? = items.map { items in
                { id in items[id].map { ChatTranscriptRowRevision(ChatTranscriptRow(id: id, item: $0, approval: nil)) } }
            }
            document.update(ids: ids, topInset: 22, bottomInset: 23, revision: revision) { [weak self] id, width in
                guard let self else { return AnyView(EmptyView()) }
                rendered.append(id)
                return AnyView(Text(id).frame(width: width, height: heights[id] ?? 80, alignment: .topLeading))
            }
            scroll.layoutSubtreeIfNeeded()
            document.layoutTranscript()
        }
        func move(to id: String, offset: CGFloat = 0) {
            position.restore(.init(id: id, offset: offset))
            scroll.layoutSubtreeIfNeeded()
            document.layoutTranscript()
        }
        func close() { position.disconnect(); window.orderOut(nil); window.contentView = nil; window.close() }
        /// One scroll step as AppKit applies it: the clip moves, then the window lays out before it draws.
        func scrollBy(_ delta: CGFloat) {
            position.userWillScroll(deltaY: -delta)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY + delta))
            scroll.reflectScrolledClipView(scroll.contentView)
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// Outside an elastic gesture `NSClipView` constrains every bounds change to the document; during one AppKit lets
    /// the clip past either edge. This clip does that while `bouncing`.
    private final class ElasticClipView: NSClipView {
        var bouncing = false
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            bouncing ? proposedBounds : super.constrainBoundsRect(proposedBounds)
        }
    }

    /// Varied heights, so a row's 100-point estimate never matches its measurement.
    private static let varied = Dictionary(uniqueKeysWithValues: (0..<100).map { ("row-\($0)", CGFloat(40 + ($0 * 37) % 120)) })

    /// What the window presents: every row intersecting the clip is shown (not cached), at its measured height,
    /// with no unbuilt gap between rows or at the clip's edges.
    private func assertPresentedRowsAreMeasured(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        let clip = fixture.scroll.contentView.bounds
        let rows = fixture.document.mountedRows.map { (id: $0.key, frame: $0.value.frame) }
            .filter { $0.frame.maxY > clip.minY && $0.frame.minY < clip.maxY }
            .sorted { $0.frame.minY < $1.frame.minY }
        guard let first = rows.first, let last = rows.last else {
            return XCTFail("No rows presented at \(clip.minY)", file: file, line: line)
        }
        for row in rows {
            XCTAssertEqual(row.frame.height, fixture.heights[row.id] ?? 80, accuracy: 0.5,
                           "\(row.id) is presented at its measured height", file: file, line: line)
        }
        for (above, below) in zip(rows, rows.dropFirst()) {
            XCTAssertEqual(below.frame.minY, above.frame.maxY, accuracy: 1,
                           "Nothing unbuilt between \(above.id) and \(below.id)", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(first.frame.minY, max(clip.minY, 22) + 1, "The clip's top is covered", file: file, line: line)
        XCTAssertGreaterThanOrEqual(last.frame.maxY, min(clip.maxY, fixture.document.frame.height - 23) - 1,
                                    "The clip's bottom is covered", file: file, line: line)
    }

    func testFirstLayoutMeasuresTheActualLastRowsAndBoundsHostingWork() throws {
        let fixture = try Fixture(count: 10_000, following: true, heights: ["row-9998": 4_000])
        defer { fixture.close() }
        XCTAssertTrue(fixture.position.showsRows())
        XCTAssertEqual(fixture.position.isAtBottom(tolerance: 1), true)
        XCTAssertGreaterThan(fixture.document.mountedRows["row-9999"]?.frame.height ?? 0, 1)
        XCTAssertLessThan(fixture.document.subviews.count, 40, "A long history keeps only viewport-sized hosting work")
        XCTAssertLessThanOrEqual(fixture.rendered.count, 3, "Measure from the followed end before creating rows a tall reply displaces")
    }

    func testVisibleHeightChangesRetainTheReadingMessageAndPixelOffset() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.move(to: "row-3", offset: -20)
        let before = fixture.position.visibleAnchor()
        fixture.heights["row-1"] = 400
        fixture.update()
        XCTAssertEqual(fixture.position.visibleAnchor(), before)
        XCTAssertFalse(fixture.position.isRestoring)
    }

    func testLargeLiveArrivalKeepsHostingBoundedAndShowsTheLatestRows() throws {
        let fixture = try Fixture(following: true)
        defer { fixture.close() }
        fixture.rendered.removeAll()
        fixture.position.expectArrival()
        fixture.ids += (100..<1_100).map { "row-\($0)" }
        fixture.update()
        XCTAssertEqual(fixture.position.isAtBottom(tolerance: 1), true)
        XCTAssertNotNil(fixture.document.mountedRows["row-1099"])
        XCTAssertLessThan(fixture.document.subviews.count, 40, "A burst must not host the history between the old and new bottom")
        XCTAssertLessThan(fixture.rendered.count, 40, "Following a burst has viewport-sized construction work")
    }

    func testPrependingHistoryRetainsTheReadingMessageAndPixelOffset() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.move(to: "row-30", offset: -25)
        let before = fixture.position.visibleAnchor()
        fixture.position.preserveForPrepend()
        fixture.ids.insert(contentsOf: (0..<20).map { "earlier-\($0)" }, at: 0)
        fixture.update()
        XCTAssertEqual(fixture.position.visibleAnchor(), before)
        XCTAssertFalse(fixture.position.isRestoring)
    }

    func testRemovingTheReadingRowRetainsItsNextVisibleNeighbour() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.move(to: "row-3", offset: -20)
        let nextOffset = CGFloat(60)
        fixture.ids.removeAll { $0 == "row-3" }
        fixture.update()
        let next = try XCTUnwrap(fixture.document.mountedRows["row-4"])
        XCTAssertEqual(next.frame.minY - fixture.scroll.contentView.bounds.minY, nextOffset, accuracy: 0.5)
    }

    func testUserInputCancelsAPendingJumpBeforeLayout() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.move(to: "row-30", offset: -20)
        let before = fixture.position.visibleAnchor()
        fixture.position.jumpToLatest()
        fixture.position.userWillScroll(deltaY: 20)
        fixture.update()
        XCTAssertEqual(fixture.position.visibleAnchor(), before)
    }

    func testWidthChangesPreserveTheReadingAnchor() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.move(to: "row-30", offset: -25)
        let before = fixture.position.visibleAnchor()
        fixture.window.setContentSize(NSSize(width: 700, height: 300))
        fixture.update()
        XCTAssertEqual(fixture.position.visibleAnchor(), before)
    }

    func testRestoringInsideAnUnmeasuredTallRowMeasuresItBeforeChoosingTheViewport() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.heights["row-80"] = 3_000
        fixture.move(to: "row-80", offset: -1_500)
        XCTAssertEqual(fixture.position.visibleAnchor(), .init(id: "row-80", offset: -1_500))
        XCTAssertFalse(fixture.position.isRestoring)
    }

    func testRestorationWaitsForARowPublishedByTheNextViewUpdate() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.position.rowExists = { _ in true }
        fixture.move(to: "next-page")
        XCTAssertTrue(fixture.position.isRestoring)
        fixture.ids.append("next-page")
        fixture.update()
        XCTAssertFalse(fixture.position.isRestoring)
        XCTAssertTrue(fixture.position.showsRows())
        XCTAssertEqual(fixture.position.isAtBottom(tolerance: 40), true)
    }

    func testAnIdleTranscriptHasNoPeriodicViewportRecovery() async throws {
        let fixture = try Fixture(following: true)
        defer { fixture.close() }
        var events: [ChatViewportTrace.Event] = []
        fixture.position.diagnosticSink = { events.append($0.event) }
        let start = ProcessInfo.processInfo.systemUptime
        try await TestSupport.eventually(timeout: .seconds(3)) { ProcessInfo.processInfo.systemUptime - start >= 2.2 }
        XCTAssertFalse(events.contains(.watchdog))
        XCTAssertFalse(events.contains(.recoveryRequested))
        XCTAssertFalse(events.contains(.rebuildRequested))
        XCTAssertTrue(fixture.position.showsRows())
    }

    func testLiveArrivalGlidesAndUserInputCancelsTheGlide() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { throw XCTSkip("Motion disabled") }
        let fixture = try Fixture(following: true)
        defer { fixture.close() }
        fixture.position.expectArrival()
        fixture.ids.append("arrival")
        fixture.heights["arrival"] = 200
        fixture.update()
        XCTAssertFalse(fixture.position.isAtBottom(tolerance: 1) == true, "A live arrival starts at the previous offset")
        try await TestSupport.eventually(timeout: .seconds(1)) { fixture.position.isAtBottom(tolerance: 1) == true }
        fixture.position.expectArrival()
        fixture.ids.append("next-arrival")
        fixture.heights["next-arrival"] = 200
        fixture.update()
        fixture.position.userWillScroll(deltaY: 32)
        let offset = fixture.scroll.contentView.bounds.minY
        let start = ProcessInfo.processInfo.systemUptime
        try await TestSupport.eventually { ProcessInfo.processInfo.systemUptime - start > 0.3 }
        XCTAssertEqual(fixture.scroll.contentView.bounds.minY, offset, accuracy: 0.5)
    }

    func testVisibleRowsAreMeasuredBeforePresentationWhileTheLookaheadIsDeferred() async throws {
        let fixture = try Fixture(heights: Self.varied)
        defer { fixture.close() }
        fixture.rendered.removeAll()
        fixture.move(to: "row-40", offset: -10)
        assertPresentedRowsAreMeasured(fixture)
        let clip = fixture.scroll.contentView.bounds
        let synchronous = Set(fixture.rendered)
        let frames = fixture.document.mountedRows.filter { synchronous.contains($0.key) }.map(\.value.frame)
        // A measurement can move a row out of the clip; none is built further than a row's height from it.
        XCTAssertTrue(frames.allSatisfy { $0.maxY > clip.minY - 160 && $0.minY < clip.maxY + 160 },
                      "Only rows the clip presents are built in the pass: \(synchronous.sorted())")
        XCTAssertTrue(fixture.document.lookaheadPending, "The lookahead is built after the frame, not inside the pass")
        let before = fixture.position.visibleAnchor()
        try await TestSupport.eventually(timeout: .seconds(3)) { !fixture.document.lookaheadPending }
        XCTAssertGreaterThan(Set(fixture.rendered).count, synchronous.count + 2, "The deferred lookahead built the next rows")
        XCTAssertEqual(fixture.position.visibleAnchor(), before, "Measuring the lookahead never moves the reader")
        assertPresentedRowsAreMeasured(fixture)
    }

    func testAFastScrollThatOutrunsTheLookaheadNeverPresentsAnUnmeasuredRow() throws {
        let fixture = try Fixture(heights: Self.varied)
        defer { fixture.close() }
        // No run-loop turn between steps: the deferred builder never gets one, as when input outpaces it.
        for _ in 0..<24 {
            fixture.scrollBy(260)
            assertPresentedRowsAreMeasured(fixture)
        }
        for _ in 0..<24 {
            fixture.scrollBy(-260)
            assertPresentedRowsAreMeasured(fixture)
        }
        XCTAssertLessThan(fixture.document.subviews.count, 40, "Hosts stay bounded however far the reader travels")
    }

    func testScrollingBackOverJustLeftRowsBuildsNothingAndIdleReleasesThem() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.move(to: "row-30")
        XCTAssertTrue((30...33).allSatisfy { fixture.document.hasMounted("row-\($0)") })
        fixture.scrollBy(320)
        XCTAssertTrue(fixture.document.isCached("row-30"), "A row that just left is kept, hidden")
        XCTAssertFalse(fixture.document.hasMounted("row-30"))
        XCTAssertNil(fixture.document.mountedRows["row-30"], "A kept host is not a mounted row")
        let created = fixture.document.createdHosts
        fixture.rendered.removeAll()
        fixture.scrollBy(-320)
        XCTAssertEqual(fixture.document.createdHosts, created, "Reversing shows the kept hosts again")
        XCTAssertEqual(fixture.rendered, [], "Reversing builds no row")
        XCTAssertTrue((30...33).allSatisfy { fixture.document.hasMounted("row-\($0)") })
        assertPresentedRowsAreMeasured(fixture)
        fixture.scrollBy(480)
        XCTAssertGreaterThan(fixture.document.cachedHostCount, 0)
        try await TestSupport.eventually(timeout: .seconds(5)) { fixture.document.cachedHostCount == 0 }
        assertPresentedRowsAreMeasured(fixture)
    }

    func testCachedHostsAreNeverAnchorsOrHitsAndLeaveWithTheirRowsOrTheWidth() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.move(to: "row-30")
        fixture.scrollBy(320)
        XCTAssertTrue(fixture.document.isCached("row-30"))
        // Over a kept host without a layout pass (rows 30-32 hidden, 33 shown): it is not visible content.
        let clip = fixture.scroll.contentView
        clip.postsBoundsChangedNotifications = false
        clip.setBoundsOrigin(NSPoint(x: 0, y: clip.bounds.minY - 300))
        XCTAssertEqual(fixture.document.visibleAnchor()?.id, "row-33")
        let hit = fixture.scroll.hitTest(NSPoint(x: 100, y: 270))
        XCTAssertFalse(hit?.isHiddenOrHasHiddenAncestor == true, "A kept host takes no clicks")
        clip.setBoundsOrigin(NSPoint(x: 0, y: clip.bounds.minY + 300))
        clip.postsBoundsChangedNotifications = true
        fixture.ids.removeAll { $0 == "row-30" }
        fixture.update()
        XCTAssertFalse(fixture.document.isCached("row-30"), "A removed row's kept host is dropped")
        XCTAssertNil(fixture.document.mountedRows["row-30"])
        XCTAssertGreaterThan(fixture.document.cachedHostCount, 0)
        fixture.window.setContentSize(NSSize(width: 700, height: 300))
        fixture.update()
        XCTAssertEqual(fixture.document.cachedHostCount, 0, "Kept hosts were laid out for the old width")
        assertPresentedRowsAreMeasured(fixture)
    }

    /// The controller's intents against the document's cache and deferred lookahead: a hold whose row is kept hidden,
    /// a jump to the latest output while the view does not follow, and a restore while a lookahead step is pending.
    func testIntentsAreRealizedAgainstCachedRowsAndPendingLookahead() async throws {
        let fixture = try Fixture(heights: Self.varied)
        defer { fixture.close() }
        fixture.move(to: "row-30")
        fixture.scrollBy(320)
        XCTAssertTrue(fixture.document.isCached("row-30"))
        let created = fixture.document.createdHosts
        fixture.move(to: "row-30", offset: -12)
        XCTAssertEqual(fixture.position.visibleAnchor(), .init(id: "row-30", offset: -12))
        XCTAssertFalse(fixture.position.isRestoring, "A hold on a kept row is realized by showing it")
        XCTAssertEqual(fixture.document.createdHosts, created, "The kept host is shown, not rebuilt")
        assertPresentedRowsAreMeasured(fixture)

        XCTAssertFalse(fixture.following)
        fixture.position.jumpToLatest()
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(fixture.position.isAtBottom(tolerance: 1), true, "A jump lands without the view following")
        XCTAssertFalse(fixture.position.isRestoring)
        assertPresentedRowsAreMeasured(fixture)

        fixture.move(to: "row-50")
        XCTAssertTrue(fixture.document.lookaheadPending)
        fixture.position.restore(.init(id: "row-10", offset: -5))
        try await TestSupport.eventually(timeout: .seconds(3)) { !fixture.document.lookaheadPending }
        XCTAssertEqual(fixture.position.visibleAnchor(), .init(id: "row-10", offset: -5))
        XCTAssertFalse(fixture.position.isRestoring)
        assertPresentedRowsAreMeasured(fixture)
    }

    func testEachUpdateOrScrollLaysOutOnceAndAnUnchangedPassDoesNothing() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.move(to: "row-30")
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        var reports = 0
        fixture.position.positionChanged = { _ in reports += 1 }
        let passes = fixture.document.layoutPasses
        fixture.heights["row-31"] = 120
        fixture.update()
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(fixture.document.layoutPasses, passes + 1, "An update lays out once, including the new row's own layout")
        fixture.scrollBy(40)
        XCTAssertEqual(fixture.document.layoutPasses, passes + 2, "A scroll step lays out once")
        let reported = reports
        fixture.document.layoutTranscript()
        fixture.scroll.needsLayout = true
        fixture.document.needsLayout = true
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(fixture.document.layoutPasses, passes + 2, "Nothing changed: no pass")
        XCTAssertEqual(reports, reported, "A skipped pass runs no completion callbacks")
        assertPresentedRowsAreMeasured(fixture)
    }

    /// The controller's completion work (an earlier-history read that finishes at once, a follow) can invalidate the
    /// document from inside its own `layout()`. AppKit drops a view's own `needsLayout` set there, so the document
    /// must still get the pass it asked for.
    func testAnInvalidationFromTheCompletionCallbackInsideLayoutGetsItsPass() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.move(to: "row-30")
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        var invalidations = 1
        fixture.position.positionChanged = { _ in
            guard invalidations > 0 else { return }
            invalidations -= 1
            fixture.position.geometryChanged()
        }
        let passes = fixture.document.layoutPasses
        fixture.document.invalidateMeasurements()
        fixture.window.layoutIfNeeded()
        XCTAssertEqual(fixture.document.layoutPasses, passes + 2, "The invalidation made during the pass gets one more")
        XCTAssertFalse(fixture.document.needsLayout)
    }

    /// Content that grows on its own after the row was measured (formatting finished, an observed model changed) with
    /// no new root: the document measures it again and keeps the reader's message where it was.
    func testRowContentGrowingOnItsOwnIsMeasuredAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let model = GrowingRowModel()
        fixture.document.update(ids: fixture.ids, topInset: 22, bottomInset: 23, revision: { id in
            ChatTranscriptRowRevision(ChatTranscriptRow(id: id, item: ChatItem(id: id, kind: .assistant, text: id), approval: nil))
        }) { id, width in
            id == "row-31" ? AnyView(GrowingRow(model: model).frame(width: width, alignment: .topLeading))
                : AnyView(Text(id).frame(width: width, height: 80, alignment: .topLeading))
        }
        fixture.move(to: "row-30", offset: -10)
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        let before = try XCTUnwrap(fixture.position.visibleAnchor())
        XCTAssertEqual(fixture.document.mountedRows["row-31"]?.frame.height ?? 0, 40, accuracy: 0.5)
        model.height = 260
        try await TestSupport.eventually(diagnostic: "row-31 \(fixture.document.mountedRows["row-31"]?.frame ?? .zero)") {
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            return abs((fixture.document.mountedRows["row-31"]?.frame.height ?? 0) - 260) < 0.5
        }
        let below = try XCTUnwrap(fixture.document.mountedRows["row-32"])
        XCTAssertEqual(below.frame.minY, try XCTUnwrap(fixture.document.mountedRows["row-31"]).frame.maxY, accuracy: 0.5)
        XCTAssertEqual(fixture.position.visibleAnchor(), before, "Growth below the reader's message does not move it")
    }

    /// A row cut off by the clip's top that grows while the reader rests (a disclosure the reader just clicked in its
    /// visible part) keeps its offset and grows downward: what the reader was pointing at stays where it was.
    func testATopRowThatGrowsWhileTheReaderRestsKeepsItsOffset() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let model = GrowingRowModel()
        model.height = 120
        fixture.document.update(ids: fixture.ids, topInset: 22, bottomInset: 23, revision: { id in
            ChatTranscriptRowRevision(ChatTranscriptRow(id: id, item: ChatItem(id: id, kind: .assistant, text: id), approval: nil))
        }) { id, width in
            id == "row-31" ? AnyView(GrowingRow(model: model).frame(width: width, alignment: .topLeading))
                : AnyView(Text(id).frame(width: width, height: 80, alignment: .topLeading))
        }
        fixture.move(to: "row-31", offset: -40)
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(fixture.position.visibleAnchor(), .init(id: "row-31", offset: -40))
        XCTAssertNotNil(fixture.document.mountedRows["row-32"], "A measured row is visible below the cut-off one")
        try await Task.sleep(for: .milliseconds(300))
        model.height = 340
        try await TestSupport.eventually(diagnostic: "row-31 \(fixture.document.mountedRows["row-31"]?.frame ?? .zero)") {
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            return abs((fixture.document.mountedRows["row-31"]?.frame.height ?? 0) - 340) < 0.5
        }
        XCTAssertEqual(fixture.position.visibleAnchor(), .init(id: "row-31", offset: -40),
                       "The row the reader rests on grows downward instead of moving up off the screen")
    }

    func testNewRowsAreLaidOutOnlyAtTheirMeasuredHeight() throws {
        let fixture = try Fixture(heights: ["row-41": 150, "row-42": 37])
        defer { fixture.close() }
        var layouts: [String: [CGFloat]] = [:]
        fixture.document.hostLaidOut = { id, size in layouts[id, default: []].append(size.height) }
        fixture.move(to: "row-40")
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        fixture.window.displayIfNeeded()
        for id in ["row-40", "row-41", "row-42"] {
            let height = fixture.heights[id] ?? 80
            XCTAssertFalse(layouts[id, default: []].isEmpty, "\(id) was laid out")
            XCTAssertEqual(Set(layouts[id, default: []]), [height], "\(id) is never laid out at the 100-point estimate")
        }
    }

    func testOnlyARowWhoseRevisionChangedGetsANewRoot() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.items = Dictionary(uniqueKeysWithValues: fixture.ids.map { ($0, ChatItem(id: $0, kind: .assistant, text: "Reply \($0)")) })
        fixture.update()
        fixture.move(to: "row-30")
        fixture.update()
        fixture.rendered.removeAll()
        fixture.update()
        XCTAssertEqual(fixture.rendered, [], "Unchanged revisions keep every root")
        fixture.items?["row-31"]?.text = "A revised reply"
        fixture.heights["row-31"] = 140
        fixture.update()
        XCTAssertEqual(fixture.rendered, ["row-31"], "Only the revised row is rebuilt")
        assertPresentedRowsAreMeasured(fixture)
    }

    func testElasticOverscrollIsNotPulledBackAndRowsAboveStillCorrectIt() throws {
        let fixture = try Fixture(elastic: true)
        defer { fixture.close() }
        let clip = try XCTUnwrap(fixture.scroll.contentView as? ElasticClipView)
        clip.bouncing = true
        var observed: [CGFloat] = []
        let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                              queue: nil) { _ in
            MainActor.assumeIsolated { observed.append(clip.bounds.minY) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        // AppKit's elastic scrolling moves the clip past the document's edges during a live scroll. The old document
        // clamped and scrolled back on every bounds change (observed [9545, 9545] for 9585, and [0, 0] for -30).
        func rubberBand(to y: CGFloat) {
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: fixture.scroll)
            fixture.position.userWillScroll(deltaY: y < clip.bounds.minY ? 4 : -4)
            observed = []
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: y))
            fixture.document.layoutTranscript()
        }
        func bottom() -> CGFloat { fixture.document.frame.height - clip.bounds.height }
        rubberBand(to: bottom())
        rubberBand(to: bottom())
        let end = bottom()
        rubberBand(to: end + 40)
        XCTAssertEqual(clip.bounds.minY, end + 40, accuracy: 0.5, "Layout must not pull a bottom bounce back: \(observed)")
        // Rows inserted above the reader during the bounce still correct the offset, keeping the overscroll.
        let before = try XCTUnwrap(fixture.position.visibleAnchor())
        fixture.position.preserveForPrepend()
        fixture.ids.insert(contentsOf: (0..<20).map { "earlier-\($0)" }, at: 0)
        fixture.update()
        XCTAssertEqual(fixture.position.visibleAnchor(), before)
        XCTAssertEqual(clip.bounds.minY, bottom() + 40, accuracy: 0.5)
        rubberBand(to: -30)
        XCTAssertEqual(clip.bounds.minY, -30, accuracy: 0.5, "Layout must not pull a top bounce back: \(observed)")
    }

    /// AppKit moves the clip of a followed transcript itself (momentum and its bounce, without wheel events that would
    /// end following) and returns a bounce to its own edge, `bottomPadding` below where following settles. Pulling the
    /// clip back to the follow offset on each of those frames fought the animation: it never ended, and flung the clip
    /// thousands of points past the document (a blank transcript).
    func testFollowingLeavesAppKitsBottomEdgeAndBounceToAppKit() throws {
        let fixture = try Fixture(following: true, elastic: true)
        defer { fixture.close() }
        let clip = try XCTUnwrap(fixture.scroll.contentView as? ElasticClipView)
        func edge() -> CGFloat { fixture.document.frame.height - clip.bounds.height }
        let follow = edge() - 22
        XCTAssertEqual(clip.bounds.minY, follow, accuracy: 0.5)
        clip.bouncing = true
        var observed: [CGFloat] = []
        let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                              queue: nil) { _ in
            MainActor.assumeIsolated { observed.append(clip.bounds.minY) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for y in [follow + 10, edge(), edge() + 60, edge() + 20, edge()] {
            observed = []
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: y))
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            fixture.document.layoutTranscript()
            XCTAssertEqual(observed, [y], "Layout must leave AppKit's clip at \(y)")
        }
        XCTAssertTrue(fixture.following)
        // New content still moves a followed clip down to the new follow offset.
        fixture.ids.append(contentsOf: (0..<3).map { "later-\($0)" })
        fixture.update()
        XCTAssertEqual(clip.bounds.minY, edge() - 22, accuracy: 0.5)
        // An explicit request for the latest output settles at the follow offset.
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: edge()))
        fixture.document.scrollToBottom()
        fixture.document.layoutTranscript()
        XCTAssertEqual(clip.bounds.minY, edge() - 22, accuracy: 0.5)
    }

    /// A momentum scroll that nears the bottom re-arms following in the middle of AppKit's live scroll, and AppKit
    /// applies its own origin again on every frame of it. A pass that moved the clip there (to the follow offset, 22
    /// points above AppKit's edge) started a fight that kept the live scroll running and flung the clip thousands of
    /// points past the document (a reported trace: rows 1758.6 → 4614 → 1758.6 → 9933, with no input, for seconds).
    /// Following waits for the live scroll's end, then settles once.
    func testFollowingWaitsForAppKitsLiveScrollToEnd() throws {
        // Rows at their estimate: no measurement moves the reader here (that correction is wanted, and tested above).
        let fixture = try Fixture(following: true, heights: Dictionary(uniqueKeysWithValues: (0..<100).map { ("row-\($0)", 100) }),
                                  elastic: true)
        defer { fixture.close() }
        let clip = try XCTUnwrap(fixture.scroll.contentView as? ElasticClipView)
        func edge() -> CGFloat { fixture.document.frame.height - clip.bounds.height }
        let follow = edge() - 22
        XCTAssertEqual(clip.bounds.minY, follow, accuracy: 0.5)
        clip.bouncing = true
        var observed: [CGFloat] = []
        let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                              queue: nil) { _ in
            MainActor.assumeIsolated { observed.append(clip.bounds.minY) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: fixture.scroll)
        // The gesture cancelled following; its momentum near the bottom arms it again (the view's positionChanged).
        XCTAssertFalse(fixture.following)
        fixture.following = true
        // Far enough past the end that no row is in the clip, then the bounce returning into the document.
        for y in [edge() + 400, edge() + 40, follow - 30, follow - 5] {
            observed = []
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: y))
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            fixture.document.layoutTranscript()
            XCTAssertEqual(observed, [y], "Layout must leave AppKit's live scroll at \(y)")
        }
        // New content during the live scroll keeps the reader's rows in place, and so does a request to keep following.
        fixture.ids.append(contentsOf: (0..<3).map { "later-\($0)" })
        fixture.update()
        fixture.position.followLatest()
        fixture.document.layoutTranscript()
        XCTAssertEqual(clip.bounds.minY, follow - 5, accuracy: 0.5)
        // The live scroll ends: following settles at the new bottom.
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: fixture.scroll)
        XCTAssertEqual(clip.bounds.minY, edge() - 22, accuracy: 0.5)
        XCTAssertTrue(fixture.following)
    }

    func testSendFlightCoordinatesCrossNativeRowHostingBoundaries() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let frames = ChatFlightFrames()
        frames.coordinateView = fixture.document
        let row = NSHostingView(rootView: Color.clear.overlay(alignment: .topLeading) {
            ChatFlightAnchor(place: .composer, frames: frames)
                .frame(width: 100, height: 20).offset(x: 17, y: 23)
        })
        row.frame = NSRect(x: 22, y: 120, width: 300, height: 80)
        fixture.document.addSubview(row)
        row.layoutSubtreeIfNeeded()
        let anchor = try XCTUnwrap(PresentationTestSupport.views(of: ChatFlightAnchor.Probe.self, in: row).first)
        let before = try XCTUnwrap(frames[.composer])
        XCTAssertEqual(before.minX, 39, accuracy: 0.5)
        row.frame.origin.y += 80
        XCTAssertEqual(try XCTUnwrap(frames[.composer]).minY - before.minY, 80, accuracy: 0.5)
        frames.unregister(.composer, view: anchor)
        XCTAssertNil(frames[.composer])
    }

    func testRecycledToolRowsKeepTheirDetailsDisclosure() async throws {
        AppFont.register()
        let fixture = try Fixture()
        defer { fixture.close() }
        let cache = ChatToolLayoutCache()
        let item = ChatItem(id: "details", kind: .tool, text: #"{"cmd":"echo sample"}"#,
                            title: "exec_command", output: "sample", completed: true, exitCode: 0)
        let detailsLabel = ToolPresentation(item).usesRawDetails ? "Raw details" : "Tool details"
        fixture.document.update(ids: fixture.ids, topInset: 22, bottomInset: 23) { id, width in
            let content: AnyView = id == "row-3"
                ? AnyView(ChatToolCard(item: item, expanded: .constant(true), directory: "/fictional",
                                       layouts: cache, layoutWidth: width, presentation: cache.viewState(for: id)))
                : AnyView(Text(id).frame(height: 80))
            return content
        }
        fixture.move(to: "row-3")
        XCTAssertTrue(fixture.document.hasMounted("row-3"))
        try await TestSupport.eventually(diagnostic: "Tool mounted=\(fixture.document.hasMounted("row-3")) key=\(fixture.window.isKeyWindow) active=\(NSApp.isActive) formatted=\(ToolPresentationCache.shared.cached(for: item) != nil)") {
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            fixture.window.contentView?.displayIfNeeded()
            return !PresentationTestSupport.accessibilityFrames(label: detailsLabel, in: fixture.window).isEmpty
        }
        let button = try XCTUnwrap(PresentationTestSupport.accessibilityFrames(label: detailsLabel, in: fixture.window).first)
        let host = try XCTUnwrap(fixture.document.mountedRows["row-3"])
        let point = NSPoint(x: button.midX, y: button.midY)
        let clicked = "host=\(host.convert(host.bounds, to: nil)) ideal=\(host.intrinsicContentSize.height) button=\(button) "
            + "hit=\(String(describing: fixture.window.contentView?.hitTest(point).map { type(of: $0) })) key=\(fixture.window.isKeyWindow) "
            + "active=\(NSApp.isActive) formatted=\(ToolPresentationCache.shared.cached(for: item) != nil)"
        var since: [String] = []
        fixture.document.hostLaidOut = { id, size in if id == "row-3" { since.append("layout \(size.height)") } }
        let passes = fixture.document.layoutPasses, renders = fixture.rendered.count
        try await PresentationTestSupport.hoverAndClick(fixture.window, at: point)
        try await TestSupport.eventually(diagnostic: clicked + " then passes=\(fixture.document.layoutPasses - passes) "
            + "rendered=\(fixture.rendered.count - renders) \(since) buttons=\(PresentationTestSupport.accessibilityFrames(label: detailsLabel, in: fixture.window)) "
            + "formattedNow=\(ToolPresentationCache.shared.cached(for: item) != nil)") { cache.viewState(for: "row-3").rawExpanded }
        fixture.move(to: "row-80")
        XCTAssertNil(host.window, "The row must actually leave its hosting view")
        fixture.move(to: "row-3")
        try await TestSupport.eventually {
            PresentationTestSupport.accessibilityValues(label: detailsLabel, in: fixture.window).contains("Expanded")
        }
    }
}

@MainActor @Observable private final class GrowingRowModel { var height: CGFloat = 40 }

/// A row whose height comes from an observed model, so it changes without a new root.
private struct GrowingRow: View {
    let model: GrowingRowModel
    var body: some View { Color.clear.frame(height: model.height) }
}
