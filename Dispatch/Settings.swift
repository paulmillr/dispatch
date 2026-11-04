import AppKit
import Dictation
import Observation

enum AppTheme: String, Codable, CaseIterable {
    case automatic, dark, light, nautical

    func sidebarTheme(systemIsDark: Bool) -> SidebarTheme {
        switch self {
        case .automatic: systemIsDark ? .dark : .light
        case .dark: .dark
        case .light: .light
        case .nautical: .nautical
        }
    }

    func isDark(systemIsDark: Bool) -> Bool {
        sidebarTheme(systemIsDark: systemIsDark).isDark
    }

    /// The code that unlocks Nautical when typed in the Settings window. Nautical is an easter egg: Settings shows its
    /// switch once the code is typed, or while it is the theme.
    static let nauticalCode = "dispatch.yachts"
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
/// The terminal cursor a program has not chosen (Ghostty's cursor-style).
enum TerminalCursor: String, Codable, CaseIterable {
    case block, bar, underline
    var title: String { rawValue.capitalized }
}

/// Which Option keys act as Alt in the terminal (Ghostty's macos-option-as-alt); the other types characters.
enum OptionKeys: String, Codable, CaseIterable {
    case both, left, right, off
    var title: String {
        switch self {
        case .both: "Both"
        case .left: "Left only"
        case .right: "Right only"
        case .off: "Off"
        }
    }
    var ghostty: String {
        switch self {
        case .both: "true"
        case .left: "left"
        case .right: "right"
        case .off: "false"
        }
    }
}

/// The key that dictates (Settings › Keyboard › Voice; DictationShortcut): held alone, one message; tapped,
/// conversation mode. With another key or a click it is an ordinary modifier.
enum VoiceKey: String, Codable, CaseIterable {
    case rightCommand, rightOption, function, off
    var title: String {
        switch self {
        case .rightCommand: "Right ⌘"
        case .rightOption: "Right ⌥"
        case .function: "fn 🌐"
        case .off: "Off"
        }
    }
    /// How hints name it: "hold right ⌘".
    var name: String {
        switch self {
        case .rightCommand: "right ⌘"
        case .rightOption: "right ⌥"
        case .function: "fn"
        case .off: ""
        }
    }
}

/// Each new terminal's scrollback: sized from the Mac's memory, a fixed size, unlimited, or a number of lines (which
/// keeps the memory-sized limit too: whichever is reached first).
enum Scrollback: String, Codable, CaseIterable {
    case automatic, small, large, unlimited, lines10k = "lines10000", lines100k = "lines100000"
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .small: "10 MB"
        case .large: "1 GB"
        case .unlimited: "Unlimited"
        case .lines10k: "10,000 lines"
        case .lines100k: "100,000 lines"
        }
    }
    /// scrollback-limit-bytes; `automatic` and the line counts take the memory-sized default.
    func limit(automatic: Int) -> String {
        switch self {
        case .automatic, .lines10k, .lines100k: String(automatic)
        case .small: String(10_000_000)
        case .large: String(1_000_000_000)
        case .unlimited: "unlimited"
        }
    }
    /// scrollback-limit-lines (nil: no line limit). Ghostty counts lines besides the screen, soft-wrapped ones each,
    /// and drops whole pages: a terminal keeps up to this many, at most a page (a few hundred lines) fewer.
    var lines: Int? {
        switch self {
        case .lines10k: 10_000
        case .lines100k: 100_000
        case .automatic, .small, .large, .unlimited: nil
        }
    }
    /// The sizes, then the line counts (the dropdown's two groups).
    static let sizes: [Scrollback] = [.automatic, .small, .large, .unlimited], lineCounts: [Scrollback] = [.lines10k, .lines100k]
}

/// Settings › Features › Remote helper and its Auto-confirm uploads, as one choice: ask on a new host, grant every
/// feature without asking, or plain SSH everywhere.
enum NewHostPolicy: String, CaseIterable {
    case ask, full, plain
}

/// How remote tabs show their host: Liquid Glass tints them (host wash and tinted tabs, no top border; a pane
/// without a tab strip keeps the border); flat chrome draws the top border alone. Follows Liquid Glass; not a setting of its own.
enum RemoteTabHighlight {
    case fade, border

    @MainActor static var current: Self { LiquidGlassStore.shared.active ? .fade : .border }
}

