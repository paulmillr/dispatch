// One page of terminal rows in one memory block (Ghostty's page.zig): rows and
// 8-byte cells, plus the page's styles, graphemes and hyperlinks.

extension UInt64 {
    @inline(__always) func bits(_ at: Int, _ n: Int) -> UInt64 { self >> UInt64(at) & (1 << UInt64(n) - 1) }
    @inline(__always) mutating func set(_ at: Int, _ n: Int, _ v: UInt64) {
        let mask: UInt64 = (1 << UInt64(n) - 1) << UInt64(at)
        self = self & ~mask | v << UInt64(at) & mask
    }
    @inline(__always) mutating func set(_ at: Int, _ v: Bool) { set(at, 1, v ? 1 : 0) }
}

/// Ghostty's packed Cell: content tag u2, content u24 (codepoint u21 | palette u8 | rgb),
/// style id u16, wide u2, protected, hyperlink, semantic content u2.
public struct Cell: Equatable {
    public enum Tag: UInt64 { case codepoint, codepointGrapheme, bgColorPalette, bgColorRGB }
    public enum Wide: UInt64 { case narrow, wide, spacerTail, spacerHead }
    public enum Semantic: UInt64 { case output, input, prompt }
    public var bits: UInt64 = 0

    public init(_ bits: UInt64 = 0) { self.bits = bits }
    public var tag: Tag { get { Tag(rawValue: bits.bits(0, 2))! } set { bits.set(0, 2, newValue.rawValue) } }
    public var content: UInt32 { get { UInt32(bits.bits(2, 24)) } set { bits.set(2, 24, UInt64(newValue)) } }
    public var styleID: Int { get { Int(bits.bits(26, 16)) } set { bits.set(26, 16, UInt64(newValue)) } }
    public var wide: Wide { get { Wide(rawValue: bits.bits(42, 2))! } set { bits.set(42, 2, newValue.rawValue) } }
    public var protected: Bool { get { bits.bits(44, 1) != 0 } set { bits.set(44, newValue) } }
    public var hyperlink: Bool { get { bits.bits(45, 1) != 0 } set { bits.set(45, newValue) } }
    public var semantic: Semantic { get { Semantic(rawValue: bits.bits(46, 2))! } set { bits.set(46, 2, newValue.rawValue) } }

    /// The text codepoint (0 for empty and bg-color cells).
    public var codepoint: UInt32 { tag.rawValue < 2 ? content & 0x1FFFFF : 0 }
    public var hasGrapheme: Bool { tag == .codepointGrapheme }
    public var hasText: Bool { codepoint != 0 }
    public var hasStyling: Bool { styleID != 0 }
    public var isEmpty: Bool { tag.rawValue < 2 && !hasText && wide == .narrow }

    public static func text(_ cp: UInt32) -> Cell { var c = Cell(); c.content = cp; return c }
}

/// Ghostty's packed Row: cells offset u32, wrap, wrap continuation, grapheme, styled,
/// hyperlink, semantic prompt u2, kitty virtual placeholder, dirty.
public struct Row: Equatable {
    public enum Prompt: UInt64 { case none, prompt, promptContinuation }
    public var bits: UInt64

    public var cells: Int { Int(bits.bits(0, 32)) }
    public var wrap: Bool { get { bits.bits(32, 1) != 0 } set { bits.set(32, newValue) } }
    public var wrapContinuation: Bool { get { bits.bits(33, 1) != 0 } set { bits.set(33, newValue) } }
    public var grapheme: Bool { get { bits.bits(34, 1) != 0 } set { bits.set(34, newValue) } }
    public var styled: Bool { get { bits.bits(35, 1) != 0 } set { bits.set(35, newValue) } }
    public var hyperlink: Bool { get { bits.bits(36, 1) != 0 } set { bits.set(36, newValue) } }
    public var semanticPrompt: Prompt { get { Prompt(rawValue: bits.bits(37, 2))! } set { bits.set(37, 2, newValue.rawValue) } }
    /// Changed since the renderer last looked (RenderState.update clears it).
    public var dirty: Bool { get { bits.bits(40, 1) != 0 } set { bits.set(40, newValue) } }
    /// Written before the terminal's last row mark (Terminal.markRows). It travels with the row's
    /// text (swaps, clones, reflow) and goes with it when the row is cleared (reset).
    public var marked: Bool { get { bits.bits(41, 1) != 0 } set { bits.set(41, newValue) } }
    /// Rows holding page-managed memory (styles, links, graphemes) need per-cell cleanup.
    public var managedMemory: Bool { bits.bits(34, 3) != 0 }
    /// Everything but the cells offset back to default, and dirty (the row's storage is recycled).
    mutating func reset() { bits = bits.bits(0, 32) | 1 << 40 }
}

