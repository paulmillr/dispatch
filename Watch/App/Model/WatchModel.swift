import Foundation
import Observation

/// One host's section of Spaces on the watch: the host, its spaces in the phone's order, each with its tabs.
struct WatchSection: Identifiable, Equatable {
    struct Space: Identifiable, Equatable {
        let space: WatchSpace
        /// Most recent first, as the phone's Activity sort (`TabsOrdering.sorted`).
        let tabs: [WatchTab]
        var id: String { space.id }
    }

    let host: WatchHost
    let spaces: [Space]
    var id: String { host.id }
}

/// What the watch says above its lists, most pressing first (docs/watch.md, Behaviour, States).
enum WatchNotice: Equatable {
    /// No snapshot yet and the phone is not reachable: nothing to show.
    case waiting
    /// The phone is out of reach; the lists are its last snapshot (from `since`).
    case unreachable(since: Date)
    /// The phone is locked and says its hosts cannot log in (`WatchHostBlock.phoneLocked`): only a phone build from
    /// before passwords read after first unlock sends that; now a locked phone alone shows nothing.
    case phoneLocked
    /// The phone needs its screen (the trusted host keys are unreadable).
    case openPhone
    /// The phone has no network.
    case phoneOffline
    /// The phone has no hosts: add one there.
    case noHosts
    /// The snapshot is older than `WatchModel.staleAfter` though the phone is reachable.
    case stale(since: Date)
}

/// The watch app's state (docs/watch.md): the phone's latest snapshot with the lists derived from it, reachability, the
/// thread pages fetched so far, and the actions, each one request to the phone. View-agnostic; the views observe it.
@Observable @MainActor
final class WatchModel {
    /// A snapshot older than this, with the phone reachable, says when it was made (the phone pushes on every change,
    /// so an old one means the phone app has not run).
    static let staleAfter: TimeInterval = 10 * 60

    @ObservationIgnored let link: any WatchLink
    @ObservationIgnored let now: () -> Date

    private(set) var snapshot: WatchSnapshot?
    private(set) var reachable = false
    /// Thread pages by conversation, the last reply for each.
    private(set) var threads: [WatchConversationKey: WatchThread] = [:]
    /// Threads with a request on its way (a spinner where nothing is cached).
    private(set) var loading: Set<WatchConversationKey> = []
    /// The last failure per thread (its request or an action on it); cleared by the next success.
    private(set) var failures: [WatchConversationKey: WatchFailure] = [:]
    /// The last failure of `start` or `refresh`.
    private(set) var failure: WatchFailure?
    private(set) var refreshing = false
    /// Threads on screen: reloaded when their row moves.
    @ObservationIgnored private var visible: Set<WatchConversationKey> = []
    /// Threads whose row moved since their page was fetched.
    private(set) var outdated: Set<WatchConversationKey> = []
    /// Threads with actions on their way, how many: their replies bring the page.
    @ObservationIgnored private var acting: [WatchConversationKey: Int] = [:]
    /// `start` ran: a phone that becomes reachable is greeted.
    @ObservationIgnored private var started = false
    /// A `hello` is on its way: launch both starts the app and finds the phone reachable, one greeting is enough.
    @ObservationIgnored private var greeting = false
    /// Hosts with a Connect on its way (K6b's button shows progress).
    private(set) var connecting: Set<String> = []
    /// The review card on screen (K8): the newest review event that arrived while its Undo was open, until dismissed.
    private(set) var review: WatchReviewSent?
    /// The review on screen was taken back on the phone (its event left the snapshot before its deadline): the card
    /// says so for `withdrawnFor`, then closes.
    private(set) var reviewWithdrawn = false
    @ObservationIgnored var withdrawnFor: Duration = .seconds(2)
    /// Reviews already shown (or arrived too late), among those the snapshot still lists: a later snapshot repeating
    /// one never shows it again, and the set never outgrows the phone's list.
    @ObservationIgnored private(set) var seenReviews: Set<String> = []
    /// Reviews this watch is undoing: their leaving the snapshot is this watch's doing, not the phone's.
    @ObservationIgnored private var undoing: Set<String> = []
    /// Called with every snapshot the model takes (the complications' writer, `WatchComplicationWriter`).
    @ObservationIgnored let snapshotChanged: ((WatchSnapshot) -> Void)?

