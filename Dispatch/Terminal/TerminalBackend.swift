import AppKit
import Term

/// The terminal engine (the Swift terminal, SwiftTerminal.swift), created when the runtime starts.
/// It holds what its terminals share.
@MainActor
protocol TerminalEngine: AnyObject {
    /// Dispatch's config text (`dark`: the scheme a light:/dark: theme follows); throws the
    /// config's diagnostics.
    func configure(_ text: String, dark: Bool) throws
    func setActive(_ active: Bool)
    /// A terminal drawing into `renderer` for `view`; `environment`: key, value, key, value...;
    /// `allowHostMedia`: Kitty file/shared-memory transports may access this Mac; `history`: output
    /// shown before the process starts (a relaunched tab's saved text; engines may drop it);
    /// `preview`: this view's terminal from `preview(...)`, which the process starts in instead.
    /// nil: the process could not start.
    func surface(view: TerminalView, renderer: NSView, scale: Double, command: String?, environment: [String], directory: String,
                 allowHostMedia: Bool, history: [UInt8]?, preview: (any TerminalBackend)?) -> (any TerminalBackend)?
    /// A terminal showing `history` with no process yet (a restored tab before it reconnects), for
    /// `surface(..., preview:)` to start later. nil: the engine cannot show output without a process.
    func preview(view: TerminalView, renderer: NSView, scale: Double, allowHostMedia: Bool, history: [UInt8]) -> (any TerminalBackend)?
}

/// The terminal behind a TerminalView. TerminalView owns input, geometry and presentation; the
/// backend owns the PTY, the terminal state and the renderer. Keys and mouse use Term's vocabulary.
@MainActor
protocol TerminalBackend: AnyObject {
    var foregroundPID: UInt64 { get }
    var needsConfirmQuit: Bool { get }
    var hasSelection: Bool { get }
    /// The grid and its pixel sizes (cols, rows, cell size, the surface's size in pixels).
    var grid: TerminalGrid { get }

    /// Ends the terminal now (its process, IO and frames); nothing may be called after it.
    func close()
    func setFocus(_ focused: Bool)
    func setOcclusion(_ visible: Bool)
    func setContentScale(_ scale: Double)
    func setSize(width: UInt32, height: UInt32)
    /// The display the view is on (its NSScreenNumber): frames follow it when it changes.
    func setDisplayID(_ display: UInt32)
    /// The displays woke: frames attach to the view's display again, even an unchanged one.
    func displaysWoke()
    func refresh()

    func key(_ key: TerminalKey) -> Bool
    func translationMods(_ mods: Mods) -> Mods
    /// Empty: no preedit.
    func preedit(_ text: String)
    /// The cursor cell for the IME window, in points from the top left.
    func imePoint() -> (x: Double, y: Double, width: Double, height: Double)
    func text(_ text: String)
    func mouseButton(_ state: Surface.MouseButtonState, _ button: MouseEvent.Button, mods: Mods) -> Bool
    func mousePos(x: Double, y: Double, mods: Mods)
    /// `mods`: Ghostty's scroll mods (bit 0 precision, bits 1-3 momentum phase).
    func mouseScroll(x: Double, y: Double, mods: Int32)
    func bindingAction(_ action: String) -> Bool

    func readText(_ region: PointTag) -> String
    /// Marks the text shown so far (Surface.markRows): an SSH session starting here never reads it.
    func markRows()
    /// The active screen's text with marked rows blank (Surface.readUnmarkedText).
    func readUnmarkedText() -> String
    /// The shell's own screen (not a full-screen program's) with its scrollback, as plain text.
    func readHistory() -> String
    /// The selection's text; nil: no selection.
    func readSelection() -> String?
    /// The cursor, and whether the text after it on its row is all faint (a shell's suggestion).
    func cursorFaintTail() -> (column: UInt32, row: UInt32, faint: Bool)
    /// tmux control session `session` was refused: leave control mode and read `bytes` as output.
    func plain(_ bytes: Data, session: Int)
}

struct TerminalGrid: Equatable {
    var columns: Int, rows: Int, cellWidth: Int, cellHeight: Int, width: Int, height: Int
}

/// A key event for the terminal (shaped like Ghostty's ghostty_input_key_s).
struct TerminalKey {
    var action: KeyEvent.Action, keycode: UInt32, mods: Mods, consumed: Mods = []
    var composing = false, text: String?, unshifted: UInt32 = 0
}

