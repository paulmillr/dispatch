// Keyboard and mouse input of the surface (Ghostty's Surface.zig keyCallback, mouseButtonCallback,
// cursorPosCallback, scrollCallback, mousePressureCallback and their helpers).

extension Surface {
    public enum KeyEffect { case ignored, consumed, closed }

    /// A key from the host (ghostty_surface_key): the physical key from the mac keycode. True: handled.
    public func key(_ action: KeyEvent.Action, keycode: UInt32, mods: Mods, consumed: Mods, composing: Bool, unshifted: UInt32, text: [UInt8]) -> Bool {
        var e = KeyEvent()
        (e.action, e.key, e.mods, e.consumedMods, e.composing) = (action, Key(macKeycode: keycode), mods, consumed, composing)
        (e.unshiftedCodepoint, e.utf8) = (unshifted <= 0x10FFFF ? unshifted : 0, text)
        return key(e) != .ignored
    }

    /// Surface.keyCallback.
    func key(_ event: KeyEvent) -> KeyEffect {
        if let effect = binding(event) { return effect }
        if config.mouseHideWhileTyping, event.action == .press, !mouse.hidden, !event.utf8.isEmpty { hideMouse() }
        if mouse.mods != event.mods {
            modsChanged(event.mods)
            if terminal.flags.mouseEvent == .none || mouse.mods.contains(.shift) && !shiftCapture() {
                refreshLinks(cursor, viewport(cursor.x, cursor.y), overLink: mouse.overLink)
            } else if !mouse.mods.contains(.shift) {
                _ = host?.perform(.mouseShape(terminal.mouseShape))
                _ = host?.perform(.mouseOverLink([]))
            }
        }
        if let shape = keyShape(event.key) { _ = host?.perform(.mouseShape(shape)) }
        var copy = event
        copy.utf8 = []
        if event.action == .release, let prev = keyboard.pressed, prev.key == copy.key { copy.key = .unidentified }
        keyboard.pressed = event.action == .release && keyboard.pressed == nil || copy.key == .unidentified && copy.mods.isEmpty ? nil : copy
        var o = KeyOptions(terminal)
        o.optionAsAlt = config.optionAsAlt
        let bytes = event.encode(o)
        guard !bytes.isEmpty else { return .ignored }
        write(bytes)
        if !event.key.isModifier {
            if config.selectionClearOnTyping || event.key == .escape { setSelection(nil) }
            if config.scrollToBottomOnKey { terminal.scrollViewport(.bottom) }
        }
        return .consumed
    }

    /// Surface.maybeHandleBinding for single-key bindings: a release of the key that triggered a
    /// binding is consumed; a press or repeat performs the bound action.
    func binding(_ event: KeyEvent) -> KeyEffect? {
        let hash = (event.key, event.unshiftedCodepoint, event.mods.intersection(.binding))
        if event.action == .release {
            guard let t = keyboard.lastTrigger, t.0 == hash.0, t.1 == hash.1, t.2 == hash.2 else { return nil }
            return .consumed
        }
        guard let action = config.bindings.get(event) else { return nil }
        keyboard.lastTrigger = nil
        _ = perform(action)
        _ = host?.perform(.keySequenceEnd)
        keyboard.lastTrigger = hash
        return .consumed
    }

    /// SurfaceMouse.keyToMouseShape: modifier keys show what a click would do.
    func keyShape(_ key: Key) -> MouseShape? {
        guard [.metaLeft, .metaRight, .shiftLeft, .shiftRight, .altLeft, .altRight].contains(key), !mouse.overLink, !mouse.hidden else { return nil }
        let (shift, rect) = (mouse.mods.contains(.shift), mouse.mods.contains(.alt))
        if terminal.flags.mouseEvent != .none {
            if shift { return rect ? MouseShape("crosshair") : MouseShape("text") }
        } else if rect { return MouseShape("crosshair") } else if shift { return MouseShape("text") }
        return terminal.mouseShape
    }

    // MARK: mouse

    /// The pointer moved (ghostty_surface_mouse_pos): points to pixels; under a pixel is no move.
    public func mousePos(x: Double, y: Double, mods: Mods) {
        let pos = (x: Float(x) * scale.x, y: Float(y) * scale.y)
        if abs(cursor.x - pos.x) < 1, abs(cursor.y - pos.y) < 1 { return }
        cursor = pos
        cursorMoved(pos, mods: mods)
    }

