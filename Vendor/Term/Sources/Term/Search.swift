// Search (Ghostty's terminal/search/): every occurrence of a needle in a screen's plain text,
// ASCII case-insensitive, kept per screen while output continues: the active area is searched
// again on every refresh, recent history results are found once, the selected match follows its
// text. Ghostty spreads the work over a thread; here each bounded step runs to completion.

/// A match: the pages it spans with their rows (first row, row after the last), and the columns
/// of its first and last cell (Ghostty's highlight.Flattened). Blank cells map back from the text
/// after them, so a match can end before it starts: rows are plain numbers, not a Range.
public struct Match {
    var chunks: [(page: Page, serial: Int, start: Int, end: Int)]
    var topX: Int, botX: Int

    init(chunks: [(page: Page, serial: Int, start: Int, end: Int)], topX: Int, botX: Int) { (self.chunks, self.topX, self.botX) = (chunks, topX, botX) }

    public var start: Pin { Pin(page: chunks[0].page, y: chunks[0].start, x: topX) }
    public var end: Pin { Pin(page: chunks[chunks.count - 1].page, y: chunks[chunks.count - 1].end - 1, x: botX) }
}

/// Page texts in the order they were added and where each ends (Ghostty's SlidingWindow, whole
/// instead of streamed: it finds the same occurrences in the same order). The cells of a page's
/// bytes are only mapped when a match starts or ends on it.
struct SearchWindow {
    static let maxTextBytes = 16 * 1024 * 1024, maxNeedleBytes = 64 * 1024, maxMatches = 10_000
    var text: [UInt8] = [], pages: [(page: Page, end: Int)] = []
    var isFull: Bool { text.count >= Self.maxTextBytes }

    /// A page's text and a newline unless its last row wraps; with a map, the cell of every byte.
    static func format(_ page: Page, _ out: inout [UInt8], _ map: inout [(x: Int, y: Int)]?) {
        var blanks = (rows: 0, cells: 0)
        page.format(0, page.rows - 1, x0: 0, x1: page.cols - 1, rectangle: false, trim: true, &blanks, &out, &map)
        if !page.row(page.rows - 1).wrap { out.append(0x0A); if let last = map.map({ $0.last ?? (0, 0) }) { map!.append(last) } }
    }

    /// Adds a page's text (pages without text are left out); returns its length.
    @discardableResult mutating func append(_ page: Page) -> Int {
        guard !isFull else { return 0 }
        var (chunk, map) = ([UInt8](), nil as [(x: Int, y: Int)]?)
        Self.format(page, &chunk, &map)
        guard !chunk.isEmpty, chunk.count <= Self.maxTextBytes - text.count else { return 0 }
        text += chunk
        pages.append((page, text.count))
        return chunk.count
    }

    /// Up to the result limit, including overlaps, ASCII case-insensitive and in text order.
    /// KMP keeps repeated input such as millions of `a`s linear in the text and needle sizes.
    func matches(_ needle: [UInt8]) -> [Match] {
        let lower = { (b: UInt8) in b &- 0x41 < 26 ? b | 0x20 : b }, n = needle.map(lower)
        guard !n.isEmpty, n.count <= Self.maxNeedleBytes, n.count <= text.count else { return [] }
        var prefix = [Int](repeating: 0, count: n.count)
        if n.count > 1 {
            var matched = 0
            for i in 1..<n.count {
                while matched > 0, n[i] != n[matched] { matched = prefix[matched - 1] }
                if n[i] == n[matched] { matched += 1 }
                prefix[i] = matched
            }
        }
        var found: [Int] = []
        found.reserveCapacity(min(Self.maxMatches, 1024))
        var matched = 0
        for (i, byte) in text.enumerated() {
            let byte = lower(byte)
            while matched > 0, byte != n[matched] { matched = prefix[matched - 1] }
            if byte == n[matched] { matched += 1 }
            if matched == n.count {
                found.append(i + 1 - n.count)
                if found.count >= Self.maxMatches { break }
                matched = prefix[matched - 1]
            }
        }
        var (maps, k) = ([[(x: Int, y: Int)]?](repeating: nil, count: pages.count), 0)
        func cell(_ i: Int) -> (page: Int, x: Int, y: Int) {
            let p = pages[k...].firstIndex { $0.end > i }!
            if maps[p] == nil { var (t, m) = ([UInt8](), [] as [(x: Int, y: Int)]?); Self.format(pages[p].page, &t, &m); maps[p] = m }
            let c = maps[p]![i - (p == 0 ? 0 : pages[p - 1].end)]
            return (p, c.x, c.y)
        }
        return found.map { i in
            let a = cell(i)
            k = a.page
            let b = cell(i + n.count - 1)
            return Match(chunks: (a.page...b.page).map { p in
                (pages[p].page, pages[p].page.serial, p == a.page ? a.y : 0, p == b.page ? b.y + 1 : pages[p].page.rows)
            }, topX: a.x, botX: b.x)
        }
    }
}

