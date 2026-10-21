#if canImport(WatchConnectivity)
import Foundation
import Synchronization
import WatchConnectivity
import os

/// The watch's link over WatchConnectivity (`WCSession.default`), the counterpart of the phone's `WatchBridge`
/// (docs/watch.md, Architecture and data flow):
///
/// - The snapshot is the phone's application context (`WatchCodec.key` holding `WatchSnapshot` bytes): read from
///   `receivedApplicationContext` at activation (the system keeps the last one across launches), then from each
///   `didReceiveApplicationContext`. A message carrying a snapshot (the phone may push one while the watch app is
///   reachable, for less delay than the context) is taken the same way.
/// - A request is one `sendMessage` with a reply handler: the system wakes the phone app in the background if needed.
///   No reply within `WatchLimits.replyTimeout` fails `timedOut`; an unreachable phone fails at once.
/// - Delegate callbacks arrive on a background queue; each hops to the main queue in arrival order (a `Task` per
///   callback could reorder two contexts), where the link's state lives.
@MainActor
final class SessionWatchLink: NSObject, WatchLink {
    private(set) var snapshot: WatchSnapshot?
    private(set) var reachable = false
    var changed: (@MainActor () -> Void)?

    /// Nil where WatchConnectivity is unsupported: nothing is ever reachable.
    private let session: WCSession?
    private let timeout: Duration
    /// `log stream --predicate 'subsystem == "yachts.dispatch.watch"'` on the watch simulator (docs/watch.md, Testing).
    nonisolated static let log = Logger(subsystem: "yachts.dispatch.watch", category: "Link")

    init(session: WCSession? = WCSession.isSupported() ? .default : nil, timeout: Duration = WatchLimits.replyTimeout) {
        self.session = session
        self.timeout = timeout
        super.init()
    }

    func activate() {
        guard let session, session.delegate !== self else { return }
        Self.log.debug("Activating")
        session.delegate = self
        session.activate()
    }

    func request(_ request: WatchRequest) async throws -> WatchReply {
        guard let session, session.activationState == .activated, session.isReachable else {
            Self.log.notice("Request \(request.action.kind, privacy: .public) not sent: phone unreachable")
            throw WatchFailure.unreachable
        }
        let message = try WatchCodec.message(request)
        let started = ContinuousClock.now
        Self.log.info("Request \(request.action.kind, privacy: .public) \(request.id.prefix(8), privacy: .public) sent")
        let pending = PendingReply()
        let data: Data
        do {
            data = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pending.start(continuation)
                    Self.send(message, on: session, to: pending)
                    let timeout = timeout
                    pending.timer = Task {
                        try? await Task.sleep(for: timeout)
                        pending.finish(.failure(WatchFailure.timedOut))
                    }
                }
            } onCancel: {
                pending.finish(.failure(CancellationError()))
            }
        } catch {
            Self.log.error("Request \(request.action.kind, privacy: .public) \(request.id.prefix(8), privacy: .public) failed after \(Self.milliseconds(since: started)) ms: \(String(describing: error), privacy: .public)")
            throw error
        }
        do {
            let reply = try WatchCodec.decode(WatchReply.self, from: data)
            let code = if case .failure(let failure) = reply.result { " " + failure.code.rawValue } else { "" }
            Self.log.info("Reply to \(request.action.kind, privacy: .public) \(request.id.prefix(8), privacy: .public): \(reply.result.kind, privacy: .public)\(code, privacy: .public), \(data.count) bytes in \(Self.milliseconds(since: started)) ms")
            return reply
        } catch {
            Self.log.error("Reply to \(request.action.kind, privacy: .public) does not decode: \(error.localizedDescription, privacy: .public)")
            throw WatchFailure.invalid
        }
    }

    /// The handlers are formed here, outside the main actor: WatchConnectivity calls them on its own queue, and a
    /// closure formed in a main-actor method is main-actor isolated, which Swift 6 checks at run time (the first reply
    /// trapped, "Block was expected to execute on queue com.apple.main-thread").
    private nonisolated static func send(_ message: [String: Any], on session: WCSession, to pending: PendingReply) {
        session.sendMessage(message, replyHandler: { reply in
            if let data = reply[WatchCodec.key] as? Data { pending.finish(.success(data)) }
            else { pending.finish(.failure(WatchFailure.invalid)) }
        }, errorHandler: { error in
            pending.finish(.failure(failure(error)))
        })
    }

    private nonisolated static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// WatchConnectivity's errors in the watch's words.
    nonisolated static func failure(_ error: any Error) -> WatchFailure {
        switch (error as? WCError)?.code {
        case .notReachable?, .deviceNotPaired?, .companionAppNotInstalled?, .sessionNotActivated?: .unreachable
        case .messageReplyTimedOut?: .timedOut
        case .messageReplyFailed?: WatchFailure(.failed, "Dispatch on your iPhone couldn't answer.")
        default: WatchFailure(.failed, error.localizedDescription)
        }
    }

    /// The snapshot in `data`, unless it is older than the one shown (a late context after a newer reply).
    private func receive(_ data: Data?) {
        guard let data else { return }
        guard let next = try? WatchCodec.decode(WatchSnapshot.self, from: data) else {
            return Self.log.error("Snapshot does not decode (\(data.count) bytes)")
        }
        if let snapshot, snapshot.generated > next.generated { return }
        guard next != snapshot else { return }
        Self.log.info("Snapshot from \(next.generated.formatted(.iso8601), privacy: .public): \(next.hosts.count) hosts, \(next.conversations.count) conversations, \(next.spaces.count) spaces, \(next.tabs.count) tabs")
        // The keys `-DispatchWatchOpen <host>/<node>` takes.
        Self.log.debug("Conversations: \(next.conversations.map { "\($0.host)/\($0.node)" }.joined(separator: " "), privacy: .public)")
        snapshot = next
        changed?()
    }

    private func update(reachable: Bool) {
        guard reachable != self.reachable else { return }
        Self.log.info("Phone \(reachable ? "reachable" : "unreachable", privacy: .public)")
        self.reachable = reachable
        changed?()
    }

    /// Runs `body` on the main actor after the callbacks queued before it.
    private nonisolated func onMain(_ body: @escaping @MainActor @Sendable (SessionWatchLink) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                body(self)
            }
        }
    }
}

