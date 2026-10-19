import Foundation
import Observation

// The git side of files mode: the
// repository enclosing the shown folder, its status on the files loader's 2 s tick, the Files list's marks, the log,
// and the diffs the selections ask for. Everything runs only while files shows (`FilesLoader.shows`), every await is
// followed by a check that what it was for still holds, and a value equal to the one shown is never written again,
// so the views do not redraw or flash.

extension FilesCoordinator {
    /// The git state that belongs to this coordinator's loader.
    var git: GitLoader { loader.git }
}

/// Writes the session's git state (`FilesSession.git`, `gitResolving`, `status`, `changesSelection` as the status moves
/// under it, `log`, `commitDetail`, `commitDetailError`, `changesDiff`, `commitDiff`) and the `mark`s of its listings. Driven by the files loader's passes (root, source, visibility, the 2 s tick, shell
/// prompts) and by the session's own git inputs (its tab, selections, `logWanted`, scope and filter).
@MainActor final class GitLoader {
    struct Environment {
        /// The wait before a diff that has not answered shows as loading.
        var sleep: @Sendable (Duration) async throws -> Void
        var now: @MainActor () -> Date
    }

    /// A diff answering within this keeps the previous one on screen instead of flashing a loading state.
    static let loadingDelay: Duration = .milliseconds(150)
    nonisolated static let page = 200
    /// A log read the helper refused as busy is asked again after this, up to `logRetries` times before the tick.
    static let logRetryDelay: Duration = .milliseconds(300)
    static let logRetries = 3
    /// Untracked files whose lines are counted for the Changes list, per status.
    nonisolated static let countedUntracked = 50
    /// An untracked file bigger than this shows no line count: counting it would read it whole.
    nonisolated static let countedBytes: UInt64 = 256 << 10
    /// What one status read may read of untracked files to count them; the files left over are counted on later reads.
    nonisolated static let countBudget: UInt64 = 4 << 20
    /// Staged or unstaged binaries whose sizes one status read asks git for (`diff --stat`, one each); the rest wait
    /// for the next read.
    nonisolated static let sizedBinaries = 16
    /// Folders remembered per connection before the cache starts again.
    static let cachedFolders = 512

    var environment = Environment(sleep: { try await System.sleep(for: $0, "files.git.loading") }, now: { System.date() })
    private var watches: [UUID: Watch] = [:]
    private var cache: [FilesEndpoint: Cache] = [:]

    /// Resolved repositories per folder for one connection's source: a reconnect brings a new source and starts over.
    private struct Cache {
        weak var source: (any FilesSource)?
        var folders: [String: GitState] = [:]
    }

    // MARK: Entry points (the files loader)

    /// A files loader pass: what the session shows through (`source` nil while hidden or offline), its root, and
    /// whether the pass is the 2 s tick, a refresh or a prompt, on which the status (or, on Commits, the refs) is read
    /// again.
    func pass(_ session: FilesSession, source: (any FilesSource)?, folder: String?, tick: Bool, enabled: Bool = true) {
        let watch = self.watch(for: session)
        // Git turned off: nothing in flight, nothing kept, and nothing resolved until it is on again.
        guard enabled else {
            // Not shown either: a session change waking `sync` meanwhile starts nothing.
            watch.shows = false
            reset(session, watch)
            watch.resolved = nil
            watch.answered = nil
            watch.host = nil
            if session.git != .off { session.git = .off }
            if session.gitResolving { session.gitResolving = false }
            return
        }
        if session.git == .off { session.git = .loading }
        if let source {
            let host = (source.endpoint.isLocal ? "local:" : "remote:") + (source.hostLabel ?? "")
            // Another host's repository is not this one: start over as never resolved (the views treat `.loading` as
            // "may be a repository", so nothing falls back while the new host answers).
            if let previous = watch.host, previous != host {
                reset(session, watch)
                watch.resolved = nil
                watch.answered = nil
                if session.git != .loading { session.git = .loading }
            }
            watch.host = host
        }
        watch.source = source
        watch.folder = folder
        watch.shows = FilesLoader.shows(session) && source != nil && folder != nil
        guard watch.shows else { return stop(watch) }
        if tick || watch.prompted {
            watch.failed = nil
            // A detail or diff that failed is asked for again, once a tick rather than on every change.
            for job in [watch.changes, watch.detail, watch.commit, watch.signature] {
                guard let job, job.failed else { continue }
                job.failed = false
                job.input = nil
            }
        }
        if watch.prompted {
            watch.prompted = false
            // A prompt may follow `git init`, `git add` or a commit: nothing cached about this folder holds. The
            // untracked files' line counts do: their stamps say which files changed.
            if let source, let folder { forgetCached(source, folder) }
            watch.resolved = nil
            watch.statusDue = true
            watch.refsDue = true
            watch.changes?.input = nil
            // `git add` or a commit changes the blobs a binary's sizes describe.
            watch.sizes = [:]
        } else if tick {
            // Commits reads the status too: its uncommitted row and the branch's ahead and behind come from it.
            watch.statusDue = true
            if session.tab == .commits { watch.refsDue = true }
        }
        sync(watch)
    }

