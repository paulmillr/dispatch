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
    /// A workspace terminal's tty on this Mac (a terminal on another machine has none here); nil outer: a standalone view.
    private var helperDevice: UInt32?? {
        guard launchCommand == nil, let workspace = TerminalRuntime.shared.workspace,
              let helper = workspace.helper(containing: id),
              let terminal = workspace.spaces.flatMap(\.tabs).first(where: { $0.id == id })?.terminal else { return nil }
        guard helper.endpoint == .local, let tty = helper.node(terminal)?.tty else { return .some(nil) }
        return UInt32(exactly: tty)
    }
    var foregroundPIDOverride: UInt64? { helperDevice.map { $0.flatMap(AgentProcess.foregroundGroup(device:)) ?? 0 } }
    /// The programs besides its shell on this terminal's tty (`AgentProcess.jobs`); nil when this Mac cannot see its tty
    /// (a standalone view, a terminal on another machine).
    var jobs: [String]? { helperDevice?.flatMap(AgentProcess.jobs(device:)) }
    /// The program here is reading a password, as far as this Mac can tell.
    private var atPasswordPrompt: Bool {
        guard let device = helperDevice else { return surface?.passwordInput ?? false }
        return device.map(System.passwordPrompt(device:)) ?? false
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
    /// `onScreen` as last told to the tab's helper.
    private var reportedOnScreen = false
    private var destroyed = false
    var herdrScrollAccumulator = HerdrScrollAccumulator()
    let scrollbar = TerminalScrollbar()
    var history: TerminalHistory?
    /// Coalesces screen publication across output batches (`screenChanged`).
    let screenPublication = OSAllocatedUnfairLock(initialState: ScreenPublication())
    private var tracking: NSTrackingArea?
    private var rendererView: NSView?
    /// The pointer over the terminal (`setPointer`): the I-beam, a link's pointing hand, or a program's choice.
    var pointer: NSCursor = .iBeam
    /// The URL of the link under the pointer, at the terminal's bottom left while it shows (`showLinkPreview`).
    var linkPreview: NSTextField?
    var markedTextRange = NSRange(location: NSNotFound, length: 0)
    var selectedTextRange = NSRange(location: 0, length: 0)
    var markedText = ""
    var currentKeyEvent: NSEvent?
    var keyTextAccumulator: [String] = []
    /// Plain text typed since the last Return; nil once another key (arrows, chords, paste) may
    /// have edited the line. Chat adopts what was typed into an agent's prompt before it opened.
    var typeahead: String? = ""
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
        registerDropTypes()
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
        // Replay: off screen this view gets no layout, so its pty cannot reach a recorded size meanwhile (no-op live).
        System.terminal(id)?.ticket.offscreen(window == nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowOcclusionDidChange(_:)),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowScreenDidChange(_:)),
                name: NSWindow.didChangeScreenNotification, object: window)
        }
        // Leaving the window invalidated the frames' display link (AppKit does), even back on the
        // same display: a remounted tab draws again only from a new one.
        if window != nil, let surface { surface.relink() }
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
        // A gone tab (`TerminalTab.gone`) keeps showing its saved output: no process starts for it again.
        if TerminalRuntime.shared.hosts.reconnect.awaitingRestore(id) || TerminalRuntime.shared.workspace?.isGone(id) == true {
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
            variables = helper.environment(id: id)
            workingDirectory = System.home.path
        } else {
            // A standalone view runs its own command (nil = the login shell).
            variables = System.testing ? ["HOME", System.home.path, "GHOSTTY_ZSH_ZDOTDIR", "/var/empty", "DISPATCH_TESTING", "1"] : []
            // Native tests must not source the user's shell plugins/update checks.
            command = launchCommand ?? (System.testing ? "/bin/zsh" : nil)
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
        SecureKeyboardEntry.blur(self)
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

    func updateFocus() { setFocus(!inputParked && isPresented && window?.isKeyWindow == true && window?.firstResponder === self) }

    private func setFocus(_ focused: Bool) {
        surface?.setFocus(focused)
        if focused { SecureKeyboardEntry.focus(self) { [weak self] in self?.atPasswordPrompt ?? false } }
        else { SecureKeyboardEntry.blur(self) }
    }

    @objc private func windowOcclusionDidChange(_ notification: Notification) { updateVisibility() }
    /// Another display (one went away, the window moved): geometry reports it, the frames follow.
    @objc private func windowScreenDidChange(_ notification: Notification) { updateGeometry() }
    /// The displays woke: the frames' display link can stay asleep, even on the same display.
    @objc private func screensDidWake(_ notification: Notification) { surface?.relink() }

    /// The terminal is on screen: presented (its tab shown in its pane, Terminal rather than Chat or Files) in a window
    /// that is at least partly visible. Off screen the engine does not render, and a chat tab's helper may hold its
    /// output (`HelperWorkspace.reconsider`).
    var onScreen: Bool { isPresented && window?.occlusionState.contains(.visible) == true }

    private func updateVisibility() {
        let shown = onScreen
        history?.setActive(shown)
        if shown != reportedOnScreen {
            reportedOnScreen = shown
            TerminalRuntime.shared.workspace?.helper(containing: id)?.reconsider(id)
        }
        guard let surface else { return }
        // Chat keeps the view mounted. Pause rendering while hidden, but leave
        // terminal IO running so the same session is current when revealed. A view out of its window is a tab or
        // space not shown (only the selected one is mounted): hidden, unlike one whose window is merely covered.
        surface.setOcclusion(shown, presented: isPresented && window != nil)
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
        setFocus(false)
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
    /// At the terminal's opacity, so a translucent terminal's margin matches its grid.
    func setBackground(r: UInt8, g: UInt8, b: UInt8) {
        scrollbar.setBackground(r: r, g: g, b: b)
        let alpha = TerminalRuntime.shared.config?.backgroundOpacity ?? 1
        layer?.backgroundColor = CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: alpha)
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

extension TerminalView {
    /// The engine's pointer shape by its CSS name (Ghostty's mouse_shape), as AppKit has it; the I-beam for the rest.
    static func cursor(named name: String) -> NSCursor {
        switch name {
        case "default", "progress", "wait", "help", "all_scroll", "move", "cell", "zoom_in", "zoom_out": .arrow
        case "context_menu": .contextualMenu
        case "pointer": .pointingHand
        case "crosshair": .crosshair
        case "vertical_text": .iBeamCursorForVerticalLayout
        case "alias": .dragLink
        case "copy": .dragCopy
        case "no_drop", "not_allowed": .operationNotAllowed
        case "grab": .openHand
        case "grabbing": .closedHand
        case "col_resize", "ew_resize", "e_resize", "w_resize": .resizeLeftRight
        case "row_resize", "ns_resize", "n_resize", "s_resize": .resizeUpDown
        default: .iBeam
        }
    }

    func setPointer(_ name: String) {
        let cursor = Self.cursor(named: name)
        guard cursor != pointer else { return }
        pointer = cursor
        window?.invalidateCursorRects(for: self)
        // The pointer is over this terminal (the engine only reports shapes for motion here): show it now.
        if let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { cursor.set() }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: pointer)
    }

    /// Where a ⌘-hovered link goes, in a small label at the terminal's bottom left, as Ghostty and browsers show it.
    func showLinkPreview(_ url: String?) {
        guard let url, !url.isEmpty else {
            linkPreview?.removeFromSuperview(); linkPreview = nil
            return
        }
        let label = linkPreview ?? {
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .labelColor
            label.drawsBackground = true
            label.backgroundColor = .windowBackgroundColor.withAlphaComponent(0.92)
            label.lineBreakMode = .byTruncatingMiddle
            label.wantsLayer = true
            label.layer?.cornerRadius = 4
            label.layer?.zPosition = 999
            label.setAccessibilityIdentifier("terminal-link-preview")
            addSubview(label)
            linkPreview = label
            return label
        }()
        label.stringValue = " " + String(url.prefix(2048)) + " "
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 6, y: 6, width: min(size.width, max(40, bounds.width - 12)), height: size.height)
    }

    /// A program rang the bell (Settings › General › Bell): on screen with Dispatch in front, the alert sound or a flash
    /// over the terminal; otherwise its tab is marked with a bell until you type in it (`ProgramStatusStore.rang`).
    func ringBell() {
        let runtime = TerminalRuntime.shared, style = runtime.preferences.bell
        guard style != .off else { return }
        guard onScreen, NSApp.isActive, window?.isKeyWindow == true else { return runtime.programs.ring(id) }
        switch style {
        case .sound: NSSound.beep()
        case .flash: flash()
        case .off: break
        }
    }

    /// The visual bell: the terminal briefly lightens, as Terminal.app's and iTerm2's do; with Reduce Motion it shows
    /// and goes without fading.
    private func flash() {
        guard let layer else { return }
        let overlay = CALayer()
        overlay.frame = layer.bounds
        overlay.backgroundColor = NSColor.labelColor.withAlphaComponent(0.18).cgColor
        overlay.zPosition = 1000
        layer.addSublayer(overlay)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setCompletionBlock { overlay.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = reduce ? 0.12 : 0.25
        fade.timingFunction = CAMediaTimingFunction(name: reduce ? .linear : .easeOut)
        if reduce { fade.fromValue = 1; fade.toValue = 1 }
        overlay.opacity = 0
        overlay.add(fade, forKey: "flash")
        CATransaction.commit()
    }
}
