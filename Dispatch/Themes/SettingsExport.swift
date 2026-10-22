import Foundation

/// Settings › Extra › Export: one folder that carries everything. `config` is Ghostty's syntax, so Ghostty (or
/// Dispatch's Ghostty import) reads it as is; `themes/` holds every scheme it names that isn't bundled with both apps;
/// `dispatch-settings.json` is Dispatch's own settings, which Import Dispatch Settings restores exactly.
enum SettingsExport {
    static let configName = "config", themesName = "themes", settingsName = "dispatch-settings.json"

    /// Writes the folder (created, or its three entries replaced) and returns the theme names it holds.
    @discardableResult
    static func write(_ preferences: Preferences, to folder: URL) throws -> [String] {
        let fm = FileManager.default
        let themes = folder.appendingPathComponent(themesName, isDirectory: true)
        try fm.createDirectory(at: themes, withIntermediateDirectories: true)
        var written: [String] = []
        for (name, theme) in exportedThemes(preferences) {
            try Data(theme.text.utf8).write(to: themes.appendingPathComponent(name), options: .atomic)
            written.append(name)
        }
        try Data(ghosttyConfig(preferences).utf8).write(to: folder.appendingPathComponent(configName), options: .atomic)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preferences).write(to: folder.appendingPathComponent(settingsName), options: .atomic)
        return written
    }

    /// Dispatch's terminal settings as a Ghostty config. Only keys both apps read the same way.
    static func ghosttyConfig(_ p: Preferences) -> String {
        var lines = ["# Exported from Dispatch. Copy themes/ into ~/.config/ghostty/themes for Ghostty to find them.", ""]
        lines.append("font-family = \(p.fontFamily)")
        // A point, never the locale's comma: Ghostty parses Zig floats.
        lines.append("font-size = \(p.fontSize.rounded() == p.fontSize ? String(Int(p.fontSize)) : String(p.fontSize))")
        let dark = themeName(p.theme), light = themeName(p.lightTheme)
        switch p.appTheme {
        case .automatic: lines.append(light == dark ? "theme = \(dark)" : "theme = light:\(light),dark:\(dark)")
        default: lines.append("theme = \(p.appTheme.isDark(systemIsDark: true) ? dark : light)")
        }
        if p.improveTextContrast { lines.append("minimum-contrast = 4.5") }
        lines.append("cursor-style = \(p.cursor.rawValue)")
        if !p.cursorBlink { lines.append("cursor-style-blink = false") }
        lines.append("macos-option-as-alt = \(p.optionAsAlt.ghostty)")
        switch p.scrollback {
        case .automatic: break
        case .unlimited: lines.append("scrollback-limit-bytes = unlimited")
        default: lines.append("scrollback-limit-bytes = \(p.scrollback.limit(automatic: 0))")
        }
        if !p.shell.isEmpty { lines.append("command = \(p.shell)") }
        lines.append("working-directory = \(p.startingDirectory == System.home.path ? "home" : p.startingDirectory)")
        if !p.allowClipboardWrites { lines.append("clipboard-write = deny") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The names a config can give: "Default" is Dispatch's own scheme, which goes along under its file name.
    static func themeName(_ name: String) -> String { name == "Default" ? "dispatch-black" : name }

    /// Every custom scheme of Dispatch's, and the chosen ones that aren't bundled with Ghostty (Dispatch's own).
    static func exportedThemes(_ p: Preferences) -> [(String, TerminalTheme)] {
        var themes: [(String, TerminalTheme)] = []
        var names = Set<String>()
        for entry in CustomThemes.list() where !entry.ghostty {
            if let text = try? String(contentsOf: entry.url, encoding: .utf8), let theme = TerminalTheme(text: text) {
                themes.append((entry.name, theme)); names.insert(entry.name)
            }
        }
        for chosen in Set([themeName(p.theme), themeName(p.lightTheme)]) where !names.contains(chosen) {
            let url = System.resources.appendingPathComponent("ghostty/themes").appendingPathComponent(chosen)
            if chosen.hasPrefix("dispatch"), let text = try? String(contentsOf: url, encoding: .utf8),
               let theme = TerminalTheme(text: text) { themes.append((chosen, theme)) }
        }
        return themes.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    /// An exported folder (or its settings file) as an import: all of Dispatch's settings, and its themes under their
    /// own names, so the settings still find them.
    static func plan(from location: URL) throws -> ImportPlan {
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: location.path, isDirectory: &isFolder)
        let folder = isFolder.boolValue ? location : location.deletingLastPathComponent()
        let file = isFolder.boolValue ? location.appendingPathComponent(settingsName) : location
        var imported = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: file))
        var plan = ImportPlan(source: "Dispatch · \(folder.lastPathComponent)")
        var directory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: imported.startingDirectory, isDirectory: &directory) || !directory.boolValue {
            plan.skipped.append("Starting folder \(imported.startingDirectory) (not on this Mac; kept as is)")
            imported.startingDirectory = System.home.path
        }
        let themes = folder.appendingPathComponent(themesName, isDirectory: true)
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: themes.path)) ?? []).sorted() where CustomThemes.valid(name) {
            guard !name.hasPrefix("dispatch"), let text = try? String(contentsOf: themes.appendingPathComponent(name), encoding: .utf8),
                  let theme = TerminalTheme(text: text) else { continue }
            plan.themes.append(.init(name: name, theme: theme, role: .none, keepsName: true))
        }
        let settings = imported
        plan.changes.append(.init(setting: "All settings", value: "as exported") { preferences in
            // This Mac's own folder stays when the exported one isn't here.
            let folder = preferences.startingDirectory
            preferences = settings
            if settings.startingDirectory == System.home.path, folder != System.home.path { preferences.startingDirectory = folder }
        })
        return plan
    }
}
