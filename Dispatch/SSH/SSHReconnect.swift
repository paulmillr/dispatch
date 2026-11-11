import AppKit
import Network
import Observation

/// Why an automatic reconnect stopped short. An unreachable host, and a login whose later steps did not finish in time
/// (`interrupted`: a slow link), are tried again by themselves; a refusal (a password or passphrase, a changed host key,
/// a closed login tab) waits for Reconnect.
enum SSHAutomaticFailure: LocalizedError {
    case unreachable(String)
    case refused(String)
    case interrupted(String)
    var errorDescription: String? {
        switch self { case .unreachable(let message), .refused(let message), .interrupted(let message): message }
    }

    /// Whether automatic reconnect tries again after an attempt failed with `error`.
    static func retries(after error: Error) -> Bool {
        switch error as? SSHAutomaticFailure {
        case .unreachable?, .interrupted?: true
        case .refused?, nil: false
        }
    }

    /// Whether a recovery step after the login failed in a way another attempt may pass: a step or the whole setup ran
    /// out of time, a setup step's transient failure (`SSHSetupFailure.transient`), or the replacement shell or its
    /// spaces not ready in time (`SSHRecoveryIncomplete`). Never a cancellation, a permanent setup failure, a changed
    /// host, grant or launcher.
    static func transient(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if error is SSHRecoveryIncomplete { return true }
        if let failure = error as? SSHSetupFailure { return failure.reason == SSHSetupFailure.timedOut || SSHSetupFailure.transient(failure) }
        if let failure = error as? HerdrFailure {
            return [SSHTimeout.message, SSHCommand.timedOut, SSHCommand.stalled(SSHBootstrap.uploadStall)].contains(failure.message)
        }
        return false
    }
}

/// A replacement shell, or the spaces it restores, not ready in time: on a slow link another attempt may pass.
struct SSHRecoveryIncomplete: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One retained connection owns its consumers, even when another login to the
/// same physical host is healthy. Recipes never retain a master or credential.
@MainActor @Observable
final class SSHReconnectController {
    struct Recipe {
        let connection: SSHConnectionID
        let host: HostID
        let shell: SSHShell
        let scope: SSHIntegrationScope?
        var accountUID: UInt32? = nil
        var boot: String? = nil
        let origin: UUID
        var launcher: AgentProcess?
        var surfaces: Set<UUID>
        var restored = false
        var backends: [HelperWorkspace.Detached] = []

