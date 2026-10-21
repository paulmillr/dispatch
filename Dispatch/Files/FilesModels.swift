import Foundation

// The contract between the files views, the per-tab session and the sources that list, read and copy
// files on a host. A source is the helper on that host; tests use an in-memory one.

/// What the helper reports for an entry (`FileKind` on the wire).
enum FileEntryKind: String, Codable, Hashable, Sendable {
    case file, directory, symlink, other
}

/// A filesystem object's stable identity for one operation. It binds copy authorization to the
/// directory and conflicting entry the user actually saw.
struct FileIdentity: Hashable, Sendable, Codable {
    var device: UInt64
    var inode: UInt64
}

/// One row of a listing as `files.list` returns it. `size` and `modified` describe the entry itself (a
/// symlink's own metadata); `targetKind` is what a symlink points at, nil when it dangles.
struct FileEntry: Hashable, Sendable, Identifiable {
    var name: String
    var kind: FileEntryKind
    var size: UInt64
    var modified: Date?
    var targetKind: FileEntryKind?
    var identity: FileIdentity? = nil

    var id: String { name }
    var isHidden: Bool { name.hasPrefix(".") }
    var isDirectory: Bool { kind == .directory || (kind == .symlink && targetKind == .directory) }
    var isRegularFile: Bool { kind == .file || (kind == .symlink && targetKind == .file) }
}

/// One level of a directory. Entries come in bytewise name order; the view sorts them.
struct FileListing: Hashable, Sendable {
    var path: String
    var entries: [FileEntry]
    /// The 10,000-entry bound stopped the listing.
    var truncated: Bool
    var identity: FileIdentity? = nil
}

struct FolderSummary: Hashable, Sendable {
    var files: UInt64
    var folders: UInt64
    var bytes: UInt64
    var truncated: Bool
}

/// The helper's `Metadata`: one version of a file, so a read spanning several requests fails with
/// `.changed` instead of mixing versions. The nanosecond stamps stay as the decimal strings the wire carries.
struct FileRevision: Hashable, Sendable, Codable {
    var kind: FileEntryKind
    var size: UInt64
    var device: UInt64
    var inode: UInt64
    var modifiedNs: String
    var changedNs: String

    var modified: Date? { Self.date(modifiedNs) }

    static func date(_ nanoseconds: String) -> Date? {
        guard let value = Double(nanoseconds) else { return nil }
        return Date(timeIntervalSince1970: value / 1_000_000_000)
    }
}

/// What `files.pack` produced: an archive on the source host, to be read with `read` and dropped afterwards.
struct PackedArchive: Hashable, Sendable {
    var archive: String
    var entries: UInt64
    var files: UInt64
    var folders: UInt64
    /// Uncompressed bytes in the archive.
    var bytes: UInt64
    /// The archive's size on disk, the total a read of it will deliver.
    var size: UInt64
    var skipped: UInt64
}

struct UnpackTransfer: Hashable, Sendable {
    var transfer: String
    var staging: String
}

struct UnpackResult: Hashable, Sendable {
    var entries: UInt64
    var bytes: UInt64
    var replaced: UInt64
    var kept: UInt64
    var skipped: UInt64
}

/// How `files.unpack.close` treats a top-level name that already exists in the target.
enum ConflictPolicy: String, Hashable, Sendable {
    case replace, keep, skip
}

enum FilesEndpoint: Hashable, Sendable {
    case local
    case remote(SSHConnectionID)

    var isLocal: Bool { self == .local }
}

enum FilesSourceError: Error, Hashable, Sendable {
    case notFound(String)
    case permissionDenied(String)
    case notDirectory(String)
    case changed(String)
    case exists(String)
    case limit(String)
    case busy(String)
    case unsupported(String)
    case offline(String)
    case cancelled
    case other(code: String, message: String)

    var message: String {
        switch self {
        case .notFound(let path): "\(path) does not exist"
        case .permissionDenied(let path): "No permission to read \(path)"
        case .notDirectory(let path): "\(path) is not a folder"
        case .changed(let path): "\(path) changed while reading"
        case .exists(let path): "\(path) already exists"
        case .limit(let detail): detail
        case .busy(let detail): detail
        case .unsupported(let detail): detail
        case .offline(let host): "\(host) is offline"
        case .cancelled: "Cancelled"
        case .other(_, let message): message
        }
    }
}

