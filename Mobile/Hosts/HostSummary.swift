import SwiftUI

/// What the host screens say about a session: Spaces' host tint and host detail's status and spaces (M1f), derived in
/// one place so the screens and the tests agree.
@MainActor
struct HostSummary {
    let session: HostSession

    var host: HostRecord { session.host }
    var connected: Bool { session.link.isConnected }

    /// Offline (gray) only when no connection is up or on its way: a connecting host keeps its colour.
    var offline: Bool {
        switch session.link {
        case .disconnected, .failed: true
        default: false
        }
    }

    var tint: Color { offline ? Color(uiColor: .systemGray) : host.tint.color }

    /// The helper's `os_label` ("macOS 26.1", "Ubuntu 24.04"), live or as last saved.
    var osLabel: String? { session.hello?.identity.map(HostRecord.osLabel) ?? host.osLabel ?? host.system?.label }

    /// The transport word in the status line. The connection is SSH with reconnect and reattach; the copy keeps the
    /// mockup's "mosh" until a mosh client is decided after v1.
    static let transport = "mosh"

    /// M1f's status line: "Connected · mosh · 38 ms".
    var status: String {
        switch session.link {
        case .connected:
            var parts = ["Connected", Self.transport]
            if let latency = session.latency { parts.append(Self.milliseconds(latency)) }
            return parts.joined(separator: " · ")
        case .connecting: return "Connecting…"
        case .authenticating: return "Logging in…"
        case .bootstrapping: return "Starting the helper…"
        case .reconnecting where session.networkUnavailable: return "Waiting for the network…"
        case .reconnecting(let attempt, _, _): return attempt > 1 ? "Reconnecting · attempt \(attempt)" : "Reconnecting…"
        case .failed(let reason): return session.hostKeyMismatch != nil ? "Host key changed" : reason
        case .disconnected: return "Offline"
        }
    }

    /// Why it is not connected yet, under the status (`HostSession.problem`).
    var problem: String? { session.problem }

    var statusColor: Color {
        switch session.link {
        case .connected: .stateConnected
        case .failed: session.hostKeyMismatch != nil ? .red : Color(uiColor: .systemGray)
        case .disconnected: Color(uiColor: .systemGray)
        default: .stateWorking
        }
    }

    /// "38 ms"; under 10 ms with one decimal ("0.2 ms" over loopback).
    static func milliseconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        let value = Double(seconds) * 1000 + Double(attoseconds) / 1e15
        return value < 10 ? String(format: "%.1f ms", max(value, 0.1)) : "\(Int(value.rounded())) ms"
    }

    /// The spaces of the topology (workspace nodes), each with the folder its first terminal is in.
    struct Space: Identifiable, Equatable {
        let id: UInt64
        let name: String
        let folder: String?
    }

    var spaces: [Space] {
        guard let topology = session.topology else { return [] }
        let nodes = topology.nodes.filter { !$0.detached }
        let homes = HomePath(session.hello)
        func folder(under id: UInt64) -> String? {
            for child in nodes where child.parent == id {
                if let cwd = child.cwd { return cwd }
                if let found = folder(under: child.id) { return found }
            }
            return nil
        }
        return nodes.filter { $0.kind == .workspace }.map { node in
            Space(id: node.id, name: node.name, folder: (node.cwd ?? folder(under: node.id)).map { homes.abbreviate($0) })
        }
    }

}

/// Opens one of a host's spaces from Host detail (Tabs owns the space screens). Rows show no chevron without it.
@MainActor protocol HostSpaceOpening: AnyObject {
    func open(host: UUID, space: UInt64)
}

extension EnvironmentValues {
    @Entry var hostSpaceOpening: (any HostSpaceOpening)? = nil
}
