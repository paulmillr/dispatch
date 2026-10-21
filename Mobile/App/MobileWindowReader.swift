import SwiftUI
import UIKit

/// The window's size, from UIKit: what the split decides on (`MobileSplit.applies`). SwiftUI's geometry of the root
/// shrinks with the software keyboard even under `ignoresSafeArea()` (an iPad in landscape measured 1210 × 374 with it
/// up, under the split's 600 points), which folded the split away while the user typed: the tab was rebuilt, the
/// composer lost focus and the keyboard went down again. The window's bounds change with rotation, Split View and
/// Stage Manager resizes, never with the keyboard. Reported after the layout pass that changed it, once per change.
struct MobileWindowReader: UIViewRepresentable {
    let changed: (CGSize) -> Void

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
        var changed: ((CGSize) -> Void)?
        private var last: CGSize?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        func report() {
            guard let size = window?.bounds.size, size.width > 0, size != last else { return }
            last = size
            // After this layout pass: the split's state changes with it, not during SwiftUI's update.
            DispatchQueue.main.async { [weak self] in self?.changed?(size) }
        }
    }
}
