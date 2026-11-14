import CoreText
import Foundation
import OSLog

/// The cursor a program has not chosen (Ghostty's `cursor-style`), as the Mac's `TerminalCursor`.
enum TerminalCursorStyle: String, CaseIterable, Identifiable, Sendable {
    case block, bar, underline
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// A terminal font Settings offers (G2): the Mac's list in the Mac's order (`SettingsView.fontMenuChoices`): Source Code
/// Pro, the default, first; then the system's monospaced font (Menlo, where the Mac lists the fonts installed on it);
/// then, after a separator, every font Dispatch bundles, by name (the app's `TermFonts` folder, beside TermApple's
/// JetBrains Mono). Ligatures are Settings' switch (`TerminalStyle.ligatures`), as on the Mac.
struct TerminalFont: Identifiable, Equatable, Sendable {
    /// The name the list shows, which is also the font's family name.
    let name: String
    /// What `font-family` names: nil for JetBrains Mono, TermApple's embedded face that every terminal falls back to.
    let family: String?
    /// Comes with iOS rather than the app.
    var system = false

    var id: String { name }

    static let jetBrainsMono = TerminalFont(name: TerminalFontCatalog.fallbackFamily, family: nil)
    /// The default, as the Mac's (`Settings.fontFamily`).
    static let sourceCodePro = TerminalFont(name: TerminalFontCatalog.defaultFamily, family: TerminalFontCatalog.defaultFamily)
    static let menlo = TerminalFont(name: "Menlo", family: "Menlo", system: true)

    /// The list's first part, before the Mac's separator: the default and the system's.
    static let leading: [TerminalFont] = [sourceCodePro, menlo]

    /// Dispatch's own fonts after the separator, by name as the Mac sorts them (`localizedStandardCompare`): the
    /// Mac's bundled monospaced families and its `moreBundledFontFamilies`.
    static let bundled: [TerminalFont] = TerminalFontCatalog.bundled
        .filter { $0.family != TerminalFontCatalog.defaultFamily }
        .map { $0.family == TerminalFontCatalog.fallbackFamily ? jetBrainsMono : TerminalFont(name: $0.family, family: $0.family) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    /// The whole list, in order.
    static let all: [TerminalFont] = leading + bundled

    /// A saved name; one no longer offered falls back to Source Code Pro.
    static func named(_ name: String?) -> TerminalFont { all.first { $0.name == name } ?? sourceCodePro }

    /// The sample line each row draws in its font: ambiguous glyphs, braces and a ligature candidate.
    static let sample = "$ cargo test --workspace 0O1lI {} <=>"
}

/// The terminal settings every terminal draws with (Settings' Terminal section, G1 and G2), as saved in the defaults.
/// The font size is not among them: it is what a new terminal opens at (`TerminalController.storedConfiguration`),
/// and a pinch changes one terminal.
struct TerminalStyle: Equatable, Sendable {
    /// Posted when Settings saves one of them; the open terminals restyle (`TerminalPresence`).
    static let changed = Notification.Name("DispatchTerminalStyleChanged")

    var font = TerminalFont.sourceCodePro
    var scheme = TerminalConfiguration.defaultScheme
    var textContrast = TextContrast.lightThemes
    var boldIsBright = false
    var cursor = TerminalCursorStyle.block
    var cursorBlink = true
    var lineSpacing = LineSpacing.normal
    /// The font's code ligatures (contextual alternates), on by default as the Mac's `fontLigatures`.
    var ligatures = true

    init() {}

    init(_ defaults: UserDefaults) {
        font = TerminalFont.named(defaults.string(forKey: MobileSettings.terminalFontKey))
        scheme = TerminalSchemes.stored(defaults.string(forKey: MobileSettings.terminalSchemeKey))
            ?? TerminalConfiguration.defaultScheme
        textContrast = defaults.string(forKey: MobileSettings.textContrastKey).flatMap(TextContrast.init(rawValue:))
            ?? .lightThemes
        boldIsBright = defaults.bool(forKey: MobileSettings.boldIsBrightKey)
        cursor = defaults.string(forKey: MobileSettings.cursorKey).flatMap(TerminalCursorStyle.init(rawValue:)) ?? .block
        cursorBlink = defaults.object(forKey: MobileSettings.cursorBlinkKey) as? Bool ?? true
        lineSpacing = defaults.string(forKey: MobileSettings.lineSpacingKey).flatMap(LineSpacing.init(rawValue:)) ?? .normal
        ligatures = defaults.object(forKey: MobileSettings.ligaturesKey) as? Bool ?? true
    }

    /// `configuration` drawn with this style; its size and pasteboard access stay.
    func applied(to configuration: TerminalConfiguration) -> TerminalConfiguration {
        var next = configuration
        next.fontFamily = font.family
        next.theme = scheme
        next.textContrast = textContrast
        next.boldIsBright = boldIsBright
        next.cursor = cursor
        next.cursorBlink = cursorBlink
        next.lineSpacing = lineSpacing
        next.ligatures = ligatures
        return next
    }
}

/// The bundled fonts, registered for the process once (CoreText): the terminal finds them by family name
/// (`FontCollection.discover`), and Settings and chat draw their names in them. Started off the main thread at launch;
/// whatever needs them first (a terminal's configuration, chat's or Settings' fonts) waits for that one registration.
enum MobileFonts {
    private static let log = Logger(subsystem: "yachts.dispatch.mobile", category: "Fonts")

    /// The app's `TermFonts` folder (project.yml's "Bundle terminal fonts").
    static var folder: URL { Bundle.main.bundleURL.appendingPathComponent("TermFonts") }

    /// Runs once, on whichever thread asks first; later calls return at once.
    private static let registration: Void = {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let fonts = files.filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix("SymbolsNerdFont") }
        for url in fonts {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let reason = error?.takeRetainedValue().localizedDescription ?? "unknown"
                log.error("Font \(url.lastPathComponent, privacy: .public) not registered: \(reason, privacy: .public)")
            }
        }
    }()

    static func register() { _ = registration }

    /// At launch, off the main thread.
    static func registerInBackground() {
        Task.detached(priority: .userInitiated) { register() }
    }
}
