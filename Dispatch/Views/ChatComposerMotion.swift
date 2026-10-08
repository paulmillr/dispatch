import SwiftUI

/// Animate only the composer's chrome; the native editor and transcript retain
/// their geometry, selection, and scroll position during a split focus change.
struct ChatComposerFocusChrome: View {
    let session: ChatSession
    let focused: Bool
    let lineHeight: CGFloat
    /// Glass only: where the unfocused reply button sits, from the composer's bottom-trailing corner.
    var buttonInset = CGSize.zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            if LiquidGlassStore.shared.active {
                // The composer's frame is the glass. Unfocused it is the round reply button (ChatView draws its
                // icon) where Send sits on the footer row; focus grows it from that corner into the composer, the
                // circle easing into the composer's corners, with the borders (working animation included) on its edge.
                // Unfocused while the agent works, the row shows its activity on the pane's own background.
                let state = AgentWorkingState(session)
                let radius: CGFloat = focused ? 12 : lineHeight / 2
                Color.clear
                    .liquidGlass(in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .opacity(focused || !(state.visible && !state.loading) ? 1 : 0)
                    .overlay {
                        Color.clear.modifier(ChatComposerBorder(session: session, active: focused, cornerRadius: radius))
                            .opacity(focused ? 1 : 0)
                    }
                    .frame(width: focused ? geometry.size.width : lineHeight, height: focused ? geometry.size.height : lineHeight)
                    .padding(.trailing, focused ? 0 : buttonInset.width).padding(.bottom, focused ? 0 : buttonInset.height)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomTrailing)
                    .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.24), value: focused)
            } else {
                Color.clear
                    .chatPanel(Chrome.sidebar, bordered: false)
                    .modifier(ChatComposerBorder(session: session, active: focused))
                    .frame(height: focused ? geometry.size.height : lineHeight)
                    .opacity(focused ? 1 : 0)
                    .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.18), value: focused)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct ChatComposerOrbit: View {
    @Environment(\.chatTheme) private var theme
    let seconds: TimeInterval
    let moving: Bool

    var body: some View {
        let pulse = moving ? (1 - cos(seconds * 2 * .pi / 1.6)) / 2 : 1
        ZStack {
            Text("◆").font(.system(size: 11.5)).foregroundStyle(theme.accent)
                .opacity(0.55 + 0.45 * pulse).scaleEffect(moving ? 0.92 + 0.16 * pulse : 1)
            if moving {
                Circle().fill(theme.accent).frame(width: 4, height: 4)
                    .shadow(color: theme.accent.opacity(0.7), radius: 3)
                    .offset(y: -8)
                    .rotationEffect(.degrees(seconds.truncatingRemainder(dividingBy: 1.4) / 1.4 * 360))
            }
        }.frame(width: 16, height: 20).accessibilityHidden(true)
    }
}

struct ChatComposerStatus: View {
    @Environment(\.chatTheme) private var theme
    let label: String
    let seconds: TimeInterval
    let moving: Bool

