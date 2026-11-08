// A session's frames, paced by the display its view is on (Ghostty's renderer thread + CVDisplayLink):
// the view's display link calls the session's own render thread at each refresh. A refresh draws
// only after a change (`request`, any thread); one with nothing to draw pauses the link until the
// next change. Output alone may be paced below the display (`pace`): the link then asks for that
// rate, and goes back to the display's own for input (FrameDemand). No frame runs on the main
// queue, except the synchronous one a resize asks for.
#if canImport(AppKit)
import AppKit
import QuartzCore

final class Frames: NSObject {
    let draw: () -> Void
    /// The render thread's run loop and the display link (used on the render thread only).
    var loop: CFRunLoop?, link: CADisplayLink?
    private let demand = FrameDemand()

    /// On the main queue (the view's display link is made there).
    init(_ view: NSView, draw: @escaping () -> Void) {
        self.draw = draw
        super.init()
        let link = view.displayLink(target: self, selector: #selector(refresh(_:)))
        let started = DispatchSemaphore(value: 0)
        // The thread holds the Frames until its run loop stops: stop() never waits for it.
        let thread = Thread { [self] in
            // Only stop() ends the run loop. AppKit invalidates a view's display links when the view
            // leaves its window; with the link as its only source the loop would end at its next
            // wakeup, and every later perform (request, relink) would wait on it forever.
            RunLoop.current.add(NSMachPort(), forMode: .default)
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

    /// The link's current rate: the display's (true) or the output pace (false); render thread only.
    private var fast = true

    /// Something changed: output, or input (`urgent`). The next refresh draws it, or a later one for output
    /// within its pace (the render thread is woken only from a pause, or to run at the display's rate again).
    func request(urgent: Bool = false) {
        let (wake, hurry) = demand.request(urgent: urgent, at: CACurrentMediaTime())
        if wake || hurry {
            perform { [self] in
                link?.isPaused = false
                if let link { rate(link, at: CACurrentMediaTime()) }
            }
        }
    }

    /// Output-only frames at most `perSecond` a second (0: every refresh), from any thread.
    func pace(_ perSecond: Int) {
        demand.pace(perSecond)
        perform { [self] in if let link { rate(link, at: CACurrentMediaTime()) } }
    }

    /// The pace the link asks the display for: its own rate after input, the output's otherwise.
    private func rate(_ link: CADisplayLink, at now: CFTimeInterval) {
        let fast = demand.fast(at: now)
        guard fast != self.fast else { return }
        self.fast = fast
        let paced = Float(demand.paced)
        link.preferredFrameRateRange = fast ? .default : CAFrameRateRange(minimum: paced, maximum: paced, preferred: paced)
    }

    /// Hidden: no frames (the link pauses at its next refresh); shown: a frame at the next refresh.
    func show(_ visible: Bool) {
        if demand.show(visible) { perform { self.link?.isPaused = false } }
    }

    /// The view's display changed or woke, or the view joined a window again (main queue: the link
    /// is made there): a new link from the view replaces the old one on the render thread. A link
    /// whose display went away (a monitor disconnected, the displays slept) can stay silent while
    /// `paused` says it runs, and one whose view left its window is invalidated; then no request
    /// wakes it. The new link runs: its first refresh draws, or pauses it while hidden.
    func relink(_ view: NSView) {
        let next = view.displayLink(target: self, selector: #selector(refresh(_:)))
        perform { [self] in
            next.add(to: .current, forMode: .default)
            link?.invalidate()
            link = next
            demand.relink()
            fast = true
            rate(next, at: CACurrentMediaTime())
        }
    }

    /// Tests: the link falls silent while `paused` says it runs (what a display going away can do).
    func stall() {
        perform { [self] in
            demand.stall()
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
        switch demand.frame(at: link.timestamp) {
        case .draw: draw()
        case .wait: break
        case .pause: link.isPaused = true
        }
        rate(link, at: link.timestamp)
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
