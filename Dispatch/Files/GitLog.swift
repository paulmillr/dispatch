import Foundation

// The Commits tab's log, shared with the iPhone app (docs/ios.md, Shared sources): the exact `files.git` argument lists
// of the log and the refs, and the pages a filter's queries load. Each app runs them through its own helper source
// (the Mac's `GitQueries`, the phone's `CommitsQueries`).

/// Which commits a log page holds. A filter runs twice, once against messages and once against authors, and the
/// two are merged by hash (`GitLogPages`).
enum GitLogMatch: Hashable, Sendable {
    case everything
    case message(String)
    case author(String)
}

/// One page of the log and whether git had more to give.
struct GitLogPage: Hashable, Sendable {
    var commits: [GitCommit]
    /// The page came back shorter than asked (not because the bound cut it): nothing follows.
    var exhausted: Bool
}

/// The argument lists of the log's commands, as the helper's `files.git` allows them.
enum GitCommands {
    /// The log record: hash, parents, author, email, author date (unix), decorations, subject, body, then NUL
    /// (`GitParsers.record`).
    static let format = "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s%x1f%b%x00"
    /// `%(*objectname)` is the commit an annotated tag peels to (empty for every other ref), which is what the log lists.
    static let refsFormat = "--format=%(refname)%09%(objectname)%09%(HEAD)%09%(*objectname)"
    /// Every branch, remote branch and tag (`GitParsers.refs`).
    static let refs = ["for-each-ref", refsFormat, "refs/heads", "refs/remotes", "refs/tags"]
    /// HEAD's commit; git fails it before the first commit.
    static let head = ["rev-parse", "--verify", "HEAD"]

    /// A page of the log, newest first: this branch (from `tip`, a hash the caller checked, else HEAD) or every ref,
    /// optionally only the commits whose message or author holds `match` (literally, ignoring case).
    static func log(scope: GitLogScope, match: GitLogMatch, skip: Int, count: Int, tip: String?) -> [String] {
        var args = ["log", "-n", String(count), "--skip=\(skip)", format, "--date=unix"]
        if scope == .all { args.append("--all") }
        switch match {
        case .everything: break
        case .message(let text): args += ["--grep=\(text)", "--regexp-ignore-case", "--fixed-strings"]
        case .author(let text): args += ["--author=\(text)", "--regexp-ignore-case", "--fixed-strings"]
        }
        if scope == .branch, let tip { args.append(tip) }
        return args
    }

    /// The commit's record and its files: their counts (`--numstat`) or their letters (`--name-status`), which git
    /// prints one at a time (`GitParsers.commitDetail`, `commitNameStatus`).
    static func show(_ hash: String, numstat: Bool) -> [String] {
        ["show", numstat ? "--numstat" : "--name-status", "-z", format, hash]
    }

    /// A merge's letters against its first parent, which is what its counts describe.
    static func mergeLetters(parent: String, hash: String) -> [String] {
        ["diff", "--name-status", "-z", parent, hash]
    }

    /// One file's diff in a commit and the stat that sizes a binary's sides: `show` for a commit with one parent, a
    /// merge's against its first parent (`mergeParent`), as its counts are.
    static func fileDiff(_ hash: String, mergeParent: String?, paths: [String]) -> (diff: [String], stat: [String]) {
        if let parent = mergeParent {
            return (["diff", "-U3", parent, hash, "--"] + paths, ["diff", "--stat", parent, hash, "--"] + paths)
        }
        return (["show", "--format=", "-U3", hash, "--"] + paths, ["show", "--stat", "--format=", hash, "--"] + paths)
    }

    /// The file's diff with more context than a file of `limit` bytes has lines: one hunk holding the whole file as the
    /// commit left it (`GitParsers.newSide`).
    static func fileSource(_ hash: String, mergeParent: String?, paths: [String], limit: UInt64) -> [String] {
        let whole = "-U\(limit)"
        if let parent = mergeParent { return ["diff", whole, parent, hash, "--"] + paths }
        return ["show", "--format=", whole, hash, "--"] + paths
    }

    /// The commit's signature checked with the user's own keys (`GitParsers.signatureCheck`).
    static func verify(_ hash: String) -> [String] { ["verify-commit", "--raw", hash] }

