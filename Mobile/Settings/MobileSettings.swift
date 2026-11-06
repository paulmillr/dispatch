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
    nonisolated static let textContrastKey = "terminal.textContrast"
    nonisolated static let boldIsBrightKey = "terminal.boldIsBright"
    nonisolated static let cursorKey = "terminal.cursor"
    nonisolated static let cursorBlinkKey = "terminal.cursorBlink"
    nonisolated static let ligaturesKey = "terminal.ligatures"
    /// The terminal's rows and chat's lines together, as the Mac's Settings › Appearance › Size › Line spacing.
    nonisolated static let lineSpacingKey = "text.lineSpacing"
    nonisolated static let chatFontKey = "chat.font"
    nonisolated static let chatTextSizeKey = "chat.textSize"
    /// Send's tap (and Return) while the agent works, as the Mac's Settings › Chat mode; the composer reads it
    /// (`@AppStorage`).
    nonisolated static let chatSendWhileWorkingKey = "chat.sendWhileWorking"
    /// New drafts start in editor mode (`ChatDraft.editorByDefault`), as the Mac's Settings › Chat mode.
    nonisolated static let chatEditorByDefaultKey = "chat.editorByDefault"
    /// What an agent tab opens on (`TabSegment.initial`), as the Mac's Settings › Chat mode.
    nonisolated static let chatAgentStartKey = "chat.agentStart"
    /// The composer's code keys row ("+" › Show code keys), off by default; the composer reads it (`@AppStorage`).
    nonisolated static let composerCodeKeysKey = "composer.codeKeys"
    nonisolated static let notifyNeedsYouKey = "notify.needsYou"
    nonisolated static let notifyFinishedKey = "notify.finished"
    nonisolated static let notifyFailedKey = "notify.failed"
    nonisolated static let notificationSoundKey = "notify.sound"
    nonisolated static let notificationTextKey = "notify.text"
    nonisolated static let notificationBadgeKey = "notify.badge"
    nonisolated static let colorVisionKey = "colorVision"
    nonisolated static let hostColorsKey = "hosts.colors"

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

    /// The app's theme (G4): Automatic follows Appearance; Graphite, Lavender and Nautical each have
    /// their own scheme (`MobileTheme`). The root reads the same key (`mobileAppearance()`).
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

    /// The font's code ligatures, on by default (the Mac's Ligatures).
    var ligatures: Bool {
        didSet { if ligatures != oldValue { save(ligatures, Self.ligaturesKey) } }
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

    /// An agent tab opens on Chat or on its terminal.
    var chatAgentStart: ChatAgentStart {
        didSet {
            TabSegment.agentStart = chatAgentStart
            if chatAgentStart != oldValue { defaults.set(chatAgentStart.rawValue, forKey: Self.chatAgentStartKey) }
        }
    }

    /// New drafts start in editor mode: a hardware keyboard's Return adds a line and ⌘Return sends.
    var chatEditorByDefault: Bool {
        didSet {
            ChatDraft.editorByDefault = chatEditorByDefault
            if chatEditorByDefault != oldValue { defaults.set(chatEditorByDefault, forKey: Self.chatEditorByDefaultKey) }
        }
    }

    /// Queue (send's long press steers) or steer (its long press queues) a message while the agent works.
    var chatSendWhileWorking: ChatSendWhileWorking {
        didSet {
            if chatSendWhileWorking != oldValue { defaults.set(chatSendWhileWorking.rawValue, forKey: Self.chatSendWhileWorkingKey) }
        }
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

    /// Colorblind-friendly (the Mac's `colorVision`): hosts take that vision's colours (`HostColor.look`), diffs its
    /// schemes' (`CodePalette.added`), and Color scheme lists only its schemes (`TerminalSchemes.listed`). Turning it on,
    /// off or to the other vision gives the terminal that vision's scheme on the same side, or Dispatch's.
    var colorVision: ColorVision {
        didSet {
            guard colorVision != oldValue else { return }
            defaults.set(colorVision.rawValue, forKey: Self.colorVisionKey)
            applyHostColors()
            conformScheme()
        }
    }

    /// Color-code hosts (the Mac's `showHostColors`); off draws every host in neutral grey.
    var showHostColors: Bool {
        didSet {
            guard showHostColors != oldValue else { return }
            defaults.set(showHostColors, forKey: Self.hostColorsKey)
            applyHostColors()
        }
    }

    /// Where host colours are drawn from (`HostTint`): the composition sets `HostColorStore.shared`; tests leave it nil
    /// or give their own.
    @ObservationIgnored var hostColors: HostColorStore? {
        didSet { applyHostColors() }
    }

    private func applyHostColors() {
        guard let hostColors else { return }
        if hostColors.vision != colorVision { hostColors.vision = colorVision }
        if hostColors.enabled != showHostColors { hostColors.enabled = showHostColors }
    }

    /// A scheme not made for `colorVision` gives way to that vision's own on the same side, or, leaving colorblind mode,
    /// to Dispatch's (the Mac's `conformSchemes`).
    private func conformScheme() {
        guard ColorVision(bundledScheme: terminalScheme) != colorVision else { return }
        guard let own = ColorVision.bundledSchemes[colorVision] else {
            terminalScheme = TerminalConfiguration.defaultScheme
            return
        }
        let dark = TerminalSchemes.url(terminalScheme).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { TerminalSchemes.parse($0, file: terminalScheme).isDark } ?? true
        terminalScheme = (dark ? own.dark : own.light).first ?? terminalScheme
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
        ligatures = style.ligatures
        lineSpacing = style.lineSpacing
        chatFont = defaults.string(forKey: Self.chatFontKey).flatMap(MobileChatFont.init(rawValue:)) ?? .system
        chatTextSize = defaults.string(forKey: Self.chatTextSizeKey).flatMap(ChatTextSize.init(rawValue:)) ?? .standard
        chatSendWhileWorking = defaults.string(forKey: Self.chatSendWhileWorkingKey).flatMap(ChatSendWhileWorking.init(rawValue:)) ?? .queue
        chatEditorByDefault = defaults.bool(forKey: Self.chatEditorByDefaultKey)
        chatAgentStart = defaults.string(forKey: Self.chatAgentStartKey).flatMap(ChatAgentStart.init(rawValue:)) ?? .chat
        notifyNeedsYou = defaults.object(forKey: Self.notifyNeedsYouKey) as? Bool ?? true
        notifyFinished = defaults.object(forKey: Self.notifyFinishedKey) as? Bool ?? true
        notifyFailed = defaults.object(forKey: Self.notifyFailedKey) as? Bool ?? true
        notificationSound = defaults.string(forKey: Self.notificationSoundKey).flatMap(NotificationSound.init(rawValue:)) ?? .standard
        notificationText = defaults.object(forKey: Self.notificationTextKey) as? Bool ?? true
        notificationBadge = defaults.object(forKey: Self.notificationBadgeKey) as? Bool ?? true
        colorVision = defaults.string(forKey: Self.colorVisionKey).flatMap(ColorVision.init(rawValue:)) ?? .typical
        showHostColors = defaults.object(forKey: Self.hostColorsKey) as? Bool ?? true
        // What the shared models read (`didSet` does not run in an initializer).
        ChatDraft.editorByDefault = chatEditorByDefault
        TabSegment.agentStart = chatAgentStart
    }

    @ObservationIgnored private var outsideChanges: (any NSObjectProtocol)?

    isolated deinit {
        if let outsideChanges { NotificationCenter.default.removeObserver(outsideChanges) }
    }

    /// The Settings app's Dispatch page (`Settings.bundle`) writes the same keys while the app is away; iOS posts the
    /// change when it is back. What changed is taken (`reload`), and `changed` runs after (the badge follows its switch).
    func followOutsideChanges(_ changed: @escaping @MainActor @Sendable () -> Void) {
        outsideChanges = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                                queue: nil) { [weak self, defaults] note in
            // Changes made outside the process have no object; other suites' writes are not ours.
            guard note.object == nil || note.object as AnyObject === defaults else { return }
            // After the write that posted, never inside one of this model's own setters.
            Task { @MainActor in if self?.reload() == true { changed() } }
        }
    }

    /// Takes what the defaults hold now and differs, through the setters: a terminal setting restyles the open
    /// terminals. True when something changed.
    @discardableResult
    func reload() -> Bool {
        let saved = MobileSettings(defaults: defaults)
        var changed = false
        func take<Value: Equatable>(_ key: ReferenceWritableKeyPath<MobileSettings, Value>) {
            guard self[keyPath: key] != saved[keyPath: key] else { return }
            self[keyPath: key] = saved[keyPath: key]
            changed = true
        }
        take(\.autoApproveUnsafePastes)
        take(\.appearance)
        take(\.backgroundRefresh)
        take(\.dictationEngine)
        take(\.whisperModel)
        take(\.theme)
        take(\.terminalFont)
        take(\.terminalScheme)
        take(\.textContrast)
        take(\.boldIsBright)
        take(\.cursor)
        take(\.cursorBlink)
        take(\.ligatures)
        take(\.lineSpacing)
        take(\.chatFont)
        take(\.chatTextSize)
        take(\.chatSendWhileWorking)
        take(\.chatEditorByDefault)
        take(\.chatAgentStart)
        take(\.notifyNeedsYou)
        take(\.notifyFinished)
        take(\.notifyFailed)
        take(\.notificationSound)
        take(\.notificationText)
        take(\.notificationBadge)
        take(\.showHostColors)
        // After the scheme: a new vision conforms the scheme, which the saved one must not undo.
        take(\.colorVision)
        return changed
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
