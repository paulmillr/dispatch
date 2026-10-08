import Foundation

/// A return address for a live terminal, never a recipe for restarting it.
struct HostPlacement {
    var generation: UUID
    let original: Space
    let pane: UUID
    let tabIndex: Int
    var extractedSpace: UUID
    var remaining: PaneArrangement?
    var remainingRatios: [UUID: Double] = [:]
    var originalIndex: Int? = nil
}

extension Workspace {
    var liveHosts: [HostRecord] {
        var ids: Set<HostID> = []
        for space in spaces {
            ids.insert(space.hostID)
            for tab in space.tabs {
                for surface in tab.surfaceIDs {
                    if let host = hosts.terminals[surface]?.host { ids.insert(host) }
                }
            }
        }
        return hosts.ordered(ids)
    }

    /// Every navigation surface consumes this order, including Control-1…9.
    var presentationSpaces: [Space] {
        guard spaceOrder == .tree else { return spaces }
        let groups = Dictionary(grouping: spaces, by: \.hostID)
        return liveHosts.flatMap { groups[$0.id] ?? [] }
    }

    func selectSpace(at index: Int) {
        let order = presentationSpaces
        let index = index == 8 ? order.count - 1 : index
        if order.indices.contains(index) { selectSpace(order[index].id) }
    }

    func spaces(matching filter: String) -> [Space] {
        guard !filter.isEmpty else { return presentationSpaces }
        // Many spaces share a host. Search its labels once per query while
        // keeping results local so connection/alias changes are never cached.
        var matches: [HostID: Bool] = [:]
        func hostMatches(_ id: HostID) -> Bool {
            if let match = matches[id] { return match }
            let record = hosts.record(id)
            let match = record.name.localizedStandardContains(filter) || record.details.localizedStandardContains(filter)
            matches[id] = match
            return match
        }
        return presentationSpaces.filter { space in
            if liveName(space).localizedStandardContains(filter) { return true }
            if hostMatches(space.hostID) { return true }
            return space.tabs.contains { tab in
                tab.surfaceIDs.contains { terminal in
                    hosts.terminals[terminal].map { hostMatches($0.host) } ?? false
                }
            }
        }
    }

    func supersedeHostPlacement(_ tab: UUID) {
        hostPlacements[tab] = nil
        for surface in spaces.flatMap(\.tabs).first(where: { $0.id == tab })?.surfaceIDs ?? [] {
            hostPlacements[surface] = nil
        }
    }

    func belongsToHost(_ space: Space, _ host: HostID) -> Bool {
        space.hostID == host && space.tabs.flatMap(\.surfaceIDs).allSatisfy { (hosts.terminals[$0]?.host ?? space.hostID) == host }
    }

    func hostsAllowMove(_ terminal: UUID, to pane: UUID) -> Bool {
        guard let source = spaces.first(where: { $0.tabs.contains { $0.id == terminal } }),
              let destination = spaces.first(where: { space in
                  space.panes.contains { $0.id == pane }
                    || container(at: pane).map { target in space.containers.contains { $0.id == target.id } } == true
              }) else { return false }
        let tab = source.tabs.first { $0.id == terminal }!
        let host = hosts.terminals[tab.focusedSurfaceID]?.host ?? source.hostID
        return host == destination.hostID && tab.surfaceIDs.allSatisfy { (hosts.terminals[$0]?.host ?? source.hostID) == host }
    }

    /// The host every terminal of a space is logged into (an SSH login inside each), if there is one.
    func loggedHost(_ space: Space) -> HostID? {
        let logins = space.tabs.flatMap(\.surfaceIDs).map { hosts.terminals[$0]?.host }
        guard let first = logins.first, let host = first, logins.allSatisfy({ $0 == host }) else { return nil }
        return host
    }

