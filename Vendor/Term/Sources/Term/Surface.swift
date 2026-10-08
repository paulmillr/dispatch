// The surface Dispatch drives (Ghostty's Surface.zig behind the C API, with apprt/embedded.zig's
// thin wrappers): keys, text, mouse and clipboard from the host become pty bytes (queued like
// Ghostty's IO mailbox, run at drain), terminal changes and host actions.

/// What the surface tells the host (Ghostty's apprt actions the surface performs).
public enum SurfaceAction {
    public enum OpenKind: String { case unknown, text, html, osc8 }
    public enum ColorKind { case palette(UInt8), foreground, background, cursor }
    case selectionChanged, mouseShape(MouseShape), mouseVisibility(visible: Bool), mouseOverLink([UInt8])
    case keySequenceEnd, openURL(OpenKind, [UInt8]), startSearch([UInt8]), endSearch
    case setTitle([UInt8]), colorChange(ColorKind, RGB), pwd([UInt8]), ringBell, desktopNotification(title: [UInt8], body: [UInt8])
    case progressReport(Progress), commandFinished(exitCode: UInt8, duration: UInt64), scrollbar(Scrollbar)
    case searchTotal(Int?), searchSelected(Int?)
}

public struct ClipboardContent {
    public var mime: [UInt8], data: [UInt8]
    public init(mime: [UInt8], data: [UInt8]) { (self.mime, self.data) = (mime, data) }
}

/// A clipboard request the surface gives the host (apprt.ClipboardRequest): a paste, a mode 5522
/// paste event that lists the MIME types only, a program's read, or a kitty write the host completes
/// at once (it reads nothing; completing it may need the user's confirmation).
public enum ClipboardRequest {
    case paste(SurfaceMessage.Clipboard), list(SurfaceMessage.Clipboard), osc52Read(SurfaceMessage.Clipboard)
    case kittyRead(SurfaceMessage.KittyClipboardRead), kittyWrite(SurfaceMessage.KittyClipboardWrite)
    public var name: String {
        switch self {
        case .paste: "paste"
        case .list: "list"
        case .osc52Read: "osc_52_read"
        case .kittyRead: "kitty_read"
        case .kittyWrite: "kitty_write"
        }
    }
}

public enum ClipboardReadResult { case started, unavailable, unsupported }

/// The host's answer to a clipboard request (Surface.CompleteClipboard).
public struct ClipboardCompletion {
    public var contents: [ClipboardContent], available: [[UInt8]], confirmed: Bool, remember: Bool
    public init(contents: [ClipboardContent] = [], available: [[UInt8]] = [], confirmed: Bool = false, remember: Bool = false) {
        (self.contents, self.available, self.confirmed, self.remember) = (contents, available, confirmed, remember)
    }
}

/// A completion that needs the user's confirmation (the host asks, then completes confirmed or denies).
public enum ClipboardError: Error { case unsafePaste, unauthorized }

/// The embedder (Dispatch): performs actions, owns the clipboards, opens URLs.
public protocol SurfaceHost: AnyObject {
    /// An apprt action; true: handled.
    func perform(_ action: SurfaceAction) -> Bool
    func setClipboard(_ location: SurfaceMessage.Clipboard, _ contents: [ClipboardContent], confirm: Bool)
    /// May complete the request (Surface.completeClipboard) before returning.
    func clipboardRequest(_ location: SurfaceMessage.Clipboard, _ request: ClipboardRequest, mimes: [[UInt8]], list: Bool) -> ClipboardReadResult
    /// The system opener, when `perform(.openURL)` declined.
    func open(_ kind: SurfaceAction.OpenKind, _ url: [UInt8]) throws
    /// Whether a file exists (relative link paths resolve against the working directory).
    func exists(_ path: [UInt8]) -> Bool
}

