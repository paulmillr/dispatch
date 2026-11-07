import AppKit
import SwiftUI

// What the linked app sources (the symlinks beside this file) need from the rest of the app, at the defaults the mockups
// draw: San Francisco interface text, Liquid Glass (the renderer's `--flat` turns it off), bundled fonts read from the
// checkout. When an app source gains a dependency, the build names it; add it here at its default.

enum System {
    /// Ids, as System.uuid: the mockups draw one fixed state, so any id does.
    static func uuid(for key: String = "") -> UUID { UUID() }
    /// The checkout's bundled fonts, which AppFont.register reads as the app reads its bundle's.
    static let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../../Dispatch/Resources/Fonts").standardizedFileURL
}

enum TerminalFontCatalog {
    static let defaultFamily = "Source Code Pro"
}

/// Settings.swift's: the app's own text (tabs, the sidebar, Files, Git and Settings).
enum InterfaceFont: String, Codable, CaseIterable {
    case system = "San Francisco"
    case sameAsCode = "Same as code"
}

/// Settings.swift's bold of a face kept in another family (Latin Modern Mono's): none in the mockups' terminal font,
/// Source Code Pro, which bolds within its own.
enum ChatFont {
    static func boldPostScriptName(_ name: String) -> String? { nil }
}

@MainActor final class LiquidGlassStore {
    static let shared = LiquidGlassStore()
    /// Liquid Glass, the app's default (Settings.liquidGlass); the renderer sets it per run (`--flat`: off).
    var active = true
}

/// Settings.swift's: how remote tabs show their host.
enum RemoteTabHighlight {
    case fade, border
    @MainActor static var current: Self { LiquidGlassStore.shared.active ? .fade : .border }
}

/// StripTab.swift's host mark, by size only (Chrome.sidebarSlotWidth): on glass as tall as the track, flat as tall as
/// the flat new-tab button.
enum StripHostMark {
    @MainActor static func size(_ typography: AppTypography) -> CGSize {
        let side = LiquidGlassStore.shared.active ? StripTab.glassTrackHeight(typography) : typography.expanded(26)
        return CGSize(width: side, height: side)
    }
}

/// StripTab.swift's glass track: 28 points (at the 12.5 design base) in the 38-point strip.
enum StripTab {
    static func glassTrackHeight(_ typography: AppTypography) -> CGFloat { typography.expanded(28) }
}

// For the linked theme maker (ThemeMakerView.swift and Themes/), at the defaults: the terminal's font and size,
// Settings' control colors, no custom schemes.

/// TerminalRuntime's preferences, as far as the theme maker's preview reads them.
struct Preferences {
    var fontFamily = TerminalFontCatalog.defaultFamily
    var fontSize = 14.0
}
@MainActor final class TerminalRuntime {
    static let shared = TerminalRuntime()
    let preferences = Preferences()
}

/// SettingsView.swift's.
@MainActor enum SettingsControlStyle {
    static var detail: Color { Chrome.palette.detail }
    static var fill: Color { Chrome.palette.control }
    static var border: Color { Chrome.palette.controlBorder }
    static var selected: Color { Chrome.palette.selectedControl }
    static var selectedText: Color { Chrome.ink }
}

/// SettingsColorSchemes.swift's: names a suggested name steps around (none in the mockups).
enum SurpriseScheme {
    static func takenNames() -> Set<String> { [] }
}

/// CustomThemes.swift's.
enum CustomThemes {
    static func sanitized(_ name: String) -> String { name }
}

/// TerminalImport.swift's: an AppKit color in sRGB, or in Display P3 when it lies outside sRGB.
extension ThemeColor {
    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB), let extended = color.usingColorSpace(.extendedSRGB) else { return nil }
        let e = 0.5 / 255
        let components = [extended.redComponent, extended.greenComponent, extended.blueComponent].map(Double.init)
        if components.allSatisfy({ (-e...(1 + e)).contains($0) }) {
            self.init(red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent))
        } else if let p3 = color.usingColorSpace(.displayP3) {
            let clamp = { (c: CGFloat) in min(1, max(0, Double(c))) }
            self.init(displayP3Red: clamp(p3.redComponent), green: clamp(p3.greenComponent), blue: clamp(p3.blueComponent))
        } else {
            return nil
        }
    }
}
