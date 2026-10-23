import Foundation

/// A phone played in memory, deterministic for a given `now`: three hosts ("studio" and "lab" connected, "pi" offline
/// behind Face ID), six conversations (one waiting on an approval, one on a question, one working, one with an unseen
/// result), and a few spaces and tabs. Requests change its state as the phone's bridge would (an answer clears the
/// request, a message sends or queues, Stop pauses the queue, seen clears the dot) and reply with the new page.
/// Drives previews, the model's tests and `DISPATCH_WATCH_SCRIPTED` (docs/watch.md, Behaviour).
@MainActor
final class ScriptedWatchLink: WatchLink {
    enum Scenario: String, CaseIterable, Sendable {
        /// The demo phone above, reachable.
        case demo
        /// A phone with no hosts.
        case empty
        /// The demo's last snapshot, the phone out of reach.
        case unreachable
        /// The demo phone, locked and in the background: its password hosts still connect (passwords read after first
        /// unlock), so the lists and actions are the demo's; only "pi", behind Face ID, waits for the phone (`openPhone`).
        case locked
        /// No snapshot yet (first launch before the phone answered), unreachable.
        case waiting
        /// The redesign mockups' data (mockups/Watch, docs/watch.md, Fidelity): host mba2 with its statistics, the three
        /// Agents rows (working, waiting on an approval, done), their threads.
        case mockup
        /// The mockups' data with mba2 offline since 2:02 PM (K6b).
        case mockupOffline = "mockup-offline"
        /// The mockups' data with a review just sent from the phone (K8).
        case mockupReview = "mockup-review"
    }

    private(set) var snapshot: WatchSnapshot?
    var reachable: Bool {
        didSet { if reachable != oldValue { changed?() } }
    }
    var changed: (@MainActor () -> Void)?
    /// Every request, in order.
    private(set) var requests: [WatchRequest] = []
    /// The next request fails with this instead of being applied.
    var failNext: WatchFailure?
    /// Each reply waits this long (previews of the loading states).
    var delay: Duration?

    private(set) var threads: [WatchConversationKey: WatchThread]
    /// Conversations "Open on iPhone" asked for, in order.
    private(set) var opened: [WatchConversationKey] = []
    /// What `open` answers; nil: shown in the foreground, else notified.
    var openOutcome: WatchOpenOutcome?
    /// Reviews taken back by Undo, in order.
    private(set) var undone: [String] = []
    private let now: () -> Date
    private var counter = 0

    init(scenario: Scenario = .demo, now: @escaping () -> Date = Date.init) {
        self.now = now
        let base = now()
        switch scenario {
        case .waiting:
            snapshot = nil
            threads = [:]
        case .empty:
            snapshot = WatchSnapshot(generated: base, phone: WatchPhone(foreground: true), hosts: [])
            threads = [:]
        case .mockup, .mockupOffline, .mockupReview:
            snapshot = WatchFixtures.mockup(now: base, offline: scenario == .mockupOffline, review: scenario == .mockupReview)
            threads = WatchFixtures.mockupThreads(now: base)
        case .demo, .unreachable, .locked:
            var demo = WatchFixtures.demo(now: base)
            if scenario == .locked {
                demo.phone.locked = true
                demo.phone.foreground = false
            }
            if scenario == .unreachable { demo.generated = base.addingTimeInterval(-25 * 60) }
            snapshot = demo
            threads = WatchFixtures.threads(now: base)
        }
        reachable = scenario != .unreachable && scenario != .waiting
    }

    func activate() {}

    /// A new snapshot from the "phone", as a pushed application context.
    func push(_ snapshot: WatchSnapshot) {
        self.snapshot = snapshot
        changed?()
    }

    func request(_ request: WatchRequest) async throws -> WatchReply {
        guard reachable else { throw WatchFailure.unreachable }
        requests.append(request)
        if let delay { try await Task.sleep(for: delay) }
        if let failure = failNext {
            failNext = nil
            return WatchReply(id: request.id, .failure(failure))
        }
        return WatchReply(id: request.id, apply(request.action))
    }

