import Foundation
import MobileTransport

// Every mapping of a host's connection state lives here: the transport's reconnect state machine to the Hosts area's
// `HostLink` (one to one, docs/ios.md, Transport), and `HostLink` to what the Spaces tab draws.

extension HostLink {
    /// The transport's state as the host session shows it.
    init(_ state: MobileTransport.HostConnectionState) {
        switch state {
        case .disconnected: self = .disconnected
        case .connecting: self = .connecting
        case .authenticating: self = .authenticating
        case .bootstrapping: self = .bootstrapping
        case .connected: self = .connected
        case .reconnecting(let attempt, let since, let reason): self = .reconnecting(attempt: attempt, since: since, reason: reason)
        case .failed(let reason): self = .failed(reason)
        }
    }
}

extension SpacesHostState {
    /// Connected; on its way (connecting, logging in, starting the helper, reconnecting); or offline (disconnected,
    /// failed), when the last-known spaces stay listed.
    init(_ link: HostLink) {
        switch link {
        case .connected: self = .connected
        case .connecting, .authenticating, .bootstrapping, .reconnecting: self = .connecting
        case .disconnected, .failed: self = .offline
        }
    }
}
