import Foundation

/// Why a git query gave no model.
enum GitError: Error, Hashable, Sendable {
    /// The folder is outside any work tree (git's "not a git repository", or inside `.git` itself).
    case notRepository
    /// git ran and failed: its own words.
    case failed(String)
    /// git cannot run there: it is not installed on the host, or the connection's grant leaves git out.
    case unavailable(String)
    /// The source failed before git answered (offline, cancelled, a refused request).
    case source(FilesSourceError)

    var message: String {
        switch self {
        case .notRepository: "Not a repository"
        case .failed(let message), .unavailable(let message): message
        case .source(let error): error.message
        }
    }
}

/// Which commits a log page holds. A filter runs twice, once against messages and once against authors, and the
/// two are merged by hash (`GitLogPages`).
enum GitLogMatch: Hashable, Sendable {
    case everything
    case message(String)
    case author(String)
}

/// An untracked file counted for the Changes list: its lines (nil for a binary or a file past the read's limit), what
/// the count read, and the file's size and modification time as read.
struct GitLineCount: Hashable, Sendable {
    var lines: Int?
    var binary: Bool
    var read: Int
    var size: UInt64
    var modified: Date?
}

/// One page of the log and whether git had more to give.
struct GitLogPage: Hashable, Sendable {
    var commits: [GitCommit]
    /// The page came back shorter than asked (not because the bound cut it): nothing follows.
    var exhausted: Bool
}

/// The read-only git commands behind the Changes and Commits tabs and the Files list's marks, over
/// `FilesSource.git`. The argument lists here are exactly what the helper's `files.git` allows;
/// git runs in the repository's top folder, so every path is repository-relative.
struct GitQueries: Sendable {
    let source: any FilesSource
    /// The repository's top folder as the source names it.
    let root: String

    /// The log record: hash, parents, author, email, author date (unix), decorations, subject, body, then NUL
    /// (`GitParsers.record`).
    static let format = "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s%x1f%b%x00"
    /// `%(*objectname)` is the commit an annotated tag peels to (empty for every other ref), which is what the log lists.
    static let refsFormat = "--format=%(refname)%09%(objectname)%09%(HEAD)%09%(*objectname)"
    /// What an untracked file is read up to for its diff.
    static let readBound: UInt64 = 2 << 20
    /// The output bound of the status and its counts: the helper's cap (2 MiB is its default), so a large work tree
    /// is cut as late as the helper allows, and `GitStatus.truncated` says when it still was.
    static let statusLimit: UInt64 = 8 << 20
    /// How many folders above a symlinked one are asked which repository holds them (`repository(of:)`).
    static let linkDepth = 16
    /// git's own binary test: a NUL in the first 8,000 bytes.
    static let binaryProbe = 8_000

    // MARK: Repository

    /// The repository enclosing `folder`, nil outside any. Its root is named through the same symlinks as `folder`
    /// where git's answer is the resolved path (`/tmp/x` in a repository git calls `/private/tmp/x`, or `~/api`, a link
    /// to `/Volumes/data/api`), so the Files list's paths and the git tabs' agree and the marks land.
    static func repository(of folder: String, source: any FilesSource) async throws(GitError) -> GitRepository? {
        do throws(GitError) {
            let top = try await toplevel(of: folder, source: source)
            if let shown = shownRoot(top, for: folder) { return GitRepository(root: shown) }
            return GitRepository(root: try await linkedRoot(top, for: folder, source: source))
        } catch .notRepository {
            return nil
        }
    }

    private static func toplevel(of folder: String, source: any FilesSource) async throws(GitError) -> String {
        let output = try await GitQueries(source: source, root: folder).run(["rev-parse", "--show-toplevel"])
        let top = output.trimmingCharacters(in: .newlines)
        guard top.hasPrefix("/") else { throw GitError.failed("git named no repository for \(folder)") }
        return top
    }

