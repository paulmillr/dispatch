import SwiftUI
import Term

struct SpaceSidebar: View {
    private var typography: AppTypography { AppTypography(contentSize: settings.values.fontSize) }
    /// Both densities share every layout below; only these numbers differ.
    private var metrics: SidebarMetrics {
        let metrics = settings.values.sidebarMetrics(glass: glass)
        return glass ? metrics.nested(cornerRadius: Self.glassRadius - Self.glassRowInset) : metrics
    }
    private var sidebarFont: Font { AppFont.ui(size: metrics.nameSize) }
    private var sidebarDetailFont: Font { AppFont.ui(size: metrics.detailSize) }
    /// Tabs only (Preferences.tabsOnly): the rows are tabs (SidebarTab), not spaces.
    private var tabsOnly: Bool { workspace.tabsOnly }
    /// The selected row: the current space, or tabs only's active tab.
    private var selectedRow: UUID? { tabsOnly ? workspace.selectedSidebarTab : workspace.selectedSpace }
    private func select(_ row: UUID) {
        if tabsOnly { workspace.selectSidebarTab(row) } else { workspace.selectSpace(row) }
    }
    /// The footer's host icons are the app's host icon size, like the tab bar's host button in a cell as tall.
    private var footerIconSize: CGFloat { typography.hostIconSize }
    private var footerCellHeight: CGFloat {
        glass ? StripTab.glassTrackHeight(typography) : max(typography.expanded(28), footerIconSize + 12)
    }
    /// The footer's cells sit this far inside the sidebar's edges.
    private static let footerInset: CGFloat = 4
    @Bindable var workspace: Workspace
    @Bindable var settings: SettingsStore
    let controller: AppDelegate
    var headerRowHeight: CGFloat? = nil
    /// Outside full screen the sidebar's top row carries the traffic lights, sidebar toggle, and header buttons.
    var windowControls = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection
    @State private var searchQuery = ""
    /// The tree group whose header is under the pointer, which shows its new-space button.
    @State private var hoveredHost: HostID?
    /// ⌘P opens the search field above the footer; a query keeps it open.
    private var searchOpen: Bool { controller.windowState.spaceSearchFocusRequest != nil }
    @FocusState private var searchFocused: Bool
    /// The rows' latest frames, unobserved: scrolling moves them every frame. `rowPlacements` changes only as a
    /// row crosses the viewport's edge, which is all the sidebar reads, so scrolling doesn't re-render it per frame.
    @State private var rowFrames = SpaceRowFrameStore()
    @State private var rowPlacements: [UUID: SpaceRowPlacement] = [:]
    @State private var viewportHeight: CGFloat = 0
    /// The overflow bar's height while it rides over the list's bottom (GlassScrollEdge); rows under it are hidden.
    @State private var overflowBarHeight: CGFloat = 0
    private var visibleHeight: CGFloat { viewportHeight - overflowBarHeight }
    /// The rows' own height, so the glass sidebar's top panel can end where the spaces do.
    @State private var rowsHeight: CGFloat = 0
    @State private var flatDetachedExpanded = true
    @State private var expandedDetached: Set<HostID> = []
    @State private var branches: [UUID: String] = [:]
    /// Nautical: the host whose radar sector was clicked, narrowing the traffic list to its traffic.
    @State private var harbourHost: HostID?

    private func setSearchQuery(_ value: String) {
        // Filtering can remove hundreds of rows at once. Keep typing immediate
        // instead of retaining all outgoing rows for their reorder animation.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { searchQuery = value }
    }

    /// Classifies against the current viewport, so a viewport change applies in the same update.
    private func placement(of id: UUID) -> SpaceRowPlacement? {
        rowFrames.frames[id].map { SpaceRowPlacement($0, visibleHeight: visibleHeight) }
    }

    private func updateRowPlacements() {
        let next = rowFrames.frames.mapValues { SpaceRowPlacement($0, visibleHeight: visibleHeight) }
        if next != rowPlacements { rowPlacements = next }
    }

    /// The listed rows (spaces or tabs, by id) the viewport hides.
    private func hiddenRows(in order: [UUID]) -> [UUID] {
        _ = rowPlacements
        // The overflow bar changes the scroll safe area. It must not keep itself alive
        // through shifted row frames after the complete rows stack fits again.
        guard viewportHeight > 0, rowsHeight > viewportHeight else { return [] }
        return order.filter {
            guard let placement = placement(of: $0) else { return true }
            return placement.above || placement.below
        }
    }

    private func rowsBelowViewport(in order: [UUID]) -> [UUID] {
        guard viewportHeight > 0, rowsHeight > viewportHeight else { return [] }
        let lastVisible = order.lastIndex { id in placement(of: id)?.showing ?? false } ?? -1
        return order.enumerated().compactMap { index, id in
            if let placement = placement(of: id) { return placement.below ? id : nil }
            return index > lastVisible ? id : nil
        }
    }

    /// Each row's terminals: a space's tabs', or tabs only's tab's.
    private var rowSurfaces: [UUID: [UUID]] {
        if tabsOnly { return Dictionary(workspace.sidebarTabs.map { ($0.id, $0.surfaceIDs) }, uniquingKeysWith: { first, _ in first }) }
        return Dictionary(workspace.spaces.map { ($0.id, $0.tabs.flatMap(\.surfaceIDs)) }, uniquingKeysWith: { first, _ in first })
    }

    /// Rows with an agent waiting for approval or a blocked program.
    private var attentionIDs: Set<UUID> { Set(rowSurfaces.filter { Self.needsAttention($1) }.keys) }

    /// Rows with a finished, unseen reply: the tile's green ●.
    private var readyIDs: Set<UUID> { Set(rowSurfaces.filter { Self.ready($1) }.keys) }

    /// Whether any of these terminals has an agent waiting for approval or a blocked program.
    private static func needsAttention(_ surfaces: [UUID]) -> Bool {
        surfaces.contains { TerminalRuntime.shared.chat.sessions[$0]?.approvals.contains(where: \.pending) == true
            || TerminalRuntime.shared.programs.visible($0).contains { $0.state == .blocked } }
    }

    /// Whether any of these terminals has a finished, unseen reply or a finished program.
    private static func ready(_ surfaces: [UUID]) -> Bool {
        surfaces.contains { id in
            TerminalRuntime.shared.chat.sessions[id].map { $0.hasNewMessages && !($0.active && $0.busy) } == true
                || TerminalRuntime.shared.programs.visible(id).contains(where: \.finished)
        }
    }

    /// A listed tab's name: the window's, or the tab's live label (its agent's conversation, program or folder).
    fileprivate func label(_ tab: SidebarTab) -> String {
        let runtime = TerminalRuntime.shared, automatic = settings.values.automaticTabNames
        if tab.window {
            guard let window = workspace.spaces.lazy.flatMap(\.containers).first(where: { $0.id == tab.id }) else { return "Terminal" }
            return runtime.label(for: window, automatic: automatic)
        }
        guard let live = workspace.liveTab(tab.id) else { return "Terminal" }
        return runtime.label(for: live, automatic: automatic)
    }

    /// Tabs only's rows matching the search: by the tab's name, or its host's name or address.
    private func listedTabs(_ query: String) -> [SidebarTab] {
        let tabs = workspace.sidebarTabs
        guard !query.isEmpty else { return tabs }
        return tabs.filter { tab in
            let host = workspace.hosts.record(tab.host)
            return label(tab).localizedStandardContains(query) || host.name.localizedStandardContains(query)
                || host.details.localizedStandardContains(query)
        }
    }

