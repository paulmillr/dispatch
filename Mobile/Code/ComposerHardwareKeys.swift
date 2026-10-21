import UIKit

/// What a hardware key does in the composer: the Mac composer's rules (`ChatEditorTextView.keyDown`,
/// `ChatComposer`'s editor-mode and interrupt shortcuts, the shortcut sheet in `ChatComposerShortcuts`). A draft is in
/// editor mode (`ChatDraft.multiline`) once it holds a newline or after ⌘E; out of it Return sends, in it Return
/// inserts a newline. Only hardware key events reach these rules (`UIKeyCommand`): the software keyboard's Return
/// keeps inserting a newline, as on the phone.
enum ComposerKeyAction: Equatable {
    /// Sends (or queues, while the agent works) the draft.
    case send
    /// Sends into the running turn (the Mac's ⌥⏎, the phone's long press on send); sends when nothing runs.
    case steer
    /// Inserts a newline as typing would.
    case newline
    /// ⌘E: editor mode on or off.
    case toggleEditor
    /// Esc in editor mode: back to single-line mode, the draft kept.
    case leaveEditor
    /// Esc while the agent works: stops the turn, the draft kept.
    case stop
    /// Esc otherwise: the composer gives up focus (the Mac's composer has nowhere to go; an iPad's focus moves on).
    case resign
    /// Not the composer's: the text system handles it (an input method's open composition, for one).
    case system
}

enum ComposerHardwareKeys {
    enum Key: Equatable { case returnKey, escape, e }

    /// The action for `key` with exactly `modifiers` held. `composing` is an input method's marked text: it owns
    /// Return and Esc (commit, cancel) as on the Mac (`hasMarkedText()`).
    static func action(_ key: Key, modifiers: UIKeyModifierFlags, multiline: Bool, working: Bool,
                       composing: Bool = false) -> ComposerKeyAction {
        guard !composing else { return .system }
        let flags = modifiers.intersection([.command, .control, .alternate, .shift])
        switch key {
        case .returnKey:
            switch flags {
            case []: return multiline ? .newline : .send
            case .shift: return .newline
            case .command, .control: return .send
            case .alternate: return .steer
            default: return .system
            }
        case .escape:
            guard flags.isEmpty else { return .system }
            if multiline { return .leaveEditor }
            return working ? .stop : .resign
        case .e:
            return flags == .command ? .toggleEditor : .system
        }
    }

    /// The key commands the composer answers. Only the ones worth discovering carry a title, so holding ⌘ lists Send,
    /// Send into Turn and Editor Mode and not every Return variant.
    static func commands(action: Selector) -> [UIKeyCommand] {
        func command(_ input: String, _ modifiers: UIKeyModifierFlags, title: String? = nil) -> UIKeyCommand {
            let command = title.map { UIKeyCommand(title: $0, action: action, input: input, modifierFlags: modifiers) }
                ?? UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
            // Return and Esc mean something to the text view (a newline, nothing); the composer's meaning wins.
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        return [
            command("\r", []),
            command("\r", .shift),
            command("\r", .command, title: "Send"),
            command("\r", .control),
            command("\r", .alternate, title: "Send into Running Turn"),
            command(UIKeyCommand.inputEscape, []),
            command("e", .command, title: "Editor Mode"),
        ]
    }

    /// The key of a command `commands` made.
    static func key(_ command: UIKeyCommand) -> Key? {
        switch command.input {
        case "\r": .returnKey
        case UIKeyCommand.inputEscape: .escape
        case "e", "E": .e
        default: nil
        }
    }
}
