import AppKit
import Observation

enum AppTheme: String, Codable, CaseIterable {
    case automatic, dark, light, graphite, lavender

    var label: String { rawValue.capitalized }

    func sidebarTheme(systemIsDark: Bool) -> SidebarTheme {
        switch self {
        case .automatic: systemIsDark ? .dark : .light
        case .dark: .dark
        case .light: .light
        case .graphite: .graphite
        case .lavender: .lavender
        }
    }

    func isDark(systemIsDark: Bool) -> Bool {
        sidebarTheme(systemIsDark: systemIsDark) == .dark
    }
}

enum SpaceOrder: String, Codable, CaseIterable { case flat, tree, urgency }

/// How the sidebar draws spaces: the dense compact list, Large's glass cards (host orb, name, details and status), or
/// the host picker's rows, each led by its host's icon.
enum SidebarStyle: String, Codable, CaseIterable {
    case compact, large, icons
    /// From the densest list to the roomiest, as Settings' space size slider steps through them.
    static let bySize: [SidebarStyle] = [.compact, .icons, .large]
    var label: String {
        switch self {
        case .compact: "Compact"
        case .large: "Large"
        case .icons: "Normal"
        }
    }
}

/// What a first SSH connection to a new host does about the Dispatch helper.
enum NewHostPolicy: String, CaseIterable {
    case ask, full, plain
    var label: String {
        switch self {
        case .ask: "Ask"
        case .full: "Full features"
        case .plain: "Plain SSH"
        }
    }
}

/// How remote tabs show their host: Liquid Glass tints them (host wash and tinted tabs, no top border; a pane
/// without a tab strip keeps the border); flat chrome draws the top border alone. Follows Liquid Glass; not a setting of its own.
enum RemoteTabHighlight {
    case fade, border

    @MainActor static var current: Self { LiquidGlassStore.shared.active ? .fade : .border }
}

enum ChatFont: String, Codable, CaseIterable {
    case sameAsCode = "Same as code"
    case comicSans = "Comic Sans"
    case system = "System UI"

    // Match median rendered lowercase height, not font-reported x-height, to Source Code Pro at 14 pt.
    // Named fonts keep this calibration when the code font changes; Same as code stays unscaled.
    // Recalibrate after font replacements with `swift scripts/measure-chat-fonts.swift`.
    var sizeScale: CGFloat {
        switch self {
        case .sameAsCode, .system: 1
        case .comicSans: 0.907
        }
    }

    var postScriptName: String? {
        switch self {
        case .comicSans: "ComicSansMS"
        case .sameAsCode, .system: nil
        }
    }
}