    var body: some View {
        let attention = attentionIDs
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let listed = tabsOnly ? [] : workspace.spaces(matching: query)
        let tabs = tabsOnly ? listedTabs(query) : []
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                // Outside full screen the window row carries the header's buttons. Search opens above the footer.
                if windowControls { windowRow } else { header }
                if harbour { harbourList(listed: listed, tabs: tabs, attention: attention) }
                else { spaceList(listed: listed, tabs: tabs, attention: attention) }
            }
            .layoutPriority(1)
            VStack(spacing: 0) {
                if searchOpen || !searchQuery.isEmpty {
                    searchField.padding(.horizontal, glass ? 8 + Self.glassRowInset : 8).padding(.vertical, 6)
                }
                // A hairline sets the footer apart: across the flat column, or inset like the rows in the glass panel.
                Rectangle().fill(glass ? Chrome.border.opacity(0.6) : Chrome.border).frame(height: 1)
                    .padding(.horizontal, glass ? Self.glassInset + Self.glassRowInset : 0)
                hostStrip.modifier(WorkspaceFooter(workspace: workspace))
                    // The footer keeps the rows' inset from the panel's bottom edge.
                    .padding(.bottom, glass ? Self.glassRowInset : 0)
            }
            .frame(maxWidth: glass ? .infinity : nil)
        }
        // With Liquid Glass the sidebar is a column in AppKit's sidebar glass, flush with the window's edges as in
        // Finder and Mail.
        .background { if glass { glassPanel } }
        .buttonStyle(.plain)
        // Without glass, one flat sidebar column.
        .background { if !glass { Chrome.sidebar } }
        .animation(InterfaceMotion.animation(reduce: reduceMotion), value: attention.count)
        .font(typography.sidebarFont).foregroundStyle(Chrome.ink)
        .environment(\.appTypography, typography)
        .onPreferenceChange(SpaceBranchNames.self) { branches = $0 }
        .onAppear { workspace.spaceOrder = settings.values.spaceOrder }
        .task(id: controller.windowState.spaceSearchFocusRequest) {
            print("Sidebar search mounted: controller=\(ObjectIdentifier(controller)), request=\(String(describing: controller.windowState.spaceSearchFocusRequest))")
            guard controller.windowState.spaceSearchFocusRequest != nil else { return }
            print("Sidebar search requested: request=\(String(describing: controller.windowState.spaceSearchFocusRequest)), open=\(searchOpen), focused=\(searchFocused)")
            // Let the split view reveal the sidebar and mount the field before focusing it.
            await Task.yield()
            guard !Task.isCancelled else { return }
            searchFocused = true
        }
        .onChange(of: settings.values.spaceOrder) { _, order in workspace.spaceOrder = order }
    }

    private var glass: Bool { LiquidGlassStore.shared.active }
    /// Nautical draws the sidebar as a vessel traffic service: a radar plot of the spaces over a traffic list.
    private var harbour: Bool { SidebarThemeStore.shared.current == .nautical }
    /// Whether the overflow control rides over the list as a bar (GlassScrollEdge) rather than below it.
    private var overflowBar: Bool {
        if #available(macOS 26, *) { return glass } else { return false }
    }
    /// The flat order's "+ space" (tabs only: "+ tab") and "+ local" on one row after the last row, on Liquid Glass two
    /// capsules close enough that their glass blends. With only the local host, "+ local" would repeat "+ space", so
    /// "+ space" stands alone in the left half rather than filling the row.
    private var newSpaceButtons: some View {
        let remote = workspace.liveHosts.contains(where: { $0.id != .local })
        return HStack(spacing: glass ? 4 : 6) {
            NewSpaceButton(workspace: workspace, metrics: metrics, tabs: tabsOnly)
            if remote {
                NewSpaceButton(workspace: workspace, host: workspace.hosts.record(.local), metrics: metrics, tabs: tabsOnly)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0).accessibilityHidden(true)
            }
        }
        // A host arrives in its own update, before any space moves to it: "+ space" keeps the left half as "+ local"
        // fades in or out of the right one, the same both ways.
        .animation(InterfaceMotion.animation(reduce: reduceMotion), value: remote)
        // Blends glass across twice the capsules' gap, so they join at rest rather than only while they move.
        .glassGroup(spacing: 8)
        // A little more room than between spaces, so the actions read apart from the list.
        .padding(.top, max(Self.glassRowInset, metrics.rowSpacing))
    }
    @ViewBuilder private var glassPanel: some View {
        if #available(macOS 26, *) {
            SystemSidebarGlass().ignoresSafeArea().accessibilityHidden(true)
        }
    }
    /// The glass panel's inset from the window edges and from the content beside it.
    static let glassInset: CGFloat = 6
    /// A titled window's corner radius on macOS 26 and 27 (the frame view reports 16 points). AppKit only exposes
    /// it publicly from macOS 27 (NSView.effectiveCornerRadii), so it is fixed here.
    static let windowCornerRadius: CGFloat = 16
    /// Concentric with the window: its corner radius less the panel's inset, so the gap is even all around.
    static let glassRadius: CGFloat = windowCornerRadius - glassInset
    /// The rows' inset inside the panel; their corners are the panel's less this, so highlights nest concentrically.
    static let glassRowInset: CGFloat = 4

    /// The rows' height, for telling which spaces the viewport hides; the glass panel takes its own size from layout.
    private func measureRows(_ height: CGFloat) {
        print("Sidebar rows: previous=\(rowsHeight), height=\(height), viewport=\(viewportHeight), glass=\(glass), large=\(metrics.large)")
        rowsHeight = height
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: typography.size(offset: -2)))
                .foregroundStyle(Chrome.palette.detail).accessibilityHidden(true)
            let prompt = tabsOnly ? "Search tabs…" : "Search spaces…"
            TextField(prompt,
                      text: Binding(get: { searchQuery }, set: { setSearchQuery($0) }),
                      prompt: Text(prompt).foregroundColor(Chrome.palette.detail))
                .textFieldStyle(.plain)
                .foregroundStyle(searchQuery.isEmpty ? Chrome.palette.detail : Chrome.ink)
                .focused($searchFocused)
                .help((tabsOnly ? "Search tabs" : "Search spaces") + " · ⌘P")
                .accessibilityLabel(tabsOnly ? "Search tabs" : "Search spaces")
                .accessibilityIdentifier("sidebar-space-search")
                // Escape clears the query first, then closes search.
                .onExitCommand {
                    if searchQuery.isEmpty { closeSearch() } else { setSearchQuery("") }
                }
                .onAppear { if searchOpen { searchFocused = true } }
            if !searchQuery.isEmpty {
                Button { setSearchQuery("") } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Chrome.palette.detail)
                }.accessibilityLabel("Clear space search")
            }
            Text("⌘P").font(typography.shortcut()).foregroundStyle(Chrome.palette.detail).fixedSize()
        }
        .font(typography.font(offset: -1.5))
        .padding(.horizontal, 8)
        .frame(height: max(20, headerHeight - 6))
        .background(Chrome.palette.field, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(searchFocused ? Chrome.ink.opacity(0.16) : Chrome.border, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onChange(of: searchFocused) { _, focused in
            print("Sidebar search focus: focused=\(focused), open=\(searchOpen), empty=\(searchQuery.isEmpty), responder=\(String(describing: controller.window?.firstResponder))")
            if !focused && searchQuery.isEmpty { controller.windowState.spaceSearchFocusRequest = nil }
        }
    }

    private func closeSearch() {
        controller.windowState.spaceSearchFocusRequest = nil
        DispatchQueue.main.async { TerminalRuntime.shared.focusActive() }
    }

    /// Header buttons share one size in both sidebar modes.
    /// The flat header controls' size (the shortcuts button's too).
    private static let headerButtonSize: CGFloat = 24
    private func headerButton<Label: View>(active: Bool = false, @ViewBuilder label: () -> Label) -> some View {
        label()
            .font(.system(size: typography.size(offset: -1.5)))
            .frame(width: Self.headerButtonSize, height: Self.headerButtonSize)
            .foregroundStyle(active ? Chrome.ink : Chrome.palette.detail)
            .background(active ? Chrome.ink.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
    }

    private var shortcutsButton: some View {
        ShortcutSheetButton(presented: Binding(get: { controller.windowState.shortcutsPresented && controller.sidebarVisible },
                                               set: { controller.windowState.shortcutsPresented = $0 }),
                            keyFont: typography.shortcut(), ink: Chrome.ink, muted: Chrome.palette.detail,
                            label: "Keyboard shortcuts", identifier: "sidebar-shortcuts",
                            symbol: "keyboard") { WorkspaceShortcutSheet() }
    }

    private var windowRow: some View {
        HStack(spacing: 0) {
            SidebarToggle(controller: controller)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if harbour { harbourTitle } else { groupingToggle }
                shortcutsButton
            }
        }
        .padding(.leading, controller.windowState.controlsInset).padding(.trailing, glass ? 8 + Self.glassRowInset : 8)
        .frame(height: StripTab.titleRowHeight(typography))
        .padding(.bottom, headerGap(rowHeight: StripTab.titleRowHeight(typography)))
        .accessibilityIdentifier("sidebar-title-row")
    }

    private var headerHeight: CGFloat { headerRowHeight ?? typography.expanded(30) }

    // Keep the header aligned with the tab bar, independently of large sidebar items.
    private var header: some View {
        HStack(spacing: 4) {
            if controller.windowState.isFullScreen {
                // The persistent full-screen toggle occupies this slot.
                Color.clear.frame(width: 32, height: 20)
            }
            Spacer(minLength: 0)
            if harbour { harbourTitle } else { groupingToggle }
            shortcutsButton
        }
        .padding(.horizontal, 8)
        .frame(height: headerHeight)
        .padding(.bottom, headerGap(rowHeight: headerHeight))
    }

    /// The space between a header row (the window row or the full-screen header) and the first space. The row's
    /// controls (the glass track's height, or the flat header buttons') sit as far above it as large spaces sit apart,
    /// or the glass panel's row inset where compact rows touch; the row's own extra height around them counts toward
    /// that.
    private func headerGap(rowHeight: CGFloat) -> CGFloat {
        let controls = glass ? StripTab.glassTrackHeight(typography) : Self.headerButtonSize
        return max(metrics.rowSpacing, Self.glassRowInset) - (rowHeight - controls) / 2
    }

    /// Tree groups spaces under their hosts; flat is one list.
    private var groupingToggle: some View {
        let tree = settings.values.spaceOrder == .tree
        return Button { saveOrder(tree ? .flat : .tree) } label: {
            let glyph = HostTreeGlyph().frame(width: typography.size(offset: -0.5), height: typography.size(offset: -0.5))
            if glass {
                glyph.modifier(GlassPanelControl(active: tree))
            } else {
                headerButton(active: tree) { glyph }
            }
        }
        .help(tree ? "Grouped by host · click for one list" : "One list · click to group by host")
        .accessibilityLabel("Group spaces by host")
        .accessibilityValue(tree ? "On" : "Off")
        .accessibilityIdentifier("sidebar-group-by-host")
    }

    /// Below the last row: a dropped space goes last (in its host's group); tabs only puts a dropped tab after the
    /// last tab, or a window after the last window.
    private var trailingDrop: some View {
        LocalReorder(edge: .pane, accepts: { item in
            switch item {
            case .space: return !tabsOnly
            case .tab(let id):
                guard tabsOnly, let last = workspace.sidebarTabs.last(where: { !$0.window }), let pane = last.pane else { return false }
                return workspace.canMoveTab(id, to: pane)
            case .window(let id):
                guard tabsOnly, let last = workspace.sidebarTabs.last(where: \.window) else { return false }
                return workspace.canMoveWindow(id, beside: last.id)
            case .host, .queued: return false
            }
        }) { item, _ in
            switch item {
            case .space(let id):
                guard let source = workspace.spaces.first(where: { $0.id == id }),
                      let last = workspace.presentationSpaces.last(where: { workspace.spaceOrder != .tree || $0.hostID == source.hostID }) else { return }
                workspace.reorderSpace(id, relativeTo: last.id, after: true)
            case .tab(let id):
                guard let last = workspace.sidebarTabs.last(where: { !$0.window }), let pane = last.pane else { return }
                workspace.moveTab(id, to: pane, relativeTo: last.id, after: true)
            case .window(let id):
                guard let last = workspace.sidebarTabs.last(where: \.window) else { return }
                workspace.moveContainer(id, beside: last.id, edge: nil, after: true)
            case .host, .queued: break
            }
        }
    }

    private func spaceList(listed: [Space], tabs: [SidebarTab], attention: Set<UUID>) -> some View {
        let order = tabsOnly ? tabs.map(\.id) : listed.map(\.id)
        let hidden = hiddenRows(in: order)
        let below = rowsBelowViewport(in: order)
        // The rows' order, with each one's host: a move between hosts or a reorder scrolls the selection back into view.
        let arrangement = tabsOnly ? workspace.sidebarTabs.map { "\($0.host.rawValue):\($0.id)" }
            : workspace.presentationSpaces.map { "\($0.hostID.rawValue):\($0.id)" }
        return ScrollViewReader { scroll in
            VStack(spacing: 0) {
                // The rows stretch to the viewport for the trailing drop target.
                GeometryReader { area in
                    rowsScroll(listed: listed, tabs: tabs, attention: attention, hidden: hidden, below: below, scroll: scroll,
                               minHeight: area.size.height)
                        .onAppear { viewportHeight = area.size.height }
                        .onChange(of: area.size.height) { _, height in viewportHeight = height }
                }
                if !hidden.isEmpty && !overflowBar {
                    overflowButton(hidden: hidden, below: below, attention: attention, scroll: scroll)
                }
            }
            .onChange(of: selectedRow) { _, id in
                if let id { DispatchQueue.main.async { scroll.scrollTo(id) } }
            }
            .onChange(of: arrangement) { _, _ in
                if let id = selectedRow { DispatchQueue.main.async { scroll.scrollTo(id) } }
            }
            .onAppear { if let id = selectedRow { scroll.scrollTo(id) } }
        }
    }

    private func rowsScroll(listed: [Space], tabs: [SidebarTab], attention: Set<UUID>, hidden: [UUID], below: [UUID],
                            scroll: ScrollViewProxy, minHeight: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                spaceRows(listed: listed, tabs: tabs, attention: attention)
                    .background(GeometryReader { rows in
                        Color.clear.onAppear { measureRows(rows.size.height) }
                            .onChange(of: rows.size.height) { _, height in measureRows(height) }
                    })
                Spacer(minLength: 0)
                    .frame(maxWidth: .infinity)
                    .overlay { trailingDrop }
            }.padding(.horizontal, glass ? Self.glassInset + Self.glassRowInset : metrics.large ? 10 : 8)
                .frame(minHeight: minHeight, alignment: .top)
        }
        .coordinateSpace(name: "space-list")
        .onPreferenceChange(SpaceRowFrames.self) { rowFrames.frames = $0; updateRowPlacements() }
        .onChange(of: visibleHeight) { _, _ in updateRowPlacements() }
        .overlay(alignment: .bottom) {
            if !below.isEmpty && !glass {
                LinearGradient(colors: [.clear, Chrome.sidebar], startPoint: .top, endPoint: .bottom)
                    .frame(height: 24).allowsHitTesting(false)
            }
        }
        .modifier(GlassScrollEdge(glass: glass, fades: !below.isEmpty,
                                  bar: hidden.isEmpty ? nil : overflowButton(hidden: hidden, below: below, attention: attention, scroll: scroll)
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { overflowBarHeight = $0 }
                                    .onDisappear { overflowBarHeight = 0 }))
    }

    /// The rows: spaces, or tabs only's tabs, in one list or grouped under their hosts.
    private func spaceRows(listed: [Space], tabs: [SidebarTab], attention: Set<UUID>) -> some View {
        let tree = settings.values.spaceOrder == .tree
        let groups = Dictionary(grouping: listed, by: \.hostID)
        let tabGroups = Dictionary(grouping: tabs, by: \.host)
        // Unbound spaces (tabs) show no shortcut: the Spaces digits jump to spaces, the Tabs digits through the list.
        let shortcuts = tabsOnly ? StripSpaceMenu.shortcuts(workspace.sidebarTabs.map(\.id), keys: settings.values.keyGroups, group: \.tabs)
            : StripSpaceMenu.shortcuts(workspace.presentationSpaces, keys: settings.values.keyGroups)
        return VStack(spacing: tree ? metrics.groupSpacing : metrics.rowSpacing) {
            if tree {
                ForEach(workspace.hosts.ordered(Set(workspace.liveHosts.map(\.id)).union(workspace.detached.map(\.host)))) { host in
                    let spaces = groups[host.id] ?? [], hostTabs = tabGroups[host.id] ?? []
                    if !spaces.isEmpty || !hostTabs.isEmpty || !detachedEntries(host.id).isEmpty || (host.id == .local && searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        hostGroup(host, empty: spaces.isEmpty && hostTabs.isEmpty) {
                            if tabsOnly {
                                ForEach(hostTabs) { tab in
                                    tabRow(tab, pending: attention.contains(tab.id), shortcut: shortcuts[tab.id] ?? "")
                                }
                            } else {
                                ForEach(spaces) { space in
                                    spaceRow(space, pending: attention.contains(space.id), shortcut: shortcuts[space.id] ?? "")
                                }
                            }
                        }
                    }
                }
            } else {
                if tabsOnly {
                    ForEach(tabs) { tab in
                        tabRow(tab, pending: attention.contains(tab.id), shortcut: shortcuts[tab.id] ?? "")
                    }
                } else {
                    ForEach(listed) { space in
                        spaceRow(space, pending: attention.contains(space.id), shortcut: shortcuts[space.id] ?? "")
                    }
                }
                newSpaceButtons
                flatDetachedSection
            }
            if listed.isEmpty && tabs.isEmpty && matchingDetachedEntries.isEmpty {
                Text(tabsOnly ? "No matching tabs" : "No matching spaces").font(sidebarDetailFont).foregroundStyle(Chrome.muted).padding(10)
            }
        }
        .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: InterfaceMotion.spaceSwitchDuration), value: selectedRow)
        .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.2),
                   value: tabsOnly ? tabs.map { "\($0.id):\($0.host.rawValue)" } : listed.map { "\($0.id):\($0.hostID.rawValue)" })
    }

    /// A tree group's heading: the host's name in title case, its connection state while not connected after it in a
    /// quieter tone. Compact leads with the host's icon; the icons style's rows carry it instead. Remote hosts keep
    /// their color.
    private func hostHeading(_ host: HostRecord) -> some View {
        let state = workspace.hosts.state(host.id)
        return HStack(spacing: 6) {
            // Sized to the heading's text, not the app's host icons, so it fits the compact header.
            if !metrics.large { HostGlyph(host: host, size: metrics.headerSize + 3) }
            Text(host.id == .local ? "Local" : host.name)
                .font(Font(AppFont.native(size: metrics.headerSize + 1, semibold: true)))
                .lineLimit(1).truncationMode(.middle)
            if host.id != .local && state != .connected {
                Text(state.shownShortLabel).font(AppFont.ui(size: metrics.headerSize)).foregroundStyle(Chrome.muted)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(host.tint?.foreground ?? Chrome.palette.secondary)
        // The icons style lines its heading up as the host picker does, past the rows' inset.
        .padding(.leading, metrics.icons ? 10 : 2).frame(height: metrics.headerHeight).contentShape(Rectangle())
    }

    /// Large's group header: the host's icon, name and connection state on a chip of its color, glass on Liquid Glass,
    /// ending in the group's new-space button. The chip brightens as a space arrives from another host, as the compact
    /// rule does. The button is the chip's neighbour, not inside the host's own button, so each keeps its clicks.
    private func hostChip(_ host: HostRecord, arriving: Bool, newSpace: some View) -> some View {
        let hue = host.tint?.foreground
        let dark = Chrome.palette.isDark
        let state = workspace.hosts.state(host.id)
        return HStack(spacing: 0) {
            HStack(spacing: 2) {
                hostHeader(host) {
                    HStack(spacing: 6) {
                        HostGlyph(host: host, size: metrics.hostIconSize).foregroundStyle(hue ?? Chrome.palette.secondary)
                        Text(host.id == .local ? "Local" : host.name)
                            .font(Font(AppFont.native(size: metrics.headerSize + 1, semibold: true)))
                            .foregroundStyle(hue ?? Chrome.palette.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        if host.id != .local && state != .connected {
                            Text(state.shownShortLabel).font(AppFont.ui(size: metrics.headerSize)).foregroundStyle(Chrome.muted)
                        }
                    }
                    .padding(.leading, 8).frame(height: metrics.headerHeight).contentShape(Rectangle())
                }.help(host.id == .local ? "Local" : host.details)
                    .accessibilityIdentifier("host-card-\(host.id.rawValue)")
                newSpace.padding(.trailing, 3)
            }
            .frame(height: metrics.headerHeight)
            .background { Capsule().fill((hue ?? Chrome.ink).opacity(glass ? 0.06 : dark ? 0.12 : 0.08)) }
            .liquidGlass(in: Capsule(), tint: host.tint?.glassWash)
            .overlay {
                Capsule().strokeBorder((hue ?? Chrome.ink).opacity(arriving ? 0.8 : dark ? 0.28 : 0.2), lineWidth: arriving ? 1.5 : 0.75)
                    .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.2), value: arriving)
                    .allowsHitTesting(false)
            }
            Spacer(minLength: 0)
        }
    }

    /// A host's group: its heading (or Large's chip) with the group's new-space button, then `rows` (its spaces, or
    /// tabs only's tabs there) and its detached work. `empty`: no rows to click through to the heading's button.
    private func hostGroup<Rows: View>(_ host: HostRecord, empty: Bool, @ViewBuilder rows: () -> Rows) -> some View {
        let tint = host.tint?.foreground ?? Chrome.palette.secondary
        let arriving = workspace.hostMoveMotion.arrivals.values.contains(host.id)
        // A heading's plus shows while its header is under the pointer, when the group has no spaces to click through
        // to it, and always for VoiceOver; Large's chip always ends in it, the chip's own control.
        let revealed = metrics.cards || hoveredHost == host.id || empty || NSWorkspace.shared.isVoiceOverEnabled
        let newSpace = NewSpaceButton(workspace: workspace, host: host, metrics: metrics, grouped: true, revealed: revealed, tabs: tabsOnly)
            .fixedSize()
        return LazyVStack(spacing: metrics.rowSpacing) {
            Group {
                if metrics.cards {
                    hostChip(host, arriving: arriving, newSpace: newSpace)
                } else {
                    HStack(spacing: 8) {
                        hostHeader(host) { hostHeading(host) }
                            .help(host.id == .local ? "Local" : host.details)
                            .accessibilityIdentifier("host-card-\(host.id.rawValue)")
                        newSpace.padding(.trailing, max(0, metrics.shortcutInset - 6))
                    }
                }
            }
            .frame(height: metrics.headerHeight)
            // The header's own button and drag tracker are AppKit views over it, which SwiftUI's hover doesn't see
            // through; a tracking area does, in an inactive window too, as sidebars reveal their actions.
            .background {
                PointerTracker { inside in
                    if inside { hoveredHost = host.id } else if hoveredHost == host.id { hoveredHost = nil }
                }
            }
            // Compact rows have no gaps; keep the header off the first row.
            .padding(.bottom, metrics.large ? 0 : 2)
            rows()
            detachedSection(host.id)
        }
        // A rule down a compact group's leading edge marks its host; the icons style marks every row with its icon,
        // Large's cards each carry an orb under the group's chip.
        .padding(.leading, metrics.large ? 0 : 8)
        .overlay(alignment: .leading) {
            if !metrics.large {
                RoundedRectangle(cornerRadius: 2).fill(tint.opacity(arriving ? 0.9 : 0.55))
                    .frame(width: metrics.large ? 3 : 2).allowsHitTesting(false)
                    .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.2), value: arriving)
            }
        }
        .opacity(workspace.hosts.state(host.id) == .disconnected ? 0.65 : 1)
    }

    private var matchingDetachedEntries: [DetachedEntry] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return workspace.detached.filter { entry in
            let host = workspace.hosts.record(entry.host)
            return query.isEmpty || entry.name.localizedStandardContains(query)
                || host.name.localizedStandardContains(query) || host.details.localizedStandardContains(query)
        }
    }

    @ViewBuilder private var flatDetachedSection: some View {
        let entries = matchingDetachedEntries
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Rectangle().fill(Chrome.border).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 6)
                HStack(spacing: 6) {
                    Button { flatDetachedExpanded.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: flatDetachedExpanded ? "chevron.down" : "chevron.right")
                                .font(AppFont.ui(size: metrics.detailSize - 2)).frame(width: metrics.activitySize)
                            Text("Detached")
                            Text("\(entries.count)").foregroundStyle(Chrome.palette.faint)
                        }.contentShape(Rectangle())
                    }.accessibilityIdentifier("detached-section-flat")
                    Spacer(minLength: 4)
                    Button("Restore all") { workspace.restoreDetached(Set(entries.map(\.id))) }
                        .disabled(entries.allSatisfy { workspace.isRestoringDetached($0.id) })
                        .help("Restore detached work using its existing processes")
                        .accessibilityIdentifier("restore-all-detached-flat")
                }.font(sidebarDetailFont).foregroundStyle(Chrome.muted)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                if flatDetachedExpanded || !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ForEach(entries) { entry in flatDetachedRow(entry) }
                }
            }.buttonStyle(.plain)
        }
    }

    private func flatDetachedRow(_ entry: DetachedEntry) -> some View {
        let restoring = workspace.isRestoringDetached(entry.id)
        let host = workspace.hosts.record(entry.host)
        return HStack(spacing: 0) {
            Button { workspace.restoreDetached([entry.id]) } label: {
                HStack(spacing: 10) {
                    Image(systemName: restoring ? "arrow.triangle.2.circlepath" : "rectangle.dashed")
                        .font(metrics.large ? sidebarFont : sidebarDetailFont).foregroundStyle(Chrome.muted).frame(width: metrics.activitySize)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(sidebarFont).foregroundStyle(Chrome.palette.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Text(restoring ? "Restoring…" : entry.source + " · " + entry.kind.lowercased())
                            .font(sidebarDetailFont).foregroundStyle(Chrome.muted)
                    }
                    Spacer(minLength: 4)
                    if entry.host != .local { spaceHostIndicator(host) }
                    Image(systemName: "arrow.uturn.backward")
                        .font(sidebarDetailFont).foregroundStyle(Chrome.muted)
                }
                .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, metrics.large ? 6 : 3)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.disabled(restoring)
                .help("Restore " + entry.name + (entry.host == .local ? "" : " on " + host.name))
                .accessibilityLabel("Restore " + entry.name)
                .accessibilityIdentifier("restore-detached-\(entry.id)")
            removeDetachedButton(entry)
        }
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            if entry.host != .local {
                Rectangle().fill(host.tint?.border ?? Chrome.border.opacity(0.5)).frame(width: 2)
                    .allowsHitTesting(false)
            }
        }
        .contextMenu {
            Button("Restore") { workspace.restoreDetached([entry.id]) }.disabled(restoring)
            Button("Remove from List") { workspace.forgetDetached(entry.id) }
        }
    }

    private func removeDetachedButton(_ entry: DetachedEntry) -> some View {
        Button { workspace.forgetDetached(entry.id) } label: {
            Image(systemName: "xmark")
                .font(sidebarDetailFont).foregroundStyle(Chrome.muted)
                .frame(width: metrics.large ? 30 : 20, height: metrics.large ? 30 : 20).contentShape(Rectangle())
        }
        .help("Remove from sidebar; keep server work running")
        .accessibilityLabel("Remove \(entry.name) from sidebar")
        .accessibilityIdentifier("remove-detached-\(entry.id)")
    }

    private func detachedEntries(_ host: HostID) -> [DetachedEntry] {
        matchingDetachedEntries.filter { $0.host == host }
    }

    @ViewBuilder private func detachedSection(_ host: HostID) -> some View {
        let entries = detachedEntries(host)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: metrics.large ? 6 : 2) {
                HStack(spacing: 6) {
                    Button {
                        if !expandedDetached.insert(host).inserted { expandedDetached.remove(host) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: expandedDetached.contains(host) ? "chevron.down" : "chevron.right")
                            Text("Detached")
                            Text("\(entries.count)").foregroundStyle(Chrome.palette.faint)
                        }
                    }.accessibilityIdentifier("detached-section-\(host.rawValue)")
                    Spacer(minLength: 4)
                    Button("Restore all") { workspace.restoreDetached(Set(entries.map(\.id))) }
                        .disabled(entries.allSatisfy { workspace.isRestoringDetached($0.id) })
                        .help("Restore these detached views; keep their existing processes")
                }
                if expandedDetached.contains(host) || !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ForEach(entries) { entry in
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).font(sidebarFont).lineLimit(1)
                                Text(entry.kind).foregroundStyle(Chrome.muted).font(sidebarDetailFont)
                            }
                            Spacer(minLength: 4)
                            Button(workspace.isRestoringDetached(entry.id) ? "Restoring…" : "Restore") { workspace.restoreDetached([entry.id]) }
                                .fixedSize(horizontal: true, vertical: false)
                                .disabled(workspace.isRestoringDetached(entry.id))
                                .accessibilityLabel("Restore \(entry.name)")
                                .accessibilityIdentifier("restore-detached-\(entry.id)")
                            removeDetachedButton(entry)
                        }.padding(.leading, 12)
                            .contextMenu {
                                Button("Restore") { workspace.restoreDetached([entry.id]) }
                                    .disabled(workspace.isRestoringDetached(entry.id))
                                Button("Remove from List") { workspace.forgetDetached(entry.id) }
                            }
                    }
                }
            }.font(sidebarDetailFont).foregroundStyle(Chrome.muted)
                .frame(maxWidth: .infinity, alignment: .leading).padding(metrics.large ? 8 : 4)
        }
    }

    private func spaceRow(_ space: Space, pending: Bool, shortcut: String) -> some View {
        SpaceSidebarRow(sidebar: self, space: space, selected: workspace.selectedSpace == space.id, pending: pending,
                        shortcut: shortcut, branch: branches[space.id], selection: selection).equatable()
    }

    private func tabRow(_ tab: SidebarTab, pending: Bool, shortcut: String) -> some View {
        SidebarTabRow(sidebar: self, tab: tab, selected: workspace.selectedSidebarTab == tab.id, pending: pending,
                      shortcut: shortcut, branch: branches[tab.id], selection: selection).equatable()
    }

    /// The body of `SpaceSidebarRow`. It reads selection and branch only through its arguments,
    /// so a space switch re-renders the two rows whose selection changed, not every row.
    fileprivate func rowContent(_ space: Space, selected: Bool, pending: Bool, shortcut: String, branch: String?, selection: Namespace.ID) -> some View {
        let flat = settings.values.spaceOrder != .tree
        let hover = SpaceHoverDetails.make(space: space, host: workspace.hosts.record(space.hostID), runtime: .shared)
        return Button { workspace.selectSpace(space.id) } label: {
            let surfaces = space.tabs.flatMap(\.surfaceIDs)
            let mixed = Set(surfaces.compactMap { workspace.hosts.terminals[$0]?.host }).subtracting([space.hostID])
            SidebarSpaceTile(entry: SidebarEntry(space: space), host: workspace.hosts.record(space.hostID),
                             mixedHost: workspace.hosts.ordered(mixed).first(where: { $0.id != .local }),
                             grouped: !flat, selected: selected, pending: pending, shortcut: shortcut,
                             connecting: surfaces.contains { workspace.hostMoveMotion.connecting.contains($0) },
                             branch: branch,
                             showBranch: settings.values.showsGitBranches, metrics: metrics, selection: selection)
        }
        .background(SpaceBranchObserver(space: space, enabled: settings.values.showsGitBranches))
        .accessibilityHint(hover.summary)
        .accessibilityIdentifier("space-\(space.id)")
        .overlay {
            LocalReorder(item: .space(space.id), edge: .vertical,
                         reorderGroup: flat ? nil : space.hostID.rawValue, spaceHover: hover,
                         hoverFontSize: metrics.nameSize,
                         select: { workspace.selectSpace(space.id) }, accepts: { item in
                switch item {
                case .space(let id):
                    return workspace.spaceOrder != .tree || workspace.spaces.first(where: { $0.id == id })?.hostID == space.hostID
                case .tab(let id): return workspace.canMoveTab(id, to: space.focusedPane)
                case .window(let id):
                    guard let window = workspace.spaces.flatMap(\.windows).first(where: { $0.id == id }),
                          let target = space.windows.first, workspace.canMoveWindow(id, beside: target.id) else { return false }
                    return window.terminals.allSatisfy {
                        (workspace.hosts.terminals[$0.id]?.host ?? .local) == space.hostID
                    }
                case .host, .queued: return false
                }
            }) { item, after in
                switch item {
                case .space(let id): workspace.reorderSpace(id, relativeTo: space.id, after: after)
                case .tab(let id): workspace.moveTab(id, to: space.focusedPane)
                case .window(let id):
                    if let last = space.windows.last { workspace.moveWindow(id, beside: last.id) }
                case .host, .queued: break
                }
            }
        }
        .contextMenu { spaceMenu(space) }
        .id(space.id)
        .modifier(HostMoveRow(motion: workspace.hostMoveMotion, id: space.id))
        .background(GeometryReader { proxy in
            Color.clear.preference(key: SpaceRowFrames.self, value: [space.id: proxy.frame(in: .named("space-list"))])
        })
    }

    /// The body of `SidebarTabRow`: a tab (or a tmux or herdr window) drawn as a space's row is, named by its live
    /// label, with its host, agent activity, branch and ⌘ digit. Tabs reorder among tabs and windows among windows;
    /// a tab dropped on another lands beside it, in that tab's pane, moving between spaces if it must.
    fileprivate func tabRowContent(_ tab: SidebarTab, selected: Bool, pending: Bool, shortcut: String, branch: String?,
                                   selection: Namespace.ID) -> some View {
        let flat = settings.values.spaceOrder != .tree
        let host = workspace.hosts.record(tab.host)
        let owner = workspace.spaces.first { $0.id == tab.space }
        // The terminal that names a window's branch and hover card: its focused pane.
        let terminal: TerminalTab? = tab.window
            ? owner?.containers.first { $0.id == tab.id }?.focusedTerminal.map { workspace.liveTab($0.id) ?? $0 }
            : workspace.liveTab(tab.id)
        let name = label(tab)
        let hover = terminal.map { SpaceHoverDetails.make(tab: $0, host: host, runtime: .shared, title: tab.window ? name : nil) }
        return Button { workspace.selectSidebarTab(tab.id) } label: {
            SidebarSpaceTile(entry: SidebarEntry(id: tab.id, name: name, surfaceIDs: tab.surfaceIDs), host: host,
                             mixedHost: nil, grouped: !flat, selected: selected, pending: pending, shortcut: shortcut,
                             connecting: tab.surfaceIDs.contains { workspace.hostMoveMotion.connecting.contains($0) },
                             branch: branch, showBranch: settings.values.showsGitBranches, metrics: metrics, selection: selection)
        }
        .background {
            if let owner, let terminal { SpaceBranchObserver(space: owner, tab: terminal, enabled: settings.values.showsGitBranches) }
        }
        .accessibilityHint(hover?.summary ?? "")
        .accessibilityIdentifier("sidebar-tab-\(tab.id)")
        .overlay {
            LocalReorder(item: tab.window ? .window(tab.id) : .tab(tab.id), edge: .vertical, spaceHover: hover,
                         hoverFontSize: metrics.nameSize, dragLabel: name,
                         select: { workspace.selectSidebarTab(tab.id) }, accepts: { item in
                switch item {
                case .tab(let id): return !tab.window && tab.pane.map { workspace.canMoveTab(id, to: $0) } == true
                case .window(let id): return tab.window && workspace.canMoveWindow(id, beside: tab.id)
                case .space, .host, .queued: return false
                }
            }) { item, after in
                switch item {
                case .tab(let id): if let pane = tab.pane { workspace.moveTab(id, to: pane, relativeTo: tab.id, after: after) }
                case .window(let id): workspace.moveContainer(id, beside: tab.id, edge: nil, after: after)
                case .space, .host, .queued: break
                }
            }
        }
        .contextMenu { tabMenu(tab, label: name) }
        .id(tab.id)
        .modifier(HostMoveRow(motion: workspace.hostMoveMotion, id: tab.id))
        .background(GeometryReader { proxy in
            Color.clear.preference(key: SpaceRowFrames.self, value: [tab.id: proxy.frame(in: .named("space-list"))])
        })
    }

    /// A listed tab's actions, as its strip offered them: a window detaches or terminates, a tab closes.
    @ViewBuilder private func tabMenu(_ tab: SidebarTab, label: String) -> some View {
        Button("Rename…") {
            controller.rename(title: "Rename tab", value: label) { name in
                if tab.window { workspace.renameWindow(tab.id, to: name) } else { workspace.updateTab(tab.id, customTitle: name) }
            }
        }
        if tab.window {
            Button("Detach") { controller.detachWindow(tab.id) }
            Button("Terminate…") { controller.terminateWindow(tab.id) }
        } else {
            Button("Close Tab") { controller.closeTab(tab.id) }
        }
    }

    /// Nautical names the actions at sea, each with its plain name beside it so none surprises.
    @ViewBuilder private func spaceMenu(_ space: Space) -> some View {
        Button(harbour ? "Rename Vessel…" : "Rename…") {
            controller.rename(title: harbour ? "Rename vessel" : "Rename space", value: space.name) { workspace.renameSpace(space.id, to: $0) }
        }
        if space.structured {
            Button(harbour ? "Weigh Anchor (Detach)" : "Detach") { controller.closeSpace(space.id) }
                .help("Remove from Dispatch; keep server work running")
            Button(harbour ? "Scuttle (Terminate)…" : "Terminate…") { controller.terminateSpace(space.id) }
        } else {
            Button(harbour ? "Lay Up (Close)" : "Close") { controller.closeSpace(space.id) }
        }
    }

    // MARK: Nautical

    /// The full title where the header has room, else just the service's name.
    private var harbourTitle: some View {
        ViewThatFits(in: .horizontal) {
            Text("VTS · DISPATCH HARBOUR").fixedSize()
            Text("VTS · HARBOUR").fixedSize()
            Text("VTS").fixedSize()
        }
        .font(HarbourType.heading(typography.size(offset: -1))).tracking(2.4)
        .foregroundStyle(Chrome.accent).lineLimit(1).padding(.trailing, 4)
        .accessibilityIdentifier("harbour-title")
    }

    /// The radar plot over the traffic list. The plot takes the sidebar's width, up to about half its height, so the
    /// list keeps room for its rows. The list holds the rows (spaces, or tabs only's tabs); the radar plots every tab
    /// of them, so the tab that needs you is the one nearest the harbour.
    private func harbourList(listed: [Space], tabs: [SidebarTab], attention: Set<UUID>) -> some View {
        // Each space's (tabs only: tab's) key is its number, the first digit of its tabs' channels.
        let order = tabsOnly ? workspace.sidebarTabs.map(\.id) : workspace.presentationSpaces.map(\.id)
        let numbers = Dictionary(order.enumerated().map { ($1, "\($0 + 1)") }, uniquingKeysWith: { first, _ in first })
        let heading = settings.values.showsGitBranches
        let ready = readyIDs
        let vessels = tabsOnly ? tabs.map { tab in
            HarbourVessel.make(id: tab.id, name: label(tab), host: workspace.hosts.record(tab.host),
                               state: workspace.hosts.state(tab.host), surfaceIDs: tab.surfaceIDs,
                               selected: workspace.selectedSidebarTab == tab.id, pending: attention.contains(tab.id),
                               ready: ready.contains(tab.id), shortcut: numbers[tab.id] ?? "", heading: heading ? branches[tab.id] : nil)
        } : listed.map {
            HarbourVessel.make($0, workspace: workspace, selected: workspace.selectedSpace == $0.id,
                               pending: attention.contains($0.id), ready: ready.contains($0.id), shortcut: numbers[$0.id] ?? "",
                               heading: heading ? branches[$0.id] : nil)
        }
        let listedSpaces = Set(listed.map(\.id))
        let plotted = tabsOnly ? tabs : workspace.sidebarTabs.filter { listedSpaces.contains($0.space) }
        let channels = harbourChannels()
        let contacts = plotted.map { tab in
            var vessel = HarbourVessel.make(id: tab.id, name: label(tab), host: workspace.hosts.record(tab.host),
                                            state: workspace.hosts.state(tab.host), surfaceIDs: tab.surfaceIDs,
                                            selected: workspace.selectedSidebarTab == tab.id,
                                            pending: Self.needsAttention(tab.surfaceIDs), ready: Self.ready(tab.surfaceIDs),
                                            shortcut: numbers[tab.id] ?? "",
                                            heading: heading ? tabsOnly ? branches[tab.id] : branches[tab.space] : nil)
            // Tabs only shows no spaces, so its convoys go unnamed.
            vessel.convoy = tab.space
            vessel.convoyName = tabsOnly ? nil : workspace.spaces.first { $0.id == tab.space }.map { workspace.liveName($0) }
            vessel.channel = channels[tab.id]
            return vessel
        }
        // A clicked sector narrows the list to the rows with a tab on its host, while that host has any.
        let sector = harbourHost.flatMap { host in contacts.first { $0.hostID == host } }
        let rowHosts = Dictionary(grouping: plotted, by: { tabsOnly ? $0.id : $0.space }).mapValues { Set($0.map(\.host)) }
        let shown = sector.map { sector in vessels.filter { rowHosts[$0.id]?.contains(sector.hostID) == true } } ?? vessels
        return GeometryReader { area in
            VStack(spacing: 0) {
                HarbourRadar(vessels: contacts, reduceMotion: reduceMotion, focus: sector?.hostID,
                             select: { workspace.selectSidebarTab($0) },
                             filter: { host in harbourHost = harbourHost == host ? nil : host })
                    .equatable()
                    .frame(width: max(0, min(area.size.width - 24, area.size.height * 0.55)),
                           height: max(0, min(area.size.width - 24, area.size.height * 0.55)))
                    .padding(.top, 4)
                HarbourTrafficList(vessels: shown, typography: typography, sector: sector?.host,
                                   clearSector: { harbourHost = nil },
                                   select: { select($0) },
                                   menu: { id in AnyView(Group {
                                       if let space = listed.first(where: { $0.id == id }) { spaceMenu(space) }
                                       if let tab = tabs.first(where: { $0.id == id }) { tabMenu(tab, label: label(tab)) }
                                   }) })
                    .padding(.horizontal, glass ? Self.glassInset + Self.glassRowInset : 10).padding(.top, 10)
            }
            .frame(width: area.size.width, height: area.size.height, alignment: .top)
        }
        // Each row's branch, read as the regular rows read it, for its heading.
        .background {
            ForEach(listed) { SpaceBranchObserver(space: $0, enabled: heading) }
            ForEach(tabs) { tab in
                if let owner = workspace.spaces.first(where: { $0.id == tab.space }),
                   let terminal = tab.window ? owner.containers.first(where: { $0.id == tab.id })?.focusedTerminal : owner.tabs.first(where: { $0.id == tab.id }) {
                    SpaceBranchObserver(space: owner, tab: terminal, enabled: heading)
                }
            }
        }
    }

    /// Each tab's VHF channel, as its strip tab names it; a structured space's window by its space's number and its
    /// own.
    private func harbourChannels() -> [UUID: String] {
        let spaceNumbers = Dictionary(workspace.presentationSpaces.enumerated().map { ($1.id, $0 + 1) },
                                      uniquingKeysWith: { first, _ in first })
        var windows: [UUID: Int] = [:]
        return Dictionary(workspace.sidebarTabs.map { tab -> (UUID, String) in
            guard tab.window else { return (tab.id, HarbourRadio.channel(for: tab.id)) }
            windows[tab.space, default: 0] += 1
            return (tab.id, "CH \(spaceNumbers[tab.space] ?? 0)\(windows[tab.space] ?? 1)")
        }, uniquingKeysWith: { first, _ in first })
    }

    private func overflowButton(hidden: [UUID], below: [UUID], attention: Set<UUID>, scroll: ScrollViewProxy) -> some View {
        let pending = hidden.filter { attention.contains($0) }
        let ready = readyIDs
        let finished = hidden.filter { ready.contains($0) && !attention.contains($0) }
        return Button {
            if let target = pending.first ?? finished.first {
                select(target)
                scroll.scrollTo(target, anchor: .center)
            } else if let target = below.first ?? hidden.last {
                scroll.scrollTo(target, anchor: .top)
            }
        } label: {
            HStack(spacing: 4) {
                Text(below.isEmpty ? "↑" : "↓")
                Text("\(hidden.count) more")
                if !pending.isEmpty { Text("· ● \(pending.count) needs you").foregroundStyle(Chrome.palette.green) }
                if !finished.isEmpty { Text("· ◆ \(finished.count) ready").foregroundStyle(Chrome.accent) }
                Spacer(minLength: 0)
            }.font(sidebarDetailFont).lineLimit(1).padding(.horizontal, 10).padding(.vertical, metrics.large ? 6 : 4)
                .frame(maxWidth: .infinity).contentShape(Rectangle())
                // On glass it is a bar over the rows' soft scroll edge, not a panel of its own.
                .modifier(OverflowPanel(glass: glass))
        }
        .accessibilityIdentifier("space-overflow")
        .help(tabsOnly ? "Reveal hidden tabs; jump to a hidden tab awaiting approval, then one with a ready reply."
              : "Reveal hidden spaces; jump to a hidden space awaiting approval, then one with a ready reply.")
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private var hostStrip: some View {
        let hosts = workspace.hosts.ordered(Set(workspace.liveHosts.map(\.id))
            .union(workspace.detached.map(\.host)))
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: min(4, hosts.count)), spacing: 4) {
            ForEach(hosts) { hostCell($0) }
        }
        // On glass the panel starts at the glass inset, and the cells sit their own inset inside it.
        .padding(.horizontal, glass ? Self.glassInset + Self.footerInset : 8).padding(.vertical, Self.footerInset)
    }

    @ViewBuilder private func hostCell(_ host: HostRecord) -> some View {
        if host.id == .local { hostStatsButton }
        else {
            hostButton(host) {
                HStack(spacing: 5) {
                    HostGlyph(host: host, size: footerIconSize).foregroundStyle(host.tint?.foreground ?? Chrome.ink)
                    Circle().fill(workspace.hosts.state(host.id) == .connected ? host.tint?.border ?? Chrome.muted : Chrome.muted.opacity(0.45))
                        .frame(width: 4, height: 4)
                }.modifier(FooterHostCell(glass: glass, height: footerCellHeight))
            }.help("\(host.name) · \(workspace.hosts.state(host.id).shownLabel)")
                .accessibilityIdentifier("host-strip-\(host.id.rawValue)")
        }
    }

    private func hostButton<Label: View>(_ host: HostRecord, alignment: VerticalAlignment = .center, @ViewBuilder label: () -> Label) -> some View {
        HostInformationButton(host: host, workspace: workspace, label: label(), rowAlignment: alignment)
    }

    /// Tree-mode host headers double as drag handles for host order.
    private func hostHeader<Label: View>(_ host: HostRecord, @ViewBuilder label: () -> Label) -> some View {
        HostInformationButton(host: host, workspace: workspace, label: label(), reorder: { dragged, after in
            withAnimation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.2)) {
                workspace.hosts.move(dragged, relativeTo: host.id, after: after)
            }
        })
    }

    private var hostStatsButton: some View {
        hostButton(.local) {
            HostGlyph(host: workspace.hosts.record(.local), size: footerIconSize)
                .modifier(FooterHostCell(glass: glass, height: footerCellHeight))
        }.foregroundStyle(Chrome.ink)
            .help("local · Host stats").accessibilityLabel("Local host stats")

    }

    private func spaceHostIndicator(_ host: HostRecord) -> some View {
        HostGlyph(host: host, size: metrics.hostIconSize)
            .foregroundStyle(host.tint?.foreground ?? Chrome.ink)
            .help(host.name)
            .accessibilityLabel("\(host.name) · \(host.system?.label ?? "Remote host, OS unavailable")")
    }

    private func saveOrder(_ order: SpaceOrder) {
        var values = settings.values
        values.spaceOrder = order
        workspace.spaceOrder = order
        do { try settings.save(values) } catch { settings.error = error.localizedDescription }
    }
}

