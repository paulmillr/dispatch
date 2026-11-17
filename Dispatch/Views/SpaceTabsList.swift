import SwiftUI

/// Vertical tabs' sidebar inside a space (Preferences.verticalTabs, mockups/Mac U1–U10): the space's heading, then its
/// tabs, a row each ("+ tab" is the bar's, SpaceTabsBar). A split lists its tabs under a heading per
/// pane, and a tmux or herdr space whose windows are split side by side its windows under a heading per group; a
/// window's panes are a line each. A row's close button shows under the pointer. Large (SidebarMetrics.cards) draws each
/// tab as a card. Rows are presentation only: they select, reorder and close what the strips did.
struct SpaceTabsList: View {
    let space: Space
    let workspace: Workspace
    let settings: SettingsStore
    let controller: AppDelegate
    let metrics: SidebarMetrics
    /// Other spaces waiting for approval or on a blocked program: Back's badge.
    let waiting: Int
    @Environment(\.appTypography) private var typography
    private var glass: Bool { LiquidGlassStore.shared.active }
    private var listInset: CGFloat { glass ? SpaceSidebar.glassInset + SpaceSidebar.glassRowInset : metrics.large ? 10 : 8 }

    var body: some View {
        let space = workspace.liveSpace(space)
        let tabs = workspace.sidebarTabs(in: space)
        ScrollViewReader { scroll in
            ScrollView {
                VStack(spacing: metrics.cards ? metrics.rowSpacing : 2) {
                    SpaceTabsHeading(space: space, workspace: workspace, controller: controller, metrics: metrics,
                                     waiting: waiting,
                                     pickerCenter: metrics.shortcutInset + SidebarGlassCircle<EmptyView>.side(typography) / 2)
                    if space.usesPaneShortcuts {
                        let panes = Self.panes(of: space, tabs: tabs)
                        ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                            paneHeading(pane, cells: panes.map(\.cell), index: index).padding(.top, index == 0 ? 0 : 6)
                            ForEach(pane.tabs) { row($0, in: space) }
                        }
                    } else {
                        ForEach(tabs) { row($0, in: space) }
                    }
                }
                .padding(.horizontal, listInset)
                .padding(.bottom, 8)
            }
            .onChange(of: workspace.selectedSidebarTab) { _, id in
                if let id { DispatchQueue.main.async { withAnimation { scroll.scrollTo(id) } } }
            }
            .onAppear { if let id = workspace.selectedSidebarTab { scroll.scrollTo(id) } }
        }
        .accessibilityIdentifier("sidebar-space-tabs")
    }

    @ViewBuilder private func row(_ tab: SidebarTab, in space: Space) -> some View {
        let selection = selection(tab, in: space)
        let shortcut = shortcut(tab, in: space)
        if metrics.cards {
            SpaceTabCard(tab: tab, space: space, workspace: workspace, settings: settings, controller: controller,
                         metrics: metrics, selected: selection == .focused, shortcut: shortcut)
                .id(tab.id)
        } else {
            SpaceTabRow(tab: tab, space: space, workspace: workspace, settings: settings, controller: controller,
                        metrics: metrics, selection: selection, shortcut: shortcut)
                .id(tab.id)
        }
    }

    private func selection(_ tab: SidebarTab, in space: Space) -> SpaceTabRow.Selection { Self.selection(tab, in: space) }
    private func shortcut(_ tab: SidebarTab, in space: Space) -> String {
        Self.shortcut(tab, in: space, keys: settings.values.keyGroups)
    }

    /// Shown in the focused pane (the window's own selection), shown in another pane, or not shown.
    static func selection(_ tab: SidebarTab, in space: Space) -> SpaceTabRow.Selection {
        if tab.window {
            if space.selectedContainer == tab.id { return .focused }
            return space.presentation?.groups.contains { $0.selected == tab.id } == true ? .shown : .none
        }
        guard let pane = space.panes.first(where: { $0.id == tab.pane }), pane.selected == tab.id else { return .none }
        return pane.id == space.focusedPane ? .focused : .shown
    }

    /// The tab's ⌘ digit as its strip advertised it: none while the digits focus panes (the pane headings show them).
    static func shortcut(_ tab: SidebarTab, in space: Space, keys: KeyGroups) -> String {
        guard let number = space.tabShortcutNumber(for: tab.id) else { return "" }
        return keys.shortcut(\.tabs, String(number)) ?? ""
    }

    /// A pane of a split, or a group of a server's windows split side by side: its frame in the unit square, whether
    /// it has focus, and the listed tabs (windows) it holds, in order.
    struct SplitPane: Identifiable {
        let id: UUID
        let cell: CGRect
        let focused: Bool
        let tabs: [SidebarTab]
    }

    /// The space's panes (window groups) in reading order, as the pane digits number them.
    static func panes(of space: Space, tabs: [SidebarTab]) -> [SplitPane] {
        let order = space.numberedPaneIDs
        if space.structured, let presentation = space.windowPresentation {
            let frames = presentation.layout.paneFrames(fractions: space.paneFractions)
            return order.compactMap { id in
                presentation.groups.first { $0.id == id }.map { group in
                    SplitPane(id: id, cell: frames.first { $0.id == id }?.frame ?? .zero,
                              focused: group.windows.contains { $0 == space.selectedContainer },
                              tabs: group.windows.compactMap { window in tabs.first { $0.id == window } })
                }
            }
        }
        let frames = space.layout.paneFrames(fractions: space.paneFractions)
        return order.map { id in
            SplitPane(id: id, cell: frames.first { $0.id == id }?.frame ?? .zero, focused: space.focusedPane == id,
                      tabs: tabs.filter { $0.pane == id })
        }
    }

    /// A pane's heading in a split, one step out from its tabs: the layout with this pane filled in the activity
    /// column (tabs only's pane glyph), its place ("Left", "Top right") where their glyphs start, and its ⌘ digit, in
    /// the accent while focused. A click focuses the pane.
    private func paneHeading(_ pane: SplitPane, cells: [CGRect], index: Int) -> some View {
        let key = settings.values.keyGroups.shortcut(\.tabs, String(index + 1)) ?? ""
        return Button { workspace.selectPane(at: index) } label: {
            HStack(spacing: 7) {
                SidebarPaneGlyph(cells: cells, cell: index, lit: pane.focused, size: metrics.detailSize + 1).frame(width: 14)
                Text(Self.place(cells[index], among: cells, index: index)).interfaceFont(size: metrics.detailSize, weight: .semibold)
                    .foregroundStyle(Chrome.palette.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if !key.isEmpty {
                    Text(key).font(.system(size: metrics.shortcutSize).monospacedDigit()).tracking(metrics.shortcutSize * 0.06)
                        .foregroundStyle(pane.focused ? Chrome.accent : Chrome.palette.secondary.opacity(metrics.shortcutOpacity))
                }
            }
            .padding(.leading, 6).padding(.trailing, metrics.shortcutInset)
            .frame(height: typography.expanded(25)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Focus this pane" + (key.isEmpty ? "" : " · \(key)"))
        .accessibilityIdentifier("sidebar-pane-\(index + 1)")
    }

    /// A pane's place among its split's `cells` (`place`), or "Pane 3" by its digit when another cell shares the name,
    /// as the two inner columns of four do: every heading then numbers, so none reads as a place and another as a count.
    static func place(_ frame: CGRect, among cells: [CGRect], index: Int) -> String {
        let names = cells.map(place)
        return Set(names).count == names.count ? place(frame) : "Pane \(index + 1)"
    }

    /// Where a pane sits in its space's frame: Left or Right, Top or Bottom, or both ("Top left").
    static func place(_ frame: CGRect) -> String {
        let column = frame.width > 0.99 ? nil : frame.minX < 0.01 ? "left" : frame.maxX > 0.99 ? "right" : "middle"
        let row = frame.height > 0.99 ? nil : frame.minY < 0.01 ? "top" : frame.maxY > 0.99 ? "bottom" : "middle"
        switch (row, column) {
        case let (row?, column?): return row.capitalized + " " + column
        case let (row?, nil): return row.capitalized
        case let (nil, column?): return column.capitalized
        case (nil, nil): return "Pane"
        }
    }
}

/// The bar inside a space, after the sidebar toggle: New Tab (⌘T) at the end, ending where the rows' shortcuts do
/// (`trailing`). Back and the layout picker lead and end the space's heading under it (SpaceTabsHeading), the picker
/// under New Tab; the space menu is the heading's name's.
struct SpaceTabsBar: View {
    let space: Space
    let workspace: Workspace
    let controller: AppDelegate
    /// Past the header row's own trailing inset, so New Tab ends in line with the rows' shortcuts.
    var trailing: CGFloat = 0

    var body: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 8)
            Button { workspace.newTab() } label: {
                SidebarGlassCircle { Image(systemName: "plus").font(SidebarGlassCircle<EmptyView>.glyph) }
            }
            .buttonStyle(.plain)
            .help("New Tab · ⌘T")
            .accessibilityLabel("New tab")
            .accessibilityIdentifier("sidebar-new-tab")
        }
        .padding(.leading, 4)
        .padding(.trailing, max(0, trailing))
    }
}

