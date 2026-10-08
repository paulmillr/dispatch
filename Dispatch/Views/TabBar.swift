import SwiftUI

/// Where a tab strip sits in the window; shared by the strip and a tmux pane's header so they line up.
struct TabBarPlacement {
    var titlebar: TitlebarPlacement?
    /// Full screen without a sidebar: this strip leads the window and makes room for the floating sidebar button.
    var sidebarSlot = false

    /// Where the strip's content starts: after the window controls, past the full-screen sidebar button, or at the
    /// strip inset. Only the strip leading the window makes that room; the strips below it keep the full width.
    @MainActor func leading(_ window: WindowState, sidebarVisible: Bool) -> CGFloat {
        if sidebarSlot { return 0 }
        if titlebar?.leading == true { return window.controlsInset }
        return Chrome.stripInset
    }
}

extension TabBarPlacement {
    /// With the sidebar hidden, the strip leading the window stands in its host mark for the sidebar toggle whenever
    /// it has one (remote tabs, or other spaces to switch to): the mark's picker shows the sidebar. Full screen asks
    /// whether that strip is a tab strip at all (a tmux pane header has no mark); the title row always is one.
    @MainActor static func markReplacesSidebarToggle(space: Space?, workspace: Workspace, sidebarVisible: Bool,
                                                     fullScreen: Bool) -> Bool {
        guard !sidebarVisible, let space else { return false }
        guard workspace.lastingSpaceCount > 1 || leadingStripHost(space) != nil else { return false }
        guard fullScreen else { return true }
        if space.structured { return WindowTabBar.showsTabs(space: space) }
        guard let pane = space.panes.first(where: { $0.id == space.layout.paneIDs.first }) else { return false }
        return PaneView.showsTabs(pane: pane, space: space)
    }

    /// The host the strip leading the window shows for its own tabs, as PaneView and WindowTabBar ask for it.
    @MainActor private static func leadingStripHost(_ space: Space) -> StripHost? {
        let ssh = TerminalRuntime.shared.ssh
        if space.structured {
            let first = space.windowPresentation?.layout.paneIDs.first
            let windows = space.windowPresentation?.groups.first { $0.id == first }
                .map { group in group.windows.compactMap { id in space.windows.first { $0.id == id } } } ?? space.windows
            return ssh.stripHost(active: space.activeTab, among: windows.flatMap(\.terminals))
        }
        guard let pane = space.panes.first(where: { $0.id == space.layout.paneIDs.first }) else { return nil }
        return ssh.stripHost(active: pane.activeTab, among: pane.tabs)
    }
}

extension StripTab.Style {
    /// Flat chrome is the ruled strip in a window and full screen alike; Liquid Glass has its own outlined pills.
    @MainActor static func current(_ window: WindowState) -> Self {
        LiquidGlassStore.shared.active ? .outlined : .strip
    }
}

extension StripTab {
    /// Windowed strips keep the title row's height on every row; only the full-screen strip is shorter. A split pane's
    /// glass capsule keeps a lone strip's margin above its track but none below, so the content starts right under it
    /// while the track stays level with the traffic lights and the other rows.
    @MainActor static func barHeight(titlebar: TitlebarPlacement?, style: Style, split: Bool = false,
                                     typography: AppTypography) -> CGFloat {
        let height = typography.expanded(titlebar != nil || style == .outlined ? 38 : 30)
        guard style == .outlined && split else { return height }
        return (height + glassTrackHeight(typography)) / 2
    }
}

