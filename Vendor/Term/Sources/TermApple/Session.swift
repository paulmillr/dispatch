// A terminal session for a host's view, like Ghostty's embedded surface (termio's IO threads + the
// renderer thread): a process on a pty feeds the surface on the pty's parse thread; frames are drawn
// with Metal into IOSurfaces that `layer` shows, on the session's render thread, paced by the
// display (Frames); the main queue only gets the host's work (messages from the program, the
// scrollbar, the cursor blink) and the synchronous frame a resize asks for. The
// surface is used under `lock` from all three (Ghostty's renderer mutex), recursively on the main
// queue (the host's callbacks come back into the surface); what frames read besides the terminal
// (fonts, GPU state, draw options) under `drawLock` (Ghostty's draw mutex), always taken first.
// Hosts call the surface inside `locked` and `pump()` after it.
#if canImport(AppKit)
import AppKit
import CoreVideo
import IOSurface
import Metal
import QuartzCore
import Term

/// This module was compiled optimized (hosts check their build, like Term.optimized).
@_spi(Test) public let optimized = !_isDebugAssertConfiguration()

public final class Session {
    public enum Failure: Error { case noMetalDevice }
    public let surface: Surface
    /// What the host's view shows (see host(in:)).
    public var layer: CALayer { surfaceLayer }
    let surfaceLayer = SurfaceLayer()
    /// Whether the window may treat the terminal as covering what is behind it (no translucent background).
    @_spi(Test) public var layerIsOpaque: Bool { surfaceLayer.isOpaque }
    /// The GPU the frames are drawn on (tests draw into their own textures).
    public var device: MTLDevice { metal.device }
    /// The process ended (its wait status), on the main queue.
    public var onExit: (@MainActor (Int32) -> Void)?
    /// Parsed output is available even when the terminal is hidden or unfocused.
    public var onUpdate: (() -> Void)?
    /// Frames of output alone (a program printing, a spinner) at most this many a second; 0: the display's rate.
    /// Input and what follows it within `FrameDemand.inputWindow` always draw at the next refresh (main queue).
    public var outputFramesPerSecond = 0 {
        didSet { if outputFramesPerSecond != oldValue { frames?.pace(outputFramesPerSecond) } }
    }
    var pty: Pty?
    var cells: CellRenderer
    let metal: MetalRenderer
    var config: Config, scale: Double, look = DrawConfig()
    /// The theme's Display P3 colors for the renderer, rebuilt when the config's change.
    var wide: WideColors?
    /// What changed since the last frame (the renderer rebuilds only that).
    var state = RenderState(), grid = (cols: 0, rows: 0)
    /// The open search's refreshes while output comes, and whether a held-back one has a frame scheduled (under `lock`).
    var snapshotCoordinator = SurfaceSnapshotCoordinator()
    /// A main-queue pump is on its way (under the lock); the scrollbar the last frame saw (drawLock).
    var posted = false, scrollbar: Scrollbar?
    /// Main-queue pumps output posted (under the lock).
    @_spi(Test) public private(set) var wakes = 0
    /// Ghostty's cursor blink (renderer Thread): 600 ms phases while focused; output shows the
    /// cursor again and restarts the phase, at most every 500 ms (`reset`: its time, `restart`:
    /// the main queue restarts the phase).
    var blink = (visible: true, reset: UInt64(0), restart: false), blinkTimer: DispatchSourceTimer?
    /// Ghostty's kitty animation clock (its start) and the wakeup for the next due frame (drawLock).
    let clock = DispatchTime.now().uptimeNanoseconds
    var animation: DispatchSourceTimer?
    let lock = NSRecursiveLock()
    /// Ghostty's renderer State.lockDemand: the parse thread takes `lock` once per batch and would
    /// win every race for it; a frame waiting for it (`demand`) goes first at the next batch
    /// boundary (`handoff` counts the frames that had their turn). Under `turn`.
    let turn = NSCondition()
    var demand = 0, handoff = 0
    let drawLock = NSLock()
    private(set) var frames: Frames?
    /// The view the frames are paced for (host(in:)); relink() makes its display link again.
    private weak var hosted: NSView?
    /// Display links made again (relink).
    @_spi(Test) public private(set) var relinks = 0
    /// Ghostty's swap chain targets: IOSurface textures the layer shows, used in turn (drawLock);
    /// frames drawn, and the newest one shown (under `shownLock`).
    var targets: [(surface: IOSurfaceRef, texture: MTLTexture)?] = [nil, nil, nil], nextTarget = 0, drawn = 0
    let shownLock = NSLock()
    var shown = 0
    /// A hidden session's GPU memory (targets, buffers, atlas textures) is given back after a retention or on memory
    /// pressure (HiddenResources); `released`: it is (drawLock), no frame is drawn until shown again.
    @_spi(Test) public private(set) lazy var hiddenResources = HiddenResources { [weak self] policy in
        // A covered window can be revealed before the app hears it: it keeps showing its last frame meanwhile.
        self?.releaseResources(keepingShownFrame: policy == .onMemoryPressure)
    }
    var released = false

