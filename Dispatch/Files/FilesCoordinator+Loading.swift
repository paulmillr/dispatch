import Foundation
import Observation

// Loading and freshness: the root follows the tab's shell directory until
// pinned, the root and every expanded folder are listed, and they refresh every 2 s while files shows (the tab
// is in files mode and its content is in a window the user can see), once after a shell prompt, and never
// otherwise.

extension FilesCoordinator {
    /// The loading state that belongs to this coordinator.
    var loader: FilesLoader { FilesLoader.attached(to: self) }

    /// Starts the session's loading task (once per session object).
    func observe(_ session: FilesSession) { loader.observe(session) }

    /// ⌘R: lists the root and the expanded folders now.
    func refreshNow(_ id: UUID) { loader.refresh(id) }

    /// The shell printed a prompt: one refresh while files shows, at most one per 500 ms.
    func shellPromptedNow(_ id: UUID) { loader.shellPrompted(id) }
}

/// One long-lived task per session that resolves the tab's source, keeps its root, prunes what fell outside
/// it, and lists. Every await is followed by a check that the session, its visibility and its source are
/// still the ones the request was made for.
@MainActor final class FilesLoader {
    struct Preferences: Equatable {
        var followShell = true
        var showHidden = false
        /// Settings › Features › Git.
        var git = true
    }

    /// Everything the loader reads from the app, replaceable in tests.
    struct Environment {
        var resolve: @MainActor (_ id: UUID, _ lastRefresh: Date?) -> FilesAvailability
        /// The tab's shell directory; read inside an observation, so it must be observable.
        var directory: @MainActor (UUID) -> String?
        /// Reads, inside an observation, whatever else should wake the loader (the resolver's inputs).
        var track: @MainActor (UUID) -> Void
        var preferences: @MainActor () -> Preferences
        var sleep: @Sendable (Duration) async throws -> Void
        var now: @MainActor () -> Date
    }

    static let interval: Duration = .seconds(2)
    static let promptInterval: TimeInterval = 0.5

    let resolver: FilesResolver
    var environment: Environment
    /// The repository, status, marks, log and diffs of every session (FilesCoordinator+Git.swift), driven by these passes.
    let git = GitLoader()
    private weak var coordinator: FilesCoordinator?
    private var watches: [UUID: Watch] = [:]

    private static var loaders: [ObjectIdentifier: FilesLoader] = [:]

    /// The coordinator's loader. Kept beside it, since the coordinator's stored properties are its own.
    static func attached(to coordinator: FilesCoordinator) -> FilesLoader {
        let key = ObjectIdentifier(coordinator)
        if let loader = loaders[key], loader.coordinator === coordinator { return loader }
        loaders = loaders.filter { $0.value.coordinator != nil }
        let loader = FilesLoader(coordinator: coordinator)
        loaders[key] = loader
        return loader
    }

    init(coordinator: FilesCoordinator) {
        self.coordinator = coordinator
        let resolver = FilesResolver()
        self.resolver = resolver
        environment = Environment(
            resolve: { resolver.availability(for: $0, lastRefresh: $1) },
            directory: { TerminalRuntime.shared.workspace?.directory(forSurface: $0) },
            track: { FilesResolver.track($0) },
            preferences: { FilesLoader.preferences() },
            sleep: { try await System.sleep(for: $0, "files.refresh") },
            now: { System.date() })
    }

    /// Settings › Files › Follow the shell’s directory and Show hidden files.
    static func preferences() -> Preferences {
        let values = TerminalRuntime.shared.preferences
        return Preferences(followShell: values.filesFollowShell, showHidden: values.filesShowHidden, git: values.gitEnabled)
    }

    // MARK: Entry points

    func observe(_ session: FilesSession) {
        if let watch = watches[session.id], watch.session === session { return }
        watches[session.id]?.task?.cancel()
        let watch = Watch(session: session)
        watches[session.id] = watch
        watch.task = Task { [weak self] in
            await self?.run(watch)
        }
    }

    func refresh(_ id: UUID) {
        git.prompted(id)
        watches[id]?.signal(full: true)
    }

    func shellPrompted(_ id: UUID) {
        guard let watch = watches[id], let session = watch.session, Self.shows(session) else { return }
        let now = environment.now()
        if let last = watch.lastPrompt, now >= last, now.timeIntervalSince(last) < Self.promptInterval { return }
        watch.lastPrompt = now
        git.prompted(id)
        watch.signal(full: true)
    }

    /// Whether the session's task is waiting: for a change only (hidden, or nothing to poll), or with the 2 s
    /// poll armed as well. Nil while it runs.
    func waiting(_ id: UUID) -> Watch.Waiting? { watches[id]?.waiting }

