import Foundation
import Observation

/// One tab's Files listing (H1): the folder it shows, the breadcrumb's root, the listings read so far, the folders'
/// item counts, git's marks, the sort, hidden files and the name search. The folder is the tab's (its active pane's
/// cwd) and follows it: a cd in the shell moves the listing there, whatever folder the user had opened; tapping a folder
/// or a crumb moves only the listing. The root is the repository's (`SpaceGitFacts`) when the folder is inside one,
/// else the home folder when it is inside that, else "/". Everything is read through `source` (the host's helper while
/// it is connected); without one the last listings stay, and nothing is asked.
@MainActor @Observable
final class FilesBrowser {
    /// A name search's hit below the shown folder.
    struct Hit: Identifiable, Equatable {
        let path: String
        let entry: FileEntry
        /// Its folder relative to the searched one ("components/ui"), "" for the searched folder itself.
        let folder: String
        var id: String { path }
    }

    /// Why a search stopped before it looked everywhere.
    enum SearchBound: Equatable {
        /// `hitLimit` matches found.
        case hits
        /// The folder, time or depth bound: this many folders were looked in.
        case folders(Int)
    }

    let tab: TabRef
    /// The host's name, for the offline state.
    let host: String
    /// The folder shown, nil until the tab's folder is known.
    private(set) var folder: String?
    /// The breadcrumb's first crumb: the repository's root, the home folder or "/".
    private(set) var root: String?
    /// The tab's folder last followed (a cd changes it; the user's own navigation does not).
    private(set) var followed: String?
    private(set) var listings: [String: FileListingState] = [:]
    /// git's marks for the repository at `marksRoot` (`files.git status`), nil outside a repository or before the read.
    private(set) var marks: GitMarks?
    private(set) var marksRoot: String?
    /// The last status was cut at its bound: the letters are the first files' only.
    private(set) var marksTruncated = false
    /// Files' sort and hidden files: the store's, shared by every tab.
    var sort: FilesSort { get { preferences.sort } set { preferences.sort = newValue } }
    var showsHidden: Bool {
        get { preferences.hidden }
        set {
            preferences.hidden = newValue
            if searching { search() }
        }
    }
    /// The search field shows; `query` filters the folder by name, then the search walks below it.
    var searching = false
    var query = "" { didSet { if query != oldValue { search() } } }
    private(set) var hits: [Hit] = []
    /// The walk below the folder runs (or waits out its debounce).
    private(set) var walking = false
    /// Why the last walk stopped early; nil when it looked everywhere.
    private(set) var walkBound: SearchBound?

    @ObservationIgnored let preferences: FilesPreferences
    @ObservationIgnored private let source: @MainActor () -> (any MobileFilesSource)?
    @ObservationIgnored private let pause: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private var home: String?
    @ObservationIgnored private var walk: Task<Void, Never>?
    @ObservationIgnored private var loads: [String: Task<Void, Never>] = [:]
    /// Listing keys, least recently used first (`listingLimit`).
    @ObservationIgnored private var used: [String] = []
    /// Item counts: paths waiting, the reads running (by key), and keys whose read failed this session.
    @ObservationIgnored private var countQueue: [String] = []
    @ObservationIgnored private var counting: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var countFailed: Set<String> = []
    /// git's marks: a read is wanted that could not be asked (no connection then), and the read running.
    @ObservationIgnored private var marksPending = false
    @ObservationIgnored private var marksTask: Task<Void, Never>?

    /// Folders listed at once for their item counts, and at most waiting.
    static let countConcurrency = 4
    static let countQueueLimit = 32
    /// Listings kept per tab (the least recently used go first; the shown folder's never).
    static let listingLimit = 48
    /// The search's bounds: folders it looks in, hits it keeps, how deep and how long it walks, and its debounce.
    static let walkLimit = 400
    static let hitLimit = 200
    static let depthLimit = 12
    static let walkSeconds: TimeInterval = 10
    static let debounce: Duration = .milliseconds(250)
    /// Never walked into: package folders and git's own (they hold most of a repository's names and none the user wants).
    static let skipped: Set<String> = [".git", "node_modules", ".build", "DerivedData", "target", ".venv", "__pycache__"]
    /// Never walked into from above: the kernel's and devices' pseudo-filesystems and other volumes.
    static let pseudo: Set<String> = ["/proc", "/sys", "/dev", "/Volumes", "/System/Volumes", "/run", "/private/var/vm"]
    /// `files.git status`'s output bound.
    static let statusLimit: UInt64 = 1 << 20

