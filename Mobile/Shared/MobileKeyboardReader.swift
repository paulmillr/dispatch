import SwiftUI
import UIKit

/// Where the software keyboard is (`TerminalAdaptation.Keyboard`: hidden, docked or floating), for SwiftUI screens that
/// must not take a floating keyboard's inset: on an iPad SwiftUI keeps a keyboard inset for a floating (or split)
/// keyboard too, which lifted Chat's composer part of the way and left it under the keyboard. The frame comes from
/// `keyboardLayoutGuide` with `followsUndockedKeyboard`, as the terminal's (`TerminalHostView.keyboardTracker`): a
/// keyboard that comes up floating posts no notifications, and floating a docked one posts a hide while it stays.
struct MobileKeyboardReader: UIViewRepresentable {
    let changed: (TerminalAdaptation.Keyboard) -> Void

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.changed = changed
    }

    final class Probe: UIView {
        var changed: ((TerminalAdaptation.Keyboard) -> Void)?
        private let tracker = UIView()
        private var last: TerminalAdaptation.Keyboard?

        override init(frame: CGRect) {
            super.init(frame: frame)
            tracker.isHidden = true
            tracker.isUserInteractionEnabled = false
            tracker.translatesAutoresizingMaskIntoConstraints = false
            addSubview(tracker)
            let guide = keyboardLayoutGuide
            guide.followsUndockedKeyboard = true
            NSLayoutConstraint.activate([
                tracker.topAnchor.constraint(equalTo: guide.topAnchor),
                tracker.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
                tracker.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                tracker.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window else { return }
            let next = TerminalAdaptation.keyboard(frame: convert(tracker.frame, to: window), window: window.bounds)
            guard next != last else { return }
            last = next
            // After this layout pass: the screen's safe area changes with it, not during SwiftUI's update.
            DispatchQueue.main.async { [weak self] in self?.changed?(next) }
        }
    }
}
