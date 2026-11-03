import SwiftUI
import UIKit

/// The frame rate the thread's looping motion (the thinking row, the reconnect banner's dots) asks the compositor for:
/// the Mac's `MotionRate` (Dispatch/Views/MotionRate.swift) for the phone. The screen's own rate (120 Hz on ProMotion,
/// `CADisableMinimumFrameDurationOnPhone`), 30 in Low Power Mode; in the background nothing runs at all
/// (`CompositorView`). A loop asks for less (`glow`, `orbit`, `sweep`): what a frame moves it by decides what its rate
/// buys. A change posts `changed`, so a running loop restarts at the new rate.
@MainActor
enum MotionRate {
    static let changed = Notification.Name("yachts.dispatch.mobile.motion-rate-changed")

    /// The slow loops, by what one frame moves them. The ◆'s breathing (1.6 s, opacity and ±8% scale) changes about 3% a
    /// frame at 30 Hz, the waiting dots' 2 pt lift a fifth of a point: no rate above shows a difference.
    static let glow = 30
    /// The orbiting dot (8 pt radius, 1.4 s a turn) moves 36 pt/s: about a Retina pixel a frame at 60 Hz, two at 30,
    /// where a small sharp dot ticks; at 120 it moves under a pixel a frame, which shows nothing more.
    static let orbit = 60
    /// The hairline's glint and the light on "thinking" (`ChatThinkingSweep`) cross the row at up to about 400 pt/s, a
    /// soft band 30% of the row wide: at 60 Hz a few points a frame inside a band a hundred wide.
    static let sweep = 60

    /// `preferredFrameRateRange` for a loop on `screen` now, at most `cap` frames a second.
    static func range(for screen: UIScreen?, upTo cap: Int = .max) -> CAFrameRateRange {
        let fps = Float(max(1, min(screen?.maximumFramesPerSecond ?? 60, limit, cap)))
        return CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
    }

    /// The policy's ceiling now, before the screen's own and a loop's cap.
    static var limit: Int {
        observe()
        return lowPower ? 30 : .max
    }

    private static var observing = false
    private static var lowPower = false