/// Which page capacity a failed operation needs grown (nil kind: rebuild at the same capacity).
public enum Grow: Error { case rehash, styles, graphemeBytes, hyperlinkBytes, stringBytes }

struct StyleContext: SetContext {
    func hash(_ v: Style) -> UInt64 { v.hash }
    func eql(_ a: Style, _ b: Style) -> Bool { a == b }
    func deleted(_ v: Style) {}
}

/// A hyperlink as a page stores it: strings in the page's string allocator.
struct LinkEntry: BitwiseCopyable {
    var explicit: Bool, implicit: UInt32, id: UInt32, idLen: UInt32, uri: UInt32, uriLen: UInt32
}

/// Link values may come from another page (clones): `src` holds the value's strings.
struct LinkContext: SetContext {
    let page: Page
    var src: Page?
    func hash(_ v: LinkEntry) -> UInt64 { (src ?? page).link(v).hash }
    func eql(_ a: LinkEntry, _ b: LinkEntry) -> Bool { (src ?? page).link(a) == page.link(b) }
    func deleted(_ v: LinkEntry) { page.free(v) }
}

func === (a: Page?, b: Page?) -> Bool { a?.header == b?.header }
func !== (a: Page?, b: Page?) -> Bool { a?.header != b?.header }

/// A page and its place in the page list (Ghostty's PageList node + Page), as a handle to its
/// header. The page list creates and frees pages like Ghostty's nodes; handles are plain values
/// (no reference counting, so using a page costs no retain/release). `===`: the same page.
public struct Page {
    struct Header {
        let memory: UnsafeMutableRawPointer, words: UnsafeMutablePointer<UInt64>, layout: Layout
        let styles: RefCountedSet<Style>, graphemeAlloc: BitmapAllocator, graphemeMap: OffsetMap<UInt64>
        let stringAlloc: BitmapAllocator, hyperlinkSet: RefCountedSet<LinkEntry>, hyperlinkMap: OffsetMap<UInt16>
        var cols: Int, rows = 0, next: Page? = nil, prev: Page? = nil, serial = 0, pooled = true, dirty = false
    }
    let header: UnsafeMutablePointer<Header>

