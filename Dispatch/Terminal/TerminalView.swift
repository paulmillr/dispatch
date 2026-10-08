import AppKit
import os
import QuartzCore

/// An NSView and its terminal surface have the same owner and lifetime, even
/// while SwiftUI removes the view for an inactive tab or space.
@MainActor
final class TerminalView: NSView {
    /// Standalone terminals (such as login sheets) own focus independently of tabs.
    enum Presentation { case workspace, standalone }
    let presentation: Presentation
    let id: UUID
    let directory: String
    /// A standalone view's own process; workspace terminals run in the helper.
    let launchCommand: String?
    private let helper: HelperRenderer?
    let machine: TerminalMachine
    /// Whether terminal output may name files or shared memory on this Mac.
    let allowHostMedia: Bool
    var onProcessExit: (() -> Void)?
    var foregroundPIDOverride: UInt64? {
        guard launchCommand == nil, let workspace = TerminalRuntime.shared.workspace,
              let helper = workspace.helper(containing: id),
              let terminal = workspace.spaces.flatMap(\.tabs).first(where: { $0.id == id })?.terminal else { return nil }
        guard helper.endpoint == .local else { return 0 }
        guard let tty = helper.node(terminal)?.tty, let device = UInt32(exactly: tty) else { return 0 }
        return AgentProcess.foregroundGroup(device: device) ?? 0
    }
    /// The grid a multiplexer server keeps for this pane; while set, the view renders exactly that grid
    /// (another client may make it smaller) and reports the cells it could show to `reportAvailable`.
    var tmuxGrid: CGSize? {
        didSet { if oldValue != tmuxGrid { updateGeometry() } }
    }
    var reportAvailable: ((Double, Double) -> Void)?
    var foregroundPID: UInt64 { foregroundPIDOverride ?? surface?.foregroundPID ?? 0 }
    /// The engine's terminal (TerminalBackend.swift).
    private(set) var surface: (any TerminalBackend)?
    /// `surface` shows restored output with no process yet: a restored SSH tab before it reconnects.
    private var previewing = false
    private var destroyed = false
    var herdrScrollAccumulator = HerdrScrollAccumulator()
    let scrollbar = TerminalScrollbar()
    var history: TerminalHistory?
    /// Coalesces screen publication across output batches (`screenChanged`).
    let screenPublication = OSAllocatedUnfairLock(initialState: ScreenPublication())
    private var tracking: NSTrackingArea?
    private var rendererView: NSView?
    var markedTextRange = NSRange(location: NSNotFound, length: 0)
    var selectedTextRange = NSRange(location: 0, length: 0)
    var markedText = ""
    var currentKeyEvent: NSEvent?
    var keyTextAccumulator: [String] = []
    var inputSuspensions = 0 {
        didSet { updateFocus() }
    }
    var isPresented = true {
        didSet {
            guard oldValue != isPresented else { return }
            if !isPresented, window?.firstResponder === self { window?.makeFirstResponder(nil) }
            updateVisibility()
            updateFocus()
        }
    }

    init(id: UUID, directory: String, launchCommand: String? = nil, machine: TerminalMachine = .local, presentation: Presentation = .workspace, allowHostMedia: Bool? = nil, helper: HelperRenderer? = nil) {
        self.presentation = presentation
        self.id = id
        self.directory = directory
        self.launchCommand = launchCommand
        self.helper = helper
        self.machine = machine
        self.allowHostMedia = allowHostMedia ?? (machine == .local)
        super.init(frame: .zero)
        wantsLayer = true
        // The renderer makes its target a layer-hosting view. Keep native controls
        // as siblings of that view so replacing the render layer cannot hide them.
        let renderer = TerminalRenderView(frame: .zero)
        renderer.wantsLayer = true
        addSubview(renderer)
        rendererView = renderer
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        scrollbar.changed = { [weak self] row in self?.scrollToRow(row) }
        TerminalRuntime.shared.configureBackground(self)
        addSubview(scrollbar)
        setAccessibilityIdentifier("terminal-\(id)")
        setAccessibilityLabel("Terminal")
        setAccessibilityRole(.group)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensDidWake(_:)),
            name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    var agentForegroundGroup: UInt64 { foregroundPID }

