import AppKit
import Term
import TermApple

/// The Swift terminal (Vendor/Term): each terminal is a Session (its PTY, IO queue and Metal
/// renderer) behind Dispatch's TerminalView, configured by the same text Ghostty reads.
@MainActor
final class SwiftEngine: TerminalEngine {
    private var config: Config
    private let backends = NSHashTable<SwiftBackend>.weakObjects()

    init(_ text: String, dark: Bool) throws {
        // Like ghostty_init: a Finder-launched app has no LANG; its terminals get the system's.
        Launch.ensureLocale()
        config = try Self.checked(text, dark: dark)
    }

    func configure(_ text: String, dark: Bool) throws {
        config = try Self.checked(text, dark: dark)
        for backend in backends.allObjects { backend.session.configure(config) }
    }

    /// Ghostty's app focus only serves global keybinds, which Dispatch has none of.
    func setActive(_ active: Bool) {}

    func surface(view: TerminalView, renderer: NSView, scale: Double, command: String?, environment: [String], directory: String,
                 allowHostMedia: Bool, history: [UInt8]?, preview: (any TerminalBackend)?) -> (any TerminalBackend)? {
        guard let backend = preview as? SwiftBackend ?? backend(view: view, renderer: renderer, scale: scale, allowHostMedia: allowHostMedia, history: history),
              backend.start(config: config, command: command, environment: environment, directory: directory) else { return nil }
        return backend
    }

    func preview(view: TerminalView, renderer: NSView, scale: Double, allowHostMedia: Bool, history: [UInt8]) -> (any TerminalBackend)? {
        backend(view: view, renderer: renderer, scale: scale, allowHostMedia: allowHostMedia, history: history)
    }

    private func backend(view: TerminalView, renderer: NSView, scale: Double, allowHostMedia: Bool, history: [UInt8]?) -> SwiftBackend? {
        guard let backend = SwiftBackend(config: config, view: view, renderer: renderer, scale: scale, allowHostMedia: allowHostMedia, history: history) else { return nil }
        backends.add(backend)
        return backend
    }

    /// Dispatch's config text as Ghostty reads it: its theme looked up in Ghostty's theme
    /// directories (GHOSTTY_RESOURCES_DIR, set by the runtime), the diagnostics kept.
    static func parse(_ text: String, dark: Bool) -> Config {
        var config = Config()
        config.load(Array(text.utf8))
        let environment = ProcessInfo.processInfo.environment
        config.finalize(dark: dark) {
            Config.theme($0, resources: environment["GHOSTTY_RESOURCES_DIR"].flatMap { $0.isEmpty ? nil : $0 }, environment: environment, diagnostics: &$1)
        }
        return config
    }

    /// Like Ghostty's config: diagnostics fail it ("key: message", Ghostty's without its file:line).
    private static func checked(_ text: String, dark: Bool) throws -> Config {
        let config = parse(text, dark: dark)
        guard config.diagnostics.isEmpty else {
            throw TerminalRuntime.RuntimeError.message(config.diagnostics.map { $0.key.isEmpty ? $0.message : "\($0.key): \($0.message)" }.joined(separator: "\n"))
        }
        return config
    }
}

/// One Session drawing into the renderer view's layer.
@MainActor
final class SwiftBackend: TerminalBackend {
    let session: Session
    private let host: SwiftHost
    private let renderer: NSView
    /// The process started, then ended (Ghostty's child_exited: no quit confirmation after it).
    private var started = false, exited = false
    /// The display the view was last on (setDisplayID).
    private var display: UInt32?

    /// A terminal showing `history` until `start` runs its process.
    init?(config: Config, view: TerminalView, renderer: NSView, scale: Double, allowHostMedia: Bool, history: [UInt8]? = nil) {
        guard let session = try? Session(config: config, scale: scale, allowHostMedia: allowHostMedia) else { return nil }
        (self.session, self.renderer, host) = (session, renderer, SwiftHost(view: view, surface: session.surface))
        // Layer-hosting, like Ghostty's renderer view.
        session.host(in: renderer)
        session.surface.host = host
        session.onExit = { [weak self, weak view] _ in
            self?.exited = true
            view?.handle(.childExited)
        }
        session.onUpdate = { [weak view] in view?.handle(.screen) }
        session.surface.control = { [weak view] event, id in
            switch event {
            case .start: view?.handle(.control(.start, nil, session: id))
            case .data(let bytes): view?.handle(.control(.data, Data(bytes), session: id))
            case .end: view?.handle(.control(.end, nil, session: id))
            }
        }
        // Before the process: its first output follows the history, which reflows with the grid.
        if let history { session.locked { history.withUnsafeBufferPointer { session.surface.feed($0) } } }
    }

