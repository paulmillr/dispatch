// The ordered pages of one screen: scrollback + active area (Ghostty's
// PageList.zig): growth and pruning at the byte/line limits, tracked pins,
// the viewport, row erasing.

/// A position: row y (and column x) of a page. Pages own nothing through pins.
public struct Pin: Equatable {
    public var page: Page
    public var y = 0, x = 0
    var garbage = false

    public static func == (a: Pin, b: Pin) -> Bool { a.page === b.page && a.y == b.y && a.x == b.x }

    public var row: Row { page.row(y) }
    func markDirty() { page.updateRow(y) { $0.dirty = true } }
    public var cell: Int { page.cellAt(y, x) }

    public func up(_ n: Int) -> Pin? { if case .offset(let p) = upOverflow(n) { return p }; return nil }
    public func down(_ n: Int) -> Pin? { if case .offset(let p) = downOverflow(n) { return p }; return nil }

    enum Move { case offset(Pin), overflow(end: Pin, remaining: Int) }

    func downOverflow(_ n: Int) -> Move {
        if n <= page.rows - (y + 1) { return .offset(Pin(page: page, y: y + n, x: x)) }
        var (p, left) = (page, n - (page.rows - (y + 1)))
        while true {
            guard let next = p.next else { return .overflow(end: Pin(page: p, y: p.rows - 1, x: min(x, p.cols - 1)), remaining: left) }
            p = next
            if left <= p.rows { return .offset(Pin(page: p, y: left - 1, x: min(x, p.cols - 1))) }
            left -= p.rows
        }
    }

    func upOverflow(_ n: Int) -> Move {
        if n <= y { return .offset(Pin(page: page, y: y - n, x: x)) }
        var (p, left) = (page, n - y)
        while true {
            guard let prev = p.prev else { return .overflow(end: Pin(page: p, y: 0, x: min(x, p.cols - 1)), remaining: left) }
            p = prev
            if left <= p.rows { return .offset(Pin(page: p, y: p.rows - left, x: min(x, p.cols - 1))) }
            left -= p.rows
        }
    }

    public func before(_ o: Pin) -> Bool {
        if page === o.page { return y < o.y || y == o.y && x < o.x }
        var p = page.next
        while let n = p { if n === o.page { return true }; p = n.next }
        return false
    }

    /// Row ranges from this pin to `limit` (inclusive), page by page, downwards or upwards.
    func chunks(down: Bool, to limit: Pin? = nil) -> [(page: Page, rows: Range<Int>)] {
        var out: [(page: Page, rows: Range<Int>)] = []
        var at: Pin? = self
        while let p = at {
            if let l = limit, l.page === p.page {
                if down ? p.y <= l.y : p.y >= l.y { out.append((p.page, down ? p.y..<l.y + 1 : l.y..<p.y + 1)) }
                break
            }
            out.append((p.page, down ? p.y..<p.page.rows : 0..<p.y + 1))
            at = down ? p.page.next.map { Pin(page: $0) } : p.page.prev.map { Pin(page: $0, y: $0.rows - 1) }
        }
        return out
    }

    /// Every row from this pin to `limit`, in order (lazily: from a row near the edge of a big
    /// scrollback, callers usually stop after a few).
    func rows(down: Bool, to limit: Pin? = nil) -> some Sequence<Pin> {
        chunks(down: down, to: limit).lazy.flatMap { c in (down ? Array(c.rows) : c.rows.reversed()).lazy.map { Pin(page: c.page, y: $0) } }
    }
}

/// A pin the list keeps valid while pages change (cursor, viewport, saved cursor).
/// Where page lists get standard page blocks their own pool lacks, and give theirs back when
/// they end: a host shares them across terminals (a closed terminal's scrollback warms the next);
/// nil: every list allocates and frees its own. Blocks are `pageBlockBytes` long; a list formats
/// a block before use, so a block never shows a previous page's content.
public protocol PageBlocks: AnyObject {
    /// A block to reuse, or nil.
    func take() -> UnsafeMutableRawPointer?
    /// Keeps an ended list's block; false: the list frees it.
    func give(_ block: UnsafeMutableRawPointer) -> Bool
}

