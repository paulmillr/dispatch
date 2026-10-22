import Foundation

/// Color schemes the user adds: Ghostty theme files in `~/.config/dispatch/themes`, which Dispatch writes when a theme
/// is imported, made or added, and Ghostty's own `~/.config/ghostty/themes`, which it only reads. A theme is chosen by
/// its file name, like a bundled one.
enum CustomThemes {
    struct Entry: Hashable {
        let name: String
        let url: URL
        /// Ghostty's folder: listed and used, never written.
        let ghostty: Bool
        /// true: light, false: dark, nil: either.
        let light: Bool?
    }

    static var directory: URL { System.home.appendingPathComponent(".config/dispatch/themes", isDirectory: true) }

    /// Ghostty's user themes (os/xdg.zig: $XDG_CONFIG_HOME, else ~/.config).
    static var ghosttyDirectory: URL {
        let xdg = System.environment("XDG_CONFIG_HOME").flatMap { $0.isEmpty ? nil : $0 }
        let config = xdg.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? System.home.appendingPathComponent(".config", isDirectory: true)
        return config.appendingPathComponent("ghostty/themes", isDirectory: true)
    }

    /// Dispatch's themes, then Ghostty's whose names Dispatch's don't take, each sorted by name.
    static func list() -> [Entry] {
        let own = entries(in: directory, ghostty: false)
        let names = Set(own.map(\.name))
        return own + entries(in: ghosttyDirectory, ghostty: true).filter { !names.contains($0.name) }
    }

    /// Dispatch's own theme file of this name, when there is one.
    static func url(named name: String) -> URL? {
        guard valid(name) else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func theme(named name: String) -> TerminalTheme? {
        let candidates = [url(named: name), valid(name) ? ghosttyDirectory.appendingPathComponent(name) : nil].compactMap { $0 }
        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8), let theme = TerminalTheme(text: text) { return theme }
        }
        return nil
    }

    /// Writes the theme under `name` (replacing one of that name) and returns where.
    @discardableResult
    static func save(_ theme: TerminalTheme, named name: String) throws -> URL {
        guard valid(name) else { throw ThemeError.invalidName }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(theme.text.utf8).write(to: url, options: .atomic)
        return url
    }

    static func delete(named name: String) throws {
        guard let url = url(named: name) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// `base`, or `base 2`, `base 3`… so that no custom or bundled theme has the name.
    static func uniqueName(_ base: String, taken: Set<String> = []) -> String {
        let base = sanitized(base)
        let used = taken.union(list().map(\.name))
        var name = base, n = 2
        while used.contains(name) { name = "\(base) \(n)"; n += 1 }
        return name
    }

    /// A file name: no path separators, no leading dot, at most 64 characters.
    static func sanitized(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Custom" : String(cleaned.prefix(64))
    }

    static func valid(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") && !name.contains(where: \.isNewline)
    }

    enum ThemeError: LocalizedError {
        case invalidName
        var errorDescription: String? { "Choose a theme name without “/” or a leading dot." }
    }

    private static func entries(in directory: URL, ghostty: Bool) -> [Entry] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter(valid).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return names.compactMap { name in
            let url = directory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8), TerminalTheme(text: text) != nil else { return nil }
            return Entry(name: name, url: url, ghostty: ghostty, light: ColorSchemes.side(text))
        }
    }
}

/// What `theme =` says for a chosen scheme name: a bundled name as is, a custom one by its file's path, and anything
/// the terminal couldn't find as Dispatch's own scheme, so a deleted or renamed theme never stops the terminal.
enum ThemeResolution {
    static func value(for name: String, resources: URL = System.resources) -> (value: String, missing: Bool) {
        if let url = CustomThemes.url(named: name) { return (url.path, false) }
        guard CustomThemes.valid(name) else { return ("dispatch-black", true) }
        let places = [resources.appendingPathComponent("ghostty/themes"), CustomThemes.ghosttyDirectory]
        if places.contains(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) }) {
            return (name, false)
        }
        return ("dispatch-black", true)
    }
}