    /// The shell printed a prompt, or ⌘R: the next shown pass reads everything again.
    func prompted(_ id: UUID) { watches[id]?.prompted = true }

    func forget(_ id: UUID) {
        guard let watch = watches.removeValue(forKey: id) else { return }
        stop(watch)
    }

    /// The listing with the marks of the session's repository status, or without marks outside a repository.
    func marked(_ listing: FileListing, in session: FilesSession) -> FileListing {
        guard let marks = watches[session.id]?.marks, let root = session.git.repository?.root,
              FilesLoader.path(listing.path, isInside: root) else {
            return listing.entries.contains { $0.mark != nil } ? GitMarks.apply(nil, folder: nil, to: listing) : listing
        }
        let folder = listing.path == root ? "" : String(listing.path.dropFirst(root == "/" ? 1 : root.count + 1))
        return GitMarks.apply(marks, folder: folder, to: listing)
    }

    // MARK: Test seams

    /// Whether the session has git work in flight: the repository, the status, the log, or a selection's load.
    func busy(_ id: UUID) -> Bool {
        guard let watch = watches[id] else { return false }
        return watch.resolving != nil || watch.statusTask != nil || watch.logTask != nil
            || [watch.changes, watch.detail, watch.commit].contains { $0?.task != nil }
    }

    /// What the cache holds for a folder of this source.
    func cached(_ source: any FilesSource, _ folder: String) -> GitState? {
        guard let entry = cache[source.endpoint], entry.source === source else { return nil }
        return entry.folders[folder]
    }

    // MARK: Reconciling

    private func watch(for session: FilesSession) -> Watch {
        if let watch = watches[session.id], watch.session === session { return watch }
        if let old = watches[session.id] { stop(old) }
        let watch = Watch(session: session)
        watches[session.id] = watch
        return watch
    }

    /// Starts whatever the session's state asks for and is not loaded or loading.
    private func sync(_ watch: Watch) {
        guard let session = watch.session, watches[session.id] === watch else { return }
        arm(session, watch)
        guard watch.shows, let source = watch.source, let folder = watch.folder else { return }
        if watch.tab != session.tab {
            // Coming to Commits, or back from it, read what the tab shows again rather than wait for the tick.
            if session.tab == .commits {
                watch.refsDue = true
                watch.statusDue = true
            } else if watch.tab == .commits {
                watch.statusDue = true
            }
            watch.tab = session.tab
        }
        resolve(session, watch, source, folder)
        // While another folder resolves, the last answer stays shown and nothing new starts.
        guard watch.resolved == Key(source, folder), let repository = session.git.repository else { return }
        let queries = GitQueries(source: source, root: repository.root)
        // The log first: every tab's git reads share the helper's two git workers, so what is asked first runs first.
        log(session, watch, queries, repository)
        status(session, watch, queries, repository)
        changesDiff(session, watch, queries, repository)
        detail(session, watch, queries, repository)
        signature(session, watch, queries, repository)
        commitDiff(session, watch, queries, repository)
    }

    /// One observation at a time, like the files loader's: the session's git inputs wake `sync`.
    private func arm(_ session: FilesSession, _ watch: Watch) {
        guard !watch.armed else { return }
        watch.armed = true
        withObservationTracking {
            _ = session.tab
            _ = session.logWanted
            _ = session.logScope
            _ = session.logFilter
            _ = session.selectedCommit
            _ = session.changesSelection
            _ = session.commitFile
            _ = session.status
            _ = session.commitDetail
        } onChange: { [weak self, weak watch] in
            Task { @MainActor [weak self, weak watch] in
                guard let self, let watch else { return }
                watch.armed = false
                self.sync(watch)
            }
        }
    }

    /// Hidden or offline: nothing runs. What shows stays; the next shown pass picks up from there.
    private func stop(_ watch: Watch) {
        cancelResolving(watch)
        watch.statusTask?.cancel()
        watch.statusTask = nil
        watch.statusAttempt = nil
        watch.logTask?.cancel()
        watch.logTask = nil
        watch.logAttempt = nil
        for job in [watch.changes, watch.detail, watch.commit, watch.signature] {
            job?.task?.cancel()
            job?.timer?.cancel()
        }
        watch.changes = nil
        watch.detail = nil
        watch.commit = nil
        watch.signature = nil
    }

