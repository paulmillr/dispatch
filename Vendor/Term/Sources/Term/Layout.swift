// Page memory layout (Ghostty's page.zig `Page.layout`, `Capacity`): the byte
// size of a page decides how much scrollback the byte limit keeps, so every
// offset and size follows Ghostty exactly, incl. Zig's item sizes (Tables.swift).

/// Zig's `std.heap.page_size_min` on this platform: page sizes are multiples of it.
#if arch(arm64) && canImport(Darwin)
let pageSizeMin = 16384
#else
let pageSizeMin = 4096
#endif

func alignForward(_ v: Int, _ a: Int) -> Int { (v + a - 1) / a * a }
func alignBackward(_ v: Int, _ a: Int) -> Int { v / a * a }
func ceilPowerOfTwo(_ v: Int) -> Int { v <= 1 ? 1 : 1 << (Int.bitWidth - (v - 1).leadingZeroBitCount) }

@_spi(Test) public struct Capacity: Equatable, Sendable {
    public var cols: UInt16, rows: UInt16, styles: UInt16, hyperlinkBytes: UInt16, graphemeBytes: UInt32, stringBytes: UInt32

    public init(cols: UInt16, rows: UInt16, styles: UInt16, hyperlinkBytes: UInt16, graphemeBytes: UInt32, stringBytes: UInt32) {
        (self.cols, self.rows, self.styles, self.hyperlinkBytes, self.graphemeBytes, self.stringBytes) =
            (cols, rows, styles, hyperlinkBytes, graphemeBytes, stringBytes)
    }

    /// Bits left for rows + cells once every other region is placed at the end.
    var gridBits: Int {
        let l = Page.layout(self)
        let starts = [(l.hyperlinkMapLayout.totalSize, Zig.hyperlinkMapAlign), (l.hyperlinkSetLayout.totalSize, Zig.hyperlinkSetAlign),
                      (l.stringAllocLayout.totalSize, Zig.stringAllocAlign), (l.graphemeMapLayout.totalSize, Zig.graphemeMapAlign),
                      (l.graphemeAllocLayout.totalSize, Zig.graphemeAllocAlign), (l.stylesLayout.totalSize, Zig.stylesAlign)]
        return starts.reduce(l.totalSize) { alignBackward($0 - $1.0, $1.1) } * 8
    }

    public var maxCols: UInt16? { gridBits <= 64 ? nil : UInt16(min(65535, (gridBits - 64) / 64)) }

    /// Same bytes, other column count: rows follow (nil when not even one row fits).
    public func adjust(cols: UInt16) -> Capacity? {
        let rows = gridBits / (64 + 64 * Int(cols))
        guard rows > 0 else { return nil }
        var c = self
        (c.cols, c.rows) = (cols, UInt16(clamping: rows))
        return c
    }
}

@_spi(Test) public struct SetLayout {
    public var cap = 0, tableCap = 0, tableMask = 0, tableStart = 0, itemsStart = 0, totalSize = 0
    init(_ n: Int, item: (size: Int, align: Int)) {
        guard n > 0 else { return }
        tableCap = ceilPowerOfTwo(n)
        cap = Int(0.8125 * Double(tableCap))
        tableMask = tableCap - 1
        itemsStart = alignForward(tableCap * 2, item.align)
        totalSize = itemsStart + cap * item.size
    }
}

@_spi(Test) public struct AllocLayout {
    public var totalSize: Int, bitmapCount: Int, bitmapStart = 0, chunksStart: Int
    init(_ bytes: Int, chunk: Int) {
        let chunks = alignForward(alignForward(bytes, chunk) / chunk, 64)
        (bitmapCount, chunksStart) = (chunks / 64, chunks / 64 * 8)
        totalSize = chunksStart + chunks * chunk
    }
}

