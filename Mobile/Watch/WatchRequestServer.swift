import Foundation
import UIKit

/// Answers the watch's requests on the phone's own objects (docs/watch.md, "Serving a request"): every action goes
/// through the same `MobileChatSession` and `ChatConversations` calls the phone's screens make, then is answered with the
/// thread page as it stands. `WatchBridge` decodes, takes the background task and races `serve` against the budget.
///
/// - A request that needs a host holds it first (`hold`: in the background, a quiet connection of the host's own
///   session), then waits for the conversation to open, up to `budget`.
/// - The same request id twice (a retried `sendMessage`) is answered once: a duplicate waits for the first or takes its
///   cached reply, so a message is never sent twice. Failures are not cached: a failed request changed nothing, and
///   a retry may succeed.
@MainActor
final class WatchRequestServer {
    let composition: MobileComposition
    private let hold: @MainActor (UUID) async -> Void

    /// How long one request may wait for a host and its conversation: under the bridge's `WatchLimits.phoneBudget`, so
    /// the phone answers with what it has rather than the bridge timing out.
    var budget: Duration = WatchLimits.phoneBudget - .seconds(2)
    /// Once a conversation is live, how long a request waits for the approval, question or queue item it names to
    /// arrive: a reopened subscription delivers the helper's open interactions and queue just after its history.
    var grace: Duration = .seconds(2)

    /// Replies to recent request ids, oldest first.
    private var recent: [(id: String, reply: WatchReply)] = []
    private static let remembered = 64
    /// Duplicates of a request still being served, waiting for its reply.
    private var waiting: [String: [CheckedContinuation<WatchReply, Never>]] = [:]

    init(composition: MobileComposition, hold: @escaping @MainActor (UUID) async -> Void) {
        self.composition = composition
        self.hold = hold
    }

    /// Serves one request within `WatchLimits.phoneBudget` (the bridge races it with a timeout). `snapshot` builds the
    /// current snapshot (the bridge's builder) for `hello`/`refresh` replies, and tells why a host cannot connect.
    /// `within`: a shorter wait than `budget` (the app has less background time left).
    func serve(_ request: WatchRequest, within: Duration? = nil, snapshot: @MainActor () -> WatchSnapshot) async -> WatchReply {
        if let index = recent.firstIndex(where: { $0.id == request.id }) {
            let hit = recent.remove(at: index)
            recent.append(hit)
            return hit.reply
        }
        if waiting[request.id] != nil {
            return await withCheckedContinuation { waiting[request.id]?.append($0) }
        }
        waiting[request.id] = []
        let result = redacted(await result(request, budget: within.map { min($0, budget) } ?? budget, snapshot: snapshot), host: request.action.conversation.flatMap(chatKey))
        let reply = WatchReply(id: request.id, result)
        if case .failure = result {} else {
            recent.append((request.id, reply))
            if recent.count > Self.remembered { recent.removeFirst(recent.count - Self.remembered) }
        }
        for duplicate in waiting.removeValue(forKey: request.id) ?? [] { duplicate.resume(returning: reply) }
        return reply
    }