/// A control of vertical tabs' sidebar: a glass circle as tall as the strip's track; flat, the header buttons' square.
struct SidebarGlassCircle<Label: View>: View {
    @Environment(\.appTypography) private var typography
    @ViewBuilder let label: Label

    @MainActor static func side(_ typography: AppTypography) -> CGFloat {
        LiquidGlassStore.shared.active ? StripTab.glassTrackHeight(typography) : 24
    }
    /// One glyph weight for every circle (Back, New Tab), so none reads larger than another.
    static var glyph: Font { .system(size: 13, weight: .medium) }

    var body: some View {
        let side = Self.side(typography)
        if LiquidGlassStore.shared.active {
            label.foregroundStyle(Chrome.palette.secondary).frame(width: side, height: side)
                .liquidGlass(in: Circle(), interactive: true).glassHover(Circle()).contentShape(Circle())
        } else {
            label.foregroundStyle(Chrome.palette.secondary).frame(width: side, height: side)
                .background(Chrome.palette.sidebarAction, in: RoundedRectangle(cornerRadius: 4))
                .glassHover(RoundedRectangle(cornerRadius: 4)).contentShape(Rectangle())
        }
    }
}

/// The space menu, in the heading's name: renaming, then detaching and terminating a server's session (a native space
/// closes). Other spaces are Back's.
struct SpaceMenuItems: View {
    let space: Space
    let workspace: Workspace
    let controller: AppDelegate

