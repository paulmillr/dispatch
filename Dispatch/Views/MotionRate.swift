import AppKit
import IOKit.ps

/// The frame rate continuous chrome motion (chat's working animation, the Nautical radar) asks the compositor for.
/// On the adapter it is the screen's own rate (120 Hz on ProMotion); on battery 60; in Low Power Mode 30, whatever
/// the screen offers (macOS may already hold a ProMotion screen at 60 there). Behind another app, visible motion keeps
/// going at no more than 60: it is watched, not worked with. A loop may ask for less (`glow`, `orbit`, `shimmer`):
/// what a frame moves it by decides what its rate buys. A change posts `changed`, so a running loop restarts at the
/// new rate.
@MainActor
enum MotionRate {
    static let changed = Notification.Name("yachts.dispatch.motion-rate-changed")

    /// The working animation's slow loops, by what one frame moves them. The ◆'s and the label's breathing (1.6 s,
    /// opacity and ±8% scale) changes about 3% a frame at 30 Hz: no rate above shows a difference.
    static let glow = 30
    /// The orbiting dot (8 pt radius, 1.4 s a turn) moves 36 pt/s: about a Retina pixel a frame at 60 Hz, two at 30,
    /// where a small sharp dot ticks; at 120 it moves under a pixel a frame, which shows nothing more.
    static let orbit = 60
    /// The label's ink shimmer, a soft 35 pt band crossing the label in 2.4 s: 1–2 pixels a frame at 60 Hz.
    static let shimmer = 60
    // The composer's border and the Thinking row's sweep cross hundreds of points a second, so they take every frame
    // the policy allows.

    /// `preferredFrameRateRange` for a loop on `window`'s screen now, at most `cap` frames a second.
    static func range(for window: NSWindow, upTo cap: Int = .max) -> CAFrameRateRange {
        let fps = Float(max(1, min(window.screen?.maximumFramesPerSecond ?? 60, limit, cap)))
        return CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
    }

    /// The policy's ceiling now, before the screen's own and a loop's cap.
    static var limit: Int {
        observe()
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return 30 }
        if !onAdapter || NSApp?.isActive == false { return 60 }
        return Int.max
    }

    private static var observing = false
    private static var source: CFRunLoopSource?
    private(set) static var onAdapter = true

    /// Starts watching the power source, Low Power Mode and activation once.
    private static func observe() {
        guard !observing else { return }
        observing = true
        onAdapter = Self.poweredByAdapter()
        // IOKit calls back on the main run loop (the source is added to it below); the context is unused.
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { MotionRate.update() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = source
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { update() }
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { update() }
            }
        }
    }

    private static var published = 0

    private static func update() {
        onAdapter = poweredByAdapter()
        let now = limit
        guard now != published else { return }
        published = now
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Whether the Mac draws from an adapter now (a desktop, or a notebook plugged in); a Mac without battery
    /// information counts as on the adapter.
    private static func poweredByAdapter() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return true }
        return type != kIOPSBatteryPowerValue
    }
}
