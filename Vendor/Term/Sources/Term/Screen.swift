// One screen (primary or alternate): its pages, cursor, saved cursor and
// charset state (Ghostty's Screen.zig).

public enum CursorShape { case bar, block, underline, blockHollow }
public enum ProtectedMode { case off, iso, dec }
public enum ClickEvents { case absolute, relative }
public enum Click { case line, multiple, conservativeVertical, smartVertical }

public struct CharsetState: Equatable {
    public struct Slots: Equatable { public var g0 = Charset.utf8, g1 = Charset.utf8, g2 = Charset.utf8, g3 = Charset.utf8 }
    public var charsets = Slots()
    public var gl = CharsetSlot.G0, gr = CharsetSlot.G2
    public var singleShift: CharsetSlot?

    public subscript(_ s: CharsetSlot) -> Charset {
        get { switch s { case .G0: charsets.g0; case .G1: charsets.g1; case .G2: charsets.g2; case .G3: charsets.g3 } }
        set { switch s { case .G0: charsets.g0 = newValue; case .G1: charsets.g1 = newValue; case .G2: charsets.g2 = newValue; case .G3: charsets.g3 = newValue } }
    }
}
extension Charset: Equatable {}

/// Kitty keyboard flags: a stack of 8 with a wrapping index.
public struct KittyKeyStack {
    public var flags = [KittyKeyFlags](repeating: KittyKeyFlags(0), count: 8), idx = 0
    public var current: KittyKeyFlags { flags[idx] }
}

public struct PromptState {
    public enum ClickKind { case none, clickEvents(ClickEvents), cl(Click) }
    public var seen = false, click = ClickKind.none
}

public struct Cursor {
    public var x = 0, y = 0
    public var cursorStyle = CursorShape.block
    public var pendingWrap = false, protected = false
    public var style = Style(), styleID = 0
    public var hyperlinkID = 0, hyperlinkImplicitID: UInt32 = 0
    public var hyperlink: Link?
    public var semanticContent = Cell.Semantic.output, semanticContentClearEOL = false
    var pin: TrackedPin
}

public struct SavedCursor {
    public var x: Int, y: Int, style: Style, protected: Bool, pendingWrap: Bool, origin: Bool, charset: CharsetState
}

/// A screen as a handle to its state, like Page: the terminal creates and frees its screens, so
/// using the active screen costs no retain/release. Fields are read and changed in place (no copies).
public struct Screen {
    struct State {
        let pages: PageList, noScrollback: Bool
        var cursor: Cursor, saved: SavedCursor? = nil, charset = CharsetState(), protectedMode = ProtectedMode.off
        var kittyKeyboard = KittyKeyStack(), semanticPrompt = PromptState()
        var selected: (start: TrackedPin, end: TrackedPin, rectangle: Bool)? = nil
        var dirty = Dirty()
        let images = ImageStorage()
    }
    /// Screen-wide changes the renderer must redraw everything for (Ghostty's Screen.Dirty).
    struct Dirty: Equatable { var selection = false, hyperlinkHover = false }
    let state: UnsafeMutablePointer<State>

    var pages: PageList { _read { yield state.pointee.pages } }
    var noScrollback: Bool { state.pointee.noScrollback }
    var cursor: Cursor { _read { yield state.pointee.cursor } nonmutating _modify { yield &state.pointee.cursor } }
    var saved: SavedCursor? { _read { yield state.pointee.saved } nonmutating _modify { yield &state.pointee.saved } }
    var charset: CharsetState { _read { yield state.pointee.charset } nonmutating _modify { yield &state.pointee.charset } }
    var protectedMode: ProtectedMode { _read { yield state.pointee.protectedMode } nonmutating _modify { yield &state.pointee.protectedMode } }
    var kittyKeyboard: KittyKeyStack { _read { yield state.pointee.kittyKeyboard } nonmutating _modify { yield &state.pointee.kittyKeyboard } }
    var semanticPrompt: PromptState { _read { yield state.pointee.semanticPrompt } nonmutating _modify { yield &state.pointee.semanticPrompt } }
    var selected: (start: TrackedPin, end: TrackedPin, rectangle: Bool)? { _read { yield state.pointee.selected } nonmutating _modify { yield &state.pointee.selected } }
    var dirty: Dirty { _read { yield state.pointee.dirty } nonmutating _modify { yield &state.pointee.dirty } }
    /// Kitty graphics: this screen's images and placements.
    public var images: ImageStorage { state.pointee.images }

