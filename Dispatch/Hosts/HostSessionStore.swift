import Foundation

/// One replaceable snapshot of the workspace: remote tabs with their connection
/// recipes and server identities (never live SSH masters or login credentials),
/// and plain local tabs, which restart a shell in their last directory. Plain
/// shells' output, local or SSH, is kept apart, in `terminalHistory`, and only
/// when the app quits.
@MainActor
struct HostSessionStore {
    let url: URL
    static var standard: Self {
        Self(url: Home.support.appendingPathComponent("host-session.json"))
    }
    var terminalHistory: TerminalHistoryStore {
        .init(url: url.deletingLastPathComponent().appendingPathComponent("terminal-history.json"))
    }
    /// Chats saved with the terminal output, on the same terms (`SavedChatStore`).
    var savedChats: SavedChatStore {
        .init(url: url.deletingLastPathComponent().appendingPathComponent("saved-chats.json"))
    }

    struct Connection: Codable {
        let id: SSHConnectionID
        let host: HostID
        let shell: SSHShell
        let scope: SSHIntegrationScope?
        let accountUID: UInt32?
        let boot: String?
        let origin: UUID
        var surfaces: Set<UUID>
        var backends: [HelperWorkspace.Detached]?

        init(_ recipe: SSHReconnectController.Recipe) {
            id = recipe.connection; host = recipe.host; shell = recipe.shell; scope = recipe.scope
            accountUID = recipe.accountUID; boot = recipe.boot; origin = recipe.origin; surfaces = recipe.surfaces; backends = recipe.backends
        }
        var recipe: SSHReconnectController.Recipe {
            .init(connection: id, host: host, shell: shell, scope: scope, accountUID: accountUID,
                  boot: boot, origin: origin, surfaces: surfaces, restored: true, backends: backends ?? [])
        }
    }
    struct Snapshot: Codable {
        var version = 1
        var hosts: [HostRecord]
        var spaces: [Space]
        var selectedSpace: UUID?
        var contexts: [UUID: TerminalHostContext]
        var connections: [Connection]
        /// What each tab showed (Files with its tab, root, selection and commit; chat; the terminal): given back as the
        /// tab comes back (`FilesCoordinator.retainLaunched`). Absent in files saved before it.
        var views: [UUID: RetainedTabView]? = nil
    }

    /// `history`: also replace the saved output of plain local and SSH tabs (as the app quits).
    func save(runtime: TerminalRuntime, history includeHistory: Bool = false) throws {
        guard let workspace = runtime.workspace else { return }
        var connections = runtime.ssh.savedConnections()
        let known = Set(connections.map(\.id))
        connections += runtime.hosts.sessionRecipes().filter { !known.contains($0.connection) }.map(Connection.init)
        let live = workspace.allSurfaceIDs
        connections = connections.compactMap { connection in
            var connection = connection
            connection.surfaces.formIntersection(live)
            return connection.surfaces.isEmpty ? nil : connection
        }
        let surfaces = Set(connections.flatMap(\.surfaces))
        // Plain shells, local or SSH, in save order; their text is read after the walk below,
        // since the tab closures must not capture main-actor reads (Xcode 26 region isolation).
        var historyTabs: [UUID] = []
        // Host grouping normally isolates remote spaces. Filter individual tabs
        // as well, so a local shell never becomes a remote relaunch command.
        var spaces: [Space] = []
        // A local multiplexer's spaces come back from its server when the helper attaches again.
        for var space in workspace.spaces where !(space.structured && space.remote == nil) {
            if let connection = space.remote, connections.contains(where: { $0.id == connection }) {
                spaces.append(space)
                continue
            }
            func filtered(_ arrangement: PaneArrangement) -> PaneArrangement? {
                var result = arrangement
                result.panes = arrangement.panes.compactMap { pane in
                    var pane = pane
                    pane.tabs = pane.tabs.flatMap { tab -> [TerminalTab] in
                        guard !surfaces.isDisjoint(with: tab.surfaceIDs) else {
                            // Plain local shells keep their place, title and directory;
                            // commands are never replayed. Disconnected SSH tabs have no restorable local state.
                            guard tab.machine == .local else { return [] }
                            var tab = tab
                            tab.launchCommand = nil; tab.isConnecting = false
                            if space.remote == nil { tab.terminal = nil }
                            historyTabs.append(tab.id)
                            return [tab]
                        }
                        var tab = tab
                        tab.launchCommand = nil; tab.isConnecting = false
                        if space.remote == nil { tab.terminal = nil }
                        if let connection = connections.first(where: { $0.surfaces.contains(tab.id) }) {
                            tab.machine = .ssh(connection.shell)
                            historyTabs.append(tab.id)
                        }
                        return [tab]
                    }
                    guard let first = pane.tabs.first else { return nil }
                    if !pane.tabs.contains(where: { $0.id == pane.selected }) { pane.selected = first.id }
                    return pane
                }
                guard let first = result.panes.first else { return nil }
                let ids = Set(result.panes.map(\.id))
                for id in result.layout.paneIDs where !ids.contains(id) {
                    if let layout = result.layout.removing(id) { result.layout = layout }
                }
                if !ids.contains(result.focusedPane) { result.focusedPane = first.id }
                return result
            }
            guard let arrangement = filtered(space.arrangement) else { continue }
            space.arrangement = arrangement
            // Rebuild the hidden local arrangement of native spaces too: it
            // can still contain the original launcher and its command.
            var clean = Space(name: space.name, tab: space.tabs[0], usesDirectoryName: space.usesDirectoryName)
            clean.id = space.id; clean.hostID = space.hostID
            clean.arrangement = space.arrangement
            clean.splitRatios = space.splitRatios
            spaces.append(clean)
        }
        var history: [UUID: String] = [:], historyBytes = 0
        if includeHistory {
            let limits = TerminalHistoryStore.limits
            // A tab whose process has not started since the last launch keeps its restored text.
            for id in historyTabs {
                let text = TerminalHistoryStore.tail(runtime.restoredHistory[id] ?? runtime.views[id]?.surface?.readHistory() ?? "", limit: limits.tab)
                if !text.isEmpty, historyBytes + text.utf8.count <= limits.total {
                    history[id] = text; historyBytes += text.utf8.count
                }
            }
        }
        // Every tab's view, local multiplexers' too: their spaces come back from their servers with the same tab ids.
        var views: [UUID: RetainedTabView] = [:]
        for id in workspace.allTabIDs {
            // A tab still offline since the last launch keeps the view that launch gave it.
            let pending = runtime.files.launchedViews.contains(id) ? runtime.files.retainedViews[id] : nil
            if let view = pending ?? runtime.files.currentView(id),
               view.mode != .terminal || view.manualViewChoice || view.files != nil { views[id] = view }
        }
        let snapshot = Snapshot(hosts: workspace.liveHosts.filter { $0.id != .local }, spaces: spaces,
                                selectedSpace: workspace.selectedSpace,
                                contexts: workspace.hosts.terminals.filter { surfaces.contains($0.key) }, connections: connections,
                                views: views.isEmpty ? nil : views)
        try PrivateFile.write(JSONEncoder().encode(snapshot), to: url)
        if includeHistory {
            try terminalHistory.save(history)
            try savedChats.save(Self.chats(runtime: runtime, workspace: workspace))
        }
    }