    /// `scale`: the view's backing scale. The size is Ghostty's initial 800x600 pixels until the
    /// host sets it. `blocks`: where its pages come from and go (the process's shared ones: a
    /// closed terminal warms the next). `allowHostMedia`: opt-in file/shared-memory Kitty media
    /// for a process trusted to name resources on this machine. `machine`: what it reads of the machine (OSC 7 accepts
    /// file URLs for its name).
    public init(config: Config, scale: Double, machine: Launch.Machine, blocks: PageBlocks = SharedPageBlocks.shared,
                allowHostMedia: Bool = false) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.noMetalDevice }
        metal = try MetalRenderer(device: device)
        let scale = RenderSize.contentScale(scale)
        (self.config, self.scale) = (config, scale)
        cells = try SurfaceSessionCore.cells(config, scale)
        var options = HandlerOptions()
        (options.hostname, options.version, options.checksumReports) = (Array(machine.host.utf8), ghosttyVersion, config.checksumReports)
        var size = RenderSize(screen: (800, 600), cell: SurfaceSessionCore.cell(cells))
        size.pad(SurfaceSessionCore.padding(config, scale), .off)
        var o = TerminalOptions(cols: size.grid.cols, rows: size.grid.rows)
        (o.blocks, o.kitty, o.maxScrollbackBytes, o.maxScrollbackLines, o.kittyImageStorageLimit) =
            (blocks, allowHostMedia ? .apple : .appleInline, config.scrollbackLimitBytes, config.scrollbackLimitLines, config.imageStorageLimitBytes)
        (o.cursorStyle, o.cursorBlink) = (config.cursorStyle, config.cursorBlink)
        surface = Surface(terminal: Terminal(o), options: options, size: size,
                          now: { DispatchTime.now().uptimeNanoseconds }, entropy: { n in (0..<n).map { _ in UInt8.random(in: .min ... .max) } })
        surface.setContentScale(x: scale, y: scale)
        (surfaceLayer.contentsScale, surfaceLayer.isOpaque) = (scale, true)
        surfaceLayer.onDisplay = { [weak self] in self?.present(sync: true) }
        apply()
    }

    /// Shows the frames in `view` (main queue), like Ghostty's Metal init: a layer-hosting view (the
    /// layer set before wantsLayer), clipped, with frames paced by the display the view is on.
    public func host(in view: NSView) {
        view.layer = surfaceLayer
        view.wantsLayer = true
        view.clipsToBounds = true
        frames?.stop()
        frames = Frames(view) { [weak self] in self?.present(sync: false) }
        if outputFramesPerSecond > 0 { frames?.pace(outputFramesPerSecond) }
        hosted = view
    }

    /// The view's display changed or woke, or it joined a window again (main queue): the frames get a
    /// display link from the view again, then a whole frame. The old link can stay silent after its
    /// display went away, and AppKit invalidates it when the view leaves its window.
    public func relink() {
        guard let hosted, let frames else { return }
        relinks += 1
        frames.relink(hosted)
        refresh()
    }

    /// Tests: the display link falls silent while the frames believe it runs.
    @_spi(Test) public func stallFrames() { frames?.stall() }

    /// Frames drawn so far (synchronous and paced).
    @_spi(Test) public var drawnFrames: Int {
        drawLock.lock()
        defer { drawLock.unlock() }
        return drawn
    }

    public func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// `locked` for changes frames read outside the terminal too (the draw lock first, like a frame).
    func exclusive<T>(_ body: () -> T) -> T {
        drawLock.lock()
        defer { drawLock.unlock() }
        return locked(body)
    }

    /// `locked` for a frame (lockDemand/unlockDemand).
    func demanded<T>(_ body: () -> T) -> T {
        turn.lock(); demand += 1; turn.unlock()
        lock.lock()
        turn.lock(); demand -= 1; turn.unlock()
        defer { lock.unlock(); turn.lock(); handoff += 1; turn.broadcast(); turn.unlock() }
        return body()
    }

    /// Between batches, `lock` not held (yieldToDemand): a waiting frame goes first, for at most 1 ms.
    func yieldToDemand() {
        turn.lock()
        defer { turn.unlock() }
        let (generation, deadline) = (handoff, Date(timeIntervalSinceNow: 0.001))
        while demand > 0, handoff == generation, turn.wait(until: deadline) {}
    }

    /// Starts the process. Reads are parsed on the pty's parse thread; replies go straight back to
    /// the pty; frames follow at the display's pace; the main queue is posted only for the host's
    /// work (the stream's messages, a cursor blink restart while focused).
    public func start(_ launch: Launch) throws {
        pty = try Pty(size: locked { winsize() }, launch: launch, onRead: { [weak self] pty, bytes in
            guard let self else { return }
            let post = self.locked {
                let now = DispatchTime.now().uptimeNanoseconds
                if self.surface.focused, now &- self.blink.reset > 500_000_000 { self.blink = (true, now, true) }
                self.surface.feed(bytes)
                self.surface.drain(reply: { pty.write($0) }, event: { _ in })
                guard !self.posted, self.blink.restart || !self.surface.stream.handler.surface.isEmpty else { return false }
                (self.posted, self.wakes) = (true, self.wakes + 1)
                return true
            }
            self.frames?.request()
            self.onUpdate?()
            if post { DispatchQueue.main.async { [weak self] in self?.pump(urgent: false) } }
            self.yieldToDemand()
        }, onExit: { [weak self] status in self?.onExit?(status) })
        if surface.focused { runBlink() }
        pump()
    }

    /// Ends the process (Ghostty's surface free): no exit callback.
    public func close() {
        blinkTimer?.cancel()
        pty?.close()
    }

    deinit {
        blinkTimer?.cancel()
        animation?.cancel()
        frames?.stop()
    }

    /// The process group in the terminal's foreground (0: none yet).
    public var foregroundPID: pid_t { pty.map { max(0, $0.foregroundPID) } ?? 0 }

    /// The surface's queued work: pty writes, its messages and scrollbar for the host, the pty size,
    /// a frame (callers may have changed the screen). `urgent`: the host's own action (a key, a scroll, a
    /// resize, a selection), drawn at the next refresh; false for the work output brought (FrameDemand).
    public func pump(urgent: Bool = true) {
        let restart = locked {
            defer { blink.restart = false }
            return blink.restart
        }
        if restart, blinkTimer != nil { runBlink() }
        locked {
            posted = false
            SurfaceSessionCore.pump(surface, reply: { pty?.write($0) })
            if surface.terminal.grid != grid {
                grid = surface.terminal.grid
                pty?.resize(winsize())
            }
        }
        frames?.request(urgent: urgent)
    }

    func winsize() -> Darwin.winsize {
        let t = surface.terminal
        let width = t.grid.cols.multipliedReportingOverflow(by: max(surface.size.cell.width, 0))
        let height = t.grid.rows.multipliedReportingOverflow(by: max(surface.size.cell.height, 0))
        return Darwin.winsize(ws_row: UInt16(clamping: t.grid.rows), ws_col: UInt16(clamping: t.grid.cols),
                              ws_xpixel: UInt16(clamping: width.overflow ? Int.max : width.partialValue),
                              ws_ypixel: UInt16(clamping: height.overflow ? Int.max : height.partialValue))
    }

    /// One frame into `target` (tests: their own texture); `completed` when the GPU is done.
    @_spi(Test) @discardableResult
    public func render(into target: MTLTexture, completed: (() -> Void)? = nil) -> MTLCommandBuffer? {
        drawLock.lock()
        defer { drawLock.unlock() }
        return frame(into: target, completed: completed)
    }

    /// A frame the layer shows (Ghostty's drawFrame + Frame.complete): drawn into the next target
    /// at the layer's pixel size (a new target when that changed), shown when the GPU is done;
    /// `sync` (a resize, on the main queue): waits for it and shows it now.
    func present(sync: Bool) {
        drawLock.lock()
        defer { drawLock.unlock() }
        guard !released else { return }
        let (bounds, scale) = (surfaceLayer.bounds, surfaceLayer.contentsScale)
        let dimensions = { (value: CGFloat) -> Int? in
            let pixels = Double(value * scale)
            guard pixels.isFinite, pixels >= 1, pixels <= Double(RenderSize.maxPixelDimension) else { return nil }
            return Int(pixels)
        }
        guard let width = dimensions(bounds.width), let height = dimensions(bounds.height) else { return }
        let i = nextTarget
        nextTarget = (nextTarget + 1) % targets.count
        if targets[i].map({ IOSurfaceGetWidth($0.surface) != width || IOSurfaceGetHeight($0.surface) != height }) ?? true {
            targets[i] = makeTarget(width, height)
        }
        guard let target = targets[i] else { return }
        drawn += 1
        let n = drawn
        if sync {
            // A frame the GPU finishes after the wait is shown when it does (never left undrawn until the next one).
            let finished = DispatchSemaphore(value: 0), state = NSLock()
            var (done, late) = (false, false)
            guard frame(into: target.texture, completed: { [weak self] in
                state.lock(); done = true; let shownLate = late; state.unlock()
                finished.signal()
                if shownLate { DispatchQueue.main.async { self?.show(target.surface, n) } }
            }) != nil else { return }
            if finished.wait(timeout: .now() + .milliseconds(250)) == .success { return show(target.surface, n) }
            state.lock(); late = !done; let finishedMeanwhile = done; state.unlock()
            if finishedMeanwhile { show(target.surface, n) }
        } else {
            _ = frame(into: target.texture, completed: { [weak self] in DispatchQueue.main.async { self?.show(target.surface, n) } })
        }
    }

    /// On the main queue (Ghostty's setSurface: no artifacts against the window's own layout): the
    /// layer's contents become frame `n`, unless a newer frame is shown or the layer's size moved on
    /// since it was drawn (Ghostty's setSurfaceCallback discards those).
    func show(_ surface: IOSurfaceRef, _ n: Int) {
        shownLock.lock()
        defer { shownLock.unlock() }
        let (bounds, scale) = (surfaceLayer.bounds, surfaceLayer.contentsScale)
        let width = Double(bounds.width * scale), height = Double(bounds.height * scale)
        guard width.isFinite, height.isFinite, width >= 0, height >= 0,
              width <= Double(RenderSize.maxPixelDimension), height <= Double(RenderSize.maxPixelDimension),
              n > shown, IOSurfaceGetWidth(surface) == Int(width), IOSurfaceGetHeight(surface) == Int(height) else { return }
        shown = n
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.contents = surface
        CATransaction.commit()
    }

    /// metal/Target.zig: a 32BGRA IOSurface tagged Display P3 (the shaders convert sRGB colors to
    /// it, load_color) and a texture drawing into it.
    func makeTarget(_ width: Int, _ height: Int) -> (surface: IOSurfaceRef, texture: MTLTexture)? {
        guard (1...RenderSize.maxPixelDimension).contains(width), (1...RenderSize.maxPixelDimension).contains(height) else { return nil }
        let properties: [CFString: Any] = [kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4, kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA]
        guard let surface = IOSurfaceCreate(properties as CFDictionary), let p3 = CGColorSpace(name: CGColorSpace.displayP3)?.copyPropertyList() else { return nil }
        IOSurfaceSetValue(surface, kIOSurfaceColorSpace, p3)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: metal.pixelFormat, width: width, height: height, mipmapped: false)
        (d.usage, d.storageMode) = (.renderTarget, metal.device.hasUnifiedMemory ? .shared : .managed)
        return metal.device.makeTexture(descriptor: d, iosurface: surface, plane: 0).map { (surface, $0) }
    }

    /// Only what reads the terminal happens under the lock (Ghostty's renderer: RenderState.update
    /// under the mutex, the cells rebuilt after it): the parse thread goes on while the frame is
    /// shaped and encoded. A changed scrollbar goes to the host through the main queue's pump. (drawLock)
    func frame(into target: MTLTexture, completed: (() -> Void)?) -> MTLCommandBuffer? {
        let (preedit, size, bar, due) = demanded { () -> ([(cp: UInt32, wide: Bool)]?, RenderSize, Scrollbar, UInt64?) in
            // Animations advance before the snapshot (a new frame changes what is drawn).
            let now = DispatchTime.now().uptimeNanoseconds
            let due = surface.terminal.animationTick((now - clock) / 1_000_000)
            let snapshot = snapshotCoordinator.capture(surface, cells: &cells, look: look, blinkVisible: blink.visible, state: &state, now: now)
            scheduleSearchRefresh(snapshot.searchRefreshDelay)
            metal.images.update(surface.terminal, cell: SurfaceSessionCore.cell(cells))
            return (snapshot.preedit, snapshot.size, snapshot.scrollbar, due)
        }
        if let due {
            if animation == nil {
                animation = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
                animation!.setEventHandler { [weak self] in self?.frames?.request() }
                animation!.resume()
            }
            animation!.schedule(deadline: .now() + .milliseconds(Int(due)))
        }
        if bar != scrollbar {
            scrollbar = bar
            DispatchQueue.main.async { [weak self] in self?.pump(urgent: false) }
        }
        let c = cells.contents(preedit: preedit, state: &state)
        state.dirty = .false
        var u = FrameUniforms(size: size, cell: SurfaceSessionCore.cell(cells), cols: c.cols, rows: c.rows, background: c.background, opacity: look.backgroundOpacity, block: c.block)
        u.minContrast = Float(config.minimumContrast)
        if config.displayP3 != wide?.theme { wide = config.displayP3.isEmpty ? nil : WideColors(config.displayP3) }
        return metal.draw(c, u, gray: cells.gray, color: cells.color, into: target, glow: config.glow ? Glow() : nil, wide: wide,
                          completed: completed)
    }

    /// Called under the surface lock; the wakeup clears its claim under the same lock before requesting a frame.
    private func scheduleSearchRefresh(_ delay: UInt64?) {
        guard let delay else { return }
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { [weak self] in
            guard let self else { return }
            self.locked { self.snapshotCoordinator.searchRefreshFired() }
            self.frames?.request()
        }
    }

    // MARK: the host's view

    /// The view's size in pixels.
    public func setSize(width: Int, height: Int) {
        locked { surface.setSize(width: width, height: height) }
        pump()
    }

    /// The view's backing scale: fonts and padding at the new resolution (Ghostty's content scale callback).
    public func setScale(_ scale: Double) {
        let scale = RenderSize.contentScale(scale)
        guard scale != self.scale else { return }
        exclusive {
            self.scale = scale
            surface.setContentScale(x: scale, y: scale)
            surfaceLayer.contentsScale = scale
            rebuild()
        }
        pump()
    }

    /// Focus (the cursor blinks only while focused; focus shows it again).
    public func setFocus(_ focused: Bool) {
        locked {
            surface.focus(focused)
            if focused, blinkTimer == nil { blink.visible = true }
        }
        if !focused { blinkTimer?.cancel(); blinkTimer = nil } else if blinkTimer == nil { runBlink() }
        pump()
    }

    /// Starts (again) the cursor's 600 ms phases.
    func runBlink() {
        blinkTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(600), repeating: .milliseconds(600))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.locked { self.blink.visible.toggle() }
            self.pump(urgent: false)
        }
        timer.resume()
        blinkTimer = timer
    }

    /// Hidden (occluded): no frames, the process keeps running; its GPU memory goes back after a retention or on
    /// memory pressure (`release`). Shown: a whole frame, drawn at once when the memory was released (the layer
    /// shows it before the view appears, never an empty frame).
    public func setVisible(_ visible: Bool, release: HiddenResources.Policy = .afterRetention) {
        exclusive {
            surface.occlusion(visible)
            if visible { state.dirty = .full }
        }
        if visible {
            if hiddenResources.show() {
                drawLock.lock(); released = false; drawLock.unlock()
                present(sync: true)
            }
        } else {
            hiddenResources.hide(release)
        }
        frames?.show(visible)
        pump()
    }

    /// The hidden session's GPU memory back to the system (main queue): the swap chain's IOSurfaces and, unless
    /// `keepingShownFrame`, the layer's reference to the shown one; the renderer's buffers and textures. A frame still
    /// in flight is never shown.
    func releaseResources(keepingShownFrame: Bool = false) {
        drawLock.lock()
        defer { drawLock.unlock() }
        released = true
        (targets, nextTarget) = ([nil, nil, nil], 0)
        metal.releaseResources()
        shownLock.lock()
        shown = drawn
        if !keepingShownFrame {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surfaceLayer.contents = nil
            CATransaction.commit()
        }
        shownLock.unlock()
    }

    /// Bytes of GPU memory the session holds for drawing: its targets and the renderer's (checks).
    @_spi(Test) public var gpuBytes: Int {
        drawLock.lock()
        defer { drawLock.unlock() }
        return targets.reduce(metal.heldBytes) { $0 + ($1.map { IOSurfaceGetAllocSize($0.surface) } ?? 0) }
    }

    /// A frame now (a whole one).
    public func refresh() {
        exclusive { state.dirty = .full }
        pump()
    }

    /// A new config (ghostty_app_update_config): colors, options and bindings at once; fonts and
    /// padding when they changed.
    public func configure(_ config: Config) {
        exclusive {
            let fonts = SurfaceSessionCore.needsRendererRebuild(from: self.config, to: config)
            self.config = config
            if fonts { rebuild() }
            apply()
        }
        pump()
    }

    // MARK: config

    /// The config's colors and options (Termio.changeConfig: palette entries a program set stay).
    func apply() {
        let c = config
        SurfaceSessionCore.apply(c, to: surface, look: &look)
        // A translucent background needs a layer the window composites.
        look.backgroundOpacity = c.backgroundOpacity
        surfaceLayer.isOpaque = c.backgroundOpacity >= 1
        state.dirty = .full
    }

    /// Fonts at the config's size and the current scale, the padding in pixels, a whole frame.
    func rebuild() {
        guard let next = try? SurfaceSessionCore.cells(config, scale) else { return }
        cells = next
        metal.invalidateTextures()
        surface.setCell(SurfaceSessionCore.cell(cells), padding: SurfaceSessionCore.padding(config, scale))
        state = RenderState()
    }
}
#endif
