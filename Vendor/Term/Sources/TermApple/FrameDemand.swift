import Foundation

/// The demand shared by native display-link adapters. Only a changed, shown terminal draws; an idle or hidden link
/// pauses at its next refresh. The adapter applies each returned wake/pause on its own render thread.
public final class FrameDemand: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = true, paused = false, shown = true

    public init() {}

    /// Records a change. Whether a paused display link must be woken.
    public func request() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        changed = true
        return wake()
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

    /// Whether this refresh draws. A false result pauses the display link.
    public func frame() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let draw = changed && shown
        if draw { changed = false } else { paused = true }
        return draw
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
