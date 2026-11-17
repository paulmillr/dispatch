import AppKit
import SwiftUI

/// An always-mounted hit region with a fading native thumb. Keeping the region
/// transparent (rather than hiding it) lets pointer entry reveal the thumb.
@MainActor
final class ChatScrollbar: NSView {
    final class Thumb: NSScroller {
        var color = NSColor(Chrome.muted) { didSet { needsDisplay = true } }
        var began: (() -> Void)?
        var ended: (() -> Void)?
        override var isOpaque: Bool { false }
        override var acceptsFirstResponder: Bool { false }
        override func draw(_ dirtyRect: NSRect) {
            guard isEnabled else { return }
            color.withAlphaComponent(0.65).setFill()
            let knob = rect(for: .knob).insetBy(dx: 4, dy: 1)
            NSBezierPath(roundedRect: knob, xRadius: 3, yRadius: 3).fill()
        }
        override func mouseDown(with event: NSEvent) {
            began?()
            defer { ended?() }
            super.mouseDown(with: event)
        }
        override func scrollWheel(with event: NSEvent) { superview?.scrollWheel(with: event) }
    }
    let thumb = Thumb(frame: NSRect(x: 0, y: 0, width: 14, height: 100))
    var beganDragging: (() -> Void)?
    var endedDragging: (() -> Void)?
    var moved: ((CGFloat) -> Void)?
    var wheel: ((NSEvent) -> Void)?
    /// When the thumb fades out, unless revealed again before. One timer is pending at most: a reveal per wheel event
    /// only moves this deadline instead of scheduling another main-queue wake-up.
    private var hideAt: CFTimeInterval?
    private var hideTimerPending = false
    private var pointerInside = false
    private var dragging = false
    private var hoverArea: NSTrackingArea?
    private(set) var canScroll = false
    private(set) var revealed = false

    init() {
        super.init(frame: thumb.frame)
        thumb.scrollerStyle = .legacy
        thumb.autoresizingMask = [.width, .height]
        thumb.target = self; thumb.action = #selector(scrolled)
        thumb.isContinuous = true; thumb.alphaValue = 0
        thumb.setAccessibilityLabel("Chat history")
        thumb.setAccessibilityIdentifier("chat-scrollbar")
        addSubview(thumb)
        thumb.began = { [weak self] in
            guard let self else { return }
            dragging = true; reveal(); beganDragging?()
        }
        thumb.ended = { [weak self] in
            guard let self else { return }
            dragging = false; endedDragging?(); scheduleHide()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var isOpaque: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp,
            .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        hoverArea = area; addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { pointerInside = true; reveal() }
    override func mouseExited(with event: NSEvent) { pointerInside = false; scheduleHide() }
    override func mouseDown(with event: NSEvent) {
        guard canScroll else { return }
        reveal(); thumb.mouseDown(with: event)
    }
    override func scrollWheel(with event: NSEvent) { reveal(); wheel?(event) }
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { hideAt = nil }
        super.viewWillMove(toSuperview: newSuperview)
    }
    /// The knob `update` last computed. A hidden thumb takes it only when it shows again: every clip movement and
    /// streamed row calls `update`, and a knob moved under alpha 0 still redraws.
    private var knob: (proportion: CGFloat, fraction: Double) = (1, 0)
    func update(total: CGFloat, visible: CGFloat, offset: CGFloat) {
        canScroll = total > visible + 1
        if thumb.isEnabled != canScroll { thumb.isEnabled = canScroll }
        knob = (total > 0 ? min(1, visible / total) : 1, Double(max(0, min(1, offset / max(1, total - visible)))))
        if !canScroll {
            hideAt = nil
            revealed = false; thumb.alphaValue = 0
        }
        if revealed || dragging { applyKnob() }
    }
    /// The scroller's setters redraw it when a value changes; nothing else needs to.
    private func applyKnob() {
        if thumb.knobProportion != knob.proportion { thumb.knobProportion = knob.proportion }
        if !dragging && thumb.doubleValue != knob.fraction { thumb.doubleValue = knob.fraction }
    }
    func reveal() {
        guard canScroll else { return }
        hideAt = nil
        applyKnob()
        if !revealed || thumb.alphaValue != 1 {
            revealed = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                thumb.animator().alphaValue = 1
            }
        }
        scheduleHide()
    }
    private func scheduleHide() {
        hideAt = nil
        guard !pointerInside && !dragging else { return }
        hideAt = CACurrentMediaTime() + 1.2
        armHideTimer(after: 1.2)
    }
    private func armHideTimer(after delay: CFTimeInterval) {
        guard !hideTimerPending else { return }
        hideTimerPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.hideIfDue() }
        }
    }
    private func hideIfDue() {
        hideTimerPending = false
        guard let hideAt, !pointerInside, !dragging else { return }
        let remaining = hideAt - CACurrentMediaTime()
        if remaining > 0.001 { armHideTimer(after: remaining); return }
        self.hideAt = nil
        revealed = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MotionStore.reduced ? 0 : 0.2
            thumb.animator().alphaValue = 0
        }
    }
    @objc private func scrolled() {
        guard canScroll else { return }
        // The scroller's own value, before revealing it applies the knob `update` last computed.
        var fraction = CGFloat(thumb.doubleValue)
        let page = thumb.knobProportion / max(0.001, 1 - thumb.knobProportion)
        reveal()
        switch thumb.hitPart {
        case .decrementPage: fraction -= page
        case .incrementPage: fraction += page
        case .decrementLine: fraction -= page / 10
        case .incrementLine: fraction += page / 10
        default: break
        }
        moved?(min(1, max(0, fraction)))
    }
}