/// The surface options Dispatch's config sets or leaves at Ghostty's defaults.
public struct SurfaceConfig {
    public var optionAsAlt = OptionAsAlt.false
    public var bindings = Bindings(["super+c=copy_to_clipboard", "super+v=paste_from_clipboard", "super+a=select_all",
                                    "shift+page_up=scroll_page_up", "shift+page_down=scroll_page_down"])
    public var clipboardRead = HandlerOptions.ClipboardAccess.ask
    public var pasteProtection = true, pasteBracketedSafe = true, trimTrailingSpaces = true
    public var selectionClearOnTyping = true, selectionClearOnCopy = false, scrollToBottomOnKey = true
    public var mouseHideWhileTyping = false, mouseReporting = true, cursorClickToMove = true, linkOSC8 = true, linkPreviews = true
    /// Double-click interval in ns (macOS: the system's; the oracle's headless default 500 ms).
    public var mouseInterval: UInt64 = 500_000_000
    public var scrollMultiplier = (precision: 1.0, discrete: 3.0)
    /// Regex links (Ghostty's `link`): the URL regex, highlighted and opened with super held
    /// (mods nil: always).
    public var links: [(regex: Regex, mods: Mods?)] = [(Regex(urlRegex)!, .super)]
    public init() {}
}

public final class Surface {
    public let terminal: Terminal
    public var stream: Stream<StreamHandler>
    public weak var host: SurfaceHost?
    public var config: SurfaceConfig
    public internal(set) var size: RenderSize
    public internal(set) var focused = true, visible = true
    /// The input method's pending text (Ghostty's renderer state preedit): code points, wide or not.
    public internal(set) var preedit: [(cp: UInt32, wide: Bool)]?
    /// The renderer's mouse state: the hovered cell (a link is under it), the mods.
    public internal(set) var hover: (point: (x: Int, y: Int)?, mods: Mods) = (nil, [])
    /// Host state (apprt/embedded.zig): cursor position in pixels, content scale, size.
    var cursor: (x: Float, y: Float) = (0, 0), scale: (x: Float, y: Float) = (1, 1), hostSize: (width: Int, height: Int) = (0, 0)
    var mouse = MouseState(), keyboard = KeyboardState()
    var selectionScrollActive = false
    /// Program-side state: the title (for title reports), the last bell and notification (rate
    /// limits), when the running command started.
    var title: [UInt8] = [], lastBell: UInt64?, lastNotification: (time: UInt64, digest: UInt64)?, commandStart: UInt64?
    let now: () -> UInt64, entropy: (Int) -> [UInt8]
    /// takeMessages' second buffer: the queue and this one swap, both keep their capacity.
    var taken: [SurfaceMessage] = []
    /// The scrollbar last reported to the host.
    var reported = Scrollbar(total: 0, offset: 0, len: 0)
    /// The find bar's search (Ghostty's Surface.search: its thread's state), while one is open.
    var searching: SearchThread?
    /// What the renderer highlights (Ghostty's renderer search state): the viewport's matches, the
    /// selected match, and whether they changed since the renderer applied them.
    public internal(set) var searchHighlights = SearchHighlights()

    struct MouseState {
        var click: [MouseButtonState] = Array(repeating: .release, count: MouseEvent.Button.allCases.count)
        var mods = Mods(), gesture = SelectionGesture(), eventPoint: (x: Int, y: Int)?, pressure = PressureStage.none
        var pendingScroll = (x: 0.0, y: 0.0), overLink = false, hidden = false, linkPoint: (x: Int, y: Int)?
        func pressed(_ b: MouseEvent.Button) -> Bool { click[b.index] == .press }
    }
    struct KeyboardState { var pressed: KeyEvent?, lastTrigger: (Key, UInt32, Mods)? }

    public enum MouseButtonState: String { case release, press }
    public enum PressureStage: String { case none, normal, deep }

    /// `now`: the awake clock in ns; `entropy`: secure random bytes (paste-event passwords).
    public init(terminal: Terminal, options: HandlerOptions, size: RenderSize, config: SurfaceConfig = SurfaceConfig(),
                now: @escaping () -> UInt64, entropy: @escaping (Int) -> [UInt8]) {
        (self.terminal, self.size, self.config, self.now, self.entropy) = (terminal, size, config, now, entropy)
        stream = Stream(handler: StreamHandler(terminal: terminal, options: options))
        hostSize = size.screen
    }