    /// Surface.cursorPosCallback.
    func cursorMoved(_ pos: (x: Float, y: Float), mods: Mods?) {
        if pos.x < 0 || pos.y < 0 {
            mouse.linkPoint = nil
            if mouse.overLink {
                mouse.overLink = false
                _ = host?.perform(.mouseShape(terminal.mouseShape))
                _ = host?.perform(.mouseOverLink([]))
            }
            hover.point = nil
            screen.dirty.hyperlinkHover = true
        }
        showMouse()
        if let mods { modsChanged(mods) }
        let vp = viewport(pos.x, pos.y), overLink = mouse.overLink
        mouse.overLink = false
        hover.point = nil
        if overLink || mouse.linkPoint.map({ $0 != vp }) ?? true, terminal.flags.mouseEvent == .none || mouse.mods.contains(.shift) && !shiftCapture() {
            refreshLinks(pos, vp, overLink: overLink)
        }
        // Shift overrides reporting only while a button is held (then it drags a selection).
        if isMouseReporting, !(mouse.mods.contains(.shift) && !shiftCapture() && mouse.click.contains { $0 != .release }) {
            report(MouseEvent.Button.allCases.first { mouse.pressed($0) }, .motion, pos)
            return
        }
        guard mouse.pressed(.left), mouse.gesture.count > 0, mouse.gesture.anchor(terminal) != nil,
              let pin = screen.pin(.viewport, x: vp.x, y: vp.y) else { return }
        let sel = mouse.gesture.drag(terminal, pin: pin, x: Double(pos.x), y: Double(pos.y), rectangle: mouse.mods.contains(.alt), geometry: geometry)
        if mouse.gesture.autoscroll == .none { if selectionScrollActive { handler.termio.append(.selectionScroll(false)) } }
        else if !selectionScrollActive { handler.termio.append(.selectionScroll(true)) }
        setSelection(sel)
    }

    var geometry: SelectionGesture.Geometry {
        SelectionGesture.Geometry(columns: UInt32(size.grid.cols), cellWidth: UInt32(size.cell.width), paddingLeft: UInt32(size.padding.left),
                                  screenHeight: UInt32(size.screen.height))
    }

    /// A button (ghostty_surface_mouse_button); true: the surface used it.
    public func mouseButton(_ state: MouseButtonState, _ button: MouseEvent.Button, mods: Mods) -> Bool {
        mouse.click[button.index] = state
        showMouse()
        modsChanged(mods)
        let capture = shiftCapture()
        if button == .left, state == .press, mods.contains(.shift), mouse.gesture.count > 0, !capture, screen.selection != nil,
           let last = mouse.gesture.time, now() - last > config.mouseInterval {
            cursorMoved(cursor, mods: nil)
            return true
        }
        if button == .left, state == .release {
            mouse.gesture.release(terminal, pin: cellAt(cursor).pin)
            if selectionScrollActive { handler.termio.append(.selectionScroll(false)) }
            if mouse.overLink, !mouse.gesture.dragged, openLink(at: cursor) { return true }
            if promptClick() { return true }
        }
        if isMouseReporting, !(mods.contains(.shift) && !capture) {
            setSelection(nil)
            mouse.gesture.reset(terminal)
            report(button, state == .press ? .press : .release, cursor)
            return true
        }
        if button == .left, state == .press, let pin = cellAt(cursor).pin {
            var sel = mouse.gesture.press(terminal, pin: pin, x: Double(cursor.x), y: Double(cursor.y), time: now(), maxDistance: Double(size.cell.width),
                                          interval: config.mouseInterval, behaviors: [.cell, .word, mods.contains(.super) ? .output : .line])
            if mouse.gesture.count == 2, let link = linkAt(pin, mods: nil) { sel = link.selection }
            if let sel { setSelection(sel) } else if mouse.gesture.count == 1, screen.selection != nil { setSelection(nil) }
        }
        // middle: primary-paste needs a selection clipboard (none on macOS).
        // right-click-action = context-menu: select the link or word under the pointer, unless inside the selection.
        if button == .right, state == .press, let pin = cellAt(cursor).pin, !(screen.selection.map { contains($0, pin) } ?? false),
           let sel = linkAt(cursor)?.selection ?? screen.selectWord(at: pin) {
            setSelection(sel)
        }
        return false
    }

