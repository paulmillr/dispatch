import AppKit
import IOKit.ps

/// The frame rate continuous chrome motion (the composer's orbit, shimmer and border, the Nautical radar) asks the
/// compositor for. On the adapter it is the screen's own rate (120 Hz on ProMotion); on battery 60; in Low Power Mode
/// 30, whatever the screen offers (macOS may already hold a ProMotion screen at 60 there). Behind another app, visible
/// motion keeps going at no more than 60: it is watched, not worked with. A change posts `changed`, so a running loop
/// restarts at the new rate.
@MainActor
enum MotionRate {
    static let changed = Notification.Name("yachts.dispatch.motion-rate-changed")

    /// `preferredFrameRateRange` for a loop on `window`'s screen now.
    static func range(for window: NSWindow) -> CAFrameRateRange {
        let fps = Float(max(1, min(window.screen?.maximumFramesPerSecond ?? 60, limit)))
        return CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
    }

    /// The policy's ceiling now, before the screen's own.
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
