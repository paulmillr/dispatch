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

/// A local notification for a conversation that started needing the user.
struct RefreshNotification: Equatable, Sendable {
    /// One per conversation: a later one replaces it.
    let id: String
    /// The conversation's tab and host ("claude · studio").
    let title: String
    /// The last line of what the agent said, else what it waits for.
    let body: String
    let key: ChatConversationKey

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
    /// Remove all data: delivered and pending notifications go.
    func removeAll()
}

extension RefreshNotification {
    /// The category every refresh notification has: with previews hidden (Settings, Notifications, Show Previews), the
    /// lock screen shows only the placeholder, neither the agent's last line nor the tab and host.
    static var category: UNNotificationCategory {
        UNNotificationCategory(identifier: categoryIdentifier, actions: [], intentIdentifiers: [],
                               hiddenPreviewsBodyPlaceholder: "An agent needs you", options: [])
    }
    static let categoryIdentifier = "agent"

    /// What `SystemNotifier` posts.
    var content: UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = key.host.uuidString
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = userInfo
        return content
    }
}

@MainActor final class SystemNotifier: RefreshNotifying {
    private var center: UNUserNotificationCenter { .current() }

    init() {
        UNUserNotificationCenter.current().setNotificationCategories([RefreshNotification.category])
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

    func removeAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
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
/// posts a local notification for each conversation that newly needs the user (title its tab and host, body the last
/// line; tapping opens the thread), updates the launch cache and disconnects, all within `budget`. It never marks
/// anything seen (only opening a thread does), skips muted conversations, and does nothing while the setting is off or
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
        cache.flush()
        return posted
    }

    /// The conversations of `result` that newly need the user (needs you now, not in the cache's last-known rows), and
    /// the cache updated with what the run saw.
    func apply(_ result: HostRefresh, to record: HostRecord) -> [RefreshNotification] {
        let previous = cache.entry(record.id)
        var notifications: [RefreshNotification] = []
        let nodes = Dictionary((result.topology?.nodes ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, summary) in result.conversations.sorted(by: { $0.key < $1.key }) where summary.needsYou {
            guard previous?.conversations[key]?.summary.needsYou != true, !markers.muted(host: record.id, node: key) else { continue }
            let node = result.topology?.nodes.first { $0.key == key }
            let tab = node.flatMap { $0.parent.flatMap { nodes[$0] }?.name ?? $0.name } ?? "Agent"
            let body = Self.lastLine(result.texts[key]) ?? Self.lastLine(summary.preview) ?? summary.attention ?? "Needs you"
            notifications.append(RefreshNotification(id: record.id.uuidString + ":" + key, title: tab + " · " + record.name,
                                                     body: body, key: ChatConversationKey(host: record.id, node: key)))
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
        let present = Set((result.topology?.nodes ?? []).map(\.key))
        var conversations = entry.conversations.filter { result.topology == nil || present.contains($0.key) }
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
