import Foundation

/// A host's files through its helper's `files.*` operations (helper/PROTOCOL.md): this Mac's bundled helper
/// for a local tab, the SSH connection's helper for a remote one. One request per call and never a retry:
/// a failed write or an unanswered commit may have happened, and only the caller knows whether repeating is safe.
final class HelperFilesSource: FilesSource, Sendable {
    let endpoint: FilesEndpoint
    let home: String?
    let hostLabel: String?
    /// The connection's grant has Files without Copy files in: copies into this host are refused before they start.
    let readOnly: Bool
    /// A fixed connection (a test's own helper), or nil to borrow the endpoint's from `HelperApp` per call:
    /// the shared local helper may be restarted, and a remote connection's helper is lent only while it lives.
    private let connection: HelperConnection?

    init(endpoint: FilesEndpoint, connection: HelperConnection, home: String?, hostLabel: String?, readOnly: Bool = false) {
        self.endpoint = endpoint
        self.connection = connection
        self.home = home
        self.hostLabel = hostLabel
        self.readOnly = readOnly
    }

    init(endpoint: FilesEndpoint, home: String?, hostLabel: String?, readOnly: Bool = false) {
        self.endpoint = endpoint
        connection = nil
        self.home = home
        self.hostLabel = hostLabel
        self.readOnly = readOnly
    }

    // MARK: Bounds

    /// How long a remote call may take before it is reported as uncertain. Local calls have no bound: this
    /// Mac's helper answers or exits, and a stalled disk is not something a timeout fixes.
    enum Bound {
        /// Listing, summaries, opening, aborting and dropping transfers.
        case quick
        /// Moving this many bytes over the connection: 10 s, and 1 s more per 64 KiB (a link of 64 KiB/s still
        /// makes it), at most 10 minutes.
        case bytes(UInt64)
        /// Packing or extracting a whole tree: as long as it takes. Timing out would only report a pack that is
        /// still running, or a commit still moving entries in, as failed; a host that went away ends the
        /// connection, and with it the call.
        case job
        /// A git command with this output bound (0: the helper's 2 MiB). The helper runs a command in up to three steps
        /// of at most 20 s each (two filter probes on a repository's first command, then the command) and says when
        /// one ran out; 65 s leaves it the time to, so a slow `status` fails in the helper's words rather than as an
        /// uncertain timeout here. The output then crosses the connection like a read of that size (1 s per 64 KiB);
        /// at most 10 minutes.
        case git(UInt64)

        /// The timer's name in recordings: one per kind, so a replay matches whatever the byte count was.
        var name: String {
            switch self {
            case .quick: "files.quick"
            case .bytes: "files.bytes"
            case .job: "files.job"
            case .git: "files.git"
            }
        }

        var duration: Duration? {
            switch self {
            case .quick: .seconds(10)
            case .bytes(let count): .seconds(10 + Int64(min(count / (64 << 10), 590)))
            case .job: nil
            case .git(let limit): .seconds(65 + Int64(min((limit == 0 ? 2 << 20 : limit) / (64 << 10), 535)))
            }
        }
    }

    // MARK: FilesSource

    func list(_ path: String, hidden: Bool) async throws -> FileListing {
        let listing: Wire.Listing = try await call("files.list", Wire.List(path: path, hidden: hidden), .quick, path: path)
        return listing.model
    }

    func summary(_ path: String) async throws -> FolderSummary {
        let summary: Wire.Summary = try await call("files.summary", Wire.Bounded(path: path), .quick, path: path)
        return FolderSummary(files: summary.files, folders: summary.folders, bytes: summary.bytes, truncated: summary.truncated)
    }

    func read(_ path: String, offset: UInt64, length: UInt64?, revision: FileRevision?) async throws
        -> (data: Data, revision: FileRevision) {
        let params = Wire.Read(path: path, offset: offset, length: length, revision: revision.map(Wire.Metadata.init))
        // To the end: the file's size is not known here, so the longest bound.
        let reply: (result: Wire.Metadata, bytes: Data) = try await perform(.bytes(length ?? .max), path: path) { connection in
            try await connection.requestBinary("files.read", params: params)
        }
        return (reply.bytes, reply.result.model)
    }

