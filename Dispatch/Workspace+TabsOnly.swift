import Foundation

/// A row of the tabs-only sidebar (Preferences.tabsOnly): a native tab, or a structured space's window (a tmux or
/// herdr window, whose panes are terminals), which its strip would show as a tab.
struct SidebarTab: Identifiable, Equatable {
    let id: UUID
    /// The space holding it; spaces are not shown, but still own layouts and backends.
    let space: UUID
    let host: HostID
    /// Its terminals: the tab's own, or every pane of the window.
    let surfaceIDs: [UUID]
    /// A structured space's window (ContainerTab): selected, moved and closed as one.
    let window: Bool
    /// The native pane holding the tab, where a dropped tab lands beside it; nil for a window.
    let pane: UUID?
}

extension Workspace {
    /// Every tab the sidebar lists in tabs-only mode, in the spaces' presentation order: a native space's panes in
    /// reading order (as the pane digits number them), each pane's tabs in order; a structured space's windows as
    /// its strip orders them.
    var sidebarTabs: [SidebarTab] {
        presentationSpaces.flatMap { space -> [SidebarTab] in
            if space.structured {
                let ordered = space.presentation?.orderedWindows ?? []
                let known = Set(ordered)
                return (ordered + space.containers.map(\.id).filter { !known.contains($0) }).compactMap { id in
                    space.containers.first { $0.id == id }.map { window in
                        let surfaces = window.terminals.flatMap(\.surfaceIDs)
                        return SidebarTab(id: window.id, space: space.id, host: host(of: surfaces, in: space),
                                          surfaceIDs: surfaces, window: true, pane: nil)
                    }
                }
            }
            return space.numberedPaneIDs.flatMap { paneID -> [SidebarTab] in
                guard let pane = space.panes.first(where: { $0.id == paneID }) else { return [] }
                return pane.tabs.map { tab in
                    SidebarTab(id: tab.id, space: space.id, host: host(of: tab.surfaceIDs, in: space),
                               surfaceIDs: tab.surfaceIDs, window: false, pane: pane.id)
                }
            }
        }
    }

    /// The host a tab's terminal reached, else its space's.
    private func host(of surfaces: [UUID], in space: Space) -> HostID {
        surfaces.lazy.compactMap { self.hosts.terminals[$0]?.host }.first ?? space.hostID
    }

    /// The listed tab that is active: the current space's selected window, or its focused pane's tab.
    var selectedSidebarTab: UUID? {
        guard let space = current else { return nil }
        if space.structured { return space.selectedContainer ?? space.containers.first?.id }
        return space.activeTab?.id
    }

    func selectSidebarTab(_ id: UUID) {
        if spaces.contains(where: { $0.containers.contains { $0.id == id } }) { selectWindow(id) } else { selectTab(id) }
    }

    /// The listed tabs the chrome counts (as `lastingSpaceCount` counts spaces): a launching tab that is already
    /// leaving does not count beside the window it launched.
    var lastingTabCount: Int {
        guard !retiringLaunchers.isEmpty else { return sidebarTabs.count }
        return sidebarTabs.count { !retiringLaunchers.contains($0.id) }
    }

    /// ⌘1…9 in tabs-only mode: the first eight listed tabs, then the last.
    func selectSidebarTab(at index: Int) {
        let order = sidebarTabs
        let index = index == 8 ? order.count - 1 : index
        if order.indices.contains(index) { selectSidebarTab(order[index].id) }
    }

    /// ⌘[ / ⌘] and ⌃⇥ in tabs-only mode: the listed tab before or after the active one, wrapping.
    func cycleSidebarTab(_ delta: Int) {
        let order = sidebarTabs.map(\.id)
        guard let selected = selectedSidebarTab, let index = order.firstIndex(of: selected) else { return }
        selectSidebarTab(order[(index + delta + order.count) % order.count])
    }
}
