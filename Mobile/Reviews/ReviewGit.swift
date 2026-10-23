import Foundation
import Observation

/// Why Review's git read gave no answer, worded as the Mac's git tabs word it (`GitQueries.output`, `GitError`).
enum ReviewGitError: Error, Equatable, Sendable, LocalizedError {
    /// The folder is outside any work tree (git's "not a git repository").
    case notRepository
    /// git ran and failed: its own words.
    case failed(String)
    /// git cannot run there: not installed on the host, or the connection's grant leaves git out.
    case unavailable(String)
    /// The read failed before git answered (the link dropped, the helper's deadline, a busy helper): says nothing
    /// about the repository, so what was shown stays and the next read asks again.
    case source(String)

    var message: String {
        switch self {
        case .notRepository: "Not a repository"
        case .failed(let message), .unavailable(let message), .source(let message): message
        }
    }

    var errorDescription: String? { message }

    /// A failure of the way to git, not git's answer: a list keeps showing the last status without a note.
    var transient: Bool {
        if case .source = self { return true }
        return false
    }
}

/// How Review reads a repository on a host: the status with its counts, a change's diff, a file's text. The helper's
/// (`files.git`, `files.read`, `files.text`, read-only: `git.read`, `file.read` and `file.text` in the grant) or a
/// script's.
struct ReviewGitReader: Sendable {
    /// `git status` with both sides' `--numstat` counts and the untracked files' line counts folded in, at `root`.
    var status: @Sendable (_ root: String) async throws -> GitStatus
    /// A change's diff at `root` (an untracked file's text as additions).
    var diff: @Sendable (_ root: String, _ change: GitChange) async throws -> GitDiff
    /// A file's text (an absolute path); nil when it is binary or too large to show.
    var text: @Sendable (_ path: String) async throws -> String?
    /// Forgets what the reader remembers of `root` between status reads (the untracked files' line counts, the
    /// binaries' sizes): the next status counts them again. Asked on an explicit refresh (pull, an agent's turn ending,
    /// foregrounding).
    var forget: @Sendable (_ root: String) -> Void = { _ in }

    /// Through a host's helper: the Mac's exact read-only commands (`GitQueries`, `GitLoader.readStatus`).
    static func helper(_ client: HelperClient) -> ReviewGitReader {
        let git = ReviewHelperGit(client: client, memory: .shared)
        return ReviewGitReader(status: { try await git.status($0) }, diff: { try await git.diff($0, $1) },
                               text: { try await git.text($0) }, forget: { git.memory.forget(git.key($0)) })
    }
}

/// The helper side of `ReviewGitReader`: `files.git` with the arguments `GitQueries` sends (git runs in the
/// repository's top folder, every path is repository-relative), `files.read` for bounded reads of untracked files,
/// `files.text` for a whole file.
struct ReviewHelperGit: Sendable {
    let client: HelperClient
    let memory: ReviewGitMemory

    /// The status and its counts' output bound (`GitQueries.statusLimit`): the helper's cap.
    static let statusLimit: UInt64 = 8 << 20
    /// What an untracked file is read up to for its diff (`GitQueries.readBound`).
    static let readBound: UInt64 = 2 << 20
    /// git's own binary test: a NUL in the first 8,000 bytes.
    static let binaryProbe = 8_000
    /// Untracked files counted per status, the bytes a count may read, and what one status may read for counts
    /// (`GitLoader.countedUntracked`, `countedBytes`, `countBudget`).
    static let countedUntracked = 50
    static let countedBytes: UInt64 = 256 << 10
    static let countBudget: UInt64 = 4 << 20
    /// Binaries whose sizes one status asks for (`GitLoader.sizedBinaries`).
    static let sizedBinaries = 16

    /// What the memory keeps for this connection and repository: a new connection (another client) counts again.
    /// The connection (`ReviewGitMemory.token`, never reused by a later client) and the repository.
    func key(_ root: String) -> String { "\(memory.token(client).uuidString)|\(root)" }

    // MARK: Status

