import Foundation
import Darwin

/// Only paths whose machine is known are eligible. A remote tab must never
/// accidentally display a branch from a similarly named directory on this Mac.
struct SpaceBranchSource: Sendable {
    struct Key: Hashable, Sendable {
        let directory: String
        let connection: SSHConnectionID?
    }
    let key: Key

    @MainActor static func firstTab(in space: Space, runtime: TerminalRuntime) -> Self? {
        guard let tab = space.tabs.first, tab.directory.hasPrefix("/") else { return nil }
        // A remote backend's pane: its directory is on that link's host.
        if let remote = space.remote { return Self(key: Key(directory: tab.directory, connection: remote)) }
        let machine = runtime.hosts.machine(for: tab.id) ?? runtime.owningMachine(for: tab)
        let observedHost = runtime.workspace?.hosts.terminals[tab.id]?.host ?? space.hostID
        if machine == .local, observedHost == .local { return Self(key: Key(directory: tab.directory, connection: nil)) }
        // A plain SSH terminal's inherited local cwd is not authoritative remote directory metadata;
        // a helper pane on that host reads through the host's helper (its SSH connection with the git grant).
        guard tab.terminal != nil, let connection = runtime.ssh.helperConnections(granting: .git).first(where: { id in
            runtime.ssh.links[id].map { HostID.authenticated($0.greeting.host) } == observedHost
        }) else { return nil }
        return Self(key: Key(directory: tab.directory, connection: connection))
    }
}

/// Bounded metadata reads, off the UI actor, without invoking git or scanning
/// working-tree contents. Shared positive/negative caching avoids polling the
/// same directory once per space; connection generations isolate remote caches.
actor SpaceBranchReader {
    static let shared = SpaceBranchReader()
    private struct Cached { let time: ContinuousClock.Instant; let branch: String? }
    private var cache: [SpaceBranchSource.Key: Cached] = [:]
    private var pending: [SpaceBranchSource.Key: Task<String?, Never>] = [:]

    func branch(_ source: SpaceBranchSource) async -> String? {
        while true {
            guard !Task.isCancelled else { return nil }
            if let cached = cache[source.key], cached.time.duration(to: .now) < .seconds(2) { return cached.branch }
            if let task = pending[source.key] { return await task.value }
            // Wait for a slot rather than repeatedly dropping later spaces.
            guard pending.count >= 4, let running = pending.values.first else { break }
            _ = await running.value
        }
        let task = Task {
            let result = await Self.resolve(source)
            if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
            cache[source.key] = Cached(time: .now, branch: result)
            pending[source.key] = nil
            return result
        }
        pending[source.key] = task
        return await task.value
    }

    /// The helper reads the branch on the directory's machine (files.branch, files plugin).
    private static func resolve(_ source: SpaceBranchSource) async -> String? {
        try? await SSHTimeout.run(.seconds(3)) {
            let endpoint = source.key.connection.map(HelperWorkspace.Endpoint.remote) ?? .local
            let branch: String? = try? await HelperApp.shared.connection(endpoint)
                .request("files.branch", params: ["path": source.key.directory])
            return branch
        }
    }
}