    /// What the state dump reads, copied out (class storage stays internal, see Terminal).
    @_spi(Test) public struct View {
        public let cursor: Cursor, saved: SavedCursor?, charset: CharsetState, protectedMode: ProtectedMode
        public let kittyKeyboard: KittyKeyStack, semanticPrompt: PromptState
        /// The selection's screen points (nil: a position no longer on the screen).
        public let selection: (start: (x: Int, y: Int)?, end: (x: Int, y: Int)?, rectangle: Bool)?
    }
    @_spi(Test) public var view: View {
        View(cursor: cursor, saved: saved, charset: charset, protectedMode: protectedMode, kittyKeyboard: kittyKeyboard, semanticPrompt: semanticPrompt,
             selection: selection.map { (pages.point(.screen, $0.start), pages.point(.screen, $0.end), $0.rectangle) })
    }

    init(cols: Int, rows: Int, maxBytes: Int?, maxLines: Int?, blocks: PageBlocks? = nil) {
        let pages = PageList(cols: cols, rows: rows, maxBytes: maxBytes, maxLines: maxLines, blocks: blocks)
        state = .allocate(capacity: 1)
        state.initialize(to: State(pages: pages, noScrollback: maxBytes == 0, cursor: Cursor(pin: pages.track(Pin(page: pages.first)))))
    }

    func free() { pages.free(); state.deinitialize(count: 1); state.deallocate() }

    public var scrollbar: Scrollbar { pages.scrollbar }
    /// Bytes counted against the scrollback limit, and the pages from the top of history down.
    @_spi(Test) public var pageBytes: Int { pages.pageSize }
    @_spi(Test) public var pageChain: [Page] { Array(sequence(first: pages.first, next: { $0.next })) }

    var pin: Pin { get { cursor.pin.pin } nonmutating set { cursor.pin.pin = newValue } }
    var page: Page { cursor.pin.pin.page }
    /// Offset of the cell at column x of the cursor row.
    func cellAt(_ x: Int) -> Int { page.cellAt(pin.y, x) }
    var cursorCell: Int { cellAt(cursor.x) }
    func cursorMarkDirty() { pin.markDirty() }

    func reset() {
        images.reset(self)
        pages.reset()
        pin.garbage = false
        cursor = Cursor(pin: cursor.pin)
        (saved, charset, kittyKeyboard, protectedMode, semanticPrompt) = (nil, CharsetState(), KittyKeyStack(), .off, PromptState())
        clearSelection()
    }

    /// PageList.increaseCapacity, keeping the cursor's style and hyperlink valid on the new page.
    @discardableResult func increaseCapacity(_ p: Page, _ g: Grow) throws(OutOfSpace) -> Page {
        guard p === page else { return try pages.increaseCapacity(p, g) }
        let n = try pages.increaseCapacity(p, g)
        if cursor.styleID != 0 {
            do { cursor.styleID = try n.addStyle(cursor.style) } catch { (cursor.style, cursor.styleID) = (Style(), 0) }
        }
        if let link = cursor.hyperlink {
            (cursor.hyperlinkID, cursor.hyperlink) = (0, nil)
            try? startHyperlinkOnce(link)
        }
        cursorReload()
        return n
    }

    /// Clones a row of another page into `p`, growing `p` (cursor-aware) until it fits.
    func cloneRowGrowing(_ p: Page, _ dy: Int, _ src: Page, _ sy: Int, _ x0: Int = 0, _ x1: Int? = nil) -> Page {
        pages.cloneRowGrowing(p, dy, src, sy, x0, x1) { p, g throws(OutOfSpace) in try self.increaseCapacity(p, g) }
    }

