import XCTest
@_spi(Test) import Term
@_spi(Test) import TermApple

/// The engine boundary both native terminal sessions use, without a display link, GPU or live transport.
final class SurfaceSessionCoreTests: XCTestCase {
    private func surface() -> Surface {
        Surface(terminal: Terminal(TerminalOptions(cols: 40, rows: 4)), options: HandlerOptions(),
                size: RenderSize(screen: (400, 80), cell: (10, 20)),
                now: { 0 }, entropy: { [UInt8](repeating: 1, count: $0) })
    }

    private func feed(_ surface: Surface, _ text: String) {
        Array(text.utf8).withUnsafeBufferPointer { surface.feed($0) }
    }

    func testFontFeaturesInvalidateTheRendererAndColoursReuseIt() {
        let initial = Config()
        var next = initial
        next.fontFeatures = [FontFeature("calt", 0), FontFeature("liga", 0)]
        XCTAssertTrue(SurfaceSessionCore.needsRendererRebuild(from: initial, to: next))
        XCTAssertFalse(SurfaceSessionCore.needsRendererRebuild(from: next, to: next))
        var reordered = next
        reordered.fontFeatures.reverse()
        XCTAssertTrue(SurfaceSessionCore.needsRendererRebuild(from: next, to: reordered), "Feature order is significant")
        XCTAssertTrue(SurfaceSessionCore.needsRendererRebuild(from: next, to: initial), "Turning ligatures back on rebuilds too")

        for line in ["font-family = Menlo", "font-size = 18", "window-padding-x = 9", "window-padding-y = 7", "adjust-cell-height = 5"] {
            var changed = initial
            changed.load(Array(line.utf8))
            XCTAssertTrue(SurfaceSessionCore.needsRendererRebuild(from: initial, to: changed), line)
        }
        next = initial
        next.minimumContrast = 4.5
        next.background = RGB(r: 1, g: 2, b: 3)
        XCTAssertFalse(SurfaceSessionCore.needsRendererRebuild(from: initial, to: next), "Colour changes reuse shaping caches")
    }

    func testConfiguredFontFeaturesReachTheShaper() throws {
        let initial = Config()
        var disabled = initial
        disabled.fontFeatures = [FontFeature("calt", 0), FontFeature("liga", 0), FontFeature("dlig", 0)]
        func atlas(_ config: Config) throws -> [UInt8] {
            let terminal = surface()
            feed(terminal, "-> => == != ===")
            var cells = try SurfaceSessionCore.cells(config, 2)
            var coordinator = SurfaceSnapshotCoordinator(), state = RenderState()
            let snapshot = coordinator.capture(terminal, cells: &cells, look: DrawConfig(), blinkVisible: true, state: &state, now: 0)
            _ = cells.contents(preedit: snapshot.preedit, state: &state)
            return cells.gray.data
        }
        XCTAssertNotEqual(try atlas(initial), try atlas(disabled), "JetBrains Mono's ligatures must change the actual glyphs")
        XCTAssertEqual(SurfaceSessionCore.padding(initial, 2).left, SurfaceSessionCore.padding(disabled, 2).left)
    }

