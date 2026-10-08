// Terminal state and VT operations (Ghostty's Terminal.zig): two screens,
// modes, margins, tabs, colors, title/pwd; print and the cursor/erase/scroll
// operations work on the active screen.

public struct DynamicRGB { public var override: RGB?, `default`: RGB?; public var value: RGB? { override ?? `default` } }

public struct Palette {
    public var current: [RGB], original: [RGB], mask = [Bool](repeating: false, count: 256)
    init(_ def: [RGB]) { (current, original) = (def, def) }
    mutating func set(_ i: Int, _ c: RGB) { current[i] = c; mask[i] = true }
    mutating func reset(_ i: Int) { current[i] = original[i]; mask[i] = false }

    /// Ghostty's default palette: 16 named colors, the 6x6x6 cube, 24 grays.
    static let standard: [RGB] = ghosttyNamedColors + (0..<216).map { i in
        let v = { (n: Int) in UInt8(n == 0 ? 0 : n * 40 + 55) }
        return RGB(r: v(i / 36), g: v(i / 6 % 6), b: v(i % 6))
    } + (0..<24).map { let g = UInt8($0 * 10 + 8); return RGB(r: g, g: g, b: g) }
}

public struct Colors { public var foreground: DynamicRGB, background: DynamicRGB, cursor: DynamicRGB, palette: Palette }

public struct ScrollingRegion { public var top: Int, bottom: Int, left: Int, right: Int }

public struct TerminalFlags {
    public enum MouseEvent { case none, x10, normal, button, any }
    public enum MouseFormat { case x10, utf8, sgr, urxvt, sgrPixels }
    public enum Capture { case null, `false`, `true` }
    public var shellRedrawsPrompt = Screen.Redraw.true
    public var modifyOtherKeys2 = false
    public var mouseEvent = MouseEvent.none, mouseFormat = MouseFormat.x10
    public var mouseShiftCapture = Capture.null
    public var focused = true, visible = true, passwordInput = false, selectionScroll = false
}

public struct CursorDefaults { public var isDefault = true, defaultStyle = CursorShape.block, defaultBlink: Bool? = false }

/// Mode values as bits in Ghostty's mode table order.
public struct ModeState {
    public var values: UInt64, saved: UInt64 = ModeState.tableDefaults, `default`: UInt64
    static let tableDefaults = modeTable.enumerated().reduce(UInt64(0)) { $0 | ($1.element.isDefault ? 1 << UInt64($1.offset) : 0) }
    public func get(_ m: Mode) -> Bool { values >> UInt64(m.index) & 1 != 0 }
    mutating func set(_ m: Mode, _ v: Bool) { values = v ? values | 1 << UInt64(m.index) : values & ~(1 << UInt64(m.index)) }
    mutating func save(_ m: Mode) { saved = saved & ~(1 << UInt64(m.index)) | values & 1 << UInt64(m.index) }
    mutating func restore(_ m: Mode) -> Bool { values = values & ~(1 << UInt64(m.index)) | saved & 1 << UInt64(m.index); return get(m) }
}

extension Mode {
    public init(_ name: String) { self.init(index: modeTable.firstIndex { $0.name == name }!) }
    /// Every mode, in Ghostty's table order.
    public static let all = modeTable.indices.map(Mode.init(index:))
}

extension MouseShape {
    init(_ name: String) { self.init(index: mouseShapeNames.firstIndex(of: name)!) }
}

/// Defaults: what the app's termio (Termio.init) makes of Ghostty's default config
/// (scrollback-limit-bytes, grapheme-width-method = unicode, cursor-style(-blink), colors).
public struct TerminalOptions {
    public var cols: Int, rows: Int
    public var maxScrollbackBytes: Int? = 50_000_000, maxScrollbackLines: Int?
    public var defaultModes = ["grapheme_cluster": true, "cursor_blinking": true]
    public var cursorStyle = CursorShape.block, cursorBlink: Bool?
    public var foreground = RGB(r: 0xFF, g: 0xFF, b: 0xFF), background = RGB(r: 0x28, g: 0x2C, b: 0x34)
    public var widthPx = 0, heightPx = 0
    /// Where the screens' pages get and return their blocks (see PageBlocks).
    public var blocks: PageBlocks?
    /// Kitty graphics decoders and medium reads (none: PNG, zlib and non-direct media unsupported).
    public var kitty = KittySystem()
    /// Zero disables Kitty graphics entirely.
    public var kittyImageStorageLimit = ImageStorage.defaultTotalLimit
    public init(cols: Int, rows: Int) { (self.cols, self.rows) = (cols, rows) }
}

/// Class storage stays internal: Swift keeps a dynamic exclusivity check on every access to a
/// public stored property of a class, and drops it for internal ones it can prove safe.
public final class Terminal {
    let primary: Screen
    /// Where its screens' pages get and return their blocks (TerminalOptions.blocks).
    let blocks: PageBlocks?
    let kittySystem: KittySystem
    var kittyImageStorageLimit: Int
    /// Glyph protocol registrations (per terminal, like Ghostty's glyph_glossary).
    @_spi(Test) public internal(set) var glossary = Glossary()
    var alternate: Screen?, active: Screen
    /// Counts removals of the alternate screen (a search or gesture knows its screen was replaced).
    var alternateGeneration = 0
    public var isAlternate: Bool { active.state != primary.state }
    /// The active screen's scrollbar (a renderer compares it after each frame).
    public var scrollbar: Scrollbar { active.scrollbar }
    var activeKey: Int { isAlternate ? 1 : 0 }
    /// A screen by key (0 primary, 1 alternate) with its generation (Ghostty's ScreenSet).
    func screen(_ key: Int) -> (screen: Screen, generation: Int)? { key == 0 ? (primary, 0) : alternate.map { ($0, alternateGeneration) } }
    var statusDisplay = StatusDisplay.main
    var tabstops: [Bool]
    var rows: Int, cols: Int
    /// The grid size (stored internally: see above).
    public var grid: (cols: Int, rows: Int) { (cols, rows) }
    var widthPx: Int, heightPx: Int
    var scrollingRegion: ScrollingRegion
    var pwd: [UInt8] = [], title: [UInt8] = []
    var colors: Colors
    var previousChar: UInt32?
    var modes: ModeState
    var cursorDefaults: CursorDefaults
    var mouseShape = MouseShape("text")
    var flags = TerminalFlags()
    /// Terminal-wide changes the renderer must redraw everything for (Ghostty's Terminal.Dirty).
    struct Dirty: Equatable { var palette = false, reverseColors = false, clear = false, preedit = false, glyphGlossary = false }
    var dirty = Dirty()
    /// The renderer saw changes: the search re-reads the active area at its next feed (Ghostty's
    /// flags.search_viewport_dirty).
    var searchViewportDirty = false