    var memory: UnsafeMutableRawPointer { header.pointee.memory }
    var words: UnsafeMutablePointer<UInt64> { header.pointee.words }
    var layout: Layout { header.pointee.layout }
    var styles: RefCountedSet<Style> { header.pointee.styles }
    var graphemeAlloc: BitmapAllocator { header.pointee.graphemeAlloc }
    var graphemeMap: OffsetMap<UInt64> { header.pointee.graphemeMap }
    var stringAlloc: BitmapAllocator { header.pointee.stringAlloc }
    var hyperlinkSet: RefCountedSet<LinkEntry> { header.pointee.hyperlinkSet }
    var hyperlinkMap: OffsetMap<UInt16> { header.pointee.hyperlinkMap }
    var cols: Int { get { header.pointee.cols } nonmutating set { header.pointee.cols = newValue } }
    /// Rows joining the page start empty: format leaves the cells unzeroed and a row is zeroed as
    /// it joins, right before it gets written (Ghostty zeroes whole pages up front).
    var rows: Int {
        get { header.pointee.rows }
        nonmutating set {
            for y in header.pointee.rows..<max(header.pointee.rows, newValue) {
                words[y] &= 0xFFFF_FFFF
                (words + Int(words[y]) / 8).update(repeating: 0, count: Int(layout.capacity.cols))
            }
            header.pointee.rows = newValue
        }
    }
    /// List links.
    var next: Page? { get { header.pointee.next } nonmutating set { header.pointee.next = newValue } }
    var prev: Page? { get { header.pointee.prev } nonmutating set { header.pointee.prev = newValue } }
    /// Changes whenever the rows are rearranged or the page is replaced (Ghostty's node serial).
    var serial: Int { get { header.pointee.serial } nonmutating set { header.pointee.serial = newValue } }
    /// Counted as a standard page by the byte limit (Ghostty: pool-owned), else by its own size.
    var pooled: Bool { get { header.pointee.pooled } nonmutating set { header.pointee.pooled = newValue } }
    var accountedSize: Int { pooled ? Page.stdSize : layout.totalSize }
    /// Every row changed (cheaper than marking each; RenderState.update clears it).
    var dirty: Bool { get { header.pointee.dirty } nonmutating set { header.pointee.dirty = newValue } }
    @_spi(Test) public var capacity: Capacity { layout.capacity }
    @_spi(Test) public var size: (cols: Int, rows: Int) { (cols, rows) }

    /// A new empty page, in a freed page's header (`node`: Ghostty's node pool) and block
    /// (`block`). Blocks of pages that fit a standard page are standard-sized (Ghostty's page
    /// pool), so any of them can hold a new one.
    init(_ cap: Capacity, node: Page? = nil, block: UnsafeMutableRawPointer? = nil) {
        let l = Page.layout(cap)
        let m = block ?? .allocate(byteCount: (l.totalSize <= Page.stdSize ? Page.stdSize : l.totalSize) + Page.stateBytes, alignment: pageSizeMin)
        let c = Page.format(m, l)
        header = node?.header ?? .allocate(capacity: 1)
        if node != nil { header.deinitialize(count: 1) }
        header.initialize(to: Header(memory: m, words: m.bindMemory(to: UInt64.self, capacity: (l.rowsSize + l.cellsSize) / 8), layout: l,
                                     styles: c.0, graphemeAlloc: c.1, graphemeMap: c.2, stringAlloc: c.3, hyperlinkSet: c.4, hyperlinkMap: c.5, cols: Int(cap.cols)))
        for y in 0..<Int(cap.rows) { words[y] = UInt64(l.cellsStart + y * cols * 8) }
    }

    func free() {
        memory.deallocate()
        freeNode()
    }

    /// Frees the header only (its block went elsewhere).
    func freeNode() {
        header.deinitialize(count: 1)
        header.deallocate()
    }

    /// The containers' counters, after Ghostty's layout in the block.
    static let stateBytes = 2 * RefCountedSet<Style>.stateBytes + 4 * MemoryLayout<Int>.stride

    /// Zeroes the block except the cells (see `rows`) and sets up the containers. The same
    /// block and layout always give the same container views.
    private static func format(_ m: UnsafeMutableRawPointer, _ l: Layout) -> (RefCountedSet<Style>, BitmapAllocator, OffsetMap<UInt64>, BitmapAllocator, RefCountedSet<LinkEntry>, OffsetMap<UInt16>) {
        let end = l.cellsStart + l.cellsSize   // cells are zeroed per row, see `rows`
        (m + end).initializeMemory(as: UInt8.self, repeating: 0, count: l.totalSize - end)
        let s = m + l.totalSize, set = RefCountedSet<Style>.stateBytes, int = MemoryLayout<Int>.stride
        return (RefCountedSet(m, at: l.stylesStart, l.stylesLayout, stride: Zig.styles.size, state: s),
                BitmapAllocator(m, at: l.graphemeAllocStart, l.graphemeAllocLayout, chunk: graphemeChunk, state: s + 2 * set),
                OffsetMap(m, at: l.graphemeMapStart, l.graphemeMapLayout, load: 100, state: s + 2 * set + int),
                BitmapAllocator(m, at: l.stringAllocStart, l.stringAllocLayout, chunk: stringChunk, state: s + 2 * set + 2 * int),
                RefCountedSet(m, at: l.hyperlinkSetStart, l.hyperlinkSetLayout, stride: Zig.hyperlinkSet.size, state: s + set),
                OffsetMap(m, at: l.hyperlinkMapStart, l.hyperlinkMapLayout, load: 80, state: s + 2 * set + 3 * int))
    }