/// The strip above a native pane or a tmux window group: the pane badge, the scrolling tabs, the new-tab button,
/// the chat switch and the layout picker. Callers supply each tab's row and what selecting and creating tabs means.
struct TabBar<Row: View>: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let ids: [UUID]
    let selected: UUID?
    let space: Space
    let workspace: Workspace
    let controller: AppDelegate
    let placement: TabBarPlacement
    /// The pane the shortcut badge focuses, and whether it is the focused one.
    let paneID: UUID
    let paneFocused: Bool
    /// The active terminal's chat session when it can switch to chat.
    let chatSession: ChatSession?
    /// Some tab in the strip can switch to chat, so the switch keeps its place on the others. Strips of plain
    /// terminals leave no gap for it.
    let reservesChatSwitch: Bool
    let showsLayoutPicker: Bool
    let hostTint: HostTint?
    /// Leads a lone strip's tabs (StripHostMark).
    var host: StripHost?
    /// Built only while the overflow control shows.
    let overflowItems: () -> [TabOverflowControl.Item]
    let select: (UUID) -> Void
    let newTab: () -> Void
    /// Laid over the tab list, behind the tabs' own overlays: e.g. a drop target appending to the strip.
    var listOverlay: AnyView?
    @ViewBuilder let row: (_ id: UUID, _ width: CGFloat, _ hovered: Bool) -> Row

    @State private var barWidth: CGFloat = 0
    @State private var stripWidth: CGFloat = 0
    /// The tabs' glass track, with the host mark's circle and gap before it.
    @State private var trackWidth: CGFloat = 0
    @State private var frames: [UUID: CGRect] = [:]
    @State private var scrollOffset: CGFloat = 0
    @State private var hovered: UUID?
    /// The space's panes (or window groups) each have a strip.
    private var split: Bool { space.numberedPaneIDs.count > 1 }
    private var glass: Bool { LiquidGlassStore.shared.active && style == .outlined }
    /// A split pane's glass strip is one capsule holding its badge, tabs and buttons (StripCapsule). A lone glass
    /// strip draws separate shapes: the tab track, the new-tab circle and a pill for the pane's buttons
    /// (StripActionsPill).
    private var capsule: Bool { glass && split }
    private var pill: Bool { glass && !split }
    /// Whether the lone strip's button pill has anything in it.
    private var hasPaneActions: Bool { chatSession != nil || reservesChatSwitch || showsLayoutPicker }

    private var style: StripTab.Style { .current(controller.windowState) }
    private var height: CGFloat { StripTab.barHeight(titlebar: placement.titlebar, style: style, split: split, typography: typography) }
    /// The tabs' row: the strip's height, or inside a split pane's capsule the capsule's.
    private var rowHeight: CGFloat { capsule ? StripTab.glassTrackHeight(typography) : height }
    /// Tabs take the host color with Liquid Glass; flat chrome keeps just the pane's top border.
    private var tabTint: HostTint? { RemoteTabHighlight.current == .fade ? hostTint : nil }
    private var edges: TabStripEdges {
        TabStripEdges(frames: frames, scroll: scrollOffset, viewport: tabViewport)
    }
    /// The host mark: a lone strip's, or in a split layout only the first pane's; the others show their host by tint
    /// alone. With other spaces to switch to, a local strip leads with the Mac's muted mark, in a window and full screen
    /// alike.
    private var mark: StripHost? {
        // The strip leading the window always carries it, so it can stand in for the sidebar toggle.
        guard !split || space.numberedPaneIDs.first == paneID || placement.sidebarSlot || placement.titlebar?.leading == true
        else { return nil }
        if let host { return host }
        guard workspace.lastingSpaceCount > 1 else { return nil }
        return StripHost(record: .local, tint: nil)
    }
    /// A window's title row with a lone strip of one tab: just the tab's title, like a window title, without the track.
    private var bareTitle: Bool { pill && placement.titlebar != nil && ids.count == 1 }
    /// The mark's circle and gap before the track, or none.
    private var markWidth: CGFloat { mark == nil ? 0 : StripHostMark.width(typography) }
    /// This strip leads the window with its host mark in place of the sidebar toggle (markReplacesSidebarToggle).
    private var replacesToggle: Bool {
        mark != nil && (placement.sidebarSlot || placement.titlebar?.leading == true)
            && TabBarPlacement.markReplacesSidebarToggle(space: space, workspace: workspace,
                                                         sidebarVisible: controller.sidebarVisible,
                                                         fullScreen: controller.windowState.isFullScreen)
    }
    /// The mark, and the sidebar toggle it stands in for, scale in and out. The animation rides on the transition, so
    /// it moves only them.
    private var markTransition: AnyTransition {
        (reduceMotion ? AnyTransition.opacity : .scale(scale: 0.4).combined(with: .opacity))
            .animation(InterfaceMotion.animation(reduce: reduceMotion))
    }
    /// The full-screen sidebar button's slot; just the strip inset once the mark replaces the button. Before the host mark it ends the mark's gap after the button's glass
    /// circle, so button, mark and track sit evenly apart.
    private var sidebarSlotWidth: CGFloat {
        if replacesToggle { return Chrome.stripInset }
        return mark == nil ? Chrome.sidebarSlotWidth
            : Chrome.sidebarButtonInset + (glass ? StripTab.glassTrackHeight(typography) : Chrome.sidebarButtonWidth)
                + StripHostMark.gap
    }
    /// The tabs' scroll viewport: the track less the mark's circle and gap. The mark's width applies in the same update that
    /// shows it, so the tabs never lay out for a frame at the width they had without it.
    private var tabViewport: CGFloat { max(0, trackWidth - markWidth) }
    /// Measured against the whole strip, not the viewport the overflow control narrows: tab widths follow the
    /// viewport, so showing the control could otherwise end the overflow that showed it, looping layout.
    private var overflowing: Bool {
        // Tabs shrink to fit the strip, so only their floor can overflow it.
        CGFloat(ids.count) * StripTab.minimumWidth(typography) > stripWidth - markWidth
    }

    var body: some View {
        HStack(spacing: 0) {
            if placement.sidebarSlot { Color.clear.frame(width: sidebarSlotWidth) }
            if placement.titlebar?.leading == true {
                if !replacesToggle {
                    TitleRowLeading(controller: controller, marked: markWidth > 0)
                        .transition(markTransition)
                }
            } else if barWidth >= 260, space.usesPaneShortcuts, !KeyGroupsStore.shared.current.tabs.isEmpty,
                      let number = space.paneShortcutNumber(for: paneID) {
                // The badge is the pane's tab-digit key; with tabs unbound there is none (the pane border marks focus).
                PaneShortcutBadge(number: number, focused: paneFocused,
                                  feedbackID: workspace.paneFocusFeedback?.paneID == paneID ? workspace.paneFocusFeedback?.id : nil,
                                  glass: capsule) {
                    workspace.selectPane(at: number - 1)
                }
                // Glass tabs outline from their edge, so the badge needs room before them.
                .padding(.trailing, style == .strip ? 0 : 2)
            }
            // Preserve the selected tab's close target in minimum-width panes.
            tabStrip.frame(minWidth: 48)
            // Tabs always fill the strip (or scroll), so the button simply follows it: no offset from measured
            // tab frames, which lag a resize or a tmux window update and slid the button over the tabs.
            // On a split pane's capsule the buttons sit on its glass. On a lone glass strip new tab acts on the strip, so
            // it is its own circle beside the track; chat and layout act on the pane and space and share a pill after
            // it. Flat strips keep plain buttons with their own gaps.
            Button(action: newTab) { NewTabLabel(style: style) }
                .help("New Tab · ⌘T").accessibilityLabel("Create new tab")
            HStack(spacing: glass ? 0 : 6) {
                if let chatSession {
                    ChatModeSwitch(session: chatSession, coordinator: TerminalRuntime.shared.chat).fixedSize()
                } else if reservesChatSwitch {
                    ChatModeSwitchSlot(dimmed: pill)
                }
                // The top-right strip only, so the picker keeps its place across spaces; one tab has no layout to choose.
                if showsLayoutPicker { LayoutPicker(space: space, workspace: workspace) }
            }
            // No pill when the strip has neither control: an empty one would draw a stray glass dot.
            .stripActionsPill(pill && hasPaneActions)
            .padding(.leading, glass ? 0 : 6)
        }
        // A split pane's capsule spans the strip inside its padding and sits at its bottom: a lone strip's margin
        // above it, none below.
        .stripCapsule(capsule, tint: tabTint)
        .padding(.leading, placement.leading(controller.windowState, sidebarVisible: controller.sidebarVisible))
        .padding(.trailing, Chrome.stripInset)
        // A split pane's capsule clips what it holds, so its mark's ripple and pulse are drawn over it instead.
        .overlayPreferenceValue(HostMarkEffectsAnchor.self) { effects in
            if let effects {
                GeometryReader { proxy in
                    let frame = proxy[effects.bounds]
                    HostMarkEffects(trigger: effects.trigger, color: effects.color, connecting: effects.connecting)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
                .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain).frame(height: height, alignment: .bottom)
        .foregroundStyle(tabTint?.tabControl ?? Chrome.ink)
        .glassBar(style)
        .hostTintStrip(hostTint, surface: LiquidGlassStore.shared.active ? .none : .solid)
        .background(GeometryReader { proxy in
            Color.clear.onAppear { barWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, value in barWidth = value }
        })
    }

    private var tabStrip: some View {
        ScrollViewReader { scroll in
            HStack(spacing: 0) {
                if ids.count > 1 && overflowing && barWidth >= 320 {
                    TabOverflowControl(items: overflowItems(), selected: selected, edges: edges, scroll: scroll, select: select)
                        .padding(.trailing, 6)
                }
                GeometryReader { available in
                    tabList(width: available.size.width, scroll: scroll)
                }
            }.background(GeometryReader { proxy in
                Color.clear.onAppear { stripWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, value in stripWidth = value }
            })
            .onAppear { scrollToSelected(scroll) }
            .onChange(of: selected) { _, _ in scrollToSelected(scroll) }
            .onChange(of: ids) { _, _ in scrollToSelected(scroll) }
        }
    }

    private func tabList(width: CGFloat, scroll: ScrollViewProxy) -> some View {
        let tabWidth = StripTab.width(count: ids.count, viewport: tabViewport, typography: typography)
        let list = ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(ids, id: \.self) { id in
                    row(id, tabWidth, hovered == id)
                        .tabStripEdge(id)
                        .onHover { inside in
                            if inside { hovered = id }
                            else if hovered == id { hovered = nil }
                        }
                }
                Spacer(minLength: 0)
            }.frame(minWidth: max(0, width - markWidth), minHeight: rowHeight, alignment: .leading)
                .tabStripContent()
        }
        .tabStripGeometry(frames: $frames, scroll: $scrollOffset)
        .onAppear { trackWidth = width }
        .onChange(of: width) { _, width in trackWidth = width; scrollToSelected(scroll) }
        .tabStripFade(edges)
        // The host mark is its own glass circle before the track; the viewport already left room for it.
        return HStack(spacing: 0) {
            if let mark {
                StripHostMark(host: mark, workspace: workspace, controller: controller)
                    .transition(markTransition)
            }
            list.tabStripGlass(pill, tint: tabTint, bare: bareTitle)
                // The tabs ease to their new width as the mark comes or goes. Keyed to that alone and scoped to the
                // tabs, so nothing else changing in the same update (a font size, the sidebar) animates with it.
                .animation(InterfaceMotion.animation(reduce: reduceMotion), value: mark != nil)
        }
        .frame(maxHeight: .infinity)
        .overlay { listOverlay }
    }

    private func scrollToSelected(_ scroll: ScrollViewProxy) {
        if let selected { scroll.scrollTo(selected) }
    }
}
