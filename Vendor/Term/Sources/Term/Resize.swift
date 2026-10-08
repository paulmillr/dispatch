// Resizing a page list (Ghostty's PageList.resize): columns with reflow
// (rows re-wrapped at the new width, tracked pins carried along), or
// without (cells cut or pages widened), and rows (grow or trim blank rows).

extension PageList {
    struct ResizeCursor { var x: Int, y: Int, pin: TrackedPin? }

    func resize(cols newCols: Int?, rows newRows: Int?, reflow: Bool, cursor: ResizeCursor?) {
        viewportPinRowOffset = nil
        guard reflow else {
            resizeWithoutReflow(cols: newCols, rows: newRows, reflow: false, cursor: cursor)
            return enforce(lines: true)
        }
        let c = newCols ?? cols
        (bytes.min, lines.min) = (PageList.minBytes(c, newRows ?? rows), Int(PageList.initialCapacity(c).rows))
        if c > cols {
            resizeCols(c, cursor)
            resizeWithoutReflow(cols: newCols, rows: newRows, reflow: true, cursor: cursor)
        } else if c < cols {
            resizeWithoutReflow(cols: cols, rows: newRows, reflow: true, cursor: cursor)
            resizeCols(c, cursor)
        } else {
            resizeWithoutReflow(cols: newCols, rows: newRows, reflow: true, cursor: cursor)
        }
        if viewport == .pin, isActive(viewportPin.pin) { viewport = .active }
        enforce(lines: true)
    }

    /// Rows that continue from above (wrap continuations) from `p` up to the active top.
    private func wrappedAbove(_ p: Pin, _ active: Pin?) -> Int {
        p.rows(down: false, to: active).filter { $0.row.wrapContinuation }.count
    }

    private func resizeCols(_ newCols: Int, _ cursor: ResizeCursor?) {
        var kept: (pin: TrackedPin, untrack: Bool, remaining: Int, wrapped: Int)?
        if let c = cursor, let p = c.pin?.pin ?? pin(.active, x: c.x, y: c.y) {
            let active = pin(.active)
            let wrapped = active.map { p.before($0) } == true ? 0 : wrappedAbove(p, active)
            kept = (c.pin ?? track(p), c.pin == nil, max(0, rows - (c.y + 1)), wrapped)
        }
        defer { if let k = kept, k.untrack { untrack(k.pin) } }
        cols = newCols
        let old = Array(Pin(page: first).rows(down: true, to: bottomRight(.screen)))   // the loop frees pages as it goes
        let start = createPage(first.capacity.resized(newCols, orRows: min(first.rows, Int(first.capacity.rows))))
        start.rows = 1
        (first, last) = (start, start)
        var r = Reflow(start)
        for row in old {
            r.reflow(self, row, kept?.pin)
            if row.y == row.page.rows - 1 { destroy(row.page) }
        }
        totalRows = r.totalRows
        var total = 0
        for page in sequence(first: first, next: { $0.next }) { total += page.rows; if total >= rows { break } }
        for _ in total..<max(total, rows) { grow() }
        if viewport == .pin, isActive(viewportPin.pin) { viewport = .active }
        if let k = kept, let at = point(.active, k.pin.pin) {
            let wrapped = wrappedAbove(k.pin.pin, pin(.active))
            let current = max(0, rows - (at.y + 1))
            for _ in 0..<max(0, max(0, k.remaining - max(0, wrapped - k.wrapped)) - current) { grow() }
        }
    }

    private func resizeWithoutReflow(cols newCols: Int?, rows newRows: Int?, reflow: Bool, cursor: ResizeCursor?) {
        if !reflow { (bytes.min, lines.min) = (PageList.minBytes(newCols ?? cols, newRows ?? rows), Int(PageList.initialCapacity(newCols ?? cols).rows)) }
        if let c = newCols, c < cols {
            for page in sequence(first: first, next: { $0.next }) {
                for y in 0..<page.rows { page.clearCells(y, c, cols) }
                page.cols = c
            }
            for t in tracked where t.pin.x >= c { t.pin.x = c - 1 }
            cols = c
        } else if let c = newCols, c > cols {
            let old = cols
            for page in Array(sequence(first: first, next: { $0.next })) { cols = old; growCols(c, page) }
            cols = c
        }
        guard let r = newRows else { return }
        if r < rows {
            totalRows -= trimTrailingBlankRows(rows - r)
            rows = r
        } else if r > rows {
            if let c = cursor, c.y < rows - 1 {
                let delta = r - rows
                rows = r
                for _ in 0..<delta { grow() }
                return
            }
            rows = r
            var count = 0
            for page in sequence(first: first, next: { $0.next }) { count += page.rows; if count >= r { break } }
            for _ in count..<max(count, r) { grow() }
            if viewport == .pin, isActive(viewportPin.pin) { viewport = .active }
        }
    }