    private func apply(_ action: WatchAction) -> WatchResult {
        // A host only the phone's screen brings back (pi, Face ID, locked or not) refuses what needs it live, as the
        // phone's server does; a message waits on the phone.
        if let id = action.conversation?.host, let host = snapshot?.hosts.first(where: { $0.id == id }), host.blocked != nil {
            switch action {
            case .answer, .stop, .resume, .sendQueuedNow: return .failure(.openPhone(host: host.name))
            case .hello, .refresh, .thread, .send, .removeQueued, .markSeen, .openOnPhone, .undoReview, .unknown: break
            }
        }
        switch action {
        case .refresh(let id?):
            // Connect: a host nothing blocks comes back, as the phone's retry would bring it.
            if var next = snapshot, let index = next.hosts.firstIndex(where: { $0.id == id }), next.hosts[index].blocked == nil {
                next.hosts[index].state = .connected
                next.hosts[index].live = true
                next.hosts[index].offlineSince = nil
                next.hosts[index].lastConnected = now()
                next.hosts[index].latency = next.hosts[index].latency ?? 24
                snapshot = next
            }
            snapshot?.generated = now()
            return snapshot.map(WatchResult.snapshot) ?? .failure(.unreachable)
        case .hello, .refresh:
            snapshot?.generated = now()
            return snapshot.map(WatchResult.snapshot) ?? .failure(.unreachable)
        case .openOnPhone(let key):
            guard threads[key] != nil || snapshot?.conversations.contains(where: { $0.key == key }) == true else { return missing(key) }
            opened.append(key)
            return .opened(openOutcome ?? (snapshot?.phone.foreground == true ? .shown : .notified))
        case .undoReview(let id):
            guard var next = snapshot, let event = next.reviews.first(where: { $0.id == id }) else {
                return .failure(WatchFailure(.requestEnded, "This review is no longer waiting."))
            }
            guard event.undoable(at: now()) else { return .failure(WatchFailure(.requestEnded, WatchModel.tooLate(event))) }
            next.reviews.removeAll { $0.id == id }
            next.generated = now()
            snapshot = next
            undone.append(id)
            changed?()
            return .done
        case .thread(let key, let limit):
            guard var thread = threads[key] else { return missing(key) }
            thread.generated = now()
            if thread.items.count > limit {
                thread.items = Array(thread.items.suffix(limit))
                thread.earlier = true
            }
            return .thread(thread)
        case .answer(let key, let request, let answer):
            guard var thread = threads[key] else { return missing(key) }
            if let approval = thread.approvals.first(where: { $0.id == request }) {
                guard let choice = approval.choices.first(where: { $0.index == answer.choice }) else {
                    return .failure(WatchFailure(.failed, "Choose Allow or Deny."))
                }
                thread.approvals.removeAll { $0.id == request }
                thread.items.append(item(.user, choice.label))
                if choice.role != .deny { thread.working = true; thread.canStop = true; thread.route = .queue }
            } else if let question = thread.questions.first(where: { $0.id == request }) {
                guard answer.completes(question) else { return .failure(WatchFailure(.failed, "Answer every question first.")) }
                thread.questions.removeAll { $0.id == request }
                let text = answer.skip ? "Skipped" : question.parts.map { part in
                    answer.texts[part.id] ?? part.options.filter { (answer.options[part.id] ?? []).contains($0.index) }
                        .map(\.label).joined(separator: ", ")
                }.joined(separator: "\n")
                thread.items.append(item(.user, text))
            } else {
                return .failure(WatchFailure(.requestEnded, "This request is no longer waiting."))
            }
            threads[key] = thread
            settle(key)
            return .thread(thread)
        case .send(let key, let text, let steer):
            guard var thread = threads[key] else { return missing(key) }
            if thread.route == .send || steer && thread.working {
                thread.items.append(item(.user, text))
                thread.working = true
                thread.canStop = true
                thread.route = .queue
            } else {
                counter += 1
                thread.queue.append(WatchQueued(id: "scripted-\(counter)", text: text, status: thread.phase == .live ? nil : "Waits for the host.",
                                                canSendNow: thread.phase == .live))
            }
            threads[key] = thread
            settle(key)
            return .thread(thread)
        case .stop(let key):
            guard var thread = threads[key] else { return missing(key) }
            thread.working = false
            thread.canStop = false
            thread.activity = nil
            thread.workingSince = nil
            thread.queueStopped = !thread.queue.isEmpty
            for index in thread.queue.indices { thread.queue[index].status = "Paused after Stop." }
            thread.route = thread.queue.isEmpty ? .send : .queue
            threads[key] = thread
            settle(key)
            return .thread(thread)
        case .resume(let key):
            guard var thread = threads[key] else { return missing(key) }
            thread.queueStopped = false
            for index in thread.queue.indices { thread.queue[index].status = nil }
            threads[key] = thread
            return .thread(thread)
        case .removeQueued(let key, let id):
            guard var thread = threads[key] else { return missing(key) }
            thread.queue.removeAll { $0.id == id }
            if thread.queue.isEmpty, !thread.working { thread.route = .send; thread.queueStopped = false }
            threads[key] = thread
            return .thread(thread)
        case .sendQueuedNow(let key, let id):
            guard var thread = threads[key], let queued = thread.queue.first(where: { $0.id == id }), queued.canSendNow else {
                return .failure(WatchFailure(.notSent, "This message can't be sent now."))
            }
            thread.queue.removeAll { $0.id == id }
            thread.items.append(item(.user, queued.text))
            thread.working = true
            thread.canStop = true
            threads[key] = thread
            settle(key)
            return .thread(thread)
        case .markSeen(let key, _):
            guard var next = snapshot, let index = next.conversations.firstIndex(where: { $0.key == key }),
                  next.conversations[index].dot == .unread, !next.conversations[index].needsYou else { return .done }
            next.conversations[index].dot = nil
            next.generated = now()
            snapshot = next
            changed?()
            return .done
        case .unknown:
            return .failure(.unsupported)
        }
    }