        /// Whether a helper's report is this recipe's login. A connection saved without its account, when a host was a
        /// machine, can only be held to the machine.
        func isLogin(machine: String, uid: UInt32) -> Bool {
            guard let accountUID else { return host == .authenticated(machine, uid: uid) || host == .authenticated(machine) }
            return accountUID == uid && host == .authenticated(machine, uid: uid)
        }
    }
    struct State: Equatable {
        var reconnecting = false
        var error: String?
        var attempted = false
        var connected = false
        var disconnectedAt: Date?
        var attempts = 0
        /// When automatic reconnect tries this connection again.
        var retryAt: Date?
        /// The tab's terminal no longer exists on its server (closed there while the app was away): the reconnect
        /// kept the tab, read-only, with what it showed (`TerminalTab.gone`).
        var gone = false
        /// What the attempt is doing now, for the strip (checking the configuration, logging in, restoring spaces).
        var step: String?
    }
    /// A prompt ssh asks a host's login through `SSHAskpassCommand`, answered in the strip.
    struct Prompt: Equatable {
        let request: SSHAskpassRequest
        /// The same question again after an answer: ssh refused it (a wrong password).
        var retry = false
        var kind: SSHAskpassRequest.Kind { request.kind }
        var text: String { request.prompt }
    }
    /// One line of a host's reconnect log: a step of the attempt (with its time), ssh's own output, or a problem.
    struct LogLine: Equatable, Identifiable {
        enum Kind: Equatable { case step, output, prompt, problem }
        let id: Int
        let time: Date?
        let text: String
        let kind: Kind
    }
    /// What ssh asks each host's login now.
    private(set) var prompts: [HostID: Prompt] = [:]
    /// Each host's reconnect log, newest last (at most `logLimit` lines), kept until its connections recover.
    private(set) var logs: [HostID: [LogLine]] = [:]
    static let logLimit = 400
    /// Hosts whose login ssh asks on its own terminal (one without SSH_ASKPASS_REQUIRE): the strip points at the log.
    private(set) var awaitingTerminal: Set<HostID> = []
    /// Surfaces whose strip shows its host's log.
    var logShown: Set<UUID> = []
    /// Where each host's current attempt was asked from: its prompt takes the keyboard there.
    private(set) var sources: [HostID: UUID] = [:]
    /// Hosts whose login terminal runs, so the log can type into it.
    private(set) var loginsRunning: Set<HostID> = []
    /// A login terminal's identity (what its ssh asks under), its host and the exact ssh executable it starts.
    private struct Login { let host: HostID; let executable: String }
    @ObservationIgnored private var logins: [UUID: Login] = [:]
    @ObservationIgnored private var loginInputs: [HostID: (Data) -> Void] = [:]
    /// Ends a login terminal (Cancel), by its identity.
    @ObservationIgnored private var loginClosers: [UUID: () -> Void] = [:]
    /// The login output's unfinished last line: a prompt ssh asks on its terminal ends there.
    @ObservationIgnored private var partial: [HostID: String] = [:]
    /// The prompt last answered for a host, to tell ssh asking it again.
    @ObservationIgnored private var answered: [HostID: String] = [:]
    @ObservationIgnored private var logCount = 0
    private(set) var states: [SSHConnectionID: State] = [:]
    private(set) var completed: [UUID: UUID] = [:]
    @ObservationIgnored private(set) var recipes: [SSHConnectionID: Recipe] = [:]
    @ObservationIgnored private var replacements: [SSHConnectionID: SSHConnectionID] = [:]
    @ObservationIgnored private weak var runtime: TerminalRuntime?
    @ObservationIgnored private var operations: [HostID: Task<Void, Never>] = [:]
    @ObservationIgnored private var epochs: [HostID: UUID] = [:]
    @ObservationIgnored private var loginBusy = false
    @ObservationIgnored private var launchingShells: [UUID: Recipe] = [:]
    /// Restored output a launching shell replays, kept until it logs in so a retry shows it again.
    @ObservationIgnored private var launchingHistory: [UUID: String] = [:]
    // Injectable attempt boundary exercises coalescing and late completion.
    @ObservationIgnored var attempt: (@MainActor (Recipe) async throws -> Void)?
    /// Settings' automatic reconnect. Turning it off cancels pending retries; on resumes them.
    @ObservationIgnored var automatic = false {
        didSet {
            guard automatic != oldValue else { return }
            if automatic {
                watch()
                for host in Set(recipes.values.filter { losses.contains($0.connection) }.map(\.host)) { schedule(host, after: .seconds(1)) }
            } else {
                unwatch()
                for host in Array(retries.keys) { retries.removeValue(forKey: host)?.cancel() }
                for id in Array(states.keys) where states[id]?.retryAt != nil { states[id]?.retryAt = nil }
            }
        }
    }
    /// Connections lost while Dispatch ran, not explicitly disconnected or restored at launch:
    /// the only ones reconnected automatically, until you reconnect, cancel or close them yourself.
    @ObservationIgnored private var losses: Set<SSHConnectionID> = []
    @ObservationIgnored private var retries: [HostID: Task<Void, Never>] = [:]
    /// Unreachable attempts, or drops soon after the last, in a row: they space retries out.
    @ObservationIgnored private var failures: [HostID: Int] = [:]
    @ObservationIgnored private var dropped: [HostID: Date] = [:]
    @ObservationIgnored private var network: NWPathMonitor?
    /// Whether the network monitor reported the path it started on: that first report is no change.
    @ObservationIgnored private var reported = false
    @ObservationIgnored private var wake: (any NSObjectProtocol)?

