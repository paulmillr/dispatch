// Key bindings (Ghostty's input/Binding.zig): triggers parsed from Ghostty's syntax and looked up
// for a key event in Ghostty's order; the actions a surface performs by name.
// [decision] single-key bindings only (no leader sequences, key tables, chains or flags: Dispatch's
// config has none); code points fold ASCII case only (Ghostty folds full Unicode: the same for
// Dispatch's c, v, a); copy formats plain, html and mixed (no vt: Dispatch copies mixed).

public struct Bindings {
    /// What a key matches: a physical key, a code point, or any key.
    enum Target: Hashable { case physical(Key), unicode(UInt32), catchAll }
    struct Trigger: Hashable { var mods: UInt16, target: Target }

    var map: [Trigger: BindingAction] = [:]

    /// `trigger=action` lines (Ghostty's keybind syntax); lines that don't parse are skipped.
    public init(_ lines: [String]) {
        for line in lines {
            guard let eq = line.firstIndex(of: "="), let t = Self.trigger(line[..<eq]),
                  let a = BindingAction(Array(line[line.index(after: eq)...].utf8)) else { continue }
            map[t] = a
        }
    }

    /// Binding.Trigger.parse: `+`-separated mods (and aliases), then a key name, one code point,
    /// or catch_all; an empty part is `+` itself.
    static func trigger(_ s: Substring) -> Trigger? {
        let aliases: [String: Mods] = ["shift": .shift, "ctrl": .ctrl, "control": .ctrl, "alt": .alt, "opt": .alt, "option": .alt,
                                       "super": .super, "cmd": .super, "command": .super]
        var (mods, target): (Mods, Target?) = ([], nil)
        for part in s.split(separator: "+", omittingEmptySubsequences: false).map(String.init) {
            if let m = aliases[part] {
                guard !mods.contains(m) else { return nil }
                mods.insert(m)
                continue
            }
            guard target == nil else { return nil }
            if part.isEmpty { target = .unicode(0x2B) }
            else if let i = keyNames.firstIndex(of: part), i > 0 { target = .physical(Key(rawValue: UInt16(i))!) }
            else if part.unicodeScalars.count == 1 { target = .unicode(fold(part.unicodeScalars.first!.value)) }
            else if part == "catch_all" { target = .catchAll }
            else { return nil }
        }
        return target.map { Trigger(mods: mods.rawValue, target: $0) }
    }

    static func fold(_ cp: UInt32) -> UInt32 { (0x41...0x5A).contains(cp) ? cp | 0x20 : cp }

    /// Binding.Set.getEvent: the physical key, the text if it is one code point, the unshifted code
    /// point, any key, then any key without mods.
    func get(_ e: KeyEvent) -> BindingAction? {
        let mods = e.mods.intersection(.binding).rawValue
        let text = scalars(e.utf8) ?? []
        var tries: [Trigger] = [Trigger(mods: mods, target: .physical(e.key))]
        if text.count == 1 { tries.append(Trigger(mods: mods, target: .unicode(Self.fold(text[0])))) }
        if e.unshiftedCodepoint > 0 { tries.append(Trigger(mods: mods, target: .unicode(Self.fold(e.unshiftedCodepoint)))) }
        tries += [Trigger(mods: mods, target: .catchAll), Trigger(mods: 0, target: .catchAll)]
        return tries.lazy.compactMap { map[$0] }.first
    }
}

/// The binding actions a surface performs for Dispatch (Ghostty's Binding.Action.parse syntax).
public enum BindingAction: Equatable {
    public enum CopyFormat: String { case plain, html, mixed }
    case copyToClipboard(CopyFormat), pasteFromClipboard, selectAll, scrollToRow(Int), scrollPageUp, scrollPageDown
    case search([UInt8]), navigateSearch(next: Bool), endSearch, startSearch, searchSelection, clearScreen

    /// `name` or `name:param`; nil: not an action this surface performs, or a bad parameter.
    public init?(_ text: [UInt8]) {
        let s = String(decoding: text, as: UTF8.self)
        let (name, param) = s.firstIndex(of: ":").map { (String(s[..<$0]), Optional(String(s[s.index(after: $0)...]))) } ?? (s, nil)
        switch (name, param) {
        case ("copy_to_clipboard", nil): self = .copyToClipboard(.mixed)
        case ("copy_to_clipboard", let p?): guard let f = CopyFormat(rawValue: p) else { return nil }; self = .copyToClipboard(f)
        case ("paste_from_clipboard", nil): self = .pasteFromClipboard
        case ("select_all", nil): self = .selectAll
        case ("scroll_page_up", nil): self = .scrollPageUp
        case ("scroll_page_down", nil): self = .scrollPageDown
        case ("end_search", nil): self = .endSearch
        case ("start_search", nil): self = .startSearch
        case ("search_selection", nil): self = .searchSelection
        case ("clear_screen", nil): self = .clearScreen
        case ("search", let p?): self = .search(Array(p.utf8))
        case ("scroll_to_row", let p?): guard let n = zigInt(Array(p.utf8), base: 10, max: UInt64(Int.max), signed: true) else { return nil }; self = .scrollToRow(Int(n))
        case ("navigate_search", "next"): self = .navigateSearch(next: true)
        case ("navigate_search", "previous"): self = .navigateSearch(next: false)
        default: return nil
        }
    }
}
