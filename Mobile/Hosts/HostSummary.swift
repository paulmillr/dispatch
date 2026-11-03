import SwiftUI

/// What the host screens say about a session: Spaces' host tint and the host's status (M1f's words), derived in one place
/// so the screens and the tests agree.
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

    static let plainSSH = "Plain SSH"

    /// The fallback can be made permanent ("Use plain SSH" on the stats' plain card, which turns the Helper switch
    /// off): the switch is on and this connection is plain.
    var offersPlainSSH: Bool { host.helper && session.isPlain }

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
}

extension HostSession {
    /// Plain SSH (docs/ios.md): by choice (the host's Helper switch is off) or on this connection (the helper could
    /// not start). Agents, background refresh and the watch leave such a host out; Spaces marks it.
    var plainSSH: Bool { !host.helper || isPlain }
}
