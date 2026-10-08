import AppKit
import Network
import Observation

/// Why an automatic reconnect stopped short. Only an unreachable host is tried again by itself;
/// a refusal (a password or passphrase, a changed host key, a closed login tab) waits for Reconnect.
enum SSHAutomaticFailure: LocalizedError {
    case unreachable(String)
    case refused(String)
    var errorDescription: String? {
        switch self { case .unreachable(let message), .refused(let message): message }
    }
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
    }
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
        state(for: surface) ?? (completed[surface] == nil ? nil : State(connected: true))
    }
    func retain(_ recipe: Recipe) {
        for surface in recipe.surfaces { completed[surface] = nil }
        recipes[recipe.connection] = recipe
        if states[recipe.connection] == nil { states[recipe.connection] = State(disconnectedAt: Date()) }
        for surface in recipe.surfaces { runtime?.views[surface]?.updateFocus() }
    }
    func launchingRestoredShell(_ surface: UUID, recipe: Recipe) {
        launchingShells[surface] = .init(connection: SSHConnectionID(), host: recipe.host, shell: recipe.shell,
            scope: recipe.scope, origin: surface, surfaces: [surface], restored: true)
        launchingHistory[surface] = runtime?.restoredHistory[surface]
    }
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
        runtime.workspace?.focusRequest = UUID()
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
        let epoch = UUID(); epochs[hostID] = epoch
        for id in ids {
            var state = states[id] ?? State(disconnectedAt: Date())
            state.reconnecting = true; state.attempted = true; state.attempts += 1; state.retryAt = nil
            states[id] = state
        }
        operations[hostID] = Task { [weak self] in
            guard let self else { return }
            var unreachable = false
            defer {
                if epochs[hostID] == epoch { operations[hostID] = nil; epochs[hostID] = nil }
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
                    let token = UUID()
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
                    guard epochs[hostID] == epoch, recipes[id] != nil else { continue }
                    var state = states[id] ?? State()
                    state.reconnecting = false
                    state.error = error is CancellationError ? nil : error.localizedDescription
                    states[id] = state
                    if case .unreachable? = error as? SSHAutomaticFailure { unreachable = true } else { losses.remove(id) }
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
            do { try await Task.sleep(for: delay) } catch { return }
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
        network.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.retryNow() } }
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
        operations.removeValue(forKey: hostID)?.cancel()
        for recipe in recipes.values where recipe.host == hostID {
            var state = states[recipe.connection] ?? State()
            state.reconnecting = false; state.attempted = true; state.error = nil
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
    }
}

