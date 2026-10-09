import AppKit
import Darwin

/// Connection recipes and live process ownership stay outside presentation
/// metadata. Background discovery never depends on Chat being enabled.
@MainActor
final class HostCoordinator {
    struct Binding {
        let generation: UUID
        let shell: SSHShell
        let process: AgentProcess?
        let integrated: Bool
        var launch: SSHLaunchRequest? = nil
    }
    private struct Address: Codable {
        let connection: SSHConnectionID?
        let terminal: UInt64
    }
    private struct Accepted: Codable {
        let target: Address
        let request: SSHLaunchRequest
        let connecting: Bool
    }
    private struct Consent: Codable {
        let target: Address
        let request: SSHConsentRequest
        let reply: URL
    }
    private struct Closed: Codable {
        let connection: SSHConnectionID
        let notice: SSHCloseNotice
    }
    private struct Sample: Codable {
        let target: Address
        let generation: UUID?
        let next: UUID
        let observation: HostProcessObservation
    }

    private func owner(_ tab: UUID) -> HelperWorkspace? {
        let space = runtime?.workspace?.spaces.first(where: { $0.tabs.contains { $0.id == tab } })
        // A mux hides its original terminal while retaining that terminal's launch capability.
        // Observing an SSH login does not confer ownership of its originating terminal.
        let owners = runtime?.helpers.values.filter { $0.controls(tab) } ?? []
        return space.flatMap { runtime?.helpers[$0.remote.map(HelperWorkspace.Endpoint.remote) ?? .local] }
            ?? (owners.count == 1 ? owners.first : nil)
    }

    private func address(_ tab: UUID) throws -> Address {
        guard let helper = owner(tab), let terminal = helper.terminal(of: tab) else {
            let visible = runtime?.workspace?.spaces.contains { $0.tabs.contains { $0.id == tab } } == true
            let retained = runtime?.helpers.values.filter { $0.controls(tab) }.count ?? 0
            throw HelperFailure(code: "replay", message: "Host event has no owning helper terminal relationship: tab=\(tab) visible=\(visible) retainedOwners=\(retained)")
        }
        return Address(connection: helper.endpoint.connection, terminal: terminal)
    }

    private func terminal(_ address: Address) throws -> UUID {
        let endpoint = address.connection.map(HelperWorkspace.Endpoint.remote) ?? .local
        guard let tab = runtime?.helpers[endpoint]?.tab(of: address.terminal) else {
            throw HelperFailure(code: "replay", message: "Recorded host terminal relationship is unavailable")
        }
        return tab
    }

    private func reject(_ error: any Error) {
        AppReplay.fail(error)
    }

    func replay(_ event: AppReplay.Event) throws -> Bool {
        switch event.kind {
        case "in.host.accepted":
            let value = try JSONDecoder().decode(Accepted.self, from: event.data)
            var request = value.request; request.tabID = try terminal(value.target)
            launch(request, connectingOnly: value.connecting)
        case "in.host.consent":
            let value = try JSONDecoder().decode(Consent.self, from: event.data)
            let request = SSHConsentRequest(id: value.request.id, tabID: try terminal(value.target),
                token: value.request.token, scope: value.request.scope, origin: value.request.origin)
            runtime?.ssh.consent(request, reply: value.reply)
        case "in.host.closed":
            let value = try JSONDecoder().decode(Closed.self, from: event.data)
            runtime?.ssh.channelClosed(value.connection, notice: value.notice)
        case "in.host.probe":
            let values = try JSONDecoder().decode([Sample].self, from: event.data)
            for value in values {
                let tab = try terminal(value.target), observation = value.observation
                apply(.init(terminal: tab, foreground: observation.foreground, device: observation.device,
                            process: observation.process, shell: observation.shell, scope: observation.scope,
                            trackedAlive: observation.trackedAlive), generation: value.generation, next: value.next)
            }
            synchronize()
        default: return false
        }
        return true
    }