    var body: some View {
        Text(label).fontWeight(.medium).lineLimit(1).foregroundStyle(theme.muted)
            .overlay {
                if moving {
                    GeometryReader { geometry in
                        LinearGradient(colors: [.clear, theme.ink, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 35)
                            .offset(x: (geometry.size.width + 35) * seconds.truncatingRemainder(dividingBy: 2.4) / 2.4 - 35)
                    }.mask(Text(label).fontWeight(.medium).lineLimit(1))
                        .accessibilityHidden(true)
                }
            }
    }
}

struct ChatComposerBorder: ViewModifier {
    @Environment(\.chatTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: ChatSession
    var active = true
    /// Follows the surface it borders: the flat panel's 8 points, or the glass composer's rounder corners.
    var cornerRadius: CGFloat = 8
    @State private var visible = false

    func body(content: Content) -> some View {
        let state = AgentWorkingState(session)
        let working = state.visible && !state.loading
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(theme.accent.opacity(working ? 0.06 : 0), lineWidth: 6)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(working ? theme.accent.opacity(0.35)
                                  // On glass the panel's own edge already frames the idle input.
                                  : (session.drafts.current.multiline ? theme.muted.opacity(0.55)
                                     : LiquidGlassStore.shared.active ? .clear : theme.border))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .overlay {
                if working && !state.waiting && !reduceMotion && session.showChat {
                    ChatComposerAnimatedBorder(accent: theme.accent, moving: visible && active, radius: cornerRadius - 0.5)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .onAppear { visible = true }
            .onDisappear { visible = false }
    }
}

/// Animate in the compositor. A display-link callback that updates a SwiftUI
/// Canvas still depends on SwiftUI scheduling and main-thread rendering per frame.
struct ChatComposerAnimatedBorder: NSViewRepresentable {
    let accent: Color
    let moving: Bool
    var radius: CGFloat = 7.5

    func makeNSView(context: Context) -> BorderView { BorderView(accent: accent) }

    func updateNSView(_ view: BorderView, context: Context) {
        view.accent = accent
        view.moving = moving
        view.radius = radius
    }

    static func dismantleNSView(_ view: BorderView, coordinator: ()) { view.stop() }

    final class BorderView: NSView {
        var accent: Color { didSet { if accent != oldValue { updateColors() } } }
        var moving = false { didSet { if moving != oldValue { updateAnimations() } } }
        var radius: CGFloat = 7.5 { didSet { if radius != oldValue { pathSize = .zero; needsLayout = true } } }
        private(set) var bands: [CAShapeLayer] = []
        private var perimeter: CGFloat = 0
        private var pathSize: CGSize = .zero
        private static let bandCount = 24
        static let animationKey = "composer-border-lap"

        init(accent: Color) {
            self.accent = accent
            super.init(frame: .zero)
            wantsLayer = true
            for _ in 0..<Self.bandCount {
                let band = CAShapeLayer()
                band.fillColor = nil; band.lineWidth = 1; band.lineCap = .butt
                layer?.addSublayer(band)
                bands.append(band)
            }
            updateColors()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            guard pathSize != bounds.size else { return }
            pathSize = bounds.size
            let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
            guard rect.width > 0, rect.height > 0 else { perimeter = 0; stop(); return }
            let radius = min(self.radius, min(rect.width, rect.height) / 2)
            let path = CGMutablePath()
            // The flipped view's increasing angles trace clockwise from top center.
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius,
                        startAngle: -.pi / 2, endAngle: 0, clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius,
                        startAngle: 0, endAngle: .pi / 2, clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius,
                        startAngle: .pi / 2, endAngle: .pi, clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius,
                        startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: false)
            path.closeSubpath()
            perimeter = 2 * (rect.width + rect.height) + (2 * .pi - 8) * radius
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for (index, band) in bands.enumerated() {
                let length = perimeter * 0.22 * (1 - CGFloat(index) / CGFloat(Self.bandCount))
                band.frame = bounds; band.path = path
                band.lineDashPattern = [NSNumber(value: length), NSNumber(value: perimeter - length)]
                band.lineDashPhase = length / 2
            }
            CATransaction.commit()
            updateAnimations()
        }

        private func updateColors() {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            var previous: CGFloat = 0
            // Nested dashes form the same soft, symmetric highlight without
            // adjacent segment seams. Each inner band adds only the missing alpha.
            for (index, band) in bands.enumerated() {
                let alpha = 0.8 * pow(sin(.pi * (CGFloat(index) + 0.5) / CGFloat(2 * Self.bandCount)), 2)
                band.strokeColor = NSColor(accent).withAlphaComponent((alpha - previous) / (1 - previous)).cgColor
                previous = alpha
            }
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(updateAnimations), name: name, object: window)
                }
            }
            updateScale()
            updateAnimations()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateScale()
        }

        private func updateScale() {
            let scale = window?.backingScaleFactor ?? 2
            for band in bands { band.contentsScale = scale }
        }