    /// How many passes the session's task has made (each resolves, roots and lists what is due).
    func passes(_ id: UUID) -> Int { watches[id]?.passes ?? 0 }

    /// Files shows for the session: the tab is in files mode and on screen. A tab in files mode in a space nobody
    /// looks at, or a window that is minimized, lists nothing.
    static func shows(_ session: FilesSession) -> Bool { session.visible && session.presented }

    // MARK: The task

    private func run(_ watch: Watch) async {
        defer {
            if watches[watch.id] === watch {
                watches[watch.id] = nil
                git.forget(watch.id)
            }
        }
        while !Task.isCancelled {
            guard let session = watch.session, coordinator?.sessions[session.id] === session else { return }
            // The 2 s tick, a refresh, a prompt or a newly shown view: git reads the status again too.
            let tick = watch.full
            let plan = prepare(session, watch)
            arm(session, watch)
            git.pass(session, source: Self.shows(session) ? session.availability.source : nil, folder: watch.root, tick: tick,
                     enabled: environment.preferences().git)
            if let plan { await load(plan, session, watch) }
            guard let session = watch.session else { return }
            switch await watch.next(poll: Self.shows(session) ? Self.interval : nil, sleep: environment.sleep) {
            case .cancelled: return
            case .timer: watch.full = true
            case .signal: break
            }
        }
    }

    /// One observation at a time: a registration stays until its first change, so re-arming every pass would
    /// pile them up.
    private func arm(_ session: FilesSession, _ watch: Watch) {
        guard !watch.armed else { return }
        watch.armed = true
        let id = session.id
        withObservationTracking {
            _ = coordinator?.sessions[id]
            _ = session.visible
            _ = session.presented
            _ = session.expanded
            _ = session.pinnedRoot
            _ = session.showHidden
            _ = environment.directory(id)
            environment.track(id)
        } onChange: { [weak watch] in
            Task { @MainActor [weak watch] in
                watch?.armed = false
                watch?.signal()
            }
        }
    }

    private struct Plan {
        let source: any FilesSource
        let root: String
        let hidden: Bool
        let paths: [String]
    }

    /// The synchronous part of a pass: availability, root, pruning, and what to list.
    private func prepare(_ session: FilesSession, _ watch: Watch) -> Plan? {
        watch.passes += 1
        // Hidden, the view is not shown and nothing is resolved or listed: a session exists for every tab whose
        // strip button renders, and the files of a tab that never shows files are nobody's business.
        guard Self.shows(session) else {
            watch.visible = false
            return nil
        }
        if !watch.visible {
            watch.visible = true
            watch.full = true
        }
        let preferences = environment.preferences()
        let availability = environment.resolve(session.id, session.lastRefresh)
        let source = availability.source
        var shown = availability
        if let source {
            // Requests to this source failed as offline: it stays offline until one succeeds.
            if watch.offline == ObjectIdentifier(source) {
                shown = .offline(host: source.hostLabel ?? "This Mac", since: session.staleSince ?? session.lastRefresh)
            }
            adopt(source, session, watch)
        } else if case .offline = availability, session.staleSince == nil, !session.listings.isEmpty {
            session.staleSince = session.lastRefresh ?? environment.now()
        }
        if !Self.same(session.availability, shown) { session.availability = shown }

        let directory = environment.directory(session.id).flatMap(Self.normalized)
        let moved = watch.seenDirectory && directory != watch.directory
        watch.directory = directory
        watch.seenDirectory = true
        // Following off: the root stays where it is, which is a pin the user can undo with ↩.
        if !preferences.followShell, session.pinnedRoot == nil, let current = watch.root ?? session.root(tabDirectory: directory) {
            session.pinnedRoot = current
        }
        let root = session.root(tabDirectory: directory).flatMap(Self.normalized)
        if root != watch.root {
            if let root { retarget(session, to: root, shellMoved: moved && session.followsShell) }
            watch.root = root
        }
        if let root {
            let expanded = session.expanded.filter { Self.path($0, isInside: root) }
            if expanded != session.expanded { session.expanded = expanded }
        }
        let hidden = session.showsHidden(default: preferences.showHidden)
        if hidden != watch.hidden {
            watch.hidden = hidden
            watch.full = true
        }

        guard let source, let root else { return nil }
        let folders = [root] + session.expanded.filter { $0 != root }.sorted()
        let paths = watch.full ? folders : folders.filter { session.listings[$0]?.listing == nil }
        watch.full = false
        guard !paths.isEmpty else { return nil }
        var listings = session.listings
        for path in paths where listings[path]?.listing == nil && listings[path]?.error == nil {
            listings[path, default: FileListingState()].loading = true
        }
        if !Self.sameStates(listings, session.listings) { session.listings = listings }
        return Plan(source: source, root: root, hidden: hidden, paths: paths)
    }

