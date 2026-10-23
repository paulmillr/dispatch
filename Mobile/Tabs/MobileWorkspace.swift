import Foundation
import Observation
import SwiftUI

/// What the Spaces tab needs to know about a host (the host list and its session map their records to this): its id,
/// name, tint and the system its glyph draws, its connection state, its place in the host order (HostStore's), and
/// the homes for "~" in paths (`HomePath`: `hello.account.home` and the login environment's HOME).
struct TabsHost: Identifiable, Equatable {
    let id: UUID
    var name: String
    var tint: Color
    var system: HostSystem?
    var home: String?
    /// The login environment's HOME, when the helper reports it (`hello.account.login_home`).
    var loginHome: String? = nil
    var state: SpacesHostState = .connected
    var order = 0
    /// The spaces come from the connected helper (`HostSession.topologyIsLive`); false while they are the cache's or a
    /// previous connection's, whose node ids the current helper does not know.
    var live = true
    /// "tmux" or "herdr": where the spaces come from (`HostSession.spacesMultiplexer`); nil while unknown.
    var multiplexer: String? = nil
    /// Plain SSH (`HostSession.plainSSH`, docs/ios.md: the Helper switch is off, or this connection fell back): the header
    /// marks it where the multiplexer goes, connected or not.
    var plain = false
    /// The host earlier in the list that reaches the same machine and account (`MobileComposition.sameMachine`): that one
    /// shows the spaces, this one names it.
    var sameMachine: String? = nil

    /// The rows show last-known data: the host is not connected, or its spaces are not this connection's yet.
    var stale: Bool { state != .connected || !live }

    /// The shared glyph draws from a host record; only its system matters here.
    var glyphRecord: HostRecord { HostRecord(id: id, name: name, address: name, user: "", auth: .password, system: system) }

    var homes: HomePath { HomePath(account: home, login: loginHome) }

    /// `/Users/me/src/app` as `~/src/app` (M2a, M2c, M4d, M6a), by the one rule (`HomePath`).
    func abbreviate(_ path: String?) -> String? { homes.abbreviate(path) }

    /// A typed `~/x` as the host's absolute path; the helper's `cwd` takes absolute paths.
    func expand(_ path: String) -> String { homes.expand(path) }
}

/// A tab across hosts: the host and its tmux window's or herdr tab's node key (stable across reconnects; node ids are
/// per helper connection).
struct TabRef: Hashable, Sendable, Codable {
    let host: UUID
    let key: String
}

/// A space across hosts: the host and its tmux session's or herdr workspace's node key.
struct SpaceRef: Hashable, Sendable, Codable {
    let host: UUID
    let key: String
}

/// One terminal of a tab: a tmux pane or a herdr pane. A tab without splits has one.
struct MobilePane: Identifiable, Equatable {
    /// The terminal node of this helper connection (what `terminals.attach` and Chat take).
    let id: UInt64
    let key: String
    var name: String
    var cwd: String?
    var agent: HelperTopology.Binding?
}

/// A tab: a tmux window or herdr tab with its panes. The phone shows one pane at a time: the one the phone picked in the
/// pane switcher while it exists, else the window's focused pane (a split tmux window shows its active pane; the phone
/// never creates splits).
@MainActor @Observable
final class MobileTab: Identifiable {
    let ref: TabRef
    nonisolated var id: TabRef { ref }
    private(set) var node: UInt64
    private(set) var space: SpaceRef
    private(set) var name: String
    /// Whether the user named the window; otherwise tmux names it after its program.
    private(set) var renamed: Bool
    /// herdr numbers an unnamed tab by its position ("1", "2"): its pane names it instead (ContainerTab.numbered).
    private(set) var numbered = false
    private(set) var panes: [MobilePane]
    /// The terminal the server focuses in this window.
    private(set) var focused: UInt64?
    /// The pane the phone picked in the switcher (by key, so it survives reconnects).
    private(set) var picked: String?
    /// When it last had activity: the server's own time when its helper reports one (`terminals.activity`: a tmux
    /// window's), or the last change the phone saw happen in any of its panes (between two live snapshots, or the
    /// phone's own), whichever is later; nil until one is known.
    private(set) var activity: Date?
    /// A plain SSH shell tab's state (`ShellSessions`); nil for a multiplexer's tab.
    private(set) var shell: ShellSessions.State?

