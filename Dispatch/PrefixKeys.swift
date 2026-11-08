import AppKit
import Observation

/// A multiplexer's prefix table: ⌃B, then a key. tmux control mode and herdr's input API deliver keys to
/// panes raw, so neither tool's own prefix table runs in Dispatch. Off is what settings before PrefixSpaces
/// saved for native spaces.
enum PrefixStyle: String, Codable, CaseIterable {
    case off, tmux, herdr

    /// The tool's default table; nil when prefix keys are off.
    var table: PrefixTable? {
        switch self {
        case .off: nil
        case .tmux: PrefixTable.tmuxDefaults
        case .herdr: PrefixTable.herdrDefaults
        }
    }
}

/// Which spaces answer ⌃B prefix keys (Settings › Keyboard): tmux and herdr spaces their tool's table, native
/// spaces tmux's.
enum PrefixSpaces: String, Codable, CaseIterable {
    case off, multiplexers, all
    var label: String {
        switch self {
        case .off: "Off"
        case .multiplexers: "tmux & herdr spaces"
        case .all: "All spaces"
        }
    }
}

/// The Dispatch action a prefix binding runs. Each keeps its menu action's safety rules:
/// detaching never terminates server work, and closing a native pane or tab first checks it is idle.
enum PrefixAction: Equatable {
    case newSpace, closeSpace, renameSpace, previousSpace, nextSpace, searchSpaces
    /// herdr's switch_workspace: the Nth space, as the Spaces number keys (⇧⌘1…9 by default).
    case selectSpace(Int)
    case newTab, closeTab, renameTab, previousTab, nextTab
    /// tmux's window index: that window on the server, else tab N in a native space.
    case selectWindow(Int)
    /// herdr's 1…9: the Nth tab, or pane in split layouts, as the Tabs number keys (⌘1…9 by default).
    case selectTab(Int)
    case splitRight, splitDown, closePane, breakPane, nextPane, previousPane
    /// tmux's next-layout and even/tiled layouts: the server's in a tmux space, the presets elsewhere.
    case nextLayout, layout(LayoutPreset)
    case nextAttention, previousAttention
    case detach, toggleSidebar, find, scrollPageUp, paste, shortcuts, settings
    /// A tmux command for the server, run as this control client: a tmux space only.
    case tmux(String)
}

/// A key as tmux and herdr name it: the typed character (Shift applied, as in `%` or `X`) or a
/// named key (Shift as `S-`), plus Option and Control. Command chords are the app's.
struct PrefixKey: Hashable {
    var name: String
    var option = false
    var control = false

    init(_ name: String, option: Bool = false, control: Bool = false) {
        (self.name, self.option, self.control) = (name, option, control)
    }

