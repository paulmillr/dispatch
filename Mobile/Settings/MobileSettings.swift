import Foundation
import Observation

/// The app's own preferences (Settings), in `UserDefaults`. Per-host choices (Chat, the multiplexer) live in the host's
/// record instead (`HostRecord.chat`, `HostRecord.multiplexer`).
@MainActor @Observable
final class MobileSettings {
    /// Light, dark or the system's (L1a, L2a). The app is dark by default.
    enum Appearance: String, CaseIterable, Identifiable, Sendable {
        case system, dark, light
        var id: Self { self }
        var title: String {
            switch self { case .system: "System"; case .dark: "Dark"; case .light: "Light" }
        }
    }

    /// Shared with the Appearance work, which makes the app honour it: a string, "system", "dark" or "light".
    static let appearanceKey = "appearance"
    static let backgroundRefreshKey = "background.refresh"

    @ObservationIgnored let defaults: UserDefaults

    var appearance: Appearance {
        didSet { if appearance != oldValue { defaults.set(appearance.rawValue, forKey: Self.appearanceKey) } }
    }

    /// The terminal's font size for new terminals (pinch zoom changes it too: the last choice is the default). Read from
    /// the defaults each time, not kept: a pinch writes there behind Settings' back, and Settings must show that size
    /// and save the user's pick even when it equals the size Settings showed before.
    var terminalFontSize: Double {
        get {
            access(keyPath: \.terminalFontSize)
            let size = defaults.double(forKey: TerminalController.fontSizeKey)
            return TerminalConfiguration.fontSizes.contains(size) ? size : TerminalConfiguration().fontSize
        }
        set {
            withMutation(keyPath: \.terminalFontSize) { defaults.set(newValue, forKey: TerminalController.fontSizeKey) }
        }
    }

    /// Background refresh with notifications for agents that need you (off until the user turns it on, which asks
    /// for permission to notify).
    var backgroundRefresh: Bool {
        didSet { if backgroundRefresh != oldValue { defaults.set(backgroundRefresh, forKey: Self.backgroundRefreshKey) } }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Self.appearanceKey).flatMap(Appearance.init(rawValue:)) ?? .dark
        backgroundRefresh = defaults.bool(forKey: Self.backgroundRefreshKey)
    }

    /// The slider's range in whole points: the terminal's zoom range. A pinch may leave a half point (13.5); the
    /// slider shows it until the user moves it.
    static let fontSizeRange = TerminalConfiguration.fontSizes.lowerBound.rounded(.up)...TerminalConfiguration.fontSizes.upperBound.rounded(.down)

    /// "12 pt", "13.5 pt".
    static func fontSizeLabel(_ size: Double) -> String {
        (size.rounded() == size ? String(Int(size)) : String(format: "%.1f", size)) + " pt"
    }
}