    /// Every tab's chat with something to show, in tab order: what it has loaded (nothing is fetched), or for a tab
    /// not back since the last launch, what that launch restored.
    static func chats(runtime: TerminalRuntime, workspace: Workspace) -> [(id: UUID, chat: SavedChat)] {
        let chat = runtime.chat
        return workspace.spaces.flatMap { space in space.tabs.map { (space, $0.id) } }.compactMap { space, id in
            let saved = chat.sessions[id].flatMap { $0.saved(multiplexed: space.structured) } ?? chat.savedChats[id]
            return saved.map { (id, $0) }
        }
    }

    func clear() throws {
        try terminalHistory.remove()
        try savedChats.remove()
        PrivateFile.removeStale(for: url)
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile { }
    }

    @discardableResult
    func restore(runtime: TerminalRuntime) -> Bool {
        PrivateFile.removeStale(for: url)
        guard let workspace = runtime.workspace,
              let data = try? Data(contentsOf: url), data.count <= 16 * 1024 * 1024,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.version == 1 else { return false }
        // Remote backend references stay parked until their authenticated helper reopens them.
        let spaces = snapshot.spaces.filter { !$0.tabs.isEmpty && !$0.panes.isEmpty }
        runtime.files.retainLaunched(snapshot.views ?? [:])
        guard !spaces.isEmpty else { return false }
        workspace.hosts.restore(snapshot.hosts)
        workspace.updateLayout { $0.spaces += spaces }
        for (surface, context) in snapshot.contexts where workspace.allSurfaceIDs.contains(surface) {
            workspace.hosts.associate(surface, context: .init(host: context.host, generation: context.generation,
                                                            state: .disconnected, authenticated: false))
        }
        for connection in snapshot.connections {
            var recipe = connection.recipe
            recipe.surfaces.formIntersection(workspace.allSurfaceIDs)
            guard !recipe.surfaces.isEmpty else { continue }
            runtime.hosts.restore(recipe)
        }
        workspace.updateLayout { $0.selectedSpace = spaces.first { $0.id == snapshot.selectedSpace }?.id ?? spaces.first?.id }
        // Plain local tabs show their view now; a remote tab's waits for its host, a local multiplexer's for its server.
        let local = workspace.spaces.filter { $0.remote == nil && !$0.structured }.flatMap(\.tabs)
            .filter { $0.machine == .local && workspace.hosts.terminals[$0.id] == nil }.map(\.id)
        runtime.files.restoreViews(present: Set(local))
        return true
    }
}
