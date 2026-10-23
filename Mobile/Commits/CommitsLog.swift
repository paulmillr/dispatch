import Foundation
import Observation

/// One tab's Commits mode (H3, C2): the log page by page, the filters, the uncommitted row, and the commits opened from
/// it with their files, diffs and signature checks. Reads go through `CommitsQueries` on the tab's repository; nothing
/// is written. A refresh (showing the mode, pull to refresh, the branch changing, a new connection) reads the refs and
/// HEAD again and starts the pages over only when either moved, as the Mac's loader does; whether the work tree has
/// changes is read beside it and never holds up the log.
@MainActor @Observable
final class CommitsLog {
    enum Phase: Equatable {
        /// Nothing asked yet.
        case idle
        /// The first page is being read.
        case loading
        case loaded
        /// Nothing could be read; what was shown before stays shown (`commits`), this says why there is nothing.
        case failed(String)
    }

    /// What a pushed commit (C2) shows: loading, its files, or why not.
    enum Detail: Equatable {
        case loading
        case loaded(GitCommitDetail)
        case failed(String)
    }

    /// A commit file's diff or source (the file screen): loading, the text, or why not.
    enum Text: Equatable {
        case loading
        case diff(GitDiff)
        case source(String)
        case failed(String)
    }

    /// What Copy patch did.
    enum Patch: Equatable {
        case copied
        /// Longer than the helper gives at once: this much of it, whole lines, was copied.
        case cut(bytes: Int)
        case failed(String)
    }

    /// Pages a client-side filter (Signed only, an author's log searched by subject) loads by itself before it waits
    /// for Load more: such a filter may match nothing in the whole history.
    static let automaticPages = 5
    /// Commits opened whose files are kept, and the bytes of diffs and sources kept, most recently used first.
    static let keptDetails = 40
    static let keptTextBytes = 4 << 20

    private(set) var phase: Phase = .idle
    /// The loaded log (refs merged), newest first.
    private(set) var commits: [GitCommit] = []
    private(set) var exhausted = false
    /// A further page is being read.
    private(set) var loadingMore = false
    /// Pages read by themselves since the filter changed or Load more was tapped (`automaticPages`).
    private(set) var automatic = 0
    /// A read after the first failed: the rows stay, this is what the footer says.
    private(set) var stale: String?
    /// HEAD's commit (the current branch's tip, or a detached HEAD).
    private(set) var head: String?
    /// The work tree has changes: the hollow "Uncommitted changes" row.
    private(set) var uncommitted = false

    /// This branch's history or every ref's.
    var scope: GitLogScope = .branch { didSet { if scope != oldValue { restart() } } }
    /// The search (subjects, messages and authors, `--grep` and `--author`), as applied.
    private(set) var search = ""
    /// One author's commits only (`--author`); the search then narrows them by subject.
    var author: String? { didSet { if author != oldValue { restart() } } }
    /// Only commits whose headers carry a signature.
    var signedOnly = false { didSet { if signedOnly != oldValue { automatic = 0 } } }
    /// The search field shows in the bar.
    var searching = false
    /// What the search field holds; applied after a pause (`apply`).
    var draft = ""

    private(set) var details: [String: Detail] = [:]
    /// Signatures checked (`verify-commit`), by hash.
    private(set) var checks: [String: GitSignatureCheck] = [:]
    /// Signed commits whose check got no answer: their chip says so and offers to check again.
    private(set) var unanswered: Set<String> = []
    private(set) var texts: [String: Text] = [:]

    @ObservationIgnored private(set) var queries: CommitsQueries?
    @ObservationIgnored private var pages: GitLogPages?
    @ObservationIgnored private var refs: [GitRefRecord] = []
    @ObservationIgnored private var wanted = CommitsQueries.page
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var statusToken = 0
    @ObservationIgnored private var verifying: Set<String> = []
    @ObservationIgnored private var detailOrder: [String] = []
    @ObservationIgnored private var textOrder: [String] = []
    @ObservationIgnored private let graphs = CommitsGraphCache()

    init() {}

    /// The repository to read: a different one forgets everything read from the last.
    func attach(_ queries: CommitsQueries?) {
        guard let queries else { self.queries = nil; return }
        // A new connection to the same repository keeps what shows; the refresh it brings checks it.
        if let current = self.queries, current.root == queries.root, current.host == queries.host {
            self.queries = queries
            return
        }
        let first = self.queries == nil
        self.queries = queries
        if !first || !commits.isEmpty {
            commits = []; details = [:]; checks = [:]; unanswered = []; texts = [:]; pages = nil; refs = []; head = nil
            detailOrder = []; textOrder = []
            exhausted = false; stale = nil; phase = .idle; uncommitted = false; automatic = 0
        }
    }

    // MARK: The log

