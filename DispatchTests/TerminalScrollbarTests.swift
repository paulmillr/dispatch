import Foundation
import XCTest
@testable import DispatchApp

@MainActor
final class TerminalScrollbarTests: XCTestCase {
    /// App consumer fragment; native Herdr tests own moved-pane lookup.
    func testServerHistoryCoalescesDragRestoresRejectionAndStopsWhenHidden() async throws {
        var values: [TerminalScrollState] = [], offsets: [UInt64] = []
        var rejected = false
        var history: TerminalHistory!
        history = TerminalHistory(seek: { offset in
            if rejected { throw HerdrFailure("Disconnected") }
            offsets.append(offset)
            history.update(.init(total: 120, offset: 100 - offset, visible: 20))
        }, changed: { values.append($0) })
        defer { history.setActive(false); history = nil }
        history.setActive(true)
        history.update(.init(total: 120, offset: 100, visible: 20))
        history.scroll(to: 0); history.scroll(to: 50); history.scroll(to: 80)
        try await TestSupport.eventually { values.last?.offset == 80 }
        XCTAssertEqual(offsets, [20])
        history.scroll(to: 100)
        try await TestSupport.eventually { values.last?.offset == 100 }
        rejected = true
        let received = values.count
        history.scroll(to: 50)
        try await TestSupport.eventually { values.count > received }
        XCTAssertEqual(values.last, TerminalScrollState(total: 120, offset: 100, visible: 20))
        history.scroll(to: 0)
        history.setActive(false)
        history.scroll(to: 0)
        await Task.yield()
        XCTAssertEqual(offsets, [20, 0], "Hidden history sends no pending or new seek")
    }

    func testHistoryRangeClampsEmptyShrinkingAndExtremeValues() throws {
        XCTAssertFalse(TerminalScrollState().canScroll)
        XCTAssertFalse(TerminalScrollState(total: 20, offset: 100, visible: 30).canScroll)
        let state = TerminalScrollState(total: 120, offset: 999, visible: 20)
        XCTAssertEqual(state.offset, 100)
        XCTAssertEqual(state.row(at: 0.5), 50)
        XCTAssertEqual(state.row(at: -1), 0)
        XCTAssertEqual(state.row(at: 2), 100)
        XCTAssertEqual(state.row(at: .nan), 100)
        let huge = TerminalScrollState(total: .max, visible: 1)
        XCTAssertEqual(huge.row(at: 1), UInt64.max - 1)
        XCTAssertLessThan(huge.row(at: Double(1).nextDown), huge.maximum)
        let history = HelperClient.History(terminal: 1, offset: .max, max: .max, viewport: 20)
        let bytes = Data(#"{"terminal":1,"offset":18446744073709551615,"max":18446744073709551615,"viewport":20}"#.utf8)
        let update = try XCTUnwrap(HelperClient.Update.decode("terminal.scroll", bytes))
        XCTAssertEqual(update, .history(history))
        XCTAssertEqual(try HelperClient.Update.decode("terminal.scroll", update.encode()), update)
        XCTAssertEqual(history.state, TerminalScrollState(total: .max, offset: 0, visible: 20))
    }
}
