import Foundation
import XCTest
@testable import DispatchMobile

/// Finger scrolling across the local scrollback and the multiplexer's history: lines split exactly at the
/// boundaries, the server's share learned from its answers and position reports.
final class TerminalScrollModelTests: XCTestCase {
    typealias Plan = TerminalScrollModel.Plan
    private let primary = TerminalScrollModel.Local(above: 5, below: 0)

    func testPointsBecomeWholeLinesWithTheRemainderCarried() {
        var model = TerminalScrollModel()
        XCTAssertEqual(model.lines(points: 10, lineHeight: 16), 0)
        XCTAssertEqual(model.lines(points: 10, lineHeight: 16), 1)
        XCTAssertEqual(model.pending, 4, accuracy: 1e-9)
        XCTAssertEqual(model.lines(points: -36, lineHeight: 16), -2)
        model.endGesture()
        XCTAssertEqual(model.pending, 0)
        XCTAssertEqual(model.lines(points: 5, lineHeight: 0), 0)
    }

    func testLocalScrollbackComesFirstThenTheServerWithoutAGap() {
        var model = TerminalScrollModel()
        XCTAssertEqual(model.route(3, local: primary), Plan(local: 3))
        // Two rows left above the viewport: they go locally, the rest to the server in the same step.
        XCTAssertEqual(model.route(5, local: .init(above: 2, below: 3)), Plan(local: 2, server: 3))
        XCTAssertEqual(model.serverOffset, 3)
        XCTAssertEqual(model.route(4, local: .init(above: 0, below: 5)), Plan(server: 4))
        XCTAssertEqual(model.serverOffset, 7)
    }

    func testScrollingBackReturnsTheServerFirstThenTheViewport() {
        var model = TerminalScrollModel()
        _ = model.route(6, local: .init(above: 0, below: 0))
        XCTAssertEqual(model.serverOffset, 6)
        XCTAssertEqual(model.route(-4, local: .init(above: 0, below: 0)), Plan(local: 0, server: -4))
        XCTAssertEqual(model.route(-5, local: .init(above: 0, below: 3)), Plan(local: -3, server: -2))
        XCTAssertEqual(model.serverOffset, 0)
        XCTAssertEqual(model.route(-2, local: .init(above: 3, below: 2)), Plan(local: -2))
    }

    func testAppOwnedAnswerReplaysTheStepLocallyAndStaysLocal() {
        var model = TerminalScrollModel()
        let plan = model.route(4, local: .init(above: 1, below: 0))
        XCTAssertEqual(plan, Plan(local: 1, server: 3))
        XCTAssertEqual(model.answered(.appOwned, for: plan), 3)
        XCTAssertEqual(model.server, .appOwned)
        XCTAssertEqual(model.serverOffset, 0)
        XCTAssertEqual(model.route(10, local: .init(above: 0, below: 1)), Plan(local: 10), "The emulator's top is a no-op")
        XCTAssertEqual(model.route(-3, local: .init(above: 0, below: 1)), Plan(local: -3))
    }

    func testServerPositionReportsCorrectThePrediction() {
        var model = TerminalScrollModel()
        let plan = model.route(5, local: .init(above: 0, below: 0))
        XCTAssertEqual(model.answered(.server, for: plan), 0)
        XCTAssertEqual(model.server, .available)
        model.history(.init(offset: 2, maximum: 3, viewport: 20))
        XCTAssertEqual(model.serverOffset, 2)
        XCTAssertEqual(model.route(4, local: .init(above: 0, below: 0)), Plan(server: 4))
        XCTAssertEqual(model.serverOffset, 3, "Clamped to the server's maximum")
        // At its oldest line the server takes no more: the step goes to the emulator, whose top is a no-op.
        XCTAssertEqual(model.route(2, local: .init(above: 0, below: 0)), Plan(local: 2))
    }

    func testFailedStepUndoesThePrediction() {
        var model = TerminalScrollModel()
        let up = model.route(4, local: .init(above: 0, below: 0))
        XCTAssertEqual(model.answered(.failed, for: up), 0)
        XCTAssertEqual(model.serverOffset, 0)
        model.history(.init(offset: 6, maximum: 100, viewport: 20))
        let down = model.route(-2, local: .init(above: 0, below: 0))
        _ = model.answered(.failed, for: down)
        XCTAssertEqual(model.serverOffset, 6)
    }

    func testProgramTakingTheWheelGetsEveryLine() {
        var model = TerminalScrollModel()
        let wheel = TerminalScrollModel.Local(above: 0, below: 0, programTakesWheel: true)
        XCTAssertEqual(model.route(3, local: wheel), Plan(server: 3), "herdr forwards the wheel to its pane")
        XCTAssertEqual(model.route(-3, local: wheel), Plan(server: -3))
        _ = model.answered(.appOwned, for: Plan(server: 3))
        XCTAssertEqual(model.route(3, local: wheel), Plan(local: 3), "tmux: the emulator encodes the wheel for the program")
    }

    func testZeroLinesDoNothing() {
        var model = TerminalScrollModel()
        XCTAssertEqual(model.route(0, local: primary), Plan())
    }
}