extension PageList {
    /// The pages in the list with their serials: a page that is gone, or a new one at its address, doesn't match.
    var live: [UnsafeMutablePointer<Page.Header>: Int] {
        Dictionary(uniqueKeysWithValues: sequence(first: first, next: { $0.next }).map { ($0.header, $0.serial) })
    }
}

/// One screen's search (Ghostty's ScreenSearch).
struct ScreenSearch {
    enum State { case active, history, historyFeed, complete }
    let screen: Screen, needle: [UInt8]
    var rows: Int, cols: Int
    var state = State.active
    /// Active results in text order, history results newest first.
    var active: [Match] = [], history: [Match] = []
    /// The history search (Ghostty's HistorySearch + PageListSearch): history ends at `start` (the
    /// active window's first page); `top` is the last cell of the topmost page searched (tracked in
    /// Ghostty too, so trimming keeps that row); `searched` once the pages above are.
    struct History { let start: TrackedPin, top: TrackedPin; var searched = false }
    var past: History?
    /// Index from the newest match, and where it is (tracked, so it follows its text).
    var selected: (idx: Int, start: TrackedPin, end: TrackedPin)?

    init(_ screen: Screen, _ needle: [UInt8]) {
        (self.screen, self.needle, rows, cols) = (screen, needle, screen.pages.rows, screen.pages.cols)
        reloadActive()
    }

    /// Releases the tracked pins (only while the screen lives: its pins die with it).
    func free() {
        [past?.start, past?.top, selected?.start, selected?.end].compactMap { $0 }.forEach(screen.pages.untrack)
    }

    var count: Int { active.count + history.count }

    /// Match `idx` from the newest.
    func match(_ idx: Int) -> Match? { idx < active.count ? active[active.count - 1 - idx] : idx < count ? history[idx - active.count] : nil }

    /// Newest first.
    var matches: [Match] { active.reversed() + history }

    /// A resize can replace every page: start over (the new search has loaded its active area).
    mutating func resetIfResized() -> Bool {
        guard screen.pages.rows != rows || screen.pages.cols != cols else { return false }
        free()
        self = ScreenSearch(screen, needle)
        return true
    }

    /// The active window: pages from the last up to the active area's first, added last-to-first
    /// (Ghostty's order), then pages above whose last row wraps, while the needle could span them.
    func activeWindow() -> (window: SearchWindow, first: Page?) {
        var (w, rem, node, first) = (SearchWindow(), screen.pages.rows, Optional(screen.pages.last), nil as Page?)
        while let n = node {
            w.append(n)
            (first, node) = (n, n.prev)
            if rem <= n.rows { break }
            rem -= n.rows
        }
        while let n = node, !w.isFull, n.row(n.rows - 1).wrap, w.append(n) < needle.count - 1 { node = n.prev }
        return (w, first)
    }