    init(tab: TabRef, host: String, preferences: FilesPreferences = FilesPreferences(),
         pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         clock: @escaping @MainActor () -> Date = { System.date() },
         source: @escaping @MainActor () -> (any MobileFilesSource)?) {
        self.tab = tab
        self.host = host
        self.preferences = preferences
        self.pause = pause
        self.clock = clock
        self.source = source
    }

    // MARK: Folder and root

    /// The tab's folder and the repository's root (nil outside one or until read), from the tab screen. A new folder
    /// (the shell's cd) is shown at once; a root that arrives later only changes the breadcrumb.
    func follow(directory: String?, repository: String?, home: String?) {
        self.home = home.map(FilesPath.normalized)
        guard let directory = directory.map(FilesPath.normalized), directory.hasPrefix("/") else { return }
        let root = Self.root(for: directory, repository: repository, home: self.home)
        if directory != followed {
            followed = directory
            self.root = root
            show(directory)
        } else if root != self.root, let folder, FilesPath.isWithin(folder, root) {
            self.root = root
        }
        // A root first followed without a connection is asked once there is one.
        if repository != marksRoot || marksPending { refreshMarks(repository: repository) }
    }

    /// The repository's root when `directory` is inside it, else the home folder when inside that, else "/".
    static func root(for directory: String, repository: String?, home: String?) -> String {
        if let repository = repository.map(FilesPath.normalized), FilesPath.isWithin(directory, repository) { return repository }
        if let home, home != "/", FilesPath.isWithin(directory, home) { return home }
        return "/"
    }

    /// Opens a folder of the listing (a row, a crumb, a search hit's folder).
    func open(_ path: String) {
        let path = FilesPath.normalized(path)
        if let root, !FilesPath.isWithin(path, root) {
            self.root = Self.root(for: path, repository: nil, home: home)
        }
        show(path)
    }

    private func show(_ path: String) {
        guard path != folder else { return }
        cancelCounts()
        folder = path
        searching = false
        query = ""
    }

    /// root › … › folder: each crumb names its folder; the root is the repository's name, `~` or "/".
    var crumbs: [FilesCrumb] {
        guard let folder else { return [] }
        return Self.crumbs(folder: folder, root: root.flatMap { FilesPath.isWithin(folder, $0) ? $0 : nil } ?? "/", home: home)
    }

    /// The crumbs of a tab's folder before its browser follows it (the bar's first frame).
    static func crumbs(folder: String?, repository: String?, home: String?) -> [FilesCrumb] {
        guard let folder = folder.map(FilesPath.normalized), folder.hasPrefix("/") else { return [] }
        let home = home.map(FilesPath.normalized)
        return crumbs(folder: folder, root: root(for: folder, repository: repository, home: home), home: home)
    }

    static func crumbs(folder: String, root: String, home: String?) -> [FilesCrumb] {
        var crumbs = [FilesCrumb(title: root == home ? "~" : FilesPath.name(root), path: root)]
        var path = root
        for part in folder.dropFirst(root == "/" ? 1 : root.count).split(separator: "/") {
            path = FilesPath.join(path, String(part))
            crumbs.append(FilesCrumb(title: String(part), path: path))
        }
        return crumbs
    }

    // MARK: Listing

    static func key(_ path: String, hidden: Bool) -> String { (hidden ? "h:" : "v:") + path }

    func state(_ path: String) -> FileListingState? { listings[Self.key(path, hidden: showsHidden)] }

    /// The shown folder's state.
    var current: FileListingState? { folder.flatMap(state) }

