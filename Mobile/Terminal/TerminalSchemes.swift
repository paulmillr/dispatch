import Foundation

/// The terminal's color schemes (Settings, Terminal, Color scheme): Dispatch's two (the app's `ghostty` folder,
/// `extras/ghostty`) and Ghostty's bundled themes (the app's `themes` folder, `Vendor/Term/Resources/ghostty/themes`),
/// the files the Mac's scheme picker lists.
enum TerminalSchemes {
    /// One scheme: its file name, the name shown, and what its swatch draws.
    struct Scheme: Identifiable, Equatable, Sendable {
        let file: String
        let title: String
        var background = RGB(0, 0, 0)
        var foreground = RGB(255, 255, 255)
        /// Palette colours 1 to 6 (red to cyan), the swatch's dots.
        var accents: [RGB] = []
        /// What makes it hard to use (SchemeAudit), shown as a warning sign after its name.
        var problems: [String] = []
        var id: String { file }
        /// A dark background (relative luminance under a half).
        var isDark: Bool { background.luminance < 0.5 }
        /// Its section among the dark or the light schemes.
        var group: SchemeGroup {
            let rgb = { (c: RGB) in (c.red, c.green, c.blue) }
            return SchemeGroup.of(file, background: rgb(background), accents: accents.map(rgb), light: !isDark)
        }
    }

    struct RGB: Equatable, Sendable {
        let red: Double, green: Double, blue: Double
        init(_ red: Double, _ green: Double, _ blue: Double) { (self.red, self.green, self.blue) = (red / 255, green / 255, blue / 255) }

        /// `#rrggbb` or `rrggbb`.
        init?(hex: String) {
            let digits = hex.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }
            guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
            self.init(Double(value >> 16 & 255), Double(value >> 8 & 255), Double(value & 255))
        }

        var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    }

    /// Dispatch's own, first in the list, by their titles (SchemeGroup.titles).
    static let dispatch = Dictionary(uniqueKeysWithValues: ["dispatch-black", "dispatch"].map {
        ($0, SchemeGroup.title($0))
    })

    static var dispatchFolder: URL { Bundle.main.bundleURL.appendingPathComponent("ghostty") }
    static var ghosttyFolder: URL { Bundle.main.bundleURL.appendingPathComponent("themes") }

    /// The scheme file's location; nil when the app has no such scheme.
    static func url(_ file: String, folders: [URL] = [dispatchFolder, ghosttyFolder]) -> URL? {
        guard !file.isEmpty, !file.contains("/") else { return nil }
        return folders.map { $0.appendingPathComponent(file) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The name the row shows (SchemeGroup.title): a few by title, the rest by file name.
    static func title(_ file: String) -> String { SchemeGroup.title(file) }

    /// Every scheme the app has: Dispatch and Dispatch Gray, then Ghostty's by name.
    static func all(folders: [URL] = [dispatchFolder, ghosttyFolder]) -> [Scheme] {
        var files: [URL] = []
        for folder in folders {
            files += ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { !$0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }
        }
        let schemes = files.compactMap { url -> Scheme? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return parse(text, file: url.lastPathComponent)
        }
        let own = ["dispatch-black", "dispatch"].compactMap { file in schemes.first { $0.file == file } }
        let rest = schemes.filter { dispatch[$0.file] == nil }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return own + rest
    }

    /// A Ghostty theme file's colours: `background`, `foreground` and `palette = N=#rrggbb`.
    static func parse(_ text: String, file: String) -> Scheme {
        var scheme = Scheme(file: file, title: title(file))
        var palette: [Int: RGB] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "background": if let rgb = RGB(hex: parts[1]) { scheme.background = rgb }
            case "foreground": if let rgb = RGB(hex: parts[1]) { scheme.foreground = rgb }
            case "palette":
                let entry = parts[1].split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if entry.count == 2, let index = Int(entry[0]), let rgb = RGB(hex: entry[1]) { palette[index] = rgb }
            default: break
            }
        }
        scheme.accents = (1...6).compactMap { palette[$0] }
        scheme.problems = SchemeAudit.problems(name: file, theme: text)
        return scheme
    }
}