    private func missing(_ key: WatchConversationKey) -> WatchResult {
        .failure(WatchFailure(.noConversation, "This conversation has ended."))
    }

    private func item(_ kind: WatchItemKind, _ text: String) -> WatchItem {
        counter += 1
        return WatchItem(id: "scripted-\(counter)", kind: kind, text: text, time: now())
    }

    /// The conversation's row follows its thread, as the phone's next snapshot would.
    private func settle(_ key: WatchConversationKey) {
        guard let thread = threads[key], var next = snapshot,
              let index = next.conversations.firstIndex(where: { $0.key == key }) else { return }
        next.conversations[index].needsYou = thread.needsYou
        next.conversations[index].busy = thread.working
        next.conversations[index].dot = thread.needsYou ? .unread : thread.working ? .working : nil
        if let time = thread.lastActivity { next.conversations[index].lastActivity = time }
        next.phone.needsYou = next.conversations.filter(\.needsYou).count
        next.generated = now()
        snapshot = next
        changed?()
    }
}

/// The scripted phone's data: fictional hosts, spaces and agents (no real names), relative to `now`.
enum WatchFixtures {
    static let studio = "5E1D1A5C-57D1-4C0A-8000-000000000001"
    static let lab = "5E1D1A5C-57D1-4C0A-8000-000000000002"
    static let pi = "5E1D1A5C-57D1-4C0A-8000-000000000003"

    /// studio: the approval. lab: the question. Both connected.
    static let approval = WatchConversationKey(host: studio, node: "tmux:s:$1:%3")
    static let working = WatchConversationKey(host: studio, node: "tmux:s:$1:%5")
    static let notes = WatchConversationKey(host: studio, node: "tmux:s:$2:%8")
    static let question = WatchConversationKey(host: lab, node: "term_4")
    static let unseen = WatchConversationKey(host: lab, node: "term_9")
    static let offline = WatchConversationKey(host: pi, node: "tmux:s:$0:%1")

