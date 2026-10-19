import Foundation
import Observation

/// One host as the Tabs area takes it from its host session (docs/ios.md, Areas and seams): identity, the connected client
/// (nil while not connected), the latest topology, and the host's multiplexer override.
struct TabsHostInput {
    var host: TabsHost
    var client: HelperClient?
    var topology: HelperTopology?
    /// "herdr" or "tmux" when the host's record overrides the preference.
    var multiplexer: String? = nil
    /// The helper features the hello accepted (`projects.recent`, `multiplexers.versions`, …).
    var features: Set<String> = []
}

/// Every host's workspace for the Tabs section, plus what other areas inject: per-terminal urgency (Chat owns it) and
/// the line a chat row shows ("fable-5.1 · thinking 48s").
@MainActor @Observable
final class MobileTabs {
    private(set) var workspaces: [MobileWorkspace] = []
    var query: TabsQuery {
        didSet { if query != oldValue { saveQuery() } }
    }
    var tree: Bool {
        didSet { if tree != oldValue { defaults.set(tree, forKey: Self.treeKey) } }
    }
    /// The space New tab goes to (the last one opened on the phone, else the most active).
    private(set) var recent: SpaceRef?

    /// (host, terminal) → how much it wants attention. Chat sets it; nil means idle or read.
    @ObservationIgnored var urgency: @MainActor (UUID, UInt64) -> TabUrgency? = { _, _ in nil }
    /// (host, terminal) → what a chat tab is doing, for line two of its row. Chat sets it.
    @ObservationIgnored var status: @MainActor (UUID, UInt64) -> String? = { _, _ in nil }
    /// (host, terminal) → when an agent's conversation last moved (its newest record, the time Agents shows). Chat sets
    /// it; a chat tab's time is the later of this and the last change the phone saw in the tab.
    @ObservationIgnored var agentActivity: @MainActor (UUID, UInt64) -> Date? = { _, _ in nil }
    /// (host, multiplexer name) → the host follows that multiplexer from now on (its saved preference, as Host detail
    /// sets it): New space on another multiplexer than the one shown. The composition sets it.
    @ObservationIgnored var follow: @MainActor (UUID, String) -> Void = { _, _ in }

    @ObservationIgnored private let activity: TabActivityStore
    @ObservationIgnored private let defaults: UserDefaults
    /// The per-host values (recent space, collapsed sections, space order), out of UserDefaults and backups.
    @ObservationIgnored let deviceState: SpacesDeviceState
    @ObservationIgnored private var detecting: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var topologies: [UUID: HelperTopology] = [:]
    /// The multiplexer each host's detection last ran for (a new choice detects again).
    @ObservationIgnored private var detected: [UUID: String?] = [:]

    /// The menu and the tree toggle name no host: they stay in UserDefaults with the other preferences.
    private static let queryKey = "tabs.query", treeKey = "tabs.tree"

    /// `deviceState` nil: the app's file with `.standard` defaults (an older build's values move there), else in memory.
    init(activity: TabActivityStore = .shared, defaults: UserDefaults = .standard, deviceState: SpacesDeviceState? = nil) {
        self.activity = activity
        self.defaults = defaults
        self.deviceState = deviceState ?? (defaults == .standard ? .shared : SpacesDeviceState(url: nil, migrating: defaults))
        query = defaults.data(forKey: Self.queryKey).flatMap { try? JSONDecoder().decode(TabsQuery.self, from: $0) } ?? TabsQuery()
        tree = defaults.bool(forKey: Self.treeKey)
        recent = self.deviceState.recent
        collapsed = self.deviceState.collapsed
        spaceOrder = self.deviceState.spaceOrder
    }

