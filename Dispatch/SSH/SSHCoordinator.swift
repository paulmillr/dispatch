import AppKit
import Observation

/// Agents whose hooks a login's consent covers (remembered per scope).
enum SSHHookAgent: String, Codable, CaseIterable, Sendable {
    case codex, claude, pi
}

@MainActor @Observable
final class SSHCoordinator {
    let permissions = SSHIntegrationPermissions()
    @ObservationIgnored var presentIntegrationConsent: @MainActor (SSHIntegrationScope, NSWindow?) async -> SSHIntegrationSelection? = {
        await SSHIntegrationConsent.present($0, window: $1)
    }
    /// The "Full features" new-host policy answers the consent sheet with this.
    /// Pi stays opt-in because it installs an extension on the remote host.
    static let fullFeatures = SSHIntegrationSelection(
        grant: .init(helperEnabled: true, features: Set(SSHIntegrationFeature.allCases)),
        agents: [.codex: true, .claude: true, .pi: false])

    /// First choice for a login: automatic under Full features, otherwise the sheet.
    private func newHostSelection(_ scope: SSHIntegrationScope, window: NSWindow?) async -> SSHIntegrationSelection? {
        if TerminalRuntime.shared.preferences.autoGrantNewHosts { return Self.fullFeatures }
        return await presentIntegrationConsent(scope, window)
    }
    @ObservationIgnored private var scopeHosts: [HostID: Set<String>] = [:]
    @ObservationIgnored private var terminalScopes: [UUID: String] = [:]
    @ObservationIgnored private var connections: [SSHConnectionID: SSHConnectionState] = [:]
    /// An authenticated connection: its launch, grant, host and remote shell.
    struct Link {
        let launch: SSHLaunchRequest
        let grant: SSHIntegrationGrant
        let scope: SSHIntegrationScope
        let greeting: SSHGreeting
        let shellPID: UInt64?
        /// The installed helper binary on the host.
        let helperPath: String?
    }
    var links: [SSHConnectionID: Link] {
        connections.compactMapValues { state in
            guard let grant = state.granted, let greeting = state.greeting, let helper = state.helper4,
                  let scope = state.request.integrationScope else { return nil }
            return Link(launch: state.request, grant: grant, scope: scope,
                        greeting: greeting, shellPID: helper.info.process?.pid, helperPath: state.helperPath)
        }
    }
    func grant(_ id: SSHConnectionID) -> SSHIntegrationGrant? { connections[id]?.granted }
    private var requests: [SSHConnectionID: SSHLaunchRequest] {
        connections.compactMapValues { $0.isFinishing ? nil : $0.request }
    }
    private func activeRequest(_ id: SSHConnectionID) -> SSHLaunchRequest? {
        guard let state = connections[id], !state.isFinishing else { return nil }
        return state.request
    }
    private var hostTints: [UUID: (connection: SSHConnectionID, tint: HostTint)] = [:]

    func tint(for tab: TerminalTab) -> HostTint? {
        if let hosts = TerminalRuntime.shared.workspace?.hosts, let context = hosts.terminals[tab.focusedSurfaceID] {
            var tint = hosts.record(context.host).tint
            tint?.offline = context.state == .disconnected || TerminalRuntime.shared.hosts.reconnect.state(for: tab.focusedSurfaceID) != nil
            return tint
        }
        return hostTints[tab.id]?.tint
    }

    /// What a glass strip of `tabs` leads with while any of them is remote: the active tab's host, or the Mac when
    /// that tab is local. Nil while every tab is local.
    func stripHost(active: TerminalTab?, among tabs: [TerminalTab]) -> StripHost? {
        guard tabs.contains(where: { tint(for: $0) != nil }) else { return nil }
        guard let active, let tint = tint(for: active) else { return StripHost(record: .local, tint: nil) }
        var record: HostRecord?
        var connecting = false
        if let hosts = TerminalRuntime.shared.workspace?.hosts, let context = hosts.terminals[active.focusedSurfaceID] {
            record = hosts.record(context.host)
            connecting = context.state == .connecting
                || TerminalRuntime.shared.hosts.reconnect.state(for: active.focusedSurfaceID)?.reconnecting == true
        }
        return StripHost(record: record, tint: tint, connecting: connecting)
    }

    private struct Write<Value: Encodable>: Encodable { let path: String; let value: Value }
    private func publish<Value: Encodable>(_ value: Value, to file: URL) {
        do {
            let data = try JSONEncoder().encode(value)
            _ = try AppReplay.query(kind: "host.reply", input: JSONEncoder().encode(Write(path: file.path, value: value))) {
                try data.write(to: file, options: .atomic)
                return Data()
            }
        } catch { AppReplay.fail(error) }
    }

    func consent(_ request: SSHConsentRequest, reply: URL) {
        guard !TerminalRuntime.shared.isResettingSSH else {
            publish(SSHConsentResponse(grant: nil), to: reply)
            return
        }
        guard TerminalRuntime.shared.preferences.enableHostDetection else {
            publish(SSHConsentResponse(grant: .init(profile: .ordinary)), to: reply)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let runtime = TerminalRuntime.shared
            let window = runtime.views[request.tabID]?.window ?? runtime.workspace?.activeSurfaceID.flatMap { runtime.views[$0]?.window }
            let grant = await permissions.choose(request.scope) { [weak self] scope in
                await self?.newHostSelection(scope, window: window)
            }
            guard HostProcessWatcher.alive(request.origin), !Task.isCancelled else { return }
            if grant != nil { terminalScopes[request.tabID] = request.scope.key }
            publish(SSHConsentResponse(grant: grant), to: reply)
        }
    }

    /// UI restoration only. This value never authorizes helper access.
    func presentationScope(for terminal: UUID) -> String? { terminalScopes[terminal] }

