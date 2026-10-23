import Foundation
import Observation
import Synchronization
import SwiftUI

/// A host key waiting for the user (the trust-on-first-use sheet).
struct HostTrustRequest: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Never seen: Trust or Cancel.
        case unknown
        /// Differs from the key trusted before: a hard stop, offering Remove and retry.
        case mismatch(trusted: KnownHostStore.Entry)
    }

    let id = UUID()
    let hostID: UUID
    let hostName: String
    let offer: HostKeyOffer
    let kind: Kind
}

/// A keyboard-interactive round waiting for the user (`HostLoginPromptSheet`).
struct HostLoginPrompt: Identifiable, Equatable, Sendable {
    let id = UUID()
    let hostID: UUID
    let hostName: String
    let challenge: HostLoginChallenge
}

/// What the host sheets ask, oldest first: a host key, else a login prompt.
enum HostQuestion: Identifiable, Equatable {
    case trust(HostTrustRequest)
    case login(HostLoginPrompt)
    var id: UUID {
        switch self {
        case .trust(let request): request.id
        case .login(let prompt): prompt.id
        }
    }
}

/// Why a quiet connection (a watch request's hold in the background, docs/watch.md, Background) stopped short: only
/// the phone's screen can get past it.
enum HostQuietRefusal: Equatable, Sendable {
    /// The key needs Face ID (`SecretVaultError.interactionNotAllowed`).
    case faceID
    /// The host key is not trusted yet: the trust sheet would have asked.
    case hostKey
    /// The server asked a keyboard-interactive round.
    case login
}

/// Every stored host's session (docs/ios.md, Areas and seams): one per host, connected while the app is in the foreground
/// and disconnected in the background. Also the stores the host screens edit, and the host key questions.
@MainActor @Observable
final class HostSessions {
    let store: HostStore
    let keys: KeyStore
    let knownHosts: KnownHostStore
    @ObservationIgnored let driver: any HostSessionDriver
    /// Steps every session runs after each connection is ready, in order. The transport integration adds Pi's
    /// `installation.install {launch, enabled: true}` here (the helper keeps that state per connection).
    @ObservationIgnored var postConnect: [HostPostConnectStep] = [] {
        didSet { for case let session? in sessionOf.values.map(\.session) { session.postConnect = postConnect } }
    }
    /// Called on the main actor whenever a saved host or its session changed (the composition root syncs the areas).
    @ObservationIgnored var changed: (() -> Void)?
    /// The helper's command line per host: the grant, and in Debug test runs a private environment
    /// (`DISPATCH_MOBILE_HOST_ENV`, docs/ios.md, Testing).
    @ObservationIgnored var launch: (HostRecord) -> HelperLaunch = { _ in HelperLaunch() }
    /// Called when a session's client goes away (`HostSession.clientEnded`); the integration stops the host's terminal
    /// presences here.
    @ObservationIgnored var clientEnded: ((HostSession) -> Void)? {
        didSet { for case let session? in sessionOf.values.map(\.session) { session.clientEnded = clientEnded } }
    }
    /// Where every session's shell tabs keep their presences (the composition's `TerminalPresences`).
    @ObservationIgnored var presences: TerminalPresences = .shared {
        didSet { for case let session? in sessionOf.values.map(\.session) { session.shells.presences = presences } }
    }

    private(set) var sessions: [UUID: HostSession] = [:]
    /// Waiting host key questions, oldest first; the sheet shows the first.
    private(set) var trustRequests: [HostTrustRequest] = []
    /// Waiting keyboard-interactive rounds, oldest first.
    private(set) var loginPrompts: [HostLoginPrompt] = []
    /// The app is in the foreground: sessions connect.
    private(set) var active: Bool
    /// Hosts whose latest quiet attempt (a hold in the background) needed the phone's screen; cleared when the host
    /// connects or the app comes to the foreground.
    private(set) var quietRefusals: [UUID: HostQuietRefusal] = [:]
    /// How long a hold keeps its host connected in the background after its last extension.
    @ObservationIgnored var holdLength: Duration = .seconds(60)
    /// How long `hold` waits for the link to settle.
    @ObservationIgnored var holdBudget: Duration = .seconds(15)
    /// Each held host's expiry.
    @ObservationIgnored private var holds: [UUID: Task<Void, Never>] = [:]

