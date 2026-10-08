import SwiftUI
import AppKit

struct PaneView: View {
    @Environment(\.appTypography) private var typography
    let pane: Pane
    let space: Space
    let workspace: Workspace
    let settings: SettingsStore
    let controller: AppDelegate
    var isPresented = true
    /// Native panes put their strip in the title row; tmux panes leave it to the window strip.
    var titlebar: TitlebarPlacement?
    private var inTitlebar: Bool { titlebar != nil }
    /// Height of an outer tmux window strip laid over this pane's top edge (Liquid Glass).
    var stripInset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// This pane's strip shows its ⌘N badge, which marks focus in place of the accent border.
    @State private var shortcutBadgeShown = false
    private var hostTint: HostTint? { pane.activeTab.flatMap { TerminalRuntime.shared.ssh.tint(for: $0) } }
    /// Tabs take the host color with Liquid Glass; flat chrome keeps just the pane's top border.
    private var tabTint: HostTint? { RemoteTabHighlight.current == .fade ? hostTint : nil }
    private var window: Space.Window? { space.windows.first { $0.arrangement.panes.contains { $0.id == pane.id } } }
    private func label(_ tab: TerminalTab) -> String {
        TerminalRuntime.shared.label(for: tab, automatic: settings.values.automaticTabNames)
    }
    private var activeLabel: String? { pane.activeTab.map(label) }
    private var tabStyle: StripTab.Style { .current(controller.windowState) }
    /// Off the title row (full screen), the strip shows only when there are tabs or panes to choose between.
    static func showsTabs(pane: Pane, space: Space) -> Bool {
        !space.structured && (pane.tabs.count > 1 || space.panes.count > 1)
    }
    private var showTabs: Bool { (!space.structured && inTitlebar) || Self.showsTabs(pane: pane, space: space) }
    private var hasTmuxHeader: Bool { space.structured && (window?.arrangement.panes.count ?? 0) > 1 }
    /// With Liquid Glass the strip lies over the content, so the glass has the terminal or chat behind it.
    private var glassStrip: Bool { LiquidGlassStore.shared.active }
    private var overlaidStrip: Bool { glassStrip && showTabs && !hasTmuxHeader }
    /// How much of the content's top a glass strip covers: this pane's own, or an outer tmux strip's.
    private var contentInset: CGFloat { overlaidStrip ? tabBarHeight : hasTmuxHeader ? 0 : stripInset }
    private var tabBarHeight: CGFloat {
        StripTab.barHeight(titlebar: titlebar, style: tabStyle, split: space.numberedPaneIDs.count > 1, typography: typography)
    }

    private var floatingChatSwitch: Bool {
        guard let window else { return !showTabs }
        return !inTitlebar && window.arrangement.panes.count == 1 && !WindowTabBar.showsTabs(space: space)
    }
    private var placement: TabBarPlacement {
        TabBarPlacement(titlebar: titlebar,
                        sidebarSlot: controller.windowState.isFullScreen && !controller.sidebarVisible && pane.id == space.layout.paneIDs.first
                            && (!space.structured || space.windows.count <= 1))
    }
    private var stripLeading: CGFloat { placement.leading(controller.windowState, sidebarVisible: controller.sidebarVisible) }

