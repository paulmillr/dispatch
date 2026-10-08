import SwiftUI

struct SpaceSidebar: View {
    private var typography: AppTypography { AppTypography(contentSize: settings.values.fontSize) }
    /// Both densities share every layout below; only these numbers differ.
    private var metrics: SidebarMetrics {
        let metrics = settings.values.sidebarMetrics(glass: glass)
        return glass ? metrics.nested(cornerRadius: Self.glassRadius - Self.glassRowInset) : metrics
    }
    private var sidebarFont: Font { AppFont.ui(size: metrics.nameSize) }
    private var sidebarDetailFont: Font { AppFont.ui(size: metrics.detailSize) }
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
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var viewportHeight: CGFloat = 0
    /// The overflow bar's height while it rides over the list's bottom (GlassScrollEdge); rows under it are hidden.
    @State private var overflowBarHeight: CGFloat = 0
    private var visibleHeight: CGFloat { viewportHeight - overflowBarHeight }
    /// The rows' own height, so the glass sidebar's top panel can end where the spaces do.
    @State private var rowsHeight: CGFloat = 0
    @State private var flatDetachedExpanded = true
    @State private var expandedDetached: Set<HostID> = []
    @State private var branches: [UUID: String] = [:]

    private func setSearchQuery(_ value: String) {
        // Filtering can remove hundreds of rows at once. Keep typing immediate
        // instead of retaining all outgoing rows for their reorder animation.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { searchQuery = value }
    }

    private func hiddenSpaces(in order: [Space]) -> [Space] {
        // The overflow bar changes the scroll safe area. It must not keep itself alive
        // through shifted row frames after the complete rows stack fits again.
        guard viewportHeight > 0, rowsHeight > viewportHeight else { return [] }
        return order.filter {
            guard let frame = rowFrames[$0.id] else { return true }
            return frame.minY < -1 || frame.maxY > visibleHeight + 1
        }
    }

    private func spacesBelowViewport(in order: [Space]) -> [Space] {
        guard viewportHeight > 0, rowsHeight > viewportHeight else { return [] }
        let lastVisible = order.lastIndex { space in
            rowFrames[space.id].map { $0.maxY > 0 && $0.minY < visibleHeight } ?? false
        } ?? -1
        return order.enumerated().compactMap { index, space in
            if let frame = rowFrames[space.id] { return frame.maxY > visibleHeight + 1 ? space : nil }
            return index > lastVisible ? space : nil
        }
    }

    private var attentionSpaceIDs: Set<UUID> {
        Set(workspace.spaces.filter { space in
            space.tabs.contains { tab in
                tab.surfaceIDs.contains { TerminalRuntime.shared.chat.sessions[$0]?.approvals.contains(where: \.pending) == true }
            }
        }.map(\.id))
    }

    /// Spaces with a finished, unseen reply: the tile's green ●.
    private var readySpaceIDs: Set<UUID> {
        Set(workspace.spaces.filter { space in
            space.tabs.flatMap(\.surfaceIDs).contains { id in
                TerminalRuntime.shared.chat.sessions[id].map { $0.hasNewMessages && !($0.active && $0.busy) } == true
            }
        }.map(\.id))
    }

