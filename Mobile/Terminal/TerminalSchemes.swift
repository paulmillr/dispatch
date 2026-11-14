import Foundation

/// The terminal's color schemes (Settings, Terminal, Color scheme): Dispatch's (the app's `ghostty` folder,
/// `extras/ghostty`: Dispatch, and the phone's own Dispatch Night and Dispatch Darkroom) and Ghostty's bundled themes
/// (the app's `themes` folder, `Vendor/Term/Resources/ghostty/themes`), the files the Mac's scheme picker lists. Chat
/// takes its colours from the scheme too (`ChatPalette`).
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
        /// nil means the scheme belongs in both sections, as in the Mac's picker.
        var side: Bool?
        var isDark: Bool { side != true }
        /// Its section among the dark or the light schemes.
        var group: SchemeGroup { group(light: !isDark) }

        func group(light: Bool) -> SchemeGroup {
            let rgb = { (c: RGB) in (c.red, c.green, c.blue) }
            return SchemeGroup.of(file, background: rgb(background), accents: accents.map(rgb), light: light)
        }
    }

    struct RGB: Equatable, Sendable {
        let red: Double, green: Double, blue: Double
        init(_ red: Double, _ green: Double, _ blue: Double) { (self.red, self.green, self.blue) = (red / 255, green / 255, blue / 255) }

        init(_ color: ThemeColor) { self.init(Double(color.r), Double(color.g), Double(color.b)) }

        /// The shared theme parser's short and full hexadecimal forms.
        init?(hex: String) {
            guard let color = ThemeColor(hex: hex) else { return nil }
            self.init(color)
        }
    }

    /// Dispatch's own, first in the list in this order, by their titles (SchemeGroup.titles).
    static let own = ["dispatch-black", "dispatch-night", "dispatch-darkroom"]
    static let dispatch = Dictionary(uniqueKeysWithValues: own.map { ($0, SchemeGroup.title($0)) })
    /// Dispatch Gray (`dispatch`): the Mac's, no longer the phone's. A phone that chose it shows Dispatch.
    static let retired = ["dispatch"]

    /// The scheme a stored choice stands for: nil for none, a retired scheme's or one the app does not have.
    static func stored(_ file: String?) -> String? {
        guard let file, !retired.contains(file), url(file) != nil else { return nil }
        return file
    }

    static var dispatchFolder: URL { Bundle.main.bundleURL.appendingPathComponent("ghostty") }
    static var ghosttyFolder: URL { Bundle.main.bundleURL.appendingPathComponent("themes") }

    /// The scheme file's location; nil when the app has no such scheme.
    static func url(_ file: String, folders: [URL] = [dispatchFolder, ghosttyFolder]) -> URL? {
        guard !file.isEmpty, !file.contains("/") else { return nil }
        return folders.map { $0.appendingPathComponent(file) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The name the row shows (SchemeGroup.title): a few by title, the rest by file name.
    static func title(_ file: String) -> String { SchemeGroup.title(file) }

    /// Every scheme the app lists: Dispatch's own, then Ghostty's by name (a retired one of Dispatch's left out).
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
        let own = Self.own.compactMap { file in schemes.first { $0.file == file } }
        let rest = schemes.filter { dispatch[$0.file] == nil && !retired.contains($0.file) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return own + rest
    }

    /// The schemes Settings lists for `vision` (the Mac's `ColorSchemes.filtered`): a colorblind mode only the schemes
    /// made for it, typical vision none of those.
    static func listed(_ schemes: [Scheme], for vision: ColorVision) -> [Scheme] {
        schemes.filter { ColorVision(bundledScheme: $0.file) == vision }
    }

    /// A Ghostty theme file's colours: `background`, `foreground` and `palette = N=#rrggbb`.
    static func parse(_ text: String, file: String) -> Scheme {
        var scheme = Scheme(file: file, title: title(file))
        let parsed = TerminalTheme.parse(text)
        if parsed.hasBackground { scheme.background = RGB(parsed.theme.background) }
        if parsed.hasForeground { scheme.foreground = RGB(parsed.theme.foreground) }
        scheme.side = parsed.side
        scheme.accents = parsed.theme.palette[1...6].compactMap { $0.map(RGB.init) }
        scheme.problems = SchemeAudit.problems(name: file, theme: text)
        return scheme
    }
}