    /// A different repository (or none): everything read from the last one goes, selections included.
    private func reset(_ session: FilesSession, _ watch: Watch) {
        stop(watch)
        watch.marks = nil
        watch.untracked = [:]
        watch.sizes = [:]
        watch.pages = nil
        watch.pagesTarget = nil
        watch.refs = []
        watch.head = nil
        remark(session)
        if session.status != nil { session.status = nil }
        if session.log != nil { session.log = nil }
        if session.changesSelection != nil { session.changesSelection = nil }
        if session.changesDiff != nil { session.changesDiff = nil }
        if session.selectedCommit != nil { session.selectedCommit = nil }
        if session.commitDetail != nil { session.commitDetail = nil }
        if session.commitDetailError != nil { session.commitDetailError = nil }
        if !session.signatureChecks.isEmpty { session.signatureChecks = [:] }
        if session.commitFile != nil { session.commitFile = nil }
        if session.commitDiff != nil { session.commitDiff = nil }
        if session.logWanted != Self.page { session.logWanted = Self.page }
    }

    private func apply(_ state: GitState, _ session: FilesSession, _ watch: Watch) {
        if session.git.repository != state.repository { reset(session, watch) }
        if session.git != state { session.git = state }
    }

    // MARK: Repository

    private func resolve(_ session: FilesSession, _ watch: Watch, _ source: any FilesSource, _ folder: String) {
        let key = Key(source, folder)
        if watch.resolved == key {
            // Back at the folder `git` answers for: an answer still coming for another one is moot.
            if watch.resolvingKey != nil { cancelResolving(watch) }
            return
        }
        if let state = cached(source, folder) {
            cancelResolving(watch)
            watch.resolved = key
            watch.answered = key
            apply(state, session, watch)
            showResolving(watch)
            return
        }
        guard watch.resolvingKey != key, watch.failed != key else { return }
        watch.resolving?.cancel()
        watch.resolvingKey = key
        showResolving(watch)
        watch.resolving = Task { [weak self, weak watch] in
            let result: Result<GitRepository?, GitError>
            do throws(GitError) { result = .success(try await GitQueries.repository(of: folder, source: source)) } catch { result = .failure(error) }
            guard let self, let watch, watch.resolvingKey == key else { return }
            watch.resolving = nil
            watch.resolvingKey = nil
            self.showResolving(watch)
            guard watch.shows, watch.source === source, watch.folder == folder, let session = watch.session else { return }
            let state: GitState
            switch result {
            case .success(let repository?): state = .repository(repository)
            case .success(nil), .failure(.notRepository): state = .none
            // git is missing, the grant leaves it out, or git refused the folder (dubious ownership): an answer.
            case .failure(.unavailable(let message)), .failure(.failed(let message)): state = .unavailable(message)
            case .failure(.source(.notFound)), .failure(.source(.notDirectory)):
                // The folder is gone, so no repository holds it; not remembered, as it may come back, and asked again
                // on the next tick.
                watch.failed = key
                watch.answered = key
                self.apply(.none, session, watch)
                return
            case .failure(.source):
                // Offline, past the deadline, a busy or broken helper: no answer. What shows stays (on a tab never
                // resolved that is `.loading`, so ⇧⌘U's Changes waits instead of falling back to Files for good) and
                // the next tick asks again.
                watch.failed = key
                return
            }
            self.store(state, source, folder)
            watch.resolved = key
            watch.answered = key
            self.apply(state, session, watch)
            self.sync(watch)
        }
    }

    private func cancelResolving(_ watch: Watch) {
        watch.resolving?.cancel()
        watch.resolving = nil
        watch.resolvingKey = nil
        showResolving(watch)
    }

    /// `gitResolving`: the shown folder's repository is being asked for while `git` still answers for another folder
    /// (or none yet). Asking again about the same folder, after a prompt, is not resolving: nothing shown is stale.
    private func showResolving(_ watch: Watch) {
        guard let session = watch.session else { return }
        let resolving = watch.resolvingKey.map { $0 != watch.answered } ?? false
        if session.gitResolving != resolving { session.gitResolving = resolving }
    }

    private func store(_ state: GitState, _ source: any FilesSource, _ folder: String) {
        cache = cache.filter { $0.value.source != nil }
        if cache[source.endpoint]?.source !== source || (cache[source.endpoint]?.folders.count ?? 0) >= Self.cachedFolders {
            cache[source.endpoint] = Cache(source: source)
        }
        cache[source.endpoint]?.folders[folder] = state
    }

    private func forgetCached(_ source: any FilesSource, _ folder: String) {
        guard cache[source.endpoint]?.source === source else { return }
        cache[source.endpoint]?.folders[folder] = nil
    }

    /// The repository vanished under a query (`rm -rf .git`): forget it and say so.
    private func lost(_ session: FilesSession, _ watch: Watch) {
        if let source = watch.source, let folder = watch.folder {
            forgetCached(source, folder)
            store(.none, source, folder)
        }
        apply(.none, session, watch)
    }

    private func failed(_ error: GitError, _ session: FilesSession, _ watch: Watch) {
        switch error {
        case .notRepository: lost(session, watch)
        case .unavailable(let message): apply(.unavailable(message), session, watch)
        case .failed, .source: break
        }
    }

    // MARK: Status and marks

