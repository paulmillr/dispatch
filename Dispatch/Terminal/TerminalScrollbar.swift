import AppKit

/// Confirmed server history and one coalesced drag; native pane lookup belongs to the helper.
@MainActor
final class TerminalHistory {
    private let seek: (UInt64) async throws -> Void
    private let changed: (TerminalScrollState) -> Void
    private var state = TerminalScrollState()
    private var active = false
    private var pending: UInt64?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(seek: @escaping (UInt64) async throws -> Void, changed: @escaping (TerminalScrollState) -> Void) {
        self.seek = seek; self.changed = changed
    }

    func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        if !value {
            generation = UUID()
            task?.cancel(); task = nil; pending = nil
            changed(state)
        }
    }

    func update(_ value: TerminalScrollState) {
        state = value
        if task == nil { changed(state) }
    }

    func scroll(to row: UInt64) {
        guard active, state.canScroll else { return }
        pending = state.maximum - min(row, state.maximum)
        guard task == nil else { return }
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { task = nil; changed(state) } }
            for _ in 0... {
                guard active, generation == token, !Task.isCancelled, let offset = pending else { return }
                pending = nil
                do { try await seek(offset) } catch {
                    if generation == token { pending = nil }
                    return
                }
            }
        }
    }
}

/// AppKit owns knob dragging, page clicks, and accessibility. A transparent track
/// overlays the terminal's right padding without changing its cell grid.
@MainActor
final class TerminalScrollbar: NSScroller {
    var changed: ((UInt64) -> Void)?
    private(set) var state = TerminalScrollState()
    private var dragging = false
    private var thumbColor = NSColor.white

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 100))
        scrollerStyle = .legacy
        target = self
        action = #selector(scrolled)
        isContinuous = true
        isHidden = true
        setAccessibilityLabel("Terminal scrollback")
        setAccessibilityIdentifier("terminal-scrollback")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    func setBackground(r: UInt8, g: UInt8, b: UInt8) {
        let luminance = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
        thumbColor = luminance < 128 ? .white : .black
        needsDisplay = true
    }

    func update(_ state: TerminalScrollState) {
        self.state = state
        isHidden = !state.canScroll
        isEnabled = state.canScroll
        knobProportion = CGFloat(state.proportion)
        if !dragging { doubleValue = state.fraction }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard state.canScroll else { return }
        thumbColor.withAlphaComponent(dragging ? 0.65 : 0.4).setFill()
        let knob = rect(for: .knob).insetBy(dx: 4, dy: 1)
        NSBezierPath(roundedRect: knob, xRadius: 3, yRadius: 3).fill()
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        needsDisplay = true
        defer { dragging = false; update(state) }
        super.mouseDown(with: event)
    }

    // A wheel over the thumb still belongs to the terminal/backend.
    override func scrollWheel(with event: NSEvent) { superview?.scrollWheel(with: event) }

    @objc private func scrolled() {
        guard state.canScroll else { return }
        var row = state.row(at: doubleValue)
        switch hitPart {
        case .decrementLine: row = state.offset > 0 ? state.offset - 1 : 0
        case .incrementLine: row = state.offset + min(1, state.maximum - state.offset)
        case .decrementPage: row = state.offset - min(state.offset, max(1, state.visible - 1))
        case .incrementPage: row = state.offset + min(state.maximum - state.offset, max(1, state.visible - 1))
        default: break
        }
        guard row != state.offset else { return }
        state = TerminalScrollState(total: state.total, offset: row, visible: state.visible)
        doubleValue = state.fraction
        changed?(row)
    }
}