    /// Starts the process, once; false: it could not start.
    func start(config: Config, command: String?, environment: [String], directory: String) -> Bool {
        guard !started else { return false }
        started = true
        let process = ProcessInfo.processInfo.environment
        let overrides = stride(from: 0, to: environment.count, by: 2).map { (environment[$0], environment[$0 + 1]) }
        do {
            try session.start(Launch(command: command, directory: directory, overrides: overrides, config: config, environment: process,
                                     resources: process["GHOSTTY_RESOURCES_DIR"].flatMap { $0.isEmpty ? nil : $0 }, id: UInt64.random(in: 1 ... .max)))
        } catch { return false }
        return true
    }

    func plain(_ bytes: Data, session id: Int) {
        call { surface in bytes.withUnsafeBytes { surface.plain($0.bindMemory(to: UInt8.self), session: id) } }
    }

    /// A surface call from the main queue, then the surface's queued work.
    private func call<T>(_ body: (Surface) -> T) -> T {
        defer { session.pump() }
        return session.locked { body(session.surface) }
    }

    var foregroundPID: UInt64 { UInt64(session.foregroundPID) }
    var needsConfirmQuit: Bool { started && !exited && session.locked { session.surface.needsConfirmQuit } }
    var hasSelection: Bool { session.locked { session.surface.hasSelection } }
    var grid: TerminalGrid {
        session.locked {
            let s = session.surface.size, g = session.surface.terminal.grid
            return TerminalGrid(columns: g.cols, rows: g.rows, cellWidth: s.cell.width, cellHeight: s.cell.height, width: s.screen.width, height: s.screen.height)
        }
    }

    func close() { session.close() }
    func setFocus(_ focused: Bool) { session.setFocus(focused) }
    func setOcclusion(_ visible: Bool) { session.setVisible(visible) }
    func setContentScale(_ scale: Double) { session.setScale(scale) }
    func setSize(width: UInt32, height: UInt32) {
        // The hosted layer lives in TerminalView's coordinates: a tmux renderer
        // is anchored at the top, so its origin is not zero.
        session.layer.frame = renderer.frame
        session.setSize(width: Int(width), height: Int(height))
    }
    /// Frames are paced by the view's display link, which AppKit moves with the view, but a link
    /// whose display went away (a monitor disconnected, the displays slept) can stay silent: the
    /// session makes it again on another display, and after the displays woke.
    func setDisplayID(_ display: UInt32) {
        defer { self.display = display }
        if let previous = self.display, previous != display { session.relink() }
    }
    func displaysWoke() { session.relink() }
    func refresh() { session.refresh() }

    func key(_ key: TerminalKey) -> Bool {
        call { $0.key(key.action, keycode: key.keycode, mods: key.mods, consumed: key.consumed, composing: key.composing, unshifted: key.unshifted, text: Array((key.text ?? "").utf8)) }
    }
    func translationMods(_ mods: Mods) -> Mods { session.locked { session.surface.translationMods(mods) } }
    func preedit(_ text: String) { call { $0.setPreedit(Array(text.utf8)) } }
    func imePoint() -> (x: Double, y: Double, width: Double, height: Double) { session.locked { session.surface.imePoint() } }
    func text(_ text: String) { call { $0.text(Array(text.utf8)) } }
    func mouseButton(_ state: Surface.MouseButtonState, _ button: MouseEvent.Button, mods: Mods) -> Bool { call { $0.mouseButton(state, button, mods: mods) } }
    func mousePos(x: Double, y: Double, mods: Mods) { call { $0.mousePos(x: x, y: y, mods: mods) } }
    func mouseScroll(x: Double, y: Double, mods: Int32) { call { $0.scroll(x: x, y: y, mods: UInt8(truncatingIfNeeded: mods)) } }
    func bindingAction(_ action: String) -> Bool { call { $0.bindingAction(Array(action.utf8)) } }