    /// Back to an empty page of the same capacity.
    func reinit() {
        _ = Page.format(memory, layout)
        for y in 0..<Int(capacity.rows) { words[y] = UInt64(layout.cellsStart + y * Int(capacity.cols) * 8) }
        header.pointee.rows = 0
        (cols, rows) = (Int(capacity.cols), Int(capacity.rows))
    }

    /// Rows, capacity and container usage (what decides when the page must grow), for the dump.
    @_spi(Test) public struct State { public let rows: Int, cap: Capacity, styles: SetState, links: SetState, graphemeBytes: Int, stringBytes: Int, graphemeMap: Int, hyperlinkMap: Int }
    @_spi(Test) public struct SetState { public let living: Int, refs: Int }
    @_spi(Test) public var state: State {
        func set<V>(_ s: RefCountedSet<V>) -> SetState { SetState(living: s.living, refs: (1..<s.nextID).reduce(0) { $0 + s.refCount(memory, $1) }) }
        return State(rows: rows, cap: capacity, styles: set(styles), links: set(hyperlinkSet), graphemeBytes: graphemeAlloc.usedBytes(memory),
                     stringBytes: stringAlloc.usedBytes(memory), graphemeMap: graphemeMap.count, hyperlinkMap: hyperlinkMap.count)
    }

    // Rows and cells. A cell is named by its byte offset in the page (Ghostty's Offset(Cell)).

    public func row(_ y: Int) -> Row { Row(bits: words[y]) }
    func setRow(_ y: Int, _ r: Row) { words[y] = r.bits }
    func updateRow(_ y: Int, _ body: (inout Row) -> Void) { var r = row(y); body(&r); setRow(y, r) }
    /// Offset of cell x in row y.
    public func cellAt(_ y: Int, _ x: Int) -> Int { row(y).cells + 8 * x }
    public func cell(_ offset: Int) -> Cell { Cell(words[offset / 8]) }
    func setCell(_ offset: Int, _ c: Cell) { words[offset / 8] = c.bits }
    func updateCell(_ offset: Int, _ body: (inout Cell) -> Void) { var c = cell(offset); body(&c); setCell(offset, c) }

    // Styles.

    public func style(_ id: Int) -> Style { id == 0 ? Style() : styles.get(memory, id) }

    func addStyle(_ s: Style) throws(Grow) -> Int {
        do { return try styles.add(memory, s, StyleContext()) } catch { throw Grow(error, .styles) }
    }

    // Graphemes: extra codepoints after the cell's own, in the grapheme allocator.

    /// The cell's extra codepoints, read in place: valid until the page changes.
    public func grapheme(_ cell: Int) -> Codepoints? {
        graphemeMap.get(memory, UInt32(cell)).map { Codepoints(base: UnsafeRawPointer(memory + Int($0 & 0xFFFF_FFFF)), endIndex: Int($0 >> 32)) }
    }

    func setGraphemes<C: Collection<UInt32>>(_ y: Int, _ cell: Int, _ cps: C) throws(Grow) {
        let stored = cps.prefix(graphemeMaxLen)
        guard let at = graphemeAlloc.alloc(memory, bytes: 4 * stored.count) else { throw .graphemeBytes }
        for (i, cp) in stored.enumerated() { memory.storeBytes(of: cp, toByteOffset: at + 4 * i, as: UInt32.self) }
        guard graphemeMap.set(memory, UInt32(cell), UInt64(at) | UInt64(stored.count) << 32) else {
            graphemeAlloc.free(memory, at: at, bytes: 4 * stored.count)
            throw .graphemeBytes
        }
        updateCell(cell) { $0.tag = .codepointGrapheme }
        updateRow(y) { $0.grapheme = true }
    }