/// A footer host's grid cell. On glass it behaves like a button in a strip's glass pill: a faint capsule under the
/// pointer.
private struct FooterHostCell: ViewModifier {
    let glass: Bool
    let height: CGFloat
    func body(content: Content) -> some View {
        let cell = content.frame(maxWidth: .infinity).frame(minHeight: height)
        if glass { cell.modifier(StripActionHover()).contentShape(Capsule()) } else { cell.contentShape(Rectangle()) }
    }
}

/// Equatable on the row's own inputs. Observable state the row reads (settings, hosts,
/// chat activity) still invalidates it directly; the sidebar copy is only used for helpers.
private struct SpaceSidebarRow: View, Equatable {
    let sidebar: SpaceSidebar
    let space: Space
    let selected: Bool
    let pending: Bool
    let shortcut: String
    let branch: String?
    let selection: Namespace.ID

    var body: some View {
        // Live: its tabs' titles and directories re-render this row, not the sidebar.
        sidebar.rowContent(sidebar.workspace.liveSpace(space), selected: selected, pending: pending, shortcut: shortcut,
                           branch: branch, selection: selection)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.space == rhs.space && lhs.selected == rhs.selected && lhs.pending == rhs.pending
            && lhs.shortcut == rhs.shortcut && lhs.branch == rhs.branch && lhs.selection == rhs.selection
    }
}