    /// Every tab reads the status on the tick, after a prompt and when Commits is entered or left: Files marks its
    /// listings with it, Changes lists it, Commits shows its uncommitted row and the branch's ahead and behind.
    private func status(_ session: FilesSession, _ watch: Watch, _ queries: GitQueries, _ repository: GitRepository) {
        let due = watch.statusDue || watch.statusAttempt != repository
        guard due else { return }
        // On Commits the log is what shows: its first read goes ahead of a status read, which on a large tree holds a
        // git worker for seconds. The status follows as the log answers (its task's end syncs again).
        if session.tab == .commits, session.log == nil, watch.logTask != nil { return }
        // A tick or prompt during a read leaves `statusDue` set: the next read starts when this one ends, so what the
        // shell changed after it began is still read.
        guard watch.statusTask == nil else { return }
        watch.statusDue = false
        watch.statusAttempt = repository
        let counted = watch.untracked, sized = watch.sizes
        let listed = listedFiles(session, repository)
        let source = queries.source
        watch.statusToken += 1
        let token = watch.statusToken
        watch.statusTask = Task { [weak self, weak watch] in
            let result = await Self.readStatus(queries, counted: counted, sized: sized, listed: listed)
            guard let self, let watch, watch.statusToken == token else { return }
            watch.statusTask = nil
            defer { self.sync(watch) }
            guard watch.shows, watch.source === source, let session = watch.session, session.git.repository == repository else { return }
            switch result {
            case .success(let read):
                watch.untracked = read.counted
                watch.sizes = read.sized
                var status = read.status
                status.loadedAt = self.environment.now()
                let previous = session.status.map(GitChangesText.ordered) ?? []
                if let shown = session.status {
                    var same = shown
                    same.loadedAt = status.loadedAt
                    if same != status { session.status = status }
                } else {
                    session.status = status
                }
                self.reconcileSelection(session, previous: previous)
                if watch.marks != read.marks {
                    watch.marks = read.marks
                    self.remark(session)
                }
            case .failure(let error):
                self.failed(error, session, watch)
            }
        }
    }

    /// The Changes selection under a new status (`GitChangesText.reconciled`): the same change, else its path in the area
    /// it moved to (`git add`), else the change now where it was, else the first. Nothing selected stays so off the
    /// Changes tab; on it the first change is picked, as the list shows it selected.
    private func reconcileSelection(_ session: FilesSession, previous: [GitChange]) {
        guard let status = session.status, session.changesSelection != nil || session.tab == .changes else { return }
        let selection = GitChangesText.reconciled(session.changesSelection, previous: previous,
                                                  current: GitChangesText.ordered(status))
        if selection != session.changesSelection { session.changesSelection = selection }
    }

    /// Size and modification time of the changed and untracked files whose folders are listed: a count, or a binary's
    /// sizes, is redone when they change.
    private func listedFiles(_ session: FilesSession, _ repository: GitRepository) -> [String: Stamp] {
        let root = repository.root
        var out: [String: Stamp] = [:]
        for (path, state) in session.listings where FilesLoader.path(path, isInside: root) {
            let folder = path == root ? "" : String(path.dropFirst(root == "/" ? 1 : root.count + 1))
            for entry in state.entries where entry.isRegularFile && entry.mark != nil && entry.mark != GitChangeKind.ignored.rawValue {
                out[folder.isEmpty ? entry.name : folder + "/" + entry.name] = Stamp(size: entry.size, modified: entry.modified)
            }
        }
        return out
    }

    private struct StatusRead: Sendable {
        var status: GitStatus
        var marks: GitMarks
        var counted: [String: Counted]
        var sized: [String: Sized]
    }