    /// Widens one page: in place when its capacity allows (and no wide char is split at the old
    /// edge), else its rows move into the previous page's free rows and new wider pages.
    private func growCols(_ newCols: Int, _ page: Page) {
        let oldCols = cols
        cols = newCols
        if Int(page.capacity.cols) >= newCols, !(0..<page.rows).contains(where: { page.cell(page.cellAt($0, oldCols - 1)).wide == .spacerHead }) {
            page.cols = newCols
            return
        }
        let cap = page.capacity.resized(newCols, orRows: min(page.rows, Int(page.capacity.rows)))
        var copied = 0
        if let prev = page.prev, prev.rows < Int(prev.capacity.rows) {
            let len = min(Int(prev.capacity.rows) - prev.rows, page.rows)
            var failed = false
            for sy in 0..<len {
                prev.rows += 1
                do { try prev.cloneRow(from: page, sy, to: prev.rows - 1, 0, prev.cols) } catch { prev.rows -= 1; failed = true; break }
                copied += 1
            }
            if !failed {
                for t in pins(on: page) where t.pin.y < len { (t.pin.page, t.pin.y) = (prev, t.pin.y + prev.rows - len) }
            }
        }
        while copied < page.rows {
            let n = createPage(cap)
            let (start, len) = (copied, min(Int(cap.rows), page.rows - copied))
            for sy in start..<start + len {
                n.rows += 1
                do { try n.cloneRow(from: page, sy, to: n.rows - 1, 0, n.cols); copied += 1 } catch { n.rows -= 1; break }
            }
            insert(n, before: page)
            for t in pins(on: page) where t.pin.y >= start && t.pin.y < copied { (t.pin.page, t.pin.y) = (n, t.pin.y - start) }
        }
        remove(page)
        destroy(page)
    }

    /// Removes up to `max` blank rows from the bottom (stops at text or a tracked pin).
    private func trimTrailingBlankRows(_ max: Int) -> Int {
        var (trimmed, invalidated) = (0, nil as Page?)
        for row in bottomRight(.screen)!.rows(down: false) {
            if (0..<row.page.cols).contains(where: { row.page.cell(row.page.cellAt(row.y, $0)).hasText }) { return trimmed }
            if tracked.contains(where: { $0.pin.page === row.page && $0.pin.y == row.y }) { return trimmed }
            if row.page.rows > 1, invalidated !== row.page { invalidate(row.page); invalidated = row.page }
            row.page.resetRow(row.y)
            row.page.rows -= 1
            if row.page.rows == 0 { erase(page: row.page) }
            trimmed += 1
            if trimmed >= max { return trimmed }
        }
        return trimmed
    }
}

/// Writes source rows into new pages at another width (Ghostty's ReflowCursor).
struct Reflow {
    var x = 0, y = 0, pendingWrap = false, newRows = 0, totalRows: Int
    var page: Page
    var styleCache: (src: Page, from: Int, to: Int)?
    var capMemo: (src: Page, cap: Capacity)?

    init(_ page: Page) { (self.page, totalRows) = (page, page.rows) }

    var cell: Int { page.cellAt(y, x) }

