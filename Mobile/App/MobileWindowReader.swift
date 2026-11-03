import SwiftUI
import UIKit

/// The window's size, from UIKit: what the split decides on (`MobileSplit.applies`). SwiftUI's geometry of the root
/// shrinks with the software keyboard even under `ignoresSafeArea()` (an iPad in landscape measured 1210 × 374 with it
/// up, under the split's 600 points), which folded the split away while the user typed: the tab was rebuilt, the
/// composer lost focus and the keyboard went down again. The window's bounds change with rotation, Split View and
/// Stage Manager resizes, never with the keyboard. Reported after the layout pass that changed it, once per change.
struct MobileWindowReader: UIViewRepresentable {
    /// The window's size, and the depth of the Dynamic Island or notch (`MobileLandscape.island`).
    let changed: (CGSize, CGFloat) -> Void

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.changed = changed
        probe.report()
    }

    final class Probe: UIView {
        var changed: ((CGSize, CGFloat) -> Void)?
        private var last: CGSize?
        private var lastIsland: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        func report() {
            guard let window, window.bounds.width > 0 else { return }
            let size = window.bounds.size, island = MobileLandscape.island(window.safeAreaInsets)
            guard size != last || island != lastIsland else { return }
            last = size
            lastIsland = island
            // After this layout pass: the split's state changes with it, not during SwiftUI's update. The size and the
            // island together, so a phone's first layout on its side already stands its rail clear of the island.
            DispatchQueue.main.async { [weak self] in self?.changed?(size, island) }
        }
    }
}
