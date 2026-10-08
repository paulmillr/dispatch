import Foundation
import Observation

/// All ownership changes happen here. Views never own shell lifetime.
@MainActor @Observable
final class Workspace {
    // Layout mutations publish a complete value through updateLayout. Readers observe its structure; a change
    // to tab titles or directories alone notifies only the views that show them (`liveTab`, `liveSpace`,
    // `liveName`, `directory(forSurface:)`), so a terminal title never re-renders the whole window.
    @ObservationIgnored private var committedLayout = WorkspaceLayout(spaces: [], selectedSpace: nil)
    private var structureRevision: UInt64 = 0
    @ObservationIgnored private var labelRevisions: [UUID: TabLabelRevisions] = [:]
    private var layout: WorkspaceLayout {
        _ = structureRevision
        return committedLayout
    }
    var spaces: [Space] {
        get { layout.spaces }
        set { commitLayout(WorkspaceLayout(spaces: newValue, selectedSpace: selectedSpace)) }
    }
    private(set) var layoutRevision: UInt64 = 0
    let hostMoveMotion = HostMoveMotion()
    let footerLayout = WorkspaceFooterLayout()
    let prefixKeys = PrefixKeys()
    var selectedSpace: UUID? {
        get { layout.selectedSpace }
        set { commitLayout(WorkspaceLayout(spaces: spaces, selectedSpace: newValue)) }
    }
    var focusRequest = UUID()
    struct PaneFocusFeedback {
        let id = UUID()
        let paneID: UUID
        let expiresAt = Date.now.addingTimeInterval(0.55)
    }
    var paneFocusFeedback: PaneFocusFeedback?
    var defaultDirectory = NSHomeDirectory()
    let hosts = HostRegistry()
    var spaceOrder: SpaceOrder = .tree
    @ObservationIgnored var hostPlacements: [UUID: HostPlacement] = [:]
    @ObservationIgnored var owningMachineForTab: ((TerminalTab) -> TerminalMachine)?
    @ObservationIgnored var onForgetHost: () -> Void = {}
    @ObservationIgnored var onCloseTabs: ([UUID]) -> Void = { _ in }
    @ObservationIgnored var machineForTab: ((TerminalTab) -> TerminalMachine)?
    @ObservationIgnored var helpers: [HelperWorkspace.Endpoint: HelperWorkspace] = [:]
    /// Per multiplexer (the helper's name): close the launching tab once its client attaches.
    var closeLaunching: [String: Bool] = [:]
    /// Launching tabs that close once their multiplexer releases them (Herdr): shown until then, already leaving.
    var retiringLaunchers: Set<UUID> = []
    /// Spaces the chrome tells apart (a sidebar hidden for one space, the title row's space name). A space of
    /// only retiring launchers is leaving: counting it beside the spaces they launched would flash both.
    var lastingSpaceCount: Int {
        guard !retiringLaunchers.isEmpty else { return spaces.count }
        return spaces.count { space in space.tabs.isEmpty || !space.tabs.allSatisfy { retiringLaunchers.contains($0.id) } }
    }

    /// Compute the complete next layout off the observable storage. A throwing
    /// mutation leaves the current layout and its effects unchanged.
    @discardableResult
    func updateLayout<Result>(_ update: (inout WorkspaceLayout) throws -> Result) rethrows -> Result {
        var next = committedLayout
        let result = try update(&next)
        commitLayout(next)
        return result
    }

    private func commitLayout(_ next: WorkspaceLayout) {
        guard committedLayout != next else { return }
        let previous = committedLayout
        let changed = previous.spaces != next.spaces
        if changed {
            // Capture departure chrome before publishing the completed layout.
            hostMoveMotion.reconcile(from: previous.spaces, to: next.spaces, groupedByHost: spaceOrder == .tree)
        }
        let labels = changed ? Self.labelChanges(from: previous.spaces, to: next.spaces) : (titles: [], directories: [])
        let structural = previous.selectedSpace != next.selectedSpace
            || (labels.titles.isEmpty && labels.directories.isEmpty)
            || Self.unlabeled(previous.spaces) != Self.unlabeled(next.spaces)
        committedLayout = next
        if changed { layoutRevision &+= 1 }
        if structural {
            structureRevision &+= 1
            let tabs = Set(next.spaces.flatMap(\.tabs).map(\.id))
            labelRevisions = labelRevisions.filter { tabs.contains($0.key) }
        }
        for id in labels.titles { labelRevisions[id]?.title &+= 1 }
        for id in labels.directories { labelRevisions[id]?.directory &+= 1 }
    }