    /// The viewport cell under a surface position and its pin.
    func cellAt(_ pos: (x: Float, y: Float)) -> (vp: (x: Int, y: Int), pin: Pin?) {
        let vp = viewport(pos.x, pos.y)
        return (vp, screen.pin(.viewport, x: vp.x, y: vp.y))
    }

    /// Selection.contains: the position is inside the selection (screen coordinates).
    func contains(_ sel: Selection, _ pin: Pin) -> Bool {
        let (a, b) = sel.corners(screen.pages)
        guard let tl = screen.point(.screen, a), let br = screen.point(.screen, b), let p = screen.point(.screen, pin) else { return false }
        if sel.rectangle { return p.y >= tl.y && p.y <= br.y && p.x >= tl.x && p.x <= br.x }
        if tl.y == br.y { return p.y == tl.y && p.x >= tl.x && p.x <= br.x }
        return p.y == tl.y ? p.x >= tl.x : p.y == br.y ? p.x <= br.x : p.y > tl.y && p.y < br.y
    }

    /// Surface.mouseReport: the encoder with the surface's size and button state.
    func report(_ button: MouseEvent.Button?, _ action: MouseEvent.Action, _ pos: (x: Float, y: Float)) {
        var o = MouseOptions(terminal, size: size)
        o.anyButtonPressed = mouse.click.contains { $0 != .release }
        write(MouseEvent(action: action, button: button, mods: mouse.mods, x: pos.x, y: pos.y).encode(o, lastCell: &mouse.eventPoint))
    }

    /// A scroll (ghostty_surface_mouse_scroll): lines, or pixels when precise; bit 0 of `mods` is precision.
    public func scroll(x: Double, y: Double, mods: UInt8) {
        showMouse()
        let precise = mods & 1 != 0
        func amount(_ off: Double, _ pending: inout Double, _ cell: Double) -> Int {
            let p = pending + off
            if abs(p) < cell { pending = p; return 0 }
            let n = p / cell
            pending = p - n * cell
            return Int(n.rounded(.towardZero))
        }
        var dy = 0, dx = 0
        if y != 0 {
            let cell = Double(size.cell.height)
            let adjusted = precise ? y * config.scrollMultiplier.precision : (y > 0 ? max(y, 1) : min(y, -1)) * cell * config.scrollMultiplier.discrete
            dy = amount(adjusted, &mouse.pendingScroll.y, cell)
        }
        if x != 0 { dx = precise ? amount(x, &mouse.pendingScroll.x, Double(size.cell.width)) : Int(x.rounded()) }
        if isMouseReporting { setSelection(nil) }
        if terminal.isAlternate, terminal.flags.mouseEvent == .none, terminal.modes.get(.mouseAlternateScroll) {
            if dy != 0 {
                setSelection(nil)
                let seq = terminal.modes.get(.cursorKeys) ? (dy > 0 ? "\u{1B}OA" : "\u{1B}OB") : (dy > 0 ? "\u{1B}[A" : "\u{1B}[B")
                for _ in 0..<abs(dy) { write(ascii(seq)) }
            }
            return
        }
        if isMouseReporting {
            for _ in 0..<abs(dy) { report(dy > 0 ? .four : .five, .press, cursor) }
            for _ in 0..<abs(dx) { report(dx > 0 ? .six : .seven, .press, cursor) }
            return
        }
        if dy != 0 { terminal.scrollViewport(.delta(-dy)) }
    }

    /// Force touch (ghostty_surface_mouse_pressure): a deep press while the left button is down selects.
    public func pressure(_ stage: PressureStage) {
        guard mouse.pressure != stage else { return }
        mouse.pressure = stage
        guard mouse.pressed(.left), stage == .deep else { return }
        let sel = mouse.gesture.deepPress(terminal)
        if selectionScrollActive { handler.termio.append(.selectionScroll(false)) }
        if let sel { setSelection(sel) }
    }

    /// The IO side's selection-scroll timer fired (it fires once more after it was stopped).
    public func selectionScrollTimer() {
        switch handler.selectionScrollTimer {
        case .off: return
        case .on: selectionScrollTick(active: true)
        case .stopping: handler.selectionScrollTimer = .off; selectionScrollTick(active: false)
        }
    }

