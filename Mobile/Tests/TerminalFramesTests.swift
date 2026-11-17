import UIKit
import XCTest
@testable import DispatchMobile

/// A phone terminal's frames follow the Mac's pacing (docs/architecture.md, Terminal output is paced): output alone
/// draws at `MotionRate.terminalOutput`, not at the display's rate, and a frame that added a line to the history is
/// not drawn a second time.
@MainActor
final class TerminalFramesTests: XCTestCase {
    /// A session whose layer is on screen (frames need a drawable), after its first frame.
    private func shown(rows: Int = 12) async throws -> (TerminalSession, UIWindow) {
        let session = try TerminalSession.testing(rows: rows)
        let view = UIView()
        let window = TerminalTestWindow.show(view)
        let size = session.layer.drawableSize
        session.layer.frame = CGRect(origin: .zero, size: CGSize(width: size.width / 3, height: size.height / 3))
        view.layer.addSublayer(session.layer)
        session.feed("Sam Example\r\n")
        try await TestSupport.eventually(timeout: .seconds(10)) { session.frameStats().frames > 0 }
        return (session, window)
    }

    func testOutputAloneDrawsAtItsPaceNotTheDisplays() async throws {
        XCTAssertEqual(MotionRate.terminalOutput, 30, "The Mac's pace on battery")
        let (session, window) = try await shown()
        defer { session.close(); window.isHidden = true }
        XCTAssertEqual(session.outputFramesPerSecond, MotionRate.terminalOutput)
        // Far under the simulator's 60 Hz, so the count below tells a paced link from an unpaced one by a wide margin.
        session.outputFramesPerSecond = 10
        // The session's size was the host's action: output draws at every refresh until its input window has passed.
        let sized = ContinuousClock.now
        try await TestSupport.eventually { ContinuousClock.now - sized > .seconds(TerminalFrames.inputWindow + 0.1) }
        let before = session.frameStats()
        let started = ContinuousClock.now
        // Some 200 small outputs, a few milliseconds apart: 50 or more display refreshes.
        let target = before.bytesFed + 200 * 6
        try await TestSupport.eventually(timeout: .seconds(30), interval: .milliseconds(4)) {
            session.feed("line\r\n")
            return session.frameStats().bytesFed >= target
        }
        let elapsed = ContinuousClock.now - started
        let frames = session.frameStats().frames - before.frames
        // A paced frame may come a tenth of its interval early (`FrameDemand.frame(at:)`).
        let allowed = Int(elapsed / .milliseconds(90)) + 3
        XCTAssertGreaterThan(frames, 0)
        XCTAssertLessThanOrEqual(frames, allowed, "\(frames) frames in \(elapsed) at 10 a second")
    }

    /// The Mac pumps after a frame that changed the scrollbar, for the scroller it shows, and the pump asks for a
    /// frame; the phone shows no scroller, and that frame drew every line of streaming output twice.
    func testAFrameThatAddedALineIsNotDrawnAgain() async throws {
        let (session, window) = try await shown(rows: 4)
        defer { session.close(); window.isHidden = true }
        // Unpaced, so a second frame would follow its first at the next refresh, well before the next line.
        session.outputFramesPerSecond = 0
        let lines = 12
        let before = session.frameStats()
        let target = before.bytesFed + lines * 6
        try await TestSupport.eventually(timeout: .seconds(30), interval: .milliseconds(100)) {
            session.feed("line\r\n")
            return session.frameStats().bytesFed >= target
        }
        try await TestSupport.eventually { session.frameStats().frames - before.frames >= lines - 1 }
        let frames = session.frameStats().frames - before.frames
        XCTAssertLessThanOrEqual(frames, lines + 2, "One frame a line, not two: \(frames) for \(lines)")
    }
}