    init(runtime: TerminalRuntime) { self.runtime = runtime }
    func state(for surface: UUID) -> State? {
        guard launchingShells[surface] == nil, let context = runtime?.workspace?.hosts.terminals[surface] else { return nil }
        let generation = SSHConnectionID(context.generation)
        let id = recipes[generation] == nil ? replacements[generation] ?? generation : generation
        guard let recipe = recipes[id], recipe.host == context.host, recipe.surfaces.contains(surface) else { return nil }
        return states[id]
    }
    func presentationState(for surface: UUID) -> State? {
        if let state = state(for: surface) { return state }
        if runtime?.workspace?.isGone(surface) == true { return State(gone: true) }
        // A restored shell logging in again in its own tab: the strip carries what its ssh asks.
        if launchingShells[surface] != nil { return State(reconnecting: true, attempted: true, step: "logging in") }
        return completed[surface] == nil ? nil : State(connected: true)
    }
    /// The tab shows the reconnect bar (`SSHReconnectOverlay`): its own state, gone, logging in again or just
    /// connected, or another host's login asking here. What else would say the connection is down (chat's status line)
    /// waits while it does.
    func showsBar(for surface: UUID) -> Bool {
        presentationState(for: surface) != nil || orphan(for: surface) != nil
    }
    func retain(_ recipe: Recipe) {
        for surface in recipe.surfaces { completed[surface] = nil }
        recipes[recipe.connection] = recipe
        if states[recipe.connection] == nil {
            states[recipe.connection] = State(disconnectedAt: Date())
            log(recipe.host, recipe.restored ? "saved connection, offline until you reconnect" : "disconnected", kind: .step)
        }
        for surface in recipe.surfaces { runtime?.views[surface]?.updateFocus() }
    }
    func launchingRestoredShell(_ surface: UUID, recipe: Recipe) {
        launchingShells[surface] = .init(connection: SSHConnectionID(), host: recipe.host, shell: recipe.shell,
            scope: recipe.scope, origin: surface, surfaces: [surface], restored: true)
        launchingHistory[surface] = runtime?.restoredHistory[surface]
    }
    /// A restored tab's shell logging in again (`launchingRestoredShell`): its ssh asks through the strip.
    func launchingRestored(_ surface: UUID) -> Bool { launchingShells[surface] != nil }
    func shellAuthenticated(_ surface: UUID) { launchingShells[surface] = nil; launchingHistory[surface] = nil }
    func restoredShellExited(_ surface: UUID) -> Bool {
        guard let recipe = launchingShells.removeValue(forKey: surface), let runtime,
              runtime.workspace?.allSurfaceIDs.contains(surface) == true else { return false }
        let history = launchingHistory.removeValue(forKey: surface)
        runtime.close([surface])
        if let history { runtime.restoredHistory[surface] = history }
        runtime.hosts.restore(recipe)
        states[recipe.connection]?.error = "SSH did not connect. Retry to log in again."
        states[recipe.connection]?.attempted = true
        runtime.workspace?.focusRequest = System.uuid()
        return true
    }
    func awaitingRestore(_ surface: UUID) -> Bool {
        launchingShells[surface] == nil && recipes.values.contains {
            $0.restored && $0.surfaces.contains(surface)
                && (surface != $0.origin || runtime?.workspace?.hosts.terminals[surface]?.generation == $0.connection.rawValue)
        }
    }
    func contains(_ generation: UUID) -> Bool { recipes[SSHConnectionID(generation)] != nil }
    func shellStarting(_ id: SSHConnectionID, replacing previous: SSHConnectionID) {
        replacements[id] = previous
        guard states[id] != nil else { return }
        if let previous = states[previous] { states[id] = previous }
        states[id]?.reconnecting = true
        states[id]?.attempted = true
    }
    func shellFailed(_ id: SSHConnectionID, error: Error) {
        guard states[id] != nil else { return }
        states[id]?.reconnecting = false
        states[id]?.error = error is CancellationError ? nil : error.localizedDescription
    }
    /// An automatic attempt never prompts and covers only lost connections; your own takes over from it.
    func reconnect(hostID: HostID, sourceSurfaceID: UUID, scope: SSHIntegrationScope? = nil, automatic: Bool = false) {
        guard operations[hostID] == nil,
              runtime?.workspace?.hosts.terminals[sourceSurfaceID]?.host == hostID else { return }
        var ids = recipes.values.filter { $0.host == hostID && (scope == nil || $0.scope == scope) }.map(\.connection)
        if automatic { ids = ids.filter(losses.contains) } else { stopRetrying(hostID) }
        guard !ids.isEmpty else { return }
        if !automatic { sources[hostID] = sourceSurfaceID }
        log(hostID, automatic ? "reconnecting automatically" : "reconnecting", kind: .step)
        let epoch = System.uuid(); epochs[hostID] = epoch
        for id in ids {
            var state = states[id] ?? State(disconnectedAt: Date())
            state.reconnecting = true; state.attempted = true; state.attempts += 1; state.retryAt = nil
            states[id] = state
        }
        operations[hostID] = Task { [weak self] in
            guard let self else { return }
            var unreachable = false
            defer {
                if epochs[hostID] == epoch { operations[hostID] = nil; epochs[hostID] = nil; endLogin(hostID) }
                // Every connection of the host recovered: its log has nothing left to explain.
                if !recipes.values.contains(where: { $0.host == hostID }) { clearLog(hostID) }
            }
            // Serialize login sheets across hosts, as well as within one host.
            while loginBusy {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            loginBusy = true
            defer { loginBusy = false }
            for id in ids {
                guard !Task.isCancelled, epochs[hostID] == epoch, let recipe = recipes[id],
                      !recipe.surfaces.isDisjoint(with: runtime?.workspace?.allSurfaceIDs ?? []) else { continue }
                runtime?.workspace?.hostMoveMotion.connecting.formUnion(recipe.surfaces)
                defer { runtime?.workspace?.hostMoveMotion.connecting.subtract(recipe.surfaces) }
                do {
                    if let attempt { try await attempt(recipe) }
                    else { try await runtime?.ssh.recover(recipe, automatic: automatic) }
                    guard !Task.isCancelled, epochs[hostID] == epoch,
                          !recipe.surfaces.isDisjoint(with: runtime?.workspace?.allSurfaceIDs ?? []),
                          recipes[id] != nil || recipe.surfaces.contains(where: {
                              guard let context = runtime?.workspace?.hosts.terminals[$0] else { return false }
                              return context.generation != id.rawValue && context.state == .connected
                          }) else { continue }
                    recipes[id] = nil; states[id] = nil; losses.remove(id)
                    let token = System.uuid()
                    for surface in recipe.surfaces {
                        completed[surface] = token
                        runtime?.views[surface]?.updateFocus()
                    }
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(600))
                        guard let self else { return }
                        for surface in recipe.surfaces where self.completed[surface] == token { self.completed[surface] = nil }
                    }
                } catch {
                    guard epochs[hostID] == epoch else { continue }
                    let retry = automatic && SSHAutomaticFailure.retries(after: error)
                    guard recipes[id] != nil else {
                        // The replacement had started (its login worked) and then failed: it is the lost connection now.
                        let successors = replacements.filter { $0.value == id && recipes[$0.key] != nil }.map(\.key)
                        losses.remove(id)
                        if retry, !successors.isEmpty { losses.formUnion(successors); unreachable = true }
                        continue
                    }
                    var state = states[id] ?? State()
                    state.reconnecting = false; state.step = nil
                    state.error = error is CancellationError ? nil : error.localizedDescription
                    log(hostID, error is CancellationError ? "cancelled" : error.localizedDescription, kind: error is CancellationError ? .step : .problem)
                    states[id] = state
                    if retry { unreachable = true } else { losses.remove(id) }
                }
                runtime?.workspace?.hostMoveMotion.connecting.subtract(recipe.surfaces)
            }
            guard automatic, unreachable, epochs[hostID] == epoch else { return }
            schedule(hostID, after: backoff(hostID))
        }
    }
    /// A transport loss (not an explicit disconnect): with automatic reconnect on, its host logs back in by itself.
    /// A loss during an attempt belongs to that attempt; one soon after the last backs off.
    func lost(_ id: SSHConnectionID) {
        guard let host = recipes[id]?.host, operations[host] == nil, losses.insert(id).inserted, retries[host] == nil else { return }
        let recent = dropped[host].map { Date().timeIntervalSince($0) < 60 } == true
        dropped[host] = Date()
        if recent { schedule(host, after: backoff(host)) }
        else { failures[host] = nil; schedule(host, after: .seconds(1)) }
    }
    /// 2, 4, 8… seconds apart, at most a minute; waking or a network change tries sooner.
    private func backoff(_ host: HostID) -> Duration {
        let count = (failures[host] ?? 0) + 1
        failures[host] = count
        return .seconds(min(60, 1 << min(count, 6)))
    }
    /// The Mac woke or its network changed: pending retries run now rather than after their backoff.
    func retryNow() {
        for host in Array(retries.keys) {
            failures[host] = nil
            schedule(host, after: .zero)
        }
    }
    private func schedule(_ host: HostID, after delay: Duration) {
        retries.removeValue(forKey: host)?.cancel()
        let ids = recipes.values.filter { $0.host == host && losses.contains($0.connection) }.map(\.connection)
        guard automatic, !ids.isEmpty else { return }
        let at = Date().addingTimeInterval(TimeInterval(delay.components.seconds))
        for id in ids { states[id]?.retryAt = at }
        retries[host] = Task { [weak self] in
            do { try await System.sleep(for: delay, "retry") } catch { return }
            guard let self, automatic else { return }
            retries[host] = nil
            // A login sheet or earlier attempt still running settles first; yours ends the retries.
            guard operations[host] == nil else { return schedule(host, after: .seconds(1)) }
            let surface = recipes.values.filter { $0.host == host && losses.contains($0.connection) }.flatMap(\.surfaces)
                .first { runtime?.workspace?.hosts.terminals[$0]?.host == host }
            if let surface { reconnect(hostID: host, sourceSurfaceID: surface, automatic: true) }
        }
    }
    private func stopRetrying(_ host: HostID) {
        retries.removeValue(forKey: host)?.cancel()
        failures[host] = nil
        for recipe in recipes.values where recipe.host == host {
            losses.remove(recipe.connection)
            if states[recipe.connection]?.retryAt != nil { states[recipe.connection]?.retryAt = nil }
        }
    }
    private func watch() {
        let network = NWPathMonitor()
        reported = false
        network.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if satisfied, self.reported { self.retryNow() }
                    self.reported = true
                }
            }
        }
        network.start(queue: .global(qos: .utility))
        self.network = network
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryNow() }
        }
    }
    private func unwatch() {
        network?.cancel(); network = nil
        if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }
        wake = nil
    }
    func cancel(hostID: HostID) {
        stopRetrying(hostID)
        epochs[hostID] = nil
        if operations.removeValue(forKey: hostID).map({ $0.cancel() }) != nil { log(hostID, "cancelled", kind: .step) }
        endLogin(hostID)
        // A login no attempt of this controller runs (a detached space's restore) ends with its terminal.
        for (identity, login) in logins where login.host == hostID { loginClosers[identity]?() }
        for recipe in recipes.values where recipe.host == hostID {
            var state = states[recipe.connection] ?? State()
            state.reconnecting = false; state.attempted = true; state.error = nil; state.step = nil
            states[recipe.connection] = state
            runtime?.workspace?.hostMoveMotion.connecting.subtract(recipe.surfaces)
        }
    }
    func close(_ surface: UUID) {
        launchingShells[surface] = nil; launchingHistory[surface] = nil
        completed[surface] = nil
        let affectedHosts = Set(recipes.values.filter { $0.surfaces.contains(surface) }.map(\.host))
        for id in Array(recipes.keys) {
            recipes[id]?.surfaces.remove(surface)
            if recipes[id]?.origin == surface { recipes[id]?.launcher = nil }
            if recipes[id]?.surfaces.isEmpty == true { recipes[id] = nil; states[id] = nil }
        }
        replacements = replacements.filter { recipes[$0.key] != nil || recipes[$0.value] != nil }
        losses.formIntersection(recipes.keys)
        for host in affectedHosts where !recipes.values.contains(where: { $0.host == host }) { cancel(hostID: host) }
    }
    func forget(_ id: SSHConnectionID) {
        let surfaces = recipes.removeValue(forKey: id)?.surfaces ?? []
        states[id] = nil; losses.remove(id)
        replacements = replacements.filter { $0.key != id && $0.value != id }
        guard !surfaces.isEmpty else { return }
        runtime?.workspace?.updateLayout { next in
            @MainActor func ready(_ arrangement: inout PaneArrangement) {
                for pane in arrangement.panes.indices {
                    for tab in arrangement.panes[pane].tabs.indices {
                        let value = arrangement.panes[pane].tabs[tab]
                        if surfaces.contains(value.id), value.terminal != nil, !awaitingRestore(value.id) {
                            arrangement.panes[pane].tabs[tab].isConnecting = false
                        }
                    }
                }
            }
            for space in next.spaces.indices {
                if next.spaces[space].containers.isEmpty { ready(&next.spaces[space].arrangement) }
                else { for container in next.spaces[space].containers.indices { ready(&next.spaces[space].containers[container].arrangement) } }
            }
        }
    }
    func stop() {
        for host in Array(operations.keys) { cancel(hostID: host) }
        automatic = false
        losses.removeAll(); failures.removeAll(); dropped.removeAll()
        recipes.removeAll(); replacements.removeAll(); states.removeAll(); completed.removeAll(); launchingShells.removeAll(); launchingHistory.removeAll()
        logs.removeAll(); logShown.removeAll(); sources.removeAll(); partial.removeAll(); answered.removeAll()
    }

    // MARK: Login: prompts and log

    /// The host a login terminal's ssh (`SSHAskpassRequest.tabID`) or a restored tab's (`terminal`) asks for, while it
    /// logs in.
    func host(asking request: SSHAskpassRequest) -> HostID? {
        if let terminal = request.terminal {
            guard let recipe = launchingShells[terminal], request.isFromSSH(executable: recipe.shell.executable) else { return nil }
            return runtime?.workspace?.hosts.terminals[terminal]?.host
        }
        guard let login = logins[request.tabID], request.isFromSSH(executable: login.executable) else { return nil }
        return login.host
    }

    /// ssh asks: the strip of every tab of the host shows it (`orphan` when none is open). An ssh that is no login of
    /// this app's, or of a restored tab logging in again, is refused.
    func ask(_ request: SSHAskpassRequest) {
        guard let host = host(asking: request), let directory = runtime?.herdrLaunch.directory else {
            if let directory = runtime?.herdrLaunch.directory { SSHAskpass.reply(request, directory: directory, answer: nil) }
            return
        }
        if let previous = prompts[host], previous.request.id != request.id { SSHAskpass.reply(previous.request, directory: directory, answer: nil) }
        // ssh asking again after an answer: the same question (a password), or a key's own retry wording.
        let retry = request.kind == .secret && answered[host] != nil
            && (answered[host] == request.prompt || request.prompt.lowercased().hasPrefix("bad passphrase"))
        prompts[host] = Prompt(request: request, retry: retry)
        awaitingTerminal.remove(host)
        log(host, request.prompt, kind: .prompt)
    }

    /// The strip's answer to `host`'s prompt; nil refuses it (No to a confirmation that takes no word).
    func answer(_ host: HostID, _ value: String?) {
        guard let prompt = prompts.removeValue(forKey: host), let directory = runtime?.herdrLaunch.directory else { return }
        SSHAskpass.reply(prompt.request, directory: directory, answer: value)
        answered[host] = value == nil ? nil : prompt.text
    }

    /// Yes or No to a confirmation: the word for a question ssh reads as text (a host key's), nothing for No to one it
    /// asks as a permission (`SSH_ASKPASS_PROMPT=confirm`, which reads any answer but yes as no).
    func confirm(_ host: HostID, _ yes: Bool) {
        guard let prompt = prompts[host] else { return }
        answer(host, yes ? "yes" : prompt.request.hint == "confirm" ? nil : "no")
    }

    /// Shows or hides the log under `surface`'s strip.
    func toggleLog(_ surface: UUID) {
        if logShown.remove(surface) == nil { logShown.insert(surface) }
    }

    /// Types `text` and Return into `host`'s login terminal: for an ssh that asks there.
    func type(_ host: HostID, _ text: String) {
        loginInputs[host]?(Data((text + "\r").utf8))
        partial[host] = nil
        awaitingTerminal.remove(host)
    }

    func loginStarted(_ identity: UUID, host: HostID, executable: String,
                      input: @escaping (Data) -> Void, close: @escaping () -> Void) {
        logins[identity] = Login(host: host, executable: executable)
        loginInputs[host] = input
        loginClosers[identity] = close
        loginsRunning.insert(host)
    }

    func loginEnded(_ identity: UUID) {
        loginClosers[identity] = nil
        guard let login = logins.removeValue(forKey: identity) else { return }
        let host = login.host
        if !logins.values.contains(where: { $0.host == host }) {
            loginInputs[host] = nil
            loginsRunning.remove(host)
            awaitingTerminal.remove(host)
            if let rest = partial.removeValue(forKey: host), !rest.isEmpty { log(host, rest, kind: .output) }
        }
    }

    /// A login's terminal output, as text lines (escape sequences dropped, a carriage return starting the line again).
    /// An unfinished line ending as a question does (`:` or `?`) is ssh asking on its terminal.
    func loginOutput(_ host: HostID, _ bytes: Data) {
        var line = partial[host] ?? ""
        for character in Self.plain(String(decoding: bytes, as: UTF8.self)) {
            switch character {
            case "\n", "\r\n": log(host, line, kind: .output); line = ""
            case "\r": line = ""
            default: line.append(character)
            }
        }
        partial[host] = String(line.suffix(2048))
        let asking = line.trimmingCharacters(in: .whitespaces).last.map { $0 == ":" || $0 == "?" } == true
        if asking, prompts[host] == nil { awaitingTerminal.insert(host) } else { awaitingTerminal.remove(host) }
    }

    /// What the attempt does now: on the strip of each of the host's connections, and in its log.
    func step(_ host: HostID, _ text: String) {
        for id in states.keys where recipes[id]?.host == host && states[id]?.reconnecting == true { states[id]?.step = text }
        log(host, text, kind: .step)
    }

    func log(_ host: HostID, _ text: String, kind: LogLine.Kind) {
        let text = String(text.prefix(4096))
        guard kind != .output || !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        logCount += 1
        var lines = logs[host] ?? []
        lines.append(LogLine(id: logCount, time: kind == .output ? nil : Date(), text: text, kind: kind))
        if lines.count > Self.logLimit { lines.removeFirst(lines.count - Self.logLimit) }
        logs[host] = lines
    }

    private func clearLog(_ host: HostID) {
        logs[host] = nil; partial[host] = nil; answered[host] = nil
        let surfaces = runtime?.workspace?.hosts.terminals.filter { $0.value.host == host }.map(\.key) ?? []
        logShown.subtract(surfaces)
    }

    /// A host with a login asking while no tab of it is open (its spaces restored from the Detached list): the active
    /// tab's strip carries the prompt, named for that host.
    func orphan(for surface: UUID) -> HostID? {
        guard let workspace = runtime?.workspace, workspace.activeSurfaceID == surface else { return nil }
        let open = workspace.allSurfaceIDs
        return Set(prompts.keys).union(awaitingTerminal).sorted { $0.rawValue < $1.rawValue }.first { host in
            !workspace.hosts.terminals.contains { $0.value.host == host && open.contains($0.key) }
        }
    }

    /// An attempt ended: a prompt still open is refused (its ssh has gone or goes now).
    private func endLogin(_ host: HostID) {
        if let prompt = prompts.removeValue(forKey: host), let directory = runtime?.herdrLaunch.directory {
            SSHAskpass.reply(prompt.request, directory: directory, answer: nil)
        }
        sources[host] = nil
        answered[host] = nil
        awaitingTerminal.remove(host)
    }

    /// Text without terminal escape sequences (CSI, OSC and two-character ones) or other control characters.
    nonisolated static func plain(_ text: String) -> String {
        var result = "", escape = false, sequence: Character?
        for character in text {
            if let kind = sequence {
                // CSI ends at a final byte (@ to ~); OSC at BEL or ST (ESC \\, whose ESC starts a new sequence).
                if kind == "[" ? character.asciiValue.map({ (0x40...0x7E).contains($0) }) == true : character == "\u{07}" { sequence = nil }
                else if character == "\u{1B}" { sequence = nil; escape = true }
                continue
            }
            if escape {
                escape = false
                if character == "[" || character == "]" { sequence = character }
                continue
            }
            if character == "\u{1B}" { escape = true; continue }
            if character == "\n" || character == "\r" || character == "\r\n" || character == "\t" { result.append(character); continue }
            if character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) { continue }
            result.append(character)
        }
        return result
    }
}