    private static let named: [UInt16: String] = [
        36: "Enter", 76: "Enter", 48: "Tab", 53: "Escape", 116: "PageUp", 121: "PageDown",
        123: "Left", 124: "Right", 125: "Down", 126: "Up",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    init?(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.contains(.command) else { return nil }
        if let name = Self.named[event.keyCode] {
            self.name = event.keyCode == 48 && flags.contains(.shift) ? "BTab" : (flags.contains(.shift) ? "S-" : "") + name
        } else {
            guard let text = event.charactersIgnoringModifiers, !text.isEmpty else { return nil }
            name = text
        }
        (option, control) = (flags.contains(.option), flags.contains(.control))
    }

    /// tmux's key string (`C-b`, `M-1`, `\"`, `S-Up`, `PPage`); nil for keys Dispatch cannot see.
    init?(tmux text: String) {
        var rest = Substring(text), option = false, control = false, shift = false
        while rest.count > 2, let modifier = ["C-", "M-", "S-"].first(where: { rest.hasPrefix($0) }) {
            switch modifier {
            case "C-": control = true
            case "M-": option = true
            default: shift = true
            }
            rest = rest.dropFirst(2)
        }
        if rest.count == 2, rest.first == "\\" { rest = rest.dropFirst() }
        let names = ["Space": " ", "Tab": "Tab", "BTab": "BTab", "Escape": "Escape", "Enter": "Enter",
                     "PPage": "PageUp", "PageUp": "PageUp", "PgUp": "PageUp",
                     "NPage": "PageDown", "PageDown": "PageDown", "PgDn": "PageDown",
                     "Up": "Up", "Down": "Down", "Left": "Left", "Right": "Right"]
        let name: String
        if let mapped = names[String(rest)] { name = mapped == " " || mapped == "BTab" ? mapped : (shift ? "S-" : "") + mapped }
        else if rest.hasPrefix("F"), let n = Int(rest.dropFirst()), (1...12).contains(n) { name = (shift ? "S-" : "") + rest }
        else if rest.count == 1 { name = shift ? rest.uppercased() : String(rest) }
        else { return nil }
        self.init(name, option: option, control: control)
    }

    /// herdr's binding syntax after any `prefix+`: `ctrl+b`, `shift+x`, `alt+1`, `minus`, `tab`.
    init?(herdr text: String) {
        var parts = text.split(separator: "+").map(String.init)
        guard let last = parts.popLast() else { return nil }
        var option = false, control = false, shift = false
        for modifier in parts {
            switch modifier.lowercased() {
            case "ctrl", "control": control = true
            case "alt", "option", "opt": option = true
            case "shift": shift = true
            default: return nil  // cmd/super chords stay the app's
            }
        }
        let names = ["minus": "-", "comma": ",", "ampersand": "&", "plus": "+", "backtick": "`", "period": ".",
                     "space": " ", "enter": "Enter", "esc": "Escape", "escape": "Escape",
                     "left": "Left", "right": "Right", "up": "Up", "down": "Down",
                     "pageup": "PageUp", "pagedown": "PageDown"]
        let name: String
        if last.lowercased() == "tab" { name = shift ? "BTab" : "Tab" }
        else if let mapped = names[last.lowercased()] { name = shift && mapped.count > 1 ? "S-" + mapped : mapped }
        else if last.lowercased().hasPrefix("f"), let n = Int(last.dropFirst()), (1...12).contains(n) { name = (shift ? "S-" : "") + "F\(n)" }
        else if last.count == 1, let character = last.first {
            // Shifted digits and punctuation depend on the keyboard layout.
            guard !shift || character.isLetter else { return nil }
            name = shift ? last.uppercased() : last
        } else { return nil }
        self.init(name, option: option, control: control)
    }

    static let escape = PrefixKey("Escape")
}

struct PrefixBinding: Equatable {
    var action: PrefixAction
    /// tmux's -r: the key repeats without the prefix within repeat-time.
    var repeats = false
}

/// A prefix key and its bindings, as one tool (or one tmux server) defines them.
struct PrefixTable: Equatable {
    var prefix: PrefixKey
    var bindings: [PrefixKey: PrefixBinding]
    var repeatTime: TimeInterval = 0.5
    /// tmux's prefix2: a second key that arms the same table.
    var prefix2: PrefixKey?
    /// The server's bindings Dispatch cannot run as tmux would (key -> its command): the key completes the
    /// sequence and is refused, never replaced by a different action.
    var rejected: [PrefixKey: String] = [:]

    /// True for the prefix and prefix2.
    func arms(_ key: PrefixKey) -> Bool { key == prefix || key == prefix2 }
}

extension PrefixTable {
    /// Dispatch runs a server command only when its single reply is certain: no command lists,
    /// blocks, prompts or menus, and only these commands, so the control connection stays in step.
    private static let forwardable: Set<String> = [
        "select-pane", "selectp", "last-pane", "lastp", "select-window", "selectw", "last-window", "last",
        "select-layout", "selectl", "next-layout", "nextl", "previous-layout", "prevl", "resize-pane", "resizep",
        "swap-pane", "swapp", "rotate-window", "rotatew", "swap-window", "swapw", "send-prefix",
    ]

