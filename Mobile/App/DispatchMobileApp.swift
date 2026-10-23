import SwiftUI
import UserNotifications

/// Dispatch for iPhone (docs/ios.md): a thin client for the hosts the user reaches over SSH. Dark by default, light or
/// the system's from the `appearance` default (`MobileAppearance`), tinted with the desktop pink (AccentColor).
@main
struct DispatchMobileApp: App {
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var delegate
    /// Every host's session and the areas they feed (docs/ios.md, Architecture and data flow).
    @State private var composition = MobileComposition.app()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MobileRoot(composition: composition).environment(composition.hosts).mobileAppearance()
                .background(MobileVerticalBarOff())
        }
        // iPadOS's menu bar and the hardware keyboard's ⌘ chords (MobileCommands).
        .commands { MobileCommands() }
        // Connected in the foreground, disconnected in the background (docs/ios.md, Connection).
        .onChange(of: scenePhase) { _, phase in composition.scenePhaseChanged(phase) }
        // The background refresh (docs/ios.md, Background refresh): the system launches or wakes the app for it.
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) { [composition] in
            await composition.backgroundRefresh()
        }
    }
}

/// Taps on the background refresh's notifications open their thread (`NotificationRoute`); the delegate is set at
/// launch, so a tap that launched the app is delivered too.
final class MobileAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MobileDevice.start()
        // The bundled terminal fonts, off the main thread; a terminal or chat that needs one first waits for it.
        MobileFonts.registerInBackground()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let host = info[RefreshNotification.hostKey] as? String, node = info[RefreshNotification.nodeKey] as? String
        Task { @MainActor in
            NotificationRoute.shared.route([RefreshNotification.hostKey: host ?? "", RefreshNotification.nodeKey: node ?? ""])
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