    var handler: StreamHandler {
        get { stream.handler }
        _modify { yield &stream.handler }
    }
    /// tmux control mode (DCS 1000p ... ST) hands its stream here as it is fed (read it with `Tmux`),
    /// with the control session it belongs to (counts DCS 1000p starts); nil: ignored.
    /// Runs inside `feed`, which holds the surface: it must not read or feed this surface.
    public var control: ((Control, Int) -> Void)? {
        get { handler.control }
        set { handler.control = newValue }
    }
    /// The host refused control session `session` (its producer no longer reads it): unless a newer
    /// one started, the stream leaves control mode without an end and `bytes` are read as output,
    /// so a DCS 1000p among them starts again.
    public func plain(_ bytes: UnsafeBufferPointer<UInt8>, session: Int) {
        guard handler.controls == session else { return }
        if case .control = handler.dcs { handler.dcs = .inactive; stream.state = .ground; stream.clear() }
        feed(bytes)
    }
    var screen: Screen { terminal.active }

    /// A resize the test scripts make directly (`r`): the host's size and the grid follow at once.
    @_spi(Test) public func resize(cols: Int, rows: Int) {
        size.screen = (cols * size.cell.width, rows * size.cell.height)
        hostSize = size.screen
        handler.termio.append(.resize(size))
    }

    /// Program output.
    public func feed(_ bytes: UnsafeBufferPointer<UInt8>) { stream.nextSlice(bytes) }

    /// The IO side: runs queued work; replies are the pty writes in order.
    public func drain(reply: ([UInt8]) -> Void, event: (TermioMessage) -> Void) { handler.drain(reply: reply, event: event) }

    func write(_ bytes: [UInt8]) { if !bytes.isEmpty { handler.termio.append(.write(bytes)) } }

    // MARK: host events (embedded.zig wrappers + Surface.zig callbacks)

    public func setSize(width: Int, height: Int) {
        guard hostSize != (width, height) else { return }
        hostSize = (width, height)
        guard size.screen != (width, height) else { return }
        size.screen = (width, height)
        handler.termio.append(.resize(size))
    }

    /// The renderer's cell or the padding changed (font size, content scale: Surface.zig
    /// setCellSize and scaledPadding); the grid follows.
    public func setCell(_ cell: (width: Int, height: Int), padding: (top: Int, bottom: Int, right: Int, left: Int)) {
        guard size.cell != cell || size.padding != padding else { return }
        (size.cell, size.padding) = (cell, padding)
        handler.termio.append(.resize(size))
    }

    /// The host's content scale (NaN or below 1: 1). The font side of Ghostty's callback lives with the fonts.
    public func setContentScale(x: Double, y: Double) {
        let clamp = { (v: Double) in Float(max(1, v.isNaN ? 1 : v)) }
        scale = (clamp(x), clamp(y))
    }

    public func occlusion(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        terminal.flags.visible = visible
        if terminal.modes.get(.reportVisibility) { handler.termio.append(.visibilityReport(visible: visible, force: false)) }
    }

    public func focus(_ on: Bool) {
        guard focused != on else { return }
        focused = on
        // A lost focus releases the pressed key, then both sides of each held modifier.
        if !on, var k = keyboard.pressed {
            keyboard.pressed = nil
            k.action = .release
            if k.key != .unidentified { _ = key(k) }
            let original = k.key
            for (m, left, right) in [(Mods.shift, Key.shiftLeft, Key.shiftRight), (.ctrl, .controlLeft, .controlRight),
                                     (.alt, .altLeft, .altRight), (.super, .metaLeft, .metaRight)] where k.mods.contains(m) {
                k.mods.remove(m)
                for side in [right, left] where side != original { k.key = side; _ = key(k) }
            }
        }
        showMouse()
        terminal.flags.focused = on
        handler.termio.append(.focused(on))
    }

    /// Mods for the host's key translation (ghostty_surface_key_translation_mods).
    public func translationMods(_ mods: Mods) -> Mods { mods.translation(config.optionAsAlt) }

    /// Text from the host (ghostty_surface_text): a paste.
    public func text(_ data: [UInt8]) { try? paste(data, allowUnsafe: true) }

    /// Surface.needsConfirmQuit with Ghostty's default confirm-close-surface (true): a program is
    /// running unless the cursor is at a shell prompt (the host answers false once the child exited).
    public var needsConfirmQuit: Bool { !terminal.cursorIsAtPrompt }

