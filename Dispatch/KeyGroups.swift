import AppKit
import Observation

/// The modifiers that, with the digit keys, choose a space (1…9), a tab or split pane (1…9) and a
/// layout (1…4). Settings › Keys records them; they are saved by name. A group with none is unbound: it has no
/// shortcut at all, and its digits stay typing.
struct KeyGroups: Codable, Equatable {
    var spaces: NSEvent.ModifierFlags = [.shift, .command]
    var tabs: NSEvent.ModifierFlags = .command
    var splits: NSEvent.ModifierFlags = .control

    /// The modifiers a group can use, in the order macOS writes them.
    static let names: [(flag: NSEvent.ModifierFlags, symbol: String, name: String)] = [
        (.control, "⌃", "control"), (.option, "⌥", "option"), (.shift, "⇧", "shift"), (.command, "⌘", "command"),
    ]
    static let modifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        names.filter { flags.contains($0.flag) }.map(\.symbol).joined()
    }

    /// A group's modifier symbols, as "⌃⌘".
    func symbols(_ group: KeyPath<KeyGroups, NSEvent.ModifierFlags>) -> String { Self.symbols(self[keyPath: group]) }

    /// A group's key for `keys` (as "1…9" or "3"), or nil while the group is unbound.
    func shortcut(_ group: KeyPath<KeyGroups, NSEvent.ModifierFlags>, _ keys: String) -> String? {
        self[keyPath: group].isEmpty ? nil : symbols(group) + keys
    }

    /// Previous / next pane: ⌥⌘[ / ⌥⌘], whatever the groups.
    static let paneStep: NSEvent.ModifierFlags = [.option, .command]

    /// [ and ] step through spaces and tabs with the modifiers their digits use (⇧⌘ and ⌘ by default), plus ⌘ so a
    /// group without it never types into a shell (⌃[ is Escape). An unbound group has none, and so does one whose
    /// chord is already taken, by pane stepping or by spaces.
    var steps: (spaces: NSEvent.ModifierFlags?, tabs: NSEvent.ModifierFlags?) {
        func step(_ group: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags? { group.isEmpty ? nil : group.union(.command) }
        let spaces = step(self.spaces).flatMap { $0 == Self.paneStep ? nil : $0 }
        let tabs = step(self.tabs).flatMap { $0 == Self.paneStep || $0 == spaces ? nil : $0 }
        return (spaces, tabs)
    }

    /// Why these groups cannot be used, or nil.
    var problem: String? {
        for (name, flags) in [("Spaces", spaces), ("Tabs", tabs), ("Splits", splits)]
        where !flags.isEmpty && flags.intersection([.control, .option, .command]).isEmpty {
            return "\(name) need ⌃, ⌥ or ⌘: digits with only ⇧ are typing."
        }
        // Unbound groups may share their lack of modifiers.
        let bound = [spaces, tabs, splits].filter { !$0.isEmpty }
        guard Set(bound.map(\.rawValue)).count == bound.count else {
            return "Spaces, tabs and splits each need their own modifiers."
        }
        return nil
    }

    init() {}

    private enum CodingKeys: String, CodingKey { case spaces, tabs, splits }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        func flags(_ key: CodingKeys) throws -> NSEvent.ModifierFlags? {
            try fields.decodeIfPresent([String].self, forKey: key).map { saved in
                Self.names.filter { saved.contains($0.name) }.reduce(into: []) { $0.insert($1.flag) }
            }
        }
        var decoded = KeyGroups()
        decoded.spaces = try flags(.spaces) ?? decoded.spaces
        decoded.tabs = try flags(.tabs) ?? decoded.tabs
        decoded.splits = try flags(.splits) ?? decoded.splits
        // A hand-edited file that breaks the rules keeps the defaults rather than the other settings.
        self = decoded.problem == nil ? decoded : KeyGroups()
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        func names(_ flags: NSEvent.ModifierFlags) -> [String] { Self.names.filter { flags.contains($0.flag) }.map(\.name) }
        try fields.encode(names(spaces), forKey: .spaces)
        try fields.encode(names(tabs), forKey: .tabs)
        try fields.encode(names(splits), forKey: .splits)
    }
}

/// The groups in effect, for the key handling and every shortcut label; TerminalRuntime applies them.
@MainActor @Observable
final class KeyGroupsStore {
    static let shared = KeyGroupsStore()
    var current = KeyGroups()
}
