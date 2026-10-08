// Selection by mouse gestures (Ghostty's SelectionGesture.zig): single, double and triple clicks
// counted by time and distance, cell/word/line/output behaviors, the drag threshold, autoscroll.
// It computes selections; the caller applies them (Screen.select), like Ghostty's surface does.

/// The left button's selection gesture on one terminal. Owns a tracked pin while a click is
/// active: call `reset` before dropping it.
public struct SelectionGesture {
    public enum Behavior: String { case cell, word, line, output }
    public enum Autoscroll: String { case none, up, down }

    /// Surface geometry for the drag threshold and autoscroll, in surface pixels.
    public struct Geometry {
        public var columns: UInt32, cellWidth: UInt32, paddingLeft: UInt32, screenHeight: UInt32
        public init(columns: UInt32, cellWidth: UInt32, paddingLeft: UInt32, screenHeight: UInt32) {
            (self.columns, self.cellWidth, self.paddingLeft, self.screenHeight) = (columns, cellWidth, paddingLeft, screenHeight)
        }
    }

    /// The first press of the click: tracked on its screen, valid while that screen's generation holds.
    var click: (pin: TrackedPin, screen: Int, generation: Int)?
    /// Surface position of the first press (later presses and drags measure from it).
    var x = 0.0, y = 0.0
    /// Clicks in the sequence (1-3; 0 = no gesture), time of the last press (ns, monotonic).
    public private(set) var count = 0, time: UInt64?
    public private(set) var behavior = Behavior.cell, dragged = false, autoscroll = Autoscroll.none

    public init() {}

    /// The first press's pin if it is on the active screen (nil: no gesture, or the screen changed).
    public func anchor(_ t: Terminal) -> Pin? {
        guard let c = click, c.screen == t.activeKey, t.screen(c.screen)?.generation == c.generation else { return nil }
        return c.pin.pin
    }

    /// A press continues the click sequence when it comes within `interval` ns of the last one,
    /// within `maxDistance` px of the first one, on the same screen; otherwise it starts a new one.
    /// `behaviors`: for single, double and triple clicks. Returns the click's selection (cell: nil).
    public mutating func press(_ t: Terminal, pin: Pin, x: Double, y: Double, time: UInt64?, maxDistance: Double, interval: UInt64,
                               behaviors: [Behavior] = [.cell, .word, .line], boundaries: [UInt32] = wordBoundaries) -> Selection? {
        let (dx, dy) = (x - self.x, y - self.y)
        if count > 0, let now = time, let last = self.time, now >= last, now - last <= interval,
           !((dx * dx + dy * dy).squareRoot() > maxDistance), anchor(t) != nil {
            count = min(count + 1, 3)
            (self.time, dragged, autoscroll, behavior) = (now, false, .none, behaviors[count - 1])
        } else {
            reset(t)
            click = (t.active.pages.track(pin), t.activeKey, t.screen(t.activeKey)!.generation)
            (count, behavior, self.x, self.y, self.time) = (1, behaviors[0], x, y, time)
        }
        switch behavior {
        case .cell: return nil
        case .word: return t.active.selectWord(at: pin, boundaries: boundaries)
        case .line: return t.active.selectLine(at: pin)
        case .output: return t.active.selectOutput(at: pin)
        }
    }

    /// The selection from the first press to `pin` by the click's behavior. Asks for autoscroll
    /// when `y` is within 1 px of the top or bottom edge.
    public mutating func drag(_ t: Terminal, pin: Pin, x: Double, y: Double, rectangle: Bool, geometry g: Geometry,
                              boundaries: [UInt32] = wordBoundaries) -> Selection? {
        guard count > 0, let click = anchor(t) else { return nil }
        if pin != click { dragged = true }
        autoscroll = y <= 1 ? .up : y > Double(g.screenHeight) - 1 ? .down : .none
        let s = t.active, back = pin.before(click)
        var sel: Selection?
        switch behavior {
        case .cell: sel = Self.cells(click, pin, self.x, x, rectangle, g)
        case .word:
            guard let a = s.selectWord(between: click, and: pin, boundaries: boundaries),
                  let b = s.selectWord(between: pin, and: click, boundaries: boundaries) else { return nil }
            sel = back ? Selection(b.start, a.end) : Selection(a.start, b.end)
        case .line:
            guard let line = s.selectLine(at: pin), var c = s.selectLine(at: click) ?? s.selectLine(at: click, whitespace: nil) else { return nil }
            if back { c.start = line.start } else { c.end = line.end }
            sel = c
        case .output:
            guard var c = s.selectOutput(at: click) else { return nil }
            if let o = s.selectOutput(at: pin) { if back { c.start = o.start } else { c.end = o.end } }
            sel = c
        }
        if behavior == .cell, sel != nil { dragged = true }
        return sel
    }