    /// The status, both sides' counts, the untracked files' line counts and the binaries' sizes, folded into one
    /// `GitStatus`.
    private nonisolated static func readStatus(_ queries: GitQueries, counted: [String: Counted], sized: [String: Sized],
                                               listed: [String: Stamp]) async -> Result<StatusRead, GitError> {
        do {
            async let porcelainRead = queries.status()
            async let unstagedRead = queries.numstat(cached: false)
            async let stagedRead = queries.numstat(cached: true)
            let porcelain = try await porcelainRead, unstaged = try await unstagedRead, staged = try await stagedRead
            var counts = [GitChangeArea.unstaged: [String: GitNumstat](), .staged: [:]]
            for count in unstaged { counts[.unstaged]?[count.path] = count }
            for count in staged { counts[.staged]?[count.path] = count }
            var next: [String: Counted] = [:]
            var budget = countBudget
            let untracked = porcelain.changes.filter { $0.area == .untracked && !$0.path.hasSuffix("/") && $0.representable }
                .prefix(countedUntracked)
            for change in untracked {
                let stamp = listed[change.path]
                if let known = counted[change.path], known.matches(stamp) {
                    next[change.path] = known
                    continue
                }
                if let size = stamp?.size, size > countedBytes {
                    // Too big to count: no count, and nothing read until the listing shows it changed.
                    next[change.path] = Counted(lines: nil, binary: false, stamp: stamp)
                    continue
                }
                // What this read has left must cover the file (the most a count reads, while its size is not listed):
                // else a later read counts it, rather than reading part of it now for nothing.
                guard budget >= stamp?.size ?? countedBytes,
                      let count = try? await queries.untrackedLines(change.path, limit: countedBytes) else { continue }
                budget -= min(UInt64(count.read), budget)
                next[change.path] = Counted(lines: count.lines, binary: count.binary,
                                            stamp: stamp ?? Stamp(size: count.size, modified: count.modified))
            }
            var changes = porcelain.changes.map { change -> GitChange in
                var change = change
                if change.area == .untracked {
                    guard let known = next[change.path] else { return change }
                    change.additions = known.lines
                    change.deletions = known.lines.map { _ in 0 }
                    change.binary = known.binary
                    if known.binary { change.newSize = known.stamp?.size }
                } else if let count = counts[change.area]?[change.path] {
                    // Only what the status lists takes counts: numstat also names a binary that is merely stat-dirty.
                    change.additions = count.additions
                    change.deletions = count.deletions
                    change.binary = count.binary
                }
                return change
            }
            // A binary's sizes, so the list says "binary · 48 KB → 51 KB" before anything is selected. Asked again
            // after a prompt (`pass`) or, for the work tree's side, when its listing shows the file changed.
            var sizes: [String: Sized] = [:], asked = 0
            for index in changes.indices where changes[index].binary && changes[index].area != .untracked
                && changes[index].representable {
                let change = changes[index]
                let stamp = change.area == .unstaged ? listed[change.path] : nil
                var known = sized[change.id]
                if let sizes = known, let stamp, sizes.stamp != stamp {
                    // Sized before its folder was listed: the listing showing the work tree's size it gave confirms it.
                    if sizes.stamp == nil, sizes.new == stamp.size { known?.stamp = stamp } else { known = nil }
                }
                if known == nil, asked < sizedBinaries {
                    asked += 1
                    if let found = try? await queries.sizes(change) {
                        known = Sized(old: found.old, new: found.new, stamp: stamp)
                    }
                }
                guard let known else { continue }
                sizes[change.id] = known
                changes[index].oldSize = known.old
                changes[index].newSize = known.new
            }
            let status = GitStatus(branch: porcelain.branch, head: porcelain.head.map { String($0.prefix(7)) },
                                   upstream: porcelain.upstream, ahead: porcelain.ahead, behind: porcelain.behind,
                                   changes: changes, loadedAt: Date(timeIntervalSince1970: 0), truncated: porcelain.truncated)
            return .success(StatusRead(status: status, marks: GitMarks(porcelain), counted: next, sized: sizes))
        } catch let error as GitError {
            return .failure(error)
        } catch {
            return .failure(.source(.cancelled))
        }
    }

    /// Sets every listing's marks from the current status; a listing whose marks are unchanged keeps its value.
    private func remark(_ session: FilesSession) {
        var listings = session.listings, changed = false
        for (path, state) in listings {
            guard let listing = state.listing else { continue }
            let marked = marked(listing, in: session)
            if marked != listing {
                listings[path]?.listing = marked
                changed = true
            }
        }
        if changed { session.listings = listings }
    }

    // MARK: Log