    @ObservationIgnored private var waiting: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var answering: [UUID: CheckedContinuation<[String]?, Never>] = [:]
    /// Every session this registry made, saved or probing, for host key answers and post-connect steps.
    @ObservationIgnored private var sessionOf: [UUID: Weak] = [:]
    private struct Weak { weak var session: HostSession? }

    /// `active` connects every host at once, so the first frame already shows them connecting.
    init(store: HostStore, keys: KeyStore, knownHosts: KnownHostStore, driver: any HostSessionDriver, active: Bool = false) {
        self.store = store
        self.keys = keys
        self.knownHosts = knownHosts
        self.driver = driver
        self.active = active
        sync()
    }

    /// In the user's order.
    var ordered: [HostSession] { store.hosts.compactMap { sessions[$0.id] } }

    func session(_ id: UUID) -> HostSession? { sessions[id] }

    var trustRequest: HostTrustRequest? { trustRequests.first }

    /// The question the sheet shows: host keys first (they come before the login), then login prompts.
    var question: HostQuestion? { trustRequests.first.map(HostQuestion.trust) ?? loginPrompts.first.map(HostQuestion.login) }

    /// Views that can present the trust sheet, in the order they appeared; the last one presents.
    private var trustPresenters: [UUID] = []
    var trustPresenter: UUID? { trustPresenters.last }
    func registerTrustPresenter(_ token: UUID) { if !trustPresenters.contains(token) { trustPresenters.append(token) } }
    func unregisterTrustPresenter(_ token: UUID) { trustPresenters.removeAll { $0 == token } }

    /// Connect all on foreground (and retry waiting reconnects at once), disconnect all on background.
    func setActive(_ active: Bool) {
        guard active != self.active else {
            if active { for session in ordered { session.retryNow() } }
            return
        }
        self.active = active
        // Foreground: every host connects interactively, so no hold is left to expire; background: everything
        // disconnects, holds included.
        for task in holds.values { task.cancel() }
        holds = [:]
        if active, !quietRefusals.isEmpty { quietRefusals = [:] }
        for session in ordered {
            session.stats.active = active
            if active { session.retryNow() } else { session.disconnect() }
        }
    }

    /// The user disconnected this host (`HostSession.park`): background refresh and watch requests leave it alone until
    /// Connect or the next launch.
    func isParked(_ id: UUID) -> Bool { sessions[id]?.parked ?? false }

    /// Low Power Mode changed: each host's stats take its cadence (`HostStatistics.cadence`).
    func powerStateChanged() {
        for session in ordered { session.stats.powerStateChanged() }
    }

    /// A watch request needs this saved host (docs/watch.md, Background). In the background its own session connects
    /// quietly (Keychain reads that may not prompt, already-trusted host keys only, no keyboard-interactive) and stays
    /// connected until `holdLength` after the last hold, unless the app comes to the foreground first. A locked phone
    /// is no reason to refuse: passwords read after first unlock, and a key behind Face ID fails the quiet read itself
    /// (`quietRefusals`). In the foreground the live session serves it. Returns once the link is
    /// connected, failed or retrying, the attempt waits on the user (a host key or login sheet, in the foreground), after
    /// `holdBudget`, or when the caller is cancelled.
    func hold(_ id: UUID) async {
        // A host the user disconnected is left alone (`HostSession.park`).
        guard let session = sessions[id], !session.parked else { return }
        if !active { extendHold(id) }
        guard session.link != .connected else {
            // The app may have been suspended since the last request: a dead link is found by an `echo` probe within
            // seconds and reconnects.
            if !active { session.retryNow() }
            return
        }
        // Starts a run when none is going (not after a host key mismatch), or tries a waiting reconnect now.
        session.retryNow()
        let start = session.link
        let deadline = ContinuousClock.now + holdBudget
        while sessions[id] === session, !Self.settled(session.link, from: start), !asks(id), ContinuousClock.now < deadline,
              !Task.isCancelled {
            await change(of: session, until: deadline)
        }
    }

