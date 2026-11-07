import Foundation

/// A tab as the sidebar lists it: a native tab, or a structured space's window (a tmux or herdr window, whose panes
/// are terminals), which its strip would show as a tab. Vertical tabs lists the shown space's; the Nautical radar plots
/// every space's.
struct SidebarTab: Identifiable, Equatable {
    let id: UUID
    let space: UUID
    let host: HostID
    /// Its terminals: the tab's own, or every pane of the window.
    let surfaceIDs: [UUID]
    /// A structured space's window (ContainerTab): selected, moved and closed as one.
    let window: Bool
    /// The native pane holding the tab; nil for a window.
    let pane: UUID?
    /// A window's panes, one per pane in reading order, when it has two or more; empty otherwise.
    var members: [SidebarSplitMember] = []
    /// The panes' frames in the unit square, in reading order, which the members' pane glyphs draw.
    var cells: [CGRect] = []
}

/// One pane of a window: the terminal it shows.
struct SidebarSplitMember: Identifiable, Equatable {
    /// The pane's terminal tab.
    let id: UUID
    let pane: UUID
    /// Its frame's index in the row's `cells`.
    let cell: Int
    /// The pane with focus in its window.
    let focused: Bool
}

extension Workspace {
    /// Every space's tabs in presentation order (the Nautical radar plots them).
    var sidebarTabs: [SidebarTab] { presentationSpaces.flatMap { sidebarTabs(in: $0) } }

    /// A space's tabs as the sidebar lists them: a native space's with its panes in reading order (as the pane digits
    /// number them) and each pane's tabs in order; a structured space's windows as its strip orders them, each with its
    /// panes.
    func sidebarTabs(in space: Space) -> [SidebarTab] {
        if space.structured {
            let ordered = space.presentation?.orderedWindows ?? []
            let known = Set(ordered)
            return (ordered + space.containers.map(\.id).filter { !known.contains($0) }).compactMap { id in
                space.containers.first { $0.id == id }.map { window in
                    let surfaces = window.terminals.flatMap(\.surfaceIDs)
                    var row = SidebarTab(id: window.id, space: space.id, host: host(of: surfaces, in: space),
                                         surfaceIDs: surfaces, window: true, pane: nil)
                    (row.members, row.cells) = Self.members(of: window.arrangement, fractions: window.arrangement.splitFractions)
                    return row
                }
            }
        }
        return space.numberedPaneIDs.compactMap { id in space.panes.first { $0.id == id } }.flatMap { pane in
            pane.tabs.map { tab in
                SidebarTab(id: tab.id, space: space.id, host: host(of: tab.surfaceIDs, in: space),
                           surfaceIDs: tab.surfaceIDs, window: false, pane: pane.id)
            }
        }
    }

    /// The shown tab of each pane, in reading order, with the panes' frames; none for a single pane.
    static func members(of arrangement: PaneArrangement, fractions: [UUID: CGFloat]) -> ([SidebarSplitMember], [CGRect]) {
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

    /// The listed tab that is active in the shown space: its selected window, or its focused pane's tab.
    var selectedSidebarTab: UUID? {
        guard let space = current else { return nil }
        if space.structured { return space.selectedContainer ?? space.containers.first?.id }
        return space.activeTab?.id
    }

    /// Chooses a listed tab: a window or a tab, in whichever space holds it.
    func selectSidebarTab(_ id: UUID) {
        if spaces.contains(where: { $0.containers.contains { $0.id == id } }) { selectWindow(id) } else { selectTab(id) }
    }
}