    private func log(_ session: FilesSession, _ watch: Watch, _ queries: GitQueries, _ repository: GitRepository) {
        guard session.tab == .commits else { return }
        let target = LogTarget(repository: repository, scope: session.logScope, filter: session.logFilter)
        let wanted = max(session.logWanted, Self.page)
        if watch.logTask != nil {
            // A different scope or filter replaces the read in flight; more of the same waits for it.
            guard watch.logTarget != target else { return }
            watch.logTask?.cancel()
            watch.logTask = nil
        }
        let base: GitLogPages?
        let checkRefs: Bool
        if watch.pagesTarget != target || watch.pages == nil {
            guard watch.logAttempt != target || watch.refsDue else { return }
            base = nil
            checkRefs = true
        } else if let pages = watch.pages, pages.queries.contains(where: { !$0.exhausted && $0.commits.count < wanted }) {
            base = pages
            checkRefs = watch.refsDue
        } else if watch.refsDue {
            base = watch.pages
            checkRefs = true
        } else {
            return
        }
        watch.refsDue = false
        watch.logAttempt = target
        watch.logTarget = target
        let refs = watch.refs, head = watch.head, source = queries.source
        watch.logToken += 1
        let token = watch.logToken
        watch.logTask = Task { [weak self, weak watch] in
            let result = await Self.readLog(queries, target: target, base: base, refs: refs, head: head, checkRefs: checkRefs,
                                            wanted: wanted)
            guard let self, let watch, watch.logToken == token else { return }
            watch.logTask = nil
            defer { self.sync(watch) }
            guard watch.shows, watch.source === source, let session = watch.session, session.git.repository == repository,
                  session.logScope == target.scope, session.logFilter == target.filter else { return }
            switch result {
            case .success(let read):
                let moved = read.refs != watch.refs || read.head != watch.head
                watch.refs = read.refs
                watch.head = read.head
                watch.pages = read.pages
                watch.pagesTarget = target
                let log = GitLog(commits: GitRefs.merge(read.pages.commits, refs: read.refs), exhausted: read.pages.exhausted,
                                 scope: target.scope, filter: target.filter, loadedAt: self.environment.now())
                if let shown = session.log {
                    var same = shown
                    same.loadedAt = log.loadedAt
                    if same != log { session.log = log }
                } else {
                    session.log = log
                }
                if moved {
                    // A commit, checkout or fetch: the detail's chips may have changed too.
                    if let detail = session.commitDetail {
                        let merged = GitRefs.merge(detail, refs: read.refs)
                        if merged != detail { session.commitDetail = merged }
                    }
                }
            case .failure(let error):
                self.failed(error, session, watch)
                // A busy helper (its git queue full of other tabs' status reads) or a dropped request: ask again
                // shortly rather than on the next tick, a few times.
                guard case .source(let reason) = error, reason != .cancelled, watch.logRetries < Self.logRetries else { return }
                watch.logRetries += 1
                Task { [weak self, weak watch] in
                    try? await self?.environment.sleep(Self.logRetryDelay)
                    guard let self, let watch, watch.logTask == nil, watch.logAttempt == target else { return }
                    watch.logAttempt = nil
                    self.sync(watch)
                }
                return
            }
            watch.logRetries = 0
        }
    }

    private struct LogRead: Sendable {
        var pages: GitLogPages
        var refs: [GitRefRecord]
        var head: String?
    }

    /// The refs and HEAD (when asked) and the log: from the start when there is no base or either moved, else the
    /// base's unfinished queries filled up to `wanted`. HEAD is read beside the refs because a detached HEAD moves
    /// without any of them; the new pages start from it (`GitLogPages.tip`).
    private nonisolated static func readLog(_ queries: GitQueries, target: LogTarget, base: GitLogPages?, refs: [GitRefRecord],
                                            head: String?, checkRefs: Bool, wanted: Int) async -> Result<LogRead, GitError> {
        do throws(GitError) {
            // The refs and HEAD side by side: each is a git run (and its filter probe) through the helper's queue.
            async let refsRead = checkRefs ? Self.attempt { () throws(GitError) in try await queries.refs() } : .success(refs)
            async let headRead = checkRefs ? Self.attempt { () throws(GitError) in try await queries.head() } : .success(head)
            let current = try await refsRead.get(), tip = try await headRead.get()
            var pages: GitLogPages
            if let base, current == refs, tip == head {
                pages = base
            } else {
                pages = GitLogPages(scope: target.scope, filter: target.filter, tip: tip)
            }
            let loaded = base?.queries.map(\.commits.count).max() ?? 0
            try await pages.fill(max(wanted, loaded), with: queries)
            return .success(LogRead(pages: pages, refs: current, head: tip))
        } catch {
            return .failure(error)
        }
    }

    /// A read's failure as a value, for an `async let` (whose errors are untyped).
    private nonisolated static func attempt<T: Sendable>(_ read: @Sendable () async throws(GitError) -> T) async
        -> Result<T, GitError> {
        do throws(GitError) { return .success(try await read()) } catch { return .failure(error) }
    }

    // MARK: Selections

    /// The Changes tab's selected change: git's diff for staged and unstaged changes, the file itself for an untracked
    /// one. Read again when the status shows the change differently (its counts moved) or after a prompt.
    private func changesDiff(_ session: FilesSession, _ watch: Watch, _ queries: GitQueries, _ repository: GitRepository) {
        guard session.tab == .changes else { return }
        if let status = session.status, session.changesSelection.map({ id in !status.changes.contains { $0.id == id } }) ?? true {
            // Coming to the tab with nothing selected, or with a selection the status does not list.
            reconcileSelection(session, previous: GitChangesText.ordered(status))
        }
        guard let id = session.changesSelection else {
            cancel(&watch.changes)
            if session.changesDiff != nil { session.changesDiff = nil }
            return
        }
        guard let status = session.status else { return }
        guard let change = status.changes.first(where: { $0.id == id }) else {
            // The change is gone (committed, reverted, or staged and so in another group).
            cancel(&watch.changes)
            if session.changesDiff != nil { session.changesDiff = nil }
            return
        }
        if let job = watch.changes, job.key == id, job.input == AnyHashable(change) { return }
        let fresh = watch.changes?.key != id || session.changesDiff?.key != id
        load(.changes, watch, key: id, input: change, fresh: fresh, repository: repository, source: queries.source) {
            () async throws(GitError) -> GitDiff in try await queries.diff(change)
        }
    }

