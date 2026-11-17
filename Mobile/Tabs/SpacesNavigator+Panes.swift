import Foundation

/// The iPad detail column's panes (docs/ios.md, iPad › Panes; `PadPanes`): Split Right and Split Down (⌘D ⇧⌘D, the
/// mode button's menu) open a new tab beside the focused one, a pill's Open in Split shows a tab beside it, Merge Panes
/// joins the innermost split, Previous and Next Pane (⌥⌘[ ⌥⌘]) and a tap move the focus. The focused pane is the path's
/// tab and what is pushed over it, so every command, the sidebar's mark and Agents act on it; the others keep theirs in
/// `panes` until focused.
extension SpacesNavigator {
    /// Panes apply in an iPad's split; the Duo's tab and the stack show the focused pane alone.
    var panesApply: Bool { sidebarHides && split }

    /// The pane `id` takes the focus: the focused one keeps its tab and what was pushed over it, and `id`'s come back
    /// onto the path.
    func focusPane(_ id: PadPanes.ID) {
        guard panesApply, id != panes.focused else { return }
        let shown = splitPath
        guard let target = panes.focus(id, leaving: shown.tab, detail: shown.detail) else { return }
        path = shown.sidebar + (target.tab.map { [.tab($0)] } ?? []) + target.detail
    }

    /// Previous and Next Pane (⌥⌘[ ⌥⌘]): the pane before or after the focused one in reading order, round the end.
    func stepPane(_ delta: Int) {
        let order = panes.leaves.map(\.id)
        guard panesApply, order.count > 1, let index = order.firstIndex(of: panes.focused) else { return }
        focusPane(order[((index + delta) % order.count + order.count) % order.count])
    }

    /// Split Right or Split Down fits: a tab is shown in an iPad's split, the column holds fewer than four panes and
    /// both halves of the focused one keep the least a pane needs (`PadPanes.minimum`).
    func canSplitPane(_ axis: PadPanes.Axis) -> Bool {
        guard panesApply, splitPath.tab.flatMap(model.tab) != nil else { return false }
        return panes.canSplit(panes.focused, axis: axis, in: paneRoom)
    }

