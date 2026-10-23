import UIKit
@preconcurrency import Term

/// Touch: one finger scrolls (with momentum) through the local scrollback and then the multiplexer's history
/// (`TerminalScrollModel`); a tap focuses the terminal, clears a selection, or clicks for programs that read the
/// mouse; a long press selects the word under the finger, with handles to extend it and an edit menu with Copy and
/// Paste; a pinch changes the font size, which resizes the grid through the feed.
///
/// A pointer (iPad trackpad or mouse) works as on the Mac: a click, double click or drag selects through the
/// surface's own mouse handling (or reaches a program that reads the mouse), a secondary click selects the word under
/// it as Ghostty's context-menu click does and opens the edit menu there, hovering moves the surface's mouse (links,
/// programs tracking motion) under an I-beam, a trackpad's two-finger scroll is a finger's (with momentum) and a
/// wheel's notches scroll without momentum.
extension TerminalHostView: @MainActor UIEditMenuInteractionDelegate, @MainActor UIPointerInteractionDelegate {
    /// Fingers and the Pencil; a pointer has recognizers of its own.
    static let touchTypes = [UITouch.TouchType.direct, .pencil].map { NSNumber(value: $0.rawValue) }
    static let pointerTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]

    func installGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = Self.touchTypes
        pan.allowedScrollTypesMask = .continuous
        addGestureRecognizer(pan)
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(wheeled(_:)))
        wheel.allowedTouchTypes = []
        wheel.allowedScrollTypesMask = .discrete
        addGestureRecognizer(wheel)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        addGestureRecognizer(pinch)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        press.allowedTouchTypes = Self.touchTypes
        addGestureRecognizer(press)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.allowedTouchTypes = Self.touchTypes
        tap.require(toFail: press)
        addGestureRecognizer(tap)
        let click = UILongPressGestureRecognizer(target: self, action: #selector(clicked(_:)))
        click.minimumPressDuration = 0
        click.allowableMovement = .greatestFiniteMagnitude
        click.allowedTouchTypes = Self.pointerTypes
        addGestureRecognizer(click)
        let secondary = UITapGestureRecognizer(target: self, action: #selector(secondaryClicked(_:)))
        secondary.allowedTouchTypes = Self.pointerTypes
        secondary.buttonMaskRequired = .secondary
        addGestureRecognizer(secondary)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        addInteraction(UIPointerInteraction(delegate: self))
        pointerRecognizers = (pan: pan, wheel: wheel, click: click, secondary: secondary)
        let menu = UIEditMenuInteraction(delegate: self)
        addInteraction(menu)
        editMenu = menu
        for handle in [startHandle, endHandle] {
            handle.isHidden = true
            addSubview(handle)
            handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleDragged(_:))))
        }
    }

    /// The scroll pan starts only for mostly vertical movement; the pointer's press only for the primary button
    /// (the secondary one is the edit menu's tap).
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pointerRecognizers?.click { return gestureRecognizer.buttonMask == .primary }
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

    /// A mouse wheel's notches: lines, no momentum.
    @objc private func wheeled(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            stopMomentum()
            scroll.endGesture()
        case .changed:
            let dy = pan.translation(in: self).y
            pan.setTranslation(.zero, in: self)
            scrollBy(points: dy, at: pan.location(in: self))
        default:
            scroll.endGesture()
        }
    }

    /// Keyboard modifiers held during a pointer gesture, as the surface's.
    static func mods(_ flags: UIKeyModifierFlags) -> Mods {
        var mods: Mods = []
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.ctrl) }
        if flags.contains(.alternate) { mods.insert(.alt) }
        if flags.contains(.command) { mods.insert(.super) }
        return mods
    }

    /// The primary button: pressed, dragged, released, as the Mac's mouseDown/Dragged/Up. The surface counts double
    /// and triple clicks (word, line) and drags the selection, or reports the clicks to a program that asked.
    @objc private func clicked(_ press: UILongPressGestureRecognizer) {
        pointerPress(press.state, at: press.location(in: self), mods: Self.mods(press.modifierFlags))
    }

    func pointerPress(_ state: UIGestureRecognizer.State, at point: CGPoint, mods: Mods) {
        switch state {
        case .began:
            stopMomentum()
            editMenu?.dismissMenu()
            pointerSelection = true
            if !isFirstResponder { _ = becomeFirstResponder() }
            session.locked {
                session.surface.mousePos(x: point.x, y: point.y, mods: mods)
                _ = session.surface.mouseButton(.press, .left, mods: mods)
            }
        case .changed:
            session.locked { session.surface.mousePos(x: point.x, y: point.y, mods: mods) }
        default:
            session.locked {
                session.surface.mousePos(x: point.x, y: point.y, mods: mods)
                _ = session.surface.mouseButton(.release, .left, mods: mods)
            }
        }
        session.pump()
        updateSelectionHandles()
    }

    /// The secondary button: the surface selects the word under it (unless inside the selection) or reports the click
    /// to a program that reads the mouse; otherwise the edit menu opens at the pointer.
    @objc private func secondaryClicked(_ tap: UITapGestureRecognizer) {
        secondaryClick(at: tap.location(in: self), mods: Self.mods(tap.modifierFlags))
    }

    func secondaryClick(at point: CGPoint, mods: Mods) {
        stopMomentum()
        pointerSelection = true
        if !isFirstResponder { _ = becomeFirstResponder() }
        let reported = session.locked {
            session.surface.mousePos(x: point.x, y: point.y, mods: mods)
            let used = session.surface.mouseButton(.press, .right, mods: mods)
            _ = session.surface.mouseButton(.release, .right, mods: mods)
            return used
        }
        session.pump()
        updateSelectionHandles()
        guard !reported else { return }
        editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: Self.pointerMenu, sourcePoint: point))
    }

    static let pointerMenu = "pointer" as NSString

    /// The pointer moved over the terminal (links, programs tracking motion); it left: off the grid.
    @objc private func hovered(_ hover: UIHoverGestureRecognizer) {
        let point = hover.state == .ended || hover.state == .cancelled ? CGPoint(x: -1, y: -1) : hover.location(in: self)
        session.locked { session.surface.mousePos(x: point.x, y: point.y, mods: Self.mods(hover.modifierFlags)) }
        session.pump()
    }

    /// An I-beam a cell tall over the text, as the Mac's text cursor.
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(shape: .verticalBeam(length: max(8, cellSize.height)), constrainedAxes: [])
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
        pointerSelection = false
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

    /// The handles follow the selection's ends (hidden for an end off the viewport, or no selection, or a selection
    /// a pointer made: it changes it with the pointer, as in iPadOS's text views).
    func updateSelectionHandles() {
        let ends = session.locked { session.surface.touchSelection }
        guard let ends, !pointerSelection else {
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

    /// Select all from the key bar's menu: the whole screen and history selected with handles, and the edit menu
    /// (Copy) over it, as after a long press.
    func selectAllWithMenu() {
        pointerSelection = false
        selectAll(nil)
        updateSelectionHandles()
        showEditMenu()
    }

    func showEditMenu() {
        guard let ends = session.locked({ session.surface.touchSelection }), let start = ends.start ?? ends.end else { return }
        let r = rect(of: start)
        editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: r.midX, y: r.minY)))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        if configuration.identifier as? NSString == Self.pointerMenu { return pointerMenu() }
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

    /// The secondary click's menu: Copy with a selection, Paste with text, Select All (the Mac's Edit menu).
    func pointerMenu() -> UIMenu {
        var actions: [UIMenuElement] = []
        if session.locked({ session.surface.hasSelection }) {
            actions.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copy(nil) })
        }
        if UIPasteboard.general.hasStrings {
            actions.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                guard let self else { return }
                self.session.locked { self.session.surface.touchClearSelection() }
                self.paste(nil)
            })
        }
        actions.append(UIAction(title: "Select All", image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in self?.selectAll(nil) })
        return UIMenu(children: actions)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        if configuration.identifier as? NSString == Self.pointerMenu {
            return CGRect(origin: configuration.sourcePoint, size: .zero)
        }
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
        // The app's tint, the theme's when one is chosen (resolved by the window's trait as it draws).
        let tint = UIColor.themed("AccentColor", \.accent)
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
