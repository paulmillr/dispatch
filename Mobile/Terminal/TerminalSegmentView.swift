import SwiftUI
import UIKit

/// The Terminal segment of a tab (M6a): the terminal fills the space under Tabs' header, the glass key capsule sits
/// at the bottom (above the keyboard while it shows), and the d-pad's arrow cluster pops up over the terminal's
/// bottom right while held or pinned. The feed is the tab's terminal node; leaving the segment stops observing it
/// and never ends anything on the host.
struct TerminalSegmentView: View {
    private let make: @MainActor () -> TerminalController
    /// Holds the controller across view updates (made once, on the first body).
    @State private var slot = Slot()

    @MainActor final class Slot {
        var controller: TerminalController?
    }

    /// A presence Tabs keeps (shared with Chat through `TerminalPresences`).
    init(presence: TerminalPresence) { make = { TerminalController(presence: presence) } }

    /// A feed's terminal through a presence of its own (previews, a tab without Chat).
    init(feed: any TerminalFeed, scrollback: TerminalScrollback = .unknown) {
        make = { TerminalController(feed: feed, scrollback: scrollback) }
    }

    init(controller: TerminalController) { make = { controller } }

    private var controller: TerminalController {
        if let controller = slot.controller { return controller }
        let controller = make()
        slot.controller = controller
        return controller
    }

    var body: some View {
        let controller = controller
        TerminalSurfaceView(controller: controller)
            .overlay(alignment: .bottomTrailing) {
                TerminalDPadCluster(controller: controller)
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
                    // Over the terminal, which keeps its own (dark) theme in either appearance.
                    .environment(\.colorScheme, .dark)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                TerminalKeyCapsule(controller: controller)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .environment(\.colorScheme, .dark)
            }
            .coordinateSpace(.named(TerminalDPadCluster.space))
            .background(Color(controller.hostView.backgroundColor ?? .black))
            .onAppear { controller.appear() }
            .onDisappear { controller.disappear() }
    }
}

/// The host view in SwiftUI.
struct TerminalSurfaceView: UIViewRepresentable {
    let controller: TerminalController

    func makeUIView(context: Context) -> TerminalHostView { controller.hostView }
    func updateUIView(_ view: TerminalHostView, context: Context) {}
}

/// The key capsule (M6a): Liquid Glass like the tab bar, six keys of equal width with no gaps: Ctrl, Esc, Tab and Alt
/// in the monospaced system font, the d-pad, and the keyboard key. Ctrl and Alt light up while latched (tinted when
/// locked by a double tap).
struct TerminalKeyCapsule: View {
    let controller: TerminalController
    @State private var dpadTouched = false
    static let height = 52.0

