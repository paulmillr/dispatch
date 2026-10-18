import Foundation

/// Which host a tab's files live on and through what (F2e): this Mac's helper for a local tab, the
/// connection's helper for a helper-backed SSH tab, nothing for plain SSH. Sources are cached per connection,
/// so a reconnect (a new connection id) gets a new source and a reused terminal UUID can never reach an older
/// connection's helper.
@MainActor final class FilesResolver {
    /// What the app knows about a tab, gathered from the workspace, the hosts and the SSH links.
    struct Facts: Equatable {
        enum Machine: Equatable {
            /// The tab is gone.
            case none
            case local
            case ssh(destination: String)
        }

        /// A live helper link: its Files grant, its scope and the home it greeted with. `grantsWrite`: Copy files in.
        struct Link: Equatable {
            var grantsFiles: Bool
            var scope: SSHIntegrationScope?
            var home: String?
            var grantsWrite = true
        }

        var machine: Machine
        /// The SSH connection whose helper serves the tab: the login the tab started, or its remote space's link.
        var connection: SSHConnectionID?
        var link: Link?
        /// The connection is still being made or used (false once it ended).
        var live = true
        /// The connection had a helper that has since gone, while its shell lives on.
        var helperGone = false
        var host: String
        var state: HostConnectionState?
        /// The reconnect controller keeps the tab's connection: it dropped, or is being made again.
        var reconnecting = false
        var disconnectedAt: Date?
    }

    enum Decision: Equatable {
        case local
        /// `readOnly`: the grant lists, reads and copies out, but Copy files in is off.
        case remote(SSHConnectionID, home: String?, host: String, readOnly: Bool = false)
        case plainSSH(host: String)
        case notGranted(host: String, scope: SSHIntegrationScope?)
        case offline(host: String, since: Date?)
        case loading
        case unavailable(String)
    }

    private var remote: [SSHConnectionID: HelperFilesSource] = [:]

    /// The decision table. `lastRefresh` is when the tab last listed live: what an offline view is as old as.
    nonisolated static func decide(_ facts: Facts, lastRefresh: Date?) -> Decision {
        let host = facts.host
        switch facts.machine {
        case .none:
            return .unavailable("This tab has closed")
        case .local where facts.connection == nil:
            return .local
        case .local, .ssh:
            if facts.reconnecting || facts.state == .disconnected {
                return .offline(host: host, since: lastRefresh ?? facts.disconnectedAt)
            }
            guard let connection = facts.connection else { return .plainSSH(host: host) }
            if let link = facts.link {
                guard link.grantsFiles else { return .notGranted(host: host, scope: link.scope) }
                return .remote(connection, home: link.home, host: host, readOnly: !link.grantsWrite)
            }
            guard facts.live else { return .offline(host: host, since: lastRefresh ?? facts.disconnectedAt) }
            if facts.helperGone { return .unavailable("The helper on \(host) stopped. Files return with its next connection.") }
            // The login is up and its helper is still starting.
            return .loading
        }
    }

    func availability(for id: UUID, lastRefresh: Date?) -> FilesAvailability {
        availability(Self.decide(facts(for: id), lastRefresh: lastRefresh))
    }

    func availability(_ decision: Decision) -> FilesAvailability {
        switch decision {
        case .local: return .available(FilesSources.localSource())
        case .remote(let id, let home, let host, let readOnly):
            return .available(source(for: id, home: home, host: host, readOnly: readOnly))
        case .plainSSH(let host): return .plainSSH(host: host)
        case .notGranted(let host, let scope): return .notGranted(host: host, scope: scope)
        case .offline(let host, let since): return .offline(host: host, since: since)
        case .loading: return .loading
        case .unavailable(let message): return .unavailable(message: message)
        }
    }

    /// One source per connection for as long as that connection is live (a grant reduced while it lives makes a new one).
    func source(for id: SSHConnectionID, home: String?, host: String, readOnly: Bool = false) -> HelperFilesSource {
        if let source = remote[id], source.home == home, source.hostLabel == host, source.readOnly == readOnly { return source }
        let source = HelperFilesSource(endpoint: .remote(id), home: home, hostLabel: host, readOnly: readOnly)
        remote[id] = source
        return source
    }

    /// Forgets the sources of connections that ended.
    func prune(keeping live: Set<SSHConnectionID>) {
        remote = remote.filter { live.contains($0.key) }
    }

    func facts(for id: UUID) -> Facts {
        let runtime = TerminalRuntime.shared
        guard let workspace = runtime.workspace, let tab = workspace.liveTab(id) else { return Facts(machine: .none, host: "") }
        let links = runtime.ssh.links
        prune(keeping: Set(links.keys))
        let space = workspace.spaces.first { $0.tabs.contains { $0.id == id } }
        let connection = space?.remote ?? runtime.ssh.connectionForOrigin(id)
        let link = connection.flatMap { links[$0] }
        let context = workspace.hosts.terminals[id]
        let reconnect = runtime.hosts.reconnect.state(for: id)
        let machine: Facts.Machine = switch runtime.machine(for: tab) {
        case .local: .local
        case .ssh(let shell): .ssh(destination: shell.destination)
        }
        var host = link?.greeting.hostname ?? link?.launch.shell.destination
        if let context, let record = workspace.hosts.records[context.host] { host = record.name }
        if host == nil, case .ssh(let destination) = machine { host = destination }
        return Facts(
            machine: machine, connection: connection,
            link: link.map { link in
                let features = link.grant.selectedFeatures
                return Facts.Link(grantsFiles: features.contains(.files), scope: link.scope, home: link.greeting.home,
                                  grantsWrite: features.contains(.filesWrite) && link.grant.capabilities.contains("file.write"))
            },
            live: connection.map { runtime.ssh.hasConnections(in: [$0.rawValue]) } ?? false,
            helperGone: link == nil && connection.map { runtime.ssh.helperInstalled($0) } == true,
            host: host ?? "The host", state: context?.state,
            reconnecting: reconnect != nil, disconnectedAt: reconnect?.disconnectedAt)
    }

    /// Reads, inside an observation, the resolver's inputs that are observable: the tab's host state and its
    /// reconnect state. The SSH links are not; the 2 s poll picks their changes up while files shows.
    static func track(_ id: UUID) {
        let runtime = TerminalRuntime.shared
        _ = runtime.workspace?.hosts.terminals[id]
        _ = runtime.hosts.reconnect.state(for: id)
    }
}
