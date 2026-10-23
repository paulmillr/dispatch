import Foundation

/// An sRGB color as a theme file writes it (`#rrggbb`).
struct ThemeColor: Hashable, Sendable {
    var r: UInt8, g: UInt8, b: UInt8

    init(r: UInt8, g: UInt8, b: UInt8) { (self.r, self.g, self.b) = (r, g, b) }

    /// Components in 0...1, clamped and rounded.
    init(red: Double, green: Double, blue: Double) {
        func byte(_ c: Double) -> UInt8 { UInt8(max(0, min(255, (c * 255).rounded()))) }
        (r, g, b) = (byte(red), byte(green), byte(blue))
    }

    /// `#rgb`, `#rrggbb`, with or without the `#` (Ghostty's color.zig hex forms).
    init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        (r, g, b) = (UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF))
    }

    var hex: String { String(format: "#%02x%02x%02x", r, g, b) }
    var components: (Double, Double, Double) { (Double(r) / 255, Double(g) / 255, Double(b) / 255) }

    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (red, green, blue) = components
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1...21.
    func contrast(with other: ThemeColor) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// A terminal color scheme in Ghostty's theme syntax: the colors the terminal draws with and the 16 ANSI colors.
/// Anything else a theme file says is kept as written, so a round trip loses nothing.
struct TerminalTheme: Equatable, Sendable {
    var background = ThemeColor(r: 0x28, g: 0x2C, b: 0x34)
    var foreground = ThemeColor(r: 0xFF, g: 0xFF, b: 0xFF)
    var cursor: ThemeColor?
    var cursorText: ThemeColor?
    var selectionBackground: ThemeColor?
    var selectionForeground: ThemeColor?
    /// ANSI 0...15; nil keeps the terminal's standard color.
    var palette: [ThemeColor?] = Array(repeating: nil, count: 16)
    /// Lines this model doesn't read (palette entries past 15, comments, other keys), in order.
    var extra: [String] = []

    init() {}

    /// Parses theme text; nil when it names no background or foreground (not a color scheme).
    init?(text: String) {
        var sawColor = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { extra.append(line); continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            let color = ThemeColor(hex: value)
            switch key {
            case "background": if let color { background = color; sawColor = true } else { extra.append(line) }
            case "foreground": if let color { foreground = color; sawColor = true } else { extra.append(line) }
            case "cursor-color": if let color { cursor = color } else { extra.append(line) }
            case "cursor-text": if let color { cursorText = color } else { extra.append(line) }
            case "selection-background": if let color { selectionBackground = color } else { extra.append(line) }
            case "selection-foreground": if let color { selectionForeground = color } else { extra.append(line) }
            case "palette":
                let parts = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, let index = Int(parts[0]), (0..<16).contains(index), let color = ThemeColor(hex: parts[1]) {
                    palette[index] = color
                } else { extra.append(line) }
            default: extra.append(line)
            }
        }
        guard sawColor else { return nil }
    }

    /// The theme file's text.
    var text: String {
        var lines: [String] = []
        for (index, color) in palette.enumerated() { if let color { lines.append("palette = \(index)=\(color.hex)") } }
        lines.append("background = \(background.hex)")
        lines.append("foreground = \(foreground.hex)")
        if let cursor { lines.append("cursor-color = \(cursor.hex)") }
        if let cursorText { lines.append("cursor-text = \(cursorText.hex)") }
        if let selectionBackground { lines.append("selection-background = \(selectionBackground.hex)") }
        if let selectionForeground { lines.append("selection-foreground = \(selectionForeground.hex)") }
        return (lines + extra).joined(separator: "\n") + "\n"
    }

    /// true: light, false: dark, nil: either.
    var isLight: Bool? { Self.side(background: background, foreground: foreground) }

    /// A background darker than its text and well below the middle is dark; lighter than its text and well above it,
    /// light; anything between reads as either.
    static func side(background: ThemeColor, foreground: ThemeColor?) -> Bool? {
        let back = background.luminance, fore = foreground?.luminance
        if back < 0.18, fore.map({ $0 > back }) ?? true { return false }
        if back > 0.4, fore.map({ $0 < back }) ?? true { return true }
        return nil
    }
}
