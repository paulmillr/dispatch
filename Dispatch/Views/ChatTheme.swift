import SwiftUI
import Observation
import Term

/// Resolved terminal appearance, shared by chat views without reparsing theme files.
struct ChatTheme: Equatable, Sendable {
    var typography = ChatTypography()
    var terminal = Chrome.terminal
    var ink = SidebarTheme.dark.palette.ink
    var muted = SidebarTheme.dark.palette.muted
    var sidebar = SidebarTheme.dark.palette.sidebar
    var window = SidebarTheme.dark.palette.window
    var border = SidebarTheme.dark.palette.border
    var accent = InterfaceMotion.accent
    var red = Color.red
    var green = Color.green
    var yellow = Color.orange
    var blue = SyntaxHighlight.function
    var cyan = SyntaxHighlight.function
    var comment = SyntaxHighlight.comment
    var keyword = SyntaxHighlight.keyword
    var string = SyntaxHighlight.string
    var number = SyntaxHighlight.number
    var selection = Color(red: 46/255, green: 46/255, blue: 52/255)
    var selectedText = SidebarTheme.dark.palette.ink
    var isDark = true
    /// Nautical's chat: the transcript is a radio log (time, call sign, message) and the composer transmits.
    var radioLog = false
    static let standard = ChatTheme()

    /// The terminal config's colors: background, foreground and the palette. Selection colors
    /// are always blends.
    @MainActor init(config: Config, preferences: Preferences) {
        self.init()
        typography = ChatTypography(preferences: preferences)
        let color = { (c: RGB) in NSColor(srgbRed: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255, alpha: 1) }
        let background = color(config.background)
        let foreground = color(config.foreground)
        func blend(_ amount: CGFloat) -> Color {
            Color(background.blended(withFraction: amount, of: foreground) ?? foreground)
        }
        terminal = Color(background); ink = Color(foreground)
        muted = blend(0.65); comment = muted; sidebar = blend(0.04); window = blend(0.07)
        border = ink.opacity(0.15)
        selection = Color(background.blended(withFraction: 0.2, of: foreground) ?? background)
        selectedText = Color(foreground)
        let rgb = background.usingColorSpace(.sRGB) ?? background
        isDark = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent < 0.5
        let colors = config.palette.map { Color(red: Double($0.r) / 255, green: Double($0.g) / 255, blue: Double($0.b) / 255) }
        red = colors[1]; green = colors[2]; yellow = colors[3]
        blue = colors[4]; accent = colors[5]; cyan = colors[6]
        keyword = colors[5]; string = colors[2]; number = colors[3]; comment = colors[8]
        radioLog = preferences.resolvedSidebarTheme == .nautical
    }
    init() {}
}

/// Nautical's names for chat: each terminal is a VHF channel and each agent a vessel calling from its host and space.
@MainActor enum HarbourRadio {
    static let ownStation = "HARBOUR"

    /// A terminal's channel: its space's number in the sidebar, then its tab's number in its pane, so the first tab
    /// of the third space is CH 31. A terminal outside the workspace's tabs keeps VHF's calling channel, 16.
    static func channel(for surface: UUID) -> String {
        guard let workspace = TerminalRuntime.shared.workspace else { return "CH 16" }
        let spaces = workspace.presentationSpaces
        for (spaceIndex, space) in spaces.enumerated() {
            for pane in space.panes {
                if let tabIndex = pane.tabs.firstIndex(where: { $0.id == surface }) {
                    return "CH \(spaceIndex + 1)\(tabIndex + 1)"
                }
            }
        }
        return "CH 16"
    }

    /// The agent's call sign: its host and space, as MINI/DISPATCH.
    static func callSign(for surface: UUID) -> String {
        guard let workspace = TerminalRuntime.shared.workspace,
              let space = workspace.spaces.first(where: { $0.tabs.contains { $0.id == surface } }) else { return "VESSEL" }
        return (workspace.hosts.record(space.hostID).name + "/" + workspace.liveName(space)).uppercased()
    }
}

/// Ship's time for the radio log: the day's six watches and the bells struck through each.
enum ShipsTime {
    /// The watch a time falls in. The dog watches split 16–20 in two, so the same watch never falls on the same
    /// hours two days running.
    static func watch(_ date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 0..<4: "Middle watch"
        case 4..<8: "Morning watch"
        case 8..<12: "Forenoon watch"
        case 12..<16: "Afternoon watch"
        case 16..<18: "First dog watch"
        case 18..<20: "Last dog watch"
        default: "First watch"
        }
    }

    /// Bells struck at a time: one per half hour into the watch, eight at its end (00:00, 04:00, …). The last dog
    /// watch strikes 4 at its start (the first dog's end), then 1, 2, 3 and 8, as at sea.
    static func bells(_ date: Date, calendar: Calendar = .current) -> Int {
        let hour = calendar.component(.hour, from: date), minute = calendar.component(.minute, from: date)
        if hour >= 18 && hour < 20 {
            let halves = (hour - 18) * 2 + minute / 30
            return halves == 0 ? 4 : halves
        }
        let halves = (hour % 4) * 2 + minute / 30
        return halves == 0 ? 8 : halves
    }

    static func bellsText(_ date: Date, calendar: Calendar = .current) -> String {
        let count = bells(date, calendar: calendar)
        return "\(count) \(count == 1 ? "bell" : "bells") · \(watch(date, calendar: calendar))"
    }

    /// The log's day header: LOG · 15 OCT.
    static func dayText(_ date: Date) -> String {
        "LOG · " + date.formatted(.dateTime.day().month(.abbreviated)).uppercased()
    }
}

