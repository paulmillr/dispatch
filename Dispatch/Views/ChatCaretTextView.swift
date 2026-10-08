import AppKit

/// The system caret can throttle presentation of the entire full-screen
/// window on an Adaptive display. Keep NSTextView's editing, input-method
/// support and caret geometry, but paint the caret in our own backing store.
class ChatCaretTextView: NSTextView {
    private(set) var caretRect = NSRect.zero
    private(set) var caretOn = false
    private(set) var caretTimer: Timer?
    private var updatingCaret = false

    override var insertionPointColor: NSColor! {
        didSet { setNeedsDisplay(caretRect) }
    }

    override var shouldDrawInsertionPoint: Bool { false }
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {}

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        refreshCaret(restart: restartFlag)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // With the native caret disabled, AppKit need not restart its
        // insertion-point state when a nonempty selection collapses.
        refreshCaret(restart: true)
    }

    override func viewDidMoveToWindow() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        super.viewDidMoveToWindow()
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged), name: name, object: window)
            }
        }
        refreshCaret(restart: true)
    }

    @objc private func windowFocusChanged(_ notification: Notification) {
        if notification.name == NSWindow.didResignKeyNotification { windowDidResignKey() }
        refreshCaret(restart: true)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        // NSWindow installs firstResponder after this method returns.
        DispatchQueue.main.async { [weak self] in self?.refreshCaret(restart: true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { stopCaret() }
        return resigned
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshCaret(restart: false)
    }

    func windowDidResignKey() {}

    private var canShowCaret: Bool {
        window?.isKeyWindow == true && window?.firstResponder === self
            && isEditable && !isHiddenOrHasHiddenAncestor
            && selectedRanges.count == 1 && selectedRange().length == 0
    }

    private func refreshCaret(restart: Bool) {
        guard !updatingCaret else { return }
        updatingCaret = true
        defer { updatingCaret = false }
        guard canShowCaret, let window else { stopCaret(); return }

        // AppKit resolves wrapped lines, empty paragraphs, Unicode, bidi
        // text and marked-text positions. Its input-client rect is in screen
        // coordinates; drawing uses this (flipped) text view's coordinates.
        let screenRect = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        var rect = convert(window.convertFromScreen(screenRect), from: nil)
        // Offscreen text has no input-client rect. A later scroll redraw
        // restores the caret when the insertion point comes back into view.
        guard rect.minX.isFinite, rect.minY.isFinite, rect.height.isFinite, rect.height > 0 else {
            stopCaret(); return
        }
        let scale = window.backingScaleFactor
        rect.origin.x = (rect.minX * scale).rounded() / scale
        rect.origin.y = (rect.minY * scale).rounded() / scale
        rect.size.width = 1
        rect.size.height = ceil(rect.height * scale) / scale
        if caretRect != rect {
            setNeedsDisplay(caretRect)
            caretRect = rect
            setNeedsDisplay(rect)
        }
        if restart || caretTimer == nil {
            caretTimer?.invalidate()
            caretOn = true
            setNeedsDisplay(caretRect)
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                MainActor.assumeIsolated {
                    guard self.canShowCaret else { self.stopCaret(); return }
                    self.caretOn.toggle()
                    self.setNeedsDisplay(self.caretRect)
                }
            }
            caretTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopCaret() {
        caretTimer?.invalidate()
        caretTimer = nil
        if caretOn { setNeedsDisplay(caretRect) }
        caretOn = false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        refreshCaret(restart: false)
        if caretOn && canShowCaret && dirtyRect.intersects(caretRect) {
            insertionPointColor.setFill()
            caretRect.fill()
        }
    }

    isolated deinit { caretTimer?.invalidate() }
}

