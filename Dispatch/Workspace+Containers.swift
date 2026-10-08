import Foundation

extension Workspace {
  func container(containing terminal: UUID) -> ContainerTab? {
    spaces.flatMap(\.containers).first { $0.terminals.contains { $0.id == terminal } }
  }

  func container(at pane: UUID) -> ContainerTab? {
    for space in spaces {
      if let group = space.presentation?.groups.first(where: { $0.id == pane }) {
        return space.containers.first { $0.id == group.selected }
      }
      if let container = space.containers.first(where: {
        $0.arrangement.panes.contains { $0.id == pane }
      }) {
        return container
      }
    }
    return nil
  }

  func selectContainer(_ id: UUID) {
    guard let container = spaces.flatMap(\.containers).first(where: { $0.id == id }),
      let pane = container.arrangement.panes.first(where: {
        $0.id == container.arrangement.focusedPane
      }), let terminal = pane.activeTab
    else { return }
    guard let space = updateLayout({ $0.selectTab(terminal.id) }) else { return }
    // Selecting a window preserves its native current pane, including a concurrent split.
    selectSpace(space, node: container.node)
  }

  @discardableResult
  func moveContainer(_ id: UUID, beside target: UUID, edge: PaneEdge?, after: Bool = false) -> Bool {
    guard let source = spaces.firstIndex(where: { $0.containers.contains { $0.id == id } }),
      let destination = spaces.firstIndex(where: {
        $0.containers.contains { $0.id == target }
      }),
      id != target, spaces[source].backend == spaces[destination].backend,
      spaces[source].remote == spaces[destination].remote,
      spaces[source].hostID == spaces[destination].hostID
    else { return false }
    // A window moved beside another goes before it, on the server (c1654cc TmuxCoordinator.moveWindowTab:
    // inserted at the target's index): the server's order is the order shown, in either space.
    if edge == nil,
      let container = spaces[source].containers.first(where: { $0.id == id }),
      let other = spaces[destination].containers.first(where: { $0.id == target }),
      let helper = helper(spaces[source])
    {
      var before: UUID? = other.id
      if after {
        let members = (spaces[destination].presentation?.groups.first {
          $0.windows.contains(target)
        }?.windows ?? spaces[destination].containers.map(\.id)).filter { $0 != id }
        if let index = members.firstIndex(of: target) {
          before = members.dropFirst(index + 1).first
        }
      }
      if var presentation = spaces[destination].presentation,
        presentation.move(id, beside: target, edge: nil, after: after)
      {
        updateLayout { next in
          next.spaces[destination].presentation = presentation
          next.spaces[destination].selectedContainer = id
          next.selectedSpace = next.spaces[destination].id
        }
      }
      return helper.move(.item(container.id), parent: .item(spaces[destination].id), before: before.map { .item($0) }, select: true)
    }
    if source != destination { return false }
    var presentation = spaces[source].presentation ?? TabPresentation(windows: spaces[source].containers.map(\.id), selected: id, preset: .single)
    guard presentation.move(id, beside: target, edge: edge) else { return false }
    updateLayout { next in
      next.spaces[source].presentation = presentation
      next.spaces[source].selectedContainer = id
      next.selectedSpace = next.spaces[source].id
    }
    selectContainer(id)
    return true
  }

  var currentTabs: [TerminalTab] {
    guard let current else { return [] }
    if !current.containers.isEmpty {
      let members =
        current.presentation?.groups.first {
          $0.windows.contains { $0 == current.selectedContainer }
        }?.windows ?? current.containers.map(\.id)
      return members.compactMap { id in
        let arrangement = current.containers.first { $0.id == id }?.arrangement
        return arrangement?.panes.first { $0.id == arrangement?.focusedPane }?.activeTab
      }
    }
    return current.activePane?.tabs ?? []
  }

  func cycleTab(_ delta: Int) {
    if let space = current, let selected = space.selectedContainer, !space.containers.isEmpty {
      let members = space.focusedWindowIDs
      if let index = members.firstIndex(of: selected) {
        selectContainer(members[(index + delta + members.count) % members.count])
      }
      return
    }
    guard let pane = current?.activePane,
      let index = pane.tabs.firstIndex(where: { $0.id == pane.selected })
    else { return }
    selectTab(pane.tabs[(index + delta + pane.tabs.count) % pane.tabs.count].id)
  }

  func selectNumberedItem(at index: Int) {
    guard let space = current, index >= 0, index < space.numberedShortcutCount else { return }
    if space.usesPaneShortcuts {
      selectPane(at: index)
    } else if !space.containers.isEmpty {
      selectContainer(space.numberedTabIDs[index])
    } else {
      selectTab(space.numberedTabIDs[index])
    }
  }

  func selectPane(at index: Int) {
    guard let space = current else { return }
    let targets = space.numberedPaneIDs
    guard targets.indices.contains(index), index < 4 else { return }
    let paneID = targets[index]
    if !space.containers.isEmpty {
      guard
        let selected = space.presentation?.groups.first(where: { $0.id == paneID })?
          .selected
      else { return }
      selectContainer(selected)
      paneFocusFeedback = PaneFocusFeedback(paneID: paneID)
      return
    }
    guard let pane = space.panes.first(where: { $0.id == paneID }) else { return }
    selectTab(pane.selected)
    paneFocusFeedback = PaneFocusFeedback(paneID: paneID)
  }

