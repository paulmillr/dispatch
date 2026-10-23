import SwiftUI

/// The watch app (docs/watch.md): one model for the app's life, started at launch and whenever the app comes forward,
/// and the notification scene for the phone's agent notifications.
@main
struct DispatchWatchApp: App {
    /// A return after this long asks the phone to retry its hosts too, not only for its lists (a wrist raise after a
    /// few seconds needs neither).
    static let refreshAfter: TimeInterval = 30

    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = WatchModel.app()
    @State private var inactiveSince: Date?

    var body: some Scene {
        WindowGroup {
            WatchRoot(model: model)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        let away = inactiveSince.map { Date.now.timeIntervalSince($0) } ?? 0
                        inactiveSince = nil
                        Task {
                            await model.start()
                            if away > Self.refreshAfter { await model.refresh() }
                        }
                    } else if inactiveSince == nil {
                        inactiveSince = .now
                    }
                }
        }
        // The phone's complication entry or a new context while the app is not running: the complications stay current
        // (docs/watch.md, Complications).
        .backgroundTask(.watchConnectivity) {
            await model.receivePending()
        }
        WKNotificationScene(controller: WatchNotificationController.self, category: WatchNotification.category)
    }
}
