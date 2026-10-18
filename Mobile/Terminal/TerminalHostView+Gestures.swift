import UIKit
@preconcurrency import Term

/// Touch: one finger scrolls (with momentum) through the local scrollback and then the multiplexer's history
/// (`TerminalScrollModel`); a tap focuses the terminal, clears a selection, or clicks for programs that read the
/// mouse; a long press selects the word under the finger, with handles to extend it and an edit menu with Copy and
/// Paste; a pinch changes the font size, which resizes the grid through the feed.
extension TerminalHostView: @MainActor UIEditMenuInteractionDelegate {
    func installGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        addGestureRecognizer(pinch)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        addGestureRecognizer(press)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.require(toFail: press)
        addGestureRecognizer(tap)
        let menu = UIEditMenuInteraction(delegate: self)
        addInteraction(menu)
        editMenu = menu
        for handle in [startHandle, endHandle] {
            handle.isHidden = true
            addSubview(handle)
            handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleDragged(_:))))
        }
    }

    /// The scroll pan starts only for mostly vertical movement.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let pan = gestureRecognizer as? UIPanGestureRecognizer, pan.view === self {
            let v = pan.velocity(in: self)
            return abs(v.y) >= abs(v.x)
        }
        return true
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            stopMomentum()
            scroll.endGesture()
        case .changed:
            let dy = pan.translation(in: self).y
            pan.setTranslation(.zero, in: self)
            scrollBy(points: dy, at: pan.location(in: self))
        case .ended:
            startMomentum(pan.velocity(in: self).y, at: pan.location(in: self))
        default:
            scroll.endGesture()
        }
    }

    /// Finger travel in points (positive: down, toward older output) as lines for the emulator and the server.
    func scrollBy(points: Double, at point: CGPoint) {
        let lines = scroll.lines(points: points, lineHeight: cellSize.height)
        guard lines != 0 else { return }
        let local = session.locked {
            TerminalScrollModel.Local(above: session.surface.touchHistoryAbove, below: session.surface.touchHistoryBelow,
                                      programTakesWheel: session.surface.touchWheelGoesToProgram)
        }
        let plan = scroll.route(lines, local: local)
        if plan.local != 0 { scrollLocally(plan.local) }
        if plan.server != 0, let feed {
            let cell = cell(at: point)
            let request = TerminalScrollRequest(lines: plan.server, column: cell.x, row: cell.y)
            Task { [weak self] in
                let result = await feed.scroll(request)
                guard let self else { return }
                let replay = self.scroll.answered(result, for: plan)
                if replay != 0 { self.scrollLocally(replay) }
            }
        }
    }

    /// Lines through the emulator: its scrollback, or the program's wheel (arrow keys or mouse reports).
    func scrollLocally(_ lines: Int) {
        let height = Double(session.currentSize.cellHeight)
        session.locked { session.surface.scroll(x: 0, y: Double(lines) * height, mods: 1) }
        session.pump()
    }

    private func startMomentum(_ velocity: Double, at point: CGPoint) {
        guard abs(velocity) > 80 else { scroll.endGesture(); return }
        momentumVelocity = velocity
        momentumTime = CACurrentMediaTime()
        momentumPoint = point
        let link = CADisplayLink(target: self, selector: #selector(momentumStep(_:)))
        link.add(to: .main, forMode: .common)
        momentum = link
    }

    func stopMomentum() {
        momentum?.invalidate()
        momentum = nil
    }

    @objc private func momentumStep(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = now - momentumTime
        momentumTime = now
        // UIScrollView's normal deceleration: 0.998 per millisecond.
        momentumVelocity *= pow(0.998, dt * 1000)
        scrollBy(points: momentumVelocity * dt, at: momentumPoint)
        if abs(momentumVelocity) < 30 {
            stopMomentum()
            scroll.endGesture()
        }
    }

    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            pinchBase = configuration.fontSize
        case .changed:
            guard let base = pinchBase else { return }
            let size = TerminalConfiguration.zoomed(base, scale: pinch.scale)
            guard size != configuration.fontSize else { return }
            var next = configuration
            next.fontSize = size
            configure(next)
            onFontSize?(size)
        default:
            pinchBase = nil
        }
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        stopMomentum()
        if session.locked({ session.surface.hasSelection }) {
            session.locked { session.surface.touchClearSelection() }
            session.pump()
            editMenu?.dismissMenu()
            return
        }
        if !isFirstResponder { _ = becomeFirstResponder() }
        guard session.locked({ session.surface.touchMouseReporting }) else { return }
        let point = tap.location(in: self)
        session.locked {
            let surface = session.surface
            surface.mousePos(x: point.x, y: point.y, mods: [])
            _ = surface.mouseButton(.press, .left, mods: [])
            _ = surface.mouseButton(.release, .left, mods: [])
        }
        session.pump()
    }

    @objc private func longPressed(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began else { return }
        stopMomentum()
        let cell = cell(at: press.location(in: self))
        guard session.locked({ session.surface.touchSelectWord(cell) }) else { return }
        session.pump()
        UISelectionFeedbackGenerator().selectionChanged()
        updateSelectionHandles()
        showEditMenu()
    }

    @objc private func handleDragged(_ pan: UIPanGestureRecognizer) {
        guard let handle = pan.view as? TerminalSelectionHandle else { return }
        switch pan.state {
        case .began:
            editMenu?.dismissMenu()
            draggedHandle = handle.end ? .end : .start
        case .changed:
            guard let dragged = draggedHandle else { return }
            // The handle's knob sits off the text: aim at the cell the stem marks.
            var point = pan.location(in: self)
            point.y += handle.end ? -cellSize.height / 2 : cellSize.height / 2
            draggedHandle = session.locked { session.surface.touchMoveSelection(dragged, to: cell(at: point)) } ?? dragged
            session.pump()
            updateSelectionHandles()
        default:
            draggedHandle = nil
            showEditMenu()
        }
    }

    /// The handles follow the selection's ends (hidden for an end off the viewport, or no selection).
    func updateSelectionHandles() {
        let ends = session.locked { session.surface.touchSelection }
        guard let ends else {
            startHandle.isHidden = true
            endHandle.isHidden = true
            return
        }
        let height = cellSize.height
        if let start = ends.start {
            let r = rect(of: start)
            startHandle.place(stemTop: CGPoint(x: r.minX, y: r.minY), height: height)
        }
        if let end = ends.end {
            let r = rect(of: end)
            endHandle.place(stemTop: CGPoint(x: r.maxX, y: r.minY), height: height)
        }
        startHandle.isHidden = ends.start == nil
        endHandle.isHidden = ends.end == nil
    }

    private func showEditMenu() {
        guard let ends = session.locked({ session.surface.touchSelection }), let start = ends.start ?? ends.end else { return }
        let r = rect(of: start)
        editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: r.midX, y: r.minY)))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        var actions: [UIMenuElement] = [UIAction(title: "Copy") { [weak self] _ in self?.copy(nil) }]
        if UIPasteboard.general.hasStrings {
            actions.append(UIAction(title: "Paste") { [weak self] _ in
                guard let self else { return }
                self.session.locked { self.session.surface.touchClearSelection() }
                self.paste(nil)
            })
        }
        return UIMenu(children: actions)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        guard let ends = session.locked({ session.surface.touchSelection }) else { return .zero }
        let a = ends.start.map { rect(of: $0) }, b = ends.end.map { rect(of: $0) }
        switch (a, b) {
        case let (a?, b?): return a.minY == b.minY ? a.union(b) : CGRect(x: 0, y: a.minY, width: bounds.width, height: b.maxY - a.minY)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return .zero
        }
    }
}

