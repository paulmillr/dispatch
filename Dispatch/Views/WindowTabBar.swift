import SwiftUI

/// A server window owns its entire split tree; the space groups window tabs.
struct WindowTabBar: View {
    @Environment(\.appTypography) private var typography
    let space: Space
    let workspace: Workspace
    let controller: AppDelegate
    var group: TabPresentation.Group?
    var titlebar: TitlebarPlacement?
    private var tabs: [Space.Window] {
        guard let group else { return space.windows }
        return group.windows.compactMap { id in space.windows.first { $0.id == id } }
    }
    private var selected: UUID? { group?.selected ?? space.activeWindow?.id }
    private var paneID: UUID { group?.id ?? space.numberedPaneIDs.first ?? space.id }
    /// Vertical tabs lists the windows in the sidebar instead.
    static func showsTabs(space: Space, verticalTabs: Bool) -> Bool {
        !verticalTabs && space.structured && ((space.windowPresentation?.groups.count ?? 1) > 1 || space.windows.count > 1)
    }

    /// Spacing and the full-screen slot match the native pane strip, so tabs keep their place across spaces.
    private var placement: TabBarPlacement {
        TabBarPlacement(titlebar: titlebar,
                        sidebarSlot: controller.windowState.isFullScreen && !controller.sidebarVisible
                            && (group == nil || group?.id == space.windowPresentation?.layout.paneIDs.first))
    }

    private func label(_ tab: Space.Window) -> String {
        guard let container = space.containers.first(where: { $0.id == tab.id }) else { return tab.name }
        return TerminalRuntime.shared.label(for: container, automatic: controller.settings.values.automaticTabNames)
    }

    private var tabStyle: StripTab.Style { .current(controller.windowState) }

    private var hostTint: HostTint? { space.activeTab.flatMap { TerminalRuntime.shared.ssh.tint(for: $0) } }
    /// Tabs take the host color with Liquid Glass; flat chrome keeps just the pane's top border.
    private var tabTint: HostTint? { RemoteTabHighlight.current == .fade ? hostTint : nil }

    /// The selected window's chat session, when that window is a single terminal; a split window's panes switch in
    /// their own headers.
    private var chatSession: ChatSession? {
        guard let window = tabs.first(where: { $0.id == selected }), window.arrangement.panes.count == 1,
              let terminal = window.arrangement.panes.first?.activeTab else { return nil }
        return TerminalRuntime.shared.chat.session(for: terminal.focusedSurfaceID)
    }

    var body: some View {
        TabBar(ids: tabs.map(\.id), selected: selected, space: space, workspace: workspace, controller: controller,
               placement: placement, paneID: paneID, paneFocused: selected == space.activeWindow?.id,
               chatSession: chatSession,
               reservesChatSwitch: tabs.contains { $0.arrangement.panes.count == 1 },
               showsLayoutPicker: space.layoutTabCount > 1 && (group == nil || group?.id == space.windowPresentation?.layout.topRightPaneID), hostTint: hostTint,
               host: TerminalRuntime.shared.ssh.stripHost(active: space.activeTab, among: tabs.flatMap(\.terminals)),
               overflowItems: { tabs.map { .init(id: $0.id, title: label($0), surfaceIDs: $0.terminals.flatMap(\.surfaceIDs)) } },
               select: { workspace.selectWindow($0) },
               newTab: {
                   if let selected { workspace.selectWindow(selected) }
                   workspace.newTab()
               }) { id, width, hovered in
            if let tab = tabs.first(where: { $0.id == id }) { row(tab, width: width, hovered: hovered) }
        }
        .font(typography, .label)
        // A container, so the tabs and buttons inside keep their own identifiers instead of inheriting this one.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tmux-window-tabs")
        .environment(\.remoteTabHighlight, .current)
    }

    private func row(_ tab: Space.Window, width: CGFloat, hovered: Bool) -> some View {
        let shortcut = space.tabShortcut(for: tab.id), title = label(tab)
        return StripTab(title: title, activityIDs: tab.terminals.map(\.id),
                        connecting: tab.terminals.contains { workspace.hostMoveMotion.connecting.contains($0.id) }, shortcut: shortcut,
                        width: width, selected: selected == tab.id, hovered: hovered, hostTint: tabTint,
                        closeHelp: "Close tab · detaches if jobs are running",
                        select: { workspace.selectWindow(tab.id) }, close: { controller.closeWindow(tab.id) },
                        style: tabStyle, divider: tabStyle == .outlined && StripTab.divider(after: tab.id, in: tabs.map(\.id), selected: selected),
                        alone: tabs.count == 1)
            .accessibilityIdentifier("tmux-window-tab-\(tab.id)")
            .overlay {
                if let terminal = tab.terminals.first {
                    HostMoveMarker(motion: workspace.hostMoveMotion, item: .tab(terminal.id)).allowsHitTesting(false)
                }
            }
            .overlay {
                LocalReorder(item: .window(tab.id), edge: .horizontal, leadingButtonWidth: StripTab.closeSlotWidth,
                             spaceHover: tab.arrangement.panes.first(where: { $0.id == tab.arrangement.focusedPane })?.activeTab.map { terminal in
                                 SpaceHoverDetails.make(tab: workspace.liveTab(terminal.id) ?? terminal, host: workspace.hosts.record(workspace.hosts.terminals[terminal.id]?.host ?? space.hostID),
                                     runtime: TerminalRuntime.shared, title: title)
                             }, hoverFontSize: typography.tabSize, dragLabel: title, select: { workspace.selectWindow(tab.id) }, accepts: { item in
                    guard case .window(let id) = item else { return false }
                    return workspace.canMoveWindow(id, beside: tab.id)
                }) { item, after in
                    if case .window(let id) = item { workspace.moveWindow(id, beside: tab.id) }
                }
            }
            .contextMenu {
                Button("Rename…") { controller.rename(title: "Rename tab", value: title) { workspace.renameWindow(tab.id, to: $0) } }
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
            }
            .contentShape(Rectangle())
    }
}

/// A place a tab's context menu can move it to, named as the menu lists it.
struct MoveTarget: Identifiable {
    let id: UUID
    let title: String
    let action: () -> Void
}

/// A tab's (or window's) move targets under one "Move to" header, each by its bare name so a space's name never reads
/// as a verb ("Move to release"): the other panes of its space, a new space, then the other spaces, which fold into a
/// submenu past `inlineSpaces` so the menu stays short however many there are.
struct MoveTargetsSection: View {
    var panes: [MoveTarget] = []
    let newSpace: () -> Void
    let spaces: [MoveTarget]

    static let inlineSpaces = 4
    static let detachHelp = "Remove from Dispatch; keep server work running"

    var body: some View {
        Section("Move to") {
            ForEach(panes) { Button($0.title, action: $0.action) }
            Button("New Space", action: newSpace)
            if spaces.count > Self.inlineSpaces {
                Menu("Other Spaces") { targets }
            } else {
                targets
            }
        }
    }

    private var targets: some View {
        ForEach(spaces) { Button($0.title, action: $0.action) }
    }
}