@_spi(Test) public struct MapLayout {
    public var totalSize: Int, keysStart: Int, valsStart: Int, capacity: Int
    /// Ghostty's `layoutForSize`: room for n entries at `load` percent, power-of-two slots
    /// after a 16-byte header and one metadata byte per slot.
    init(_ n: Int, load: Int, key: (size: Int, align: Int), value: (size: Int, align: Int), align: Int) {
        capacity = n == 0 ? 0 : min(ceilPowerOfTwo((n * 100 + load - 1) / load), 1 << 31)
        let keys = alignForward(16 + capacity, key.align), vals = alignForward(keys + capacity * key.size, value.align)
        (keysStart, valsStart, totalSize) = (keys - 16, vals - 16, alignForward(vals + capacity * value.size, align))
    }
}

@_spi(Test) public struct Layout {
    public var totalSize = 0, rowsStart = 0, rowsSize = 0, cellsStart = 0, cellsSize = 0
    public var stylesStart = 0, stylesLayout: SetLayout
    public var graphemeAllocStart = 0, graphemeAllocLayout: AllocLayout
    public var graphemeMapStart = 0, graphemeMapLayout: MapLayout
    public var stringAllocStart = 0, stringAllocLayout: AllocLayout
    public var hyperlinkMapStart = 0, hyperlinkMapLayout: MapLayout
    public var hyperlinkSetStart = 0, hyperlinkSetLayout: SetLayout
    public var capacity: Capacity
}

/// Grapheme codepoints live in 16-byte chunks (4 x u21 stored as u32), strings in 32-byte chunks.
let graphemeChunk = 16, stringChunk = 32
/// Hyperlink map slots per hyperlink set item.
let hyperlinkCellMultiplier = 16

extension Page {
    @_spi(Test) public static func layout(_ cap: Capacity) -> Layout {
        let rowsSize = Int(cap.rows) * 8, cellsSize = Int(cap.cols) * Int(cap.rows) * 8
        let styles = SetLayout(Int(cap.styles), item: Zig.styles)
        let graphemeAlloc = AllocLayout(Int(cap.graphemeBytes), chunk: graphemeChunk)
        let graphemes = cap.graphemeBytes == 0 ? 0 : ceilPowerOfTwo((Int(cap.graphemeBytes) + graphemeChunk - 1) / graphemeChunk)
        let graphemeMap = MapLayout(graphemes, load: 100, key: Zig.graphemeMapKey, value: Zig.graphemeMapValue, align: Zig.graphemeMapAlign)
        let strings = AllocLayout(Int(cap.stringBytes), chunk: stringChunk)
        let links = Int(cap.hyperlinkBytes) / Zig.hyperlinkSet.size
        let linkSet = SetLayout(links, item: Zig.hyperlinkSet)
        let linkMap = MapLayout(min(links * hyperlinkCellMultiplier, Int(UInt32.max)), load: 80,
                                key: Zig.hyperlinkMapKey, value: Zig.hyperlinkMapValue, align: Zig.hyperlinkMapAlign)
        var l = Layout(stylesLayout: styles, graphemeAllocLayout: graphemeAlloc, graphemeMapLayout: graphemeMap,
                       stringAllocLayout: strings, hyperlinkMapLayout: linkMap, hyperlinkSetLayout: linkSet, capacity: cap)
        (l.rowsSize, l.cellsStart, l.cellsSize) = (rowsSize, rowsSize, cellsSize)
        l.stylesStart = alignForward(rowsSize + cellsSize, Zig.stylesAlign)
        l.graphemeAllocStart = alignForward(l.stylesStart + styles.totalSize, Zig.graphemeAllocAlign)
        l.graphemeMapStart = alignForward(l.graphemeAllocStart + graphemeAlloc.totalSize, Zig.graphemeMapAlign)
        l.stringAllocStart = alignForward(l.graphemeMapStart + graphemeMap.totalSize, Zig.stringAllocAlign)
        l.hyperlinkSetStart = alignForward(l.stringAllocStart + strings.totalSize, Zig.hyperlinkSetAlign)
        l.hyperlinkMapStart = alignForward(l.hyperlinkSetStart + linkSet.totalSize, Zig.hyperlinkMapAlign)
        l.totalSize = alignForward(l.hyperlinkMapStart + linkMap.totalSize, pageSizeMin)
        return l
    }

    /// Size of a standard page: the unit of the byte limit (Ghostty's `std_size`).
    static let stdSize = layout(Zig.stdCapacity).totalSize
}