/// The size of a standard page block (what PageBlocks hold).
public let pageBlockBytes = Page.stdSize + Page.stateBytes

/// How many standard pages a scrollback limit of `bytes` holds at most (the limit counts each as
/// one standard page; the block's state bytes don't count).
public func pageBlocks(scrollbackBytes bytes: Int) -> Int { bytes / Page.stdSize }

/// A handle the list allocates in track() and frees in untrack() or with the list (no reference
/// counting, like pages).
public struct TrackedPin {
    let p: UnsafeMutablePointer<Pin>
    init(_ pin: Pin) { p = .allocate(capacity: 1); p.initialize(to: pin) }
    public internal(set) var pin: Pin { get { p.pointee } nonmutating set { p.pointee = newValue } }
    func free() { p.deinitialize(count: 1); p.deallocate() }
}

func === (a: TrackedPin?, b: TrackedPin?) -> Bool { a?.p == b?.p }
func !== (a: TrackedPin?, b: TrackedPin?) -> Bool { a?.p != b?.p }

public enum PointTag { case active, viewport, screen, history }

/// The page list as a handle to its state, like Page and Screen: its screen creates and frees it,
/// so using it costs no retain/release. Fields are read and changed in place.
struct PageList {
    enum Viewport { case active, top, pin }
    struct Limit { var explicit = Int.max; var min: Int; var max: Int { Swift.max(explicit, min) } }   // two declarations: a shared one breaks non-WMO builds
    struct State {
        var first: Page, last: Page
        var cols: Int, rows: Int
        var serial: Int
        /// Bytes counted against the byte limit.
        var pageSize: Int
        var bytes: Limit, lines: Limit
        var totalRows: Int
        var tracked: [TrackedPin]
        var pool = Pool()
        var viewport = Viewport.active
        let viewportPin: TrackedPin
        var viewportPinRowOffset: Int? = nil
    }
    let state: UnsafeMutablePointer<State>

    var first: Page { _read { yield state.pointee.first } nonmutating _modify { yield &state.pointee.first } }
    var last: Page { _read { yield state.pointee.last } nonmutating _modify { yield &state.pointee.last } }
    var cols: Int { _read { yield state.pointee.cols } nonmutating _modify { yield &state.pointee.cols } }
    var rows: Int { _read { yield state.pointee.rows } nonmutating _modify { yield &state.pointee.rows } }
    var serial: Int { _read { yield state.pointee.serial } nonmutating _modify { yield &state.pointee.serial } }
    var pageSize: Int { _read { yield state.pointee.pageSize } nonmutating _modify { yield &state.pointee.pageSize } }
    var bytes: Limit { _read { yield state.pointee.bytes } nonmutating _modify { yield &state.pointee.bytes } }
    var lines: Limit { _read { yield state.pointee.lines } nonmutating _modify { yield &state.pointee.lines } }
    var totalRows: Int { _read { yield state.pointee.totalRows } nonmutating _modify { yield &state.pointee.totalRows } }
    var tracked: [TrackedPin] { _read { yield state.pointee.tracked } nonmutating _modify { yield &state.pointee.tracked } }
    var pool: Pool { _read { yield state.pointee.pool } nonmutating _modify { yield &state.pointee.pool } }

    /// Freed page headers, standard page blocks and tracked pins, kept for reuse last-freed first
    /// (Ghostty's node, page and pin pools): they only grow, to the most the list ever needed at
    /// once. Headers are the pages' identities, so a reused one compares equal like a reused node.
    struct Pool {
        var nodes: [Page] = [], blocks: [UnsafeMutableRawPointer] = [], pins: [TrackedPin] = []
        /// Where standard blocks come from when `blocks` runs out, and go when the list ends.
        var source: PageBlocks?

        mutating func page(_ cap: Capacity) -> Page {
            let pooled = Page.layout(cap).totalSize <= Page.stdSize
            let p = Page(cap, node: nodes.popLast(), block: pooled ? blocks.popLast() ?? source?.take() : nil)
            p.pooled = pooled
            return p
        }

