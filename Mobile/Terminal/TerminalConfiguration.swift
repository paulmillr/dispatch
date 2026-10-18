import Foundation
@preconcurrency import Term
@preconcurrency import TermApple

/// The terminal's config as the Mac writes it (`TerminalRuntime.makeConfig`, Ghostty's config syntax read by
/// `Vendor/Term`): the same theme names, contrast shader setting and keybinds, with the phone's font size and the
/// mockup's padding (M6a: 14 points beside the text, 10 above and below). Dark by default: `dispatch-black`, the
/// Mac's Default dark theme. Themes come from the app's `ghostty` folder (`extras/ghostty`), fonts from TermApple's
/// bundled JetBrains Mono and Symbols Nerd Font.
struct TerminalConfiguration: Equatable, Sendable {
    static let defaultFontSize = 12.0
    /// Pinch zoom stays within these sizes (points).
    static let fontSizes = 7.0...28.0

    var fontSize = defaultFontSize
    var theme = "dispatch-black"
    /// The Mac's "Improve text contrast": the contrast shader raises text to 4.5:1 against its background.
    var improveTextContrast = false
    var paddingX = 14
    var paddingY = 10
    /// Kept small on a phone: the multiplexer keeps the long history (herdr), or tmux's own history is replayed.
    var scrollbackBytes = 10_000_000

    /// Where the bundled themes are (`DispatchMobile.app/ghostty`).
    static var themes: URL { Bundle.main.bundleURL.appendingPathComponent("ghostty") }

    var text: String {
        let themePath = Self.themes.appendingPathComponent(theme).path
        return """
        term = xterm-256color
        font-size = \(fontSize)
        theme = \(themePath)
        minimum-contrast = \(improveTextContrast ? 4.5 : 1)
        macos-option-as-alt = true
        window-padding-x = \(paddingX)
        window-padding-y = \(paddingY)
        scrollback-limit-bytes = \(scrollbackBytes)
        image-storage-limit = 0
        clipboard-read = ask
        clipboard-write = ask
        keybind = clear
        """
    }

    /// The parsed config; a theme that does not load leaves Ghostty's defaults and a diagnostic.
    func config() -> Config {
        var config = Config()
        config.load(Array(text.utf8))
        config.finalize(dark: true) { name, diagnostics in
            Config.theme(name, resources: Self.themes.path, environment: [:], diagnostics: &diagnostics)
        }
        return config
    }

    /// The pinch's font size: the base size scaled, kept within `fontSizes`, in half-point steps.
    static func zoomed(_ base: Double, scale: Double) -> Double {
        guard scale.isFinite, scale > 0 else { return base }
        let size = min(max(base * scale, fontSizes.lowerBound), fontSizes.upperBound)
        return (size * 2).rounded() / 2
    }
}