    /// What the state dump reads, copied out.
    @_spi(Test) public struct View {
        public let cols: Int, rows: Int, widthPx: Int, heightPx: Int, isAlternate: Bool, statusDisplay: StatusDisplay, previousChar: UInt32?
        public let mouseShape: MouseShape, flags: TerminalFlags, cursorDefaults: CursorDefaults, modes: ModeState, scrollingRegion: ScrollingRegion
        public let tabstops: [Bool], colors: Colors, title: [UInt8], pwd: [UInt8], primary: Screen, alternate: Screen?
    }
    @_spi(Test) public var view: View {
        View(cols: cols, rows: rows, widthPx: widthPx, heightPx: heightPx, isAlternate: isAlternate, statusDisplay: statusDisplay, previousChar: previousChar,
             mouseShape: mouseShape, flags: flags, cursorDefaults: cursorDefaults, modes: modes, scrollingRegion: scrollingRegion,
             tabstops: tabstops, colors: colors, title: title, pwd: pwd, primary: primary, alternate: alternate)
    }

    public init(_ o: TerminalOptions) {
        let imageLimit = min(max(0, o.kittyImageStorageLimit), ImageStorage.defaultTotalLimit)
        (rows, cols, widthPx, heightPx) = (o.rows, o.cols, o.widthPx, o.heightPx)
        (blocks, kittySystem, kittyImageStorageLimit) = (o.blocks, o.kitty, imageLimit)
        primary = Screen(cols: o.cols, rows: o.rows, maxBytes: o.maxScrollbackBytes, maxLines: o.maxScrollbackLines, blocks: o.blocks)
        primary.images.totalLimit = imageLimit
        active = primary
        tabstops = Terminal.tabs(o.cols)
        scrollingRegion = ScrollingRegion(top: 0, bottom: o.rows - 1, left: 0, right: o.cols - 1)
        colors = Colors(foreground: DynamicRGB(default: o.foreground), background: DynamicRGB(default: o.background), cursor: DynamicRGB(), palette: Palette(Palette.standard))
        var m = ModeState.tableDefaults
        for (name, v) in o.defaultModes { let i = UInt64(Mode(name).index); m = v ? m | 1 << i : m & ~(1 << i) }
        modes = ModeState(values: m, default: m)
        cursorDefaults = CursorDefaults(defaultStyle: o.cursorStyle, defaultBlink: o.cursorBlink)
        setCursorStyle(.default)
    }

    /// The config's default colors (Termio.changeConfig): palette entries a program set stay; the
    /// cursor's default is the config's cursor color when it is a plain color.
    public func changeDefaults(foreground: RGB, background: RGB, cursor: RGB?, palette: [RGB]) {
        colors.palette.original = palette
        for i in palette.indices where !colors.palette.mask[i] { colors.palette.current[i] = palette[i] }
        dirty.palette = true
        (colors.foreground.default, colors.background.default, colors.cursor.default) = (foreground, background, cursor)
    }

    deinit { primary.free(); alternate?.free() }

    var kittyGraphicsEnabled: Bool { kittyImageStorageLimit > 0 }

    /// Applies a runtime opt-in change and discards protocol state that crossed the old boundary.
    public func setKittyGraphicsLimit(_ limit: Int) {
        let limit = min(max(0, limit), ImageStorage.defaultTotalLimit)
        guard limit != kittyImageStorageLimit else { return }
        primary.images.reset(primary)
        primary.images.totalLimit = limit
        if let alternate { alternate.images.reset(alternate); alternate.images.totalLimit = limit }
        kittyImageStorageLimit = limit
        dirty.clear = true
    }

    static func tabs(_ cols: Int) -> [Bool] { (0..<cols).map { $0 > 0 && $0 % 8 == 0 && $0 < cols - 1 } }

    var cursor: Cursor { _read { yield active.cursor } _modify { yield &active.cursor } }
    var region: ScrollingRegion { scrollingRegion }
    var fullWidth: Bool { region.left == 0 && region.right == cols - 1 }

    public func setCursorStyle(_ v: CursorStyle) {
        cursorDefaults.isDefault = v == .default
        switch v {
        case .default: modes.set(.cursorBlinking, cursorDefaults.defaultBlink ?? true)
        case .steadyBlock, .steadyBar, .steadyUnderline: modes.set(.cursorBlinking, false)
        default: modes.set(.cursorBlinking, true)
        }
        switch v {
        case .default: active.cursor.cursorStyle = cursorDefaults.defaultStyle
        case .blinkingBlock, .steadyBlock: active.cursor.cursorStyle = .block
        case .blinkingBar, .steadyBar: active.cursor.cursorStyle = .bar
        case .blinkingUnderline, .steadyUnderline: active.cursor.cursorStyle = .underline
        }
    }

    // Printing.

    public func print(_ c: UInt32) {
        guard statusDisplay == .main else { return }
        let s = active
        let rightLimit = s.cursor.x > region.right ? cols : region.right + 1
        if c > 255, modes.get(.graphemeCluster), s.cursor.x > 0, graphemeAttach(c, rightLimit) { return }
        let width = c <= 0xFF ? 1 : Unicode.props(c).width
        if width == 0 {
            if modes.get(.graphemeCluster) { return }
            let left = modes.get(.wraparound) && s.cursor.pendingWrap ? 0 : 1
            if s.cursor.x == 0, left == 1 { return }
            var prev = s.cellAt(s.cursor.x - left)
            if s.page.cell(prev).wide == .spacerTail { prev = s.cellAt(s.cursor.x - left - 1) }
            guard s.page.cell(prev).hasText else { return }
            if c == 0xFE0F || c == 0xFE0E, Unicode.props(s.page.cell(prev).codepoint).graphemeBreak != extendedPictographic { return }
            try? s.appendGrapheme(prev, c)
            return
        }
        previousChar = c
        if s.cursor.pendingWrap, modes.get(.wraparound) { printWrap() }
        if modes.get(.insert), s.cursor.x + width < cols { insertBlanks(width) }
        if width == 1 { s.cursorMarkDirty(); printCell(c, .narrow) } else if rightLimit - region.left > 1 {
            if s.cursor.x == rightLimit - 1 {
                guard modes.get(.wraparound) else { return }
                if rightLimit == cols {
                    s.page.updateRow(s.pin.y) { $0.wrap = true }
                    printCell(0, .spacerHead)
                } else { printCell(0, .narrow) }
                printWrap()
            }
            s.cursorMarkDirty()
            printCell(c, .wide)
            s.cursorRight(1)
            printCell(0, .spacerTail)
        } else { s.cursorMarkDirty(); printCell(0, .narrow) }
        if s.cursor.x == rightLimit - 1 { s.cursor.pendingWrap = true } else { s.cursorRight(1) }
    }

    /// Kitty graphics' Unicode placeholder: printing it needs row bookkeeping, so it never takes the run path.
    private let kittyPlaceholder: UInt32 = 0x10EEEE
    /// The grapheme break table, read once: each read of the lazily built global is a runtime call.
    private let breaks = graphemeBreaks

    /// Ghostty's printSlice: when nothing per-codepoint can happen (no insert mode, no charset
    /// mapping, no cursor hyperlink, wraparound on), runs of narrow or wide codepoints are stored
    /// straight into the row; everything else goes through print(c).
    /// Text may be stored in runs (Ghostty's printSlice conditions): the main display, no insert
    /// mode, wraparound, a UTF-8 or ASCII charset without a single shift, no hyperlink.
    private var runs: Bool {
        let s = active, gl = s.charset[s.charset.gl]
        return statusDisplay == .main && !modes.get(.insert) && modes.get(.wraparound) && s.charset.singleShift == nil
            && (gl == .utf8 || gl == .ascii) && s.cursor.hyperlinkID == 0
    }

