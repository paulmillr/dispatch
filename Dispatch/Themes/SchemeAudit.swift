import Foundation

/// What makes a scheme hard to use, read from its theme file: the scheme lists mark it and say why. Contrast is WCAG's
/// ratio against the background. Fun schemes are left alone (their colors are the joke), classics too (people choose
/// them as they are), and so is the letter under a block cursor: a fifth of the bundled schemes draw it close to the
/// cursor's own color, too many to mark.
enum SchemeAudit {
    typealias RGB = (Double, Double, Double)

    /// The problems, worst first, as short phrases ("yellow hard to read"); empty when there are none.
    static func problems(name: String, theme: String) -> [String] {
        guard SchemeGroup.bundled[name] != .fun, SchemeGroup.classics[name] == nil else { return [] }
        var colors: [String: RGB] = [:], palette: [Int: RGB] = [:]
        for line in theme.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].hasPrefix("#") else { continue }
            if parts[0] == "palette" {
                // palette = N=#rrggbb
                let entry = parts[1].split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if entry.count == 2, let index = Int(entry[0]), let rgb = color(entry[1]) { palette[index] = rgb }
            } else if let rgb = color(parts[1]) {
                colors[parts[0]] = rgb
            }
        }
        guard let background = colors["background"] else { return [] }
        let foreground = colors["foreground"] ?? (1, 1, 1)
        let dark = luminance(background) < 0.18
        let contrast = { (rgb: RGB) in ratio(rgb, background) }
        var found: [String] = []

        let text = contrast(foreground)
        if text < 4.5 { found.append("text contrast only \(String(format: "%.1f", text)):1") }
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        let faint = (1...6).filter { palette[$0].map { contrast($0) < 2.5 } ?? false }.map { names[$0] }
        if !faint.isEmpty { found.append("\(list(faint)) hard to read") }
        if dark {
            // A light scheme's white (and a dark one's black) is meant to sit near the background.
            let whites = [(7, "white"), (15, "bright white")].filter { palette[$0.0].map { contrast($0) < 4.5 } ?? false }.map(\.1)
            if !whites.isEmpty { found.append("\(list(whites)) hard to read") }
        }
        if let dim = palette[8], contrast(dim) < 1.6 { found.append("dim text (bright black) invisible") }
        if dark {
            // Bright colors fainter than their normal ones: what a program brightens gets harder to read.
            let dimmer = (1...7).filter { i in
                guard let normal = palette[i], let bright = palette[i + 8] else { return false }
                return contrast(bright) < contrast(normal) * 0.75
            }
            if dimmer.count >= 3 { found.append("bright colors dimmer than normal") }
        }
        if let selection = colors["selection-background"],
           ratio(colors["selection-foreground"] ?? foreground, selection) < 3 {
            found.append("selected text hard to read")
        }
        if let cursor = colors["cursor-color"], contrast(cursor) < 2 { found.append("cursor hard to see") }
        return found
    }

    /// "yellow", "yellow and cyan", "red, green and blue".
    private static func list(_ names: [String]) -> String {
        names.count < 3 ? names.joined(separator: " and ") : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    /// `#rrggbb`, `rrggbb` or `#rgb` as 0...1 components; nil for anything else (`cell-foreground`).
    private static func color(_ text: String) -> RGB? {
        var hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return (Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// WCAG relative luminance.
    static func luminance(_ c: RGB) -> Double {
        let linear = { (v: Double) in v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.0) + 0.7152 * linear(c.1) + 0.0722 * linear(c.2)
    }

    /// WCAG contrast ratio, 1...21.
    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