    init(ref: TabRef, node: UInt64, space: SpaceRef, name: String, renamed: Bool, panes: [MobilePane], focused: UInt64?, activity: Date?) {
        self.ref = ref
        self.node = node
        self.space = space
        self.name = name
        self.renamed = renamed
        self.panes = panes
        self.focused = focused
        self.activity = activity
    }

    /// The pane the tab shows (M4a, M6a).
    var activePane: MobilePane? {
        if let picked, let pane = panes.first(where: { $0.key == picked }) { return pane }
        if let focused, let pane = panes.first(where: { $0.id == focused }) { return pane }
        return panes.first
    }

    /// The pane running an agent: the active one when it has a binding, else the first that has one.
    var agentPane: MobilePane? {
        if let active = activePane, active.agent != nil { return active }
        return panes.first { $0.agent != nil }
    }

    /// A chat tab (M2a's speech bubble disc, the Chats filter, Chat as the default segment).
    var isChat: Bool { agentPane != nil }

    /// A plain SSH shell tab (the Shell space's): no chat, no node on any server, closed on the phone.
    var isShell: Bool { shell != nil }

    /// What runs in it, when the server says so: tmux names an unrenamed window after its foreground program.
    var program: String? { renamed ? nil : name }

    var cwd: String? { activePane?.cwd }

    /// Whether its program is a login shell at a prompt, as far as the name tells (M2b: busy tabs are white).
    var atShell: Bool { program.map(Self.isShell) ?? false }

    static func isShell(_ name: String) -> Bool {
        let base = name.hasPrefix("-") ? String(name.dropFirst()) : name
        return ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "elvish", "xonsh", "pwsh"].contains(base)
    }

    /// The name it shows, by the Mac's automatic names (ContainerTab.displayLabel): a renamed tab keeps its name; else
    /// the agent's conversation title; else for a numbered herdr tab its pane's label (TerminalTab.displayLabel): the
    /// terminal's own title (`paneTitle`, OSC 0/2, when the phone has it attached, else the pane's name), or its folder
    /// when that title names the folder (a shell at its prompt) or there is none. A tmux window keeps the name tmux gives
    /// it (its program), as on the Mac.
    func label(conversation: String?, homes: HomePath, paneTitle: String? = nil) -> String {
        guard !renamed else { return name }
        if let title = TerminalTab.conversationLabel(conversation) { return title }
        guard numbered, let pane = activePane else { return name }
        let folder: String? = pane.cwd.map { cwd in
            let path = homes.abbreviate(cwd)
            return path == "/" || path == "~" ? path : (path as NSString).lastPathComponent
        }
        let title = (paneTitle ?? pane.name).trimmingCharacters(in: .whitespaces)
        if !title.isEmpty, title != name, !TerminalTab.titleNamesDirectory(title, pane.cwd ?? "") { return title }
        return folder ?? (title.isEmpty ? name : title)
    }

    func pick(_ pane: MobilePane) { if picked != pane.key { picked = pane.key } }

    fileprivate func update(node: UInt64, space: SpaceRef, name: String, renamed: Bool, numbered: Bool, panes: [MobilePane],
                            focused: UInt64?, activity: Date?) {
        if self.node != node { self.node = node }
        if self.space != space { self.space = space }
        if self.name != name { self.name = name }
        if self.renamed != renamed { self.renamed = renamed }
        if self.numbered != numbered { self.numbered = numbered }
        if self.panes != panes { self.panes = panes }
        if self.focused != focused { self.focused = focused }
        if self.activity != activity { self.activity = activity }
        if let picked, !panes.contains(where: { $0.key == picked }) { self.picked = nil }
    }

    fileprivate func touch(_ date: Date) { if activity.map({ $0 < date }) ?? true { activity = date } }

    /// A shell tab: one pane keyed by the tab's key (its presence's node), named after the tab; no folder (the terminal's
    /// own OSC 7 is the Terminal segment's subtitle).
    fileprivate func update(shell tab: ShellSessions.ShellTab, space: SpaceRef) {
        let pane = MobilePane(id: 0, key: tab.key, name: tab.label, cwd: nil, agent: nil)
        update(node: 0, space: space, name: tab.label, renamed: true, numbered: false, panes: [pane], focused: nil,
               activity: tab.activity)
        if shell != tab.state { shell = tab.state }
    }
}