    func integrationEntries(for host: HostID) -> [SSHIntegrationPermissions.Entry] {
        var keys = scopeHosts[host] ?? []
        for (tab, context) in TerminalRuntime.shared.workspace?.hosts.terminals ?? [:] where context.host == host {
            if let key = terminalScopes[tab] { keys.insert(key) }
        }
        return keys.compactMap { permissions.entries[$0] }.sorted {
            ($0.scope.account, $0.scope.destination, $0.scope.key) < ($1.scope.account, $1.scope.destination, $1.scope.key)
        }
    }

    func associatePermissions(terminal: UUID, host: HostID) {
        guard let key = terminalScopes[terminal] else { return }
        scopeHosts[host, default: []].insert(key)
    }

    func resetIntegration(for host: HostID) {
        for entry in integrationEntries(for: host) { permissions.reset(entry.scope) }
    }

    func integrationConnectionState(_ scope: SSHIntegrationScope) -> SSHIntegrationConsent.ConnectionState {
        let active = links.values.filter { $0.scope == scope }
            .sorted { $0.launch.connectionID.rawValue.uuidString < $1.launch.connectionID.rawValue.uuidString }
        return .init(grants: active.map(\.grant), requirements: [])
    }

    func editIntegration(_ scope: SSHIntegrationScope) {
        Task { [weak self] in
            guard let self else { return }
            var reconnectRequested = false
            let state = integrationConnectionState(scope)
            let selection = await SSHIntegrationConsent.present(scope, current: permissions.remembered(scope),
                agents: permissions.agentHooks(scope),
                status: state.status, reconnect: { reconnectRequested = true },
                reconnectRequirements: state.requirements, activeGrants: state.grants,
                connectionState: { [weak self] in self?.integrationConnectionState(scope) ?? .init() })
            guard let selection else { return }
            // Connections can start or end while the settings sheet is open.
            // Apply the reconnect request to the current scope's sessions, not
            // just those present when editing began.
            if reconnectRequested { retainIntegration(scope) }
            permissions.save(selection, for: scope)
            if reconnectRequested { reconnectIntegrationRetained(scope) }
        }
    }

    /// Reconnect a login's live sessions so its saved helper choice takes
    /// effect, as after Save & reconnect.
    func reconnectIntegration(_ scope: SSHIntegrationScope) {
        retainIntegration(scope)
        reconnectIntegrationRetained(scope)
    }

    private func retainIntegration(_ scope: SSHIntegrationScope) {
        for link in links.values.filter({ $0.scope == scope }) { retain(link.launch.connectionID) }
    }

    private func reconnectIntegrationRetained(_ scope: SSHIntegrationScope) {
        guard permissions.remembered(scope).map({ $0.profile != .ordinary }) == true else { return }
        let controller = TerminalRuntime.shared.hosts.reconnect
        let recipes = controller.recipes.values.filter { $0.scope == scope }
        for host in Set(recipes.map(\.host)) {
            if let recipe = recipes.first(where: { $0.host == host }), let surface = recipe.surfaces.first {
                controller.reconnect(hostID: host, sourceSurfaceID: surface, scope: scope)
            }
        }
    }

    func statisticsConnection(for tabID: UUID?) -> SSHConnectionID? {
        guard let tabID else { return nil }
        return links.values.first { $0.launch.tabID == tabID && $0.grant.selectedFeatures.contains(.statistics) }?.launch.connectionID
    }

    /// Withdraw feature authority while keeping the authenticated login shell alive.
    private func permissionsChanged(_ scope: SSHIntegrationScope, _ grant: SSHIntegrationGrant) {
        for (id, link) in links where link.scope == scope {
            let reduced = link.grant.reduced(to: grant)
            guard reduced != link.grant else { continue }
            guard let state = connections[id] else { continue }
            state.granted = reduced
            let runtime = TerminalRuntime.shared
            let surfaces = runtime.helpers[.remote(id)]?.reduce(to: Set(reduced.selectedFeatures.map(\.rawValue))) ?? []
            if !surfaces.isEmpty { retain(id, surfaces: surfaces) }
            if !reduced.selectedFeatures.contains(.chat) {
                runtime.chat.helperExited(.remote(id), status: Self.integrationDisabled, disabled: true)
            }
            if !reduced.selectedFeatures.contains(.statistics) { SSHStatisticsStore.shared.remove(id) }
            if let helper = state.helper4 {
                let previous = state.reduction
                state.reduction = Task { [weak self, weak state] in
                    await previous?.value
                    guard let self, let state, !Task.isCancelled, connections[id] === state,
                          state.helper4 === helper else { return }
                    do {
                        let _: HelperClient.Empty = try await SSHTimeout.run(.seconds(5)) {
                            try await helper.connection.request(
                                "permissions.reduce", params: ["capabilities": reduced.capabilities.sorted()])
                        }
                        if reduced.profile == .ordinary, state.helper4 === helper {
                            helperDisconnected(id, shellAvailable: true)
                        }
                    } catch {
                        if state.helper4 === helper { helperDisconnected(id, shellAvailable: true) }
                    }
                }
            }
        }
        for (id, request) in requests where request.integrationScope == scope && connections[id]?.helper4 == nil
            && request.integrationGrant.map({ $0.reduced(to: grant) != $0 }) == true {
            connections[id]?.launchTask?.cancel()
            Task { _ = try? await SSHCommand.run(executable: request.master.executable,
                arguments: request.master.arguments(command: SSHBootstrap.publish(sessionID: request.sessionID, relativePath: nil)), timeout: 3) }
        }
    }

    func start() throws {
        permissions.onChange = { [weak self] scope, grant in self?.permissionsChanged(scope, grant) }
    }

    func connectionForOrigin(_ tab: UUID) -> SSHConnectionID? {
        requests.values.first { $0.tabID == tab && connections[$0.connectionID]?.originClosed != true }?.connectionID
    }

