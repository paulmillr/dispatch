import Foundation

/// A `multiplexers.list` row. With the `multiplexers.versions` hello feature (helper/PROTOCOL.md, Features) it also
/// says whether the program is installed, its version, and for tmux whether it reports bracketed-paste state (3.7
/// and later); a helper or client without the feature leaves them out. Newer helpers add `running` under the same
/// feature: whether the multiplexer's server runs for this account (absent: ask `stats.processes`).
struct TabsMultiplexer: Decodable, Equatable, Sendable {
    let mux: UInt64
    let name: String
    let external: Bool
    var program: String? = nil
    var installed: Bool? = nil
    var version: String? = nil
    var paste_state: Bool? = nil
    var running: Bool? = nil
}

/// The multiplexer a host's new spaces go to (plan 3.2): herdr when the host has it (its workspaces and tabs map one to
/// one onto spaces and tabs), else tmux, unless the host's record overrides it by name. Only server-owned multiplexers
/// count (`external`), installed (when the helper says) and with a backend: the helper's native one dies with the SSH
/// connection.
struct MultiplexerChoice: Equatable, Sendable {
    let mux: UInt64
    /// "herdr" or "tmux", as `multiplexers.list` names it (Host detail's line, the per-host override).
    let name: String
    let route: HelperBackend.Route
    /// "0.9.3", "3.7" when the helper reports versions (Host detail's "herdr 0.9.3" line).
    var version: String? = nil
    /// The Mac's warning for a tmux older than 3.7, else nil.
    var warning: String? = nil

    static let preference = ["herdr", "tmux"]

    /// The text the helper gives (and the Mac's Chat shows) when a tmux server cannot report bracketed-paste state.
    static let tmuxWarning = "This tmux server cannot report bracketed-paste state. Use the terminal to send input."

    static func choose(multiplexers: [TabsMultiplexer], backends: [HelperBackend], override: String? = nil) -> MultiplexerChoice? {
        let ranked = available(multiplexers: multiplexers, backends: backends)
        return override.flatMap { name in ranked.first { $0.name == name } } ?? ranked.first
    }

    /// Every multiplexer a new space can go to (New space's Multiplexer), herdr first. The helper's native one is never
    /// offered: its sessions belong to the helper, which ends with the phone's connection (every trip to the
    /// background), and Spaces never lists them.
    static func available(multiplexers: [TabsMultiplexer], backends: [HelperBackend]) -> [MultiplexerChoice] {
        multiplexers.filter { $0.external && $0.installed != false }
            .sorted { rank($0.name) < rank($1.name) }
            .compactMap { kind in
                let candidates = backends.filter { $0.mux == kind.mux }
                guard let backend = candidates.first(where: { $0.isDefault == true }) ?? candidates.first else { return nil }
                // The helper's own answer first; a version alone (older feature rows) is read the same way.
                let pasteState = kind.paste_state ?? kind.version.map(tmuxSupported)
                let warning = kind.name == "tmux" && pasteState == false ? tmuxWarning : nil
                return MultiplexerChoice(mux: kind.mux, name: kind.name, route: backend.route, version: kind.version, warning: warning)
            }
    }

    private static func rank(_ name: String) -> Int { preference.firstIndex(of: name) ?? preference.count }

    /// tmux 3.7 and later report bracketed-paste state ("3.7", "3.7a", "next-3.8"; an unreadable version counts as able).
    static func tmuxSupported(_ version: String) -> Bool {
        let trimmed = version.hasPrefix("tmux ") ? String(version.dropFirst(5)) : version
        let digits = trimmed.drop { !$0.isNumber }
        let parts = digits.split(separator: ".", maxSplits: 1)
        guard let major = parts.first.flatMap({ Int($0) }) else { return true }
        let minor = parts.count > 1 ? Int(parts[1].prefix { $0.isNumber }) ?? 0 : 0
        return (major, minor) >= (3, 7)
    }
}

/// A `projects.recent` row (the `projects.recent` hello feature): a folder the host's agents worked in, newest first,
/// from their own session stores. Fields beyond the path are optional so an older reply still parses.
struct TabsRecentProject: Decodable, Equatable, Sendable {
    let path: String
    var time_ms: UInt64? = nil
    var agents: [String]? = nil
    var exists: Bool? = nil

    enum CodingKeys: String, CodingKey { case path, time_ms, agents, exists }