    /// Starts watching Low Power Mode once.
    private static func observe() {
        guard !observing else { return }
        observing = true
        lowPower = System.lowPowerMode
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { update() }
        }
    }

    private static func update() {
        let now = System.lowPowerMode
        guard now != lowPower else { return }
        lowPower = now
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// Continuous motion in the compositor, as the Mac's `CompositorView` (Dispatch/Views/ChatComposerMotion.swift): a
/// `TimelineView(.animation)` re-renders SwiftUI every frame (the thinking row cost about 12% of a core in the app and
/// as much in the render server at 60 Hz); here SwiftUI draws the still artwork once and Core Animation moves its
/// layers, at `MotionRate`'s rate. Loops run only while `moving` (the view is on screen in its scroll view and no sheet
/// covers it, `coversLoops`), in a window and with the app not in the background; each is phase-aligned to the media
/// clock, so every loop of one period (two rows, the hairline's glint and the label's light) is at the same point in a
/// frame. The background is tracked from its notifications, not `applicationState`, which still reads `.background`
/// when `willEnterForeground` arrives; Core Animation drops the loops meanwhile, so they are added again on the way
/// back (and on `didBecomeActive` if any is missing).
class CompositorView: UIView {
    static let animationKey = "compositor-loop"
    var moving = false { didSet { if moving != oldValue { updateAnimations() } } }
    /// Tests: the loops stand at this instant's point instead of running (the instant's phase of each period, as the
    /// SwiftUI frame for the same `animationDateOverride` draws it).
    var frozen: Date? { didSet { if frozen != oldValue { updateAnimations() } } }
    private var looping: [CALayer] = []
    /// Between `didEnterBackground` and the way back.
    private var backgrounded = UIApplication.shared.applicationState == .background

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(updateAnimations), name: MotionRate.changed, object: nil)
        center.addObserver(self, selector: #selector(enteredBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(returned), name: UIApplication.willEnterForegroundNotification, object: nil)
        center.addObserver(self, selector: #selector(returned), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAnimations()
    }

    /// Whether the loops run now: added, and still on their layers.
    var running: Bool { !looping.isEmpty && looping.allSatisfy { $0.animation(forKey: Self.animationKey) != nil } }

    @objc func updateAnimations() {
        stop()
        guard moving, window != nil, !backgrounded else { return }
        start()
    }

    @objc private func enteredBackground() {
        backgrounded = true
        stop()
    }

    /// Back from the background (`willEnterForeground`, then `didBecomeActive`): the loops again, unless they run.
    @objc private func returned() {
        backgrounded = false
        if !running { updateAnimations() }
    }

    /// Adds the loops; called whenever motion (re)starts, in a window.
    func start() {}

    /// Repeats `animation` (linear between its values) at MotionRate's rate, at most `cap` frames a second, phase-aligned
    /// to the media clock; `lag` delays it within its period (the waiting dots rise in turn).
    func loop(_ animation: CAAnimation, on layer: CALayer, upTo cap: Int, lag: TimeInterval = 0) {
        let period = animation.duration
        animation.repeatCount = .infinity
        if !(animation is CAKeyframeAnimation), !(animation is CAAnimationGroup) {
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
        }
        if let frozen {
            animation.speed = 0
            animation.timeOffset = Self.phase(frozen.timeIntervalSinceReferenceDate - lag, period: period)
        } else {
            let now = CACurrentMediaTime()
            animation.beginTime = layer.convertTime(now - now.truncatingRemainder(dividingBy: period), from: nil)
            animation.timeOffset = Self.phase(-lag, period: period)
        }
        animation.preferredFrameRateRange = MotionRate.range(for: window?.windowScene?.screen, upTo: cap)
        layer.add(animation, forKey: Self.animationKey)
        looping.append(layer)
    }

    /// `time` within `period`, in 0..<period.
    static func phase(_ time: TimeInterval, period: TimeInterval) -> TimeInterval {
        let value = time.truncatingRemainder(dividingBy: period)
        return value < 0 ? value + period : value
    }

    func stop() {
        for layer in looping { layer.removeAnimation(forKey: Self.animationKey) }
        looping.removeAll()
    }

    /// A keyframe loop of `keyPath` over one `period`: `value` sampled at `count` + 1 points, linear between them (33
    /// points keep an eased curve within 0.3% of itself, as the Mac's).
    static func keyframes(_ keyPath: String, period: TimeInterval, count: Int = 32, _ value: (Double) -> Double) -> CAKeyframeAnimation {
        let times = (0...count).map { Double($0) / Double(count) }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = times.map { value($0 * period) }
        animation.keyTimes = times.map { NSNumber(value: $0) }
        animation.calculationMode = .linear
        animation.duration = period
        return animation
    }

    /// What `draw` rendered, by its caller's key: a row that appears again (every turn's working row) reuses its artwork
    /// instead of running `ImageRenderer` inside SwiftUI's update. A few dozen images at most (styles, sizes, schemes).
    private static var drawn: [AnyHashable: CGImage] = [:]

    /// SwiftUI renders still content once; its layer moves in the compositor. `key` names the content, its proposal and
    /// scale (a style).
    func draw(_ content: @autoclosure () -> some View, key: AnyHashable, into layer: CALayer, scale: CGFloat,
              proposal: ProposedViewSize = .unspecified) {
        let image = Self.drawn[key] ?? {
            let renderer = ImageRenderer(content: content())
            renderer.proposedSize = proposal
            renderer.scale = scale
            let image = renderer.cgImage
            if Self.drawn.count >= 64 { Self.drawn.removeAll() }
            if let image { Self.drawn[key] = image }
            return image
        }()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.contents = image
        layer.contentsScale = scale
        layer.bounds = CGRect(x: 0, y: 0, width: CGFloat(image?.width ?? 0) / scale, height: CGFloat(image?.height ?? 0) / scale)
        CATransaction.commit()
    }
}

extension View {
    /// Whether this view shows within its scroll view's visible bounds (always outside one), into `visible`: the thread's
    /// loops stop while their row is scrolled away.
    func onScreen(_ visible: Binding<Bool>) -> some View {
        onGeometryChange(for: Bool.self) { proxy in
            guard let bounds = proxy.bounds(of: .scrollView) else { return true }
            return bounds.intersects(CGRect(origin: .zero, size: proxy.size))
        } action: { visible.wrappedValue = $0 }
    }

    /// While `covered` (a sheet over this content), the compositor's loops below stand still (`loopsCovered`).
    func coversLoops(_ covered: Bool) -> some View {
        transformEnvironment(\.loopsCovered) { $0 = $0 || covered }
    }
}

// MARK: The thinking glyph

/// `ChatThinkingGlyph`'s loops: the ◆ breathing (`ChatThinkingMotion.pulse`) while the dot circles it.
struct ChatOrbitLoop: UIViewRepresentable {
    let size: CGFloat
    let moving: Bool

    func makeUIView(context: Context) -> OrbitView { OrbitView() }

    func updateUIView(_ view: OrbitView, context: Context) {
        view.style = .init(size: size, accent: Color.dispatchPink.resolve(in: context.environment), scale: context.environment.displayScale)
        view.frozen = context.environment.animationLoopsFrozen
        view.moving = moving && !context.environment.loopsCovered
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: OrbitView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }

    static func dismantleUIView(_ view: OrbitView, coordinator: ()) { view.stop() }

    final class OrbitView: CompositorView {
        struct Style: Hashable {
            var size: CGFloat = 16, accent = Color.Resolved(red: 0, green: 0, blue: 0), scale: CGFloat = 2
        }
        var style = Style() { didSet { if style != oldValue { redraw() } } }
        let diamond = CALayer(), orbit = CALayer(), dot = CALayer()

        override init() {
            super.init()
            orbit.addSublayer(dot)
            layer.addSublayer(diamond)
            layer.addSublayer(orbit)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            diamond.position = CGPoint(x: bounds.midX, y: bounds.midY)
            orbit.frame = bounds
            dot.position = CGPoint(x: bounds.midX, y: bounds.midY - style.size / 2)
            CATransaction.commit()
        }

        private func redraw() {
            draw(ChatThinkingGlyph.diamondText(size: style.size, color: Color(style.accent)), key: ["diamond", style] as [AnyHashable],
                 into: diamond, scale: style.scale)
            // The satellite is Core Animation's own circle and shadow: an ImageRenderer's copy of SwiftUI's
            // `.shadow(radius: 3)` glows about twice as strongly as SwiftUI draws it on screen; this one matches. Drawn
            // once into a bitmap (`shouldRasterize`), which only turns with its parent.
            let color = style.accent.cgColor
            let size = ChatThinkingGlyph.dotSize
            CATransaction.begin(); CATransaction.setDisableActions(true)
            dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            dot.cornerRadius = size / 2
            dot.backgroundColor = color
            dot.shadowColor = color
            dot.shadowOpacity = 1
            dot.shadowRadius = ChatThinkingGlyph.dotGlow
            dot.shadowOffset = .zero
            dot.shadowPath = CGPath(ellipseIn: dot.bounds, transform: nil)
            dot.shouldRasterize = true
            dot.rasterizationScale = style.scale
            CATransaction.commit()
            setNeedsLayout()
            updateAnimations()
        }

        override func start() {
            let pulse = CAAnimationGroup()
            pulse.animations = [
                Self.keyframes("opacity", period: ChatThinkingMotion.pulsePeriod) { 0.55 + 0.45 * ChatThinkingMotion.pulse($0) },
                Self.keyframes("transform.scale", period: ChatThinkingMotion.pulsePeriod) { 0.92 + 0.16 * ChatThinkingMotion.pulse($0) },
            ]
            pulse.duration = ChatThinkingMotion.pulsePeriod
            loop(pulse, on: diamond, upTo: MotionRate.glow)
            let circle = CABasicAnimation(keyPath: "transform.rotation.z")
            circle.fromValue = 0
            circle.toValue = 2 * Double.pi
            circle.duration = ChatThinkingMotion.orbitPeriod
            loop(circle, on: orbit, upTo: MotionRate.orbit)
        }
    }
}

// MARK: The sweep

/// `ChatAccentScan`'s loop: the glint (`ChatSweepTrack.glint`) easing across the hairline every `ChatThinkingSweep.period`.
struct ChatScanLoop: UIViewRepresentable {
    let moving: Bool

    func makeUIView(context: Context) -> ScanView { ScanView() }

    func updateUIView(_ view: ScanView, context: Context) {
        view.accent = Color.dispatchPink.resolve(in: context.environment)
        view.frozen = context.environment.animationLoopsFrozen
        view.moving = moving && !context.environment.loopsCovered
    }

    static func dismantleUIView(_ view: ScanView, coordinator: ()) { view.stop() }

    final class ScanView: CompositorView {
        var accent = Color.Resolved(red: 0, green: 0, blue: 0) { didSet { if accent != oldValue { redraw() } } }
        let band = CAGradientLayer()
        private var drawnWidth: CGFloat?

        override init() {
            super.init()
            band.startPoint = CGPoint(x: 0, y: 0.5)
            band.endPoint = CGPoint(x: 1, y: 0.5)
            band.opacity = Float(ChatAccentScan.opacity)
            layer.masksToBounds = true
            layer.addSublayer(band)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard drawnWidth != bounds.width || band.bounds.height != bounds.height else { return }
            redraw()
        }

        private func redraw() {
            drawnWidth = bounds.width
            let color = accent.cgColor
            CATransaction.begin(); CATransaction.setDisableActions(true)
            // The ends are the accent made clear (a premultiplied blend, as SwiftUI's from `.clear`), not black.
            band.colors = [color.copy(alpha: 0) ?? color, color, color.copy(alpha: 0) ?? color]
            let glint = ChatSweepTrack.glint(lineWidth: bounds.width, progress: 0)
            band.bounds = CGRect(x: 0, y: 0, width: glint.half * 2, height: bounds.height)
            // Off the line until its loop runs.
            band.position = CGPoint(x: glint.center, y: bounds.midY)
            CATransaction.commit()
            updateAnimations()
        }

        override func start() {
            guard bounds.width > 0 else { return }
            let width = bounds.width
            loop(Self.keyframes("position.x", period: ChatThinkingSweep.period) {
                Double(ChatSweepTrack.glint(lineWidth: width, progress: ChatThinkingSweep.progress(phase: $0)).center)
            }, on: band, upTo: MotionRate.sweep)
        }
    }
}

/// `ChatShimmerText`'s loop: a copy of the label in the highlight colour over the base-coloured label, seen through a
/// band crossing it with the hairline's glint (on a `track`, as wide and where the glint is), else across the label on
/// the same period.
struct ChatShimmerLoop: UIViewRepresentable {
    let text: String
    var track: ChatSweepTrack?
    let moving: Bool

    func makeUIView(context: Context) -> ShimmerView { ShimmerView() }

    func updateUIView(_ view: ShimmerView, context: Context) {
        let environment = context.environment
        view.style = .init(text: text, highlight: Color.shimmerHighlight.resolve(in: environment), scale: environment.displayScale,
                           typeSize: environment.dynamicTypeSize, weight: environment.legibilityWeight,
                           direction: environment.layoutDirection)
        view.track = track
        view.frozen = environment.animationLoopsFrozen
        view.moving = moving && !context.environment.loopsCovered
    }

    static func dismantleUIView(_ view: ShimmerView, coordinator: ()) { view.stop() }

    final class ShimmerView: CompositorView {
        struct Style: Hashable {
            var text = "", highlight = Color.Resolved(red: 1, green: 1, blue: 1), scale: CGFloat = 2
            var typeSize = DynamicTypeSize.large, weight: LegibilityWeight?, direction = LayoutDirection.leftToRight
        }
        var style = Style() { didSet { if style != oldValue { redraw() } } }
        var track: ChatSweepTrack? { didSet { if track != oldValue { place() } } }
        let ink = CALayer(), band = CAGradientLayer()
        private var drawnSize: CGSize?

        override init() {
            super.init()
            band.colors = [UIColor.clear, .black, .clear].map(\.cgColor)
            band.startPoint = CGPoint(x: 0, y: 0.5)
            band.endPoint = CGPoint(x: 1, y: 0.5)
            ink.mask = band
            ink.anchorPoint = .zero
            layer.addSublayer(ink)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard drawnSize != bounds.size else { return }
            redraw()
        }

        private func redraw() {
            guard bounds.width > 0 else { return }
            drawnSize = bounds.size
            let label = ChatShimmerText.label(style.text)
                .foregroundStyle(Color(style.highlight))
                .environment(\.dynamicTypeSize, style.typeSize)
                .environment(\.legibilityWeight, style.weight)
                .environment(\.layoutDirection, style.direction)
            draw(label, key: ["ink", style, bounds.width, bounds.height] as [AnyHashable], into: ink, scale: style.scale,
                 proposal: ProposedViewSize(bounds.size))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            ink.position = .zero
            CATransaction.commit()
            place()
        }

        /// The light's centre and half width on the label, in points, at `progress`.
        private func light(progress: Double) -> (center: CGFloat, half: CGFloat)? {
            let width = bounds.width
            guard width > 0 else { return nil }
            guard let track else {
                let half = ChatShimmerText.half
                return ((-half + (1 + 2 * half) * progress) * width, half * width)
            }
            // Not laid out yet: unlit, rather than a frame of a light that is not the glint's.
            guard track.lineWidth > 0 else { return nil }
            let glint = ChatSweepTrack.glint(lineWidth: track.lineWidth, progress: progress)
            return (glint.center - track.labelX, glint.half)
        }

        private func place() {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if let light = light(progress: 0) {
                band.bounds = CGRect(x: 0, y: 0, width: light.half * 2, height: max(bounds.height, ink.bounds.height))
                // Off the label until its loop runs.
                band.position = CGPoint(x: -light.half * 4, y: band.bounds.midY)
                ink.isHidden = false
            } else {
                ink.isHidden = true
            }
            CATransaction.commit()
            updateAnimations()
        }

        override func start() {
            guard light(progress: 0) != nil else { return }
            loop(Self.keyframes("position.x", period: ChatThinkingSweep.period) {
                Double(light(progress: ChatThinkingSweep.progress(phase: $0))?.center ?? 0)
            }, on: band, upTo: MotionRate.sweep)
        }
    }
}

// MARK: The waiting dots

/// `ChatWaitingDots`' loops: each dot rises and fades in (`ChatWaitingDots.lift`), one after another.
struct ChatDotsLoop: UIViewRepresentable {
    let color: Color
    let size: CGFloat
    let moving: Bool

    func makeUIView(context: Context) -> DotsView { DotsView() }

    func updateUIView(_ view: DotsView, context: Context) {
        view.style = .init(color: color.resolve(in: context.environment), size: size, scale: context.environment.displayScale)
        view.frozen = context.environment.animationLoopsFrozen
        view.moving = moving && !context.environment.loopsCovered
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: DotsView, context: Context) -> CGSize? {
        CGSize(width: 3 * size + 2 * ChatWaitingDots.spacing, height: size)
    }

    static func dismantleUIView(_ view: DotsView, coordinator: ()) { view.stop() }

    final class DotsView: CompositorView {
        struct Style: Hashable {
            var color = Color.Resolved(red: 0, green: 0, blue: 0), size: CGFloat = 5, scale: CGFloat = 2
        }
        var style = Style() { didSet { if style != oldValue { redraw() } } }
        let dots = (0..<3).map { _ in CALayer() }

        override init() {
            super.init()
            for dot in dots { layer.addSublayer(dot) }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for (index, dot) in dots.enumerated() {
                dot.position = CGPoint(x: style.size / 2 + CGFloat(index) * (style.size + ChatWaitingDots.spacing), y: bounds.midY)
            }
            CATransaction.commit()
        }

        private func redraw() {
            for dot in dots {
                draw(ChatWaitingDots.dot(color: Color(style.color), size: style.size), key: ["dot", style] as [AnyHashable], into: dot,
                     scale: style.scale)
            }
            setNeedsLayout()
            updateAnimations()
        }

        override func start() {
            // The lift is linear between these points: up over 0.3 of the period, down over the next 0.3, then still.
            let times = [0, 0.3, 0.6, 1.0]
            for (index, dot) in dots.enumerated() {
                let lift = times.map { ChatWaitingDots.lift(phase: $0) }
                let opacity = CAKeyframeAnimation(keyPath: "opacity")
                opacity.values = lift.map { 0.35 + 0.65 * $0 }
                let rise = CAKeyframeAnimation(keyPath: "transform.translation.y")
                rise.values = lift.map { -2 * $0 }
                for animation in [opacity, rise] {
                    animation.keyTimes = times.map { NSNumber(value: $0) }
                    animation.duration = ChatWaitingDots.period
                }
                let group = CAAnimationGroup()
                group.animations = [opacity, rise]
                group.duration = ChatWaitingDots.period
                loop(group, on: dot, upTo: MotionRate.glow, lag: Double(index) * ChatWaitingDots.lag)
            }
        }
    }
}

extension EnvironmentValues {
    /// Tests: the Core Animation loops stand at this instant instead of running (`CompositorView.frozen`).
    @Entry var animationLoopsFrozen: Date? = nil
    /// A sheet covers this content (`coversLoops`): its loops stand still.
    @Entry var loopsCovered = false
}