        mutating func recycle(_ p: Page) {
            if p.pooled { blocks.append(p.memory) } else { p.memory.deallocate() }
            nodes.append(p)
        }
    }
    var viewport: Viewport { _read { yield state.pointee.viewport } nonmutating _modify { yield &state.pointee.viewport } }
    var viewportPin: TrackedPin { state.pointee.viewportPin }
    var viewportPinRowOffset: Int? { _read { yield state.pointee.viewportPinRowOffset } nonmutating _modify { yield &state.pointee.viewportPinRowOffset } }

    init(cols: Int, rows: Int, maxBytes: Int?, maxLines: Int?, blocks: PageBlocks? = nil) {
        var pool = Pool(source: blocks)
        let (first, last, pageSize, serial) = PageList.pages(cols, rows, 0, &pool)
        let viewportPin = TrackedPin(Pin(page: first))
        var (bytes, lines) = (Limit(min: PageList.minBytes(cols, rows)), Limit(min: PageList.initialCapacity(cols).rows.int))
        (bytes.explicit, lines.explicit) = (maxBytes ?? Int.max, maxLines ?? Int.max)
        state = .allocate(capacity: 1)
        state.initialize(to: State(first: first, last: last, cols: cols, rows: rows, serial: serial, pageSize: pageSize, bytes: bytes, lines: lines,
                                   totalRows: rows, tracked: [viewportPin], pool: pool, viewportPin: viewportPin))
    }

    /// Enough standard pages for the active area (from `pool` first): (first, last, counted bytes, next serial).
    private static func pages(_ cols: Int, _ rows: Int, _ start: Int, _ pool: inout Pool) -> (Page, Page, Int, Int) {
        let cap = PageList.initialCapacity(cols)
        var (rem, pages, serial) = (rows, [Page](), start)
        while rem > 0 {
            let p = pool.page(cap)
            (p.serial, p.rows) = (serial, min(rem, Int(cap.rows)))
            serial += 1
            rem -= p.rows
            if let l = pages.last { l.next = p; p.prev = l }
            pages.append(p)
        }
        return (pages.first!, pages.last!, pages.reduce(0) { $0 + $1.accountedSize }, serial)
    }

    static func initialCapacity(_ cols: Int) -> Capacity { Zig.stdCapacity.resized(cols, orRows: Int(Zig.stdCapacity.rows)) }

    static func minBytes(_ cols: Int, _ rows: Int) -> Int {
        let cap = Int(initialCapacity(cols).rows)
        return Page.stdSize * ((cap >= rows ? 1 : (rows + cap - 1) / cap) + 1)
    }

    func free() {
        freeAll()
        for p in pool.nodes { p.freeNode() }
        for b in pool.blocks where pool.source?.give(b) != true { b.deallocate() }
        for t in tracked + pool.pins { t.free() }
        state.deinitialize(count: 1)
        state.deallocate()
    }

    private func freeAll() {
        var p: Page? = first
        while let page = p { p = page.next; pool.recycle(page) }
    }

    func reset() {
        freeAll()
        (first, last, pageSize, serial) = PageList.pages(cols, rows, serial, &pool)
        totalRows = rows
        for t in tracked { t.pin = Pin(page: first, garbage: true) }
        viewportPin.pin.garbage = false
        viewport = .active
    }

    // Pages in the list.

    func append(_ p: Page) { p.prev = last; last.next = p; last = p }
    func insert(_ p: Page, after a: Page) { if a === last { return append(p) }; (p.next, p.prev) = (a.next, a); a.next?.prev = p; a.next = p }
    func insert(_ p: Page, before b: Page) { if let a = b.prev { insert(p, after: a) } else { (p.next, first, b.prev) = (b, p, p) } }
    func remove(_ p: Page) {
        if p === first { first = p.next! } else { p.prev!.next = p.next }
        if p === last { last = p.prev! } else { p.next!.prev = p.prev }
        (p.next, p.prev) = (nil, nil)
    }

    func createPage(_ cap: Capacity) -> Page {
        let p = pool.page(cap)
        p.serial = serial
        serial += 1
        pageSize += p.accountedSize
        return p
    }