/// Lists, reads and copies files on one host. Paths are absolute on that host. Implementations are the
/// helper on that host (`HelperFilesSource`) and the tests' in-memory tree (`FakeFilesSource`).
protocol FilesSource: AnyObject, Sendable {
    var endpoint: FilesEndpoint { get }
    /// The account's home on that host: the default root and the `~` of the crumbs.
    var home: String? { get }
    /// The host's short name ("homelab"; the crumbs add the colon); nil on this Mac.
    var hostLabel: String? { get }
    /// Nothing may be copied in: the host's grant has Files without Copy files in. This Mac's files never are.
    var readOnly: Bool { get }

    /// One level. `hidden` false omits dot-names at the source.
    func list(_ path: String, hidden: Bool) async throws -> FileListing
    /// A bounded walk below a folder.
    func summary(_ path: String) async throws -> FolderSummary
    /// `length` nil reads to the end. A `revision` from an earlier window makes a changed file fail with `.changed`.
    func read(_ path: String, offset: UInt64, length: UInt64?, revision: FileRevision?) async throws
        -> (data: Data, revision: FileRevision)
    /// One whole small file, written to a temporary name beside the target and renamed into place.
    func write(_ path: String, data: Data, mode: UInt32?, replace: Bool, parent: FileIdentity,
               replaced: FileIdentity?) async throws -> FileRevision
    /// Packs `paths` (absolute, inside `base`) into a temporary tar.zst on that host, named relative to `base`.
    func pack(transfer: String, base: String, paths: [String]) async throws -> PackedArchive
    /// Removes a packed archive, or marks a running pack so its archive is removed when it completes.
    func dropArchive(transfer: String) async throws
    /// Opens a staging folder beside `target` for an archive to arrive in. `names` are the archive's top-level
    /// names (the dragged items' own names, before any keep-both numbering): the helper refuses an archive that
    /// holds any other, so a host answering for the source cannot plant a name the user never dragged.
    func openUnpack(transfer: String, target: String, policy: ConflictPolicy, names: [String], parent: FileIdentity,
                    replacements: [String: FileIdentity]) async throws -> UnpackTransfer
    /// Appends archive bytes; returns the bytes staged so far.
    func writeUnpack(transfer: String, data: Data) async throws -> UInt64
    /// Extracts and moves the archive's entries into the target (`commit`), or removes the staging folder.
    func closeUnpack(transfer: String, commit: Bool) async throws -> UnpackResult
    /// A read-only git command the helper allows (`files.git`), run in `path`, output bounded by `limit` (0: the
    /// helper's own bound). A failed command answers with its status and stderr, not an error; a refused one throws.
    func git(_ path: String, args: [String], limit: UInt64) async throws -> GitOutput
}

extension FilesSource {
    var readOnly: Bool { false }
}

/// Whether a tab can show files, and through what.
enum FilesAvailability {
    case loading
    case available(any FilesSource)
    /// The tab connected as plain SSH: no helper on that host.
    case plainSSH(host: String)
    /// The connection has a helper but the Files grant is off.
    case notGranted(host: String, scope: SSHIntegrationScope?)
    /// The host's connection dropped; `since` is when the last live listing was taken.
    case offline(host: String, since: Date?)
    case unavailable(message: String)

    var source: (any FilesSource)? {
        if case .available(let source) = self { return source }
        return nil
    }

    var isAvailable: Bool { source != nil }
}

/// The three tabs of files mode. Step one shows `.files` only; the others are remembered but not shown.
/// What files mode shows: the Files tab, or the Commits tab with one of its rows selected: `changes` is its
/// uncommitted-changes row (the working tree's files and their diffs in the detail), `commits` a commit. With
/// Settings › Features › Git › Separate Changes tab, `changes` is that tab instead (`FilesSession.showsLog`).
enum FilesTab: String, Hashable, Sendable, CaseIterable {
    case files, changes, commits
}

enum FilesSort: String, Hashable, Sendable, CaseIterable {
    case name, modified, size
}

/// One loaded (or loading, or failed) directory level, keyed by absolute path in `FilesSession.listings`.
struct FileListingState: Sendable {
    var listing: FileListing?
    var loadedAt: Date?
    var error: FilesSourceError?
    var loading = false

    var entries: [FileEntry] { listing?.entries ?? [] }
}