    func appendGrapheme(_ y: Int, _ cell: Int, _ cp: UInt32) throws(Grow) {
        guard self.cell(cell).hasGrapheme, let v = graphemeMap.get(memory, UInt32(cell)) else { return try setGraphemes(y, cell, CollectionOfOne(cp)) }
        let (at, len) = (Int(v & 0xFFFF_FFFF), Int(v >> 32))
        if len >= graphemeMaxLen { return }
        if len % (graphemeChunk / 4) != 0 {
            memory.storeBytes(of: cp, toByteOffset: at + 4 * len, as: UInt32.self)
            _ = graphemeMap.set(memory, UInt32(cell), UInt64(at) | UInt64(len + 1) << 32)
            return
        }
        guard let new = graphemeAlloc.alloc(memory, bytes: 4 * (len + 1)) else { throw .graphemeBytes }
        (memory + new).copyMemory(from: memory + at, byteCount: 4 * len)
        memory.storeBytes(of: cp, toByteOffset: new + 4 * len, as: UInt32.self)
        _ = graphemeMap.set(memory, UInt32(cell), UInt64(new) | UInt64(len + 1) << 32)
        graphemeAlloc.free(memory, at: at, bytes: 4 * len)
    }

    func moveGrapheme(_ src: Int, _ dst: Int) {
        let v = graphemeMap.get(memory, UInt32(src))!
        graphemeMap.remove(memory, UInt32(src))
        _ = graphemeMap.set(memory, UInt32(dst), v)
    }

    func clearGrapheme(_ cell: Int) {
        let v = graphemeMap.get(memory, UInt32(cell))!
        graphemeAlloc.free(memory, at: Int(v & 0xFFFF_FFFF), bytes: 4 * Int(v >> 32))
        graphemeMap.remove(memory, UInt32(cell))
        updateCell(cell) { $0.tag = .codepoint }
    }

    public var graphemeCount: Int { graphemeMap.count }

    // Hyperlinks: cell -> id map, id -> entry set, strings in the string allocator.

    public func hyperlink(_ cell: Int) -> Int? { hyperlinkMap.get(memory, UInt32(cell)).map(Int.init) }

    func bytes(_ at: UInt32, _ len: UInt32) -> [UInt8] { (0..<Int(len)).map { memory.load(fromByteOffset: Int(at) + $0, as: UInt8.self) } }
    func link(_ e: LinkEntry) -> Link { Link(id: e.explicit ? .explicit(bytes(e.id, e.idLen)) : .implicit(e.implicit), uri: bytes(e.uri, e.uriLen)) }
    public func link(id: Int) -> Link { link(hyperlinkSet.get(memory, id)) }

    func free(_ e: LinkEntry) {
        if e.explicit, e.idLen > 0 { stringAlloc.free(memory, at: Int(e.id), bytes: Int(e.idLen)) }
        if e.uriLen > 0 { stringAlloc.free(memory, at: Int(e.uri), bytes: Int(e.uriLen)) }
    }

    /// Copies a string into the string allocator.
    func store(_ s: [UInt8]) throws(Grow) -> UInt32 {
        guard let at = stringAlloc.alloc(memory, bytes: s.count) else { throw .stringBytes }
        for (i, b) in s.enumerated() { memory.storeBytes(of: b, toByteOffset: at + i, as: UInt8.self) }
        return UInt32(at)
    }

