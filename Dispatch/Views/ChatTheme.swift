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
    }
    init() {}
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