    /// Dispatch's dispatch_surface_cursor_faint_tail: the cursor (active area) and whether the text
    /// after it on its row is all faint (a shell's inline suggestion), with at least one such cell.
    public func cursorFaintTail() -> (x: Int, y: Int, faint: Bool) {
        let s = screen, page = s.page, y = s.pin.y
        var found = false
        for x in (s.cursor.x + 1)..<page.cols {
            let c = page.cell(page.cellAt(y, x))
            if c.codepoint == 0 || c.codepoint == 0x20 { continue }
            guard c.styleID != 0, page.style(c.styleID).flags.faint else { return (s.cursor.x, s.cursor.y, false) }
            found = true
        }
        return (s.cursor.x, s.cursor.y, found)
    }

    /// Whether there is a selection (ghostty_surface_has_selection).
    public var hasSelection: Bool { screen.selection != nil }

    /// Where the input method's window goes (Surface.imePoint): the cursor cell's bottom center in
    /// points from the top left, the cell's height, the preedit's width (in pixels, as Ghostty) up
    /// to the screen's right edge.
    public func imePoint() -> (x: Double, y: Double, width: Double, height: Double) {
        let c = terminal.cursor, cell = size.cell, p = size.padding
        let preedit = (self.preedit ?? []).reduce(0) { $0 + ($1.wide ? 2 : 1) }
        let screen = max(0, size.screen.width - p.left - p.right)
        return ((Double(c.x * cell.width + p.left) + Double(cell.width) / 2) / Double(scale.x), Double(c.y * cell.height + p.top + cell.height) / Double(scale.y),
                min(Double(preedit * cell.width), Double(screen) - Double((c.x + 1) * cell.width)), Double(cell.height) / Double(scale.y))
    }

    /// ghostty_surface_read_text over a whole region (its top left to bottom right corner).
    public func readText(_ tag: PointTag) -> [UInt8] {
        let pages = screen.pages
        guard let br = pages.bottomRight(tag) else { return [] }
        return screen.readText(Selection(pages.topLeft(tag), br)).text
    }

    /// Marks the text written so far (Terminal.markRows), for `readUnmarkedText`.
    public func markRows() { terminal.markRows() }

    /// `readText(.active)` with every marked row blank (Row.marked): each row keeps its line, so
    /// the cursor's row still indexes the text. Dispatch gives an SSH session's helper only this,
    /// never what the tab showed before the session.
    public func readUnmarkedText() -> [UInt8] {
        let pages = screen.pages
        let rows = (0..<pages.rows).compactMap { pages.pin(.active, y: $0) }
        guard rows.contains(where: { $0.row.marked }) else { return readText(.active) }
        var out: [UInt8] = [], i = 0
        while i < rows.count {
            var end = i
            if !rows[i].row.marked {
                while end + 1 < rows.count, !rows[end + 1].row.marked { end += 1 }
                var last = rows[end]
                last.x = last.page.cols - 1
                let text = screen.selectionString(Selection(rows[i], last), trim: false)
                out += text
                // The formatter ends rows in newlines only before more text (soft wraps join rows):
                // pad its trailing blank rows so the next row starts on its own line.
                let breaks = (i..<end).filter { !rows[$0].row.wrap }.count
                out += [UInt8](repeating: 0x0A, count: max(0, breaks - text.filter { $0 == 0x0A }.count))
            }
            if end + 1 < rows.count { out.append(0x0A) }
            i = end + 1
        }
        while out.last == 0x0A { out.removeLast() }
        return out
    }

    /// The primary screen's scrollback and active area as plain text, even while the alternate
    /// screen shows (Dispatch saves it for a relaunched shell).
    public func readPrimaryText() -> [UInt8] {
        let screen = terminal.primary, pages = screen.pages
        guard let br = pages.bottomRight(.screen) else { return [] }
        return screen.readText(Selection(pages.topLeft(.screen), br)).text
    }

    /// The selection's text (ghostty_surface_read_selection); nil: no selection.
    public func readSelection() -> [UInt8]? { screen.selection.map { screen.readText($0).text } }