/// A space: a herdr workspace or a tmux session, with its tabs in server order; or a plain SSH host's one synthetic
/// space, "Shell", whose tabs are the phone's own shells (`ShellSessions`).
@MainActor @Observable
final class MobileSpace: Identifiable {
    enum Kind: Equatable, Sendable {
        /// A multiplexer's space from the helper's topology.
        case multiplexer
        /// A plain SSH host's "Shell": no node, no backend, no multiplexer mark; New tab opens a shell.
        case plainShell
    }

    let ref: SpaceRef
    nonisolated var id: SpaceRef { ref }
    let kind: Kind
    private(set) var node: UInt64
    /// The topology's backend id this space lives in (the parent `terminals.create` takes for a new space there).
    private(set) var backend: UInt64
    private(set) var name: String
    private(set) var tabs: [MobileTab]
    /// Its directory: the workspace's own, else its first tab's.
    private(set) var cwd: String?

    /// The Shell space's key (`SpaceRef.key`) and node: no topology node has id 0.
    static let shellKey = "shell"
    static let shellNode: UInt64 = 0
    static let shellName = "Shell"

    init(ref: SpaceRef, node: UInt64, backend: UInt64, name: String, tabs: [MobileTab], cwd: String?, kind: Kind = .multiplexer) {
        self.ref = ref
        self.kind = kind
        self.node = node
        self.backend = backend
        self.name = name
        self.tabs = tabs
        self.cwd = cwd
    }

    var activity: Date? { tabs.compactMap(\.activity).max() }

    fileprivate func update(node: UInt64, backend: UInt64, name: String, tabs: [MobileTab], cwd: String?) {
        if self.node != node { self.node = node }
        if self.backend != backend { self.backend = backend }
        if self.name != name { self.name = name }
        if self.tabs.map(ObjectIdentifier.init) != tabs.map(ObjectIdentifier.init) { self.tabs = tabs }
        if self.cwd != cwd { self.cwd = cwd }
    }
}

/// One host's spaces and tabs (Phase 2), built from the helper's `HelperTopology` snapshots: herdr workspaces or tmux
/// sessions are spaces, their tabs or windows are tabs, their panes are a tab's terminals. Snapshots merge into the
/// objects already shown: an unchanged node keeps its object and no property of it is written, so rows are never
/// recreated. Detached nodes (dismissed on this connection, still running) are left out.
@MainActor @Observable
final class MobileWorkspace: Identifiable {
    private(set) var host: TabsHost
    nonisolated let id: UUID
    /// Commands need it; nil while the host is not connected (the last-known tabs stay listed).
    private(set) var client: HelperClient?
    private(set) var spaces: [MobileSpace] = []
    /// The multiplexer this host's new spaces go to (`MultiplexerChoice.choose`): the one the host follows, whose spaces
    /// it shows. Nil before detection.
    var choice: MultiplexerChoice?
    /// Every installed multiplexer a new space can go to (`MultiplexerChoice.available`), herdr first; empty before
    /// detection.
    var multiplexers: [MultiplexerChoice] = []
    /// The opt-in helper features this connection's hello accepted (`HelperSession.Info.features`).
    var features: Set<String> = []
    /// The host's recent project folders (`recentProjects`), newest first.
    var recents: [TabsRecentProject] = []
    /// How the host is reached (`TabsHostInput.mode`): plain SSH shows the Shell space and no topology.
    private(set) var mode: HostSession.Mode?

