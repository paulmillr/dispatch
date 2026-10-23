import ObjectiveC
import SwiftUI
import UIKit

/// iOS 27.1's vertical bar is off on screens wide enough for the split (`MobileSplit`). On the iPhone Duo it puts the
/// status bar, and with it the tab bar and the bar items, in a strip down one side: unfolded in book posture the strip
/// kept the tab's column off the screen's trailing edge. The folded cover screen keeps the system's choice: without
/// the strip its status shared the bar's row with the camera, and the tab's header folded into the bar's "…" menu.
/// UIKit asks the window's root view controller, which here is SwiftUI's hosting controller: its class answers for
/// itself (it overrides both the behavior and the child it defers to), so the root's class and `UIViewController`
/// answer by the window's size with no child, and fold and unfold ask again (`refresh`). SwiftUI has no modifier.
enum MobileVerticalBar {
    @MainActor private static weak var root: UIViewController?

    @MainActor static func install(root: UIViewController) {
        guard #available(iOS 27.1, *) else { return }
        Self.root = root
        let behavior = #selector(getter: UIViewController.preferredVerticalBarBehavior)
        let child = #selector(getter: UIViewController.childForPreferredVerticalBarBehavior)
        let bySize: @convention(block) (UIViewController) -> Int = { controller in
            let size = controller.viewIfLoaded?.window?.bounds.size ?? .zero
            return MobileSplit.applies(to: size) ? UIVerticalBarBehavior.disabled.rawValue : UIVerticalBarBehavior.automatic.rawValue
        }
        let none: @convention(block) (UIViewController) -> UIViewController? = { _ in nil }
        for type in [UIViewController.self, Swift.type(of: root)] {
            if let method = class_getInstanceMethod(type, behavior) { method_setImplementation(method, imp_implementationWithBlock(bySize)) }
            if let method = class_getInstanceMethod(type, child) { method_setImplementation(method, imp_implementationWithBlock(none)) }
        }
        root.setNeedsUpdateOfVerticalBarConfiguration()
    }

    /// The window changed screens (folded or unfolded): the behavior follows its new size.
    @MainActor static func refresh() {
        guard #available(iOS 27.1, *) else { return }
        root?.setNeedsUpdateOfVerticalBarConfiguration()
    }
}

/// At the app's root: installs the vertical bar's answer once the window has its root view controller.
struct MobileVerticalBarOff: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {}

    final class Probe: UIView {
        private var done = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard !done, window != nil else { return }
            // The hosting controller becomes the root after its view is in the window.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.done, let root = self.window?.rootViewController else { return }
                self.done = true
                MobileVerticalBar.install(root: root)
            }
        }
    }
}
