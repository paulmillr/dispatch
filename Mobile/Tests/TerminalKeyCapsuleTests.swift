import Foundation
import XCTest
@testable import DispatchMobile

/// The key capsule's state machine (M6a) on a test clock: Ctrl and Alt latches, the d-pad's hold, drag and pinned
/// modes, key repeat timing, and the cluster's hit test.
final class TerminalKeyCapsuleTests: XCTestCase {
    /// Milliseconds on the test clock.
    private func ms(_ value: Int) -> Duration { .milliseconds(value) }

    func testModifierTapLatchesForOneKey() {
        var model = KeyCapsuleModel()
        model.tap(.ctrl, at: ms(0))
        XCTAssertEqual(model.ctrl, .once)
        XCTAssertEqual(model.mods, .ctrl)
        XCTAssertEqual(model.consume(), .ctrl)
        XCTAssertEqual(model.ctrl, .off)
        XCTAssertEqual(model.consume(), [])
    }

    func testDoubleTapLocksUntilTappedAgain() {
        var model = KeyCapsuleModel()
        model.tap(.alt, at: ms(0))
        model.tap(.alt, at: ms(300))
        XCTAssertEqual(model.alt, .locked)
        XCTAssertEqual(model.consume(), .alt)
        XCTAssertEqual(model.consume(), .alt, "A locked modifier stays for every key")
        model.tap(.alt, at: ms(2000))
        XCTAssertEqual(model.alt, .off)
    }

    func testSlowSecondTapReleasesInsteadOfLocking() {
        var model = KeyCapsuleModel()
        model.tap(.ctrl, at: ms(0))
        model.tap(.ctrl, at: ms(351))
        XCTAssertEqual(model.ctrl, .off)
        model.tap(.ctrl, at: ms(1000))
        XCTAssertEqual(model.ctrl, .once)
    }

    func testCtrlAndAltLatchTogether() {
        var model = KeyCapsuleModel()
        model.tap(.ctrl, at: ms(0))
        model.tap(.alt, at: ms(100))
        XCTAssertEqual(model.ctrl, .once, "Tapping Alt is not Ctrl's second tap")
        XCTAssertEqual(model.consume(), [.ctrl, .alt])
        XCTAssertEqual(model.mods, [])
    }

    func testHoldShowsTheClusterAfterTheDelay() {
        var model = KeyCapsuleModel()
        model.dpadDown(at: ms(1000))
        XCTAssertFalse(model.clusterVisible)
        XCTAssertEqual(model.nextDeadline, ms(1250))
        XCTAssertEqual(model.advance(to: ms(1249)), [])
        XCTAssertFalse(model.clusterVisible)
        XCTAssertEqual(model.advance(to: ms(1250)), [])
        XCTAssertEqual(model.cluster, .holding)
        XCTAssertNil(model.nextDeadline)
    }

    func testDraggingOntoAKeySendsItAndRepeatsWhileHeld() {
        var model = KeyCapsuleModel()
        model.dpadDown(at: ms(0))
        _ = model.advance(to: ms(250))
        XCTAssertEqual(model.drag(over: .up, at: ms(300)), [.up])
        XCTAssertEqual(model.drag(over: .up, at: ms(320)), [], "Staying on a key does not press it again")
        XCTAssertEqual(model.nextDeadline, ms(700))
        XCTAssertEqual(model.advance(to: ms(699)), [])
        XCTAssertEqual(model.advance(to: ms(700)), [.up])
        XCTAssertEqual(model.nextDeadline, ms(780))
        // A late tick sends every repeat that came due, once each.
        XCTAssertEqual(model.advance(to: ms(945)), [.up, .up, .up])
        XCTAssertEqual(model.nextDeadline, ms(1020))
    }

