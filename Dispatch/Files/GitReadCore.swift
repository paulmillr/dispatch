import Foundation

/// The bytes of an untracked file, interpreted identically on both clients. Reads and their bounds belong to the
/// adapters; a cut text file contributes only whole lines, and git's binary probe examines the first 8,000 bytes.
enum GitContent {
    static let binaryProbe = 8_000

    static func isBinary(_ data: Data) -> Bool { data.prefix(binaryProbe).contains(0) }

    static func lineCount(_ data: Data) -> Int {
        let newlines = data.reduce(0) { $1 == 0x0a ? $0 + 1 : $0 }
        return newlines + (data.last.map { $0 == 0x0a ? 0 : 1 } ?? 0)
    }

    static func wholeLines(_ data: Data) -> Data {
        guard let last = data.lastIndex(of: 0x0a) else { return Data() }
        return data[...last]
    }

    static func untracked(path: String, data: Data, size: UInt64) -> GitDiff {
        if isBinary(data) { return GitDiff(path: path, text: "", binary: true, oldSize: nil, newSize: size) }
        let truncated = UInt64(data.count) < size
        let content = String(decoding: truncated ? wholeLines(data) : data, as: UTF8.self)
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let endsInNewline = lines.last == ""
        if endsInNewline { lines.removeLast() }
        var text = "diff --git a/\(path) b/\(path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(path)\n"
        if !lines.isEmpty {
            text += "@@ -0,0 +1\(lines.count == 1 ? "" : ",\(lines.count)") @@\n"
            text += lines.map { "+" + $0 + "\n" }.joined()
            if !endsInNewline, !truncated { text += "\\ No newline at end of file\n" }
        }
        return GitDiff(path: path, text: text, oldSize: nil, newSize: size, truncated: truncated)
    }
}

/// Whether the working tree is the new side the review is displaying. A staged file changed again belongs to the
/// index: its Source and gaps must use the staged patch, since a working-tree read would quote different lines.
enum ReviewSourcePolicy {
    static func readsWorkingTree(_ change: GitChange, areas: Set<GitChangeArea>) -> Bool {
        change.kind != .deleted && !(change.area == .staged && areas.contains(.unstaged))
    }

    static func readsWorkingTree(_ change: GitChange, changes: [GitChange]) -> Bool {
        readsWorkingTree(change, areas: Set(changes.filter { $0.path == change.path }.map(\.area)))
    }
}

/// Fold read results only into paths status actually lists; numstat can also report files that are merely stat-dirty.
/// The clients retain their own cache invalidation and read budgets.
enum GitStatusEnrichment {
    struct Untracked {
        var lines: Int?
        var binary: Bool
        var size: UInt64?
    }

    static func counts(_ changes: [GitChange], unstaged: [GitNumstat], staged: [GitNumstat],
                       untracked: (String) -> Untracked?) -> [GitChange] {
        var counts = [GitChangeArea.unstaged: [String: GitNumstat](), .staged: [:]]
        for count in unstaged { counts[.unstaged]?[count.path] = count }
        for count in staged { counts[.staged]?[count.path] = count }
        return changes.map { change in
            var change = change
            if change.area == .untracked {
                guard let counted = untracked(change.path) else { return change }
                change.additions = counted.lines
                change.deletions = counted.lines.map { _ in 0 }
                change.binary = counted.binary
                if counted.binary { change.newSize = counted.size }
            } else if let count = counts[change.area]?[change.path] {
                change.additions = count.additions
                change.deletions = count.deletions
                change.binary = count.binary
            }
            return change
        }
    }
}

/// Commit reads share commands, parsing and concurrency, while each adapter retains its transport and typed errors.
/// A Result executor also preserves the error type across child tasks (`async let` otherwise erases typed throws).
struct GitCommitReads<Failure: Error & Sendable>: Sendable {
    var execute: @Sendable ([String], UInt64) async -> Result<GitOutput, Failure>
    var failed: @Sendable (String) -> Failure
    var failedMessage: @Sendable (Failure) -> String?

    func output(_ args: [String], limit: UInt64 = 0) async throws(Failure) -> GitOutput {
        try await execute(args, limit).get()
    }

    func checked(_ hash: String) throws(Failure) -> String {
        guard let checked = GitCommands.checked(hash) else { throw failed("\(hash) is not a commit hash") }
        return checked
    }