    // Cursor movement.

    func cursorRight(_ n: Int) { cursor.x += n; pin.x += n }
    func cursorLeft(_ n: Int) { cursor.x -= n; pin.x -= n }
    func cursorUp(_ n: Int) { cursor.y -= n; changePin(pin.up(n)!) }
    func cursorDown(_ n: Int) { cursor.y += n; changePin(pin.down(n)!) }
    func cursorHorizontalAbsolute(_ x: Int) { pin.x = x; cursor.x = x }

    func cursorAbsolute(_ x: Int, _ y: Int) {
        var p = y < cursor.y ? pin.up(cursor.y - y)! : y > cursor.y ? pin.down(y - cursor.y)! : pin
        p.x = x
        (cursor.x, cursor.y) = (x, y)
        changePin(p)
    }

    /// Recomputes x/y from the tracked pin (after pages changed), or resets to the top left.
    func cursorReload() {
        if let pt = pages.point(.active, pin) { (cursor.x, cursor.y) = pt; return }
        (cursor.x, cursor.y) = (0, 0)
        changePin(pages.pin(.active)!)
        (cursor.x, cursor.y) = pages.point(.active, pin)!
    }

    /// Moves the cursor pin; on another page the cursor's style and link are re-added there. A
    /// move marks the old and new rows dirty (the cursor splits text runs: ligatures).
    func changePin(_ new: Pin) {
        if pin != new { cursorMarkDirty(); new.markDirty() }
        if new.page === page { pin = new; return }
        let oldStyle = cursor.styleID != 0 ? cursor.style : nil
        if oldStyle != nil { page.styles.release(page.memory, cursor.styleID); (cursor.style, cursor.styleID) = (Style(), 0) }
        if cursor.hyperlink != nil { page.hyperlinkSet.release(page.memory, cursor.hyperlinkID); cursor.hyperlinkID = 0 }
        pin = new
        if let s = oldStyle {
            cursor.style = s
            do { try manualStyleUpdate() } catch { (cursor.style, cursor.styleID) = (Style(), 0) }
        }
        if let link = cursor.hyperlink {
            cursor.hyperlink = nil
            if case .explicit(let id) = link.id { try? startHyperlink(link.uri, id) } else { try? startHyperlink(link.uri, nil) }
        }
    }

    func cursorResetWrap() {
        cursor.pendingWrap = false
        guard pin.row.wrap else { return }
        page.updateRow(pin.y) { $0.wrap = false }
        if let next = pin.down(1) { next.page.updateRow(next.y) { $0.wrapContinuation = false } }
        if page.cell(cellAt(page.cols - 1)).wide == .spacerHead { clearCells(page, pin.y, page.cols - 1..<page.cols) }
    }

    /// Cursor on the last row: scroll everything up one row (into history, or erased).
    func cursorDownScroll() {
        if noScrollback {
            if pages.rows == 1 {
                clearCells(page, pin.y, 0..<page.cols)
                page.updateRow(pin.y) { $0.reset() }
                cursorMarkDirty()
            } else {
                let old = pin
                pages.eraseRow(pages.pin(.active)!)
                pin = old
            }
        } else {
            let old = pin
            pages.grow()
            var new: Pin
            if old.page === page { new = pin.down(1)! } else { new = pin; new.x = cursor.x }
            if new.page === page { cursorMarkDirty(); pin = new } else { changePin(new) }
            cursorMarkDirty()
            if cursor.style.bgColor != .none { clearCells(page, pin.y, 0..<page.cols) }
        }
        fillBlank()
    }

    /// With a style that has a background, a scrolled-in row takes that background.
    private func fillBlank() {
        guard cursor.styleID != 0, let blank = cursor.style.bgCell else { return }
        page.fillCells(pin.y, 0..<pages.cols, blank)
    }

