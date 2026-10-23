import Foundation
import UserNotifications

/// The notifications' sound (Settings, Notifications, Sound, G5): the system's, the ship's bell (the Mac's Nautical
/// bell, `ShipsBellSound`, written to `Library/Sounds` for the notification centre), or none.
enum NotificationSound: String, CaseIterable, Identifiable, Sendable {
    case standard = "default", shipsBell, none
    var id: Self { self }
    var title: String {
        switch self { case .standard: "Default"; case .shipsBell: "Ship's bell"; case .none: "None" }
    }

    /// The bell's file in `Library/Sounds`, where `UNNotificationSound(named:)` finds it, named by a fingerprint of
    /// its samples: a changed synthesis is a new file, so it reaches existing installs.
    nonisolated static let bellFile = bellName(ShipsBellSound.wav())
    nonisolated static var sounds: URL { System.home.appendingPathComponent("Library/Sounds") }

    /// "ships-bell-<FNV-1a of the WAV, hex>.wav".
    nonisolated static func bellName(_ wav: Data) -> String {
        let hash = wav.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
        return "ships-bell-" + String(hash, radix: 16) + ".wav"
    }

    var content: UNNotificationSound? {
        switch self {
        case .standard: .default
        case .shipsBell: UNNotificationSound(named: UNNotificationSoundName(Self.bellFile))
        case .none: nil
        }
    }

    /// Writes the bell once per synthesis (it is synthesized, not shipped) and removes older ones. False when it could
    /// not be written: the default plays.
    @discardableResult
    nonisolated static func installBell(in folder: URL = sounds) -> Bool {
        let url = folder.appendingPathComponent(bellFile)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for old in files where old.hasPrefix("ships-bell") && old != bellFile {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
        }
        if FileManager.default.fileExists(atPath: url.path) { return true }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try ShipsBellSound.wav().write(to: url, options: .atomic)
            return true
        } catch { return false }
    }
}

/// When an agent notifies (Settings, Notifications, G5), for the background refresh (`BackgroundRefresh.apply`) and for
/// what arrives while the app is open (`ChatConversations.arrived`): an agent that newly needs the user (an approval or
/// question always; the agent's own attention when Needs you is on), one whose turn ended (Finished), one that went
/// away while it worked (Failed or disconnected: its terminal or agent ended mid-turn). Each notification names the tab
/// and host; with Show message text it carries the agent's last line, else only what happened. The badge counts the
/// conversations waiting for the user across hosts.
@MainActor
final class AgentAlerts {
    /// Settings' switches.
    struct Policy: Equatable, Sendable {
        var needsYou = true
        var finished = true
        var failed = true
        var sound = NotificationSound.standard
        var text = true
        var badge = true
    }

    /// What happened to a conversation between two looks at it.
    enum Event: Equatable, Sendable {
        /// It newly needs the user: `question` for an open approval or question (`waiting`), else the agent's attention.
        case needsYou(question: Bool)
        /// Its turn ended without needing the user.
        case finished
        /// It went away while it was working.
        case stopped

        /// The body without the agent's text.
        var line: String {
            switch self {
            case .needsYou: "Needs you"
            case .finished: "Finished"
            case .stopped: "Stopped while working"
            }
        }
    }

    /// The event between `previous` and `current` (nil: the conversation is gone); nil when nothing worth a banner happened.
    static func event(previous: ChatConversationSummary?, current: ChatConversationSummary?) -> Event? {
        guard let current else { return previous?.busy == true ? .stopped : nil }
        if current.needsYou, previous?.needsYou != true { return .needsYou(question: current.waiting) }
        if previous?.busy == true, !current.busy, !current.needsYou { return .finished }
        return nil
    }

    /// Whether `policy` lets `event` notify: approvals and questions always do.
    static func notifies(_ event: Event, _ policy: Policy) -> Bool {
        switch event {
        case .needsYou(let question): question || policy.needsYou
        case .finished: policy.finished
        case .stopped: policy.failed
        }
    }

