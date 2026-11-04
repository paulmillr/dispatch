import SwiftUI

// What the linked app sources (the symlinks beside this file) need from the rest of the app, at the defaults the mockups
// draw: San Francisco interface text, flat chrome (no Liquid Glass), bundled fonts read from the checkout. When an app
// source gains a dependency, the build names it; add it here at its default.

enum System {
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
    case sourceCodePro = "Source Code Pro"
}

@MainActor final class LiquidGlassStore {
    static let shared = LiquidGlassStore()
    /// Off: the mockups draw flat chrome, the app's default.
    var active = false
}

/// Settings.swift's: how remote tabs show their host.
enum RemoteTabHighlight {
    case fade, border
    @MainActor static var current: Self { LiquidGlassStore.shared.active ? .fade : .border }
}

/// StripTab.swift's host mark, by size only (Chrome.sidebarSlotWidth): flat, as tall as the flat new-tab button.
enum StripHostMark {
    static func size(_ typography: AppTypography) -> CGSize {
        CGSize(width: typography.expanded(26), height: typography.expanded(26))
    }
}

/// StripTab.swift's glass track: 28 points (at the 12.5 design base) in the 38-point strip.
enum StripTab {
    static func glassTrackHeight(_ typography: AppTypography) -> CGFloat { typography.expanded(28) }
}
