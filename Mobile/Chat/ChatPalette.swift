import SwiftUI

/// Chat's colours, from the terminal's scheme as the Mac's chat takes them (`ChatTheme`): the thread on the scheme's
/// background, text in its foreground with muted and faint shades blended toward the background, the agent's bubble a
/// little lighter than the background, the user's in the scheme's accent (ANSI magenta) with the background as its text,
/// code in the scheme's colours. Dispatch, the default, keeps the app's own colours (`standard`), and a scheme on the
/// other side from the app's appearance (a dark scheme in light mode) does too, so chat never turns dark in light mode.
/// Dispatch Night and Dispatch Darkroom are drawn outlined: no fills, hairline bubbles, code and composer, no glass.
/// Computed once per scheme and side (`current`), so a scrolling thread only reads values.
struct ChatPalette: Equatable {
    /// What the palette is: "app", or the scheme's file and side; caches that bake colours in key on it.
    var id: String
    var canvas: Color
    var ink: Color
    var muted: Color
    var faint: Color
    var agentFill: Color?
    var agentBorder: Color?
    var userFill: Color?
    var userBorder: Color?
    var userText: Color
    var codeFill: Color?
    var codeBorder: Color?
    var hairline: Color
    var accent: Color
    var syntax: CodeSyntax.Colors
    /// The composer's controls on Liquid Glass; false, flat on the canvas with a hairline (the night schemes).
    var glass: Bool
    var chromeBorder: Color?
    /// From a scheme: the thread sets text's hierarchical styles from it.
    var themed: Bool
    /// Every mark's colour where the app has fixed ones (step badges, status marks, the composer's glyphs): Darkroom's
    /// red, so nothing in the thread leaves its one hue. Nil keeps them.
    var monochrome: Color? = nil

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }

    /// The app's own colours: Dispatch, and every scheme on the other side from the appearance.
    static let standard = ChatPalette(
        id: "app", canvas: .canvas, ink: .primary, muted: .secondary, faint: Color(uiColor: .tertiaryLabel),
        agentFill: .bubbleAgent, agentBorder: nil, userFill: .bubbleUser, userBorder: nil, userText: .bubbleUserText,
        codeFill: .faintFill, codeBorder: nil, hairline: .hairline, accent: .dispatchPink, syntax: .standard,
        glass: true, chromeBorder: nil, themed: false)

    /// The schemes drawn outlined.
    static let outlined: Set<String> = ["dispatch-night", "dispatch-darkroom"]

    /// The palette for `file` (a stored choice, `TerminalSchemes.stored`) in the appearance `dark`.
    @MainActor static func current(file: String?, dark: Bool) -> ChatPalette {
        let file = TerminalSchemes.stored(file) ?? TerminalConfiguration.defaultScheme
        guard file != TerminalConfiguration.defaultScheme else { return .standard }
        if cache[file] == nil {
            let text = TerminalSchemes.url(file).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            cache[file] = .some(text.flatMap { derived(file: file, text: $0) })
        }
        guard let derived = cache[file] ?? nil, derived.dark == dark else { return .standard }
        return derived.palette
    }

    @MainActor private static var cache: [String: (palette: ChatPalette, dark: Bool)?] = [:]

    /// `file`'s palette and whether its background is dark; nil for a file without both colours.
    static func derived(file: String, text: String) -> (palette: ChatPalette, dark: Bool)? {
        let parsed = TerminalTheme.parse(text)
        guard parsed.hasBackground, parsed.hasForeground else { return nil }
        let background = RGB(parsed.theme.background), foreground = RGB(parsed.theme.foreground)
        let ansi = parsed.theme.palette.map { $0.map(RGB.init) }
        func color(_ index: Int, _ fallback: RGB) -> Color { ((ansi.indices.contains(index) ? ansi[index] : nil) ?? fallback).color }
        func blend(_ amount: Double) -> Color { background.mix(foreground, amount).color }
        let dark = background.luminance < 0.5
        let accent = color(5, foreground)
        let syntax = CodeSyntax.Colors(id: file, colors: [
            .plain: foreground.color, .keyword: accent, .call: color(4, foreground), .string: color(2, foreground),
            .type: color(13, foreground), .number: color(3, foreground), .comment: color(8, background.mix(foreground, 0.5)),
        ])
        var palette = ChatPalette(
            id: file + (dark ? ":dark" : ":light"), canvas: background.color, ink: foreground.color, muted: blend(0.65),
            faint: blend(0.4), agentFill: blend(0.1), agentBorder: nil, userFill: accent, userBorder: nil,
            userText: background.color, codeFill: blend(0.05), codeBorder: nil, hairline: foreground.color.opacity(0.15),
            accent: accent, syntax: syntax, glass: true, chromeBorder: nil, themed: true)
        if outlined.contains(file) {
            // Z1: hairlines on black, nothing filled; the user's bubble outlined in the accent, its text the accent. The
            // dim schemes' secondary and tertiary text sit nearer the foreground, or the faintest (the steps line, the
            // plan's limits) would be all but black.
            palette.muted = blend(0.78)
            palette.faint = blend(0.6)
            palette.agentFill = nil
            palette.agentBorder = blend(0.18)
            palette.userFill = nil
            palette.userBorder = accent.opacity(0.55)
            palette.userText = accent
            palette.codeFill = nil
            palette.codeBorder = blend(0.14)
            palette.hairline = blend(0.16)
            palette.glass = false
            palette.chromeBorder = blend(0.18)
            if file == "dispatch-darkroom" { palette.monochrome = accent }
            if file == "dispatch-night" {
                // The user's bubble filled, as Dispatch's: the dimmed accent with black text, the agent's still outlined.
                palette.userFill = accent
                palette.userBorder = nil
                palette.userText = background.color
            }
        }
        return (palette, dark)
    }

    struct RGB: Equatable {
        var red: Double, green: Double, blue: Double

        init(_ color: ThemeColor) {
            red = Double(color.r) / 255; green = Double(color.g) / 255; blue = Double(color.b) / 255
        }

        init(red: Double, green: Double, blue: Double) { (self.red, self.green, self.blue) = (red, green, blue) }

        var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
        var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

        /// `amount` of the way toward `other`.
        func mix(_ other: RGB, _ amount: Double) -> RGB {
            RGB(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
                blue: blue + (other.blue - blue) * amount)
        }
    }
}

extension EnvironmentValues {
    /// The thread's colours (`ChatPalette`); the app's own outside a thread.
    @Entry var chatPalette = ChatPalette.standard
}

extension View {
    /// A chat control's surface: Liquid Glass, or for the night schemes flat on the canvas with a hairline.
    func chatSurface<S: InsettableShape>(_ shape: S) -> some View {
        modifier(ChatSurface(shape: shape))
    }
}

private struct ChatSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.chatPalette) private var palette

    func body(content: Content) -> some View {
        if palette.glass {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content
                .background(palette.canvas, in: shape)
                .overlay { shape.strokeBorder(palette.chromeBorder ?? palette.hairline, lineWidth: 1) }
        }
    }
}