typealias ChatFont = ChatFontChoice

extension ChatFontChoice {

    /// The system font's own designs: drawn as the system font, never by name. San Francisco draws in SF Rounded,
    /// whose missing italic is San Francisco's own (`italic(for:)`).
    var systemDesign: NSFontDescriptor.SystemDesign? {
        switch self {
        case .system: .rounded
        case .newYork: .serif
        case .sameAsCode, .comicSans, .latinModernRoman: nil
        }
    }

    /// The system font in this choice's design; nil for fonts drawn by name.
    func systemFont(ofSize size: CGFloat) -> NSFont? {
        guard let design = systemDesign else { return nil }
        let font = NSFont.systemFont(ofSize: size)
        return font.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? font
    }

    /// SF Rounded has no italic (Apple ships none): asked for one, `font` (any rounded system face) comes back upright,
    /// so emphasis draws San Francisco's italic at its size and weight. nil for every other face.
    static func italic(for font: CTFont) -> CTFont? {
        guard !CTFontGetSymbolicTraits(font).contains(.traitItalic),
              CTFontCopyFamilyName(font) as String == ChatFont.system.systemFont(ofSize: 12)?.familyName else { return nil }
        let weight = (CTFontCopyTraits(font) as? [CFString: Any])?[kCTFontWeightTrait] as? CGFloat ?? 0
        let upright = NSFont.systemFont(ofSize: CTFontGetSize(font), weight: NSFont.Weight(weight))
        return CTFontCreateCopyWithSymbolicTraits(upright, CTFontGetSize(font), nil, .traitItalic, .traitItalic)
    }

    /// Draws the face at Source Code Pro's lowercase height, measured from its outlines as terminal fonts are
    /// (`TerminalFontScale`); the reference stays Source Code Pro whatever the code font. Same as code stays unscaled,
    /// and a face that isn't installed keeps 1. `swift scripts/measure-fonts.swift` prints every role's result.
    var sizeScale: CGFloat {
        if self == .sameAsCode { return 1 }
        guard let font = systemFont(ofSize: 16) ?? postScriptName.flatMap({ NSFont(name: $0, size: 16) }) else { return 1 }
        return CGFloat(TerminalFontScale.factor(font as CTFont))
    }

    var postScriptName: String? { namedFace(on: .macOS) }

    /// Latin Modern Mono (chat's Same as code with it as the terminal font) has no bold of its own: its bold faces are
    /// Latin Modern Mono Light's, as TeX pairs them. nil: the face bolds within its own family.
    static func boldPostScriptName(_ name: String) -> String? {
        switch name {
        case "LMMono10-Regular": "LMMonoLt10-Bold"
        case "LMMono10-Italic": "LMMonoLt10-BoldOblique"
        default: nil
        }
    }
}

/// The app's own text: tabs, the sidebar, Files, Git and Settings. Terminals and chat keep their own fonts.
enum InterfaceFont: String, Codable, CaseIterable {
    case system = "San Francisco"
    case sourceCodePro = "Source Code Pro"
}