    /// The rows shown: the loaded log, with Signed only and (for one author's log) the search by subject applied.
    var shown: [GitCommit] {
        var rows = commits
        if signedOnly { rows = rows.filter { $0.signature != nil } }
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if author != nil, !text.isEmpty { rows = rows.filter { $0.subject.localizedCaseInsensitiveContains(text) } }
        return rows
    }

    /// Whether a filter narrows the log: the graph then draws each commit alone (`GitGraph.layout(linked:)`).
    var filtered: Bool { signedOnly || author != nil || !search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// A filter the phone applies to the loaded pages (not git): pages may hold none of what it keeps.
    var filteredHere: Bool { signedOnly || (author != nil && !search.trimmingCharacters(in: .whitespaces).isEmpty) }

    /// Pages remain, and the list stops asking for them by itself until Load more.
    var paused: Bool { !exhausted && filteredHere && automatic >= Self.automaticPages }

    /// The authors the filter menu offers: the loaded log's, most commits first, at most `limit`.
    func authors(limit: Int = 8) -> [String] {
        var counts: [String: Int] = [:]
        for commit in commits { counts[commit.author, default: 0] += 1 }
        if let author, counts[author] == nil { counts[author] = 0 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(limit).map(\.key)
    }

    /// The graph of the shown rows (laid out again only when they change), for a list with room for `maxLanes`.
    func graph(maxLanes: Int) -> GitGraph {
        graphs.graph(shown, head: head, uncommitted: uncommitted && !filtered, linked: !filtered, maxLanes: maxLanes)
    }

    /// The search after the pause: the log starts over with it.
    func apply(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != search else { return }
        search = text
        restart()
    }

    /// Closes the search field and drops its filter.
    func endSearch() {
        searching = false
        draft = ""
        apply("")
    }

    /// Reads the refs, HEAD and the work tree's state; the pages start over when the refs or HEAD moved (or none
    /// were read yet), else the loaded ones stay. Returns once the log answered.
    func refresh() async {
        readStatus()
        await read(fresh: false)
    }

    /// More rows: the next page, once the last one asked has come. `automatic` (the end of the list in sight) counts
    /// against a client-side filter's `automaticPages`; Load more (`automatic` false) starts that count again.
    func more(automatic: Bool = true) {
        guard !exhausted, !loadingMore, phase == .loaded, task == nil else { return }
        if automatic {
            if filteredHere {
                guard self.automatic < Self.automaticPages else { return }
                self.automatic += 1
            }
        } else {
            self.automatic = 0
        }
        wanted = max(wanted, commits.count) + CommitsQueries.page
        loadingMore = true
        task = Task { await self.read(fresh: false, more: true) }
    }

    /// A filter or the scope changed: the pages start over (the rows stay until the new ones answer).
    private func restart() {
        pages = nil
        wanted = CommitsQueries.page
        automatic = 0
        task?.cancel()
        task = Task { await self.read(fresh: true) }
    }

    /// Whether the work tree has changes, beside the log: the uncommitted row comes when it answers.
    private func readStatus() {
        guard let queries else { return }
        statusToken += 1
        let token = statusToken
        Task {
            guard let changes = try? await queries.hasChanges(), token == self.statusToken,
                  self.queries?.root == queries.root else { return }
            if changes != uncommitted { uncommitted = changes }
        }
    }

    private func read(fresh: Bool, more: Bool = false) async {
        guard let queries else { return }
        token += 1
        let token = token
        if commits.isEmpty, phase != .loaded { phase = .loading }
        let scope = scope, search = search, author = author, wanted = wanted
        let base = fresh ? nil : pages, knownRefs = refs, knownHead = head
        let result = await Self.load(queries, scope: scope, search: search, author: author, base: base,
                                     refs: knownRefs, head: knownHead, wanted: wanted, checkRefs: !more)
        guard token == self.token else { return }
        task = nil
        loadingMore = false
        switch result {
        case .success(let read):
            refs = read.refs
            head = read.head
            pages = read.pages
            let merged = GitRefs.merge(read.pages.commits, refs: read.refs)
            if merged != commits { commits = merged }
            exhausted = read.pages.exhausted
            stale = nil
            phase = .loaded
            if read.moved {
                // A commit, checkout or fetch: the chips of the commits opened may have changed too.
                for (hash, detail) in details {
                    if case .loaded(let loaded) = detail { details[hash] = .loaded(GitRefs.merge(loaded, refs: read.refs)) }
                }
            }
        case .failure(.cancelled):
            // Replaced or given up: what shows stays as it was.
            if phase == .loading, commits.isEmpty { phase = .idle }
        case .failure(let error):
            if commits.isEmpty { phase = .failed(error.message) } else { stale = error.message }
        }
    }

    private struct Read: Sendable {
        var pages: GitLogPages
        var refs: [GitRefRecord]
        var head: String?
        var moved: Bool
    }

    private nonisolated static func load(_ queries: CommitsQueries, scope: GitLogScope, search: String, author: String?,
                                         base: GitLogPages?, refs: [GitRefRecord], head: String?, wanted: Int,
                                         checkRefs: Bool) async -> Result<Read, CommitsError> {
        do throws(CommitsError) {
            async let refsRead = checkRefs ? attempt { () throws(CommitsError) in try await queries.refs() } : .success(refs)
            async let headRead = checkRefs ? attempt { () throws(CommitsError) in try await queries.head() } : .success(head)
            let current = try await refsRead.get(), tip = try await headRead.get()
            let moved = current != refs || tip != head
            var pages: GitLogPages
            if let base, !moved {
                pages = base
            } else {
                pages = GitLogPages(scope: scope, filter: author == nil ? search : "", tip: tip)
                if let author { pages.queries = [GitLogPages.Query(match: .author(author))] }
            }
            let loaded = base?.queries.map(\.commits.count).max() ?? 0
            try await pages.fill(max(wanted, loaded), page: CommitsQueries.page) { (match, skip, count, tip) throws(CommitsError) in
                try await queries.log(scope: scope, match: match, skip: skip, count: count, tip: tip)
            }
            return .success(Read(pages: pages, refs: current, head: tip, moved: moved))
        } catch {
            return .failure(error)
        }
    }

    private nonisolated static func attempt<T: Sendable>(_ read: @Sendable () async throws(CommitsError) -> T) async
        -> Result<T, CommitsError> {
        do throws(CommitsError) { return .success(try await read()) } catch { return .failure(error) }
    }

    // MARK: A commit

    /// The commit as the log has it (with its raw headers), else as its detail read it.
    func commit(_ hash: String) -> GitCommit? {
        let row = commits.first { $0.hash.hasPrefix(hash) }
        guard case .loaded(let detail)? = details[row?.hash ?? hash] ?? details.first(where: { $0.key.hasPrefix(hash) })?.value
        else { return row }
        var commit = detail.commit
        if let row {
            commit.refs = row.refs
            commit.signature = commit.signature ?? row.signature
            commit.zone = commit.zone ?? row.zone
            commit.committer = commit.committer ?? row.committer
        }
        return commit
    }

    func detail(_ hash: String) -> Detail? {
        details[hash] ?? details.first(where: { $0.key.hasPrefix(hash) })?.value
    }

    /// Reads the commit's files (once, again after a failure) and checks a signed commit's signature.
    func open(_ hash: String) async {
        guard let queries else { return }
        if case .loaded(let detail)? = detail(hash) {
            touchDetail(detail.commit.hash)
            return verify(detail.commit)
        }
        if case .loading? = details[hash] { return }
        details[hash] = .loading
        do throws(CommitsError) {
            let detail = GitRefs.merge(try await queries.commit(hash), refs: refs)
            keep(detail, asked: hash)
            verify(detail.commit)
        } catch .cancelled {
            details[hash] = nil
        } catch {
            details[hash] = .failed(error.message)
        }
    }

    private func keep(_ detail: GitCommitDetail, asked hash: String) {
        details[hash] = .loaded(detail)
        if detail.commit.hash != hash { details[detail.commit.hash] = .loaded(detail) }
        touchDetail(detail.commit.hash)
        touchDetail(hash)
        while detailOrder.count > Self.keptDetails {
            let oldest = detailOrder.removeFirst()
            details[oldest] = nil
        }
    }

    private func touchDetail(_ hash: String) {
        detailOrder.removeAll { $0 == hash }
        detailOrder.append(hash)
    }

    /// A signed commit's verdict, read beside its files: gpg can take a moment. No answer is kept as unchecked, with
    /// `unanswered` marking it for `checkAgain`.
    private func verify(_ commit: GitCommit) {
        guard let kind = commit.signature, checks[commit.hash] == nil, !verifying.contains(commit.hash), let queries else { return }
        verifying.insert(commit.hash)
        Task {
            let check = await queries.verify(commit.hash)
            verifying.remove(commit.hash)
            if let check {
                unanswered.remove(commit.hash)
                checks[commit.hash] = check
            } else {
                unanswered.insert(commit.hash)
                checks[commit.hash] = GitSignatureCheck(verdict: .unchecked("\(queries.host) did not answer"), kind: kind)
            }
        }
    }

    /// Checks a signature that got no answer again.
    func checkAgain(_ hash: String) {
        guard unanswered.contains(hash), let commit = commit(hash) else { return }
        unanswered.remove(commit.hash)
        checks[commit.hash] = nil
        verify(commit)
    }

    static func textKey(_ hash: String, _ path: String, source: Bool) -> String { "\(source ? "s" : "d"):\(hash):\(path)" }

    func text(_ hash: String, path: String, source: Bool) -> Text? { texts[Self.textKey(hash, path, source: source)] }

    /// Reads a file's diff in the commit, or (`source`) the file as the commit left it. The texts kept are bounded
    /// (`keptTextBytes`), the oldest read going first.
    func read(_ commit: GitCommit, path: String, oldPath: String?, source: Bool) async {
        guard let queries else { return }
        let key = Self.textKey(commit.hash, path, source: source)
        switch texts[key] {
        case .loading?: return
        case .diff?, .source?:
            textOrder.removeAll { $0 == key }
            textOrder.append(key)
            return
        case .failed?, nil: break
        }
        texts[key] = .loading
        do throws(CommitsError) {
            texts[key] = source ? .source(try await queries.source(commit, path: path, oldPath: oldPath))
                                : .diff(try await queries.diff(commit, path: path, oldPath: oldPath))
            textOrder.removeAll { $0 == key }
            textOrder.append(key)
            trimTexts(keeping: key)
        } catch .cancelled {
            texts[key] = nil
        } catch {
            texts[key] = .failed(error.message)
        }
    }

    private func trimTexts(keeping key: String) {
        func size(_ text: Text?) -> Int {
            switch text {
            case .diff(let diff)?: diff.text.utf8.count
            case .source(let source)?: source.utf8.count
            default: 0
            }
        }
        var total = textOrder.reduce(0) { $0 + size(texts[$1]) }
        while total > Self.keptTextBytes, let oldest = textOrder.first, oldest != key {
            total -= size(texts[oldest])
            texts[oldest] = nil
            textOrder.removeFirst()
        }
    }

    /// Copy patch: the commit's patch as its files are listed, onto the pasteboard by `copy`.
    func copyPatch(_ hash: String, copy: (String) -> Void) async -> Patch {
        guard let queries, let commit = commit(hash) else { return .failed("The commit is not read yet") }
        do throws(CommitsError) {
            let (text, truncated) = try await queries.patch(commit)
            copy(text)
            return truncated ? .cut(bytes: text.utf8.count) : .copied
        } catch .cancelled {
            return .failed("Cancelled")
        } catch {
            return .failed(error.message)
        }
    }
}

/// The graph of the shown rows, laid out again only when they (each commit and its parents, in order), HEAD, the
/// uncommitted row or the room change.
@MainActor final class CommitsGraphCache {
    private struct Key: Equatable {
        var rows: Int
        var count: Int
        var head: String?
        var uncommitted: Bool
        var linked: Bool
        var maxLanes: Int
    }

    private var key: Key?
    private var value = GitGraph.empty

    static func fingerprint(_ commits: [GitCommit]) -> Int {
        var hasher = Hasher()
        for commit in commits {
            hasher.combine(commit.hash)
            hasher.combine(commit.parents)
        }
        return hasher.finalize()
    }

    func graph(_ commits: [GitCommit], head: String?, uncommitted: Bool, linked: Bool, maxLanes: Int) -> GitGraph {
        let key = Key(rows: Self.fingerprint(commits), count: commits.count, head: head, uncommitted: uncommitted,
                      linked: linked, maxLanes: maxLanes)
        if key != self.key {
            self.key = key
            value = GitGraph.layout(commits, head: head, uncommitted: uncommitted, linked: linked, maxLanes: maxLanes)
        }
        return value
    }
}

/// Every tab's Commits mode state, by host and tab key, so the list and the commits pushed from it share one log. The
/// last `limit` tabs used are kept; one let go while a screen still holds it comes back when its tab asks again.
@MainActor final class MobileCommits {
    struct Key: Hashable {
        let host: UUID
        let tab: String
    }

    private struct Held {
        weak var log: CommitsLog?
    }

    /// The tab's repository to read, nil while there is none to read (no helper with `git.read`, no repository yet).
    var queries: @MainActor (TabRef) -> CommitsQueries? = { _ in nil }
    let limit: Int
    private var logs: [Key: CommitsLog] = [:]
    private var used: [Key] = []
    private var released: [Key: Held] = [:]

    init(limit: Int = 8) { self.limit = limit }

    func log(_ tab: TabRef) -> CommitsLog {
        let key = Key(host: tab.host, tab: tab.key)
        used.removeAll { $0 == key }
        used.append(key)
        if let log = logs[key] { return log }
        let log = released.removeValue(forKey: key)?.log ?? CommitsLog()
        logs[key] = log
        while used.count > limit {
            let oldest = used.removeFirst()
            if let log = logs.removeValue(forKey: oldest) { released[oldest] = Held(log: log) }
        }
        released = released.filter { $0.value.log != nil }
        return log
    }
}
