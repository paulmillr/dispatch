import Foundation

/// A `multiplexers.list` row. The optional fields require the `multiplexers.versions` hello feature; older helpers
/// omit them. `running` describes the account's server without starting one. An absent value remains unknown.
struct HelperMultiplexer: Decodable, Equatable, Sendable {
    let mux: UInt64
    let name: String
    let external: Bool
    var program: String? = nil
    var installed: Bool? = nil
    var version: String? = nil
    var paste_state: Bool? = nil
    var running: Bool? = nil
}