    /// A new source: the reconnected connection of the same host keeps what is shown; another host's does not.
    private func adopt(_ source: any FilesSource, _ session: FilesSession, _ watch: Watch) {
        let identity = ObjectIdentifier(source)
        guard identity != watch.source else { return }
        let host = (source.endpoint.isLocal ? "local:" : "remote:") + (source.hostLabel ?? "")
        if let previous = watch.host, previous != host {
            session.listings = [:]
            session.expanded = []
            session.selection = []
            session.anchor = nil
            session.pinnedRoot = nil
            session.staleSince = nil
            watch.root = nil
        }
        if watch.offline != identity { watch.offline = nil }
        watch.source = identity
        watch.host = host
        watch.full = true
        if session.home != source.home { session.home = source.home }
        if session.hostLabel != source.hostLabel { session.hostLabel = source.hostLabel }
    }

    /// The root moved: what is outside it goes, and a shell `cd` clears the selection.
    private func retarget(_ session: FilesSession, to root: String, shellMoved: Bool) {
        let listings = session.listings.filter { Self.path($0.key, isInside: root) }
        if listings.count != session.listings.count { session.listings = listings }
        let selection: Set<String> = shellMoved ? [] : session.selection.filter { Self.path($0, isInside: root) }
        if selection != session.selection { session.selection = selection }
        if let anchor = session.anchor, shellMoved || !Self.path(anchor, isInside: root) { session.anchor = nil }
    }

    private func load(_ plan: Plan, _ session: FilesSession, _ watch: Watch) async {
        let source = plan.source, hidden = plan.hidden
        let listing = Task { () -> [(String, Result<FileListing, FilesSourceError>)] in
            await withTaskGroup(of: (String, Result<FileListing, FilesSourceError>).self) { group in
                for path in plan.paths {
                    group.addTask {
                        do { return (path, .success(try await source.list(path, hidden: hidden))) }
                        catch { return (path, .failure(Self.failure(error, source: source, path: path))) }
                    }
                }
                var results: [(String, Result<FileListing, FilesSourceError>)] = []
                for await result in group { results.append(result) }
                return results
            }
        }
        // A request that never answers (a stalled disk, a wedged helper) must not hold the session: once what the
        // pass was made for changes, the pass ends (its requests cancelled) and the next one lists what shows then.
        watch.supersede = { [weak self, weak session, weak watch] in
            guard let self, let session, let watch, !self.current(plan, session, watch) else { return }
            listing.cancel()
        }
        let results = await withTaskCancellationHandler { await listing.value } onCancel: { listing.cancel() }
        watch.supersede = nil
        // The pass is stale if anything it was made for changed meanwhile; the next pass lists again.
        guard !Task.isCancelled, !listing.isCancelled, current(plan, session, watch), watch.root == plan.root,
              watch.hidden == plan.hidden else {
            // Undo the loading marks of this pass, or a folder would spin until its next listing.
            clearLoading(session, plan.paths)
            return
        }
        let now = environment.now()
        var listings = session.listings
        var listed = false, offline = false
        for (path, result) in results where Self.path(path, isInside: plan.root) {
            let previous = listings[path]
            switch result {
            case .success(let fresh):
                listed = true
                // Marked before comparing, so a listing whose entries and marks are unchanged is not rewritten.
                let listing = git.marked(fresh, in: session)
                // An unchanged folder keeps its state value, so the outline does not redraw every 2 s.
                if previous?.listing != listing || previous?.error != nil || previous?.loading == true {
                    listings[path] = FileListingState(listing: listing, loadedAt: now, error: nil, loading: false)
                }
            case .failure(.offline):
                offline = true
                if previous?.loading == true { listings[path]?.loading = false }
            case .failure(.cancelled):
                if previous?.loading == true { listings[path]?.loading = false }
            case .failure(let error):
                // A folder that is gone or unreadable shows the error, not its old entries; a transient failure
                // keeps them beside the error.
                let keep: Bool = switch error {
                case .notFound, .notDirectory, .permissionDenied: false
                default: true
                }
                let next = FileListingState(listing: keep ? previous?.listing : nil, loadedAt: previous?.loadedAt, error: error,
                                            loading: false)
                if previous?.listing != next.listing || previous?.error != next.error || previous?.loading == true {
                    listings[path] = next
                }
            }
        }
        if !Self.sameStates(listings, session.listings) { session.listings = listings }
        if offline {
            if session.staleSince == nil { session.staleSince = session.lastRefresh ?? now }
            watch.offline = ObjectIdentifier(source)
            let shown = FilesAvailability.offline(host: source.hostLabel ?? "This Mac", since: session.staleSince)
            if !Self.same(session.availability, shown) { session.availability = shown }
        } else if listed {
            session.lastRefresh = now
            if session.staleSince != nil { session.staleSince = nil }
            if watch.offline != nil {
                watch.offline = nil
                if !Self.same(session.availability, .available(source)) { session.availability = .available(source) }
            }
        }
    }