    /// The selected commit's signature, checked once it is known to carry one (the log says so), beside its detail:
    /// gpg can take a moment, so the files and diff never wait for it. Kept by hash; a failed source asks on the tick.
    private func signature(_ session: FilesSession, _ watch: Watch, _ queries: GitQueries, _ repository: GitRepository) {
        guard session.tab == .commits, let hash = session.selectedCommit,
              session.log?.commits.first(where: { $0.hash == hash })?.signature != nil,
              session.signatureChecks[hash] == nil else { return }
        if let job = watch.signature, job.key == hash, job.input != nil { return }
        cancel(&watch.signature)
        let source = queries.source
        let job = Job(key: hash, input: hash)
        watch.signature = job
        job.task = Task { [weak self, weak watch, weak job] in
            let check = await queries.verify(hash)
            guard self != nil, let watch, let job, watch.signature === job else { return }
            job.task = nil
            guard watch.shows, watch.source === source, let session = watch.session, session.git.repository == repository
            else { return }
            guard let check else {
                job.failed = true
                return
            }
            session.signatureChecks[hash] = check
        }
    }

    private func detail(_ session: FilesSession, _ watch: Watch, _ queries: GitQueries, _ repository: GitRepository) {
        guard session.tab == .commits else { return }
        guard let hash = session.selectedCommit else {
            cancel(&watch.detail)
            if session.commitDetail != nil { session.commitDetail = nil }
            if session.commitDetailError != nil { session.commitDetailError = nil }
            return
        }
        // Loaded or loading; a failed or cancelled load has no input and is read again.
        if let job = watch.detail, job.key == hash, job.input != nil { return }
        // Another commit's error is not this one's; a retry keeps its own until it answers.
        if watch.detail?.key != hash, session.commitDetailError != nil { session.commitDetailError = nil }
        cancel(&watch.detail)
        let source = queries.source
        let job = Job(key: hash, input: hash)
        watch.detail = job
        job.task = Task { [weak self, weak watch, weak job] in
            let result: Result<GitCommitDetail, GitError>
            do throws(GitError) { result = .success(try await queries.commit(hash)) } catch { result = .failure(error) }
            guard let self, let watch, let job, watch.detail === job else { return }
            job.task = nil
            guard watch.shows, watch.source === source, let session = watch.session, session.git.repository == repository,
                  session.selectedCommit == hash else { return }
            switch result {
            case .success(let detail):
                let merged = GitRefs.merge(detail, refs: watch.refs)
                if session.commitDetail != merged { session.commitDetail = merged }
                if session.commitDetailError != nil { session.commitDetailError = nil }
            case .failure(.source(.cancelled)):
                // Read again on the next sync.
                job.input = nil
            case .failure(let error):
                // Shown in the detail pane instead of a spinner that never ends; the next tick asks again.
                job.failed = true
                if session.commitDetail != nil { session.commitDetail = nil }
                if session.commitDetailError != error.message { session.commitDetailError = error.message }
                self.failed(error, session, watch)
            }
        }
    }

    /// The file picked in the commit's detail; waits for that detail, which says whether it was renamed.
    private func commitDiff(_ session: FilesSession, _ watch: Watch, _ queries: GitQueries, _ repository: GitRepository) {
        guard session.tab == .commits else { return }
        guard let hash = session.selectedCommit, let path = session.commitFile else {
            cancel(&watch.commit)
            if session.commitDiff != nil { session.commitDiff = nil }
            return
        }
        guard let detail = session.commitDetail, detail.commit.hash == hash else { return }
        let key = hash + ":" + path
        // Loaded or loading; a failed or cancelled load has no input and is read again.
        if let job = watch.commit, job.key == key, job.input != nil { return }
        let fresh = session.commitDiff?.key != key
        let old = detail.files.first { $0.path == path }?.oldPath, commit = detail.commit
        load(.commit, watch, key: key, input: key, fresh: fresh, repository: repository, source: queries.source) {
            () async throws(GitError) -> GitDiff in try await queries.commitDiff(commit, path: path, oldPath: old)
        }
    }

    private enum Slot { case changes, commit }