    public func setPreedit(_ text: [UInt8]) {
        if preedit != nil || !text.isEmpty, config.selectionClearOnTyping { setSelection(nil) }
        terminal.dirty.preedit = true
        // Invalid UTF-8 leaves no preedit (Ghostty's Utf8View fails after clearing it).
        let cps = scalars(text)?.compactMap { cp -> (cp: UInt32, wide: Bool)? in
            let w = Unicode.props(cp).width
            return w > 0 ? (cp, w >= 2) : nil
        } ?? []
        preedit = cps.isEmpty ? nil : cps
    }

    /// Where the preedit shows (renderer.State.Preedit.range): from `start`, pushed left so it ends by
    /// column `max`; `offset` skips the code points that don't fit.
    public static func preeditRange(_ p: [(cp: UInt32, wide: Bool)], start: Int, max: Int) -> (start: Int, end: Int, offset: Int) {
        var (w, offset) = (0, 0)
        for (i, c) in p.enumerated().reversed() {
            w += c.wide ? 2 : 1
            if w > max - start + 1 { offset = i; break }
        }
        let end = w > 0 ? start + w - 1 : start
        let shift = end > max ? end - max : 0
        return (Swift.max(0, start - shift), Swift.max(0, end - shift), offset)
    }

    // MARK: binding actions

    /// A binding action by name (ghostty_surface_binding_action); false: unknown or not performed.
    public func bindingAction(_ text: [UInt8]) -> Bool {
        guard let a = BindingAction(text) else { return false }
        return perform(a)
    }

    func perform(_ action: BindingAction) -> Bool {
        switch action {
        case .copyToClipboard(let format):
            guard let sel = screen.selection else { return false }
            copy(sel, .standard, format)
            if config.selectionClearOnCopy { setSelection(nil) }
        case .pasteFromClipboard: return startClipboardRequest(.standard, .paste(.standard)) == .started
        case .selectAll: if let sel = screen.selectAll() { setSelection(sel) }
        case .scrollToRow(let n): screen.scroll(.row(n))
        case .scrollPageUp: handler.termio.append(.scrollViewport(.delta(-size.grid.rows)))
        case .scrollPageDown: handler.termio.append(.scrollViewport(.delta(size.grid.rows)))
        case .search(let needle): return search(needle)
        case .navigateSearch(let next): return navigateSearch(next: next)
        case .endSearch: return endSearch()
        // The host opens its search UI (the search starts with the first needle).
        case .startSearch: return host?.perform(.startSearch([])) ?? false
        case .searchSelection:
            guard let sel = screen.selection else { return false }
            var pins: [Pin]?
            return host?.perform(.startSearch(screen.selectionString(sel, trim: false, emit: .plain, pins: &pins))) ?? false
        case .clearScreen: return clearScreen()
        }
        return true
    }

    /// Termio.clearScreen(history: true). The alternate screen is left alone (the binding stays
    /// unconsumed): an emulator-level clear would desynchronize the program drawing it.
    private func clearScreen() -> Bool {
        let t = terminal, s = t.active
        guard !t.isAlternate else { return false }
        setSelection(nil)
        t.eraseDisplay(.scrollback, protected: false)
        if t.cursorIsAtPrompt {
            // Clear everything, then a form feed lets the shell repaint its prompt at the top.
            // Unlike Ghostty, erase history again: ED 2 at a prompt keeps the screen's text there.
            t.eraseDisplay(.complete, protected: false)
            t.eraseDisplay(.scrollback, protected: false)
            handler.termio.append(.write([0x0C]))
        } else {
            // Screen.eraseActive(cursor.y - 1): drop the rows above the cursor, its row moves to the top.
            let y = s.cursor.y
            if y > 0 {
                for _ in 0..<y { s.pages.grow() }
                s.eraseHistory()
            }
            s.images.clearScreen(t)
            t.dirty.clear = true
        }
        return true
    }

    // MARK: clipboard

    func startClipboardRequest(_ location: SurfaceMessage.Clipboard, _ request: ClipboardRequest) -> ClipboardReadResult {
        var request = request
        if case .paste(let c) = request, terminal.modes.get(.kittyPasteEvents) { request = .list(c) }
        // What the host reads: text asks for text/plain (kitty reads: their types, text ones as text/plain).
        let plain = ascii("text/plain")
        let (mimes, list): ([[UInt8]], Bool) = switch request {
        case .paste, .osc52Read: ([plain], false)
        case .list: ([], true)
        case .kittyRead(let r): (r.mimes.map { isTextMime($0) ? plain : $0 }, r.list)
        case .kittyWrite: ([], false)
        }
        return host?.clipboardRequest(location, request, mimes: mimes, list: list) ?? .unsupported
    }