    public func printSlice(_ cps: UnsafeBufferPointer<UInt32>) {
        guard runs else { for c in cps { print(c) }; return }
        let cluster = modes.get(.graphemeCluster), unicode = !cluster || region.left == 0
        var i = 0
        while i < cps.count {
            let n = printRun(UnsafeBufferPointer(rebasing: cps[i...]), cluster, unicode)
            if n > 0 { i += n } else { print(cps[i]); i += 1 }
        }
    }

    /// Ghostty's printSliceFast: how many leading codepoints were stored (0 = use print).
    private func printRun(_ cps: UnsafeBufferPointer<UInt32>, _ cluster: Bool, _ unicode: Bool) -> Int {
        let s = active, c = cps[0]
        if c <= 0xFF { return c < 0x10 ? 0 : fill(cps, run: extent(cps, 1, cluster, unicode), 1) }
        guard unicode, c != kittyPlaceholder else { return 0 }
        if cluster, s.cursor.pendingWrap { return 0 }
        if cluster, s.cursor.x > 0 {
            var prev = s.page.cell(s.cellAt(s.cursor.x - 1))
            if prev.wide == .spacerTail { prev = s.page.cell(s.cellAt(s.cursor.x - 2)) }
            var state: UInt8 = 0
            if prev.codepoint != 0, prev.hasGrapheme || !Unicode.graphemeBreak(prev.codepoint, c, &state, breaks) { return 0 }
        }
        let width = Unicode.props(c).width
        return width == 1 || width == 2 ? fill(cps, run: extent(cps, width, cluster, unicode), width) : 0
    }

    /// Printable ASCII bytes (the stream's spans): each one narrow cell, stored like a run of code
    /// points (no grapheme joins with a Latin-1 cell, as in printRun).
    public func printBytes(_ b: UnsafeBufferPointer<UInt8>) {
        guard runs else { for c in b { print(UInt32(c)) }; return }
        var i = 0
        while i < b.count {
            let n = fill(UnsafeBufferPointer(rebasing: b[i...]), run: b.count - i, 1)
            if n > 0 { i += n } else { print(UInt32(b[i])); i += 1 }
        }
    }

    /// How many leading code points share the first one's width (and print through `fill`).
    private func extent(_ cps: UnsafeBufferPointer<UInt32>, _ width: Int, _ cluster: Bool, _ unicode: Bool) -> Int {
        var run = 1
        // Narrow Latin-1 (most text) 8 code points at a time: c in 0x10...0xFF has no bits above
        // 0xFF in c | (c + 0xF0) ^ 0x100 (lane arithmetic: mask compares compile to slow code).
        if width == 1 {
            let (add, flip, high) = (SIMD4<UInt32>(repeating: 0xF0), SIMD4<UInt32>(repeating: 0x100), SIMD4<UInt32>(repeating: ~0xFF))
            while run + 8 <= cps.count {
                let (a, b) = (UnsafeRawPointer(cps.baseAddress! + run).loadUnaligned(as: SIMD4<UInt32>.self),
                              UnsafeRawPointer(cps.baseAddress! + run + 4).loadUnaligned(as: SIMD4<UInt32>.self))
                let bad = (a | (a &+ add) ^ flip | b | (b &+ add) ^ flip) & high
                let (x, y) = unsafeBitCast(bad, to: (UInt64, UInt64).self)
                if x | y != 0 { break }
                run += 8
            }
        }
        while run < cps.count {
            let c = cps[run]
            if width == 1, c >= 0x10, c <= 0xFF { run += 1; continue }
            var state: UInt8 = 0
            guard c > 0xFF, unicode, c != kittyPlaceholder, Unicode.props(c).width == width,
                  !cluster || Unicode.graphemeBreak(cps[run - 1], c, &state, breaks) else { break }
            run += 1
        }
        return run
    }

    /// Ghostty's printSliceFill: stores `run` code points of this width row by row, while the
    /// target cells are plain narrow cells (a different style only changes ref counts).
    private func fill<C: FixedWidthInteger & UnsignedInteger>(_ cps: UnsafeBufferPointer<C>, run: Int, _ width: Int) -> Int {
        let s = active, shift = width - 1   // width is 1 or 2: shifts, not divisions (an idiv per run)
        // Cell fields a plain target must have: codepoint tag, narrow, no hyperlink, (style).
        let mask: UInt64 = 3 | 0xFFFF << 26 | 3 << 42 | 1 << 45
        var printed = 0
        while printed < run {
            if s.cursor.pendingWrap { printWrap() }
            let rightLimit = s.cursor.x > region.right ? cols : region.right + 1
            if width == 2, rightLimit - region.left <= 1 { break }
            let avail = rightLimit - s.cursor.x, page = s.page, y = s.pin.y, cells = page.words + s.cursorCell / 8
            let style = s.cursor.styleID
            var template = Cell()
            (template.styleID, template.protected, template.semantic) = (style, s.cursor.protected, s.cursor.semanticContent)
            let plain = UInt64(style) << 26
            if width == 2, avail == 1 {
                guard cells[0] & mask == plain else { break }
                page.updateRow(y) { ($0.dirty, $0.wrap, $0.styled) = (true, $0.wrap || rightLimit == cols, $0.styled || style != 0) }
                if rightLimit == cols { template.wide = .spacerHead }
                cells[0] = template.bits
                printWrap()
                continue
            }
            var wide = template, tail = template
            (wide.wide, tail.wide) = (.wide, .spacerTail)
            let count = min(avail >> shift, run - printed) << shift, src = cps.baseAddress! + printed
            let (narrowBits, wideBits, tailBits) = (template.bits, wide.bits, tail.bits)
            /// Stores the codepoints for cells [a, b).
            func store(_ a: Int, _ b: Int) {
                if width == 1 { for j in a..<b { cells[j] = narrowBits | UInt64(src[j]) << 2 } } else {
                    for j in stride(from: a, to: b, by: 2) { (cells[j], cells[j + 1]) = (wideBits | UInt64(src[j >> 1]) << 2, tailBits) }
                }
            }
            // Usually every target is plain in this style (fresh rows, redraws): one branch-free check.
            var diff: UInt64 = 0
            for j in 0..<count { diff |= cells[j] & mask ^ plain }
            var k = diff == 0 ? count : 0
            if k > 0 { store(0, count) }
            while k < count {
                // Plain cells of the same style (whole pairs for wide), then plain cells of another
                // style (ref counts move in bulk, narrow only), then one cell at a time.
                var n = 0
                while k + n < count, cells[k + n] & mask == plain { n += 1 }
                n &= ~shift
                if n > 0 { store(k, k + n); k += n; continue }
                let first = cells[k] & mask, old = Int(first >> 26 & 0xFFFF)
                if width == 1, first == UInt64(old) << 26 {
                    n = 1
                    while k + n < count, cells[k + n] & mask == first { n += 1 }
                    if old != 0 { page.styles.release(page.memory, old, n) }
                    if style != 0 { page.styles.use(page.memory, style, n) }
                    store(k, k + n)
                    k += n
                    continue
                }
                guard (k..<k + width).allSatisfy({ let t = Cell(cells[$0]); return t.wide == .narrow && !t.hasGrapheme && !t.hyperlink }) else { break }
                for j in k..<k + width where Cell(cells[j]).styleID != style {
                    if Cell(cells[j]).styleID != 0 { page.styles.release(page.memory, Cell(cells[j]).styleID) }
                    if style != 0 { page.styles.use(page.memory, style) }
                }
                store(k, k + width)
                k += width
            }
            if k > 0 {
                page.updateRow(y) { ($0.dirty, $0.styled) = (true, $0.styled || style != 0) }
                previousChar = UInt32(cps[printed + k >> shift - 1])
                printed += k >> shift
                if s.cursor.x + k >= rightLimit { s.cursorRight(k - 1); s.cursor.pendingWrap = true } else { s.cursorRight(k) }
            }
            if k < count { break }
        }
        return printed
    }

