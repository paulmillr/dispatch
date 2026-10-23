import CoreText
import Foundation
import Metal
import QuartzCore
@preconcurrency import Term
@preconcurrency import TermApple

/// One terminal on the phone: the Term surface fed from a `TerminalFeed`, drawn by TermApple's Metal renderer into
/// a `CAMetalLayer` on the frames' render thread. The Mac's `Session` (Vendor/Term/Sources/TermApple/Session.swift)
/// with the pty replaced by the feed: output is parsed on the feed's task; the emulator's replies go back through
/// the feed as input; the main queue gets the host's work (titles, the scrollbar, the grid for `resize`).
///
/// Locks as on the Mac: `lock` (recursive) guards the surface for the feed task, the render thread and the main
/// queue; `drawLock` guards what frames read besides the terminal (fonts, renderer, config), always taken first.
/// A frame waiting for `lock` goes first at the next output batch boundary (Ghostty's lockDemand).
final class TerminalSession: @unchecked Sendable {
    /// What the surface tells the host, on the main queue.
    enum Event: Sendable {
        case title(String)
        case pwd(String)
        case bell
        case selectionChanged
        case scrollbar(total: Int, offset: Int, visible: Int)
        case background(r: UInt8, g: UInt8, b: UInt8)
        /// A program copied text (OSC 52, kitty clipboard).
        case clipboard(String)
        /// The search (Ghostty's search binding actions): its match count and the selected match's index (newest
        /// first), nil when none; `endSearch` after `end_search`.
        case searchTotal(Int?)
        case searchSelected(Int?)
        case endSearch
    }

    /// Frame times on the render thread: building the frame (snapshot, shaping, encoding) and until the GPU finished.
    struct FrameStats: Sendable {
        var frames = 0
        var build: [Double] = []
        var total: [Double] = []
        var bytesFed = 0
        /// Output batches parsed (fewer than the feed's events when they were coalesced).
        var batches = 0
    }

    let surface: Surface
    let layer = CAMetalLayer()
    private let metal: MetalRenderer
    private var cells: CellRenderer
    private(set) var config: Config
    private(set) var scale: Double
    private var look = DrawConfig()
    /// Settings' "Bold text as bright colors" (`TerminalConfiguration.boldIsBright`), applied to `look`.
    private var boldIsBright = false
    /// What frames draw bold text with: bright colours or the cell's own (tests).
    var drawsBoldBright: Bool { look.bold != nil }
    private var state = RenderState()
    /// When the open search last read the terminal (Ghostty's 24 ms search refresh); a frame request is on its way
    /// for a refresh the interval held back (under `lock`).
    private var searchThrottle = SearchRefreshThrottle()
    private var searchRefreshScheduled = false
    private var lastScrollbar: Scrollbar?
    private let host = TerminalSurfaceHost()

    private let lock = NSRecursiveLock()
    private let drawLock = NSLock()
    private let turn = NSCondition()
    private var demand = 0, handoff = 0
    /// Set once in `init` and never replaced: the parse task requests frames from its own thread, also after `close`.
    private var frames: TerminalFrames?
    /// A main-queue pump is on its way (under `lock`); the grid the host last heard of.
    private var posted = false
    private var grid = (cols: 0, rows: 0)
    /// The cursor's blink phase and when output last showed it (under `lock`).
    private var blink = (visible: true, reset: UInt64(0))
    private let statsLock = NSLock()
    private var stats = FrameStats()

    /// Replies and other bytes for the program (the feed's `send`). Any thread: a reattach replaces it on the main
    /// queue while the parse task may be replying, so it is kept under `lock`.
    var output: (@Sendable (Data) -> Void)? {
        get { locked { sink } }
        set { locked { sink = newValue } }
    }
    private var sink: (@Sendable (Data) -> Void)?
    /// The grid changed (the feed's `resize`). Main queue.
    var onGrid: (@MainActor (TerminalFeedSize) -> Void)?
    /// A batch of output was parsed (the parse task's thread).
    var onParsed: (@Sendable () -> Void)?
    /// The surface's actions. Main queue.
    var onEvent: (@MainActor (Event) -> Void)? {
        get { host.onEvent }
        set { host.onEvent = newValue }
    }

    enum Failure: Error { case noMetalDevice }