    /// Takes a page out of the byte count and frees it, standard pages into the pool (it must be out of the list).
    func destroy(_ p: Page) {
        pageSize -= p.accountedSize
        pool.recycle(p)
    }

    func invalidate(_ p: Page) { p.serial = serial; serial += 1 }

    func pins(on p: Page) -> LazyFilterSequence<[TrackedPin]> { tracked.lazy.filter { $0.pin.page === p } }

    func track(_ p: Pin) -> TrackedPin {
        let t = pool.pins.popLast() ?? TrackedPin(p)
        t.pin = p
        tracked.append(t)
        return t
    }
    func untrack(_ t: TrackedPin) { tracked.removeAll { $0 === t }; pool.pins.append(t) }

    // Positions.

    func topLeft(_ tag: PointTag) -> Pin {
        switch tag {
        case .screen, .history: return Pin(page: first)
        case .viewport: return viewport == .active ? topLeft(.active) : viewport == .top ? topLeft(.screen) : viewportPin.pin
        case .active:
            var (rem, p) = (rows, last)
            while rem > p.rows { rem -= p.rows; p = p.prev! }
            return Pin(page: p, y: p.rows - rem)
        }
    }

    func bottomRight(_ tag: PointTag) -> Pin? {
        switch tag {
        case .screen, .active: return Pin(page: last, y: last.rows - 1, x: last.cols - 1)
        case .viewport: var br = topLeft(.viewport).down(rows - 1)!; br.x = br.page.cols - 1; return br
        case .history: guard var br = topLeft(.active).up(1) else { return nil }; br.x = br.page.cols - 1; return br
        }
    }

    func pin(_ tag: PointTag, x: Int = 0, y: Int = 0) -> Pin? {
        guard x < cols, var p = topLeft(tag).down(y), x < p.page.cols else { return nil }
        p.x = x
        return p
    }

    /// (x, y) of a pin relative to the top left of `tag`, nil when above it.
    func point(_ tag: PointTag, _ p: Pin) -> (x: Int, y: Int)? {
        let tl = topLeft(tag)
        if p.page === tl.page { return tl.y > p.y ? nil : (p.x, p.y - tl.y) }
        var (y, n) = (tl.page.rows - tl.y, tl.page.next)
        while let page = n {
            if page === p.page { return (p.x, y + p.y) }
            y += page.rows
            n = page.next
        }
        return nil
    }

    func isActive(_ p: Pin) -> Bool {
        let a = topLeft(.active)
        if p.page === a.page { return p.y >= a.y }
        var n = a.page.next
        while let page = n { if page === p.page { return true }; n = page.next }
        return false
    }

    func isTop(_ p: Pin) -> Bool { p.y == 0 && p.page === first }

    // Growth and limits.

    /// One more row at the bottom: in the last page, a new page, or the pruned first page.
    @discardableResult func grow() -> Page? {
        if last.capacity.rows.int > last.rows {
            last.rows += 1
            totalRows += 1
            enforce(lines: true)
            return nil
        }
        let cap = PageList.initialCapacity(cols)
        if first !== last, pageSize + Page.stdSize > bytes.max {
            let old = first
            remove(old)
            totalRows -= old.rows
            if totalRows + 1 < rows {
                insert(old, before: first)
                totalRows += old.rows
            } else {
                if viewport == .pin, let v = viewportPinRowOffset {
                    if v < old.rows { viewport = .top } else { viewportPinRowOffset = v - old.rows }
                }
                for t in tracked where t.pin.page === old { t.pin = Pin(page: first, garbage: true) }
                viewportPin.pin.garbage = false
                if old.pooled {
                    // Ghostty reuses the pruned page's memory for the new last page: same accounting.
                    let p = Page(cap, node: old, block: old.memory)
                    (p.serial, p.rows) = (serial, 1)
                    serial += 1
                    append(p)
                    totalRows += 1
                    enforce(lines: true)
                    return p
                }
                destroy(old)
            }
        }
        let p = createPage(cap)
        append(p)
        p.rows = 1
        totalRows += 1
        enforce(lines: true)
        return p
    }