    /// The status, both sides' counts, the untracked files' line counts and the binaries' sizes, folded into one
    /// `GitStatus` as the Mac's `GitLoader.readStatus` does. `loadedAt` is left at the epoch for the caller.
    func status(_ root: String) async throws(ReviewGitError) -> GitStatus {
        async let porcelainRead = result(root, ["status", "--porcelain=v2", "--branch", "-z", "--ignored", "--untracked-files=normal"],
                                         limit: Self.statusLimit)
        async let unstagedRead = result(root, ["diff", "--numstat", "-z"], limit: Self.statusLimit)
        async let stagedRead = result(root, ["diff", "--cached", "--numstat", "-z"], limit: Self.statusLimit)
        let output = try await porcelainRead.get(), unstagedOutput = try await unstagedRead.get()
        let stagedOutput = try await stagedRead.get()
        var porcelain = GitParsers.porcelain(output.output)
        porcelain.truncated = output.truncated
        var counts = [GitChangeArea.unstaged: [String: GitNumstat](), .staged: [:]]
        for count in GitParsers.numstat(unstagedOutput.output) { counts[.unstaged]?[count.path] = count }
        for count in GitParsers.numstat(stagedOutput.output) { counts[.staged]?[count.path] = count }

        let key = key(root)
        let known = memory.counted(key)
        var next: [String: ReviewGitMemory.Counted] = [:]
        var budget = Self.countBudget
        let untracked = porcelain.changes.filter { $0.area == .untracked && !$0.path.hasSuffix("/") && $0.representable }
            .prefix(Self.countedUntracked)
        for change in untracked {
            // Counted before and still untracked: nothing tells it changed until an explicit refresh forgets it.
            if let counted = known[change.path] {
                next[change.path] = counted
                continue
            }
            // What this read has left must cover the most a count reads: else a later read counts it.
            guard budget >= Self.countedBytes, let read = try? await read(root, change.path, length: Self.countedBytes) else { continue }
            budget -= min(UInt64(read.data.count), budget)
            let binary = Self.isBinary(read.data)
            let whole = UInt64(read.data.count) >= read.size
            next[change.path] = ReviewGitMemory.Counted(lines: !binary && whole ? Self.lineCount(read.data) : nil, binary: binary,
                                                        size: read.size)
        }
        memory.setCounted(key, next)

        var changes = porcelain.changes.map { change -> GitChange in
            var change = change
            if change.area == .untracked {
                guard let counted = next[change.path] else { return change }
                change.additions = counted.lines
                change.deletions = counted.lines.map { _ in 0 }
                change.binary = counted.binary
                if counted.binary { change.newSize = counted.size }
            } else if let count = counts[change.area]?[change.path] {
                // Only what the status lists takes counts: numstat also names a binary that is merely stat-dirty.
                change.additions = count.additions
                change.deletions = count.deletions
                change.binary = count.binary
            }
            return change
        }

        // A binary's sizes, so the list says "binary · 48 KB → 51 KB": at most `sizedBinaries` asked per status.
        let sizedBefore = memory.sized(key)
        var sized: [String: ReviewGitMemory.Sized] = [:], asked = 0
        for index in changes.indices where changes[index].binary && changes[index].area != .untracked && changes[index].representable {
            let change = changes[index]
            var found = sizedBefore[change.id]
            if found == nil, asked < Self.sizedBinaries {
                asked += 1
                if let sizes = try? await self.sizes(root, change) { found = ReviewGitMemory.Sized(old: sizes.old, new: sizes.new) }
            }
            guard let found else { continue }
            sized[change.id] = found
            changes[index].oldSize = found.old
            changes[index].newSize = found.new
        }
        memory.setSized(key, sized)

        return GitStatus(branch: porcelain.branch, head: porcelain.head.map { String($0.prefix(7)) }, upstream: porcelain.upstream,
                         ahead: porcelain.ahead, behind: porcelain.behind, changes: changes,
                         loadedAt: Date(timeIntervalSince1970: 0), truncated: porcelain.truncated)
    }

