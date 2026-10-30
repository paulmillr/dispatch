import AppKit
import Observation

/// Apply title-bar positioning before a frame is drawn, rather than correcting
/// native button positions after the window has already displayed an update.
final class MainWindow: NSWindow {
    /// Its controller's state (AppDelegate.window sets it): the window's delegate is not always that controller.
    weak var state: WindowState?
    var titleBarHeight: CGFloat = 38 {
        didSet { if titleBarHeight != oldValue { alignWindowControls() } }
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

    /// Posted synchronously just before this window goes back on screen (ordered in, or its app unhidden). A view
    /// that held its updates while the window was off screen (`ChatScrollPosition`, the transcript) applies them here,
    /// and the window lays them out and draws them before it is ordered in: its first frame on screen is current.
    static let willShow = Notification.Name("MainWindow.willShow")
    /// Posted after this window left the screen: ordered out, or its app hidden.
    static let didLeaveScreen = Notification.Name("MainWindow.didLeaveScreen")
    /// Whether the window is off screen in a way `willShow` ends (minimized windows are not: AppKit brings them back
    /// on its own path).
    var isOffScreen: Bool { (NSApp.isHidden || !isVisible) && !isMiniaturized }
    /// Unhiding orders the app's windows in without this window's order(_:relativeTo:); hiding orders none out.
    private var appObservers: [NSObjectProtocol]?

    isolated deinit { appObservers?.forEach(NotificationCenter.default.removeObserver) }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if appObservers == nil {
            appObservers = [
                NotificationCenter.default.addObserver(forName: NSApplication.willUnhideNotification, object: nil, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.prepareToShow() }
                },
                NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { if let self { NotificationCenter.default.post(name: Self.didLeaveScreen, object: self) } }
                }
            ]
        }
        if place != .out, !isVisible, !isMiniaturized { prepareToShow() }
        super.order(place, relativeTo: otherWin)
        if place == .out { NotificationCenter.default.post(name: Self.didLeaveScreen, object: self) }
    }

    /// Set by a view that applied what it held (`willShow`): the window lays it out before it is ordered in.
    var releasedHeldContent = false

    /// Lets held views apply what they held (each marks its hosting views for layout), then, if one did, lays out,
    /// draws and commits the result before the window is ordered in. With nothing held, ordering in is unchanged.
    private func prepareToShow() {
        NotificationCenter.default.post(name: Self.willShow, object: self)
        guard releasedHeldContent else { return }
        releasedHeldContent = false
        contentView?.superview?.layoutSubtreeIfNeeded()
        displayIfNeeded()
        CATransaction.flush()
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
            let x = nativeControlX[kind] ?? button.frame.minX
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
    /// Where title-row content starts: 16 points after the green button, read once from the window.
    var controlsInset: CGFloat = 82
    var sidebarVisibilityOverride: Bool?
    var spaceSearchFocusRequest: UUID?
    /// The ⌘/ sheet outside chat: on the sidebar, or the content area when it is hidden.
    var shortcutsPresented = false
}