    init(path: String, time_ms: UInt64? = nil, agents: [String]? = nil, exists: Bool? = nil) {
        self.path = path
        self.time_ms = time_ms
        self.agents = agents
        self.exists = exists
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        path = try fields.decode(String.self, forKey: .path)
        time_ms = try? fields.decodeIfPresent(UInt64.self, forKey: .time_ms)
        agents = try? fields.decodeIfPresent([String].self, forKey: .agents)
        exists = try? fields.decodeIfPresent(Bool.self, forKey: .exists)
    }

    var time: Date? { time_ms.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
}

/// A `terminals.activity` row (the `terminals.activity` hello feature): when the server last saw activity in a node of
/// the topology, by its key (node ids are per connection). tmux reports its windows (`#{window_activity}`, whole
/// seconds); herdr reports nothing.
struct TabsServerActivity: Decodable, Equatable, Sendable {
    let node: UInt64
    let key: String
    let time_ms: UInt64

    var time: Date { Date(timeIntervalSince1970: Double(time_ms) / 1000) }
}

/// The three ways to close, with the Mac's names (its tab and space menus: Close Tab, Detach, Terminate…).
enum TabsClose: Equatable, Sendable {
    /// Close Tab: terminate only when every pane is verified idle, else detach. A space always detaches, as on the Mac
    /// (docs/integrations.md: "Close space, Detach, and quit always detach").
    case close
    /// Keep the work running on the server; the tab leaves this connection's lists.
    case detach
    /// End the windows or panes and the processes running inside them (asks first, as the Mac does).
    case terminate
}

enum TabsCloseOutcome: Equatable, Sendable {
    case terminated, detached
}

/// The Mac's confirmation for Terminate (AppDelegate.confirmTermination), word for word.
enum TabsTerminateCopy {
    static func title(tab name: String) -> String { "Terminate tab “\(name)”?" }
    static func title(space name: String) -> String { "Terminate space “\(name)”?" }
    static let message = "This ends its server windows or panes and the processes running inside them. To keep work running, use Detach."
    static let confirm = "Terminate"
}

/// The Tabs area's operations on a host's helper. Stateless: each call is one or a few requests on `client`.
struct TabCommands: Sendable {
    let client: HelperClient

    /// `multiplexers.list` and `backends.list`, enqueued together.
    func detect() async throws -> (multiplexers: [TabsMultiplexer], backends: [HelperBackend]) {
        async let kinds: [TabsMultiplexer] = client.connection.request("multiplexers.list", params: [String: String]())
        async let backends = client.backends()
        return try await (kinds, backends)
    }

    /// `backends.open`: the backend's id; its `topology` updates go to `topology` until the request is cancelled.
    func open(_ route: HelperBackend.Route, topology: @escaping @Sendable (HelperTopology) -> Void,
              ended: @escaping @Sendable (any Error) -> Void = { _ in }) async throws -> UInt64 {
        try await client.open(route) { result in
            switch result {
            case .success(.topology(let value)): topology(value)
            case .success: break
            case .failure(let error): ended(error)
            }
        }
    }

    /// `projects.recent {limit}` (needs the `projects.recent` hello feature).
    func recentProjects(limit: Int = 30) async throws -> [TabsRecentProject] {
        struct Limit: Encodable { let limit: Int }
        return try await client.connection.request("projects.recent", params: Limit(limit: limit))
    }

    /// `terminals.activity {}` (needs the `terminals.activity` hello feature). A row this build cannot read is left out.
    func serverActivity() async throws -> [TabsServerActivity] {
        let rows: [Lenient<TabsServerActivity>] = try await client.connection.request("terminals.activity", params: [String: String]())
        return rows.compactMap(\.value)
    }

    /// `backends.create`: makes sure the multiplexer's server is up and returns its backend id.
    func createBackend(_ route: HelperBackend.Route) async throws -> UInt64 {
        try await client.create(route)
    }

    /// `terminals.create` under `parent`: a backend id makes a new space (herdr workspace, tmux session), a space node
    /// a new tab in it. The phone never creates splits (`beside` stays nil).
    func createTerminal(parent: UInt64, cwd: String?) async throws -> UInt64 {
        try await client.create(HelperClient.Create(parent: parent, beside: nil, cwd: cwd, launch: nil))
    }

    /// `memberships.place` of a new terminal's tab into a new space labelled `space`, once the topology shows the tab.
    @MainActor
    func place(terminal: UInt64, space: String, in workspace: MobileWorkspace, timeout: Duration) async throws {
        guard let tab = await workspace.tab(for: terminal, timeout: timeout) else {
            throw TabsFailure(message: "The space was created, but the host has not shown it yet.")
        }
        try await client.place(HelperClient.Placement(node: tab.node, place: .init(kind: "workspace", label: space)))
    }

