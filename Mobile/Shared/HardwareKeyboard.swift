import Foundation
import GameController
import Observation

/// Whether a hardware keyboard is attached (a Magic Keyboard, Bluetooth, or the Mac's keyboard forwarded by the
/// simulator): what the terminal's key capsule, Chat's composer and the app's shortcuts adapt to on an iPad. The
/// GameController framework's coalesced keyboard is nil without one and changes with its connect and disconnect
/// notifications. In Debug builds the launch argument `-DispatchHardwareKeyboard YES|NO` pins it, so tests and
/// screenshots do not depend on the simulator's keyboard setting.
@MainActor @Observable final class HardwareKeyboard {
    static let shared = HardwareKeyboard()

    private(set) var attached: Bool
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// A fixed value (tests); nil follows the system.
    init(attached: Bool? = nil) {
        var fixed = attached
        #if DEBUG
        // A launch argument arrives as a string ("YES"), which `as? Bool` never matches; `bool(forKey:)` parses it.
        if fixed == nil, UserDefaults.standard.object(forKey: "DispatchHardwareKeyboard") != nil {
            fixed = UserDefaults.standard.bool(forKey: "DispatchHardwareKeyboard")
        }
        #endif
        self.attached = fixed ?? (GCKeyboard.coalesced != nil)
        guard fixed == nil else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attached = GCKeyboard.coalesced != nil }
            })
        }
    }
}