struct Preferences: Codable, Equatable {
    var spaceOrder = SpaceOrder.flat
    /// Tabs follow the agent's conversation, a running program's title, then the folder.
    var automaticTabNames = true
    var fontFamily = TerminalFontCatalog.defaultFamily
    /// The code font's ligatures (`->` as an arrow, in Hasklig, Fira Code…) in terminals, code and the file preview.
    var fontLigatures = true
    var chatFont = ChatFont.system
    var interfaceFont = InterfaceFont.system
    /// Terminal and interface text: Source Code Pro at 14 has the lowercase height of the system's 13-point text, and
    /// every terminal font draws at that apparent size (`TerminalFontScale`). Layouts grow from a 12.5 design base
    /// (`AppTypography.expanded`).
    var fontSize = 14.0
    /// The host picker's rows are the default.
    var sidebarStyle = SidebarStyle.icons
    /// Any but the dense, compact sidebar; setting it picks large or compact.
    var largeSidebarItems: Bool {
        get { sidebarStyle != .compact }
        set { sidebarStyle = newValue ? .large : .compact }
    }
    /// Branch names beside each space; used to come with large sidebar items.
    var showGitBranches = false
    /// Branch names show only while git is on.
    var showsGitBranches: Bool { showGitBranches && gitEnabled }
    /// macOS 26 Liquid Glass for the chat input, tab strips and sidebar, the same in a window and full screen.
    /// On by default; earlier systems ignore it and keep the flat chrome.
    var liquidGlass = true
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
    var textContrast = TextContrast.lightThemes
    /// Contrast on every scheme; off leaves the light-theme default (imports, which can't say which side they mean).
    var improveTextContrast: Bool {
        get { textContrast == .always }
        set { textContrast = newValue ? .always : .lightThemes }
    }
    /// Colorblind-friendly: the scheme pickers offer only schemes made for this vision, and new schemes are made for it.
    var colorVision = ColorVision.typical
    /// How opaque terminals' backgrounds are, `terminalOpacityRange`; below 1 the desktop shows through terminals only.
    var terminalOpacity = 1.0
    /// Lower and text over a busy desktop stops reading, whatever the scheme.
    static let terminalOpacityRange = 0.6...1.0
    var optionAsAlt = OptionKeys.both
    var cursor = TerminalCursor.block
    var cursorBlink = true
    /// The terminal's rows and chat's lines together (Settings › General › Text).
    var lineSpacing = LineSpacing.normal
    var scrollback = Scrollback.automatic
    /// Which spaces answer ⌃B prefix keys: tmux and herdr spaces their own tool's, native spaces tmux's. Native
    /// spaces are left out by default because ⌃B is a shell and editor key there.
    var prefixKeys = PrefixSpaces.multiplexers
    /// The modifiers for choosing spaces, tabs and layouts with the digit keys.
    var keyGroups = KeyGroups()
    var enableDiagnostics = false
    /// Settings › Experimental › Slow connection mode: helpers started from then on keep at most 256 KB of terminal output in
    /// flight to this app (`terminals.window`, HelperOutputWindow), so a keystroke or a reply never waits behind megabytes
    /// parked in SSH and TCP buffers on a slow link. Off: output streams as before.
    var outputWindow = false
    /// Settings › Experimental › Host icons in group headings: in the icons sidebar grouped by host, each host's icon
    /// shows once, at the end of its group's heading, and the rows lead with their activity instead of the host's disc
    /// (SidebarMetrics.hostInHeader).
    var hostHeaderIcons = false
    var hideSingleSpace = true
    /// Tabs only: no tab strips, and the sidebar lists every tab (a tmux or herdr space's windows) instead of spaces,
    /// with "+ tab" in place of "+ space". Spaces still exist underneath (⌘N, splits, layouts); they are just not shown.
    var tabsOnly = false
    /// Per multiplexer (the helper's name): open its sessions started in terminals as spaces.
    var spaces: [String: Bool] = [:]
    /// Kitty's terminal image protocol. Disabled unless the user explicitly opts in.
    var enableKittyGraphics = false
    var rememberHosts = true
    /// Plain local and SSH tabs' output, saved as the app quits for the next launch (with rememberHosts).
    var restoreTerminalOutput = false
    /// Off means Plain SSH for new hosts: the helper is never uploaded.
    var enableHostDetection = true
    /// With the helper allowed, new hosts get every feature instead of the consent sheet.
    var autoGrantNewHosts = false
    /// Programs in any tab, local or remote, can set the clipboard (OSC 52, kitty clipboard, tmux buffers). Stored under
    /// its old name, from when it covered helper hosts only.
    var allowClipboardWrites = true
    /// Preserve the existing paste behavior; off asks before an unsafe clipboard paste.
    var autoApproveUnsafePastes = true
    /// A helper connection lost while Dispatch runs logs back in by itself, with keys or the SSH agent only.
    var autoReconnectSSH = false
    /// Keystrokes kept from other apps while Dispatch is active (SecureKeyboardEntry).
    var secureKeyboardEntry = true
    /// nil until onboarding is answered; both nil and false make no automatic update requests.
    var automaticUpdates: Bool? = nil
    var newHostPolicy: NewHostPolicy {
        get { !enableHostDetection ? .plain : autoGrantNewHosts ? .full : .ask }
        set { enableHostDetection = newValue != .plain; autoGrantNewHosts = newValue == .full }
    }
    var attentionNotifications = true
    var attentionDockBadge = true
    var attentionSound = true
    /// Banners carry the agent's text and the pane's folder; off, only the pane and what happened.
    var attentionTextContent = true
    /// Nautical only: a ship's double bell, instead of the attention sound, when an agent finishes in the background.
    var shipsBell = false
    var startingDirectory = System.home.path
    /// What a new local tab runs: empty for the login shell, else a program (by full path) and its arguments.
    var shell = ""
    /// The shell's program, its first word; nil for the login shell.
    var shellProgram: String? {
        let command = shell.trimmingCharacters(in: .whitespaces)
        return command.isEmpty ? nil : String(command.split(separator: " ", maxSplits: 1)[0])
    }
    /// A line typed into each new local shell as it starts (iTerm's "send text at start"); empty types nothing.
    var startupCommand = ""
    /// Files mode itself. Off, no tab offers it and tabs showing it return to their terminals.
    var filesEnabled = true
    /// Files mode: copy in from Finder, out to Finder, or onto a terminal as paths.
    var filesDragAndDrop = true
    /// Each tab's ⇧⌘. overrides this for that tab only (FilesSession.showHidden).
    var filesShowHidden = true
    /// The Files tab's preview. Off, no file's contents are read to show it: the list spans the view and ⌥⌘P does
    /// nothing there (Review's and Commits' diffs still show).
    var filesPreviews = true
    /// The file preview's line numbers.
    var filesLineNumbers = true
    /// The file preview wraps long lines; each tab's wrap button overrides it for that tab (FilesSession.previewWrap).
    var filesWrapLines = false
    /// Git in files mode (the Review and Commits tabs) and the sidebar's branch names. Off, Dispatch reads nothing of any repository.
    var gitEnabled = true
    /// Chat's Return while the agent works: queue the message (⌥⌘⏎ steers) or steer it into the turn (⌥⌘⏎ queues).
    var chatSendWhileWorking = ChatSendWhileWorking.queue
    /// New chat drafts start in editor mode (`ChatDraft.editorByDefault`): Return inserts a newline, ⌘⏎ sends.
    var chatEditorByDefault = false
    /// A tab whose terminal starts an agent shows Chat, or stays on the terminal (`ChatCoordinator.agentStart`).
    var chatAgentStart = ChatAgentStart.chat
    /// How tool groups show in the transcript until opened or closed (`ChatSession.toolSteps`).
    var chatToolSteps = ChatToolGroupDisclosure.current
    /// Chat dictation's engine, and the Whisper model it uses when Whisper is chosen (DictationModelStore downloads it,
    /// and Parakeet's).
    /// Chat's microphone beside Send. Off, the composer shows none.
    var dictationEnabled = true
    /// Hold this key to dictate into the active chat (release inserts, ↩ sends); tap it to dictate hands-free.
    var dictationKey = VoiceKey.rightCommand
    /// "Dispatch, …" switches spaces and tabs (VoiceNavigation) instead of becoming text.
    var dictationNavigation = true
    /// Conversation mode reads its chat's replies aloud and says when other agents finish or need you.
    var dictationReadReplies = true
    /// The words "Dispatch, …" commands start with (WakeWords checks them).
    var dictationWakeWords = VoiceCommand.defaultWakeWords
    var dictationEngine = DictationEngine.apple
    var whisperModel = WhisperModel.small

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
        case automaticUpdates
        case enableHostDetection, autoGrantNewHosts, autoReconnectSSH, secureKeyboardEntry, autoApproveUnsafePastes, attentionNotifications, attentionDockBadge, attentionSound, attentionTextContent, shipsBell
        case spaceOrder, automaticTabNames, fontFamily, fontLigatures, chatFont, fontSize, appTheme, theme, lightTheme, cursor, cursorBlink, lineSpacing, scrollback
        case keyGroups
        case hideSingleSpace, tabsOnly, startingDirectory, shell, startupCommand, rememberHosts, restoreTerminalOutput
        case enableDiagnostics, outputWindow, hostHeaderIcons
        case sidebarStyle, showGitBranches, liquidGlass, hostColors, showHostColors
        case textContrast, colorVision, terminalOpacity
        case spaces, enableKittyGraphics
        case filesEnabled, filesDragAndDrop, filesPreviews, filesLineNumbers, filesWrapLines, gitEnabled
        case chatSendWhileWorking, chatEditorByDefault, chatAgentStart, chatToolSteps
        case dictationEnabled, dictationKey, dictationNavigation, dictationReadReplies, dictationWakeWords, dictationEngine, whisperModel
        // Stored under a new name since hidden files show by default: every save wrote the old key, so its `false`
        // was usually the old default rather than a choice.
        case filesShowHidden = "filesShowHiddenFiles"
        // Renamed when San Francisco became the default: every save had written the old default under the old key.
        case interfaceFont = "interfaceTypeface"
        case allowClipboardWrites = "allowRemoteClipboardWrites"
        case optionAsAlt = "optionKeysAsAlt"
        case prefixKeys = "prefixSpaces"
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        automaticUpdates = try fields.decodeIfPresent(Bool.self, forKey: .automaticUpdates)
        enableHostDetection = try fields.decodeIfPresent(Bool.self, forKey: .enableHostDetection) ?? enableHostDetection
        autoGrantNewHosts = try fields.decodeIfPresent(Bool.self, forKey: .autoGrantNewHosts) ?? autoGrantNewHosts
        allowClipboardWrites = try fields.decodeIfPresent(Bool.self, forKey: .allowClipboardWrites) ?? allowClipboardWrites
        autoApproveUnsafePastes = try fields.decodeIfPresent(Bool.self, forKey: .autoApproveUnsafePastes) ?? autoApproveUnsafePastes
        autoReconnectSSH = try fields.decodeIfPresent(Bool.self, forKey: .autoReconnectSSH) ?? autoReconnectSSH
        secureKeyboardEntry = try fields.decodeIfPresent(Bool.self, forKey: .secureKeyboardEntry) ?? secureKeyboardEntry
        attentionNotifications = try fields.decodeIfPresent(Bool.self, forKey: .attentionNotifications) ?? attentionNotifications
        attentionDockBadge = try fields.decodeIfPresent(Bool.self, forKey: .attentionDockBadge) ?? attentionDockBadge
        attentionSound = try fields.decodeIfPresent(Bool.self, forKey: .attentionSound) ?? attentionSound
        attentionTextContent = try fields.decodeIfPresent(Bool.self, forKey: .attentionTextContent) ?? attentionTextContent
        shipsBell = try fields.decodeIfPresent(Bool.self, forKey: .shipsBell) ?? shipsBell
        spaceOrder = try fields.decodeIfPresent(SpaceOrder.self, forKey: .spaceOrder) ?? spaceOrder
        // Replaces `tabNaming`, whose stored "terminal" was usually the old default rather than a choice.
        automaticTabNames = try fields.decodeIfPresent(Bool.self, forKey: .automaticTabNames) ?? automaticTabNames
        fontFamily = try fields.decodeIfPresent(String.self, forKey: .fontFamily) ?? fontFamily
        fontLigatures = try fields.decodeIfPresent(Bool.self, forKey: .fontLigatures) ?? fontLigatures
        // Removed font choices fall back without discarding the other settings.
        chatFont = try fields.decodeIfPresent(String.self, forKey: .chatFont).flatMap(ChatFont.init(rawValue:)) ?? chatFont
        interfaceFont = try fields.decodeIfPresent(String.self, forKey: .interfaceFont).flatMap(InterfaceFont.init(rawValue:)) ?? interfaceFont
        fontSize = try fields.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        sidebarStyle = try fields.decodeIfPresent(String.self, forKey: .sidebarStyle).flatMap(SidebarStyle.init(rawValue:))
            ?? sidebarStyle
        showGitBranches = try fields.decodeIfPresent(Bool.self, forKey: .showGitBranches) ?? showGitBranches
        liquidGlass = try fields.decodeIfPresent(Bool.self, forKey: .liquidGlass) ?? liquidGlass
        // An unknown color drops only that host's choice.
        hostColors = try fields.decodeIfPresent([String: String].self, forKey: .hostColors)?
            .compactMapValues(HostColor.init(rawValue:)) ?? hostColors
        showHostColors = try fields.decodeIfPresent(Bool.self, forKey: .showHostColors) ?? showHostColors
        // A removed or unknown theme resets only this choice, preserving the rest of the file.
        appTheme = try fields.decodeIfPresent(String.self, forKey: .appTheme).flatMap(AppTheme.init(rawValue:)) ?? appTheme
        theme = try fields.decodeIfPresent(String.self, forKey: .theme) ?? theme
        lightTheme = try fields.decodeIfPresent(String.self, forKey: .lightTheme) ?? lightTheme
        textContrast = try fields.decodeIfPresent(String.self, forKey: .textContrast).flatMap(TextContrast.init(rawValue:))
            ?? textContrast
        colorVision = try fields.decodeIfPresent(String.self, forKey: .colorVision).flatMap(ColorVision.init(rawValue:)) ?? colorVision
        terminalOpacity = (try fields.decodeIfPresent(Double.self, forKey: .terminalOpacity)).map {
            $0.isFinite ? min(max($0, Self.terminalOpacityRange.lowerBound), 1) : 1
        } ?? terminalOpacity
        optionAsAlt = try fields.decodeIfPresent(String.self, forKey: .optionAsAlt).flatMap(OptionKeys.init(rawValue:))
            ?? optionAsAlt
        cursor = try fields.decodeIfPresent(String.self, forKey: .cursor).flatMap(TerminalCursor.init(rawValue:)) ?? cursor
        cursorBlink = try fields.decodeIfPresent(Bool.self, forKey: .cursorBlink) ?? cursorBlink
        lineSpacing = try fields.decodeIfPresent(String.self, forKey: .lineSpacing).flatMap(LineSpacing.init(rawValue:)) ?? lineSpacing
        scrollback = try fields.decodeIfPresent(String.self, forKey: .scrollback).flatMap(Scrollback.init(rawValue:)) ?? scrollback
        prefixKeys = try fields.decodeIfPresent(String.self, forKey: .prefixKeys).flatMap(PrefixSpaces.init(rawValue:))
            ?? prefixKeys
        keyGroups = try fields.decodeIfPresent(KeyGroups.self, forKey: .keyGroups) ?? keyGroups
        rememberHosts = try fields.decodeIfPresent(Bool.self, forKey: .rememberHosts) ?? rememberHosts
        restoreTerminalOutput = try fields.decodeIfPresent(Bool.self, forKey: .restoreTerminalOutput) ?? restoreTerminalOutput
        enableDiagnostics = try fields.decodeIfPresent(Bool.self, forKey: .enableDiagnostics) ?? false
        outputWindow = try fields.decodeIfPresent(Bool.self, forKey: .outputWindow) ?? false
        hostHeaderIcons = try fields.decodeIfPresent(Bool.self, forKey: .hostHeaderIcons) ?? false
        hideSingleSpace = try fields.decodeIfPresent(Bool.self, forKey: .hideSingleSpace) ?? hideSingleSpace
        tabsOnly = try fields.decodeIfPresent(Bool.self, forKey: .tabsOnly) ?? tabsOnly
        spaces = try fields.decodeIfPresent([String: Bool].self, forKey: .spaces) ?? [:]
        enableKittyGraphics = try fields.decodeIfPresent(Bool.self, forKey: .enableKittyGraphics) ?? enableKittyGraphics
        startingDirectory = try fields.decodeIfPresent(String.self, forKey: .startingDirectory) ?? startingDirectory
        shell = try fields.decodeIfPresent(String.self, forKey: .shell) ?? shell
        startupCommand = try fields.decodeIfPresent(String.self, forKey: .startupCommand) ?? startupCommand
        filesEnabled = try fields.decodeIfPresent(Bool.self, forKey: .filesEnabled) ?? filesEnabled
        filesDragAndDrop = try fields.decodeIfPresent(Bool.self, forKey: .filesDragAndDrop) ?? filesDragAndDrop
        filesShowHidden = try fields.decodeIfPresent(Bool.self, forKey: .filesShowHidden) ?? filesShowHidden
        filesPreviews = try fields.decodeIfPresent(Bool.self, forKey: .filesPreviews) ?? filesPreviews
        filesLineNumbers = try fields.decodeIfPresent(Bool.self, forKey: .filesLineNumbers) ?? filesLineNumbers
        filesWrapLines = try fields.decodeIfPresent(Bool.self, forKey: .filesWrapLines) ?? filesWrapLines
        gitEnabled = try fields.decodeIfPresent(Bool.self, forKey: .gitEnabled) ?? gitEnabled
        chatSendWhileWorking = try fields.decodeIfPresent(String.self, forKey: .chatSendWhileWorking)
            .flatMap(ChatSendWhileWorking.init(rawValue:)) ?? chatSendWhileWorking
        chatEditorByDefault = try fields.decodeIfPresent(Bool.self, forKey: .chatEditorByDefault) ?? chatEditorByDefault
        chatAgentStart = try fields.decodeIfPresent(String.self, forKey: .chatAgentStart).flatMap(ChatAgentStart.init(rawValue:)) ?? chatAgentStart
        chatToolSteps = try fields.decodeIfPresent(String.self, forKey: .chatToolSteps)
            .flatMap(ChatToolGroupDisclosure.init(rawValue:)) ?? chatToolSteps
        dictationEnabled = try fields.decodeIfPresent(Bool.self, forKey: .dictationEnabled) ?? dictationEnabled
        dictationKey = try fields.decodeIfPresent(String.self, forKey: .dictationKey).flatMap(VoiceKey.init(rawValue:))
            ?? dictationKey
        dictationNavigation = try fields.decodeIfPresent(Bool.self, forKey: .dictationNavigation) ?? dictationNavigation
        dictationReadReplies = try fields.decodeIfPresent(Bool.self, forKey: .dictationReadReplies) ?? dictationReadReplies
        // A hand-edited list with no usable word keeps the defaults.
        if let saved = try fields.decodeIfPresent([String].self, forKey: .dictationWakeWords) {
            let usable = WakeWords.check(saved.joined(separator: ",")).words
            if !usable.isEmpty { dictationWakeWords = usable }
        }
        dictationEngine = try fields.decodeIfPresent(String.self, forKey: .dictationEngine).flatMap(DictationEngine.init(rawValue:)) ?? dictationEngine
        whisperModel = try fields.decodeIfPresent(String.self, forKey: .whisperModel).flatMap(WhisperModel.init(rawValue:)) ?? whisperModel
    }
}

