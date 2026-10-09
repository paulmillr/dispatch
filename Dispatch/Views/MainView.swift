import SwiftUI
import AppKit

struct MainView: View {
    private var typography: AppTypography { AppTypography(contentSize: settings.values.fontSize) }
    @Bindable var workspace: Workspace
    @Bindable var settings: SettingsStore
    let controller: AppDelegate

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The sidebar's visible width, the same for the split column and the floating glass panel, so switching between
    /// them keeps it; dragging either one's trailing edge resizes it.
    @State private var sidebarWidth: CGFloat = 264
    /// The full-screen edge reveal is showing its host mark, or the mark's picker is open.
    @State private var revealShown = false
    @State private var revealPicker = false
    private var sidebarVisible: Bool { controller.sidebarVisible }
    /// With Liquid Glass and the Liquid sidebar, the sidebar floats over the content instead of taking a split column.
    private var glassSidebar: Bool { LiquidGlassStore.shared.floatingSidebar }
    /// The floating sidebar's footprint: its panel, with the glass inset on either side.
    private var glassSidebarWidth: CGFloat { sidebarWidth + 2 * SpaceSidebar.glassInset }
    private var showTmuxTabs: Bool {
        guard let space = workspace.current, space.structured else { return false }
        return (space.windowPresentation?.groups.count ?? 1) <= 1 && (titlebarTabs || WindowTabBar.showsTabs(space: space))
    }

    /// Outside full screen, the strips along the top edge are the title row, as pills.
    private var titlebarTabs: Bool {
        !controller.windowState.isFullScreen && TerminalRuntime.shared.error == nil && workspace.current != nil
    }

    /// The title-row placement for a pane or tmux group, if its strip touches the top edge. With the
    /// sidebar hidden, the top-left strip leads with the window controls and the top-right one ends with its actions.
    private func titlebar(for id: UUID, in layout: PaneLayout) -> TitlebarPlacement? {
        guard titlebarTabs, layout.topPaneIDs.contains(id) else { return nil }
        return TitlebarPlacement(leading: !sidebarVisible && id == layout.paneIDs.first)
    }

    /// The window header row exists only when no tab strip carries the window controls:
    /// a visible sidebar does, and so does the title row.
    private var showsHeader: Bool {
        !controller.windowState.isFullScreen && !sidebarVisible && !titlebarTabs
    }

    private var hasLeadingTabRow: Bool {
        guard let space = workspace.current,
              let pane = space.panes.first(where: { $0.id == space.layout.paneIDs.first }) else { return false }
        if space.structured { return showTmuxTabs || space.panes.count > 1 }
        return PaneView.showsTabs(pane: pane, space: space)
    }

    /// In full screen without a tab row, the edge reveal shows the host mark in place of the sidebar button, whenever a
    /// strip would lead with one: the active tab's host, or the Mac with other spaces to switch to. Its picker carries
    /// the sidebar toggle.
    private var revealHost: StripHost? {
        guard controller.windowState.isFullScreen, !sidebarVisible, !hasLeadingTabRow, let space = workspace.current else { return nil }
        if let host = TerminalRuntime.shared.ssh.stripHost(active: space.activeTab, among: space.tabs) { return host }
        return workspace.lastingSpaceCount > 1 ? StripHost(record: .local, tint: nil) : nil
    }

    private var leadingRowHeight: CGFloat {
        // Glass strips are 38 points in full screen too, and a split pane's shorter strip keeps its capsule level with a
        // lone strip's track, so the sidebar header and button follow 38 points in every layout and backend.
        if glassStrips { return typography.expanded(38) }
        guard let space = workspace.current, space.structured else { return typography.expanded(30) }
        if showTmuxTabs || (space.windowPresentation?.groups.count ?? 1) > 1 { return tmuxStripHeight }
        return typography.expanded(hasLeadingTabRow ? 26 : 30)
    }

    // Native traffic-light spacing varies by macOS; keep the mockup gap.
    private var sidebarToggleLeadingSpace: CGFloat {
        // Less the header padding and HStack gap.
        max(0, controller.windowState.controlsInset - 14 - 12)
    }

