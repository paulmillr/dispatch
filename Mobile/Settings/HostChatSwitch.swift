import Foundation

extension HelperTopology {
    /// The snapshot without agent bindings: what Spaces and Agents see of a host with Chat off (its agents are
    /// terminals only). Nodes keep every other field as the helper sent it.
    func withoutAgents() -> HelperTopology {
        guard nodes.contains(where: { $0.agent != nil }),
              let data = try? JSONEncoder().encode(self),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodes = object["nodes"] as? [[String: Any]] else { return self }
        object["nodes"] = nodes.map { node in
            var node = node
            node.removeValue(forKey: "agent")
            return node
        }
        guard let stripped = try? JSONSerialization.data(withJSONObject: object),
              let topology = try? JSONDecoder().decode(HelperTopology.self, from: stripped) else { return self }
        return topology
    }
}

/// What the areas see of each host's topology: as the helper sent it, without agents for a host with Chat off, and none
/// for a plain SSH host (`HostSession.plainSSH`: its spaces are never a server's, and Agents has nothing of it, even a
/// cached snapshot from when it had its helper). The stripped snapshot is kept per host, so a sync that changes nothing
/// costs nothing.
@MainActor
final class HostTopologies {
    private var stripped: [UUID: (source: HelperTopology, result: HelperTopology)] = [:]

    func topology(_ session: HostSession) -> HelperTopology? {
        guard !session.plainSSH, let topology = session.topology else {
            stripped[session.id] = nil
            return nil
        }
        guard !session.host.chat else {
            stripped[session.id] = nil
            return topology
        }
        if let cached = stripped[session.id], cached.source == topology { return cached.result }
        let result = topology.withoutAgents()
        stripped[session.id] = (topology, result)
        return result
    }

    func forget(_ host: UUID) { stripped[host] = nil }
}