    /// Paths after `--`. One holding pathspec magic (`*`, `?`, `[`, a leading `:`) is passed literally, or git would
    /// match it as a pattern.
    static func paths(_ path: String, old: String?) -> [String] {
        (old.map { [literal($0)] } ?? []) + [literal(path)]
    }

    static func literal(_ path: String) -> String {
        path.contains(where: { "*?[\\".contains($0) }) || path.hasPrefix(":") ? ":(literal)" + path : path
    }

    /// A hash as git prints one (4 to 64 hex digits), nil for anything else (an option, a range), so nothing but a
    /// commit name reaches git where a commit is asked for.
    static func checked(_ hash: String) -> String? {
        (4...64).contains(hash.utf8.count) && GitParsers.isHex(hash) ? hash : nil
    }

    /// The same range as `log` in the raw format, whose headers name a signature (without checking it), the author
    /// date's offset and the committer (`GitParsers.rawHeaders`).
    static func raw(_ log: [String]) -> [String] {
        log.map { $0 == format ? "--pretty=raw" : $0 }.filter { $0 != "--date=unix" }
    }
}

/// The log as the Commits tab loads it, page by page: one query, or a filter's two (message and author) merged by
/// hash, newest first.
struct GitLogPages: Hashable, Sendable {
    struct Query: Hashable, Sendable {
        var match: GitLogMatch
        /// Each commit once.
        var commits: [GitCommit] = []
        var exhausted = false
        /// What git has printed so far, repeats included: where the next page starts.
        var fetched = 0
    }

    var scope: GitLogScope
    var filter: String
    /// The commit the branch scope pages from (HEAD when the first page was read), so a commit or checkout between
    /// two pages cannot shift the second; nil follows HEAD (nothing committed yet). The refs check notices the move
    /// and starts the pages over.
    var tip: String?
    var queries: [Query]

    init(scope: GitLogScope, filter: String, tip: String? = nil) {
        self.scope = scope
        self.filter = filter
        self.tip = tip
        let text = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        queries = text.isEmpty ? [Query(match: .everything)] : [Query(match: .message(text)), Query(match: .author(text))]
    }

    var exhausted: Bool { queries.allSatisfy(\.exhausted) }

    /// The merged commits whose order is certain: those no later page of an unfinished query could precede.
    var commits: [GitCommit] {
        if queries.count == 1 { return queries[0].commits }
        var seen = Set<String>(), merged: [GitCommit] = []
        var cursors = queries.map { $0.commits[...] }
        while true {
            var best: Int?
            for index in cursors.indices {
                guard let head = cursors[index].first else { continue }
                if let current = best, let other = cursors[current].first, other.date >= head.date { continue }
                best = index
            }
            guard let index = best, let next = cursors[index].popFirst() else { break }
            if seen.insert(next.hash).inserted { merged.append(next) }
        }
        let cutoff = queries.filter { !$0.exhausted }.compactMap { $0.commits.last?.date }.max()
        guard let cutoff else { return merged }
        return merged.filter { $0.date >= cutoff }
    }

    /// Loads each unfinished query up to `wanted` commits, `page` at a time through `read` (its match, skip, count and
    /// the tip): the helper refuses more than 1,000 a call, and starting over after the refs moved may want several
    /// thousand. A page that repeats commits (`--all` while a ref moved) adds only the new ones.
    mutating func fill<Failure: Error>(_ wanted: Int, page: Int,
                                       read: (GitLogMatch, Int, Int, String?) async throws(Failure) -> GitLogPage)
        async throws(Failure) {
        for index in queries.indices {
            while !queries[index].exhausted, queries[index].commits.count < wanted {
                let query = queries[index]
                let loaded = try await read(query.match, query.fetched, min(wanted - query.commits.count, page), tip)
                var seen = Set(query.commits.map(\.hash))
                queries[index].commits += loaded.commits.filter { seen.insert($0.hash).inserted }
                queries[index].fetched += loaded.commits.count
                queries[index].exhausted = loaded.exhausted
                if loaded.commits.isEmpty { break }
            }
        }
    }
}