    var body: some View {
        let attention = attentionSpaceIDs
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let listed = workspace.spaces(matching: query)
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                // Outside full screen the window row carries the header's buttons. Search opens above the footer.
                if windowControls { windowRow } else { header }
                spaceList(listed: listed, attention: attention)
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
        // With Liquid Glass the sidebar is one panel from top to bottom, floating over the content (MainView) at the
        // glass inset, the title row keeping its place beside the traffic lights inside it.
        .background { if glass { glassPanel.padding(.horizontal, Self.glassInset).padding(.top, Self.glassInset) } }
        .padding(.bottom, glass ? Self.glassInset : 0)
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
    /// Whether the overflow control rides over the list as a bar (GlassScrollEdge) rather than below it.
    private var overflowBar: Bool {
        if #available(macOS 26, *) { return glass } else { return false }
    }
    /// The flat order's actions under the last space, as the host picker lists them: "New space", then "New local
    /// space" while another host is live, where it differs from "New space".
    private var newSpaceButtons: some View {
        let remote = workspace.liveHosts.contains(where: { $0.id != .local })
        return VStack(spacing: metrics.rowSpacing) {
            NewSpaceButton(workspace: workspace, metrics: metrics)
            if remote { NewSpaceButton(workspace: workspace, host: workspace.hosts.record(.local), metrics: metrics) }
        }
        // A host arrives in its own update, before any space moves to it: "New local space" fades in and out.
        .animation(InterfaceMotion.animation(reduce: reduceMotion), value: remote)
        // A little more room than between spaces, so the actions read apart from the list.
        .padding(.top, max(Self.glassRowInset, metrics.rowSpacing))
    }
    private var glassPanel: some View {
        Color.clear.liquidGlass(in: RoundedRectangle(cornerRadius: Self.glassRadius, style: .continuous))
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
            TextField("Search spaces…",
                      text: Binding(get: { searchQuery }, set: { setSearchQuery($0) }),
                      prompt: Text("Search spaces…").foregroundColor(Chrome.palette.detail))
                .textFieldStyle(.plain)
                .foregroundStyle(searchQuery.isEmpty ? Chrome.palette.detail : Chrome.ink)
                .focused($searchFocused)
                .help("Search spaces · ⌘P")
                .accessibilityLabel("Search spaces")
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
                groupingToggle
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
            groupingToggle
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

    private var trailingDrop: some View {
        LocalReorder(edge: .pane, accepts: { if case .space = $0 { return true }; return false }) { item, _ in
            guard case .space(let id) = item,
                  let source = workspace.spaces.first(where: { $0.id == id }),
                  let last = workspace.presentationSpaces.last(where: { workspace.spaceOrder != .tree || $0.hostID == source.hostID }) else { return }
            workspace.reorderSpace(id, relativeTo: last.id, after: true)
        }
    }

    private func spaceList(listed: [Space], attention: Set<UUID>) -> some View {
        let hidden = hiddenSpaces(in: listed)
        let below = spacesBelowViewport(in: listed)
        return ScrollViewReader { scroll in
            VStack(spacing: 0) {
                // The rows stretch to the viewport for the trailing drop target.
                GeometryReader { area in
                    rowsScroll(listed: listed, attention: attention, hidden: hidden, below: below, scroll: scroll,
                               minHeight: area.size.height)
                        .onAppear { viewportHeight = area.size.height }
                        .onChange(of: area.size.height) { _, height in viewportHeight = height }
                }
                if !hidden.isEmpty && !overflowBar {
                    overflowButton(hidden: hidden, below: below, attention: attention, scroll: scroll)
                }
            }
            .onChange(of: workspace.selectedSpace) { _, id in
                if let id { DispatchQueue.main.async { scroll.scrollTo(id) } }
            }
            .onChange(of: workspace.presentationSpaces.map { "\($0.hostID.rawValue):\($0.id)" }) { _, _ in
                if let id = workspace.selectedSpace { DispatchQueue.main.async { scroll.scrollTo(id) } }
            }
            .onAppear { if let id = workspace.selectedSpace { scroll.scrollTo(id) } }
        }
    }

    private func rowsScroll(listed: [Space], attention: Set<UUID>, hidden: [Space], below: [Space], scroll: ScrollViewProxy,
                            minHeight: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                spaceRows(listed: listed, attention: attention)
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
        .onPreferenceChange(SpaceRowFrames.self) { rowFrames = $0 }
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

    private func spaceRows(listed: [Space], attention: Set<UUID>) -> some View {
        let order = workspace.presentationSpaces
        let groups = Dictionary(grouping: listed, by: \.hostID)
        // Unbound spaces show no shortcut.
        let shortcuts = StripSpaceMenu.shortcuts(order, keys: settings.values.keyGroups)
        return VStack(spacing: settings.values.spaceOrder == .tree ? metrics.groupSpacing : metrics.rowSpacing) {
            if settings.values.spaceOrder == .tree {
                ForEach(workspace.hosts.ordered(Set(workspace.liveHosts.map(\.id)).union(workspace.detached.map(\.host)))) { host in
                    let spaces = groups[host.id] ?? []
                    if !spaces.isEmpty || !detachedEntries(host.id).isEmpty || (host.id == .local && searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        hostGroup(host, spaces: spaces, attention: attention, shortcuts: shortcuts)
                    }
                }
            } else {
                ForEach(listed) { space in
                    spaceRow(space, pending: attention.contains(space.id), shortcut: shortcuts[space.id] ?? "")
                }
                newSpaceButtons
                flatDetachedSection
            }
            if listed.isEmpty && matchingDetachedEntries.isEmpty { Text("No matching spaces").font(sidebarDetailFont).foregroundStyle(Chrome.muted).padding(10) }
        }
        .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: InterfaceMotion.spaceSwitchDuration), value: workspace.selectedSpace)
        .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.2), value: listed.map { "\($0.id):\($0.hostID.rawValue)" })
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
                Text(state.shortLabel).font(AppFont.ui(size: metrics.headerSize)).foregroundStyle(Chrome.muted)
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
                            Text(state.shortLabel).font(AppFont.ui(size: metrics.headerSize)).foregroundStyle(Chrome.muted)
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