    var body: some View {
        Button("Rename Space…") {
            controller.rename(title: "Rename space", value: workspace.liveName(space)) { workspace.renameSpace(space.id, to: $0) }
        }
        Divider()
        if space.structured {
            Button("Detach") { controller.closeSpace(space.id) }.help(MoveTargetsSection.detachHelp)
            Button("Terminate…") { controller.terminateSpace(space.id) }
        } else {
            Button("Close Space") { controller.closeSpace(space.id) }
        }
    }
}

/// The space at the head of its tabs: Back to the spaces (a glass circle, as iOS 26's, with the count of other spaces
/// that need you) centered in the space before the name; the name, larger than a tab's, where their titles start,
/// which opens the space menu (SpaceMenuItems); dimmed under it the host (remote) and the folder, or for a tmux or
/// herdr session its git branch (SpaceBranchObserver); and at the end, with two tabs or more, the layout picker,
/// centered under the bar's New Tab (the host's widget is the footer's). A rule sets it apart from the tabs.
struct SpaceTabsHeading: View {
    let space: Space
    let workspace: Workspace
    let controller: AppDelegate
    let metrics: SidebarMetrics
    let waiting: Int
    /// How far from the heading's trailing edge the layout picker centers (under the bar's New Tab).
    let pickerCenter: CGFloat
    @Environment(\.appTypography) private var typography
    @State private var branch: String?