    /// Loads a diff into its slot. The previous diff stays until the new one answers; one slower than `loadingDelay`
    /// shows as loading under its new key meanwhile.
    private func load(_ slot: Slot, _ watch: Watch, key: String, input: AnyHashable, fresh: Bool, repository: GitRepository,
                      source: any FilesSource, _ body: @escaping @Sendable () async throws(GitError) -> GitDiff) {
        switch slot {
        case .changes: cancel(&watch.changes)
        case .commit: cancel(&watch.commit)
        }
        let job = Job(key: key, input: input)
        switch slot {
        case .changes: watch.changes = job
        case .commit: watch.commit = job
        }
        func current(_ watch: Watch) -> Job? { slot == .changes ? watch.changes : watch.commit }
        func valid(_ watch: Watch) -> FilesSession? {
            guard watch.shows, watch.source === source, let session = watch.session, session.git.repository == repository
            else { return nil }
            return session
        }
        func write(_ state: GitDiffState, _ session: FilesSession) {
            switch slot {
            case .changes: if session.changesDiff != state { session.changesDiff = state }
            case .commit: if session.commitDiff != state { session.commitDiff = state }
            }
        }
        if fresh {
            let sleep = environment.sleep
            job.timer = Task { [weak watch, weak job] in
                do { try await sleep(Self.loadingDelay) } catch { return }
                guard let watch, let job, current(watch) === job, job.task != nil, let session = valid(watch) else { return }
                write(GitDiffState(key: key, loading: true), session)
            }
        }
        job.task = Task { [weak self, weak watch, weak job] in
            let result: Result<GitDiff, GitError>
            do throws(GitError) { result = .success(try await body()) } catch { result = .failure(error) }
            guard let self, let watch, let job, current(watch) === job else { return }
            job.task = nil
            job.timer?.cancel()
            job.timer = nil
            guard let session = valid(watch) else { return }
            switch result {
            case .success(let diff): write(GitDiffState(key: key, diff: diff), session)
            case .failure(.source(.cancelled)):
                // Read again on the next sync.
                job.input = nil
            case .failure(let error):
                if case .notRepository = error { return self.lost(session, watch) }
                // Asked again on the next tick (`pass`); the error shows until then.
                job.failed = true
                write(GitDiffState(key: key, error: error.message), session)
            }
        }
    }

    private func cancel(_ job: inout Job?) {
        job?.task?.cancel()
        job?.timer?.cancel()
        job = nil
    }

    // MARK: Per-session state

    struct Key: Equatable {
        let source: ObjectIdentifier
        let folder: String

        init(_ source: any FilesSource, _ folder: String) {
            self.source = ObjectIdentifier(source)
            self.folder = folder
        }
    }

    struct LogTarget: Equatable, Sendable {
        var repository: GitRepository
        var scope: GitLogScope
        var filter: String
    }

    /// An untracked file's size and modification time as its folder's listing shows them.
    struct Stamp: Hashable, Sendable {
        var size: UInt64
        var modified: Date?
    }

    /// An untracked file's counted lines and the stamp they were counted at.
    struct Counted: Hashable, Sendable {
        var lines: Int?
        var binary: Bool
        var stamp: Stamp?

        /// Still good: the listing shows the file as it was counted (the stamp is the listing's, or the read's when its
        /// folder was not listed then), or does not show it (its folder is collapsed): nothing tells it changed, so it
        /// is not read again.
        func matches(_ listed: Stamp?) -> Bool {
            guard let listed, let stamp else { return true }
            return listed == stamp
        }
    }

    /// A staged or unstaged binary's sizes as `diff --stat` gave them, and (unstaged) its listing's stamp then.
    struct Sized: Hashable, Sendable {
        var old: UInt64
        var new: UInt64
        var stamp: Stamp?
    }

    /// One selection's load: what it is for and, while it runs, its task.
    @MainActor final class Job {
        let key: String
        /// What the load read; nil makes the next sync read again.
        var input: AnyHashable?
        /// The load failed: the next tick clears `input`, so it is asked for again then and not on every sync.
        var failed = false
        var task: Task<Void, Never>?
        var timer: Task<Void, Never>?

        init(key: String, input: AnyHashable) {
            self.key = key
            self.input = input
        }
    }

    @MainActor final class Watch {
        weak var session: FilesSession?
        let id: UUID
        var source: (any FilesSource)?
        var host: String?
        var folder: String?
        var shows = false
        var prompted = false
        var armed = false
        var tab: FilesTab?

        /// The source and folder `session.git` answers for, while that answer holds (a prompt asks again).
        var resolved: Key?
        /// The source and folder `session.git` was last set for, kept while the same folder is asked again.
        var answered: Key?
        var resolving: Task<Void, Never>?
        var resolvingKey: Key?
        /// A folder whose resolution failed: asked again on the next tick, not on every change.
        var failed: Key?

        var statusDue = false
        /// The repository the last status read was for, so a failing one is retried on the tick, not in a loop.
        var statusAttempt: GitRepository?
        var statusTask: Task<Void, Never>?
        var statusToken = 0
        var marks: GitMarks?
        var untracked: [String: Counted] = [:]
        /// By `GitChange.id`.
        var sizes: [String: Sized] = [:]

        var refsDue = false
        var refs: [GitRefRecord] = []
        /// HEAD's commit when the refs were read.
        var head: String?
        var pages: GitLogPages?
        var pagesTarget: LogTarget?
        var logAttempt: LogTarget?
        var logTarget: LogTarget?
        var logTask: Task<Void, Never>?
        var logToken = 0
        /// Quick retries since the last log read that answered.
        var logRetries = 0

        var changes: Job?
        var detail: Job?
        var commit: Job?
        var signature: Job?

        init(session: FilesSession) {
            self.session = session
            id = session.id
        }
    }
}
