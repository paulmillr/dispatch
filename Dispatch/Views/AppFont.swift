import AppKit
import SwiftUI
import CoreText

enum AppFont {
    @MainActor private static var registered = false
    /// The families of the fonts Dispatch brings (`register`), whether or not this Mac has them installed too.
    @MainActor private(set) static var bundledFamilies: Set<String> = []
    @MainActor static func register() {
        guard !registered else { return }
        registered = true
        var urls: [URL] = []
        for ext in ["ttf", "otf"] {
            urls += ((try? FileManager.default.contentsOfDirectory(at: System.resources, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == ext }
        }
        // JetBrains Mono is the terminal engine's own variable face (its Resources folder): registered, Settings offers
        // it, and its wght axis gives the terminal real bold faces.
        urls += ["JetBrainsMono-Variable", "JetBrainsMono-Italic-Variable"].map { System.resources.appendingPathComponent("Resources/\($0).ttf") }
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
            for descriptor in descriptors {
                if let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String { bundledFamilies.insert(family) }
            }
        }
    }
    /// San Francisco, drawn in SF Rounded as chat's is, at Source Code Pro's lowercase height so switching keeps the
    /// text the same size: measured from the outlines as terminal and chat faces are (`TerminalFontScale`), about
    /// 0.948. Digits stay monospaced for timers and counts.
    @MainActor static var systemScale: CGFloat {
        if let measuredSystemScale { return measuredSystemScale }
        register()
        let value = CGFloat(TerminalFontScale.factor(rounded(size: 16) as CTFont))
        measuredSystemScale = value
        return value
    }
    @MainActor private static var measuredSystemScale: CGFloat?
    /// SF Rounded with monospaced digits, at `size` itself.
    private static func rounded(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
    }
    /// Settings › Font's interface font; reading it in a body redraws the view when it changes.
    @MainActor static func ui(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch InterfaceFontStore.shared.current {
        case .sameAsCode: code(size: size, weight: weight)
        case .system: .system(size: size * systemScale, weight: weight, design: .rounded).monospacedDigit()
        }
    }
    /// The terminal font (Settings › Font) whatever the interface font, at the size the terminal draws it: text that is
    /// code (paths, commands, color values), and all the interface's text in Same as code.
    @MainActor static func code(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let face = codeFace(InterfaceFontStore.shared.codeFamily)
        if [.semibold, .bold, .heavy, .black].contains(weight), let bold = face.bold { return .custom(bold, size: size * face.scale) }
        return .custom(face.regular, size: size * face.scale).weight(weight)
    }
    /// Source Code Pro whatever the fonts chosen: pictures drawn to a fixed size, as onboarding's terminals.
    static func sourceCodePro(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("SourceCodePro-Regular", size: size).weight(weight)
    }
    /// The code font's faces of `family`, the terminal font: its regular face by name, a bold kept in another family
    /// (Latin Modern Mono's, `ChatFont.boldPostScriptName`), and the scale to Source Code Pro's lowercase height the
    /// terminal draws it at. A family this Mac no longer has draws Source Code Pro.
    @MainActor private static func codeFace(_ family: String) -> CodeFace {
        if let face = codeFaces[family] { return face }
        register()
        guard let regular = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 14) else {
            return CodeFace(family: TerminalFontScale.reference, regular: "SourceCodePro-Regular", bold: nil, scale: 1)
        }
        let face = CodeFace(family: family, regular: regular.fontName, bold: ChatFont.boldPostScriptName(regular.fontName),
                            scale: CGFloat(TerminalFontScale.factor(family)))
        codeFaces[family] = face
        return face
    }
    private struct CodeFace { let family, regular: String; let bold: String?; let scale: CGFloat }
    @MainActor private static var codeFaces: [String: CodeFace] = [:]
    /// Source Code Pro's line at `size` (TextKit's, ascent and descent each rounded up): the line every font of the
    /// interface and of chat's prose is set on at that size, so switching fonts changes the letters, not where lines
    /// and the rows they make fall. San Francisco's own is about two points shorter, Latin Modern's five taller.
    @MainActor static func lineHeight(size: CGFloat) -> CGFloat {
        if let line = lineHeights[size] { return line }
        register()
        let font = NSFont(name: "SourceCodePro-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let line = NSLayoutManager().defaultLineHeight(for: font)
        lineHeights[size] = line
        return line
    }
    @MainActor private static var lineHeights: [CGFloat: CGFloat] = [:]
    static func shortcut(size: CGFloat = 11) -> Font { Font(nativeShortcut(size: size)) }
    /// SF Mono keeps keyboard legends monospaced with a full-width Shift glyph.
    static func nativeShortcut(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    /// The letter spacing that draws `text` semibold at its regular width, so a title that turns semibold when selected
    /// neither moves its letters nor truncates sooner: San Francisco's semibold is about 6% wider. Next to nothing in
    /// a code font, whose weights share one advance width.
    @MainActor static func semiboldTracking(_ text: String, size: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let width = { (font: NSFont) in (text as NSString).size(withAttributes: [.font: font]).width }
        return (width(native(size: size)) - width(native(size: size, semibold: true))) / CGFloat(text.count)
    }
    @MainActor static func native(size: CGFloat, semibold: Bool = false) -> NSFont {
        register()
        if InterfaceFontStore.shared.current == .system {
            return rounded(size: size * systemScale, weight: semibold ? .semibold : .regular)
        }
        let face = codeFace(InterfaceFontStore.shared.codeFamily), scaled = size * face.scale
        // Semibold is the family's nearest face to it: Bold in a family without a SemiBold, as SwiftUI picks.
        let font = semibold
            ? face.bold.flatMap { NSFont(name: $0, size: scaled) }
                ?? NSFontManager.shared.font(withFamily: face.family, traits: [], weight: 8, size: scaled)
            : NSFont(name: face.regular, size: scaled)
        return font ?? .monospacedSystemFont(ofSize: scaled, weight: semibold ? .semibold : .regular)
    }
}

@MainActor @Observable
final class InterfaceFontStore {
    static let shared = InterfaceFontStore()
    var current = InterfaceFont.system
    /// The terminal font's family (Settings › Font), which code text (`AppFont.code`) and Same as code draw.
    var codeFamily = TerminalFontCatalog.defaultFamily
}

/// UI sizes are offsets from the content size (Settings › Font size); compact labels retain an 8 pt floor. Text takes
/// one of the roles; only display headings (the empty window's) pick their own offset.
struct AppTypography: Equatable {
    /// The interface's text sizes, as offsets from the content size.
    enum Role: CGFloat {
        /// Pane and window titles.
        case title = 0.5
        /// Text at the content size itself.
        case content = 0
        /// Names: sidebar spaces, tabs, rows' primary text and control labels.
        case label = -0.5
        /// Most text: descriptions, list rows, messages.
        case body = -1.5
        /// Secondary details: metadata, counts, hints.
        case caption = -2.5
        /// Badges and section headers.
        case micro = -3
    }
    var contentSize: CGFloat = 14
    func size(offset: CGFloat = 0) -> CGFloat { max(8, contentSize + offset) }
    func size(_ role: Role) -> CGFloat { size(offset: role.rawValue) }
    @MainActor func font(_ role: Role, weight: Font.Weight = .regular) -> Font { AppFont.ui(size: size(role), weight: weight) }
    /// A display size outside the roles.
    @MainActor func font(offset: CGFloat, weight: Font.Weight = .regular) -> Font {
        AppFont.ui(size: size(offset: offset), weight: weight)
    }
    /// An SF Symbol beside a role's text, at the role's size whichever interface font draws the text.
    func symbol(_ role: Role, weight: Font.Weight = .regular) -> Font { .system(size: size(role), weight: weight) }
    /// `AppFont.code` at a role's size.
    @MainActor func code(_ role: Role, weight: Font.Weight = .regular) -> Font { AppFont.code(size: size(role), weight: weight) }
    func shortcut(offset: CGFloat = -1.5) -> Font { AppFont.shortcut(size: size(offset: offset)) }
    var sidebarShortcut: Font { AppFont.shortcut(size: size(.label)) }
    /// Grow text containers with larger fonts without shrinking their default hit areas.
    func expanded(_ dimension: CGFloat) -> CGFloat { dimension * max(1, contentSize / 12.5) }
    /// Every host icon in the app (HostGlyph): about the text's size, growing with it.
    var hostIconSize: CGFloat { expanded(15) }
    @MainActor func popoverHeight(_ dimension: CGFloat) -> CGFloat {
        min(expanded(dimension), max(200, (NSScreen.main?.visibleFrame.height ?? 900) - 80))
    }
    /// Tab titles: the label size, about macOS's 12.5-point text in lowercase height at the default size.
    var tabSize: CGFloat { size(.label) }
}

extension View {
    /// A role's interface font on Source Code Pro's line for its size (`AppFont.lineHeight`), whichever interface font
    /// draws it: San Francisco's rows and wrapped text take the room Source Code Pro's do. macOS 26 sets text's line
    /// height; earlier, each font keeps its own line.
    @MainActor func font(_ typography: AppTypography, _ role: AppTypography.Role, weight: Font.Weight = .regular) -> some View {
        modifier(InterfaceLine(font: typography.font(role, weight: weight), line: AppFont.lineHeight(size: typography.size(role))))
    }
    /// A display size outside the roles, on its line as `font(_:_:weight:)`.
    @MainActor func font(_ typography: AppTypography, offset: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(InterfaceLine(font: typography.font(offset: offset, weight: weight),
                               line: AppFont.lineHeight(size: typography.size(offset: offset))))
    }
    /// `AppFont.ui` at `size`, on its line as `font(_:_:weight:)`.
    @MainActor func interfaceFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(InterfaceLine(font: AppFont.ui(size: size, weight: weight), line: AppFont.lineHeight(size: size)))
    }
}

/// Text that changes in place (a button's Play and Copying…), as wide as the widest of its variants, so what is beside
/// it stays put whichever shows.
struct ReservedText: View {
    let text: String
    let variants: [String]
    var body: some View {
        ZStack {
            ForEach(variants, id: \.self) { Text($0).hidden().accessibilityHidden(true) }
            Text(text)
        }
    }
}

/// A font and the line its text is set on. The line height is an environment value, so text inside that sets only a
/// font takes the same line: code text at the role's size is on it already.
struct InterfaceLine: ViewModifier {
    let font: Font
    let line: CGFloat
    func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.font(font).lineHeight(.exact(points: line)) } else { content.font(font) }
    }
}

private struct AppTypographyKey: EnvironmentKey {
    static let defaultValue = AppTypography()
}

extension EnvironmentValues {
    var appTypography: AppTypography {
        get { self[AppTypographyKey.self] }
        set { self[AppTypographyKey.self] = newValue }
    }
}
