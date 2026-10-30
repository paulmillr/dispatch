import Dictation
import Foundation
import Observation

/// The app's own preferences (Settings), in `UserDefaults`. Per-host choices (Chat, the multiplexer) live in the host's
/// record instead (`HostRecord.chat`, `HostRecord.multiplexer`).
@MainActor @Observable
final class MobileSettings {
    static let autoApproveUnsafePastesKey = "autoApproveUnsafePastes"
    var autoApproveUnsafePastes: Bool {
        didSet { defaults.set(autoApproveUnsafePastes, forKey: Self.autoApproveUnsafePastesKey) }
    }
    static func autoApprovesUnsafePastes(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: autoApproveUnsafePastesKey) as? Bool ?? true
    }
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
    static let dictationEngineKey = "dictation.engine"
    static let whisperModelKey = "dictation.whisperModel"
    nonisolated static let themeKey = "theme"
    nonisolated static let terminalFontKey = "terminal.font"
    nonisolated static let terminalSchemeKey = "terminal.scheme"
    /// The old Improve text contrast switch, read once by `TerminalStyle` when there is no `textContrastKey`.
    nonisolated static let terminalContrastKey = "terminal.contrast"
    nonisolated static let textContrastKey = "terminal.textContrast"
    nonisolated static let boldIsBrightKey = "terminal.boldIsBright"
    nonisolated static let cursorKey = "terminal.cursor"
    nonisolated static let cursorBlinkKey = "terminal.cursorBlink"
    /// The terminal's rows and chat's lines together, as the Mac's Settings › Appearance › Size › Line spacing.
    nonisolated static let lineSpacingKey = "text.lineSpacing"
    nonisolated static let chatFontKey = "chat.font"
    nonisolated static let chatTextSizeKey = "chat.textSize"
    nonisolated static let notifyNeedsYouKey = "notify.needsYou"
    nonisolated static let notifyFinishedKey = "notify.finished"
    nonisolated static let notifyFailedKey = "notify.failed"
    nonisolated static let notificationSoundKey = "notify.sound"
    nonisolated static let notificationTextKey = "notify.text"
    nonisolated static let notificationBadgeKey = "notify.badge"

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
            return TerminalConfiguration.fontSizes.contains(size) ? size : TerminalController.defaultFontSize
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

    /// Chat dictation's engine (Apple's by default), and the Whisper model it uses when Whisper is chosen.
    var dictationEngine: DictationEngine {
        didSet { if dictationEngine != oldValue { defaults.set(dictationEngine.rawValue, forKey: Self.dictationEngineKey) } }
    }

    var whisperModel: WhisperModel {
        didSet { if whisperModel != oldValue { defaults.set(whisperModel.rawValue, forKey: Self.whisperModelKey) } }
    }

    /// The app's theme (G4): Automatic follows Appearance; Graphite, Lavender and Nautical are the Mac's, each with
    /// its own scheme (`MobileTheme`). The root reads the same key (`mobileAppearance()`).
    var theme: MobileTheme {
        didSet { if theme != oldValue { defaults.set(theme.rawValue, forKey: Self.themeKey) } }
    }

    // The terminal (G1, G2): each change reaches the open terminals at once (`TerminalStyle.changed`); the font size
    // is the one setting that does not, it is what new terminals open at.

    /// The terminal font's name as the list shows it (`TerminalFont.all`); Source Code Pro by default.
    var terminalFont: String {
        didSet { if terminalFont != oldValue { save(terminalFont, Self.terminalFontKey) } }
    }

    /// The terminal's color scheme: a bundled Ghostty theme's file name (`TerminalSchemes`), `dispatch-black` by default.
    var terminalScheme: String {
        didSet { if terminalScheme != oldValue { save(terminalScheme, Self.terminalSchemeKey) } }
    }

    /// The Mac's "Improve text contrast": the contrast shader raises text to 4.5:1 against its background, by default on
    /// light schemes only.
    var textContrast: TextContrast {
        didSet { if textContrast != oldValue { save(textContrast.rawValue, Self.textContrastKey) } }
    }

    /// Bold text in the first eight colours draws in their bright variants (Ghostty's `bold-color = bright`).
    var boldIsBright: Bool {
        didSet { if boldIsBright != oldValue { save(boldIsBright, Self.boldIsBrightKey) } }
    }

    /// The cursor a program has not chosen (Ghostty's `cursor-style`), and whether it blinks.
    var cursor: TerminalCursorStyle {
        didSet { if cursor != oldValue { save(cursor.rawValue, Self.cursorKey) } }
    }

    var cursorBlink: Bool {
        didSet { if cursorBlink != oldValue { save(cursorBlink, Self.cursorBlinkKey) } }
    }

    /// Tight, normal or relaxed lines in the terminal and chat (`LineSpacing`); chat reads the same key
    /// (`mobileAppearance()`).
    var lineSpacing: LineSpacing {
        didSet { if lineSpacing != oldValue { save(lineSpacing.rawValue, Self.lineSpacingKey) } }
    }

    /// Chat's text (G3): the Mac's three fonts, and the size relative to Dynamic Type. The root reads the same keys
    /// (`mobileAppearance()`, `ChatTypography`).
    var chatFont: MobileChatFont {
        didSet { if chatFont != oldValue { defaults.set(chatFont.rawValue, forKey: Self.chatFontKey) } }
    }

    var chatTextSize: ChatTextSize {
        didSet { if chatTextSize != oldValue { defaults.set(chatTextSize.rawValue, forKey: Self.chatTextSizeKey) } }
    }

    /// What the notifications say (G5, `AgentAlerts`): an agent that needs you (approvals and questions notify
    /// whatever this says), one that finished its turn, one that stopped while working.
    var notifyNeedsYou: Bool {
        didSet { if notifyNeedsYou != oldValue { defaults.set(notifyNeedsYou, forKey: Self.notifyNeedsYouKey) } }
    }

    var notifyFinished: Bool {
        didSet { if notifyFinished != oldValue { defaults.set(notifyFinished, forKey: Self.notifyFinishedKey) } }
    }

    var notifyFailed: Bool {
        didSet { if notifyFailed != oldValue { defaults.set(notifyFailed, forKey: Self.notifyFailedKey) } }
    }

    var notificationSound: NotificationSound {
        didSet { if notificationSound != oldValue { defaults.set(notificationSound.rawValue, forKey: Self.notificationSoundKey) } }
    }

    /// Banners carry the agent's last line; off, only which conversation and what happened.
    var notificationText: Bool {
        didSet { if notificationText != oldValue { defaults.set(notificationText, forKey: Self.notificationTextKey) } }
    }

    /// The app icon's badge counts the conversations waiting for the user, across hosts.
    var notificationBadge: Bool {
        didSet { if notificationBadge != oldValue { defaults.set(notificationBadge, forKey: Self.notificationBadgeKey) } }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoApproveUnsafePastes = Self.autoApprovesUnsafePastes(defaults)
        appearance = defaults.string(forKey: Self.appearanceKey).flatMap(Appearance.init(rawValue:)) ?? .dark
        backgroundRefresh = defaults.bool(forKey: Self.backgroundRefreshKey)
        (dictationEngine, whisperModel) = Self.dictation(defaults)
        theme = MobileTheme(stored: defaults.string(forKey: Self.themeKey))
        let style = TerminalStyle(defaults)
        terminalFont = style.font.name
        terminalScheme = style.scheme
        textContrast = style.textContrast
        boldIsBright = style.boldIsBright
        cursor = style.cursor
        cursorBlink = style.cursorBlink
        lineSpacing = style.lineSpacing
        chatFont = defaults.string(forKey: Self.chatFontKey).flatMap(MobileChatFont.init(rawValue:)) ?? .system
        chatTextSize = defaults.string(forKey: Self.chatTextSizeKey).flatMap(ChatTextSize.init(rawValue:)) ?? .standard
        notifyNeedsYou = defaults.object(forKey: Self.notifyNeedsYouKey) as? Bool ?? true
        notifyFinished = defaults.object(forKey: Self.notifyFinishedKey) as? Bool ?? true
        notifyFailed = defaults.object(forKey: Self.notifyFailedKey) as? Bool ?? true
        notificationSound = defaults.string(forKey: Self.notificationSoundKey).flatMap(NotificationSound.init(rawValue:)) ?? .standard
        notificationText = defaults.object(forKey: Self.notificationTextKey) as? Bool ?? true
        notificationBadge = defaults.object(forKey: Self.notificationBadgeKey) as? Bool ?? true
    }

    /// A terminal setting saved: the open terminals take it (`TerminalPresence` observes `TerminalStyle.changed`).
    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: TerminalStyle.changed, object: defaults)
    }

    /// The notification policy's switches (`AgentAlerts.Policy`).
    var alertPolicy: AgentAlerts.Policy {
        AgentAlerts.Policy(needsYou: notifyNeedsYou, finished: notifyFinished, failed: notifyFailed, sound: notificationSound,
                           text: notificationText, badge: notificationBadge)
    }

    /// Settings' Notifications row (G1): "Sound, text", "Ship's bell", "Off".
    var notificationSummary: String {
        var parts: [String] = []
        switch notificationSound {
        case .standard: parts.append("Sound")
        case .shipsBell: parts.append("Ship's bell")
        case .none: break
        }
        if notificationText { parts.append(parts.isEmpty ? "Text" : "text") }
        if parts.isEmpty { return notificationBadge ? "Badge" : "Silent" }
        return parts.joined(separator: ", ")
    }

    /// The dictation choice as saved: what the composer reads when the microphone is tapped.
    static func dictation(_ defaults: UserDefaults = .standard) -> (engine: DictationEngine, model: WhisperModel) {
        (defaults.string(forKey: dictationEngineKey).flatMap(DictationEngine.init(rawValue:)) ?? .apple,
         defaults.string(forKey: whisperModelKey).flatMap(WhisperModel.init(rawValue:)) ?? .small)
    }

    /// The slider's range in whole points: the terminal's zoom range. A pinch may leave a half point (13.5); the
    /// slider shows it until the user moves it.
    static let fontSizeRange = TerminalConfiguration.fontSizes.lowerBound.rounded(.up)...TerminalConfiguration.fontSizes.upperBound.rounded(.down)

    /// "12 pt", "13.5 pt".
    static func fontSizeLabel(_ size: Double) -> String {
        (size.rounded() == size ? String(Int(size)) : String(format: "%.1f", size)) + " pt"
    }
}
