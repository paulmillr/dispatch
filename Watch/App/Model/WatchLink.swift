import Foundation

/// The watch's side of the phone link (docs/watch.md, Architecture and data flow): the phone's latest snapshot, whether
/// the phone can be asked anything now, and one request at a time answered by one reply. `SessionWatchLink` is the
/// WatchConnectivity one; `ScriptedWatchLink` plays a deterministic phone for previews, tests and
/// `DISPATCH_WATCH_SCRIPTED`. `WatchModel` is its only user.
@MainActor
protocol WatchLink: AnyObject {
    /// The phone's latest pushed snapshot (its application context), kept by the system across launches; nil before the
    /// phone ever sent one.
    var snapshot: WatchSnapshot? { get }
    /// The phone can take a request now (`WCSession.isReachable`). The snapshot stays readable either way.
    var reachable: Bool { get }
    /// Called on the main actor after `snapshot` or `reachable` changed.
    var changed: (@MainActor () -> Void)? { get set }
    /// Starts the link (WatchConnectivity's activation). Idempotent.
    func activate()
    /// Sends `request` and waits for its reply. Throws a `WatchFailure` (`unreachable`, `timedOut`, `invalid`) when no
    /// reply arrives; a failure the phone reports comes back as a reply with `.failure`.
    func request(_ request: WatchRequest) async throws -> WatchReply
}