/// What a terminal tells Dispatch (the embedding actions Dispatch handles).
enum TerminalEvent {
    case screen
    /// `session`: which DCS 1000p session of this terminal (the id Surface.control events carry).
    case control(HelperClient.Control.Event, Data?, session: Int)
    case title(String), tabTitle(String), pwd(String?), childExited
    case scrollbar(TerminalScrollState), background(r: UInt8, g: UInt8, b: UInt8)
    case startSearch(String), endSearch, searchTotal(Int?), searchSelected(Int?)
}

extension TerminalView {
    /// The engine's actions. Called on any thread; handled on the main queue.
    nonisolated func handle(_ event: TerminalEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let runtime = TerminalRuntime.shared
            switch event {
            case .control(let event, let bytes, let session):
                guard runtime.views[self.id] === self else { return }
                // A control session keeps its owner if an SSH observer arrives after its start.
                // Only a fresh session may choose that observer using its remote process facts.
                let owner = runtime.helpers.values.first { $0.controls(self.id, session: session) }
                    ?? runtime.helpers.values.first { $0.observes(self.id) && $0.allowsControl }
                    ?? runtime.helpers.values.first { $0.controls(self.id) }
                    ?? runtime.workspace?.helper(containing: self.id)
                if event != .data {
                    print("Helper control dispatch: tab=\(self.id), session=\(session), event=\(event), owner=\(String(describing: owner?.endpoint))")
                }
                owner?.control(self.id, event: event, bytes: bytes, session: session)
            case .screen:
                guard runtime.views[self.id] === self, let surface = self.surface else { return }
                let cursor = surface.cursorFaintTail()
                func screen(_ terminal: UInt64, _ text: String) -> HelperClient.Screen {
                    .init(terminal: terminal, text: text, cursor: .init(column: cursor.column, row: cursor.row), faint_tail: cursor.faint)
                }
                // The helper running this tab, and the remote helper observing an SSH login in it: each acts
                // on the screen under its own terminal id (a remote send waits for that screen). The observer
                // gets only what its session wrote, never the tab's earlier local text (observedText).
                if let terminal = runtime.workspace?.spaces.flatMap(\.tabs).first(where: { $0.id == self.id })?.terminal {
                    runtime.workspace?.helper(containing: self.id)?.publish(screen(terminal, surface.readText(.active)))
                }
                for helper in runtime.helpers.values {
                    if let terminal = helper.observedTerminal(self.id), let text = helper.observedText(terminal, surface: surface) {
                        helper.publish(screen(terminal, text))
                    }
                }
            case .startSearch(let query):
                guard runtime.views[self.id] === self, let search = runtime.chat.sessions[self.id]?.terminalSearch else { return }
                if !query.isEmpty { search.query = query }
                search.open()
            case .endSearch:
                guard runtime.views[self.id] === self else { return }
                runtime.chat.sessions[self.id]?.terminalSearch.close()
            case .searchTotal(let value), .searchSelected(let value):
                guard runtime.views[self.id] === self, let search = runtime.chat.sessions[self.id]?.terminalSearch, search.visible else { return }
                if case .searchTotal = event { search.total = value } else { search.selected = value }
            case .title(let title), .tabTitle(let title): runtime.workspace?.updateTab(self.id, title: title)
            case .pwd(let path): runtime.workspace?.updateTab(self.id, directory: path)
            case .childExited: self.didExit()
            case .scrollbar(let state): self.updateScrollback(state)
            case .background(let r, let g, let b): self.setBackground(r: r, g: g, b: b)
            }
        }
    }
}

/// Dispatch's clipboard policy: the standard clipboard only, plain text; a paste
/// needing confirmation is approved, other confirmations (OSC 52 reads) denied, and a program's
/// write (OSC 52, kitty clipboard) follows TerminalRuntime.allowsClipboardWrite for its surface.
enum TerminalClipboard {
    static func read() -> String {
        Thread.isMainThread ? MainActor.assumeIsolated { NSPasteboard.general.string(forType: .string) ?? "" }
            : DispatchQueue.main.sync { NSPasteboard.general.string(forType: .string) ?? "" }
    }

    static func write(_ text: String) {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// A program's write: decided on the main queue, where the surface's connection is known.
    static func write(_ text: String, from surface: UUID) {
        DispatchQueue.main.async {
            guard MainActor.assumeIsolated({ TerminalRuntime.shared.allowsClipboardWrite(from: surface) }) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
