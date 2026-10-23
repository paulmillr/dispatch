import BackgroundTasks
import Foundation
import UserNotifications

/// Submits and cancels the app refresh request (`BGTaskScheduler` in the app, a recorder in tests).
protocol RefreshScheduling: Sendable {
    func submit(_ identifier: String, earliest: Date) throws
    func cancel(_ identifier: String)
}

struct SystemRefreshScheduler: RefreshScheduling {
    func submit(_ identifier: String, earliest: Date) throws {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliest
        try BGTaskScheduler.shared.submit(request)
    }

    func cancel(_ identifier: String) { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
}

/// A local notification for a conversation that started needing the user, finished or stopped (`AgentAlerts`).
struct RefreshNotification: Equatable, Sendable {
    /// One per conversation: a later one replaces it.
    let id: String
    /// The conversation's tab and host ("claude · studio").
    let title: String
    /// The last line of what the agent said, else what it waits for.
    let body: String
    let key: ChatConversationKey
    /// Settings' sound (G5).
    var sound = NotificationSound.standard
    /// What happened: the category, so a hidden preview says it in neutral words.
    var event = AgentAlerts.Event.needsYou(question: false)

    /// `userInfo` keys: tapping opens the thread (`NotificationRoute`).
    static let hostKey = "host", nodeKey = "node"
    var userInfo: [String: String] { [Self.hostKey: key.host.uuidString, Self.nodeKey: key.node] }

    static func key(_ userInfo: [AnyHashable: Any]) -> ChatConversationKey? {
        guard let host = (userInfo[hostKey] as? String).flatMap(UUID.init(uuidString:)), let node = userInfo[nodeKey] as? String
        else { return nil }
        return ChatConversationKey(host: host, node: node)
    }
}

/// Local notifications (`UNUserNotificationCenter` in the app).
@MainActor protocol RefreshNotifying: AnyObject {
    /// Whether the user allowed notifications (without asking).
    func authorized() async -> Bool
    /// Asks once; true when allowed.
    func requestAuthorization() async -> Bool
    func post(_ notification: RefreshNotification)
    /// The app icon's badge (0 clears it).
    func setBadge(_ count: Int)
    /// Remove all data: delivered and pending notifications go.
    func removeAll()
}

extension RefreshNotification {
    /// The categories, one per event: with previews hidden (Settings, Notifications, Show Previews), the lock screen
    /// shows only the placeholder, neither the agent's last line nor the tab and host. `agent` (needs you) is the
    /// category the watch's long look registers.
    static var categories: Set<UNNotificationCategory> {
        Set([(categoryIdentifier, "An agent needs you"), (finishedCategory, "An agent finished"),
             (stoppedCategory, "An agent stopped")].map { identifier, placeholder in
            UNNotificationCategory(identifier: identifier, actions: [], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: placeholder, options: [])
        })
    }
    static let categoryIdentifier = "agent", finishedCategory = "agent.finished", stoppedCategory = "agent.stopped"

    var category: String {
        switch event {
        case .needsYou: Self.categoryIdentifier
        case .finished: Self.finishedCategory
        case .stopped: Self.stoppedCategory
        }
    }

    /// What `SystemNotifier` posts.
    var content: UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound.content
        content.threadIdentifier = key.host.uuidString
        content.categoryIdentifier = category
        content.userInfo = userInfo
        return content
    }
}

@MainActor final class SystemNotifier: RefreshNotifying {
    private var center: UNUserNotificationCenter { .current() }

    /// The badge last set: a change only reaches the notification centre.
    private var badge: Int?

    init() {
        UNUserNotificationCenter.current().setNotificationCategories(RefreshNotification.categories)
        // Synthesized off the main thread; a notification before it is written plays the default sound.
        Task.detached(priority: .utility) { NotificationSound.installBell() }
    }

    func authorized() async -> Bool {
        let center = center
        return await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                let status = settings.authorizationStatus
                continuation.resume(returning: status == .authorized || status == .provisional)
            }
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func post(_ notification: RefreshNotification) {
        center.add(UNNotificationRequest(identifier: notification.id, content: notification.content, trigger: nil)) { _ in }
    }