    /// Inserts a blank row above the cursor's row... below it: rows from the cursor down move
    /// down one, the bottom row goes into history (Ghostty's cursorScrollAbove).
    func cursorScrollAbove() {
        cursorMarkDirty()
        if cursor.y == pages.rows - 1 { return cursorDownScroll() }
        let old = pin
        if let fresh = pages.grow() { scrollAboveRotate(fresh) } else if page === pages.last {
            _ = old
            pin = pin.down(1)!
            pages.invalidate(page)
            page.rotateDown(pin.y..<page.rows)
            page.dirty = true
        } else { scrollAboveRotate(nil) }
        fillBlank()
    }

    private func scrollAboveRotate(_ fresh: Page?) {
        changePin(pin.down(1)!)
        var (cur, isFresh) = (pages.last, fresh != nil)
        while cur !== page {
            let prev = cur.prev!
            if !isFresh { pages.invalidate(cur) }
            cur.rotateDown(0..<cur.rows)
            cur = cloneRowGrowing(cur, 0, prev, prev.rows - 1, 0, pages.cols)
            cur.dirty = true
            cur = cur.prev!
            isFresh = false
        }
        pages.invalidate(cur)
        cur.rotateDown(pin.y..<cur.rows)
        clearCells(cur, pin.y, 0..<cur.cols)
        cur.updateRow(pin.y) { $0.reset() }
        cur.dirty = true
    }

    /// Scrolls rows [cursor.y - limit, cursor.y] up one; the top one is dropped.
    func cursorScrollRegionUp(_ limit: Int) {
        guard pin.y >= limit else { return scrollRegionUpSlow(limit) }
        let (p, top) = (page, pin.y - limit)
        let blankIsZero = cursor.styleID == 0 || cursor.style.bgColor == .none
        if !p.row(top).managedMemory && blankIsZero {
            p.fillCells(top, 0..<p.cols, Cell())
        } else { clearCells(p, top, 0..<p.cols) }
        p.updateRow(top) { $0.reset() }
        pages.invalidate(p)
        p.rotateUp(top..<pin.y + 1)
        p.dirty = true
        if pages.viewport == .pin, let v = pages.viewportPinRowOffset {
            let vp = pages.viewportPin.pin
            if vp.page === p, vp.y >= top, vp.y <= pin.y, vp.y != 0 { pages.viewportPinRowOffset = v - 1 }
        }
        for t in pages.pins(on: p) where t !== cursor.pin && t.pin.y >= top && t.pin.y <= pin.y {
            if t.pin.y == 0 { t.pin.x = 0 } else { t.pin.y -= 1 }
        }
    }

    private func scrollRegionUpSlow(_ limit: Int) {
        let old = pin
        pages.eraseRow(pages.pin(.active, y: cursor.y - limit)!, limit: limit)
        pin = old
        let blank = blankCell
        if blank.bits != 0 { page.fillCells(pin.y, 0..<pages.cols, blank) }
    }

    /// Takes another cursor's attributes and position (alt screen switches keep the cursor).
    func cursorCopy(_ other: Cursor, hyperlink: Bool = true) throws(OutOfSpace) {
        endHyperlink()
        let old = cursor
        var c = other
        (c.styleID, c.hyperlinkID, c.hyperlink, c.pin, c.x, c.y) = (old.styleID, 0, nil, old.pin, old.x, old.y)
        cursor = c
        do { try manualStyleUpdate() } catch { cursor = old; throw error }
        cursorAbsolute(other.x, other.y)
        if hyperlink, other.hyperlinkID != 0 {
            let l = other.pin.pin.page.link(id: other.hyperlinkID)
            if case .explicit(let id) = l.id { try? startHyperlink(l.uri, id) } else { try? startHyperlink(l.uri, nil) }
        }
    }

    // Viewport and erasing.

    func scroll(_ s: PageList.Scroll) { pages.scroll(s) }
    func scrollClear() { pages.scrollClear(); cursorReload() }
    func eraseHistory() { pages.eraseHistory(); cursorReload() }