    /// c joins the grapheme of the previous cell (grapheme clustering on): true when handled.
    private func graphemeAttach(_ c: UInt32, _ rightLimit: Int) -> Bool {
        let s = active
        var left: Int
        if modes.get(.wraparound) { left = s.cursor.pendingWrap ? 0 : 1 } else if s.cursor.x != rightLimit - 1 { left = 1 } else {
            left = s.page.cell(s.cursorCell).codepoint == 0 ? 1 : 0
        }
        if s.page.cell(s.cellAt(s.cursor.x - left)).wide == .spacerTail { left += 1 }
        var prev = s.cellAt(s.cursor.x - left)
        let prevCell = s.page.cell(prev)
        guard prevCell.codepoint != 0 else { return false }
        var (last, state): (UInt32, UInt8) = (prevCell.codepoint, 0)
        if prevCell.hasGrapheme { for cp in s.page.grapheme(prev)! { _ = Unicode.graphemeBreak(last, cp, &state, breaks); last = cp } }
        if Unicode.graphemeBreak(last, c, &state, breaks) { return false }
        switch graphemeWidthEffect(last, c) {
        case .ignore: return true
        case .wide:
            if prevCell.wide == .wide { break }
            s.cursorLeft(left)
            if s.cursor.x == rightLimit - 1 {
                guard modes.get(.wraparound) else { return true }
                let rowWrap = rightLimit == cols
                if rowWrap { s.page.updateRow(s.pin.y) { $0.wrap = true } }
                let cp = prevCell.codepoint
                if prevCell.hasGrapheme {
                    s.page.updateCell(prev) { ($0.wide, $0.content) = (rowWrap ? .spacerHead : .narrow, 0) }
                    // The old cell is one row up after the wrap (the cursor moved down or the region
                    // scrolled up), except when the wrap's index does nothing: Ghostty still looks one
                    // row up there and hits the wrong cell (its crash, corpus/crashes); we use the row.
                    let y = s.cursor.y
                    let stays = y < region.top || y > region.bottom ? y == rows - 1 : y == region.bottom && (s.cursor.x < region.left || s.cursor.x > region.right)
                    printWrap()
                    printCell(cp, .wide)
                    guard var old = stays ? s.pin : s.pin.up(1) else { return true }
                    old.x = rightLimit - 1
                    let (src, dst) = (old.cell, s.cursorCell)
                    if old.page === s.page {
                        s.page.moveGrapheme(src, dst)
                        s.page.updateCell(src) { $0.tag = .codepoint }
                        s.page.updateCell(dst) { $0.tag = .codepointGrapheme }
                        s.page.updateRow(s.pin.y) { $0.grapheme = true }
                    } else {
                        for g in old.page.grapheme(src)! { try? s.appendGrapheme(s.cursorCell, g) }
                        old.page.clearGrapheme(src)
                    }
                    old.page.updateRow(old.y) { $0.grapheme = old.page.any(old.y) { $0.hasGrapheme } }
                } else {
                    printCell(0, rowWrap ? .spacerHead : .narrow)
                    printWrap()
                    printCell(cp, .wide)
                }
                prev = s.cursorCell
            } else { s.page.updateCell(prev) { $0.wide = .wide } }
            s.cursorRight(1)
            let (node, serial) = (s.page, s.page.serial)
            printCell(0, .spacerTail)
            if s.page !== node || s.page.serial != serial { prev = s.cellAt(s.cursor.x - 1) }
            if s.cursor.x == rightLimit - 1 { s.cursor.pendingWrap = true } else { s.cursorRight(1) }
        case .narrow:
            if prevCell.wide != .wide { break }
            s.page.updateCell(prev) { $0.wide = .narrow }
            let px = s.cursor.x - left
            if px < cols - 1 { s.page.updateCell(prev + 8) { $0.wide = .narrow } }
            s.cursor.pendingWrap = false
            s.cursorHorizontalAbsolute(min(px + 1, rightLimit - 1))
        case .noChange: break
        }
        s.cursorMarkDirty()
        try? s.appendGrapheme(prev, c)
        return true
    }

    enum WidthEffect { case ignore, noChange, wide, narrow }

    /// How a joining codepoint changes the grapheme's width (Ghostty's graphemeWidthEffect).
    func graphemeWidthEffect(_ prev: UInt32, _ cp: UInt32) -> WidthEffect {
        if cp == 0xFE0F || cp == 0xFE0E { return !Unicode.props(prev).emojiVSBase ? .ignore : cp == 0xFE0F ? .wide : .narrow }
        return Unicode.props(cp).widthZeroInGrapheme ? .noChange : .wide
    }

    /// Writes one cell at the cursor with the cursor's attributes (charset mapped).
    func printCell(_ unmapped: UInt32, _ wide: Cell.Wide) {
        let s = active
        let slot = s.charset.singleShift ?? s.charset.gl
        s.charset.singleShift = nil
        let set = s.charset[slot]
        let c: UInt32 = set == .utf8 || set == .ascii ? unmapped : unmapped > 255 ? 0x20 : charsetMap(set, unmapped)
        let at = s.cursorCell, old = s.page.cell(at)
        if old.wide != wide {
            switch old.wide {
            case .wide:
                if s.cursor.x < cols - 1 {
                    s.clearCells(s.page, s.pin.y, s.cursor.x + 1..<s.cursor.x + 2)
                    clearHeadAbove()
                }
            case .spacerTail:
                s.clearCells(s.page, s.pin.y, s.cursor.x - 1..<s.cursor.x)
                clearHeadAbove()
            default: break
            }
        }
        if s.page.cell(at).hasGrapheme {
            s.page.clearGrapheme(at)
            s.page.updateRow(s.pin.y) { $0.grapheme = s.page.any(s.pin.y) { $0.hasGrapheme } }
        }
        let styleChanged = s.page.cell(at).styleID != s.cursor.styleID
        if styleChanged, s.page.cell(at).styleID != 0 { s.page.styles.release(s.page.memory, s.page.cell(at).styleID) }
        let hadLink = s.page.cell(at).hyperlink
        var cell = Cell.text(c)
        (cell.styleID, cell.wide, cell.protected, cell.semantic) = (s.cursor.styleID, wide, s.cursor.protected, s.cursor.semanticContent)
        s.page.setCell(at, cell)
        if styleChanged, cell.styleID != 0 {
            s.page.styles.use(s.page.memory, cell.styleID)
            s.page.updateRow(s.pin.y) { $0.styled = true }
        }
        if s.cursor.hyperlinkID > 0 { try? s.cursorSetHyperlink() } else if hadLink {
            s.page.clearHyperlink(at)
            s.page.updateRow(s.pin.y) { $0.hyperlink = s.page.any(s.pin.y) { $0.hyperlink } }
        }
    }

