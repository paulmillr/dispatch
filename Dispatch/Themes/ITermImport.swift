import AppKit

/// iTerm2's profiles as Dispatch can take them, one profile at a time, from its preferences
/// (com.googlecode.iterm2: "New Bookmarks" holds the profiles, "Default Bookmark Guid" names the default).
enum ITermImport {
    static let domain = "com.googlecode.iterm2"

    /// iTerm2's preferences on this Mac, nil without profiles. A custom preferences folder, when iTerm2 loads from
    /// one, wins.
    static func load() -> [String: Any]? {
        guard var preferences = ImportMapping.preferences(domain) else { return nil }
        if ImportMapping.bool(preferences["LoadPrefsFromCustomFolder"]) == true, let folder = preferences["PrefsCustomFolder"] as? String,
           let directory = ImportMapping.directory(folder),
           let data = try? Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(domain + ".plist")),
           let custom = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            preferences = custom
        }
        return profiles(in: preferences).isEmpty ? nil : preferences
    }

    /// The profiles, the default first.
    static func profiles(in preferences: [String: Any]) -> [ImportPlan.Profile] { entries(preferences).map(\.profile) }

    /// This Mac's iTerm2 profile (`profile`: a `Profile.id`, else the default), for the fonts Settings offers.
    @MainActor static func plan(profile: String? = nil) -> ImportPlan? {
        load().map { plan(preferences: $0, profile: profile, fonts: SettingsView.monospacedFontFamilies) }
    }

    /// A profile's settings (`profile`: a `Profile.id`, else the default profile).
    static func plan(preferences: [String: Any], profile: String? = nil, fonts: [String]) -> ImportPlan {
        let all = entries(preferences)
        guard let chosen = all.first(where: { $0.profile.id == profile }) ?? all.first else { return ImportPlan(source: "iTerm2") }
        return plan(profile: chosen.settings, named: chosen.profile.name, fonts: fonts)
    }

    static func plan(profile p: [String: Any], named name: String, fonts: [String]) -> ImportPlan {
        var plan = ImportPlan(source: "iTerm2 · \(name)")

        // "PostScriptName size", e.g. "SFMono-Regular 13".
        if let font = p["Normal Font"] as? String {
            let parts = font.split(separator: " ")
            let size = parts.count > 1 ? Double(parts[parts.count - 1]) : nil
            let postScript = (size == nil ? parts : parts.dropLast()).joined(separator: " ")
            if let family = NSFont(name: postScript, size: CGFloat(size ?? 12))?.familyName {
                plan.setFont(family, fonts: fonts, key: "Font")
            } else if !postScript.isEmpty {
                plan.skipped.append("Font \(postScript) (not installed)")
            }
            if let size { plan.setFontSize(size, key: "Font size") }
        }

        if ImportMapping.bool(p["Use Separate Colors for Light and Dark Mode"]) == true {
            for (suffix, role) in [(" (Light)", ImportPlan.Theme.Role.light), (" (Dark)", .dark)] {
                let label = suffix == " (Light)" ? "Light" : "Dark"
                plan.themes.append(.init(name: ImportMapping.themeName("iTerm2 · \(name) \(label)"), theme: theme(p, suffix: suffix), role: role))
            }
        } else if p["Background Color"] != nil || p["Foreground Color"] != nil || p["Ansi 0 Color"] != nil {
            plan.themes.append(.init(name: ImportMapping.themeName("iTerm2 · \(name)"), theme: theme(p, suffix: ""), role: .both))
        }

        switch ImportMapping.number(p["Cursor Type"]).map(Int.init) {
        case 0: plan.setCursor(.underline)
        case 1: plan.setCursor(.bar)
        case 2: plan.setCursor(.block)
        default: break
        }
        if let blink = ImportMapping.bool(p["Blinking Cursor"]) { plan.setCursorBlink(blink) }
        // 0 types characters; 1 (Meta) and 2 (Esc+) both act as Alt.
        let left = ImportMapping.number(p["Option Key Sends"]).map { $0 != 0 }, right = ImportMapping.number(p["Right Option Key Sends"]).map { $0 != 0 }
        if left != nil || right != nil {
            switch (left ?? false, right ?? false) {
            case (true, true): plan.setOptionAsAlt(.both)
            case (true, false): plan.setOptionAsAlt(.left)
            case (false, true): plan.setOptionAsAlt(.right)
            case (false, false): plan.setOptionAsAlt(.off)
            }
        }
        if ImportMapping.bool(p["Unlimited Scrollback"]) == true { plan.setScrollback(.unlimited) }
        else if let lines = ImportMapping.number(p["Scrollback Lines"]) { plan.setScrollback(ImportMapping.scrollback(lines: Int(lines))) }

        switch p["Custom Command"] as? String {
        case "No": plan.setShell("", key: "Command")
        case "Yes": plan.setShell(p["Command"] as? String ?? "", key: "Command")
        case "Custom Shell": plan.setShell(p["Custom Shell"] as? String ?? p["Command"] as? String ?? "", key: "Custom shell")
        default: break
        }
        switch p["Custom Directory"] as? String {
        case "No": plan.setStartingDirectory(System.home.path, key: "Working Directory")
        case "Yes": plan.setStartingDirectory(p["Working Directory"] as? String ?? "", key: "Working Directory")
        case "Recycle": plan.skipped.append("Reuse previous session's directory (new tabs follow the current folder)")
        case "Advanced": plan.skipped.append("Advanced working directory (one starting folder)")
        default: break
        }
        // iTerm2's 0...1 minimum contrast; any at all asks for legible text.
        if let contrast = ImportMapping.number(p["Minimum Contrast"]) { plan.setContrast(contrast > 0) }

        // iTerm2's 0 opaque … 1 clear; Dispatch takes the opacity, not the blur.
        if let transparency = ImportMapping.number(p["Transparency"]), transparency > 0 {
            plan.setTerminalOpacity(1 - transparency)
            if ImportMapping.bool(p["Blur"]) == true { plan.skipped.append("Blur (terminal opacity only)") }
        }
        if let image = p["Background Image Location"] as? String, !image.isEmpty { plan.skipped.append("Background image (no background images)") }
        if ImportMapping.bool(p["Use Bold Color"]) == true { plan.skipped.append("Bold color (bold text keeps its color)") }
        if ImportMapping.bool(p["ASCII Ligatures"]) == true { plan.skipped.append("Ligatures (not drawn)") }
        if ImportMapping.bool(p["Use Non-ASCII Font"]) == true { plan.skipped.append("Non-ASCII font (one font for all text)") }
        let spacing = ["Vertical Spacing", "Horizontal Spacing"].compactMap { ImportMapping.number(p[$0]) }
        if spacing.contains(where: { abs($0 - 1) > 0.001 }) { plan.skipped.append("Line and character spacing (not adjustable)") }
        if let triggers = p["Triggers"] as? [Any], !triggers.isEmpty { plan.skipped.append("Triggers (none in Dispatch)") }
        return plan
    }

    /// The profile's colors; `suffix` " (Light)" or " (Dark)" picks one mode's, each falling back to the shared key.
    static func theme(_ p: [String: Any], suffix: String) -> TerminalTheme {
        let color = { (key: String) -> ThemeColor? in self.color(p[key + suffix]) ?? self.color(p[key]) }
        var theme = TerminalTheme()
        // iTerm2's defaults: light gray on black.
        theme.background = color("Background Color") ?? ThemeColor(r: 0, g: 0, b: 0)
        theme.foreground = color("Foreground Color") ?? ThemeColor(r: 0xC7, g: 0xC7, b: 0xC7)
        // A smart cursor picks its colors from the text under it.
        if ImportMapping.bool(p["Smart Cursor Color" + suffix] ?? p["Smart Cursor Color"]) != true {
            theme.cursor = color("Cursor Color")
            theme.cursorText = color("Cursor Text Color")
        }
        theme.selectionBackground = color("Selection Color")
        if ImportMapping.bool(p["Use Selected Text Color" + suffix] ?? p["Use Selected Text Color"]) != false {
            theme.selectionForeground = color("Selected Text Color")
        }
        theme.palette = (0..<16).map { color("Ansi \($0) Color") }
        return theme
    }

    /// An iTerm2 color: components in its "Color Space" ("sRGB", "P3", else calibrated, i.e. generic RGB, as
    /// iTerm2 reads one without), in sRGB.
    static func color(_ value: Any?) -> ThemeColor? {
        guard let dict = value as? [String: Any], let red = ImportMapping.number(dict["Red Component"]),
              let green = ImportMapping.number(dict["Green Component"]), let blue = ImportMapping.number(dict["Blue Component"]) else { return nil }
        let (r, g, b) = (CGFloat(red), CGFloat(green), CGFloat(blue))
        let color = switch dict["Color Space"] as? String {
        case "sRGB": NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        case "P3": NSColor(displayP3Red: r, green: g, blue: b, alpha: 1)
        default: NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
        }
        return ThemeColor(color)
    }

    /// Each profile with its settings, the default first; one without a GUID goes by its place.
    private static func entries(_ preferences: [String: Any]) -> [(profile: ImportPlan.Profile, settings: [String: Any])] {
        let defaultID = preferences["Default Bookmark Guid"] as? String
        let all = (preferences["New Bookmarks"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.enumerated().map { index, settings in
            let id = settings["Guid"] as? String ?? "\(index)"
            return (profile: ImportPlan.Profile(id: id, name: settings["Name"] as? String ?? "Profile \(index + 1)", isDefault: id == defaultID),
                    settings: settings)
        }
        return all.filter { $0.profile.isDefault } + all.filter { !$0.profile.isDefault }
    }
}
