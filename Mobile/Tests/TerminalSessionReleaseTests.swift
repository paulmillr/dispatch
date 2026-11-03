import UIKit
import XCTest
@_spi(Test) import TermApple
@testable import DispatchMobile

/// A hidden phone terminal gives back its renderer's GPU memory after the retention (HiddenResources, as on the Mac)
/// and draws again when shown; its layer keeps the last frame meanwhile.
@MainActor
final class TerminalSessionReleaseTests: XCTestCase {
    func testHiddenSessionReleasesItsRendererAndDrawsAgainWhenShown() async throws {
        let retention = HiddenResources.retention
        defer { HiddenResources.retention = retention }
        HiddenResources.retention = 0.3
        let session = try TerminalSession.testing()
        defer { session.close() }
        // Frames need the layer on screen.
        let view = UIView()
        let window = TerminalTestWindow.show(view)
        defer { window.isHidden = true }
        session.layer.frame = CGRect(origin: .zero, size: CGSize(width: session.layer.drawableSize.width / 3, height: session.layer.drawableSize.height / 3))
        view.layer.addSublayer(session.layer)
        session.feed("Sam Example\r\n")
        session.refresh()
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "frames \(session.frameStats().frames), bytes \(session.rendererBytes), drawable \(session.layer.drawableSize)") {
            session.frameStats().frames > 0 && session.rendererBytes > 0
        }
        session.setVisible(false)
        // Reported hidden again on every poll: the retention still runs out.
        try await TestSupport.eventually(timeout: .seconds(5)) {
            session.setVisible(false)
            return session.rendererBytes == 0
        }
        let frames = session.frameStats().frames
        session.setVisible(true)
        session.refresh()
        try await TestSupport.eventually(timeout: .seconds(10)) { session.frameStats().frames > frames && session.rendererBytes > 0 }
    }
}
