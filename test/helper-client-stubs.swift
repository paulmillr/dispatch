import Foundation
// Out-of-app builds of the helper client (fixture recording, probe): the app types HelperApp names.
struct SSHConnectionID: Hashable, Sendable { let id = UUID() }
enum HelperWorkspace {
    enum Endpoint: Hashable, Sendable {
        case local
        case remote(SSHConnectionID)
        var connection: SSHConnectionID? { if case .remote(let id) = self { id } else { nil } }
    }
}
