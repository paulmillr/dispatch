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
        space.tabs.first.flatMap { tab(in: space, $0, runtime: runtime) }
    }

    /// One of the space's tabs: its own branch, for a tabs-only sidebar row.
    @MainActor static func tab(in space: Space, _ tab: TerminalTab, runtime: TerminalRuntime) -> Self? {
        guard tab.directory.hasPrefix("/") else { return nil }
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
    /// Timed by System.date(): whether a read reuses the cache decides whether the helper is asked, so a replay
    /// must decide it as the capture did (a slower run past 2 s on the wall clock asked again, unrecorded).
    private struct Cached { let time: Date; let branch: String? }
    private var cache: [SpaceBranchSource.Key: Cached] = [:]
    private var pending: [SpaceBranchSource.Key: Task<String?, Never>] = [:]
    /// At most 4 reads run. Spaces wait for a slot in arrival order, and a read that ends hands its slot to the first of
    /// them: whichever read ends first, a slot never sits idle while a space waits.
    private var free = 4
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let read: @Sendable (SpaceBranchSource) async -> String?

    init(read: @escaping @Sendable (SpaceBranchSource) async -> String? = { await SpaceBranchReader.helper($0) }) {
        self.read = read
    }

    func branch(_ source: SpaceBranchSource) async -> String? {
        guard !Task.isCancelled else { return nil }
        if let cached = recent(source.key) { return cached.branch }
        if let task = pending[source.key] { return await task.value }
        if free > 0 { free -= 1 } else {
            await withCheckedContinuation { waiting.append($0) }
            // Meanwhile another space read this directory, or this one was cancelled: the slot goes on to the next.
            if Task.isCancelled || recent(source.key) != nil || pending[source.key] != nil {
                release()
                return await branch(source)
            }
        }
        let task = Task {
            let result = await read(source)
            if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
            cache[source.key] = Cached(time: System.date(), branch: result)
            pending[source.key] = nil
            release()
            return result
        }
        pending[source.key] = task
        return await task.value
    }

    private func recent(_ key: SpaceBranchSource.Key) -> Cached? {
        cache[key].flatMap { System.date().timeIntervalSince($0.time) < 2 ? $0 : nil }
    }

    private func release() {
        if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
    }

    /// The helper reads the branch on the directory's machine (files.branch, files plugin).
    static func helper(_ source: SpaceBranchSource) async -> String? {
        try? await SSHTimeout.run(.seconds(3), "branch") {
            let endpoint = source.key.connection.map(HelperWorkspace.Endpoint.remote) ?? .local
            let branch: String? = try? await HelperApp.shared.connection(endpoint)
                .request("files.branch", params: ["path": source.key.directory])
            return branch
        }
    }
}