    /// A tmux command's words as tmux's parser reads them: blanks split, '…' is literal, "…" and bare text take
    /// backslash escapes. A lone `{` or `}`, and a `;` ending a word, are what mark blocks and command lists.
    static func tmuxWords(_ command: String) -> [String] {
        var words: [String] = [], word = "", started = false
        var rest = Substring(command)
        while let c = rest.popFirst() {
            switch c {
            case " ", "\t":
                if started { words.append(word); word = ""; started = false }
                continue
            case "'":
                while let q = rest.popFirst(), q != "'" { word.append(q) }
            case "\"":
                while let q = rest.popFirst(), q != "\"" { word.append(q == "\\" ? rest.popFirst() ?? q : q) }
            case "\\":
                word.append(rest.popFirst() ?? c)
            default:
                word.append(c)
            }
            started = true
        }
        if started { words.append(word) }
        return words
    }

    /// The action for a tmux binding's command, only where it does what tmux would: Dispatch's own for what it
    /// presents, with no operand it would drop (a window's name, a program, a split's size, a target); the server's
    /// own for pane and layout commands, run as they are. Nil for the rest (tmux's own client UI, command lists,
    /// options Dispatch has no equivalent for): the table refuses that key.
    static func tmuxAction(_ command: String) -> PrefixAction? {
        let words = tmuxWords(command)
        guard let name = words.first else { return nil }
        let arguments = Array(words.dropFirst())
        // Dispatch asks before closing work itself, so tmux's prompt is not needed: only the bare kill, with the
        // prompt's own options before it.
        if name == "confirm-before" || name == "confirm" {
            switch options(arguments, values: ["-p", "-c", "-t"], flags: ["-b", "-y"]) {
            case ["kill-window"]?, ["killw"]?: return .closeTab
            case ["kill-pane"]?, ["killp"]?: return .closePane
            default: return nil
            }
        }
        // A prompt whose template only renames the window or session, or finds a window, with what is typed.
        if name == "command-prompt" {
            guard var template = options(arguments, values: ["-I", "-p", "-T", "-t"], flags: ["-1", "-b", "-F", "-i", "-k", "-l", "-N", "-W"]),
                  template.count == 1 || (template.first == "{" && template.last == "}") else { return nil }
            if template.count == 1 { template = tmuxWords(template[0]) } else { template = Array(template.dropFirst().dropLast()) }
            guard arguments.firstIndex(of: "-T").map({ arguments.indices.contains($0 + 1) && arguments[$0 + 1] == "command" }) ?? true
            else { return nil }
            switch template {
            case ["rename-window", "%%"], ["renamew", "%%"]: return .renameTab
            case ["rename-session", "%%"], ["rename", "%%"]: return .renameSpace
            case ["find-window", "%%"], ["find-window", "-Z", "%%"], ["findw", "%%"], ["findw", "-Z", "%%"]: return .searchSpaces
            default: return nil
            }
        }
        // Command lists and blocks are separate tokens; `#{…}` formats are arguments.
        guard !words.contains(where: { $0 == "{" || $0 == "}" || $0.hasSuffix(";") }) else { return nil }
        // Dispatch's new windows and splits start in the current pane's directory, as -c "#{pane_current_path}" asks.
        let here = ["-c", "#{pane_current_path}"]
        switch name {
        case "new-window", "neww": return arguments.isEmpty || arguments == here ? .newTab : nil
        case "kill-window", "killw": return arguments.isEmpty ? .closeTab : nil
        case "kill-pane", "killp": return arguments.isEmpty ? .closePane : nil
        case "split-window", "splitw":
            var rest = arguments
            if let at = rest.indices.first(where: { rest.indices.contains($0 + 1) && Array(rest[$0...($0 + 1)]) == here }) {
                rest.removeSubrange(at...(at + 1))
            }
            guard rest.allSatisfy({ $0 == "-h" || $0 == "-v" }) else { return nil }
            return rest.last == "-h" ? .splitRight : .splitDown
        case "break-pane", "breakp": return arguments.isEmpty ? .breakPane : nil
        case "detach-client", "detach": return arguments.isEmpty ? .detach : nil
        case "switch-client", "switchc":
            return arguments == ["-n"] ? .nextSpace : arguments == ["-p"] ? .previousSpace : nil
        // Their own presentation options only (zoom, sorting, the starting view): Dispatch's search shows the spaces.
        case "choose-tree", "choose-session", "choose-window":
            return arguments.allSatisfy({ $0.count > 1 && $0.hasPrefix("-") && $0.dropFirst().allSatisfy("GNrswZ".contains) })
                ? .searchSpaces : nil
        case "next-window", "next":
            return arguments.isEmpty ? .nextTab : arguments == ["-a"] ? .nextAttention : nil
        case "previous-window", "prev":
            return arguments.isEmpty ? .previousTab : arguments == ["-a"] ? .previousAttention : nil
        case "copy-mode": return arguments.isEmpty ? .find : arguments == ["-u"] ? .scrollPageUp : nil
        case "paste-buffer", "pasteb": return arguments.isEmpty || arguments == ["-p"] ? .paste : nil
        case "list-keys", "lsk": return arguments.isEmpty || arguments == ["-N"] ? .shortcuts : nil
        case "send-prefix": return arguments.isEmpty || arguments == ["-2"] ? .tmux(command) : nil
        default: break
        }
        if (name == "next-layout" || name == "nextl"), arguments.isEmpty { return .nextLayout }
        if (name == "select-pane" || name == "selectp"), arguments == ["-t", ":.+"] { return .nextPane }
        if (name == "select-window" || name == "selectw"), arguments.count == 2, arguments[0] == "-t",
           arguments[1].hasPrefix(":="), let index = Int(arguments[1].dropFirst(2)) { return .selectWindow(index) }
        if name == "select-layout" || name == "selectl", arguments.count == 1,
           let preset = LayoutPreset(tmuxLayout: arguments[0]) { return .layout(preset) }
        return forwardable.contains(name) ? .tmux(command) : nil
    }

