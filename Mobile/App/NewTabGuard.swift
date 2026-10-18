import SwiftUI
import UIKit

/// Turns the tab bar's last tab (New) into a button: its selection is refused in the tab bar controller's delegate,
/// before UIKit switches to the tab's empty content, and `action` runs instead. Refusing it in SwiftUI's selection
/// binding is too late: a screen recording showed the empty tab for 16 frames (about 250 ms) before
/// SwiftUI puts the selection back and the sheet starts. SwiftUI keeps its own delegate; this one wraps it and
/// forwards everything else.
struct NewTabGuard: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> GuardView { GuardView() }

    func updateUIView(_ view: GuardView, context: Context) {
        view.action = action
        view.install()
    }

    final class GuardView: UIView {
        var action: () -> Void = {}
        private let proxy = Proxy()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            proxy.action = { [weak self] in self?.action() }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            install()
            // The tab bar controller can appear after this view on the first pass.
            DispatchQueue.main.async { [weak self] in self?.install() }
        }

        /// Wraps the tab bar controller's delegate, again whenever SwiftUI has replaced it.
        func install() {
            guard let root = window?.rootViewController, let controller = Self.tabBarController(in: root) else { return }
            guard controller.delegate !== proxy else { return }
            proxy.original = controller.delegate
            controller.delegate = proxy
        }

        private static func tabBarController(in controller: UIViewController) -> UITabBarController? {
            if let tabs = controller as? UITabBarController { return tabs }
            for child in controller.children {
                if let found = tabBarController(in: child) { return found }
            }
            return controller.presentedViewController.flatMap(tabBarController(in:))
        }
    }

    /// Answers whether New may be selected (never) and forwards every other delegate call to SwiftUI's delegate.
    final class Proxy: NSObject, UITabBarControllerDelegate {
        // Read from the nonisolated selector forwarding below; UIKit calls all of it on the main thread.
        nonisolated(unsafe) weak var original: (any UITabBarControllerDelegate)?
        var action: () -> Void = {}

        func tabBarController(_ controller: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
            if tab === controller.tabs.last {
                action()
                return false
            }
            return original?.tabBarController?(controller, shouldSelectTab: tab) ?? true
        }

        func tabBarController(_ controller: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
            if controller.tabs.isEmpty, viewController === controller.viewControllers?.last {
                action()
                return false
            }
            return original?.tabBarController?(controller, shouldSelect: viewController) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
        }
    }
}