    mutating func reflow(_ list: PageList, _ row: Pin, _ cursor: TrackedPin?) {
        let src = row.page, sy = row.y, srcRow = src.row(sy)
        var len = src.cols
        if !srcRow.wrap {
            while len > 0, src.cell(src.cellAt(sy, len - 1)).isEmpty { len -= 1 }
            if len == 0, srcRow.semanticPrompt != .none { len = 1 }
        }
        let pins = list.tracked.filter { $0.pin.page === src && $0.pin.y == sy }
        for p in pins where p !== cursor {
            if p.pin.x >= len { p.pin.x = min(p.pin.x, page.cols - 1 - x) }
            len = max(len, p.pin.x + 1)
        }
        if let c = cursor, c.pin.page === src, c.pin.y == sy { len = max(len, c.pin.x + 1) }
        if len == 0 {
            if !srcRow.wrapContinuation { newRows += 1 }
            return
        }
        let cap: Capacity
        if let m = capMemo, m.src === src { cap = m.cap } else {
            cap = src.capacity.resized(page.cols, orRows: min(src.rows, Int(Zig.stdCapacity.rows)))
            capMemo = (src, cap)
        }
        while newRows > 0 { scrollOrNewPage(list, cap); newRows -= 1 }
        // A destination row holding any marked text is marked (Row.marked).
        page.updateRow(y) { $0.semanticPrompt = srcRow.semanticPrompt; $0.marked = $0.marked || srcRow.marked }
        var sx = 0
        while sx < len {
            if pendingWrap {
                page.updateRow(y) { $0.wrap = true }
                scrollOrNewPage(list, cap)
                page.updateRow(y) { $0.semanticPrompt = srcRow.semanticPrompt; $0.wrapContinuation = true; $0.marked = $0.marked || srcRow.marked }
            }
            func movePins(_ at: Int) { for p in pins where p.pin.page === src && p.pin.y == sy && p.pin.x == at { (p.pin.page, p.pin.x, p.pin.y) = (page, x, y) } }
            movePins(sx)
            do {
                switch try write(list, src, src.cellAt(sy, sx)) {
                case .success: sx += 1
                case .skipNext: movePins(sx + 1); sx += 2
                case .repeat: break
                }
            } catch {
                if y == 0 { sx += 1; forward() } else { moveLastRowToNewPage(list, cap) }
            }
        }
        if !srcRow.wrap { newRows += 1 }
    }

    enum Written { case success, `repeat`, skipNext }

    /// Copies one source cell here, re-adding what it holds to this page.
    mutating func write(_ list: PageList, _ src: Page, _ at: Int) throws(OutOfSpace) -> Written {
        let c = src.cell(at)
        switch c.tag {
        case .codepoint, .codepointGrapheme:
            switch c.wide {
            case .narrow: page.setCell(cell, c)
            case .wide:
                if page.cols > 1 {
                    if x == page.cols - 1 {
                        var head = Cell()
                        head.wide = .spacerHead
                        page.setCell(cell, head)
                        forward()
                        return .repeat
                    }
                    page.setCell(cell, c)
                } else {
                    page.updateCell(cell) { ($0.content, $0.wide) = (0, .narrow) }
                    forward()
                    return .skipNext
                }
            case .spacerTail: if page.cols > 1 { page.setCell(cell, c) } else { return .success }
            case .spacerHead: return .success
            }
        case .bgColorPalette, .bgColorRGB:
            page.setCell(cell, c)
            forward()
            return .success
        }
        page.updateCell(cell) { ($0.tag, $0.hyperlink, $0.styleID) = (.codepoint, false, 0) }
        if c.hasGrapheme {
            let cps = src.grapheme(at)!
            if page.graphemeCount >= page.graphemeMap.capacity { try grow(list, .graphemeBytes) }
            while true {
                if let a = page.graphemeAlloc.alloc(page.memory, bytes: 4 * cps.count) { page.graphemeAlloc.free(page.memory, at: a, bytes: 4 * cps.count); break }
                try grow(list, .graphemeBytes)
            }
            do { try page.setGraphemes(y, cell, cps) } catch { page.updateCell(cell) { ($0.tag, $0.content) = (.codepoint, 0xFFFD) } }
        }
        if c.hyperlink, let id = src.hyperlink(at) {
            let link = src.link(id: id)
            if page.hyperlinkCount >= page.hyperlinkCapacity { try grow(list, .hyperlinkBytes) }
            while !stringsFit(link) { try grow(list, .stringBytes) }
            var dst: Int?
            if let e = try? page.entry(link) {
                do { dst = try page.hyperlinkSet.add(page.memory, e, id: id, LinkContext(page: page)) ?? id } catch {
                    page.free(e)
                    try grow(list, error == .outOfMemory ? .hyperlinkBytes : .rehash)
                    while !stringsFit(link) { try grow(list, .stringBytes) }
                    if let e2 = try? page.entry(link) {
                        do { dst = try page.hyperlinkSet.add(page.memory, e2, id: id, LinkContext(page: page)) ?? id } catch { page.free(e2) }
                    }
                }
            }
            if let dst {
                do { try page.setHyperlink(y, cell, dst) } catch { page.hyperlinkSet.release(page.memory, dst); page.updateCell(cell) { $0.hyperlink = false } }
            }
        }
        if c.hasStyling {
            if let s = styleCache, s.src === src, s.from == c.styleID {
                page.styles.use(page.memory, s.to)
                page.updateRow(y) { $0.styled = true }
                page.updateCell(cell) { $0.styleID = s.to }
            } else {
                let style = src.styles.get(src.memory, c.styleID)
                var id: Int?
                do { id = try page.styles.add(page.memory, style, id: c.styleID, StyleContext()) ?? c.styleID } catch {
                    try grow(list, error == .outOfMemory ? .styles : .rehash)
                    do { id = try page.styles.add(page.memory, style, id: c.styleID, StyleContext()) ?? c.styleID } catch { id = nil }
                }
                if let id {
                    styleCache = (src, c.styleID, id)
                    page.updateRow(y) { $0.styled = true }
                    page.updateCell(cell) { $0.styleID = id }
                } else { page.updateCell(cell) { $0.styleID = 0 } }
            }
        }
        forward()
        return .success
    }