    func setBadge(_ count: Int) {
        guard count != badge else { return }
        badge = count
        center.setBadgeCount(count) { _ in }
    }

    func removeAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        badge = nil
        setBadge(0)
    }
}

/// What one host's refresh found: its live state for the cache, and its agent conversations by topology key.
struct HostRefresh: Sendable {
    var hello: HelperSession.Info?
    var multiplexers: [HelperClient.Multiplexer] = []
    var versions: [String: String] = [:]
    var following: String?
    var topology: HelperTopology?
    var conversations: [String: ChatConversationSummary] = [:]
    /// The newest agent text as the helper gave it (lines kept), by topology key: the notification's last line.
    var texts: [String: String] = [:]
}

/// Connects one host for the refresh and reads its conversations (`HostSessionsRefreshSource` in the app).
@MainActor protocol RefreshSource: AnyObject, Sendable {
    /// Nil when the host could not be reached before `deadline`.
    func refresh(_ host: HostRecord, until deadline: ContinuousClock.Instant) async -> HostRefresh?
}

/// The background refresh (plan 3.8): a `BGAppRefreshTask` at most every 15 minutes, as the system allows. Each run
/// connects to the hosts with Chat on, reads their conversations (`chat.list`, else `chat.state` per conversation),
/// posts a local notification for each conversation that newly needs the user, finished its turn or stopped while
/// working, as Settings' Notifications allow (`AgentAlerts`: title its tab and host, body the last line; tapping opens
/// the thread), sets the badge, updates the launch cache and disconnects, all within `budget`. It never marks anything
/// seen (only opening a thread does), skips muted conversations, and does nothing while the setting is off or
/// notifications are not allowed.
@MainActor
final class BackgroundRefresh {
    /// Under the bundle id (Info.plist `BGTaskSchedulerPermittedIdentifiers`: `$(PRODUCT_BUNDLE_IDENTIFIER).refresh`).
    static var identifier: String { (Bundle.main.bundleIdentifier ?? "yachts.dispatch.mobile") + ".refresh" }
    /// The earliest next run after scheduling: 15 minutes, the least iOS honours for app refresh.
    static let interval: TimeInterval = 15 * 60

    let identifier: String
    let scheduler: any RefreshScheduling
    let notifier: any RefreshNotifying
    let settings: MobileSettings
    let cache: HostCache
    let markers: ChatMarkers
    private let clock: () -> Date
    private let hosts: () -> [HostRecord]
    private let source: any RefreshSource
    /// The whole run: connect, read, disconnect (iOS gives an app refresh about 30 seconds).
    var budget: Duration = .seconds(25)

    init(identifier: String = BackgroundRefresh.identifier, scheduler: any RefreshScheduling = SystemRefreshScheduler(),
         notifier: any RefreshNotifying, settings: MobileSettings, cache: HostCache, markers: ChatMarkers,
         clock: @escaping () -> Date = Date.init, hosts: @escaping () -> [HostRecord], source: any RefreshSource) {
        self.identifier = identifier
        self.scheduler = scheduler
        self.notifier = notifier
        self.settings = settings
        self.cache = cache
        self.markers = markers
        self.clock = clock
        self.hosts = hosts
        self.source = source
    }

    /// A host the run connects: Chat on, with its helper. A plain SSH host (Helper off, docs/ios.md) is never refreshed.
    static func refreshes(_ record: HostRecord) -> Bool { record.helper && record.chat }

    /// Asks for the next run (the app went to the background, a run started, the setting or the hosts changed); with
    /// the setting off or no host with Chat on, cancels any pending one.
    func schedule() {
        guard settings.backgroundRefresh, hosts().contains(where: Self.refreshes) else {
            scheduler.cancel(identifier)
            return
        }
        try? scheduler.submit(identifier, earliest: clock().addingTimeInterval(Self.interval))
    }

    /// Settings' switch: on asks for permission to notify first and stays off without it. Returns the new state.
    @discardableResult
    func setEnabled(_ enabled: Bool) async -> Bool {
        if enabled, await !notifier.authorized(), await !notifier.requestAuthorization() {
            settings.backgroundRefresh = false
            schedule()
            return false
        }
        settings.backgroundRefresh = enabled
        schedule()
        return enabled
    }