    /// The notification for `event`: titled with the tab and host, the body the agent's last line (with Show message
    /// text on and a line to show), else what happened.
    static func notification(_ event: Event, key: ChatConversationKey, tab: String, host: String, text: String?,
                             policy: Policy) -> RefreshNotification {
        let body = policy.text && event != .stopped ? text ?? event.line : event.line
        return RefreshNotification(id: key.host.uuidString + ":" + key.node, title: tab + " · " + host, body: body, key: key,
                                   sound: policy.sound, event: event)
    }

    /// The badge's count, the same for the background refresh and the open app: conversations that need the user
    /// among the live rows given (the open app's rows of connected hosts, the refresh's rows of the hosts it reached;
    /// rows whose agent left are in neither).
    static func waiting(_ summaries: [ChatConversationSummary]) -> Int { summaries.filter(\.needsYou).count }

    /// The badge: `waiting`, or none with Badge app icon off.
    static func badge(waiting: Int, policy: Policy) -> Int { policy.badge ? waiting : 0 }

    /// How long a conversation that went away while working must stay away before it counts as stopped: a helper
    /// restart or a reconnect rebinds the agent within it.
    var stopGrace: Duration = .seconds(10)
    /// Whether the conversation is still gone (the composition looks at its rows); nil: it is.
    var stillGone: ((ChatConversationKey) -> Bool)?
    /// Terminals the user closed, detached or terminated from this phone, and when: their agents leaving is no failure.
    private var closedByUser: [ChatConversationKey: ContinuousClock.Instant] = [:]
    /// How long a close from the phone covers its agents' leaving.
    static let closeWindow = Duration.seconds(60)
    /// Permission was asked for once this run (iOS shows its prompt once; after that the answer stands).
    private var askedPermission = false

    let notifier: any RefreshNotifying
    let settings: MobileSettings
    /// Threads on screen: what arrives for them shows there, not as a banner.
    var onScreen: Set<ChatConversationKey> = []
    /// Posted while the app is open (tests).
    private(set) var posted: [RefreshNotification] = []

    init(notifier: any RefreshNotifying, settings: MobileSettings) {
        self.notifier = notifier
        self.settings = settings
    }

    /// A live conversation changed while the app is open (`ChatConversations.arrived`): a banner, as the background
    /// refresh would post, unless its thread is on screen, it is muted, or notifications are not allowed (asked for
    /// the first time one would post). A stop counts only after `stopGrace` without the agent coming back, and never
    /// for a terminal the user closed from the phone.
    func arrived(_ key: ChatConversationKey, tab: String, host: String, previous: ChatConversationSummary?,
                 current: ChatConversationSummary?, muted: Bool) async {
        let policy = settings.alertPolicy
        guard let event = Self.event(previous: previous, current: current), Self.notifies(event, policy), !muted,
              !onScreen.contains(key) else { return }
        if event == .stopped {
            if let closed = closedByUser[key], ContinuousClock.now - closed < Self.closeWindow { return }
            if stopGrace > .zero { try? await Task.sleep(for: stopGrace) }
            guard stillGone?(key) ?? true else { return }
        }
        let text = BackgroundRefresh.lastLine(current?.preview) ?? current?.attention
        let notification = Self.notification(event, key: key, tab: tab, host: host, text: text, policy: policy)
        guard await ensureAuthorized() else { return }
        notifier.post(notification)
        posted.append(notification)
    }

    /// The user closed, detached or terminated these terminals from the phone.
    func userClosed(_ keys: [ChatConversationKey]) {
        let now = ContinuousClock.now
        closedByUser = closedByUser.filter { now - $0.value < Self.closeWindow }
        for key in keys { closedByUser[key] = now }
    }

    /// Whether notifications are allowed, asking once when iOS has not been asked yet (a notification switch turned on,
    /// the Notifications screen with one on, the first banner while open).
    func ensureAuthorized() async -> Bool {
        if await notifier.authorized() { return true }
        guard !askedPermission else { return false }
        askedPermission = true
        return await notifier.requestAuthorization()
    }

    /// The app icon's badge: `waiting` conversations, or cleared with the setting off; set only when it changes.
    func badge(waiting: Int) {
        let count = Self.badge(waiting: waiting, policy: settings.alertPolicy)
        guard count != lastBadge else { return }
        lastBadge = count
        notifier.setBadge(count)
    }

    private var lastBadge: Int?
}
