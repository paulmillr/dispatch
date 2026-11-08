import AppKit
import IOKit.ps
import Observation

/// The frame rate continuous chrome motion (chat's working animation, the Nautical radar) asks the compositor for.
/// On the adapter it is the screen's own rate (120 Hz on ProMotion); on battery 60; in Low Power Mode 30, whatever
/// the screen offers (macOS may already hold a ProMotion screen at 60 there). Behind another app, visible motion keeps
/// going at no more than 60: it is watched, not worked with. A loop may ask for less (`glow`, `orbit`, `shimmer`):
/// what a frame moves it by decides what its rate buys. Low Power Mode also stills the loops that only decorate
/// (`decorates`). A change posts `changed`, so a running loop restarts at the new rate, or stops.
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
        range(on: window.screen, upTo: cap)
    }

    /// `preferredFrameRateRange` for a loop on `screen` now, at most `cap` frames a second.
    static func range(on screen: NSScreen?, upTo cap: Int = .max) -> CAFrameRateRange {
        let fps = Float(max(1, min(screen?.maximumFramesPerSecond ?? 60, limit, cap)))
        return CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
    }

    /// Frames a second for a terminal's output alone (a program printing, a spinner, an agent's status line), 0 for
    /// the display's own: on the adapter while Dispatch is in front every frame, otherwise (on battery, behind another
    /// app, in Low Power Mode) 30, since each frame draws the whole grid on the GPU and composites it again. Input and
    /// what answers it within a quarter second still draw at the display's rate (`FrameDemand`). Follows `limit`, so
    /// `changed` covers it.
    static var terminalOutput: Int { limit == .max ? 0 : 30 }

    /// The policy's ceiling now, before the screen's own and a loop's cap.
    static var limit: Int {
        if lowPower { return 30 }
        if !onAdapter || NSApp?.isActive == false { return 60 }
        return Int.max
    }

    /// Whether the Mac draws from an adapter now, watched from the first ask (also this Mac's stats cadence,
    /// StatisticsCadence.viewed).
    static var adapter: Bool {
        observe()
        return onAdapter
    }

    /// Low Power Mode now, watched from the first ask; observable, so a view that reads it follows it.
    static var lowPower: Bool {
        observe()
        return state.lowPower
    }

    /// Whether loops that only decorate run: the label's shimmer, the Thinking row's sweep, the composer's and the reply
    /// halo's lap, the radar's sweep and echoes, a connecting tab's pulse. Low Power Mode stills them where Reduce Motion
    /// does (a steady accent edge, the resting beam, a steady ring), and keeps the motion that says an agent works (the
    /// ◆'s breath and its orbit, at 30 frames a second); one-off transitions stay.
    static var decorates: Bool { !lowPower }

    /// Tests: Low Power Mode as given, nil for the Mac's own.
    static func pin(lowPower: Bool?) {
        observe()
        pinned = lowPower
        update()
    }

    @Observable final class State {
        fileprivate(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    private static let state = State()
    private static var pinned: Bool?

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
        let low = pinned ?? ProcessInfo.processInfo.isLowPowerModeEnabled
        if state.lowPower != low { state.lowPower = low }
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