    /// Connections whose remote helper runs with this feature granted.
    func helper4Connections(granting feature: SSHIntegrationFeature) -> [SSHConnectionID] {
        connections.values.filter { $0.helper4 != nil && $0.granted?.selectedFeatures.contains(feature) == true }.map(\.id)
    }

    /// The remote helper and its login terminal behind an SSH tab.
    func helper4(for tab: UUID) -> (connection: SSHConnectionID, terminal: UInt64)? {
        guard let id = connectionForOrigin(tab), let terminal = connections[id]?.helper4?.info.terminal else { return nil }
        return (id, terminal)
    }

    func machine(for tab: UUID) -> TerminalMachine? {
        requests.values.first(where: { $0.tabID == tab && connections[$0.connectionID]?.originClosed != true }).map { .ssh($0.shell) }
    }

    func helperInstalled(_ id: SSHConnectionID) -> Bool { connections[id]?.helperInstalled == true }

    /// Whether programs in this terminal can run over a connection that has had the helper: SSH
    /// started in it, or a space of that link's remote backends.
    func helperBacked(_ tab: UUID) -> Bool {
        if let id = connectionForOrigin(tab), helperInstalled(id) { return true }
        let space = TerminalRuntime.shared.workspace?.spaces.first { $0.tabs.contains { $0.id == tab } }
        return space?.remote.map(helperInstalled) == true
    }

    func launch(_ request: SSHLaunchRequest, recovering: Bool = false, startShell: Bool = true,
                prepare: (@MainActor (String, HelperSession.Info) throws -> Void)? = nil) {
        guard !TerminalRuntime.shared.isResettingSSH else { return }
        guard connections[request.connectionID] == nil, let resources = Bundle.main.resourceURL else { return }
        let state = SSHConnectionState(request: request)
        connections[request.connectionID] = state
        if !recovering { TerminalRuntime.shared.hosts.began(request) }
        let release = TerminalRuntime.shared.workspace?.helper(containing: request.tabID)?.suspend(request.tabID)
        state.launchTask = Task { [weak self, weak state] in
            defer {
                release?()
                if let self, let state, connections[request.connectionID] === state { state.launchTask = nil }
            }
            do {
                guard let self, let state, connections[request.connectionID] === state,
                      let scope = request.integrationScope, let requested = request.integrationGrant,
                      let remembered = permissions.remembered(scope) else { throw HerdrFailure("SSH integration permission is missing.") }
                let grant = requested.reduced(to: remembered)
                // The foreground SSH command already contains its selected
                // login profile. If consent changed during authentication, use
                // its ordinary fallback instead of launching a differently
                // authorized broker beside that original login command.
                guard grant == requested, grant.isCurrent, grant.profile != .ordinary else {
                    throw HerdrFailure("SSH integration permission changed during authentication.")
                }
                try await startHelper4(request, state: state, grant: grant, resources: resources,
                                       recovering: recovering, startShell: startShell, prepare: prepare)
            } catch {
                state?.launchFailure = error
                guard let self, let state, connections[request.connectionID] === state else { return }
                if connections[request.connectionID]?.helper4 != nil { helperDisconnected(request.connectionID) }
                guard activeRequest(request.connectionID) != nil, !Task.isCancelled else { return }
                TerminalRuntime.shared.hosts.failed(request.connectionID)
                // Release a remote login waiting for bootstrap. It falls back
                // to the requested shell/command without repeating login.
                let release = SSHBootstrap.publish(sessionID: request.sessionID, relativePath: nil)
                _ = try? await SSHCommand.run(executable: request.master.executable, arguments: request.master.arguments(command: release), timeout: 3)
            }
        }
    }

    private func decision(_ request: SSHLaunchRequest, _ value: SSHResumeDecision) {
        let directory = URL(fileURLWithPath: request.master.controlPath).deletingLastPathComponent().deletingLastPathComponent()
        let file = directory.appendingPathComponent(request.connectionID.rawValue.uuidString + ".sshresume")
        publish(value, to: file)
    }