    func exceeded(lines: Bool) -> Bool {
        lines ? totalRows > rows && totalRows - rows > self.lines.max : pageSize > bytes.max
    }

    /// Drops whole pages from the top while a limit is exceeded (never into the active area).
    func enforce(lines: Bool) {
        guard exceeded(lines: lines), totalRows > rows else { return }
        var removed = 0
        while exceeded(lines: lines) {
            let old = first
            if old === topLeft(.active).page { break }
            for t in tracked where t.pin.page === old { t.pin.garbage = true }
            totalRows -= old.rows
            removed += old.rows
            erase(page: old)
        }
        if removed > 0 { fixupViewport(removed) }
    }

    func erase(page p: Page) {
        for t in tracked where t.pin.page === p { t.pin = Pin(page: p.prev ?? p.next!, garbage: t.pin.garbage) }
        remove(p)
        destroy(p)
    }

    func fixupViewport(_ removed: Int) {
        viewportPin.pin.garbage = false
        switch viewport {
        case .active: break
        case .pin:
            if isActive(viewportPin.pin) { viewport = .active } else if let v = viewportPinRowOffset {
                if v < removed { viewport = .top } else { viewportPinRowOffset = v - removed }
            }
        case .top: if isActive(Pin(page: first)) { viewport = .active }
        }
    }

    /// A page like `p` with one capacity doubled (or rebuilt as is), replacing it.
    func increaseCapacity(_ p: Page, _ grow: Grow) throws(OutOfSpace) -> Page {
        var cap = p.capacity
        if grow != .rehash {
            let old = cap.value(grow), def = Zig.defaultCapacity.value(grow)
            let new = old == 0 ? def : old * 2 <= cap.max(grow) ? old * 2 : old < cap.max(grow) ? cap.max(grow) : -1
            if new < 0 { throw OutOfSpace() }
            cap.set(grow, new)
            if Page.layout(cap).totalSize > Int(UInt32.max) { throw OutOfSpace() }
            let used = grow == .graphemeBytes ? p.graphemeAlloc.usedBytes(p.memory) : grow == .styles ? p.styles.living : 0
            if used > 0, p.rows > 0 {
                let density = used * Int(cap.rows) / p.rows
                let projected = min(density + density / 4, old * 32, cap.max(grow))
                var proj = cap
                proj.set(grow, projected)
                if projected > cap.value(grow), Page.layout(proj).totalSize <= Int(UInt32.max) { cap = proj }
            }
        }
        let n = createPage(cap)
        (n.rows, n.cols) = (p.rows, p.cols)
        do { try n.clone(from: p, 0, p.rows) } catch { fatalError("unexpected clone failure") }
        n.dirty = p.dirty
        for t in pins(on: p) { t.pin.page = n }
        insert(n, before: p)
        remove(p)
        destroy(p)
        return n
    }

    // Viewport.

    enum Scroll { case active, top, row(Int), delta(Int), pin(Pin) }

    func scroll(_ s: Scroll) {
        if bytes.explicit == 0 { viewport = .active; return }
        switch s {
        case .active: viewport = .active
        case .top: viewport = .top
        case .pin(let p): setViewport(p)
        case .row(let n):
            if n == 0 { viewport = .top; return }
            if n >= totalRows - rows { viewport = .active; return }
            if viewport == .pin, let v = viewportPinRowOffset { return scroll(.delta(n - v)) }
            viewportPinRowOffset = n
            viewport = .pin
            if let p = (n < totalRows / 2 ? Pin(page: first).down(n) : Pin(page: last, y: last.rows - 1).up(totalRows - n - 1)) {
                viewportPin.pin = p
            } else { viewport = .active }
        case .delta(let n):
            if n == 0 || viewport == .top && n < 0 || viewport == .active && n > 0 { return }
            if viewport == .pin {
                switch n < 0 ? viewportPin.pin.upOverflow(-n) : viewportPin.pin.downOverflow(n) {
                case .offset(let p):
                    if n > 0, isActive(p) { viewport = .active; return }
                    viewportPin.pin = p
                    viewportPinRowOffset = viewportPinRowOffset.map { $0 + n }
                case .overflow: viewport = n < 0 ? .top : .active
                }
                return
            }
            let top = topLeft(.viewport)
            switch n < 0 ? top.upOverflow(-n) : top.downOverflow(n) {
            case .offset(let p), .overflow(let p, _): setViewport(p)
            }
        }
    }