    /// Writing over half of a wide char at column <= 1 un-heads the spacer at the end of the row above.
    private func clearHeadAbove() {
        let s = active
        guard s.cursor.y > 0, s.cursor.x <= 1, var p = s.pin.up(1) else { return }
        p.x = p.page.cols - 1
        if p.page.cell(p.cell).wide == .spacerHead { p.page.updateCell(p.cell) { $0.wide = .narrow } }
    }

    func printWrap() {
        let s = active
        let mark = s.cursor.x == cols - 1
        if mark { s.page.updateRow(s.pin.y) { $0.wrap = true } }
        let (sem, eol) = (s.cursor.semanticContent, s.cursor.semanticContentClearEOL)
        index()
        s.cursorHorizontalAbsolute(region.left)
        (s.cursor.semanticContent, s.cursor.semanticContentClearEOL) = (sem, eol)
        if sem == .prompt { s.page.updateRow(s.pin.y) { $0.semanticPrompt = .promptContinuation } }
        if mark { s.page.updateRow(s.pin.y) { $0.wrapContinuation = true } }
    }

    public func printRepeat(_ n: Int) {
        guard let c = previousChar else { return }
        for _ in 0..<max(n, 1) { print(c) }
    }

    // Charsets.

    func configureCharset(_ slot: CharsetSlot, _ set: Charset) { active.charset[slot] = set }

    func invokeCharset(_ bank: CharsetBank, _ slot: CharsetSlot, single: Bool) {
        if single { active.charset.singleShift = slot; return }
        if bank == .GL { active.charset.gl = slot } else { active.charset.gr = slot }
    }

    // Cursor movement.

    public func carriageReturn() {
        active.cursor.pendingWrap = false
        active.cursorHorizontalAbsolute(modes.get(.origin) || cursor.x >= region.left ? region.left : 0)
    }

    public func linefeed() {
        index()
        if modes.get(.linefeed) { carriageReturn() }
    }

    public func backspace() { cursorLeft(1) }

    public func cursorUp(_ n: Int) {
        active.cursor.pendingWrap = false
        let maxN = cursor.y >= region.top ? cursor.y - region.top : cursor.y
        active.cursorUp(min(maxN, max(n, 1)))
    }

    public func cursorDown(_ n: Int) {
        active.cursor.pendingWrap = false
        let maxN = cursor.y <= region.bottom ? region.bottom - cursor.y : rows - cursor.y - 1
        active.cursorDown(min(maxN, max(n, 1)))
    }

    public func cursorRight(_ n: Int) {
        active.cursor.pendingWrap = false
        let maxN = cursor.x <= region.right ? region.right - cursor.x : cols - cursor.x - 1
        active.cursorRight(min(maxN, max(n, 1)))
    }

    public func cursorLeft(_ n: Int) {
        let s = active
        let mode = !modes.get(.wraparound) ? 0 : modes.get(.reverseWrapExtended) ? 2 : modes.get(.reverseWrap) ? 1 : 0
        var count = max(n, 1)
        if mode == 0 {
            s.cursorLeft(min(count, s.cursor.x))
            s.cursor.pendingWrap = false
            return
        }
        if s.cursor.pendingWrap { count -= 1; s.cursor.pendingWrap = false }
        let leftMargin = s.cursor.x < region.left ? 0 : region.left
        if s.cursor.x == leftMargin, mode == 1, s.cursor.y <= region.top { return s.cursorAbsolute(leftMargin, region.top) }
        while true {
            let amount = min(s.cursor.x - leftMargin, count)
            count -= amount
            s.cursorLeft(amount)
            if count == 0 { break }
            if s.cursor.y == region.top {
                if mode != 2 { break }
                s.cursorAbsolute(region.right, region.bottom)
                count -= 1
                continue
            }
            if s.cursor.y == 0 { break }
            if mode != 2, !s.pin.up(1)!.row.wrap { break }
            s.cursorAbsolute(region.right, s.cursor.y - 1)
            count -= 1
        }
    }

    public func saveCursor() {
        let c = cursor
        active.saved = SavedCursor(x: c.x, y: c.y, style: c.style, protected: c.protected, pendingWrap: c.pendingWrap, origin: modes.get(.origin), charset: active.charset)
    }

    public func restoreCursor() {
        let s = active
        let saved = s.saved ?? SavedCursor(x: 0, y: 0, style: Style(), protected: false, pendingWrap: false, origin: false, charset: CharsetState())
        s.cursor.style = saved.style
        do { try s.manualStyleUpdate() } catch { s.cursor.style = Style(); try? s.manualStyleUpdate() }
        s.charset = saved.charset
        modes.set(.origin, saved.origin)
        (s.cursor.pendingWrap, s.cursor.protected) = (saved.pendingWrap, saved.protected)
        s.cursorAbsolute(min(saved.x, cols - 1), min(saved.y, rows - 1))
    }

    func setProtectedMode(_ m: ProtectedMode) {
        active.cursor.protected = m != .off
        if m != .off { active.protectedMode = m }
    }

    // Semantic prompts (OSC 133).

    func semanticPrompt(_ cmd: SemanticPrompt) {
        let s = active
        switch cmd.action {
        case .freshLine: semanticFreshLine()
        case .freshLineNewPrompt, .newCommand:
            semanticFreshLine()
            s.setSemanticContent(.prompt(cmd.promptKind ?? .initial))
            if let r = cmd.redraw { flags.shellRedrawsPrompt = r }
            if let v = cmd.clickEvents { s.semanticPrompt.click = .clickEvents(v) } else if let v = cmd.click { s.semanticPrompt.click = .cl(v) }
        case .promptStart: s.setSemanticContent(.prompt(cmd.promptKind ?? .initial))
        case .endPromptStartInput: s.setSemanticContent(.input(clearEOL: false))
        case .endPromptStartInputTerminateEol: s.setSemanticContent(.input(clearEOL: true))
        case .endInputStartOutput:
            s.setSemanticContent(.output)
            if s.pin.row.semanticPrompt != .none, s.cursor.x == 0 { s.page.updateRow(s.pin.y) { $0.semanticPrompt = .none } }
        case .endCommand: s.setSemanticContent(.output)
        }
    }

