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

    private var commits: GitCommitReads<CommitsError> {
        GitCommitReads(execute: { args, limit in
            do throws(CommitsError) { return .success(try await output(args, limit: limit)) }
            catch { return .failure(error) }
        }, failed: { .failed($0) }, failedMessage: { error in
            if case .failed(let message) = error { return message }
            return nil
        })
    }

    // MARK: The log

    /// A page of the log with what each commit's raw headers say (its signature's kind, the author's offset, the
    /// committer), read beside it; a page whose raw read fails shows less rather than failing.
    func log(scope: GitLogScope, match: GitLogMatch, skip: Int, count: Int, tip: String?) async throws(CommitsError) -> GitLogPage {
        try await commits.log(scope: scope, match: match, skip: skip, count: count, tip: tip)
    }

    static func fold(_ headers: [String: GitRawHeaders], into commits: inout [GitCommit]) {
        GitCommitReads<CommitsError>.fold(headers, into: &commits)
    }

    func refs() async throws(CommitsError) -> [GitRefRecord] {
        try await commits.refs()
    }

    /// HEAD's commit, nil before the first one.
    func head() async throws(CommitsError) -> String? {
        try await commits.head()
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
        try await commits.commit(hash, requireLetters: false, rawHeaders: true)
    }

    /// One file's diff in the commit (a merge's against its first parent), with a binary's sizes.
    func diff(_ commit: GitCommit, path: String, oldPath: String?) async throws(CommitsError) -> GitDiff {
        try await commits.diff(commit, path: path, oldPath: oldPath)
    }

    /// The file as the commit left it (the Source view): the commit's diff of it with the whole file as context.
    func source(_ commit: GitCommit, path: String, oldPath: String?) async throws(CommitsError) -> String {
        try await commits.source(commit, path: path, oldPath: oldPath, limit: Self.sourceLimit,
                                 tooLarge: "Over 2 MB: the terminal shows the rest")
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