    var body: some View {
        // Under a glass strip the banner floats just below it instead of pushing the content down.
        let floatsBanner = overlaidStrip || (stripInset > 0 && !hasTmuxHeader)
        VStack(spacing: 0) {
            if hasTmuxHeader {
                tmuxPaneHeader.padding(.leading, stripLeading - Chrome.stripInset).padding(.top, stripInset)
            } else if showTabs && !overlaidStrip {
                tabBar
            }
            if !floatsBanner, space.focusedPane == pane.id { AttentionBanner(controller: controller) }
            if let tab = pane.activeTab {
                Group {
                    if tab.isConnecting {
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Connecting…").foregroundStyle(Chrome.muted)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.top, contentInset)
                    } else { tabContent(tab).environment(\.glassStripInset, contentInset) }
                }
            }
        }
        .overlay(alignment: .top) {
            if floatsBanner {
                VStack(spacing: 0) {
                    if overlaidStrip { tabBar }
                    if space.focusedPane == pane.id { AttentionBanner(controller: controller) }
                }.padding(.top, overlaidStrip ? 0 : stripInset)
            }
        }
        .hostTintBorder(!space.structured ? hostTint : nil, surfaceID: pane.activeTab?.focusedSurfaceID,
                        stripHeight: showTabs ? tabBarHeight : 0)
        .frame(minWidth: 180, maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
        .font(typography.font(offset: -1))
        .foregroundStyle(Chrome.ink)
        .onPreferenceChange(PaneShortcutBadgeShown.self) { shortcutBadgeShown = $0 }
        // The strip's accent-colored shortcut badge marks the focused pane when it shows; otherwise this border does.
        .overlay {
            if space.panes.count > 1 && !shortcutBadgeShown {
                Rectangle().strokeBorder(Chrome.accent.opacity(space.focusedPane == pane.id ? 0.35 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
                    .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.14), value: space.focusedPane)
            }
        }
        .modifier(PaneFocusHighlight(workspace: workspace,
                                     paneID: !space.structured && space.focusedPane == pane.id && !shortcutBadgeShown ? pane.id : nil))
        .overlay {
            LocalReorder(edge: .pane, accepts: { item in
                guard case .tab(let id) = item else { return false }
                return workspace.canMoveTab(id, to: pane.id) && space.panes.contains { $0.id != pane.id && $0.tabs.contains { $0.id == id } }
            }) { item, _ in
                guard case .tab(let id) = item else { return }
                workspace.moveTab(id, to: pane.id)
            }
        }
        .environment(\.remoteTabHighlight, .current)
    }

    private func tabHoverDetails(_ tab: TerminalTab) -> SpaceHoverDetails {
        let host = workspace.hosts.terminals[tab.focusedSurfaceID]?.host ?? space.hostID
        return SpaceHoverDetails.make(tab: tab, host: workspace.hosts.record(host), runtime: TerminalRuntime.shared)
    }

    private var tmuxPaneHeader: some View {
        HStack(spacing: 8) {
            tmuxPaneTitle
            let chat = TerminalRuntime.shared.chat
            let session = chat.session(for: pane.activeTab?.focusedSurfaceID ?? pane.selected)
            if chat.canEnterChat(session) || session.showChat {
                ChatModeSwitch(session: session, coordinator: chat).fixedSize()
            }
            Button { controller.closeTab(pane.selected) } label: {
                CloseGlyph()
                    .frame(width: 24, height: glassStrip ? StripTab.glassTrackHeight(typography) : typography.expanded(26))
                    .contentShape(Rectangle())
            }.accessibilityLabel("Close pane").help("Close pane · detaches if jobs are running")
        }
        // On glass a split pane's capsule like a native pane's strip, the strip's margin above it and none below; its
        // chat switch sits on the capsule's glass. Leading the window in full screen, it starts with the sidebar
        // button's slot, as a native strip does.
        .padding(.leading, placement.sidebarSlot ? Chrome.sidebarSlotWidth : glassStrip ? 12 : 0)
        .padding(.trailing, glassStrip ? 4 : 0)
        .stripCapsule(glassStrip, tint: tabTint)
        .padding(.horizontal, Chrome.stripInset)
        .frame(height: glassStrip ? StripTab.barHeight(titlebar: nil, style: .outlined, split: true, typography: typography)
                                  : typography.expanded(26), alignment: .bottom)
            .buttonStyle(.plain)
            // A container, so its switch and close button keep their own identifiers.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("tmux-pane-header-\(pane.id)")
            .contextMenu {
                Button("Rename Pane…") { controller.rename(title: "Rename pane", value: activeLabel ?? "") { workspace.updateTab(pane.selected, customTitle: $0) } }
                Button("Move Pane to New Space") { workspace.moveTabToNewSpace(pane.selected) }
                Button("Detach") { controller.detachTab(pane.selected) }
                Button("Terminate…") { controller.terminatePane(pane.selected) }
            }
    }

    private var tmuxPaneTitle: some View {
        HStack(spacing: 8) {
            AgentActivityGlyph(tabIDs: pane.tabs.flatMap(\.surfaceIDs), connecting: pane.tabs.flatMap(\.surfaceIDs).contains { workspace.hostMoveMotion.connecting.contains($0) })
            Text(window?.name ?? activeLabel ?? "Terminal").lineLimit(1).truncationMode(.middle)
            if (window?.terminals.count ?? 0) > 1 {
                Text(activeLabel ?? "").foregroundStyle(Chrome.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }.frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { workspace.selectTab(pane.selected) }
            .overlay {
                LocalReorder(item: .tab(pane.selected), edge: .horizontal,
                             spaceHover: pane.activeTab.map { tabHoverDetails($0) },
                             dragLabel: activeLabel, select: { workspace.selectTab(pane.selected) },
                             accepts: { if case .tab(let id) = $0 { return workspace.canMoveTab(id, to: pane.id) }; return false }) { item, _ in
                    if case .tab(let id) = item { workspace.moveTab(id, to: pane.id) }
                }
            }
    }

    private var tabBar: some View {
        let chat = TerminalRuntime.shared.chat
        let session = chat.session(for: pane.activeTab?.focusedSurfaceID ?? pane.selected)
        return TabBar(ids: pane.tabs.map(\.id), selected: pane.selected, space: space, workspace: workspace, controller: controller,
                      placement: placement, paneID: pane.id, paneFocused: space.focusedPane == pane.id,
                      chatSession: (chat.canEnterChat(session) || session.showChat) ? session : nil,
                      reservesChatSwitch: chat.canShowChat(anyOf: pane.tabs.map(\.focusedSurfaceID)),
                      showsLayoutPicker: pane.id == space.layout.topRightPaneID && space.layoutTabCount > 1, hostTint: hostTint,
                      host: TerminalRuntime.shared.ssh.stripHost(active: pane.activeTab, among: pane.tabs),
                      overflowItems: { pane.tabs.map { .init(id: $0.id, title: label($0), surfaceIDs: $0.surfaceIDs) } },
                      select: { workspace.selectTab($0) },
                      newTab: { workspace.selectTab(pane.selected); workspace.newTab() },
                      listOverlay: AnyView(LocalReorder(edge: .pane, accepts: { if case .tab(let id) = $0 { return workspace.canMoveTab(id, to: pane.id) }; return false }) { item, _ in
                          guard case .tab(let id) = item, let last = pane.tabs.last else { return }
                          workspace.moveTab(id, to: pane.id, relativeTo: last.id, after: true)
                      })) { id, width, hovered in
            if let tab = pane.tabs.first(where: { $0.id == id }) { tabRow(tab, width: width, hovered: hovered) }
        }
    }

    private func tabRow(_ tab: TerminalTab, width: CGFloat, hovered: Bool) -> some View {
        let connecting = tab.surfaceIDs.contains { workspace.hostMoveMotion.connecting.contains($0) }
        return StripTab(title: label(tab), activityIDs: tab.surfaceIDs, connecting: connecting, shortcut: space.tabShortcut(for: tab.id),
                        width: width, selected: pane.selected == tab.id, hovered: hovered, hostTint: tabTint,
                        closeHelp: "Close tab",
                        select: { workspace.selectTab(tab.id) }, close: { controller.closeTab(tab.id) }, style: tabStyle,
                        divider: tabStyle == .outlined && StripTab.divider(after: tab.id, in: pane.tabs.map(\.id), selected: pane.selected),
                        alone: pane.tabs.count == 1)
        .accessibilityIdentifier("tab-\(tab.id)")
        .overlay { HostMoveMarker(motion: workspace.hostMoveMotion, item: .tab(tab.id)).allowsHitTesting(false) }
        .overlay {
            LocalReorder(item: .tab(tab.id), edge: .horizontal, leadingButtonWidth: StripTab.closeSlotWidth, spaceHover: tabHoverDetails(tab), dragLabel: label(tab),
                         select: { workspace.selectTab(tab.id) },
                         accepts: { if case .tab(let id) = $0 { return workspace.canMoveTab(id, to: pane.id) }; return false }) { item, after in
                guard case .tab(let id) = item else { return }
                workspace.moveTab(id, to: pane.id, relativeTo: tab.id, after: after)
            }
        }
        .contextMenu {
            Button("Rename…") { controller.rename(title: "Rename tab", value: label(tab)) { workspace.updateTab(tab.id, customTitle: $0) } }
            if space.panes.count > 1 {
                ForEach(space.panes.filter { $0.id != pane.id }) { target in
                    Button("Move to Pane \(space.paneShortcutNumber(for: target.id) ?? 1)") { workspace.moveTab(tab.id, to: target.id) }
                }
            }
            Button("Move to New Space") { workspace.moveTabToNewSpace(tab.id) }
            ForEach(workspace.spaces.filter { $0.id != space.id && workspace.canMoveTab(tab.id, to: $0.focusedPane) }) { target in
                Button("Move to \(target.name)") { workspace.moveTab(tab.id, to: target.focusedPane) }
            }
            Button("Close Tab") { controller.closeTab(tab.id) }
        }
    }

    private func tabContent(_ tab: TerminalTab) -> some View {
        TerminalContentView(tab: tab, workspace: workspace, spaceID: space.id, windowTabID: window?.id, paneID: pane.id, focused: isPresented && space.focusedPane == pane.id,
                            isPresented: isPresented, floatingSwitch: floatingChatSwitch)
            .overlay { SplitDropZones(pane: pane, workspace: workspace) }
    }

}

extension PaneLayout {
    var topRightPaneID: UUID {
        switch self {
        case .pane(let id): id
        case .split(_, let axis, let first, let second):
            (axis == .columns ? second : first).topRightPaneID
        }
    }

    /// Panes whose top edge is the layout's top edge.
    var topPaneIDs: Set<UUID> {
        switch self {
        case .pane(let id): [id]
        case .split(_, let axis, let first, let second):
            axis == .columns ? first.topPaneIDs.union(second.topPaneIDs) : first.topPaneIDs
        }
    }
}

struct TerminalHost: NSViewRepresentable {
    let tab: TerminalTab
    let spaceID: UUID
    let windowTabID: UUID?
    let paneID: UUID
    let focusRequest: UUID
    let focused: Bool
    let visible: Bool

    private var ownsPresentation: Bool {
        guard let space = TerminalRuntime.shared.workspace?.current else { return false }
        let currentWindow = space.windows.first { $0.terminals.contains { $0.id == tab.id } }?.id
        return space.id == spaceID && currentWindow == windowTabID && space.layout.paneIDs.contains(paneID)
            && space.panes.first(where: { $0.id == paneID })?.activeTab?.surfaceIDs.contains(tab.id) == true
            && TerminalRuntime.shared.workspace?.isSurfacePresented(tab.id) == true
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        if ownsPresentation { attach(to: container).isPresented = visible }
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Outgoing SwiftUI trees can update after the terminal's new host has
        // mounted. Only its current model owner may reparent the retained view.
        guard ownsPresentation else {
            for case let terminal as TerminalView in container.subviews {
                terminal.isPresented = false
                terminal.removeFromSuperview()
            }
            return
        }
        let terminal = attach(to: container)
        terminal.isPresented = visible
        let becameFocused = focused && !context.coordinator.focused
        context.coordinator.focused = focused
        guard focused, becameFocused || context.coordinator.request != focusRequest else { return }
        context.coordinator.request = focusRequest
        DispatchQueue.main.async {
            let active = TerminalRuntime.shared.workspace?.activeTab
            guard active?.id == tab.id else { return }
            TerminalRuntime.shared.focusActive()
        }
    }

    private func attach(to container: NSView) -> TerminalView {
        let terminal = TerminalRuntime.shared.view(for: tab)
        if terminal.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            terminal.removeFromSuperview()
            terminal.frame = container.bounds
            terminal.autoresizingMask = [.width, .height]
            container.addSubview(terminal)
        }
        return terminal
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        // The registry retains the terminal; detaching only changes visibility.
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var request: UUID?; var focused = false }
}