    /// The shown folder's entries in the sort, folders first; while searching, those whose name holds the query.
    var rows: [FileEntry] {
        let entries = Self.sorted(current?.entries ?? [], by: sort)
        let query = query.trimmingCharacters(in: .whitespaces)
        guard searching, !query.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// The shown folder again (and git's marks): pull to refresh, Refresh, the app coming to the foreground, an agent's
    /// turn ending.
    func refresh() async {
        refreshMarks(repository: marksRoot)
        await load(force: true)
    }

    /// The host's connection came back: what was shown, or failed for want of it, is read again.
    func reconnected() async {
        if marksPending || marksRoot != nil { refreshMarks(repository: marksRoot) }
        countFailed.removeAll()
        await load(force: true)
    }

    /// Lists the shown folder: a listing read before shows at once and is read again behind it (`force`, or a
    /// listing older than a few seconds). A failure keeps what was shown, except a folder that is gone.
    func load(force: Bool = false) async {
        guard let folder else { return }
        let key = Self.key(folder, hidden: showsHidden)
        if !force, let loaded = listings[key]?.loadedAt, clock().timeIntervalSince(loaded) < 5 { return }
        await list(folder, hidden: showsHidden)
    }

    /// One listing, one request at a time per folder (a second ask waits for the first).
    private func list(_ path: String, hidden: Bool) async {
        let key = Self.key(path, hidden: hidden)
        if let running = loads[key] { return await running.value }
        guard let source = source() else {
            if listings[key]?.listing == nil { listings[key, default: FileListingState()].error = .offline(host) }
            return
        }
        listings[key, default: FileListingState()].loading = true
        let task = Task { @MainActor in
            do {
                store(key, try await source.list(path, hidden: hidden))
            } catch {
                fail(key, error)
            }
        }
        loads[key] = task
        await task.value
        loads[key] = nil
    }

    private func store(_ key: String, _ listing: FileListing) {
        listings[key] = FileListingState(listing: listing, loadedAt: clock(), error: nil, loading: false)
        countFailed.remove(key)
        touch(key)
    }

    private func fail(_ key: String, _ error: any Error) {
        let failure = error as? FilesSourceError ?? .other(code: "internal", message: error.localizedDescription)
        var state = listings[key] ?? FileListingState()
        state.loading = false
        if failure != .cancelled {
            state.error = failure
            // A folder that is gone shows so, not its last contents.
            switch failure {
            case .notFound, .notDirectory: state.listing = nil
            default: break
            }
        }
        listings[key] = state
    }

    /// Marks a listing used; past `listingLimit` the least recently used go (never the shown folder's, nor one loading).
    private func touch(_ key: String) {
        used.removeAll { $0 == key }
        used.append(key)
        guard used.count > Self.listingLimit else { return }
        let shown = folder.map { Self.key($0, hidden: showsHidden) }
        var index = 0
        while used.count > Self.listingLimit, index < used.count {
            let candidate = used[index]
            if candidate == shown || loads[candidate] != nil {
                index += 1
                continue
            }
            used.remove(at: index)
            listings[candidate] = nil
        }
    }

    /// Folders first (as Finder keeps them), then by name, newest first or largest first; ties by name.
    static func sorted(_ entries: [FileEntry], by sort: FilesSort) -> [FileEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let byName = a.name.localizedStandardCompare(b.name)
            switch sort {
            case .name: return byName == .orderedAscending
            case .modified:
                let (x, y) = (a.modified ?? .distantPast, b.modified ?? .distantPast)
                return x == y ? byName == .orderedAscending : x > y
            case .size:
                return (a.size == b.size || a.isDirectory) ? byName == .orderedAscending : a.size > b.size
            }
        }
    }

    // MARK: Item counts

    /// A folder row's "3 items": its own listing, read when the row shows (a few at a time) and kept, so opening the
    /// folder shows it at once. Nil until read.
    func count(_ path: String) -> (count: Int, truncated: Bool)? {
        guard let listing = state(path)?.listing else { return nil }
        return (listing.entries.count, listing.truncated)
    }