/// Where the app's files live: the user's home, or one fresh home per test run (System.testing:
/// the test host is the app itself), so tests never touch the user's files, Dispatch's own or the
/// agent homes it installs hooks into.
enum Home {
    /// Dispatch's own files.
    static var support: URL { System.home.appendingPathComponent("Library/Application Support/Dispatch") }

    /// Background agents must not inherit the application's working directory.
    static func agentDirectory(_ known: String?) throws -> URL {
        if let known, known.hasPrefix("/") { return URL(fileURLWithPath: known) }
        let directory = support.appendingPathComponent("Agents/" + System.uuid().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return directory
    }

    /// Dispatch's folder, owner-only: what it keeps names hosts, folders and conversations. An older one made with the
    /// default mode is narrowed too.
    static func protect() {
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
    }

    /// While testing, this process's own environment moves to the test home (HOME there, the test PATH, no
    /// variables that move an agent's home): every process it starts, however, inherits it. Nor does it keep what
    /// names this Mac or the account's login session (Xcode's run destination: the device's UDID and name; the
    /// session's SSH agent socket): nothing a test runs needs them, and every recording would keep them.
    static func isolate() {
        guard System.testing else { return }
        try? FileManager.default.createDirectory(at: System.home, withIntermediateDirectories: true)
        setenv("HOME", System.home.path, 1)
        setenv("PATH", System.path, 1)
        for name in ["CODEX_HOME", "CLAUDE_CONFIG_DIR", "PI_CODING_AGENT_DIR", "RUN_DESTINATION_DEVICE_NAME",
                     "RUN_DESTINATION_DEVICE_UDID", "RUN_DESTINATION_DEVICE_PLATFORM_IDENTIFIER", "SSH_AUTH_SOCK"] { unsetenv(name) }
    }
}

extension UserDefaults {
    /// The app's defaults: none while testing, so its stores never persist into the user's own.
    static var app: UserDefaults? { System.testing ? nil : .standard }
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
            let data = try Data(contentsOf: self.file)
            let loaded = try JSONDecoder().decode(Preferences.self, from: data)
            try Self.validate(loaded)
            values = loaded
            // Settings name the starting folder and shell: a file an older build wrote readable by others is narrowed.
            let permissions = try FileManager.default.attributesOfItem(atPath: self.file.path)[.posixPermissions] as? NSNumber
            if permissions?.intValue != 0o600 { try PrivateFile.write(data, to: self.file) }
        }
        catch { self.error = "Could not load settings: \(error.localizedDescription)" }
    }

    func save(_ preferences: Preferences) throws {
        try Self.validate(preferences)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PrivateFile.write(encoder.encode(preferences), to: file)
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