    private func setViewport(_ p: Pin) {
        if isActive(p) { viewport = .active } else if isTop(p) { viewport = .top } else {
            viewportPin.pin = p
            viewport = .pin
            viewportPinRowOffset = nil
        }
    }

    var scrollbar: Scrollbar {
        bytes.explicit == 0 ? Scrollbar(total: rows, offset: 0, len: rows) : Scrollbar(total: totalRows, offset: viewportRowOffset, len: rows)
    }

    var viewportRowOffset: Int {
        switch viewport {
        case .top: return 0
        case .active: return totalRows - rows
        case .pin:
            if let v = viewportPinRowOffset { return v }
            var (offset, p) = (0, Optional(last))
            while let page = p {
                offset += page.rows
                if page === viewportPin.pin.page { break }
                p = page.prev
            }
            viewportPinRowOffset = totalRows - (offset - viewportPin.pin.y)
            return viewportPinRowOffset!
        }
    }

    /// Grows until every non-empty row of the active area is in history (clear screen, keep text).
    func scrollClear() {
        var (n, count) = (0, 0)
        search: for page in sequence(first: last, next: { $0.prev }) {
            for y in (0..<page.rows).reversed() {
                if (0..<cols).contains(where: { !page.cell(page.cellAt(y, $0)).isEmpty }) { count = rows - n; break search }
                n += 1
                if n > rows { break search }
            }
        }
        for _ in 0..<count { grow() }
    }

    // Erasing rows.

    /// Removes row y of `p` by rotating it to the end and pulling the first row of each
    /// following page up (Ghostty's eraseRow, `limit` nil) or at most `limit` rows below
    /// it (eraseRowBounded); the freed row is cleared.
    func eraseRow(_ at: Pin, limit: Int? = nil) {
        var (page, y, shifted) = (at.page, at.y, 0)
        func adjustViewport(_ inRange: (Pin) -> Bool) {
            if viewport == .pin, let v = viewportPinRowOffset, inRange(viewportPin.pin) { viewportPinRowOffset = v - 1 }
        }
        invalidate(page)
        if let limit, page.rows - y > limit {
            page.resetRow(y)
            page.rotateUp(y..<y + limit + 1)
            page.dirty = true
            adjustViewport { $0.page === page && $0.y >= y && $0.y <= y + limit && $0.y != 0 }
            for t in pins(on: page) where t.pin.y >= y && t.pin.y <= y + limit { if t.pin.y == 0 { t.pin.x = 0 } else { t.pin.y -= 1 } }
            return
        }
        page.rotateUp(y..<page.rows)
        page.dirty = true
        if limit == nil {
            for t in pins(on: page) where t.pin.y > y { t.pin.y -= 1 }
            fixupViewport(1)
        } else {
            shifted = page.rows - y
            adjustViewport { $0.page === page && $0.y >= y && $0.y != 0 }
            for t in pins(on: page) where t.pin.y >= y { if t.pin.y == 0 { t.pin.x = 0 } else { t.pin.y -= 1 } }
        }
        while let next = page.next {
            _ = cloneRowGrowing(page, page.rows - 1, next, 0)
            (page, y) = (next, 0)
            if let limit, page.rows > limit - shifted {
                let bound = limit - shifted
                invalidate(page)
                page.resetRow(0)
                page.rotateUp(0..<bound + 1)
                page.dirty = true
                adjustViewport { $0.page === page && $0.y <= bound }
                for t in pins(on: page) where t.pin.y <= bound { moveUpAcrossPages(t) }
                return
            }
            invalidate(page)
            page.rotateUp(0..<page.rows)
            page.dirty = true
            shifted += page.rows
            if limit != nil { adjustViewport { $0.page === page } }
            for t in pins(on: page) { moveUpAcrossPages(t) }
        }
        page.resetRow(page.rows - 1)
    }

