import Foundation

/// What Files reads on a host (docs/ios.md, Files): one folder level, a window of a file, a read-only git command. The
/// phone's side of the Mac's `FilesSource`, read-only by construction: the phone's grant has no `file.write`, and this
/// protocol has no write, pack or copy to call. The helper's (`HelperMobileFilesSource`) is the app's; the Spaces sample
/// and tests bring their own.
protocol MobileFilesSource: AnyObject, Sendable {
    /// One level of the absolute folder `path` (`files.list`); `hidden` false leaves dot-names out at the source.
    func list(_ path: String, hidden: Bool) async throws -> FileListing
    /// `length` bytes from `offset` (`files.read`); a `revision` from an earlier window makes a changed file fail with
    /// `.changed` instead of mixing two versions.
    func read(_ path: String, offset: UInt64, length: UInt64, revision: FileRevision?) async throws -> (data: Data, revision: FileRevision)
    /// A read-only git command in `path` (`files.git`): a failed command answers with its status, a refused one throws.
    func git(_ path: String, args: [String], limit: UInt64) async throws -> GitOutput
}

/// A host's files through its helper's `files.*` operations (helper/PROTOCOL.md), on the connection's client. One
/// request per call and never a retry. `files.list` and `files.read` need `file.text`, `files.git` needs `git.read` (the
/// host's Files & git switch, `HelperGrant`).
final class HelperMobileFilesSource: MobileFilesSource {
    let client: HelperClient
    /// The host's name, for the offline error ("mba2 is offline").
    let host: String

    init(client: HelperClient, host: String) {
        self.client = client
        self.host = host
    }

    func list(_ path: String, hidden: Bool) async throws -> FileListing {
        do {
            let listing: Wire.Listing = try await client.connection.request("files.list", params: Wire.List(path: path, hidden: hidden))
            return listing.model
        } catch {
            throw Self.map(error, path: path, host: host)
        }
    }

    func read(_ path: String, offset: UInt64, length: UInt64, revision: FileRevision?) async throws -> (data: Data, revision: FileRevision) {
        let params = Wire.Read(path: path, offset: offset, length: length, revision: revision.map(Wire.Metadata.init))
        do {
            let reply: (result: Wire.Metadata, bytes: Data) = try await client.connection.requestBinary("files.read", params: params)
            return (reply.bytes, reply.result.model)
        } catch {
            throw Self.map(error, path: path, host: host)
        }
    }

    func git(_ path: String, args: [String], limit: UInt64) async throws -> GitOutput {
        do {
            let answer: Wire.Git = try await client.connection.request("files.git", params: Wire.GitRun(path: path, args: args, limit: limit))
            return GitOutput(status: answer.status, output: answer.output, truncated: answer.truncated)
        } catch {
            throw Self.map(error, path: path, host: host)
        }
    }

    /// The helper's codes as Files words them (the Mac's `HelperFilesSource.map`, without its local helper): a broken
    /// stream or a closed connection is the host going offline.
    static func map(_ error: any Error, path: String, host: String) -> FilesSourceError {
        if let error = error as? FilesSourceError { return error }
        if error is CancellationError { return .cancelled }
        if error is HelperWire.Failure || error is HelperBinary.Failure { return .offline(host) }
        guard let failure = error as? HelperFailure else { return .other(code: "internal", message: error.localizedDescription) }
        let detail = failure.message.isEmpty ? "The helper on \(host) failed (\(failure.code))" : failure.message
        switch failure.code {
        case "not_found": return .notFound(path)
        case "permission_denied": return .permissionDenied(path)
        case "not_directory": return .notDirectory(path)
        case "changed": return .changed(path)
        case "limit": return .limit(detail)
        case "busy": return .busy(detail)
        case "unsupported": return .unsupported(detail)
        case "unavailable", "connection_closed", "invalid_response", "offline": return .offline(host)
        case "cancelled": return .cancelled
        default: return .other(code: failure.code, message: detail)
        }
    }
}

/// The `files.*` params and results as the helper encodes them (the Mac's `HelperFilesSource` wire types, read-only
/// part). Nanosecond stamps are i128 on the helper and travel as decimal strings.
private enum Wire {
    struct List: Encodable, Sendable {
        let path: String
        let hidden: Bool
        /// 0: the helper's own bound (10,000 entries).
        var limit: UInt64 = 0
        /// Accepted and ignored by the helper: marks come from `files.git status`.
        var git = false
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
        let length: UInt64
        let revision: Metadata?
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
        let device: UInt64?
        let inode: UInt64?

        var model: FileEntry {
            FileEntry(name: name, kind: FileEntryKind(rawValue: kind) ?? .other, size: size,
                      modified: FileRevision.date(modified_ns.text), targetKind: target.map { FileEntryKind(rawValue: $0) ?? .other },
                      identity: device.flatMap { device in inode.map { FileIdentity(device: device, inode: $0) } })
        }
    }

    struct Listing: Decodable, Sendable {
        let path: String
        let entries: [Entry]
        let truncated: Bool

        var model: FileListing { FileListing(path: path, entries: entries.map(\.model), truncated: truncated) }
    }
}
