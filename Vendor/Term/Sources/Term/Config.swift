// Ghostty's config text for the keys Dispatch writes and theme files set (config/Config.zig with
// cli/args.zig's line reader and field parsers): the same text gives the same values and
// diagnostics. Keys of Ghostty's config outside this set are accepted unread.

/// The version Ghostty 31bdcd5 reports when built from a detached checkout, as Dispatch builds it
/// (build/Config.zig: branch "HEAD" as the pre-release, the newline turned into '-' before trimming,
/// the short hash as the build): XTVERSION, TERM_PROGRAM_VERSION.
public let ghosttyVersion = "1.3.2-HEAD-+31bdcd5"

/// This module was compiled optimized (hosts check their build: unoptimized, output drains 18-80x slower).
@_spi(Test) public let optimized = !_isDebugAssertConfiguration()

public struct Config {
    public enum Clipboard: String { case allow, deny, ask }
    public enum OptionAsAlt: String { case `false`, `true`, left, right }
    public struct ShellIntegration: Equatable {
        public var cursor = true, sudo = false, title = true, sshEnv = false, sshTerminfo = false, path = true
    }

    public var background = RGB(r: 0x28, g: 0x2C, b: 0x34), foreground = RGB(r: 0xFF, g: 0xFF, b: 0xFF)
    public var cursorColor: DrawConfig.Source?, cursorText: DrawConfig.Source?
    public var selectionBackground: DrawConfig.Source?, selectionForeground: DrawConfig.Source?
    public var palette = Palette.standard
    public var fontFamily: [String] = []
    #if os(macOS)
    public var fontSize: Float = 13
    #else
    public var fontSize: Float = 12
    #endif
    public var minimumContrast = 1.0
    /// window-padding-x/-y: (top or left, bottom or right).
    public var paddingX = (2, 2), paddingY = (2, 2)
    public var optionAsAlt: OptionAsAlt?
    public var clipboardRead = Clipboard.ask, clipboardWrite = Clipboard.allow
    public var term = "xterm-ghostty"
    /// Each new terminal's scrollback, in bytes of pages; nil: `unlimited`.
    public var scrollbackLimitBytes: Int? = 50_000_000
    /// Kitty image storage. Zero disables Kitty graphics before its commands are buffered.
    public var imageStorageLimitBytes = ImageStorage.defaultTotalLimit
    public var shellIntegration = ShellIntegration()
    /// keybind lines in order after the last `clear` (Bindings parses them).
    public var keybinds: [String] = []
    public var theme: (light: String, dark: String)?
    /// (key, message) like Ghostty's diagnostics.
    public var diagnostics: [(key: String, message: String)] = []
    /// The lines applied, to replay over a theme.
    var steps: [(key: String, value: String?)] = []

    public init() {}