    private func hostGroup(_ host: HostRecord, spaces: [Space], attention: Set<UUID>, shortcuts: [UUID: String]) -> some View {
        let tint = host.tint?.foreground ?? Chrome.palette.secondary
        let arriving = workspace.hostMoveMotion.arrivals.values.contains(host.id)
        // A heading's plus shows while its header is under the pointer, when the group has no spaces to click through
        // to it, and always for VoiceOver; Large's chip always ends in it, the chip's own control.
        let revealed = metrics.cards || hoveredHost == host.id || spaces.isEmpty || NSWorkspace.shared.isVoiceOverEnabled
        let newSpace = NewSpaceButton(workspace: workspace, host: host, metrics: metrics, grouped: true, revealed: revealed)
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
            ForEach(spaces) { space in
                spaceRow(space, pending: attention.contains(space.id), shortcut: shortcuts[space.id] ?? "")
            }
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

    /// The body of `SpaceSidebarRow`. It reads selection and branch only through its arguments,
    /// so a space switch re-renders the two rows whose selection changed, not every row.
    fileprivate func rowContent(_ space: Space, selected: Bool, pending: Bool, shortcut: String, branch: String?, selection: Namespace.ID) -> some View {
        let flat = settings.values.spaceOrder != .tree
        let hover = SpaceHoverDetails.make(space: space, host: workspace.hosts.record(space.hostID), runtime: .shared)
        return Button { workspace.selectSpace(space.id) } label: {
            let surfaces = space.tabs.flatMap(\.surfaceIDs)
            let mixed = Set(surfaces.compactMap { workspace.hosts.terminals[$0]?.host }).subtracting([space.hostID])
            SidebarSpaceTile(space: space, host: workspace.hosts.record(space.hostID),
                             mixedHost: workspace.hosts.ordered(mixed).first(where: { $0.id != .local }),
                             grouped: !flat, selected: selected, pending: pending, shortcut: shortcut,
                             connecting: surfaces.contains { workspace.hostMoveMotion.connecting.contains($0) },
                             branch: branch,
                             showBranch: settings.values.showGitBranches, metrics: metrics, selection: selection)
        }
        .background(SpaceBranchObserver(space: space))
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
        .contextMenu {
            Button("Rename…") { controller.rename(title: "Rename space", value: space.name) { workspace.renameSpace(space.id, to: $0) } }
            if space.structured {
                Button("Detach") { controller.closeSpace(space.id) }
                    .help("Remove from Dispatch; keep server work running")
                Button("Terminate…") { controller.terminateSpace(space.id) }
            } else {
                Button("Close") { controller.closeSpace(space.id) }
            }
        }
        .id(space.id)
        .modifier(HostMoveRow(motion: workspace.hostMoveMotion, id: space.id))
        .background(GeometryReader { proxy in
            Color.clear.preference(key: SpaceRowFrames.self, value: [space.id: proxy.frame(in: .named("space-list"))])
        })
    }

    private func overflowButton(hidden: [Space], below: [Space], attention: Set<UUID>, scroll: ScrollViewProxy) -> some View {
        let pending = hidden.filter { attention.contains($0.id) }
        let ready = readySpaceIDs
        let finished = hidden.filter { ready.contains($0.id) && !attention.contains($0.id) }
        return Button {
            if let target = pending.first ?? finished.first {
                workspace.selectSpace(target.id)
                scroll.scrollTo(target.id, anchor: .center)
            } else if let target = below.first ?? hidden.last {
                scroll.scrollTo(target.id, anchor: .top)
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
        .help("Reveal hidden spaces; jump to a hidden space awaiting approval, then one with a ready reply.")
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
            }.help("\(host.name) · \(workspace.hosts.state(host.id).label)")
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
        sidebar.rowContent(space, selected: selected, pending: pending, shortcut: shortcut, branch: branch, selection: selection)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.space == rhs.space && lhs.selected == rhs.selected && lhs.pending == rhs.pending
            && lhs.shortcut == rhs.shortcut && lhs.branch == rhs.branch && lhs.selection == rhs.selection
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
        if glass { content } else { content.chromePanel(Chrome.palette.isDark ? Chrome.terminal : Chrome.window, cornerRadius: 6) }
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