/// How an error or a stop reads on the radio: MAYDAY for a failure or a stuck pane, PAN-PAN for a request that needs
/// an answer.
enum HarbourDistress {
    /// Status text that reports a failure rather than progress.
    static func isFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["error", "failed", "failure", "exited", "crash", "unavailable", "denied", "cannot", "couldn’t", "could not"]
            .contains { lower.contains($0) }
    }
}

@MainActor @Observable
final class ChatThemeStore {
    static let shared = ChatThemeStore()
    var current = ChatTheme.standard
}
private struct ChatThemeKey: EnvironmentKey { static let defaultValue = ChatTheme.standard }
extension EnvironmentValues {
    var chatTheme: ChatTheme {
        get { self[ChatThemeKey.self] }
        set { self[ChatThemeKey.self] = newValue }
    }
}
private struct ChatPanel: ViewModifier {
    @Environment(\.chatTheme) private var theme
    let fill: Color?
    let radius: CGFloat
    let bordered: Bool
    func body(content: Content) -> some View {
        content.background(fill ?? theme.sidebar, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(bordered ? theme.border : .clear))
    }
}
extension View {
    func chatPanel(_ fill: Color? = nil, cornerRadius: CGFloat = 8, bordered: Bool = true) -> some View { modifier(ChatPanel(fill: fill, radius: cornerRadius, bordered: bordered)) }
}

/// Resolve the selected family once per settings change, shared by native and SwiftUI text.
struct ChatTypography: Equatable, Sendable {
    var fontName = "SourceCodePro-Regular"
    var codeFontName = "SourceCodePro-Regular"
    var size: CGFloat = 12.5
    var sizeScale: CGFloat = 1
    private var usesSystemFont = false
    var codeDetailSize: CGFloat { size - 2 }
    var detailSize: CGFloat { pointSize(offset: -2) }
    var replySize: CGFloat { pointSize(offset: 1) }
    // Scale after role-specific offsets; code text and composer fences remain unscaled.
    func pointSize(offset: CGFloat = 0) -> CGFloat { (size + offset) * sizeScale }
    var body: Font { font() }
    var detail: Font { font(offset: -2) }
    func font(offset: CGFloat = 0, weight: Font.Weight = .regular) -> Font {
        if usesSystemFont { return .system(size: pointSize(offset: offset), weight: weight) }
        return .custom(fontName, fixedSize: pointSize(offset: offset)).weight(weight)
    }
    func codeFont(offset: CGFloat = 0) -> Font {
        .custom(codeFontName, fixedSize: size + offset)
    }
    var codeDetail: Font { codeFont(offset: -2) }
    var codeDetailLineHeight: CGFloat = 14
    @MainActor var reply: NSFont {
        if usesSystemFont { return .systemFont(ofSize: replySize, weight: .regular) }
        return NSFont(name: fontName, size: replySize) ?? .monospacedSystemFont(ofSize: replySize, weight: .regular)
    }
    @MainActor var codeReply: NSFont {
        NSFont(name: codeFontName, size: size + 1) ?? .monospacedSystemFont(ofSize: size + 1, weight: .regular)
    }
    var characterWidth: CGFloat = 7.5
    var replyLineHeight: CGFloat = 18
    var detailLineHeight: CGFloat = 14
    init() {}
    @MainActor init(preferences: Preferences) {
        AppFont.register()
        size = preferences.fontSize
        usesSystemFont = preferences.chatFont == .system
        let code = NSFontManager.shared.font(withFamily: preferences.fontFamily, traits: [], weight: 5, size: size)
            ?? NSFont(name: preferences.fontFamily, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        codeFontName = code.fontName
        let chatFont = usesSystemFont ? NSFont.systemFont(ofSize: size)
            : preferences.chatFont.postScriptName.flatMap { NSFont(name: $0, size: size) }
        sizeScale = chatFont == nil ? 1 : preferences.chatFont.sizeScale
        let selected = chatFont.flatMap { sizeScale == 1 ? $0 : NSFont(descriptor: $0.fontDescriptor, size: pointSize()) } ?? code
        fontName = selected.fontName
        characterWidth = ("0" as NSString).size(withAttributes: [.font: selected]).width
        let layout = NSLayoutManager()
        codeDetailLineHeight = layout.defaultLineHeight(for: NSFont(descriptor: code.fontDescriptor, size: codeDetailSize)
            ?? .monospacedSystemFont(ofSize: codeDetailSize, weight: .regular))
        replyLineHeight = layout.defaultLineHeight(for: reply)
        detailLineHeight = layout.defaultLineHeight(for: NSFont(descriptor: selected.fontDescriptor, size: detailSize)
            ?? .monospacedSystemFont(ofSize: detailSize, weight: .regular))
    }
}