    /// Applies config text (Ghostty's LineIterator + parseIntoField).
    public mutating func load(_ text: [UInt8]) {
        for raw in text.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let line = trim(raw, " \t\r")
            guard let first = line.first, first != 0x23 else { continue }
            let step: (key: String, value: String?)
            if let eq = line.firstIndex(of: 0x3D) {
                var value = trim(line[(eq + 1)...], " \t")
                if value.count >= 2, value.first == 0x22, value.last == 0x22 { value = value.dropFirst().dropLast() }
                step = (String(decoding: trim(line[..<eq], " \t"), as: UTF8.self), String(decoding: value, as: UTF8.self))
            } else {
                step = (String(decoding: line, as: UTF8.self), nil)
            }
            steps.append(step)
            set(step.key, step.value)
        }
    }

    /// Ghostty's finalize: the theme text loaded first (nil: not loaded, the loader's messages are
    /// the diagnostics) and this config's lines again over it (`dark` picks a light/dark pair's
    /// side), then minimum-contrast kept in 1...21.
    public mutating func finalize(dark: Bool, theme load: (String, inout [String]) -> [UInt8]?) {
        defer { minimumContrast = min(21, max(1, minimumContrast)) }
        guard let theme else { return }
        var messages: [String] = []
        let text = load(dark ? theme.dark : theme.light, &messages)
        diagnostics += messages.map { ("", $0) }
        guard let text else { return }
        var next = Config()
        next.load(text)
        for s in steps { next.set(s.key, s.value) }
        next.steps = steps
        self = next
    }

    mutating func set(_ key: String, _ value: String?) {
        let bad = { (self: inout Config) in self.diagnostics.append((key, "invalid value \"\(value ?? "")\"")) }
        let required = { (self: inout Config) in self.diagnostics.append((key, "value required")) }
        // An empty value restores the default.
        if value == "" {
            let d = Config()
            switch key {
            case "background": background = d.background
            case "foreground": foreground = d.foreground
            case "cursor-color": cursorColor = nil
            case "cursor-text": cursorText = nil
            case "selection-background": selectionBackground = nil
            case "selection-foreground": selectionForeground = nil
            case "palette": palette = d.palette
            case "font-family": fontFamily = []
            case "font-size": fontSize = d.fontSize
            case "minimum-contrast": minimumContrast = d.minimumContrast
            case "window-padding-x": paddingX = d.paddingX
            case "window-padding-y": paddingY = d.paddingY
            case "macos-option-as-alt": optionAsAlt = nil
            case "clipboard-read": clipboardRead = d.clipboardRead
            case "clipboard-write": clipboardWrite = d.clipboardWrite
            case "term": term = d.term
            case "scrollback-limit-bytes": scrollbackLimitBytes = d.scrollbackLimitBytes
            case "image-storage-limit": imageStorageLimitBytes = d.imageStorageLimitBytes
            case "shell-integration-features": shellIntegration = d.shellIntegration
            case "keybind": keybinds = []
            case "theme": theme = nil
            default: if !ghosttyConfigKeys.contains(key) { diagnostics.append((key, "unknown field")) }
            }
            return
        }
        guard ghosttyConfigKeys.contains(key) else { diagnostics.append((key, "unknown field")); return }
        let modeled = ["background", "foreground", "cursor-color", "cursor-text", "selection-background", "selection-foreground", "palette",
                       "font-family", "font-size", "minimum-contrast", "window-padding-x", "window-padding-y", "macos-option-as-alt",
                       "clipboard-read", "clipboard-write", "term", "scrollback-limit-bytes", "image-storage-limit", "shell-integration-features", "keybind", "theme"]
        guard modeled.contains(key) else { return }
        guard let v = value else { return required(&self) }
        let bytes = Array(v.utf8)
        func color() -> RGB? { parseRGB(bytes) }
        func terminalColor() -> DrawConfig.Source?? {
            if v == "cell-foreground" { return .some(.cellForeground) }
            if v == "cell-background" { return .some(.cellBackground) }
            return color().map { .some(.color($0)) }
        }
        switch key {
        case "background": if let c = color() { background = c } else { bad(&self) }
        case "foreground": if let c = color() { foreground = c } else { bad(&self) }
        case "cursor-color": if let c = terminalColor() { cursorColor = c } else { bad(&self) }
        case "cursor-text": if let c = terminalColor() { cursorText = c } else { bad(&self) }
        case "selection-background": if let c = terminalColor() { selectionBackground = c } else { bad(&self) }
        case "selection-foreground": if let c = terminalColor() { selectionForeground = c } else { bad(&self) }
        case "palette":
            // color.zig parsePaletteEntry: `index=color`, the index like Zig's parseInt(u8, _, 0).
            guard let eq = bytes.firstIndex(of: 0x3D) else { return bad(&self) }
            switch Self.int(trim(bytes[..<eq], " \t"), max: 255) {
            case .none: bad(&self)
            case .some(nil): diagnostics.append((key, "unknown error error.Overflow"))
            case .some(let i?): if let c = parseRGB(bytes[(eq + 1)...]) { palette[Int(i)] = c } else { bad(&self) }
            }
        case "font-family": fontFamily.append(v)
        case "font-size": if let f = Self.float(bytes).map(Float.init) { fontSize = f } else { bad(&self) }
        case "minimum-contrast": if let f = Self.float(bytes) { minimumContrast = f } else { bad(&self) }
        case "window-padding-x", "window-padding-y":
            // WindowPadding.parseCLI: `n` or `a,b`, decimal u32s.
            let parts = bytes.split(separator: 0x2C, maxSplits: 1, omittingEmptySubsequences: false).map { trim($0, " \t") }
            let n = parts.map { zigInt($0, base: 10, max: UInt64(UInt32.max), signed: true) }
            guard !n.contains(where: { $0 == nil }) else { return bad(&self) }
            let p = (Int(n[0]!), Int(n[parts.count - 1]!))
            if key == "window-padding-x" { paddingX = p } else { paddingY = p }
        case "macos-option-as-alt": if let o = OptionAsAlt(rawValue: v) { optionAsAlt = o } else { bad(&self) }
        case "clipboard-read", "clipboard-write":
            guard let c = Clipboard(rawValue: v) else {
                return diagnostics.append((key, "invalid value \"\(v)\", valid values are: allow, deny, ask"))
            }
            if key == "clipboard-read" { clipboardRead = c } else { clipboardWrite = c }
        case "term": term = v
        case "scrollback-limit-bytes":
            // Limit(usize).parseCLI: `unlimited` or parseInt(_, 0); usize's maximum is unlimited too.
            if v == "unlimited" { scrollbackLimitBytes = nil }
            else if case let n?? = Self.int(bytes[...], max: .max) { scrollbackLimitBytes = n == .max ? nil : Int(clamping: n) }
            else { bad(&self) }
        case "image-storage-limit":
            if case let n?? = Self.int(bytes[...], max: UInt64(ImageStorage.defaultTotalLimit)) { imageStorageLimitBytes = Int(n) }
            else { bad(&self) }
        case "shell-integration-features": if let f = Self.features(bytes) { shellIntegration = f } else { bad(&self) }
        case "keybind": if v == "clear" { keybinds = [] } else { keybinds.append(v) }
        case "theme": if let t = Self.theme(bytes) { theme = t } else { bad(&self) }
        default: break
        }
    }

    /// Zig's parseInt(u8-sized, _, 0): sign, then 0x/0o/0b or decimal. nil: not a number;
    /// .some(nil): too big.
    static func int(_ s: ArraySlice<UInt8>, max: UInt64) -> UInt64?? {
        var body = s, negative = false
        if let c = body.first, c == 0x2B || c == 0x2D { negative = c == 0x2D; body = body.dropFirst() }
        var base: UInt64 = 10
        if body.count > 2, body.first == 0x30, let p = body.dropFirst().first {
            switch p { case 0x78, 0x58: base = 16; case 0x6F, 0x4F: base = 8; case 0x62, 0x42: base = 2; default: break }
            if base != 10 { body = body.dropFirst(2) }
        }
        guard let v = zigInt(body, base: base, max: .max) else { return nil }
        if negative, v != 0 { return .some(nil) }
        return v > max ? .some(nil) : .some(v)
    }

    /// Zig's parseFloat: sign, digits with `_` between them, `.`, exponent, or inf/infinity/nan,
    /// or a hex float (0x...p...).
    static func float(_ s: [UInt8]) -> Double? {
        var t = s
        if let c = t.first, c == 0x2B || c == 0x2D { t.removeFirst() }
        let lower = String(decoding: t, as: UTF8.self).lowercased()
        if ["inf", "infinity", "nan"].contains(lower) { return Double(String(decoding: s, as: UTF8.self).lowercased()) }
        guard let first = t.first, first != 0x5F, t.last != 0x5F else { return nil }
        let hex = lower.hasPrefix("0x")
        for (i, c) in t.enumerated() where c == 0x5F {
            let digit = { (x: UInt8) in hex ? (0x30...0x39).contains(x) || (0x61...0x66).contains(x | 0x20) : (0x30...0x39).contains(x) }
            guard i > 0, i < t.count - 1, digit(t[i - 1]), digit(t[i + 1]) else { return nil }
        }
        let clean = String(decoding: s.filter { $0 != 0x5F }, as: UTF8.self)
        guard let d = Double(clean), !clean.contains(where: { $0 == " " }) else { return nil }
        return d
    }

    /// parsePackedStruct: a bool for every flag, or `name`/`no-name` parts separated by commas
    /// (starting from the defaults).
    static func features(_ s: [UInt8]) -> ShellIntegration? {
        var f = ShellIntegration()
        if let b = bool(s) { (f.cursor, f.sudo, f.title, f.sshEnv, f.sshTerminfo, f.path) = (b, b, b, b, b, b); return f }
        for part in s.split(separator: 0x2C, omittingEmptySubsequences: false) {
            var name = String(decoding: trim(part, " \t"), as: UTF8.self), on = true
            if name.hasPrefix("no-") { (name, on) = (String(name.dropFirst(3)), false) }
            switch name {
            case "cursor": f.cursor = on
            case "sudo": f.sudo = on
            case "title": f.title = on
            case "ssh-env": f.sshEnv = on
            case "ssh-terminfo": f.sshTerminfo = on
            case "path": f.path = on
            default: return nil
            }
        }
        return f
    }

    static func bool(_ s: [UInt8]) -> Bool? {
        switch String(decoding: s, as: UTF8.self) { case "1", "t", "T", "true": true; case "0", "f", "F", "false": false; default: nil }
    }

    /// Theme.parseCLI: `name` (both sides), or `light:a,dark:b` pairs when there is a `,`, `=` or `:`.
    static func theme(_ s: [UInt8]) -> (light: String, dark: String)? {
        guard s.contains(where: { $0 == 0x2C || $0 == 0x3D || $0 == 0x3A }) else {
            let name = String(decoding: trim(s, " \t"), as: UTF8.self)
            return (name, name)
        }
        var (light, dark): (String?, String?) = (nil, nil)
        for entry in s.split(separator: 0x2C, omittingEmptySubsequences: false) {
            guard let colon = entry.firstIndex(of: 0x3A) else { return nil }
            var value = trim(entry[(colon + 1)...], " \t")
            if value.count >= 2, value.first == 0x22, value.last == 0x22 { value = value.dropFirst().dropLast() }
            let v = String(decoding: value, as: UTF8.self)
            switch String(decoding: trim(entry[..<colon], " \t"), as: UTF8.self) {
            case "light": light = v
            case "dark": dark = v
            default: return nil
            }
        }
        guard let light, let dark else { return nil }
        return (light, dark)
    }
}