    func write(_ path: String, data: Data, mode: UInt32?, replace: Bool, parent: FileIdentity,
               replaced: FileIdentity?) async throws -> FileRevision {
        let params = Wire.Write(path: path, bytes: data, mode: mode.map(UInt64.init), replace: replace,
                                parent: Wire.Identity(parent), replaced: replaced.map(Wire.Identity.init))
        let metadata: Wire.Metadata = try await call("files.write", params, .bytes(UInt64(data.count)), path: path)
        return metadata.model
    }

    func pack(transfer: String, base: String, paths: [String]) async throws -> PackedArchive {
        let packed: Wire.Packed = try await call("files.pack", Wire.Pack(transfer: transfer, base: base, paths: paths), .job, path: base)
        return PackedArchive(archive: packed.archive, entries: packed.entries, files: packed.files, folders: packed.folders,
                             bytes: packed.bytes, size: packed.size, skipped: packed.skipped)
    }

    func dropArchive(transfer: String) async throws {
        let _: HelperClient.Ignored = try await call("files.pack.drop", Wire.Named(transfer: transfer), .quick, path: transfer)
    }

    func openUnpack(transfer: String, target: String, policy: ConflictPolicy, names: [String], parent: FileIdentity,
                    replacements: [String: FileIdentity]) async throws -> UnpackTransfer {
        let guarded = replacements.map { Wire.Replacement(name: $0.key, device: $0.value.device, inode: $0.value.inode) }
        let params = Wire.Open(transfer: transfer, target: target, policy: policy.rawValue, names: names,
                               parent: Wire.Identity(parent), replacements: guarded)
        let opened: Wire.Transfer = try await call("files.unpack.open", params, .quick, path: target)
        return UnpackTransfer(transfer: opened.transfer, staging: opened.staging)
    }

    func writeUnpack(transfer: String, data: Data) async throws -> UInt64 {
        let progress: Wire.Progress = try await call("files.unpack.write", Wire.Append(transfer: transfer, bytes: data),
                                                     .bytes(UInt64(data.count)), path: transfer)
        return progress.bytes
    }

    func closeUnpack(transfer: String, commit: Bool) async throws -> UnpackResult {
        let unpacked: Wire.Unpacked = try await call("files.unpack.close", Wire.Close(transfer: transfer, commit: commit),
                                                     commit ? .job : .quick, path: transfer)
        return UnpackResult(entries: unpacked.entries, bytes: unpacked.bytes, replaced: unpacked.replaced, kept: unpacked.kept,
                            skipped: unpacked.skipped)
    }

    func git(_ path: String, args: [String], limit: UInt64) async throws -> GitOutput {
        let answer: Wire.Git = try await call("files.git", Wire.GitRun(path: path, args: args, limit: limit), .git(limit), path: path)
        return GitOutput(status: answer.status, output: answer.output, truncated: answer.truncated)
    }

    // MARK: Calls

    private func call<P: Encodable & Sendable, R: Decodable & Sendable>(_ method: String, _ params: P, _ bound: Bound,
                                                                         path: String) async throws -> R {
        try await perform(bound, path: path) { connection in try await connection.request(method, params: params) }
    }

    private func perform<R: Sendable>(_ bound: Bound, path: String,
                                      _ body: @escaping @Sendable (HelperConnection) async throws -> R) async throws -> R {
        let fixed = connection, endpoint = endpoint
        let run: @Sendable () async throws -> R = {
            let connection: HelperConnection
            if let fixed { connection = fixed } else {
                switch endpoint {
                case .local: connection = try await HelperApp.shared.connection(.local)
                case .remote(let id): connection = try await HelperApp.shared.connection(.remote(id))
                }
            }
            return try await body(connection)
        }
        do {
            guard !endpoint.isLocal, let duration = bound.duration else { return try await run() }
            return try await SSHTimeout.run(duration, bound.name, operation: run)
        } catch {
            throw Self.map(error, path: path, host: endpoint.isLocal ? nil : hostLabel ?? "The host")
        }
    }