    /// The integration point: called whenever a host session changes. Workspaces keep their identity per host; a
    /// connected client is (re)detected for the multiplexer choice.
    func sync(_ hosts: [TabsHostInput]) {
        var next: [MobileWorkspace] = []
        for input in hosts {
            let workspace = workspaces.first { $0.id == input.host.id }
                ?? MobileWorkspace(host: input.host, client: nil, activity: activity)
            workspace.update(host: input.host)
            if workspace.features != input.features { workspace.features = input.features }
            let reconnected = workspace.client !== input.client
            workspace.connect(input.client)
            if let topology = input.topology, topologies[input.host.id] != topology {
                let previous = topologies[input.host.id]
                topologies[input.host.id] = topology
                // Applied first: a snapshot naming the same nodes under a new backend id (a reconnect, or the live data
                // after the cached) replaces the old one in place, so every row keeps its object. Whatever is left of the
                // old backend (another multiplexer's) goes after.
                workspace.apply(topology)
                if let previous, previous.backend != topology.backend { workspace.remove(backend: previous.backend) }
            } else if input.topology == nil, input.client != nil, let previous = topologies.removeValue(forKey: input.host.id) {
                // Connected without a snapshot: the followed multiplexer changed to one with no server yet.
                workspace.remove(backend: previous.backend)
            }
            let multiplexerChanged = detected[input.host.id].map { $0 != input.multiplexer } ?? false
            if reconnected || multiplexerChanged, input.client != nil {
                detected[input.host.id] = .some(input.multiplexer)
                detecting[input.host.id]?.cancel()
                let override = input.multiplexer
                detecting[input.host.id] = Task { [weak workspace] in
                    _ = try? await workspace?.detect(override: override)
                    // Ready before New space opens, so its folders are there from the first frame.
                    await workspace?.recentProjects()
                }
            }
            next.append(workspace)
        }
        next = next.enumerated().sorted { a, b in
            a.element.host.order != b.element.host.order ? a.element.host.order < b.element.host.order : a.offset < b.offset
        }.map(\.element)
        let removed = Set(workspaces.map(\.id)).subtracting(next.map(\.id))
        for id in removed {
            detecting.removeValue(forKey: id)?.cancel()
            topologies.removeValue(forKey: id)
            detected.removeValue(forKey: id)
        }
        if workspaces.map(ObjectIdentifier.init) != next.map(ObjectIdentifier.init) { workspaces = next }
    }

    /// Host sections the user collapsed (M2b's disclosure), kept on the device.
    private(set) var collapsed: Set<UUID> = []
    /// The phone's order of each host's spaces (M1e's drag handles), by space key; spaces it does not name follow in
    /// server order. Kept on the device: the servers have no order of their own to change.
    private(set) var spaceOrder: [UUID: [String]] = [:]

    func toggle(_ host: UUID) {
        if collapsed.remove(host) == nil { collapsed.insert(host) }
        deviceState.collapsed = collapsed
    }

