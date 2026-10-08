import Foundation

/// Common discovery data. Its route is opaque and its label comes from the helper.
struct HelperBackend: Codable, Equatable, Sendable {
  let mux: UInt64
  let key: String
  let label: String
  let isDefault: Bool?

  enum CodingKeys: String, CodingKey {
    case mux, key, label
    case isDefault = "default"
  }

  struct Route: Codable, Hashable, Sendable {
    let mux: UInt64
    let key: String
  }

  var route: Route { Route(mux: mux, key: key) }
}