    private func semanticFreshLine() {
        let leftMargin = cursor.x < region.left ? 0 : region.left
        if cursor.x == leftMargin { return }
        carriageReturn()
        index()
    }

    // Tabs.

    public func horizontalTab() {
        while cursor.x < region.right {
            active.cursorRight(1)
            if tabstops[cursor.x] { return }
        }
    }

    public func horizontalTabBack() {
        let leftLimit = modes.get(.origin) ? region.left : 0
        while cursor.x > leftLimit {
            active.cursorLeft(1)
            if tabstops[cursor.x] { return }
        }
    }

    func tabClear(all: Bool) { if all { tabstops = [Bool](repeating: false, count: cols) } else { tabstops[cursor.x] = false } }
    func tabSet() { tabstops[cursor.x] = true }
    func tabReset() { tabstops = Terminal.tabs(cols) }

    // Index, scrolling, margins.

    public func index() {
        let s = active
        s.cursor.pendingWrap = false
        defer {
            if s.cursor.semanticContent != .output {
                if s.cursor.semanticContentClearEOL { (s.cursor.semanticContent, s.cursor.semanticContentClearEOL) = (.output, false) } else {
                    s.page.updateRow(s.pin.y) { $0.semanticPrompt = .promptContinuation }
                }
            }
        }
        if s.cursor.y < region.top || s.cursor.y > region.bottom {
            if s.cursor.y < rows - 1 { s.cursorDown(1) }
            return
        }
        if s.cursor.y == region.bottom, s.cursor.x >= region.left, s.cursor.x <= region.right {
            let images = !s.images.placements.isEmpty
            if region.top == 0, fullWidth, !s.noScrollback || region.bottom == 0 {
                return images ? withImagesScrolled(-1, inPlace: false) { s.cursorScrollAbove() } : s.cursorScrollAbove()
            }
            if !fullWidth { return scrollUp(1) }
            if images { return withImagesScrolled(-1, inPlace: true) { s.cursorScrollRegionUp(region.bottom - region.top) } }
            return s.cursorScrollRegionUp(region.bottom - region.top)
        }
        if s.cursor.y < region.bottom { s.cursorDown(1) }
    }

    public func reverseIndex() {
        if cursor.y != region.top || cursor.x < region.left || cursor.x > region.right { return cursorUp(1) }
        scrollDown(1)
    }

    public func setCursorPos(_ rowReq: Int, _ colReq: Int) {
        let origin = modes.get(.origin)
        let (xOff, yOff) = origin ? (region.left, region.top) : (0, 0)
        let (xMax, yMax) = origin ? (region.right + 1, region.bottom + 1) : (cols, rows)
        active.cursor.pendingWrap = false
        let x = max(0, min(xMax, max(colReq, 1) + xOff) - 1), y = max(0, min(yMax, max(rowReq, 1) + yOff) - 1)
        if y == cursor.y {
            if x > cursor.x { active.cursorRight(x - cursor.x) } else { active.cursorLeft(cursor.x - x) }
            return
        }
        active.cursorAbsolute(x, y)
    }

    public func setTopAndBottomMargin(_ topReq: Int, _ bottomReq: Int) {
        let top = max(1, topReq), bottom = min(rows, bottomReq == 0 ? rows : bottomReq)
        guard top < bottom else { return }
        (scrollingRegion.top, scrollingRegion.bottom) = (top - 1, bottom - 1)
        setCursorPos(1, 1)
    }

    public func setLeftAndRightMargin(_ leftReq: Int, _ rightReq: Int) {
        guard modes.get(.enableLeftAndRightMargin) else { return }
        let left = max(1, leftReq), right = min(cols, rightReq == 0 ? cols : rightReq)
        guard left < right else { return }
        (scrollingRegion.left, scrollingRegion.right) = (left - 1, right - 1)
        setCursorPos(1, 1)
    }

    /// Runs `body` with the cursor elsewhere, then puts it back (with its pending wrap).
    private func keepingCursor(_ body: () -> Void) {
        let (x, y, wrap) = (cursor.x, cursor.y, cursor.pendingWrap)
        body()
        active.cursorAbsolute(x, y)
        active.cursor.pendingWrap = wrap
    }

    /// Kitty placements move with a scroll inside margins (SU/IND/SD/RI, not IL/DL): the ones in
    /// the region shift by `delta` rows (clipped, or gone), then re-anchor after `body` moved the rows.
    private func withImagesScrolled(_ delta: Int, inPlace: Bool, _ body: () -> Void) {
        let s = active
        guard !s.images.placements.isEmpty, region.top != 0 || region.bottom != rows - 1 || !fullWidth else { return body() }
        let restores = s.images.scrollMarginsBegin(self, delta, inPlace: inPlace)
        body()
        ImageStorage.scrollMarginsEnd(s, restores)
    }

    public func scrollDown(_ n: Int) {
        keepingCursor {
            withImagesScrolled(min(n, region.bottom - region.top + 1), inPlace: true) {
                active.cursorAbsolute(region.left, region.top)
                insertLines(n)
            }
        }
    }

    public func scrollUp(_ n: Int) {
        keepingCursor {
            let scrollback = region.top == 0 && fullWidth && (!active.noScrollback || region.bottom == rows - 1)
            withImagesScrolled(-min(n, region.bottom - region.top + 1), inPlace: !scrollback) {
                if scrollback {
                    active.cursorAbsolute(0, region.bottom)
                    for _ in 0..<min(n, region.bottom + 1) { active.cursorScrollAbove() }
                    return
                }
                active.cursorAbsolute(region.left, region.top)
                deleteLines(n)
            }
        }
    }

    public enum ViewportScroll { case top, bottom, delta(Int), row(Int) }

    public func scrollViewport(_ s: ViewportScroll) {
        switch s {
        case .top: active.scroll(.top)
        case .bottom: active.scroll(.active)
        case .delta(let n): active.scroll(.delta(n))
        case .row(let n): active.scroll(.row(n))
        }
    }

    /// A row's cells at the margins are about to shift: wide chars cut by a margin become blanks.
    private func rowWillBeShifted(_ p: Page, _ y: Int) {
        if region.right == cols - 1 || region.left < 2, p.cell(p.cellAt(y, p.cols - 1)).wide == .spacerHead {
            p.updateCell(p.cellAt(y, p.cols - 1)) { $0.wide = .narrow }
        }
        func unwide(_ wideX: Int, _ tailX: Int) {
            let w = p.cellAt(y, wideX)
            if p.cell(w).hasGrapheme { p.clearGrapheme(w); p.updateRow(y) { $0.grapheme = p.any(y) { $0.hasGrapheme } } }
            p.updateCell(w) { ($0.content, $0.wide) = (0, .narrow) }
            p.updateCell(p.cellAt(y, tailX)) { $0.wide = .narrow }
        }
        if p.cell(p.cellAt(y, region.left)).wide == .spacerTail { unwide(region.left - 1, region.left) }
        if p.cell(p.cellAt(y, region.right)).wide == .wide { unwide(region.right, region.right + 1) }
    }