    func testSnapshotSearchRefreshSchedulesTheFinalOutputOnce() throws {
        let terminal = surface()
        feed(terminal, "alpha")
        XCTAssertTrue(terminal.bindingAction(Array("search:alpha".utf8)))
        XCTAssertTrue(terminal.bindingAction(Array("navigate_search:next".utf8)))
        var cells = try SurfaceSessionCore.cells(Config(), 1)
        var coordinator = SurfaceSnapshotCoordinator(), state = RenderState()
        func frame(_ milliseconds: UInt64) -> SurfaceSnapshotCoordinator.Snapshot {
            let snapshot = coordinator.capture(terminal, cells: &cells, look: DrawConfig(), blinkVisible: true,
                                               state: &state, now: milliseconds * 1_000_000)
            _ = cells.contents(preedit: snapshot.preedit, state: &state)
            state.dirty = .false
            return snapshot
        }
        XCTAssertNil(frame(0).searchRefreshDelay)
        XCTAssertEqual(state.highlights[0].filter { !$0.selected }.map(\.x), [0...4])
        feed(terminal, " alpha")
        XCTAssertEqual(frame(8).searchRefreshDelay, 16_000_000)
        XCTAssertEqual(state.highlights[0].filter { !$0.selected }.count, 1, "The second match waits for the search interval")
        XCTAssertNil(frame(16).searchRefreshDelay, "An outstanding wakeup is shared by successive frames")
        coordinator.searchRefreshFired()
        XCTAssertNil(frame(24).searchRefreshDelay)
        XCTAssertEqual(state.highlights[0].filter { !$0.selected }.map(\.x).sorted { $0.lowerBound < $1.lowerBound }, [0...4, 6...10])
        XCTAssertEqual(state.highlights[0].filter(\.selected).map(\.x), [0...4], "The selected match keeps its location")
        XCTAssertTrue(terminal.bindingAction(Array("end_search".utf8)))
        _ = frame(25)
        XCTAssertTrue(state.highlights.allSatisfy(\.isEmpty), "Ending search clears copied highlights even without new output")
    }

    func testPumpDrainsRepliesProducedByAHostCallbackInOrder() {
        let terminal = surface(), host = DenyingClipboardHost()
        host.surface = terminal
        terminal.host = host
        feed(terminal, "\u{1B}[6n\u{1B}]52;c;?\u{07}")
        var replies: [UInt8] = []
        SurfaceSessionCore.pump(terminal, reply: { replies += $0 })
        XCTAssertEqual(host.reads, 1)
        XCTAssertEqual(String(decoding: replies, as: UTF8.self), "\u{1B}[1;1R\u{1B}]52;c;\u{1B}\\")
        var later: [UInt8] = []
        SurfaceSessionCore.pump(terminal, reply: { later += $0 })
        XCTAssertTrue(later.isEmpty, "The host's synchronous reply left in the same pump")
    }

    func testFrameDemandPausesCoalescesAndRestoresHiddenFrames() {
        let demand = FrameDemand()
        XCTAssertTrue(demand.frame(), "The first refresh draws")
        XCTAssertFalse(demand.frame(), "An idle refresh pauses")
        XCTAssertTrue(demand.request(), "A paused link wakes once")
        XCTAssertFalse(demand.request(), "More changes share that wakeup")
        XCTAssertTrue(demand.frame())
        XCTAssertFalse(demand.show(false))
        XCTAssertFalse(demand.request(), "Output stays dirty while hidden")
        XCTAssertFalse(demand.frame(), "Hidden links pause with output waiting")
        XCTAssertTrue(demand.show(true))
        XCTAssertTrue(demand.frame(), "Showing draws retained output")
        XCTAssertFalse(demand.frame())
        XCTAssertTrue(demand.show(true), "Showing also redraws an unchanged terminal")
        XCTAssertTrue(demand.frame())
    }

    func testFrameDemandRelinksAfterADisplayFallsSilent() {
        let demand = FrameDemand()
        XCTAssertTrue(demand.frame())
        demand.stall()
        XCTAssertFalse(demand.request(), "A vanished running link cannot be woken by demand alone")
        demand.relink()
        XCTAssertTrue(demand.frame(), "The replacement link draws immediately")
        _ = demand.show(false)
        demand.relink()
        XCTAssertFalse(demand.frame(), "A replacement link still respects visibility")
        XCTAssertTrue(demand.show(true))
        XCTAssertTrue(demand.frame())
    }
}

private final class DenyingClipboardHost: SurfaceHost {
    weak var surface: Surface?
    var reads = 0
    func perform(_ action: SurfaceAction) -> Bool { true }
    func setClipboard(_ location: SurfaceMessage.Clipboard, _ contents: [ClipboardContent], confirm: Bool) {}
    func clipboardRequest(_ location: SurfaceMessage.Clipboard, _ request: ClipboardRequest, mimes: [[UInt8]], list: Bool) -> ClipboardReadResult {
        reads += 1
        surface?.denyClipboard(request)
        return .started
    }
    func open(_ kind: SurfaceAction.OpenKind, _ url: [UInt8]) throws {}
    func exists(_ path: [UInt8]) -> Bool { false }
}