    /// A sheet waits for the user on this host's attempt: the request is answered "Open Dispatch" now, not after the budget.
    private func asks(_ id: UUID) -> Bool {
        trustRequests.contains { $0.hostID == id } || loginPrompts.contains { $0.hostID == id }
    }

    func isHeld(_ id: UUID) -> Bool { holds[id] != nil }

    private func extendHold(_ id: UUID) {
        holds[id]?.cancel()
        let length = holdLength
        holds[id] = Task { [weak self] in
            try? await Task.sleep(for: length)
            guard !Task.isCancelled, let self else { return }
            self.holds[id] = nil
            if !self.active { self.sessions[id]?.disconnect() }
        }
    }

    /// Connected, ended, or a retry that moved on from where the hold found it.
    private static func settled(_ link: HostLink, from start: HostLink) -> Bool {
        switch link {
        case .connected, .failed, .disconnected: true
        case .reconnecting: link != start
        case .connecting, .authenticating, .bootstrapping: false
        }
    }

    /// Pull to refresh (Spaces, Agents): every host is asked at once, as on a network change (`retryNow`: a connected
    /// one checks that its link still answers, a waiting reconnect tries now, a failed one connects again). Returns
    /// when each host has answered since (`HostSession.updated`), failed, tried and is still down, or waits on the
    /// user (a host key or login sheet); at the latest after `timeout`, or when the pull is cancelled.
    func refresh(timeout: Duration = .seconds(10)) async {
        guard active else { return }
        let start = System.date()
        let sessions = ordered
        let links = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.link) })
        for session in sessions { session.retryNow() }
        let deadline = ContinuousClock.now + timeout
        func answered(_ session: HostSession) -> Bool {
            if let updated = session.updated, updated >= start { return true }
            // Plain SSH: no helper to answer (the SSH keepalive watches the link).
            if session.link == .connected, session.isPlain { return true }
            if self.sessions[session.id] !== session || session.hostKeyMismatch != nil || asks(session.id) { return true }
            switch session.link {
            case .failed, .disconnected: return true
            case .reconnecting: return session.link != links[session.id]
            case .connected, .connecting, .authenticating, .bootstrapping: return false
            }
        }
        while !sessions.allSatisfy(answered), ContinuousClock.now < deadline, !Task.isCancelled {
            await change(until: deadline) {
                for session in sessions {
                    _ = session.link
                    _ = session.updated
                }
            }
        }
    }

    /// Returns at the session's next link change or question, at `deadline`, or when the caller is cancelled (the watch
    /// request was answered without it).
    private func change(of session: HostSession, until deadline: ContinuousClock.Instant) async {
        await change(until: deadline) { _ = session.link }
    }

    /// Returns at the next change of what `observing` reads or of the questions, at `deadline`, or when the caller is
    /// cancelled.
    private func change(until deadline: ContinuousClock.Instant, observing: () -> Void) async {
        let once = ResumeOnce()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                once.start(continuation)
                withObservationTracking {
                    observing()
                    _ = trustRequests
                    _ = loginPrompts
                } onChange: { once.resume() }
                once.timer = Task {
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    once.resume()
                }
            }
        } onCancel: {
            once.resume()
        }
    }

    /// The connection attempt asks the user nothing: a watch hold in the background (the background refresh's sessions
    /// are always quiet).
    private func isQuiet(_ id: UUID) -> Bool { !active && holds[id] != nil }

    /// Whether this read may prompt: `fixed` when the session's context says, else unless the attempt is quiet.
    private func interactive(_ fixed: Bool?, _ id: UUID) -> Bool { fixed ?? !isQuiet(id) }

    private func refusedQuietly(_ id: UUID, _ refusal: HostQuietRefusal) {
        if quietRefusals[id] != refusal { quietRefusals[id] = refusal }
    }

    /// The network path became usable or moved to other interfaces (`NetworkPathWatcher`): in the foreground every
    /// session retries at once (a waiting reconnect tries now, a connected one checks its link still answers).
    func networkChanged() {
        guard active else { return }
        for session in ordered { session.retryNow() }
    }

    /// Whether this iPhone has a usable network, for what the hosts say while they cannot connect.
    private(set) var networkUnavailable = false
    @ObservationIgnored private var probes: [Weak] = []

    /// Each reading of the network path (`NetworkPathWatcher.observed`).
    func networkPath(satisfied: Bool) {
        networkUnavailable = !satisfied
        probes.removeAll { $0.session == nil }
        for session in ordered + probes.compactMap(\.session) { session.networkUnavailable = !satisfied }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background: setActive(false)
        // Returning passes through inactive: connecting then keeps the first frame back from showing hosts offline.
        case .active, .inactive: setActive(true)
        @unknown default: break
        }
    }

    /// A session for a host that is not saved yet: New host connects it once to verify (M8a). Pass it to `add`
    /// to keep its connection.
    func probe(_ record: HostRecord) -> HostSession {
        let session = makeSession(record)
        // Verifying a host samples no stats; `add` turns them on with the session it keeps.
        session.stats.active = false
        probes.append(Weak(session: session))
        return session
    }

    /// A session for background work (the app refresh task) that asks the user nothing: a host key that is not
    /// already trusted and a keyboard-interactive login fail it, as does a key behind Face ID (no prompt can show).
    /// It is not one of `sessions`: nothing it does reaches the lists.
    /// A host the user disconnected (`HostSession.park`) is left alone: the caller skips it (`isParked`).
    func backgroundSession(_ record: HostRecord) -> HostSession {
        let session = HostSession(host: record, driver: driver) { [weak self] session in
            guard let self else {
                return HostSessionContext(verifyHostKey: { _ in false }, key: { nil }, password: { nil },
                                          retries: AsyncStream { $0.finish() })
            }
            // Keychain reads that may not prompt: a key behind Face ID fails at once and the host is skipped.
            let quiet = self.context(for: session, interactive: false)
            return HostSessionContext(launch: quiet.launch,
                                      verifyHostKey: { [weak self] offer in await self?.trusted(offer) ?? false },
                                      key: quiet.key, password: quiet.password, retries: quiet.retries,
                                      keyboardInteractive: { _ in nil }, keyAvailable: quiet.keyAvailable)
        }
        session.refusal = { [weak self] in self?.connectionRefusal }
        return session
    }

    /// Why no connection may start now: the trusted host keys are unreadable (fail closed until Reset or Retry).
    var connectionRefusal: String? { knownHosts.unreadable ? KnownHostStore.unreadableLink : nil }

    /// Retry on the known-hosts notice: reads the file again; when it reads, every host connects again.
    func retryKnownHosts() {
        guard knownHosts.retryRead() else { return }
        if active { for session in ordered { session.retryNow() } }
        changed?()
    }

    /// Reset on the known-hosts notice: the unreadable file is set aside and every host asks about its key again.
    func resetKnownHosts() {
        knownHosts.reset()
        if active { for session in ordered { session.retryNow() } }
        changed?()
    }

    private func trusted(_ offer: HostKeyOffer) -> Bool {
        knownHosts.verify(host: offer.host, port: offer.port, algorithm: offer.algorithm, key: offer.key) == .match
    }

    /// Saves a new host. A connected probe becomes its session as it is, so the new row never shows a reconnect.
    func add(_ record: HostRecord, probe: HostSession? = nil) {
        store.add(record)
        guard let saved = store.record(record.id) else { return }
        if let probe, probe.id == record.id {
            probe.stats.active = active
            probe.update(saved)
            sessions[record.id] = probe
        }
        sync()
        changed?()
    }

    /// Saves an edit: the session keeps its connection unless the address, port, user or authentication changed. A new
    /// multiplexer preference is followed on the live connection. Chat turned off withdraws the hooks and agent
    /// capabilities from the running helper (`permissions.reduce`; a reconnect when that fails); turned on, the session
    /// reconnects, as a helper's grant only ever shrinks. The Helper switch reconnects (plain SSH or the helper), unless it
    /// goes off while the connection is already plain.
    func update(_ record: HostRecord) {
        guard let previous = store.record(record.id) else { return }
        store.update(record)
        guard let saved = store.record(record.id), let session = sessions[record.id] else { return }
        if previous.sameConnection(as: saved) {
            session.update(saved)
            // The Helper switch decides at each connection (plain SSH or the helper): a new run, except when it goes off on a
            // connection that is already plain ("Use plain SSH for this host"): that one stays, and so do its shells.
            if previous.helper != saved.helper {
                if saved.helper || !session.isPlain { reconnect(session) }
            } else if previous.chat != saved.chat {
                chatChanged(session)
            }
        } else {
            session.disconnect()
            sessionOf[session.id] = nil
            let replacement = makeSession(saved)
            // The shells ended with the old connection; their cards stay with the host.
            replacement.shells.adopt(session.shells)
            replacement.stats.adopt(session.stats)
            if session.parked { replacement.park() }
            sessions[record.id] = replacement
            if active { replacement.connect() }
        }
        changed?()
    }

    /// Forgets the host, its password, and its host key unless another host uses the same address and port. Nothing
    /// changes on the host.
    func remove(_ id: UUID) {
        guard let record = store.record(id) else { return }
        sessions[id]?.disconnect()
        holds.removeValue(forKey: id)?.cancel()
        quietRefusals[id] = nil
        withdrawQuestions(of: id, mismatches: true)
        store.remove(id)
        keys.removePassword(for: id)
        if !store.hosts.contains(where: { $0.address.lowercased() == record.address.lowercased() && $0.port == record.port }) {
            knownHosts.forget(host: record.address, port: record.port)
        }
        sync()
        changed?()
    }

    private func chatChanged(_ session: HostSession) {
        guard !session.host.chat, let client = session.client else {
            if session.client != nil || session.link.isPending { reconnect(session) }
            return
        }
        let reduced = HelperGrant.capabilities(chat: false).sorted()
        Task { [weak self, weak session] in
            do {
                let _: HelperClient.Empty = try await client.connection.request("permissions.reduce", params: ["capabilities": reduced])
            } catch {
                guard let self, let session, session.client === client else { return }
                self.reconnect(session)
            }
        }
    }

    /// A new run for a saved session (its grant changed).
    private func reconnect(_ session: HostSession) {
        guard sessions[session.id] === session else { return }
        session.disconnect()
        if active { session.connect() }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        store.move(fromOffsets: source, toOffset: destination)
        for record in store.hosts { sessions[record.id]?.update(record) }
        changed?()
    }

    /// Trust or Cancel on the first-use sheet. Trust applies to the offered key only, and only while the address still
    /// has no trusted key: another connection to the same address and port (a second host entry, a probe) may have had
    /// a different key trusted while this sheet waited, which makes this one a mismatch, the hard stop.
    func resolve(_ request: HostTrustRequest, trust: Bool) {
        trustRequests.removeAll { $0.id == request.id }
        var trusted = false
        if trust, request.kind == .unknown {
            let offer = request.offer
            switch knownHosts.verify(host: offer.host, port: offer.port, algorithm: offer.algorithm, key: offer.key) {
            case .unknown:
                knownHosts.trust(host: offer.host, port: offer.port, algorithm: offer.algorithm, key: offer.key)
                trusted = true
            case .match:
                trusted = true
            case .mismatch(let entry):
                (sessionOf[request.hostID]?.session ?? sessions[request.hostID])?.reportMismatch(offer)
                trustRequests.append(HostTrustRequest(hostID: request.hostID, hostName: request.hostName, offer: offer,
                                                      kind: .mismatch(trusted: entry)))
            case .unavailable:
                break
            }
        }
        waiting.removeValue(forKey: request.id)?.resume(returning: trusted)
    }

    /// Remove and retry on the mismatch sheet: forgets the trusted key and connects again, which asks about the new
    /// key as on first use.
    func removeAndRetry(_ request: HostTrustRequest) {
        trustRequests.removeAll { $0.id == request.id }
        knownHosts.forget(host: request.offer.host, port: request.offer.port)
        guard let session = sessionOf[request.hostID]?.session ?? sessions[request.hostID] else { return }
        // The refused run may still be ending: start a fresh one (the user asked: a Disconnect is lifted).
        session.disconnect()
        session.unpark()
        session.connect()
    }

    /// The host's open questions end with the run that asked them (the transport asks from tasks a disconnect does not
    /// cancel), and a later attempt's question replaces an earlier one: one sheet per host, never a stale one answered.
    /// A host key question starts an attempt (login prompts of earlier ones go too); a login prompt follows its own
    /// attempt's host key (`trust` false). A mismatch stays until Remove and retry or the host's removal (`mismatches`).
    private func withdrawQuestions(of host: UUID, trust: Bool = true, mismatches: Bool = false) {
        for request in trustRequests where trust && request.hostID == host {
            if request.kind == .unknown { resolve(request, trust: false) }
            else if mismatches { trustRequests.removeAll { $0.id == request.id } }
        }
        for prompt in loginPrompts where prompt.hostID == host { answer(prompt, with: nil) }
    }

    private func verify(_ offer: HostKeyOffer, for session: HostSession) async -> Bool {
        switch knownHosts.verify(host: offer.host, port: offer.port, algorithm: offer.algorithm, key: offer.key) {
        case .match:
            return true
        case .unavailable:
            // Fail closed: no key is trusted or asked about while the trusted keys cannot be read.
            return false
        case .mismatch(let trusted):
            session.reportMismatch(offer)
            // Each run against the changed key fails the same way: one sheet says so.
            let kind = HostTrustRequest.Kind.mismatch(trusted: trusted)
            if !trustRequests.contains(where: { $0.hostID == session.id && $0.offer == offer && $0.kind == kind }) {
                trustRequests.append(HostTrustRequest(hostID: session.id, hostName: session.host.name, offer: offer, kind: kind))
            }
            return false
        case .unknown:
            // A hold in the background: the sheet waits for the phone's screen, so the attempt fails now.
            if isQuiet(session.id), sessions[session.id] === session {
                refusedQuietly(session.id, .hostKey)
                return false
            }
            withdrawQuestions(of: session.id)
            let request = HostTrustRequest(hostID: session.id, hostName: session.host.name, offer: offer, kind: .unknown)
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    waiting[request.id] = continuation
                    trustRequests.append(request)
                }
            } onCancel: {
                // The connection went away while the sheet was up: the question is moot.
                Task { @MainActor [weak self] in self?.cancel(request.id) }
            }
        }
    }

    private func cancel(_ id: UUID) {
        guard let request = trustRequests.first(where: { $0.id == id }) else { return }
        resolve(request, trust: false)
    }

    /// The user's answers to a keyboard-interactive round, or nil (Cancel), which ends the login.
    func answer(_ prompt: HostLoginPrompt, with answers: [String]?) {
        loginPrompts.removeAll { $0.id == prompt.id }
        answering.removeValue(forKey: prompt.id)?.resume(returning: answers)
    }

    private func ask(_ challenge: HostLoginChallenge, for session: HostSession) async -> [String]? {
        withdrawQuestions(of: session.id, trust: false)
        let prompt = HostLoginPrompt(hostID: session.id, hostName: session.host.name, challenge: challenge)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                answering[prompt.id] = continuation
                loginPrompts.append(prompt)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let prompt = self.loginPrompts.first(where: { $0.id == prompt.id }) else { return }
                self.answer(prompt, with: nil)
            }
        }
    }

    private func sync() {
        let saved = Set(store.hosts.map(\.id))
        for (id, session) in sessions where !saved.contains(id) {
            session.disconnect()
            sessions[id] = nil
            sessionOf[id] = nil
        }
        for record in store.hosts where sessions[record.id] == nil {
            let session = makeSession(record)
            sessions[record.id] = session
            if active { session.connect() }
        }
    }

    private func makeSession(_ record: HostRecord) -> HostSession {
        let session = HostSession(host: record, driver: driver) { [weak self] session in
            self?.context(for: session) ?? HostSessionContext(verifyHostKey: { _ in false }, key: { nil },
                                                               password: { nil }, retries: AsyncStream { $0.finish() })
        }
        session.helloReceived = { [weak self] session, hello in self?.received(hello, on: session) }
        session.plainConnected = { [weak self] session in self?.connectedPlain(session) }
        session.refusal = { [weak self] in self?.connectionRefusal }
        session.postConnect = postConnect
        session.clientEnded = clientEnded
        session.shells.presences = presences
        session.networkUnavailable = networkUnavailable
        session.stats.active = active
        session.changed = { [weak self] session in
            guard let self, self.sessions[session.id] === session else { return }
            // Disconnected (backgrounded, or the user's own disconnect): no run is left to take an answer.
            if session.link == .disconnected { self.withdrawQuestions(of: session.id) }
            if session.link == .connected, self.quietRefusals[session.id] != nil { self.quietRefusals[session.id] = nil }
            self.changed?()
        }
        sessionOf[record.id] = Weak(session: session)
        return session
    }

    /// `interactive` false: Keychain reads never prompt (the background session). Nil: chosen at each read, quiet while
    /// the app is in the background and the host is held for a watch request (`hold`), so a held run that the foreground
    /// takes over asks again as usual.
    private func context(for session: HostSession, interactive fixed: Bool? = nil) -> HostSessionContext {
        let auth = session.host.auth, id = session.id
        var launch = launch(session.host)
        if !session.host.chat { launch.capabilities = HelperGrant.capabilityList(chat: false) }
        return HostSessionContext(
            launch: launch,
            verifyHostKey: { [weak self, weak session] offer in
                guard let self, let session else { return false }
                return await self.verify(offer, for: session)
            },
            key: { [weak self] in
                guard case .key(let key) = auth, let self else { return nil }
                let interactive = await self.interactive(fixed, id)
                do {
                    return try await self.keys.material(for: key, interactive: interactive)
                } catch SecretVaultError.interactionNotAllowed {
                    if fixed == nil { await self.refusedQuietly(id, .faceID) }
                    throw SecretVaultError.interactionNotAllowed
                }
            },
            password: { [weak self] in
                guard case .password = auth, let self else { return nil }
                let interactive = await self.interactive(fixed, id)
                return try await self.keys.password(for: id, interactive: interactive)
            },
            retries: AsyncStream { $0.finish() },
            keyboardInteractive: { [weak self, weak session] challenge in
                guard let self, let session else { return nil }
                if await !self.interactive(nil, id) {
                    await self.refusedQuietly(id, .login)
                    return nil
                }
                return await self.ask(challenge, for: session)
            },
            keyAvailable: { @MainActor [weak self] in
                guard case .key(let key) = auth, let self else { return false }
                return self.keys.key(key) != nil
            })
    }

    /// Saves what the helper said about the host and when it was reached.
    /// A plain SSH connection: the connection time (no helper reports the OS).
    private func connectedPlain(_ session: HostSession) {
        guard var record = store.record(session.id) else { return }
        record.lastConnected = Date()
        store.update(record)
        if let saved = store.record(record.id) { session.update(saved) }
    }

    private func received(_ hello: HelperSession.Info, on session: HostSession) {
        guard var record = store.record(session.id) else { return }
        if let identity = hello.identity {
            record.system = HostSystem(os: identity.os, distribution: identity.distribution, name: identity.os_name)
            record.osLabel = HostRecord.osLabel(identity)
        }
        record.lastConnected = Date()
        store.update(record)
        if let saved = store.record(record.id) { session.update(saved) }
    }
}

/// A continuation resumed once, by whichever comes first: an observed change or the timer (cancelled then).
private final class ResumeOnce: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Never>?
        var timer: Task<Void, Never>?
        var done = false
    }
    private let state = Mutex(State())

    func start(_ continuation: CheckedContinuation<Void, Never>) {
        let done = state.withLock { value in
            if !value.done { value.continuation = continuation }
            return value.done
        }
        if done { continuation.resume() }
    }

    var timer: Task<Void, Never>? {
        get { state.withLock { $0.timer } }
        set {
            let done = state.withLock { value in
                value.timer = newValue
                return value.done
            }
            if done { newValue?.cancel() }
        }
    }

    func resume() {
        let (continuation, timer) = state.withLock { value -> (CheckedContinuation<Void, Never>?, Task<Void, Never>?) in
            guard !value.done else { return (nil, nil) }
            value.done = true
            defer { value.continuation = nil }
            return (value.continuation, value.timer)
        }
        timer?.cancel()
        continuation?.resume()
    }
}