    /// Insert (down) or delete (up) `count` lines at the cursor within the scroll region.
    private func shiftLines(_ count: Int, insert: Bool) {
        let s = active
        guard count > 0, cursor.y >= region.top, cursor.y <= region.bottom, cursor.x >= region.left, cursor.x <= region.right else { return }
        let startY = cursor.y
        defer { s.cursorAbsolute(region.left, startY); s.cursor.pendingWrap = false }
        let leftRight = !fullWidth
        let rem = region.bottom - cursor.y + 1, n = min(count, rem)
        let cur = s.pages.track(insert ? s.pin.down(rem - 1)! : s.pin)
        defer { s.pages.untrack(cur) }
        if !leftRight {
            let (a, b) = insert ? (s.page, cur.pin.page) : (cur.pin.page, cur.pin.down(rem - 1)!.page)
            var p: Page? = a
            while let page = p { s.pages.invalidate(page); if page === b { break }; p = page.next }
        }
        for i in 0..<rem {
            let (dp, dy) = (cur.pin.page, cur.pin.y)
            if i < rem - n {
                let off = insert ? cur.pin.up(n)! : cur.pin.down(n)!
                rowWillBeShifted(dp, dy)
                rowWillBeShifted(off.page, off.y)
                if !leftRight {
                    off.page.updateRow(off.y) { ($0.wrap, $0.wrapContinuation) = (false, false) }
                    dp.updateRow(dy) { ($0.wrap, $0.wrapContinuation) = (false, false) }
                }
                if off.page !== dp {
                    _ = s.cloneRowGrowing(dp, dy, off.page, off.y, region.left, region.right + 1)
                } else if !leftRight {
                    dp.swapRows(dy, off.y)
                } else {
                    dp.moveCells(off.y, region.left, dy, region.left, region.right - region.left + 1)
                    // Marked text moved into this row keeps it marked (Row.marked).
                    if dp.row(off.y).marked { dp.updateRow(dy) { $0.marked = true } }
                }
            } else {
                rowWillBeShifted(dp, dy)
                s.clearCells(dp, dy, region.left..<region.right + 1)
                if !leftRight { dp.updateRow(dy) { $0.reset() } }
            }
            cur.pin.markDirty()
            if let p = insert ? cur.pin.up(1) : cur.pin.down(1) { cur.pin = p }
        }
    }

    public func insertLines(_ n: Int) { shiftLines(n, insert: true) }

    /// Marks the text written so far (Row.marked): every primary-screen row above the cursor, in
    /// scrollback too, the cursor's own row once something is left of it, and the whole alternate
    /// screen if it shows. The mark stays with that text wherever later output moves it.
    public func markRows() {
        func mark(_ pages: PageList, through last: Pin?) {
            guard let last else { return }
            for (page, rows) in Pin(page: pages.first).chunks(down: true, to: last) {
                for y in rows { page.updateRow(y) { $0.marked = true } }
            }
        }
        mark(primary.pages, through: primary.cursor.x > 0 ? primary.pin : primary.pin.up(1))
        if isAlternate, let alternate { mark(alternate.pages, through: alternate.pages.bottomRight(.screen)) }
    }
    public func deleteLines(_ n: Int) { shiftLines(n, insert: false) }

    public func insertBlanks(_ count: Int) {
        let s = active
        s.cursor.pendingWrap = false
        guard count > 0, cursor.x >= region.left, cursor.x <= region.right else { return }
        let (p, y, x) = (s.page, s.pin.y, cursor.x)
        if p.cell(s.cursorCell).wide == .spacerTail { s.clearCells(p, y, x - 1..<x + 1) }
        let rem = region.right - x + 1
        if p.cell(p.cellAt(y, x + rem - 1)).wide == .wide { s.clearCells(p, y, x + rem - 1..<x + rem + 1) }
        let n = min(count, rem), scroll = rem - n
        if scroll > 0 {
            if p.cell(p.cellAt(y, x + scroll - 1)).wide == .wide { s.clearCells(p, y, x + scroll - 1..<x + scroll + 1) }
            for i in (x..<x + scroll).reversed() { p.swapCells(p.cellAt(y, i), p.cellAt(y, i + n)) }
        }
        s.clearCells(p, y, x..<x + n)
        s.cursorMarkDirty()
    }

    public func deleteChars(_ req: Int) {
        let s = active
        guard req > 0, cursor.x >= region.left, cursor.x <= region.right else { return }
        let (p, y, x) = (s.page, s.pin.y, cursor.x)
        let rem = region.right - x + 1, n = min(req, rem)
        s.splitCellBoundary(x)
        s.splitCellBoundary(x + n)
        s.splitCellBoundary(region.right + 1)
        let scroll = rem - n
        for i in x..<x + scroll { p.swapCells(p.cellAt(y, i + n), p.cellAt(y, i)) }
        s.clearCells(p, y, x + scroll..<x + rem)
        s.cursorResetWrap()
        s.cursorMarkDirty()
    }

    public func eraseChars(_ req: Int) {
        let s = active
        let remaining = cols - cursor.x
        var n = min(remaining, max(req, 1))
        if n != remaining, s.page.cell(s.cellAt(cursor.x + n - 1)).wide == .wide { n += 1 }
        s.splitCellBoundary(cursor.x)
        s.splitCellBoundary(cursor.x + n)
        s.cursorResetWrap()
        s.cursorMarkDirty()
        if s.protectedMode != .iso { return s.clearCells(s.page, s.pin.y, cursor.x..<cursor.x + n) }
        s.clearUnprotectedCells(s.page, s.pin.y, cursor.x..<cursor.x + n)
    }

    public enum EraseLine { case right, left, complete, rightUnlessPendingWrap }

    public func eraseLine(_ mode: EraseLine, protected req: Bool) {
        let s = active
        let range: Range<Int>
        switch mode {
        case .right:
            let x = cursor.x > 0 && s.page.cell(s.cursorCell).wide == .spacerTail ? cursor.x - 1 : cursor.x
            s.cursorResetWrap()
            range = x..<cols
        case .left: range = 0..<(s.page.cell(s.cursorCell).wide == .wide ? cursor.x + 2 : cursor.x + 1)
        case .complete: s.cursorResetWrap(); range = 0..<cols
        case .rightUnlessPendingWrap: return
        }
        s.cursor.pendingWrap = false
        s.cursorMarkDirty()
        if s.protectedMode == .iso || req { s.clearUnprotectedCells(s.page, s.pin.y, range) } else { s.clearCells(s.page, s.pin.y, range) }
    }

    public enum EraseDisplay { case below, above, complete, scrollback, scrollComplete }

