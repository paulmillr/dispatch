import AppKit
import SwiftUI

// Colours the mockups draw with. The interface's come from the app's own Chrome.swift (linked: `Chrome.palette`,
// `Chrome.accent`…); the terminal's and chat's from the terminal scheme, as the app derives them: dispatch-black
// (extras/ghostty/dispatch-black, read from the checkout) under the theme's `defaultColorSchemeOverrides`.

/// A terminal colour scheme: background, foreground and the 16 ANSI colours.
struct TerminalScheme {
    var background: Color
    var foreground: Color
    var palette: [Color]
    fileprivate var raw: (background: NSColor, foreground: NSColor)
    /// The background's sRGB components (0...1), for passes over a rendered screen.
    var backgroundComponents: (CGFloat, CGFloat, CGFloat) {
        let c = raw.background.usingColorSpace(.sRGB) ?? raw.background
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    @MainActor static var current: TerminalScheme {
        let key = "\(SidebarThemeStore.shared.current.rawValue)/\(Mock.scheme ?? "")"
        return cached[key] ?? load(SidebarThemeStore.shared.current, scheme: Mock.scheme, key: key)
    }
    @MainActor private static var cached: [String: TerminalScheme] = [:]

    /// dispatch-black under the theme's overrides, or (`--scheme`) a bundled scheme as is: the app applies the overrides
    /// only to its default scheme (TerminalRuntime).
    @MainActor private static func load(_ theme: SidebarTheme, scheme: String?, key: String) -> TerminalScheme {
        let file = scheme.map { name in
            [Paths.mockups.appendingPathComponent("../Vendor/Term/Resources/ghostty/themes/\(name)"),
             Paths.mockups.appendingPathComponent("../extras/ghostty/\(name)")]
                .first { FileManager.default.fileExists(atPath: $0.path) } ?? URL(fileURLWithPath: "/nonexistent")
        } ?? Paths.mockups.appendingPathComponent("../extras/ghostty/dispatch-black")
        var values: [String: String] = [:], palette: [Int: String] = [:]
        let text = ((try? String(contentsOf: file, encoding: .utf8)) ?? "") + "\n" + (scheme == nil ? theme.defaultColorSchemeOverrides : "")
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].hasPrefix("#") else { continue }
            if parts[0] == "palette" {
                let entry = parts[1].split(separator: "=", maxSplits: 1)
                if entry.count == 2, let index = Int(entry[0]) { palette[index] = String(entry[1]) }
            } else {
                values[parts[0]] = parts[1]
            }
        }
        func color(_ hex: String?) -> NSColor {
            let value = UInt32((hex ?? "#808080").dropFirst(), radix: 16) ?? 0x808080
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        }
        let background = color(values["background"]), foreground = color(values["foreground"])
        let scheme = TerminalScheme(background: Color(nsColor: background), foreground: Color(nsColor: foreground),
                                    palette: (0..<16).map { Color(nsColor: color(palette[$0])) },
                                    raw: (background, foreground))
        cached[key] = scheme
        return scheme
    }
}

/// Chat's colours, derived from the terminal scheme as ChatTheme.init(config:) does.
struct ChatColors {
    let terminal, ink, muted, sidebar, window, border, selection: Color
    let red, green, yellow, blue, accent, cyan, comment: Color

    @MainActor static var current: ChatColors {
        let scheme = TerminalScheme.current
        let (background, foreground) = scheme.raw
        func blend(_ amount: CGFloat) -> Color { Color(nsColor: background.blended(withFraction: amount, of: foreground) ?? foreground) }
        let p = scheme.palette
        return ChatColors(terminal: scheme.background, ink: scheme.foreground, muted: blend(0.65), sidebar: blend(0.04),
                          window: blend(0.07), border: scheme.foreground.opacity(0.15), selection: blend(0.2),
                          red: p[1], green: p[2], yellow: p[3], blue: p[4], accent: p[5], cyan: p[6], comment: p[8])
    }
}