    /// What follows a command's options, when every option before it is one of these (`values` take one word).
    private static func options(_ words: [String], values: Set<String>, flags: Set<String>) -> [String]? {
        var rest = words[...]
        while let word = rest.first, word.hasPrefix("-"), word != "-" {
            rest = rest.dropFirst()
            if word == "--" { break }
            if values.contains(word) { guard rest.popFirst() != nil else { return nil } } else if !flags.contains(word) { return nil }
        }
        return Array(rest)
    }

    /// The server's table as the helper read it (`backends.prefix`): the node's session's prefix, prefix2 and
    /// repeat time, and `list-keys -T prefix`; nil when the prefix is None or a key Dispatch cannot see.
    static func tmux(server: HelperClient.Prefix) -> PrefixTable? {
        tmux(prefix: server.key ?? "None", prefix2: server.prefix2, repeatTime: server.repeatMilliseconds.map(String.init) ?? "",
             bindings: server.bindings.map { ($0.key, $0.command, $0.repeat) })
    }

    /// The prefix table from `show-options -gv prefix`, `show-options -gv repeat-time` and
    /// `list-keys -T prefix`; nil when the prefix is None or unreadable.
    static func tmux(prefix: String, repeatTime: String, keys: [String]) -> PrefixTable? {
        var parsed: [(key: String, command: String, repeats: Bool)] = []
        for line in keys {
            var rest = Substring(line)
            func word() -> Substring? {
                rest = rest.drop { $0 == " " || $0 == "\t" }
                guard !rest.isEmpty else { return nil }
                let word = rest.prefix { $0 != " " && $0 != "\t" }
                rest = rest.dropFirst(word.count)
                return word
            }
            guard word() == "bind-key" else { continue }
            var repeats = false, table: Substring?, key: Substring?
            while key == nil, let next = word() {
                switch next {
                case "-r": repeats = true
                case "-T": table = word()
                default: key = next
                }
            }
            guard table == "prefix", let key else { continue }
            parsed.append((String(key), rest.trimmingCharacters(in: .whitespaces), repeats))
        }
        return tmux(prefix: prefix, prefix2: nil, repeatTime: repeatTime, bindings: parsed)
    }