    /// Clears whole rows from `top` to `bottom` (keeping protected cells when asked).
    func clearRows(_ top: Pin, _ bottom: Pin?, protected: Bool) {
        for (p, rows) in top.chunks(down: true, to: bottom ?? pages.bottomRight(.screen)) {
            for y in rows {
                if protected { clearUnprotectedCells(p, y) } else {
                    clearCells(p, y, 0..<p.cols)
                    p.updateRow(y) { $0.reset() }
                }
                p.updateRow(y) { $0.dirty = true }
            }
        }
    }

    /// Clears cells, filling them with the cursor's background (Ghostty's Screen.clearCells).
    func clearCells(_ p: Page, _ y: Int, _ r: Range<Int>) {
        guard !r.isEmpty else { return }
        p.clearCells(y, r.lowerBound, r.upperBound, blank: blankCell)
    }

    func clearUnprotectedCells(_ p: Page, _ y: Int, _ r: Range<Int>? = nil) {
        let r = r ?? 0..<p.cols
        var x0 = r.lowerBound
        while x0 < r.upperBound {
            while x0 < r.upperBound, p.cell(p.cellAt(y, x0)).protected { x0 += 1 }
            guard x0 < r.upperBound else { return }
            var x1 = x0 + 1
            while x1 < r.upperBound, !p.cell(p.cellAt(y, x1)).protected { x1 += 1 }
            clearCells(p, y, x0..<x1)
            x0 = x1
        }
    }

    /// Before writing at column x: clears the halves of wide characters that x would split.
    func splitCellBoundary(_ x: Int) {
        let cols = page.cols
        if x == cols {
            if pin.row.wrap, page.cell(cellAt(cols - 1)).wide == .spacerHead { clearCells(page, pin.y, cols - 1..<cols) }
            return
        }
        if x <= 1, pin.row.wrapContinuation, page.cell(cellAt(0)).wide == .wide, let above = pin.up(1),
           above.page.cell(above.page.cellAt(above.y, above.page.cols - 1)).wide == .spacerHead {
            clearCells(above.page, above.y, above.page.cols - 1..<above.page.cols)
            above.markDirty()
        }
        if x == 0 { return }
        if page.cell(cellAt(x - 1)).wide == .wide { clearCells(page, pin.y, x - 1..<x + 1) }
    }

    var blankCell: Cell { cursor.styleID == 0 ? Cell() : cursor.style.bgCell ?? Cell() }

    // Resize.

    func resize(cols: Int, rows: Int, reflow: Bool, promptRedraw: Redraw) {
        let savedPin = saved.flatMap { pages.pin(.active, x: $0.x, y: $0.y) }.map { pages.track($0) }
        defer { if let p = savedPin { pages.untrack(p) } }
        let (node, serial) = (page, page.serial)
        let (style, styleID, link, linkID) = (cursor.style, cursor.styleID, cursor.hyperlink, cursor.hyperlinkID)
        if styleID != 0 { node.styles.use(node.memory, styleID) }
        if linkID != 0 { node.hyperlinkSet.use(node.memory, linkID) }
        cursor.style = Style()
        try? manualStyleUpdate()
        if cursor.hyperlinkID != 0 {
            page.hyperlinkSet.release(page.memory, cursor.hyperlinkID)
            (cursor.hyperlinkID, cursor.hyperlink) = (0, nil)
        }
        pages.resize(cols: cols, rows: rows, reflow: reflow, cursor: .init(x: cursor.x, y: cursor.y, pin: cursor.pin))
        if noScrollback { pages.eraseHistory() }
        cursorReload()
        clearPromptForRedraw(promptRedraw)
        cursor.style = style
        do { try manualStyleUpdate() } catch { (cursor.style, cursor.styleID) = (Style(), 0) }
        if let p = savedPin {
            if let pt = pages.point(.active, p.pin) {
                (saved!.x, saved!.y) = pt
                if saved!.pendingWrap, saved!.x != cols - 1 { saved!.pendingWrap = false; saved!.x += 1 }
            } else { (saved!.x, saved!.y, saved!.pendingWrap) = (0, 0, false) }
        }
        if let link {
            if case .explicit(let id) = link.id { try? startHyperlink(link.uri, id) } else { try? startHyperlink(link.uri, nil) }
        }
        if page === node, page.serial == serial {
            if styleID != 0 { node.styles.release(node.memory, styleID) }
            if linkID != 0 { node.hyperlinkSet.release(node.memory, linkID) }
        }
    }

