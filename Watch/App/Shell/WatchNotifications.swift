import SwiftUI
import UserNotifications
import WatchKit

/// Where a notification tap leads: the thread it names, waiting until `WatchRoot` takes it (the tap can arrive before
/// the root is on screen, at a cold launch). Independent of `WatchModel`: the delegate that receives the tap has none.
@Observable @MainActor
final class WatchRouter {
    static let shared = WatchRouter()

    private(set) var pending: WatchConversationKey?

    func open(_ key: WatchConversationKey) { pending = key }

    /// The pending thread, once: the root pushes it and the next tap sets a new one.
    func take() -> WatchConversationKey? {
        defer { pending = nil }
        return pending
    }

    /// Debug only (`-DispatchWatchShow`): a screen of Spaces to open at launch, for screenshots without touches.
    enum Show: Equatable {
        /// Spaces, scrolled to a host's section when one is named.
        case spaces(host: String?)
        case space(WatchSpaceRoute)
        case tab(WatchTabRoute)

        /// "spaces", "spaces:<host>" (scrolled to that host), "space:<host>/<key>", "tab:<host>/<key>".
        init?(argument: String) {
            if argument == "spaces" { self = .spaces(host: nil); return }
            if argument.hasPrefix("spaces:") { self = .spaces(host: String(argument.dropFirst(7))); return }
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let slash = parts[1].firstIndex(of: "/") else { return nil }
            let host = String(parts[1][..<slash]), key = String(parts[1][parts[1].index(after: slash)...])
            switch parts[0] {
            case "space": self = .space(WatchSpaceRoute(host: host, space: key))
            case "tab": self = .tab(WatchTabRoute(host: host, tab: key))
            default: return nil
            }
        }
    }

    var show: Show?
    /// The host section Spaces scrolls to when it appears (`Show.spaces(host:)`).
    var scrollTarget: String?
}

/// The phone's agent notifications on the watch (docs/watch.md, Behaviour, Notifications). iOS forwards them while the
/// phone is locked and the watch worn; the watch app registers category `agent` (`WatchNotification.category`, no
/// actions: an approval belongs to a live subscription), and a tap whose `userInfo` names a conversation opens its
/// thread through `WatchRouter`.
final class WatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([WatchNotifications.category])
        #if DEBUG
        WatchNotifications.debugHooks(arguments: ProcessInfo.processInfo.arguments)
        #endif
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let key = WatchNotification.key(response.notification.request.content.userInfo) else { return }
        await MainActor.run { WatchRouter.shared.open(key) }
    }

    /// In the foreground (the debug hook's own notification) the banner still shows, so its tap can be tried.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

enum WatchNotifications {
    static var category: UNNotificationCategory {
        UNNotificationCategory(identifier: WatchNotification.category, actions: [], intentIdentifiers: [])
    }

    /// `host/node` (a debug argument's form) as a conversation key; the host must be a UUID, as `WatchNotification.key`
    /// requires. The node may itself hold slashes.
    static func key(argument: String) -> WatchConversationKey? {
        guard let slash = argument.firstIndex(of: "/") else { return nil }
        return WatchNotification.key([WatchNotification.hostKey: String(argument[..<slash]),
                                      WatchNotification.nodeKey: String(argument[argument.index(after: slash)...])])
    }

    #if DEBUG
    /// `-DispatchWatchNotify <host>/<node>`: posts a local notification with the phone's `userInfo` and category 3 s after
    /// launch, so a tap on it exercises the tap path (forwarded iPhone notifications need a paired phone). Provisional
    /// authorization: no prompt to answer first (simctl cannot grant notifications), delivered to Notification Center.
    /// `-DispatchWatchOpen <host>/<node>`: the same route without the notification (what the tap would do), for
    /// headless screenshots; `-DispatchWatchShow spaces|space:<host>/<key>|tab:<host>/<key>` opens Spaces' screens.
    @MainActor static func debugHooks(arguments: [String]) {
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        if let key = value("-DispatchWatchOpen").flatMap(key(argument:)) { WatchRouter.shared.open(key) }
        WatchRouter.shared.show = value("-DispatchWatchShow").flatMap(WatchRouter.Show.init(argument:))
        if let key = value("-DispatchWatchNotify").flatMap(key(argument:)) {
            Task { await post(key) }
        }
    }

    private static func post(_ key: WatchConversationKey) async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .provisional])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "claude · studio"
        content.body = "An agent needs you."
        content.categoryIdentifier = WatchNotification.category
        content.userInfo = [WatchNotification.hostKey: key.host, WatchNotification.nodeKey: key.node]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: "dispatch.watch.debug", content: content, trigger: trigger))
    }
    #endif
}

/// The long look of an `agent` notification: its title (the host), subtitle and body as the phone wrote them, in the
/// app's colours. Registered by `DispatchWatchApp`'s `WKNotificationScene`; the tap itself goes to the delegate.
final class WatchNotificationController: WKUserNotificationHostingController<WatchNotificationView> {
    private var content = WatchNotificationView.Content()

    override var body: WatchNotificationView { WatchNotificationView(content: content) }

    override func didReceive(_ notification: UNNotification) {
        let source = notification.request.content
        content = WatchNotificationView.Content(title: source.title, subtitle: source.subtitle, body: source.body)
    }
}

struct WatchNotificationView: View {
    struct Content: Equatable {
        var title = ""
        var subtitle = ""
        var body = ""
    }

    let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                WatchDotView(color: WatchDots.needsYou)
                Text(content.title).font(.headline).lineLimit(1)
            }
            if !content.subtitle.isEmpty {
                Text(content.subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            if !content.body.isEmpty {
                Text(content.body).font(.body)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