    /// The link's strings copied into this page.
    func entry(_ l: Link) throws(Grow) -> LinkEntry {
        var e = LinkEntry(explicit: false, implicit: 0, id: 0, idLen: 0, uri: try store(l.uri), uriLen: UInt32(l.uri.count))
        switch l.id {
        case .implicit(let v): e.implicit = v
        case .explicit(let id):
            do { (e.explicit, e.id, e.idLen) = (true, try store(id), UInt32(id.count)) } catch {
                stringAlloc.free(memory, at: Int(e.uri), bytes: l.uri.count)
                throw error
            }
        }
        return e
    }

    func insertHyperlink(_ l: Link) throws(Grow) -> Int {
        let e = try entry(l)
        do { return try hyperlinkSet.add(memory, e, LinkContext(page: self)) } catch {
            free(e)
            throw Grow(error, .hyperlinkBytes)
        }
    }

    func setHyperlink(_ y: Int, _ cell: Int, _ id: Int) throws(Grow) {
        if let old = hyperlink(cell) {
            hyperlinkSet.release(memory, old)
            if old == id { updateCell(cell) { $0.hyperlink = true }; return }
        } else if hyperlinkMap.count >= hyperlinkMap.maxLoad { throw .hyperlinkBytes }
        _ = hyperlinkMap.set(memory, UInt32(cell), UInt16(id))
        updateCell(cell) { $0.hyperlink = true }
        updateRow(y) { $0.hyperlink = true }
    }

    func clearHyperlink(_ cell: Int) {
        guard let id = hyperlink(cell) else { return }
        hyperlinkSet.release(memory, id)
        hyperlinkMap.remove(memory, UInt32(cell))
        updateCell(cell) { $0.hyperlink = false }
    }

    func moveHyperlink(_ src: Int, _ dst: Int) {
        let id = hyperlinkMap.get(memory, UInt32(src))!
        hyperlinkMap.remove(memory, UInt32(src))
        _ = hyperlinkMap.set(memory, UInt32(dst), id)
    }

    public var hyperlinkCount: Int { hyperlinkMap.count }
    public var hyperlinkCapacity: Int { hyperlinkMap.maxLoad }
}

extension Grow {
    /// A set's "full" as the capacity to grow: rehash needs no growth.
    init(_ e: PageFull, _ kind: Grow) { self = e == .needsRehash ? .rehash : kind }
}

/// Graphemes keep at most this many extra codepoints.
let graphemeMaxLen = 64

/// Codepoints stored in page memory (a view, no copy).
public struct Codepoints: RandomAccessCollection {
    let base: UnsafeRawPointer
    public let endIndex: Int
    public var startIndex: Int { 0 }
    public subscript(i: Int) -> UInt32 { base.load(fromByteOffset: 4 * i, as: UInt32.self) }
}

extension Page {
    /// Frees what cells [left, end) of row y hold in page memory, then fills them with `blank`.
    func clearCells(_ y: Int, _ left: Int, _ end: Int, blank: Cell = Cell()) {
        let full = end - left == cols, cells = stride(from: cellAt(y, left), to: cellAt(y, end), by: 8)
        if row(y).grapheme {
            for c in cells where cell(c).hasGrapheme { clearGrapheme(c) }
            updateRow(y) { $0.grapheme = !full && self.any(y) { $0.hasGrapheme } }
        }
        if row(y).hyperlink {
            for c in cells where cell(c).hyperlink { clearHyperlink(c) }
            updateRow(y) { $0.hyperlink = !full && self.any(y) { $0.hyperlink } }
        }
        if row(y).styled {
            for c in cells where cell(c).hasStyling { styles.release(memory, cell(c).styleID) }
            updateRow(y) { $0.styled = !full && self.any(y) { $0.hasStyling } }
        }
        fillCells(y, left..<end, blank)
    }

    /// Cells x of row y all become c.
    func fillCells(_ y: Int, _ x: Range<Int>, _ c: Cell) { (words + cellAt(y, x.lowerBound) / 8).update(repeating: c.bits, count: x.count) }

    func any(_ y: Int, _ test: (Cell) -> Bool) -> Bool { (0..<cols).contains { test(cell(cellAt(y, $0))) } }