    /// Whether a pass's plan still fits the session: the same session, shown, through the same source, with the
    /// same root and hidden setting.
    private func current(_ plan: Plan, _ session: FilesSession, _ watch: Watch) -> Bool {
        guard watch.session === session, coordinator?.sessions[session.id] === session, Self.shows(session),
              environment.resolve(session.id, session.lastRefresh).source === plan.source else { return false }
        let directory = environment.directory(session.id).flatMap(Self.normalized)
        return session.root(tabDirectory: directory).flatMap(Self.normalized) == plan.root
            && session.showsHidden(default: environment.preferences().showHidden) == plan.hidden
    }

    private func clearLoading(_ session: FilesSession, _ paths: [String]) {
        var listings = session.listings
        for path in paths where listings[path]?.loading == true { listings[path]?.loading = false }
        if !Self.sameStates(listings, session.listings) { session.listings = listings }
    }

    private nonisolated static func failure(_ error: any Error, source: any FilesSource, path: String) -> FilesSourceError {
        HelperFilesSource.map(error, path: path, host: source.endpoint.isLocal ? nil : source.hostLabel ?? "The host")
    }

    // MARK: Paths and comparisons

    /// An absolute path without a trailing slash; nil for a relative or empty one.
    nonisolated static func normalized(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    nonisolated static func path(_ path: String, isInside root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    static func same(_ a: FilesAvailability, _ b: FilesAvailability) -> Bool {
        switch (a, b) {
        case (.loading, .loading): true
        case (.available(let x), .available(let y)): x === y
        case (.plainSSH(let x), .plainSSH(let y)): x == y
        case (.notGranted(let x, let s), .notGranted(let y, let t)): x == y && s == t
        case (.offline(let x, let s), .offline(let y, let t)): x == y && s == t
        case (.unavailable(let x), .unavailable(let y)): x == y
        default: false
        }
    }

    nonisolated static func sameStates(_ a: [String: FileListingState], _ b: [String: FileListingState]) -> Bool {
        a.count == b.count && a.allSatisfy { key, value in
            guard let other = b[key] else { return false }
            return value.listing == other.listing && value.loadedAt == other.loadedAt && value.error == other.error
                && value.loading == other.loading
        }
    }

    // MARK: Per-session state

    @MainActor final class Watch {
        enum Waiting: Equatable { case change, poll }
        enum Wake { case signal, timer, cancelled }

        weak var session: FilesSession?
        let id: UUID
        var task: Task<Void, Never>?
        var armed = false
        var root: String?
        var directory: String?
        var seenDirectory = false
        var hidden: Bool?
        var visible = false
        /// The next pass lists every folder, not only those without a listing.
        var full = true
        var source: ObjectIdentifier?
        var host: String?
        /// The source whose requests last failed as offline.
        var offline: ObjectIdentifier?
        var lastPrompt: Date?
        var passes = 0
        /// Set while a pass lists: ends it when a signal says what it lists for has changed.
        var supersede: (@MainActor () -> Void)?
        private(set) var waiting: Waiting?

        private var pending = false
        private var waiter: CheckedContinuation<Wake, Never>?
        private var timer: Task<Void, Never>?
        private var turn = 0

        init(session: FilesSession) {
            self.session = session
            id = session.id
        }

        func signal(full: Bool = false) {
            if full { self.full = true }
            supersede?()
            resume(.signal, turn: turn)
        }

        /// Waits for a signal, or for `poll` to pass.
        func next(poll: Duration?, sleep: @escaping @Sendable (Duration) async throws -> Void) async -> Wake {
            if pending {
                pending = false
                return .signal
            }
            if Task.isCancelled { return .cancelled }
            turn += 1
            let turn = turn
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    waiter = continuation
                    waiting = poll == nil ? .change : .poll
                    if let poll {
                        timer = Task { @MainActor [weak self] in
                            do { try await sleep(poll) } catch { return }
                            self?.resume(.timer, turn: turn)
                        }
                    }
                }
            } onCancel: { [weak self] in
                Task { @MainActor [weak self] in self?.resume(.cancelled, turn: turn) }
            }
        }

        private func resume(_ wake: Wake, turn: Int) {
            guard let waiter else {
                if wake == .signal { pending = true }
                return
            }
            // A timer or cancellation from an earlier wait does not end this one.
            guard wake == .signal || turn == self.turn else { return }
            self.waiter = nil
            waiting = nil
            timer?.cancel()
            timer = nil
            waiter.resume(returning: wake)
        }
    }
}
