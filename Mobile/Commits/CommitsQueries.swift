import Foundation

/// What the Commits mode asks git through: `files.git` on the tab's host (`HelperCommitsGit`), or in Debug the sample's
/// repository (`CommitsFixture`). A failed command answers with its status and stderr; a refused or unanswered request
/// throws.
protocol CommitsGit: Sendable {
    /// The connection (or fixture) answering: a new one reads everything again.
    var identity: ObjectIdentifier { get }
    func git(_ path: String, args: [String], limit: UInt64) async throws -> GitOutput
}

/// `files.git` through the host's helper (the `git.read` grant: the host's Files & git switch).
struct HelperCommitsGit: CommitsGit {
    let client: HelperClient

    var identity: ObjectIdentifier { ObjectIdentifier(client) }

    private struct Run: Encodable, Sendable { let path: String; let args: [String]; let limit: UInt64 }
    private struct Answer: Decodable, Sendable { let status: Int64; let output: String; let truncated: Bool }

    func git(_ path: String, args: [String], limit: UInt64) async throws -> GitOutput {
        let answer: Answer = try await client.connection.request("files.git", params: Run(path: path, args: args, limit: limit))
        return GitOutput(status: answer.status, output: answer.output, truncated: answer.truncated)
    }
}

/// Why a Commits read gave nothing, in the words the screens show.
enum CommitsError: Error, Equatable, Sendable {
    /// git ran and failed: its own words.
    case failed(String)
    /// The helper refused (git missing, the grant without git) or is not there.
    case unavailable(String)
    /// The host did not answer: the connection dropped.
    case offline(String)
    /// The read was given up (a newer one replaced it, the view went): nothing to say.
    case cancelled

    var message: String {
        switch self {
        case .failed(let message), .unavailable(let message), .offline(let message): message
        case .cancelled: "Cancelled"
        }
    }

    /// The helper's refusals and a dropped connection, worded for `host`.
    static func from(_ error: any Error, host: String) -> CommitsError {
        if let error = error as? CommitsError { return error }
        if error is CancellationError { return .cancelled }
        guard let failure = error as? HelperFailure else { return .offline("\(host) is not connected") }
        switch failure.code {
        case "cancelled": return .cancelled
        case "permission_denied": return .unavailable("Git isn’t allowed on \(host): turn on Files & git for this host")
        case "unsupported": return .unavailable(failure.message.isEmpty ? "git can’t run on \(host)" : failure.message)
        case "unavailable", "connection_closed", "closed", "offline", "invalid_response": return .offline("\(host) is not connected")
        default: return .failed(failure.message.isEmpty ? "git failed on \(host) (\(failure.code))" : failure.message)
        }
    }
}

/// The phone's side of the Mac's `GitQueries` for the Commits mode: the same argument lists (`GitCommands`), the same
/// parsers, over `CommitsGit`. git runs in the repository's top folder, so every path is repository-relative.
struct CommitsQueries: Sendable {
    let git: any CommitsGit
    /// The repository's top folder on the host.
    let root: String
    /// The host's name, for the errors.
    let host: String

    /// A page's size, the Mac's (`GitLoader.page`); the helper refuses more than 1,000 commits a call.
    static let page = 200
    /// The Source view's bound: the whole file as the commit left it, up to 2 MB (the Mac's `sourceLimit`).
    static let sourceLimit: UInt64 = 2_000_000
    /// The uncommitted changes are only asked whether there are any: a short read is enough.
    static let statusLimit: UInt64 = 64 << 10

    func output(_ args: [String], limit: UInt64 = 0) async throws(CommitsError) -> GitOutput {
        let output: GitOutput
        do {
            output = try await git.git(root, args: args, limit: limit)
        } catch {
            throw CommitsError.from(error, host: host)
        }
        guard output.succeeded else {
            let words = output.output.trimmingCharacters(in: .whitespacesAndNewlines)
            // -1: the helper stopped git at its deadline; nothing about the repository.
            if output.status < 0 { throw CommitsError.offline(words.isEmpty ? "git did not finish on \(host)" : words) }
            throw CommitsError.failed(words.isEmpty ? "git \(args.first ?? "") failed (\(output.status))" : words)
        }
        return output
    }

    func run(_ args: [String], limit: UInt64 = 0) async throws(CommitsError) -> String {
        try await output(args, limit: limit).output
    }

    static func checked(_ hash: String) throws(CommitsError) -> String {
        guard let hash = GitCommands.checked(hash) else { throw CommitsError.failed("\(hash) is not a commit hash") }
        return hash
    }

    // MARK: The log