    func log(scope: GitLogScope, match: GitLogMatch, skip: Int, count: Int, tip: String?,
             tagged: Bool = false) async throws(Failure) -> GitLogPage {
        let tip = try scope == .branch ? tip.map(checked) : nil
        let args = GitCommands.log(scope: scope, match: match, skip: skip, count: count, tip: tip, tagged: tagged)
        async let raw = execute(GitCommands.raw(args), 0)
        let result = await execute(args, 0)
        if case .failure(let error) = result, let message = failedMessage(error),
           message.contains("does not have any commits") || message.contains("bad default revision") {
            return GitLogPage(commits: [], exhausted: true)
        }
        let output = try result.get()
        var commits = GitParsers.log(output.output)
        if case .success(let raw) = await raw { Self.fold(GitParsers.rawHeaders(raw.output), into: &commits) }
        return GitLogPage(commits: commits, exhausted: output.truncated ? commits.isEmpty : commits.count < count)
    }

    static func fold(_ headers: [String: GitRawHeaders], into commits: inout [GitCommit]) {
        for index in commits.indices {
            guard let read = headers[commits[index].hash] else { continue }
            commits[index].signature = read.signature
            commits[index].zone = read.author?.zone
            commits[index].committer = read.committer
        }
    }

    func refs() async throws(Failure) -> [GitRefRecord] {
        GitParsers.refs(try await output(GitCommands.refs).output)
    }

    func head() async throws(Failure) -> String? {
        let result = await execute(GitCommands.head, 0)
        if case .failure(let error) = result, failedMessage(error) != nil { return nil }
        let hash = try result.get().output.trimmingCharacters(in: .whitespacesAndNewlines)
        return GitParsers.isObjectName(hash) ? hash : nil
    }

    /// The desktop requires the name-status read; the phone tolerates its failure and enriches with raw headers.
    /// These are adapter policies, independent of parsing and first-parent merge semantics.
    func commit(_ hash: String, requireLetters: Bool, rawHeaders: Bool) async throws(Failure) -> GitCommitDetail {
        let hash = try checked(hash)
        async let letters = execute(GitCommands.show(hash, numstat: false), 0)
        async let raw: Result<GitOutput, Failure>? = rawHeaders ? await execute(["log", "-n", "1", "--pretty=raw", hash], 0) : nil
        let output = try await output(GitCommands.show(hash, numstat: true)).output
        guard var detail = GitParsers.commitDetail(output) else { throw failed("git described no commit \(hash)") }
        let named: [GitNameStatus]
        if let parent = detail.commit.parents.first, detail.commit.parents.count > 1 {
            named = GitParsers.nameStatus(try await self.output(GitCommands.mergeLetters(parent: try checked(parent), hash: hash)).output)
        } else {
            let result = await letters
            if requireLetters { named = GitParsers.commitNameStatus(try result.get().output) }
            else if case .success(let output) = result { named = GitParsers.commitNameStatus(output.output) }
            else { named = [] }
        }
        detail = GitParsers.commitDetail(output, letters: named) ?? detail
        if case .success(let raw)? = await raw {
            var commits = [detail.commit]
            Self.fold(GitParsers.rawHeaders(raw.output), into: &commits)
            detail.commit = commits[0]
        }
        return detail
    }

    func diff(_ commit: GitCommit, path: String, oldPath: String?) async throws(Failure) -> GitDiff {
        guard GitChange.representable(path), oldPath.map(GitChange.representable) ?? true else {
            throw failed(GitChange.unrepresentable)
        }
        let hash = try checked(commit.hash)
        let parent = try commit.parents.count > 1 ? checked(commit.parents[0]) : nil
        let (args, stat) = GitCommands.fileDiff(hash, mergeParent: parent, paths: GitCommands.paths(path, old: oldPath))
        let output = try await output(args)
        var diff = GitParsers.diffs(output.output, truncated: output.truncated).last
            ?? GitDiff(path: path, oldPath: oldPath, text: "", truncated: output.truncated)
        if diff.binary, case .success(let sizes) = await execute(stat, 0), let read = GitParsers.binarySizes(sizes.output) {
            diff.oldSize = read.old
            diff.newSize = read.new
        }
        return diff
    }

    func source(_ commit: GitCommit, path: String, oldPath: String?, limit: UInt64,
                tooLarge: String) async throws(Failure) -> String {
        guard GitChange.representable(path), oldPath.map(GitChange.representable) ?? true else {
            throw failed(GitChange.unrepresentable)
        }
        let hash = try checked(commit.hash)
        let parent = try commit.parents.count > 1 ? checked(commit.parents[0]) : nil
        let args = GitCommands.fileSource(hash, mergeParent: parent, paths: GitCommands.paths(path, old: oldPath), limit: limit)
        let output = try await output(args, limit: limit * 2)
        if output.truncated { throw failed(tooLarge) }
        guard let text = GitParsers.newSide(output.output) else { throw failed("git shows no lines of this file in the commit") }
        return text
    }
}