    /// Scrolls the viewport one row in the autoscroll direction, then drags to the viewport cell
    /// now under the pointer. Resets the gesture if its screen changed.
    public mutating func autoscrollTick(_ t: Terminal, viewport: (x: Int, y: Int), x: Double, y: Double, rectangle: Bool, geometry: Geometry,
                                        boundaries: [UInt32] = wordBoundaries) -> Selection? {
        guard count > 0, autoscroll != .none else { return nil }
        guard anchor(t) != nil else { reset(t); return nil }
        t.scrollViewport(.delta(autoscroll == .up ? -1 : 1))
        guard let pin = t.active.pin(.viewport, x: viewport.x, y: viewport.y) else { return nil }
        return drag(t, pin: pin, x: x, y: y, rectangle: rectangle, geometry: geometry, boundaries: boundaries)
    }

    /// A force click while pressed: the word under the first press; ends the gesture.
    public mutating func deepPress(_ t: Terminal, boundaries: [UInt32] = wordBoundaries) -> Selection? {
        guard let click = anchor(t) else { return nil }
        let sel = t.active.selectWord(at: click, boundaries: boundaries)
        reset(t)
        dragged = true
        return sel
    }

    /// Ends a drag (the click sequence stays for the next press). `pin`: the release cell, nil
    /// when the pointer is not over one (counts as moved).
    public mutating func release(_ t: Terminal, pin: Pin?) {
        guard count > 0 else { return }
        if pin == nil || pin != anchor(t) { dragged = true }
        autoscroll = .none
    }

    /// Cancels the gesture and releases its pin.
    public mutating func reset(_ t: Terminal) {
        (count, time, behavior, dragged, autoscroll) = (0, nil, .cell, false, .none)
        if let c = click, let s = t.screen(c.screen), s.generation == c.generation { s.screen.pages.untrack(c.pin) }
        click = nil
    }

    /// The first press's screen and pin (pin nil: that screen was removed since). For tests.
    @_spi(Test) public func pressed(_ t: Terminal) -> (screen: Int, pin: Pin?)? {
        click.map { c in (c.screen, t.screen(c.screen)?.generation == c.generation ? c.pin.pin : nil) }
    }

    /// Cell selection with a threshold at 60% of a cell: the first and the current cell count
    /// once the pointer is past it in the drag's direction (a rectangle compares columns).
    static func cells(_ click: Pin, _ drag: Pin, _ clickX: Double, _ dragX: Double, _ rect: Bool, _ g: Geometry) -> Selection? {
        guard g.columns > 0, g.cellWidth > 0 else { return nil }
        let threshold = UInt32((Double(g.cellWidth) * 0.6).rounded())
        let span = g.columns.multipliedReportingOverflow(by: g.cellWidth)
        let last = (span.overflow ? .max : span.partialValue) - 1
        let pixel = { (v: Double) -> UInt32 in v.isNaN || v <= 0 ? 0 : v >= Double(UInt32.max) ? .max : UInt32(v) }
        let offset = { (v: Double) in min(last, pixel(v) > g.paddingLeft ? pixel(v) - g.paddingLeft : 0) % g.cellWidth }
        let (cx, dx, same) = (offset(clickX), offset(dragX), drag == click)
        let back = same ? dx < cx : rect ? (drag.x == click.x ? dx < cx : drag.x < click.x) : drag.before(click)
        let (withClick, withDrag) = back ? (cx >= threshold, dx < threshold) : (cx < threshold, dx >= threshold)
        // One cell towards the other end in reading order. Ghostty keeps a rectangle's step inside
        // the row; that differs only at a row edge, where the same-column rule below gives nil anyway.
        let step = { (p: Pin, right: Bool) in p.cells(down: right).dropFirst().first { _ in true } ?? p }
        let start = withClick ? click : step(click, !back), end = withDrag ? drag : step(drag, back)
        if !withClick && (same || end == click || rect && (click.x == drag.x || end.x == click.x))
            || !withDrag && (start == drag || rect && start.x == drag.x) { return nil }
        return Selection(start, end, rectangle: rect)
    }
}