struct Preferences: Codable, Equatable {
    var spaceOrder = SpaceOrder.flat
    /// Tabs follow the agent's conversation, a running program's title, then the folder.
    var automaticTabNames = true
    var fontFamily = "Source Code Pro"
    var chatFont = ChatFont.system
    var fontSize = 12.5
    /// The host picker's rows are the default.
    var sidebarStyle = SidebarStyle.icons
    /// Any but the dense, compact sidebar; setting it picks large or compact.
    var largeSidebarItems: Bool {
        get { sidebarStyle != .compact }
        set { sidebarStyle = newValue ? .large : .compact }
    }
    /// Branch names beside each space; used to come with large sidebar items.
    var showGitBranches = false
    /// macOS 26 Liquid Glass for the chat input, tab strips and sidebar, the same in a window and full screen.
    /// On by default; earlier systems ignore it and keep the flat chrome.
    var liquidGlass = true
    /// With Liquid Glass, the sidebar is Dispatch's glass panel floating over the content; off, it is a column at the
    /// window's edge in AppKit's sidebar glass, as in Finder and Mail.
    var liquidSidebar = true
    /// Colors chosen for SSH hosts, by HostTint.machine; others keep their automatic color.
    var hostColors: [String: HostColor] = [:]
    /// Off draws remote hosts in neutral gray: they stay marked, but not by hue.
    var showHostColors = true
    var sidebarMetrics: SidebarMetrics { sidebarMetrics(glass: false) }
    func sidebarMetrics(glass: Bool) -> SidebarMetrics {
        switch sidebarStyle {
        case .compact: .compact(contentSize: fontSize)
        case .large: .large(contentSize: fontSize, glass: glass)
        case .icons: .icons(contentSize: fontSize)
        }
    }
    var sidebarFontSize: Double { sidebarMetrics.nameSize }
    // Reserve the activity slot even when idle so loading never resizes a tile.
    var sidebarRowHeight: Double { sidebarMetrics.rowHeight }
    var appTheme = AppTheme.automatic
    var theme = "Default"
    var lightTheme = "Default"
    var improveTextContrast = false
    var optionAsAlt = true
    /// tmux- or herdr-style ⌃B prefix keys in native spaces; off by default because ⌃B is a shell
    /// and editor key there.
    var prefixKeys = PrefixStyle.off
    /// tmux and herdr spaces answer their own tool's prefix keys.
    var backendPrefixKeys = true
    /// The modifiers for choosing spaces, tabs and layouts with the digit keys.
    var keyGroups = KeyGroups()
    var enableDiagnostics = false
    var hideSingleSpace = true
    /// Per multiplexer (the helper's name): open its sessions started in terminals as spaces.
    var spaces: [String: Bool] = [:]
    /// Per multiplexer: close the launching tab once its client attaches. Settings no longer shows it, so it stays on
    /// unless an older settings file turned it off; tests turn it off to keep the launching tab.
    var closeLaunching: [String: Bool] = [:]
    /// Kitty's terminal image protocol. Disabled unless the user explicitly opts in.
    var enableKittyGraphics = false
    var rememberHosts = true
    /// Plain local and SSH tabs' output, saved as the app quits for the next launch (with rememberHosts).
    var restoreTerminalOutput = false
    /// Off means Plain SSH for new hosts: the helper is never uploaded.
    var enableHostDetection = true
    /// With the helper allowed, new hosts get every feature instead of the consent sheet.
    var autoGrantNewHosts = false
    /// Programs on this Mac and over plain SSH can always set the clipboard (OSC 52,
    /// kitty clipboard, tmux buffers). On hosts with the helper, only when this is on (the default).
    var allowRemoteClipboardWrites = true
    /// A helper connection lost while Dispatch runs logs back in by itself, with keys or the SSH agent only.
    var autoReconnectSSH = false
    var newHostPolicy: NewHostPolicy {
        get { !enableHostDetection ? .plain : autoGrantNewHosts ? .full : .ask }
        set { enableHostDetection = newValue != .plain; autoGrantNewHosts = newValue == .full }
    }
    var attentionNotifications = true
    var attentionDockBadge = true
    var attentionSound = true
    var startingDirectory = NSHomeDirectory()

    func resolvedTheme(systemIsDark: Bool) -> String {
        let selected = appTheme.isDark(systemIsDark: systemIsDark) ? theme : lightTheme
        return selected == "Default" ? "dispatch-black" : selected
    }

    func usesDefaultColorScheme(systemIsDark: Bool) -> Bool {
        (appTheme.isDark(systemIsDark: systemIsDark) ? theme : lightTheme) == "Default"
    }

    @MainActor var resolvedSidebarTheme: SidebarTheme {
        appTheme.sidebarTheme(systemIsDark: SidebarThemeStore.systemIsDark)
    }

    init() {}