    /// Plain tabs move entirely within the workspace. A multiplexer's window moves through its server.
    func placeHostTerminal(_ terminal: UUID) {
        guard let context = hosts.terminals[terminal] else { return }
        if let space = spaces.first(where: { $0.structured && $0.tabs.contains { $0.id == terminal } }) {
            placeHostWindow(terminal, in: space, context: context)
            return
        }
        guard let (s, p, t) = location(ofTab: terminal) else { return }
        if var placement = hostPlacements[terminal] {
            placement.generation = context.generation
            hostPlacements[terminal] = placement
            if spaces[s].tabs.count == 1, spaces[s].hostID != context.host {
                updateLayout { next in
                    next.spaces[s].hostID = context.host
                    next.positionAtHostEnd(placement.extractedSpace)
                }
            }
            return
        }
        guard spaces[s].hostID != context.host else { return }
        let original = spaces[s], selected = activeSurfaceID == terminal
        var placement = HostPlacement(generation: context.generation, original: original,
                                      pane: original.panes[p].id, tabIndex: t, extractedSpace: original.id)
        placement.originalIndex = s
        let chosen = updateLayout { next -> UUID? in
            var chosen: UUID?
            if original.tabs.count == 1 {
                next.spaces[s].hostID = context.host
            } else {
                guard let tab = next.detachTab(terminal) else { return nil }
                var extracted = Space(name: Self.nextSpaceName(in: next.spaces), tab: tab, usesDirectoryName: true)
                extracted.hostID = context.host
                placement.extractedSpace = extracted.id
                // The source survives because it originally contained multiple tabs.
                placement.remaining = next.spaces[s].arrangement
                placement.remainingRatios = next.spaces[s].splitRatios
                next.spaces.insert(extracted, at: min(s + 1, next.spaces.count))
                // Background detection does not select the moved terminal.
                if selected { chosen = next.selectTab(terminal) }
            }
            next.positionAtHostEnd(placement.extractedSpace)
            return chosen
        }
        hostPlacements[terminal] = placement
        if let chosen { selectSpace(chosen) }
    }

    /// Move the existing terminal into its own native space, retaining its return address.
    private func placeHostWindow(_ terminal: UUID, in space: Space, context: TerminalHostContext) {
        if hostPlacements[terminal] != nil {
            hostPlacements[terminal]?.generation = context.generation
            return
        }
        guard space.hostID != context.host,
              let index = space.containers.firstIndex(where: { $0.terminals.contains { $0.id == terminal } }),
              space.containers[index].terminals.count > 1 || space.containers.count > 1,
              let node = space.containers[index].terminals.first(where: { $0.id == terminal })?.terminal else { return }
        hostPlacements[terminal] = HostPlacement(generation: context.generation, original: space, pane: space.containers[index].id,
                                                 tabIndex: index, extractedSpace: space.id)
        // Background detection does not select the moved terminal; a selected one stays selected.
        if activeSurfaceID == terminal, let node = space.tabs.first(where: { $0.id == terminal })?.terminal {
            helper(space)?.follow(node, from: space.id)
        }
        helper(space)?.place(node, inNewSpace: nextSpaceName, optional: true)
    }

    /// The window goes back beside the window it followed, unless its origin is gone or changed meanwhile
    /// (windows added, closed or split: the user's new arrangement wins).
    private func restoreHostWindow(_ terminal: UUID, placement: HostPlacement) {
        if placement.original.containers.first(where: { $0.id == placement.pane })?.terminals.count ?? 0 > 1 {
            guard let space = spaces.first(where: { $0.tabs.contains { $0.id == terminal } }),
                  space.id != placement.original.id,
                  let node = space.tabs.first(where: { $0.id == terminal })?.terminal else { return }
            if activeSurfaceID == terminal { helper(space)?.follow(node, from: space.id) }
            helper(space)?.relocate(node, to: .init(kind: "restore", label: ""), optional: true)
            return
        }
        let shape = { (windows: [ContainerTab]) in windows.filter { $0.id != placement.pane }.map { [$0.id] + $0.terminals.map(\.id) } }
        guard let space = spaces.first(where: { $0.tabs.contains { $0.id == terminal } }), space.id != placement.original.id,
              let window = space.containers.first(where: { $0.terminals.contains { $0.id == terminal } }),
              let origin = spaces.first(where: { $0.id == placement.original.id }), let parent = origin.node,
              shape(origin.containers) == shape(placement.original.containers) else { return }
        let next = placement.original.containers.dropFirst(placement.tabIndex + 1).lazy
            .compactMap { old in origin.containers.first { $0.id == old.id }?.node }.first
        if activeSurfaceID == terminal, let node = window.terminals.first(where: { $0.id == terminal })?.terminal {
            helper(space)?.follow(node, from: space.id)
        }
        helper(space)?.move(.node(window.node), parent: .node(parent), before: next.map { .node($0) })
    }