    public enum Redraw { case `true`, `false`, last }

    private func clearPromptForRedraw(_ redraw: Redraw) {
        guard redraw != .false, cursor.semanticContent != .output else { return }
        if redraw == .last { return clearCells(page, pin.y, 0..<page.cols) }
        guard let start = pages.promptAbove(pin) else { return }
        for r in start.rows(down: true) { clearCells(r.page, r.y, 0..<r.page.cols) }
    }

    // Styles, graphemes, hyperlinks.

    func setAttribute(_ a: Attribute) throws(OutOfSpace) {
        let old = cursor.style
        var s = old
        switch a {
        case .unset: s = Style()
        case .bold: s.flags.bold = true
        case .resetBold: (s.flags.bold, s.flags.faint) = (false, false)
        case .italic: s.flags.italic = true
        case .resetItalic: s.flags.italic = false
        case .faint: s.flags.faint = true
        case .underline(let u): s.flags.underline = u
        case .underlineColor(let c): s.underlineColor = .rgb(c)
        case .underlineColor256(let i): s.underlineColor = .palette(i)
        case .resetUnderlineColor: s.underlineColor = .none
        case .overline: s.flags.overline = true
        case .resetOverline: s.flags.overline = false
        case .blink: s.flags.blink = true
        case .resetBlink: s.flags.blink = false
        case .inverse: s.flags.inverse = true
        case .resetInverse: s.flags.inverse = false
        case .invisible: s.flags.invisible = true
        case .resetInvisible: s.flags.invisible = false
        case .strikethrough: s.flags.strikethrough = true
        case .resetStrikethrough: s.flags.strikethrough = false
        case .directColorFg(let c): s.fgColor = .rgb(c)
        case .directColorBg(let c): s.bgColor = .rgb(c)
        case .fg8(let n), .brightFg8(let n): s.fgColor = .palette(n.value)
        case .bg8(let n), .brightBg8(let n): s.bgColor = .palette(n.value)
        case .resetFg: s.fgColor = .none
        case .resetBg: s.bgColor = .none
        case .fg256(let i): s.fgColor = .palette(i)
        case .bg256(let i): s.bgColor = .palette(i)
        case .unknown: return
        }
        cursor.style = s
        if s == old { return }
        do { try manualStyleUpdate() } catch {
            cursor.style = old
            do { try manualStyleUpdate() } catch { cursor.style = Style(); try? manualStyleUpdate() }
            throw error
        }
    }

    /// Re-adds the cursor style to its page after it changed (Ghostty's manualStyleUpdate).
    func manualStyleUpdate() throws(OutOfSpace) {
        var p = page
        if cursor.styleID != 0 { p.styles.release(p.memory, cursor.styleID) }
        cursor.styleID = 0
        if cursor.style == Style() { return }
        let id: Int
        do { id = try p.addStyle(cursor.style) } catch {
            do { p = try increaseCapacity(p, error) } catch { try splitForCapacity(pin); p = page }
            do { id = try p.addStyle(cursor.style) } catch { if error == .rehash { return }; throw OutOfSpace() }
        }
        cursor.styleID = id
    }

    private func splitForCapacity(_ at: Pin) throws(OutOfSpace) {
        let above = Page.layout(at.page.exactCapacity(0, at.y + 1)).totalSize
        let below = Page.layout(at.page.exactCapacity(at.y, at.page.rows)).totalSize
        let old = pin
        try pages.split(above < below ? at.down(1) ?? at : at)
        if page === old.page { return }
        let new = pin
        pin = old
        changePin(new)
    }