/// OpenSSH owns authentication in a real PTY. No password or key material is
/// copied into a recipe, argv, or app field. The private master is fresh each time.
@MainActor
enum SSHReconnectLogin {
    static func authenticate(shell: SSHShell, master: SSHMaster, window: NSWindow?) async throws {
        guard let window = window ?? NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow ?? NSApp.mainWindow else {
            throw HerdrFailure("Open a Dispatch window to authenticate this connection.")
        }
        let arguments = ["-o", "ControlMaster=yes", "-o", "ControlPersist=yes", "-S", master.controlPath,
                         "-f", "-N"] + shell.options + ["--", shell.destination]
        let command = ([shell.executable] + arguments).map(HerdrLaunch.quote).joined(separator: " ")
        // Authentication owns this short-lived helper, not a workspace terminal. Keeping its
        // topology private avoids importing password prompts into the user's tabs; its existing
        // recorded transport covers the PTY without skipping the live panel during replay.
        let process = Process()
        process.executableURL = HelperApp.executable
        guard let executable = process.executableURL else { throw HerdrFailure("The bundled helper is missing.") }
        process.arguments = ["--stdio"]
        // Authentication starts from the account home, independently of the active workspace.
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let session = try await HelperSession(process: process)
        defer { session.close() }
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
        let testing = ProcessInfo.processInfo.environment["DISPATCH_TESTING"] == "1"
        let environment = testing ? ["HOME=" + Home.url.path, "GHOSTTY_ZSH_ZDOTDIR=/var/empty", "DISPATCH_TESTING=1"] : []
        let node = try await client.create(.init(parent: parent, beside: nil, cwd: NSHomeDirectory(), launch: nil,
                                                 command: command, environment: environment))
        let id = try AppReplay.identity(kind: "ssh.authentication", value: UUID())
        let directory = TerminalRuntime.shared.herdrLaunch.directory.appendingPathComponent("auth-" + id.uuidString.prefix(8))
        let renderer = try HelperRenderer(directory: directory, executable: executable)
        defer { renderer.stop() }
        let cancellation = LoginCancellation()
        defer { cancellation.closed = true; cancellation.sending?.cancel(); cancellation.attaching?.cancel() }
        renderer.onConnect = { _, channel in
            channel.onResize = { size in
                guard cancellation.attached, !cancellation.closed else { return }
                let previous = cancellation.sending
                cancellation.sending = Task {
                    await previous?.value
                    guard !Task.isCancelled, !cancellation.closed else { return }
                    do { try await client.resize(.init(terminal: node, size: size)) }
                    catch { cancellation.error = error }
                }
            }
            channel.onClose = { cancellation.finished = true; cancellation.sending?.cancel() }
            cancellation.attaching = Task {
                do {
                    let size = channel.grid
                    _ = try await client.attach(.init(terminal: node, size: size, takeover: false)) { result in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard !cancellation.closed else { return }
                                switch result {
                                case .success(.attached):
                                    cancellation.attached = true
                                    channel.onInput = { bytes in
                                        let previous = cancellation.sending
                                        cancellation.sending = Task {
                                            await previous?.value
                                            guard !Task.isCancelled, !cancellation.closed else { return }
                                            do { try await client.input(.init(terminal: node, bytes: bytes)) }
                                            catch { cancellation.error = error }
                                        }
                                    }
                                    if channel.grid != size { channel.onResize(channel.grid) }
                                case .success(.output(let output)): channel.write(output.bytes)
                                case .success(.exit): cancellation.finished = true; channel.finish()
                                case .failure(let error): cancellation.error = error; channel.close()
                                default: break
                                }
                            }
                        }
                    }
                } catch { cancellation.error = error }
            }
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 320),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Reconnect to \(shell.destination)"
        panel.isReleasedWhenClosed = false
        // Authentication lives outside the workspace and must accept focus
        // without selecting a tab or passing the workspace visibility check.
        let terminal = TerminalView(id: id, directory: NSHomeDirectory(),
                                    presentation: .standalone, allowHostMedia: false, helper: renderer)
        terminal.frame = NSRect(x: 12, y: 48, width: 596, height: 260)
        panel.contentView?.addSubview(terminal)
        terminal.onProcessExit = { cancellation.finished = true }
        let button = NSButton(title: "Cancel", target: cancellation, action: #selector(LoginCancellation.cancel))
        button.frame = NSRect(x: 520, y: 10, width: 88, height: 28)
        panel.contentView?.addSubview(button)
        let responder = window.firstResponder
        window.beginSheet(panel, completionHandler: nil)
        panel.makeFirstResponder(terminal)
        defer {
            window.endSheet(panel); panel.orderOut(nil); terminal.destroy()
            TerminalRuntime.shared.chat.close(terminal.id)
            TerminalRuntime.shared.herdrLaunch.close(terminal.id)
            if let responder, (responder as? NSView)?.window === window { window.makeFirstResponder(responder) }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if cancellation.cancelled { throw CancellationError() }
            if let error = cancellation.error { throw error }
            let ready = try AppReplay.query(kind: "ssh.master.ready", input: JSONEncoder().encode(master.controlPath)) {
                try JSONEncoder().encode(FileManager.default.fileExists(atPath: master.controlPath))
            }
            if try JSONDecoder().decode(Bool.self, from: ready) {
                let result = try await SSHCommand.run(executable: master.executable, arguments: master.controlArguments("check"), timeout: 3)
                if result.status == 0 { return }
            }
            if cancellation.finished { throw HerdrFailure("SSH authentication failed. Retry to log in again.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HerdrFailure("SSH authentication timed out. Retry to authenticate again.")
    }
    /// Keys and the SSH agent only: an automatic reconnect never prompts. OpenSSH refusing the login
    /// (a password or passphrase it would ask for, a changed host key) is `.refused`; the rest `.unreachable`.
    static func authenticateSilently(shell: SSHShell, master: SSHMaster) async throws {
        // The first value given for an option wins, so these hold over the connection's own options.
        let arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ControlMaster=yes", "-o", "ControlPersist=yes",
                         "-S", master.controlPath, "-f", "-N"] + shell.options + ["--", shell.destination]
        let result: SSHCommand.Result
        do { result = try await SSHCommand.run(executable: shell.executable, arguments: arguments, timeout: 30, errors: true) }
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
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SSHAutomaticFailure.unreachable("SSH logged in, but its connection did not become ready.")
    }
    @MainActor private final class LoginCancellation: NSObject {
        var cancelled = false
        var finished = false
        var attached = false
        var closed = false
        var error: (any Error)?
        var sending: Task<Void, Never>?
        var attaching: Task<Void, Never>?
        @objc func cancel() { cancelled = true }
    }
}