  var canSplit: Bool {
    if let space = current, !space.containers.isEmpty {
      let group = space.presentation?.groups.first {
        $0.windows.contains { $0 == space.selectedContainer }
      }
      return (space.presentation?.groups.count ?? 1) < 4
        && (group?.windows.count ?? space.containers.count) > 1
    }
    return (current?.panes.count ?? 4) < 4 && currentTabs.count > 1
  }

  func canApplyLayout(_ preset: LayoutPreset, in space: Space? = nil) -> Bool {
    if (space ?? current)?.tabs.contains(where: \.isConnecting) == true { return false }
    guard let space = space ?? current else { return false }
    return space.layoutTabCount >= preset.count
  }
}

/// Window tabs of a structured space (helper containers). Views and actions use these instead of
/// naming a multiplexer.
extension Space {
  struct Window: Identifiable, Equatable {
    let id: UUID
    let name: String
    let arrangement: PaneArrangement
    var terminals: [TerminalTab] { arrangement.panes.flatMap(\.tabs) }
  }

  /// An attached multiplexer session: a helper backend space with containers.
  var structured: Bool { backend != nil && !containers.isEmpty }

  /// What layouts arrange: window tabs when there are containers, terminal tabs otherwise.
  var layoutTabCount: Int { containers.isEmpty ? tabs.count : containers.count }

  var windows: [Window] {
    containers.map { Window(id: $0.id, name: $0.name, arrangement: $0.arrangement) }
  }

  var windowPresentation: TabPresentation? { presentation }

  var activeWindow: Window? {
    windows.first { $0.id == selectedContainer }
  }

  /// The windows ⌘[ / ⌘] cycle through: the selected window's presentation group, else every window.
  var focusedWindowIDs: [UUID] {
    guard let selected = selectedContainer else { return [] }
    return presentation?.groups.first { $0.windows.contains(selected) }?.windows ?? containers.map(\.id)
  }
}

extension Workspace {
  func selectWindow(_ id: UUID) {
    selectContainer(id)
  }

  func renameWindow(_ id: UUID, to name: String) {
    if let space = spaces.first(where: { $0.containers.contains { $0.id == id } }),
      let container = space.containers.first(where: { $0.id == id })
    {
      helper(space)?.rename(container.id, name: name)
    }
  }

  /// Windows move only within one backend session.
  func canMoveWindow(_ id: UUID, beside target: UUID) -> Bool {
    guard id != target else { return false }
    let containers = spaces.flatMap(\.containers)
    if containers.contains(where: { $0.id == id }) {
      let source = spaces.first { $0.containers.contains { $0.id == id } }
      let destination = spaces.first { $0.containers.contains { $0.id == target } }
      return source?.backend != nil && source?.backend == destination?.backend && source?.remote == destination?.remote
        && source?.hostID == destination?.hostID
    }
    return false
  }

  /// Moves a window into a new space of its session.
  func moveWindowToNewSpace(_ id: UUID) {
    guard let space = spaces.first(where: { $0.containers.contains { $0.id == id } }),
      let container = space.containers.first(where: { $0.id == id })
    else { return }
    // A manual move supersedes the automatic return of a host move; the selection goes with the window.
    container.terminals.forEach { supersedeHostPlacement($0.id) }
    if let active = container.terminals.first(where: { $0.id == activeSurfaceID })?.terminal {
      helper(space)?.follow(active, from: space.id)
    }
    helper(space)?.place(container.placeable, inNewSpace: Self.nextSpaceName(in: spaces), select: true)
  }

  /// Moves a window beside another of the same backend session.
  @discardableResult
  func moveWindow(_ id: UUID, beside target: UUID) -> Bool {
    moveContainer(id, beside: target, edge: nil)
  }
}

/// Detached work kept running on its server, listed in the sidebar until restored or forgotten.
struct DetachedEntry: Identifiable, Equatable {
  let id: UUID
  let host: HostID
  let name: String
  let kind: String
  /// Who keeps it running: the helper backend's label.
  let source: String
}

extension Workspace {
  var detached: [DetachedEntry] {
    helpers.values.flatMap { helper in
        helper.detachedRoutes.flatMap { entry in
          let label = helper.source(entry.route)
          return entry.presentation.map {
            DetachedEntry(id: $0.id, host: $0.hostID, name: $0.name, kind: "Space", source: label)
          }
        }
        + helper.detachedWindows.map { window in
          let label = helper.source(window.route)
          return DetachedEntry(id: window.id, host: window.host, name: window.name, kind: "Tab", source: label)
        }
      }
  }

  func restoreDetached(_ ids: Set<UUID>) {
    for helper in helpers.values { helper.restore(ids) }
  }

  func forgetDetached(_ id: UUID) {
    for helper in helpers.values { helper.forget(id) }
  }

  func isRestoringDetached(_ id: UUID) -> Bool {
    helpers.values.contains { $0.isRestoring(id) }
  }
}
