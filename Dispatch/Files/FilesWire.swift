import Foundation

/// Shared read-only `files.*` payloads (helper/PROTOCOL.md). Integer identities and sizes stay UInt64;
/// i128 nanosecond timestamps travel as decimal strings, accepting integer replies from older helpers.
enum FilesWire {
    struct List: Encodable, Sendable {
        let path: String
        let hidden: Bool
        /// 0: the helper's own bound (10,000 entries).
        var limit: UInt64 = 0
        /// Git marks are reserved for the git tabs; step one never asks for them.
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
        /// Absent reads to the end.
        let length: UInt64?
        let revision: Metadata?

        init(path: String, offset: UInt64, length: UInt64?, revision: FileRevision?) {
            self.path = path
            self.offset = offset
            self.length = length
            self.revision = revision.map(Metadata.init)
        }
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
        /// On the wire, never set: the Files list shows nothing of git.
        let mark: String?
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
        let device: UInt64?
        let inode: UInt64?

        var model: FileListing {
            FileListing(path: path, entries: entries.map(\.model), truncated: truncated,
                        identity: device.flatMap { device in inode.map { FileIdentity(device: device, inode: $0) } })
        }
    }
}