    static func demo(now: Date) -> WatchSnapshot {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let hosts = [
            WatchHost(id: studio, name: "studio", order: 0, state: .connected, tint: "#C98BD9", system: "macos", osLabel: "macOS 26.1",
                      multiplexer: "tmux", lastConnected: now, latency: 18,
                      stats: stats(cpu: 34, memory: 11, of: 32, disk: 48, of: 512, warnings: [.disk], seed: 11, now: now)),
            WatchHost(id: lab, name: "lab", order: 1, state: .connected, tint: "#6FB7A8", system: "linux", osLabel: "Ubuntu 24.04",
                      multiplexer: "herdr", lastConnected: now, latency: 41,
                      stats: stats(cpu: 12, memory: 6.5, of: 16, disk: 210, of: 480, seed: 5, now: now)),
            WatchHost(id: pi, name: "pi", order: 2, state: .offline, tint: nil, system: "linux", osLabel: "Debian 13",
                      problem: "Open Dispatch on your iPhone to unlock this host's key.", blocked: .faceID, live: false,
                      multiplexer: "tmux", lastConnected: ago(130), offlineSince: ago(130),
                      stats: stats(cpu: 3, memory: 0.6, of: 4, disk: 9, of: 64, seed: 3, now: ago(130))),
        ]
        let conversations = [
            WatchConversation(host: lab, node: question.node, name: "Tune the learning rate", space: "train", tab: "tab_2", agent: "claude",
                              preview: "Which schedule should I use for the next run?", dot: .unread, needsYou: true, lastActivity: ago(1),
                              title: "Tune the learning rate", waitingText: "Which schedule should I use for the next run?"),
            WatchConversation(host: studio, node: approval.node, name: "Fix the flaky replay test", space: "dispatch", tab: "tmux:s:$1:@2",
                              agent: "claude", preview: "I'll run the replay suite to confirm the fix.", dot: .unread, needsYou: true,
                              lastActivity: ago(2), title: "Fix the flaky replay test",
                              waitingText: "Allow swift test --filter ReplayTests?"),
            WatchConversation(host: studio, node: working.node, name: "Refactor the queue drainer", space: "dispatch", tab: "tmux:s:$1:@4",
                              agent: "codex", preview: "Splitting the drain loop into claim and send steps.", dot: .working, busy: true,
                              lastActivity: ago(4), title: "Refactor the queue drainer", step: "Editing drain.rs", workingSince: ago(4)),
            WatchConversation(host: lab, node: unseen.node, name: "Summarize the nightly logs", space: "infra", tab: "tab_7", agent: "pi",
                              preview: "Three jobs failed on disk space; the rest passed. Details are below.", dot: .unread, lastActivity: ago(18)),
            WatchConversation(host: studio, node: notes.node, name: "Draft the release notes", space: "notes", tab: "tmux:s:$2:@7", agent: "claude",
                              preview: "Here's a first draft grouped by area.", lastActivity: ago(95)),
            WatchConversation(host: pi, node: offline.node, name: "Rotate the backups", space: "ops", tab: "tmux:s:$0:@0", agent: "claude",
                              preview: "Backups now rotate weekly and keep eight copies.", lastActivity: ago(300), stale: true),
        ]
        let spaces = [
            WatchSpace(host: studio, key: "tmux:s:$1", name: "dispatch", folder: "~/src/dispatch", unread: 1, working: true, activity: ago(2)),
            WatchSpace(host: studio, key: "tmux:s:$2", name: "notes", folder: "~/notes", activity: ago(95)),
            WatchSpace(host: lab, key: "ws_1", name: "train", folder: "~/train", unread: 1, activity: ago(1)),
            WatchSpace(host: lab, key: "ws_3", name: "infra", folder: "~/infra", unread: 1, activity: ago(18)),
            WatchSpace(host: pi, key: "tmux:s:$0", name: "ops", folder: "~", activity: ago(300)),
        ]
        let tabs = [
            WatchTab(host: studio, space: "tmux:s:$1", key: "tmux:s:$1:@2", name: "Fix the flaky replay test", folder: "~/src/dispatch",
                     chat: true, agent: "claude", conversation: approval.node, urgency: .needsYou, status: "opus-5.5 · needs you", activity: ago(2)),
            WatchTab(host: studio, space: "tmux:s:$1", key: "tmux:s:$1:@4", name: "Refactor the queue drainer", folder: "~/src/dispatch",
                     chat: true, agent: "codex", conversation: working.node, urgency: .working, status: "gpt-5.5 · editing files", activity: ago(4)),
            WatchTab(host: studio, space: "tmux:s:$1", key: "tmux:s:$1:@6", name: "zsh", program: "zsh", folder: "~/src/dispatch", activity: ago(40)),
            WatchTab(host: studio, space: "tmux:s:$2", key: "tmux:s:$2:@7", name: "Draft the release notes", folder: "~/notes", chat: true,
                     agent: "claude", conversation: notes.node, status: "Here's a first draft grouped by area.", activity: ago(95)),
            WatchTab(host: studio, space: "tmux:s:$2", key: "tmux:s:$2:@9", name: "vim", program: "vim", folder: "~/notes", activity: ago(200)),
            WatchTab(host: lab, space: "ws_1", key: "tab_2", name: "Tune the learning rate", folder: "~/train", chat: true, agent: "claude",
                     conversation: question.node, urgency: .needsYou, status: "needs you", activity: ago(1)),
            WatchTab(host: lab, space: "ws_1", key: "tab_5", name: "htop", program: "htop", folder: "~/train", activity: ago(3)),
            WatchTab(host: lab, space: "ws_3", key: "tab_7", name: "Summarize the nightly logs", folder: "~/infra", chat: true, agent: "pi",
                     conversation: unseen.node, urgency: .unseen, status: "Three jobs failed on disk space.", activity: ago(18)),
            WatchTab(host: pi, space: "tmux:s:$0", key: "tmux:s:$0:@0", name: "Rotate the backups", folder: "~", chat: true, agent: "claude",
                     conversation: offline.node, activity: ago(300)),
        ]
        return WatchSnapshot(generated: now, phone: WatchPhone(foreground: false, needsYou: 2), hosts: hosts,
                             conversations: conversations, spaces: spaces, tabs: tabs)
    }

