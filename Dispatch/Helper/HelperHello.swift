import Foundation

/// A client's opt-in protocol features. Each platform supplies its own list; grants are separate.
struct HelperHello: Encodable, Sendable {
    let features: [String]

    enum Failure: Error, Equatable {
        case protocolVersion, transportLimits
    }

    /// The hello's required transport settings, validated before configuring a connection. The connection still
    /// checks the actual frame/chunk bounds, so malformed limits keep their transport error and handling.
    struct Transport: Equatable, Sendable {
        let limit: UInt32
        let chunkKind: UInt8
        let chunkLimit: UInt32
        let ops: [String]

        init(version: UInt64, expectedVersion: UInt64, limit: UInt32?, chunkKind: UInt8?, chunkLimit: UInt32?,
             ops: [String]) throws {
            guard version == expectedVersion else { throw Failure.protocolVersion }
            guard let limit, let chunkKind, let chunkLimit else { throw Failure.transportLimits }
            self.limit = limit
            self.chunkKind = chunkKind
            self.chunkLimit = chunkLimit
            self.ops = ops
        }
    }
}