    var body: some View {
        let host = workspace.hosts.record(space.hostID)
        // The name starts where the tab titles do: a row's leading inset, its activity column and kind glyph.
        // The bar's circles' size, which the layout picker sits under.
        let side = SidebarGlassCircle<EmptyView>.side(typography)
        let titleColumn = metrics.cards ? 9 + metrics.discSize + 11 : SpaceTabRow.titleInset
        let gap: CGFloat = metrics.cards ? 11 : 5
        HStack(spacing: gap) {
            // Back, centered in the free space before the name.
            Button { workspace.sidebarListsSpaces = true } label: {
                SidebarGlassCircle { Image(systemName: "chevron.left").font(SidebarGlassCircle<EmptyView>.glyph) }
                    .overlay(alignment: .topTrailing) {
                        if waiting > 0 {
                            Text("\(waiting)").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Chrome.window)
                                .frame(minWidth: 14, minHeight: 14).background(Chrome.palette.green, in: Capsule())
                                .offset(x: 4, y: -3)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(waiting > 0 ? "Back to spaces · \(waiting) need\(waiting == 1 ? "s" : "") you" : "Back to spaces")
            .accessibilityLabel("Back to spaces")
            .accessibilityValue(waiting > 0 ? "\(waiting) waiting" : "")
            .accessibilityIdentifier("sidebar-back")
            .frame(width: max(SidebarGlassCircle<EmptyView>.side(typography), titleColumn - gap))
            VStack(alignment: .leading, spacing: 1) {
                Menu { SpaceMenuItems(space: space, workspace: workspace, controller: controller) } label: {
                    HStack(spacing: 5) {
                        Text(workspace.liveName(space)).interfaceFont(size: metrics.nameSize + (metrics.cards ? 2.5 : 3.5), weight: .semibold)
                            .foregroundStyle(Chrome.ink).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Chrome.palette.detail)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Spaces · rename, detach, terminate")
                .accessibilityIdentifier("sidebar-space-name-menu")
                headingPlace(host)
            }
            Spacer(minLength: 0)
            // The layout picker, with two tabs or more (as a strip shows it), centered under the bar's New Tab.
            if space.layoutTabCount > 1 {
                LayoutPicker(space: space, workspace: workspace).buttonStyle(.plain)
                    .frame(minWidth: side)
                    .padding(.trailing, pickerCenter - side / 2)
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(Chrome.border).frame(height: 1).offset(y: 6) }
        .padding(.bottom, 12)
        // A session's branch, read as the sidebar reads a space's; Files › Git off reads none.
        .background {
            if space.structured { SpaceBranchObserver(space: space, enabled: controller.settings.values.gitEnabled) }
        }
        .onPreferenceChange(SpaceBranchNames.self) { names in branch = names[space.id] }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-space-heading")
    }

    /// Where the space is, as the phone says it (mockups/Mac U11 B): the host by its name in its colour (a remote one),
    /// then a session's git branch, else the folder's name; the full path in the help and for VoiceOver.
    @ViewBuilder private func headingPlace(_ host: HostRecord) -> some View {
        let folder = SpaceTabPlace.spaceDirectory(space, in: workspace)
        let named = space.structured && branch != nil ? branch : folder.flatMap { SpaceHoverDetails.folderName($0.path, home: $0.home) }
        // A space named for its folder would say its name twice: a remote one's line says its host alone, a local one's
        // goes; the path stays in the help.
        let shown = SpaceHoverDetails.distinct(named, from: workspace.liveName(space))
        if space.hostID != .local || shown != nil {
        SpaceTabPlaceText(host: space.hostID == .local ? nil : host, folder: shown, size: metrics.detailSize)
            .help(folder?.path ?? "")
            .accessibilityLabel([space.hostID == .local ? nil : host.name, branch.flatMap { space.structured ? $0 : nil } ?? folder?.path]
                .compactMap { $0 }.joined(separator: ", "))
            .accessibilityIdentifier("sidebar-space-place")
        }
    }
}

/// A tab's row inside a space (the compact and icons styles): its activity, its kind (the chat bubble for an agent, the
/// terminal for a shell), its title on one line or two, and its ⌘ digit; a window's panes a line each under its title.
/// As tall as a space's row on one line. A click shows the tab; it drags among the tabs (to another pane too) as its
/// strip tab did, and its menu renames, moves and closes it.
struct SpaceTabRow: View {
    enum Selection { case none, shown, focused }
    let tab: SidebarTab
    let space: Space
    let workspace: Workspace
    let settings: SettingsStore
    let controller: AppDelegate
    let metrics: SidebarMetrics
    let selection: Selection
    let shortcut: String
    @State private var hovered = false

    /// Where a row's title starts: its inset, the activity column and the kind's glyph, with their gaps.
    static let titleInset: CGFloat = 6 + 14 + 7 + 18 + 7

    var body: some View {
        let name = SpaceTabLabel.name(tab, in: workspace, settings: settings)
        let selected = selection == .focused
        let line = NSLayoutManager().defaultLineHeight(for: AppFont.native(size: metrics.nameSize))
        let host = workspace.hosts.record(tab.host)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 7) {
                // Under the pointer the close button takes the activity's place, as a strip tab's does.
                Group {
                    if hovered {
                        Button { close() } label: { CloseGlyph() }
                            .buttonStyle(.plain)
                            .help(tab.window ? "Close tab · asks first if something runs there" : "Close tab")
                            .accessibilityLabel("Close \(name)")
                    } else {
                        AgentActivityGlyph(tabIDs: tab.surfaceIDs, connecting: connecting, size: metrics.activitySize, showsQuiet: false)
                            .fixedSize()
                    }
                }
                .frame(width: 14, height: line)
                SpaceTabLabel.kind(tab, in: workspace).font(.system(size: metrics.nameSize - 1))
                    .foregroundStyle(Chrome.muted).frame(width: 18, height: line)
                // Semibold while selected, at its regular width (`AppFont.semiboldTracking`), as a strip tab's: the title
                // neither shifts nor wraps differently as the selection moves.
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(Font(AppFont.native(size: metrics.nameSize, semibold: selected)))
                        .tracking(selected ? AppFont.semiboldTracking(name, size: metrics.nameSize) : 0)
                        .lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                    // Only a tab that is not where its space is says where it is (mockups/Mac U11 B).
                    if let place = SpaceTabPlace.elsewhere(tab, in: space, workspace: workspace, title: name) {
                        SpaceTabPlaceText(host: place.host, folder: place.folder, size: metrics.detailSize)
                            .help(place.path ?? "")
                            .accessibilityIdentifier("sidebar-tab-place-\(tab.id)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !shortcut.isEmpty {
                    Text(shortcut).font(.system(size: metrics.shortcutSize).monospacedDigit()).tracking(metrics.shortcutSize * 0.06)
                        .foregroundStyle(Chrome.palette.secondary.opacity(metrics.shortcutOpacity)).frame(height: line)
                }
            }
            // The row's padding is inside the reorder view, so its hover and drop marks span the row; it leaves the close
            // button's corner to the button.
            .padding(.leading, 6).padding(.trailing, metrics.shortcutInset)
            .padding(.vertical, max(0, (metrics.rowHeight - line) / 2))
            .frame(minHeight: metrics.rowHeight)
            .contentShape(Rectangle())
            .overlay {
                LocalReorder(item: tab.window ? .window(tab.id) : .tab(tab.id), edge: .vertical,
                             leadingButtonWidth: hovered ? 6 + 14 + 3 : 0,
                             spaceHover: SpaceTabLabel.hover(tab, name: name, host: host, in: workspace, space: space),
                             hoverFontSize: metrics.nameSize, dragLabel: name, hovering: { hovered = $0 }, select: { select() },
                             accepts: accepts, drop: drop)
            }
            if tab.members.count > 1 {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(tab.members) { member in paneLine(member) }
                }
                .padding(.leading, Self.titleInset).padding(.trailing, metrics.shortcutInset)
                .padding(.bottom, max(0, (metrics.rowHeight - line) / 2))
            }
        }
        .foregroundStyle(selected ? Chrome.ink : Chrome.palette.secondary)
        .background {
            let shape = RoundedRectangle(cornerRadius: metrics.cornerRadius)
            shape.fill(selection == .focused ? Chrome.palette.selection
                       : selection == .shown || hovered ? Chrome.palette.hover : .clear)
        }
        .modifier(AttentionMotion(pending: SpaceSidebar.needsAttention(tab.surfaceIDs), cornerRadius: metrics.cornerRadius))
        .onHover { hovered = $0 }
        .contextMenu { SpaceTabMenu(tab: tab, space: space, workspace: workspace, controller: controller, name: name) }
        // A window's pane lines stay controls of their own.
        .accessibilityElement(children: tab.members.count > 1 ? .contain : .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        // The close button shows only under the pointer: VoiceOver and Full Keyboard Access close from here.
        .accessibilityAction(named: "Close") { close() }
        .accessibilityIdentifier("sidebar-tab-\(tab.id)")
    }

    private var connecting: Bool { tab.surfaceIDs.contains { workspace.hostMoveMotion.connecting.contains($0) } }

    private func select() {
        if tab.window { workspace.selectWindow(tab.id) } else { workspace.selectTab(tab.id) }
    }

    /// As the strip tab's close: a window asks first if something runs there.
    private func close() {
        if tab.window { controller.closeWindow(tab.id) } else { controller.closeTab(tab.id) }
    }

    /// A tab dropped beside a tab lands in its pane; a window beside a window moves there on the server.
    private func accepts(_ item: ReorderItem) -> Bool {
        switch item {
        case .tab(let id): return !tab.window && tab.pane.map { workspace.canMoveTab(id, to: $0) } == true
        case .window(let id): return tab.window && workspace.canMoveWindow(id, beside: tab.id)
        case .space, .host, .queued: return false
        }
    }

    private func drop(_ item: ReorderItem, after: Bool) {
        switch item {
        case .tab(let id): if let pane = tab.pane { workspace.moveTab(id, to: pane, relativeTo: tab.id, after: after) }
        case .window(let id): workspace.moveContainer(id, beside: tab.id, edge: nil, after: after)
        case .space, .host, .queued: break
        }
    }

    /// A window's pane: the window's layout with the pane filled, and its terminal's name; the focused pane's bright
    /// on the shown window. A click focuses the pane.
    private func paneLine(_ member: SidebarSplitMember) -> some View {
        let bright = selection == .focused && member.focused
        let name = SpaceTabLabel.name(ofTab: member.id, in: workspace, settings: settings)
        return Button { workspace.selectTab(member.id) } label: {
            HStack(spacing: 6) {
                SidebarPaneGlyph(cells: tab.cells, cell: member.cell, lit: bright, size: metrics.detailSize)
                Text(name).interfaceFont(size: metrics.detailSize).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(bright ? Chrome.ink : Chrome.palette.sidebarDetail)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-pane-line-\(member.id)")
    }
}

/// Large's tab: a card as a space's is (SidebarCardChrome), at a tab's measure. Its kind in a neutral orb (its status's
/// glyph there while it has news other than work), its title on up to two lines with its ⌘ keycap, then its status in a
/// word when there is one; as tall as a space's card, taller when the title wraps.
struct SpaceTabCard: View {
    let tab: SidebarTab
    let space: Space
    let workspace: Workspace
    let settings: SettingsStore
    let controller: AppDelegate
    let metrics: SidebarMetrics
    let selected: Bool
    let shortcut: String
    @State private var hovered = false

    var body: some View {
        let name = SpaceTabLabel.name(tab, in: workspace, settings: settings)
        let connecting = tab.surfaceIDs.contains { workspace.hostMoveMotion.connecting.contains($0) }
        let activity = AgentActivity(tabIDs: tab.surfaceIDs, connecting: connecting)
        // Unread, needs you, failed: the status takes the orb. Working keeps the kind's glyph and its pill's own.
        let statusInOrb = (activity.finished || activity.blocked || activity.failed) && !activity.working
        let host = workspace.hosts.record(tab.host)
        HStack(alignment: .center, spacing: 11) {
            SidebarCardOrb(hue: nil, selected: selected, size: metrics.discSize) {
                if hovered {
                    // Under the pointer the orb is the close button, as a strip tab's leading slot is.
                    Button {
                        if tab.window { controller.closeWindow(tab.id) } else { controller.closeTab(tab.id) }
                    } label: { Image(systemName: "xmark").font(.system(size: metrics.detailSize, weight: .semibold)) }
                        .buttonStyle(.plain)
                        .help(tab.window ? "Close tab · asks first if something runs there" : "Close tab")
                        .accessibilityLabel("Close \(name)")
                } else if statusInOrb {
                    AgentActivityGlyph(tabIDs: tab.surfaceIDs, connecting: connecting, size: metrics.activitySize).fixedSize()
                } else {
                    SpaceTabLabel.kind(tab, in: workspace).font(.system(size: metrics.nameSize - 1.5))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name).font(Font(AppFont.native(size: metrics.nameSize, semibold: selected)))
                        .tracking(selected ? AppFont.semiboldTracking(name, size: metrics.nameSize) : 0)
                        .foregroundStyle(selected ? Chrome.ink : Chrome.palette.secondary)
                        .lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SidebarKeycap(shortcut: shortcut, selected: selected, size: metrics.shortcutSize)
                }
                if activity.label != nil {
                    SidebarStatusPill(activity: activity, surfaceIDs: tab.surfaceIDs, connecting: connecting, metrics: metrics,
                                      label: activity.label, glyph: !statusInOrb)
                }
            }
        }
        .padding(.leading, 9).padding(.trailing, 11).padding(.vertical, 10)
        .frame(minHeight: metrics.rowHeight)
        .modifier(SidebarCardChrome(selected: selected, pending: SpaceSidebar.needsAttention(tab.surfaceIDs), host: host,
                                    metrics: metrics))
        .environment(\.pointerOver, hovered)
        .overlay {
            LocalReorder(item: tab.window ? .window(tab.id) : .tab(tab.id), edge: .vertical,
                         leadingButtonWidth: hovered ? 9 + metrics.discSize : 0,
                         spaceHover: SpaceTabLabel.hover(tab, name: name, host: host, in: workspace, space: space),
                         hoverFontSize: metrics.nameSize, dragLabel: name, hovering: { hovered = $0 }, select: {
                if tab.window { workspace.selectWindow(tab.id) } else { workspace.selectTab(tab.id) }
            }, accepts: { item in
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
        .onHover { hovered = $0 }
        .contextMenu { SpaceTabMenu(tab: tab, space: space, workspace: workspace, controller: controller, name: name) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Close") {
            if tab.window { controller.closeWindow(tab.id) } else { controller.closeTab(tab.id) }
        }
        .accessibilityIdentifier("sidebar-tab-\(tab.id)")
    }
}

/// A listed tab's actions, as its strip tab offers them: rename, the "Move to" submenu (another pane, a new space,
/// another space), close; a window detaches or terminates.
struct SpaceTabMenu: View {
    let tab: SidebarTab
    let space: Space
    let workspace: Workspace
    let controller: AppDelegate
    let name: String

    var body: some View {
        Button("Rename…") {
            controller.rename(title: "Rename tab", value: name) { value in
                if tab.window { workspace.renameWindow(tab.id, to: value) } else { workspace.updateTab(tab.id, customTitle: value) }
            }
        }
        if tab.window {
            MoveTargetsSection(newSpace: { workspace.moveWindowToNewSpace(tab.id) },
                               spaces: workspace.spaces.filter { target in
                target.id != space.id && target.windows.first.map { workspace.canMoveWindow(tab.id, beside: $0.id) } == true
            }.map { target in
                // The window goes beside the target space's last one.
                MoveTarget(id: target.id, title: workspace.liveName(target)) {
                    if let last = target.windows.last { workspace.moveWindow(tab.id, beside: last.id) }
                }
            })
            Divider()
            Button("Detach") { controller.detachWindow(tab.id) }.help(MoveTargetsSection.detachHelp)
            Button("Terminate…") { controller.terminateWindow(tab.id) }
            Button("Close Tab") { controller.closeWindow(tab.id) }.help(MoveTargetsSection.closeHelp)
        } else {
            MoveTargetsSection(
                panes: space.panes.filter { $0.id != tab.pane }.map { target in
                    MoveTarget(id: target.id, title: "Pane \(space.paneShortcutNumber(for: target.id) ?? 1)") { workspace.moveTab(tab.id, to: target.id) }
                },
                newSpace: { workspace.moveTabToNewSpace(tab.id) },
                spaces: workspace.spaces.filter { $0.id != space.id && workspace.canMoveTab(tab.id, to: $0.focusedPane) }.map { target in
                    MoveTarget(id: target.id, title: workspace.liveName(target)) { workspace.moveTab(tab.id, to: target.focusedPane) }
                })
            Divider()
            Button("Close Tab") { controller.closeTab(tab.id) }
        }
    }
}

/// Names, glyphs and hover cards of listed tabs, live (`Workspace.liveTab`) so a title change re-renders the row.
@MainActor enum SpaceTabLabel {
    static func name(_ tab: SidebarTab, in workspace: Workspace, settings: SettingsStore) -> String {
        guard tab.window else { return name(ofTab: tab.id, in: workspace, settings: settings) }
        guard let window = workspace.spaces.lazy.flatMap(\.containers).first(where: { $0.id == tab.id }) else { return "Terminal" }
        return TerminalRuntime.shared.label(for: window, automatic: settings.values.automaticTabNames)
    }

    static func name(ofTab id: UUID, in workspace: Workspace, settings: SettingsStore) -> String {
        guard let live = workspace.liveTab(id) else { return "Terminal" }
        return TerminalRuntime.shared.label(for: live, automatic: settings.values.automaticTabNames)
    }

    /// The chat bubble while an agent leads the tab's terminal (its mode switch opens chat), else the terminal.
    static func kind(_ tab: SidebarTab, in workspace: Workspace) -> Image {
        let chat = TerminalRuntime.shared.chat
        let agent = tab.surfaceIDs.contains { chat.sessions[$0].map { chat.chatLeads($0) } == true }
        return Image(systemName: agent ? "text.bubble" : "terminal")
    }

    static func hover(_ tab: SidebarTab, name: String, host: HostRecord, in workspace: Workspace, space: Space) -> SpaceHoverDetails? {
        let terminal: TerminalTab? = tab.window
            ? space.containers.first { $0.id == tab.id }?.focusedTerminal.map { workspace.liveTab($0.id) ?? $0 }
            : workspace.liveTab(tab.id)
        return terminal.map { SpaceHoverDetails.make(tab: $0, host: host, runtime: .shared, title: tab.window ? name : nil) }
    }
}

/// Where a tab is against its space, for vertical tabs (mockups/Mac U11 B): the space's folder is where most of its tabs
/// are, and only a tab elsewhere (another folder, or another host for a plain SSH tab) gets a line saying where.
enum SpaceTabPlace {
    /// The terminal whose folder a row stands for: a window's focused pane, else the tab.
    @MainActor static func terminal(_ tab: SidebarTab, in space: Space) -> UUID {
        guard tab.window, let terminal = space.containers.first(where: { $0.id == tab.id })?.focusedTerminal else { return tab.id }
        return terminal.id
    }

    /// The folder most of the space's tabs are in (the first such tab's on a tie), with its host's home.
    @MainActor static func spaceDirectory(_ space: Space, in workspace: Workspace) -> (path: String, home: String?)? {
        let runtime = TerminalRuntime.shared
        let folders = space.tabs.compactMap { SpaceHoverDetails.liveDirectory($0.id, runtime: runtime) }
        guard let first = folders.first else { return nil }
        let counts = Dictionary(folders.map { ($0.path, 1) }, uniquingKeysWith: +)
        return folders.first { counts[$0.path] == counts.values.max() } ?? first
    }

    struct Line: Equatable {
        /// Another host than the space's (a plain SSH tab's), named in its colour.
        var host: HostRecord?
        var folder: String?
        var path: String?
    }

    /// A row's line: nil where the tab is where its space is, or where its title already names its folder (an automatic
    /// tab name).
    @MainActor static func elsewhere(_ tab: SidebarTab, in space: Space, workspace: Workspace, title: String? = nil) -> Line? {
        let own = SpaceHoverDetails.liveDirectory(terminal(tab, in: space), runtime: .shared)
        let host = tab.host != space.hostID ? workspace.hosts.record(tab.host) : nil
        return line(own: own, space: spaceDirectory(space, in: workspace), otherHost: host, title: title)
    }

    static func line(own: (path: String, home: String?)?, space: (path: String, home: String?)?, otherHost: HostRecord?,
                     title: String? = nil) -> Line? {
        let folder = own.flatMap { own in own.path == space?.path ? nil : SpaceHoverDetails.folderName(own.path, home: own.home) }
            .flatMap { SpaceHoverDetails.distinct($0, from: title) }
        guard otherHost != nil || folder != nil else { return nil }
        return Line(host: otherHost, folder: folder, path: folder == nil ? nil : own?.path)
    }
}

/// "build-box · billing": a host's name in its colour (none: the folder alone), then the folder's name, dimmed.
struct SpaceTabPlaceText: View {
    let host: HostRecord?
    let folder: String?
    let size: CGFloat

    var body: some View {
        let dim = Chrome.palette.sidebarDetail
        let name = host.map { Text($0.name).foregroundColor($0.tint?.foreground ?? Chrome.palette.secondary) } ?? Text("")
        let separator = host != nil && folder != nil ? Text(" · ").foregroundColor(dim) : Text("")
        (name + separator + Text(folder ?? "").foregroundColor(dim))
            .interfaceFont(size: size).lineLimit(1).truncationMode(.middle)
    }
}
