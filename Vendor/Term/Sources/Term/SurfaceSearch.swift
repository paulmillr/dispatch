// The find bar (Ghostty's Surface search binding actions and its search thread, terminal/search/
// Thread.zig): the thread's work runs to completion right away (Ghostty's thread gets to it soon
// after, and refreshes every 24 ms while the program writes: `searchRefresh`, which the embedder
// calls between inputs and frames). What the thread tells the surface becomes messages (totals,
// the selected index) and the renderer's highlights.

/// The search thread's state: the search (none until a needle), what it last told (it tells
/// changes only).
struct SearchThread {
    var search: TerminalSearch?
    var told = Told()
    struct Told { var key: Int?, total: Int?, selected: (idx: Int, start: Pin, end: Pin)? }
}

/// The renderer's search state: the viewport's matches, the selected one, changed since applied.
public struct SearchHighlights {
    public var matches: [Match] = [], selected: Match?, changed = false
    public init() {}
}

extension Surface {
    /// `search:<needle>` (empty: stop).
    func search(_ needle: [UInt8]) -> Bool {
        if searching == nil {
            if needle.isEmpty { return false }
            searching = SearchThread()
        }
        if needle.isEmpty { quitSearch(); return true }
        changeNeedle(needle)
        runSearch()
        return true
    }

    /// `navigate_search:next|previous`: the next (older) or previous match, scrolled into view.
    func navigateSearch(next: Bool) -> Bool {
        guard searching != nil else { return false }
        if searching!.search != nil, searching!.search!.select(terminal, next: next) { searching!.told.selected = nil }
        runSearch()
        return true
    }

    /// `end_search`: performed only when a search was open; the host hears of it anyway.
    func endSearch() -> Bool {
        let open = searching != nil
        if open { quitSearch() }
        _ = host?.perform(.endSearch)
        return open
    }

    /// The thread's refresh (every 24 ms in Ghostty): the terminal read again, then the work left.
    public func searchRefresh() {
        guard searching?.search != nil else { return }
        feedSearch()
        runSearch()
    }

    /// Thread.feedLocked: the terminal read again; the active area searched again if a frame found
    /// the viewport dirty since.
    func feedSearch() {
        searching!.search!.feed(terminal, dirty: terminal.searchViewportDirty)
        terminal.searchViewportDirty = false
    }

    /// Thread.changeNeedle: the same needle (ignoring ASCII case) changes nothing; a new one
    /// replaces the search (the old one's total and selection cleared first; its highlights are
    /// replaced by the new search's first notify, which runs right after, so Ghostty's clearing of
    /// them has nothing to show here).
    func changeNeedle(_ needle: [UInt8]) {
        let lower = { (b: [UInt8]) in b.map { $0 &- 0x41 < 26 ? $0 | 0x20 : $0 } }
        if let old = searching!.search {
            if lower(old.needle) == lower(needle) { return }
            old.free(terminal)
            (searching!.search, searching!.told) = (nil, SearchThread.Told())
            told(total: 0)
            told(selected: nil)
        }
        searching!.search = TerminalSearch(needle)
        feedSearch()
    }

    /// Thread.runSync: tell what changed, work a step, until the search is complete.
    func runSearch() {
        while searching?.search != nil {
            notifySearch()
            if searching!.search!.isComplete { return }
            if searching!.search!.tick() == .blocked { feedSearch() }
        }
    }

    /// Thread.notify: changes since last told (a screen switch forgets the total and selection).
    func notifySearch() {
        var s = searching!.search!
        defer { searching!.search = s }
        if searching!.told.key != s.activeKey { (searching!.told.key, searching!.told.total, searching!.told.selected) = (s.activeKey, nil, nil) }
        guard let screen = s.activeSearch else { return }
        if let total = s.total, total != searching!.told.total { searching!.told.total = total; told(total: total) }
        if let matches = s.viewportMatches() { told(matches: matches) }
        // The selected match as the results hold it (where its text was when last searched, not
        // where its tracked pins are now); none there (not searched yet) tells nothing.
        if let idx = screen.selected?.idx {
            if let m = screen.match(idx), searching!.told.selected.map({ $0.idx != idx || $0.start != m.start || $0.end != m.end }) ?? true {
                searching!.told.selected = (idx, m.start, m.end)
                told(selected: (idx, m))
            }
        } else if searching!.told.selected != nil {
            searching!.told.selected = nil
            told(selected: nil)
        }
    }

    /// The thread's exit (end, or an empty needle): the renderer's highlights and the totals cleared.
    func quitSearch() {
        searching!.search?.free(terminal)
        searching = nil
        (searchHighlights, searchHighlights.changed) = (SearchHighlights(), true)
        handler.surface.append(.searchTotal(nil))
        handler.surface.append(.searchSelected(nil))
    }

    // Surface.searchCallback_: the renderer's part now, the surface's as messages.
    func told(total: Int) { handler.surface.append(.searchTotal(total)) }
    func told(matches: [Match]) {
        (searchHighlights.matches, searchHighlights.changed) = (matches, true)
    }
    func told(selected: (idx: Int, match: Match)?) {
        (searchHighlights.selected, searchHighlights.changed) = (selected?.match, true)
        handler.surface.append(.searchSelected(selected?.idx))
    }

    /// The renderer took the highlights.
    public func searchHighlightsApplied() { searchHighlights.changed = false }
}