    /// A row showed: its count is read unless known, waiting, running or failed this session. At most
    /// `countQueueLimit` wait; the oldest give way.
    func needCount(_ path: String) {
        let key = Self.key(path, hidden: showsHidden)
        guard listings[key]?.listing == nil, counting[key] == nil, !countFailed.contains(key), !countQueue.contains(path) else { return }
        countQueue.append(path)
        if countQueue.count > Self.countQueueLimit { countQueue.removeFirst(countQueue.count - Self.countQueueLimit) }
        pumpCounts()
    }

    /// A row went off screen: its count is no longer wanted (a running read is cancelled).
    func dropCount(_ path: String) {
        countQueue.removeAll { $0 == path }
        let key = Self.key(path, hidden: showsHidden)
        counting.removeValue(forKey: key)?.cancel()
        pumpCounts()
    }

    /// The listing left the screen, or another folder shows: no count is read for it any more.
    func cancelCounts() {
        countQueue.removeAll()
        for task in counting.values { task.cancel() }
        counting.removeAll()
    }

    /// Item counts waiting and running (tests).
    var countsPending: Int { countQueue.count + counting.count }

    private func pumpCounts() {
        while counting.count < Self.countConcurrency, !countQueue.isEmpty {
            let path = countQueue.removeFirst()
            let hidden = showsHidden, key = Self.key(path, hidden: hidden)
            guard listings[key]?.listing == nil, let source = source() else { continue }
            counting[key] = Task { @MainActor [weak self] in
                do {
                    let listing = try await source.list(path, hidden: hidden)
                    guard !Task.isCancelled, let self else { return }
                    self.store(key, listing)
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError), (error as? FilesSourceError) != .cancelled else { return }
                    self?.countFailed.insert(key)
                }
                guard let self, !Task.isCancelled else { return }
                self.counting[key] = nil
                self.pumpCounts()
            }
        }
    }

    // MARK: Git

    /// The status letter a row shows, in the phone's badge letters (`GitStatusBadge`): M, A, D, R, C, T, ? untracked,
    /// U conflicted; nil for clean and ignored entries and outside a repository.
    func mark(_ entry: FileEntry) -> String? {
        guard let marks, let marksRoot, let folder else { return nil }
        let path = FilesPath.join(folder, entry.name)
        guard FilesPath.isWithin(path, marksRoot), path != marksRoot else { return nil }
        let relative = String(path.dropFirst(marksRoot == "/" ? 1 : marksRoot.count + 1))
        return Self.badge(marks.mark(relative, directory: entry.isDirectory))
    }

    /// git's letters (`GitChangeKind`) as the badge's: untracked U becomes ?, a conflict's X becomes U, ignored none.
    static func badge(_ mark: String?) -> String? {
        switch mark {
        case nil, "!"?: nil
        case "U"?: "?"
        case "X"?: "U"
        case let letter?: letter
        }
    }

    /// `files.git status` in the repository's root: the rows' letters. Outside a repository there are none. A newer
    /// read cancels the one running; without a connection the read waits for the next follow or reconnect.
    func refreshMarks(repository: String?) {
        marksTask?.cancel()
        marksTask = nil
        guard let repository else {
            marks = nil
            marksRoot = nil
            marksPending = false
            marksTruncated = false
            return
        }
        if marksRoot != repository {
            marks = nil
            marksTruncated = false
        }
        marksRoot = repository
        guard let source = source() else {
            marksPending = true
            return
        }
        marksPending = false
        marksTask = Task { @MainActor [weak self] in
            guard let output = try? await source.git(repository, args: Self.statusArguments, limit: Self.statusLimit),
                  !Task.isCancelled, let self, output.succeeded, self.marksRoot == repository else { return }
            let next = GitMarks(GitParsers.porcelain(output.output))
            if self.marks != next { self.marks = next }
            if self.marksTruncated != output.truncated { self.marksTruncated = output.truncated }
        }
    }

    static let statusArguments = ["status", "--porcelain=v2", "-z", "--untracked-files=normal"]

    // MARK: Search

    /// Starts (or stops) the walk below the shown folder for names holding the query, `debounce` after the last change:
    /// breadth first, through `files.list`, listings read before reused, hidden names only when hidden files show,
    /// never into `skipped` or (from above) `pseudo`, at most `walkLimit` folders, `depthLimit` deep, `walkSeconds`
    /// long and `hitLimit` hits. The shown folder's own matches are `rows`.
    func search() {
        walk?.cancel()
        hits = []
        walkBound = nil
        let query = query.trimmingCharacters(in: .whitespaces)
        guard searching, !query.isEmpty, let folder else {
            walking = false
            return
        }
        walking = true
        let hidden = showsHidden, pause = pause
        walk = Task { [weak self] in
            do { try await pause(Self.debounce) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.walk(from: folder, query: query, hidden: hidden)
        }
    }

    private func walk(from start: String, query: String, hidden: Bool) async {
        var queue = [(path: start, depth: 0)], looked = 0, deeper = false
        var found: [Hit] = []
        let began = clock()
        defer { if !Task.isCancelled { walking = false } }
        while !queue.isEmpty, !Task.isCancelled {
            guard looked < Self.walkLimit, clock().timeIntervalSince(began) < Self.walkSeconds else {
                walkBound = .folders(looked)
                break
            }
            let (path, depth) = queue.removeFirst()
            looked += 1
            if listings[Self.key(path, hidden: hidden)]?.listing == nil {
                await list(path, hidden: hidden)
                guard !Task.isCancelled else { return }
            }
            guard let entries = listings[Self.key(path, hidden: hidden)]?.listing?.entries else { continue }
            for entry in Self.sorted(entries, by: .name) {
                let child = FilesPath.join(path, entry.name)
                if path != start, entry.name.localizedCaseInsensitiveContains(query) {
                    let folder = String(path.dropFirst(start == "/" ? 1 : start.count + 1))
                    found.append(Hit(path: child, entry: entry, folder: folder))
                    if found.count >= Self.hitLimit { break }
                }
                guard entry.kind == .directory, !Self.skipped.contains(entry.name), !Self.pseudo.contains(child) else { continue }
                if depth + 1 <= Self.depthLimit {
                    queue.append((child, depth + 1))
                } else {
                    deeper = true
                }
            }
            hits = found
            if found.count >= Self.hitLimit {
                walkBound = .hits
                break
            }
        }
        if walkBound == nil, deeper, !Task.isCancelled { walkBound = .folders(looked) }
    }

    /// Stops searching: the folder's rows again.
    func endSearch() {
        searching = false
        query = ""
    }
}

