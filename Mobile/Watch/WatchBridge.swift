import Foundation
import Observation
import UIKit
import WatchConnectivity
import os

/// What the bridge needs of `WCSession`: its state and the two sends. `WCSession` in the app, `ScriptedWatchSession` in
/// tests.
@MainActor protocol WatchSessioning: AnyObject {
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    var isReachable: Bool { get }
    var activationState: WCSessionActivationState { get }
    /// Sets the delegate, then activates (again after `sessionDidDeactivate`).
    func activate(delegate: any WCSessionDelegate)
    func updateApplicationContext(_ context: [String: Any]) throws
    /// A message that expects no reply.
    func sendMessage(_ message: [String: Any], failed: @escaping @Sendable (any Error) -> Void)
}

extension WCSession: WatchSessioning {
    func activate(delegate: any WCSessionDelegate) {
        self.delegate = delegate
        activate()
    }

    func sendMessage(_ message: [String: Any], failed: @escaping @Sendable (any Error) -> Void) {
        sendMessage(message, replyHandler: nil, errorHandler: failed)
    }
}

/// The Settings row's state (`WCSession.isPaired`, `isWatchAppInstalled`).
enum WatchPairing: Equatable, Sendable {
    case notPaired, notInstalled, installed

    var label: String {
        switch self {
        case .notPaired: "Not paired"
        case .notInstalled: "Not installed"
        case .installed: "Installed"
        }
    }
}

/// What Settings observes of the bridge.
@MainActor @Observable final class WatchBridgeStatus {
    var pairing: WatchPairing = .notPaired
}

/// The phone's side of WatchConnectivity (docs/watch.md, The bridge): made and kept by `MobileComposition.app()`. It
/// activates the session at once (a message that wakes the app reaches only an activated session with its delegate
/// set), pushes the snapshot whenever what it shows changes, and serves the watch's requests through
/// `WatchRequestServer`. Nothing is sent while no watch with the app installed is paired.
@MainActor
final class WatchBridge: NSObject {
    let status = WatchBridgeStatus()
    /// Changes come together (a sync touches several hosts and rows): one build per `debounce` at most.
    var debounce: Duration = .seconds(1)
    /// How long a request may take before the watch is answered `timedOut` (it gives up at `WatchLimits.replyTimeout`).
    var budget: Duration = WatchLimits.phoneBudget
    /// Protected data is available (the phone is unlocked); the notifications keep it. Only `WatchPhone.locked`
    /// reads it: a locked phone still serves requests (docs/watch.md, Background).
    private(set) var protectedDataAvailable: Bool
    /// The last snapshot handed to the session, `generated` cleared: an equal one is not sent again.
    private(set) var pushed: WatchSnapshot?
    /// The last snapshot built, before fitting (requests answer with a fresh one).
    private(set) var built: WatchSnapshot?
    /// Why the latest push sent nothing (logged when it changes).
    private(set) var skipped: String?

    private weak var composition: MobileComposition?
    private let session: any WatchSessioning
    private let server: WatchRequestServer
    private let clock: () -> Date
    /// Begins a background task named so; the closure returned ends it (once).
    private let backgroundTask: @MainActor (String) -> @MainActor () -> Void
    /// The background time the system still grants (`backgroundTimeRemaining`; `.greatestFiniteMagnitude` in the
    /// foreground).
    private let backgroundRemaining: @MainActor () -> TimeInterval
    private var pending: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []
    private nonisolated static let log = Logger(subsystem: "yachts.dispatch.mobile", category: "Watch")

    /// Nil where WatchConnectivity is unsupported (an iPad).
    static func app(_ composition: MobileComposition) -> WatchBridge? {
        guard WCSession.isSupported() else { return nil }
        return WatchBridge(composition: composition, session: WCSession.default,
                           protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable)
    }