    func consent(_ request: SSHConsentRequest, reply: URL) {
        guard !AppReplay.replaying, runtime?.isResettingSSH != true else { return }
        let epoch = epoch
        Task { [weak self] in
            guard let self, let tab = await watcher.locate(request.origin, in: targets()), self.epoch == epoch,
                  await watcher.locate(request.origin, in: targets()) == tab, self.epoch == epoch else { return }
            let attributed = SSHConsentRequest(id: request.id, tabID: tab, token: request.token,
                                               scope: request.scope, origin: request.origin)
            do {
                if AppReplay.enabled {
                    try AppReplay.emit(kind: "host.consent", data: JSONEncoder().encode(
                        Consent(target: address(tab), request: attributed, reply: reply)))
                }
                runtime?.ssh.consent(attributed, reply: reply)
            } catch { reject(error) }
        }
    }

    func closed(_ id: SSHConnectionID, notice: SSHCloseNotice) {
        do {
            try AppReplay.emit(kind: "host.closed", data: JSONEncoder().encode(Closed(connection: id, notice: notice)))
            runtime?.ssh.channelClosed(id, notice: notice)
        } catch { reject(error) }
    }

    private func launch(_ request: SSHLaunchRequest, connectingOnly: Bool) {
        if connectingOnly { connecting(request) }
        else { runtime?.ssh.launch(request) }
    }

    private weak var runtime: TerminalRuntime?
    private let watcher = HostProcessWatcher()
    lazy var reconnect = SSHReconnectController(runtime: runtime!)
    private var task: Task<Void, Never>?
    /// Probes wait half a second while Dispatch is active and ten seconds otherwise; activation ends the wait.
    private var nap: Task<Void, Never>?
    private var activation: NSObjectProtocol?
    private var cursor = 0
    private var epoch = UUID()
    private var bindings: [UUID: Binding] = [:]
    private struct PendingHost {
        let generation: UUID
        let destination: String
        let seed: HostID?
        let scope: SSHIntegrationScope?
        var state: HostConnectionState
        let deadline: ContinuousClock.Instant
        var task: Task<Void, Never>?
    }
    private var pendingHosts: [UUID: PendingHost] = [:]
    private let identityGracePeriod: Duration

    init(runtime: TerminalRuntime, identityGracePeriod: Duration = .seconds(5)) {
        self.runtime = runtime
        self.identityGracePeriod = identityGracePeriod
    }