/// A reconnect's login runs in a terminal of a private helper: never a workspace tab, a space or a sheet. OpenSSH asks
/// its prompts through `SSH_ASKPASS` (`SSHAskpass`), which the strip answers; the terminal's output goes to the host's
/// reconnect log, whose field types into it for an ssh that asks there. No password or key material is kept in a recipe,
/// argv or app field: an answer goes once from the strip's field to the process ssh asked. The private master is fresh
/// each time.
@MainActor
enum SSHReconnectLogin {
    /// A command in a terminal of a private helper (`--stdio`), its output in `host`'s reconnect log.
    @MainActor final class Terminal {
        /// The identity its processes ask under (`DISPATCH_HERDR_TAB`).
        let identity: UUID
        let host: HostID
        private let session: HelperSession
        private let client: HelperClient
        private let node: UInt64
        private(set) var exited = false
        private(set) var status: Int32?
        private(set) var failure: (any Error)?
        private var sending: Task<Void, Never>?
        /// Closed: by its owner when done, or by Cancel (`SSHReconnectController.cancel`).
        private(set) var closed = false

        private init(identity: UUID, host: HostID, session: HelperSession, client: HelperClient, node: UInt64) {
            self.identity = identity; self.host = host; self.session = session; self.client = client; self.node = node
        }

