import SwiftUI
import UIKit

/// The app's theme (Settings, Theme, G4): Automatic, Dispatch's pink chrome in the scheme Appearance picks, or a
/// theme in its own scheme: Graphite and Lavender light, Nautical dark. A theme colours the chrome and chat
/// (`MobileColors`' accent, bubbles, canvas and cards); the terminal keeps its colour scheme. Nautical's palette is the
/// Mac's (`SidebarPalette`, shared with the Mac app); Graphite and Lavender are the iPhone's own.
enum MobileTheme: String, CaseIterable, Identifiable, Sendable {
    case automatic, graphite, lavender, nautical

    var id: Self { self }

    init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .automatic }

    var title: String { rawValue.capitalized }

    /// The tile's line under the name (G4).
    var subtitle: String {
        switch self {
        case .automatic: "Follows Appearance"
        case .graphite: "Neutral greys"
        case .lavender: "Purple accent"
        case .nautical: "Radar green, engine room"
        }
    }

    /// The scheme the theme fixes; nil follows Appearance.
    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: nil
        case .graphite, .lavender: .light
        case .nautical: .dark
        }
    }

    var interfaceStyle: UIUserInterfaceStyle? { colorScheme.map { $0 == .dark ? .dark : .light } }

    /// The theme's colours for `MobileColors`' themed tokens; nil for Automatic. Made once per theme: every themed
    /// colour resolves through it as it draws.
    var palette: Palette? { Self.palettes[self] }

    private static let palettes: [MobileTheme: Palette] = [
        .graphite: Palette(accent: 0x2a5bd7, canvas: 0xf2f2f2, ink: 0x000000, control: 0xdddddd, raised: 0xffffff),
        .lavender: Palette(accent: 0x5648c4, canvas: 0xf3f1f9, ink: 0x120f1a, control: 0xe0dcec, raised: 0xfcfbfe),
        .nautical: Palette(dark: .nautical),
    ]

    /// The tokens a theme replaces: the accent (tint, the user's bubble), the text on it, the agent's bubble, the
    /// canvas, cards and raised cards.
    struct Palette: @unchecked Sendable {
        let accent: UIColor
        let onAccent: UIColor
        let bubbleAgent: UIColor
        let canvas: UIColor
        let groupedRow: UIColor
        let raisedRow: UIColor
        /// The tile's faint lines (G4): the theme's ink, faint.
        let line: UIColor

        /// A dark theme from the Mac's palette: the canvas is its window, cards sit between its field and controls.
        init(dark theme: SidebarTheme) {
            let palette = theme.palette
            accent = UIColor(palette.accent)
            canvas = UIColor(palette.window)
            line = UIColor(palette.ink).withAlphaComponent(0.18)
            onAccent = UIColor(palette.window)
            bubbleAgent = UIColor(palette.control)
            groupedRow = UIColor(palette.field).blended(with: UIColor(palette.control), 0.6)
            raisedRow = UIColor(palette.control)
        }

        /// A light theme from sRGB hex values: white on the accent, the agent's bubble in `control`, cards `raised`.
        init(accent: UInt32, canvas: UInt32, ink: UInt32, control: UInt32, raised: UInt32) {
            self.accent = MobileTheme.color(accent)
            self.canvas = MobileTheme.color(canvas)
            line = MobileTheme.color(ink).withAlphaComponent(0.18)
            onAccent = .white
            bubbleAgent = MobileTheme.color(control)
            groupedRow = MobileTheme.color(raised)
            raisedRow = MobileTheme.color(raised)
        }
    }

    /// An sRGB hex colour, made the way `SidebarPalette` makes its own.
    static func color(_ hex: UInt32) -> UIColor {
        UIColor(Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255))
    }
}

/// The theme as a UIKit trait (the window's, set by `mobileAppearance()`), bridged to SwiftUI's environment, so the
/// themed catalog colours (`UIColor.themed`) resolve per view in UIKit and SwiftUI alike.
struct MobileThemeTrait: UITraitDefinition {
    static let defaultValue = MobileTheme.automatic
    static let affectsColorAppearance = true
    static let name = "DispatchTheme"
    static let identifier = "yachts.dispatch.mobile.theme"
}

struct MobileThemeKey: EnvironmentKey {
    static let defaultValue = MobileTheme.automatic
}

extension MobileThemeKey: UITraitBridgedEnvironmentKey {
    static func read(from traitCollection: UITraitCollection) -> MobileTheme { traitCollection[MobileThemeTrait.self] }
    static func write(to mutableTraits: inout UIMutableTraits, value: MobileTheme) { mutableTraits[MobileThemeTrait.self] = value }
}

extension EnvironmentValues {
    var mobileTheme: MobileTheme {
        get { self[MobileThemeKey.self] }
        set { self[MobileThemeKey.self] = newValue }
    }
}

extension UIColor {
    /// A catalog colour that a theme replaces: the theme's from `palette`, else the catalog's (light or dark).
    static func themed(_ name: String, _ palette: KeyPath<MobileTheme.Palette, UIColor>) -> UIColor {
        let catalog = UIColor.dispatch(name)
        return UIColor { traits in
            traits[MobileThemeTrait.self].palette?[keyPath: palette] ?? catalog.resolvedColor(with: traits)
        }
    }

    /// `self` mixed with `other` by `amount` (0 is `self`), in sRGB.
    func blended(with other: UIColor, _ amount: CGFloat) -> UIColor {
        var (r1, g1, b1, a1, r2, g2, b2, a2) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount, blue: b1 + (b2 - b1) * amount,
                       alpha: a1 + (a2 - a1) * amount)
    }
}