    /// A page of the log with what each commit's raw headers say (its signature's kind, the author's offset, the
    /// committer), read beside it; a page whose raw read fails shows less rather than failing.
    func log(scope: GitLogScope, match: GitLogMatch, skip: Int, count: Int, tip: String?) async throws(CommitsError) -> GitLogPage {
        var checkedTip: String?
        if scope == .branch, let tip { checkedTip = try Self.checked(tip) }
        let args = GitCommands.log(scope: scope, match: match, skip: skip, count: count, tip: checkedTip)
        async let raw = try? self.output(GitCommands.raw(args))
        let output: GitOutput
        do throws(CommitsError) {
            output = try await self.output(args)
        } catch .failed(let message) where message.contains("does not have any commits") || message.contains("bad default revision") {
            // A repository before its first commit has an empty log.
            return GitLogPage(commits: [], exhausted: true)
        }
        var commits = GitParsers.log(output.output)
        if let raw = await raw { Self.fold(GitParsers.rawHeaders(raw.output), into: &commits) }
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

    func refs() async throws(CommitsError) -> [GitRefRecord] {
        GitParsers.refs(try await run(GitCommands.refs))
    }

    /// HEAD's commit, nil before the first one.
    func head() async throws(CommitsError) -> String? {
        do throws(CommitsError) {
            let hash = try await run(GitCommands.head).trimmingCharacters(in: .whitespacesAndNewlines)
            return GitParsers.isObjectName(hash) ? hash : nil
        } catch .failed {
            return nil
        }
    }

    /// Whether the work tree has changes (the hollow "Uncommitted changes" row): staged, unstaged or untracked files.
    func hasChanges() async throws(CommitsError) -> Bool {
        let output = try await output(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"],
                                      limit: Self.statusLimit)
        return !GitParsers.porcelain(output.output).changes.isEmpty || output.truncated
    }

    // MARK: A commit

    /// The commit, its files' counts and letters (as the Mac's `GitQueries.commit`), and its raw headers.
    func commit(_ hash: String) async throws(CommitsError) -> GitCommitDetail {
        let hash = try Self.checked(hash)
        async let letters = try? self.run(GitCommands.show(hash, numstat: false))
        async let raw = try? self.run(["log", "-n", "1", "--pretty=raw", hash])
        let output = try await run(GitCommands.show(hash, numstat: true))
        guard var detail = GitParsers.commitDetail(output) else { throw CommitsError.failed("git described no commit \(hash)") }
        let named: [GitNameStatus]
        if let parent = detail.commit.parents.first, detail.commit.parents.count > 1 {
            named = GitParsers.nameStatus(try await run(GitCommands.mergeLetters(parent: try Self.checked(parent), hash: hash)))
        } else {
            named = (await letters).map(GitParsers.commitNameStatus) ?? []
        }
        detail = GitParsers.commitDetail(output, letters: named) ?? detail
        if let raw = await raw {
            var commits = [detail.commit]
            Self.fold(GitParsers.rawHeaders(raw), into: &commits)
            detail.commit = commits[0]
        }
        return detail
    }

    /// One file's diff in the commit (a merge's against its first parent), with a binary's sizes.
    func diff(_ commit: GitCommit, path: String, oldPath: String?) async throws(CommitsError) -> GitDiff {
        guard GitChange.representable(path), oldPath.map(GitChange.representable) ?? true else {
            throw CommitsError.failed(GitChange.unrepresentable)
        }
        let hash = try Self.checked(commit.hash)
        let parent = try commit.parents.count > 1 ? Self.checked(commit.parents[0]) : nil
        let (args, stat) = GitCommands.fileDiff(hash, mergeParent: parent, paths: GitCommands.paths(path, old: oldPath))
        let output = try await output(args)
        var diff = GitParsers.diffs(output.output, truncated: output.truncated).last
            ?? GitDiff(path: path, oldPath: oldPath, text: "", truncated: output.truncated)
        if diff.binary, let sizes = try? await run(stat), let read = GitParsers.binarySizes(sizes) {
            diff.oldSize = read.old
            diff.newSize = read.new
        }
        return diff
    }

    /// The file as the commit left it (the Source view): the commit's diff of it with the whole file as context.
    func source(_ commit: GitCommit, path: String, oldPath: String?) async throws(CommitsError) -> String {
        guard GitChange.representable(path), oldPath.map(GitChange.representable) ?? true else {
            throw CommitsError.failed(GitChange.unrepresentable)
        }
        let hash = try Self.checked(commit.hash)
        let parent = try commit.parents.count > 1 ? Self.checked(commit.parents[0]) : nil
        let args = GitCommands.fileSource(hash, mergeParent: parent, paths: GitCommands.paths(path, old: oldPath),
                                          limit: Self.sourceLimit)
        let output = try await output(args, limit: Self.sourceLimit * 2)
        if output.truncated { throw CommitsError.failed("Over 2 MB: the terminal shows the rest") }
        guard let text = GitParsers.newSide(output.output) else {
            throw CommitsError.failed("git shows no lines of this file in the commit")
        }
        return text
    }

    /// The most of a patch Copy patch reads: the helper's cap.
    static let patchLimit: UInt64 = 8 << 20

    /// The commit's whole patch (Copy patch), as its files are listed: `show --format=` for a commit with one parent, a
    /// merge's `diff` against its first parent. `truncated`: the patch is longer than `patchLimit` and this is its start.
    func patch(_ commit: GitCommit) async throws(CommitsError) -> (text: String, truncated: Bool) {
        let output = try await output(Self.patchArguments(commit), limit: Self.patchLimit)
        return (output.output, output.truncated)
    }

    static func patchArguments(_ commit: GitCommit) throws(CommitsError) -> [String] {
        let hash = try checked(commit.hash)
        if commit.parents.count > 1 { return ["diff", "-U3", try checked(commit.parents[0]), hash] }
        return ["show", "--format=", "-U3", hash]
    }

    /// The signature checked with the user's own keys and allowed signers on the host; nil when nothing answered.
    func verify(_ hash: String) async -> GitSignatureCheck? {
        guard let hash = GitCommands.checked(hash),
              let output = try? await git.git(root, args: GitCommands.verify(hash), limit: 0) else { return nil }
        return GitParsers.signatureCheck(output.output, status: output.status)
    }
}
