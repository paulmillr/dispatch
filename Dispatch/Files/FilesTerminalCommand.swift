import Foundation
import Observation

/// cd Here (F2a, F2d): `cd 'path'` is typed into the tab's own terminal, so it runs on whichever host that shell is on (a
/// remote tab's paths are that host's), then the tab shows its terminal. Nothing is typed unless the shell sits at a
/// prompt.
enum FilesTerminalCommand {
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
            case .unsafePath: "This name has control characters; cd to it from the shell"
            }
        }
    }

    /// `'path'` for any POSIX shell: single quotes keep everything literal, and an embedded quote closes the
    /// string, adds an escaped quote and reopens it.
    static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The line typed to change to `path`, or nil when the path cannot be typed safely.
    static func command(changingTo path: String) -> String? {
        guard !path.isEmpty, !hasControlCharacters(path) else { return nil }
        return "cd " + quote(path)
    }

    /// Whether to type now. `busy`: the terminal is not at a shell prompt (`needsConfirmQuit`) or its input is parked.
    static func refusal(path: String, hasTerminal: Bool, busy: Bool) -> Refusal? {
        if command(changingTo: path) == nil { return .unsafePath }
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
    static func changeDirectory(_ path: String, tab: UUID, files: FilesCoordinator) -> Refusal? {
        guard let command = command(changingTo: path) else {
            FilesTerminalNotices.shared.post(Refusal.unsafePath.message, tab: tab)
            return .unsafePath
        }
        return type(command, tab: tab, files: files)
    }

    /// Types `line`, built by `command`, and a Return into the tab's terminal and shows the terminal, under
    /// `changeDirectory`'s rule.
    /// A shell that marks its prompt (OSC 133, Dispatch's own shell integration) is at it or not. One that never marks
    /// it (in a tmux or herdr pane, on an SSH host) is asked about through the tab's helper, which checks the pane's own
    /// processes; then the line is typed once it answers, into the same terminal only.
    @MainActor
    private static func type(_ line: String, tab: UUID, files: FilesCoordinator) -> Refusal? {
        let view = TerminalRuntime.shared.views[tab]
        let surface = view?.surface
        let parked = view?.inputParked ?? true
        if let view, surface != nil, !parked, surface?.needsConfirmQuit == true, let (helper, node) = helperTerminal(tab) {
            Task { @MainActor in
                let idle = await helper.idle(node)
                guard idle == true, TerminalRuntime.shared.views[tab] === view, !view.inputParked,
                      helperTerminal(tab)?.node == node else {
                    FilesTerminalNotices.shared.post(Refusal.busy.message, tab: tab)
                    return
                }
                write(line, tab: tab, files: files)
            }
            return nil
        }
        let busy = parked || (surface?.needsConfirmQuit ?? true)
        if let refusal = terminalRefusal(hasTerminal: surface != nil, busy: busy) {
            FilesTerminalNotices.shared.post(refusal.message, tab: tab)
            return refusal
        }
        return write(line, tab: tab, files: files)
    }

    /// The tab's terminal as its helper knows it: the helper of its space and the terminal's node.
    @MainActor
    private static func helperTerminal(_ tab: UUID) -> (helper: HelperWorkspace, node: UInt64)? {
        guard let workspace = TerminalRuntime.shared.workspace,
              let space = workspace.spaces.first(where: { $0.tabs.contains { $0.id == tab } }),
              let node = space.tabs.first(where: { $0.id == tab })?.terminal,
              let helper = workspace.helper(space) else { return nil }
        return (helper, node)
    }

    @MainActor @discardableResult
    private static func write(_ line: String, tab: UUID, files: FilesCoordinator) -> Refusal? {
        guard let surface = TerminalRuntime.shared.views[tab]?.surface else { return .noTerminal }
        // `text` pastes: with bracketed paste on, the shell takes the whole line as typed text and nothing runs
        // until the Return key that follows, sent as a key so it arrives after the paste's closing bracket.
        surface.text(line)
        var enter = TerminalKey(action: .press, keycode: 36, mods: [])
        _ = surface.key(enter)
        enter.action = .release
        _ = surface.key(enter)
        FilesTerminalNotices.shared.clear(tab)
        files.switchMode(tab, to: .terminal)
        return nil
    }
}

/// The files header's brief notice when cd Here typed nothing, per tab: in the header, so it shows whichever view and
/// pane are shown. It lives outside the files session so the crumbs' menu and the folder preview report the same way.
@MainActor @Observable final class FilesTerminalNotices {
    static let shared = FilesTerminalNotices()

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
            try? await System.sleep(for: .seconds(4), "files.terminal-notice")
            if self?.notices[tab] == notice { self?.notices[tab] = nil }
        }
    }

    func clear(_ tab: UUID) {
        notices[tab] = nil
    }
}