/// Chat's text: San Francisco drawn in SF Rounded at Source Code Pro's lowercase height (ChatTypography), on Source
/// Code Pro's line plus 4 points.
@MainActor enum ChatType {
    static var scale: CGFloat { AppFont.systemScale }
    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight, design: .rounded)
    }
    static var body: Font { font(14) }
    static var detail: Font { font(12).monospacedDigit() }
    static var reply: Font { font(15) }
    static var bodyLine: CGFloat { AppFont.lineHeight(size: 14) + 4 }

    // ChatTypography.init(preferences:)'s measurements, for San Francisco (drawn in SF Rounded) at size 14.
    private static func rounded(_ size: CGFloat) -> NSFont {
        let font = NSFont.systemFont(ofSize: size)
        return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
    }
    private static var selected: NSFont { rounded(14 * scale) }
    static var detailSize: CGFloat { 12 * scale }
    /// The code font's detail size (code stays unscaled): keycaps and the like.
    static let codeDetailSize: CGFloat = 12
    /// A "0"'s width: bubbles keep to 80 of them, a group's run chart is 16.
    static var characterWidth: CGFloat { ("0" as NSString).size(withAttributes: [.font: selected]).width }
    static var detailLineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: NSFont(descriptor: selected.fontDescriptor, size: detailSize) ?? rounded(detailSize))
    }
    static var replyLineHeight: CGFloat { NSLayoutManager().defaultLineHeight(for: rounded(15 * scale)) }
    /// An opened group's title column: the widest common step name in semibold detail text, plus a point.
    static var stepTitleWidth: CGFloat {
        let detail = NSFont(descriptor: selected.fontDescriptor, size: detailSize) ?? rounded(detailSize)
        let semibold = NSFont(descriptor: detail.fontDescriptor.addingAttributes(
            [.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold]]), size: detailSize) ?? detail
        let names = ["Shell", "Read", "Search", "Patch", "Edit", "Write", "Web", "Tool", "Locate"]
        return ceil(names.map { ($0 as NSString).size(withAttributes: [.font: semibold]).width }.max() ?? 64) + 1
    }
}

/// Liquid Glass does not draw offscreen, so glass surfaces are drawn as the app's capture shows them over a dark or
/// light window: opaque tones, sampled from build/ui-audit/main-sidebar-*.png (MainMockupPresentationTests, macOS 26.6
/// in the test VM, 2026-11-06) as ColorSync renders them into sRGB (a CGContext in sRGB, as a browser shows the PNG; the
/// capture carries the VM display's profile). Another macOS draws its glass in other tones: sample a new capture again.
@MainActor enum GlassTone {
    static var dark: Bool { Chrome.palette.isDark }
    /// The sidebar's glass panel (AppKit's sidebar glass, SpaceSidebar.glassPanel): the system's material, not the
    /// palette's sidebar. It floats 8 points in from the window's leading, top and bottom edges, with a 10-point
    /// corner and a hairline rim, on `sidebarWindow`.
    static var sidebar: Color { dark ? Color(hex: 0x171719) : Color(hex: 0xf8f8f9) }
    static var sidebarWindow: Color { dark ? Color(hex: 0x121214) : Color(hex: 0xededef) }
    static var sidebarEdge: Color { dark ? Color(hex: 0x353538) : Color(hex: 0xffffff) }
    /// The strip's capsule track, and the glass buttons beside it (and the sidebar's glass capsules and discs).
    static var track: Color { dark ? Color(hex: 0x161617) : Color(hex: 0xf6f6f7) }
    /// The glass's rim, a hairline brighter than its fill.
    static var trackEdge: Color { dark ? Color(hex: 0x2b2b2e) : Color(hex: 0xfefeff) }
    /// The selected tab's pill on the track.
    static var selected: Color { dark ? Color(hex: 0x1d1d1d) : Color(hex: 0xb8b8b9) }
    /// The strip's background behind the glass: the window's.
    static var bar: Color { dark ? Color(hex: 0x0d0d0f) : Color(hex: 0xeeeef0) }
    static var shadow: Color { .black.opacity(dark ? 0.35 : 0.1) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255, opacity: opacity)
    }
}

/// Settings the renderer applies to every screen (`--flat`), read by the kit.
@MainActor enum Mock {
    /// Liquid Glass, as the app ships by default; `--flat` draws flat chrome (LiquidGlassStore.active off).
    static var glass: Bool { LiquidGlassStore.shared.active }
    /// The sidebar's glass as macOS 26 draws it, a panel inset 8 points with a corner and rim; off, as macOS 27 draws
    /// it, a flush full-height column (SystemSidebarGlass in LiquidGlass.swift). macOS 27 is the current system.
    static var insetSidebar = false
    static var typography: AppTypography { AppTypography(contentSize: contentSize) }
    static var contentSize: CGFloat = 14
    /// The window's controlsInset (the zoom button's end + 16, AppDelegate), where the title row's controls start:
    /// measured from the app's captures, 85 on glass (main-sidebar-dark.png, 2026-11-06), 82 flat.
    static var controlsInset: CGFloat { glass ? 85 : 82 }
    /// `--scheme`: a bundled terminal scheme (Vendor/Term/Resources/ghostty/themes, extras/ghostty) in place of
    /// dispatch-black.
    static var scheme: String?
    /// The render's scale (`--scale`), for screens drawn as bitmaps.
    static var scale: CGFloat = 2
    /// The scheme draws with the phosphor glow and scanlines: the app's `SchemeGroup.glowing`.
    static var glowing: Bool { scheme.map { ["Root Access", "Red Alert", "Bluescreen"].contains($0) } ?? false }
}