    /// The host completes a request it was given (throws: the user must confirm first).
    public func completeClipboard(_ request: ClipboardRequest, _ c: ClipboardCompletion) throws {
        let text = c.contents.first { isTextMime($0.mime) }?.data ?? []
        switch request {
        case .paste: try paste(text, allowUnsafe: c.confirmed)
        case .list(let location): pasteEvent(location, c.available)
        case .osc52Read(let location): try osc52Reply(text, location, confirmed: c.confirmed)
        // Under ask, data needs the user's yes or a grant (listing only: no prompt); `remember`
        // grants the password for the session.
        case .kittyRead(let r):
            guard config.clipboardRead != .ask || c.confirmed || r.granted || r.mimes.isEmpty else { throw ClipboardError.unauthorized }
            if c.remember && !r.pw.isEmpty { handler.grants.grant(r.pw, read: true, oneTime: false) }
            kittyRead(r, c.contents, c.available)
        // The write's own contents (none: an empty text clears the clipboard), then DONE.
        case .kittyWrite(let w):
            guard handler.options.clipboardWrite != .ask || c.confirmed || w.granted else { throw ClipboardError.unauthorized }
            if c.remember && !w.pw.isEmpty { handler.grants.grant(w.pw, read: false, oneTime: false) }
            host?.setClipboard(w.location, w.contents.isEmpty ? [ClipboardContent(mime: ascii("text/plain"), data: [])] : w.contents, confirm: false)
            handler.kittyStatus("write", "DONE", w.id, w.terminator)
        }
    }

    /// The user refused: a program reading the clipboard gets an empty answer (kitty: EPERM).
    public func denyClipboard(_ request: ClipboardRequest) {
        switch request {
        case .paste, .list: break
        case .osc52Read(let location): try? osc52Reply([], location, confirmed: true)
        case .kittyRead(let r): handler.kittyStatus("read", "EPERM", r.id, r.terminator)
        case .kittyWrite(let w): handler.kittyStatus("write", "EPERM", w.id, w.terminator)
        }
    }

    /// Surface.completeKittyClipboardRead: the asked types in order under their asked names (a text
    /// type matches any text content), unavailable ones left out.
    func kittyRead(_ r: SurfaceMessage.KittyClipboardRead, _ contents: [ClipboardContent], _ available: [[UInt8]]) {
        let served = r.mimes.compactMap { m in
            contents.first { $0.mime == m || isTextMime(m) && isTextMime($0.mime) }.map { ClipboardContent(mime: m, data: $0.data) }
        }
        write(KittyClipboard.readSuccess(primary: r.location == .primary, id: r.id, pw: nil, list: r.list, available: available, contents: served, terminator: r.terminator))
    }

    /// Surface.completeClipboardPaste: refuses unsafe data unless allowed, then the pieces the paste
    /// encoder makes, one pty write each.
    func paste(_ data: [UInt8], allowUnsafe: Bool) throws {
        guard !data.isEmpty else { return }
        let o = PasteOptions(terminal)
        let unsafe = config.pasteProtection && !allowUnsafe
            && (o.bracketed && data.firstRange(of: ascii("\u{1B}[201~")) != nil || !(o.bracketed && config.pasteBracketedSafe) && !Paste.isSafe(data))
        if unsafe { throw ClipboardError.unsafePaste }
        terminal.scrollViewport(.bottom)
        for piece in Paste.encode(data, o) { write(piece) }
    }

    /// A mode 5522 paste event (terminal/paste.zig pasteKittyEvent; the paste became one because the
    /// mode is on): a one-time password, granted once for reads, and the listing of what the
    /// clipboard has.
    func pasteEvent(_ location: SurfaceMessage.Clipboard, _ available: [[UInt8]]) {
        let pw = KittyGrants.password(entropy)
        handler.grants.grant(pw, read: true, oneTime: true)
        write(KittyClipboard.readSuccess(primary: location != .standard, pw: pw, available: Array(available.prefix(16))))
    }

