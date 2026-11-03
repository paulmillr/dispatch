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
            let listing: FilesWire.Listing = try await client.connection.request("files.list", params: FilesWire.List(path: path, hidden: hidden))
            return listing.model
        } catch {
            throw Self.map(error, path: path, host: host)
        }
    }

    func read(_ path: String, offset: UInt64, length: UInt64, revision: FileRevision?) async throws -> (data: Data, revision: FileRevision) {
        let params = FilesWire.Read(path: path, offset: offset, length: length, revision: revision)
        do {
            let reply: (result: FilesWire.Metadata, bytes: Data) = try await client.connection.requestBinary("files.read", params: params)
            return (reply.bytes, reply.result.model)
        } catch {
            throw Self.map(error, path: path, host: host)
        }
    }

    func git(_ path: String, args: [String], limit: UInt64) async throws -> GitOutput {
        do {
            let answer: FilesWire.Git = try await client.connection.request("files.git", params: FilesWire.GitRun(path: path, args: args, limit: limit))
            return GitOutput(status: answer.status, output: answer.output, truncated: answer.truncated)
        } catch {
            throw Self.map(error, path: path, host: host)
        }
    }

    /// The helper's codes as Files words them (the Mac's `HelperFilesSource.map`, without its local helper): a broken
    /// stream or a closed connection is the host going offline.
    static func map(_ error: any Error, path: String, host: String) -> FilesSourceError {
        FilesSourceFailure.map(error, path: path, context: .mobile(host: host))
    }
}