    /// A staged or unstaged binary's sizes on each side (`diff [--cached] --stat -- path`); nil when git printed none.
    func sizes(_ root: String, _ change: GitChange) async throws(ReviewGitError) -> (old: UInt64, new: UInt64)? {
        let cached = change.area == .staged ? ["--cached"] : []
        let output = try await run(root, ["diff"] + cached + ["--stat", "--"] + Self.paths(change.path, old: change.oldPath))
        return GitParsers.binarySizes(output.output)
    }

    // MARK: Diff

    /// The change's diff: git's (`diff [--cached] -U3 -- path`, both paths for a rename) for a staged or unstaged one,
    /// the file's text as additions for an untracked one.
    func diff(_ root: String, _ change: GitChange) async throws(ReviewGitError) -> GitDiff {
        guard change.representable else { throw .failed(GitChange.unrepresentable) }
        if change.area == .untracked { return try await untracked(root, change.path) }
        let cached = change.area == .staged ? ["--cached"] : []
        let output = try await run(root, ["diff"] + cached + ["-U3", "--"] + Self.paths(change.path, old: change.oldPath))
        var diff = GitParsers.diffs(output.output, truncated: output.truncated).last
            ?? GitDiff(path: change.path, oldPath: change.oldPath, text: "", truncated: output.truncated)
        if diff.binary, let sizes = try? await sizes(root, change) {
            diff.oldSize = sizes.old
            diff.newSize = sizes.new
        }
        return diff
    }