    /// Whether the link's strings fit in this page's string allocator now.
    func stringsFit(_ l: Link) -> Bool {
        let a = page.stringAlloc
        guard let u = a.alloc(page.memory, bytes: l.uri.count) else { return false }
        defer { a.free(page.memory, at: u, bytes: l.uri.count) }
        guard case .explicit(let id) = l.id else { return true }
        guard let i = a.alloc(page.memory, bytes: id.count) else { return false }
        a.free(page.memory, at: i, bytes: id.count)
        return true
    }

    mutating func grow(_ list: PageList, _ g: Grow) throws(OutOfSpace) {
        let (ox, oy, total) = (x, y, totalRows)
        self = Reflow(try list.increaseCapacity(page, g))
        (x, y, totalRows) = (ox, oy, total)
    }

    mutating func forward() { if x == page.cols - 1 { pendingWrap = true } else { x += 1 } }

    mutating func scrollOrNewPage(_ list: PageList, _ cap: Capacity) {
        let total = totalRows + 1
        if y == Int(page.capacity.rows) - 1 { newPage(list, cap) } else {
            page.rows += 1
            (y, x, pendingWrap) = (y + 1, 0, false)
        }
        totalRows = total
    }

    mutating func newPage(_ list: PageList, _ cap: Capacity) {
        let rows = newRows
        let n = list.createPage(cap)
        n.rows = 1
        list.insert(n, after: page)
        self = Reflow(n)
        newRows = rows
    }

    /// The row being written moves to a fresh page when this one can't hold what it needs.
    mutating func moveLastRowToNewPage(_ list: PageList, _ cap: Capacity) {
        let (old, oldY, ox, total) = (page, y, x, totalRows)
        newPage(list, cap)
        (x, pendingWrap) = (ox, false)
        do { try page.cloneRow(from: old, oldY, to: 0, 0, page.cols) } catch { fatalError("unexpected copy row failure") }
        for t in list.tracked where t.pin.page === old && t.pin.y == old.rows - 1 { (t.pin.page, t.pin.y) = (page, 0) }
        old.resetRow(oldY)
        old.rows -= 1
        if old.rows == 0 { list.remove(old); list.destroy(old) }
        totalRows = total
    }
}

extension Capacity {
    /// Same bytes at `cols` columns; when not even one row fits, `cols` x `orRows` instead.
    func resized(_ cols: Int, orRows: Int) -> Capacity {
        if let c = adjust(cols: UInt16(cols)) { return c }
        var c = self
        (c.cols, c.rows) = (UInt16(cols), UInt16(orRows))
        return c
    }
}
