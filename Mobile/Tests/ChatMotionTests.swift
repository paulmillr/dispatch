import SwiftUI
import XCTest
@testable import DispatchMobile

/// The thread's looping motion in the compositor (`CompositorView`, `MotionRate`): the thinking row's ◆ and satellite,
/// its glint and the light on "thinking", the reconnect banner's dots. Each loop asks for its rate, runs only on screen
/// in the foreground, and at any instant draws what the SwiftUI frame for that instant (`animationDateOverride`) draws.
@MainActor
final class ChatMotionTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true }
        windows = []
    }

    private func show(_ view: some View, size: CGSize) throws -> UIWindow {
        let scene = try XCTUnwrap(TestSupport.windowScene())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: view.environment(\.reduceMotionOverride, false))
        window.isHidden = false
        windows.append(window)
        return window
    }

    private func loops(in view: UIView) -> [CompositorView] {
        (view as? CompositorView).map { [$0] } ?? view.subviews.flatMap { loops(in: $0) }
    }

    /// The four looping views, as the thread shows them.
    private static var all: some View {
        VStack(spacing: 8) {
            ChatThinkingGlyph()
            ChatShimmerText(text: "thinking")
            ChatAccentScan().frame(width: 300, height: 2)
            ChatWaitingDots(color: .caution)
        }
    }

    private static func rate(_ layer: CALayer) -> Float? {
        layer.animation(forKey: CompositorView.animationKey)?.preferredFrameRateRange.preferred
    }

    /// The ◆'s breathing and the dots at `glow`, the satellite at `orbit`, the glint and the label's light at `sweep`, each
    /// within what the screen and Low Power Mode allow.
    func testEachLoopAsksForItsRate() async throws {
        let window = try show(Self.all, size: CGSize(width: 402, height: 300))
        var found: [CompositorView] = []
        try await TestSupport.eventually { found = self.loops(in: window); return found.count == 4 && found.allSatisfy(\.running) }
        let screen = window.windowScene?.screen.maximumFramesPerSecond ?? 60
        func expected(_ cap: Int) -> Float { Float(min(screen, MotionRate.limit, cap)) }
        let orbit = try XCTUnwrap(found.lazy.compactMap { $0 as? ChatOrbitLoop.OrbitView }.first)
        XCTAssertEqual(Self.rate(orbit.diamond), expected(MotionRate.glow))
        XCTAssertEqual(Self.rate(orbit.orbit), expected(MotionRate.orbit))
        let scan = try XCTUnwrap(found.lazy.compactMap { $0 as? ChatScanLoop.ScanView }.first)
        XCTAssertEqual(Self.rate(scan.band), expected(MotionRate.sweep))
        let shimmer = try XCTUnwrap(found.lazy.compactMap { $0 as? ChatShimmerLoop.ShimmerView }.first)
        XCTAssertEqual(Self.rate(shimmer.band), expected(MotionRate.sweep))
        let dots = try XCTUnwrap(found.lazy.compactMap { $0 as? ChatDotsLoop.DotsView }.first)
        XCTAssertEqual(dots.dots.map(Self.rate), Array(repeating: expected(MotionRate.glow), count: 3))
        XCTAssertEqual([MotionRate.glow, MotionRate.orbit, MotionRate.sweep], [30, 60, 60])
    }

    /// Nothing runs in the background, out of a window or scrolled out of sight; back, the loops run again.
    func testTheLoopsStopWhereNothingShowsThem() async throws {
        let window = try show(Self.all, size: CGSize(width: 402, height: 300))
        var found: [CompositorView] = []
        try await TestSupport.eventually { found = self.loops(in: window); return found.count == 4 && found.allSatisfy(\.running) }
        // The system's order: didEnterBackground, then willEnterForeground (while `applicationState` still reads
        // .background), then didBecomeActive. The loops follow the notifications.
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertTrue(found.allSatisfy { !$0.running }, "the background")
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertTrue(found.allSatisfy(\.running), "on the way back")
        // Core Animation drops a layer's animations while the app is away: becoming active adds what is missing.
        for loop in found { Self.dropAnimations(loop.layer) }
        XCTAssertTrue(found.allSatisfy { !$0.running })
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(found.allSatisfy(\.running), "active again")

        // A sheet over them (`coversLoops`).
        let covered = try show(Self.all.coversLoops(true), size: CGSize(width: 402, height: 300))
        var under: [CompositorView] = []
        try await TestSupport.eventually { under = self.loops(in: covered); return under.count == 4 && under.allSatisfy { !$0.running } }

        let orbit = ChatOrbitLoop.OrbitView()
        orbit.style = .init(size: 16, accent: Color.Resolved(red: 1, green: 0.2, blue: 0.5), scale: 2)
        orbit.moving = true
        XCTAssertFalse(orbit.running, "out of a window")
        window.addSubview(orbit)
        XCTAssertTrue(orbit.running)
        orbit.removeFromSuperview()
        XCTAssertFalse(orbit.running)

        // Below a scroll view's visible part, then scrolled into it.
        let scrolled = try show(ScrollView { VStack(spacing: 0) { Color.clear.frame(height: 1200); ChatThinkingGlyph() } },
                                size: CGSize(width: 402, height: 400))
        var below: [CompositorView] = []
        try await TestSupport.eventually { below = self.loops(in: scrolled); return below.count == 1 && !below[0].running }
        let scrollView = try XCTUnwrap(Self.scrollView(in: scrolled))
        scrollView.setContentOffset(CGPoint(x: 0, y: scrollView.contentSize.height - scrollView.bounds.height), animated: false)
        try await TestSupport.eventually { below[0].running }
    }

    private static func dropAnimations(_ layer: CALayer) {
        layer.removeAllAnimations()
        for sublayer in (layer.sublayers ?? []) + [layer.mask].compactMap({ $0 }) { dropAnimations(sublayer) }
    }

    private static func scrollView(in view: UIView) -> UIScrollView? {
        (view as? UIScrollView) ?? view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    // MARK: Frames

    /// The view's pixels (RGBA, 2x), drawn at a full-size window's top leading corner.
    private func pixels(_ view: some View, size: CGSize, waitForLoops: Bool) async throws -> [UInt8] {
        let found = await TestSupport.windowScene()
        let scene = try XCTUnwrap(found)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let root = view.frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.black)
            .ignoresSafeArea()
            .environment(\.reduceMotionOverride, false)
            .preferredColorScheme(.dark)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        windows.append(window)
        if waitForLoops {
            try await TestSupport.eventually { !self.loops(in: window).isEmpty && self.loops(in: window).allSatisfy(\.running) }
        }
        try await Task.sleep(for: .milliseconds(100))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: CGRect(origin: .zero, size: size), format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        guard let cgImage = image.cgImage else { return [] }
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = CGContext(data: &bytes, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
                                bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return bytes
    }

    private static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        return Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
    }

    /// At chosen instants the compositor's frame (its loops frozen there) is the SwiftUI frame for that instant, and
    /// clearly not another instant's.
    func testTheCompositorDrawsTheSwiftUIFrames() async throws {
        let start = Date(timeIntervalSinceReferenceDate: 363_636_363 * ChatThinkingSweep.period)
        let cases: [(String, AnyView, CGSize, [Double])] = [
            ("the thinking glyph", AnyView(ChatThinkingGlyph()), CGSize(width: 28, height: 28), [0.2, 0.7, 1.1]),
            ("the accent scan", AnyView(ChatAccentScan()), CGSize(width: 300, height: 4), [0.5, 1.1, 1.6]),
            ("the shimmer", AnyView(ChatShimmerText(text: "thinking").fixedSize()), CGSize(width: 90, height: 24), [0.9, 1.1, 1.3]),
            ("the shimmer on a track", AnyView(ChatShimmerText(text: "thinking", track: ChatSweepTrack(lineWidth: 300, labelX: 40)).fixedSize()),
             CGSize(width: 90, height: 24), [0.75, 0.85, 0.95]),
            ("the waiting dots", AnyView(ChatWaitingDots(color: .caution)), CGSize(width: 30, height: 12), [0.1, 0.3, 0.5]),
        ]
        for (name, view, size, offsets) in cases {
            for offset in offsets {
                let date = start.addingTimeInterval(offset)
                let other = start.addingTimeInterval(offset + 0.45)
                let loops = try await pixels(view.environment(\.animationLoopsFrozen, date), size: size, waitForLoops: true)
                let frame = try await pixels(view.environment(\.animationDateOverride, date), size: size, waitForLoops: false)
                let elsewhere = try await pixels(view.environment(\.animationDateOverride, other), size: size, waitForLoops: false)
                let same = Self.difference(loops, frame), apart = Self.difference(loops, elsewhere)
                // Measured: the glyph and the dots differ by 1–1.6 of 255 per channel (edge antialiasing), the sweep under
                // 0.7; another instant 2.5 to 28.
                XCTAssertLessThan(same, apart / 4, "\(name) at +\(offset) s: \(same) against another instant's \(apart)")
                XCTAssertLessThan(same, 2.5, "\(name) at +\(offset) s")
            }
        }
    }
}