/// A selection handle: the system's look (a stem the cell's height, a knob above the start or below the end) in the
/// app tint. Its frame is larger than the drawing so a thumb can catch it.
final class TerminalSelectionHandle: UIView {
    let end: Bool
    private let stem = UIView(), knob = UIView()
    static let touch = 44.0

    init(end: Bool) {
        self.end = end
        super.init(frame: CGRect(x: 0, y: 0, width: Self.touch, height: Self.touch))
        let tint = UIColor(named: "AccentColor") ?? .systemPink
        stem.backgroundColor = tint
        knob.backgroundColor = tint
        knob.layer.cornerRadius = 5
        addSubview(stem)
        addSubview(knob)
        accessibilityLabel = end ? "Selection end" : "Selection start"
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Places the stem along a cell's edge from `stemTop`, `height` tall.
    func place(stemTop: CGPoint, height: Double) {
        let width = Self.touch
        frame = CGRect(x: stemTop.x - width / 2, y: stemTop.y - (end ? 0 : 10), width: width, height: height + 10)
        let local = CGPoint(x: width / 2, y: end ? 0 : 10)
        stem.frame = CGRect(x: local.x - 1, y: local.y, width: 2, height: height)
        knob.frame = CGRect(x: local.x - 5, y: end ? local.y + height : local.y - 10, width: 10, height: 10)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: -12).contains(point)
    }
}