    func testMovingToAnotherKeyRestartsTheRepeat() {
        var model = KeyCapsuleModel()
        model.dpadDown(at: ms(0))
        _ = model.advance(to: ms(250))
        _ = model.drag(over: .left, at: ms(300))
        XCTAssertEqual(model.drag(over: nil, at: ms(400)), [])
        XCTAssertNil(model.held)
        XCTAssertNil(model.nextDeadline, "Between keys nothing repeats")
        XCTAssertEqual(model.drag(over: .enter, at: ms(500)), [.enter])
        XCTAssertEqual(model.advance(to: ms(899)), [])
        XCTAssertEqual(model.advance(to: ms(900)), [.enter])
    }

    func testLiftingHidesTheHeldCluster() {
        var model = KeyCapsuleModel()
        model.dpadDown(at: ms(0))
        _ = model.advance(to: ms(300))
        _ = model.drag(over: .right, at: ms(310))
        model.dpadUp(at: ms(500))
        XCTAssertEqual(model.cluster, .hidden)
        XCTAssertNil(model.held)
        XCTAssertEqual(model.advance(to: ms(5000)), [])
    }

    func testTapPinsTheClusterForTappingAndTapAgainHidesIt() {
        var model = KeyCapsuleModel()
        model.dpadDown(at: ms(0))
        model.dpadUp(at: ms(120))
        XCTAssertEqual(model.cluster, .pinned)
        XCTAssertEqual(model.drag(over: .up, at: ms(130)), [], "A pinned cluster takes taps, not the d-pad finger")
        XCTAssertEqual(model.keyDown(.down, at: ms(200)), [.down])
        XCTAssertEqual(model.advance(to: ms(600)), [.down])
        model.keyUp()
        XCTAssertEqual(model.advance(to: ms(2000)), [])
        XCTAssertEqual(model.cluster, .pinned)
        model.dpadDown(at: ms(3000))
        model.dpadUp(at: ms(3050))
        XCTAssertEqual(model.cluster, .hidden)
    }

    func testHiddenClusterIgnoresKeys() {
        var model = KeyCapsuleModel()
        XCTAssertEqual(model.keyDown(.up, at: ms(0)), [])
        XCTAssertEqual(model.drag(over: .up, at: ms(0)), [])
    }

    func testArrowsMapToTheirKeys() {
        XCTAssertEqual(KeyCapsuleModel.key(.up), .up)
        XCTAssertEqual(KeyCapsuleModel.key(.enter), .enter)
        XCTAssertEqual(KeyCapsuleModel.key(.left).keycode, 0x7B)
    }

    /// The cluster is 3 x 52 points with 6 point gaps: keys in a cross, corners empty, a little slack around each.
    func testClusterHitTest() {
        let frame = CGRect(x: 100, y: 200, width: TerminalDPadCluster.side, height: TerminalDPadCluster.side)
        XCTAssertEqual(TerminalDPadCluster.side, 168)
        let at = { (x: Double, y: Double) in TerminalDPadCluster.arrow(at: CGPoint(x: 100 + x, y: 200 + y), in: frame) }
        XCTAssertEqual(at(84, 26), .up)
        XCTAssertEqual(at(26, 84), .left)
        XCTAssertEqual(at(84, 84), .enter)
        XCTAssertEqual(at(142, 84), .right)
        XCTAssertEqual(at(84, 142), .down)
        XCTAssertNil(at(20, 20), "Corners are empty")
        XCTAssertNil(at(-5, 84))
        XCTAssertNil(at(84, 84 + 29 + 1), "Outside a key's circle and its slack")
    }

    func testCharactersMapToUSKeys() {
        XCTAssertEqual(TerminalInputKey.character("c"), TerminalInputKey(keycode: 0x08, text: "c"))
        XCTAssertEqual(TerminalInputKey.character("C"), TerminalInputKey(keycode: 0x08, text: "C", mods: .shift))
        XCTAssertEqual(TerminalInputKey.character("!"), TerminalInputKey(keycode: 0x12, text: "!", mods: .shift))
        XCTAssertEqual(TerminalInputKey.character("\n"), .enter)
        XCTAssertEqual(TerminalInputKey.character("é").keycode, TerminalInputKey.unidentified)
    }
}