    /// One run of the task. Returns what it posted.
    @discardableResult
    func run() async -> [RefreshNotification] {
        schedule()
        guard settings.backgroundRefresh, await notifier.authorized() else { return [] }
        let deadline = ContinuousClock.now + budget
        let records = hosts().filter(Self.refreshes)
        guard !records.isEmpty else { return [] }
        let source = source
        // In parallel, each within the deadline; the system ending the task early cancels them all.
        let tasks = records.map { record in Task { @MainActor in await source.refresh(record, until: deadline) } }
        var results: [UUID: HostRefresh] = [:]
        await withTaskCancellationHandler {
            for (record, task) in zip(records, tasks) { results[record.id] = await task.value }
        } onCancel: {
            for task in tasks { task.cancel() }
        }
        // The run took a while: a host removed meanwhile (Remove all data among them), or one whose Chat went off, gets
        // nothing posted or cached, and turning the setting off stops the run.
        guard settings.backgroundRefresh else { return [] }
        let current = Dictionary(hosts().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var posted: [RefreshNotification] = []
        // Two hosts reaching one machine and account (a LAN and a Tailscale address) notify once, for the first in the
        // list, as Spaces and Agents show that machine once (`MobileComposition.sameMachine`).
        var machines: Set<String> = []
        for record in records {
            guard let result = results[record.id], let record = current[record.id], Self.refreshes(record) else { continue }
            let machine = result.hello.flatMap { hello in
                hello.identity.flatMap { identity in hello.account.map { identity.host + ":" + String($0.uid) } }
            }
            let duplicate = machine.map { !machines.insert($0).inserted } ?? false
            for notification in apply(result, to: record) where !duplicate {
                notifier.post(notification)
                posted.append(notification)
            }
        }
        // Conversations waiting for the user on the hosts the run reached (their cache entries, now current; rows whose
        // agent left are gone from them): `AgentAlerts.waiting`, as the app counts its live rows.
        let reached = records.filter { results[$0.id] != nil && current[$0.id].map(Self.refreshes) == true }
        let waiting = AgentAlerts.waiting(reached.flatMap { cache.entry($0.id)?.conversations.values.map(\.summary) ?? [] })
        notifier.setBadge(AgentAlerts.badge(waiting: waiting, policy: settings.alertPolicy))
        cache.flush()
        return posted
    }

    /// The notifications for `result` against the cache's last-known rows (`AgentAlerts.event`: newly needs you, a turn
    /// that ended, an agent gone mid-turn from a live topology), as Settings allows, and the cache updated with what the
    /// run saw.
    func apply(_ result: HostRefresh, to record: HostRecord) -> [RefreshNotification] {
        let previous = cache.entry(record.id)
        var notifications: [RefreshNotification] = []
        let policy = settings.alertPolicy
        let nodes = Dictionary((result.topology?.nodes ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Without a live topology a missing row says nothing: only the rows read are compared.
        let keys = Set(result.conversations.keys).union(result.topology == nil ? [] : previous?.conversations.keys.map { $0 } ?? [])
        for key in keys.sorted() {
            let before = previous?.conversations[key]?.summary, now = result.conversations[key]
            // Gone means no agent on that terminal any more: not a row the helper left out, nor a detached tab's agent
            // (the refresh reads no detached terminal), whose agent goes on working.
            if now == nil, result.topology?.nodes.contains(where: { $0.key == key && $0.agent != nil }) != false { continue }
            guard let event = AgentAlerts.event(previous: before, current: now), AgentAlerts.notifies(event, policy),
                  !markers.muted(host: record.id, node: key) else { continue }
            let node = result.topology?.nodes.first { $0.key == key }
            let tab = node.flatMap { $0.parent.flatMap { nodes[$0] }?.name ?? $0.name } ?? before?.title ?? "Agent"
            let text = Self.lastLine(result.texts[key]) ?? Self.lastLine(now?.preview) ?? now?.attention
            notifications.append(AgentAlerts.notification(event, key: ChatConversationKey(host: record.id, node: key), tab: tab,
                                                          host: record.name, text: text, policy: policy))
        }
        var entry = previous ?? HostCacheEntry(saved: clock())
        if let hello = result.hello {
            entry.hello = hello
            entry.heard = clock()
        }
        if !result.multiplexers.isEmpty { entry.multiplexers = result.multiplexers.map(HostCacheEntry.Multiplexer.init) }
        if !result.versions.isEmpty { entry.versions = result.versions }
        if let following = result.following { entry.following = following }
        if let topology = result.topology { entry.topology = topology }
        // A row stays while its terminal keeps an agent; one whose agent left goes, so its stop notifies once and a
        // new agent there starts afresh.
        let bound = Set((result.topology?.nodes ?? []).filter { $0.agent != nil }.map(\.key))
        var conversations = entry.conversations.filter { result.topology == nil || bound.contains($0.key) }
        for (key, summary) in result.conversations { conversations[key] = HostCacheEntry.Conversation(summary) }
        entry.conversations = conversations
        cache.replace(entry, for: record.id)
        return notifications
    }

    /// The last line with text, trimmed.
    static func lastLine(_ text: String?) -> String? {
        text?.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }
}

/// The app's refresh source: a session per host through `HostSessions` that asks the user nothing (an unknown host
/// key, a keyboard-interactive login or a key behind Face ID fail it), connected for the run and disconnected after.
@MainActor
final class HostSessionsRefreshSource: RefreshSource {
    let hosts: HostSessions
    /// For helpers without the `chat.list` feature.
    var probe: any ChatConversationSource = ChatStateProbe()

    init(hosts: HostSessions) { self.hosts = hosts }

    func refresh(_ record: HostRecord, until deadline: ContinuousClock.Instant) async -> HostRefresh? {
        // Disconnect means leave the host alone until the user connects it (docs/ios.md, Connection).
        guard !hosts.isParked(record.id) else { return nil }
        let session = hosts.backgroundSession(record)
        let (links, continuation) = AsyncStream<HostLink>.makeStream(bufferingPolicy: .bufferingNewest(1))
        session.changed = { continuation.yield($0.link) }
        session.connect()
        defer {
            session.changed = nil
            session.disconnect()
            continuation.finish()
        }
        let connected = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await link in links {
                    if link == .connected { return true }
                    switch link {
                    case .failed, .disconnected, .reconnecting: return false
                    default: continue
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(until: deadline, clock: .continuous)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        // A connection that fell back to plain SSH has no helper to read: nothing to refresh.
        guard connected, !session.isPlain, let client = session.client, let hello = session.hello else { return nil }
        // Node ids only from this connection's helper (a background session restores nothing, but never trust a kept one).
        let topology = session.topologyIsLive ? session.topology : nil
        var result = HostRefresh(hello: hello, multiplexers: session.multiplexers, versions: session.multiplexerVersions,
                                 following: session.following, topology: topology)
        let agents = topology?.nodes.filter { $0.kind == .terminal && $0.agent != nil && !$0.detached } ?? []
        guard !agents.isEmpty else { return result }
        if Set(hello.features ?? []).contains("chat.list") {
            // One request: the rows' summaries, and their previews with lines for the notification's last line.
            let rows = Dictionary((await ChatListOperation.rows(client) ?? []).map { ($0.terminal, $0) },
                                  uniquingKeysWith: { first, _ in first })
            for node in agents {
                guard let row = rows[node.id] else { continue }
                result.conversations[node.key] = row.summary
                result.texts[node.key] = row.preview
            }
        } else {
            let fetched = await probe.summaries(agents.map(\.id), client: client)
            for node in agents { result.conversations[node.key] = fetched[node.id] }
        }
        return result
    }
}

/// Routes a tapped notification to its thread: the composition registers the opener at launch; a tap that arrives
/// first waits for it.
@MainActor
final class NotificationRoute {
    static let shared = NotificationRoute()
    private var pending: ChatConversationKey?
    var open: ((ChatConversationKey) -> Void)? {
        didSet {
            guard let open, let pending else { return }
            self.pending = nil
            open(pending)
        }
    }

    func route(_ userInfo: [AnyHashable: Any]) {
        guard let key = RefreshNotification.key(userInfo) else { return }
        if let open { open(key) } else { pending = key }
    }
}