    /// `scale`: the screen's scale (pixels per point). The size is 800x600 pixels until the host sets it.
    init(configuration: TerminalConfiguration, scale: Double) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.noMetalDevice }
        metal = try MetalRenderer(device: device)
        config = configuration.config()
        let scale = RenderSize.contentScale(scale)
        self.scale = scale
        cells = try Self.cells(config, scale)
        var size = RenderSize(screen: (800, 600), cell: Self.cell(cells))
        size.pad(Self.padding(config, scale), .off)
        var o = TerminalOptions(cols: size.grid.cols, rows: size.grid.rows)
        (o.blocks, o.kitty, o.maxScrollbackBytes, o.kittyImageStorageLimit) = (SharedPageBlocks.shared, .appleInline, config.scrollbackLimitBytes, 0)
        (o.cursorStyle, o.cursorBlink) = (config.cursorStyle, config.cursorBlink)
        var options = HandlerOptions()
        options.version = ghosttyVersion
        surface = Surface(terminal: Terminal(o), options: options, size: size,
                          now: { DispatchTime.now().uptimeNanoseconds }, entropy: { n in (0..<n).map { _ in UInt8.random(in: .min ... .max) } })
        surface.setContentScale(x: scale, y: scale)
        surface.host = host
        host.surface = surface
        layer.device = device
        layer.pixelFormat = metal.pixelFormat
        layer.contentsScale = scale
        layer.isOpaque = true
        layer.contentsGravity = .topLeft
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.maximumDrawableCount = 3
        boldIsBright = configuration.boldIsBright
        apply()
        frames = TerminalFrames { [weak self] in self?.present() }
    }

    deinit { frames?.stop() }

    /// Stops drawing for good (the view went away). Requests after it reach a stopped run loop and do nothing.
    func close() { frames?.stop() }

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func exclusive<T>(_ body: () -> T) -> T {
        drawLock.lock()
        defer { drawLock.unlock() }
        return locked(body)
    }

    private func demanded<T>(_ body: () -> T) -> T {
        turn.lock(); demand += 1; turn.unlock()
        lock.lock()
        turn.lock(); demand -= 1; turn.unlock()
        defer { lock.unlock(); turn.lock(); handoff += 1; turn.broadcast(); turn.unlock() }
        return body()
    }

    private func yieldToDemand() {
        turn.lock()
        defer { turn.unlock() }
        let (generation, deadline) = (handoff, Date(timeIntervalSinceNow: 0.001))
        while demand > 0, handoff == generation, turn.wait(until: deadline) {}
    }

    /// Program output (the feed's task): parsed now, replies sent back, a frame requested, the host's work posted.
    func feed(_ data: Data) {
        var replies: [UInt8] = []
        let post = locked { () -> Bool in
            let now = DispatchTime.now().uptimeNanoseconds
            if surface.focused, now &- blink.reset > 500_000_000 { blink = (true, now) }
            data.withUnsafeBytes { surface.feed($0.bindMemory(to: UInt8.self)) }
            surface.drain(reply: { replies += $0 }, event: { _ in })
            guard !posted, !surface.stream.handler.surface.isEmpty else { return false }
            posted = true
            return true
        }
        statsLock.withLock { stats.bytesFed += data.count; stats.batches += 1 }
        if !replies.isEmpty { output?(Data(replies)) }
        onParsed?()
        frames?.request()
        if post { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.pump() } } }
        yieldToDemand()
    }

    /// Clears the screen and its history for a new attachment, whose output repaints everything.
    func reset() {
        locked {
            surface.touchClearSelection()
            let bytes: [UInt8] = Array("\u{1B}c\u{1B}[3J".utf8)
            bytes.withUnsafeBufferPointer { surface.feed($0) }
            surface.drain(reply: { _ in }, event: { _ in })
        }
        frames?.request()
    }

    /// The surface's queued work: replies, its messages for the host, the scrollbar, the grid, a frame. Call after
    /// changing the surface on the main queue.
    @MainActor func pump() {
        var replies: [UInt8] = []
        let changedGrid = locked { () -> TerminalFeedSize? in
            posted = false
            for _ in 0..<2 {
                surface.drain(reply: { replies += $0 }, event: { _ in })
                surface.takeMessages(surface.handle)
            }
            surface.reportScrollbar()
            guard surface.terminal.grid != grid else { return nil }
            grid = surface.terminal.grid
            return currentSize
        }
        if !replies.isEmpty { output?(Data(replies)) }
        if let changedGrid { onGrid?(changedGrid) }
        frames?.request()
    }

    /// The grid and its cell in pixels, for `attach` and `resize` (under `lock`).
    var currentSize: TerminalFeedSize {
        locked {
            let g = surface.terminal.grid, cell = surface.size.cell
            return TerminalFeedSize(columns: g.cols, rows: g.rows, cellWidth: cell.width, cellHeight: cell.height)
        }
    }

    /// The terminal's part of a frame, under `lock` (with `drawLock` held): what changed, the search's refresh and
    /// highlights, the rows drawn. Whether a main-queue pump must take the surface's new messages.
    private func snapshot() -> ([(cp: UInt32, wide: Bool)]?, RenderSize, Scrollbar, Bool) {
        state.update(surface.terminal)
        // The search thread's refresh (Ghostty's, every 24 ms while output comes, not every frame): a frame that found
        // the viewport changed lets an open search read it again, at most once per interval; its matches are laid on
        // the rows (the renderer's updateFrame), and new totals go to the host.
        let now = DispatchTime.now().uptimeNanoseconds
        if searchThrottle.frame(at: now, changed: state.dirty != .false) { surface.searchRefresh() }
        if let due = searchThrottle.due, !searchRefreshScheduled {
            // The refresh the interval held back: a frame when it is due, so the last output is searched too.
            searchRefreshScheduled = true
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .nanoseconds(Int(due &- min(due, now)))) { [weak self] in
                guard let self else { return }
                self.locked { self.searchRefreshScheduled = false }
                self.frames?.request()
            }
        }
        if state.highlight(surface.searchHighlights) { surface.searchHighlightsApplied() }
        cells.snapshot(surface.terminal, look, focused: surface.focused, blinkVisible: blink.visible, preedit: surface.preedit,
                       links: surface.drawLinks(), state: &state)
        let post = !posted && !surface.stream.handler.surface.isEmpty
        if post { posted = true }
        return (surface.preedit, surface.size, surface.terminal.scrollbar, post)
    }

    /// A frame into the layer's next drawable (render thread). Only the snapshot of the terminal happens under the
    /// lock; shaping and encoding run after it while output keeps being parsed.
    private func present() {
        drawLock.lock()
        defer { drawLock.unlock() }
        let started = CACurrentMediaTime()
        let size = layer.drawableSize
        guard size.width >= 1, size.height >= 1, let drawable = layer.nextDrawable() else { return }
        let (preedit, renderSize, bar, post) = demanded { snapshot() }
        if post { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.pump() } } }
        if bar != lastScrollbar {
            lastScrollbar = bar
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.pump() } }
        }
        let c = cells.contents(preedit: preedit, state: &state)
        state.dirty = .false
        var u = FrameUniforms(size: renderSize, cell: Self.cell(cells), cols: c.cols, rows: c.rows, background: c.background,
                              opacity: look.backgroundOpacity, block: c.block)
        u.minContrast = Float(config.minimumContrast)
        let built = CACurrentMediaTime()
        let committed = metal.draw(c, u, gray: cells.gray, color: cells.color, into: drawable.texture) { [weak self] in
            drawable.present()
            let done = CACurrentMediaTime()
            self?.statsLock.withLock {
                guard let self else { return }
                self.stats.frames += 1
                if self.stats.build.count < 100_000 {
                    self.stats.build.append((built - started) * 1000)
                    self.stats.total.append((done - started) * 1000)
                }
            }
        }
        if committed == nil { frames?.request() }
    }

    /// Frame timings and bytes fed so far; `reset` starts a new measurement.
    func frameStats(reset: Bool = false) -> FrameStats {
        statsLock.withLock {
            defer { if reset { stats = FrameStats() } }
            return stats
        }
    }

    /// A frame at the next refresh, a whole one.
    func refresh() {
        exclusive { state.dirty = .full }
        frames?.request()
    }

    /// Hidden: no frames (output is still parsed); shown: a whole frame.
    func setVisible(_ visible: Bool) {
        exclusive {
            surface.occlusion(visible)
            if visible { state.dirty = .full }
        }
        frames?.show(visible)
    }

    /// The view's size in points: the drawable and the surface in pixels.
    @MainActor func setSize(width: Double, height: Double) {
        let pixel = { (points: Double) -> Int in
            let value = (points * self.scale).rounded()
            guard value.isFinite, value > 0 else { return 0 }
            return value >= Double(RenderSize.maxPixelDimension) ? RenderSize.maxPixelDimension : Int(value)
        }
        let pixels = (pixel(width), pixel(height))
        layer.drawableSize = CGSize(width: pixels.0, height: pixels.1)
        locked { surface.setSize(width: pixels.0, height: pixels.1) }
        pump()
    }

    /// A grid with no view (a presence the Chat segment keeps): the size in pixels that holds it exactly. `drawn`: a
    /// view shows it at that size (the server's grid, `TerminalPresence.shownGrid`), so the drawable follows.
    @MainActor func setGrid(columns: Int, rows: Int, drawn: Bool = false) {
        let (width, height) = pixels(columns: columns, rows: rows)
        if drawn { layer.drawableSize = CGSize(width: width, height: height) }
        locked { surface.setSize(width: width, height: height) }
        pump()
    }

    /// The pixels a grid takes, padding included.
    @MainActor func pixels(columns: Int, rows: Int) -> (width: Int, height: Int) {
        let (cell, padding) = locked { (surface.size.cell, surface.size.padding) }
        func dimension(_ count: Int, _ unit: Int, _ a: Int, _ b: Int) -> Int {
            let value = Double(max(count, 0)) * Double(max(unit, 0)) + Double(max(a, 0)) + Double(max(b, 0))
            return value >= Double(RenderSize.maxPixelDimension) ? RenderSize.maxPixelDimension : Int(value)
        }
        return (dimension(columns, cell.width, padding.left, padding.right), dimension(rows, cell.height, padding.top, padding.bottom))
    }

    /// The grid a view of this size in points holds, and its cell in pixels (what `resize` asks the server for).
    @MainActor func fitting(width: Double, height: Double) -> TerminalFeedSize {
        let (cell, padding) = locked { (surface.size.cell, surface.size.padding) }
        let pixel = { (points: Double) -> Int in
            let value = (points * self.scale).rounded()
            guard value.isFinite, value > 0 else { return 0 }
            return value >= Double(RenderSize.maxPixelDimension) ? RenderSize.maxPixelDimension : Int(value)
        }
        let pixels = (pixel(width), pixel(height))
        let columns = (pixels.0 - padding.left - padding.right) / max(1, cell.width)
        let rows = (pixels.1 - padding.top - padding.bottom) / max(1, cell.height)
        return TerminalFeedSize(columns: max(1, columns), rows: max(1, rows), cellWidth: cell.width, cellHeight: cell.height)
    }

    /// The screen's scale: fonts and padding at the new resolution.
    @MainActor func setScale(_ scale: Double) {
        let scale = RenderSize.contentScale(scale)
        guard scale != self.scale else { return }
        exclusive {
            self.scale = scale
            surface.setContentScale(x: scale, y: scale)
            layer.contentsScale = scale
            rebuild()
        }
        pump()
    }

    @MainActor func setFocus(_ focused: Bool) {
        locked {
            surface.focus(focused)
            blink.visible = true
        }
        pump()
    }

    /// The cursor's 600 ms blink phase (main queue timer): shown again for 500 ms after output.
    @MainActor func blinkTick() {
        let changed = locked { () -> Bool in
            guard surface.focused else { return false }
            if DispatchTime.now().uptimeNanoseconds &- blink.reset < 500_000_000, blink.visible { return false }
            blink.visible.toggle()
            return true
        }
        if changed { refresh() }
    }

    /// A new configuration: colours and options at once; fonts and padding when they changed.
    @MainActor func configure(_ configuration: TerminalConfiguration) {
        let next = configuration.config()
        exclusive {
            boldIsBright = configuration.boldIsBright
            let fonts = next.fontFamily != config.fontFamily || next.fontSize != config.fontSize || next.paddingX != config.paddingX
                || next.paddingY != config.paddingY
            config = next
            if fonts { rebuild() }
            apply()
        }
        pump()
    }

    /// The config's colours and options (the Mac's Session.apply).
    private func apply() {
        let c = config
        (look.selectionBackground, look.selectionForeground, look.cursorColor, look.cursorText) = (c.selectionBackground, c.selectionForeground, c.cursorColor, c.cursorText)
        // Search matches in the app's amber (the state amber of the working dot), the selected one brighter, both with
        // dark text: the terminal keeps its dark theme in either appearance.
        (look.searchBackground, look.searchForeground) = (.color(Self.searchMatch), .color(RGB(r: 0, g: 0, b: 0)))
        (look.searchSelectedBackground, look.searchSelectedForeground) = (.color(Self.searchSelected), .color(RGB(r: 0, g: 0, b: 0)))
        surface.config.optionAsAlt = OptionAsAlt(rawValue: (c.optionAsAlt ?? .false).rawValue) ?? .true
        surface.config.bindings = Bindings(c.keybinds)
        surface.config.clipboardRead = HandlerOptions.ClipboardAccess(rawValue: c.clipboardRead.rawValue) ?? .ask
        surface.stream.handler.options.clipboardWrite = HandlerOptions.ClipboardAccess(rawValue: c.clipboardWrite.rawValue) ?? .ask
        host.writes = c.clipboardWrite == .allow
        surface.terminal.setKittyGraphicsLimit(c.imageStorageLimitBytes)
        surface.terminal.changeCursorDefaults(style: c.cursorStyle, blink: c.cursorBlink)
        look.bold = boldIsBright ? .bright : nil
        let cursor: RGB? = if case .color(let rgb)? = c.cursorColor { rgb } else { nil }
        surface.terminal.changeDefaults(foreground: c.foreground, background: c.background, cursor: cursor, palette: c.palette)
        state.dirty = .full
    }

    /// Fonts at the config's size and the current scale, the padding in pixels, a whole frame.
    private func rebuild() {
        guard let next = try? Self.cells(config, scale) else { return }
        cells = next
        metal.invalidateTextures()
        surface.setCell(Self.cell(cells), padding: Self.padding(config, scale))
        state = RenderState()
    }

    /// The search highlights: `StateWorking` (#D9B36A) for every match, a brighter amber for the selected one.
    static let searchMatch = RGB(r: 0xD9, g: 0xB3, b: 0x6A)
    static let searchSelected = RGB(r: 0xFF, g: 0xD0, b: 0x66)

    /// A full reset of the terminal's state (RIS, then the history erased): modes, colours, the screen and its
    /// history, the selection. What the program shows next draws on a fresh terminal.
    @MainActor func fullReset() {
        locked {
            surface.touchClearSelection()
            let bytes: [UInt8] = Array("\u{1B}c\u{1B}[3J".utf8)
            bytes.withUnsafeBufferPointer { surface.feed($0) }
        }
        pump()
    }

    /// Search highlights per viewport row as a frame lays them (tests): the columns of each match, and whether it is
    /// the selected one. The frame's terminal part runs as a frame's does; the rows it marks stay marked, so the next
    /// real frame still draws them.
    func searchHighlightRows() -> [[(x: ClosedRange<Int>, selected: Bool)]] {
        drawLock.lock()
        defer { drawLock.unlock() }
        let (highlights, post) = locked { () -> ([[(x: ClosedRange<Int>, selected: Bool)]], Bool) in
            let post = snapshot().3
            return (state.highlights, post)
        }
        if post { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.pump() } } }
        return highlights
    }

    /// The background colour (the view behind the drawable's edges).
    var background: RGB { locked { config.background } }

    static func cells(_ config: Config, _ scale: Double) throws -> CellRenderer {
        let fonts = try FontCollection(families: config.fontFamily, points: config.fontSize, dpi: Int(72 * scale))
        let primary = fonts.face(fonts.faces[0][0].entry)
        return CellRenderer(fonts, metrics: CellMetrics(Face(primary, pixels: CTFontGetSize(primary)).metrics))
    }

    static func cell(_ cells: CellRenderer) -> (width: Int, height: Int) { (Int(cells.metrics.cellWidth), Int(cells.metrics.cellHeight)) }

    /// window-padding-x/-y in pixels (Ghostty's scaledPadding).
    static func padding(_ c: Config, _ scale: Double) -> (top: Int, bottom: Int, right: Int, left: Int) {
        let px = { (points: Int) in RenderSize.pixels(points: points, dpi: Float(72 * scale)) }
        return (px(c.paddingY.0), px(c.paddingY.1), px(c.paddingX.1), px(c.paddingX.0))
    }
}

