import AppKit
import Observation

/// Apply title-bar positioning before a frame is drawn, rather than correcting
/// native button positions after the window has already displayed an update.
final class MainWindow: NSWindow {
    var titleBarHeight: CGFloat = 38 {
        didSet { if titleBarHeight != oldValue { alignWindowControls() } }
    }
    /// Moves the traffic lights right of their native place, into the glass sidebar panel (WindowState.controlsShift).
    var controlsShift: CGFloat = 0 {
        didSet { if controlsShift != oldValue { alignWindowControls() } }
    }
    /// Each button's native x, and the x this window last gave it: if a button isn't where it was put,
    /// AppKit has laid it out again and its current x is native.
    private var nativeControlX: [NSWindow.ButtonType: CGFloat] = [:]
    private var appliedControlX: [NSWindow.ButtonType: CGFloat] = [:]
    override func displayIfNeeded() {
        contentView?.superview?.layoutSubtreeIfNeeded()
        alignWindowControls()
        super.displayIfNeeded()
    }
    private func alignWindowControls() {
        guard !styleMask.contains(.fullScreen), let content = contentView else { return }
        // Center native buttons in the current header. AppKit can
        // reset their frames on resize or full-screen exit, so reapply after
        // native layout, changing frames only when the position differs.
        let centerY = content.convert(content.bounds, to: nil).maxY - titleBarHeight / 2
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(kind), button.window === self,
                  let parent = button.superview else { continue }
            let rect = button.convert(button.bounds, to: nil)
            if appliedControlX[kind].map({ abs(button.frame.minX - $0) > 0.01 }) ?? true {
                nativeControlX[kind] = button.frame.minX
            }
            let x = (nativeControlX[kind] ?? button.frame.minX) + controlsShift
            appliedControlX[kind] = x
            guard abs(rect.midY - centerY) > 0.01 || abs(button.frame.minX - x) > 0.01 else { continue }
            let center = parent.convert(NSPoint(x: rect.midX, y: centerY), from: nil)
            button.setFrameOrigin(NSPoint(x: x, y: center.y - button.frame.height / 2))
        }
    }
}

@MainActor @Observable
final class WindowState {
    var isFullScreen = false
    /// Where title-row content starts: 16 points after the green button, wherever controlsShift puts it.
    var controlsInset: CGFloat { nativeControlsInset + controlsShift }
    /// controlsInset for the traffic lights' native place, read once from the window.
    var nativeControlsInset: CGFloat = 82
    /// How far right of their native place the traffic lights sit: into the glass sidebar panel while it shows.
    var controlsShift: CGFloat = 0
    var sidebarVisibilityOverride: Bool?
    var spaceSearchFocusRequest: UUID?
    /// The ⌘/ sheet outside chat: on the sidebar, or the content area when it is hidden.
    var shortcutsPresented = false
}