/// Tabs only's row, equatable on its inputs like a space's; its label is live (`Workspace.liveTab`), so a title
/// change re-renders this row alone.
private struct SidebarTabRow: View, Equatable {
    let sidebar: SpaceSidebar
    let tab: SidebarTab
    let selected: Bool
    let pending: Bool
    let shortcut: String
    let branch: String?
    let selection: Namespace.ID

    var body: some View {
        sidebar.tabRowContent(tab, selected: selected, pending: pending, shortcut: shortcut, branch: branch, selection: selection)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tab == rhs.tab && lhs.selected == rhs.selected && lhs.pending == rhs.pending
            && lhs.shortcut == rhs.shortcut && lhs.branch == rhs.branch && lhs.selection == rhs.selection
    }
}

private final class SpaceRowFrameStore {
    var frames: [UUID: CGRect] = [:]
}

private struct SpaceRowPlacement: Equatable {
    let above: Bool
    let showing: Bool
    let below: Bool

    init(_ frame: CGRect, visibleHeight: CGFloat) {
        above = frame.minY < -1
        showing = frame.maxY > 0 && frame.minY < visibleHeight
        below = frame.maxY > visibleHeight + 1
    }
}

private struct SpaceRowFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// The group-by-host toggle: a parent with two child branches, drawn on a 20-point grid.
private struct HostTreeGlyph: View {
    var body: some View {
        Canvas { context, canvas in
            let unit = canvas.width / 20
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
            var branches = Path()
            branches.move(to: point(5.5, 5)); branches.addLine(to: point(5.5, 17)); branches.addLine(to: point(10, 17))
            branches.move(to: point(5.5, 10.5)); branches.addLine(to: point(10, 10.5))
            context.stroke(branches, with: .foreground,
                           style: StrokeStyle(lineWidth: 1.5 * unit, lineCap: .round, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: 3.25 * unit, y: 0.75 * unit, width: 4.5 * unit, height: 4.5 * unit)), with: .foreground)
            for y: CGFloat in [10.5, 17] {
                context.stroke(Path(ellipseIn: CGRect(x: 12.5 * unit, y: (y - 2) * unit, width: 4 * unit, height: 4 * unit)),
                               with: .foreground, lineWidth: 1.5 * unit)
            }
        }
        .accessibilityHidden(true)
    }
}