    /// The helper's codes as the files views word them. `path` names what the request was about; `host` is the
    /// remote host's name, nil on this Mac (whose helper going away is a failure, not the host going offline).
    static func map(_ error: any Error, path: String, host: String?) -> FilesSourceError {
        if let error = error as? FilesSourceError { return error }
        if error is CancellationError { return .cancelled }
        // SSHTimeout's own failure: the request may still complete on the host.
        if let timeout = error as? HerdrFailure { return .other(code: "uncertain", message: timeout.message) }
        let helper = host.map { "The helper on " + $0 } ?? "This Mac’s helper"
        // The helper's stream broke: a frame cut short, a chunked reply left open, a reply out of step. The connection
        // ends the stream on any of these (`HelperConnection.receive`), so they read as the connection dropping.
        if error is HelperWire.Failure || error is HelperBinary.Failure {
            return host.map(FilesSourceError.offline) ?? .other(code: "disconnected", message: helper + " stopped answering")
        }
        guard let failure = error as? HelperFailure else { return .other(code: "internal", message: error.localizedDescription) }
        func detail(_ fallback: String) -> String { failure.message.isEmpty ? fallback : failure.message }
        switch failure.code {
        case "not_found": return .notFound(path)
        case "permission_denied": return .permissionDenied(path)
        case "not_directory": return .notDirectory(path)
        case "changed": return .changed(path)
        case "exists": return .exists(path)
        case "limit": return .limit(detail("\(path) is larger than the helper copies at once"))
        case "busy": return .busy(detail(helper + " is busy with another copy"))
        case "unsupported": return .unsupported(detail(helper + " can’t do this yet"))
        case "unavailable", "connection_closed", "invalid_response":
            if let host { return .offline(host) }
            let code = failure.code == "invalid_response" ? "disconnected" : failure.code
            return .other(code: code, message: detail(helper + " is unavailable"))
        case "cancelled": return .cancelled
        default: return .other(code: failure.code, message: detail(helper + " failed (\(failure.code))"))
        }
    }
}

/// The `files.*` params and results as the helper encodes them. Nanosecond stamps are i128 on the helper and
/// travel as decimal strings; `Bytes` params are raw `Data`.
private enum Wire {
    struct List: Encodable, Sendable {
        let path: String
        let hidden: Bool
        /// 0: the helper's own bound (10,000 entries).
        var limit: UInt64 = 0
        /// Git marks are reserved for the git tabs; step one never asks for them.
        var git = false
    }

    struct Bounded: Encodable, Sendable {
        let path: String
        /// 0: the helper's own bound (100,000 entries visited).
        var limit: UInt64 = 0
    }
    struct GitRun: Encodable, Sendable {
        let path: String
        let args: [String]
        let limit: UInt64
    }
    struct Git: Decodable, Sendable {
        let status: Int64
        let output: String
        let truncated: Bool
    }

    struct Read: Encodable, Sendable {
        let path: String
        let offset: UInt64
        /// Absent reads to the end.
        let length: UInt64?
        let revision: Metadata?
    }

    struct Write: Encodable, Sendable {
        let path: String
        let bytes: Data
        /// Absent: 0o644 less the helper's umask.
        let mode: UInt64?
        let replace: Bool
        let parent: Identity
        let replaced: Identity?
    }

    struct Identity: Codable, Sendable {
        let device: UInt64
        let inode: UInt64

        init(_ identity: FileIdentity) { (device, inode) = (identity.device, identity.inode) }
    }

    struct Replacement: Encodable, Sendable {
        let name: String
        let device: UInt64
        let inode: UInt64
    }

    struct Pack: Encodable, Sendable {
        let transfer: String
        let base: String
        let paths: [String]
        /// 0: the helper's own bound (250,000 entries).
        var limit: UInt64 = 0
    }

