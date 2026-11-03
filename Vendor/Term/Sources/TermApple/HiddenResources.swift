// When a hidden terminal gives back the GPU memory it draws with (Ghostty 1.4 releases a hidden surface's GPU
// resources at once): here after a short retention, so switching back and forth between tabs keeps them, and at
// once for every hidden terminal when the system reports memory pressure. The process, the terminal's contents and
// its history are untouched; the next frame makes what it needs again. Main queue only.
import Dispatch
import Foundation

public final class HiddenResources {
    /// When a hidden terminal releases: after `retention` (it is out of sight, e.g. a background tab), or only on
    /// memory pressure (e.g. its window is merely covered: it may be revealed before a new frame is ready).
    public enum Policy: Sendable { case afterRetention, onMemoryPressure }

    /// How long a hidden terminal keeps its GPU memory, in seconds.
    public nonisolated(unsafe) static var retention: TimeInterval = 5

    /// The terminals that may release (weak), and the process's memory pressure source.
    nonisolated(unsafe) private static let all = NSHashTable<HiddenResources>.weakObjects()
    nonisolated(unsafe) private static var pressure: DispatchSourceMemoryPressure?

    private let release: (Policy) -> Void
    /// Hidden with this policy (nil: shown); the pending release (cancelled by showing again); released.
    private var policy: Policy?, pending: DispatchWorkItem?
    public private(set) var released = false
    /// A release waits for the retention (checks).
    @_spi(Test) public var scheduled: Bool { pending != nil }
    /// How it is hidden (nil: shown; checks).
    @_spi(Test) public var hiddenPolicy: Policy? { policy }

    /// `release`: gives the memory back (main queue, at most once per hiding), told how the terminal is hidden.
    public init(release: @escaping (Policy) -> Void) {
        self.release = release
        Self.all.add(self)
        if Self.pressure == nil {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            source.setEventHandler { HiddenResources.releaseHidden() }
            source.resume()
            Self.pressure = source
        }
    }

    deinit { pending?.cancel() }

    /// Hidden: releases after the retention (`afterRetention`) or on memory pressure. Hiding again the same way
    /// changes nothing (hosts report visibility often: the retention runs from the first report).
    public func hide(_ policy: Policy) {
        guard policy != self.policy else { return }
        self.policy = policy
        pending?.cancel()
        pending = nil
        guard policy == .afterRetention, !released else { return }
        let item = DispatchWorkItem { [weak self] in self?.releaseNow() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retention, execute: item)
    }

    /// Shown again: true when the memory was released (the caller draws a frame before the view shows).
    @discardableResult public func show() -> Bool {
        pending?.cancel()
        (pending, policy) = (nil, nil)
        defer { released = false }
        return released
    }

    /// Releases now if hidden.
    public func releaseNow() {
        pending = nil
        guard let policy, !released else { return }
        released = true
        release(policy)
    }

    /// Every hidden terminal releases now (memory pressure; checks).
    public static func releaseHidden() {
        for terminal in all.allObjects { terminal.releaseNow() }
    }
}