/// The surface's host: actions become `TerminalSession.Event`s on the main queue. Remote program clipboard reads are
/// denied: the phone has no consent surface for them; a paste is the user's own gesture. Writes reach the host only
/// under `clipboard-write = allow` (plain shells, `TerminalConfiguration.clipboardWrite`) and become `.clipboard`.
private final class TerminalSurfaceHost: SurfaceHost, @unchecked Sendable {
    weak var surface: Surface?
    /// `clipboard-write = allow` (under the session's lock, like every surface callback).
    var writes = false
    var onEvent: (@MainActor (TerminalSession.Event) -> Void)?

    private func post(_ event: TerminalSession.Event) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { onEvent?(event) }
        } else {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onEvent?(event) } }
        }
    }

    func perform(_ action: SurfaceAction) -> Bool {
        let text = { (bytes: [UInt8]) in String(decoding: bytes, as: UTF8.self) }
        switch action {
        case .setTitle(let title): post(.title(text(title)))
        case .pwd(let path): post(.pwd(text(path)))
        case .ringBell: post(.bell)
        case .selectionChanged: post(.selectionChanged)
        case .scrollbar(let s): post(.scrollbar(total: s.total, offset: s.offset, visible: s.len))
        case .colorChange(.background, let c): post(.background(r: c.r, g: c.g, b: c.b))
        case .searchTotal(let total): post(.searchTotal(total))
        case .searchSelected(let index): post(.searchSelected(index))
        case .endSearch: post(.endSearch)
        default: return false
        }
        return true
    }

    func setClipboard(_ location: SurfaceMessage.Clipboard, _ contents: [ClipboardContent], confirm: Bool) {
        // `clipboard-write = deny` keeps Ghostty from reaching this. Keep the host fail-closed too, so a parser or
        // configuration regression cannot silently replace the phone's global pasteboard: only an allowed, unconfirmed
        // write of the standard clipboard's text gets through.
        guard writes, !confirm, location == .standard,
              let text = contents.first(where: { String(decoding: $0.mime, as: UTF8.self).hasPrefix("text/") }) else { return }
        post(.clipboard(String(decoding: text.data, as: UTF8.self)))
    }

    func clipboardRequest(_ location: SurfaceMessage.Clipboard, _ request: ClipboardRequest, mimes: [[UInt8]], list: Bool) -> ClipboardReadResult {
        guard let surface else { return .unsupported }
        // A kitty clipboard write (OSC 5522) is a write like OSC 52's; reads, pastes and listings are denied.
        if case .kittyWrite = request, writes, location == .standard, (try? surface.completeClipboard(request, ClipboardCompletion())) != nil {
            return .started
        }
        surface.denyClipboard(request)
        return .started
    }

    func open(_ kind: SurfaceAction.OpenKind, _ url: [UInt8]) throws { throw CocoaError(.featureUnsupported) }

    func exists(_ path: [UInt8]) -> Bool { false }
}

/// Ghostty's search thread reads the terminal again every 24 ms while output comes; frames come up to 120 times a
/// second, and a refresh costs about half a millisecond under the session's lock. Frames whose viewport changed refresh
/// at most once per interval; a change inside the interval waits (`pending`) for a frame at `due`, so the last output
/// is always searched. Times are nanoseconds on any monotonic clock.
struct SearchRefreshThrottle: Equatable {
    static let interval: UInt64 = 24_000_000
    private(set) var last: UInt64?
    private(set) var pending = false

    /// A frame at `now` (`changed`: its viewport changed since the last frame): whether it refreshes the search.
    mutating func frame(at now: UInt64, changed: Bool) -> Bool {
        guard changed || pending else { return false }
        if let last, now &- last < Self.interval {
            pending = true
            return false
        }
        last = now
        pending = false
        return true
    }

    /// When the held-back refresh may run.
    var due: UInt64? { pending ? last.map { $0 &+ Self.interval } : nil }
}