    @ObservationIgnored private let activity: TabActivityStore
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var snapshots: [UInt64: HelperTopology] = [:]
    @ObservationIgnored private var order: [UInt64] = []
    @ObservationIgnored private var tabObjects: [String: MobileTab] = [:]
    @ObservationIgnored private var spaceObjects: [String: MobileSpace] = [:]
    /// What each pane looked like in the last snapshot, to see it change.
    @ObservationIgnored private var seen: [String: PaneSignature] = [:]
    /// The backends whose last snapshot came live on this connection: a change in their next one happened just now.
    /// Whatever changed across a gap (the launch cache against the live data, a reconnect, a newly followed
    /// multiplexer) happened at a time nobody knows, so it moves no time.
    @ObservationIgnored private var watched: Set<UInt64> = []
    /// The backend whose changes the running rebuild dates (`apply` of a watched backend's snapshot).
    @ObservationIgnored private var stamping: UInt64?
    @ObservationIgnored private var waiters: [Waiter] = []
    /// Nodes a close is on its way for: hidden at once, shown again if the close fails.
    private(set) var closing: Set<UInt64> = []
    /// The phone's shell tabs on this host (`ShellSessions.tabs`), the Shell space's.
    @ObservationIgnored private var shellTabs: [ShellSessions.ShellTab] = []
    @ObservationIgnored private var shellSpaceObject: MobileSpace?
    @ObservationIgnored private var shellTabObjects: [UUID: MobileTab] = [:]
    /// The running `terminals.activity` read, the periodic one, and whether another was asked for meanwhile.
    @ObservationIgnored private var activityRead: Task<Void, Never>?
    @ObservationIgnored private var activityPoll: Task<Void, Never>?
    @ObservationIgnored private var activityAgain = false

    /// The hello feature whose operation reports the server's last-activity times.
    static let activityFeature = "terminals.activity"
    /// How often a connected host's server times are read again while its topology stays the same.
    static let activityInterval: Duration = .seconds(30)

    private struct PaneSignature: Equatable {
        let name: String
        let cwd: String?
        let agent: HelperTopology.Binding?
        let window: String
    }

    init(host: TabsHost, client: HelperClient? = nil, activity: TabActivityStore = .shared, now: @escaping () -> Date = Date.init) {
        self.host = host
        id = host.id
        self.client = client
        self.activity = activity
        self.now = now
    }

    var tabs: [MobileTab] { spaces.flatMap(\.tabs) }

    /// Plain SSH: shells instead of a helper's spaces (also while offline when the host's Helper switch is off).
    var isPlain: Bool { if case .plain = mode { true } else { false } }
    /// New tab opens a shell here now: plain SSH and connected.
    var opensShells: Bool { isPlain && host.state == .connected }
    /// Tabs can be made on the host now: through its helper, or as shells.
    var connected: Bool { client != nil || opensShells }
    /// The Shell space, while listed: on a plain host always, elsewhere while ended shell cards are left.
    var shellSpace: MobileSpace? { spaces.first { $0.kind == .plainShell } }

    /// Whether New tab can make a tab in `space` now: a shell in the Shell space, else a terminal through the helper.
    func canAddTab(to space: MobileSpace) -> Bool { space.kind == .plainShell ? opensShells : client != nil }

    /// The host's mode and shell tabs (`MobileTabs.sync`). Plain SSH drops the helper's spaces (the connection has
    /// none); the Shell space lists the shells while the host is plain, or while any are left.
    func update(mode: HostSession.Mode?, shells: [ShellSessions.ShellTab]) {
        let modeChanged = self.mode != mode
        guard modeChanged || shellTabs != shells else { return }
        if modeChanged { self.mode = mode }
        shellTabs = shells
        if isPlain, !snapshots.isEmpty {
            snapshots = [:]
            order = []
            watched = []
        }
        rebuild()
    }

    func tab(_ key: String) -> MobileTab? { tabs.first { $0.ref.key == key } }
    func space(_ key: String) -> MobileSpace? { spaces.first { $0.ref.key == key } }
    func space(of tab: MobileTab) -> MobileSpace? { spaces.first { $0.ref == tab.space } }
    func tab(containing terminal: UInt64) -> MobileTab? { tabs.first { $0.panes.contains { $0.id == terminal } } }