    init(link: any WatchLink, now: @escaping () -> Date = Date.init, snapshotChanged: ((WatchSnapshot) -> Void)? = nil) {
        self.link = link
        self.now = now
        self.snapshotChanged = snapshotChanged
        snapshot = link.snapshot
        reachable = link.reachable
        link.changed = { [weak self] in self?.linkChanged() }
        if let snapshot {
            snapshotChanged?(snapshot)
            noteReviews(snapshot)
        }
    }

    // MARK: Lists

    /// In the user's order (`HostRecord.order`).
    var hosts: [WatchHost] {
        (snapshot?.hosts ?? []).enumerated().sorted { a, b in
            a.element.order != b.element.order ? a.element.order < b.element.order : a.offset < b.offset
        }.map(\.element)
    }

    func host(_ id: String) -> WatchHost? { snapshot?.hosts.first { $0.id == id } }

    /// Agents, as the phone sorts them (`ChatConversations.rebuild`): newest activity first, then host name, then node
    /// key, all descending.
    var conversations: [WatchConversation] {
        let names = Dictionary((snapshot?.hosts ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return (snapshot?.conversations ?? []).sorted { a, b in
            let left = (a.lastActivity ?? .distantPast, names[a.host] ?? "", a.node)
            let right = (b.lastActivity ?? .distantPast, names[b.host] ?? "", b.node)
            return left > right
        }
    }

    func conversation(_ key: WatchConversationKey) -> WatchConversation? {
        snapshot?.conversations.first { $0.key == key }
    }

    /// Conversations waiting for the user (the badge), as the phone counts them.
    var needsYou: Int { snapshot.map { max($0.phone.needsYou, $0.conversations.filter(\.needsYou).count) } ?? 0 }

    /// Spaces: every host in order, its spaces in the phone's order, their tabs by activity.
    var sections: [WatchSection] {
        let spaces = snapshot?.spaces ?? [], tabs = snapshot?.tabs ?? []
        return hosts.map { host in
            WatchSection(host: host, spaces: spaces.filter { $0.host == host.id }.map { space in
                WatchSection.Space(space: space, tabs: Self.sorted(tabs.filter { $0.host == host.id && $0.space == space.key }))
            })
        }
    }

    func tab(host: String, key: String) -> WatchTab? { snapshot?.tabs.first { $0.host == host && $0.key == key } }

    /// The phone's Activity sort (`TabsOrdering.sorted(_:by: .activity)`): most recent first, unknown times last, then
    /// by name as Finder sorts, then by key so the order never flickers.
    static func sorted(_ tabs: [WatchTab]) -> [WatchTab] {
        tabs.sorted { a, b in
            switch (a.activity, b.activity) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            switch a.name.localizedStandardCompare(b.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.key < b.key
            }
        }
    }

    /// A host's spaces and tabs as Spaces lists them, for K6's "2 spaces · 5 tabs".
    func counts(host: String) -> (spaces: Int, tabs: Int) {
        ((snapshot?.spaces ?? []).filter { $0.host == host }.count, (snapshot?.tabs ?? []).filter { $0.host == host }.count)
    }

    /// A host's conversations that need you, and whether one works (K6's blue count and amber dot).
    func activity(host: String) -> (needsYou: Int, working: Bool) {
        let rows = (snapshot?.conversations ?? []).filter { $0.host == host }
        return (rows.filter(\.needsYou).count, rows.contains { $0.busy && !$0.needsYou })
    }

    /// The banner the lists show at `date`, if any.
    func notice(at date: Date) -> WatchNotice? {
        guard let snapshot else { return reachable ? nil : .waiting }
        if !reachable { return .unreachable(since: snapshot.generated) }
        if snapshot.phone.locked, snapshot.hosts.contains(where: { $0.blocked == .phoneLocked }) { return .phoneLocked }
        if snapshot.phone.knownHostsUnreadable { return .openPhone }
        if snapshot.phone.offline { return .phoneOffline }
        if snapshot.hosts.isEmpty { return .noHosts }
        if date.timeIntervalSince(snapshot.generated) > Self.staleAfter { return .stale(since: snapshot.generated) }
        return nil
    }

    /// What a host's rows say instead of acting, when only the phone can bring it back.
    static func blockedMessage(_ host: WatchHost) -> String? {
        switch host.blocked {
        case .phoneLocked?: WatchFailure.phoneLocked.message
        case .faceID?, .trustHostKey?, .hostKeyChanged?, .login?, .unknown?: WatchFailure.openPhone(host: host.name).message
        case nil: nil
        }
    }

    // MARK: Lifecycle

    /// The WatchConnectivity background task (the phone transferred a complication entry or a new context while the app
    /// was not running): activate, take what is pending (the link hands it on: snapshots to the model and its writer,
    /// complication entries to the writer), then return so the system can suspend the app.
    func receivePending() async {
        #if canImport(WatchConnectivity)
        guard let session = link as? SessionWatchLink else { return }
        await session.drain()
        #endif
    }

    /// The app launched or came forward: the link starts and the phone is asked for a fresh snapshot, now or as soon as
    /// it becomes reachable (WatchConnectivity's activation completes later).
    func start() async {
        started = true
        link.activate()
        guard link.reachable else { return }
        await greet()
    }

    private func greet() async {
        guard !greeting else { return }
        greeting = true
        defer { greeting = false }
        await ask(.hello)
    }

    /// Pull to refresh: the phone retries its hosts and answers with the lists.
    func refresh(host: String? = nil) async {
        await ask(.refresh(host: host))
    }

    private func ask(_ action: WatchAction) async {
        refreshing = true
        defer { refreshing = false }
        switch await perform(action) {
        case .success(.snapshot(let next)):
            failure = nil
            accept(next)
        case .success: failure = nil
        case .failure(let error): failure = error
        }
    }

    private func linkChanged() {
        let back = link.reachable && !reachable
        reachable = link.reachable
        if let next = link.snapshot { accept(next) }
        // The context may be minutes old: the phone that just came back answers with its lists now.
        if back, started { Task { await self.greet() } }
        // A thread opened while the phone was out of reach (a cold launch from a notification opens one before
        // WatchConnectivity has activated) loads now rather than showing "not reachable" until Try Again.
        if back {
            for key in visible where threads[key] == nil || failures[key]?.code == .unreachable {
                Task { await self.loadThread(key) }
            }
        }
    }

    /// A snapshot from the context or a reply; an older one than shown is ignored (a late context after a reply).
    private func accept(_ next: WatchSnapshot) {
        if let snapshot, snapshot.generated > next.generated { return }
        let previous = snapshot
        guard next != previous else { return }
        snapshot = next
        snapshotChanged?(next)
        noteReviews(next)
        // Pages of conversations the phone no longer lists (as a row or a tab's agent) go, unless on screen.
        let listed = Set(next.conversations.map(\.key) + next.tabs.compactMap(\.conversationKey))
        for key in threads.keys where !listed.contains(key) && !visible.contains(key) && acting[key] == nil {
            threads[key] = nil
            outdated.remove(key)
            failures[key] = nil
        }
        // A conversation whose row moved past its page has a newer page on the phone: on screen it loads again, otherwise
        // on its next open. One with a request on its way gets its page from that reply.
        for (key, page) in threads where acting[key] == nil && !loading.contains(key) {
            guard let row = next.conversations.first(where: { $0.key == key }),
                  row != previous?.conversations.first(where: { $0.key == key }), !Self.page(page, shows: row) else { continue }
            outdated.insert(key)
            if visible.contains(key) { Task { await self.loadThread(key) } }
        }
    }

    /// Whether `page` already shows what `row` says (the reply to the watch's own action came first).
    static func page(_ page: WatchThread, shows row: WatchConversation) -> Bool {
        page.needsYou == row.needsYou && page.working == row.busy && page.lastActivity == row.lastActivity
            && row.stale == (page.phase != .live)
    }

    /// A review the phone sent shows once, if it arrives while Undo still takes it back. One on screen that leaves the
    /// snapshot was taken back on the phone (before its deadline: said briefly) or is read (after it: the card closes).
    private func noteReviews(_ next: WatchSnapshot) {
        let date = now()
        let listed = Set(next.reviews.map(\.id))
        if let current = review, !listed.contains(current.id), !undoing.contains(current.id) {
            if current.undoable(at: date) { withdraw(current) } else { dismissReview() }
        }
        for event in next.reviews where seenReviews.insert(event.id).inserted && event.undoable(at: date) {
            review = event
            reviewWithdrawn = false
        }
        seenReviews.formIntersection(listed)
    }

    private func withdraw(_ event: WatchReviewSent) {
        reviewWithdrawn = true
        let delay = withdrawnFor
        Task {
            try? await Task.sleep(for: delay)
            if review?.id == event.id, reviewWithdrawn { dismissReview() }
        }
    }

    /// The review card was closed.
    func dismissReview() {
        review = nil
        reviewWithdrawn = false
    }

    /// Undo of the review on screen: the phone takes it back before the agent reads it. Nil when it did, else why not.
    func undoReview(_ event: WatchReviewSent) async -> WatchFailure? {
        guard event.undoable(at: now()) else { return WatchFailure(.requestEnded, Self.tooLate(event)) }
        undoing.insert(event.id)
        defer { undoing.remove(event.id) }
        switch await perform(.undoReview(id: event.id)) {
        case .success:
            if review?.id == event.id { dismissReview() }
            return nil
        case .failure(let failure):
            return failure
        }
    }

    static func tooLate(_ event: WatchReviewSent) -> String {
        "Too late to undo: \(event.agent ?? "the agent") has it."
    }

    /// Connect (K6b): the phone connects the host now (`refresh` with the host: `HostSession.connectByUser`, which lifts
    /// the phone's Disconnect; a quiet hold in the background) and answers with its lists.
    func connect(host: String) async {
        guard connecting.insert(host).inserted else { return }
        defer { connecting.remove(host) }
        await ask(.refresh(host: host))
    }

    /// "Open on iPhone": what to say under the button, from what the phone did.
    func openOnPhone(_ key: WatchConversationKey) async -> String {
        switch await perform(.openOnPhone(key)) {
        case .success(.opened(let outcome)): return Self.openWords(outcome)
        case .success: return Self.openWords(.unknown)
        case .failure(let failure): return failure.message
        }
    }

    static func openWords(_ outcome: WatchOpenOutcome) -> String {
        switch outcome {
        case .shown: "Open on your iPhone"
        case .notified: "Tap the notification on your iPhone"
        case .unavailable: "Open Dispatch on your iPhone: its notifications are off."
        case .unknown: "Sent to your iPhone"
        }
    }

    // MARK: Threads

    /// The cached page, if any (the view shows it while a newer one loads).
    func thread(for key: WatchConversationKey) -> WatchThread? { threads[key] }

    /// The thread is on screen: its page loads (unless a fresh one is cached) and, once shown, its result counts as seen.
    func open(_ key: WatchConversationKey) async {
        visible.insert(key)
        if threads[key] == nil || outdated.contains(key) { await loadThread(key) }
        await markSeen(key)
    }

    /// The thread left the screen.
    func close(_ key: WatchConversationKey) { visible.remove(key) }

    /// Fetches the page (one request at a time per thread).
    func loadThread(_ key: WatchConversationKey, limit: Int = WatchLimits.threadItems) async {
        guard loading.insert(key).inserted else { return }
        defer { loading.remove(key) }
        apply(await perform(.thread(key, limit: limit)), to: key)
    }

    // MARK: Actions

    /// An approval's chip. The card leaves at once; a refusal brings the phone's page back with its reason.
    @discardableResult
    func answer(_ key: WatchConversationKey, approval: WatchApproval, choice: WatchChoice) async -> Bool {
        let guess = update(key) { $0.approvals.removeAll { $0.id == approval.id } }
        return await act(.answer(key, request: approval.id, .choice(choice)), on: key, guess: guess)
    }

    /// A question's answer (or `.skipped`). Nothing is sent until it answers every part.
    @discardableResult
    func answer(_ key: WatchConversationKey, question: WatchQuestion, _ answer: WatchAnswer) async -> Bool {
        guard answer.completes(question) else {
            failures[key] = WatchFailure(.failed, "Answer every question first.")
            return false
        }
        let guess = update(key) { $0.questions.removeAll { $0.id == question.id } }
        return await act(.answer(key, request: question.id, answer), on: key, guess: guess)
    }

    /// A typed or dictated message: sent or queued as the phone routes it. Shown as queued until the phone's page says
    /// where it went.
    @discardableResult
    func send(_ key: WatchConversationKey, text: String, steer: Bool = false) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let guess = update(key) {
            $0.queue.append(WatchQueued(id: Self.sendingID + "-" + UUID().uuidString, text: WatchText.clip(text, to: WatchLimits.line),
                                        status: "Sending…"))
        }
        return await act(.send(key, text: text, steer: steer), on: key, guess: guess)
    }

    /// The placeholder rows of messages on their way: this prefix, one id each (two may be on their way).
    static let sendingID = "watch-sending"
    static func isSending(_ item: WatchQueued) -> Bool { item.id.hasPrefix(sendingID) }

    @discardableResult
    func stop(_ key: WatchConversationKey) async -> Bool {
        let guess = update(key) { $0.canStop = false }
        return await act(.stop(key), on: key, guess: guess)
    }

    @discardableResult
    func resume(_ key: WatchConversationKey) async -> Bool {
        let guess = update(key) { $0.queueStopped = false }
        return await act(.resume(key), on: key, guess: guess)
    }

    @discardableResult
    func removeQueued(_ key: WatchConversationKey, item: WatchQueued) async -> Bool {
        let guess = update(key) { $0.queue.removeAll { $0.id == item.id } }
        return await act(.removeQueued(key, item: item.id), on: key, guess: guess)
    }

    @discardableResult
    func sendQueuedNow(_ key: WatchConversationKey, item: WatchQueued) async -> Bool {
        guard item.canSendNow else { return false }
        return await act(.sendQueuedNow(key, item: item.id), on: key)
    }

    /// The thread was shown up to its newest item: the phone's seen marker moves there. Only a row with an unseen result
    /// asks (a needs-you row stays blue until answered, as on the phone); its dot clears at once.
    func markSeen(_ key: WatchConversationKey) async {
        guard let row = conversation(key), row.dot == .unread, !row.needsYou,
              let through = threads[key]?.lastActivity ?? row.lastActivity else { return }
        if var next = snapshot, let index = next.conversations.firstIndex(where: { $0.key == key }) {
            next.conversations[index].dot = nil
            snapshot = next
        }
        if case .failure(let error) = await perform(.markSeen(key, through: through)) { failures[key] = error }
    }

    // MARK: Requests

    /// `guess`: the page before the optimistic change and the change, undone when the action fails (an approval that
    /// did not go out must show again) unless something newer replaced the guess meanwhile (another action's reply, or
    /// its guess: the reload below brings the truth), then the phone's page is asked for when it can be.
    private func act(_ action: WatchAction, on key: WatchConversationKey,
                     guess: (before: WatchThread, after: WatchThread)? = nil) async -> Bool {
        acting[key, default: 0] += 1
        let result = await perform(action)
        acting[key] = acting[key].flatMap { $0 > 1 ? $0 - 1 : nil }
        apply(result, to: key)
        guard case .failure(let error) = result else { return true }
        if let guess, threads[key] == guess.after { threads[key] = guess.before }
        if link.reachable { await loadThread(key) }
        // The action's failure is what the thread says, whatever the reload did.
        failures[key] = error
        return false
    }

    private func apply(_ result: Result<WatchResult, WatchFailure>, to key: WatchConversationKey) {
        switch result {
        case .success(.thread(let page)):
            threads[key] = page
            outdated.remove(key)
            failures[key] = nil
        case .success(.snapshot(let next)):
            accept(next)
            failures[key] = nil
        case .success:
            failures[key] = nil
        case .failure(let error):
            failures[key] = error
        }
    }

    /// Changes the cached page at once; returns it as it was and as changed.
    @discardableResult
    private func update(_ key: WatchConversationKey, _ change: (inout WatchThread) -> Void) -> (before: WatchThread, after: WatchThread)? {
        guard let before = threads[key] else { return nil }
        var thread = before
        change(&thread)
        threads[key] = thread
        return (before, thread)
    }

    /// One request; a reply that is a failure, or one this build cannot read, is a failure.
    private func perform(_ action: WatchAction) async -> Result<WatchResult, WatchFailure> {
        guard link.reachable else { return .failure(.unreachable) }
        do {
            let reply = try await link.request(WatchRequest(action))
            switch reply.result {
            case .failure(let failure): return .failure(failure)
            case .unknown: return .failure(.unsupported)
            default: return .success(reply.result)
            }
        } catch let failure as WatchFailure {
            return .failure(failure)
        } catch {
            return .failure(WatchFailure(.failed, error.localizedDescription))
        }
    }

    // MARK: The app's

    /// The app's model: WatchConnectivity's link, or in Debug the scripted phone with `DISPATCH_WATCH_SCRIPTED=1`
    /// (or `empty`, `unreachable`, `locked`, `waiting`; also the launch argument `-DispatchWatchScripted <value>`).
    static func app(environment: [String: String] = ProcessInfo.processInfo.environment,
                    arguments: [String] = ProcessInfo.processInfo.arguments) -> WatchModel {
        let writer: (WatchSnapshot) -> Void = { snapshot in MainActor.assumeIsolated { WatchComplicationWriter.shared.write(snapshot) } }
        #if DEBUG
        if let scenario = scripted(environment: environment, arguments: arguments) {
            return WatchModel(link: ScriptedWatchLink(scenario: scenario), snapshotChanged: writer)
        }
        #endif
        #if canImport(WatchConnectivity)
        let link = SessionWatchLink()
        link.complication = { WatchComplicationWriter.shared.write(entry: $0) }
        return WatchModel(link: link, snapshotChanged: writer)
        #else
        return WatchModel(link: ScriptedWatchLink(scenario: .waiting), snapshotChanged: writer)
        #endif
    }

    /// The scripted scenario the environment or the launch arguments ask for ("1" is the demo; "0" none).
    static func scripted(environment: [String: String], arguments: [String]) -> ScriptedWatchLink.Scenario? {
        let value = environment["DISPATCH_WATCH_SCRIPTED"]
            ?? arguments.firstIndex(of: "-DispatchWatchScripted").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        guard let value, value != "0", value.lowercased() != "no" else { return nil }
        if value == "1" || value.lowercased() == "yes" { return .demo }
        return ScriptedWatchLink.Scenario(rawValue: value) ?? .demo
    }
}
