// What a touch host needs of the surface beyond Ghostty's pointer API (Dispatch for iPhone): a long
// press selects the word under the finger without a click reaching the program, selection handles
// move either end, and the scroll model asks whether the viewport has history above it or the
// program takes the wheel. iOS only; the Mac's AppKit host uses the pointer callbacks.
#if os(iOS)
extension Surface {
    /// A selection end a handle drags.
    public enum TouchHandle: Sendable { case start, end }

    /// The viewport cell under a point in pixels from the surface's top left (clamped to the grid).
    public func touchCell(x: Double, y: Double) -> (x: Int, y: Int) { viewport(Float(x), Float(y)) }

    /// Selects the word under a viewport cell, or the cell itself when it holds no word; false: no
    /// such cell. The program sees nothing (no click is reported).
    @discardableResult
    public func touchSelectWord(_ cell: (x: Int, y: Int)) -> Bool {
        guard let pin = screen.pin(.viewport, x: cell.x, y: cell.y) else { return false }
        setSelection(screen.selectWord(at: pin) ?? Selection(pin, pin))
        return true
    }

    /// Moves one end of the selection to a viewport cell. The ends stay ordered: when the moved end
    /// crosses the other, they swap, and the result names the handle the finger now drags.
    @discardableResult
    public func touchMoveSelection(_ handle: TouchHandle, to cell: (x: Int, y: Int)) -> TouchHandle? {
        guard let sel = screen.selection, let pin = screen.pin(.viewport, x: cell.x, y: cell.y) else { return nil }
        var (start, end) = sel.end.before(sel.start) ? (sel.end, sel.start) : (sel.start, sel.end)
        var moved = handle
        switch handle {
        case .start:
            if end.before(pin) { (start, end, moved) = (end, pin, .end) } else { start = pin }
        case .end:
            if pin.before(start) { (start, end, moved) = (pin, start, .start) } else { end = pin }
        }
        setSelection(Selection(start, end))
        return moved
    }

    /// The selection's first and last cells in viewport coordinates (an end off the viewport: nil).
    public var touchSelection: (start: (x: Int, y: Int)?, end: (x: Int, y: Int)?)? {
        guard let sel = screen.selection else { return nil }
        let (a, b) = sel.end.before(sel.start) ? (sel.end, sel.start) : (sel.start, sel.end)
        return (screen.point(.viewport, a), screen.point(.viewport, b))
    }

    public func touchClearSelection() { setSelection(nil) }

    /// The program reads the wheel itself: mouse reporting, or the alternate screen's alternate
    /// scroll (arrow keys), so the viewport has no history of its own to scroll.
    public var touchWheelGoesToProgram: Bool {
        isMouseReporting || terminal.isAlternate && terminal.modes.get(.mouseAlternateScroll)
    }

    /// The program asked for mouse reports (a tap is a click for it).
    public var touchMouseReporting: Bool { isMouseReporting }

    /// Rows of history above the viewport (0: at the top of the scrollback).
    public var touchHistoryAbove: Int { terminal.scrollbar.offset }
    /// Rows below the viewport (0: following the active area).
    public var touchHistoryBelow: Int {
        let s = terminal.scrollbar
        return max(0, s.total - s.offset - s.len)
    }

    /// Back to the active area (the program's output follows).
    public func touchScrollToBottom() { terminal.scrollViewport(.bottom) }
}
#endif