/// On glass there is no opaque color to fade into. On macOS 26 the overflow control is a bar over the list, and the
/// system's soft scroll edge effect blurs rows passing under it; earlier systems fade the rows out above the bottom
/// edge while more spaces follow.
private struct GlassScrollEdge<Bar: View>: ViewModifier {
    let glass: Bool
    let fades: Bool
    let bar: Bar?

    func body(content: Content) -> some View {
        if #available(macOS 26, *), glass {
            content.scrollEdgeEffectStyle(.soft, for: .bottom)
                .safeAreaBar(edge: .bottom, spacing: 0) { if let bar { bar } }
        } else {
            content.mask {
                VStack(spacing: 0) {
                    Color.black
                    if fades && glass {
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 24)
                    }
                }
            }
        }
    }
}

private struct OverflowPanel: ViewModifier {
    let glass: Bool
    func body(content: Content) -> some View {
        if glass { content } else { content.chromePanel(Chrome.palette.terminal, cornerRadius: 6) }
    }
}

/// Reports the pointer entering and leaving its frame, whatever views lie over it and whether or not the window is
/// active. It takes no clicks.
private struct PointerTracker: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> PointerTrackingView { PointerTrackingView() }
    func updateNSView(_ view: PointerTrackingView, context: Context) { view.changed = changed }
}

final class PointerTrackingView: NSView {
    var changed: (Bool) -> Void = { _ in }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { changed(true) }
    override func mouseExited(with event: NSEvent) { changed(false) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Leaving the window (a group closing, the sidebar hiding) never sends an exit.
        if window == nil { changed(false) }
    }
}

/// Nautical's type: the mockup's monospaced log text and condensed, letter-spaced headings.
enum HarbourType {
    static func mono(_ size: CGFloat) -> Font { .custom("SourceCodePro-Regular", fixedSize: size) }
    static func heading(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold).width(.condensed) }
}

/// A tab (in the traffic list, a space) as Nautical's sidebar shows it: a vessel at anchor, under way while its agent
/// works, inbound with a reply you have not read, or calling while it waits for an answer.
struct HarbourVessel: Equatable, Identifiable {
    /// In the order of how much the vessel needs you: the radar's range bands, from the anchorage in to the harbour.
    enum Status: Equatable, CaseIterable { case anchor, underWay, inbound, calling }
    let id: UUID
    let name: String
    let host: String
    /// Its host, whose radar sector it sails in, and whether that host is reachable.
    var hostID: HostID = .local
    var inRange = true
    let status: Status
    /// When its agent started working; the heading vector grows with the passage.
    let since: Date?
    let selected: Bool
    let shortcut: String
    /// Its git branch, the course it is set on.
    var heading: String? = nil
    /// Subagents its agents run: escorts trailing it.
    var escorts = 0
    /// Whether an agent or a watched program is aboard; a plain shell plots as a bare contact.
    var crewed = true
    /// The space it sails with on the radar, and that convoy's name where the radar shows it.
    var convoy: UUID? = nil
    var convoyName: String? = nil
    /// Its VHF channel, the radar's tag for a vessel it does not label.
    var channel: String? = nil

    var statusLabel: String {
        switch status {
        case .anchor: "at anchor"
        case .underWay: "under way"
        case .inbound: "inbound"
        case .calling: "calling"
        }
    }

    @MainActor static func make(_ space: Space, workspace: Workspace, selected: Bool, pending: Bool, ready: Bool,
                                shortcut: String, heading: String? = nil) -> HarbourVessel {
        make(id: space.id, name: workspace.liveName(space), host: workspace.hosts.record(space.hostID),
             state: workspace.hosts.state(space.hostID), surfaceIDs: space.tabs.flatMap(\.surfaceIDs), selected: selected,
             pending: pending, ready: ready, shortcut: shortcut, heading: heading)
    }