    /// Split Right or Split Down (⌘D ⇧⌘D), as the Mac's: a new tab in the focused tab's space and folder, in a new pane
    /// beside the focused one, which takes the focus; a plain host's Shell space gets a new shell.
    func splitPane(_ axis: PadPanes.Axis) {
        guard canSplitPane(axis), let ref = splitPath.tab, let tab = model.tab(ref), let space = model.space(tab.space),
              let workspace = model.workspace(ref.host), workspace.canAddTab(to: space) else { return }
        let pane = panes.focused
        if space.kind == .plainShell {
            do { split(pane, axis, showing: try model.newShell(on: ref.host).ref) } catch {
                actions.failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            return
        }
        Task {
            do {
                let new = try await workspace.newTab(in: space, cwd: tab.cwd)
                model.visited(new.space)
                model.segments[new.ref] = .terminal
                split(pane, axis, showing: new.ref)
            } catch {
                actions.failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Whether `tab` can open in a split beside `pane` (a pill's Open in Split): it is not shown in a pane already, and
    /// the pane has the room.
    func canOpenBeside(_ tab: TabRef, pane: PadPanes.ID, axis: PadPanes.Axis) -> Bool {
        guard panesApply, splitPath.tab != tab, panes.pane(showing: tab) == nil else { return false }
        return panes.canSplit(pane, axis: axis, in: paneRoom)
    }

    /// `tab` in a new pane beside `pane` along `axis`, focused. A tab another pane shows leaves that pane; without the
    /// room (the window narrowed while a new tab was made), the focused pane shows it.
    func split(_ pane: PadPanes.ID, _ axis: PadPanes.Axis, showing tab: TabRef) {
        guard panesApply, splitPath.tab != tab, panes.leaf(pane)?.tab != tab else { return }
        if let other = panes.pane(showing: tab), other != pane { panes.remove(other) }
        let target = panes.leaf(pane) != nil ? pane : panes.focused
        guard panes.canSplit(target, axis: axis, in: paneRoom) else { return select(tab) }
        focusPane(target)
        let shown = splitPath
        guard panes.split(target, axis: axis, keeping: shown.tab, detail: shown.detail) != nil else { return select(tab) }
        path = shown.sidebar + [.tab(tab)]
    }

    /// View › Merge Panes, as the Mac's: the innermost split around the focused pane becomes that pane; the tabs the
    /// others showed stay in their strips.
    func mergePanes() {
        guard panesApply, panes.isSplit else { return }
        panes.merge()
    }

    // MARK: Layouts

    /// The layout the panes have, when it is a preset's (the layout button's icon and checkmark).
    var paneLayout: PadLayout? { panes.preset }

    /// The tabs a layout may place: those the panes show, then the focused tab's space's others in strip order.
    private var layoutTabs: (shown: [TabRef], spare: [TabRef]) {
        let shown = [splitPath.tab].compactMap { $0 } + panes.otherTabs
        let strip = splitPath.tab.map { model.strip(for: $0).map(\.ref) } ?? []
        return (shown, strip.filter { !shown.contains($0) })
    }

    /// Why `layout` cannot apply now, as the Mac says it (`Workspace.layoutRefusal`): "Grid needs 4 tabs. This space has
    /// 2." or that it needs a larger window; nil when it can.
    func layoutRefusal(_ layout: PadLayout) -> String? {
        guard panesApply, splitPath.tab.flatMap(model.tab) != nil else { return "\(layout.title) needs a tab open." }
        let tabs = layoutTabs
        let open = tabs.shown.count + tabs.spare.count
        if open < layout.count { return "\(layout.title) needs \(layout.count) tabs. This space has \(open)." }
        if layout != .single, !layout.fits(paneRoom) { return "\(layout.title) needs a larger window." }
        return nil
    }

    func canApplyLayout(_ layout: PadLayout) -> Bool { layoutRefusal(layout) == nil }

    /// A layout from the layout button or the View menu, as the Mac's presets: existing tabs move into its panes and
    /// nothing starts (`PadPanes.arranged`); the focused tab keeps the focus. The layout already shown evens its
    /// dividers.
    func applyLayout(_ layout: PadLayout) {
        guard canApplyLayout(layout), let tab = splitPath.tab else { return }
        if panes.preset == layout { return panes.even() }
        if layout == .single {
            while panes.isSplit { panes.merge() }
            return
        }
        let room = CGRect(origin: .zero, size: paneRoom)
        guard let arranged = panes.arranged(layout, focused: (tab, splitPath.detail), spare: layoutTabs.spare, in: room) else {
            return
        }
        panes = arranged
    }

    /// The path's tab moved by another way than the panes' own (a sidebar row, Agents, a notification): a tab another
    /// pane shows takes the focus there, and the pane focused until now keeps what it showed (or goes, without a tab).
    func followPanes(from old: [TabsRoute]) {
        guard panesApply, panes.isSplit, let tab = splitPath.tab, let other = panes.pane(showing: tab) else { return }
        let before = Self.split(old)
        let previous = panes.focused
        _ = panes.focus(other, leaving: before.tab, detail: before.detail)
        if before.tab == nil { panes.remove(previous) }
    }

    /// The window split again (it was the stack, which showed the focused pane alone): a pane showing the tab the stack
    /// left on top goes, and without a tab on top the next pane takes the focus.
    func settlePanes() {
        guard panesApply, panes.isSplit else { return }
        for leaf in panes.leaves where leaf.id != panes.focused && (leaf.tab == nil || leaf.tab == splitPath.tab) {
            panes.remove(leaf.id)
        }
        guard splitPath.tab == nil, panes.isSplit else { return }
        let shown = splitPath
        panes.remove(panes.focused)
        let back = panes.takeFocused()
        path = shown.sidebar + (back.tab.map { [.tab($0)] } ?? []) + back.detail
    }

    /// Panes whose tab closed (`closed`, `reconcile`): each shows the next tab of its strip (`order`), else the one
    /// before, that no pane shows; without one the pane goes, and when it was the focused one the pane that takes its
    /// place takes the focus.
    func panesLost(_ isGone: (TabRef) -> Bool, order: (TabRef, PadPanes.Leaf?) -> [TabRef]) {
        guard panes.isSplit else { return }
        for leaf in panes.leaves where leaf.id != panes.focused {
            guard let tab = leaf.tab, isGone(tab) else { continue }
            if let next = neighbour(of: tab, in: order(tab, leaf), isGone: isGone) {
                panes.update(leaf.id) { $0.tab = next; $0.detail = [] }
            } else {
                panes.remove(leaf.id)
            }
        }
        let shown = splitPath
        guard panes.isSplit, let tab = shown.tab, isGone(tab) else { return }
        if let next = neighbour(of: tab, in: order(tab, nil), isGone: isGone) {
            path = shown.sidebar + [.tab(next)]
        } else {
            panes.remove(panes.focused)
            let back = panes.takeFocused()
            path = shown.sidebar + (back.tab.map { [.tab($0)] } ?? []) + back.detail
        }
    }

    /// The tab after `tab` in `order`, else the one before, that is still there and no pane shows.
    private func neighbour(of tab: TabRef, in order: [TabRef], isGone: (TabRef) -> Bool) -> TabRef? {
        guard let index = order.firstIndex(of: tab) else { return nil }
        let shown = Set(panes.otherTabs + [splitPath.tab].compactMap { $0 })
        func free(_ ref: TabRef) -> Bool { !isGone(ref) && !shown.contains(ref) && model.tab(ref) != nil }
        return order[(index + 1)...].first(where: free) ?? order[..<index].reversed().first(where: free)
    }

    /// The other panes' strips as last seen, for `panesLost` once the host closes their tab.
    func rememberPaneStrips() {
        for leaf in panes.leaves where leaf.id != panes.focused {
            guard let tab = leaf.tab.flatMap(model.tab) else { continue }
            let strip = model.strip(for: tab.ref).map(\.ref)
            if leaf.strip != strip { panes.update(leaf.id) { $0.strip = strip } }
        }
    }

    // MARK: A pane's view

    /// The tab pane `id` shows: the path's for the focused one.
    func paneTab(_ id: PadPanes.ID) -> TabRef? {
        id == panes.focused ? splitPath.tab : panes.leaf(id)?.tab
    }

    /// What pane `id`'s stack has pushed over its tab.
    func paneDetail(_ id: PadPanes.ID) -> [TabsRoute] {
        id == panes.focused ? splitPath.detail : panes.leaf(id)?.detail ?? []
    }

    /// Pane `id`'s stack moved (Back in it): the focused one's is the path's.
    func setPaneDetail(_ id: PadPanes.ID, _ routes: [TabsRoute]) {
        if id == panes.focused { return setDetail(routes) }
        if routes.contains(where: { $0.tab != nil }) {
            focusPane(id)
            return setDetail(routes)
        }
        panes.update(id) { $0.detail = routes }
    }

    /// The path as pane `id`'s tab screen sees it (it pushes onto it, `TabScreen.path`): the focused one's is the path;
    /// another's is the path it would be focused, and a change to it focuses the pane first.
    func panePath(_ id: PadPanes.ID) -> [TabsRoute] {
        guard id != panes.focused, let leaf = panes.leaf(id) else { return path }
        return splitPath.sidebar + (leaf.tab.map { [.tab($0)] } ?? []) + leaf.detail
    }

    func setPanePath(_ id: PadPanes.ID, _ routes: [TabsRoute]) {
        focusPane(id)
        path = routes
    }

    static let panesKey = "tabs.panes"

    /// The panes for the next launch (`rememberSplit`): nil without splits.
    var keptPanes: Data? {
        guard panes.isSplit else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(panes.kept)
    }

    /// The panes the last launch kept, the tabs the host's cached topology no longer has left out (`restoreSplit`).
    func restorePanes(_ data: Data?, showing tab: TabRef) {
        guard let data,
              let kept = try? JSONDecoder().decode(PadPanes.Kept.self, from: data),
              let restored = PadPanes(kept: kept, exists: { $0 != tab && self.model.tab($0) != nil }) else { return }
        panes = restored
    }
}