    // Settings saved by earlier local builds gain defaults for new fields.
    // Explicit user choices remain unchanged.
    private enum CodingKeys: String, CodingKey {
        case enableHostDetection, autoGrantNewHosts, allowRemoteClipboardWrites, autoReconnectSSH, attentionNotifications, attentionDockBadge, attentionSound
        case spaceOrder, automaticTabNames, fontFamily, chatFont, fontSize, appTheme, theme, lightTheme, optionAsAlt
        case prefixKeys, backendPrefixKeys, keyGroups
        case hideSingleSpace, startingDirectory, rememberHosts, restoreTerminalOutput
        case enableDiagnostics
        case sidebarStyle, showGitBranches, liquidGlass, liquidSidebar, hostColors, showHostColors
        case improveTextContrast
        case spaces, closeLaunching, enableKittyGraphics
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case autoCloseNativeSpace, sidebarTheme, appearance, largeSidebarItems, systemSidebar
        case enableTmuxIntegration, enableHerdrIntegration, autoCloseTmuxNativeSpace, autoCloseHerdrNativeSpace
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        enableHostDetection = try fields.decodeIfPresent(Bool.self, forKey: .enableHostDetection) ?? enableHostDetection
        autoGrantNewHosts = try fields.decodeIfPresent(Bool.self, forKey: .autoGrantNewHosts) ?? autoGrantNewHosts
        allowRemoteClipboardWrites = try fields.decodeIfPresent(Bool.self, forKey: .allowRemoteClipboardWrites) ?? allowRemoteClipboardWrites
        autoReconnectSSH = try fields.decodeIfPresent(Bool.self, forKey: .autoReconnectSSH) ?? autoReconnectSSH
        attentionNotifications = try fields.decodeIfPresent(Bool.self, forKey: .attentionNotifications) ?? attentionNotifications
        attentionDockBadge = try fields.decodeIfPresent(Bool.self, forKey: .attentionDockBadge) ?? attentionDockBadge
        attentionSound = try fields.decodeIfPresent(Bool.self, forKey: .attentionSound) ?? attentionSound
        spaceOrder = try fields.decodeIfPresent(SpaceOrder.self, forKey: .spaceOrder) ?? spaceOrder
        // Replaces `tabNaming`, whose stored "terminal" was usually the old default rather than a choice.
        automaticTabNames = try fields.decodeIfPresent(Bool.self, forKey: .automaticTabNames) ?? automaticTabNames
        fontFamily = try fields.decodeIfPresent(String.self, forKey: .fontFamily) ?? fontFamily
        // Removed font choices fall back without discarding the other settings.
        chatFont = try fields.decodeIfPresent(String.self, forKey: .chatFont).flatMap(ChatFont.init(rawValue:)) ?? chatFont
        fontSize = try fields.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        // Replaces `largeSidebarItems`. Every save wrote it, so on was usually the old default rather than a choice:
        // it takes the new default, while off, an explicit choice, stays compact. An unknown style keeps the default.
        let large = try legacy.decodeIfPresent(Bool.self, forKey: .largeSidebarItems)
        sidebarStyle = try fields.decodeIfPresent(String.self, forKey: .sidebarStyle).flatMap(SidebarStyle.init(rawValue:))
            ?? (large == false ? .compact : sidebarStyle)
        // Large sidebar items used to show branches; keep them for users who chose large
        // explicitly, not for everyone now that large is the default.
        showGitBranches = try fields.decodeIfPresent(Bool.self, forKey: .showGitBranches) ?? large ?? showGitBranches
        liquidGlass = try fields.decodeIfPresent(Bool.self, forKey: .liquidGlass) ?? liquidGlass
        // Replaces `systemSidebar`, its inverse.
        liquidSidebar = try fields.decodeIfPresent(Bool.self, forKey: .liquidSidebar)
            ?? legacy.decodeIfPresent(Bool.self, forKey: .systemSidebar).map(!) ?? liquidSidebar
        // An unknown color drops only that host's choice.
        hostColors = try fields.decodeIfPresent([String: String].self, forKey: .hostColors)?
            .compactMapValues(HostColor.init(rawValue:)) ?? hostColors
        showHostColors = try fields.decodeIfPresent(Bool.self, forKey: .showHostColors) ?? showHostColors
        if let selected = try fields.decodeIfPresent(AppTheme.self, forKey: .appTheme) {
            appTheme = selected
        } else if let palette = try legacy.decodeIfPresent(SidebarTheme.self, forKey: .sidebarTheme), palette != .dark {
            appTheme = AppTheme(rawValue: palette.rawValue) ?? .automatic
        } else {
            let mode = try legacy.decodeIfPresent(String.self, forKey: .appearance)
            appTheme = mode.flatMap(AppTheme.init(rawValue:)) ?? .automatic
        }
        let savedTheme = try fields.decodeIfPresent(String.self, forKey: .theme)
        theme = savedTheme ?? theme
        lightTheme = try fields.decodeIfPresent(String.self, forKey: .lightTheme) ?? theme
        improveTextContrast = try fields.decodeIfPresent(Bool.self, forKey: .improveTextContrast) ?? improveTextContrast
        optionAsAlt = try fields.decodeIfPresent(Bool.self, forKey: .optionAsAlt) ?? optionAsAlt
        prefixKeys = try fields.decodeIfPresent(String.self, forKey: .prefixKeys).flatMap(PrefixStyle.init(rawValue:)) ?? prefixKeys
        backendPrefixKeys = try fields.decodeIfPresent(Bool.self, forKey: .backendPrefixKeys) ?? backendPrefixKeys
        keyGroups = try fields.decodeIfPresent(KeyGroups.self, forKey: .keyGroups) ?? keyGroups
        rememberHosts = try fields.decodeIfPresent(Bool.self, forKey: .rememberHosts) ?? rememberHosts
        restoreTerminalOutput = try fields.decodeIfPresent(Bool.self, forKey: .restoreTerminalOutput) ?? restoreTerminalOutput
        enableDiagnostics = try fields.decodeIfPresent(Bool.self, forKey: .enableDiagnostics) ?? false
        hideSingleSpace = try fields.decodeIfPresent(Bool.self, forKey: .hideSingleSpace) ?? hideSingleSpace
        spaces = try fields.decodeIfPresent([String: Bool].self, forKey: .spaces) ?? [:]
        closeLaunching = try fields.decodeIfPresent([String: Bool].self, forKey: .closeLaunching) ?? [:]
        enableKittyGraphics = try fields.decodeIfPresent(Bool.self, forKey: .enableKittyGraphics) ?? enableKittyGraphics
        // Settings saved before the per-multiplexer keys.
        let autoClose = try legacy.decodeIfPresent(Bool.self, forKey: .autoCloseNativeSpace) ?? true
        for (name, open, close) in [("tmux", LegacyCodingKeys.enableTmuxIntegration, LegacyCodingKeys.autoCloseTmuxNativeSpace),
                                    ("herdr", .enableHerdrIntegration, .autoCloseHerdrNativeSpace)] {
            if spaces[name] == nil { spaces[on: name] = try legacy.decodeIfPresent(Bool.self, forKey: open) ?? true }
            if closeLaunching[name] == nil { closeLaunching[on: name] = try legacy.decodeIfPresent(Bool.self, forKey: close) ?? autoClose }
        }
        startingDirectory = try fields.decodeIfPresent(String.self, forKey: .startingDirectory) ?? startingDirectory
    }
}