    private func result(_ request: WatchRequest, budget: Duration, snapshot: @MainActor () -> WatchSnapshot) async -> WatchResult {
        // A newer watch's version means a change this phone would misread.
        guard request.version <= WatchProtocol.version else { return .failure(.unsupported) }
        let deadline = ContinuousClock.now.advanced(by: budget)
        switch request.action {
        case .hello:
            return .snapshot(WatchCodec.fit(snapshot()))
        case .refresh(let host):
            await refresh(host.flatMap(UUID.init(uuidString:)), all: host == nil, deadline: deadline)
            return .snapshot(WatchCodec.fit(snapshot()))
        case .thread(let key, let limit):
            switch await open(key, deadline: deadline, snapshot: snapshot) {
            case .failure(let failure): return .failure(failure)
            case .success(let opened): return .thread(page(opened, limit: limit, snapshot: snapshot))
            }
        case .answer(let key, let id, let answer):
            return await act(key, live: true, deadline: deadline, snapshot: snapshot) { session in
                await self.answer(session, request: id, answer)
            }
        case .send(let key, let text, let steer):
            // Not live is fine: the message waits on the phone (`route` outbox) as the composer's would.
            return await act(key, live: false, deadline: deadline, snapshot: snapshot) { session in
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return WatchFailure(.invalid, "There's nothing to send.")
                }
                guard session.send(text: text, steer: steer) != nil else {
                    return WatchFailure(.notSent, session.failure ?? "Your iPhone couldn't keep this message. Nothing was sent.")
                }
                return nil
            }
        case .stop(let key):
            return await act(key, live: true, deadline: deadline, snapshot: snapshot) { session in
                session.stop()
                return nil
            }
        case .resume(let key):
            return await act(key, live: true, deadline: deadline, snapshot: snapshot) { session in
                session.resumeQueue()
                return nil
            }
        case .removeQueued(let key, let item):
            return await act(key, live: false, deadline: deadline, snapshot: snapshot) { session in
                // Gone already is what was asked.
                guard let row = await self.queued(session, item) else { return nil }
                if Task.isCancelled { return Self.abandoned }
                // A row only the host's queue holds needs the live conversation; the device's own go offline too.
                if case .helper = row.source, session.phase != .verified { return self.notLive(session, snapshot: snapshot) }
                session.removeQueued(row)
                return nil
            }
        case .sendQueuedNow(let key, let item):
            return await act(key, live: true, deadline: deadline, snapshot: snapshot) { session in
                guard let row = await self.queued(session, item) else {
                    return WatchFailure(.notSent, "This message is no longer queued.")
                }
                if Task.isCancelled { return Self.abandoned }
                guard session.canSendNow(row) else {
                    return WatchFailure(.notSent, row.status ?? "Your iPhone can't send this message now.")
                }
                session.sendQueuedNow(row)
                return nil
            }
        case .markSeen(let key, let through):
            guard let chat = chatKey(key), composition.conversations.conversations.contains(where: { $0.key == chat }) else {
                return .failure(Self.noConversation)
            }
            // A row with nothing written yet has nothing to mark: still done.
            composition.conversations.markSeen(chat, through: through)
            return .done
        case .unknown:
            return .failure(.unsupported)
        }
    }

    /// The host's address, port and user out of every text of a reply (connection failures name them); the snapshot
    /// builder does the same for its hosts.
    private func redacted(_ result: WatchResult, host key: ChatConversationKey?) -> WatchResult {
        guard let record = key.flatMap({ composition.hosts.session($0.host)?.host }) else { return result }
        func redact(_ text: String) -> String { WatchSnapshotBuilder.redact(text, host: record) }
        switch result {
        case .failure(var failure):
            failure.message = redact(failure.message)
            return .failure(failure)
        case .thread(var page):
            page.reason = page.reason.map(redact)
            page.failure = page.failure.map(redact)
            page.notes = page.notes.map(redact)
            return .thread(page)
        case .snapshot, .done, .unknown:
            return result
        }
    }

    // MARK: Hosts

    /// Pull to refresh: the hosts with Chat on (or `host`; never a plain SSH host) connect, held in the background or retried in the
    /// foreground, and their rows are read again; returns once every link settled or at the deadline.
    private func refresh(_ host: UUID?, all: Bool, deadline: ContinuousClock.Instant) async {
        let hosts = composition.hosts
        let sessions = hosts.ordered.filter { !$0.plainSSH && (all ? $0.host.chat : $0.id == host) }
        if hosts.active {
            for session in sessions { session.retryNow() }
        } else {
            let holds = sessions.map { session in Task { await self.hold(session.id, until: deadline) } }
            for hold in holds { await hold.value }
        }
        await until(deadline) { sessions.allSatisfy { !$0.link.isPending } }
        for session in sessions where session.link.isConnected {
            await composition.conversations.refresh(host: session.id)
        }
    }

    // MARK: Conversations

    private struct Opened {
        let session: MobileChatSession
        let host: HostSession
        let row: ChatConversation?
    }

    private func chatKey(_ key: WatchConversationKey) -> ChatConversationKey? {
        UUID(uuidString: key.host).map { ChatConversationKey(host: $0, node: key.node) }
    }

    /// The conversation's session, its host held and the conversation given until the deadline to open (verified with
    /// its history, or paused, or nothing more to wait for).
    private func open(_ key: WatchConversationKey, deadline: ContinuousClock.Instant,
                      snapshot: @MainActor () -> WatchSnapshot) async -> Result<Opened, WatchFailure> {
        guard let chat = chatKey(key), let host = composition.hosts.session(chat.host) else {
            return .failure(Self.noConversation)
        }
        // Also with the phone locked: a password reads after first unlock, a key behind Face ID refuses the quiet read.
        await hold(chat.host, until: deadline)
        let conversations = composition.conversations
        guard conversations.sessions[chat] != nil || conversations.conversations.contains(where: { $0.key == chat }) else {
            return .failure(Self.noConversation)
        }
        let session = conversations.session(for: chat)
        await until(deadline) { Self.settled(session, host: host) }
        // Input waits for the terminal to attach (the composer queues meanwhile): a moment, not the budget.
        if session.phase == .verified {
            await until(min(deadline, ContinuousClock.now.advanced(by: grace))) { session.terminalAttached }
        }
        return .success(Opened(session: session, host: host, row: conversations.conversations.first { $0.key == chat }))
    }

    /// Nothing more will change by waiting: verified with its history, paused, or detached for good (the host down, or
    /// connected with a live topology that binds no agent here).
    private static func settled(_ session: MobileChatSession, host: HostSession) -> Bool {
        switch session.phase {
        case .verified: return !session.loadingHistory
        case .paused: return true
        case .opening: return false
        case .detached:
            if host.link.isPending { return false }
            return !host.link.isConnected || (host.topologyIsLive && session.binding == nil)
        }
    }

    /// Opens the conversation, applies `action` (nil: done; else why not) and answers with the page.
    private func act(_ key: WatchConversationKey, live: Bool, deadline: ContinuousClock.Instant,
                     snapshot: @MainActor () -> WatchSnapshot,
                     _ action: (MobileChatSession) async -> WatchFailure?) async -> WatchResult {
        switch await open(key, deadline: deadline, snapshot: snapshot) {
        case .failure(let failure): return .failure(failure)
        case .success(let opened):
            if live, opened.session.phase != .verified { return .failure(notLive(opened.session, snapshot: snapshot)) }
            // The bridge already answered `timedOut`: the watch puts its card or message back, so nothing may happen.
            if Task.isCancelled { return .failure(Self.abandoned) }
            if let failure = await action(opened.session) { return .failure(failure) }
            return .thread(page(opened, snapshot: snapshot))
        }
    }

    private func page(_ opened: Opened, limit: Int = WatchLimits.threadItems,
                      snapshot: @MainActor () -> WatchSnapshot) -> WatchThread {
        let offline = opened.session.phase == .detached && !opened.host.link.isConnected
            ? hostFailure(opened.host, snapshot: snapshot)?.message : nil
        return WatchThreadBuilder.page(opened.session, row: opened.row, limit: limit, offline: offline)
    }

    /// Why a conversation that must be live is not.
    private func notLive(_ session: MobileChatSession, snapshot: @MainActor () -> WatchSnapshot) -> WatchFailure {
        if case .paused(let reason) = session.phase {
            return session.binding == nil ? WatchFailure(.noConversation, reason) : WatchFailure(.failed, reason)
        }
        if let host = composition.hosts.session(session.key.host) {
            if let failure = hostFailure(host, snapshot: snapshot) { return failure }
            if host.topologyIsLive, session.binding == nil { return Self.noConversation }
        }
        return WatchFailure(.timedOut, "\(session.agentName) on \(session.hostName) didn't answer in time.")
    }

    /// Why a host is not connected, in the watch's terms; nil while it is.
    private func hostFailure(_ host: HostSession, snapshot: @MainActor () -> WatchSnapshot) -> WatchFailure? {
        guard !host.link.isConnected else { return nil }
        // The snapshot builder decides what blocks a host (Face ID, trust, a changed key, a login): one rule for both.
        switch snapshot().hosts.first(where: { $0.id == host.id.uuidString })?.blocked {
        case .faceID, .trustHostKey, .hostKeyChanged, .login: return .openPhone(host: host.host.name)
        // Reserved: the builder no longer marks a host blocked by the lock, so `WatchFailure.phoneLocked` is never sent.
        case .phoneLocked, .unknown, nil: break
        }
        if case .failed(let reason) = host.link { return WatchFailure(.hostOffline, reason) }
        return WatchFailure(.hostOffline, host.problem ?? "\(host.host.name) isn't connected.")
    }

    // MARK: Answers

    private func answer(_ session: MobileChatSession, request: String, _ answer: WatchAnswer) async -> WatchFailure? {
        let found = await until(ContinuousClock.now.advanced(by: grace)) {
            session.approvals.contains { $0.interaction.id == request && $0.pending.pending }
                || session.questions.contains { $0.id == request && !$0.submitted }
        }
        guard found else { return Self.requestEnded }
        if Task.isCancelled { return Self.abandoned }
        if let approval = session.approvals.first(where: { $0.interaction.id == request && $0.pending.pending }) {
            if approval.pending.questions != nil { return form(session, approval, answer) }
            guard let index = answer.choice,
                  let choice = MobileChatSession.choices(for: approval.interaction).first(where: { $0.index == index }) else {
                return Self.unanswerable
            }
            session.answer(approval, with: choice)
            return approval.pending.pending ? Self.requestEnded : nil
        }
        guard let question = session.questions.first(where: { $0.id == request && !$0.submitted }) else { return Self.requestEnded }
        return side(session, question, answer)
    }

    /// A question form: per question its text and the chosen labels joined by ", " (`ClaudeQuestionDraft.answer`'s
    /// form) or the typed text; skip declines it.
    private func form(_ session: MobileChatSession, _ approval: MobileChatSession.Approval, _ answer: WatchAnswer) -> WatchFailure? {
        if answer.skip {
            session.answer(approval, answers: nil)
            return nil
        }
        var answers: [String: String] = [:]
        for question in approval.interaction.questions {
            if let text = answer.texts[question.id], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                answers[question.text] = text
            } else {
                let chosen = Set(answer.options[question.id] ?? [])
                let labels = question.options.indices.filter(chosen.contains).map { question.options[$0].label }
                guard !labels.isEmpty, question.multiple || labels.count == 1 else { return Self.unanswerable }
                answers[question.text] = labels.joined(separator: ", ")
            }
        }
        guard approval.pending.questions?.accepts(answers) == true else { return Self.unanswerable }
        session.answer(approval, answers: answers)
        return approval.pending.pending ? Self.requestEnded : nil
    }

    /// A side question, answered part by part as its view does (`select` per option, `type` for text).
    private func side(_ session: MobileChatSession, _ question: ChatSideQuestion, _ answer: WatchAnswer) -> WatchFailure? {
        if !answer.skip {
            let shown = question.index
            question.clearAnswers()
            for (index, part) in question.questions.enumerated() {
                question.index = index
                if let text = answer.texts[part.id], part.allowsCustom,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    question.type(text)
                } else {
                    let options = part.options ?? []
                    var chosen: [Int] = []
                    for option in answer.options[part.id] ?? [] where options.indices.contains(option) && !chosen.contains(option) {
                        chosen.append(option)
                    }
                    for option in chosen { question.select(options[option].label) }
                }
            }
            question.index = min(shown, max(question.questions.count - 1, 0))
            guard question.complete else { return Self.unanswerable }
        }
        session.answer(question, skip: answer.skip)
        return question.submitted ? nil : Self.requestEnded
    }

    /// The queue row named `item`, waiting up to the grace for the helper's queue to arrive and for a queue change in
    /// flight to end (the phone makes one at a time).
    private func queued(_ session: MobileChatSession, _ item: String) async -> MobileChatSession.QueueRow? {
        await until(ContinuousClock.now.advanced(by: grace)) {
            !session.queueBusy && session.queueRows.contains { $0.id == item }
        }
        return session.queueRows.first { $0.id == item }
    }

    // MARK: Support

    /// Polls `condition` until it holds, `deadline` passes or the request is cancelled; whether it held. (Cancelled,
    /// `Task.sleep` returns at once: without the check this would spin on the main actor until the deadline.)
    @discardableResult
    private func until(_ deadline: ContinuousClock.Instant, _ condition: () -> Bool) async -> Bool {
        while !condition() {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// `hold`, given up at `deadline` (the host's own `holdBudget` is the bridge's whole budget) or when the request is
    /// cancelled; the hold itself stays, so the connection goes on for the next request.
    private func hold(_ id: UUID, until deadline: ContinuousClock.Instant) async {
        let hold = hold
        let task = Task { await hold(id) }
        let timer = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            task.cancel()
        }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        timer.cancel()
    }

    static let noConversation = WatchFailure(.noConversation, "This conversation isn't on your iPhone any more.")
    static let requestEnded = WatchFailure(.requestEnded, "This was already answered or is no longer waiting.")
    static let unanswerable = WatchFailure(.invalid, "That answer doesn't fit the question. Answer it on your iPhone.")
    /// What a request that lost to the budget returns (the watch already has `timedOut`; never cached, so a retry runs).
    static let abandoned = WatchFailure(.timedOut, WatchFailure.timedOut.message)
}
