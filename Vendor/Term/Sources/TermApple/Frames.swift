// A session's frames, paced by the display its view is on (Ghostty's renderer thread + CVDisplayLink):
// the view's display link calls the session's own render thread at each refresh. A refresh draws
// only after a change (`request`, any thread); one with nothing to draw pauses the link until the
// next change. No frame runs on the main queue, except the synchronous one a resize asks for.
#if canImport(AppKit)
import AppKit
import QuartzCore

final class Frames: NSObject {
    let draw: () -> Void
    /// The render thread's run loop and the display link (used on the render thread only).
    var loop: CFRunLoop?, link: CADisplayLink?
    /// Under `lock`: a change waits for a frame; the link is paused; the session is shown.
    let lock = NSLock()
    var changed = true, paused = false, shown = true

    /// On the main queue (the view's display link is made there).
    init(_ view: NSView, draw: @escaping () -> Void) {
        self.draw = draw
        super.init()
        let link = view.displayLink(target: self, selector: #selector(refresh(_:)))
        let started = DispatchSemaphore(value: 0)
        // The thread holds the Frames until its run loop stops: stop() never waits for it.
        let thread = Thread { [self] in
            link.add(to: .current, forMode: .default)
            (self.loop, self.link) = (CFRunLoopGetCurrent(), link)
            started.signal()
            CFRunLoopRun()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
    }

    /// Runs `body` on the render thread.
    func perform(_ body: @escaping () -> Void) {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, body)
        CFRunLoopWakeUp(loop)
    }

    /// Something changed: the next refresh draws it (the render thread is woken only from a pause).
    func request() {
        lock.lock()
        changed = true
        let wake = paused && shown
        if wake { paused = false }
        lock.unlock()
        if wake { perform { self.link?.isPaused = false } }
    }

    /// Hidden: no frames (the link pauses at its next refresh); shown: a frame at the next refresh.
    func show(_ visible: Bool) {
        lock.lock(); shown = visible; lock.unlock()
        if visible { request() }
    }

    /// The view's display changed or woke (main queue: the link is made there): a new link from the
    /// view replaces the old one on the render thread. A link whose display went away (a monitor
    /// disconnected, the displays slept) can stay silent while `paused` says it runs, and then no
    /// request wakes it. The new link runs: its first refresh draws, or pauses it while hidden.
    func relink(_ view: NSView) {
        let next = view.displayLink(target: self, selector: #selector(refresh(_:)))
        perform { [self] in
            next.add(to: .current, forMode: .default)
            link?.invalidate()
            link = next
            lock.lock(); (changed, paused) = (true, false); lock.unlock()
        }
    }

    /// Tests: the link falls silent while `paused` says it runs (what a display going away can do).
    func stall() {
        perform { [self] in
            lock.lock(); paused = false; lock.unlock()
            link?.isPaused = true
        }
    }

    /// Ends the pacing and the render thread, without waiting (callable from the render thread too).
    func stop() {
        perform { [self] in
            link?.invalidate()
            CFRunLoopStop(loop)
        }
    }

    @objc func refresh(_ link: CADisplayLink) {
        lock.lock()
        let now = changed && shown
        if now { changed = false } else { paused = true }
        lock.unlock()
        if now { draw() } else { link.isPaused = true }
    }
}

/// The session's layer (Ghostty's IOSurfaceLayer): frames arrive as IOSurface contents, never
/// stretched or animated; a size change asks for a frame right away (`display`, synchronous).
final class SurfaceLayer: CALayer {
    var onDisplay: (() -> Void)?

    override init() {
        super.init()
        (contentsGravity, needsDisplayOnBoundsChange) = (.topLeft, true)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func display() { onDisplay?() }
    override func action(forKey event: String) -> CAAction? { NSNull() }
}
#endif
