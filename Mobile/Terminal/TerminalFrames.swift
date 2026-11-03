import Foundation
import QuartzCore
@preconcurrency import TermApple

/// A session's frames, paced by the display (Frames.swift on the Mac, with `CADisplayLink` in place of
/// `NSView.displayLink`): the link runs on the session's own render thread and draws only after a change
/// (`request`, any thread); a refresh with nothing to draw pauses the link until the next change. Nothing is drawn
/// on the main queue.
final class TerminalFrames: NSObject, @unchecked Sendable {
    private let draw: @Sendable () -> Void
    /// The render thread's run loop and the link (used on the render thread only).
    private var loop: CFRunLoop?
    private var link: CADisplayLink?
    private let demand = FrameDemand()

    init(draw: @escaping @Sendable () -> Void) {
        self.draw = draw
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(refresh(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        let started = DispatchSemaphore(value: 0)
        let box = LinkBox(link)
        // The thread holds the frames until its run loop stops: stop() never waits for it.
        let thread = Thread { [self] in
            // A port keeps the run loop alive while the link is paused or replaced.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            box.link.add(to: .current, forMode: .default)
            (self.loop, self.link) = (CFRunLoopGetCurrent(), box.link)
            started.signal()
            CFRunLoopRun()
        }
        thread.name = "Terminal frames"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
    }

    private final class LinkBox: @unchecked Sendable {
        let link: CADisplayLink
        init(_ link: CADisplayLink) { self.link = link }
    }

    private func perform(_ body: @escaping () -> Void) {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, body)
        CFRunLoopWakeUp(loop)
    }

    /// Something changed: the next refresh draws it (the render thread is woken only from a pause).
    func request() {
        if demand.request() { perform { self.link?.isPaused = false } }
    }

    /// Hidden: no frames (the link pauses at its next refresh); shown: a frame at the next refresh.
    func show(_ visible: Bool) {
        if demand.show(visible) { perform { self.link?.isPaused = false } }
    }

    /// Ends the pacing and the render thread, without waiting.
    func stop() {
        perform { [self] in
            link?.invalidate()
            link = nil
            CFRunLoopStop(loop)
        }
    }

    @objc private func refresh(_ link: CADisplayLink) {
        if demand.frame() { draw() } else { link.isPaused = true }
    }
}
