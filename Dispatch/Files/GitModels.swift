import Foundation

// The git side of files mode: everything is read-only and comes from
// bounded git commands the helper runs on the tab's host (`files.git`); the app parses the output.

/// What `files.git` answers: the command's stdout (its stderr instead when it failed), its exit status, and whether
/// the output was cut at the helper's bound.
struct GitOutput: Hashable, Sendable {
    var status: Int64
    var output: String
    var truncated: Bool

    var succeeded: Bool { status == 0 }
}

/// The repository enclosing a shown folder (`git rev-parse --show-toplevel`).
struct GitRepository: Hashable, Sendable {
    var root: String
}

/// Whether the shown folder is in a repository, as the loader resolves it per folder and connection.
enum GitState: Hashable, Sendable {
    case loading
    case repository(GitRepository)
    /// Not a repository: the Changes and Commits segments do not show.
    case none
    /// git is missing on the host, or the connection's grant lacks git.
    case unavailable(String)

    var repository: GitRepository? {
        if case .repository(let repository) = self { return repository }
        return nil
    }
}

/// The status letter a change shows (F2a, F3a): M amber, A and U green, D red; `!` dims an ignored entry.
enum GitChangeKind: String, Hashable, Sendable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case typeChanged = "T"
    case untracked = "U"
    case ignored = "!"
    case conflicted = "X"
}

/// Where a change sits in the working tree against HEAD. A file changed in two areas appears twice.
enum GitChangeArea: String, Hashable, Sendable, CaseIterable {
    case staged, unstaged, untracked
}

struct GitChange: Hashable, Sendable, Identifiable {
    /// Repository-relative.
    var path: String
    /// A rename's or copy's old path.
    var oldPath: String?
    var kind: GitChangeKind
    var area: GitChangeArea
    /// From `git diff --numstat`; nil for binary files and until the counts are loaded.
    var additions: Int?
    var deletions: Int?
    var binary = false
    /// A binary's sizes on each side, when the data layer knows them: the list shows "binary · 48 KB → 51 KB" from
    /// these before its diff is loaded.
    var oldSize: UInt64?
    var newSize: UInt64?

    var id: String { area.rawValue + ":" + path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }

    /// Whether git can be asked about it by name. The helper's output is read as UTF-8 with U+FFFD for what is not, so
    /// a name in another encoding arrives changed and naming it back to git would ask about a file that does not exist
    /// (or another one): such a change gets no diff, only `unrepresentable`.
    var representable: Bool { Self.representable(path) && oldPath.map(Self.representable) ?? true }
    static func representable(_ path: String) -> Bool { !path.unicodeScalars.contains("\u{FFFD}") }
    /// The diff error of a change that is not `representable`.
    static let unrepresentable = "Name not representable: it is not UTF-8, so git cannot be asked for its diff"
}

/// `git status --porcelain=v2 --branch` with the per-file counts folded in.
struct GitStatus: Hashable, Sendable {
    /// Nil on a detached HEAD.
    var branch: String?
    /// HEAD's short hash.
    var head: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var changes: [GitChange]
    var loadedAt: Date
    /// The status was cut at the helper's bound: `changes` holds the first of them only.
    var truncated = false

    func changes(in area: GitChangeArea) -> [GitChange] { changes.filter { $0.area == area } }
    var additions: Int { changes.reduce(0) { $0 + ($1.additions ?? 0) } }
    var deletions: Int { changes.reduce(0) { $0 + ($1.deletions ?? 0) } }
}

enum GitRefKind: Hashable, Sendable {
    case head, branch, remote, tag
}

/// A ref chip on a commit: the checked-out branch is filled, a tag is amber text, a remote branch outlined (F4a).
struct GitRef: Hashable, Sendable {
    var name: String
    var kind: GitRefKind
    var current: Bool
}

struct GitCommit: Hashable, Sendable, Identifiable {
    var hash: String
    var parents: [String]
    var subject: String
    var body: String
    var author: String
    var email: String
    var date: Date
    var refs: [GitRef]

    var id: String { hash }
    var short: String { String(hash.prefix(7)) }
}

/// What the detail pane shows for the selected commit: its files with their counts.
struct GitCommitDetail: Hashable, Sendable {
    var commit: GitCommit
    var files: [GitChange]
}

enum GitLogScope: String, Hashable, Sendable {
    case branch, all
}

/// The loaded part of the log, 200 commits a page (F4a).
struct GitLog: Hashable, Sendable {
    var commits: [GitCommit]
    /// No page follows the last one loaded.
    var exhausted: Bool
    var scope: GitLogScope
    var filter: String
    var loadedAt: Date
}

/// One file's diff as git prints it (unified, no colour), or the facts of a binary change.
struct GitDiff: Hashable, Sendable {
    var path: String
    var oldPath: String?
    var text: String
    var binary = false
    var oldSize: UInt64?
    var newSize: UInt64?
    var truncated = false
}

enum GitDiffMode: String, Hashable, Sendable {
    case diff, source
}

/// A diff the views asked for: loading, loaded, or failed.
struct GitDiffState: Hashable, Sendable {
    var key: String
    var diff: GitDiff?
    var error: String?
    var loading = false
}
