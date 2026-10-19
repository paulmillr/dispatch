import SwiftUI
import Observation

/// Resolved app palettes. Automatic appearance selects dark or light.
enum SidebarTheme: String, Codable, CaseIterable, Sendable {
    case dark, light, graphite, lavender, nautical
    var label: String { rawValue.capitalized }
    /// Dark palettes: dark system appearance, the dark terminal scheme and light-on-dark host tones.
    var isDark: Bool { self == .dark || self == .nautical }
    var palette: SidebarPalette { SidebarPalette(theme: self) }

    #if canImport(AppKit)
    /// Default terminal colors use the app palette. Explicit Ghostty schemes bypass these overrides.
    @MainActor var defaultColorSchemeOverrides: String {
        guard self != .dark else { return "" } // Preserve dispatch-black.
        func hex(_ color: Color) -> String {
            let rgb = NSColor(color).usingColorSpace(.sRGB)!
            return String(format: "#%02x%02x%02x", Int((rgb.redComponent * 255).rounded()),
                          Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        }
        // Light palettes take ANSI colors dark enough to read on them; dark palettes take the dispatch scheme's.
        // Nautical's deck matches its radio: a phosphor scheme, every hue pulled toward the radar's green-black.
        let colors = self == .nautical
            ? [hex(palette.control), "#e0846e", "#7fd3a1", "#d9c46a", "#6fb3c9", hex(palette.accent), "#7fd3b4", hex(palette.secondary),
               hex(palette.detail), "#f0a08c", "#a3e3bd", "#ebd98f", "#9ccce0", hex(palette.accent), "#a7e6cc", hex(palette.ink)]
            : isDark
            ? [hex(palette.control), "#e07b7b", "#7fd3a1", "#d9b36a", "#7ea6c9", hex(palette.accent), "#6fb3aa", hex(palette.secondary),
               hex(palette.detail), "#ec9b9b", "#a3e3bd", "#e8cb8f", "#a3c4df", hex(palette.accent), "#9ad0c9", hex(palette.ink)]
            : [hex(palette.ink), "#b33d46", "#2f7d48", "#946515", "#356a9a", hex(palette.accent), "#247b78", hex(palette.secondary),
               hex(palette.muted), "#bd3545", "#267342", "#88600e", "#285f98", hex(palette.accent), "#206f70", hex(palette.ink)]
        return """
        background = \(hex(palette.window))
        foreground = \(hex(palette.ink))
        cursor-color = \(hex(palette.ink))
        cursor-text = \(hex(palette.window))
        selection-background = \(hex(palette.hostGroup))
        selection-foreground = \(hex(palette.ink))
        \(colors.enumerated().map { "palette = \($0.offset)=\($0.element)" }.joined(separator: "\n"))
        """
    }
    #endif
}

struct SidebarPalette: Sendable {
    let theme: SidebarTheme
    var isDark: Bool { theme.isDark }
    /// Nautical, the hidden theme Settings unlocks, is a harbour's vessel traffic radar: green-black chrome, phosphor
    /// green accent and gray-green ink.
    private func color(_ dark: UInt32, _ light: UInt32, _ graphite: UInt32, _ lavender: UInt32, _ nautical: UInt32) -> Color {
        let hex: UInt32
        switch theme {
        case .dark: hex = dark; case .light: hex = light; case .graphite: hex = graphite; case .lavender: hex = lavender
        case .nautical: hex = nautical
        }
        return Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
    var window: Color { color(0x131315, 0xf6f6f8, 0xf2f2f2, 0xf3f1f9, 0x0c100d) }
    /// What the terminal and chat sit on: Dark keeps dispatch-black's near-black; other palettes use the window.
    var terminal: Color { theme == .dark ? Chrome.terminal : window }
    var sidebar: Color { color(0x16161a, 0xececef, 0xe6e6e6, 0xe9e6f2, 0x0e130f) }
    var border: Color { theme == .dark ? .white.opacity(0.08) : color(0, 0xdcdce0, 0xcfcfcf, 0xd5d0e3, 0x1f2a21) }
    var sidebarDivider: Color { color(0x212121, 0xcdcdd1, 0xc5c5c5, 0xcbc8d2, 0x1f2a21) }
    var ink: Color { color(0xececf0, 0x131318, 0x000000, 0x120f1a, 0xdfe8df) }
    var secondary: Color { color(0xc9c9ce, 0x2e2e36, 0x1f1f1f, 0x2a2538, 0x9aa89b) }
    var muted: Color { color(0x8f8f98, 0x767680, 0x5a5a5a, 0x69617e, 0x7c8c7e) }
    var detail: Color { color(0x5c5c64, 0x8a8a94, 0x6b6b6b, 0x7a7290, 0x55635a) }
    var faint: Color { color(0x3f3f47, 0xb0b0b8, 0x969696, 0xa199b5, 0x2c3b2e) }
    var accent: Color { color(0xe07be0, 0xb8449e, 0x2a5bd7, 0x5648c4, 0x8be28f) }
    var green: Color { color(0x7fd3a1, 0x2f9a5c, 0x2f9a5c, 0x2f9a5c, 0x7fd3a1) }
    var warning: Color { color(0xd9b36a, 0xb07a1a, 0xb07a1a, 0xb07a1a, 0xd9b36a) }
    var selection: Color { (isDark ? Color.white : Color.black).opacity(0.07) }
    var hover: Color { (isDark ? Color.white : Color.black).opacity(0.04) }
    var hostGroup: Color { theme == .dark ? Chrome.terminal.opacity(0.55) : color(0, 0xe4e4e8, 0xdddddd, 0xe0dcec, 0x111612) }
    var field: Color { color(0x111114, 0xf6f6f8, 0xf2f2f2, 0xf3f1f9, 0x111612) }
    var control: Color { color(0x1d1d21, 0xe9e9ed, 0xdddddd, 0xe0dcec, 0x1f2a21) }
    var controlBorder: Color { color(0x2a2a30, 0xd0d0d6, 0xbfbfbf, 0xc9c2dc, 0x2c3b2e) }
    var sidebarDetail: Color { color(0x6f6f78, 0x767680, 0x5a5a5a, 0x69617e, 0x7c8c7e) }
    var sidebarHostLabel: Color { color(0x9a9aa2, 0x767680, 0x5a5a5a, 0x69617e, 0x9aa89b) }
    var sidebarAction: Color { color(0x232328, 0xe9e9ed, 0xdddddd, 0xe0dcec, 0x1f2a21) }
    var selectedControl: Color { color(0x2e2e34, 0xffffff, 0xffffff, 0xfcfbfe, 0x2c3b2e) }
    var separator: Color { color(0x1c1c20, 0xe3e3e7, 0xcfcfcf, 0xd5d0e3, 0x141b16) }
}

@MainActor @Observable
final class SidebarThemeStore {
    static let shared = SidebarThemeStore()
    #if canImport(AppKit)
    static var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    #endif
    var current = SidebarTheme.dark
    /// Typing `AppTheme.nauticalCode` in Settings sets this for the rest of the run.
    var nauticalUnlocked = false
}

@MainActor
enum Chrome {
    static let paneContentInset: CGFloat = 22
    /// Tab strips' side inset: chrome lines up across panes and sits near terminal text, while chat keeps
    /// `paneContentInset` for reading.
    static let stripInset: CGFloat = 12
    /// The full-screen sidebar button's inset from the screen's leading edge.
    static let sidebarButtonInset: CGFloat = 8
    #if canImport(AppKit)
    /// The full-screen sidebar button (a circle the host mark's size, StripHostMark.size) plus a 12-point gap. It
    /// replaces the strip's leading inset. Liquid Glass keeps 52 points.
    static func sidebarSlotWidth(_ typography: AppTypography) -> CGFloat {
        LiquidGlassStore.shared.active ? 52 : sidebarButtonInset + StripHostMark.size(typography).width + 12
    }
    #endif
    static var palette: SidebarPalette { SidebarThemeStore.shared.current.palette }
    static var window: Color { palette.window }
    static var sidebar: Color { palette.sidebar }
    nonisolated static let terminal = Color(red: 13/255, green: 13/255, blue: 15/255)
    static var border: Color { palette.border }
    static var ink: Color { palette.ink }
    static var muted: Color { palette.muted }
    /// Sidebar keybind hints and host status labels share this dimmer tone.
    static var sidebarHint: Color { palette.muted.opacity(0.7) }
    static var accent: Color { palette.accent }
    static var colorScheme: ColorScheme { palette.isDark ? .dark : .light }
}

extension View {
    func chromePanel(_ fill: Color = Chrome.sidebar, cornerRadius: CGFloat = 8) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Chrome.border))
    }
}