    private func moveUpAcrossPages(_ t: TrackedPin) {
        if t.pin.y == 0 { t.pin.page = t.pin.page.prev!; t.pin.y = t.pin.page.rows - 1 } else { t.pin.y -= 1 }
    }

    /// Clones row sy of `src` into row dy of `page`, growing `page` (with `grow`) until it fits.
    func cloneRowGrowing(_ page: Page, _ dy: Int, _ src: Page, _ sy: Int, _ x0: Int = 0, _ x1: Int? = nil,
                         grow: ((Page, Grow) throws(OutOfSpace) -> Page)? = nil) -> Page {
        var cur = page
        while true {
            do { try cur.cloneRow(from: src, sy, to: dy, x0, x1 ?? cur.cols); return cur } catch {
                do { cur = try grow?(cur, error) ?? increaseCapacity(cur, error) } catch { fatalError("increaseCapacity OutOfSpace") }
            }
        }
    }

    /// Erases all history rows (pages above the active area; the active area's page keeps its active rows).
    func eraseHistory() {
        var erased = 0
        guard let bottom = bottomRight(.history) else { return }
        for (page, r) in topLeft(.history).chunks(down: true, to: bottom) {
            if r.lowerBound == 0, r.upperBound == page.rows {
                if page.next == nil, page.prev == nil {
                    invalidate(page)
                    erased += page.rows
                    page.reinit()
                    page.rows = 0
                    break
                }
                erased += page.rows
                erase(page: page)
                continue
            }
            invalidate(page)
            let keep = page.rows - r.upperBound
            for i in 0..<keep { page.swapRows(i, i + r.upperBound); page.updateRow(i) { $0.dirty = true } }
            for i in keep..<page.rows { page.resetRow(i) }
            for t in pins(on: page) { if t.pin.y >= r.upperBound { t.pin.y -= r.upperBound } else { (t.pin.y, t.pin.x) = (0, 0) } }
            page.rows = keep
            erased += r.upperBound
        }
        totalRows -= erased
        fixupViewport(erased)
    }

    /// Splits `p.page` at row p.y: rows from there move to a new page after it.
    func split(_ p: Pin) throws(OutOfSpace) {
        let page = p.page
        if page.rows <= 1 { throw OutOfSpace() }
        if p.y == 0 { return }
        let target = createPage(page.capacity)
        target.rows = page.rows - p.y
        do { try target.clone(from: page, p.y, page.rows) } catch { destroy(target); throw OutOfSpace() }
        invalidate(page)
        for t in pins(on: page) where t.pin.y >= p.y { (t.pin.page, t.pin.y) = (target, t.pin.y - p.y) }
        for y in p.y..<page.rows { page.resetRow(y) }
        page.rows = p.y
        insert(target, after: page)
    }
}

struct OutOfSpace: Error {}

/// The scrollbar as the app sees it: rows in total, the viewport's first row, rows shown.
public struct Scrollbar: Equatable { public var total: Int, offset: Int, len: Int }

extension UInt16 { var int: Int { Int(self) } }

extension Capacity {
    /// The growable capacity fields by name.
    func value(_ g: Grow) -> Int {
        switch g { case .styles: styles.int; case .graphemeBytes: Int(graphemeBytes); case .hyperlinkBytes: hyperlinkBytes.int; case .stringBytes: Int(stringBytes); case .rehash: 0 }
    }
    func max(_ g: Grow) -> Int { g == .graphemeBytes || g == .stringBytes ? Int(UInt32.max) : Int(UInt16.max) }
    mutating func set(_ g: Grow, _ v: Int) {
        switch g {
        case .styles: styles = UInt16(v)
        case .graphemeBytes: graphemeBytes = UInt32(v)
        case .hyperlinkBytes: hyperlinkBytes = UInt16(v)
        case .stringBytes: stringBytes = UInt32(v)
        case .rehash: break
        }
    }
}