    func restoreHostTerminal(_ terminal: UUID, generation: UUID) {
        guard let placement = hostPlacements[terminal], placement.generation == generation else { return }
        hostPlacements[terminal] = nil
        if placement.original.structured { restoreHostWindow(terminal, placement: placement); return }
        guard let (s, _, _) = location(ofTab: terminal), spaces[s].id == placement.extractedSpace else { return }
        if placement.original.id == placement.extractedSpace {
            updateLayout { next in
                next.spaces[s].hostID = placement.original.hostID
                if let index = placement.originalIndex {
                    let restored = next.spaces.remove(at: s)
                    next.spaces.insert(restored, at: min(index, next.spaces.count))
                }
            }
            return
        }
        // The terminal stays separate if its origin vanished or its split was
        // rearranged. Selection/title updates are not structural changes.
        guard let origin = spaces.firstIndex(where: { $0.id == placement.original.id }),
              belongsToHost(spaces[origin], placement.original.hostID),
              let remaining = placement.remaining,
              Self.sameStructure(spaces[origin].arrangement, remaining),
              spaces[origin].splitRatios == placement.remainingRatios else {
            if spaces[s].tabs.count == 1 { updateLayout { $0.spaces[s].hostID = placement.original.hostID } }
            return
        }
        let selected = activeSurfaceID == terminal
        let chosen = updateLayout { next -> UUID? in
            guard let tab = next.detachTab(terminal),
                  let origin = next.spaces.firstIndex(where: { $0.id == placement.original.id }) else { return nil }
            if let pane = next.spaces[origin].panes.firstIndex(where: { $0.id == placement.pane }) {
                next.spaces[origin].panes[pane].tabs.insert(tab, at: min(placement.tabIndex, next.spaces[origin].panes[pane].tabs.count))
            } else if let paneIndex = placement.original.panes.firstIndex(where: { $0.id == placement.pane }) {
                next.spaces[origin].panes.insert(Pane(id: placement.pane, tabs: [tab]), at: min(paneIndex, next.spaces[origin].panes.count))
            }
            // Setting layout filters ratios, so restore the saved ratios last.
            next.spaces[origin].layout = placement.original.layout
            next.spaces[origin].preset = placement.original.preset
            next.spaces[origin].splitFractions = placement.original.splitFractions
            next.spaces[origin].splitRatios = placement.original.splitRatios
            return selected ? next.selectTab(terminal) : nil
        }
        if let chosen { selectSpace(chosen) }
    }

    static func sameStructure(_ a: PaneArrangement, _ b: PaneArrangement) -> Bool {
        a.layout == b.layout && a.panes.map { $0.tabs.map(\.id) } == b.panes.map { $0.tabs.map(\.id) }
            && a.splitFractions == b.splitFractions
    }

    /// After an authenticated identity upgrade, all terminals can change cards
    /// together without altering backend ownership or the native view IDs.
    func regroupHosts() {
        updateLayout { next in
            for s in next.spaces.indices {
                let contexts = next.spaces[s].tabs.flatMap(\.surfaceIDs).map { hosts.terminals[$0]?.host ?? .local }
                if let host = contexts.first, contexts.allSatisfy({ $0 == host }), next.spaces[s].hostID != host {
                    next.spaces[s].hostID = host
                }
            }
        }
    }
}