    static func threads(now: Date) -> [WatchConversationKey: WatchThread] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        var threads: [WatchConversationKey: WatchThread] = [:]
        threads[approval] = WatchThread(
            key: approval, generated: now, title: "Fix the flaky replay test", agent: "Claude Code", model: "opus-5.5",
            items: [
                WatchItem(id: "a1", kind: .user, text: "The replay test fails one run in ten. Find out why.", time: ago(9), turn: "t1"),
                WatchItem(id: "a2", kind: .thinking, text: "The failure looks timing related; checking the burst coalescing.", time: ago(8), turn: "t1"),
                WatchItem(id: "a3", kind: .tool, text: "Tests/ReplayTests.swift", time: ago(8), turn: "t1", tool: "Read"),
                WatchItem(id: "a4", kind: .tool, text: "Sources/Replay/Coalescer.swift", time: ago(6), turn: "t1", tool: "Patch", detail: "+4 −1"),
                WatchItem(id: "a5", kind: .agent, text: "The coalescer dropped a frame when two bursts landed in one tick. I made it keep the newest. I'll run the replay suite to confirm the fix.",
                          time: ago(2), turn: "t1"),
            ],
            approvals: [WatchApproval(id: "interaction-7", title: "Run the replay tests", detail: "swift test --filter ReplayTests", arrived: ago(2),
                                      choices: [WatchChoice(index: 1, label: "Deny", role: .deny),
                                                WatchChoice(index: 2, label: "This session", role: .session),
                                                WatchChoice(index: 0, label: "Allow", role: .allow)], verb: .run)],
            route: .queue)
        threads[working] = WatchThread(
            key: working, generated: now, title: "Refactor the queue drainer", agent: "Codex", model: "gpt-5.5", working: true,
            activity: "editing files", workingSince: ago(4),
            items: [
                WatchItem(id: "w1", kind: .user, text: "Split the drain loop so claims and sends are separate steps.", time: ago(6), turn: "t1"),
                WatchItem(id: "w2", kind: .tool, text: "rg -n \"fn drain\" helper/core", time: ago(5), turn: "t1", tool: "Search"),
                WatchItem(id: "w3", kind: .tool, text: "cargo test -p dispatch-core drain", time: ago(4), turn: "t1", tool: "Run",
                          detail: "test result: ok. 12 passed", running: true),
            ],
            queue: [WatchQueued(id: "B2C1D7E0-0000-4000-8000-000000000001", text: "Then update the docs to match.", canSendNow: true)],
            canStop: true, route: .queue)
        threads[notes] = WatchThread(
            key: notes, generated: now, title: "Draft the release notes", agent: "Claude Code", model: "opus-5.5",
            items: [
                WatchItem(id: "n1", kind: .user, text: "Draft release notes for this week.", time: ago(97), turn: "t1"),
                WatchItem(id: "n2", kind: .agent, text: "Here's a first draft grouped by area.\n\n• Files: faster tree loading\n• Chat: queued messages survive reconnects",
                          time: ago(95), turn: "t1", caption: "2 steps · 1m 12s", summary: WatchTurnSummary(steps: 2, seconds: 72, files: 1, additions: 24)),
            ])
        threads[question] = WatchThread(
            key: question, generated: now, title: "Tune the learning rate", agent: "Claude Code", model: "opus-5.5",
            items: [
                WatchItem(id: "q1", kind: .user, text: "Try a few schedules on the small model.", time: ago(12), turn: "t1"),
                WatchItem(id: "q2", kind: .tool, text: "python train.py --sweep", time: ago(10), turn: "t1", tool: "Run", detail: "best loss 1.84"),
                WatchItem(id: "q3", kind: .agent, text: "Cosine decay won on the small model. Which schedule should I use for the next run?", time: ago(1), turn: "t1"),
            ],
            questions: [WatchQuestion(id: "interaction-12", arrived: ago(1), parts: [
                WatchQuestion.Part(id: "schedule", header: "Schedule", text: "Which schedule should I use for the next run?",
                                   options: [WatchOption(index: 0, label: "Cosine", detail: "Best loss so far"),
                                             WatchOption(index: 1, label: "Linear"),
                                             WatchOption(index: 2, label: "Constant")],
                                   custom: true),
            ])],
            route: .queue)
        threads[unseen] = WatchThread(
            key: unseen, generated: now, title: "Summarize the nightly logs", agent: "Pi",
            items: [
                WatchItem(id: "u1", kind: .user, text: "Summarize last night's job logs.", time: ago(20), turn: "t1"),
                WatchItem(id: "u2", kind: .agent, text: "Three jobs failed on disk space; the rest passed. Details are below.\n\n• build-arm: no space left on device\n• build-x86: no space left on device\n• docs: no space left on device",
                          time: ago(18), turn: "t1", caption: "4 steps · 48s", summary: WatchTurnSummary(steps: 4, seconds: 48)),
            ])
        threads[offline] = WatchThread(
            key: offline, generated: now, title: "Rotate the backups", agent: "Claude Code", phase: .offline,
            reason: "pi is offline. Open Dispatch on your iPhone to unlock this host's key.",
            items: [
                WatchItem(id: "o1", kind: .agent, text: "Backups now rotate weekly and keep eight copies.", time: ago(300), turn: "t1"),
            ],
            earlier: true, route: .outbox)
        return threads
    }

    /// A host's statistics for the fixtures: CPU %, memory used and disk free in GiB of totals, a 15-minute CPU series
    /// (the phone mockups' generator; `seed` 11 is theirs, with its gap and its 82 % peak).
    static func stats(cpu: Double, memory: Double, of memoryTotal: Double, disk: Double, of diskTotal: Double,
                      warnings: [WatchHostStats.Warning] = [], seed: UInt64, now: Date) -> WatchHostStats {
        let gib = 1_073_741_824.0
        return WatchHostStats(cpu: cpu, load: cpu / 25, memoryUsed: Int64(memory * gib), memoryTotal: Int64(memoryTotal * gib),
                              diskFree: Int64(disk * gib), diskTotal: Int64(diskTotal * gib), warnings: warnings,
                              history: history(seed: seed, last: cpu, peak: 82), sampled: now)
    }

    /// 60 buckets of 15 s: a random walk between 4 and `peak` with a gap of four buckets and the peak at bucket 41,
    /// ending at `last`.
    static func history(seed: UInt64, last: Double, peak: Double = 82) -> [Double?] {
        var state = seed
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        var values: [Double?] = [], value = 28.0
        for index in 0..<WatchHostStats.historyCount {
            value = max(4, min(96, value + (random() - 0.5) * 18))
            if (12...15).contains(index) { values.append(nil); continue }
            if index == 41 { value = peak }
            values.append(value)
        }
        // Scaled so the highest bucket is the peak; the shape stays.
        let highest = values.compactMap { $0 }.max() ?? peak
        values = values.map { $0.map { ($0 * peak / highest).rounded() } }
        values[values.count - 1] = last
        return values
    }

    /// The mockups' host (mockups/Watch: "mba2", macOS, herdr) and its id.
    static let mba2 = "5E1D1A5C-57D1-4C0A-8000-000000000011"
    static let sidebar = WatchConversationKey(host: mba2, node: "term_1")
    static let limiter = WatchConversationKey(host: mba2, node: "term_2")
    static let docs = WatchConversationKey(host: mba2, node: "term_3")

    /// The mockups' phone (K1 to K8): mba2 with its statistics, the conversations "Sidebar theme toggle" (Claude,
    /// working), "Rate limiter for the API" (Codex, an approval) and "Docs site migration" (Claude, done), in the "app"
    /// space; `offline`: mba2 offline since 2:02 PM today; `review`: a review the phone just sent, its eight-second Undo
    /// window held open a little before it starts, so a screenshot finds it.
    static func mockup(now: Date, offline: Bool = false, review: Bool = false) -> WatchSnapshot {
        func ago(_ seconds: Double) -> Date { now.addingTimeInterval(-seconds) }
        let since = Calendar.current.date(bySettingHour: 14, minute: 2, second: 0, of: now) ?? ago(3600)
        let host = WatchHost(id: mba2, name: "mba2", order: 0, state: offline ? .offline : .connected, tint: "#7EA6C9", system: "macos",
                             osLabel: "macOS 26.1", problem: offline ? "mba2 isn't reachable." : nil, live: !offline,
                             multiplexer: "herdr", lastConnected: offline ? since : now, latency: offline ? nil : 18,
                             offlineSince: offline ? since : nil,
                             stats: stats(cpu: 34, memory: 11, of: 24, disk: 48, of: 494, warnings: [.disk], seed: 11, now: now))
        let conversations = [
            WatchConversation(host: mba2, node: sidebar.node, name: "Sidebar theme toggle", space: "app", tab: "tab_1", agent: "claude",
                              preview: "Added a ThemeToggle to the sidebar header and wired it to useTheme.", dot: .working, busy: true,
                              lastActivity: ago(10), stale: offline, title: "Sidebar theme toggle", step: "Editing Sidebar.tsx",
                              workingSince: ago(48)),
            WatchConversation(host: mba2, node: limiter.node, name: "Rate limiter for the API", space: "app", tab: "tab_2", agent: "codex",
                              preview: "The limiter is in; the tests need a run.", dot: .unread, needsYou: true, lastActivity: ago(120),
                              stale: offline, title: "Rate limiter for the API", waitingText: "Allow cargo test --workspace?"),
            WatchConversation(host: mba2, node: docs.node, name: "Docs site migration", space: "app", tab: "tab_3", agent: "claude",
                              preview: "Moved the docs to Starlight; the old MkDocs config is gone.", lastActivity: ago(3600),
                              stale: offline, title: "Docs site migration"),
        ]
        let spaces = [
            WatchSpace(host: mba2, key: "ws_1", name: "app", folder: "~/src/app", unread: 1, working: true, activity: ago(10)),
            WatchSpace(host: mba2, key: "ws_2", name: "site", folder: "~/src/site", activity: ago(7200)),
        ]
        let tabs = [
            WatchTab(host: mba2, space: "ws_1", key: "tab_1", name: "Sidebar theme toggle", chat: true, agent: "claude",
                     conversation: sidebar.node, urgency: .working, status: "opus-5.5 · Editing Sidebar.tsx", activity: ago(10)),
            WatchTab(host: mba2, space: "ws_1", key: "tab_2", name: "Rate limiter for the API", chat: true, agent: "codex",
                     conversation: limiter.node, urgency: .needsYou, status: "gpt-5-codex · needs you", activity: ago(120)),
            WatchTab(host: mba2, space: "ws_1", key: "tab_3", name: "Docs site migration", chat: true, agent: "claude",
                     conversation: docs.node, status: "Moved the docs to Starlight.", activity: ago(3600)),
            WatchTab(host: mba2, space: "ws_1", key: "tab_4", name: "zsh", program: "zsh", folder: "~/src/app", activity: ago(600)),
            WatchTab(host: mba2, space: "ws_2", key: "tab_5", name: "vite", program: "node", folder: "~/src/site", activity: ago(7200)),
        ]
        var reviews: [WatchReviewSent] = []
        if review {
            reviews.append(WatchReviewSent(id: "review-1", host: mba2, node: sidebar.node, agent: "claude", title: "Sidebar theme toggle",
                                           comments: 3, files: 2, sent: now.addingTimeInterval(112), undoUntil: now.addingTimeInterval(120)))
        }
        return WatchSnapshot(generated: now, phone: WatchPhone(foreground: true, needsYou: 1), hosts: [host],
                             conversations: conversations, spaces: spaces, tabs: tabs, reviews: reviews)
    }

    static func mockupThreads(now: Date) -> [WatchConversationKey: WatchThread] {
        func ago(_ seconds: Double) -> Date { now.addingTimeInterval(-seconds) }
        var threads: [WatchConversationKey: WatchThread] = [:]
        threads[sidebar] = WatchThread(
            key: sidebar, generated: now, title: "Sidebar theme toggle", agent: "Claude Code", model: "opus-5.5",
            items: [
                WatchItem(id: "s1", kind: .user, text: "Add a theme toggle to the sidebar.", time: ago(100), turn: "t1"),
                WatchItem(id: "s2", kind: .tool, text: "src/Sidebar.tsx", time: ago(95), turn: "t1", tool: "Read"),
                WatchItem(id: "s3", kind: .tool, text: "src/Sidebar.tsx, src/ThemeToggle.tsx", time: ago(60), turn: "t1", tool: "Patch",
                          detail: "+52 −6"),
                WatchItem(id: "s4", kind: .agent, text: "Added a ThemeToggle to the sidebar header and wired it to useTheme.",
                          time: ago(14), turn: "t1", caption: "5 steps · 1m 26s",
                          summary: WatchTurnSummary(steps: 5, seconds: 86, files: 4, additions: 61, deletions: 9)),
            ])
        threads[limiter] = WatchThread(
            key: limiter, generated: now, title: "Rate limiter for the API", agent: "Codex", model: "gpt-5-codex",
            items: [
                WatchItem(id: "r1", kind: .user, text: "Add a token bucket rate limiter to the API.", time: ago(400), turn: "t1"),
                WatchItem(id: "r2", kind: .agent, text: "The limiter is in; the tests need a run.", time: ago(130), turn: "t1"),
            ],
            approvals: [WatchApproval(id: "interaction-21", title: "Run cargo test", detail: "cargo test --workspace", arrived: ago(150),
                                      choices: [WatchChoice(index: 1, label: "Deny", role: .deny),
                                                WatchChoice(index: 0, label: "Allow", role: .allow)], verb: .run)],
            questions: [WatchQuestion(id: "interaction-22", arrived: ago(110), parts: [
                WatchQuestion.Part(id: "where", header: "Placement", text: "Where should the toggle live?",
                                   options: [WatchOption(index: 0, label: "Sidebar header", detail: "next to the space name"),
                                             WatchOption(index: 1, label: "Settings page", detail: "under Appearance"),
                                             WatchOption(index: 2, label: "Both")], custom: true),
                WatchQuestion.Part(id: "store", header: "Storage", text: "Where should the setting be kept?",
                                   options: [WatchOption(index: 0, label: "Local storage"), WatchOption(index: 1, label: "The user's profile")]),
            ])],
            route: .queue)
        threads[docs] = WatchThread(
            key: docs, generated: now, title: "Docs site migration", agent: "Claude Code", model: "opus-5.5",
            items: [
                WatchItem(id: "d1", kind: .user, text: "Move the docs site to Starlight.", time: ago(4000), turn: "t1"),
                WatchItem(id: "d2", kind: .agent, text: "Moved the docs to Starlight; the old MkDocs config is gone.", time: ago(3600),
                          turn: "t1", caption: "12 steps · 6m 3s",
                          summary: WatchTurnSummary(steps: 12, seconds: 363, files: 18, additions: 420, deletions: 388)),
            ])
        return threads
    }

    /// A busy phone for the size bound: `hosts` hosts with `conversations` agent tabs each, two spaces and two terminal
    /// tabs per host, every text at its longest (each row's distinct: a binary plist stores a repeated string once), every
    /// host with its statistics and a full CPU line, every row titled (its title is its name, as an agent's title names
    /// its tab), a working row with its step and a waiting one with what it asks.
    static func crowded(hosts count: Int, conversations perHost: Int, now: Date) -> WatchSnapshot {
        let long = String(repeating: "The build passed on every platform and the replay corpus matched; ", count: 4)
        var hosts: [WatchHost] = [], conversations: [WatchConversation] = [], spaces: [WatchSpace] = [], tabs: [WatchTab] = []
        for h in 0..<count {
            let id = String(format: "5E1D1A5C-57D1-4C0A-8000-%012d", h + 100)
            let gib = 1_073_741_824.0
            let history: [Double?] = (0..<WatchHostStats.historyCount).map { Double(h * 1000 + $0) / 7.0 + 0.123456789 }
            let stats = WatchHostStats(cpu: 37.123456789 + Double(h), load: 2.987654321, memoryUsed: Int64(11.3 * gib) + Int64(h),
                                       memoryTotal: Int64(32 * gib), diskFree: Int64(48.7 * gib) + Int64(h), diskTotal: Int64(494 * gib),
                                       warnings: [.cpu, .memory, .disk], history: history, sampled: now)
            hosts.append(WatchHost(id: id, name: "host-\(h)", order: h, state: h % 2 == 0 ? .connected : .connecting, tint: "#C98BD9",
                                   system: "linux", osLabel: "Ubuntu 24.04", problem: h % 2 == 0 ? nil : "Reconnecting after the network changed",
                                   multiplexer: "tmux", lastConnected: now, latency: 18.123456789 + Double(h),
                                   offlineSince: now.addingTimeInterval(-Double(h) * 60), stats: stats))
            for s in 0..<2 {
                spaces.append(WatchSpace(host: id, key: "tmux:s:$\(s)", name: "project-\(s)", folder: "~/src/project-\(s)", unread: 2,
                                         working: true, activity: now))
                for t in 0..<2 {
                    tabs.append(WatchTab(host: id, space: "tmux:s:$\(s)", key: "tmux:s:$\(s):@\(90 + t)", name: "zsh", program: "zsh",
                                         folder: "~/src/project-\(s)", activity: now.addingTimeInterval(-Double(t) * 60)))
                }
            }
            for c in 0..<perHost {
                let node = "tmux:s:$\(c % 2):%\(c + 10)"
                let tab = "tmux:s:$\(c % 2):@\(c + 10)"
                let time = now.addingTimeInterval(-Double(h * perHost + c) * 90)
                conversations.append(WatchConversation(
                    host: id, node: node, name: "Conversation \(c) on host \(h) with a longer title", space: "project-\(c % 2)", tab: tab,
                    agent: "claude", preview: "\(h).\(c) " + long, attention: nil, dot: c % 3 == 0 ? .unread : .working, needsYou: c % 3 == 0, busy: c % 3 == 1,
                    lastActivity: time, title: "Conversation \(c) on host \(h) with a longer title",
                    step: c % 3 == 1 ? "Editing \(h).\(c) " + long : nil, workingSince: c % 3 == 1 ? time : nil,
                    waitingText: c % 3 == 0 ? "Allow \(h).\(c) " + long : nil))
                tabs.append(WatchTab(host: id, space: "tmux:s:$\(c % 2)", key: tab, name: "Conversation \(c) on host \(h) with a longer title",
                                     folder: "~/src/project-\(c % 2)", chat: true, agent: "claude", conversation: node,
                                     urgency: c % 3 == 0 ? .needsYou : .working, status: "opus-5.5 · thinking", activity: time))
            }
        }
        return WatchSnapshot(generated: now, phone: WatchPhone(foreground: true, needsYou: count * ((perHost + 2) / 3)), hosts: hosts,
                             conversations: conversations, spaces: spaces, tabs: tabs)
    }
}