    func channelClosed(_ id: SSHConnectionID, notice: SSHCloseNotice) {
        guard let request = activeRequest(id), request.credential == notice.credential else { return }
        // Closing the launching tab ends only its shell channel. Native herdr views still use the helper's
        // own channel through the persistent master; its loss is reported separately when that channel ends.
        if connections[id]?.originClosed == true, TerminalRuntime.shared.helpers[.remote(id)] != nil, consumed(id) { return }
        Task { [weak self] in
            guard let self else { return }
            var status = connections[id]?.normalExit
            if status == nil, connections[id]?.intentionalDisconnect != true {
                status = notice.remoteExitStatus
            }
            if status == nil, connections[id]?.intentionalDisconnect != true, let helper = connections[id]?.helperPath {
                // A helper-owned receipt distinguishes even `exit 255` from
                // transport loss. Read it through this authenticated master.
                let command = "exec " + HerdrLaunch.quote(helper) + " exit-status " + HerdrLaunch.quote(request.sessionID)
                if let result = try? await SSHCommand.run(executable: request.master.executable, arguments: request.master.arguments(command: command), timeout: 3), result.status == 0 {
                    status = Int32(String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            guard activeRequest(id)?.credential == request.credential else { return }
            // Ordinary bootstrap fallback has OpenSSH's normal status, but no
            // authenticated shell receipt. Only a known managed shell may wait.
            if let status {
                connections[id]?.normalExit = status
                decision(request, .init(credential: notice.credential, exitStatus: status))
                if !consumed(id) { TerminalRuntime.shared.hosts.reconnect.forget(id) }
                closed(id, credential: notice.credential)
            } else if notice.recoverable, connections[id]?.helperPath != nil {
                if notice.recoverable { decision(request, .init(credential: notice.credential, waiting: true)) }
                retain(id)
                helperDisconnected(id)
                // Only a confirmed transport loss: no exit status or receipt, and not Disconnect or a replacement.
                if connections[id]?.intentionalDisconnect != true { TerminalRuntime.shared.hosts.reconnect.lost(id) }
                if !notice.recoverable {
                    decision(request, .init(credential: notice.credential, exitStatus: notice.status))
                    connections[id]?.originClosed = true
                }
            } else {
                decision(request, .init(credential: notice.credential, exitStatus: notice.status))
                closed(id, credential: notice.credential)
            }
        }
    }

    private func retain(_ id: SSHConnectionID, surfaces requestedSurfaces: Set<UUID>? = nil) {
        guard connections[id]?.normalExit == nil || consumed(id), let request = activeRequest(id), let scope = request.integrationScope,
              let workspace = TerminalRuntime.shared.workspace else { return }
        TerminalRuntime.shared.hosts.synchronize()
        let previous = TerminalRuntime.shared.hosts.reconnect.recipes[id]
        // The old launcher can report its exit after replacement authentication
        // starts. Its facts must not replace the consumers' current restore intent.
        if let previous, previous.restored, previous.origin != request.tabID { return }
        let requested = requestedSurfaces.map { $0.union(previous?.surfaces ?? []) }
        let surfaces = Set(workspace.hosts.terminals.filter { $0.value.generation == id.rawValue }.map(\.key))
            .intersection(workspace.allSurfaceIDs).intersection(requested ?? workspace.allSurfaceIDs)
        guard !surfaces.isEmpty, let host = surfaces.first.flatMap({ workspace.hosts.terminals[$0]?.host }) else { return }
        TerminalRuntime.shared.hosts.reconnect.retain(.init(connection: id, host: host, shell: request.shell, scope: scope,
            accountUID: connections[id]?.greeting?.uid ?? previous?.accountUID,
            boot: connections[id]?.greeting?.boot ?? previous?.boot, origin: request.tabID, launcher: connections[id]?.originClosed == true ? nil : request.origin,
            surfaces: surfaces, backends: previous?.backends ?? []))
    }

    func closed(_ id: SSHConnectionID, credential: String) {
        guard let request = activeRequest(id), request.credential == credential else { return }
        connections[id]?.originClosed = true
        (TerminalRuntime.shared.helpers[.remote(id)] ?? connections[id]?.workspace)?.unobserve(request.tabID)
        TerminalRuntime.shared.hosts.exited(request)
        if hostTints[request.tabID]?.connection == id { hostTints[request.tabID] = nil }
        print("SSH origin closed: connection=\(id), retained=\(consumed(id))")
        if !consumed(id) { finish(id) }
    }
    private func consumed(_ id: SSHConnectionID) -> Bool {
        let runtime = TerminalRuntime.shared
        if let pending = runtime.hosts.reconnect.recipes[id], pending.restored,
           pending.origin != connections[id]?.request.tabID,
           !pending.surfaces.isDisjoint(with: runtime.workspace?.allSurfaceIDs ?? []) { return true }
        let helper = runtime.helpers[.remote(id)] ?? connections[id]?.workspace
        return runtime.workspace?.spaces.contains { space in
            space.remote == id && space.backend.map { helper?.external($0) == true } == true
        } == true
    }
    private func finish(_ id: SSHConnectionID) {
        guard let state = connections[id], state.beginFinishing() else { return }
        let request = state.request
        TerminalRuntime.shared.hosts.reconnect.forget(id)
        if hostTints[request.tabID]?.connection == id { hostTints[request.tabID] = nil }
        state.retireOrigin()
        helperDisconnected(id)
        state.cleanupTask = Task { [weak self, state] in
            defer {
                state.cleanupTask = nil
                if self?.connections[id] === state { self?.connections[id] = nil }
            }
            _ = try? await SSHCommand.run(executable: request.master.executable,
                arguments: request.master.controlArguments("exit"), timeout: 3)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: request.master.controlPath).deletingLastPathComponent())
        }
    }
    /// helper4 runs on the server like the local helper; the same client reaches it over SSH.
    private func startHelper4(_ request: SSHLaunchRequest, state: SSHConnectionState, grant: SSHIntegrationGrant,
                              resources: URL, recovering: Bool, startShell: Bool,
                              prepare: (@MainActor (String, HelperSession.Info) throws -> Void)?) async throws {
        let started = try await SSHBootstrap.startHelper4(master: request.master, resources: resources,
                                                          sessionID: request.sessionID, publish: startShell, prepare: prepare)
        guard !Task.isCancelled, connections[request.connectionID] === state,
              request.integrationScope.flatMap(permissions.remembered).map({ grant.reduced(to: $0) == grant }) == true,
              let identity = started.session.info.identity, let account = started.session.info.account else {
            started.session.close()
            throw HerdrFailure("The SSH helper did not identify its host.")
        }
        let greeting = SSHGreeting(version: 4, host: identity.host, boot: identity.boot, uid: account.uid, home: account.home,
                                   capabilities: started.session.info.ops, hostname: identity.hostname, os: identity.os,
                                   distribution: identity.distribution, osName: identity.os_name, profile: grant.profile)
        do { try greeting.validate() } catch {
            started.session.close()
            throw error
        }
        let runtime = TerminalRuntime.shared
        var restored = runtime.hosts.reconnect.recipes.values.first { $0.restored && $0.origin == request.tabID }
        if var pending = restored, !pending.surfaces.contains(pending.origin) {
            // A temporary authentication shell does not keep dismissed consumers alive.
            let surfaces = pending.surfaces.intersection(runtime.workspace?.allSurfaceIDs ?? [])
            guard !surfaces.isEmpty else { started.session.close(); throw CancellationError() }
            pending.backends = pending.backends.compactMap { entry in
                var entry = entry
                entry.presentation.removeAll { $0.tabs.flatMap(\.surfaceIDs).allSatisfy { !surfaces.contains($0) } }
                return entry.presentation.isEmpty ? nil : entry
            }
            restored = pending
        }
        if let restored {
            guard restored.host == .authenticated(greeting.host),
                  restored.accountUID == nil || restored.accountUID == greeting.uid else {
                started.session.close()
                throw HerdrFailure("The authenticated host or account changed. Open a new connection.")
            }
            runtime.hosts.reconnect.shellStarting(request.connectionID, replacing: restored.connection)
            runtime.hosts.recovered(from: restored.connection.rawValue, request: request)
            if let workspace = runtime.workspace {
                for index in workspace.spaces.indices where workspace.spaces[index].remote == restored.connection {
                    workspace.spaces[index].remote = request.connectionID
                }
            }
        }
        // Publish the ready link together with its workspace and authenticated host.
        // An actor hop after publishing shellPID exposes a partially connected session.
        await HelperApp.shared.borrow(started.session.connection, for: request.connectionID)
        guard !Task.isCancelled, connections[request.connectionID] === state,
              request.integrationScope.flatMap(permissions.remembered).map({ grant.reduced(to: $0) == grant }) == true else {
            await HelperApp.shared.forget(request.connectionID)
            started.session.close()
            throw CancellationError()
        }
        state.helper4 = started.session
        state.granted = grant
        state.greeting = greeting
        if let scope = request.integrationScope, grant.selectedFeatures.contains(.statistics) {
            _ = SSHStatisticsStore.shared.register(HelperStatisticsProvider(id: request.connectionID, scope: scope, greeting: greeting),
                                                   grant: grant, hostID: .authenticated(greeting.host))
        }
        state.helperPath = greeting.home + "/" + started.relativePath
        if let terminal = started.session.info.terminal {
            TerminalRuntime.shared.connect(request.connectionID, terminal: terminal, tab: request.tabID,
                                           granted: Set(grant.selectedFeatures.map(\.rawValue)), host: .authenticated(greeting.host),
                                           previous: state.workspace ?? restored.flatMap { runtime.helpers[.remote($0.connection)] },
                                           retained: restored?.backends ?? [])
            state.workspace = nil
        }
        if !recovering { TerminalRuntime.shared.hosts.authenticated(request, greeting: greeting) }
        hostTints[request.tabID] = (request.connectionID, HostTint(hostID: greeting.hostID))
        Task { [weak self, session = started.session] in
            for await _ in session.exited {}
            guard let self, connections[request.connectionID]?.helper4 === session else { return }
            helperDisconnected(request.connectionID)
        }
        TerminalRuntime.shared.chat.connectHelper(TerminalRuntime.shared.chat.session(for: request.tabID))
        if grant.selectedFeatures.contains(.hooks) { TerminalRuntime.shared.chat.installHelperIntegrations(on: request.connectionID) }
    }

    private static let integrationDisabled = "Chat integration is disabled for this SSH configuration. This transcript is read-only."

    private func helperDisconnected(_ id: SSHConnectionID, shellAvailable: Bool = false) {
        let disabled = connections[id]?.granted?.selectedFeatures.contains(.chat) == false
        if let state = connections[id], let helper = TerminalRuntime.shared.helpers[.remote(id)],
           !helper.detachedRoutes.isEmpty, let greeting = state.greeting {
            helper.recovery = .init(connection: id, host: .authenticated(greeting.host), shell: state.request.shell,
                scope: state.request.integrationScope, accountUID: greeting.uid, boot: greeting.boot,
                origin: state.request.tabID, surfaces: [], restored: true, backends: helper.detachedRoutes)
        }
        if let helper4 = connections[id]?.helper4 {
            connections[id]?.helper4 = nil
            Task { await HelperApp.shared.forget(id) }
            helper4.close()
            TerminalRuntime.shared.chat.helperExited(.remote(id), status: disabled
                ? Self.integrationDisabled : "SSH disconnected. Reconnect from the terminal to continue.", disabled: disabled)
            if let workspace = TerminalRuntime.shared.disconnect(id) { connections[id]?.workspace = workspace }
        }
        if !shellAvailable {
            retain(id)
            TerminalRuntime.shared.hosts.failed(id)
        }

        SSHStatisticsStore.shared.remove(id)
        if connections[id]?.originClosed == true {
            let retained = consumed(id)
            print("SSH helper disconnected after origin exit: connection=\(id), consumers=\(retained)")
            if !retained { finish(id) }
        }
    }

    func closeTab(_ tab: UUID) {
        for request in Array(requests.values) where request.tabID == tab && connections[request.connectionID]?.originClosed != true {
            decision(request, .init(credential: request.credential, exitStatus: 130))
            closed(request.connectionID, credential: request.credential)
        }
        for id in Array(connections.keys) where connections[id]?.originClosed == true && !consumed(id) {
            print("SSH consumers released: connection=\(id), terminal=\(tab)")
            finish(id)
        }
    }

    func savedConnections() -> [HostSessionStore.Connection] {
        let runtime = TerminalRuntime.shared
        guard let workspace = runtime.workspace else { return [] }
        var recipes = runtime.hosts.reconnect.recipes
        for (id, request) in requests {
            let surfaces = Set(workspace.hosts.terminals.filter { $0.value.generation == id.rawValue }.map(\.key))
                .intersection(workspace.allSurfaceIDs)
            guard let host = surfaces.first.flatMap({ workspace.hosts.terminals[$0]?.host }) else { continue }
            // Typed steps: as one expression, slower machines' type checkers gave up on it.
            let previous = recipes[id], helper = runtime.helpers[.remote(id)] ?? connections[id]?.workspace
            let backends: [HelperWorkspace.Detached] = helper?.retained ?? previous?.backends ?? []
            let accountUID: UInt32? = connections[id]?.greeting?.uid ?? previous?.accountUID
            let boot: String? = connections[id]?.greeting?.boot ?? previous?.boot
            recipes[id] = SSHReconnectController.Recipe(connection: id, host: host, shell: request.shell,
                scope: request.integrationScope, accountUID: accountUID, boot: boot,
                origin: request.tabID, surfaces: surfaces, backends: backends)
        }
        return recipes.values.map(HostSessionStore.Connection.init)
    }

    private func resumeRestoredShells(_ recipe: SSHReconnectController.Recipe) {
        let runtime = TerminalRuntime.shared
        guard let workspace = runtime.workspace else { return }
        for tab in workspace.spaces.filter({ $0.remote == nil }).flatMap(\.tabs)
            where (recipe.surfaces.contains(tab.id) || tab.id == recipe.origin) && (recipe.backends.isEmpty || tab.id == recipe.origin) {
            runtime.hosts.reconnect.launchingRestoredShell(tab.id, recipe: recipe)
            workspace.hosts.associate(tab.id, context: .init(host: recipe.host, generation: UUID(), state: .connecting, authenticated: false))
            workspace.helper(containing: tab.id)?.prepare(tab)
            runtime.views[tab.id]?.resumeRestoredSession()
        }
        workspace.focusRequest = UUID()
    }

    /// Detached server work keeps a recipe, not an SSH master. A fresh launcher authenticates
    /// before the helper reopens the saved backend identity (old TmuxCoordinator.restoreDetached).
    func restore(_ saved: SSHReconnectController.Recipe, entries: [HelperWorkspace.Detached]) async throws {
        let runtime = TerminalRuntime.shared
        guard let workspace = runtime.workspace else { throw CancellationError() }
        var previous = runtime.hosts.reconnect.recipes[saved.connection]
        previous?.backends = entries
        var tab = TerminalTab(directory: Home.url.path); tab.machine = .ssh(saved.shell)
        var login = Space(name: "Reconnect", tab: tab); login.hostID = saved.host
        let recipe = SSHReconnectController.Recipe(connection: saved.connection, host: saved.host, shell: saved.shell, scope: saved.scope,
            accountUID: saved.accountUID, boot: saved.boot, origin: tab.id,
            surfaces: previous?.surfaces ?? Set(entries.flatMap(\.presentation).flatMap { $0.tabs.flatMap(\.surfaceIDs) }).union([tab.id]),
            restored: true, backends: entries)
        workspace.addSpace(login)
        runtime.hosts.restore(recipe)
        var completed = false
        defer {
            let attempts = Array(requests.values.filter { $0.tabID == tab.id })
            // A temporary launcher is retired now, not when its eventual process-exit
            // callback arrives. Its external consumers own the surviving connection.
            for request in attempts {
                if completed { closed(request.connectionID, credential: request.credential) }
                else { finish(request.connectionID) }
            }
            workspace.closeTab(tab.id, policy: .terminate)
            runtime.hosts.reconnect.forget(recipe.connection)
            if !completed, var previous {
                previous.surfaces.formIntersection(workspace.allSurfaceIDs)
                if !previous.surfaces.isEmpty {
                    let generations = Set(attempts.map { $0.connectionID.rawValue })
                    for surface in previous.surfaces {
                        guard let context = workspace.hosts.terminals[surface],
                              generations.contains(context.generation) else { continue }
                        workspace.hosts.associate(surface, context: .init(host: context.host,
                            generation: previous.connection.rawValue, state: .disconnected, authenticated: false))
                        workspace.hostPlacements[surface]?.generation = previous.connection.rawValue
                    }
                    for index in workspace.spaces.indices where workspace.spaces[index].remote.map({ generations.contains($0.rawValue) }) == true {
                        workspace.spaces[index].remote = previous.connection
                    }
                    runtime.hosts.reconnect.retain(previous)
                }
            }
            print("SSH consumer restore settled: connection=\(recipe.connection), completed=\(completed), retained=\(previous?.surfaces.count ?? 0)")
        }
        try await recover(recipe)
        completed = true
        if let space = entries.first?.presentation.first { workspace.selectSpace(space.id) }
    }

    /// An automatic attempt shows nothing: no consent sheet, no login sheet or tab, keys and the agent only.
    func recover(_ recipe: SSHReconnectController.Recipe, automatic: Bool = false) async throws {
        let runtime = TerminalRuntime.shared
        let spaces = Set(runtime.workspace?.spaces.filter {
            $0.structured && $0.tabs.flatMap(\.surfaceIDs).contains(where: recipe.surfaces.contains)
        }.map(\.id) ?? [])
        let old = activeRequest(recipe.connection)
        guard old != nil || recipe.restored, Bundle.main.resourceURL != nil else { throw HerdrFailure("The original connection is no longer available.") }
        // Without its launcher, recovery logs in through a new tab, which an automatic attempt never opens.
        if automatic, recipe.restored || connections[recipe.connection]?.originClosed == true || recipe.launcher == nil {
            throw SSHAutomaticFailure.refused("Its SSH login tab is closed. Reconnect to log in again.")
        }
        // A saved connection may outlive its launching tab. Authenticate through a temporary
        // shell instead of waiting for an absent origin to restart itself.
        if recipe.restored, runtime.workspace?.allSurfaceIDs.contains(recipe.origin) != true, !recipe.backends.isEmpty {
            try await restore(recipe, entries: recipe.backends)
            return
        }
        // A restored tab's shell starts again by itself; its spaces' backends reattach when the host's helper is back.
        if recipe.restored {
            if recipe.backends.isEmpty { runtime.hosts.reconnect.forget(recipe.connection) }
            resumeRestoredShells(recipe)
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            for _ in 0... {
                let consumers = runtime.hosts.reconnect.recipes[recipe.connection]?.surfaces ?? []
                let retained = Set(recipe.backends.flatMap(\.presentation).filter { space in
                    recipe.surfaces.contains(recipe.origin) || space.tabs.flatMap(\.surfaceIDs).contains(where: consumers.contains)
                }.map(\.id))
                if !recipe.surfaces.contains(recipe.origin), retained.isEmpty { throw CancellationError() }
                if retained.isEmpty { break }
                try Task.checkCancellation()
                if let state = connections.values.first(where: { $0.request.tabID == recipe.origin }) {
                    if let failure = state.launchFailure { throw failure }
                    if let failure = runtime.helpers[.remote(state.id)]?.error { throw HerdrFailure(failure) }
                }
                let restored = Set(runtime.workspace?.spaces.compactMap { space -> UUID? in
                    guard retained.contains(space.id), let connection = space.remote,
                          connection != recipe.connection, let helper = runtime.helpers[.remote(connection)] else { return nil }
                    if helper.error != nil { return nil }
                    return space.backend.flatMap { helper.multiplexer(of: $0) } != nil
                        && !helper.isRestoring(space.id) ? space.id : nil
                } ?? [])
                if retained.isSubset(of: restored) { break }
                guard ContinuousClock.now < deadline else {
                    throw HerdrFailure("The SSH shell reconnected, but its retained terminal spaces did not restore.")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            runtime.hosts.reconnect.forget(recipe.connection)
            print("SSH restored consumers ready: connection=\(recipe.connection), surfaces=\(recipe.surfaces.count)")
            for surface in recipe.surfaces { runtime.views[surface]?.resumeRestoredSession() }
            return
        }
        if connections[recipe.connection]?.originClosed == true || recipe.launcher == nil {
            let helper = runtime.helpers[.remote(recipe.connection)] ?? connections[recipe.connection]?.workspace
            let entries = recipe.backends.isEmpty ? helper?.retained ?? [] : recipe.backends
            guard !entries.isEmpty else { throw HerdrFailure("The retained terminal spaces are no longer available.") }
            print("SSH consumer restore starting: connection=\(recipe.connection), backends=\(entries.count), surfaces=\(recipe.surfaces.count)")
            try await restore(recipe, entries: entries)
            finish(recipe.connection)
            return
        }
        guard HostProcessWatcher.alive(recipe.launcher) else { throw HerdrFailure("The SSH launcher has closed. Open a new terminal to connect.") }
        let invocation = SSHInvocation(options: recipe.shell.options, destination: recipe.shell.destination, command: nil, forcedTTY: false)
        let configuration = await Task.detached { [executable = recipe.shell.executable] in
            SSHLauncherCommand.resolvedConfiguration(invocation, executable: executable)
        }.value
        guard let configuration, let scope = SSHIntegrationScope(executable: recipe.shell.executable, destination: recipe.shell.destination, configuration: configuration), scope == recipe.scope else {
            throw HerdrFailure("The SSH account or configuration changed. Open a new connection for the changed identity.")
        }
        let window = recipe.surfaces.compactMap { runtime.views[$0]?.window }.first
            ?? runtime.workspace?.activeSurfaceID.flatMap { runtime.views[$0]?.window }
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.sheetParent == nil }
        let grant = automatic ? permissions.remembered(scope)
            : await permissions.choose(scope, present: { [weak self] in await self?.newHostSelection($0, window: window) })
        guard let grant, grant.profile != .ordinary else { throw CancellationError() }
        try Task.checkCancellation()
        // The helper can fail while the old master is still alive. Retire only
        // this recipe's private master so its launcher can consume the resume.
        if let old {
            connections[recipe.connection]?.intentionalDisconnect = true
            _ = try? await SSHCommand.run(executable: old.master.executable, arguments: old.master.controlArguments("exit"), timeout: 3)
        }
        try Task.checkCancellation()
        let id = SSHConnectionID()
        let folder = runtime.herdrLaunch.directory.appendingPathComponent("s-" + id.rawValue.uuidString.prefix(12))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let master = SSHMaster(executable: recipe.shell.executable, controlPath: folder.appendingPathComponent("master").path, destination: recipe.shell.destination)
        var committed = false
        var replacement: SSHConnectionState?
        defer {
            if !committed {
                if let replacement {
                    if connections[id] === replacement { finish(id) }
                } else {
                    // Authentication failed before an owner could be installed.
                    Task {
                        _ = try? await SSHCommand.run(executable: master.executable, arguments: master.controlArguments("exit"), timeout: 3)
                        try? FileManager.default.removeItem(at: folder)
                    }
                }
            }
        }
        if automatic { try await SSHReconnectLogin.authenticateSilently(shell: recipe.shell, master: master) }
        else { try await SSHReconnectLogin.authenticate(shell: recipe.shell, master: master, window: window) }
        try Task.checkCancellation()
        let request = SSHLaunchRequest(tabID: recipe.origin, token: old?.token ?? "", connectionID: id, credential: UUID().uuidString,
            master: master, shell: recipe.shell, integrationScope: scope, integrationGrant: grant, origin: recipe.launcher)
        launch(request, recovering: true) { [self] path, info in
            try Task.checkCancellation()
            guard let identity = info.identity, let account = info.account,
                  HostID.authenticated(identity.host) == recipe.host,
                  recipe.accountUID == nil || recipe.accountUID == account.uid,
                  !recipe.surfaces.isDisjoint(with: runtime.workspace?.allSurfaceIDs ?? []),
                  runtime.hosts.reconnect.contains(recipe.connection.rawValue) else {
                throw HerdrFailure("The authenticated host changed or the retained tabs were closed.")
            }
            guard activeRequest(recipe.connection) != nil, permissions.remembered(scope) == grant else { throw CancellationError() }
            guard let old, HostProcessWatcher.alive(recipe.launcher) else { throw HerdrFailure("The original SSH launcher closed during authentication.") }
            connections[id]?.helperPath = account.home + "/" + path
            connections[id]?.workspace = connections[recipe.connection]?.workspace
            runtime.hosts.recovered(from: recipe.connection.rawValue, request: request)
            runtime.hosts.reconnect.retain(.init(connection: id, host: recipe.host, shell: recipe.shell, scope: scope,
                accountUID: account.uid, boot: identity.boot, origin: recipe.origin, launcher: recipe.launcher, surfaces: recipe.surfaces))
            runtime.hosts.reconnect.shellStarting(id, replacing: recipe.connection)
            decision(old, .init(credential: old.credential, launch: request))
            // The launcher owns this generation even if its new shell fails to start.
            finish(recipe.connection)
            committed = true
        }
        replacement = connections[id]
        do {
            await connections[id]?.launchTask?.value
            if let error = connections[id]?.launchFailure { throw error }
            try Task.checkCancellation()
            guard committed, let state = connections[id], state.granted == grant,
                  state.helper4?.info.process != nil, let greeting = state.greeting,
                  HostID.authenticated(greeting.host) == recipe.host,
                  recipe.accountUID == nil || recipe.accountUID == greeting.uid,
                  permissions.remembered(scope) == grant else {
                throw HerdrFailure("The replacement SSH shell did not start. Retry to reconnect.")
            }
            // Authentication does not make retained renderers writable: their original
            // spaces must be published and rebound by the replacement helper first.
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            for _ in 0... {
                try Task.checkCancellation()
                let helper = runtime.helpers[.remote(id)]
                let restored = Set(runtime.workspace?.spaces.filter { space in
                    space.remote == id && space.backend.flatMap { helper?.multiplexer(of: $0) } != nil
                        && helper?.isRestoring(space.id) == false
                }.map(\.id) ?? [])
                if spaces.isSubset(of: restored) { break }
                if let error = helper?.error { throw HerdrFailure(error) }
                guard ContinuousClock.now < deadline else {
                    throw HerdrFailure("The SSH shell reconnected, but its retained terminal spaces did not restore.")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            print("SSH reconnect ready: connection=\(id), restored=\(spaces)")
            runtime.hosts.reconnect.forget(id)
        } catch {
            if committed {
                disconnect(generations: [id.rawValue])
                let failure = HerdrFailure("The replacement SSH shell did not start. " + error.localizedDescription)
                runtime.hosts.reconnect.shellFailed(id, error: failure)
            }
            throw error
        }
    }

    func hasConnections(in generations: Set<UUID>) -> Bool {
        requests.keys.contains { generations.contains($0.rawValue) && !TerminalRuntime.shared.hosts.reconnect.contains($0.rawValue) }
    }

    var hasActiveConnections: Bool {
        requests.keys.contains { !TerminalRuntime.shared.hosts.reconnect.contains($0.rawValue) }
    }

    var originSurfaces: Set<UUID> { Set(requests.values.map(\.tabID)) }

    func disconnect(generations: Set<UUID>) {
        for id in Array(requests.keys) where generations.contains(id.rawValue) {
            connections[id]?.intentionalDisconnect = true
            TerminalRuntime.shared.helpers[.remote(id)]?.cancelRestores()
            connections[id]?.launchTask?.cancel()
            retain(id)
            helperDisconnected(id)
            if let request = activeRequest(id) {
                Task { _ = try? await SSHCommand.run(executable: request.master.executable, arguments: request.master.controlArguments("exit"), timeout: 3) }
            }
        }
    }
    @discardableResult
    func reset(pending: [SSHLaunchRequest] = []) -> Task<Void, Never> {
        // Release launchers waiting for recovery back to their local shell.
        for request in requests.values {
            decision(request, .init(credential: request.credential, exitStatus: 130))
        }
        // A ready mailbox request can race with reset before bootstrap owns it.
        // The connecting announcement carries the same private path/credential.
        let unowned = pending.filter { connections[$0.connectionID] == nil }
        for request in unowned { decision(request, .init(credential: request.credential, exitStatus: 130)) }
        let cleanup = stop()
        scopeHosts.removeAll(); terminalScopes.removeAll()
        permissions.resetAll()
        return Task {
            for request in unowned {
                _ = try? await SSHCommand.run(executable: request.master.executable, arguments: request.master.controlArguments("exit"), timeout: 3)
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: request.master.controlPath).deletingLastPathComponent())
            }
            await cleanup.value
        }
    }

    func resetHost(_ host: HostID, generations: Set<UUID>, surfaces: Set<UUID>, pending: [SSHLaunchRequest]) {
        let entries = integrationEntries(for: host)
        let unowned = pending.filter { connections[$0.connectionID] == nil }
        for id in Array(requests.keys) where generations.contains(id.rawValue) {
            if let request = activeRequest(id) { decision(request, .init(credential: request.credential, exitStatus: 130)) }
            finish(id)
        }
        for request in unowned {
            decision(request, .init(credential: request.credential, exitStatus: 130))
            Task {
                _ = try? await SSHCommand.run(executable: request.master.executable, arguments: request.master.controlArguments("exit"), timeout: 3)
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: request.master.controlPath).deletingLastPathComponent())
            }
        }
        for entry in entries { permissions.reset(entry.scope) }
        scopeHosts[host] = nil
        for surface in surfaces { terminalScopes[surface] = nil }
    }

    @discardableResult
    func stop() -> Task<Void, Never> {
        for id in Array(requests.keys) { finish(id) }
        for state in connections.values { state.intentionalDisconnect = false }
        hostTints.removeAll()
        // Include cleanup started by an earlier close as well as this stop.
        // Its private control paths must survive until ssh -O exit completes.
        let pending = connections.values.compactMap(\.cleanupTask)
        return Task { for cleanup in pending { await cleanup.value } }
    }
}
