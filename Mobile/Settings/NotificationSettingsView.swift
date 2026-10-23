import SwiftUI

/// Settings › Notifications (G5): which agent events notify, the sound, the agent's text in the banner, the badge, and
/// how the watch shows them (`AgentAlerts`). Notifications come from the background refresh and, while the app is open,
/// from what arrives for threads not on screen.
struct NotificationSettingsView: View {
    let composition: MobileComposition
    @Bindable var settings: MobileSettings
    /// iOS's answer: nil until asked, false when notifications are off for Dispatch in the Settings app.
    @State private var allowed: Bool?

    init(composition: MobileComposition) {
        self.composition = composition
        settings = composition.settings
    }

    var body: some View {
        List {
            Group {
                if allowed == false {
                    Section {
                        Text("Notifications are off for Dispatch in the Settings app.")
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                }
                Section {
                    Toggle("Needs you", isOn: $settings.notifyNeedsYou)
                    Toggle("Finished", isOn: $settings.notifyFinished)
                    Toggle("Failed or disconnected", isOn: $settings.notifyFailed)
                } header: {
                    Text("Notify when an agent")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Approvals and questions always notify.")
                        if !settings.backgroundRefresh {
                            Text("With Background refresh off, Dispatch notifies only while it is open.")
                        }
                    }
                }
                Section {
                    Picker("Sound", selection: $settings.notificationSound) {
                        ForEach(NotificationSound.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Show message text", isOn: $settings.notificationText)
                    Toggle("Badge app icon", isOn: $settings.notificationBadge)
                } footer: {
                    Text("Off, banners say only which conversation needs you. The badge counts conversations waiting for you across hosts.")
                }
                if let watch = composition.watch {
                    Section {
                        LabeledContent("Apple Watch") { Text(Self.watchLabel(watch.status.pairing)) }
                    } footer: {
                        Text("iOS shows the same notifications on your watch while this iPhone is locked and the watch is on your wrist.")
                    }
                }
            }
            // The theme's cards (`Color.groupedRow`), also in a sheet, whose own rows are a shade lighter.
            .listRowBackground(Color.groupedRow)
        }
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        // The badge follows its switch at once.
        .onChange(of: settings.notificationBadge) { _, _ in composition.updateBadge() }
        // Approvals and questions always notify: iOS is asked here, and again when a switch is turned on (it shows its
        // prompt once; after that the answer is the Settings app's).
        .task { await checkPermission() }
        .onChange(of: [settings.notifyNeedsYou, settings.notifyFinished, settings.notifyFailed, settings.notificationBadge]) { old, new in
            if zip(old, new).contains(where: { !$0 && $1 }) { Task { await checkPermission() } }
        }
    }

    private func checkPermission() async {
        guard let alerts = composition.alerts else { return }
        allowed = await alerts.ensureAuthorized()
    }

    static func watchLabel(_ pairing: WatchPairing) -> String {
        pairing == .notPaired ? pairing.label : "Mirrored"
    }
}