    func update(host: TabsHost) {
        if self.host != host { self.host = host }
        if !host.live { watched = [] }
    }

    func connect(_ client: HelperClient?) {
        if self.client !== client {
            self.client = client
            watched = []
            pollActivity()
        }
        if client == nil, !closing.isEmpty {
            closing = []
            rebuild()
        }
    }

    /// A backend's latest topology (the `topology` update of `backends.open`).
    func apply(_ topology: HelperTopology) {
        // After a reconnect the same server comes back under a new backend id (ids are per helper connection): the
        // snapshot that names the same nodes is the old view of it and gives way, so no row shows twice and every
        // row keeps its object (rows are keyed by host and node key).
        let keys = Set(topology.nodes.map(\.key))
        for (backend, previous) in snapshots where backend != topology.backend && previous.nodes.contains(where: { keys.contains($0.key) }) {
            snapshots.removeValue(forKey: backend)
            if let index = order.firstIndex(of: backend) {
                if order.contains(topology.backend) { order.remove(at: index) } else { order[index] = topology.backend }
            }
        }
        if !order.contains(topology.backend) { order.append(topology.backend) }
        snapshots[topology.backend] = topology
        stamping = host.live && watched.contains(topology.backend) ? topology.backend : nil
        rebuild()
        stamping = nil
        if host.live { watched.insert(topology.backend) } else { watched = [] }
        // A live snapshot names this connection's nodes: their server times can be read now.
        scheduleActivity()
    }

    /// A backend the helper no longer serves (its open ended).
    func remove(backend: UInt64) {
        guard snapshots.removeValue(forKey: backend) != nil else { return }
        order.removeAll { $0 == backend }
        watched.remove(backend)
        rebuild()
    }

    /// Something happened in a terminal that the topology does not show (output, an agent's state).
    func noteActivity(terminal: UInt64, at date: Date? = nil) {
        guard let tab = tab(containing: terminal), let pane = tab.panes.first(where: { $0.id == terminal }) else { return }
        let date = date ?? now()
        activity.note(host: host.id, key: pane.key, at: date)
        tab.touch(date)
    }

    /// Reads the server's last-activity times (`terminals.activity`) into the activity store, by topology key, and shows
    /// them. Nothing is asked of a helper without the feature (too old: the rows keep only what the phone saw), a host
    /// not connected, or spaces that are not this connection's yet. False when nothing was read.
    @discardableResult
    func refreshActivity() async -> Bool {
        guard features.contains(Self.activityFeature), let client, host.live else { return false }
        guard let rows = try? await TabCommands(client: client).serverActivity(), self.client === client else { return false }
        applyServerActivity(rows)
        return true
    }

    /// Server times by topology key: a tab's own (a tmux window) or one of its panes'. Kept in the store, so the next
    /// launch shows them before the host connects.
    func applyServerActivity(_ rows: [TabsServerActivity]) {
        for row in rows where row.time_ms > 0 {
            activity.note(host: host.id, key: row.key, at: row.time)
            tabs.first { $0.ref.key == row.key || $0.panes.contains { $0.key == row.key } }?.touch(row.time)
        }
    }

    /// One read at a time; asked again while one runs, it runs once more after it.
    private func scheduleActivity() {
        guard features.contains(Self.activityFeature), client != nil, host.live else { return }
        guard activityRead == nil else {
            activityAgain = true
            return
        }
        activityRead = Task { [weak self] in
            repeat {
                self?.activityAgain = false
                await self?.refreshActivity()
            } while self?.activityAgain == true
            self?.activityRead = nil
        }
    }