    init(composition: MobileComposition, session: any WatchSessioning, protectedDataAvailable: Bool = true,
         clock: @escaping () -> Date = Date.init,
         backgroundTask: @escaping @MainActor (String) -> @MainActor () -> Void = WatchBridge.applicationBackgroundTask,
         backgroundRemaining: @escaping @MainActor () -> TimeInterval = { UIApplication.shared.backgroundTimeRemaining }) {
        self.composition = composition
        self.session = session
        self.protectedDataAvailable = protectedDataAvailable
        self.clock = clock
        self.backgroundTask = backgroundTask
        self.backgroundRemaining = backgroundRemaining
        let hosts = composition.hosts
        server = WatchRequestServer(composition: composition, hold: { [weak hosts] id in
            guard let hosts else { return }
            let before = hosts.session(id).map { "\($0.link)" } ?? "none", started = ContinuousClock.now
            await hosts.hold(id)
            let after = hosts.session(id).map { "\($0.link)" } ?? "none"
            Self.log.info("Hold \(Self.short(id), privacy: .public) (\(hosts.active ? "foreground" : "background", privacy: .public)): \(before, privacy: .public) → \(after, privacy: .public) in \(Self.milliseconds(since: started)) ms\(hosts.isHeld(id) ? ", held" : "", privacy: .public)")
        })
        super.init()
        // Synchronously, before anything else: a request that launched the app is delivered once this returns.
        session.activate(delegate: self)
        updateStatus()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.protectedData(available: false) }
            },
            center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.protectedData(available: true) }
            },
        ]
        // Builds once, arming the observation; sent once the session is activated.
        push(reason: "launch")
    }

    isolated deinit {
        pending?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Snapshot

    /// The snapshot as the phone shows it now.
    func buildSnapshot() -> WatchSnapshot {
        guard let composition else { return WatchSnapshot(generated: clock(), phone: WatchPhone(), hosts: []) }
        let snapshot = WatchSnapshotBuilder(composition: composition, protectedDataAvailable: protectedDataAvailable).build(at: clock())
        built = snapshot
        return snapshot
    }

    /// Builds the snapshot inside `withObservationTracking`, so the next change of anything it read schedules the next
    /// push, and sends it unless it equals the last one sent. `force`: send even then (the watch app just became
    /// reachable and gets it as a message at once).
    func push(reason: String, force: Bool = false) {
        pending?.cancel()
        pending = nil
        let snapshot = withObservationTracking { buildSnapshot() } onChange: { [weak self] in
            // Called before the change is made: the build waits for the debounce.
            Task { @MainActor in self?.schedule() }
        }
        logHostChanges(snapshot)
        let fitted = WatchCodec.fit(snapshot)
        Self.log.debug("Snapshot built (\(reason, privacy: .public)): \(fitted.hosts.count) hosts, \(fitted.conversations.count) conversations, \(fitted.spaces.count) spaces, \(fitted.tabs.count) tabs\(fitted.truncated ? ", truncated" : "", privacy: .public)")
        send(fitted, reason: reason, force: force)
    }

    /// Each host's state as last built, to log what changed (a hold that connected or expired).
    private var hostStates: [String: WatchHostState] = [:]

    private func logHostChanges(_ snapshot: WatchSnapshot) {
        for host in snapshot.hosts where hostStates[host.id] != host.state {
            let before = hostStates[host.id]?.rawValue ?? "new"
            Self.log.info("Host \(host.id.prefix(8), privacy: .public): \(before, privacy: .public) → \(host.state.rawValue, privacy: .public)")
            hostStates[host.id] = host.state
        }
    }

    nonisolated static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    nonisolated static func seconds(_ duration: Duration) -> String {
        String(format: "%.1f", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    nonisolated static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// The next push, `debounce` from the first change since the last one.
    private func schedule() {
        guard pending == nil else { return }
        let debounce = debounce
        pending = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.push(reason: "change")
        }
    }

    private func send(_ snapshot: WatchSnapshot, reason: String, force: Bool) {
        var comparable = snapshot
        comparable.generated = .distantPast
        if !force, comparable == pushed { return skip("unchanged") }
        guard session.activationState == .activated else { return skip("session not activated") }
        guard session.isPaired else { return skip("no watch paired") }
        guard session.isWatchAppInstalled else { return skip("watch app not installed") }
        let message: [String: Any]
        do {
            message = try WatchCodec.message(snapshot)
            try session.updateApplicationContext(message)
        } catch {
            Self.log.error("Snapshot push failed (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return
        }
        pushed = comparable
        skipped = nil
        let reachable = session.isReachable
        Self.log.info("Snapshot pushed (\(reason, privacy: .public)): \(snapshot.hosts.count) hosts, \(snapshot.conversations.count) conversations, \(WatchCodec.size(snapshot)) bytes\(reachable ? ", also as a message" : "", privacy: .public)")
        // The watch app is running: a message arrives sooner than the context.
        if reachable {
            session.sendMessage(message) { error in
                Self.log.error("Snapshot message failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func skip(_ why: String) {
        guard skipped != why else { return }
        skipped = why
        Self.log.notice("Snapshot not pushed: \(why, privacy: .public)")
    }

    /// The scene's phase changed (`MobileComposition.scenePhaseChanged`): `phone.foreground` may have changed, and the app
    /// may be suspended soon.
    func scenePhaseChanged() { push(reason: "scene phase") }

    func protectedData(available: Bool) {
        protectedDataAvailable = available
        push(reason: available ? "unlocked" : "locking")
    }

    // MARK: Session state

    private func updateStatus() {
        let pairing: WatchPairing = !session.isPaired ? .notPaired : session.isWatchAppInstalled ? .installed : .notInstalled
        if status.pairing != pairing { status.pairing = pairing }
    }

    func activated(_ state: WCSessionActivationState, error: (any Error)?) {
        if let error { Self.log.error("Activation failed: \(error.localizedDescription, privacy: .public)") }
        updateStatus()
        if state == .activated { push(reason: "activated") }
    }

    /// Paired, unpaired, the app installed or removed: what was pushed before may not be there.
    func watchStateChanged() {
        updateStatus()
        pushed = nil
        push(reason: "watch state")
    }

    func reachabilityChanged() {
        guard session.isReachable else { return }
        push(reason: "reachable", force: true)
    }

    /// The user switched watches: the session activates again for the new one.
    func deactivated() {
        pushed = nil
        session.activate(delegate: self)
    }

    // MARK: Requests

    /// One request from the watch: decoded, served by `WatchRequestServer` within `budget`, answered.
    /// The app may be in the background (woken by the message): a background task keeps it running meanwhile.
    func received(_ data: Data?, reply: @escaping @Sendable ([String: Any]) -> Void) {
        let end = backgroundTask("Watch request")
        Task {
            let answer = await self.answer(data)
            reply((try? WatchCodec.message(answer)) ?? [:])
            end()
        }
    }

    /// The reply to a request's bytes.
    func answer(_ data: Data?) async -> WatchReply {
        guard let data else { return WatchReply(id: "", .failure(.invalid)) }
        let request: WatchRequest
        do {
            request = try WatchCodec.decode(WatchRequest.self, from: data)
        } catch {
            // Answered with its id when at least that reads.
            let id = (try? WatchCodec.decode(Envelope.self, from: data))?.id ?? ""
            Self.log.error("Request does not decode: \(error.localizedDescription, privacy: .public)")
            return WatchReply(id: id, .failure(.invalid))
        }
        // The version is the server's to judge; a kind this build does not know is not.
        if case .unknown(let kind) = request.action {
            Self.log.notice("Unsupported request kind \(kind, privacy: .public)")
            return WatchReply(id: request.id, .failure(.unsupported))
        }
        let state = UIApplication.shared.applicationState
        Self.log.info("Request \(request.action.kind, privacy: .public) \(request.id.prefix(8), privacy: .public) received (app \(state == .active ? "active" : state == .background ? "in the background" : "inactive", privacy: .public))")
        let started = ContinuousClock.now
        let reply = await serve(request)
        // The failure's words may name a host: private.
        let (code, words) = if case .failure(let failure) = reply.result { (" " + failure.code.rawValue, failure.message) } else { ("", "") }
        Self.log.info("Answered \(request.action.kind, privacy: .public) \(request.id.prefix(8), privacy: .public) with \(reply.result.kind, privacy: .public)\(code, privacy: .public) in \(Self.milliseconds(since: started)) ms \(words, privacy: .private)")
        return reply
    }

    /// What a request may take now: `budget`, or less when the system grants less background time (a phone app the
    /// message woke had 14 s left on the simulator, under the 15 s budget): the reply goes before the app is suspended.
    /// Nil: the full budget.
    nonisolated static func budget(_ budget: Duration, remaining: TimeInterval) -> Duration? {
        guard remaining < 1e6 else { return nil }
        let granted = Duration.milliseconds(Int(max(remaining - 1.5, 0.5) * 1000))
        return granted < budget ? granted : nil
    }

    private func serve(_ request: WatchRequest) async -> WatchReply {
        let server = server
        let race = Race<WatchReply>()
        let short = Self.budget(budget, remaining: backgroundRemaining())
        if let short { Self.log.notice("Request \(request.action.kind, privacy: .public) has \(Self.seconds(short)) s of background time") }
        return await withCheckedContinuation { continuation in
            race.start(continuation)
            race.tasks.append(Task {
                // Shortened, the server answers with what it has a little before the bridge would time out, as it
                // does under the full budget.
                let within = short.map { max($0 - .seconds(2), $0 / 2) }
                let reply = await server.serve(request, within: within, snapshot: { self.buildSnapshot() })
                race.finish(reply)
            })
            let budget = short ?? budget
            race.tasks.append(Task {
                try? await Task.sleep(for: budget)
                if race.finish(WatchReply(id: request.id, .failure(.timedOut))) {
                    Self.log.notice("Request \(request.action.kind, privacy: .public) timed out")
                }
            })
        }
    }

    private struct Envelope: Decodable { let id: String }

    /// `UIApplication.beginBackgroundTask`, ended by the returned closure or by the system's expiration, once.
    static func applicationBackgroundTask(_ name: String) -> @MainActor () -> Void {
        let task = BackgroundTaskEnd()
        task.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            log.notice("Background task \(name, privacy: .public) expired")
            MainActor.assumeIsolated { task.end() }
        }
        let remaining = UIApplication.shared.backgroundTimeRemaining
        log.debug("Background task \(name, privacy: .public) \(task.identifier.rawValue) began (\(remaining > 1e6 ? "foreground" : "\(Int(remaining)) s left", privacy: .public))")
        return {
            log.debug("Background task \(name, privacy: .public) \(task.identifier.rawValue) ended")
            task.end()
        }
    }
}

/// A background task identifier ended once.
@MainActor private final class BackgroundTaskEnd {
    var identifier: UIBackgroundTaskIdentifier = .invalid
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// The first of several results on the main actor; the tasks racing for it are cancelled then (the server's wait for a
/// host after the budget, the timer after a reply).
@MainActor private final class Race<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var done = false
    var tasks: [Task<Void, Never>] = []

    func start(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }

    /// False when another result came first.
    @discardableResult
    func finish(_ value: Value) -> Bool {
        guard !done else { return false }
        done = true
        continuation?.resume(returning: value)
        continuation = nil
        for task in tasks { task.cancel() }
        return true
    }
}

extension WatchBridge: WCSessionDelegate {
    // Callbacks arrive on the session's own serial queue; each hops to the main queue in order (a `Task` per callback
    // could reorder them).

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        onMain { $0.activated(state, error: error) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        onMain { $0.deactivated() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        onMain { $0.watchStateChanged() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        onMain { $0.reachabilityChanged() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let data = message[WatchCodec.key] as? Data
        let reply = ReplyHandler(replyHandler)
        onMain { $0.received(data) { reply.send($0) } }
    }

    /// The watch sends nothing without a reply handler in protocol 1: ignored.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {}

    private nonisolated func onMain(_ body: @escaping @MainActor @Sendable (WatchBridge) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                body(self)
            }
        }
    }
}

/// WatchConnectivity's reply handler, called once from the main actor.
private final class ReplyHandler: @unchecked Sendable {
    private let handler: ([String: Any]) -> Void
    init(_ handler: @escaping ([String: Any]) -> Void) { self.handler = handler }
    func send(_ reply: [String: Any]) { handler(reply) }
}
