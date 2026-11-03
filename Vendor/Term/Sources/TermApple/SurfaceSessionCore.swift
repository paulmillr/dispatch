import CoreText
import Term

/// The engine work shared by native PTY and remote-feed sessions. Callers retain their surface, transport and
/// renderer lifetimes; surface access stays under their recursive lock, with the draw lock taken first whenever
/// fonts or render state change. None of these operations dispatches work or calls a transport outside that lock.
public enum SurfaceSessionCore {
    /// A different shaping option needs new caches just as a different font does. Keep this decision beside the
    /// renderer construction so both native sessions apply every configured font feature.
    public static func needsRendererRebuild(from old: Config, to next: Config) -> Bool {
        next.fontFamily != old.fontFamily || next.fontSize != old.fontSize || next.paddingX != old.paddingX
            || next.paddingY != old.paddingY || next.adjustCellHeight != old.adjustCellHeight
            || next.fontFeatures != old.fontFeatures
    }

    public static func cells(_ config: Config, _ scale: Double) throws -> CellRenderer {
        let fonts = try FontCollection(families: config.fontFamily, points: config.fontSize, dpi: Int(72 * scale))
        let primary = fonts.face(fonts.faces[0][0].entry)
        return CellRenderer(fonts, metrics: CellMetrics(Face(primary, pixels: CTFontGetSize(primary)).metrics, cellHeight: config.adjustCellHeight),
                            features: config.fontFeatures.map { ($0.tag, $0.value) })
    }

    public static func cell(_ cells: CellRenderer) -> (width: Int, height: Int) {
        (Int(cells.metrics.cellWidth), Int(cells.metrics.cellHeight))
    }

    /// window-padding-x/-y in pixels (Ghostty's scaledPadding).
    public static func padding(_ config: Config, _ scale: Double) -> (top: Int, bottom: Int, right: Int, left: Int) {
        let px = { (points: Int) in RenderSize.pixels(points: points, dpi: Float(72 * scale)) }
        return (px(config.paddingY.0), px(config.paddingY.1), px(config.paddingX.1), px(config.paddingX.0))
    }

    /// Colours, bindings and program options. Host clipboard consent, layer opacity, bold colours and search colours
    /// remain the native session's policy. Palette entries the program set survive a configuration change.
    public static func apply(_ config: Config, to surface: Surface, look: inout DrawConfig) {
        (look.selectionBackground, look.selectionForeground, look.cursorColor, look.cursorText) =
            (config.selectionBackground, config.selectionForeground, config.cursorColor, config.cursorText)
        surface.config.optionAsAlt = OptionAsAlt(rawValue: (config.optionAsAlt ?? .false).rawValue)!
        surface.config.bindings = Bindings(config.keybinds)
        surface.config.clipboardRead = HandlerOptions.ClipboardAccess(rawValue: config.clipboardRead.rawValue)!
        surface.stream.handler.options.clipboardWrite = HandlerOptions.ClipboardAccess(rawValue: config.clipboardWrite.rawValue)!
        surface.terminal.setKittyGraphicsLimit(config.imageStorageLimitBytes)
        surface.terminal.changeCursorDefaults(style: config.cursorStyle, blink: config.cursorBlink)
        let cursor: RGB? = if case .color(let rgb)? = config.cursorColor { rgb } else { nil }
        surface.terminal.changeDefaults(foreground: config.foreground, background: config.background, cursor: cursor, palette: config.palette)
    }

    /// Handling a host message can queue replies again, so the pump drains twice. The caller clears its posted flag
    /// first and reports grid changes afterwards, preserving recursive host callbacks and transport ordering.
    public static func pump(_ surface: Surface, reply: ([UInt8]) -> Void) {
        for _ in 0..<2 {
            surface.drain(reply: reply, event: { _ in })
            surface.takeMessages(surface.handle)
        }
        surface.reportScrollbar()
    }
}

/// The terminal part of a frame, before shaping runs without the surface lock. Both native renderers refresh search
/// on the same clock and apply its highlights before copying rows. Scheduling remains with the host: one wakeup is
/// outstanding at a time, and it calls `searchRefreshFired` under the surface lock before requesting another frame.
public struct SurfaceSnapshotCoordinator {
    private var searchThrottle = SearchRefreshThrottle()
    private var searchRefreshScheduled = false

    public init() {}

    public struct Snapshot {
        public let preedit: [(cp: UInt32, wide: Bool)]?
        public let size: RenderSize
        public let scrollbar: Scrollbar
        /// Nanoseconds from the supplied frame time, or nil when no wakeup needs scheduling.
        public let searchRefreshDelay: UInt64?
    }

    public mutating func capture(_ surface: Surface, cells: inout CellRenderer, look: DrawConfig, blinkVisible: Bool,
                                 state: inout RenderState, now: UInt64) -> Snapshot {
        state.update(surface.terminal)
        if searchThrottle.frame(at: now, changed: state.dirty != .false) { surface.searchRefresh() }
        var delay: UInt64?
        if let due = searchThrottle.due, !searchRefreshScheduled {
            searchRefreshScheduled = true
            delay = due &- min(due, now)
        }
        if state.highlight(surface.searchHighlights) { surface.searchHighlightsApplied() }
        cells.snapshot(surface.terminal, look, focused: surface.focused, blinkVisible: blinkVisible, preedit: surface.preedit,
                       links: surface.drawLinks(), state: &state)
        return Snapshot(preedit: surface.preedit, size: surface.size, scrollbar: surface.terminal.scrollbar, searchRefreshDelay: delay)
    }

    public mutating func searchRefreshFired() { searchRefreshScheduled = false }
}