    public func eraseDisplay(_ mode: EraseDisplay, protected req: Bool) {
        let s = active
        let protected = s.protectedMode == .iso || req
        switch mode {
        case .scrollComplete:
            s.scrollClear()
            s.cursor.pendingWrap = false
            s.images.clearScreen(self)
        case .complete:
            // At a prompt (the bottom row is a prompt row): keep the screen's text in history.
            if !isAlternate, let br = s.pages.bottomRight(.active), br.row.semanticPrompt != .none { s.scrollClear() }
            s.clearRows(s.pages.topLeft(.active), nil, protected: protected)
            s.cursor.pendingWrap = false
            s.images.clearScreen(self)
            dirty.clear = true
        case .below:
            eraseLine(.right, protected: req)
            if cursor.y + 1 < rows { s.clearRows(s.pages.pin(.active, y: cursor.y + 1)!, nil, protected: protected) }
        case .above:
            eraseLine(.left, protected: req)
            if cursor.y > 0 { s.clearRows(s.pages.pin(.active)!, s.pages.pin(.active, y: cursor.y - 1)!, protected: protected) }
        case .scrollback: s.eraseHistory()
        }
    }

    public func decaln() {
        let s = active
        let old = s.cursor.style
        s.cursor.style = Style(fgColor: old.fgColor, bgColor: old.bgColor, underlineColor: .none, flags: Style.Flags())
        do { try s.manualStyleUpdate() } catch { s.cursor.style = old; return }
        scrollingRegion = ScrollingRegion(top: 0, bottom: rows - 1, left: 0, right: cols - 1)
        modes.set(.origin, false)
        setCursorPos(1, 1)
        s.clearRows(s.pages.topLeft(.active), nil, protected: false)
        while true {
            var e = Cell.text(0x45)
            e.styleID = s.cursor.styleID
            s.page.fillCells(s.pin.y, 0..<s.page.cols, e)
            if s.cursor.styleID != 0 {
                s.page.styles.use(s.page.memory, s.cursor.styleID, s.page.cols)
                s.page.updateRow(s.pin.y) { $0.styled = true }
            }
            s.cursorMarkDirty()
            if s.cursor.y == rows - 1 { break }
            s.cursorDown(1)
        }
        setCursorPos(1, 1)
    }

    public func setAttribute(_ a: Attribute) { try? active.setAttribute(a) }

    /// The cursor's SGR state as parameters (DECRQSS "m" reply).
    func printAttributes() -> String {
        let pen = cursor.style
        var out = "0"
        let f = pen.flags
        for (on, a) in [(f.bold, 1), (f.faint, 2), (f.italic, 3), (f.underline != .none, 4), (f.overline, 53), (f.blink, 5), (f.inverse, 7), (f.invisible, 8), (f.strikethrough, 9)] where on {
            out += a == 4 && f.underline != .single ? ";4:\(f.underline.rawValue)" : ";\(a)"
        }
        func color(_ c: Style.Color, _ base: Int, _ bright: Int, _ ext: Int) {
            switch c {
            case .none: break
            case .palette(let i): out += i >= 16 ? ";\(ext):5:\(i)" : i >= 8 ? ";\(bright)\(i - 8)" : ";\(base)\(i)"
            case .rgb(let v): out += ";\(ext):2::\(v.r):\(v.g):\(v.b)"
            }
        }
        color(pen.fgColor, 3, 9, 38)
        color(pen.bgColor, 4, 10, 48)
        return out
    }

    // Screens and size.

    public func deccolm(_ cols132: Bool) {
        guard modes.get(.enableMode3) else { return modes.set(.mode132Column, false) }
        modes.set(.mode132Column, cols132)
        resize(cols: cols132 ? 132 : 80, rows: rows)
        eraseDisplay(.complete, protected: false)
        setCursorPos(1, 1)
    }

    public func resize(cols newCols: Int, rows newRows: Int, cellWidth: Int? = nil, cellHeight: Int? = nil) {
        guard newCols > 0, newRows > 0 else { return }
        if let w = cellWidth, let h = cellHeight { (widthPx, heightPx) = (newCols * w, newRows * h) }
        modes.set(.synchronizedOutput, false)
        if cols == newCols, rows == newRows { return }
        primary.resize(cols: newCols, rows: newRows, reflow: modes.get(.wraparound), promptRedraw: flags.shellRedrawsPrompt)
        // The alternate screen never reflows (Ghostty replaces it only when its resize fails).
        alternate?.resize(cols: newCols, rows: newRows, reflow: false, promptRedraw: .false)
        if cols != newCols { tabstops = Terminal.tabs(newCols) }
        dirty.clear = true
        (cols, rows) = (newCols, newRows)
        scrollingRegion = ScrollingRegion(top: 0, bottom: newRows - 1, left: 0, right: newCols - 1)
    }

    /// Makes `alt` (or primary) active; returns the previously active screen when it changed.
    @discardableResult func switchScreen(alternate alt: Bool) -> Screen? {
        guard alt != isAlternate else { return nil }
        let old = active
        old.endHyperlink()
        let new: Screen
        if alt {
            new = alternate ?? Screen(cols: cols, rows: rows, maxBytes: 0, maxLines: nil, blocks: blocks)
            new.images.totalLimit = kittyImageStorageLimit
            alternate = new
        } else { new = primary }
        new.charset = old.charset
        new.clearSelection()
        dirty.clear = true
        active = new
        return old
    }

    public enum ScreenMode { case m47, m1047, m1049 }

    public func switchScreenMode(_ mode: ScreenMode, _ enabled: Bool) {
        if mode == .m1047, !enabled, isAlternate { eraseDisplay(.complete, protected: false) }
        if mode == .m1049, enabled { saveCursor() }
        let old = switchScreen(alternate: enabled)
        switch mode {
        case .m47, .m1047: if let old { try? active.cursorCopy(old.cursor, hyperlink: false) }
        case .m1049:
            if enabled {
                eraseDisplay(.complete, protected: false)
                if let old { try? active.cursorCopy(old.cursor, hyperlink: false) }
            } else { restoreCursor() }
        }
    }

    public func fullReset() {
        active = primary
        if let a = alternate { a.free(); alternateGeneration += 1 }
        alternate = nil
        primary.reset()
        let visible = flags.visible
        modes = ModeState(values: modes.default, default: modes.default)
        flags = TerminalFlags()
        flags.visible = visible
        tabstops = Terminal.tabs(cols)
        previousChar = nil
        (pwd, title, glossary) = ([], [], Glossary())
        statusDisplay = .main
        scrollingRegion = ScrollingRegion(top: 0, bottom: rows - 1, left: 0, right: cols - 1)
        setCursorStyle(.default)
        dirty = Dirty(clear: true)
    }
}

/// DEC special graphics and British sets: 7-bit code -> codepoint (Ghostty's charsets.zig).
func charsetMap(_ set: Charset, _ c: UInt32) -> UInt32 {
    switch set {
    case .british: return c == 0x23 ? 0xA3 : c
    case .decSpecial:
        let t: [UInt32] = [0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0, 0x00B1, 0x2424, 0x240B, 0x2518, 0x2510, 0x250C, 0x2514,
                           0x253C, 0x23BA, 0x23BB, 0x2500, 0x23BC, 0x23BD, 0x251C, 0x2524, 0x2534, 0x252C, 0x2502, 0x2264, 0x2265, 0x03C0,
                           0x2260, 0x00A3, 0x00B7]
        return (0x60...0x7E).contains(c) ? t[Int(c) - 0x60] : c
    default: return c
    }
}

/// uucode's grapheme break class number for Extended_Pictographic.
let extendedPictographic: UInt8 = 11