    mutating func tickActive(_ window: SearchWindow? = nil) {
        active = (window ?? activeWindow().window).matches(needle)
        enforceLimit()
        if state == .active { state = .history }
    }

    /// Keep match metadata bounded too; results are ordered newest active, then newest history.
    mutating func enforceLimit() {
        if active.count > SearchWindow.maxMatches { active = Array(active.suffix(SearchWindow.maxMatches)) }
        let keep = max(0, SearchWindow.maxMatches - active.count)
        if history.count > keep { history = Array(history.prefix(keep)) }
        if let selected, selected.idx >= count { clearSelection() }
    }

    /// The history pages (up to the start page) at once; matches starting on the start page are the active window's.
    mutating func tickHistory() {
        if let h = past, !h.searched {
            let start = h.start.pin.page
            var w = SearchWindow()
            var recent: [Page] = [], bytes = 0, node = start.prev
            while let p = node, bytes + p.accountedSize <= SearchWindow.maxTextBytes {
                recent.append(p)
                bytes += p.accountedSize
                node = p.prev
            }
            for p in recent.reversed() { w.append(p) }
            history += w.matches(needle).reversed().filter { $0.chunks[0].page !== start }
            enforceLimit()
            if let oldest = recent.last { h.top.pin = Pin(page: oldest, y: oldest.rows - 1, x: oldest.cols - 1) }
            past!.searched = true
        }
        state = past == nil ? .complete : .historyFeed
    }

    mutating func feed() {
        _ = resetIfResized()
        if let h = past, !h.searched { state = .history; return }
        state = .complete
        pruneHistory()
    }

    func historyValid(_ m: Match, _ live: [UnsafeMutablePointer<Page.Header>: Int]) -> Bool { m.chunks.allSatisfy { live[$0.page.header] == $0.serial } }

    mutating func dropHistory() {
        if let h = past { screen.pages.untrack(h.start); screen.pages.untrack(h.top) }
        (past, history) = (nil, [])
    }

    mutating func clearSelection() {
        if let s = selected { screen.pages.untrack(s.start); screen.pages.untrack(s.end) }
        selected = nil
    }

    /// Drops history results on pages that are gone (pruned, erased), keeping the selection on its match.
    mutating func pruneHistory() {
        let (live, old) = (screen.pages.live, selected.map { $0.idx - active.count })
        var (kept, removed, hit) = ([Match](), 0, false)
        for (i, m) in history.enumerated() {
            if historyValid(m, live) { kept.append(m) } else if old == i { hit = true } else if let o = old, o > i { removed += 1 }
        }
        history = kept
        if hit { clearSelection() } else if removed > 0 { selected!.idx -= removed }
    }