    /// `entities.rename` of a space or tab.
    func rename(_ node: UInt64, to name: String) async throws {
        try await client.rename(HelperClient.Rename(node: node, name: name))
    }

    /// `close.request` with the Mac's policy. Closing a space detaches it. Closing a tab asks the helper first (`check`,
    /// nothing changes): when every pane is verified idle the tab is terminated through `prompt`, which re-verifies on
    /// the server and detaches what turned busy in between; otherwise, or when the check is unavailable, it is detached
    /// and its work keeps running.
    func close(_ node: UInt64, _ how: TabsClose, space: Bool = false) async throws -> TabsCloseOutcome {
        switch how {
        case .close where space, .detach:
            _ = try await client.close(.init(node: node, policy: .detach))
            return .detached
        case .terminate:
            _ = try await client.close(.init(node: node, policy: .terminate))
            return .terminated
        case .close:
            let idle: Bool
            do {
                let checked = try await client.close(.init(node: node, policy: .prompt, check: true))
                idle = !checked.closed && !checked.confirmation
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Inspection unavailable (an older multiplexer, a lost server): keep the work.
                idle = false
            }
            guard idle else {
                _ = try await client.close(.init(node: node, policy: .detach))
                return .detached
            }
            let closed = try await client.close(.init(node: node, policy: .prompt))
            guard closed.confirmation else { return .terminated }
            _ = try await client.close(.init(node: node, policy: .detach))
            return .detached
        }
    }
}

/// What failed, for the alert a screen shows.
struct TabsFailure: Error, Equatable, LocalizedError {
    let message: String
    var errorDescription: String? { message }
    static let disconnected = TabsFailure(message: "The host is not connected.")
    /// Connected, but its spaces are still the last-known ones (their ids are not this connection's).
    static let loading = TabsFailure(message: "The host's spaces are still loading. Try again in a moment.")
    static let noMultiplexer = TabsFailure(message: "This host has neither herdr nor tmux. Install one to keep spaces running.")
}

extension MobileWorkspace {
    /// The commands on this connection; `nodes`: the request names node ids from the spaces shown, which must then be
    /// this connection's (`TabsHost.live`).
    private func commands(nodes: Bool = true) throws -> TabCommands {
        guard let client else { throw TabsFailure.disconnected }
        if nodes, !host.live { throw TabsFailure.loading }
        return TabCommands(client: client)
    }

    /// Detects the host's multiplexers and picks where new spaces go (`override` is the host's own choice, by name).
    @discardableResult
    func detect(override: String? = nil) async throws -> MultiplexerChoice? {
        let found = try await commands(nodes: false).detect()
        let available = MultiplexerChoice.available(multiplexers: found.multiplexers, backends: found.backends)
        if multiplexers != available { multiplexers = available }
        let chosen = override.flatMap { name in available.first { $0.name == name } } ?? available.first
        if choice != chosen { choice = chosen }
        return chosen
    }

    /// M7a's recent project folders: existing ones, newest first; none when the helper lacks the `projects.recent`
    /// feature (the sheet then shows Home and Other folder… only) or the request fails. Kept in `recents`, which the
    /// sheet shows at once (fetched when the host connects) and refreshes.
    @discardableResult
    func recentProjects(limit: Int = 30) async -> [TabsRecentProject] {
        guard features.contains("projects.recent"), let commands = try? commands(nodes: false) else { return [] }
        guard let rows = try? await commands.recentProjects(limit: limit) else { return recents }
        let found = rows.filter { $0.exists != false }
        if recents != found { recents = found }
        return found
    }

    /// Opens the chosen backend and keeps this workspace on its topology (for a host session that does not open it
    /// itself). Returns the subscription's request id; cancel it on the connection to stop.
    func open(_ route: HelperBackend.Route) async throws -> UInt64 {
        let commands = try commands(nodes: false)
        return try await commands.open(route, topology: { topology in
            Task { @MainActor [weak self] in self?.apply(topology) }
        })
    }