    private static func tmux(prefix: String, prefix2: String?, repeatTime: String,
                             bindings keys: [(key: String, command: String, repeats: Bool)]) -> PrefixTable? {
        guard let prefix = PrefixKey(tmux: prefix.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        var bindings: [PrefixKey: PrefixBinding] = [:], rejected: [PrefixKey: String] = [:]
        for (key, command, repeats) in keys {
            guard let parsed = PrefixKey(tmux: key), !command.isEmpty else { continue }
            if let action = tmuxAction(command) {
                bindings[parsed] = PrefixBinding(action: action, repeats: repeats)
            } else {
                rejected[parsed] = command
            }
        }
        let milliseconds = Double(repeatTime.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 500
        return PrefixTable(prefix: prefix, bindings: bindings, repeatTime: milliseconds / 1000,
                           prefix2: prefix2.flatMap { PrefixKey(tmux: $0.trimmingCharacters(in: .whitespacesAndNewlines)) },
                           rejected: rejected)
    }

    /// tmux 3.7's default prefix table, for native spaces and for a tmux server not yet read.
    static let tmuxDefaults = tmux(prefix: "C-b", repeatTime: "500", keys: ([
        "Space next-layout", "! break-pane", "\\\" split-window", "\\% split-window -h",
        "& confirm-before -p \"kill-window #W? (y/n)\" kill-window", "( switch-client -p", ") switch-client -n",
        ", command-prompt -I \"#W\" { rename-window \"%%\" }", "\\$ command-prompt -I \"#S\" { rename-session \"%%\" }",
        "\\; last-pane", "? list-keys -N", "E select-layout -E", "[ copy-mode", "] paste-buffer -p", "c new-window",
        "d detach-client", "f command-prompt { find-window -Z \"%%\" }", "l last-window", "n next-window",
        "o select-pane -t :.+", "p previous-window", "s choose-tree -Zs", "w choose-tree -Zw",
        "x confirm-before -p \"kill-pane #P? (y/n)\" kill-pane", "z resize-pane -Z", "\\{ swap-pane -U", "\\} swap-pane -D",
        "PPage copy-mode -u", "-r Up select-pane -U", "-r Down select-pane -D", "-r Left select-pane -L", "-r Right select-pane -R",
        "M-1 select-layout even-horizontal", "M-2 select-layout even-vertical", "M-3 select-layout main-horizontal",
        "M-4 select-layout main-vertical", "M-5 select-layout tiled", "M-n next-window -a", "M-o rotate-window -D",
        "M-p previous-window -a", "-r M-Up resize-pane -U 5", "-r M-Down resize-pane -D 5", "-r M-Left resize-pane -L 5",
        "-r M-Right resize-pane -R 5", "C-o rotate-window", "-r C-Up resize-pane -U", "-r C-Down resize-pane -D",
        "-r C-Left resize-pane -L", "-r C-Right resize-pane -R",
    ] + (0...9).map { "\($0) select-window -t :=\($0)" })
        .map { "bind-key " + ($0.hasPrefix("-r ") ? "-r -T prefix " + $0.dropFirst(3) : "-T prefix " + $0) })!

    /// herdr's action names that map onto Dispatch, by their config.toml [keys] name.
    private static let herdrActions: [String: @Sendable (Int?) -> PrefixAction] = [
        "help": { _ in .shortcuts }, "settings": { _ in .settings }, "detach": { _ in .detach },
        "workspace_picker": { _ in .searchSpaces }, "goto": { _ in .searchSpaces },
        "open_notification_target": { _ in .nextAttention }, "previous_agent": { _ in .previousAttention },
        "next_agent": { _ in .nextAttention }, "new_workspace": { _ in .newSpace }, "rename_workspace": { _ in .renameSpace },
        "close_workspace": { _ in .closeSpace }, "previous_workspace": { _ in .previousSpace }, "next_workspace": { _ in .nextSpace },
        "switch_workspace": { .selectSpace($0 ?? 1) }, "new_tab": { _ in .newTab }, "rename_tab": { _ in .renameTab },
        "previous_tab": { _ in .previousTab }, "next_tab": { _ in .nextTab }, "switch_tab": { .selectTab($0 ?? 1) },
        "close_tab": { _ in .closeTab }, "cycle_pane_next": { _ in .nextPane }, "cycle_pane_previous": { _ in .previousPane },
        "split_vertical": { _ in .splitRight }, "split_horizontal": { _ in .splitDown }, "close_pane": { _ in .closePane },
        "toggle_sidebar": { _ in .toggleSidebar },
    ]

    /// herdr 0.9.3's default [keys] that map onto Dispatch.
    private static let herdrDefaultKeys: [String: String] = [
        "prefix": "ctrl+b", "help": "prefix+?", "settings": "prefix+s", "detach": "prefix+q",
        "open_notification_target": "prefix+o", "workspace_picker": "prefix+w", "goto": "prefix+g",
        "new_workspace": "prefix+shift+n", "rename_workspace": "prefix+shift+w", "close_workspace": "prefix+shift+d",
        "new_tab": "prefix+c", "rename_tab": "prefix+shift+t", "previous_tab": "prefix+p", "next_tab": "prefix+n",
        "switch_tab": "prefix+1..9", "close_tab": "prefix+shift+x", "cycle_pane_next": "prefix+tab",
        "cycle_pane_previous": "prefix+shift+tab", "split_vertical": "prefix+v", "split_horizontal": "prefix+minus",
        "close_pane": "prefix+x", "toggle_sidebar": "prefix+b",
    ]

    static let herdrDefaults = herdr(config: "")!

    /// herdr's config.toml: its [keys] prefix and prefix+ bindings over the defaults. Direct
    /// (non-prefix) shortcuts stay with the terminal. Nil when the prefix is one Dispatch cannot see.
    static func herdr(config: String) -> PrefixTable? {
        var keys = herdrDefaultKeys, section = ""
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line; continue }
            guard section == "[keys]", !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            // The value's first quoted string; a trailing comment may follow.
            let value = line[line.index(after: equals)...]
            guard let open = value.firstIndex(of: "\""), let close = value[value.index(after: open)...].firstIndex(of: "\"") else { continue }
            keys[name] = String(value[value.index(after: open)..<close])
        }
        guard let prefixText = keys["prefix"], let prefix = PrefixKey(herdr: prefixText) else { return nil }
        var bindings: [PrefixKey: PrefixBinding] = [:]
        for (name, binding) in keys where binding.hasPrefix("prefix+") {
            guard let action = herdrActions[name] else { continue }
            let key = String(binding.dropFirst(7))
            if key.hasSuffix("1..9") {
                for digit in 1...9 {
                    if let parsed = PrefixKey(herdr: key.dropLast(4) + String(digit)) { bindings[parsed] = PrefixBinding(action: action(digit)) }
                }
            } else if let parsed = PrefixKey(herdr: key) {
                bindings[parsed] = PrefixBinding(action: action(nil))
            }
        }
        return PrefixTable(prefix: prefix, bindings: bindings)
    }
}

extension LayoutPreset {
    /// tmux's even and tiled layouts, which match a Dispatch preset.
    init?(tmuxLayout: String) {
        switch tmuxLayout {
        case "even-horizontal": self = .columns
        case "even-vertical": self = .rows
        case "tiled": self = .grid
        default: return nil
        }
    }
    var tmuxLayout: String? {
        switch self {
        case .columns: "even-horizontal"
        case .rows: "even-vertical"
        case .grid: "tiled"
        case .single, .twoAbove, .six, .eight: nil
        }
    }
}

/// The prefix state of the focused terminal: the prefix arms it, the next key runs a binding. The
/// prefix twice sends it literally; Escape or an unbound key cancels, as in tmux; a Command chord
/// cancels and stays the app's. A repeatable binding's key repeats without the prefix within the
/// table's repeat time. A consumed key's repeats and release are swallowed too.
@MainActor @Observable
final class PrefixKeys {
    /// The terminal whose next key completes a prefix sequence.
    private(set) var armed: UUID?
    /// The table a terminal answers; nil when its prefix keys are off.
    @ObservationIgnored var table: (UUID) -> PrefixTable? = { _ in nil }
    @ObservationIgnored var perform: (PrefixAction, UUID) -> Void = { _, _ in }
    /// A server binding Dispatch cannot run (`PrefixTable.rejected`): its command, for the refusal.
    @ObservationIgnored var reject: (String, UUID) -> Void = { _, _ in }
    /// A sequence ended (a binding ran or was refused, Escape, an unbound key, the prefix sent literally).
    @ObservationIgnored var finished: (UUID) -> Void = { _ in }
    @ObservationIgnored private var swallowed: Set<UInt16> = []
    @ObservationIgnored private var repeating: (surface: UUID, until: TimeInterval)?