    /// Surface.handleMessage(selection_scroll_tick) + selectionScrollTick.
    func selectionScrollTick(active: Bool) {
        selectionScrollActive = active
        guard active else { return }
        guard mouse.gesture.autoscroll != .none else { handler.termio.append(.selectionScroll(false)); return }
        let vp = viewport(cursor.x, cursor.y)
        let sel = mouse.gesture.autoscrollTick(terminal, viewport: vp, x: Double(cursor.x), y: Double(cursor.y), rectangle: mouse.mods.contains(.alt), geometry: geometry)
        if mouse.gesture.autoscroll == .none { handler.termio.append(.selectionScroll(false)) }
        if mouse.gesture.count > 0 { setSelection(sel) }
    }

    // MARK: prompts (OSC 133 click options)

    /// Surface.maybePromptClick: a click on the prompt's input line moves the cursor there (click
    /// events for the shell, or arrow keys).
    func promptClick() -> Bool {
        let s = screen
        guard config.cursorClickToMove, terminal.cursorIsAtPrompt, !mouse.gesture.dragged, s.selection == nil else { return false }
        let (vp, pin) = cellAt(cursor)
        guard let click = pin, let prompt = s.pages.promptAbove(s.pin) else { return false }
        if click.before(prompt) { return false }
        switch s.semanticPrompt.click {
        case .clickEvents(let v):
            // relative: from the prompt pin's row in its page (Ghostty uses the page-relative y).
            let y = v == .absolute ? vp.y + 1 : max(0, vp.y - prompt.y) + 1
            write(ascii("\u{1B}[<0;\(vp.x + 1);\(y)M"))
        case .cl:
            let (left, right) = s.promptClickMove(click)
            let keys = terminal.modes.get(.cursorKeys) ? ("\u{1B}OD", "\u{1B}OC") : ("\u{1B}[D", "\u{1B}[C")
            for _ in 0..<left { write(ascii(keys.0)) }
            for _ in 0..<right { write(ascii(keys.1)) }
        case .none: return false
        }
        return true
    }
}

extension Terminal {
    /// Terminal.cursorIsAtPrompt: the primary screen's cursor is on a prompt row or in prompt/input.
    var cursorIsAtPrompt: Bool {
        guard !isAlternate else { return false }
        return active.pin.row.semanticPrompt != .none || active.cursor.semanticContent != .output
    }
}

extension Screen {
    /// Screen.promptClickMove for `cl=` prompts: arrow presses from the cursor to the clicked input cell,
    /// counting input cells along wrapped rows (right: down through continuation rows; left: up).
    func promptClickMove(_ click: Pin) -> (left: Int, right: Int) {
        guard cursor.semanticContent == .input || pin.cellValue.semantic == .input, case .cl = semanticPrompt.click else { return (0, 0) }
        let start = pin
        if start == click { return (0, 0) }
        var count = 0
        if start.before(click) {
            var row: Pin? = Pin(page: start.page, y: start.y)
            rows: while let r = row {
                let isCursorRow = r.page === start.page && r.y == start.y
                if !isCursorRow, r.row.semanticPrompt != .promptContinuation { break }
                let cells = (0..<r.page.cols).map { r.page.cell(r.page.cellAt(r.y, $0)) }
                let from = isCursorRow ? start.x + 1 : cells.firstIndex { $0.semantic == .input } ?? cells.count
                for x in from..<cells.count where cells[x].semantic == .input {
                    count += 1
                    if r.page === click.page, r.y == click.y, x == click.x { break rows }
                }
                if !r.row.wrap {
                    if pin.cellValue.semantic == .input { count += 1 }
                    break
                }
                if r.page === click.page, r.y == click.y { break }
                row = r.down(1)
            }
            return (0, count)
        }
        var row: Pin? = Pin(page: start.page, y: start.y)
        rows: while let r = row {
            let end = r.page === start.page && r.y == start.y ? start.x : r.page.cols
            for x in (0..<end).reversed() where r.page.cell(r.page.cellAt(r.y, x)).semantic == .input {
                count += 1
                if r.page === click.page, r.y == click.y, x == click.x { break rows }
            }
            if !r.row.wrapContinuation || r.page === click.page && r.y == click.y { break }
            row = r.up(1)
        }
        return (count, 0)
    }
}

extension Key {
    /// Key.modifier: one of the eight modifier keys.
    var isModifier: Bool { [.shiftLeft, .controlLeft, .altLeft, .metaLeft, .shiftRight, .controlRight, .altRight, .metaRight].contains(self) }
}