    struct Named: Encodable, Sendable {
        let transfer: String
    }

    struct Open: Encodable, Sendable {
        let transfer: String
        let target: String
        let policy: String
        /// The archive's top-level names; the helper refuses any other.
        let names: [String]
        let parent: Identity
        let replacements: [Replacement]
    }

    struct Append: Encodable, Sendable {
        let transfer: String
        let bytes: Data
    }

    struct Close: Encodable, Sendable {
        let transfer: String
        let commit: Bool
    }

    /// An i128 nanosecond stamp: the helper writes a decimal string; an integer is accepted as well.
    struct Stamp: Codable, Sendable {
        let text: String

        init(_ text: String) { self.text = text }

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let text = try? value.decode(String.self) { self.text = text }
            else if let number = try? value.decode(Int64.self) { text = String(number) }
            else { text = String(try value.decode(UInt64.self)) }
        }

        func encode(to encoder: any Encoder) throws {
            var value = encoder.singleValueContainer()
            try value.encode(text)
        }
    }

    struct Metadata: Codable, Sendable {
        let kind: String
        let size: UInt64
        let device: UInt64
        let inode: UInt64
        let modified_ns: Stamp
        let changed_ns: Stamp

        init(_ revision: FileRevision) {
            kind = revision.kind.rawValue
            size = revision.size
            device = revision.device
            inode = revision.inode
            modified_ns = Stamp(revision.modifiedNs)
            changed_ns = Stamp(revision.changedNs)
        }

        var model: FileRevision {
            FileRevision(kind: FileEntryKind(rawValue: kind) ?? .other, size: size, device: device, inode: inode,
                         modifiedNs: modified_ns.text, changedNs: changed_ns.text)
        }
    }

    struct Entry: Decodable, Sendable {
        let name: String
        let kind: String
        let size: UInt64
        let modified_ns: Stamp
        let target: String?
        let mark: String?
        let device: UInt64?
        let inode: UInt64?

        var model: FileEntry {
            FileEntry(name: name, kind: FileEntryKind(rawValue: kind) ?? .other, size: size,
                      modified: FileRevision.date(modified_ns.text), targetKind: target.map { FileEntryKind(rawValue: $0) ?? .other },
                      mark: mark, identity: device.flatMap { device in inode.map { FileIdentity(device: device, inode: $0) } })
        }
    }

    struct Listing: Decodable, Sendable {
        let path: String
        let entries: [Entry]
        let truncated: Bool
        let device: UInt64?
        let inode: UInt64?

        var model: FileListing {
            FileListing(path: path, entries: entries.map(\.model), truncated: truncated,
                        identity: device.flatMap { device in inode.map { FileIdentity(device: device, inode: $0) } })
        }
    }

    struct Summary: Decodable, Sendable {
        let files: UInt64
        let folders: UInt64
        let bytes: UInt64
        let truncated: Bool
    }

    struct Packed: Decodable, Sendable {
        let archive: String
        let entries: UInt64
        let files: UInt64
        let folders: UInt64
        let bytes: UInt64
        let size: UInt64
        let skipped: UInt64
    }

    struct Transfer: Decodable, Sendable {
        let transfer: String
        let staging: String
    }

    struct Progress: Decodable, Sendable {
        let bytes: UInt64
    }

    struct Unpacked: Decodable, Sendable {
        let entries: UInt64
        let bytes: UInt64
        let replaced: UInt64
        let kept: UInt64
        let skipped: UInt64
    }
}

/// Sources other code asks for without a tab: this Mac's files.
enum FilesSources {
    @MainActor private static var shared: HelperFilesSource?

    /// This Mac's helper, one instance for every caller (the resolver hands the same one to local tabs).
    @MainActor static func local() -> any FilesSource { localSource() }

    @MainActor static func localSource() -> HelperFilesSource {
        if let shared { return shared }
        let source = HelperFilesSource(endpoint: .local, home: System.home.path, hostLabel: nil)
        shared = source
        return source
    }
}