    func start() {
        guard task == nil else { return }
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.nap?.cancel() }
        }
        task = Task { [weak self] in
            while !Task.isCancelled, let self {
                await self.poll()
                await self.wait()
            }
        }
    }

    private func wait() async {
        let interval: Duration = NSApp?.isActive == false ? .seconds(10) : .milliseconds(500)
        let nap = Task { _ = try? await Task.sleep(for: interval) }
        self.nap = nap
        await nap.value
    }

    func stop() {
        epoch = UUID()
        task?.cancel(); task = nil
        nap?.cancel(); nap = nil
        activation.map(NotificationCenter.default.removeObserver); activation = nil
        reconnect.stop()
        for pending in pendingHosts.values { pending.task?.cancel() }
        pendingHosts.removeAll()
        bindings.removeAll(); cursor = 0
        runtime?.workspace?.hosts.clear()
        runtime?.workspace?.hostMoveMotion.connecting.removeAll()
        runtime?.workspace?.hostPlacements.removeAll()
    }

    var hasActiveSSHConnections: Bool {
        !pendingHosts.isEmpty || bindings.values.sorted { $0.generation.uuidString < $1.generation.uuidString }.contains { HostProcessWatcher.alive($0.process) }
            || reconnect.states.values.contains { $0.reconnecting }
    }

    var remoteSurfaces: Set<UUID> {
        Set(bindings.keys)
            .union(reconnect.recipes.values.flatMap(\.surfaces))
    }

    var pendingLaunches: [SSHLaunchRequest] {
        bindings.values.filter { !$0.integrated }.compactMap(\.launch)
    }

    /// Called before dropping bindings, so ordinary SSH also relinquishes its
    /// verified process. Enhanced connections are retired by SSHCoordinator.
    func disconnectOrdinarySSH() {
        for (terminal, binding) in bindings.sorted(by: { $0.value.generation.uuidString < $1.value.generation.uuidString }) where !binding.integrated {
            runtime?.helpers.values.forEach { $0.disconnect(terminal) }
            HostProcessWatcher.terminate(binding.process)
        }
    }

    func resetDiscoveryCache() async { await watcher.reset() }

    func restore(_ recipe: SSHReconnectController.Recipe) {
        bindings[recipe.origin] = Binding(generation: recipe.connection.rawValue, shell: recipe.shell, process: nil, integrated: true)
        runtime?.workspace?.hosts.associate(recipe.origin, context: .init(host: recipe.host, generation: recipe.connection.rawValue,
                                                                        state: .disconnected, authenticated: false))
        reconnect.retain(recipe)
    }

    func sessionRecipes() -> [SSHReconnectController.Recipe] {
        guard let workspace = runtime?.workspace else { return [] }
        var result = reconnect.recipes
        for (surface, context) in workspace.hosts.terminals where context.host != .local {
            let id = SSHConnectionID(context.generation)
            if result[id] != nil { result[id]?.surfaces.insert(surface); continue }
            guard let binding = bindings[surface] else { continue }
            result[id] = .init(connection: id, host: context.host, shell: binding.shell, scope: nil,
                               origin: surface, surfaces: [surface])
        }
        return Array(result.values)
    }

    func machine(for terminal: UUID) -> TerminalMachine? { bindings[terminal].map { .ssh($0.shell) } }

    private func generations(for host: HostID) -> Set<UUID> {
        guard host != .local, let workspace = runtime?.workspace else { return [] }
        return Set(workspace.hosts.terminals.values.filter { $0.host == host }.map(\.generation))
    }

    func canDisconnect(_ host: HostID) -> Bool {
        let generations = generations(for: host)
        return bindings.values.contains { generations.contains($0.generation) && !reconnect.contains($0.generation) }
            || generations.contains { reconnect.states[SSHConnectionID($0)]?.reconnecting == true }
            || runtime?.ssh.hasConnections(in: generations) == true
    }

    func canForget(_ host: HostID) -> Bool {
        guard host != .local, let workspace = runtime?.workspace,
              workspace.hosts.state(host) == .disconnected, !canDisconnect(host) else { return false }
        let spaces = workspace.spaces.filter { $0.hostID == host }
        let hasDetached = workspace.detached.contains { $0.host == host }
        return (!spaces.isEmpty || hasDetached)
            && spaces.allSatisfy { workspace.belongsToHost($0, host) }
    }

    /// Removing disconnected presentation never terminates server jobs.
    func forget(_ host: HostID) {
        guard canForget(host), let runtime, let workspace = runtime.workspace else { return }
        removePresentation(host, runtime: runtime, workspace: workspace)
        workspace.onForgetHost()
    }

    func canReset(_ host: HostID) -> Bool {
        guard host != .local, let workspace = runtime?.workspace else { return false }
        return workspace.spaces.filter { $0.hostID == host }.allSatisfy {
            workspace.belongsToHost($0, host)
        }
    }

    /// Drop only this host's client state. Native server sessions keep running.
    func reset(_ host: HostID) {
        guard canReset(host), let runtime, let workspace = runtime.workspace else { return }
        let generations = generations(for: host)
        let surfaces = Set(workspace.hosts.terminals.filter { $0.value.host == host }.map(\.key))
        let pending = bindings.values.filter { generations.contains($0.generation) && !$0.integrated }.compactMap(\.launch)
        // Invalidate discoveries suspended before the reset started.
        epoch = UUID()
        disconnect(host)
        runtime.ssh.resetHost(host, generations: generations, surfaces: surfaces, pending: pending)
        removePresentation(host, runtime: runtime, workspace: workspace)
        runtime.close(Array(surfaces.subtracting(workspace.allSurfaceIDs)))
        for generation in generations { reconnect.forget(SSHConnectionID(generation)) }
        SSHStatisticsStore.shared.reset(host)
        HostBackendCache.shared.reset(host)
        workspace.hosts.forget(host)
        workspace.onForgetHost()
    }

    private func removePresentation(_ host: HostID, runtime: TerminalRuntime, workspace: Workspace) {
        let surfaces = workspace.hosts.terminals.filter { $0.value.host == host }.map(\.key)
        reconnect.cancel(hostID: host)
        for id in workspace.spaces.filter({ $0.hostID == host }).map(\.id) { workspace.detachSpace(id) }
        for entry in workspace.detached where entry.host == host { workspace.forgetDetached(entry.id) }
        workspace.removeHostPresentation(host)
        // Hidden launchers are not part of the space's visible tab list.
        runtime.close(surfaces.filter { !workspace.allSurfaceIDs.contains($0) })
        workspace.hosts.forget(host)
    }

    /// Snapshot live ownership, including retained native consumers. Labels and
    /// SSH aliases never authorize disconnecting another host's connections.
    func disconnect(_ host: HostID) {
        let generations = generations(for: host)
        guard !generations.isEmpty, let runtime else { return }
        reconnect.cancel(hostID: host)
        for (terminal, binding) in bindings.sorted(by: { $0.value.generation.uuidString < $1.value.generation.uuidString }) where !binding.integrated && generations.contains(binding.generation) {
            for helper in runtime.helpers.values { helper.disconnect(terminal) }
            HostProcessWatcher.terminate(binding.process)
        }
        runtime.ssh.disconnect(generations: generations)
    }

    /// The mailbox capability authorizes a launch but does not identify its
    /// pane. Match the live originating PTY, including inherited capabilities.
    func accept(_ request: SSHLaunchRequest, connectingOnly: Bool = false) {
        guard runtime?.isResettingSSH != true, !AppReplay.replaying else { return }
        let epoch = epoch
        Task { [weak self] in
            guard let self, await watcher.validate(request), self.epoch == epoch else { return }
            guard let origin = request.origin, let tab = await watcher.locate(origin, in: targets()),
                  self.epoch == epoch else { return }
            let targets = targets().filter { $0.terminal == tab }
            for start in stride(from: 0, to: targets.count, by: 16) {
                guard self.epoch == epoch else { return }
                let observations: [HostProcessObservation]
                do { observations = try await AppReplay.unrecorded { await watcher.probe(Array(targets[start..<min(start + 16, targets.count)])) } }
                catch { reject(error); return }
                let matches = observations.filter { $0.device == request.terminalDevice && $0.process == request.sshProcess }
                if let match = matches.first, matches.count == 1, await watcher.validate(request),
                   self.epoch == epoch,
                   runtime?.workspace?.allSurfaceIDs.contains(match.terminal) == true {
                    var attributed = request; attributed.tabID = match.terminal
                    attributed.presentationScope = match.scope
                    do {
                        if AppReplay.enabled {
                            try AppReplay.emit(kind: "host.accepted", data: JSONEncoder().encode(
                                Accepted(target: address(attributed.tabID), request: attributed, connecting: connectingOnly)))
                        }
                        launch(attributed, connectingOnly: connectingOnly)
                    } catch { reject(error) }
                    return
                }
            }
        }
    }

    func connecting(_ request: SSHLaunchRequest) {
        // Progress can be delivered after the ready request. Never restart a
        // connection indicator once this generation has advanced to bootstrap.
        guard bindings[request.tabID]?.generation != request.connectionID.rawValue else { return }
        // Authentication can exit without a ready request or managed close
        // notice. Let the process watcher clean up this provisional binding.
        began(request, integrated: false)
    }

    func began(_ request: SSHLaunchRequest, integrated: Bool = true) {
        guard let workspace = runtime?.workspace else { return }
        let seed = workspace.hosts.terminals[request.tabID]?.host
        let deadline = bindings[request.tabID]?.process == request.sshProcess ? pendingHosts[request.tabID]?.deadline : nil
        bindings[request.tabID] = Binding(generation: request.connectionID.rawValue, shell: request.shell,
                                          process: request.sshProcess, integrated: integrated, launch: request)
        queueHost(request.tabID, generation: request.connectionID.rawValue, destination: request.shell.destination,
                  seed: seed, scope: request.presentationScope, state: .connecting, deadline: deadline)
    }

    func authenticated(_ request: SSHLaunchRequest, greeting: SSHGreeting) {
        reconnect.shellAuthenticated(request.tabID)
        guard let workspace = runtime?.workspace else { return }
        if bindings[request.tabID]?.generation == request.connectionID.rawValue {
            workspace.hostMoveMotion.connecting.remove(request.tabID)
        }
        presentPendingHost(request.tabID, generation: request.connectionID.rawValue)
        workspace.hosts.update(request.tabID, generation: request.connectionID.rawValue, destination: request.shell.destination,
                               greeting: greeting, state: .connected)
        synchronize()
    }

    func failed(_ id: SSHConnectionID) {
        for (terminal, binding) in bindings where binding.generation == id.rawValue {
            runtime?.workspace?.hostMoveMotion.connecting.remove(terminal)
        }
        for terminal in pendingHosts.keys where pendingHosts[terminal]?.generation == id.rawValue {
            pendingHosts[terminal]?.state = .disconnected
        }
        runtime?.workspace?.hosts.setState(.disconnected, generation: id.rawValue)
    }

    func recovered(from old: UUID, request: SSHLaunchRequest) {
        guard let workspace = runtime?.workspace else { return }
        for (surface, context) in workspace.hosts.terminals where context.generation == old {
            workspace.hosts.associate(surface, context: .init(host: context.host, generation: request.connectionID.rawValue,
                                                            state: .connected, authenticated: true))
            workspace.hostPlacements[surface]?.generation = request.connectionID.rawValue
        }
        if bindings[request.tabID]?.generation == old {
            bindings[request.tabID] = Binding(generation: request.connectionID.rawValue, shell: request.shell, process: nil, integrated: true)
        }
        synchronize()
    }

    func exited(_ request: SSHLaunchRequest) {
        ended(request.tabID, generation: request.connectionID.rawValue)
    }

    private func ended(_ terminal: UUID, generation: UUID) {
        guard bindings[terminal]?.generation == generation, let workspace = runtime?.workspace else { return }
        workspace.hostMoveMotion.connecting.remove(terminal)
        pendingHosts.removeValue(forKey: terminal)?.task?.cancel()
        bindings[terminal] = nil
        workspace.hosts.remove(terminal, generation: generation)
        workspace.restoreHostTerminal(terminal, generation: generation)
        synchronize()
    }

    func close(_ terminal: UUID) {
        reconnect.close(terminal)
        runtime?.workspace?.hostMoveMotion.connecting.remove(terminal)
        pendingHosts.removeValue(forKey: terminal)?.task?.cancel()
        bindings[terminal] = nil
        runtime?.workspace?.hosts.remove(terminal)
        runtime?.workspace?.hostPlacements[terminal] = nil
    }

    /// Routing is already live in bindings; only provisional host presentation waits.
    private func queueHost(_ terminal: UUID, generation: UUID, destination: String, seed: HostID? = nil,
                           scope: SSHIntegrationScope?, state: HostConnectionState,
                           deadline: ContinuousClock.Instant? = nil) {
        guard let workspace = runtime?.workspace else { return }
        pendingHosts.removeValue(forKey: terminal)?.task?.cancel()
        if state == .connecting { workspace.hostMoveMotion.connecting.insert(terminal) }
        else { workspace.hostMoveMotion.connecting.remove(terminal) }
        let deadline = deadline ?? ContinuousClock.now.advanced(by: identityGracePeriod)
        pendingHosts[terminal] = PendingHost(generation: generation, destination: destination, seed: seed,
                                             scope: scope, state: state, deadline: deadline)
        if let seed, workspace.hosts.record(seed).system != nil {
            // Keep a known icon while refreshing its identity, even if resolving
            // the new login scope would otherwise create a provisional record.
            workspace.hosts.seed(terminal, from: seed, generation: generation)
            workspace.hosts.setState(state, generation: generation)
        }
        pendingHosts[terminal]?.task = Task { [weak self, weak workspace] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard let self, let workspace, runtime?.workspace === workspace else { return }
            presentPendingHost(terminal, generation: generation)
            synchronize()
        }
    }

    private func presentPendingHost(_ terminal: UUID, generation: UUID) {
        guard let workspace = runtime?.workspace, bindings[terminal]?.generation == generation,
              let pending = pendingHosts[terminal], pending.generation == generation else { return }
        pendingHosts.removeValue(forKey: terminal)?.task?.cancel()
        workspace.hosts.begin(terminal, generation: generation, destination: pending.destination,
                              seed: pending.seed, state: pending.state, scope: pending.scope)
    }

    func synchronize() {
        guard let workspace = runtime?.workspace else { return }
        for terminal in bindings.keys {
            if let context = workspace.hosts.terminals[terminal] {
                runtime?.ssh.associatePermissions(terminal: terminal, host: context.host)
            }
            workspace.placeHostTerminal(terminal)
        }
        // Hidden control origins can acquire their host after their panes were imported.
        for space in workspace.spaces {
            if let backend = space.backend { workspace.helper(space)?.inherit(backend) }
        }
        workspace.regroupHosts()
    }

    private func targets() -> [HostProcessTarget] {
        guard let runtime, let workspace = runtime.workspace else { return [] }
        var targets: [HostProcessTarget] = []
        let visible = workspace.spaces.flatMap(\.tabs).map(\.id)
        let retained = runtime.views.keys.filter { !visible.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        for tab in visible + retained {
            // Workspace views relay helper terminals; their renderer is not the shell.
            // Remote device numbers cannot identify a PTY on this Mac.
            guard let helper = owner(tab), helper.endpoint == .local, !helper.stopped,
                  let terminal = helper.terminal(of: tab), let tty = helper.node(terminal)?.tty,
                  let device = UInt32(exactly: tty) else { continue }
            targets.append(.init(terminal: tab, source: .device(device), tracking: bindings[tab]?.process))
        }
        return targets
    }

    private func apply(_ observation: HostProcessObservation, generation: UUID?, next: UUID) {
        let terminal = observation.terminal
        guard runtime?.workspace?.allSurfaceIDs.contains(terminal) == true || owner(terminal)?.controls(terminal) == true,
              bindings[terminal]?.generation == generation else { return }
        // An observation started before a newer accepted login cannot retire it.
        if let old = bindings[terminal] {
            if old.integrated || old.process == nil || observation.trackedAlive { return }
            ended(terminal, generation: old.generation)
        }
        guard let process = observation.process, let shell = observation.shell else { return }
        reconnect.shellAuthenticated(terminal)
        bindings[terminal] = Binding(generation: next, shell: shell, process: process, integrated: false)
        queueHost(terminal, generation: next, destination: shell.destination, scope: observation.scope, state: .unverified)
    }

    func poll() async {
        guard !AppReplay.replaying, runtime?.isResettingSSH != true, let workspace = runtime?.workspace else { return }
        let epoch = epoch
        let all = targets()
        guard !all.isEmpty else { return }
        let count = min(16, all.count)
        let batch = (0..<count).map { all[(cursor + $0) % all.count] }
        cursor = (cursor + count) % all.count
        let owners = Dictionary(uniqueKeysWithValues: batch.compactMap { target in
            owner(target.terminal).map { (target.terminal, $0) }
        })
        let terminals = Dictionary(uniqueKeysWithValues: batch.compactMap { target in
            owners[target.terminal]?.terminal(of: target.terminal).map { (target.terminal, $0) }
        })
        let generations = Dictionary(uniqueKeysWithValues: batch.compactMap { target in
            bindings[target.terminal].map { (target.terminal, $0.generation) }
        })
        let observations: [HostProcessObservation]
        do { observations = try await AppReplay.unrecorded { await watcher.probe(batch) } }
        catch { reject(error); return }
        guard !Task.isCancelled, self.epoch == epoch, runtime?.workspace === workspace else { return }
        do {
            let current = targets()
            let observations = observations.filter { observation in
                owners[observation.terminal] === owner(observation.terminal)
                    && terminals[observation.terminal] == owner(observation.terminal)?.terminal(of: observation.terminal)
                    && current.contains { target in
                        target.terminal == observation.terminal
                            && batch.contains { $0.terminal == target.terminal && $0.source == target.source }
                    }
            }
            let next = Dictionary(uniqueKeysWithValues: observations.map { ($0.terminal, UUID()) })
            if AppReplay.enabled {
                let samples = try observations.filter { bindings[$0.terminal] != nil || $0.process != nil }.map { observation in
                    Sample(target: try address(observation.terminal), generation: generations[observation.terminal],
                           next: next[observation.terminal]!, observation: observation)
                }
                try AppReplay.emit(kind: "host.probe", data: JSONEncoder().encode(samples))
            }
            for observation in observations {
                apply(observation, generation: generations[observation.terminal], next: next[observation.terminal]!)
            }
        } catch { reject(error); return }
        synchronize()
    }
}