    /// Tabs whose shown title (automatic or custom) or directory differs between two layouts.
    private static func labelChanges(from old: [Space], to new: [Space]) -> (titles: [UUID], directories: [UUID]) {
        let before = Dictionary(old.flatMap(\.tabs).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var titles: [UUID] = [], directories: [UUID] = []
        for tab in new.flatMap(\.tabs) {
            guard let previous = before[tab.id] else { continue }
            if previous.title != tab.title || previous.customTitle != tab.customTitle { titles.append(tab.id) }
            if previous.directory != tab.directory { directories.append(tab.id) }
        }
        return (titles, directories)
    }

    private static func unlabeled(_ spaces: [Space]) -> [Space] {
        spaces.map { space in
            var space = space
            space.updateTabs { $0.title = ""; $0.customTitle = nil; $0.directory = "" }
            return space
        }
    }

    private func observeLabels(of id: UUID, title: Bool = true, directory: Bool = true) {
        let revisions = labelRevisions[id] ?? TabLabelRevisions()
        labelRevisions[id] = revisions
        if title { _ = revisions.title }
        if directory { _ = revisions.directory }
    }

    /// The tab's current value; reading it in a view re-renders on its title or directory as well as on the layout.
    func liveTab(_ id: UUID) -> TerminalTab? {
        observeLabels(of: id)
        return committedLayout.spaces.lazy.flatMap(\.tabs).first { $0.id == id }
    }

    /// The space with its tabs' current titles and directories.
    func liveSpace(_ space: Space) -> Space {
        for tab in space.tabs { observeLabels(of: tab.id) }
        return committedLayout.spaces.first { $0.id == space.id } ?? space
    }

    /// The space's current name, which can follow its first tab's directory.
    func liveName(_ space: Space) -> String {
        if space.usesDirectoryName, let first = space.tabs.first { observeLabels(of: first.id, title: false) }
        return (committedLayout.spaces.first { $0.id == space.id } ?? space).name
    }

    var current: Space? { spaces.first { $0.id == selectedSpace } }
    var activeTab: TerminalTab? { current?.activeTab }
    var activeSurfaceID: UUID? { activeTab?.focusedSurfaceID }
    func isSurfacePresented(_ id: UUID) -> Bool {
        guard let space = current else { return false }
        return space.panes.contains { pane in
            guard space.layout.paneIDs.contains(pane.id), let tab = pane.activeTab else { return false }
            return tab.surfaceIDs.contains(id)
        }
    }
    func directory(forSurface id: UUID) -> String? {
        observeLabels(of: id, title: false)
        return committedLayout.spaces.lazy.flatMap(\.tabs).first { $0.id == id }?.directory
    }
    var allTabIDs: Set<UUID> { Set(spaces.flatMap { $0.tabs.map(\.id) }) }
    var allSurfaceIDs: Set<UUID> { allTabIDs }

    typealias TabLocation = (space: Int, pane: Int, tab: Int)

    func location(ofTab id: UUID) -> TabLocation? {
        WorkspaceLayout(spaces: spaces, selectedSpace: selectedSpace).location(ofTab: id)
    }

    private func location(ofPane id: UUID) -> (space: Int, pane: Int)? {
        WorkspaceLayout(spaces: spaces, selectedSpace: selectedSpace).location(ofPane: id)
    }

    func newSpace() {
        if followsDetectedSSH { newNativeSpace(); return }
        newBackendSpace()
    }

    func newSpaceSource(on host: HostID) -> Space? {
        if let current, current.hostID == host { return current }
        let candidates = presentationSpaces.filter { $0.hostID == host }
        return candidates.first { $0.structured } ?? candidates.first
    }

    /// A new space on a host: its terminal runs there (through ssh for another host), starting that
    /// backend's program when one is chosen.
    func newSpace(on host: HostID, backend: SpaceBackend? = nil) {
        let sources = [newSpaceSource(on: host)].compactMap { $0 }
            + (backend == nil ? [] : presentationSpaces.filter { $0.hostID == host })
        if backend != .native, let source = sources.first(where: { space in
            guard space.structured, let node = space.backend, let helper = helper(space) else { return false }
            return helper.external(node) && (backend == nil || helper.multiplexer(of: node) == backend?.rawValue)
        }), let helper = helper(source), let node = source.backend {
            helper.create(node, in: source)
            return
        }
        guard let machine = newSpaceMachine(on: host) else { return }
        var tab = TerminalTab(directory: defaultDirectory)
        tab.machine = machine
        tab.launchCommand = machine.command(running: backend?.command)
        hosts.seed(tab.id, from: host, generation: UUID())
        var space = Space(name: nextSpaceName, tab: tab, usesDirectoryName: true)
        space.hostID = host
        addSpace(space)
    }

    func newSpaceMachine(on host: HostID) -> TerminalMachine? {
        if host == .local { return .local }
        guard let source = newSpaceSource(on: host), let tab = source.activeTab else { return nil }
        return machineForTab?(tab) ?? tab.machine
    }

    /// The helper hosting a space's backend: its SSH link's, else this Mac's.
    func helper(_ space: Space?) -> HelperWorkspace? {
        helpers[space?.remote.map { .remote($0) } ?? .local]
    }

    /// The helper of the space holding this space, window or tab id.
    func helper(containing id: UUID) -> HelperWorkspace? {
        helper(spaces.first { $0.id == id || $0.containers.contains { $0.id == id } || $0.tabs.contains { $0.id == id } })
    }

    func newBackendSpace() {
        if let current, let helper = helper(current), !current.containers.isEmpty, let backend = current.backend {
            helper.create(backend, in: current)
        } else {
            newNativeSpace()
        }
    }

    var currentMachine: TerminalMachine { resolveMachine(using: machineForTab) }
    var owningMachine: TerminalMachine { resolveMachine(using: owningMachineForTab) }

    private func resolveMachine(using resolve: ((TerminalTab) -> TerminalMachine)?) -> TerminalMachine {
        guard let tab = activeTab else { return .local }
        if let resolve { return resolve(tab) }
        return tab.machine
    }

    var followsDetectedSSH: Bool {
        guard current?.structured == true else { return false }
        return currentMachine != .local && currentMachine != owningMachine
    }

    func newNativeSpace() {
        let tab = makeNativeTab(machine: currentMachine, directory: defaultDirectory)
        var space = Space(name: nextSpaceName, tab: tab, usesDirectoryName: true)
        if let context = hosts.terminals[tab.id] { space.hostID = context.host }
        addSpace(space)
    }

    private func makeNativeTab(machine: TerminalMachine, directory: String) -> TerminalTab {
        var tab = TerminalTab(directory: directory)
        tab.machine = machine; tab.launchCommand = machine.command()
        if machine != .local, let source = activeSurfaceID, let context = hosts.terminals[source] {
            hosts.seed(tab.id, from: context.host, generation: UUID())
        }
        return tab
    }

    /// A new space on this Mac; its terminal starts `program` when given (a multiplexer's client,
    /// which the multiplexer then opens as its own space).
    func newLocalSpace(program: String? = nil) {
        var tab = TerminalTab(directory: defaultDirectory)
        tab.launchCommand = program
        addSpace(Space(name: nextSpaceName, tab: tab, usesDirectoryName: true))
    }

    func addSpace(_ space: Space) {
        updateLayout { next in next.spaces.append(space); next.selectedSpace = space.id }
        selectSpace(space.id)
    }

    var nextSpaceName: String {
        Self.nextSpaceName(in: spaces)
    }

    static func nextSpaceName(in spaces: [Space]) -> String {
        let used = Set(spaces.map(\.name))
        var number = 1
        while true {
            var value = number
            var suffix = ""
            while value > 0 {
                value -= 1
                suffix = String(UnicodeScalar(65 + value % 26)!) + suffix
                value /= 26
            }
            let name = "Space \(suffix)"
            if !used.contains(name) { return name }
            number += 1
        }
    }

    @discardableResult
    func reorderSpace(_ id: UUID, relativeTo target: UUID, after: Bool) -> Bool {
        guard id != target, let source = spaces.firstIndex(where: { $0.id == id }),
              let destinationSpace = spaces.first(where: { $0.id == target }),
              spaceOrder != .tree || spaces[source].hostID == destinationSpace.hostID else { return false }
        // The sidebar owns one order across all backends. Server snapshots
        // update these slots in place instead of grouping spaces by endpoint.
        updateLayout { next in
            let space = next.spaces.remove(at: source)
            let destination = next.spaces.firstIndex(where: { $0.id == target })!
            next.spaces.insert(space, at: destination + (after ? 1 : 0))
        }
        return true
    }

    func selectSpace(_ id: UUID, node: UInt64? = nil) {
        guard spaces.contains(where: { $0.id == id }) else { return }
        selectedSpace = id
        focusRequest = UUID()
        let container = current?.containers.first { $0.id == current?.activeWindow?.id }
        if let target = node ?? container?.node ?? activeTab?.terminal { helper(current)?.focus(target) }
    }

    func selectTab(_ id: UUID) {
        guard let space = updateLayout({ $0.selectTab(id) }) else { return }
        selectSpace(space, node: activeTab?.terminal)
    }

    func selectSurface(_ id: UUID) {
        if activeSurfaceID == id { return }
        selectTab(id)
    }

    func newTab() {
        newTab(placement: current?.focusedPane)
    }

    private func newTab(placement: UUID?, splitting edge: PaneEdge? = nil) {
        let nativeSplit = edge.flatMap { edge in
            current.flatMap { space in space.activeTab.map { NativeSplitPlacement(space: space, original: $0, edge: edge) } }
        }
        if let current, let helper = helper(current), let node = current.node, !current.containers.isEmpty {
            helper.create(node, in: current, splitting: nativeSplit)
            return
        }
        guard let s = spaces.firstIndex(where: { $0.id == selectedSpace }),
              let p = spaces[s].panes.firstIndex(where: { $0.id == spaces[s].focusedPane }) else { newSpace(); return }
        let machine = currentMachine
        let tab = makeNativeTab(machine: machine, directory: machine == .local ? activeTab?.directory ?? defaultDirectory : defaultDirectory)
        updateLayout { next in
            next.spaces[s].panes[p].tabs.append(tab)
            if let edge {
                let host = hosts.terminals[tab.focusedSurfaceID]?.host ?? next.spaces[s].hostID
                if host == next.spaces[s].hostID,
                   tab.surfaceIDs.allSatisfy({ (hosts.terminals[$0]?.host ?? next.spaces[s].hostID) == host }) {
                    next.splitTab(tab.id, beside: next.spaces[s].panes[p].id, edge: edge)
                }
            } else { next.selectTab(tab.id) }
        }
        selectSpace(spaces[s].id)
    }

    /// A divider drag in any space.
    func resizeDivider(_ id: UUID, in spaceID: UUID, fraction: Double) {
        resizeSplit(id, in: spaceID, fraction: fraction)
    }

    func resizeSplit(_ id: UUID, in spaceID: UUID, fraction: Double) {
        guard fraction.isFinite, let index = spaces.firstIndex(where: { $0.id == spaceID }),
              fraction > 0, fraction < 1, spaces[index].layout.splitIDs.contains(id),
              abs((spaces[index].splitRatios[id] ?? -1) - fraction) > 0.0001 else { return }
        // A server's split moves at once on screen; its next topology confirms or corrects it.
        if helper(spaces[index])?.resize(id, fraction: fraction) == true {
            updateLayout { $0.spaces[index].splitFractions[id] = CGFloat(fraction) }
            return
        }
        updateLayout { $0.spaces[index].splitRatios[id] = fraction }
    }

    private func splitToCollapse(_ axis: SplitAxis) -> [UUID]? {
        guard let current else { return nil }
        if let presentation = current.presentation,
           let group = presentation.groups.first(where: {
               $0.windows.contains { $0 == current.selectedContainer }
           }) {
            return presentation.layout.splitPanes(containing: group.id, axis: axis)
        }
        return current.layout.splitPanes(containing: current.focusedPane, axis: axis)
    }

    func canToggleSplit(_ axis: SplitAxis) -> Bool {
        guard canApplyLayout(.single), let current else { return false }
        if splitToCollapse(axis) != nil { return true }
        if !current.containers.isEmpty { return (current.presentation?.groups.count ?? 1) < 4 }
        return current.panes.count < 4
    }

    func toggleSplit(_ axis: SplitAxis) {
        guard canToggleSplit(axis) else { return }
        guard let ids = splitToCollapse(axis), let destination = ids.first,
              let s = spaces.firstIndex(where: { $0.id == selectedSpace }) else {
            createSplit(axis)
            return
        }
        if !spaces[s].containers.isEmpty, var presentation = spaces[s].presentation {
            let windows = ids.flatMap { id in presentation.groups.first { $0.id == id }?.windows ?? [] }
            guard let selected = spaces[s].selectedContainer,
                  let target = presentation.groups.firstIndex(where: { $0.id == destination }) else { return }
            presentation.groups[target].windows = windows
            presentation.groups[target].selected = selected
            presentation.groups.removeAll { ids.dropFirst().contains($0.id) }
            for id in ids.dropFirst() {
                if let layout = presentation.layout.removing(id) { presentation.layout = layout }
            }
            presentation.preset = presentation.groups.count == 1 ? .single : nil
            updateLayout { next in
                next.spaces[s].presentation = presentation
                next.spaces[s].splitRatios = next.spaces[s].splitRatios.filter { presentation.layout.splitIDs.contains($0.key) }
                next.spaces[s].selectedContainer = selected
            }
            selectSpace(spaces[s].id)
        } else {
            let tabs = ids.flatMap { id in spaces[s].panes.first { $0.id == id }?.tabs ?? [] }
            guard let selected = activeTab?.id,
                  let target = spaces[s].panes.firstIndex(where: { $0.id == destination }) else { return }
            for tab in tabs { supersedeHostPlacement(tab.id) }
            updateLayout { next in
                next.spaces[s].panes[target] = Pane(id: destination, tabs: tabs, selected: selected)
                next.spaces[s].panes.removeAll { ids.dropFirst().contains($0.id) }
                for id in ids.dropFirst() {
                    if let layout = next.spaces[s].layout.removing(id) { next.spaces[s].layout = layout }
                }
                next.spaces[s].preset = next.spaces[s].panes.count == 1 ? .single : nil
                let splitIDs = next.spaces[s].layout.splitIDs
                next.spaces[s].splitRatios = next.spaces[s].splitRatios.filter { splitIDs.contains($0.key) }
                next.selectTab(selected)
            }
            selectSpace(spaces[s].id)
        }
    }

    struct NativeSplitPlacement {
        let space: UUID
        let pane: UUID
        let originalTab: UUID
        let originalWindow: UUID?
        let edge: PaneEdge

        init(space: Space, original: TerminalTab, edge: PaneEdge) {
            self.space = space.id
            pane = space.focusedPane
            originalTab = original.id
            originalWindow = space.selectedContainer
            self.edge = edge
        }

        func apply(to layout: inout WorkspaceLayout, createdTab: UUID) -> Bool {
            guard layout.selectedSpace == space, createdTab != originalTab,
                  let s = layout.spaces.firstIndex(where: { $0.id == space }),
                  layout.spaces[s].tabs.contains(where: { $0.id == createdTab }) else { return false }
            let windows = layout.spaces[s].containers
            if let originalWindow,
               let created = windows.first(where: { $0.terminals.contains(where: { $0.id == createdTab }) }) {
                var presentation = layout.spaces[s].presentation
                    ?? TabPresentation(windows: windows.map(\.id), selected: created.id, preset: .single)
                presentation.select(originalWindow)
                guard presentation.move(created.id, beside: originalWindow, edge: edge) else { return false }
                layout.spaces[s].presentation = presentation
                layout.spaces[s].selectedContainer = created.id
                return true
            }
            guard let p = layout.spaces[s].panes.firstIndex(where: { $0.id == pane }) else { return false }
            layout.spaces[s].panes[p].selected = originalTab
            return layout.splitTab(createdTab, beside: pane, edge: edge) != nil
        }
    }

    private func createSplit(_ axis: SplitAxis) {
        guard current != nil, activeTab != nil else { return }
        newTab(placement: nil, splitting: axis == .columns ? .right : .bottom)
    }

    func split(_ axis: SplitAxis) {
        guard let current else { return }
        if let selected = current.selectedContainer, !current.containers.isEmpty {
            let members = current.presentation?.groups.first { $0.windows.contains(selected) }?.windows ?? current.containers.map(\.id)
            if let other = members.first(where: { $0 != selected }) {
                _ = moveContainer(selected, beside: other, edge: axis == .columns ? .right : .bottom)
            }
            return
        }
        guard let pane = current.activePane,
              pane.tabs.count > 1 else { return }
        splitTab(pane.selected, beside: pane.id, edge: axis == .columns ? .right : .bottom)
    }

    @discardableResult
    func applyLayout(_ preset: LayoutPreset) -> Bool {
        guard let current else { return false }
        guard let s = spaces.firstIndex(where: { $0.id == selectedSpace }) else { return false }
        if !current.containers.isEmpty {
            let windows = current.presentation?.orderedWindows ?? current.containers.map(\.id)
            guard windows.count >= preset.count, let selected = current.selectedContainer else { return false }
            var presentation = current.presentation ?? TabPresentation(windows: windows, selected: selected, preset: .single)
            let groups = presentation.groups.map { LayoutPreset.TabGroup(id: $0.id, tabs: $0.windows, selected: $0.selected) }
            let arranged = preset.arrange(groups, in: presentation.layout, selected: selected)
            presentation.groups = arranged.map { .init(id: $0.id, windows: $0.tabs, selected: $0.selected) }
            presentation.layout = preset.layout(arranged.map(\.id)); presentation.preset = preset
            updateLayout { next in
                next.spaces[s].presentation = presentation
                next.spaces[s].splitRatios = [:]
            }
            focusRequest = UUID()
            return true
        }
        let tabs = current.tabs
        guard tabs.count >= preset.count, let selected = activeTab?.id else { return false }
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let groups = current.panes.map { LayoutPreset.TabGroup(id: $0.id, tabs: $0.tabs.map(\.id), selected: $0.selected) }
        let panes = preset.arrange(groups, in: current.layout, selected: selected).map { group in
            Pane(id: group.id, tabs: group.tabs.compactMap { byID[$0] }, selected: group.selected)
        }
        let ids = panes.map(\.id)
        updateLayout { next in
            next.spaces[s].layout = preset.layout(ids)
            next.spaces[s].panes = panes; next.spaces[s].preset = preset
            next.spaces[s].splitRatios = [:]
            next.selectTab(selected)
        }
        selectSpace(spaces[s].id)
        return true
    }

    func canSplitTab(_ id: UUID, beside target: UUID) -> Bool {
        guard hostsAllowMove(id, to: target) else { return false }
        if let source = container(containing: id) {
            guard let destination = container(at: target),
                  let space = spaces.first(where: { $0.containers.contains { $0.id == source.id } }),
                  space.containers.contains(where: { $0.id == destination.id }), source.id != destination.id else { return false }
            var presentation = space.presentation
                ?? TabPresentation(windows: space.containers.map(\.id), selected: source.id, preset: .single)
            return presentation.move(source.id, beside: destination.id, edge: .right)
        }
        guard let destination = location(ofPane: target), let location = location(ofTab: id),
              destination.space == location.space else { return false }
        let space = spaces[location.space]
        let source = space.panes[location.pane]
        return (source.id != target || source.tabs.count > 1) &&
            (space.panes.count < 4 || (source.id != target && source.tabs.count == 1))
    }

    @discardableResult
    func splitTab(_ id: UUID, beside target: UUID, edge: PaneEdge) -> Bool {
        guard canSplitTab(id, beside: target) else { return false }
        supersedeHostPlacement(id)
        if let source = container(containing: id), let other = container(at: target) {
            return moveContainer(source.id, beside: other.id, edge: edge)
        }
        guard canSplitTab(id, beside: target) else { return false }
        let space = updateLayout { $0.splitTab(id, beside: target, edge: edge) }
        guard let space else { return false }
        selectSpace(space)
        return true
    }

    /// A programmatic close never asks (the user's Close Tab passes `.prompt`, as only user actions
    /// confirmed before): an external multiplexer's session keeps its work (detach), the app's own ends.
    func closeTab(_ id: UUID, policy: HelperClient.Policy? = nil) {
        if let space = spaces.first(where: { $0.tabs.contains { $0.id == id } }),
           let terminal = space.tabs.first(where: { $0.id == id })?.terminal, let helper = helper(space) {
            helper.close(terminal, policy: policy ?? (space.backend.map(helper.external) == true ? .prompt : .terminate))
            return
        }
        guard let (s, p, _) = location(ofTab: id) else { return }
        let tab = spaces[s].tabs.first { $0.id == id }!
        let spaceID = spaces[s].id
        let collapsesPane = spaces[s].panes[p].tabs.count == 1
        updateLayout { next in
            _ = next.detachTab(id)
            if collapsesPane, let index = next.spaces.firstIndex(where: { $0.id == spaceID }), next.spaces[index].panes.count == 1 {
                next.spaces[index].preset = .single
            }
        }
        onCloseTabs(tab.surfaceIDs)
        focusRequest = UUID()
    }

    /// Same policy as `closeTab`: a programmatic close never asks.
    func closeSpace(_ id: UUID, policy: HelperClient.Policy? = nil) {
        if helpers.values.contains(where: { $0.dismiss(id) }) { return }
        guard let s = spaces.firstIndex(where: { $0.id == id }) else { return }
        if spaces[s].backend != nil, spaces[s].containers.isEmpty {
            for tab in spaces[s].tabs { closeTab(tab.id, policy: policy) }
            return
        }
        if let node = spaces[s].node, let helper = helper(spaces[s]) {
            if policy == nil, spaces[s].backend.map(helper.external) == true {
                for container in spaces[s].containers { helper.close(container.node, policy: .prompt) }
                return
            }
            helper.close(node, policy: policy ?? (spaces[s].backend.map(helper.external) == true ? .detach : .terminate))
            return
        }
        detachSpace(id)
    }

    func detachSpace(_ id: UUID) {
        guard let s = spaces.firstIndex(where: { $0.id == id }) else { return }
        if spaces[s].node != nil, !spaces[s].containers.isEmpty, let helper = helper(spaces[s]) { helper.detachSpace(spaces[s]); return }
        let ids = spaces[s].tabs.flatMap(\.surfaceIDs)
        removeSpace(at: s)
        onCloseTabs(ids)
        focusRequest = UUID()
    }

    /// Forgetting a host clears everything it still presents: tabs left in other hosts' spaces and spaces
    /// a disconnected backend could not reconcile away. Only presentation goes; server work keeps running.
    func removeHostPresentation(_ host: HostID) {
        let onHost = { (tab: TerminalTab) in tab.surfaceIDs.contains { self.hosts.terminals[$0]?.host == host } }
        for space in spaces.filter({ space in
            space.hostID != host && space.backend.flatMap { helper(space)?.multiplexer(of: $0) } != "tmux"
        }) {
            if let helper = helper(space), !space.containers.isEmpty {
                for container in space.containers where container.terminals.contains(where: onHost) {
                    helper.close(container.node, policy: .detach)
                }
            } else {
                for tab in space.tabs where onHost(tab) { closeTab(tab.id, policy: .detach) }
            }
        }
        for space in spaces.filter({ $0.hostID == host }) {
            closeSpace(space.id, policy: .detach)
        }
    }

    private func removeSpace(at index: Int) {
        updateLayout { $0.removeSpace(at: index) }
    }

    func renameSpace(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = spaces.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        if let helper = helper(spaces[s]) { helper.rename(id, name: name); return }
        updateLayout { $0.spaces[s].name = name }
    }

    func updateTab(_ id: UUID, title: String? = nil, directory: String? = nil, customTitle: String? = nil) {
        if let helper = helper(containing: id), let customTitle {
            helper.rename(id, name: customTitle)
            return
        }
        guard let s = spaces.firstIndex(where: { $0.tabs.contains { $0.id == id } }) else { return }
        updateLayout { next in
            next.spaces[s].updateTabs { tab in
                guard tab.id == id else { return }
                if let title { tab.title = title }
                if let directory { tab.directory = directory }
                if let customTitle { tab.customTitle = customTitle.isEmpty ? nil : customTitle }
            }
        }
    }

    func cycleSpace(_ delta: Int) {
        let order = presentationSpaces
        guard let index = order.firstIndex(where: { $0.id == selectedSpace }) else { return }
        selectSpace(order[(index + delta + order.count) % order.count].id)
    }

    func cyclePane(_ delta: Int) {
        guard let space = current, let index = space.layout.paneIDs.firstIndex(of: space.focusedPane) else { return }
        let ids = space.layout.paneIDs
        let target = ids[(index + delta + ids.count) % ids.count]
        if let pane = space.panes.first(where: { $0.id == target }) { selectTab(pane.selected) }
    }

    @discardableResult
    func moveTab(_ id: UUID, to paneID: UUID, relativeTo target: UUID? = nil, after: Bool = false) -> Bool {
        guard hostsAllowMove(id, to: paneID) else { return false }
        if let source = container(containing: id), let other = container(at: paneID) {
            var destination = other
            if let target {
                guard target != id, let container = container(containing: target) else { return false }
                let members = spaces.first { $0.containers.contains { $0.id == other.id } }?
                    .presentation?.groups.first { $0.windows.contains(other.id) }?.windows ?? [other.id]
                guard members.contains(container.id) else { return false }
                destination = container
            }
            let moved = moveContainer(source.id, beside: destination.id, edge: nil, after: after)
            if moved { supersedeHostPlacement(id) }
            return moved
        }
        guard let (destinationSpace, destinationPane) = location(ofPane: paneID),
              location(ofTab: id) != nil else { return false }
        let destination = spaces[destinationSpace].panes[destinationPane]
        if let target { guard target != id, destination.tabs.contains(where: { $0.id == target }) else { return false } }
        if let source = destination.tabs.firstIndex(where: { $0.id == id }) {
            guard let target else { return false }
            supersedeHostPlacement(id)
            updateLayout { next in
                let tab = next.spaces[destinationSpace].panes[destinationPane].tabs.remove(at: source)
                let index = next.spaces[destinationSpace].panes[destinationPane].tabs.firstIndex { $0.id == target }!
                next.spaces[destinationSpace].panes[destinationPane].tabs.insert(tab, at: index + (after ? 1 : 0))
            }
            return true
        }
        supersedeHostPlacement(id)
        let space: UUID? = updateLayout { next in
            guard let tab = next.detachTab(id), let (s, p) = next.location(ofPane: paneID) else { return nil }
            let index = target.flatMap { id in next.spaces[s].panes[p].tabs.firstIndex { $0.id == id } }
                .map { $0 + (after ? 1 : 0) } ?? next.spaces[s].panes[p].tabs.count
            next.spaces[s].panes[p].tabs.insert(tab, at: index)
            return next.selectTab(id)
        }
        guard let space else { return false }
        selectSpace(space)
        return true
    }

    func canMoveTab(_ id: UUID, to paneID: UUID) -> Bool {
        guard hostsAllowMove(id, to: paneID) else { return false }
        if let from = container(containing: id) {
            guard let to = container(at: paneID), from.id != to.id,
                  let source = spaces.first(where: { $0.containers.contains { $0.id == from.id } }),
                  let destination = spaces.first(where: { $0.containers.contains { $0.id == to.id } }),
                  source.backend == destination.backend, source.remote == destination.remote,
                  source.hostID == destination.hostID else { return false }
            if source.id != destination.id { return helper(source) != nil }
            var presentation = source.presentation
                ?? TabPresentation(windows: source.containers.map(\.id), selected: from.id, preset: .single)
            return presentation.move(from.id, beside: to.id, edge: nil)
        }
        return location(ofTab: id) != nil && location(ofPane: paneID) != nil
    }

    func moveTabToNewSpace(_ id: UUID) {
        if let container = container(containing: id) {
            moveWindowToNewSpace(container.id)
            return
        }
        guard spaces.contains(where: { $0.tabs.contains { $0.id == id } }) else { return }
        guard location(ofTab: id) != nil else { return }
        supersedeHostPlacement(id)
        let selected: UUID? = updateLayout { next in
            guard let tab = next.detachTab(id) else { return nil }
            var space = Space(name: Self.nextSpaceName(in: next.spaces), tab: tab, usesDirectoryName: true)
            space.hostID = hosts.terminals[id]?.host ?? .local
            next.spaces.append(space)
            return next.selectTab(id)
        }
        if let selected { selectSpace(selected) }
    }

    /// Repairs ownership and selection; only the caller decides whether to close the shell.
    func detachTab(_ id: UUID) -> TerminalTab? {
        updateLayout { $0.detachTab(id) }
    }
}

/// One tab's label changes, observed apart from the layout.
@MainActor @Observable
final class TabLabelRevisions {
    var title: UInt64 = 0
    var directory: UInt64 = 0
}

extension Space {
    /// Visits every tab where it's stored: the native arrangement, or each container's.
    mutating func updateTabs(_ update: (inout TerminalTab) -> Void) {
        func visit(_ arrangement: inout PaneArrangement) {
            for p in arrangement.panes.indices {
                for t in arrangement.panes[p].tabs.indices { update(&arrangement.panes[p].tabs[t]) }
            }
        }
        if containers.isEmpty { visit(&arrangement) }
        else { for c in containers.indices { visit(&containers[c].arrangement) } }
    }
}