    /// M7a: a new space in `directory` (absolute or `~/…`) on `multiplexer` (nil: `choice`, the followed one):
    /// `backends.create` for it (its server starts when none runs), a first terminal under that backend as the new
    /// herdr workspace or tmux space, then, when `name` is not empty, `entities.rename` once the topology shows it.
    /// Without a name the server names it as the Mac's new spaces are named (`NewSpaceName`): after its folder, following
    /// it until renamed. Returns its first tab, which Create opens. The host shows one multiplexer's spaces at a time: on
    /// another one, `follow` switches the host to it (its saved preference) once its server runs, so the new space shows
    /// up.
    func createSpace(name: String, directory: String?, on multiplexer: MultiplexerChoice? = nil,
                     follow: @MainActor (String) -> Void = { _ in }, timeout: Duration = .seconds(10)) async throws -> MobileTab {
        let commands = try commands(nodes: false)
        guard let target = multiplexer ?? choice else { throw TabsFailure.noMultiplexer }
        // The backend's id whether its server already runs or starts now; the host session's open of the same route
        // brings the new space's topology.
        let backend = try await commands.createBackend(target.route)
        let switching = target.name != choice?.name
        if switching {
            follow(target.name)
            choice = target
        }
        let cwd = directory.map(host.expand).flatMap { $0.isEmpty ? nil : $0 }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let terminal: UInt64
        /// The space the first window was made in before it was placed into its own.
        var placedFrom: SpaceRef?
        do {
            terminal = try await commands.createTerminal(parent: backend, cwd: cwd)
        } catch let failure as HelperFailure {
            // tmux makes a new space under its backend only while one session is attached ("needs an unambiguous
            // session"). Otherwise: a window in one of its spaces, placed into a new space. The helper names a placed
            // space after its folder too (the label only while the folder is unknown), so a name the user gave is set
            // after. After a switch its spaces arrive with the first snapshot of the newly followed multiplexer.
            if switching { await waitForSpaces(on: backend, timeout: timeout) }
            guard host.live, let anchor = spaces.first(where: { $0.backend == backend }) else { throw failure }
            terminal = try await commands.createTerminal(parent: anchor.node, cwd: cwd)
            let label = trimmed.isEmpty ? NewSpaceName.automatic(directory, host: host) ?? "space" : trimmed
            try await commands.place(terminal: terminal, space: label, in: self, timeout: timeout)
            placedFrom = anchor.ref
        }
        guard let tab = await tab(for: terminal, timeout: timeout), space(of: tab) != nil else {
            throw TabsFailure(message: "The space was created, but the host has not shown it yet.")
        }
        guard !trimmed.isEmpty else { return tab }
        // A placed window's space is renamed once the topology shows it moved (by key: the move may land a snapshot
        // later), even when its label already reads the same: the rename is what stops it following the folder.
        if let placedFrom { await waitUntil(timeout: timeout) { tab.space != placedFrom } }
        if let space = space(of: tab), space.ref != placedFrom, placedFrom != nil || trimmed != space.name {
            try await commands.rename(space.node, to: trimmed)
        }
        return tab
    }

    /// Until `done` holds of a live snapshot, at most `timeout`.
    private func waitUntil(timeout: Duration, _ done: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !(host.live && done()), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Until a live snapshot lists spaces of `backend`, at most `timeout`.
    private func waitForSpaces(on backend: UInt64, timeout: Duration) async {
        await waitUntil(timeout: timeout) { spaces.contains { $0.backend == backend } }
    }

    /// New tab in a space: a new window (tmux) or tab (herdr) in the directory the space's active tab is in. No `cwd`,
    /// as the Mac sends none to a multiplexer: the server knows its focused pane's live directory (tmux
    /// `#{pane_current_path}`), which a folder the topology last reported may no longer be.
    func newTab(in space: MobileSpace, timeout: Duration = .seconds(10)) async throws -> MobileTab {
        let commands = try commands()
        let terminal = try await commands.createTerminal(parent: space.node, cwd: nil)
        guard let tab = await tab(for: terminal, timeout: timeout) else {
            throw TabsFailure(message: "The tab was created, but the host has not shown it yet.")
        }
        return tab
    }

    func rename(space: MobileSpace, to name: String) async throws {
        try await commands().rename(space.node, to: name)
    }

    func rename(tab: MobileTab, to name: String) async throws {
        try await commands().rename(tab.node, to: name)
    }

    /// Close, Detach or Terminate a tab. It leaves the list at once and comes back if the helper refuses.
    @discardableResult
    func close(tab: MobileTab, _ how: TabsClose) async throws -> TabsCloseOutcome {
        try await close(node: tab.node, how, space: false)
    }

    @discardableResult
    func close(space: MobileSpace, _ how: TabsClose) async throws -> TabsCloseOutcome {
        try await close(node: space.node, how, space: true)
    }

    private func close(node: UInt64, _ how: TabsClose, space: Bool) async throws -> TabsCloseOutcome {
        let commands = try commands()
        hide(node)
        do {
            return try await commands.close(node, how, space: space)
        } catch {
            reveal(node)
            throw error
        }
    }

}