    /// Rows [r] move up by one, the first to the end (Ghostty's fastmem.rotateOnce).
    func rotateUp(_ r: Range<Int>) { guard r.count > 1 else { return }; let f = words[r.lowerBound]; for y in r.dropLast() { words[y] = words[y + 1] }; words[r.upperBound - 1] = f }
    /// Rows [r] move down by one, the last to the start (rotateOnceR).
    func rotateDown(_ r: Range<Int>) { guard r.count > 1 else { return }; let l = words[r.upperBound - 1]; for y in r.dropFirst().reversed() { words[y] = words[y - 1] }; words[r.lowerBound] = l }
    func swapRows(_ a: Int, _ b: Int) { (words[a], words[b]) = (words[b], words[a]) }

    func resetRow(_ y: Int) {
        clearCells(y, 0, cols)
        updateRow(y) { $0.reset() }
    }

    /// Moves len cells from row sy (at sx) to row dy (at dx), with what they hold; the source is zeroed.
    func moveCells(_ sy: Int, _ sx: Int, _ dy: Int, _ dx: Int, _ len: Int) {
        clearCells(dy, dx, dx + len)
        let managed = row(sy).managedMemory
        for i in 0..<len {
            let (src, dst) = (cellAt(sy, sx + i), cellAt(dy, dx + i))
            var c = cell(src)
            setCell(dst, c)
            guard managed else { continue }
            if c.hasGrapheme {
                moveGrapheme(src, dst)
                updateCell(src) { $0.tag = .codepoint }
                updateRow(dy) { $0.grapheme = true }
            }
            if c.hyperlink {
                moveHyperlink(src, dst)
                updateRow(dy) { $0.hyperlink = true }
            }
            c = Cell()
        }
        if !row(dy).styled { updateRow(dy) { $0.styled = (dx..<dx + len).contains { self.cell(self.cellAt(dy, $0)).hasStyling } } }
        fillCells(sy, sx..<sx + len, Cell())
        if len == cols { updateRow(sy) { ($0.grapheme, $0.hyperlink, $0.styled) = (false, false, false) } }
    }

    /// Swaps two cells with what they hold.
    func swapCells(_ a: Int, _ b: Int) {
        let (ca, cb) = (cell(a), cell(b))
        if ca.hasGrapheme || cb.hasGrapheme { swapValues(graphemeMap, a, b) }
        if ca.hyperlink || cb.hyperlink { swapValues(hyperlinkMap, a, b) }
        setCell(a, cb); setCell(b, ca)
    }

    private func swapValues<V>(_ map: OffsetMap<V>, _ a: Int, _ b: Int) {
        let (va, vb) = (map.get(memory, UInt32(a)), map.get(memory, UInt32(b)))
        map.remove(memory, UInt32(a))
        map.remove(memory, UInt32(b))
        if let vb { _ = map.set(memory, UInt32(a), vb) }
        if let va { _ = map.set(memory, UInt32(b), va) }
    }

    /// Copies rows [start, end) of another page (or this one) to rows 0... here.
    func clone(from other: Page, _ start: Int, _ end: Int) throws(Grow) {
        for (dy, sy) in (start..<end).enumerated() { try cloneRow(from: other, sy, to: dy, 0, cols) }
    }