/// Where the app's files live: the user's home, or one fresh home per test run (DISPATCH_TESTING:
/// the test host is the app itself), so tests never touch the user's files, Dispatch's own or the
/// agent homes it installs hooks into.
enum Home {
    static let testing = ProcessInfo.processInfo.environment["DISPATCH_TESTING"] == "1"
    static let url = testing ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dispatch-home-" + UUID().uuidString)
        : URL(fileURLWithPath: NSHomeDirectory())
    /// The variables that move the agents' homes (CODEX_HOME...): the app's, none while testing.
    static var environment: [String: String] { testing ? [:] : ProcessInfo.processInfo.environment }
    /// Dispatch's own files.
    static var support: URL { url.appendingPathComponent("Library/Application Support/Dispatch") }

    /// Background agents must not inherit the application's working directory.
    static func agentDirectory(_ known: String?) throws -> URL {
        if let known, known.hasPrefix("/") { return URL(fileURLWithPath: known) }
        let directory = support.appendingPathComponent("Agents/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return directory
    }

    /// While testing, this process's own environment moves to the test home (HOME there, no
    /// variables that move an agent's home): every process it starts, however, inherits it.
    static func isolate() {
        guard testing else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        setenv("HOME", url.path, 1)
        for name in ["CODEX_HOME", "CLAUDE_CONFIG_DIR", "PI_CODING_AGENT_DIR"] { unsetenv(name) }
    }
}

extension UserDefaults {
    /// The app's defaults: none while testing, so its stores never persist into the user's own.
    static var app: UserDefaults? { Home.testing ? nil : .standard }
}

@MainActor @Observable
final class SettingsStore {
    var values = Preferences()
    var error: String?
    @ObservationIgnored var onSave: ((Preferences) -> Void)?
    private let file: URL

    init(file: URL? = nil) {
        self.file = file ?? Home.support.appendingPathComponent("Local/settings.json")
        guard FileManager.default.fileExists(atPath: self.file.path) else { return }
        do {
            let loaded = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: self.file))
            try Self.validate(loaded)
            values = loaded
        }
        catch { self.error = "Could not load settings: \(error.localizedDescription)" }
    }

    func save(_ preferences: Preferences) throws {
        try Self.validate(preferences)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preferences).write(to: file, options: .atomic)
        values = preferences
        error = nil
        onSave?(preferences)
    }

    static func validate(_ preferences: Preferences) throws {
        guard (8...32).contains(preferences.fontSize), !preferences.fontFamily.contains(where: \.isNewline),
              !preferences.theme.contains(where: \.isNewline),
              !preferences.theme.isEmpty,
              !preferences.lightTheme.contains(where: \.isNewline), !preferences.lightTheme.isEmpty,
              !preferences.fontFamily.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw SettingsError.invalidFont
        }
        if let problem = preferences.keyGroups.problem { throw SettingsError.invalidKeyGroups(problem) }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: preferences.startingDirectory, isDirectory: &directory), directory.boolValue else {
            throw SettingsError.invalidDirectory
        }
    }

    enum SettingsError: LocalizedError {
        case invalidFont, invalidDirectory, invalidKeyGroups(String)
        var errorDescription: String? {
            switch self {
            case .invalidFont: "Choose a font name and a size between 8 and 32 points."
            case .invalidDirectory: "Choose an existing starting folder."
            case .invalidKeyGroups(let problem): problem
            }
        }
    }
}

extension Dictionary where Key == String, Value == Bool {
    /// A per-name switch that is on unless set off; only `false` is stored, so on == absent.
    subscript(on name: String) -> Bool {
        get { self[name] ?? true }
        set { self[name] = newValue ? nil : false }
    }
}
