import Foundation

/// A row of the tabs-only sidebar (Preferences.tabsOnly): a native tab, a split, or a structured space's window (a
/// tmux or herdr window, whose panes are terminals), which its strip would show as a tab. A row is what the window
/// shows when it is chosen: a split, a native space whose panes hold one tab each, is one row (its id the space's).
struct SidebarTab: Identifiable, Equatable {
    let id: UUID
    /// The space holding it; spaces are not shown, but still own layouts and backends.
    let space: UUID
    let host: HostID
    /// Its terminals: the tab's own, every pane's of a split, or every pane of the window.
    let surfaceIDs: [UUID]
    /// A structured space's window (ContainerTab): selected, moved and closed as one.
    let window: Bool
    /// The native pane holding the tab, where a dropped tab lands beside it; nil for a window or a split.
    let pane: UUID?
    /// A split's tabs or a window's panes, one per pane in reading order; empty for a single terminal.
    var members: [SidebarSplitMember] = []
    /// A split of tmux or herdr windows (a space whose window groups hold one window each): its members are windows.
    var windows = false
    /// The panes' frames in the unit square, in reading order, which the members' pane glyphs draw.
    var cells: [CGRect] = []

    /// A split (of native tabs, or of windows): its members can be chosen, popped out and rearranged one by one.
    var split: Bool { !window && !members.isEmpty }
    /// The tabs (or windows) a split of this row would take: a split's own, else the row's.
    var tabIDs: [UUID] { split ? members.map(\.id) : [id] }
    /// A tmux or herdr window, or a split of them.
    var multiplexed: Bool { window || windows }
}

/// One pane of a split row: the tab it shows.
struct SidebarSplitMember: Identifiable, Equatable {
    /// The tab (a window's pane's terminal).
    let id: UUID
    let pane: UUID
    /// Its frame's index in the row's `cells`.
    let cell: Int
    /// The pane with focus in its space or window.
    let focused: Bool
}

/// How a sidebar row was clicked: alone, ⌘ (toggles it among the marked rows) or ⇧ (marks a range).
enum SidebarClick {
    case plain, toggle, range

    init(command: Bool, shift: Bool) { self = command ? .toggle : shift ? .range : .plain }
}

