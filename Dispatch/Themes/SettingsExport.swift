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
        if let height = p.lineSpacing.cellHeight { lines.append("adjust-cell-height = \(height)") }
        lines.append("macos-option-as-alt = \(p.optionAsAlt.ghostty)")
        switch p.scrollback {
        case .automatic: break
        case .unlimited: lines.append("scrollback-limit-bytes = unlimited")
        case .lines10k, .lines100k: lines.append("scrollback-limit-lines = \(p.scrollback.lines ?? 0)")
        case .small, .large: lines.append("scrollback-limit-bytes = \(p.scrollback.limit(automatic: 0))")
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

    /// An exported folder (or its settings file) as an import: each setting that differs from `current` as its own row,
    /// the ones that run a command or loosen security apart (`cautions`), never this Mac's own answers (`machineKeys`);
    /// and its themes, under their own names so the settings still find them, unless one of yours has that name with
    /// other colors: then under a free name, which the settings take.
    static func plan(from location: URL, current: Preferences = Preferences()) throws -> ImportPlan {
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: location.path, isDirectory: &isFolder)
        let folder = isFolder.boolValue ? location : location.deletingLastPathComponent()
        let file = isFolder.boolValue ? location.appendingPathComponent(settingsName) : location
        var imported = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: file))
        var plan = ImportPlan(source: "Dispatch · \(folder.lastPathComponent)")
        var directory: ObjCBool = false
        var skip: Set<String> = machineKeys
        if !FileManager.default.fileExists(atPath: imported.startingDirectory, isDirectory: &directory) || !directory.boolValue {
            // This Mac's own folder stays when the exported one isn't here.
            plan.skipped.append("Starting folder \(imported.startingDirectory) (not on this Mac)")
            skip.insert("startingDirectory")
        }
        let themes = folder.appendingPathComponent(themesName, isDirectory: true)
        let bundled = Set((try? FileManager.default.contentsOfDirectory(atPath: System.resources.appendingPathComponent("ghostty/themes").path)) ?? [])
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: themes.path)) ?? []).sorted() where CustomThemes.valid(name) {
            guard !name.hasPrefix("dispatch"), let text = try? String(contentsOf: themes.appendingPathComponent(name), encoding: .utf8),
                  let theme = TerminalTheme(text: text) else { continue }
            var saved = CustomThemes.sanitized(name), note: String?
            if let mine = CustomThemes.theme(named: saved), mine.text != theme.text {
                saved = CustomThemes.uniqueName(saved, taken: bundled)
                note = "saved as “\(saved)”: your “\(name)” is kept"
                if imported.theme == name { imported.theme = saved }
                if imported.lightTheme == name { imported.lightTheme = saved }
            }
            plan.themes.append(.init(name: saved, theme: theme, role: .none, keepsName: true, note: note))
        }
        plan.changes = changes(from: current, to: imported, skipping: skip)
        return plan
    }

    /// This Mac's own answers, which an export from elsewhere never carries over: whether the setup sheet was shown,
    /// automatic updates, and the schemes colorblind mode keeps for when it is turned off.
    static let machineKeys: Set<String> = ["setupShown", "automaticUpdates", "typicalTheme", "typicalLightTheme"]

    /// Settings an import shows apart and unchecked: what runs commands or reaches past the terminal.
    static let cautions: [String: String] = [
        "startupCommand": "typed into every new local shell",
        "shell": "runs in every new local tab",
        "autoApproveUnsafePastes": "pastes can run commands without asking",
        "allowRemoteClipboardWrites": "programs can replace your clipboard",
        "enableKittyGraphics": "output can make Dispatch open files",
        "secureKeyboardEntry": "who can read your keystrokes",
        "autoGrantNewHosts": "new SSH hosts get every helper feature",
        "enableHostDetection": "whether the helper goes to SSH hosts",
        "autoReconnectSSH": "logs in again by itself",
    ]

    /// Settings' labels by stored key; another key reads as its words.
    static let labels: [String: String] = [
        "enableHostDetection": "Remote helper", "autoGrantNewHosts": "Auto-confirm uploads", "autoReconnectSSH": "Reconnect automatically",
        "secureKeyboardEntry": "Secure keyboard entry", "autoApproveUnsafePastes": "Automatically approve unsafe pastes",
        "attentionNotifications": "Notifications", "attentionDockBadge": "Dock badge", "attentionSound": "Attention sound",
        "attentionTextContent": "Display text content", "shipsBell": "Ship’s bell", "spaceOrder": "Space order",
        "automaticTabNames": "Automatic tab names", "fontFamily": "Terminal font", "fontLigatures": "Ligatures", "chatFont": "Chat font",
        "fontSize": "Font size", "appTheme": "Appearance", "theme": "Dark color scheme", "lightTheme": "Light color scheme",
        "cursor": "Cursor", "cursorBlink": "Blinking cursor", "lineSpacing": "Line spacing", "scrollback": "Scrollback",
        "keyGroups": "Number keys", "tabsOnly": "Vertical tabs", "hideSingleSpace": "Hide the sidebar with one space",
        "startingDirectory": "Starting folder", "shell": "Shell", "startupCommand": "Startup command", "rememberHosts": "Reopen spaces",
        "restoreTerminalOutput": "Reopen history", "enableDiagnostics": "Diagnostics", "outputWindow": "Slow connection mode",
        "sidebarStyle": "Space size", "showGitBranches": "Show git branch in spaces", "liquidGlass": "Liquid Glass",
        "hostColors": "Host colors", "showHostColors": "Color-code remote hosts", "textContrast": "Improve text contrast",
        "colorVision": "Colorblind-friendly", "terminalOpacity": "Terminal opacity", "spaces": "Tmux & herdr sessions as spaces",
        "enableKittyGraphics": "Kitty graphics", "filesEnabled": "Files", "filesDragAndDrop": "Drag and drop",
        "filesPreviews": "File previews", "filesLineNumbers": "Line numbers", "filesWrapLines": "Wrap lines",
        "filesRenderMarkdown": "Render Markdown", "gitEnabled": "Git", "chatSendWhileWorking": "While the agent works",
        "chatAgentStart": "Open agents in", "chatToolSteps": "Tool steps",
        "dictationEnabled": "Dictation", "dictationKey": "Dictate key", "dictationNavigation": "Navigate by voice",
        "dictationReadReplies": "Read replies aloud", "dictationWakeWords": "Wake words", "dictationEngine": "Dictation engine",
        "whisperModel": "Whisper model", "filesShowHiddenFiles": "Show hidden files", "interfaceTypeface": "Interface font",
        "allowRemoteClipboardWrites": "Programs can copy", "optionKeysAsAlt": "Option as Alt", "prefixSpaces": "Prefix keys",
    ]

    /// One change per stored setting that differs, in Settings' words, each setting only its own key.
    static func changes(from current: Preferences, to imported: Preferences, skipping skip: Set<String>) -> [ImportPlan.Change] {
        guard let mine = fields(current), let theirs = fields(imported) else { return [] }
        return theirs.keys.sorted().compactMap { key -> ImportPlan.Change? in
            guard !skip.contains(key), let value = theirs[key], !(mine[key].map { ($0 as AnyObject).isEqual(value) } ?? false) else { return nil }
            return .init(setting: labels[key] ?? words(key), value: shown(value, key: key), caution: cautions[key]) { preferences in
                guard var fields = fields(preferences) else { return }
                fields[key] = value
                if let data = try? JSONSerialization.data(withJSONObject: fields),
                   let next = try? JSONDecoder().decode(Preferences.self, from: data) { preferences = next }
            }
        }.sorted { ($0.caution == nil ? 0 : 1, $0.setting) < ($1.caution == nil ? 0 : 1, $1.setting) }
    }

    /// Preferences as stored: its JSON object.
    private static func fields(_ preferences: Preferences) -> [String: Any]? {
        (try? JSONEncoder().encode(preferences)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// A stored value as a row shows it.
    private static func shown(_ value: Any, key: String) -> String {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "on" : "off" }
        if let text = value as? String {
            if text.isEmpty { return "none" }
            return text.hasPrefix(System.home.path) ? "~" + text.dropFirst(System.home.path.count) : text
        }
        if let number = value as? NSNumber { return number.stringValue }
        if let list = value as? [String] { return list.joined(separator: ", ") }
        return "changed"
    }

    /// "autoReconnectSSH" as "Auto reconnect SSH".
    private static func words(_ key: String) -> String {
        var result = ""
        for (index, character) in key.enumerated() {
            if character.isUppercase, index > 0, let last = result.last, !last.isUppercase { result += " " }
            result.append(index == 0 ? Character(character.uppercased()) : character)
        }
        return result
    }
}
