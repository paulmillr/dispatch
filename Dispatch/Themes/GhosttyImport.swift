import Foundation

/// Ghostty's settings as Dispatch can take them. Reads the user's config files (and the files they include) as
/// Ghostty would, never writing them; a named theme comes along as a copy, so it keeps working without Ghostty.
enum GhosttyImport {
    /// A theme by its `theme =` name; nil when there's none.
    typealias ThemeLookup = (String) -> TerminalTheme?

    /// Ghostty's config files in the order it loads them, later ones winning (config/Config.zig loadDefaultFiles):
    /// $XDG_CONFIG_HOME/ghostty (else ~/.config/ghostty), then macOS's Application Support folder; in each, `config`
    /// and then `config.ghostty`. Only the ones there.
    static func configURLs(home: URL = System.home, xdg: String? = System.environment("XDG_CONFIG_HOME")) -> [URL] {
        let config = xdg.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent(".config", isDirectory: true)
        let folders = [config.appendingPathComponent("ghostty"), home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")]
        return folders.flatMap { folder in ["config", "config.ghostty"].map { folder.appendingPathComponent($0) } }
            .filter { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    /// The config Ghostty reads on this Mac, nil when it has none: Settings offers the import only then.
    static var configURL: URL? { configURLs().first }

    /// This Mac's Ghostty settings, for the fonts Settings offers; nil without a config.
    @MainActor static func plan() -> ImportPlan? {
        let files = configURLs()
        guard !files.isEmpty else { return nil }
        return plan(files: files, fonts: SettingsView.terminalFontFamilies)
    }

    /// The settings of these config files, in Ghostty's order, and of the files they include.
    static func plan(files: [URL], fonts: [String], theme: ThemeLookup = theme(named:)) -> ImportPlan {
        var skipped: [String] = []
        let roots = files.compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map { (text: $0, file: Optional(url), directory: Optional(url.deletingLastPathComponent())) }
        }
        return plan(lines: load(roots, skipped: &skipped), skipped: skipped, fonts: fonts, theme: theme)
    }

    /// The settings of config text; its `config-file` includes resolve against `directory` (without one, only
    /// absolute paths do).
    static func plan(text: String, directory: URL? = nil, fonts: [String], theme: ThemeLookup = theme(named:)) -> ImportPlan {
        var skipped: [String] = []
        let lines = load([(text, nil, directory)], skipped: &skipped)
        return plan(lines: lines, skipped: skipped, fonts: fonts, theme: theme)
    }

    /// A theme by its `theme =` value (config/theme.zig): an absolute path, or a name in Ghostty's user themes, then
    /// Dispatch's bundled themes, then an installed Ghostty's own.
    static func theme(named name: String) -> TerminalTheme? {
        let places: [URL]
        if name.hasPrefix("/") { places = [URL(fileURLWithPath: name)] }
        else {
            guard !name.isEmpty, !name.contains("/") else { return nil }
            places = [CustomThemes.ghosttyDirectory, System.resources.appendingPathComponent("ghostty/themes"),
                      URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes")]
                .map { $0.appendingPathComponent(name) }
        }
        for url in places {
            if let text = try? String(contentsOf: url, encoding: .utf8), let theme = TerminalTheme(text: text) { return theme }
        }
        return nil
    }

    // MARK: Reading

    struct Line: Equatable { let key: String; let value: String? }

    /// Ghostty's line reader (cli/args.zig LineIterator): `key = value`, whitespace trimmed, one pair of quotes around
    /// the value dropped; blank lines and `#` comments skipped; a line without `=` is a key without a value.
    static func lines(_ text: String) -> [Line] {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            guard let eq = line.firstIndex(of: "=") else { return Line(key: line, value: nil) }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            return Line(key: line[..<eq].trimmingCharacters(in: .whitespaces), value: value)
        }
    }

    /// The most files one import reads, includes and all.
    static let fileLimit = 32

    /// The lines of `roots`, then of the files their `config-file` lines name, each file's after the ones before it
    /// as Ghostty loads them (loadRecursiveFiles: an include applies after the file naming it, whatever comes later
    /// there). Relative paths are relative to the including file; a `?` makes one optional. A file read once is not
    /// read again, which also ends cycles.
    static func load(_ roots: [(text: String, file: URL?, directory: URL?)], skipped: inout [String]) -> [Line] {
        var result: [Line] = [], queue: [(path: String, optional: Bool, directory: URL?)] = [], next = 0
        var seen = Set(roots.compactMap { $0.file?.standardizedFileURL.path })
        func take(_ text: String, in directory: URL?) {
            for line in lines(text) {
                guard line.key == "config-file" else { result.append(line); continue }
                var path = line.value ?? ""
                // An empty value clears the includes not yet read.
                guard !path.isEmpty else { queue.removeSubrange(next...); continue }
                let optional = path.hasPrefix("?")
                if optional { path.removeFirst() }
                if path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") { path = String(path.dropFirst().dropLast()) }
                queue.append((path, optional, directory))
            }
        }
        for root in roots { take(root.text, in: root.directory) }
        while next < queue.count {
            let include = queue[next]
            next += 1
            let name = (include.path as NSString).lastPathComponent
            guard seen.count < fileLimit else { skipped.append("config-file \(name) (more than \(fileLimit) files)"); break }
            var path = include.path
            if path == "~" || path.hasPrefix("~/") { path = System.home.path + path.dropFirst() }
            let url: URL
            if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
            else if let directory = include.directory { url = directory.appendingPathComponent(path) }
            else { skipped.append("config-file \(name) (relative to no file)"); continue }
            guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                if !include.optional { skipped.append("config-file \(name) (not found)") }
                continue
            }
            take(text, in: url.deletingLastPathComponent())
        }
        return result
    }

    // MARK: Mapping

    /// Keys that set the colors over the theme (config/Config.zig's theme replay).
    static let colorKeys: Set<String> = ["background", "foreground", "cursor-color", "cursor-text", "selection-background",
                                         "selection-foreground", "palette"]

    /// Keys Dispatch maps; every other key that's set is either listed as unsupported below or ignored.
    static let mappedKeys: Set<String> = colorKeys.union(["theme", "font-family", "font-size", "cursor-style", "cursor-style-blink",
        "adjust-cell-height", "macos-option-as-alt", "scrollback-limit", "scrollback-limit-bytes", "scrollback-limit-lines", "command", "working-directory",
        "minimum-contrast", "clipboard-write", "clipboard-read", "image-storage-limit", "background-opacity"])

    /// What a user might expect to come along but can't, by why. Ghostty's many other keys aren't mentioned.
    static let unsupported: [(reason: String, matches: @Sendable (String) -> Bool)] = [
        ("terminal opacity only", { ["background-opacity-cells", "background-blur", "unfocused-split-opacity"].contains($0) }),
        ("no background images", { $0.hasPrefix("background-image") }),
        ("Dispatch arranges its own windows", { $0.hasPrefix("window-") || $0.hasPrefix("macos-titlebar") || $0.hasPrefix("macos-window")
            || ["maximize", "fullscreen", "macos-non-native-fullscreen"].contains($0) }),
        ("Dispatch keeps its own shortcuts", { $0 == "keybind" }),
        ("font styles and features", { $0.hasPrefix("font-") && $0 != "font-family" && $0 != "font-size" }),
        ("no cell adjustments", { $0.hasPrefix("adjust-") }),
        ("mouse behavior", { $0.hasPrefix("mouse-") || ["copy-on-select", "focus-follows-mouse", "right-click-action", "middle-click-action"].contains($0) }),
        ("Dispatch's own shell integration", { $0.hasPrefix("shell-integration") }),
        ("no custom shaders", { $0.hasPrefix("custom-shader") }),
        ("no quick terminal", { $0.hasPrefix("quick-terminal") }),
        ("no startup command or environment", { ["initial-command", "env", "input"].contains($0) }),
        ("bold text keeps its color", { $0 == "bold-color" }),
    ]

    static func plan(lines: [Line], skipped: [String], fonts: [String], theme lookup: ThemeLookup) -> ImportPlan {
        var plan = ImportPlan(source: "Ghostty", skipped: skipped)
        // Each key's last value; an empty one restores Ghostty's default, as if never set. font-family repeats (the
        // first is the font, the rest fallbacks); colors replay over the theme in order.
        var last: [String: String?] = [:], families: [String] = [], colors: [Line] = [], order: [String] = []
        for line in lines {
            if !order.contains(line.key) { order.append(line.key) }
            if colorKeys.contains(line.key) { colors.append(line); continue }
            if line.key == "font-family" {
                if let value = line.value, !value.isEmpty { families.append(value) } else { families = [] }
                continue
            }
            if line.value == "" { last[line.key] = nil } else { last[line.key] = .some(line.value) }
        }
        let value = { (key: String) -> String? in last[key] ?? nil }

        if let family = families.first { plan.setFont(family, fonts: fonts, key: "font-family") }
        if let size = value("font-size").flatMap(Double.init) { plan.setFontSize(size, key: "font-size") }
        themes(value("theme"), colors: colors, lookup: lookup, into: &plan)

        switch value("cursor-style") {
        case "block", "block_hollow": plan.setCursor(.block)
        case "bar": plan.setCursor(.bar)
        case "underline": plan.setCursor(.underline)
        default: break
        }
        switch value("cursor-style-blink") {
        case "false": plan.setCursorBlink(false)
        case "true": plan.setCursorBlink(true)
        default: break
        }
        // The nearest of Settings' line spacings to a percentage; pixels depend on the font, so they stay behind.
        if let height = value("adjust-cell-height") {
            if height.hasSuffix("%"), let percent = Double(height.dropLast()), percent.isFinite {
                let scale = 1 + percent / 100
                plan.setLineSpacing(LineSpacing.allCases.min { abs($0.scale - scale) < abs($1.scale - scale) } ?? .normal)
            } else {
                plan.skipped.append("adjust-cell-height \(height) (Dispatch takes a percentage)")
            }
        }
        switch value("macos-option-as-alt") {
        case "true": plan.setOptionAsAlt(.both)
        case "false": plan.setOptionAsAlt(.off)
        case "left": plan.setOptionAsAlt(.left)
        case "right": plan.setOptionAsAlt(.right)
        default: break
        }
        // Released Ghostty's scrollback-limit and newer builds' scrollback-limit-bytes are bytes; -lines, lines.
        if let bytes = value("scrollback-limit-bytes") ?? value("scrollback-limit") {
            if bytes == "unlimited" { plan.setScrollback(.unlimited) }
            else if let n = UInt64(bytes) { plan.setScrollback(ImportMapping.scrollback(bytes: n >= UInt64(Int.max) ? nil : Int(n))) }
        } else if let lines = value("scrollback-limit-lines") {
            if lines == "unlimited" { plan.setScrollback(.unlimited) }
            else if let n = Int(lines) { plan.setScrollback(ImportMapping.scrollback(lines: n)) }
        }
        if var command = value("command") {
            // Ghostty 1.2's `direct:` and `shell:` prefixes say how it starts the command.
            for prefix in ["direct:", "shell:"] where command.hasPrefix(prefix) { command.removeFirst(prefix.count) }
            plan.setShell(command, key: "command")
        }
        switch value("working-directory") {
        case nil: break
        // `inherit` from an app opened in the Finder or Dock is the home folder.
        case "home"?, "inherit"?: plan.setStartingDirectory(System.home.path, key: "working-directory")
        case let path?: plan.setStartingDirectory(path, key: "working-directory")
        }
        if let contrast = value("minimum-contrast").flatMap(Double.init) { plan.setContrast(contrast > 1) }
        if let opacity = value("background-opacity").flatMap(Double.init), opacity.isFinite { plan.setTerminalOpacity(opacity) }
        switch value("clipboard-write") {
        case "deny": plan.setClipboardWrites(false)
        case "allow", "ask": plan.setClipboardWrites(true)
        default: break
        }
        if value("clipboard-read") == "allow" { plan.skipped.append("clipboard-read (programs never read the clipboard)") }
        // Kitty graphics stay opt-in: only Ghostty's turning them off comes along.
        if value("image-storage-limit").flatMap(Int.init) == 0 { plan.setKittyGraphics(false) }

        let set = order.filter { !mappedKeys.contains($0) && value($0) != nil }
        for group in unsupported {
            let keys = set.filter(group.matches)
            if !keys.isEmpty { plan.skipped.append(ImportMapping.listed(keys, group.reason)) }
        }
        return plan
    }

    /// The `theme =` value's themes as copies, and the config's own colors over them as one more ("Ghostty", or
    /// "Ghostty Light" and "Ghostty Dark" for a light/dark pair), which then take the scheme roles.
    static func themes(_ value: String?, colors: [Line], lookup: ThemeLookup, into plan: inout ImportPlan) {
        let pair = value.flatMap(Self.pair)
        if value != nil, pair == nil { plan.skipped.append("theme (not a theme name or light/dark pair)") }
        let sides: [(name: String, role: ImportPlan.Theme.Role, label: String)] = switch pair {
        case let (light, dark)? where light == dark: [(light, .both, "Ghostty")]
        case let (light, dark)?: [(light, .light, "Ghostty Light"), (dark, .dark, "Ghostty Dark")]
        case nil: [("", .both, "Ghostty")]
        }
        for side in sides {
            var base = TerminalTheme()
            if !side.name.isEmpty {
                if let theme = lookup(side.name) {
                    base = theme
                    let name = ImportMapping.themeName((side.name as NSString).lastPathComponent)
                    plan.themes.append(.init(name: name, theme: theme, role: colors.isEmpty ? side.role : .none))
                } else {
                    plan.skipped.append("theme \(side.name) (not found)")
                }
            }
            if !colors.isEmpty { plan.themes.append(.init(name: side.label, theme: overlay(colors, on: base), role: side.role)) }
        }
    }

    /// Theme.parseCLI: one name for both sides, or `light:a,dark:b` when the value has a `,`, `=` or `:` (an absolute
    /// path with neither works as a name).
    static func pair(_ value: String) -> (light: String, dark: String)? {
        guard value.contains(where: { ",=:".contains($0) }) else { return (value, value) }
        var light: String?, dark: String?
        for entry in value.split(separator: ",", omittingEmptySubsequences: false) {
            guard let colon = entry.firstIndex(of: ":") else { return nil }
            var name = entry[entry.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") { name = String(name.dropFirst().dropLast()) }
            switch entry[..<colon].trimmingCharacters(in: .whitespaces) {
            case "light": light = name
            case "dark": dark = name
            default: return nil
            }
        }
        guard let light, let dark else { return nil }
        return (light, dark)
    }

    /// The config's color lines replayed over a theme, as Ghostty's finalize does; an empty value restores Ghostty's
    /// default color, and a value this model can't hold (`cell-foreground`, an X11 name) leaves the color as it was.
    static func overlay(_ colors: [Line], on base: TerminalTheme) -> TerminalTheme {
        var theme = base
        let defaults = TerminalTheme()
        for line in colors {
            let value = line.value ?? ""
            let color = ThemeColor(hex: value)
            switch line.key {
            case "background": theme.background = value.isEmpty ? defaults.background : color ?? theme.background
            case "foreground": theme.foreground = value.isEmpty ? defaults.foreground : color ?? theme.foreground
            case "cursor-color": theme.cursor = value.isEmpty ? nil : color ?? theme.cursor
            case "cursor-text": theme.cursorText = value.isEmpty ? nil : color ?? theme.cursorText
            case "selection-background": theme.selectionBackground = value.isEmpty ? nil : color ?? theme.selectionBackground
            case "selection-foreground": theme.selectionForeground = value.isEmpty ? nil : color ?? theme.selectionForeground
            case "palette":
                guard !value.isEmpty else { theme.palette = defaults.palette; continue }
                let parts = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, let index = Int(parts[0]), (0..<16).contains(index), let color = ThemeColor(hex: parts[1]) {
                    theme.palette[index] = color
                }
            default: break
            }
        }
        return theme
    }
}