    /// `top` as `folder` names it: itself when `folder` is inside it, else the ancestor of `folder` with the same last
    /// component (the symlinked spelling of the same folder); nil when no name matches (a link with a name of its own).
    static func shownRoot(_ top: String, for folder: String) -> String? {
        if FilesLoader.path(folder, isInside: top) { return top }
        let name = (top as NSString).lastPathComponent
        var candidate = folder
        while candidate.count > 1 {
            if (candidate as NSString).lastPathComponent == name { return candidate }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// The root of a repository reached through a link named otherwise (`~/proj` → `/Volumes/data/api`): the highest
    /// of `folder` and its parents, as they are spelled, that git still places in `top`. Most often that is `folder`
    /// itself, after one question about its parent.
    private static func linkedRoot(_ top: String, for folder: String, source: any FilesSource) async throws(GitError) -> String {
        var shown = folder
        for _ in 0..<linkDepth {
            let parent = (shown as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != shown else { break }
            do throws(GitError) {
                guard try await toplevel(of: parent, source: source) == top else { break }
            } catch .notRepository {
                break
            } catch .failed {
                break
            }
            shown = parent
        }
        return shown
    }

    // MARK: Changes

    func status() async throws(GitError) -> GitPorcelain {
        let output = try await output(["status", "--porcelain=v2", "--branch", "-z", "--ignored", "--untracked-files=normal"],
                                      limit: Self.statusLimit)
        var porcelain = GitParsers.porcelain(output.output)
        porcelain.truncated = output.truncated
        return porcelain
    }

    /// Per-file counts: the work tree against the index, or (`cached`) the index against HEAD.
    func numstat(cached: Bool) async throws(GitError) -> [GitNumstat] {
        GitParsers.numstat(try await run(["diff"] + (cached ? ["--cached"] : []) + ["--numstat", "-z"], limit: Self.statusLimit))
    }

    /// The change's diff. A staged or unstaged one is git's (`diff [--cached] -U3 -- path`, both paths for a rename so
    /// git pairs them); an untracked file has nothing to diff against, so its text is read and shown as additions.
    func diff(_ change: GitChange) async throws(GitError) -> GitDiff {
        guard change.representable else { throw GitError.failed(GitChange.unrepresentable) }
        if change.area == .untracked { return try await untracked(change.path) }
        let cached = change.area == .staged ? ["--cached"] : []
        let output = try await output(["diff"] + cached + ["-U3", "--"] + Self.paths(change.path, old: change.oldPath))
        var diff = GitParsers.diffs(output.output, truncated: output.truncated).last
            ?? GitDiff(path: change.path, oldPath: change.oldPath, text: "", truncated: output.truncated)
        if diff.binary, let sizes = try? await sizes(change) {
            diff.oldSize = sizes.old
            diff.newSize = sizes.new
        }
        return diff
    }

    /// A staged or unstaged binary's sizes on each side (`diff [--cached] --stat -- path`, the only place git prints
    /// them); nil when git printed none.
    func sizes(_ change: GitChange) async throws(GitError) -> (old: UInt64, new: UInt64)? {
        guard change.representable else { throw GitError.failed(GitChange.unrepresentable) }
        let cached = change.area == .staged ? ["--cached"] : []
        return try await stat(["diff"] + cached + ["--stat", "--"] + Self.paths(change.path, old: change.oldPath))
    }

    /// An untracked file as a diff from nothing: a hunk adding every line, or a binary with its size.
    func untracked(_ path: String) async throws(GitError) -> GitDiff {
        if path.hasSuffix("/") {
            throw GitError.failed("\(path.dropLast()) is a folder git does not track yet: its files show in the Files tab")
        }
        let (data, revision) = try await read(path, length: Self.readBound)
        let size = revision.size
        if Self.isBinary(data) {
            return GitDiff(path: path, text: "", binary: true, oldSize: nil, newSize: size)
        }
        let truncated = UInt64(data.count) < size
        var text = String(decoding: truncated ? Self.wholeLines(data) : data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let endsInNewline = lines.last == ""
        if endsInNewline { lines.removeLast() }
        text = "diff --git a/\(path) b/\(path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(path)\n"
        if !lines.isEmpty {
            text += "@@ -0,0 +1\(lines.count == 1 ? "" : ",\(lines.count)") @@\n"
            text += lines.map { "+" + $0 + "\n" }.joined()
            if !endsInNewline, !truncated { text += "\\ No newline at end of file\n" }
        }
        return GitDiff(path: path, text: text, oldSize: nil, newSize: size, truncated: truncated)
    }

    /// An untracked file's line count (its additions in the Changes list), reading at most `limit` bytes: no lines for
    /// a binary or for a file longer than that.
    func untrackedLines(_ path: String, limit: UInt64) async throws(GitError) -> GitLineCount {
        let (data, revision) = try await read(path, length: limit)
        var count = GitLineCount(lines: nil, binary: Self.isBinary(data), read: data.count, size: revision.size,
                                 modified: revision.modified)
        if !count.binary, UInt64(data.count) >= revision.size { count.lines = Self.lineCount(data) }
        return count
    }

    // MARK: Commits

    /// A page of the log, newest first: this branch (from `tip`, else HEAD) or every ref, optionally only the commits
    /// whose message or author holds `match` (literally, ignoring case).
    func log(scope: GitLogScope, match: GitLogMatch = .everything, skip: Int, count: Int,
             from tip: String? = nil) async throws(GitError) -> GitLogPage {
        var args = ["log", "-n", String(count), "--skip=\(skip)", Self.format, "--date=unix"]
        if scope == .all { args.append("--all") }
        switch match {
        case .everything: break
        case .message(let text): args += ["--grep=\(text)", "--regexp-ignore-case", "--fixed-strings"]
        case .author(let text): args += ["--author=\(text)", "--regexp-ignore-case", "--fixed-strings"]
        }
        if scope == .branch, let tip { args.append(try Self.checked(tip)) }
        // Which of them are signed: the same range in the raw format, whose headers name a signature without checking
        // it, read beside the page. A page without it shows no seals rather than failing.
        let rawArgs = args.map { $0 == Self.format ? "--pretty=raw" : $0 }.filter { $0 != "--date=unix" }
        async let raw = try? self.output(rawArgs)
        let output: GitOutput
        do throws(GitError) {
            output = try await self.output(args)
        } catch .failed(let message) where message.contains("does not have any commits") || message.contains("bad default revision") {
            // A repository before its first commit has an empty log.
            return GitLogPage(commits: [], exhausted: true)
        }
        var commits = GitParsers.log(output.output)
        if let raw = await raw {
            let signed = GitParsers.signatures(raw.output)
            for index in commits.indices { commits[index].signature = signed[commits[index].hash] }
        }
        // A page the bound cut is short without being the end; one the bound cut to nothing can never advance.
        return GitLogPage(commits: commits, exhausted: output.truncated ? commits.isEmpty : commits.count < count)
    }

    /// The commit's signature checked with the user's own keys and allowed signers (`verify-commit --raw`, with the
    /// programs the helper trusts). Nil when the source did not answer.
    func verify(_ hash: String) async -> GitSignatureCheck? {
        guard let hash = try? Self.checked(hash),
              let output = try? await source.git(root, args: ["verify-commit", "--raw", hash], limit: 0) else { return nil }
        return GitParsers.signatureCheck(output.output, status: output.status)
    }

    /// HEAD's commit (`rev-parse --verify HEAD`), nil before the first commit. With the refs it tells a moved HEAD,
    /// detached or not, from one that stayed.
    func head() async throws(GitError) -> String? {
        do throws(GitError) {
            let hash = try await run(["rev-parse", "--verify", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            return GitParsers.isObjectName(hash) ? hash : nil
        } catch .failed {
            // "Needed a single revision": nothing is committed yet.
            return nil
        }
    }

    func refs() async throws(GitError) -> [GitRefRecord] {
        GitParsers.refs(try await run(["for-each-ref", Self.refsFormat, "refs/heads", "refs/remotes", "refs/tags"]))
    }

    /// The commit, its files' counts and their letters (A, D, M, R, C, T). git prints `--numstat` or `--name-status`,
    /// never both, so the two run side by side. A merge's letters come from `diff` against its first parent, which is
    /// what its counts describe: `show` names only the files a merge changed against every parent.
    func commit(_ hash: String) async throws(GitError) -> GitCommitDetail {
        let hash = try Self.checked(hash)
        async let shown = result(["show", "--name-status", "-z", Self.format, hash])
        let output = try await run(["show", "--numstat", "-z", Self.format, hash])
        guard let counted = GitParsers.commitDetail(output) else { throw GitError.failed("git described no commit \(hash)") }
        let letters: [GitNameStatus]
        if let parent = counted.commit.parents.first, counted.commit.parents.count > 1 {
            letters = GitParsers.nameStatus(try await run(["diff", "--name-status", "-z", try Self.checked(parent), hash]))
        } else {
            letters = GitParsers.commitNameStatus(try await shown.get())
        }
        return GitParsers.commitDetail(output, letters: letters) ?? counted
    }

    /// One file's diff in a commit (`show --format= -U3 <hash> -- path`). A merge's is against its first parent
    /// (`diff -U3 <parent> <hash> -- path`), which is what its file counts describe: `show` prints a merge's combined
    /// diff only for files both sides changed.
    func commitDiff(_ commit: GitCommit, path: String, oldPath: String?) async throws(GitError) -> GitDiff {
        guard GitChange.representable(path), oldPath.map(GitChange.representable) ?? true else {
            throw GitError.failed(GitChange.unrepresentable)
        }
        let hash = try Self.checked(commit.hash)
        let paths = Self.paths(path, old: oldPath)
        let args: [String], stat: [String]
        if commit.parents.count > 1 {
            let parent = try Self.checked(commit.parents[0])
            args = ["diff", "-U3", parent, hash, "--"] + paths
            stat = ["diff", "--stat", parent, hash, "--"] + paths
        } else {
            args = ["show", "--format=", "-U3", hash, "--"] + paths
            stat = ["show", "--stat", "--format=", hash, "--"] + paths
        }
        let output = try await output(args)
        var diff = GitParsers.diffs(output.output, truncated: output.truncated).last
            ?? GitDiff(path: path, oldPath: oldPath, text: "", truncated: output.truncated)
        if diff.binary, let sizes = try? await self.stat(stat) {
            diff.oldSize = sizes.old
            diff.newSize = sizes.new
        }
        return diff
    }

    /// The file as `commit` left it, for the Commits tab's Source: `files.git` reads no `<rev>:<path>`, so this is the
    /// commit's diff of the file with the whole file as context (one hunk), its new side. Over `sourceLimit`, a binary
    /// file or a commit that changed only the file's mode answers why instead.
    func commitSource(_ commit: GitCommit, path: String, oldPath: String?) async throws(GitError) -> String {
        guard GitChange.representable(path), oldPath.map(GitChange.representable) ?? true else {
            throw GitError.failed(GitChange.unrepresentable)
        }
        let hash = try Self.checked(commit.hash)
        let paths = Self.paths(path, old: oldPath)
        // More context than a file within the limit has lines: the patch is one hunk holding all of it.
        let whole = "-U\(GitChangesText.sourceLimit)"
        let args = commit.parents.count > 1
            ? ["diff", whole, try Self.checked(commit.parents[0]), hash, "--"] + paths
            : ["show", "--format=", whole, hash, "--"] + paths
        let output = try await output(args, limit: GitChangesText.sourceLimit * 2)
        if output.truncated { throw GitError.failed("Over 2 MB · the terminal shows the rest") }
        guard let text = GitParsers.newSide(output.output) else {
            throw GitError.failed("git shows no lines of this file in the commit")
        }
        return text
    }

    // MARK: Running

    /// stdout of a command that succeeded.
    func run(_ args: [String], limit: UInt64 = 0) async throws(GitError) -> String {
        try await output(args, limit: limit).output
    }

    /// `run` with its failure as a value, for an `async let` (whose errors are untyped).
    private func result(_ args: [String]) async -> Result<String, GitError> {
        do throws(GitError) { return .success(try await run(args)) } catch { return .failure(error) }
    }

    func output(_ args: [String], limit: UInt64 = 0) async throws(GitError) -> GitOutput {
        let output: GitOutput
        do {
            output = try await source.git(root, args: args, limit: limit)
        } catch {
            throw Self.failure(error, source: source, path: root)
        }
        guard output.succeeded else {
            let words = output.output.trimmingCharacters(in: .whitespacesAndNewlines)
            // -1: the helper stopped git at its deadline (or a signal did). That says nothing about the repository, so
            // it is not git's answer: the caller keeps what it showed and asks again.
            if output.status < 0 {
                throw GitError.source(.other(code: "deadline", message: words.isEmpty ? "git did not finish" : words))
            }
            if words.contains("not a git repository") || words.contains("must be run in a work tree") {
                throw GitError.notRepository
            }
            throw GitError.failed(words.isEmpty ? "git \(args.first ?? "") failed (\(output.status))" : words)
        }
        return output
    }

    /// The helper's refusals as the git tabs word them: a host without git, or a grant without it, is unavailable.
    static func failure(_ error: any Error, source: any FilesSource, path: String) -> GitError {
        let host = source.endpoint.isLocal ? nil : source.hostLabel ?? "the host"
        switch HelperFilesSource.map(error, path: path, host: host) {
        case .unsupported(let message): return .unavailable(message)
        case .permissionDenied:
            return .unavailable(host.map { "Git isn’t allowed on \($0): turn on Git metadata for this host" }
                ?? "Git isn’t allowed on this Mac’s helper")
        case let other: return .source(other)
        }
    }

    private func stat(_ args: [String]) async throws(GitError) -> (old: UInt64, new: UInt64)? {
        GitParsers.binarySizes(try await run(args))
    }

    private func read(_ path: String, length: UInt64) async throws(GitError) -> (Data, FileRevision) {
        let absolute = root == "/" ? "/" + path : root + "/" + path
        do {
            return try await source.read(absolute, offset: 0, length: length, revision: nil)
        } catch {
            throw .source(HelperFilesSource.map(error, path: absolute, host: source.endpoint.isLocal ? nil : source.hostLabel ?? "The host"))
        }
    }

    // MARK: Helpers

    /// Paths after `--`. One holding pathspec magic (`*`, `?`, `[`, a leading `:`) is passed literally, or git would
    /// match it as a pattern.
    static func paths(_ path: String, old: String?) -> [String] {
        (old.map { [literal($0)] } ?? []) + [literal(path)]
    }

    static func literal(_ path: String) -> String {
        path.contains(where: { "*?[\\".contains($0) }) || path.hasPrefix(":") ? ":(literal)" + path : path
    }

    /// A hash from git's own output, refused before it reaches git if it is anything else (an option, a range).
    static func checked(_ hash: String) throws(GitError) -> String {
        guard (4...64).contains(hash.utf8.count), GitParsers.isHex(hash) else { throw GitError.failed("\(hash) is not a commit hash") }
        return hash
    }

    static func isBinary(_ data: Data) -> Bool { data.prefix(binaryProbe).contains(0) }

    static func lineCount(_ data: Data) -> Int {
        let newlines = data.reduce(0) { $1 == 0x0a ? $0 + 1 : $0 }
        return newlines + (data.last.map { $0 == 0x0a ? 0 : 1 } ?? 0)
    }

    /// The data up to its last newline: a cut file shows whole lines only.
    static func wholeLines(_ data: Data) -> Data {
        guard let last = data.lastIndex(of: 0x0a) else { return Data() }
        return data[...last]
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

    /// Loads each unfinished query up to `wanted` commits, a page (`GitLoader.page`) at a time: the helper refuses
    /// more than 1,000 a call, and starting over after the refs moved may want several thousand. A page that repeats
    /// commits (`--all` while a ref moved) adds only the new ones.
    mutating func fill(_ wanted: Int, with queries: GitQueries) async throws(GitError) {
        for index in self.queries.indices {
            while !self.queries[index].exhausted, self.queries[index].commits.count < wanted {
                let query = self.queries[index]
                let page = try await queries.log(scope: scope, match: query.match, skip: query.fetched,
                                                 count: min(wanted - query.commits.count, GitLoader.page), from: tip)
                var seen = Set(query.commits.map(\.hash))
                self.queries[index].commits += page.commits.filter { seen.insert($0.hash).inserted }
                self.queries[index].fetched += page.commits.count
                self.queries[index].exhausted = page.exhausted
                if page.commits.isEmpty { break }
            }
        }
    }
}