        /// `logged`: its output goes to the log (a login's); a resumed login shell's does not.
        static func start(command: String, executable: String, directory: String?, host: HostID,
                          logged: Bool = true) async throws -> Terminal {
            let process = Process()
            process.executableURL = HelperApp.executable
            guard process.executableURL != nil else { throw HerdrFailure("The bundled helper is missing.") }
            process.arguments = ["--stdio"]
            // Authentication starts from the account home, independently of the active workspace.
            process.currentDirectoryURL = System.home
            let session = try await HelperSession(process: process)
            do {
                let client = HelperClient(session.connection)
                guard let backend = try await client.backends().first(where: { $0.key == "native" }) else {
                    throw HerdrFailure("The native terminal backend is unavailable.")
                }
                let (opened, ready) = AsyncThrowingStream<UInt64, any Error>.makeStream()
                _ = try await client.open(backend.route) { result in
                    switch result {
                    case .success(.opened(let id)): ready.yield(id); ready.finish()
                    case .failure(let error): ready.finish(throwing: error)
                    default: break
                    }
                }
                var iterator = opened.makeAsyncIterator()
                guard let parent = try await iterator.next() else { throw HerdrFailure("The native terminal backend closed.") }
                let id = try AppReplay.identity(kind: "ssh.authentication", value: UUID())
                let runtime = TerminalRuntime.shared
                // Its own launch capability (the token askpass posts with) and the askpass program.
                var variables = runtime.herdrLaunch.environment(for: id)
                variables.merge(SSHAskpass.environment(directory: runtime.herdrLaunch.directory)) { _, new in new }
                if System.testing {
                    variables.merge(["HOME": System.home.path, "GHOSTTY_ZSH_ZDOTDIR": "/var/empty", "DISPATCH_TESTING": "1"]) { _, new in new }
                }
                let identity = variables["DISPATCH_HERDR_TAB"].flatMap(UUID.init(uuidString:)) ?? id
                // ssh runs where the connection was typed (`SSHShell.directory`): its relative paths resolve as they did.
                let node = try await client.create(.init(parent: parent, beside: nil, cwd: directory ?? System.home.path, launch: nil,
                    command: command, environment: variables.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }))
                let terminal = Terminal(identity: identity, host: host, session: session, client: client, node: node)
                runtime.hosts.reconnect.loginStarted(identity, host: host, executable: executable,
                                                     input: { [weak terminal] bytes in terminal?.type(bytes) },
                                                     close: { [weak terminal] in terminal?.close() })
                _ = try await client.attach(.init(terminal: node, size: .init(columns: 120, rows: 32), takeover: false)) { [weak terminal] result in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let terminal, !terminal.closed else { return }
                            switch result {
                            case .success(.output(let output)): if logged { runtime.hosts.reconnect.loginOutput(host, output.bytes) }
                            case .success(.exit(let exit)): terminal.status = exit.status; terminal.exited = true
                            case .failure(let error): terminal.failure = error; terminal.exited = true
                            default: break
                            }
                        }
                    }
                }
                return terminal
            } catch {
                session.close()
                throw error
            }
        }

        func type(_ bytes: Data) {
            guard !closed else { return }
            let previous = sending, client = client, node = node
            sending = Task {
                await previous?.value
                guard !Task.isCancelled else { return }
                do { try await client.input(.init(terminal: node, bytes: bytes)) } catch {}
            }
        }

        /// Ends the terminal's processes with the private helper.
        func close() {
            guard !closed else { return }
            closed = true
            sending?.cancel()
            let runtime = TerminalRuntime.shared
            runtime.hosts.reconnect.loginEnded(identity)
            runtime.herdrLaunch.close(identity)
            session.close()
        }
    }

    /// `configuration`: the connection's `ssh -G`, which decides the master's keepalive (`SSHKeepalive`).
    static func authenticate(shell: SSHShell, master: SSHMaster, host: HostID, configuration: String? = nil) async throws {
        let arguments = interactiveArguments(shell: shell, master: master, configuration: configuration)
        let command = ([shell.executable] + arguments).map(HerdrLaunch.quote).joined(separator: " ")
        let terminal = try await Terminal.start(command: command, executable: shell.executable,
                                                directory: shell.workingDirectory, host: host)
        defer { terminal.close() }
        let controller = TerminalRuntime.shared.hosts.reconnect
        // A login waiting for an answer has as long as it needs; one waiting for nothing gives up after two minutes.
        var deadline = ContinuousClock.now.advanced(by: .seconds(120))
        // `ssh -f` leaves once the master is in the background: its exit is a failure only while no master answers.
        var exitedAt: ContinuousClock.Instant?
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if terminal.closed { throw CancellationError() }
            if controller.prompts[host] != nil || controller.awaitingTerminal.contains(host) {
                deadline = ContinuousClock.now.advanced(by: .seconds(120))
            }
            if let error = terminal.failure { throw error }
            let ready = try AppReplay.query(kind: "observe.ssh.master.ready", input: .string(master.controlPath)) {
                .bool(FileManager.default.fileExists(atPath: master.controlPath))
            }
            if try AppReplay.decode(Bool.self, ready) {
                let result = try await SSHCommand.run(executable: master.executable, arguments: master.controlArguments("check"), timeout: 3)
                if result.status == 0 { return }
            }
            if terminal.exited {
                if terminal.status.map({ $0 != 0 }) ?? true { throw HerdrFailure("SSH authentication failed. Retry to log in again.") }
                let now = ContinuousClock.now
                if let exitedAt, exitedAt.duration(to: now) > .seconds(3) {
                    throw HerdrFailure("SSH logged in, but its connection did not become ready.")
                }
                if exitedAt == nil { exitedAt = now }
            }
            try await System.sleep(for: .milliseconds(100), "authentication")
        }
        throw HerdrFailure("SSH authentication timed out. Retry to authenticate again.")
    }
    /// Keys and the SSH agent only: an automatic reconnect never prompts. OpenSSH refusing the login
    /// (a password or passphrase it would ask for, a changed host key) is `.refused`; the rest `.unreachable`.
    static func authenticateSilently(shell: SSHShell, master: SSHMaster, configuration: String? = nil) async throws {
        let arguments = silentArguments(shell: shell, master: master, configuration: configuration)
        let result: SSHCommand.Result
        do { result = try await SSHCommand.run(executable: shell.executable, arguments: arguments, timeout: 30, errors: true, directory: shell.workingDirectory) }
        catch {
            try Task.checkCancellation()
            throw SSHAutomaticFailure.unreachable(error.localizedDescription)
        }
        guard result.status == 0 else {
            let errors = String(decoding: result.errors ?? Data(), as: UTF8.self)
            let message = errors.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }
            let refusals = ["permission denied", "host key verification failed", "host identification has changed",
                            "too many authentication failures", "no more authentication methods"]
            if refusals.contains(where: errors.lowercased().contains) {
                throw SSHAutomaticFailure.refused(message ?? "SSH refused the login.")
            }
            throw SSHAutomaticFailure.unreachable(message ?? "SSH could not reach \(shell.destination).")
        }
        // The backgrounded master answers on its control socket once it is ready.
        for _ in 0..<30 {
            if try await SSHCommand.run(executable: master.executable, arguments: master.controlArguments("check"), timeout: 3).status == 0 { return }
            try await System.sleep(for: .milliseconds(100), "master")
        }
        throw SSHAutomaticFailure.unreachable("SSH logged in, but its connection did not become ready.")
    }
    /// The interactive login's master: the connection's own options, whose prompts reach the strip through askpass.
    nonisolated static func interactiveArguments(shell: SSHShell, master: SSHMaster, configuration: String?) -> [String] {
        ["-o", "ControlMaster=yes", "-o", "ControlPersist=yes", "-S", master.controlPath,
         "-f", "-N"] + shell.options + SSHKeepalive.options(configuration: configuration) + ["--", shell.destination]
    }
    /// The first value given for an option wins, so BatchMode and the rest hold over the connection's own options; the
    /// keepalive comes after them, so the connection's own keepalive holds over it.
    nonisolated static func silentArguments(shell: SSHShell, master: SSHMaster, configuration: String?) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ControlMaster=yes", "-o", "ControlPersist=yes",
         "-S", master.controlPath, "-f", "-N"] + shell.options + SSHKeepalive.options(configuration: configuration)
            + ["--", shell.destination]
    }
}