    /// An untracked file as a diff from nothing (`GitQueries.untracked`): a hunk adding every line, or a binary with
    /// its size.
    func untracked(_ root: String, _ path: String) async throws(ReviewGitError) -> GitDiff {
        if path.hasSuffix("/") {
            throw .failed("\(path.dropLast()) is a folder git does not track yet: its files show in the Files tab")
        }
        let read = try await read(root, path, length: Self.readBound)
        if Self.isBinary(read.data) { return GitDiff(path: path, text: "", binary: true, oldSize: nil, newSize: read.size) }
        let truncated = UInt64(read.data.count) < read.size
        var text = String(decoding: truncated ? Self.wholeLines(read.data) : read.data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let endsInNewline = lines.last == ""
        if endsInNewline { lines.removeLast() }
        text = "diff --git a/\(path) b/\(path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(path)\n"
        if !lines.isEmpty {
            text += "@@ -0,0 +1\(lines.count == 1 ? "" : ",\(lines.count)") @@\n"
            text += lines.map { "+" + $0 + "\n" }.joined()
            if !endsInNewline, !truncated { text += "\\ No newline at end of file\n" }
        }
        return GitDiff(path: path, text: text, oldSize: nil, newSize: read.size, truncated: truncated)
    }

    // MARK: Text

    /// The whole file (`files.text`, as the chat's patch viewer asks it); nil for a binary, non-UTF-8 or too large file
    /// (the helper's `unsupported`).
    func text(_ path: String) async throws(ReviewGitError) -> String? {
        do {
            let text: String = try await client.connection.request("files.text", params: ["plugin": "files", "path": path])
            return text
        } catch let failure as HelperFailure where failure.code == "unsupported" {
            return nil
        } catch {
            throw Self.failure(error)
        }
    }

    // MARK: Running

    private struct GitRun: Encodable, Sendable {
        let path: String
        let args: [String]
        let limit: UInt64
    }

    private struct GitAnswer: Decodable, Sendable {
        let status: Int64
        let output: String
        let truncated: Bool
    }

    private struct Read: Encodable, Sendable {
        let path: String
        let offset: UInt64
        let length: UInt64
    }

    private struct Metadata: Decodable, Sendable {
        let size: UInt64
    }

    /// stdout of a git command that succeeded; its failure in `GitQueries.output`'s words.
    func run(_ root: String, _ args: [String], limit: UInt64 = 0) async throws(ReviewGitError) -> GitOutput {
        let answer: GitAnswer
        do {
            answer = try await client.connection.request("files.git", params: GitRun(path: root, args: args, limit: limit))
        } catch {
            throw Self.failure(error)
        }
        let output = GitOutput(status: answer.status, output: answer.output, truncated: answer.truncated)
        guard output.succeeded else {
            let words = output.output.trimmingCharacters(in: .whitespacesAndNewlines)
            // -1: the helper stopped git at its deadline (or a signal did): not git's answer about the repository.
            if output.status < 0 { throw .source(words.isEmpty ? "git did not finish" : words) }
            if words.contains("not a git repository") || words.contains("must be run in a work tree") { throw .notRepository }
            throw .failed(words.isEmpty ? "git \(args.first ?? "") failed (\(output.status))" : words)
        }
        return output
    }

    /// `run` with its failure as a value, for an `async let`.
    private func result(_ root: String, _ args: [String], limit: UInt64) async -> Result<GitOutput, ReviewGitError> {
        do throws(ReviewGitError) { return .success(try await run(root, args, limit: limit)) } catch { return .failure(error) }
    }

    /// The first `length` bytes of a repository file (`files.read`) and the file's size.
    func read(_ root: String, _ path: String, length: UInt64) async throws(ReviewGitError) -> (data: Data, size: UInt64) {
        let absolute = root == "/" ? "/" + path : root + "/" + path
        do {
            let reply: (result: Metadata, bytes: Data) = try await client.connection.requestBinary(
                "files.read", params: Read(path: absolute, offset: 0, length: length))
            return (reply.bytes, reply.result.size)
        } catch {
            throw Self.failure(error)
        }
    }

    /// The helper's refusals as the git tabs word them (`GitQueries.failure`): a host without git, or a grant without
    /// it, is unavailable; anything else is the source failing.
    static func failure(_ error: any Error) -> ReviewGitError {
        if let error = error as? ReviewGitError { return error }
        if error is CancellationError { return .source("Cancelled") }
        guard let failure = error as? HelperFailure else {
            if error is HelperWire.Failure || error is HelperBinary.Failure { return .source("The helper stopped answering") }
            return .source(error.localizedDescription)
        }
        switch failure.code {
        case "unsupported": return .unavailable(failure.message.isEmpty ? "The helper can’t run git on this host" : failure.message)
        case "permission_denied": return .unavailable("Git isn’t allowed on this host: turn on Files & git for it")
        case "not_found": return .source(failure.message.isEmpty ? "The file does not exist" : failure.message)
        case "unavailable", "connection_closed", "invalid_response": return .source("The host is offline")
        default: return .source(failure.message.isEmpty ? "The helper failed (\(failure.code))" : failure.message)
        }
    }

    // MARK: Helpers

    /// Paths after `--`; one holding pathspec magic is passed literally (`GitQueries.paths`).
    static func paths(_ path: String, old: String?) -> [String] {
        (old.map { [literal($0)] } ?? []) + [literal(path)]
    }

    static func literal(_ path: String) -> String {
        path.contains(where: { "*?[\\".contains($0) }) || path.hasPrefix(":") ? ":(literal)" + path : path
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

/// What the helper reader keeps between status reads, per connection and repository: the untracked files' line counts
/// (reading them is what costs) and the binaries' sizes. A path keeps its count while it stays untracked and among the
/// counted ones, until `forget` (an explicit refresh); the Mac recounts on its listing's stamps, which the phone does
/// not list.
final class ReviewGitMemory: @unchecked Sendable {
    struct Counted: Hashable, Sendable {
        var lines: Int?
        var binary: Bool
        var size: UInt64
    }

    struct Sized: Hashable, Sendable {
        var old: UInt64
        var new: UInt64
    }

    static let shared = ReviewGitMemory()
    /// Repositories remembered before the memory starts again (connections come and go).
    static let capacity = 64

    private let lock = NSLock()
    /// One token per helper client while it lives: an `ObjectIdentifier` alone can name a later client at the same
    /// address after a reconnect.
    private struct Token {
        weak var client: HelperClient?
        let id: UUID
    }
    private var tokens: [ObjectIdentifier: Token] = [:]
    private var counts: [String: [String: Counted]] = [:]

    /// The connection's token: the same for one client, a new one for any other.
    func token(_ client: HelperClient) -> UUID {
        lock.withLock {
            let key = ObjectIdentifier(client)
            if let token = tokens[key], token.client === client { return token.id }
            tokens = tokens.filter { $0.value.client != nil }
            let id = System.uuid()
            tokens[key] = Token(client: client, id: id)
            return id
        }
    }
    private var sizes: [String: [String: Sized]] = [:]

    func counted(_ key: String) -> [String: Counted] { lock.withLock { counts[key] ?? [:] } }
    func sized(_ key: String) -> [String: Sized] { lock.withLock { sizes[key] ?? [:] } }

    func setCounted(_ key: String, _ value: [String: Counted]) {
        lock.withLock {
            if counts[key] == nil, counts.count >= Self.capacity { counts.removeAll() }
            counts[key] = value
        }
    }

    func setSized(_ key: String, _ value: [String: Sized]) {
        lock.withLock {
            if sizes[key] == nil, sizes.count >= Self.capacity { sizes.removeAll() }
            sizes[key] = value
        }
    }

    func forget(_ key: String) {
        lock.withLock {
            counts[key] = nil
            sizes[key] = nil
        }
    }
}

/// One repository's uncommitted changes as Review lists them (H2), read through the host's helper.
///
/// One read at a time: a refresh asked during a read runs once more after it (its callers wait for that one). A failed
/// read keeps the last status (S3 lists it dimmed while the host is offline). Nothing is read while the host has no
/// reader (offline, no grant). The list's `watch` reads on appear and every `interval` while it shows; the screen
/// refreshes on foregrounding, and `MobileReview.changed(host:)` refreshes a host's shown lists when an agent's turn
/// ends.
@MainActor @Observable
final class ReviewChanges {
    let place: ReviewPlace
    @ObservationIgnored private weak var review: MobileReview?
    /// The last status read; kept through failed reads.
    private(set) var status: GitStatus?
    /// The last read's failure, nil after one that answered.
    private(set) var failure: ReviewGitError?
    /// A read is running.
    private(set) var loading = false
    /// The bar's search (the list filters by path while it is open).
    var searching = false
    var query = ""

    /// The watch's cadence (the Mac's files tick).
    @ObservationIgnored var interval: Duration = .seconds(2)
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    @ObservationIgnored var now: @MainActor () -> Date = { System.date() }
    /// Lists showing (their `watch` running): `MobileReview.changed(host:)` refreshes only these.
    @ObservationIgnored private(set) var shown = 0
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var again = false
    @ObservationIgnored private var recount = false

    init(place: ReviewPlace, review: MobileReview) {
        self.place = place
        self.review = review
    }

    var reader: ReviewGitReader? { review?.reader(place.host) }

    /// The failure's words, nil after a read that answered.
    var error: String? { failure?.message }

    /// Reads the status now, or once more after the read in flight; returns when the read covering this call ended.
    /// `fresh` recounts what the reader remembers (the untracked files' lines, the binaries' sizes).
    func refresh(fresh: Bool = false) async {
        if fresh { recount = true }
        if let reading {
            again = true
            await reading.value
            return
        }
        guard reader != nil else { return }
        let task = Task { await self.read() }
        reading = task
        await task.value
    }

    /// Reads on appear and every `interval` until the task is cancelled (a view's `.task`).
    func watch() async {
        shown += 1
        defer { shown -= 1 }
        await refresh()
        while !Task.isCancelled {
            do { try await sleep(interval) } catch { return }
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    private func read() async {
        repeat {
            again = false
            guard let reader else { break }
            if recount {
                recount = false
                reader.forget(place.root)
            }
            set(loading: true)
            do {
                var next = try await reader.status(place.root)
                next.loadedAt = now()
                // A status equal to the shown one but for its time is not written again: the list does not redraw.
                if var same = status {
                    same.loadedAt = next.loadedAt
                    if same != next { status = next }
                } else {
                    status = next
                }
                if failure != nil { failure = nil }
            } catch {
                let failure = ReviewHelperGit.failure(error)
                if self.failure != failure { self.failure = failure }
            }
        } while again
        set(loading: false)
        reading = nil
    }

    private func set(loading: Bool) {
        if self.loading != loading { self.loading = loading }
    }
}