    override var acceptsFirstResponder: Bool {
        isPresented && (presentation == .standalone || (TerminalRuntime.shared.workspace?.isSurfacePresented(id) ?? true))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { event?.type == .leftMouseDown }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowOcclusionDidChange(_:)),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowScreenDidChange(_:)),
                name: NSWindow.didChangeScreenNotification, object: window)
        }
        if window != nil { createIfNeeded() }
        updateVisibility()
        updateGeometry()
        updateFocus()
        // A retained tab can mount after the selection's first focus request.
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, TerminalRuntime.shared.workspace?.activeSurfaceID == self.id else { return }
                TerminalRuntime.shared.focusActive()
            }
        }
    }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        createIfNeeded()
        updateGeometry()
    }

    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateGeometry() }

    func resumeRestoredSession() { createIfNeeded(); updateGeometry(); updateFocus() }

    private func createIfNeeded() {
        guard !destroyed, surface == nil || previewing, let window, bounds.width > 0, bounds.height > 0,
              let engine = TerminalRuntime.shared.engine else { return }
        let renderer = rendererView ?? self
        if TerminalRuntime.shared.hosts.reconnect.awaitingRestore(id) {
            // Until it reconnects, a restored tab shows its saved output where the engine can;
            // the text stays saved, for the next quit, until its process starts.
            guard surface == nil, let text = TerminalRuntime.shared.restoredHistory[id] else { return }
            renderer.frame = bounds
            surface = engine.preview(view: self, renderer: renderer, scale: window.backingScaleFactor,
                                     allowHostMedia: allowHostMedia, history: TerminalHistoryStore.replay(text))
            previewing = surface != nil
            updateVisibility()
            updateGeometry()
            return
        }
        renderer.frame = bounds
        // A nil command selects the user's login shell; the engine manages
        // the PTY and the child process.
        let command: String?, workingDirectory: String
        let variables: [String]
        if let helper {
            command = helper.command
            do { variables = try helper.environment(id: id) }
            catch { AppReplay.fail(error); return }
            workingDirectory = Home.url.path
        } else {
            // A standalone view runs its own command (nil = the login shell).
            let testing = ProcessInfo.processInfo.environment["DISPATCH_TESTING"] == "1"
            variables = testing ? ["HOME", Home.url.path, "GHOSTTY_ZSH_ZDOTDIR", "/var/empty", "DISPATCH_TESTING", "1"] : []
            // Native tests must not source the user's shell plugins/update checks.
            command = launchCommand ?? (testing ? "/bin/zsh" : nil)
            workingDirectory = directory
        }
        // Kitty file and shared-memory transports name resources on this Mac. Remote output must
        // not be able to probe, read or unlink them; direct inline image data remains available.
        let saved = TerminalRuntime.shared.restoredHistory.removeValue(forKey: id)
        let preview = previewing ? surface : nil
        previewing = false
        surface = engine.surface(view: self, renderer: renderer, scale: window.backingScaleFactor, command: command,
                                 environment: variables, directory: workingDirectory, allowHostMedia: allowHostMedia,
                                 history: preview == nil ? saved.map(TerminalHistoryStore.replay) : nil, preview: preview)
        if surface == nil {
            preview?.close()
            let label = NSTextField(wrappingLabelWithString: "Could not start the shell. Close this tab and try again.")
            label.frame = bounds.insetBy(dx: 20, dy: 20)
            label.autoresizingMask = [.width, .height]
            addSubview(label)
            destroyed = true
        }
        updateVisibility()
        updateGeometry()
        updateFocus()
    }

    func destroy() {
        destroyed = true
        history?.setActive(false)
        helper?.revoke(id)
        surface?.close()
        surface = nil
        rendererView?.removeFromSuperview(); rendererView = nil
        removeFromSuperview()
        layer = nil
    }

    func didExit() {
        guard !destroyed else { return }
        helper?.revoke(id)
        if let onProcessExit { onProcessExit(); return }
        // A restored SSH shell that failed to log in again offers its retry instead of closing.
        if TerminalRuntime.shared.hosts.reconnect.restoredShellExited(id) { return }
        // A failed renderer does not own an external server's process.
        let workspace = TerminalRuntime.shared.workspace
        let space = workspace?.spaces.first { $0.tabs.contains { $0.id == id } }
        let owner = workspace?.helper(containing: id)
        if let backend = space?.backend, owner?.external(backend) == true {
            // Losing a pane adapter ends its control session, not the server's pane process.
            for space in workspace?.spaces ?? [] where space.backend == backend && workspace?.helper(space) === owner {
                if let node = space.node { owner?.close(node, policy: .detach) }
            }
        } else {
            workspace?.closeTab(id, policy: .terminate)
        }
    }

    func updateFocus() {
        surface?.setFocus(!inputParked && isPresented && window?.isKeyWindow == true && window?.firstResponder === self)
    }

    @objc private func windowOcclusionDidChange(_ notification: Notification) { updateVisibility() }
    /// Another display (one went away, the window moved): geometry reports it, the frames follow.
    @objc private func windowScreenDidChange(_ notification: Notification) { updateGeometry() }
    /// The displays woke: the frames' display link can stay asleep, even on the same display.
    @objc private func screensDidWake(_ notification: Notification) { surface?.displaysWoke() }

    private func updateVisibility() {
        history?.setActive(isPresented && window?.occlusionState.contains(.visible) == true)
        guard let surface else { return }
        // Chat keeps the view mounted. Pause rendering while hidden, but leave
        // terminal IO running so the same session is current when revealed.
        surface.setOcclusion(isPresented && window?.occlusionState.contains(.visible) == true)
    }

    override func becomeFirstResponder() -> Bool {
        // Popover dismissal can restore a responder before SwiftUI unmounts its
        // old space. The workspace is authoritative during that short interval.
        guard acceptsFirstResponder, super.becomeFirstResponder() else { return false }
        updateFocus()
        select()
        return true
    }

    func select() {
        if acceptsFirstResponder, presentation == .workspace {
            TerminalRuntime.shared.workspace?.selectSurface(id)
        }
    }

    override func resignFirstResponder() -> Bool {
        surface?.setFocus(false)
        return super.resignFirstResponder()
    }

    var availableSize: CGSize? {
        guard let surface, let window, bounds.width > 0, bounds.height > 0 else { return nil }
        let grid = surface.grid
        guard grid.cellWidth > 0, grid.cellHeight > 0 else { return nil }
        let size = convertToBacking(bounds).size, scale = window.backingScaleFactor
        return CGSize(width: (size.width - 20 * scale) / Double(grid.cellWidth),
                      height: (size.height - 16 * scale) / Double(grid.cellHeight))
    }

    private func updateGeometry() {
        scrollbar.frame = NSRect(x: max(0, bounds.width - 14), y: 2, width: 14, height: max(0, bounds.height - 4))
        guard let surface, let window, bounds.width > 0, bounds.height > 0 else { return }
        let size = convertToBacking(bounds).size
        let scale = window.backingScaleFactor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        CATransaction.commit()
        surface.setContentScale(scale)
        if let grid = tmuxGrid {
            let metrics = surface.grid
            let cellWidth = Double(metrics.cellWidth), cellHeight = Double(metrics.cellHeight)
            if cellWidth > 0, cellHeight > 0 {
                // Keep the VT grid identical to the server's even when another client
                // limits its size. UI geometry advertises our available cells.
                if let availableSize { reportAvailable?(availableSize.width, availableSize.height) }
                let pixelWidth = grid.width * cellWidth + 20 * scale
                let pixelHeight = grid.height * cellHeight + 16 * scale
                // A smaller server grid stays at the same font size, anchored
                // at the top left; the renderer must not stretch to fill us.
                rendererView?.frame = NSRect(x: 0, y: bounds.height - pixelHeight / scale, width: pixelWidth / scale, height: pixelHeight / scale)
                surface.setSize(width: UInt32(pixelWidth), height: UInt32(pixelHeight))
            }
        } else {
            rendererView?.frame = bounds
            surface.setSize(width: UInt32(size.width), height: UInt32(size.height))
        }
        if let screen = window.screen, let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            surface.setDisplayID(display)
        }
        surface.refresh()
    }

    /// A tmux renderer covers only the server's grid. The remainder shows the
    /// terminal's background, not the window behind it, so overlays stay seamless.
    func setBackground(r: UInt8, g: UInt8, b: UInt8) {
        scrollbar.setBackground(r: r, g: g, b: b)
        layer?.backgroundColor = CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    func updateScrollback(_ state: TerminalScrollState) {
        guard !destroyed, history == nil else { return }
        scrollbar.update(state)
    }

    func updateHistory(_ metrics: HelperClient.History) {
        guard !destroyed else { return }
        if history == nil {
            history = TerminalHistory(seek: { [weak self] offset in
                guard let self, let owner = TerminalRuntime.shared.workspace?.helper(containing: id) else {
                    throw CancellationError()
                }
                try await owner.seek(id, offset: offset)
            }, changed: { [weak self] in self?.scrollbar.update($0) })
        }
        history?.update(metrics.state)
        updateVisibility()
    }

    private func scrollToRow(_ row: UInt64) {
        guard !destroyed else { return }
        if let history { history.scroll(to: row); return }
        performBindingAction("scroll_to_row:\(row)")
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        self.tracking = tracking
        super.updateTrackingAreas()
    }
}

/// Rendering stays in a precisely sized child; input belongs to TerminalView.
private final class TerminalRenderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