    /// Ghostty's clonePartialRowFrom: cells [x0, x1) of row sy in `other` to row dy here,
    /// re-adding styles, links and graphemes to this page.
    func cloneRow(from other: Page, _ sy: Int, to dy: Int, _ x0: Int, _ x1Req: Int) throws(Grow) {
        let x1 = min(x1Req, cols, other.cols)
        if row(dy).managedMemory { clearCells(dy, x0, x1) }
        let src = other.row(sy)
        updateRow(dy) { d in
            var r = src
            if x1 - x0 < cols {
                (r.wrap, r.wrapContinuation, r.grapheme, r.hyperlink, r.styled, r.dirty) = (d.wrap, d.wrapContinuation, d.grapheme, d.hyperlink, d.styled, r.dirty || d.dirty)
                // Cells outside [x0, x1) stay: a marked row's are still marked text.
                r.marked = r.marked || d.marked
            }
            d.bits = r.bits.bits(32, 32) << 32 | UInt64(d.cells)
        }
        for x in x0..<x1 {
            let (s, dst) = (other.cell(other.cellAt(sy, x)), cellAt(dy, x))
            var c = s
            if src.managedMemory { (c.hyperlink, c.styleID) = (false, 0); if c.tag == .codepointGrapheme { c.tag = .codepoint } }
            setCell(dst, c)
            guard src.managedMemory else { continue }
            if s.hasGrapheme { try setGraphemes(dy, dst, other.grapheme(other.cellAt(sy, x))!) }
            if s.hyperlink { try setHyperlink(dy, dst, try linkID(from: other, other.hyperlink(other.cellAt(sy, x))!)) }
            if s.styleID != 0 {
                updateRow(dy) { $0.styled = true }
                let id: Int
                if other === self { id = s.styleID; styles.use(memory, id) } else {
                    do { id = try styles.add(memory, other.styles.get(other.memory, s.styleID), id: s.styleID, StyleContext()) ?? s.styleID } catch { throw Grow(error, .styles) }
                }
                updateCell(dst) { $0.styleID = id }
            }
        }
        if cols > other.cols, cell(cellAt(dy, other.cols - 1)).wide == .spacerHead { updateCell(cellAt(dy, other.cols - 1)) { $0.wide = .narrow } }
    }

    /// This page's id for link `id` of `other`: same entry, or a copy added here.
    private func linkID(from other: Page, _ id: Int) throws(Grow) -> Int {
        if other === self { hyperlinkSet.use(memory, id); return id }
        if hyperlinkCount >= hyperlinkCapacity { throw .hyperlinkBytes }
        let e = other.hyperlinkSet.get(other.memory, id)
        if let i = hyperlinkSet.lookup(memory, e, LinkContext(page: self, src: other)) { hyperlinkSet.use(memory, i); return i }
        let copy = try entry(other.link(e))
        do { return try hyperlinkSet.add(memory, copy, id: id, LinkContext(page: self)) ?? id } catch { throw Grow(error, .hyperlinkBytes) }
    }

    /// The smallest capacity that holds rows [start, end) as they are (Ghostty's exactRowCapacity).
    func exactCapacity(_ start: Int, _ end: Int) -> Capacity {
        var styleIDs = Set<Int>(), linkIDs = Set<Int>(), graphemeBytes = 0, stringBytes = 0, linkCells = 0
        for y in start..<end {
            for x in 0..<cols {
                let c = cellAt(y, x)
                if cell(c).hasStyling { styleIDs.insert(cell(c).styleID) }
                if cell(c).hasGrapheme, let g = grapheme(c) { graphemeBytes += alignForward(4 * g.count, graphemeChunk) }
                guard cell(c).hyperlink else { continue }
                linkCells += 1
                if let id = hyperlink(c), linkIDs.insert(id).inserted {
                    let e = hyperlinkSet.get(memory, id)
                    stringBytes += alignForward(Int(e.uriLen), stringChunk) + (e.explicit ? alignForward(Int(e.idLen), stringChunk) : 0)
                }
            }
        }
        let forCount = { (n: Int) in n == 0 ? 0 : Int((Double(n + 1) / 0.8125).rounded(.up)) }
        let links = max(forCount(linkIDs.count), (linkCells + hyperlinkCellMultiplier - 1) / hyperlinkCellMultiplier)
        return Capacity(cols: UInt16(cols), rows: UInt16(end - start), styles: UInt16(forCount(styleIDs.count)),
                        hyperlinkBytes: UInt16(truncatingIfNeeded: links * Zig.hyperlinkSet.size), graphemeBytes: UInt32(graphemeBytes), stringBytes: UInt32(stringBytes))
    }
}
