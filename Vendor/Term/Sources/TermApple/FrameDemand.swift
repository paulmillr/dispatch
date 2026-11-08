import Foundation

/// The demand shared by native display-link adapters. Only a changed, shown terminal draws; an idle or hidden link
/// pauses at its next refresh. The adapter applies each returned wake/pause on its own render thread.
///
/// Output alone (a program printing, a spinner, an animation) may be paced below the display (`interval`): it draws at
/// most once an interval, its changes kept for the next. Input (`request(urgent:)`: typing, scrolling, a resize, a
/// selection) draws at the next refresh, and so does output for `inputWindow` after it: the echo of a key, a program's
/// reply to it.
public final class FrameDemand: @unchecked Sendable {
    /// What a refresh does.
    public enum Refresh: Equatable { case draw, wait, pause }
    /// How long after input output still draws at every refresh (an echo, the reply to a key).
    public static let inputWindow: Double = 0.25

    private let lock = NSLock()
    private var changed = true, paused = false, shown = true
    /// Output-only frames at most once this many seconds (0: every refresh); times are the display link's.
    private var interval = 0.0
    private var urgentUntil = -Double.infinity, lastDraw = -Double.infinity

    public init() {}

    /// Records a change. Whether a paused display link must be woken.
    public func request() -> Bool { request(urgent: false, at: 0).wake }

    /// Records a change: input (`urgent`) or output, at `now` (the display link's clock, CACurrentMediaTime).
    /// `wake`: a paused link must be woken; `hurry`: a link paced for output must run at the display's rate again.
    public func request(urgent: Bool, at now: Double) -> (wake: Bool, hurry: Bool) {
        lock.lock()
        defer { lock.unlock() }
        changed = true
        var hurry = false
        if urgent {
            hurry = interval > 0 && now >= urgentUntil
            urgentUntil = now + Self.inputWindow
        }
        return (wake(), hurry)
    }

    /// Showing always requests a frame, including when no output arrived while hidden.
    public func show(_ visible: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        shown = visible
        guard visible else { return false }
        changed = true
        return wake()
    }

    /// Whether this refresh draws, at any pace. A false result pauses the display link.
    public func frame() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let draw = changed && shown
        if draw { changed = false } else { paused = true }
        return draw
    }

    /// What the refresh at `now` does: draws a change, waits (output drawn less than an interval ago keeps its
    /// change for a later refresh) or pauses (nothing changed, or hidden).
    public func frame(at now: Double) -> Refresh {
        lock.lock()
        defer { lock.unlock() }
        guard changed && shown else { paused = true; return .pause }
        // A tenth of an interval early still draws: refreshes come at the display's period, not exactly on it.
        if interval > 0, now >= urgentUntil, now - lastDraw < interval * 0.9 { return .wait }
        (changed, lastDraw) = (false, now)
        return .draw
    }

    /// Whether refreshes at `now` should come at the display's rate (input recently, or no pace): otherwise at the
    /// output's.
    public func fast(at now: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return interval == 0 || now < urgentUntil
    }

    /// Output-only frames at most `perSecond` a second; 0: every refresh.
    public func pace(_ perSecond: Int) {
        lock.lock()
        defer { lock.unlock() }
        interval = perSecond > 0 ? 1 / Double(perSecond) : 0
    }

    /// The output pace, frames a second (0: none).
    public var paced: Int {
        lock.lock()
        defer { lock.unlock() }
        return interval > 0 ? Int((1 / interval).rounded()) : 0
    }

    /// A replacement link starts running even if its predecessor fell silent; its first refresh draws or pauses.
    public func relink() {
        lock.lock()
        defer { lock.unlock() }
        (changed, paused) = (true, false)
    }

    /// A display disappeared while the adapter still believes its link runs (native display recovery checks).
    @_spi(Test) public func stall() {
        lock.lock()
        defer { lock.unlock() }
        paused = false
    }

    private func wake() -> Bool {
        let wake = paused && shown
        if wake { paused = false }
        return wake
    }
}