    /// Adds a codepoint to the grapheme of a cell in the cursor row's page.
    func appendGrapheme(_ cell: Int, _ cp: UInt32) throws(OutOfSpace) {
        do { try page.appendGrapheme(pin.y, cell, cp) } catch {
            let x = (cell - cellAt(0)) / 8
            try increaseCapacity(page, .graphemeBytes)
            do { try page.appendGrapheme(pin.y, cellAt(x), cp) } catch { throw OutOfSpace() }
        }
    }

    func startHyperlink(_ uri: [UInt8], _ id: [UInt8]?) throws(OutOfSpace) {
        let link = Link(id: id.map { .explicit($0) } ?? .implicit(cursor.hyperlinkImplicitID), uri: uri)
        if id == nil { cursor.hyperlinkImplicitID &+= 1 }
        while true {
            do { return try startHyperlinkOnce(link) } catch {
                do { try increaseCapacity(page, error) } catch {
                    if id == nil { cursor.hyperlinkImplicitID &-= 1 }
                    throw error
                }
            }
        }
    }

    private func startHyperlinkOnce(_ link: Link) throws(Grow) {
        endHyperlink()
        cursor.hyperlinkID = try page.insertHyperlink(link)
        cursor.hyperlink = link
    }

    func endHyperlink() {
        guard cursor.hyperlinkID != 0 else { return }
        page.hyperlinkSet.release(page.memory, cursor.hyperlinkID)
        (cursor.hyperlinkID, cursor.hyperlink) = (0, nil)
    }

    /// Marks the cursor cell with the current hyperlink.
    func cursorSetHyperlink() throws(OutOfSpace) {
        do {
            try page.setHyperlink(pin.y, cursorCell, cursor.hyperlinkID)
            page.hyperlinkSet.use(page.memory, cursor.hyperlinkID)
        } catch {
            // Ghostty checks the uri fits by allocating it and never frees that allocation.
            while let link = cursor.hyperlink {
                if page.stringAlloc.alloc(page.memory, bytes: link.uri.count) != nil { break }
                try increaseCapacity(page, .stringBytes)
            }
            try increaseCapacity(page, .hyperlinkBytes)
            if cursor.hyperlinkID > 0 { try cursorSetHyperlink() }
        }
    }

    enum SemanticContent { case prompt(PromptKind), output, input(clearEOL: Bool) }
    public enum PromptKind { case initial, right, continuation, secondary }

    func setSemanticContent(_ t: SemanticContent) {
        switch t {
        case .output: (cursor.semanticContent, cursor.semanticContentClearEOL) = (.output, false)
        case .input(let eol): (cursor.semanticContent, cursor.semanticContentClearEOL) = (.input, eol)
        case .prompt(let kind):
            semanticPrompt.seen = true
            (cursor.semanticContent, cursor.semanticContentClearEOL) = (.prompt, false)
            page.updateRow(pin.y) { $0.semanticPrompt = kind == .initial || kind == .right ? .prompt : .promptContinuation }
        }
    }
}

extension Style {
    /// A background-only style as a bg-color cell (Ghostty's bgCell).
    var bgCell: Cell? {
        var c = Cell()
        switch bgColor {
        case .none: return nil
        case .palette(let i): (c.tag, c.content) = (.bgColorPalette, UInt32(i))
        case .rgb(let v): (c.tag, c.content) = (.bgColorRGB, UInt32(v.r) | UInt32(v.g) << 8 | UInt32(v.b) << 16)
        }
        return c
    }
}

extension PageList {
    /// The start of the prompt at or above `p` (Ghostty's promptIterator left_up, first result).
    func promptAbove(_ start: Pin) -> Pin? {
        var cur: Pin? = start
        while let p = cur {
            switch p.row.semanticPrompt {
            case .none: break
            case .prompt: return Pin(page: p.page, y: p.y)
            case .promptContinuation:
                var end = p
                while let prior = end.up(1) {
                    switch prior.row.semanticPrompt {
                    case .none: return Pin(page: end.page, y: end.y)
                    case .promptContinuation: end = prior
                    case .prompt: return Pin(page: prior.page, y: prior.y)
                    }
                }
                return Pin(page: p.page, y: p.y)
            }
            cur = p.up(1)
        }
        return nil
    }
}