        @objc private func updateAnimations() {
            stop()
            guard moving, let window, window.occlusionState.contains(.visible), perimeter > 0 else { return }
            let fps = Float(max(1, window.screen?.maximumFramesPerSecond ?? 60))
            let now = CACurrentMediaTime()
            let start = now - now.truncatingRemainder(dividingBy: 4)
            for band in bands {
                let animation = CABasicAnimation(keyPath: "lineDashPhase")
                animation.fromValue = band.lineDashPhase
                animation.toValue = band.lineDashPhase - perimeter
                animation.duration = 4; animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                animation.beginTime = band.convertTime(start, from: nil)
                animation.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
                band.add(animation, forKey: Self.animationKey)
            }
        }

        func stop() {
            for band in bands { band.removeAnimation(forKey: Self.animationKey) }
        }
    }
}

// Compositor version (Core Animation): moves the orbit, pulse, sweep and border without a SwiftUI
// update per frame. Disabled until visually reviewed; the SwiftUI version above is live.
/*
/// The ◆ pulses while a dot circles it; still, the ◆ rests at full strength.
struct ChatComposerOrbit: NSViewRepresentable {
    let moving: Bool

    func makeNSView(context: Context) -> OrbitView { OrbitView(accent: context.environment.chatTheme.accent) }

    func updateNSView(_ view: OrbitView, context: Context) {
        view.accent = context.environment.chatTheme.accent
        view.moving = moving
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: OrbitView, context: Context) -> CGSize? {
        CGSize(width: 16, height: 20)
    }

    static func dismantleNSView(_ view: OrbitView, coordinator: ()) { view.stop() }

    final class OrbitView: CompositorView {
        var accent: Color { didSet { if accent != oldValue { redraw() } } }
        let diamond = CALayer(), orbit = CALayer()
        private let dot = CALayer()

        init(accent: Color) {
            self.accent = accent
            super.init()
            orbit.addSublayer(dot)
            orbit.isHidden = true
            layer?.addSublayer(diamond); layer?.addSublayer(orbit)
        }

        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            diamond.position = CGPoint(x: bounds.midX, y: bounds.midY)
            orbit.frame = bounds
            dot.position = CGPoint(x: bounds.midX, y: bounds.midY - 8)
            CATransaction.commit()
        }

        override func redraw() {
            draw(Text("◆").font(.system(size: 11.5)).foregroundStyle(accent), into: diamond)
            draw(Circle().fill(accent).frame(width: 4, height: 4).shadow(color: accent.opacity(0.7), radius: 3).padding(6), into: dot)
        }

        override func start(_ rate: CAFrameRateRange) {
            orbit.isHidden = false
            // (1 - cos) / 2 sampled at 33 points: linear steps stay within 0.3% of the curve.
            let times = (0...32).map { Double($0) / 32 }
            func pulse(_ keyPath: String, from low: Double, to high: Double) -> CAKeyframeAnimation {
                let animation = CAKeyframeAnimation(keyPath: keyPath)
                animation.values = times.map { low + (high - low) * (1 - cos($0 * 2 * .pi)) / 2 }
                animation.keyTimes = times.map { NSNumber(value: $0) }
                animation.duration = 1.6
                return animation
            }
            let breathe = CAAnimationGroup()
            breathe.animations = [pulse("opacity", from: 0.55, to: 1), pulse("transform.scale", from: 0.92, to: 1.08)]
            breathe.duration = 1.6
            loop(breathe, on: diamond, rate: rate)
            let circle = CABasicAnimation(keyPath: "transform.rotation.z")
            circle.fromValue = 0; circle.toValue = 2 * Double.pi; circle.duration = 1.4
            loop(circle, on: orbit, rate: rate)
        }

        override func stop() {
            super.stop()
            orbit.isHidden = true
        }
    }
}

/// While moving, an ink copy of the label shows through a band sweeping across it.
struct ChatComposerStatus: View {
    @Environment(\.chatTheme) private var theme
    let label: String
    let moving: Bool

    var body: some View {
        Text(label).fontWeight(.medium).lineLimit(1).foregroundStyle(theme.muted)
            .overlay {
                if moving { ChatComposerShimmer(label: label).accessibilityHidden(true) }
            }
    }
}

struct ChatComposerShimmer: NSViewRepresentable {
    let label: String

    func makeNSView(context: Context) -> ShimmerView { ShimmerView() }

    func updateNSView(_ view: ShimmerView, context: Context) {
        view.style = .init(label: label, font: context.environment.font, truncation: context.environment.truncationMode,
                           ink: context.environment.chatTheme.ink)
        view.moving = true
    }

    static func dismantleNSView(_ view: ShimmerView, coordinator: ()) { view.stop() }

    final class ShimmerView: CompositorView {
        struct Style: Equatable {
            var label = "", font: Font?, truncation = Text.TruncationMode.tail, ink = Color.clear
        }
        var style = Style() { didSet { if style != oldValue { redraw() } } }
        let ink = CALayer(), band = CAGradientLayer()
        private var drawnSize: CGSize?
        private static let width: CGFloat = 35

        override init() {
            super.init()
            band.colors = [NSColor.clear, .black, .clear].map(\.cgColor)
            band.startPoint = CGPoint(x: 0, y: 0.5); band.endPoint = CGPoint(x: 1, y: 0.5)
            ink.mask = band
            // Still captures (CALayer.render(in:)) ignore masks: the copy shows only while its loop runs.
            ink.opacity = 0
            layer?.addSublayer(ink)
        }

        override func layout() {
            super.layout()
            guard drawnSize != bounds.size else { return }
            redraw()
            updateAnimations()
        }

        override func redraw() {
            guard bounds.width > 0 else { return }
            drawnSize = bounds.size
            draw(Text(style.label).font(style.font).fontWeight(.medium).lineLimit(1).truncationMode(style.truncation)
                    .foregroundStyle(style.ink), into: ink, proposal: ProposedViewSize(bounds.size))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            ink.position = CGPoint(x: ink.bounds.midX, y: ink.bounds.midY)
            band.frame = CGRect(x: -Self.width, y: 0, width: Self.width, height: bounds.height)
            CATransaction.commit()
        }

        override func start(_ rate: CAFrameRateRange) {
            guard bounds.width > 0 else { return }
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 1; show.toValue = 1; show.duration = 2.4
            loop(show, on: ink, rate: rate)
            let sweep = CABasicAnimation(keyPath: "position.x")
            sweep.fromValue = -Self.width / 2; sweep.toValue = bounds.width + Self.width / 2; sweep.duration = 2.4
            loop(sweep, on: band, rate: rate)
        }
    }
}

/// A soft highlight laps the composer border while an agent works.
struct ChatComposerAnimatedBorder: NSViewRepresentable {
    let accent: Color
    let moving: Bool

    func makeNSView(context: Context) -> BorderView { BorderView(accent: accent) }

    func updateNSView(_ view: BorderView, context: Context) {
        view.accent = accent
        view.moving = moving
    }

    static func dismantleNSView(_ view: BorderView, coordinator: ()) { view.stop() }

    final class BorderView: CompositorView {
        var accent: Color { didSet { if accent != oldValue { updateColors() } } }
        private(set) var bands: [CAShapeLayer] = []
        private var perimeter: CGFloat = 0
        private var pathSize: CGSize = .zero
        private static let bandCount = 24

        init(accent: Color) {
            self.accent = accent
            super.init()
            for _ in 0..<Self.bandCount {
                let band = CAShapeLayer()
                band.fillColor = nil; band.lineWidth = 1; band.lineCap = .butt
                layer?.addSublayer(band)
                bands.append(band)
            }
            updateColors()
        }

        override func layout() {
            super.layout()
            guard pathSize != bounds.size else { return }
            pathSize = bounds.size
            let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
            guard rect.width > 0, rect.height > 0 else { perimeter = 0; stop(); return }
            let radius = min(7.5, min(rect.width, rect.height) / 2)
            let path = CGMutablePath()
            // The flipped view's increasing angles trace clockwise from top center.
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius,
                        startAngle: -.pi / 2, endAngle: 0, clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius,
                        startAngle: 0, endAngle: .pi / 2, clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius,
                        startAngle: .pi / 2, endAngle: .pi, clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius,
                        startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: false)
            path.closeSubpath()
            perimeter = 2 * (rect.width + rect.height) + (2 * .pi - 8) * radius
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for (index, band) in bands.enumerated() {
                let length = perimeter * 0.22 * (1 - CGFloat(index) / CGFloat(Self.bandCount))
                band.frame = bounds; band.path = path
                band.lineDashPattern = [NSNumber(value: length), NSNumber(value: perimeter - length)]
                band.lineDashPhase = length / 2
            }
            CATransaction.commit()
            updateAnimations()
        }

        private func updateColors() {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            var previous: CGFloat = 0
            // Nested dashes form the same soft, symmetric highlight without
            // adjacent segment seams. Each inner band adds only the missing alpha.
            for (index, band) in bands.enumerated() {
                let alpha = 0.8 * pow(sin(.pi * (CGFloat(index) + 0.5) / CGFloat(2 * Self.bandCount)), 2)
                band.strokeColor = NSColor(accent).withAlphaComponent((alpha - previous) / (1 - previous)).cgColor
                previous = alpha
            }
            CATransaction.commit()
        }

        override func redraw() {
            for band in bands { band.contentsScale = window?.backingScaleFactor ?? 2 }
        }

        override func start(_ rate: CAFrameRateRange) {
            guard perimeter > 0 else { return }
            for band in bands {
                let animation = CABasicAnimation(keyPath: "lineDashPhase")
                animation.fromValue = band.lineDashPhase
                animation.toValue = band.lineDashPhase - perimeter
                animation.duration = 4
                loop(animation, on: band, rate: rate)
            }
        }
    }
}

/// Continuous motion runs in the compositor. Chat views sit inside the window's nested
/// hosting views, where every SwiftUI update re-lays out the whole window: SwiftUI motion
/// costs that on each frame, and behind a slow layout the next frame lands in the same
/// window layout until AppKit stops its Update Constraints loop. A display-link callback
/// that updates SwiftUI has the same cost. SwiftUI only draws the still artwork.
class CompositorView: NSView {
    static let animationKey = "compositor-loop"
    var moving = false { didSet { if moving != oldValue { updateAnimations() } } }
    private var looping: [CALayer] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(updateAnimations), name: name, object: window)
            }
        }
        redraw()
        updateAnimations()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redraw()
    }

    @objc func updateAnimations() {
        stop()
        guard moving, let window, window.occlusionState.contains(.visible) else { return }
        let fps = Float(max(1, window.screen?.maximumFramesPerSecond ?? 60))
        start(CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps))
    }

    /// Adds the loops; called whenever motion (re)starts.
    func start(_ rate: CAFrameRateRange) {}
    /// Redraws still artwork for the current inputs and backing scale.
    func redraw() {}

    /// Repeats `animation` at the screen's rate, phase-aligned to the media clock so
    /// every indicator with the same period moves together.
    func loop(_ animation: CAAnimation, on layer: CALayer, rate: CAFrameRateRange) {
        let now = CACurrentMediaTime()
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.beginTime = layer.convertTime(now - now.truncatingRemainder(dividingBy: animation.duration), from: nil)
        animation.preferredFrameRateRange = rate
        layer.add(animation, forKey: Self.animationKey)
        looping.append(layer)
    }

    func stop() {
        for layer in looping { layer.removeAnimation(forKey: Self.animationKey) }
        looping.removeAll()
    }

    /// SwiftUI renders still content once; its layer moves in the compositor.
    func draw(_ content: some View, into layer: CALayer, proposal: ProposedViewSize = .unspecified) {
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = proposal
        let scale = window?.backingScaleFactor ?? 2
        renderer.scale = scale
        let image = renderer.cgImage
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.contents = image
        layer.contentsScale = scale
        layer.bounds.size = CGSize(width: CGFloat(image?.width ?? 0) / scale, height: CGFloat(image?.height ?? 0) / scale)
        CATransaction.commit()
    }
}
*/