extension SessionWatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        let context = session.receivedApplicationContext[WatchCodec.key] as? Data
        let reachable = state == .activated && session.isReachable
        Self.log.info("Activated: state \(state.rawValue), reachable \(reachable), companion installed \(session.isCompanionAppInstalled), context \(context?.count ?? 0) bytes\(error.map { ", error: \($0.localizedDescription)" } ?? "", privacy: .public)")
        onMain { link in
            link.receive(context)
            link.update(reachable: reachable)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        onMain { $0.update(reachable: reachable) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let data = applicationContext[WatchCodec.key] as? Data
        Self.log.debug("Application context received (\(data?.count ?? 0) bytes)")
        onMain { $0.receive(data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let data = message[WatchCodec.key] as? Data
        Self.log.debug("Snapshot message received (\(data?.count ?? 0) bytes)")
        onMain { $0.receive(data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        // The phone asks the watch nothing in protocol 1: answer at once so its handler never waits.
        let data = message[WatchCodec.key] as? Data
        replyHandler([:])
        onMain { $0.receive(data) }
    }
}

/// One request's reply, resumed exactly once: by the reply, the error handler, the timeout or cancellation, whichever
/// comes first (WatchConnectivity calls its handlers on its own queue). A result that comes before `start` (a request
/// cancelled before it was sent) is kept for it.
private final class PendingReply: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Data, any Error>?
        var timer: Task<Void, Never>?
        var result: Result<Data, any Error>?
    }
    private let state = Mutex(State())

    func start(_ continuation: CheckedContinuation<Data, any Error>) {
        let result = state.withLock { value -> Result<Data, any Error>? in
            guard let result = value.result else {
                value.continuation = continuation
                return nil
            }
            return result
        }
        if let result { continuation.resume(with: result) }
    }

    /// The timeout's task, cancelled once a result is in.
    var timer: Task<Void, Never>? {
        get { state.withLock { $0.timer } }
        set {
            let finished = state.withLock { value in
                value.timer = newValue
                return value.result != nil
            }
            if finished { newValue?.cancel() }
        }
    }

    func finish(_ result: Result<Data, any Error>) {
        let (continuation, timer) = state.withLock { value -> (CheckedContinuation<Data, any Error>?, Task<Void, Never>?) in
            guard value.result == nil else { return (nil, nil) }
            value.result = result
            defer { value.continuation = nil }
            return (value.continuation, value.timer)
        }
        timer?.cancel()
        continuation?.resume(with: result)
    }
}
#endif