extension Workspace {
    /// Every row the sidebar lists in tabs-only mode, in the order it draws them (which ⌘1…9 and ⌘[ / ⌘] walk): the
    /// spaces' presentation order, a native space's tabs with its panes in reading order (as the pane digits number
    /// them) and each pane's tabs in order, a structured space's windows as its strip orders them. A split native space
    /// is one row. Grouped by host, rows go under their own host (a tab's terminal can reach another than its
    /// space's). Listing spaces, every tab is a row (the Nautical radar).
    var sidebarTabs: [SidebarTab] {
        let rows = listedRows
        guard tabsOnly, spaceOrder == .tree else { return rows }
        let order = Dictionary(liveHosts.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return rows.enumerated().sorted {
            let left = order[$0.element.host, default: .max], right = order[$1.element.host, default: .max]
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    /// The rows space by space; a tab a split's pane holds behind its shown one (none while tabs only lifts them out,
    /// `liftHiddenTabs`) lists after the split.
    private var listedRows: [SidebarTab] {
        presentationSpaces.flatMap { space -> [SidebarTab] in
            if space.structured, tabsOnly, Self.windowSplit(space), let presentation = space.presentation {
                // One row, a line per window in reading order, as a native split's.
                let order = presentation.layout.paneIDsInReadingOrder(fractions: space.paneFractions)
                let frames = presentation.layout.paneFrames(fractions: space.paneFractions)
                let groups = order.compactMap { id in presentation.groups.first { $0.id == id } }
                let members = groups.enumerated().map { index, group in
                    SidebarSplitMember(id: group.selected, pane: group.id, cell: index, focused: group.selected == space.selectedContainer)
                }
                let surfaces = space.containers.flatMap { $0.terminals.flatMap(\.surfaceIDs) }
                return [SidebarTab(id: space.id, space: space.id, host: host(of: surfaces, in: space), surfaceIDs: surfaces,
                                   window: false, pane: nil, members: members, windows: true,
                                   cells: order.map { id in frames.first { $0.id == id }?.frame ?? .zero })]
            }
            if space.structured {
                let ordered = space.presentation?.orderedWindows ?? []
                let known = Set(ordered)
                return (ordered + space.containers.map(\.id).filter { !known.contains($0) }).compactMap { id in
                    space.containers.first { $0.id == id }.map { window in
                        let surfaces = window.terminals.flatMap(\.surfaceIDs)
                        var row = SidebarTab(id: window.id, space: space.id, host: host(of: surfaces, in: space),
                                             surfaceIDs: surfaces, window: true, pane: nil)
                        if tabsOnly {
                            (row.members, row.cells) = Self.members(of: window.arrangement, fractions: window.arrangement.splitFractions)
                        }
                        return row
                    }
                }
            }
            let panes = space.numberedPaneIDs.compactMap { id in space.panes.first { $0.id == id } }
            let plain = { (tab: TerminalTab, pane: Pane) in
                SidebarTab(id: tab.id, space: space.id, host: self.host(of: tab.surfaceIDs, in: space),
                           surfaceIDs: tab.surfaceIDs, window: false, pane: pane.id)
            }
            guard tabsOnly, panes.count > 1 else { return panes.flatMap { pane in pane.tabs.map { plain($0, pane) } } }
            let (members, cells) = Self.members(of: space.arrangement, fractions: space.paneFractions)
            let surfaces = members.map(\.id)
            let split = SidebarTab(id: space.id, space: space.id, host: host(of: surfaces, in: space), surfaceIDs: surfaces,
                                   window: false, pane: nil, members: members, cells: cells)
            return [split] + panes.flatMap { pane in pane.tabs.filter { $0.id != pane.selected }.map { plain($0, pane) } }
        }
    }

    /// The shown tab of each pane, in reading order, with the panes' frames; none for a single pane.
    private static func members(of arrangement: PaneArrangement, fractions: [UUID: CGFloat]) -> ([SidebarSplitMember], [CGRect]) {
        let frames = arrangement.layout.paneFrames(fractions: fractions)
        let order = arrangement.layout.paneIDsInReadingOrder(fractions: fractions)
        guard order.count > 1 else { return ([], []) }
        let cells = order.map { id in frames.first { $0.id == id }?.frame ?? .zero }
        let members = order.enumerated().compactMap { index, id -> SidebarSplitMember? in
            arrangement.panes.first { $0.id == id }?.activeTab.map {
                SidebarSplitMember(id: $0.id, pane: id, cell: index, focused: id == arrangement.focusedPane)
            }
        }
        return (members, cells)
    }

    /// The host a tab's terminal reached, else its space's.
    private func host(of surfaces: [UUID], in space: Space) -> HostID {
        surfaces.lazy.compactMap { self.hosts.terminals[$0]?.host }.first ?? space.hostID
    }

    /// A native space whose panes the sidebar lists as one split row.
    func isSplit(_ space: Space) -> Bool { space.containers.isEmpty && space.panes.count > 1 }

    /// A tmux or herdr space shown as a split of its windows: two or more window groups (Dispatch's own, side by
    /// side), one window each, holding all of the space's windows.
    static func windowSplit(_ space: Space) -> Bool {
        guard !space.containers.isEmpty, let groups = space.presentation?.groups, groups.count > 1,
              groups.allSatisfy({ $0.windows.count == 1 }) else { return false }
        return Set(groups.flatMap(\.windows)) == Set(space.containers.map(\.id))
    }

    /// The listed row that is active: the current space's selected window, its split, or its focused pane's tab.
    var selectedSidebarTab: UUID? {
        guard let space = current else { return nil }
        if tabsOnly, Self.windowSplit(space) { return space.id }
        if space.structured { return space.selectedContainer ?? space.containers.first?.id }
        if tabsOnly, isSplit(space) { return space.id }
        return space.activeTab?.id
    }

    /// Chooses a row: a split shows with the pane it had focused.
    func selectSidebarTab(_ id: UUID) {
        if spaces.contains(where: { $0.id == id }) { selectSpace(id); return }
        if spaces.contains(where: { $0.containers.contains { $0.id == id } }) { selectWindow(id) } else { selectTab(id) }
    }

    /// The listed tabs the chrome counts (as `lastingSpaceCount` counts spaces): a launching tab that is already
    /// leaving does not count beside the window it launched.
    var lastingTabCount: Int {
        guard !retiringLaunchers.isEmpty else { return sidebarTabs.count }
        return sidebarTabs.count { !retiringLaunchers.contains($0.id) }
    }

    /// ⌘1…9 in tabs-only mode: the first eight listed rows, then the last.
    func selectSidebarTab(at index: Int) {
        let order = sidebarTabs
        let index = index == 8 ? order.count - 1 : index
        if order.indices.contains(index) { selectSidebarTab(order[index].id) }
    }

    /// ⌘[ / ⌘] and ⌃⇥ in tabs-only mode: the listed row before or after the active one, wrapping.
    func cycleSidebarTab(_ delta: Int) {
        let order = sidebarTabs.map(\.id)
        guard let selected = selectedSidebarTab, let index = order.firstIndex(of: selected) else { return }
        selectSidebarTab(order[(index + delta + order.count) % order.count])
    }

    // MARK: Marks

    /// The marked rows still listed.
    var liveSidebarMarks: Set<UUID> {
        guard !sidebarMarks.isEmpty else { return [] }
        return sidebarMarks.intersection(sidebarTabs.map(\.id))
    }

    /// A click on a row. Alone it chooses the row and clears the marks; ⌘ toggles the row among them (the first
    /// ⌘-click marks the active row too, as Finder's selection does); ⇧ marks every row from the last one clicked.
    func clickSidebarRow(_ id: UUID, _ click: SidebarClick) {
        let order = sidebarTabs.map(\.id)
        switch click {
        case .plain:
            sidebarMarks = []
            sidebarMarkAnchor = id
            selectSidebarTab(id)
        case .toggle:
            var marks = liveSidebarMarks
            if marks.isEmpty, let active = selectedSidebarTab, active != id, order.contains(active) { marks.insert(active) }
            if marks.contains(id) { marks.remove(id) } else { marks.insert(id) }
            sidebarMarks = marks
            sidebarMarkAnchor = id
        case .range:
            let anchor = sidebarMarkAnchor.flatMap { order.contains($0) ? $0 : nil } ?? selectedSidebarTab
            guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) else {
                sidebarMarks = [id]
                return
            }
            sidebarMarks = Set(order[min(from, to)...max(from, to)])
        }
    }

    // MARK: Splits

    /// Why these rows cannot make one split, or nil when they can: native tabs (a split's count as its tabs), two to
    /// four of them, on one host.
    func sidebarSplitRefusal(_ rows: Set<UUID>) -> String? {
        let listed = sidebarTabs.filter { rows.contains($0.id) }
        let multiplexed = listed.filter(\.multiplexed)
        if !multiplexed.isEmpty, multiplexed.count != listed.count { return "Tabs and tmux or herdr windows can't share a split" }
        let tabs = listed.flatMap(\.tabIDs)
        if listed.count < 2 || tabs.count < 2 { return "Choose two or more tabs" }
        if tabs.count > 4 { return "A split holds at most 4 tabs" }
        if !multiplexed.isEmpty {
            let sessions = Set(listed.compactMap { row in spaces.first { $0.id == row.space } }
                .map { "\($0.backend.map(String.init) ?? "")|\($0.remote.map { "\($0)" } ?? "")|\($0.hostID.rawValue)" })
            return sessions.count > 1 ? "Windows of different sessions can't share a split" : nil
        }
        if Set(listed.map(\.host)).count > 1 { return "Tabs on different hosts can't share a split" }
        return nil
    }

    /// Splits the rows' tabs into a new space after the first row's, in the list's order and the given layout (one
    /// for their count otherwise), and shows it with the active tab focused if it is one of them. The spaces they
    /// leave keep their other tabs. Clears the marks.
    @discardableResult
    func splitSidebarRows(_ rows: Set<UUID>, preset: LayoutPreset? = nil) -> Bool {
        guard sidebarSplitRefusal(rows) == nil else { return false }
        let listed = sidebarTabs.filter { rows.contains($0.id) }
        if listed[0].multiplexed { return splitWindows(listed.flatMap(\.tabIDs), preset: preset) }
        let tabs = listed.flatMap(\.tabIDs)
        let host = listed[0].host, anchor = listed[0].space
        let focus = activeTab.map(\.id).flatMap { tabs.contains($0) ? $0 : nil } ?? tabs[0]
        let order = spaces.map(\.id)
        for id in tabs { supersedeHostPlacement(id) }
        let made: UUID? = updateLayout { next in
            let moved = tabs.compactMap { next.detachTab($0) }
            guard let first = moved.first else { return nil }
            let panes = moved.map { Pane(tabs: [$0]) }
            let layout = preset.flatMap { $0.count == panes.count ? $0 : nil } ?? LayoutPreset.split(panes.count)
            var space = Space(name: Self.nextSpaceName(in: next.spaces), tab: first, usesDirectoryName: true)
            space.hostID = host
            space.panes = panes
            space.layout = layout.layout(panes.map(\.id))
            space.preset = layout
            space.focusedPane = panes.first { $0.selected == focus }?.id ?? panes[0].id
            next.spaces.insert(space, at: Self.insertion(after: anchor, in: next.spaces, order: order))
            return next.selectTab(focus)
        }
        sidebarMarks = []
        if let made { selectSpace(made) }
        return made != nil
    }

    /// Splits tmux or herdr windows of one session in Dispatch: they move into a space of their own (the first
    /// window's, when it is alone there; else a new one after it), which only retags them on the server (tmux's
    /// `@dispatch-window` group), and once they are all there it shows them side by side, one window group each, in
    /// the given layout (one for their count otherwise). No pane, window or session is created or merged.
    private func splitWindows(_ windows: [UUID], preset: LayoutPreset?) -> Bool {
        guard let first = windows.first,
              let origin = spaces.first(where: { $0.containers.contains { $0.id == first } }) else { return false }
        let preset = preset.flatMap { $0.count == windows.count ? $0 : nil } ?? LayoutPreset.split(windows.count)
        sidebarMarks = []
        pendingWindowSplits.append(PendingWindowSplit(windows: windows, preset: preset))
        if origin.containers.count > 1 { moveWindowToNewSpace(first) } else { selectWindow(first) }
        for window in windows.dropFirst() { moveContainer(window, beside: first, edge: nil, after: true) }
        // Already together (a split's windows, alone in their space): the layout applies at once.
        updateLayout { _ in }
        return true
    }

    /// Lays a split of windows out once its windows are all in one space and nothing else is: the first one's
    /// selection kept. A window that went meanwhile drops the request.
    private func applyWindowSplits(_ next: inout WorkspaceLayout) {
        guard !pendingWindowSplits.isEmpty else { return }
        let all = Set(next.spaces.flatMap(\.containers).map(\.id))
        pendingWindowSplits.removeAll { !Set($0.windows).isSubset(of: all) }
        pendingWindowSplits.removeAll { request in
            guard let s = next.spaces.firstIndex(where: { space in request.windows.allSatisfy { window in space.containers.contains { $0.id == window } } }),
                  next.spaces[s].containers.count == request.windows.count else { return false }
            let selected = next.spaces[s].selectedContainer.flatMap { request.windows.contains($0) ? $0 : nil } ?? request.windows[0]
            next.spaces[s].presentation = TabPresentation(windows: request.windows, selected: selected, preset: request.preset)
            next.spaces[s].selectedContainer = selected
            next.spaces[s].splitRatios = [:]
            return true
        }
    }

    /// The nearest space of the same session that is no split, before `split` first: where a window popped out goes.
    func windowHome(near split: Space) -> Space? {
        let index = spaces.firstIndex { $0.id == split.id } ?? spaces.count
        let homes = spaces.indices.filter { s in
            let space = spaces[s]
            return space.id != split.id && space.structured && space.node != nil && !Self.windowSplit(space)
                && space.backend == split.backend && space.remote == split.remote && space.hostID == split.hostID
        }
        return (homes.last { $0 < index } ?? homes.first { $0 > index }).map { spaces[$0] }
    }

    /// Whether this tab can join (or, already in it, move within) the split space: native, on its host, while the
    /// split holds fewer than four.
    func canAddToSplit(_ id: UUID, space spaceID: UUID) -> Bool {
        guard let space = spaces.first(where: { $0.id == spaceID }), isSplit(space),
              space.panes.allSatisfy({ $0.tabs.count == 1 }) else { return false }
        if space.tabs.contains(where: { $0.id == id }) { return true }
        guard space.panes.count < 4, container(containing: id) == nil, location(ofTab: id) != nil else { return false }
        return hostsAllowMove(id, to: space.panes[0].id)
    }

    /// A tab dropped on a split's tab, before or after it in reading order. One from outside joins as a pane, the
    /// layout taking the new count's (two above one, then a grid); one already there trades places, the panes and
    /// their proportions staying. Shows the tab.
    @discardableResult
    func addToSplit(_ id: UUID, space spaceID: UUID, relativeTo target: UUID?, after: Bool) -> Bool {
        guard canAddToSplit(id, space: spaceID), let space = spaces.first(where: { $0.id == spaceID }) else { return false }
        var order = space.numberedPaneIDs.compactMap { pane in space.panes.first { $0.id == pane }?.selected }
        let joining = !order.contains(id)
        order.removeAll { $0 == id }
        let index = target.flatMap { order.firstIndex(of: $0) }.map { $0 + (after ? 1 : 0) } ?? order.count
        order.insert(id, at: index)
        supersedeHostPlacement(id)
        let selected: UUID? = updateLayout { next in
            let arriving = joining ? next.detachTab(id) : nil
            guard let s = next.spaces.firstIndex(where: { $0.id == spaceID }) else { return nil }
            var tabs = Dictionary(next.spaces[s].tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if let arriving { tabs[id] = arriving }
            if joining {
                let paneOf = Dictionary(next.spaces[s].panes.map { ($0.selected, $0.id) }, uniquingKeysWith: { first, _ in first })
                let panes = order.compactMap { tab in tabs[tab].map { Pane(id: paneOf[tab] ?? System.uuid(), tabs: [$0]) } }
                let preset = LayoutPreset.split(panes.count)
                next.spaces[s].panes = panes
                next.spaces[s].layout = preset.layout(panes.map(\.id))
                next.spaces[s].preset = preset
                next.spaces[s].splitRatios = [:]
                next.spaces[s].splitFractions = [:]
            } else {
                let panes = next.spaces[s].numberedPaneIDs
                guard panes.count == order.count else { return nil }
                next.spaces[s].panes = zip(panes, order).compactMap { pane, tab in tabs[tab].map { Pane(id: pane, tabs: [$0]) } }
            }
            return next.selectTab(id)
        }
        if let selected { selectSpace(selected) }
        return selected != nil
    }

    /// Lays a split's panes out again in a preset for their count, in their reading order.
    func arrangeSplit(_ spaceID: UUID, _ preset: LayoutPreset) {
        if let s = spaces.firstIndex(where: { $0.id == spaceID }), Self.windowSplit(spaces[s]),
           let presentation = spaces[s].presentation, presentation.groups.count == preset.count {
            let order = presentation.layout.paneIDsInReadingOrder(fractions: spaces[s].paneFractions)
            let windows = order.compactMap { id in presentation.groups.first { $0.id == id }?.selected }
            let selected = spaces[s].selectedContainer ?? windows[0]
            updateLayout { next in
                next.spaces[s].presentation = TabPresentation(windows: windows, selected: selected, preset: preset)
                next.spaces[s].splitRatios = [:]
            }
            focusRequest = System.uuid()
            return
        }
        guard let s = spaces.firstIndex(where: { $0.id == spaceID }), isSplit(spaces[s]),
              spaces[s].panes.count == preset.count else { return }
        let panes = spaces[s].numberedPaneIDs
        updateLayout { next in
            next.spaces[s].layout = preset.layout(panes)
            next.spaces[s].preset = preset
            next.spaces[s].splitRatios = [:]
            next.spaces[s].splitFractions = [:]
        }
        focusRequest = System.uuid()
    }

    /// Takes a tab out of its split to a row of its own: into the nearest space of plain tabs on its host (the one
    /// before the split first), else a new space after the split. The split keeps its other tabs (one left is a plain
    /// row), and its focus.
    /// A window goes to the nearest space of its session that is no split (its last window), else to a space of its
    /// own: a retag on the server.
    func popOutOfSplit(_ id: UUID) {
        if let split = spaces.first(where: { Self.windowSplit($0) && $0.containers.contains { $0.id == id } }) {
            if let home = windowHome(near: split), let last = home.presentation?.orderedWindows.last ?? home.containers.last?.id {
                moveContainer(id, beside: last, edge: nil, after: true)
            } else {
                moveWindowToNewSpace(id)
            }
            return
        }
        guard let space = spaces.first(where: { isSplit($0) && $0.tabs.contains { $0.id == id } }) else { return }
        let host = hosts.terminals[id]?.host ?? space.hostID
        let home = homePane(on: host, near: space.id)
        supersedeHostPlacement(id)
        updateLayout { next in
            guard let tab = next.detachTab(id) else { return }
            _ = Self.place(tab, in: &next, home: home, after: space.id, host: host)
        }
        focusRequest = System.uuid()
    }

    /// Every tab of a split back to rows of their own, as Pop Out places them, the focused one still shown.
    /// A split of windows keeps its first window; the others go as Pop Out sends them.
    func separateSplit(_ spaceID: UUID) {
        if let split = spaces.first(where: { $0.id == spaceID }), Self.windowSplit(split), let presentation = split.presentation {
            let order = presentation.layout.paneIDsInReadingOrder(fractions: split.paneFractions)
            for id in order.dropFirst().compactMap({ id in presentation.groups.first { $0.id == id }?.selected }) { popOutOfSplit(id) }
            return
        }
        guard let space = spaces.first(where: { $0.id == spaceID }), isSplit(space) else { return }
        let tabs = space.numberedPaneIDs.flatMap { pane in space.panes.first { $0.id == pane }?.tabs.map(\.id) ?? [] }
        let focused = space.activeTab?.id
        let hostOf = Dictionary(tabs.map { ($0, hosts.terminals[$0]?.host ?? space.hostID) }, uniquingKeysWith: { first, _ in first })
        var homes: [HostID: UUID] = [:]
        for host in Set(hostOf.values) { homes[host] = homePane(on: host, near: space.id) }
        for id in tabs { supersedeHostPlacement(id) }
        updateLayout { next in
            for id in tabs {
                guard let host = hostOf[id], let tab = next.detachTab(id) else { continue }
                homes[host] = Self.place(tab, in: &next, home: homes[host], after: spaceID, host: host)
            }
        }
        if let focused { selectTab(focused) }
    }

    /// The pane of the space of plain tabs nearest the given space on this host: the closest before it, else after.
    func homePane(on host: HostID, near spaceID: UUID) -> UUID? { Self.homePane(on: host, near: spaceID, in: spaces) }

    static func homePane(on host: HostID, near spaceID: UUID, in spaces: [Space]) -> UUID? {
        let index = spaces.firstIndex { $0.id == spaceID } ?? spaces.count
        let homes = spaces.indices.filter { s in
            let space = spaces[s]
            return space.id != spaceID && space.hostID == host && space.containers.isEmpty && space.backend == nil
                && space.node == nil && space.panes.count == 1
        }
        let home = homes.last { $0 < index } ?? homes.first { $0 > index }
        return home.map { spaces[$0].panes[0].id }
    }

    /// Tabs only keeps no tab behind a split's pane, where no row could show it without another taking its place (a
    /// split made while spaces showed, a restored one, a tab a command moved into a pane): each goes to a row of its
    /// own, where Pop Out would put it. Every layout commit does this while tabs only is on.
    func liftHiddenTabs(_ next: inout WorkspaceLayout) {
        applyWindowSplits(&next)
        // Window groups side by side that are no split of their own (made while spaces showed, or a window that
        // joined a split's space): one strip, since a window's row would show the others too. Dispatch's state alone.
        for s in next.spaces.indices where !next.spaces[s].containers.isEmpty {
            guard let presentation = next.spaces[s].presentation, presentation.groups.count > 1,
                  !Self.windowSplit(next.spaces[s]) else { continue }
            let windows = presentation.orderedWindows
            let selected = next.spaces[s].selectedContainer.flatMap { windows.contains($0) ? $0 : nil } ?? windows[0]
            next.spaces[s].presentation = TabPresentation(windows: windows, selected: selected, preset: .single)
        }
        let splits = next.spaces.filter { space in
            space.containers.isEmpty && space.panes.count > 1 && space.panes.contains { $0.tabs.count > 1 }
        }
        for split in splits {
            let hidden = split.numberedPaneIDs.flatMap { id -> [TerminalTab] in
                guard let pane = split.panes.first(where: { $0.id == id }) else { return [] }
                return pane.tabs.filter { $0.id != pane.selected }
            }
            var homes: [HostID: UUID] = [:]
            for tab in hidden {
                let host = hosts.terminals[tab.id]?.host ?? split.hostID
                supersedeHostPlacement(tab.id)
                guard let lifted = next.detachTab(tab.id) else { continue }
                let home = homes[host] ?? Self.homePane(on: host, near: split.id, in: next.spaces)
                homes[host] = Self.place(lifted, in: &next, home: home, after: split.id, host: host)
            }
        }
    }

    /// Places a tab out of a split: last in the home pane, else in a new space after `anchor` (or last). Returns the
    /// pane it went to, the next one's home.
    static func place(_ tab: TerminalTab, in next: inout WorkspaceLayout, home: UUID?, after anchor: UUID, host: HostID) -> UUID? {
        if let home, let (s, p) = next.location(ofPane: home) {
            next.spaces[s].panes[p].tabs.append(tab)
            return home
        }
        var space = Space(name: nextSpaceName(in: next.spaces), tab: tab, usesDirectoryName: true)
        space.hostID = host
        let index = next.spaces.firstIndex { $0.id == anchor }.map { $0 + 1 } ?? next.spaces.count
        next.spaces.insert(space, at: index)
        return space.panes.first?.id
    }

    /// Where a space made from `anchor`'s tabs goes: after it, or where it stood if it left (after the last space
    /// before it that remains).
    static func insertion(after anchor: UUID, in spaces: [Space], order: [UUID]) -> Int {
        if let index = spaces.firstIndex(where: { $0.id == anchor }) { return index + 1 }
        guard let position = order.firstIndex(of: anchor) else { return spaces.count }
        for id in order[..<position].reversed() {
            if let index = spaces.firstIndex(where: { $0.id == id }) { return index + 1 }
        }
        return 0
    }

    /// Tabs only's ⌘D and ⌘⇧D, before the plain split: marked rows split together (⌘⇧D stacks two); in a split,
    /// the panes on that axis that would merge pop out instead but the focused one, so no pane holds a hidden tab; a
    /// tab among others in its space moves to a space of its own after it first, where the new tab then splits
    /// beside it. True when that was all; false to go on with the plain split.
    func tabsOnlySplit(_ axis: SplitAxis) -> Bool {
        guard tabsOnly else { return false }
        let marks = liveSidebarMarks
        if marks.count > 1 { splitSidebarRows(marks, preset: axis == .rows ? .rows : nil); return true }
        guard let current else { return false }
        if !current.containers.isEmpty {
            // A window among others moves to a space of its own first; ⌘D there splits it (a window beside it).
            guard !Self.windowSplit(current), current.containers.count > 1, let window = current.selectedContainer else { return false }
            moveWindowToNewSpace(window)
            return true
        }
        if isSplit(current), let panes = splitToCollapse(axis) {
            for pane in panes where pane != current.focusedPane {
                for tab in current.panes.first(where: { $0.id == pane })?.tabs ?? [] { popOutOfSplit(tab.id) }
            }
            return true
        }
        if current.panes.count == 1, current.tabs.count > 1, let tab = activeTab { isolateTab(tab.id, after: current.id) }
        return false
    }

    /// Moves a tab to a new space of its own right after `anchor`, and shows it.
    private func isolateTab(_ id: UUID, after anchor: UUID) {
        guard let source = spaces.first(where: { $0.tabs.contains { $0.id == id } }) else { return }
        let host = hosts.terminals[id]?.host ?? source.hostID
        let order = spaces.map(\.id)
        supersedeHostPlacement(id)
        let made: UUID? = updateLayout { next in
            guard let tab = next.detachTab(id) else { return nil }
            var space = Space(name: Self.nextSpaceName(in: next.spaces), tab: tab, usesDirectoryName: true)
            space.hostID = host
            next.spaces.insert(space, at: Self.insertion(after: anchor, in: next.spaces, order: order))
            return next.selectTab(id)
        }
        if let made { selectSpace(made) }
    }
}

/// A split of tmux or herdr windows waiting for its windows to reach one space (`Workspace.splitWindows`).
struct PendingWindowSplit {
    let windows: [UUID]
    let preset: LayoutPreset
}