    /// Surface.copySelectionToClipboards for one clipboard: plain text, HTML (with the terminal's
    /// colors on its div), or both (mixed: the HTML without them).
    func copy(_ sel: Selection, _ location: SurfaceMessage.Clipboard, _ format: BindingAction.CopyFormat) {
        let text = { (emit: Emit, mime: String) in
            var pins: [Pin]?
            return ClipboardContent(mime: ascii(mime), data: self.screen.selectionString(sel, trim: self.config.trimTrailingSpaces, emit: emit, pins: &pins))
        }
        let (palette, colors) = (terminal.colors.palette.current, terminal.colors)
        let contents = switch format {
        case .plain: [text(.plain, "text/plain")]
        case .html: [text(.html(palette: palette, background: colors.background.value, foreground: colors.foreground.value), "text/html")]
        case .mixed: [text(.plain, "text/plain"), text(.html(palette: palette, background: nil, foreground: nil), "text/html")]
        }
        host?.setClipboard(location, contents, confirm: false)
    }

    // MARK: selection and pointer helpers

    func setSelection(_ sel: Selection?) {
        let changed = screen.selection.map { prev in sel.map { !($0 == prev) } ?? true } ?? (sel != nil)
        screen.select(sel)
        if changed { _ = host?.perform(.selectionChanged) }
    }

    func showMouse() {
        guard mouse.hidden else { return }
        mouse.hidden = false
        _ = host?.perform(.mouseVisibility(visible: true))
    }

    func hideMouse() {
        guard !mouse.hidden else { return }
        mouse.hidden = true
        _ = host?.perform(.mouseVisibility(visible: false))
    }

    /// Surface.modsChanged: other mods than the stored binding ones (sided or lock bits count)
    /// redraw everything: link highlights follow the mods.
    func modsChanged(_ mods: Mods) {
        guard mouse.mods != mods else { return }
        mouse.mods = mods.intersection(.binding)
        hover.mods = modsWithCapture(mouse.mods)
        terminal.dirty.clear = true
    }

    /// Shift goes to the program only when it asked (mouse-shift-capture false: XTSHIFTESCAPE decides).
    func shiftCapture() -> Bool { terminal.flags.mouseShiftCapture == .true }

    func modsWithCapture(_ mods: Mods) -> Mods {
        terminal.flags.mouseEvent == .none || !mods.contains(.shift) || shiftCapture() ? mods : mods.subtracting(.shift)
    }

    var isMouseReporting: Bool { config.mouseReporting && terminal.flags.mouseEvent != .none }

    /// Surface pixels to a viewport cell (renderer Coordinate.convert: clamped to the grid).
    func viewport(_ x: Float, _ y: Float) -> (x: Int, y: Int) {
        let g = size.grid
        let cx = Int(max(0, (Double(x) - Double(size.padding.left)) / Double(size.cell.width)))
        let cy = Int(max(0, (Double(y) - Double(size.padding.top)) / Double(size.cell.height)))
        return (min(cx, g.cols - 1), min(cy, g.rows - 1))
    }
}

extension MouseEvent.Button: CaseIterable {
    public static var allCases: [MouseEvent.Button] { [.unknown, .left, .right, .middle, .four, .five, .six, .seven, .eight, .nine, .ten, .eleven] }
    var index: Int { Self.allCases.firstIndex(of: self)! }
}

/// The code points of valid UTF-8 (nil: invalid, like Zig's Utf8View.init).
func scalars(_ bytes: [UInt8]) -> [UInt32]? {
    var (it, decoder, out) = (bytes.makeIterator(), UTF8(), [UInt32]())
    while true {
        switch decoder.decode(&it) {
        case .scalarValue(let s): out.append(s.value)
        case .emptyInput: return out
        case .error: return nil
        }
    }
}

/// Ghostty's clipboard.isTextMime.
func isTextMime(_ mime: [UInt8]) -> Bool { ["text/plain", "text/plain;charset=utf-8", "UTF8_STRING", "TEXT", "STRING"].contains { ascii($0) == mime } }
