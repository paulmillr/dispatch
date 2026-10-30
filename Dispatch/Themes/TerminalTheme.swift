import Foundation

/// An sRGB color as a theme file writes it (`#rrggbb`), or a Display P3 one outside sRGB with its sRGB stand-in.
struct ThemeColor: Hashable, Sendable {
    /// sRGB; for a Display P3 color, the nearest sRGB color (chroma reduced at the same OKLCH lightness and hue),
    /// which contrast checks, Ghostty and every other reader use.
    var r: UInt8, g: UInt8, b: UInt8
    /// The color in Display P3, when it lies outside sRGB; Dispatch's terminal draws it (`# display-p3:` lines).
    var displayP3: P3?

    struct P3: Hashable, Sendable {
        var r: UInt8, g: UInt8, b: UInt8
        var hex: String { String(format: "#%02x%02x%02x", r, g, b) }
    }

    init(r: UInt8, g: UInt8, b: UInt8) { (self.r, self.g, self.b) = (r, g, b) }

    /// Display P3 components in 0...1: an sRGB color when it fits sRGB, else this P3 color with its sRGB stand-in.
    init(displayP3Red red: Double, green: Double, blue: Double) {
        let (r, g, b) = Self.linearSRGB(displayP3: (Self.linear(red), Self.linear(green), Self.linear(blue)))
        // Within half an 8-bit step of sRGB is sRGB.
        let e = 0.5 / 255
        if [r, g, b].allSatisfy({ (-e...(1 + e)).contains(Self.gamma(max(0, $0))) && $0 >= -e }) {
            self.init(red: Self.gamma(max(0, r)), green: Self.gamma(max(0, g)), blue: Self.gamma(max(0, b)))
            return
        }
        self.init(oklch: OKLCH(lab: Self.oklab(linear: r, g, b)))
        func byte(_ c: Double) -> UInt8 { UInt8(max(0, min(255, (c * 255).rounded()))) }
        displayP3 = P3(r: byte(red), g: byte(green), b: byte(blue))
    }

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

    /// WCAG relative luminance, of a Display P3 color itself rather than its stand-in.
    var luminance: Double {
        let (red, green, blue) = linearSRGB
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
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
            if line.hasPrefix(Self.displayP3Prefix) { wide(line); continue }
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

    /// The theme file's text. A Display P3 color is its sRGB stand-in's line, then the same line in P3 as a comment
    /// (`# display-p3: background = #rrggbb`), which Ghostty skips and Dispatch's terminal reads.
    var text: String {
        var lines: [String] = []
        func add(_ key: String, _ color: ThemeColor?, prefix: String = "") {
            guard let color else { return }
            lines.append("\(key) = \(prefix)\(color.hex)")
            if let wide = color.displayP3 { lines.append("\(Self.displayP3Prefix) \(key) = \(prefix)\(wide.hex)") }
        }
        for (index, color) in palette.enumerated() { add("palette", color, prefix: "\(index)=") }
        add("background", background)
        add("foreground", foreground)
        add("cursor-color", cursor)
        add("cursor-text", cursorText)
        add("selection-background", selectionBackground)
        add("selection-foreground", selectionForeground)
        return (lines + extra).joined(separator: "\n") + "\n"
    }

    static let displayP3Prefix = "# display-p3:"

    /// The colors a theme file's `# display-p3:` lines give, over the sRGB ones already read.
    private mutating func wide(_ line: String) {
        let rest = line.dropFirst(Self.displayP3Prefix.count)
        guard let eq = rest.firstIndex(of: "=") else { return }
        let key = rest[..<eq].trimmingCharacters(in: .whitespaces)
        var value = rest[rest.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        var index: Int?
        if key == "palette" {
            let parts = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let i = Int(parts[0]), (0..<16).contains(i) else { return }
            (index, value) = (i, parts[1])
        }
        guard let p3 = ThemeColor(hex: value) else { return }
        let wide = ThemeColor.P3(r: p3.r, g: p3.g, b: p3.b)
        switch key {
        case "background": background.displayP3 = wide
        case "foreground": foreground.displayP3 = wide
        case "cursor-color": cursor?.displayP3 = wide
        case "cursor-text": cursorText?.displayP3 = wide
        case "selection-background": selectionBackground?.displayP3 = wide
        case "selection-foreground": selectionForeground?.displayP3 = wide
        case "palette": if let index { palette[index]?.displayP3 = wide }
        default: break
        }
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