    /// A vessel for any row: a space, or a tab, by its terminals' agents and programs.
    @MainActor static func make(id: UUID, name: String, host: HostRecord, state: HostConnectionState, surfaceIDs: [UUID],
                                selected: Bool, pending: Bool, ready: Bool, shortcut: String,
                                heading: String? = nil) -> HarbourVessel {
        let runtime = TerminalRuntime.shared
        let sessions = surfaceIDs.compactMap { runtime.chat.sessions[$0] }
        let working = sessions.filter { AgentWorkingState.isWorking($0) }
        return HarbourVessel(id: id, name: name, host: host.id == .local ? "Local" : host.name, hostID: host.id,
                             inRange: host.id == .local || state != .disconnected,
                             status: pending ? .calling : ready ? .inbound : working.isEmpty ? .anchor : .underWay,
                             since: working.compactMap(\.workingSince).min(), selected: selected, shortcut: shortcut,
                             heading: heading, escorts: sessions.reduce(0) { $0 + $1.subagents.count },
                             crewed: !sessions.isEmpty || surfaceIDs.contains { !runtime.programs.visible($0).isEmpty })
    }

    static func elapsed(since date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        return seconds >= 3600 ? "\(seconds / 3600)h \(seconds % 3600 / 60)m"
            : seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
}

extension HarbourVessel.Status {
    func tint(_ palette: SidebarPalette) -> Color {
        switch self {
        case .anchor: palette.secondary
        case .underWay: palette.accent
        case .inbound: palette.ink
        case .calling: palette.warning
        }
    }
}

/// Where the radar plots its vessels. Each host takes a sector of bearings in proportion to its tabs, clockwise from
/// north in the order the tabs are listed; inside it each space's tabs sail as a convoy on an arc of their own; and a
/// vessel's range is its status's band. So a tab keeps its bearing while it closes on the harbour and moves off again.
/// A convoy's tabs in one band spread across its arc, alternately in and out within the band.
struct HarbourChart: Equatable {
    struct Sector: Equatable { let host: HostID; let name: String; let inRange: Bool; let start: Double; let end: Double }
    /// `leading`: the first convoy of its sector, which starts at the sector's boundary.
    struct Convoy: Equatable { let name: String?; let start: Double; let end: Double; let leading: Bool }
    struct Fix: Equatable { let bearing: Double; let distance: Double }
    private(set) var sectors: [Sector] = []
    private(set) var convoys: [Convoy] = []
    private(set) var fixes: [UUID: Fix] = [:]

    /// A status's range band, as fractions of the radius: the more the vessel needs you, the nearer the harbour. The
    /// rim outside the anchorage keeps the sectors' and convoys' names.
    static func band(_ status: HarbourVessel.Status) -> ClosedRange<Double> {
        switch status {
        case .calling: 0.14...0.32
        case .inbound: 0.32...0.5
        case .underWay: 0.5...0.68
        case .anchor: 0.68...0.86
        }
    }

    static func bandName(_ status: HarbourVessel.Status) -> String {
        switch status {
        case .calling: "CALLING"
        case .inbound: "INBOUND"
        case .underWay: "UNDER WAY"
        case .anchor: "ANCHORAGE"
        }
    }

    init(_ vessels: [HarbourVessel]) {
        var hosts: [(first: HarbourVessel, convoys: [[HarbourVessel]])] = []
        for vessel in vessels {
            guard let h = hosts.firstIndex(where: { $0.first.hostID == vessel.hostID }) else {
                hosts.append((vessel, [[vessel]])); continue
            }
            let key = vessel.convoy ?? vessel.id
            if let c = hosts[h].convoys.firstIndex(where: { ($0[0].convoy ?? $0[0].id) == key }) { hosts[h].convoys[c].append(vessel) }
            else { hosts[h].convoys.append([vessel]) }
        }
        // A sector's share is its tabs and one more, so a host with a single tab keeps room around it.
        let total = Double(vessels.count + hosts.count)
        var start = 0.0
        for host in hosts {
            let count = host.convoys.reduce(0) { $0 + $1.count }
            let span = 360 * Double(count + 1) / total
            sectors.append(Sector(host: host.first.hostID, name: host.first.host, inRange: host.first.inRange,
                                  start: start, end: start + span))
            // Padding keeps vessels off the boundaries, and north clear for the bands' names.
            let padding = min(10, span * 0.15)
            var bearing = start + padding
            let arc = span - 2 * padding
            for (index, convoy) in host.convoys.enumerated() {
                let width = arc * Double(convoy.count) / Double(count)
                convoys.append(Convoy(name: convoy[0].convoyName, start: bearing, end: bearing + width, leading: index == 0))
                for status in HarbourVessel.Status.allCases {
                    let group = convoy.filter { $0.status == status }
                    let band = Self.band(status), depth = band.upperBound - band.lowerBound
                    for (place, vessel) in group.enumerated() {
                        let stagger = group.count == 1 ? 0 : place % 2 == 0 ? -0.22 : 0.22
                        fixes[vessel.id] = Fix(bearing: bearing + width * (Double(place) + 0.5) / Double(group.count),
                                               distance: (band.lowerBound + band.upperBound) / 2 + stagger * depth)
                    }
                }
                bearing += width
            }
            start += span
        }
    }
}

/// Nautical's radar scope, with the harbour (you) at its center. Every tab is a vessel, plotted nearer the harbour the
/// more it needs you: calling (waiting for an answer) on the inner ring, then inbound with an unread reply, under way
/// while its agent works, and the anchorage outside. Each host sails in its own sector and each space's tabs in a
/// convoy inside it (HarbourChart). The sweep turns every four seconds and each vessel glows as it passes. Clicking a
/// vessel selects its tab, and clicking a sector's rim narrows the traffic list to that host. Labels go to the vessels
/// that are selected, active or under the pointer; the rest carry their channel. Reduce Motion holds the sweep still
/// and drops the glow.
///
/// The sweep and its echoes turn in the compositor (HarbourSweep, HarbourEchoes), as the composer's motion does: a
/// SwiftUI redraw per frame of a full-screen window throttles its presentation on an Adaptive-refresh display
/// (docs/benchmarks.md, Chat rendering). The plot redraws only when a vessel or the pointer's vessel changes, and once a
/// second while one is under way, for its passage time.
struct HarbourRadar: View, Equatable {
    let vessels: [HarbourVessel]
    let reduceMotion: Bool
    /// The host whose sector narrows the traffic list.
    var focus: HostID? = nil
    var select: (UUID) -> Void = { _ in }
    var filter: (HostID) -> Void = { _ in }
    @State private var hovered: UUID?
    static let period: TimeInterval = 4
    /// The still sweep's bearing, the mockup's.
    static let restingBearing: Double = 32
    /// How far behind the sweep line its trail reaches, in degrees.
    static let trail: Double = 70
    /// A passage this long draws the full heading vector.
    private static let fullPassage: TimeInterval = 600

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.vessels == rhs.vessels && lhs.reduceMotion == rhs.reduceMotion && lhs.focus == rhs.focus
    }

    fileprivate static func point(_ bearing: Double, _ distance: CGFloat, from center: CGPoint) -> CGPoint {
        let angle = bearing * .pi / 180
        return CGPoint(x: center.x + sin(angle) * distance, y: center.y - cos(angle) * distance)
    }

    fileprivate static func geometry(_ size: CGSize) -> (center: CGPoint, radius: CGFloat) {
        (CGPoint(x: size.width / 2, y: size.height / 2), min(size.width, size.height) / 2 - 1)
    }

