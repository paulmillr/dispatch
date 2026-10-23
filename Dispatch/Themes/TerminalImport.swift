import AppKit

extension ImportPlan {
    /// One of iTerm2's or Terminal's profiles, each imported on its own.
    struct Profile: Hashable, Identifiable {
        /// What `plan(preferences:profile:)` takes: iTerm2's GUID, Terminal's profile name.
        let id: String
        let name: String
        let isDefault: Bool
    }

    /// The setting `field` set to `value`, shown in the plan as `setting` → `shown`.
    mutating func set<Value>(_ setting: String, _ shown: String, _ field: WritableKeyPath<Preferences, Value>, _ value: Value) {
        changes.append(Change(setting: setting, value: shown, apply: { $0[keyPath: field] = value }))
    }

    /// The terminal font, when it is one Settings offers (`fonts`); otherwise said in `skipped` as `key`.
    mutating func setFont(_ family: String, fonts: [String], key: String) {
        // A hidden system family (Terminal's own profiles decode to .AppleSystemUIFont) is the SF Mono they show.
        let name = family.hasPrefix(".") ? "SF Mono" : family.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let match = fonts.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            set("Terminal font", match, \.fontFamily, match)
        } else {
            skipped.append("\(key) \(name) (not a monospaced font on this Mac)")
        }
    }

    /// The font size, in the range Settings saves.
    mutating func setFontSize(_ size: Double, key: String) {
        let shown = size.formatted(.number.precision(.fractionLength(0...1)))
        guard (8...32).contains(size) else { return skipped.append("\(key) \(shown) pt (Dispatch takes 8–32 pt)") }
        set("Font size", "\(shown) pt", \.fontSize, size)
    }

    mutating func setCursor(_ cursor: TerminalCursor) { set("Cursor", cursor.title, \.cursor, cursor) }
    mutating func setCursorBlink(_ on: Bool) { set("Blinking cursor", on ? "On" : "Off", \.cursorBlink, on) }
    mutating func setOptionAsAlt(_ keys: OptionKeys) { set("Option as Alt", keys.title, \.optionAsAlt, keys) }
    mutating func setScrollback(_ size: Scrollback) { set("Scrollback", size.title, \.scrollback, size) }
    mutating func setContrast(_ on: Bool) { set("Improve text contrast", on ? "On" : "Off", \.improveTextContrast, on) }
    /// Within what Settings offers: lower comes in at its floor.
    mutating func setTerminalOpacity(_ opacity: Double) {
        let range = Preferences.terminalOpacityRange
        let value = ((min(max(opacity, range.lowerBound), range.upperBound)) * 20).rounded() / 20
        set("Terminal opacity", value.formatted(.percent.precision(.fractionLength(0))), \.terminalOpacity, value)
    }
    mutating func setClipboardWrites(_ on: Bool) { set("Programs can copy", on ? "On" : "Off", \.allowClipboardWrites, on) }
    mutating func setKittyGraphics(_ on: Bool) { set("Kitty graphics", on ? "On" : "Off", \.enableKittyGraphics, on) }

    /// The shell new local tabs run: "" for the login shell, else a command `ImportMapping.shell` accepts; any other
    /// command is said in `skipped` as `key`.
    mutating func setShell(_ command: String, key: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return set("Shell", "Login shell", \.shell, "") }
        guard let shell = ImportMapping.shell(trimmed) else { return skipped.append("\(key) (not a program by its full path)") }
        set("Shell", shell, \.shell, shell)
    }

    /// The starting folder, when it exists.
    mutating func setStartingDirectory(_ path: String, key: String) {
        guard let folder = ImportMapping.directory(path) else { return skipped.append("\(key) (folder not found)") }
        let home = System.home.path
        let shown = folder == home ? "~" : folder.hasPrefix(home + "/") ? "~" + folder.dropFirst(home.count) : folder
        set("Starting folder", shown, \.startingDirectory, folder)
    }
}

/// What the importers share: reading property list values, and mapping other terminals' sizes, commands and colors
/// onto Dispatch's choices.
enum ImportMapping {
    /// Scrollback in bytes (nil: unlimited) as the nearest Settings choice. Automatic is 50–256 MB, so a limit up to
    /// 30 MB keeps the small 10 MB, up to 512 MB takes Automatic, and anything larger 1 GB.
    static func scrollback(bytes: Int?) -> Scrollback {
        guard let bytes else { return .unlimited }
        return bytes <= 30_000_000 ? .small : bytes <= 512_000_000 ? .automatic : .large
    }

    /// Scrollback in lines, at about a kilobyte a line (a wide terminal row of Ghostty's 8-byte cells).
    static func scrollback(lines: Int) -> Scrollback { scrollback(bytes: lines > Int.max / 1_000 ? .max : max(0, lines) * 1_000) }

    /// A command as Dispatch's Shell takes it: a program by its full path (one Dispatch can run, without spaces in
    /// its path), then its arguments. nil for anything else, such as a command line for a shell to interpret.
    static func shell(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline), let program = trimmed.split(separator: " ", maxSplits: 1).first,
              program.hasPrefix("/"), !program.contains("\""), !program.contains("'"),
              FileManager.default.isExecutableFile(atPath: String(program)) else { return nil }
        return trimmed
    }

    /// An existing folder's full path, `~` expanded; nil when there's none.
    static func directory(_ path: String) -> String? {
        var path = path.trimmingCharacters(in: .whitespaces)
        if path == "~" { path = System.home.path } else if path.hasPrefix("~/") { path = System.home.appendingPathComponent(String(path.dropFirst(2))).path }
        var folder: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &folder), folder.boolValue else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// A property list number, or a string of one.
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let text as String: Double(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    /// A property list Boolean, number or "YES"/"NO" string.
    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber: number.boolValue
        case let text as String: ["yes", "true", "1"].contains(text.lowercased()) ? true : ["no", "false", "0"].contains(text.lowercased()) ? false : nil
        default: nil
        }
    }

    /// A domain's preferences as the defaults system has them (cfprefsd may hold changes not yet in the file); nil
    /// while testing, so tests never read the user's own.
    static func preferences(_ domain: String) -> [String: Any]? {
        guard !System.testing else { return nil }
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyMultiple(nil, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any]
    }

    /// A theme named for its source, its file name sanitized.
    static func themeName(_ name: String) -> String { CustomThemes.sanitized(name) }

    /// Keys, at most three of them by name, with why: "window-theme, window-padding-x (…)".
    static func listed(_ keys: [String], _ reason: String) -> String {
        let shown = keys.prefix(3).joined(separator: ", ")
        return (keys.count > 3 ? "\(shown) and \(keys.count - 3) more" : shown) + " (\(reason))"
    }
}

extension ThemeColor {
    /// An AppKit color in sRGB (colors outside it clamped); nil for a pattern or other color without components.
    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent))
    }
}
