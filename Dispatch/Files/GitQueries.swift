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

/// An untracked file counted for the Changes list: its lines (nil for a binary or a file past the read's limit), what
/// the count read, and the file's size and modification time as read.
struct GitLineCount: Hashable, Sendable {
    var lines: Int?
    var binary: Bool
    var read: Int
    var size: UInt64
    var modified: Date?
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
    static let format = GitCommands.format
    /// `%(*objectname)` is the commit an annotated tag peels to (empty for every other ref), which is what the log lists.
    static let refsFormat = GitCommands.refsFormat
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
        var checkedTip: String?
        if scope == .branch, let tip { checkedTip = try Self.checked(tip) }
        let args = GitCommands.log(scope: scope, match: match, skip: skip, count: count, tip: checkedTip)
        // Which of them are signed, the author date's offset and the committer: the same range in the raw format, whose
        // headers name a signature without checking it, read beside the page. A page without it shows less rather than
        // failing.
        let rawArgs = GitCommands.raw(args)
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
            let headers = GitParsers.rawHeaders(raw.output)
            for index in commits.indices {
                guard let read = headers[commits[index].hash] else { continue }
                commits[index].signature = read.signature
                commits[index].zone = read.author?.zone
                commits[index].committer = read.committer
            }
        }
        // A page the bound cut is short without being the end; one the bound cut to nothing can never advance.
        return GitLogPage(commits: commits, exhausted: output.truncated ? commits.isEmpty : commits.count < count)
    }

    /// The commit's signature checked with the user's own keys and allowed signers (`verify-commit --raw`, with the
    /// programs the helper trusts). Nil when the source did not answer.
    func verify(_ hash: String) async -> GitSignatureCheck? {
        guard let hash = try? Self.checked(hash),
              let output = try? await source.git(root, args: GitCommands.verify(hash), limit: 0) else { return nil }
        return GitParsers.signatureCheck(output.output, status: output.status)
    }

    /// HEAD's commit (`rev-parse --verify HEAD`), nil before the first commit. With the refs it tells a moved HEAD,
    /// detached or not, from one that stayed.
    func head() async throws(GitError) -> String? {
        do throws(GitError) {
            let hash = try await run(GitCommands.head).trimmingCharacters(in: .whitespacesAndNewlines)
            return GitParsers.isObjectName(hash) ? hash : nil
        } catch .failed {
            // "Needed a single revision": nothing is committed yet.
            return nil
        }
    }

    func refs() async throws(GitError) -> [GitRefRecord] {
        GitParsers.refs(try await run(GitCommands.refs))
    }

    /// The commit, its files' counts and their letters (A, D, M, R, C, T). git prints `--numstat` or `--name-status`,
    /// never both, so the two run side by side. A merge's letters come from `diff` against its first parent, which is
    /// what its counts describe: `show` names only the files a merge changed against every parent.
    func commit(_ hash: String) async throws(GitError) -> GitCommitDetail {
        let hash = try Self.checked(hash)
        async let shown = result(GitCommands.show(hash, numstat: false))
        let output = try await run(GitCommands.show(hash, numstat: true))
        guard let counted = GitParsers.commitDetail(output) else { throw GitError.failed("git described no commit \(hash)") }
        let letters: [GitNameStatus]
        if let parent = counted.commit.parents.first, counted.commit.parents.count > 1 {
            letters = GitParsers.nameStatus(try await run(GitCommands.mergeLetters(parent: try Self.checked(parent), hash: hash)))
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
        let parent = try commit.parents.count > 1 ? Self.checked(commit.parents[0]) : nil
        let (args, stat) = GitCommands.fileDiff(hash, mergeParent: parent, paths: Self.paths(path, old: oldPath))
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
        let parent = try commit.parents.count > 1 ? Self.checked(commit.parents[0]) : nil
        let args = GitCommands.fileSource(hash, mergeParent: parent, paths: Self.paths(path, old: oldPath),
                                          limit: GitChangesText.sourceLimit)
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
    static func paths(_ path: String, old: String?) -> [String] { GitCommands.paths(path, old: old) }

    static func literal(_ path: String) -> String { GitCommands.literal(path) }

    /// A hash from git's own output, refused before it reaches git if it is anything else (an option, a range).
    static func checked(_ hash: String) throws(GitError) -> String {
        guard let hash = GitCommands.checked(hash) else { throw GitError.failed("\(hash) is not a commit hash") }
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

extension GitLogPages {
    /// `fill` through `queries`, a page (`GitLoader.page`) at a time.
    mutating func fill(_ wanted: Int, with queries: GitQueries) async throws(GitError) {
        let scope = scope
        try await fill(wanted, page: GitLoader.page) { (match, skip, count, tip) throws(GitError) in
            try await queries.log(scope: scope, match: match, skip: skip, count: count, from: tip)
        }
    }
}