    var body: some View {
        let palette = Chrome.palette
        let chart = HarbourChart(vessels)
        let underWay = vessels.contains { $0.since != nil }
        GeometryReader { proxy in
            ZStack {
                HarbourSweep(accent: palette.accent, moving: !reduceMotion)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                if !reduceMotion {
                    HarbourEchoes(echoes: echoes(chart, palette: palette)).frame(width: proxy.size.width, height: proxy.size.height)
                    HarbourPings(vessels: vessels, palette: palette).frame(width: proxy.size.width, height: proxy.size.height)
                }
                TimelineView(.animation(minimumInterval: 1, paused: !underWay)) { timeline in
                    Canvas { context, size in draw(in: &context, size: size, chart: chart, now: timeline.date, palette: palette) }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                if let id = vessel(at: location, chart: chart, size: proxy.size) { select(id) }
                else if let host = sector(at: location, chart: chart, size: proxy.size) { filter(host) }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location): hovered = vessel(at: location, chart: chart, size: proxy.size)
                case .ended: hovered = nil
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Harbour radar")
        .accessibilityValue(vessels.map { "\($0.name), \($0.statusLabel)" }.joined(separator: "; "))
        .accessibilityIdentifier("harbour-radar")
    }

    /// The vessel nearest `location`, within reach of a click.
    private func vessel(at location: CGPoint, chart: HarbourChart, size: CGSize) -> UUID? {
        let (center, radius) = Self.geometry(size)
        return chart.fixes.map { id, fix -> (UUID, CGFloat) in
            let p = Self.point(fix.bearing, radius * fix.distance, from: center)
            return (id, hypot(p.x - location.x, p.y - location.y))
        }.filter { $0.1 < 16 }.min { $0.1 < $1.1 }?.0
    }

    /// The bearing of `p` from `origin`, clockwise from north.
    fileprivate static func bearing(of p: CGPoint, from origin: CGPoint) -> Double {
        let bearing = atan2(p.x - origin.x, origin.y - p.y) * 180 / .pi
        return bearing < 0 ? bearing + 360 : bearing
    }

    /// The sector whose rim, outside the anchorage, holds `location`; none while one host has the whole scope.
    private func sector(at location: CGPoint, chart: HarbourChart, size: CGSize) -> HostID? {
        let (center, radius) = Self.geometry(size)
        let distance = hypot(location.x - center.x, location.y - center.y)
        guard chart.sectors.count > 1, distance > radius * HarbourChart.band(.anchor).upperBound, distance < radius + 4 else { return nil }
        let bearing = Self.bearing(of: location, from: center)
        return chart.sectors.first { $0.start <= bearing && bearing < $0.end }?.host
    }

    /// Each vessel's glow as the sweep passes: bright for those that need you, dim at anchor, faint for bare contacts.
    private func echoes(_ chart: HarbourChart, palette: SidebarPalette) -> [HarbourEchoes.Echo] {
        vessels.compactMap { vessel in
            chart.fixes[vessel.id].map { fix in
                HarbourEchoes.Echo(bearing: fix.bearing, distance: fix.distance,
                                   color: vessel.status == .anchor ? palette.accent : vessel.status.tint(palette),
                                   strength: !vessel.crewed ? 0.16 : vessel.status == .anchor ? 0.26 : 0.5)
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, chart: HarbourChart, now: Date, palette: SidebarPalette) {
        let (center, radius) = Self.geometry(size)
        guard radius > 20 else { return }
        func point(_ bearing: Double, _ distance: CGFloat, from origin: CGPoint = center) -> CGPoint {
            Self.point(bearing, distance, from: origin)
        }
        func circle(_ r: CGFloat, at p: CGPoint = center) -> Path {
            Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
        func spoke(_ bearing: Double, from inner: Double, to outer: Double) -> Path {
            var path = Path()
            path.move(to: point(bearing, radius * inner)); path.addLine(to: point(bearing, radius * outer))
            return path
        }
        /// An arc clockwise between two bearings. Path angles run from east, and SwiftUI's y axis points down.
        func arc(_ r: CGFloat, from start: Double, to end: Double, at p: CGPoint = center) -> Path {
            var path = Path()
            path.addArc(center: p, radius: r, startAngle: .degrees(start - 90), endAngle: .degrees(end - 90), clockwise: false)
            return path
        }
        func hull(_ course: Double, _ length: CGFloat, at p: CGPoint) -> Path {
            var path = Path()
            path.move(to: point(course, length, from: p))
            path.addLine(to: point(course + 141, length * 1.14, from: p))
            path.addLine(to: point(course - 141, length * 1.14, from: p))
            path.closeSubpath()
            return path
        }
        let inner = HarbourChart.band(.calling).lowerBound, anchorage = HarbourChart.band(.anchor).upperBound
        let small = HarbourType.mono(max(8, min(10, radius / 22)))
        let font = HarbourType.mono(max(9, min(11, radius / 20)))

        // An out-of-range host's sector is shaded.
        for sector in chart.sectors where !sector.inRange {
            var wedge = arc(radius, from: sector.start, to: sector.end)
            wedge.addArc(center: center, radius: radius * inner, startAngle: .degrees(sector.end - 90),
                         endAngle: .degrees(sector.start - 90), clockwise: true)
            wedge.closeSubpath()
            context.fill(wedge, with: .color(palette.faint.opacity(0.35)))
        }

        // The rim and the bands' rings, the sectors' boundaries, and dashed lines between a sector's convoys.
        context.stroke(circle(radius), with: .color(palette.faint), lineWidth: 1.5)
        for status in [HarbourVessel.Status.calling, .inbound, .underWay] {
            context.stroke(circle(radius * HarbourChart.band(status).upperBound), with: .color(palette.control), lineWidth: 1)
        }
        context.stroke(circle(radius * anchorage), with: .color(palette.separator), style: StrokeStyle(lineWidth: 1, dash: [2, 6]))
        var boundaries = spoke(0, from: inner, to: 1)
        for sector in chart.sectors { boundaries.addPath(spoke(sector.start, from: inner, to: 1)) }
        context.stroke(boundaries, with: .color(palette.control), lineWidth: 1)
        var convoyLines = Path()
        for convoy in chart.convoys where !convoy.leading { convoyLines.addPath(spoke(convoy.start, from: inner, to: anchorage)) }
        context.stroke(convoyLines, with: .color(palette.separator), style: StrokeStyle(lineWidth: 1, dash: [2, 6]))
        if let focus, let sector = chart.sectors.first(where: { $0.host == focus }) {
            context.stroke(arc(radius, from: sector.start, to: sector.end), with: .color(palette.accent), lineWidth: 2.5)
        }
        // Text already placed, and the vessels, so later text moves clear of them or gives way.
        var placed: [CGRect] = chart.fixes.values.map { fix in
            let p = point(fix.bearing, radius * fix.distance)
            return CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)
        }
        func clear(_ frame: CGRect) -> Bool {
            frame.minX >= 1 && frame.maxX <= size.width - 1 && frame.minY >= 1 && frame.maxY <= size.height - 1
                && !placed.contains { $0.insetBy(dx: -2, dy: -1).intersects(frame) }
        }

        // The bands' names, down the north line.
        for status in HarbourVessel.Status.allCases {
            let text = context.resolve(Text(HarbourChart.bandName(status)).font(small).foregroundColor(palette.detail))
            let origin = CGPoint(x: center.x + 4, y: center.y - radius * HarbourChart.band(status).upperBound + 3)
            placed.append(CGRect(origin: origin, size: text.measure(in: size)))
            context.draw(text, at: origin, anchor: .topLeading)
        }

        // The harbour: you, at the center.
        context.fill(circle(4), with: .color(palette.ink))
        context.stroke(circle(9), with: .color(palette.ink.opacity(0.5)), lineWidth: 1)
        if vessels.isEmpty {
            context.draw(Text("No traffic in range").font(font).foregroundColor(palette.detail),
                         at: CGPoint(x: center.x, y: center.y + radius * 0.45))
        }

        // Sectors are named on the rim just past their boundary, once there is more than the local one.
        let namesSectors = chart.sectors.count > 1 || chart.sectors.contains { $0.host != .local || !$0.inRange }
        if namesSectors {
            for sector in chart.sectors {
                let text = context.resolve(Text(sector.name.uppercased())
                    .font(HarbourType.heading(10)).tracking(1.2)
                    .foregroundColor(sector.host == focus ? palette.accent : sector.inRange ? palette.muted : palette.detail))
                let measured = text.measure(in: size), rim = radius - 9
                let past = min(Double(measured.width / 2 + 6) / Double(rim) * 180 / .pi, (sector.end - sector.start) / 2)
                let p = point(sector.start + past, rim)
                var frame = CGRect(x: p.x - measured.width / 2, y: p.y - measured.height / 2, width: measured.width, height: measured.height)
                frame.origin.x = min(max(1, frame.minX), size.width - 1 - frame.width)
                placed.append(frame)
                context.draw(text, at: CGPoint(x: frame.midX, y: frame.midY))
            }
        }
        // An out-of-range sector says so across its shading, where that is clear.
        for sector in chart.sectors where !sector.inRange {
            let text = context.resolve(Text("out of range").font(small).foregroundColor(palette.muted))
            let measured = text.measure(in: size)
            for distance in [0.41, 0.59, 0.23] {
                let p = point((sector.start + sector.end) / 2, radius * distance)
                let frame = CGRect(x: p.x - measured.width / 2, y: p.y - measured.height / 2, width: measured.width, height: measured.height)
                guard clear(frame) else { continue }
                placed.append(frame)
                context.draw(text, at: p)
                break
            }
        }

        // The vessels, the selected one and those that need you last so they draw on top.
        func rank(_ vessel: HarbourVessel) -> Int {
            vessel.selected ? 9 : HarbourVessel.Status.allCases.firstIndex(of: vessel.status) ?? 0
        }
        let ordered = vessels.sorted { rank($0) < rank($1) }
        for vessel in ordered {
            guard let fix = chart.fixes[vessel.id] else { continue }
            let p = point(fix.bearing, radius * fix.distance)
            let tint = vessel.status.tint(palette)
            // Under way it heads out; inbound and calling, home.
            let course = vessel.status == .underWay ? fix.bearing : fix.bearing + 180
            let reach = radius * 0.13
            switch vessel.status {
            case .anchor where !vessel.crewed:
                context.fill(circle(2.5, at: p), with: .color(palette.muted))
            case .anchor:
                context.stroke(circle(7, at: p), with: .color(tint), lineWidth: 1.4)
                var anchor = Path()
                anchor.move(to: CGPoint(x: p.x, y: p.y - 4)); anchor.addLine(to: CGPoint(x: p.x, y: p.y + 4))
                anchor.move(to: CGPoint(x: p.x - 2, y: p.y - 2.5)); anchor.addLine(to: CGPoint(x: p.x + 2, y: p.y - 2.5))
                anchor.move(to: CGPoint(x: p.x - 3, y: p.y + 1.5))
                anchor.addQuadCurve(to: CGPoint(x: p.x + 3, y: p.y + 1.5), control: CGPoint(x: p.x, y: p.y + 5.5))
                context.stroke(anchor, with: .color(tint), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            case .underWay:
                // The wake astern, the heading vector ahead and its progress over the passage.
                let passage = vessel.since.map { min(1, now.timeIntervalSince($0) / Self.fullPassage) } ?? 0
                var wake = Path()
                wake.move(to: p); wake.addLine(to: point(course + 180, reach * 0.85, from: p))
                context.stroke(wake, with: .color(tint.opacity(0.7)), style: StrokeStyle(lineWidth: 1.2, dash: [1.5, 5]))
                var vector = Path()
                vector.move(to: p); vector.addLine(to: point(course, reach, from: p))
                context.stroke(vector, with: .color(tint), lineWidth: 1.4)
                if passage > 0 {
                    var progress = Path()
                    progress.move(to: p); progress.addLine(to: point(course, reach * passage, from: p))
                    context.stroke(progress, with: .color(tint.opacity(0.35)), lineWidth: 5)
                }
                context.fill(hull(course, 10, at: p), with: .color(tint))
            case .inbound:
                // Its course home, ahead of it.
                var line = Path()
                line.move(to: point(course, 12, from: p)); line.addLine(to: point(course, 12 + reach * 0.6, from: p))
                context.stroke(line, with: .color(tint.opacity(0.6)), style: StrokeStyle(lineWidth: 1.2, dash: [1.5, 4]))
                context.fill(hull(course, 10, at: p), with: .color(tint))
            case .calling:
                // Hailing the harbour: two arcs ahead of its bow.
                for (index, r) in [CGFloat(13), 17].enumerated() {
                    context.stroke(arc(r, from: course - 32, to: course + 32, at: p),
                                   with: .color(tint.opacity(index == 0 ? 0.8 : 0.45)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
                context.fill(hull(course, 10, at: p), with: .color(tint))
            }
            // Escorts: its subagents, small hulls in line astern, alternating either side of its wake.
            for index in 0..<min(vessel.escorts, 4) {
                let side: Double = index % 2 == 0 ? 1 : -1
                let e = point(course + 180 + side * 28, 16 + CGFloat(index / 2) * 10, from: p)
                context.fill(hull(course, 5, at: e), with: .color((vessel.status == .anchor ? palette.secondary : tint).opacity(0.75)))
            }
            if vessel.selected {
                context.stroke(circle(16, at: p), with: .color(palette.accent.opacity(0.6)), lineWidth: 1)
            }
        }

        // Labels: the selected vessel, those that need you, those under way, then the one under the pointer. Each takes
        // the first spot around its vessel that is clear and inside the plot; with none, it steps past what is in its
        // way and a leader line ties it back.
        let labelled = ordered.reversed().filter { $0.selected || $0.status != .anchor || $0.id == hovered }
        let hoveredLast = labelled.filter { $0.id != hovered } + labelled.filter { $0.id == hovered }
        for vessel in hoveredLast {
            guard let fix = chart.fixes[vessel.id] else { continue }
            let p = point(fix.bearing, radius * fix.distance)
            let title = Text(vessel.name).foregroundColor(vessel.selected || vessel.id == hovered ? palette.ink : palette.secondary)
            let detail: [String]
            switch vessel.status {
            case .underWay, .calling: detail = [vessel.statusLabel, HarbourVessel.elapsed(since: vessel.since, now: now)]
            case .anchor, .inbound: detail = [vessel.statusLabel, vessel.channel ?? ""]
            }
            let first = context.resolve(title.font(font))
            let second = context.resolve(Text(detail.filter { !$0.isEmpty }.joined(separator: " · ")).font(font)
                .foregroundColor(vessel.status == .anchor ? palette.muted : vessel.status.tint(palette)))
            let third = vessel.heading.map { context.resolve(Text("heading " + $0).font(font).foregroundColor(palette.detail)) }
            let firstSize = first.measure(in: size), secondSize = second.measure(in: size)
            let thirdSize = third?.measure(in: size) ?? .zero
            let width = max(firstSize.width, secondSize.width, thirdSize.width)
            let height = firstSize.height + secondSize.height + thirdSize.height
            let spots = [CGPoint(x: p.x + 18, y: p.y - 2), CGPoint(x: p.x - 18 - width, y: p.y - 2),
                         CGPoint(x: p.x + 18, y: p.y + 2 - height), CGPoint(x: p.x - 18 - width, y: p.y + 2 - height),
                         CGPoint(x: p.x - width / 2, y: p.y + 18), CGPoint(x: p.x - width / 2, y: p.y - 18 - height)]
                .map { CGRect(origin: $0, size: CGSize(width: width, height: height)) }
            var frame: CGRect
            if let spot = spots.first(where: clear) { frame = spot } else {
                frame = spots[0]
                frame.origin.x = p.x + 18 + width <= size.width - 2 ? p.x + 18 : max(2, min(p.x - 18 - width, size.width - 2 - width))
                frame.origin.y = min(max(2, frame.minY), size.height - 2 - height)
                for _ in 0..<8 {
                    guard let blocking = placed.first(where: { $0.insetBy(dx: 0, dy: -2).intersects(frame) }) else { break }
                    frame.origin.y = blocking.maxY + 3 + height <= size.height - 2 ? blocking.maxY + 3 : blocking.minY - 3 - height
                }
                let near = CGPoint(x: min(max(p.x, frame.minX), frame.maxX), y: min(max(p.y, frame.minY), frame.maxY))
                if hypot(near.x - p.x, near.y - p.y) > 24 {
                    var leader = Path()
                    leader.move(to: point(Self.bearing(of: near, from: p), 11, from: p)); leader.addLine(to: near)
                    context.stroke(leader, with: .color(palette.detail.opacity(0.7)), lineWidth: 0.8)
                }
            }
            // The pointer's label shows wherever it lands; it goes when the pointer does.
            if vessel.id == hovered, !vessel.selected, vessel.status == .anchor {
                context.fill(Path(roundedRect: frame.insetBy(dx: -3, dy: -2), cornerRadius: 3), with: .color(palette.window.opacity(0.85)))
            }
            placed.append(frame)
            context.draw(first, at: CGPoint(x: frame.minX, y: frame.minY), anchor: .topLeading)
            context.draw(second, at: CGPoint(x: frame.minX, y: frame.minY + firstSize.height), anchor: .topLeading)
            if let third { context.draw(third, at: CGPoint(x: frame.minX, y: frame.minY + firstSize.height + secondSize.height), anchor: .topLeading) }
        }

        // Convoys are named on the rim within their arc, where there is room.
        for convoy in chart.convoys {
            guard let name = convoy.name else { continue }
            let text = context.resolve(Text(name.count > 18 ? String(name.prefix(17)) + "…" : name).font(small).foregroundColor(palette.muted))
            let measured = text.measure(in: size)
            for fraction in [0.5, 0.75, 0.25] {
                let p = point(convoy.start + (convoy.end - convoy.start) * fraction, radius * (anchorage + 1) / 2)
                let frame = CGRect(x: p.x - measured.width / 2, y: p.y - measured.height / 2, width: measured.width, height: measured.height)
                guard clear(frame) else { continue }
                placed.append(frame)
                context.draw(text, at: p)
                break
            }
        }

        // The other crewed vessels carry their channel, where it fits.
        for vessel in ordered where !labelled.contains(where: { $0.id == vessel.id }) && vessel.crewed {
            guard let fix = chart.fixes[vessel.id], let channel = vessel.channel else { continue }
            let p = point(fix.bearing, radius * fix.distance)
            let text = context.resolve(Text(channel.replacingOccurrences(of: "CH ", with: "")).font(small).foregroundColor(palette.detail))
            let measured = text.measure(in: size)
            let frame = CGRect(x: p.x + 11, y: p.y - measured.height / 2, width: measured.width, height: measured.height)
            guard clear(frame) else { continue }
            placed.append(frame)
            context.draw(text, at: frame.origin, anchor: .topLeading)
        }
    }
}

/// Nautical's traffic list: one row per space with its status, passage time and key. Clicking selects the space;
/// the context menu is the space's own. A sector clicked on the radar narrows it to that host's traffic, named in its
/// heading, which clears it.
private struct HarbourTrafficList: View {
    let vessels: [HarbourVessel]
    let typography: AppTypography
    var sector: String? = nil
    var clearSector: () -> Void = {}
    let select: (UUID) -> Void
    let menu: (UUID) -> AnyView

    private var size: CGFloat { typography.size(offset: -1.5) }
    private var font: Font { HarbourType.mono(size) }
    /// Source Code Pro advances 0.6 em per character: columns fit their longest values, "under way", "59m 59s" and a
    /// two-digit key.
    private func columnWidth(_ characters: Int) -> CGFloat { ceil(size * 0.6 * CGFloat(characters)) + 2 }
    private var statusWidth: CGFloat { columnWidth(9) }
    private var timeWidth: CGFloat { columnWidth(7) }
    private var keyWidth: CGFloat { columnWidth(2) }

    var body: some View {
        VStack(spacing: 0) {
            columns(trafficHeading.fixedSize(), Text("STATUS"), Text("TIME"), Text("KEY").fixedSize())
                .font(HarbourType.heading(typography.size(offset: -2))).tracking(1.8)
                .foregroundStyle(Chrome.palette.detail)
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) { Rectangle().fill(Chrome.border).frame(height: 1) }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vessels) { row($0).id($0.id) }
                    }.padding(.top, 2)
                }
                .scrollIndicators(.never)
                .onChange(of: vessels.first(where: \.selected)?.id) { _, id in
                    if let id { withAnimation(nil) { scroll.scrollTo(id) } }
                }
            }
        }
        .accessibilityIdentifier("harbour-traffic")
    }

    @ViewBuilder private var trafficHeading: some View {
        if let sector {
            Button(action: clearSector) { Text("TRAFFIC · \(sector.uppercased()) · \(vessels.count)  ✕") }
                .buttonStyle(.plain).help("Show all traffic").accessibilityIdentifier("harbour-sector")
        } else {
            Text("TRAFFIC · \(vessels.count)")
        }
    }

    private func columns(_ name: some View, _ status: some View, _ time: some View, _ key: some View) -> some View {
        HStack(spacing: 8) {
            name.frame(maxWidth: .infinity, alignment: .leading)
            status.frame(width: statusWidth, alignment: .leading)
            time.frame(width: timeWidth, alignment: .leading)
            key.frame(width: keyWidth, alignment: .trailing)
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
    }

    private func row(_ vessel: HarbourVessel) -> some View {
        let tint = vessel.status.tint(Chrome.palette)
        return Button { select(vessel.id) } label: {
            columns(
                HStack(spacing: 7) {
                    glyph(vessel.status, tint: tint)
                    Text(vessel.name).foregroundStyle(vessel.selected ? Chrome.ink : Chrome.palette.secondary)
                        .truncationMode(.middle)
                    Text(vessel.host).foregroundStyle(vessel.selected ? Chrome.muted : Chrome.palette.detail)
                        .truncationMode(.tail).layoutPriority(-1)
                    if let heading = vessel.heading {
                        Text("⎇ " + heading).foregroundStyle(Chrome.palette.faint)
                            .truncationMode(.tail).layoutPriority(-2)
                    }
                },
                Text(vessel.status == .anchor ? "anchor" : vessel.statusLabel).foregroundStyle(vessel.status == .anchor ? Chrome.palette.secondary : tint),
                TimelineView(.animation(minimumInterval: 1, paused: vessel.since == nil)) { timeline in
                    Text(vessel.since == nil ? "–" : HarbourVessel.elapsed(since: vessel.since, now: timeline.date))
                }.monospacedDigit().foregroundStyle(vessel.since == nil ? Chrome.palette.detail : Chrome.ink),
                Text(vessel.shortcut).monospacedDigit().foregroundStyle(Chrome.muted)
            )
            .font(font)
            .padding(.vertical, 6)
            .background(vessel.selected ? Chrome.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { menu(vessel.id) }
        .accessibilityLabel("\(vessel.name), \(vessel.host), \(vessel.statusLabel)")
        .accessibilityAddTraits(vessel.selected ? .isSelected : [])
        .accessibilityIdentifier("space-\(vessel.id)")
    }

    @ViewBuilder private func glyph(_ status: HarbourVessel.Status, tint: Color) -> some View {
        switch status {
        case .anchor: Circle().strokeBorder(tint, lineWidth: 1.2).frame(width: 7, height: 7)
        case .underWay: HarbourHull().fill(tint).frame(width: 8, height: 8)
        // Inbound and calling, it heads home, as on the radar.
        case .inbound, .calling: HarbourHull().fill(tint).frame(width: 8, height: 8).rotationEffect(.degrees(180))
        }
    }
}

private struct HarbourHull: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The radar's sweep: its trail and line drawn once, turned by Core Animation at the screen's frame rate.
private struct HarbourSweep: NSViewRepresentable {
    let accent: Color
    let moving: Bool

    func makeNSView(context: Context) -> SweepView { SweepView(accent: accent) }

    func updateNSView(_ view: SweepView, context: Context) {
        view.accent = accent
        view.moving = moving
    }

    static func dismantleNSView(_ view: SweepView, coordinator: ()) { view.stop() }

    final class SweepView: CompositorView {
        var accent: Color { didSet { if accent != oldValue { redraw() } } }
        private let beam = CALayer()
        private var drawnDiameter: CGFloat = 0
        private var diameter: CGFloat { max(0, min(bounds.width, bounds.height) - 2) }

        init(accent: Color) {
            self.accent = accent
            super.init()
            layer?.addSublayer(beam)
        }

        override func layout() {
            super.layout()
            if drawnDiameter != diameter { redraw(); updateAnimations() }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            beam.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }

        /// Pointing north, its trail behind it counterclockwise. The view is flipped, so a positive rotation turns
        /// it clockwise.
        override func redraw() {
            let diameter = diameter
            drawnDiameter = diameter
            guard diameter > 0 else { return }
            let trail = HarbourRadar.trail / 360
            let gradient = AngularGradient(stops: [
                .init(color: accent.opacity(0), location: 0),
                .init(color: accent.opacity(0), location: 1 - trail),
                .init(color: accent.opacity(0.05), location: 1 - trail * 0.8),
                .init(color: accent.opacity(0.28), location: 1),
            ], center: .center, startAngle: .degrees(-90), endAngle: .degrees(270))
            draw(ZStack(alignment: .top) {
                Circle().fill(gradient)
                Rectangle().fill(accent.opacity(0.55)).frame(width: 1.2, height: diameter / 2)
            }.frame(width: diameter, height: diameter), into: beam, proposal: ProposedViewSize(width: diameter, height: diameter))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            beam.position = CGPoint(x: bounds.midX, y: bounds.midY)
            if !moving { rest() }
            CATransaction.commit()
        }

        override func start(_ rate: CAFrameRateRange) {
            guard drawnDiameter > 0 else { return }
            beam.transform = CATransform3DIdentity
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0; turn.toValue = 2 * Double.pi; turn.duration = HarbourRadar.period
            loop(turn, on: beam, rate: rate)
        }

        override func stop() {
            super.stop()
            rest()
        }

        /// Reduce Motion, or a hidden window: the sweep rests at the mockup's bearing.
        private func rest() {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            beam.transform = CATransform3DMakeRotation(HarbourRadar.restingBearing * .pi / 180, 0, 0, 1)
            CATransaction.commit()
        }
    }
}

/// A radar ping where a vessel changes course: getting under way, coming inbound or calling, a ring at its new range
/// in its new color that opens and fades once, in the compositor like the sweep.
private struct HarbourPings: NSViewRepresentable {
    let vessels: [HarbourVessel]
    let palette: SidebarPalette

    func makeNSView(context: Context) -> PingView { PingView() }

    func updateNSView(_ view: PingView, context: Context) {
        view.palette = palette
        view.update(vessels)
    }

    final class PingView: NSView {
        var palette: SidebarPalette?
        private var statuses: [UUID: HarbourVessel.Status] = [:]
        private static let duration: CFTimeInterval = 1.4

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            setAccessibilityElement(false)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Pings each vessel that was plotted before and has just changed to any status but at anchor.
        func update(_ vessels: [HarbourVessel]) {
            let next = Dictionary(vessels.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
            defer { statuses = next }
            guard let window, window.occlusionState.contains(.visible), bounds.width > 0, let palette else { return }
            let chart = HarbourChart(vessels)
            let (center, radius) = HarbourRadar.geometry(bounds.size)
            for vessel in vessels where vessel.status != .anchor {
                guard let previous = statuses[vessel.id], previous != vessel.status, let fix = chart.fixes[vessel.id] else { continue }
                ping(at: HarbourRadar.point(fix.bearing, radius * fix.distance, from: center), color: vessel.status.tint(palette),
                     window: window)
            }
        }

        private func ping(at point: CGPoint, color: Color, window: NSWindow) {
            let ring = CAShapeLayer()
            let size: CGFloat = 52
            ring.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            ring.position = point
            ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1, dy: 1), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = NSColor(color).cgColor
            ring.lineWidth = 1.5
            ring.opacity = 0
            ring.contentsScale = window.backingScaleFactor
            layer?.addSublayer(ring)
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.15; grow.toValue = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.9; fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = Self.duration
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.preferredFrameRateRange = MotionRate.range(for: window)
            CATransaction.begin()
            CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
            ring.add(group, forKey: "ping")
            CATransaction.commit()
        }
    }
}

/// The sweep's echoes: each vessel glows as the beam crosses it and fades over the turn, as a radar's phosphor does.
/// Each glow loops in the compositor on the sweep's period, phase-aligned to the same media clock (CompositorView.loop),
/// so it lights exactly as the beam passes its bearing.
private struct HarbourEchoes: NSViewRepresentable {
    struct Echo: Equatable {
        let bearing: Double
        let distance: Double
        let color: Color
        /// The glow's peak opacity.
        let strength: Double
    }
    let echoes: [Echo]

    func makeNSView(context: Context) -> EchoView { EchoView() }

    func updateNSView(_ view: EchoView, context: Context) {
        view.echoes = echoes
        view.moving = true
    }

    static func dismantleNSView(_ view: EchoView, coordinator: ()) { view.stop() }

    final class EchoView: CompositorView {
        var echoes: [Echo] = [] { didSet { if echoes != oldValue { redraw(); updateAnimations() } } }
        private var blips: [CALayer] = []
        private var drawnSize: CGSize = .zero
        /// How much of the turn a glow takes to fade.
        private static let fade = 0.6

        override func layout() {
            super.layout()
            if drawnSize != bounds.size { redraw(); updateAnimations() }
        }

        override func redraw() {
            drawnSize = bounds.size
            CATransaction.begin(); CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            blips.forEach { $0.removeFromSuperlayer() }
            blips = []
            guard bounds.width > 0 else { return }
            let (center, radius) = HarbourRadar.geometry(bounds.size)
            for echo in echoes {
                let blip = CAGradientLayer()
                let color = NSColor(echo.color)
                blip.type = .radial
                blip.colors = [color.withAlphaComponent(echo.strength).cgColor, color.withAlphaComponent(0).cgColor]
                blip.startPoint = CGPoint(x: 0.5, y: 0.5)
                blip.endPoint = CGPoint(x: 1, y: 1)
                blip.bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
                blip.position = HarbourRadar.point(echo.bearing, radius * echo.distance, from: center)
                blip.opacity = 0
                blip.contentsScale = window?.backingScaleFactor ?? 2
                layer?.addSublayer(blip)
                blips.append(blip)
            }
        }

        override func start(_ rate: CAFrameRateRange) {
            for (blip, echo) in zip(blips, echoes) { loop(Self.afterglow(at: echo.bearing / 360), on: blip, rate: rate) }
        }

        /// One turn of a glow whose bearing the beam crosses at `phase` of the turn: off until then, full as it
        /// passes, then fading.
        static func afterglow(at phase: Double) -> CAKeyframeAnimation {
            func level(_ time: Double) -> Double {
                let since = (time - phase + 1).truncatingRemainder(dividingBy: 1)
                return pow(max(0, 1 - since / fade), 2)
            }
            let times = Array(Set((0...48).map { Double($0) / 48 } + [phase, max(0, phase - 0.001)])).sorted()
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.keyTimes = times.map { NSNumber(value: $0) }
            animation.values = times.map { level($0) }
            animation.duration = HarbourRadar.period
            return animation
        }
    }
}