/// Files' sort and hidden files, one choice for every tab in this run (the Mac keeps its per window).
@MainActor @Observable
final class FilesPreferences {
    var sort: FilesSort = .name
    var hidden = false
}

/// Every tab's `FilesBrowser`, made on first use and kept while the tab lives, and how they reach the host
/// (`source`: the host's connected helper with Files on, else nil).
@MainActor
final class FilesBrowsers {
    private var browsers: [TabRef: FilesBrowser] = [:]
    let preferences = FilesPreferences()
    var source: @MainActor (UUID) -> (any MobileFilesSource)? = { _ in nil }
    /// The tabs that exist: a new browser drops those of closed tabs.
    var alive: @MainActor () -> Set<TabRef>? = { nil }

    init() {
        FilesShareItem.sweep()
    }

    func browser(_ tab: TabRef, host: String) -> FilesBrowser {
        if let browser = browsers[tab] { return browser }
        if let alive = alive() { retain(alive) }
        let browser = FilesBrowser(tab: tab, host: host, preferences: preferences) { [weak self] in self?.source(tab.host) }
        browsers[tab] = browser
        return browser
    }

    /// Keeps only the tabs that still exist.
    func retain(_ tabs: Set<TabRef>) {
        for tab in browsers.keys where !tabs.contains(tab) { browsers[tab] = nil }
    }
}