    var body: some View {
        workspaceContent
            .environment(\.remoteTabHighlight, .current)
            .onChange(of: settings.values.appTheme, initial: true) { _, _ in
                SidebarThemeStore.shared.current = settings.values.resolvedSidebarTheme
                controller.applySidebarTheme(settings.values.resolvedSidebarTheme)
            }
            .onChange(of: SidebarThemeStore.shared.current) { _, theme in
                controller.applySidebarTheme(theme)
            }

    }

    private var workspaceContent: some View {
        VStack(spacing: 0) {
            if showsHeader {
                titleBar
                Rectangle().fill(Chrome.border).frame(height: 1)
            }
            // The content keeps one identity in both modes: with glass, its column only gains a leading safe area
            // under the floating sidebar, so toggling glass never remounts terminals or chats.
            NativeSplit(first: glassSidebar ? AnyView(Color.clear) : AnyView(spaceSidebar.accessibilityHidden(!sidebarVisible)),
                        second: AnyView(content.modifier(SidebarExtension(leading: glassSidebar && sidebarVisible ? glassSidebarWidth : 0))),
                        axis: .columns, sidebar: true, firstHidden: !sidebarVisible || glassSidebar, sidebarWidth: $sidebarWidth,
                        firstMinimumSize: CGSize(width: typography.expanded(200), height: 120),
                        secondMinimumSize: minimumTerminalSize)
                .overlay(alignment: .leading) {
                    if glassSidebar && sidebarVisible {
                        spaceSidebar.frame(width: glassSidebarWidth)
                            .overlay(alignment: .trailing) { SidebarResizeHandle(width: $sidebarWidth, minimum: typography.expanded(200)) }
                            // Behind the glass, never over it: the content's top-left host edge (and wash) runs on
                            // under the panel, so it reads as one window-wide edge through the glass and its gap.
                            .background(alignment: .topLeading) {
                                // The gaps around the split panels show the terminal color scheme's background.
                                ChatThemeStore.shared.current.terminal
                                if let edge = leadingHostEdge {
                                    Color.clear.hostTintBorder(edge.tint, surfaceID: edge.surfaceID, stripHeight: edge.stripHeight)
                                }
                            }
                            .transition(.move(edge: .leading))
                    }
                }
                .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: InterfaceMotion.sidebarDuration), value: sidebarVisible)
        }
        .font(typography.font(offset: -0.5, design: .monospaced))
        .environment(\.appTypography, typography)
        .foregroundStyle(Chrome.ink)
        .background(Chrome.window)
        .preferredColorScheme(Chrome.colorScheme)
        .ignoresSafeArea()
        .overlay { HostMoveCanvas(motion: workspace.hostMoveMotion).allowsHitTesting(false) }
        .overlay(alignment: .leading) {
            if controller.windowState.isFullScreen {
                let host = revealHost
                FullScreenSidebarReveal(theme: SidebarThemeStore.shared.current, sidebarVisible: sidebarVisible,
                                        suppressed: TabBarPlacement.markReplacesSidebarToggle(
                                            space: workspace.current, workspace: workspace, sidebarVisible: sidebarVisible,
                                            fullScreen: true),
                                        hosted: host != nil,
                                        pinned: sidebarVisible || hasLeadingTabRow, rowHeight: leadingRowHeight,
                                        buttonSize: StripHostMark.size(typography).height,
                                        revealed: { revealShown = $0 }) { controller.toggleSidebar() }
                    .frame(width: 48).frame(maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        // The reveal tracks the pointer; the mark shows where its button would.
                        if let host, revealShown || revealPicker {
                            StripHostMark(host: host, workspace: workspace, controller: controller,
                                          presentedChanged: { revealPicker = $0 })
                                .offset(x: Chrome.sidebarButtonInset,
                                        y: (leadingRowHeight - StripHostMark.size(typography).height) / 2)
                                .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                        }
                    }
                    .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.15), value: revealShown || revealPicker)
            }
        }
        .onChange(of: workspace.focusRequest) { _, _ in
            DispatchQueue.main.async { TerminalRuntime.shared.focusActive() }
        }
        .background(WindowTitleSync(workspace: workspace, settings: settings, controller: controller))
        .onChange(of: StripTab.titleRowHeight(typography), initial: true) { _, height in
            (controller.window as? MainWindow)?.titleBarHeight = height
        }
        .onChange(of: settings.values.hideSingleSpace) { _, _ in controller.windowState.sidebarVisibilityOverride = nil }
        .onChange(of: minimumContentSize, initial: true) { _, size in controller.updateMinimumContentSize(size) }
        .onChange(of: controlsShift, initial: true) { _, shift in
            controller.windowState.controlsShift = shift
            (controller.window as? MainWindow)?.controlsShift = shift
        }
    }

    /// The host color along the top of the content's top-left: the tmux space's, or the top-left native pane's.
    private var leadingHostEdge: (tint: HostTint, surfaceID: UUID?, stripHeight: CGFloat)? {
        guard let space = workspace.current else { return nil }
        let ssh = TerminalRuntime.shared.ssh
        let style = StripTab.Style.current(controller.windowState)
        if space.structured {
            guard let tab = space.activeTab, let tint = ssh.tint(for: tab) else { return nil }
            return (tint, tab.focusedSurfaceID, showTmuxTabs || groupedTmux(space) ? tmuxStripHeight : 0)
        }
        guard let pane = space.panes.first(where: { $0.id == space.layout.paneIDs.first }),
              let tab = pane.activeTab, let tint = ssh.tint(for: tab) else { return nil }
        let strip = PaneView.showsTabs(pane: pane, space: space) || titlebarTabs
        return (tint, tab.focusedSurfaceID,
                strip ? StripTab.barHeight(titlebar: titlebarTabs ? TitlebarPlacement() : nil, style: style,
                                           split: space.numberedPaneIDs.count > 1, typography: typography) : 0)
    }

    private var spaceSidebar: SpaceSidebar {
        SpaceSidebar(workspace: workspace, settings: settings, controller: controller, headerRowHeight: leadingRowHeight,
                     windowControls: !controller.windowState.isFullScreen)
    }

    private var minimumContentSize: CGSize {
        let panes = minimumTerminalSize
        return CGSize(width: max(620, (sidebarVisible ? max(420, panes.width) + typography.expanded(200) + 1 : panes.width)),
                      height: max(400, panes.height + (showsHeader ? StripTab.titleRowHeight(typography) + 1 : 0)))
    }

    /// The glass sidebar panel is inset from the window edge; the traffic lights move in with it so they sit inside
    /// the panel's corner rather than against its edge.
    private var controlsShift: CGFloat {
        glassSidebar && sidebarVisible && !controller.windowState.isFullScreen ? SpaceSidebar.glassInset : 0
    }

    /// With Liquid Glass, tmux strips lie over the panes instead of taking their own row, in full screen too.
    private var glassStrips: Bool { LiquidGlassStore.shared.active }

    private func groupedTmux(_ space: Space) -> Bool { (space.windowPresentation?.groups.count ?? 1) > 1 }
    private func tmuxTint(_ space: Space) -> HostTint? { space.activeTab.flatMap { TerminalRuntime.shared.ssh.tint(for: $0) } }

    /// Matches `WindowTabBar`'s frame, so tmux and native rows line up.
    private var tmuxStripHeight: CGFloat {
        StripTab.barHeight(titlebar: titlebarTabs ? TitlebarPlacement() : nil, style: glassStrips ? .outlined : .strip,
                           split: (workspace.current?.numberedPaneIDs.count ?? 1) > 1, typography: typography)
    }

    private var minimumTerminalSize: CGSize {
        let panes = workspace.current?.layout.minimumSize ?? PaneLayout.minimumPaneSize
        return CGSize(width: panes.width, height: panes.height + (showTmuxTabs ? tmuxStripHeight : 0))
    }

    private var titleBar: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: sidebarToggleLeadingSpace)
            SidebarToggle(controller: controller)
            Spacer(minLength: 0)
            MainTitleText(workspace: workspace, settings: settings, offline: activeHostOffline).font(typography.font(offset: 0.5)).lineLimit(1).truncationMode(.middle)
                .id(workspace.selectedSpace)
                .transition(reduceMotion ? .identity : .asymmetric(insertion: .offset(y: 8).combined(with: .opacity), removal: .offset(y: -8).combined(with: .opacity)))
                .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: InterfaceMotion.spaceSwitchDuration), value: workspace.selectedSpace)
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: InterfaceMotion.spaceSwitchDuration), value: workspace.selectedSpace)
        .padding(.horizontal, 14).frame(height: StripTab.titleRowHeight(typography))
        .background(Chrome.window)
        .accessibilityIdentifier("main-title-bar")
    }

    private var activeHostOffline: Bool {
        workspace.activeSurfaceID.map { TerminalRuntime.shared.hosts.reconnect.state(for: $0) != nil } ?? false
    }

    private var content: some View {
        Group {
            if let error = TerminalRuntime.shared.error {
                ContentUnavailableView("Terminal unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let space = workspace.current {
                GlassStripStack(overlaid: showTmuxTabs && glassStrips) {
                    if showTmuxTabs {
                        WindowTabBar(space: space, workspace: workspace, controller: controller,
                                   titlebar: titlebarTabs ? TitlebarPlacement(leading: !sidebarVisible) : nil)
                    }
                } content: {
                    MotionContent(content: layout(space.layout, space: space, stripInset: showTmuxTabs && glassStrips ? tmuxStripHeight : 0),
                                  identity: "\(space.id):\(space.layout)",
                                  spaceID: space.id, layout: space.layout, hostID: space.hostID, selectedTabID: space.activeWindow?.id)
                }
                // Split tmux windows give each group its own strip; with glass each washes below its own.
                .hostTintBorder(!space.structured || (groupedTmux(space) && glassStrips) ? nil : tmuxTint(space),
                                surfaceID: space.activeTab?.focusedSurfaceID,
                                stripHeight: showTmuxTabs ? tmuxStripHeight : 0)
                .modifier(PaneFocusHighlight(workspace: workspace,
                    paneID: space.structured && space.numberedPaneIDs.count == 1 ? space.numberedPaneIDs.first : nil))
            } else {
                VStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().interpolation(.high).frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    Text("A space to work.").font(typography.font(offset: 4.5))
                    HStack(spacing: 12) {
                        Button { workspace.newNativeSpace() } label: {
                            HStack { Text("New Space"); Text("⌘N").font(typography.shortcut()) }
                        }.keyboardShortcut("n")
                        Button { workspace.newTab() } label: {
                            HStack { Text("New Tab"); Text("⌘T").font(typography.shortcut()) }
                        }.keyboardShortcut("t")
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Chrome.palette.isDark ? Chrome.terminal : Chrome.window)
        .overlay(alignment: .bottom) {
            // Over the panes' bottom edge, so the title row keeps the top edge.
            if let helper = workspace.helpers.values.first(where: { $0.error != nil }), let error = helper.error {
                HelperErrorBar(error: error) { helper.dismissError() }
            }
        }
        .overlay(alignment: .top) {
            // With the sidebar hidden, ⌘/ has no chip to open from; the tab bar is hidden for single tabs too.
            Color.clear.frame(width: 1, height: 1)
                .popover(isPresented: Binding(get: { controller.windowState.shortcutsPresented && !sidebarVisible },
                                              set: { controller.windowState.shortcutsPresented = $0 }),
                         arrowEdge: .top) { WorkspaceShortcutSheet() }
        }
        .font(typography.font(offset: -0.5, design: .monospaced))
        .foregroundStyle(Chrome.ink)
        .preferredColorScheme(Chrome.colorScheme)
    }

    /// `stripInset`: the height of a glass strip laid over this node's top edge, for the panes along it.
    private func layout(_ node: PaneLayout, space: Space, groupHeaders: Bool = true, stripInset: CGFloat = 0) -> AnyView {
        if groupHeaders, let presentation = space.windowPresentation, presentation.groups.count > 1,
           let group = presentation.groups.first(where: { group in
               space.windows.first(where: { $0.id == group.selected })?.arrangement.layout == node
           }) {
            return AnyView(GlassStripStack(overlaid: glassStrips) {
                WindowTabBar(space: space, workspace: workspace, controller: controller, group: group,
                           titlebar: titlebar(for: group.id, in: presentation.layout))
            } content: {
                layout(node, space: space, groupHeaders: false, stripInset: glassStrips ? tmuxStripHeight : 0)
            }.hostTintBorder(glassStrips ? tmuxTint(space) : nil, surfaceID: group.selected, stripHeight: tmuxStripHeight)
                .id(group.id)
                .modifier(PaneFocusHighlight(workspace: workspace, paneID: group.selected == space.activeWindow?.id ? group.id : nil)))
        }
        switch node {
        case .pane(let id):
            guard let pane = space.panes.first(where: { $0.id == id }) else { return AnyView(EmptyView()) }
            return AnyView(PaneView(pane: pane, space: space, workspace: workspace, settings: settings, controller: controller,
                                    // tmux panes sit under their window strip, which is always shown in the title row.
                                    titlebar: !space.structured ? titlebar(for: id, in: space.layout) : titlebarTabs ? TitlebarPlacement() : nil,
                                    stripInset: stripInset).id(id))
        case .split(let id, let axis, let first, let second):
            let serverWindow = space.containers.contains { $0.arrangement.layout.splitIDs.contains(id) }
            // Side by side, both children share the top edge; stacked, only the first does.
            return AnyView(NativeSplit(first: layout(first, space: space, groupHeaders: groupHeaders, stripInset: stripInset),
                                      second: layout(second, space: space, groupHeaders: groupHeaders, stripInset: axis == .columns ? stripInset : 0),
                                      axis: axis, initialFraction: space.splitRatios[id].map { CGFloat($0) } ?? space.splitFractions[id] ?? 0.5,
                                      controlledFraction: space.splitFractions[id], onDividerChange: { fraction in
                                          if serverWindow { workspace.resizeDivider(id, in: space.id, fraction: fraction) }
                                      },
                                      firstMinimumSize: first.minimumSize, secondMinimumSize: second.minimumSize,
                                      fractionChanged: serverWindow ? nil : { workspace.resizeDivider(id, in: space.id, fraction: $0) }).id(id))
        }
    }
}

/// A helper's error over the panes' bottom edge: a full-width bar, or on Liquid Glass a glass panel floating in from
/// the edges like the find bar, its Dismiss on the panel's glass with the strip buttons' hover capsule.
private struct HelperErrorBar: View {
    @Environment(\.appTypography) private var typography
    let error: String
    let dismiss: () -> Void

    var body: some View {
        if LiquidGlassStore.shared.active {
            HStack {
                message
                Spacer()
                Button(action: dismiss) {
                    Text("Dismiss").padding(.horizontal, 10).padding(.vertical, 4)
                        .modifier(StripActionHover()).contentShape(Capsule())
                }.buttonStyle(.plain)
            }
            .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(8)
        } else {
            HStack {
                message
                Spacer()
                Button("Dismiss", action: dismiss)
            }.padding(8).background(Chrome.sidebar)
        }
    }

    private var message: some View { Text(error).font(typography.font(offset: -1.5)).textSelection(.enabled) }
}

/// A tab strip in the title row. `leading` carries the traffic-light inset, sidebar toggle, and space
/// name; a visible sidebar carries them instead.
struct TitlebarPlacement: Equatable {
    var leading = false
}

/// The sidebar toggle that leads the title row.
struct TitleRowLeading: View {
    let controller: AppDelegate
    /// The strip's host mark follows the toggle.
    var marked = false

    var body: some View {
        // Before the host mark, the mark's own gap, so toggle, mark and track sit evenly apart.
        SidebarToggle(controller: controller).padding(.trailing, marked ? StripHostMark.gap : 14)
    }
}

struct SidebarToggle: View {
    let controller: AppDelegate

    var body: some View {
        let visible = controller.sidebarVisible
        Button { controller.toggleSidebar() } label: {
            if LiquidGlassStore.shared.active && visible {
                // Inside the glass panel: one of the header's matching controls.
                Image(systemName: "sidebar.left").modifier(GlassPanelControl())
            } else {
                Image(systemName: "sidebar.left").font(.system(size: 14))
                    .frame(width: 22, height: 20)
                    .modifier(SidebarToggleGlass())
                    .foregroundStyle(visible ? Chrome.ink : Chrome.muted)
            }
        }
        .buttonStyle(.plain)
        .help("Toggle sidebar · ⌘\\")
        .accessibilityLabel(visible ? "Hide sidebar" : "Show sidebar")
        .accessibilityIdentifier("sidebar-toggle")
    }
}

/// With Liquid Glass, outside the sidebar the toggle is a glass circle like the strips' buttons; on a split pane's glass
/// capsule it is a circle on the capsule. (Inside the glass sidebar panel it is a GlassPanelControl, so there is no glass on
/// glass.)
private struct SidebarToggleGlass: ViewModifier {
    @Environment(\.appTypography) private var typography
    @Environment(\.stripActionsMerged) private var onCapsule

    func body(content: Content) -> some View {
        if LiquidGlassStore.shared.active {
            let size = StripTab.glassTrackHeight(typography)
            if onCapsule {
                content.frame(minWidth: size, minHeight: size).modifier(StripActionHover()).contentShape(Capsule())
            } else {
                content.frame(minWidth: size, minHeight: size).liquidGlass(in: Capsule(), interactive: true).contentShape(Capsule())
            }
        } else {
            content.contentShape(Rectangle())
        }
    }
}

/// Tracking-only edge region: terminal input passes through everywhere except
/// the revealed button. Revealing it never changes the split or terminal size.
private struct FullScreenSidebarReveal: NSViewRepresentable {
    let theme: SidebarTheme
    let sidebarVisible: Bool
    /// The leading strip's host mark stands in for the button (TabBarPlacement.markReplacesSidebarToggle).
    let suppressed: Bool
    /// A host mark laid over the button shows instead of it; the view still tracks the pointer and reports `revealed`.
    let hosted: Bool
    let pinned: Bool
    let rowHeight: CGFloat
    /// The button's circle: the host mark's size (StripHostMark.size).
    let buttonSize: CGFloat
    var revealed: (Bool) -> Void = { _ in }
    let toggle: () -> Void
    func makeNSView(context: Context) -> FullScreenSidebarRevealView { FullScreenSidebarRevealView() }
    func updateNSView(_ view: FullScreenSidebarRevealView, context: Context) {
        view.toggle = toggle
        let palette = SidebarPalette(theme: theme)
        view.button.contentTintColor = NSColor(palette.ink)
        // Match LayoutPicker over a header; floating over terminal content needs a fill, or glass with Liquid Glass.
        // Inside the glass sidebar panel it is a plain icon like the header's others: no glass on glass, no box.
        let liquid = LiquidGlassStore.shared.active
        view.size = buttonSize
        view.glass = liquid && !sidebarVisible
        view.button.layer?.backgroundColor = (pinned || view.glass ? NSColor.clear : NSColor(palette.window).withAlphaComponent(0.95)).cgColor
        view.button.layer?.borderColor = (liquid ? NSColor.clear : NSColor(palette.border)).cgColor
        view.button.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        view.revealed = revealed
        view.hosted = hosted
        view.suppressed = suppressed
        view.pinned = pinned
        view.rowHeight = rowHeight
        view.button.toolTip = "Toggle sidebar · ⌘\\"
        view.button.setAccessibilityLabel(sidebarVisible ? "Hide sidebar" : "Show sidebar")
    }
}

final class FullScreenSidebarRevealView: NSView {
    let button = NSButton()
    var toggle: (() -> Void)?
    var rowHeight: CGFloat = 30 {
        didSet {
            guard rowHeight != oldValue else { return }
            alignButton()
            updateTrackingAreas()
        }
    }
    /// The button is a circle this size (the host mark's), whether or not its glass shows, so it keeps its frame as
    /// the sidebar slides over it.
    var size: CGFloat = 26 {
        didSet {
            guard size != oldValue else { return }
            alignButton()
            updateTrackingAreas()
        }
    }
    /// With Liquid Glass the button floats on a glass capsule behind it, shown and hidden with it. The capsule
    /// fades with the sidebar's slide instead of popping in, so the button doesn't flicker as the sidebar toggles.
    var glass = false {
        didSet {
            guard glass != oldValue else { return }
            if glass, glassView == nil, #available(macOS 26, *) {
                let effect = NSGlassEffectView()
                effect.alphaValue = 0
                addSubview(effect, positioned: .below, relativeTo: button)
                glassView = effect
                alignButton(); buttonHidden = button.isHidden
            }
            transition { self.glassView?.alphaValue = self.glassAlpha }
        }
    }
    /// Runs changes over the sidebar's own duration (immediately with Reduce Motion or before the view shows).
    private func transition(_ changes: @escaping () -> Void) {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { changes(); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = InterfaceMotion.sidebarDuration
            context.allowsImplicitAnimation = true
            changes()
        }
    }
    private var glassView: NSView?
    private var buttonHidden: Bool {
        get { button.isHidden }
        set {
            button.isHidden = newValue; glassView?.isHidden = newValue
            // Reported after the update that changed it, which may be SwiftUI's own.
            let shown = !newValue
            DispatchQueue.main.async { [weak self] in self?.revealed?(shown) }
        }
    }
    var revealed: ((Bool) -> Void)?
    /// A host mark shows in the button's place: the button turns invisible and leaves clicks to the mark.
    var hosted = false {
        didSet {
            guard hosted != oldValue else { return }
            // Crossfades with the mark scaling in or out over it.
            transition { self.button.alphaValue = self.buttonAlpha; self.glassView?.alphaValue = self.glassAlpha }
        }
    }
    var pinned = false {
        didSet {
            guard pinned != oldValue else { return }
            dismissal?.cancel(); dismissal = nil
            if pinned { buttonHidden = suppressed }
            else if let window { updatePointer(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
        }
    }
    /// Hidden for good, edge included, while the strip's host mark stands in for it. It fades out as the mark scales
    /// in, and back in as the mark goes.
    var suppressed = false {
        didSet {
            guard suppressed != oldValue else { return }
            dismissal?.cancel(); dismissal = nil
            fadeButton(shown: !suppressed && pinned)
        }
    }
    /// The button's and its glass's resting opacity.
    private var buttonAlpha: CGFloat { hosted ? 0 : 1 }
    private var glassAlpha: CGFloat { glass && !hosted ? 1 : 0 }
    private func fadeButton(shown: Bool) {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { buttonHidden = !shown; return }
        if shown && buttonHidden {
            button.alphaValue = 0; glassView?.alphaValue = 0
            buttonHidden = false
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = InterfaceMotion.viewDuration
            context.allowsImplicitAnimation = true
            button.animator().alphaValue = shown ? buttonAlpha : 0
            glassView?.animator().alphaValue = shown ? glassAlpha : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A later change may have shown it again meanwhile.
                guard let self, !shown, self.suppressed || !self.pinned else { return }
                self.buttonHidden = true
                self.button.alphaValue = self.buttonAlpha; self.glassView?.alphaValue = self.glassAlpha
            }
        })
    }
    private var areas: [NSTrackingArea] = []
    private var dismissal: DispatchWorkItem?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init() {
        super.init(frame: .zero)
        alignButton()
        button.title = ""; button.isBordered = false
        button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        button.wantsLayer = true
        button.layer?.borderWidth = 1
        button.focusRingType = .none
        button.setAccessibilityIdentifier("fullscreen-sidebar-toggle")
        button.target = self; button.action = #selector(clicked)
        button.isHidden = true
        addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    private func alignButton() {
        // Match the tab controls as font size and native/tmux row heights change.
        button.frame = NSRect(x: Chrome.sidebarButtonInset, y: (rowHeight - size) / 2, width: size, height: size)
        button.layer?.cornerRadius = size / 2
        glassView?.frame = button.frame
        if #available(macOS 26, *) { (glassView as? NSGlassEffectView)?.cornerRadius = button.frame.height / 2 }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !hosted, !button.isHidden, button.frame.contains(local) else { return nil }
        return button
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        areas.forEach(removeTrackingArea)
        areas = [NSRect(x: 0, y: 0, width: 14, height: bounds.height), button.frame.insetBy(dx: -6, dy: -6)].map {
            NSTrackingArea(rect: $0, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        }
        areas.forEach(addTrackingArea)
    }
    override func mouseEntered(with event: NSEvent) { updatePointer(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { updatePointer(at: convert(event.locationInWindow, from: nil)) }
    func updatePointer(at point: NSPoint) {
        dismissal?.cancel(); dismissal = nil
        guard !suppressed else { buttonHidden = true; return }
        let edge = NSRect(x: 0, y: 0, width: 14, height: bounds.height)
        if pinned || edge.contains(point) || button.frame.insetBy(dx: -6, dy: -6).contains(point) {
            buttonHidden = false
        } else {
            let task = DispatchWorkItem { [weak self] in self?.buttonHidden = true; self?.dismissal = nil }
            dismissal = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: task)
        }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        dismissal?.cancel(); dismissal = nil; buttonHidden = suppressed || !pinned
        super.viewWillMove(toWindow: newWindow)
    }
    @objc private func clicked() { toggle?() }
}

/// The content under a floating glass sidebar: laid out right of it, with its own background continuing beneath
/// (backgrounds extend into safe areas), so the glass floats over the same ground as the panes. No mirrored
/// background extension: at the leading edge it would mostly copy the tab strips, smeared into a band.
/// The modifier stays attached at zero, keeping the content's identity when Liquid Glass or the sidebar toggles.
private struct SidebarExtension: ViewModifier {
    let leading: CGFloat
    func body(content: Content) -> some View {
        content.safeAreaPadding(.leading, leading)
    }
}

/// The floating sidebar's trailing edge: drag to resize its panel within the same bounds as the split column.
private struct SidebarResizeHandle: View {
    @Binding var width: CGFloat
    let minimum: CGFloat
    @State private var start: CGFloat?
    @State private var hovering = false

    var body: some View {
        Color.clear.frame(width: 8).contentShape(Rectangle())
            .onHover { inside in
                if inside, !hovering { NSCursor.resizeLeftRight.push() } else if !inside, hovering { NSCursor.pop() }
                hovering = inside
            }
            .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let origin = start ?? width
                    start = origin
                    width = min(max(minimum, origin + value.translation.width), max(340, minimum * 1.7))
                }
                .onEnded { _ in start = nil })
            .accessibilityHidden(true)
    }
}

/// The window's title follows the active tab's label. Leaf views read it, so a title change re-renders them
/// instead of MainView and everything below it.
@MainActor private func windowTitle(_ workspace: Workspace, settings: SettingsStore) -> String {
    guard let space = workspace.current else { return "Dispatch" }
    let runtime = TerminalRuntime.shared, automatic = settings.values.automaticTabNames
    let tab = space.containers.first { $0.id == space.selectedContainer }.map { runtime.label(for: $0, automatic: automatic) }
        ?? space.activeTab.map { runtime.label(for: workspace.liveTab($0.id) ?? $0, automatic: automatic) }
    return "\(tab ?? "Terminal") — \(workspace.liveName(space))"
}

private struct MainTitleText: View {
    let workspace: Workspace
    let settings: SettingsStore
    let offline: Bool

    var body: some View {
        Text(windowTitle(workspace, settings: settings))
            + Text(offline ? " · offline" : "").foregroundColor(Color(red: 217/255, green: 179/255, blue: 106/255))
    }
}

private struct WindowTitleSync: View {
    let workspace: Workspace
    let settings: SettingsStore
    let controller: AppDelegate

    var body: some View {
        Color.clear.onChange(of: windowTitle(workspace, settings: settings)) { _, title in controller.window.title = title }
    }
}
