import Foundation
import QuartzCore
@preconcurrency import TermApple

/// A session's frames, paced by the display (Frames.swift on the Mac, with `CADisplayLink` in place of
/// `NSView.displayLink`): the link runs on the session's own render thread and draws only after a change
/// (`request`, any thread); a refresh with nothing to draw pauses the link until the next change. Output alone is
/// paced below the display (`pace`): the link then asks for that rate, and goes back to the display's own for input
/// (`FrameDemand`). Nothing is drawn on the main queue.
final class TerminalFrames: NSObject, @unchecked Sendable {
    /// How long after input output still draws at every refresh. The Mac's quarter second is a local program's: here
    /// the echo of a key crosses the link to the host and back, often in more than that.
    static let inputWindow = 1.0
    /// What the link asks the display for after input: its own rate.
    private static let display = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)

    private let draw: @Sendable () -> Void
    /// The render thread's run loop and the link (used on the render thread only).
    private var loop: CFRunLoop?
    private var link: CADisplayLink?
    private let demand = FrameDemand(inputWindow: TerminalFrames.inputWindow)
    /// The link's current rate: the display's (true) or the output pace (false); render thread only.
    private var fast = true

    /// `outputFramesPerSecond`: frames of output alone at most this many a second (0: every refresh).
    init(outputFramesPerSecond: Int = 0, draw: @escaping @Sendable () -> Void) {
        self.draw = draw
        super.init()
        demand.pace(outputFramesPerSecond)
        let link = CADisplayLink(target: self, selector: #selector(refresh(_:)))
        link.preferredFrameRateRange = Self.display
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

    /// Something changed: output, or input (`urgent`). The next refresh draws it, or a later one for output within
    /// its pace (the render thread is woken only from a pause, or to run at the display's rate again).
    func request(urgent: Bool = false) {
        let (wake, hurry) = demand.request(urgent: urgent, at: CACurrentMediaTime())
        guard wake || hurry else { return }
        perform { [self] in
            link?.isPaused = false
            if let link { rate(link, at: CACurrentMediaTime()) }
        }
    }

    /// Output-only frames at most `perSecond` a second (0: every refresh), from any thread.
    func pace(_ perSecond: Int) {
        demand.pace(perSecond)
        perform { [self] in if let link { rate(link, at: CACurrentMediaTime()) } }
    }

    /// The output pace, frames a second (0: none).
    var paced: Int { demand.paced }

    /// The pace the link asks the display for: its own rate after input, the output's otherwise.
    private func rate(_ link: CADisplayLink, at now: CFTimeInterval) {
        let fast = demand.fast(at: now)
        guard fast != self.fast else { return }
        self.fast = fast
        let paced = Float(demand.paced)
        link.preferredFrameRateRange = fast ? Self.display : CAFrameRateRange(minimum: paced, maximum: paced, preferred: paced)
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
        switch demand.frame(at: link.timestamp) {
        case .draw: draw()
        case .wait: break
        case .pause: link.isPaused = true
        }
        rate(link, at: link.timestamp)
    }
}