    func readText(_ region: PointTag) -> String { session.locked { String(decoding: session.surface.readText(region), as: UTF8.self) } }
    func markRows() { session.locked { session.surface.markRows() } }
    func readUnmarkedText() -> String { session.locked { String(decoding: session.surface.readUnmarkedText(), as: UTF8.self) } }
    func readHistory() -> String { session.locked { String(decoding: session.surface.readPrimaryText(), as: UTF8.self) } }
    func readSelection() -> String? { session.locked { session.surface.readSelection().map { String(decoding: $0, as: UTF8.self) } } }
    func cursorFaintTail() -> (column: UInt32, row: UInt32, faint: Bool) {
        let t = session.locked { session.surface.cursorFaintTail() }
        return (UInt32(t.x), UInt32(t.y), t.faint)
    }
}

/// The surface's host: Dispatch's policy (and TermTool's ToolHost that the differential tests
/// check against Ghostty): actions become
/// TerminalEvents, the clipboard follows TerminalClipboard. Called on the main queue.
private final class SwiftHost: SurfaceHost {
    weak var view: TerminalView?
    weak var surface: Surface?

    init(view: TerminalView, surface: Surface) { (self.view, self.surface) = (view, surface) }

    func perform(_ action: SurfaceAction) -> Bool {
        let text = { (bytes: [UInt8]) in String(decoding: bytes, as: UTF8.self) }
        let event: TerminalEvent
        switch action {
        case .startSearch(let needle): event = .startSearch(text(needle))
        case .endSearch: event = .endSearch
        case .searchTotal(let n): event = .searchTotal(n)
        case .searchSelected(let n): event = .searchSelected(n)
        case .setTitle(let title): event = .title(text(title))
        case .pwd(let path): event = .pwd(text(path))
        case .scrollbar(let s): event = .scrollbar(TerminalScrollState(total: UInt64(s.total), offset: UInt64(s.offset), visible: UInt64(s.len)))
        case .colorChange(.background, let c): event = .background(r: c.r, g: c.g, b: c.b)
        default: return false
        }
        view?.handle(event)
        return true
    }

    /// The first text/plain content to the pasteboard; a program's write (OSC 52, which
    /// clipboard-write = ask marks for confirming) follows the surface's policy instead.
    func setClipboard(_ location: SurfaceMessage.Clipboard, _ contents: [ClipboardContent], confirm: Bool) {
        guard let content = contents.first(where: { $0.mime == Array("text/plain".utf8) }) else { return }
        let text = String(decoding: content.data, as: UTF8.self)
        if !confirm { TerminalClipboard.write(text) } else if let view { TerminalClipboard.write(text, from: view.id) }
    }

    /// The standard clipboard's text and/or its listing, completed at once (kitty writes read
    /// nothing); a completion that needs confirming is approved for pastes, denied otherwise.
    func clipboardRequest(_ location: SurfaceMessage.Clipboard, _ request: ClipboardRequest, mimes: [[UInt8]], list: Bool) -> ClipboardReadResult {
        let plain = Array("text/plain".utf8), wantsText = mimes.contains(plain)
        let write = if case .kittyWrite = request { true } else { false }
        guard let surface, location == .standard, wantsText || list || write else { return .unsupported }
        var completion = ClipboardCompletion(contents: wantsText ? [ClipboardContent(mime: plain, data: Array(TerminalClipboard.read().utf8))] : [],
                                             available: list ? [plain] : [])
        // A kitty write is a program's write: allowed by policy, it needs no prompt.
        if write, let view { completion.confirmed = MainActor.assumeIsolated { TerminalRuntime.shared.allowsClipboardWrite(from: view.id) } }
        do { try surface.completeClipboard(request, completion) } catch {
            guard case .paste = request else { surface.denyClipboard(request); return .started }
            completion.confirmed = true
            try? surface.completeClipboard(request, completion)
        }
        return .started
    }

    /// Ghostty's fallback opener (os/open.zig on macOS): `open`, `open -t` for text; OSC 8 links
    /// fail closed (the host declined them).
    func open(_ kind: SurfaceAction.OpenKind, _ url: [UInt8]) throws {
        guard kind != .osc8 else { throw CocoaError(.featureUnsupported) }
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = (kind == .text ? ["-t"] : []) + [String(decoding: url, as: UTF8.self)]
        try opener.run()
    }

    func exists(_ path: [UInt8]) -> Bool { FileManager.default.fileExists(atPath: String(decoding: path, as: UTF8.self)) }
}