    var body: some View {
        HStack(spacing: 0) {
            modifier("Ctrl", .ctrl)
            key("Esc") { controller.press(.escape) }
            key("Tab") { controller.press(.tab) }
            modifier("Alt", .alt)
            dpad
            Button { controller.toggleKeyboard() } label: {
                Image(systemName: controller.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
                    .scaledFont(19, relativeTo: .callout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(controller.keyboardVisible ? "Hide keyboard" : "Show keyboard")
        }
        .buttonStyle(KeyCapsuleButtonStyle())
        // A colour, not the hierarchical `.primary`: the d-pad's Canvas draws with it.
        .foregroundStyle(Color.primary)
        // Capped at the first accessibility size: the capsule keeps the terminal its rows.
        .keyCapsule(height: height)
    }

    @Environment(\.dynamicTypeSize) private var typeSize
    private var height: CGFloat { min(typeSize, .accessibility1).scaled(Self.height, relativeTo: .callout) }

    private func key(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.callout.monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label == "Esc" ? "Escape" : label)
    }

    private func modifier(_ label: String, _ modifier: KeyCapsuleModel.Modifier) -> some View {
        let latch = controller.capsule.latch(modifier)
        return Button { controller.tap(modifier) } label: {
            Text(label)
                .font(.callout.monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(latch == .locked ? Color.dispatchPink : .primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if latch != .off {
                        Capsule().fill(Color.primary.opacity(0.18)).padding(.vertical, 7)
                    }
                }
                .contentShape(Rectangle())
        }
        .accessibilityLabel(modifier == .ctrl ? "Control" : "Alt")
        .accessibilityValue(latch == .off ? "Off" : latch == .once ? "Next key" : "Locked")
    }

    /// Hold to show the arrow cluster and drag onto a key; a tap pins the cluster open.
    private var dpad: some View {
        TerminalDPadGlyph()
            .frame(width: 22, height: 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(TerminalDPadCluster.space))
                    .onChanged { value in
                        if !dpadTouched {
                            dpadTouched = true
                            controller.dpadDown()
                        }
                        if controller.capsule.cluster == .holding {
                            controller.dpadDrag(over: TerminalDPadCluster.arrow(at: value.location))
                        }
                    }
                    .onEnded { _ in
                        dpadTouched = false
                        controller.dpadUp()
                    }
            )
            .accessibilityLabel("Arrow keys")
            .accessibilityAddTraits(.isButton)
    }
}

/// The d-pad key's glyph (M6a): four rings in a cross around a dot.
struct TerminalDPadGlyph: View {
    var body: some View {
        Canvas { context, size in
            let s = size.width / 22
            for (x, y) in [(11.0, 4.5), (11, 17.5), (4.5, 11), (17.5, 11)] {
                let ring = Path(ellipseIn: CGRect(x: (x - 2.6) * s, y: (y - 2.6) * s, width: 5.2 * s, height: 5.2 * s))
                context.stroke(ring, with: .foreground, lineWidth: 1.6 * s)
            }
            context.fill(Path(ellipseIn: CGRect(x: 9.8 * s, y: 9.8 * s, width: 2.4 * s, height: 2.4 * s)), with: .foreground)
        }
    }
}

/// The arrow cluster (M6a): round keys in a cross around Return, 52 points each with 6 point gaps, over the
/// terminal's bottom right. Shown while the d-pad key is held (keys are entered by dragging) or pinned by a tap
/// (keys are tapped); a held key repeats. Reduce Motion: it fades instead of popping up.
struct TerminalDPadCluster: View {
    let controller: TerminalController
    @State private var touched: KeyCapsuleModel.Arrow?
    @ReduceMotion private var reduceMotion
    nonisolated static let space = "terminal-segment"
    nonisolated static let key = 52.0, gap = 6.0
    nonisolated static var side: Double { 3 * key + 2 * gap }
    /// The cluster's frame in the segment's coordinate space, for the holding finger's hit test.
    @MainActor static var frame = CGRect.zero

    var body: some View {
        ZStack {
            if controller.capsule.clusterVisible {
                grid
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: Self.side, height: Self.side)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.22, bounce: 0.2), value: controller.capsule.clusterVisible)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { Self.frame = $0 }
        .allowsHitTesting(controller.capsule.cluster == .pinned)
    }

    private var grid: some View {
        Grid(horizontalSpacing: Self.gap, verticalSpacing: Self.gap) {
            GridRow { Color.clear.frame(width: Self.key, height: Self.key); key(.up); Color.clear.frame(width: Self.key, height: Self.key) }
            GridRow { key(.left); key(.enter); key(.right) }
            GridRow { Color.clear.frame(width: Self.key, height: Self.key); key(.down); Color.clear.frame(width: Self.key, height: Self.key) }
        }
    }

    private func key(_ arrow: KeyCapsuleModel.Arrow) -> some View {
        let held = controller.capsule.held == arrow
        return ZStack {
            Circle()
                .fill(Color.terminalKey)
                .overlay(Circle().fill(Color.primary.opacity(held ? 0.18 : 0)))
                .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
            Self.glyph(arrow)
        }
        .frame(width: Self.key, height: Self.key)
        .foregroundStyle(Color.primary)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard touched != arrow else { return }
                    touched = arrow
                    controller.clusterKeyDown(arrow)
                }
                .onEnded { _ in
                    touched = nil
                    controller.clusterKeyUp()
                }
        )
        .accessibilityLabel(Self.label(arrow))
        .accessibilityAddTraits(.isButton)
    }

    static func glyph(_ arrow: KeyCapsuleModel.Arrow) -> some View {
        Group {
            switch arrow {
            case .up: Image(systemName: "chevron.up")
            case .down: Image(systemName: "chevron.down")
            case .left: Image(systemName: "chevron.left")
            case .right: Image(systemName: "chevron.right")
            case .enter: Image(systemName: "return")
            }
        }
        .font(.system(size: 17, weight: .semibold))
    }

    static func label(_ arrow: KeyCapsuleModel.Arrow) -> String {
        switch arrow {
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .enter: "Return"
        }
    }

    /// The arrow under a point of the segment's coordinate space (inside a key's circle), if any.
    @MainActor static func arrow(at point: CGPoint) -> KeyCapsuleModel.Arrow? { arrow(at: point, in: frame) }

    nonisolated static func arrow(at point: CGPoint, in frame: CGRect) -> KeyCapsuleModel.Arrow? {
        let stride = key + gap
        let x = point.x - frame.minX, y = point.y - frame.minY
        guard x >= 0, y >= 0 else { return nil }
        let column = Int(x / stride), row = Int(y / stride)
        let center = CGPoint(x: Double(column) * stride + key / 2, y: Double(row) * stride + key / 2)
        guard hypot(x - center.x, y - center.y) <= key / 2 + gap / 2 else { return nil }
        switch (column, row) {
        case (1, 0): return .up
        case (0, 1): return .left
        case (1, 1): return .enter
        case (2, 1): return .right
        case (1, 2): return .down
        default: return nil
        }
    }
}

#Preview("M6a") {
    TerminalSegmentView(feed: ScriptedTerminalFeed([.output(TerminalFixtures.viteDev), .attached],
                                                   options: .init(echo: true)))
    }