    /// While connected, the times are read every `activityInterval`: output moves them without changing the topology.
    private func pollActivity() {
        activityPoll?.cancel()
        activityPoll = nil
        guard client != nil else { return }
        activityPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.activityInterval)
                guard !Task.isCancelled, let self else { return }
                self.scheduleActivity()
            }
        }
    }

    /// The tabs a close request is pending for leave the lists at once.
    func hide(_ node: UInt64) {
        guard closing.insert(node).inserted else { return }
        rebuild()
    }
    func reveal(_ node: UInt64) {
        guard closing.remove(node) != nil else { return }
        rebuild()
    }

    private func rebuild() {
        var spaces: [MobileSpace] = []
        var liveTabs: Set<String> = [], liveSpaces: Set<String> = []
        var signatures: [String: PaneSignature] = [:]
        let stamp = now()
        for backend in order {
            guard let topology = snapshots[backend] else { continue }
            let nodes = Dictionary(topology.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var children: [UInt64: [HelperTopology.Node]] = [:]
            var roots: [HelperTopology.Node] = []
            for node in topology.nodes where !node.detached {
                if let parent = node.parent, nodes[parent] != nil { children[parent, default: []].append(node) } else { roots.append(node) }
            }
            let layouts = Dictionary(topology.layouts.map { ($0.container, $0) }, uniquingKeysWith: { first, _ in first })

            func terminals(under node: HelperTopology.Node) -> [HelperTopology.Node] {
                (children[node.id] ?? []).flatMap { $0.kind == .terminal ? [$0] : terminals(under: $0) }
            }
            func leaves(_ split: HelperTopology.Split) -> [UInt64] {
                switch split {
                case .leaf(let id): [id]
                case .branch(_, _, let children): children.flatMap { leaves($0.split) }
                }
            }
            /// The terminal a container's focus leads to.
            func focus(of container: UInt64, depth: Int = 0) -> UInt64? {
                guard depth < 16, let id = layouts[container]?.focus else { return nil }
                return nodes[id]?.kind == .terminal ? id : focus(of: id, depth: depth + 1)
            }

            func makeTab(window: HelperTopology.Node, panes found: [HelperTopology.Node], space: SpaceRef) -> MobileTab {
                // Panes in the window's layout order (left to right, top to bottom), then any the layout does not name.
                let laid = layouts[window.id].map { leaves($0.full) } ?? []
                let ordered = laid.compactMap { id in found.first { $0.id == id } } + found.filter { !laid.contains($0.id) }
                let panes = ordered.map { MobilePane(id: $0.id, key: $0.key, name: $0.name, cwd: $0.cwd, agent: $0.agent) }
                var latest: Date?
                for pane in panes {
                    let signature = PaneSignature(name: pane.name, cwd: pane.cwd, agent: pane.agent, window: window.name)
                    signatures[pane.key] = signature
                    // A change between two live snapshots, or a pane that appeared between them, is activity now.
                    if backend == stamping, let before = seen[pane.key], before != signature {
                        activity.note(host: host.id, key: pane.key, at: stamp)
                    } else if backend == stamping, seen[pane.key] == nil, activity.date(host: host.id, key: pane.key) == nil {
                        activity.note(host: host.id, key: pane.key, at: stamp)
                    }
                    if let date = activity.date(host: host.id, key: pane.key), latest.map({ $0 < date }) ?? true { latest = date }
                }
                // The server's own time for the tab (`terminals.activity`, kept by its key).
                if let date = activity.date(host: host.id, key: window.key), latest.map({ $0 < date }) ?? true { latest = date }
                let focused = focus(of: window.id) ?? topology.focus.flatMap { id in panes.contains { $0.id == id } ? id : nil }
                let ref = TabRef(host: host.id, key: window.key)
                liveTabs.insert(window.key)
                let renamed = window.kind == .terminal ? true : window.renamed == true
                let numbered = host.multiplexer == "herdr" && !renamed
                if let tab = tabObjects[window.key] {
                    tab.update(node: window.id, space: space, name: window.name, renamed: renamed, numbered: numbered, panes: panes,
                               focused: focused, activity: latest)
                    return tab
                }
                let tab = MobileTab(ref: ref, node: window.id, space: space, name: window.name, renamed: renamed, panes: panes,
                                    focused: focused, activity: latest)
                tab.update(node: window.id, space: space, name: window.name, renamed: renamed, numbered: numbered, panes: panes,
                           focused: focused, activity: latest)
                tabObjects[window.key] = tab
                return tab
            }

            func makeSpace(_ workspace: HelperTopology.Node) {
                let ref = SpaceRef(host: host.id, key: workspace.key)
                var tabs: [MobileTab] = []
                for child in children[workspace.id] ?? [] {
                    switch child.kind {
                    case .tab: tabs.append(makeTab(window: child, panes: terminals(under: child), space: ref))
                    // A terminal straight under a workspace is a tab of its own.
                    case .terminal: tabs.append(makeTab(window: child, panes: [child], space: ref))
                    case .workspace: makeSpace(child)
                    }
                }
                tabs.removeAll { closing.contains($0.node) }
                guard !closing.contains(workspace.id) else { return }
                liveSpaces.insert(workspace.key)
                let cwd = workspace.cwd ?? tabs.first?.cwd
                if let space = spaceObjects[workspace.key] {
                    space.update(node: workspace.id, backend: topology.backend, name: workspace.name, tabs: tabs, cwd: cwd)
                    spaces.append(space)
                } else {
                    let space = MobileSpace(ref: ref, node: workspace.id, backend: topology.backend, name: workspace.name, tabs: tabs, cwd: cwd)
                    spaceObjects[workspace.key] = space
                    spaces.append(space)
                }
            }

            for root in roots where root.kind == .workspace { makeSpace(root) }
        }
        if let shell = rebuildShellSpace() { spaces.append(shell) }
        tabObjects = tabObjects.filter { liveTabs.contains($0.key) }
        spaceObjects = spaceObjects.filter { liveSpaces.contains($0.key) }
        seen = signatures
        if self.spaces.map(ObjectIdentifier.init) != spaces.map(ObjectIdentifier.init) { self.spaces = spaces }
        resumeWaiters()
    }

    /// The Shell space from `shellTabs`, keeping its objects; nil while it is not listed.
    private func rebuildShellSpace() -> MobileSpace? {
        guard isPlain || !shellTabs.isEmpty else {
            shellSpaceObject = nil
            shellTabObjects = [:]
            return nil
        }
        let ref = SpaceRef(host: host.id, key: MobileSpace.shellKey)
        let tabs = shellTabs.map { shell -> MobileTab in
            let tab = shellTabObjects[shell.id] ?? MobileTab(ref: TabRef(host: host.id, key: shell.key), node: 0, space: ref,
                                                             name: shell.label, renamed: true, panes: [], focused: nil,
                                                             activity: shell.activity)
            tab.update(shell: shell, space: ref)
            return tab
        }
        shellTabObjects = Dictionary(uniqueKeysWithValues: zip(shellTabs.map(\.id), tabs))
        if let space = shellSpaceObject {
            space.update(node: MobileSpace.shellNode, backend: 0, name: MobileSpace.shellName, tabs: tabs, cwd: nil)
            return space
        }
        let space = MobileSpace(ref: ref, node: MobileSpace.shellNode, backend: 0, name: MobileSpace.shellName, tabs: tabs,
                                cwd: nil, kind: .plainShell)
        shellSpaceObject = space
        return space
    }

    @MainActor private final class Waiter {
        let terminal: UInt64
        var continuation: CheckedContinuation<MobileTab?, Never>?
        init(terminal: UInt64) { self.terminal = terminal }
        func resume(_ tab: MobileTab?) {
            continuation?.resume(returning: tab)
            continuation = nil
        }
    }

    /// The tab a created terminal shows up in, once a live topology names it (a stale one's ids are another helper's);
    /// nil after `timeout`.
    func tab(for terminal: UInt64, timeout: Duration = .seconds(10)) async -> MobileTab? {
        if host.live, let tab = tab(containing: terminal) { return tab }
        let waiter = Waiter(terminal: terminal)
        waiters.append(waiter)
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            waiter.resume(nil)
            self?.waiters.removeAll { $0 === waiter }
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            if host.live, let tab = tab(containing: terminal) {
                continuation.resume(returning: tab)
                waiters.removeAll { $0 === waiter }
            } else {
                waiter.continuation = continuation
            }
        }
    }

    private func resumeWaiters() {
        guard host.live else { return }
        for waiter in waiters {
            if let tab = tab(containing: waiter.terminal) { waiter.resume(tab) }
        }
        waiters.removeAll { $0.continuation == nil }
    }
}