    /// True when the key was the prefix's: the terminal must not send it.
    func handle(_ event: NSEvent, surface: UUID) -> Bool {
        guard event.type == .keyDown else { return false }
        // Holding the prefix or a binding's key repeats it; a repeat never completes a sequence.
        // A fresh press forgets a consumed release that went to another view (a rename dialog).
        if event.isARepeat { if swallowed.contains(event.keyCode) { return true } } else { swallowed.remove(event.keyCode) }
        let key = PrefixKey(event)
        if let repeating, repeating.surface == surface, event.timestamp <= repeating.until, let key,
           let table = table(surface), !table.arms(key), let binding = table.bindings[key], binding.repeats {
            perform(binding.action, surface)
            self.repeating = (surface, event.timestamp + table.repeatTime)
            return swallow(event)
        }
        repeating = nil
        guard armed == surface else {
            armed = nil
            guard let key, let table = table(surface), table.arms(key) else { return false }
            armed = surface
            return swallow(event)
        }
        armed = nil
        defer { finished(surface) }
        guard let key, let table = table(surface), !table.arms(key) else { return false }
        if key != .escape, let binding = table.bindings[key] {
            perform(binding.action, surface)
            if binding.repeats { repeating = (surface, event.timestamp + table.repeatTime) }
        } else if key != .escape, let command = table.rejected[key] {
            reject(command, surface)
        }
        return swallow(event)
    }

    /// True when the key is the surface's prefix or completes its armed sequence, so a text view
    /// passes it to `handle` before AppKit reads it as a text command.
    func claims(_ event: NSEvent, surface: UUID) -> Bool {
        armed == surface || PrefixKey(event).map { table(surface)?.arms($0) } == true
    }

    /// True for the release of a key whose press `handle` consumed.
    func swallowsKeyUp(_ event: NSEvent) -> Bool { swallowed.remove(event.keyCode) != nil }

    func cancel() { armed = nil; repeating = nil }

    private func swallow(_ event: NSEvent) -> Bool {
        swallowed.insert(event.keyCode)
        return true
    }
}
