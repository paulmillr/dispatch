import AppKit

/// Terminal's profiles as Dispatch can take them, one profile at a time, from its preferences (com.apple.Terminal:
/// "Window Settings" holds the profiles by name, "Default Window Settings" names the default). Fonts and colors are
/// keyed archives of NSFont and NSColor.
enum TerminalAppImport {
    static let domain = "com.apple.Terminal"

    /// Terminal's preferences on this Mac, nil without profiles.
    static func load() -> [String: Any]? {
        guard let preferences = ImportMapping.preferences(domain), !profiles(in: preferences).isEmpty else { return nil }
        return preferences
    }

    /// The profiles, the default first, then by name.
    static func profiles(in preferences: [String: Any]) -> [ImportPlan.Profile] {
        let defaultName = preferences["Default Window Settings"] as? String
        return windowSettings(preferences).keys
            .sorted { a, b in a == defaultName || b != defaultName && a.localizedStandardCompare(b) == .orderedAscending }
            .map { ImportPlan.Profile(id: $0, name: $0, isDefault: $0 == defaultName) }
    }

    /// This Mac's Terminal profile (`profile`: its name, else the default), for the fonts Settings offers.
    @MainActor static func plan(profile: String? = nil) -> ImportPlan? {
        load().map { plan(preferences: $0, profile: profile, fonts: SettingsView.terminalFontFamilies) }
    }

    /// A profile's settings (`profile`: its name, else the default profile), with Terminal's own Shell setting.
    static func plan(preferences: [String: Any], profile: String? = nil, fonts: [String]) -> ImportPlan {
        let all = windowSettings(preferences)
        guard let name = profile.flatMap({ all[$0] == nil ? nil : $0 }) ?? profiles(in: preferences).first?.id, let settings = all[name] else {
            return ImportPlan(source: "Terminal")
        }
        return plan(profile: settings, named: name, shell: preferences["Shell"] as? String, fonts: fonts)
    }

    /// The ANSI colors' keys, 0...15.
    static let paletteKeys = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"].map { "ANSI\($0)Color" }
        + ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"].map { "ANSIBright\($0)Color" }

    /// `shell`: Terminal's "Shells open with" command, which a profile's command run as the shell overrides.
    static func plan(profile p: [String: Any], named name: String, shell: String?, fonts: [String]) -> ImportPlan {
        var plan = ImportPlan(source: "Terminal · \(name)")

        if let font = (p["Font"] as? Data).flatMap({ try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: $0) }) {
            if let family = font.familyName { plan.setFont(family, fonts: fonts, key: "Font") }
            plan.setFontSize(Double(font.pointSize), key: "Font size")
        }

        let colors = p.keys.contains { $0.hasSuffix("Color") && $0 != "TextBoldColor" }
        if colors {
            var theme = TerminalTheme()
            // Terminal's defaults: black text on white.
            let background = color(p["BackgroundColor"])
            theme.background = background.flatMap { ThemeColor($0) } ?? ThemeColor(r: 0xFF, g: 0xFF, b: 0xFF)
            theme.foreground = color(p["TextColor"]).flatMap { ThemeColor($0) } ?? ThemeColor(r: 0, g: 0, b: 0)
            theme.cursor = color(p["CursorColor"]).flatMap { ThemeColor($0) }
            theme.selectionBackground = color(p["SelectionColor"]).flatMap { ThemeColor($0) }
            theme.palette = paletteKeys.map { color(p[$0]).flatMap { ThemeColor($0) } }
            let role: ImportPlan.Theme.Role = switch theme.isLight { case true?: .light; case false?: .dark; case nil: .both }
            plan.themes.append(.init(name: ImportMapping.themeName("Terminal · \(name)"), theme: theme, role: role))
            // The background color's alpha is the window's opacity; Dispatch takes it, not the blur.
            if let alpha = background?.alphaComponent, alpha < 1 {
                plan.setTerminalOpacity(alpha)
                if ImportMapping.number(p["BackgroundBlur"]).map({ $0 > 0 }) == true { plan.skipped.append("Background blur (terminal opacity only)") }
            }
        } else {
            plan.skipped.append("Colors (this profile follows the system's light or dark appearance)")
        }

        switch ImportMapping.number(p["CursorType"]).map(Int.init) {
        case 0: plan.setCursor(.block)
        case 1: plan.setCursor(.underline)
        case 2: plan.setCursor(.bar)
        default: break
        }
        if let blink = ImportMapping.bool(p["CursorBlink"]) { plan.setCursorBlink(blink) }
        if let meta = ImportMapping.bool(p["useOptionAsMetaKey"]) { plan.setOptionAsAlt(meta ? .both : .off) }
        if let limited = ImportMapping.bool(p["ShouldLimitScrollback"]) {
            plan.setScrollback(limited ? ImportMapping.scrollback(lines: Int(ImportMapping.number(p["ScrollbackLines"]) ?? 10_000)) : .unlimited)
        }

        // RunCommandAsShell: "Run inside shell" off, so the command is the shell; on, it's a command the shell runs.
        let command = (p["CommandString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !command.isEmpty, ImportMapping.bool(p["RunCommandAsShell"]) == true {
            plan.setShell(command, key: "Run command")
        } else {
            if !command.isEmpty { plan.skipped.append("Run command (no startup command)") }
            if let shell, !shell.trimmingCharacters(in: .whitespaces).isEmpty { plan.setShell(shell, key: "Shells open with") }
        }

        if p["TextBoldColor"] != nil { plan.skipped.append("Bold text color (bold text keeps its color)") }
        if p["BackgroundImageBookmark"] != nil { plan.skipped.append("Background image (no background images)") }
        let spacing = ["FontHeightSpacing", "FontWidthSpacing"].compactMap { ImportMapping.number(p[$0]) }
        if spacing.contains(where: { abs($0 - 1) > 0.001 }) { plan.skipped.append("Character and line spacing (not adjustable)") }
        return plan
    }

    /// An archived NSColor.
    static func color(_ value: Any?) -> NSColor? {
        (value as? Data).flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: $0) }
    }

    private static func windowSettings(_ preferences: [String: Any]) -> [String: [String: Any]] {
        (preferences["Window Settings"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
    }
}