    /// The active area changed: search it again, move results of pages that left it into history,
    /// and keep the selection on its match (Ghostty's reloadActive).
    mutating func reloadActive() {
        if resetIfResized() { return }
        if let s = selected, s.idx >= active.count, !(match(s.idx).map { historyValid($0, screen.pages.live) } ?? false) { clearSelection() }
        let selectPrev = selected.map { $0.start.pin.garbage || $0.end.pin.garbage } ?? false
        if selectPrev { clearSelection() }
        defer { if selectPrev { _ = select(next: false) } }
        let (window, first) = activeWindow()
        if let first, !screen.noScrollback {
            // Pruned up through the start page: no history anymore.
            if past?.start.pin.garbage == true { dropHistory() }
            if let h = past {
                if h.start.pin.page !== first {
                    // The pages between the old start and the new one left the active area.
                    var w = SearchWindow()
                    for p in sequence(first: h.start.pin.page, next: { $0 === first ? nil : $0.next }) {
                        if w.isFull { break }
                        w.append(p)
                    }
                    h.start.pin = Pin(page: first)
                    let added = Array(w.matches(needle).filter { $0.chunks[0].page !== first }.reversed())
                    let overflow = active.count + history.count + added.count > SearchWindow.maxMatches
                    if overflow, selected.map({ $0.idx >= active.count }) == true { clearSelection() }
                    history = added + history
                    enforceLimit()
                    if !overflow, let sel = selected, sel.idx >= active.count { selected!.idx += added.count }
                }
            } else {
                past = History(start: screen.pages.track(Pin(page: first)), top: screen.pages.track(Pin(page: first, y: first.rows - 1, x: first.cols - 1)))
            }
        } else if first == nil {
            dropHistory()
            if let s = selected, s.idx >= active.count { clearSelection(); _ = select(next: false) }
        }
        let (oldActive, oldIdx) = (active.count, selected?.idx)
        let saved = state
        tickActive(window)
        if saved != .active { state = saved }
        if screen.noScrollback, !active.isEmpty {
            let tl = screen.pages.topLeft(.active)
            active = Array(active.drop { !tl.before($0.end) })
        }
        guard let old = oldIdx, let s = selected else { return }
        if old >= oldActive { selected!.idx += active.count - oldActive; return }
        if let i = active.firstIndex(where: { $0.start == s.start.pin && $0.end == s.end.pin }) { selected!.idx = active.count - 1 - i; return }
        clearSelection()
        _ = select(next: true)
    }

    /// Selects the next (older) or previous (newer) match, wrapping; with none selected, the newest or oldest.
    mutating func select(next: Bool) -> Bool {
        _ = resetIfResized()
        reloadActive()
        pruneHistory()
        guard count > 0 else { return false }
        let idx = selected.map { next ? ($0.idx + 1 >= count ? 0 : $0.idx + 1) : ($0.idx != 0 ? $0.idx - 1 : count - 1) } ?? (next ? 0 : count - 1)
        let m = match(idx)!
        clearSelection()
        selected = (idx, screen.pages.track(m.start), screen.pages.track(m.end))
        return true
    }
}

/// The viewport's matches (Ghostty's ViewportSearch): the text of the pages the viewport covers,
/// with pages before it whose last row wraps (as far as the needle reaches back) and after it
/// while the text wraps on; searched again when those pages change, or when the active area was
/// dirty and the viewport shows part of it.
struct ViewportSearch {
    let needle: [UInt8]
    var pages: [(page: Page, serial: Int)] = []
    /// nil until the first update (which checks the active area).
    var activeDirty: Bool?
    var window = SearchWindow()

    /// Whether the window was rebuilt (its matches may have changed).
    mutating func update(_ list: PageList) -> Bool {
        let old = pages
        pages.removeAll(keepingCapacity: true)
        var (pin, rows) = (list.topLeft(.viewport), list.rows)
        while rows > 0 {
            pages.append((pin.page, pin.page.serial))
            rows -= pin.page.rows - pin.y
            guard rows > 0, let next = pin.page.next else { break }
            pin = Pin(page: next)
        }
        let changed = old.count != pages.count || zip(old, pages).contains { $0.page !== $1.page || $0.serial != $1.serial }
        if !changed {
            let check = activeDirty.map { dirty in activeDirty = false; return dirty } ?? true
            let (tl, br) = (list.topLeft(.active).page, list.bottomRight(.active)!.page)
            guard check, pages.contains(where: { $0.page === tl || $0.page === br }) else { return false }
        }
        if activeDirty != nil { activeDirty = false }
        window = SearchWindow()
        let overlap = max(needle.count - 1, 0)
        var (node, added) = (pages[0].page.prev, 0)
        while let n = node, n.row(n.rows - 1).wrap {
            added += window.append(n)
            if added >= overlap || window.isFull { break }
            node = n.prev
        }
        for p in pages { window.append(p.page) }
        let end = pages[pages.count - 1].page
        if end.row(end.rows - 1).wrap {
            (node, added) = (end.next, 0)
            while let n = node {
                added += window.append(n)
                if added >= overlap || window.isFull || !n.row(n.rows - 1).wrap { break }
                node = n.next
            }
        }
        return true
    }
}

