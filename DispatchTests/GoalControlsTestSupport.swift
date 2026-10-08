import AppKit
import XCTest
@testable import DispatchApp

@MainActor
extension PresentationTestSupport {
    static func openGoalControls(in window: NSWindow) async throws -> NSWindow {
        // Command results and editor dismissal resize the composer on the next
        // SwiftUI update. Let that layout settle before deriving click coordinates.
        try await Task.sleep(for: .milliseconds(250))
        let captureID = UUID().uuidString
        let snapshot = try await capture(window, named: "goal-before-opening-" + captureID, in: "chat-command-validation")
        let observations = try snapshot.recognizedText()
        if !observations.contains(where: { $0.topCandidates(1).first?.string.contains("goal") == true }) {
            // Preserve the offscreen rendering path beside the composited failure.
            _ = try render(XCTUnwrap(window.contentView), named: "goal-view-cache-" + captureID, in: "chat-command-validation")
        }
        let goal = try XCTUnwrap(observations.filter {
            $0.topCandidates(1).first?.string.contains("goal") == true
        }.min { $0.boundingBox.midY < $1.boundingBox.midY })
        let recognized = try XCTUnwrap(goal.topCandidates(1).first)
        let range = try XCTUnwrap(recognized.string.range(of: "goal"))
        let box = try XCTUnwrap(recognized.boundingBox(for: range)).boundingBox
        try clickGoalControl(at: box, in: window)
        var popup: NSWindow?
        var observed = ""
        try await TestSupport.eventually(diagnostic: "Goal controls did not open; visible popup: \(observed)") {
            for candidate in NSApp.windows where candidate !== window && candidate.isVisible && candidate.contentView != nil {
                let snapshot = try await capture(candidate, named: "goal-popup-candidate-" + captureID, in: "chat-command-validation")
                // OCR can read the menu during its opening scale animation, before
                // those pixels occupy the AppKit coordinates used by the click.
                guard snapshot.positioned else { continue }
                let text = try snapshot.text()
                observed = text
                if ["Pause", "Resume", "Stop"].allSatisfy({ text.localizedCaseInsensitiveContains($0) }) {
                    popup = candidate
                    return true
                }
            }
            return false
        }
        return try XCTUnwrap(popup)
    }

    static func clickGoalAction(_ action: String, in window: NSWindow) async throws {
        let popup = try await openGoalControls(in: window)
        let snapshot = try await capture(popup, named: "goal-" + action.lowercased(), in: "chat-command-validation")
        let label = try XCTUnwrap(snapshot.box(of: action))
        try clickGoalControl(at: label, in: popup)
        try await TestSupport.eventually { !popup.isVisible }
    }

    static func dismissGoalControls(_ popup: NSWindow) async throws {
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popup.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.postEvent(escape, atStart: false)
        try await TestSupport.eventually(diagnostic: "Goal popover remained open: appActive=\(NSApp.isActive), key=\(popup.isKeyWindow), responder=\(String(describing: NSApp.keyWindow?.firstResponder))") { !popup.isVisible }
    }

    private static func clickGoalControl(at box: CGRect, in window: NSWindow) throws {
        let content = try XCTUnwrap(window.contentView)
        let point = content.convert(NSPoint(x: box.midX * content.bounds.width,
            y: (content.isFlipped ? 1 - box.midY : box.midY) * content.bounds.height), to: nil)
        let screen = window.convertPoint(toScreen: point), desktop = try XCTUnwrap(NSScreen.screens.first)
        XCTAssertEqual(CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: desktop.frame.maxY - screen.y)), .success)
        NSApp.postEvent(try mouseEvent(.mouseMoved, in: window, at: point), atStart: false)
        NSApp.postEvent(try mouseEvent(.leftMouseDown, in: window, at: point), atStart: false)
        NSApp.postEvent(try mouseEvent(.leftMouseUp, in: window, at: point), atStart: false)
    }
}
