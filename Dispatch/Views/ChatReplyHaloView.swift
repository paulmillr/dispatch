import AppKit
import SwiftUI

/// The reply halo (ChatReplyHalo) on its bubble's frame in the transcript document. The light is the composer's working
/// border (ChatComposerAnimatedBorder): nested dash bands lapping the outline every 4 s on the same media clock, over a
/// steady accent edge; settling, light and edge fade into the bubble's own outline.
final class ChatReplyHaloView: NSView {
    static let bandCount = 24
    static let lapDuration: CFTimeInterval = 4
    static let key = "reply-halo"

    var accent: Color { didSet { if accent != oldValue { updateColors() } } }
    private(set) var phase: ChatReplyHalo.Phase?
    private let lap = CALayer(), ring = CAShapeLayer()
    /// The accent edge's strength under the light: the composer's working border's.
    static let edge: Float = 0.35
    private var bands: [CAShapeLayer] = []
    private var pathSize: CGSize = .zero
    private var perimeter: CGFloat = 0

    init(accent: Color) {
        self.accent = accent
        super.init(frame: .zero)
        wantsLayer = true
        lap.opacity = 0
        layer?.addSublayer(lap)
        for _ in 0..<Self.bandCount {
            let band = CAShapeLayer()
            band.fillColor = nil; band.lineWidth = 1; band.lineCap = .butt
            lap.addSublayer(band)
            bands.append(band)
        }
        ring.fillColor = nil; ring.lineWidth = 1; ring.opacity = 0
        layer?.addSublayer(ring)
        updateColors()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A quadratic corner (ChatBubbleOutline's) of radius r is this many r long.
    private static let corner: CGFloat = 1.1478

    private func outline(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - 10, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + 10), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 10))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - 10, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + 3, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - 3), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 10))
        path.addQuadCurve(to: CGPoint(x: rect.minX + 10, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }

    override func layout() {
        super.layout()
        guard pathSize != bounds.size else { return }
        pathSize = bounds.size
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        guard rect.width > 20, rect.height > 20 else { perimeter = 0; stop(); return }
        let full = outline(rect)
        perimeter = 2 * (rect.width + rect.height) - 66 + Self.corner * 33
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.frame = bounds; ring.path = full
        for (index, band) in bands.enumerated() {
            let length = perimeter * 0.22 * (1 - CGFloat(index) / CGFloat(Self.bandCount))
            band.frame = bounds; band.path = full
            band.lineDashPattern = [NSNumber(value: length), NSNumber(value: perimeter - length)]
            band.lineDashPhase = length / 2
        }
        CATransaction.commit()
        restartMotion()
    }

    private func updateColors() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        var previous: CGFloat = 0
        for (index, band) in bands.enumerated() {
            let alpha = 0.8 * pow(sin(.pi * (CGFloat(index) + 0.5) / CGFloat(2 * Self.bandCount)), 2)
            band.strokeColor = NSColor(accent).withAlphaComponent((alpha - previous) / (1 - previous)).cgColor
            previous = alpha
        }
        ring.strokeColor = NSColor(accent).cgColor
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? 2
        for band in bands { band.contentsScale = scale }
        ring.contentsScale = scale
        if window == nil { stop() } else { restartMotion() }
    }

    func apply(_ next: ChatReplyHalo.Phase) {
        guard next != phase else { return }
        phase = next
        switch next {
        case .lapping:
            fade(lap, to: 1, duration: 0.3)
            fade(ring, to: Self.edge, duration: 0.3)
        case .settling:
            // Gradually, while the first words type in: the light dims as it goes on lapping, the edge with it.
            let duration = ChatReplyHalo.settle
            fade(lap, to: 0, duration: duration, timing: .easeOut)
            fade(ring, to: 0, duration: duration, timing: .easeInEaseOut)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                if case .settling = self?.phase { self?.stop() }
            }
        }
        restartMotion()
    }

    private func fade(_ layer: CALayer, to opacity: Float, duration: CFTimeInterval,
                      timing: CAMediaTimingFunctionName = .easeInEaseOut) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        guard from != opacity || layer.opacity != opacity else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from; animation.toValue = opacity; animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = opacity
        CATransaction.commit()
        layer.add(animation, forKey: "fade")
    }

    private func restartMotion() {
        stop()
        guard let window, perimeter > 0, phase != nil else { return }
        let rate = MotionRate.range(for: window)
        let now = CACurrentMediaTime()
        // The lap keeps running through a settle's fade; it stops with the next phase or the view.
        let start = now - now.truncatingRemainder(dividingBy: Self.lapDuration)
        for band in bands {
            let animation = CABasicAnimation(keyPath: "lineDashPhase")
            animation.fromValue = band.lineDashPhase
            animation.toValue = band.lineDashPhase - perimeter
            animation.duration = Self.lapDuration; animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.beginTime = band.convertTime(start, from: nil)
            animation.preferredFrameRateRange = rate
            band.add(animation, forKey: Self.key)
        }
    }

    /// Hidden: the next phase starts afresh, fading in.
    func reset() {
        phase = nil
        stop()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for layer in [lap, ring] as [CALayer] { layer.removeAllAnimations(); layer.opacity = 0 }
        CATransaction.commit()
    }

    func stop() {
        for band in bands { band.removeAnimation(forKey: Self.key) }
    }
}