/// A search over the terminal's screens (Ghostty's TerminalSearch): one ScreenSearch per screen,
/// replaced when its screen is; totals and selection are the active screen's; the viewport's
/// matches for the renderer (stale until read after they may have changed).
public struct TerminalSearch {
    public let needle: [UInt8]
    var screens: [(search: ScreenSearch, generation: Int)?] = [nil, nil]
    var activeKey = 0
    var viewport: ViewportSearch, stale = true

    /// The viewport starts dirty (Ghostty: the first change is re-searched).
    public init(_ needle: [UInt8]) { (self.needle, viewport) = (needle, ViewportSearch(needle: needle, activeDirty: true)) }

    var activeSearch: ScreenSearch? { screens[activeKey]?.search }
    public var total: Int? { activeSearch?.count }
    public var selected: Int? { activeSearch?.selected?.idx }
    /// Newest first.
    public var matches: [Match] { activeSearch?.matches ?? [] }

    /// Releases pins on screens that still exist.
    public func free(_ t: Terminal) {
        for (key, e) in screens.enumerated() { if let e, t.screen(key)?.generation == e.generation { e.search.free() } }
    }

    /// Reads the terminal: screens added or replaced, the active area when `dirty`, more history.
    public mutating func feed(_ t: Terminal, dirty: Bool) {
        activeKey = t.activeKey
        for key in 0..<2 {
            if let e = screens[key], t.screen(key)?.generation != e.generation { screens[key] = nil }
            if screens[key] == nil, let (s, g) = t.screen(key) { screens[key] = (ScreenSearch(s, needle), g) }
        }
        if dirty {
            viewport.activeDirty = true
            screens[activeKey]?.search.reloadActive()
        }
        if viewport.update(t.active.pages) { stale = true }
        for key in 0..<2 where [.historyFeed, .complete].contains(screens[key]?.search.state) { screens[key]!.search.feed() }
    }

    public enum Tick { case complete, progress, blocked }

    /// Every screen search one step (Ghostty's TerminalSearch.tick): blocked when those left need a feed.
    mutating func tick() -> Tick {
        var result = Tick.complete
        for key in 0..<2 {
            switch screens[key]?.search.state {
            case .active: screens[key]!.search.tickActive(); result = .progress
            case .history: screens[key]!.search.tickHistory(); result = .progress
            case .historyFeed: if result == .complete { result = .blocked }
            default: break
            }
        }
        return result
    }

    var isComplete: Bool { !screens.contains { $0 != nil && $0!.search.state != .complete } }

    /// Searches until nothing is left (Ghostty's thread: tick, feed when blocked).
    public mutating func run(_ t: Terminal) {
        while !isComplete { if tick() == .blocked { feed(t, dirty: false) } }
    }

    /// The viewport's matches when they may have changed since last read (Ghostty's viewportMatches).
    mutating func viewportMatches() -> [Match]? {
        guard stale else { return nil }
        stale = false
        return viewport.window.matches(needle)
    }

    /// Selects the next or previous match and scrolls it into view if it isn't.
    @discardableResult public mutating func select(_ t: Terminal, next: Bool) -> Bool {
        feed(t, dirty: false)
        guard screens[activeKey] != nil else { return false }
        _ = screens[activeKey]!.search.select(next: next)
        guard let s = screens[activeKey]?.search, let m = s.selected.flatMap({ s.match($0.idx) }) else { return false }
        let pages = s.screen.pages
        let view = pages.bottomRight(.viewport).map { pages.topLeft(.viewport).chunks(down: true, to: $0) } ?? []
        if !view.contains(where: { v in m.chunks.contains { $0.page === v.page && v.rows.upperBound > $0.start && v.rows.lowerBound < $0.end } }) {
            pages.scroll(.pin(m.start))
        }
        return true
    }
}