    /// A host's spaces in the phone's order.
    func orderedSpaces(_ workspace: MobileWorkspace) -> [MobileSpace] {
        let order = spaceOrder[workspace.id] ?? []
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return workspace.spaces.enumerated().sorted { a, b in
            switch (rank[a.element.ref.key], rank[b.element.ref.key]) {
            case let (x?, y?): x < y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Drag in M1e: spaces stay within their host. The offsets count the rows shown (`visible`, the space keys a filter
    /// left, in order; nil: all of them): the moved rows take the shown rows' places and hidden spaces keep theirs.
    func moveSpaces(of host: UUID, visible: [String]? = nil, from source: IndexSet, to destination: Int) {
        guard let workspace = workspace(host) else { return }
        var keys = orderedSpaces(workspace).map(\.ref.key)
        var shown = visible ?? keys
        let slots = keys.indices.filter { shown.contains(keys[$0]) }
        guard slots.count == shown.count else { return }
        shown.move(fromOffsets: source, toOffset: destination)
        for (slot, key) in zip(slots, shown) { keys[slot] = key }
        spaceOrder[host] = keys
        deviceState.spaceOrder = spaceOrder
    }

    /// Drag in M1e: a dragged host lands before `target` (or last); the list follows at once and the new order goes to
    /// the host store (`actions`).
    func moveHost(_ id: UUID, before target: UUID?, actions: SpacesHostActions) {
        var ids = workspaces.map(\.id).filter { $0 != id }
        guard ids.count + 1 == workspaces.count else { return }
        ids.insert(id, at: target.flatMap { ids.firstIndex(of: $0) } ?? ids.endIndex)
        guard ids != workspaces.map(\.id) else { return }
        applyHostOrder(ids)
        actions.reorderHosts(ids)
    }

    /// The hosts in this order until the next sync brings the store's.
    func applyHostOrder(_ ids: [UUID]) {
        let next = ids.compactMap(workspace) + workspaces.filter { !ids.contains($0.id) }
        for (index, workspace) in next.enumerated() where workspace.host.order != index {
            var host = workspace.host
            host.order = index
            workspace.update(host: host)
        }
        if workspaces.map(ObjectIdentifier.init) != next.map(ObjectIdentifier.init) { workspaces = next }
    }

    /// A removed host leaves the list at once (its store removal follows).
    func dropHost(_ id: UUID) {
        workspaces.removeAll { $0.id == id }
        detecting.removeValue(forKey: id)?.cancel()
        topologies.removeValue(forKey: id)
        detected.removeValue(forKey: id)
        activity.forget(host: id)
        if spaceOrder.removeValue(forKey: id) != nil { deviceState.spaceOrder = spaceOrder }
        if collapsed.remove(id) != nil { deviceState.collapsed = collapsed }
        if recent?.host == id {
            recent = nil
            deviceState.recent = nil
        }
    }

    /// M2b: every host as a section (hosts are managed here too), its spaces in the phone's order; the filter keeps the
    /// spaces with a matching tab. A space's count is its tabs that need you or hold an unseen result (Mail's unread);
    /// a collapsed section shows the sum.
    var sections: [SpacesSection] {
        workspaces.map { workspace in
            let rows = orderedSpaces(workspace).compactMap { space -> SpacesSpaceRow? in
                let entries = space.tabs.map { entry($0, space: space, host: workspace.host) }
                guard query.filter == .all || entries.contains(where: { $0.matches(query.filter) }) else { return nil }
                return SpacesSpaceRow(space: space, unread: entries.filter { $0.urgency?.unread == true }.count,
                                      working: entries.contains { $0.urgency == .working }, id: space.ref)
            }
            return SpacesSection(host: workspace.host, spaces: rows, unread: rows.map(\.unread).reduce(0, +),
                                 collapsed: collapsed.contains(workspace.id))
        }
    }

    /// New space (M7a's Create, and the quick menu's entries) on `multiplexer` (nil: the one the host shows): its first
    /// tab once the host shows it. Another multiplexer than the one shown becomes the host's (`follow`).
    func createSpace(on host: UUID, name: String, directory: String?, multiplexer: MultiplexerChoice? = nil) async throws -> MobileTab {
        guard let workspace = workspace(host) else { throw TabsFailure.disconnected }
        // Not detected yet (just connected): where the host's spaces are, as `sync` would detect it.
        if workspace.choice == nil { try await workspace.detect(override: detected[host] ?? nil) }
        let follow = follow
        return try await workspace.createSpace(name: name, directory: directory, on: multiplexer, follow: { follow(host, $0) })
    }

    /// Adds a workspace directly (previews, tests).
    func insert(_ workspace: MobileWorkspace) {
        workspaces.removeAll { $0.id == workspace.id }
        workspaces.append(workspace)
    }

    func workspace(_ host: UUID) -> MobileWorkspace? { workspaces.first { $0.id == host } }
    func tab(_ ref: TabRef) -> MobileTab? { workspace(ref.host)?.tab(ref.key) }
    func space(_ ref: SpaceRef) -> MobileSpace? { workspace(ref.host)?.space(ref.key) }

    /// A tab's urgency: its most urgent pane's.
    func urgency(of tab: MobileTab) -> TabUrgency? { tab.panes.compactMap { urgency(tab.ref.host, $0.id) }.max() }
    func urgency(of space: MobileSpace) -> TabUrgency? { space.tabs.compactMap { urgency(of: $0) }.max() }

    /// A tab's time (its row's, and the Activity sort's): the server's last-activity time for it (`terminals.activity`,
    /// tmux windows) or the last change the phone saw in it live, whichever is later, and for a chat tab its agent's
    /// newest record when that is later still. Nil until one is known: the topology carries no times, and a helper too
    /// old for the feature (or herdr, which keeps none) leaves only what the phone saw.
    func activity(of tab: MobileTab) -> Date? {
        let agent = tab.panes.filter { $0.agent != nil }.compactMap { agentActivity(tab.ref.host, $0.id) }.max()
        return [tab.activity, agent].compactMap { $0 }.max()
    }
    func activity(of space: MobileSpace) -> Date? { space.tabs.compactMap { activity(of: $0) }.max() }

    private func entry(_ tab: MobileTab, space: MobileSpace?, host: TabsHost) -> TabsEntry {
        TabsEntry(tab: tab, space: space, host: host, urgency: urgency(of: tab), activity: activity(of: tab))
    }

    /// Chat's count of conversations waiting for the user, but `excluding`'s (the back pill); nil: counted from the rows.
    @ObservationIgnored var needsYouCount: (@MainActor (TabRef?) -> Int)?

    /// Waiting conversations everywhere but `excluding` (the back pill's count, as Messages counts unread elsewhere).
    func needsYou(excluding: TabRef? = nil) -> Int {
        if let needsYouCount { return needsYouCount(excluding) }
        return workspaces.flatMap(\.tabs).filter { $0.ref != excluding && urgency(of: $0) == .needsYou }.count
    }

    var entries: [TabsEntry] {
        workspaces.flatMap { workspace in
            workspace.spaces.flatMap { space in
                space.tabs.map { entry($0, space: space, host: workspace.host) }
            }
        }
    }

    /// M2a's rows.
    var rows: [TabsEntry] { TabsOrdering.query(entries, query) }

    /// M2b's rows: spaces with at least one tab the filter shows (all of them unfiltered).
    var spaceRows: [(space: MobileSpace, host: TabsHost)] {
        let spaces = workspaces.flatMap { workspace in
            workspace.spaces.map { (space: $0, host: workspace.host) }
        }.filter { item in
            query.filter == .all || item.space.tabs.contains { tab in
                entry(tab, space: item.space, host: item.host).matches(query.filter)
            }
        }
        return TabsOrdering.sorted(spaces: spaces, by: query.sort, activity: activity(of:))
    }

    /// M2c's rows: a space's tabs under the same menu.
    func rows(in space: MobileSpace) -> [TabsEntry] {
        guard let host = workspace(space.ref.host)?.host else { return [] }
        return TabsOrdering.query(space.tabs.map { entry($0, space: space, host: host) }, query)
    }

    /// The segment each tab showed last in this run (Create and New tab open theirs in Terminal).
    @ObservationIgnored var segments: [TabRef: TabSegment] = [:]

    /// The space New tab uses: the last one opened while it exists on a connected host, else the most active one.
    var recentSpace: MobileSpace? {
        let connected = workspaces.filter { $0.client != nil }
        if let recent, let space = connected.first(where: { $0.id == recent.host })?.space(recent.key) { return space }
        return connected.flatMap(\.spaces).max { a, b in (activity(of: a) ?? .distantPast) < (activity(of: b) ?? .distantPast) }
    }

    func visited(_ space: SpaceRef) {
        guard recent != space else { return }
        recent = space
        deviceState.recent = space
    }

    /// Settings' Remove all data: the per-host values go (the menu and the tree toggle stay, as appearance does).
    func removeDeviceState() {
        deviceState.removeAll()
        for key in SpacesDeviceState.legacyKeys { defaults.removeObject(forKey: key) }
        recent = nil
        collapsed = []
        spaceOrder = [:]
    }

    private func saveQuery() { defaults.set(try? JSONEncoder().encode(query), forKey: Self.queryKey) }
}
