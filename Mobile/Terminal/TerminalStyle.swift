import CoreText
import Foundation
import OSLog

/// The cursor a program has not chosen (Ghostty's `cursor-style`), as the Mac's `TerminalCursor`.
enum TerminalCursorStyle: String, CaseIterable, Identifiable, Sendable {
    case block, bar, underline
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// A terminal font Settings offers (G2): the monospaced fonts the app bundles (the Mac's, in the app's `TermFonts`
/// folder beside TermApple's JetBrains Mono) and the system's Menlo.
struct TerminalFont: Identifiable, Equatable, Sendable {
    /// The name the list shows, which is also the font's family name.
    let name: String
    /// What `font-family` names: nil for JetBrains Mono, TermApple's embedded face that every terminal falls back to.
    let family: String?
    /// The font has code ligatures (contextual alternates), which the terminal's shaper draws.
    var ligatures = false
    /// Comes with iOS rather than the app.
    var system = false

    var id: String { name }

    static let jetBrainsMono = TerminalFont(name: "JetBrains Mono", family: nil, ligatures: true)

    /// The list's order: the default first, the system's last.
    static let all: [TerminalFont] = [
        jetBrainsMono,
        TerminalFont(name: "Source Code Pro", family: "Source Code Pro"),
        TerminalFont(name: "Fira Code", family: "Fira Code", ligatures: true),
        TerminalFont(name: "0xProto", family: "0xProto", ligatures: true),
        TerminalFont(name: "Departure Mono", family: "Departure Mono"),
        TerminalFont(name: "Menlo", family: "Menlo", system: true),
    ]

    /// A saved name; one no longer offered falls back to JetBrains Mono.
    static func named(_ name: String?) -> TerminalFont { all.first { $0.name == name } ?? jetBrainsMono }

    /// The sample line each row draws in its font: ambiguous glyphs, braces and a ligature candidate.
    static let sample = "$ cargo test --workspace 0O1lI {} <=>"
}

/// The terminal settings every terminal draws with (Settings' Terminal section, G1 and G2), as saved in the defaults.
/// The font size is not among them: it is what a new terminal opens at (`TerminalController.storedConfiguration`),
/// and a pinch changes one terminal.
struct TerminalStyle: Equatable, Sendable {
    /// Posted when Settings saves one of them; the open terminals restyle (`TerminalPresence`).
    static let changed = Notification.Name("DispatchTerminalStyleChanged")

    var font = TerminalFont.jetBrainsMono
    var scheme = TerminalConfiguration.defaultScheme
    var improveTextContrast = false
    var boldIsBright = false
    var cursor = TerminalCursorStyle.block
    var cursorBlink = true

    init() {}

    init(_ defaults: UserDefaults) {
        font = TerminalFont.named(defaults.string(forKey: MobileSettings.terminalFontKey))
        scheme = defaults.string(forKey: MobileSettings.terminalSchemeKey).flatMap { TerminalSchemes.url($0) == nil ? nil : $0 }
            ?? TerminalConfiguration.defaultScheme
        improveTextContrast = defaults.bool(forKey: MobileSettings.terminalContrastKey)
        boldIsBright = defaults.bool(forKey: MobileSettings.boldIsBrightKey)
        cursor = defaults.string(forKey: MobileSettings.cursorKey).flatMap(TerminalCursorStyle.init(rawValue:)) ?? .block
        cursorBlink = defaults.object(forKey: MobileSettings.cursorBlinkKey) as? Bool ?? true
    }

    /// `configuration` drawn with this style; its size and pasteboard access stay.
    func applied(to configuration: TerminalConfiguration) -> TerminalConfiguration {
        var next = configuration
        next.fontFamily = font.family
        next.theme = scheme
        next.improveTextContrast = improveTextContrast
        next.boldIsBright = boldIsBright
        next.cursor = cursor
        next.cursorBlink = cursorBlink
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
