import Foundation
import Observation

/// Open in editor and cd here (F2a, F2d, F5a "$EDITOR in this tab"): the command is typed into the tab's own
/// terminal, so it runs on whichever host that shell is on (a remote tab's paths are that host's), then the tab
/// shows its terminal. Nothing is typed unless the shell sits at a prompt.
enum FilesEditor {
    enum Action: Equatable, Sendable {
        case edit
        case changeDirectory
    }

    /// Why nothing was typed.
    enum Refusal: Equatable, Sendable {
        /// A program runs in the terminal (or its input is held during a reconnect): typing would go to it.
        case busy
        /// The tab has no running terminal.
        case noTerminal
        /// The path holds control characters, which a terminal paste strips or a line editor acts on.
        case unsafePath

        var message: String {
            switch self {
            case .busy: "The terminal is busy"
            case .noTerminal: "The terminal isn’t running"
            case .unsafePath: "This name has control characters; open it from the shell"
            }
        }
    }

    /// `'path'` for any POSIX shell: single quotes keep everything literal, and an embedded quote closes the
    /// string, adds an escaped quote and reopens it.
    static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The line typed for `action`, or nil when the path cannot be typed safely. `$EDITOR` is expanded by the
    /// shell, with vi when it is unset, as most tools do.
    static func command(for path: String, action: Action) -> String? {
        guard !path.isEmpty, !hasControlCharacters(path) else { return nil }
        switch action {
        case .edit: return "${EDITOR:-vi} " + quote(path)
        case .changeDirectory: return "cd " + quote(path)
        }
    }

    /// Whether to type now. `busy`: the terminal is not at a shell prompt (`needsConfirmQuit`) or its input is parked.
    static func refusal(path: String, action: Action, hasTerminal: Bool, busy: Bool) -> Refusal? {
        if command(for: path, action: action) == nil { return .unsafePath }
        return terminalRefusal(hasTerminal: hasTerminal, busy: busy)
    }

    private static func terminalRefusal(hasTerminal: Bool, busy: Bool) -> Refusal? {
        if !hasTerminal { return .noTerminal }
        if busy { return .busy }
        return nil
    }

    static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
    }

    /// Types the command and a Return into the tab's terminal and shows the terminal, or posts why it did not.
    @MainActor @discardableResult
    static func run(_ action: Action, path: String, tab: UUID, files: FilesCoordinator) -> Refusal? {
        guard let command = command(for: path, action: action) else {
            FilesEditorNotices.shared.post(Refusal.unsafePath.message, tab: tab)
            return .unsafePath
        }
        return type(command, tab: tab, files: files)
    }

    /// Types `line`, built by `command`, and a Return into the tab's terminal and shows the terminal, under `run`'s rule.
    @MainActor
    private static func type(_ line: String, tab: UUID, files: FilesCoordinator) -> Refusal? {
        let view = TerminalRuntime.shared.views[tab]
        let surface = view?.surface
        let busy = (view?.inputParked ?? true) || (surface?.needsConfirmQuit ?? true)
        if let refusal = terminalRefusal(hasTerminal: surface != nil, busy: busy) {
            FilesEditorNotices.shared.post(refusal.message, tab: tab)
            return refusal
        }
        guard let surface else { return .noTerminal }
        // `text` pastes: with bracketed paste on, the shell takes the whole line as typed text and nothing runs
        // until the Return key that follows, sent as a key so it arrives after the paste's closing bracket.
        surface.text(line)
        var enter = TerminalKey(action: .press, keycode: 36, mods: [])
        _ = surface.key(enter)
        enter.action = .release
        _ = surface.key(enter)
        FilesEditorNotices.shared.clear(tab)
        files.switchMode(tab, to: .terminal)
        return nil
    }
}

/// The preview header's brief notice when Open in editor or cd here typed nothing, per tab. It lives outside the
/// files session so the list's ⌘O and the preview's button report the same way.
@MainActor @Observable final class FilesEditorNotices {
    static let shared = FilesEditorNotices()

    struct Notice: Equatable {
        let id: UUID
        let text: String
    }

    private(set) var notices: [UUID: Notice] = [:]

    func notice(for tab: UUID) -> String? { notices[tab]?.text }

    func post(_ text: String, tab: UUID) {
        let notice = Notice(id: System.uuid(), text: text)
        notices[tab] = notice
        Task { @MainActor [weak self] in
            try? await System.sleep(for: .seconds(4), "files.editor-notice")
            if self?.notices[tab] == notice { self?.notices[tab] = nil }
        }
    }

    func clear(_ tab: UUID) {
        notices[tab] = nil
    }
}
