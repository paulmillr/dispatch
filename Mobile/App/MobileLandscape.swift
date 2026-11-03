import SwiftUI
import UIKit

/// An iPhone on its side (mockups L12–L15): 874 × 402 points on an iPhone 17, 956 × 440 on a Pro Max. Every point of
/// the window goes to the tab's content: no navigation bar, no capsule row, no composer row, no key capsule at rest.
/// The chrome stands in one rail on the Dynamic Island's side (`TabRail`): Back and the menu disc, the five modes, the
/// mode's action at its foot (Reply, the keyboard, Create review). iOS insets both sides for the island (62 points on
/// an iPhone 17 or 18 Pro, 68 on the Air, whose island sits lower; 47 for the 17e's notch), which is on one side only;
/// the rail stands just clear of it and the content runs into the other side's inset, to the glass's rounded corners. As pure rules, so tests check every size and orientation on any simulator.
enum MobileLandscape {
    /// By the window's size, not its size classes: the window the root measures (`MobileWindowReader`) keeps its size
    /// while the keyboard comes up, so typing never flips the layout. A phone's window wider than tall and too short for
    /// the split (`MobileSplit.minimum`): every iPhone on its side, and the Duo's cover screen; the unfolded Duo splits
    /// instead, and an iPad's narrow windows keep the phone's stack upright.
    static func applies(to size: CGSize, device: MobileSplit.Device) -> Bool {
        device == .phone && size.width > size.height && !MobileSplit.applies(to: size, device: device)
    }

    /// The rail's edge: the Dynamic Island's, which is the phone's top. The interface turned landscape right has the
    /// home indicator's side on the right and the top on the left; landscape left the other way. Unknown (the
    /// simulator before its first rotation): leading.
    static func railEdge(_ orientation: UIInterfaceOrientation) -> HorizontalEdge {
        orientation == .landscapeLeft ? .trailing : .leading
    }

    /// How deep the island (or notch) reaches in from its edge, as the safe area keeps it: the portrait top inset, the
    /// landscape side's (the home indicator's bottom inset aside). A phone's constant, read from its window.
    static func island(_ insets: UIEdgeInsets) -> CGFloat { max(insets.top, insets.left, insets.right) }

    /// Before the window is measured: an iPhone 17's and 18 Pro's.
    static let defaultIsland: CGFloat = 62

    /// The rail's padding from the window's edge: its glass 2 points clear of the island, which ends about 14 points
    /// inside the safe area's inset (48 of 62 on an iPhone 17 or 18 Pro Max, 54 of 68 on the Air, 33 of 47 for the
    /// 17e's notch), the glass reaching 2 points past the padding: 10 inside the inset. A phone without one (no inset)
    /// keeps the content's margin from the rounded corners.
    static func railInset(island: CGFloat) -> CGFloat { max(contentInset, island - 10) }

    /// The content's outer edge on the side without the island: clear of the rounded corners at mid height.
    static let contentInset: CGFloat = 12

    /// Review's and Commits' list beside its pane: a portrait row less its margins, leaving the pane the rest (the iPad's
    /// 360 would leave a diff about half of the window).
    static let listWidth: CGFloat = 300

    /// The rail's width: a 44-point control and its glass.
    static let railWidth: CGFloat = 52
    /// The rail's margin above and below, and the least gap between its groups: the tallest rail (Back, the disc, five
    /// modes, the action) fits the shortest phone on its side (375 points).
    static let railMargin: CGFloat = 8
    static let railGap: CGFloat = 6
    /// The rail's height with everything in it: Back and the disc 8 apart, the modes, the 50-point action.
    static var railHeight: CGFloat {
        2 * railMargin + 44 + 8 + 44 + railGap + PadModeSwitch.length(5, axis: .vertical) + railGap + 50
    }

    /// The terminal's key capsule shows only riding a docked keyboard; at rest the rail's keyboard button raises it
    /// (and, held, offers Esc, Ctrl-C and the rest), so the terminal keeps its full width and height.
    static func keyCapsule(keyboard: TerminalAdaptation.Keyboard) -> Bool { keyboard == .docked }

    /// Above a docked keyboard the rail keeps Back and the menu disc: the modes and the action wait for it to go.
    static func compactRail(keyboard: TerminalAdaptation.Keyboard) -> Bool { keyboard == .docked }

    /// How long the tab's name shows in its chip as the tab opens, the header that said it being gone.
    static let titleDuration: Duration = .seconds(2.5)
}

extension EnvironmentValues {
    /// The phone's window is on its side (`MobileLandscape.applies`); set by the root's stack.
    @Entry var mobileLandscape = false
    /// The side the rail stands on (`MobileLandscape.railEdge`); set by the root's stack.
    @Entry var mobileRailEdge: HorizontalEdge = .leading
    /// How deep the island reaches in (`MobileLandscape.island`); set by the root's stack.
    @Entry var mobileIsland: CGFloat = MobileLandscape.defaultIsland
    /// The rail a tab's segment talks to (`TabRailState`): set by `TabScreen` on a phone's side, nil otherwise.
    @Entry var tabRail: TabRailState? = nil
}

/// What a tab's segment gives the rail on a phone's side: the terminal its controller (the keyboard button and its
/// menu), Chat its Reply while the empty composer is folded into it.
@MainActor @Observable
final class TabRailState {
    /// The shown terminal's controller (set while its segment shows, so the rail's keyboard button appears with it).
    var terminal: TerminalController?
    /// Chat's composer is folded (empty, unfocused): Reply shows at the rail's foot.
    var replyShown = false
    /// Unfolds the composer and focuses it.
    @ObservationIgnored var reply: () -> Void = {}
}

/// The window scene's interface orientation, from UIKit: its geometry is observed, so a half turn (landscape left to
/// right, the same size) reports too. Reported after the change, once per change.
struct MobileOrientationReader: UIViewRepresentable {
    let changed: (UIInterfaceOrientation) -> Void

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) { probe.changed = changed }

    final class Probe: UIView {
        var changed: ((UIInterfaceOrientation) -> Void)?
        private var last: UIInterfaceOrientation?
        private var observation: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            observation = window?.windowScene?.observe(\.effectiveGeometry, options: [.initial, .new]) { [weak self] scene, _ in
                let orientation = scene.effectiveGeometry.interfaceOrientation
                DispatchQueue.main.async { self?.report(orientation) }
            }
        }

        private func report(_ orientation: UIInterfaceOrientation) {
            guard orientation != last else { return }
            last = orientation
            changed?(orientation)
        }
    }
}
