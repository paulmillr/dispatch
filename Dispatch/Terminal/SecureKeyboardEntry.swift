import Carbon.HIToolbox

/// Secure keyboard entry, as Terminal's: while Dispatch is the active app, macOS keeps its keystrokes from other
/// apps' event taps and keyloggers (Input Monitoring), passwords at a sudo or ssh prompt included. It is the whole
/// system's while on, so it follows the app: on while active, off once another app is.
@MainActor enum SecureKeyboardEntry {
    /// Settings › General › Secure keyboard entry.
    static var enabled = false { didSet { update() } }
    /// The app is the active one (AppDelegate, through TerminalRuntime.setActive).
    static var active = false { didSet { update() } }
    private(set) static var engaged = false

    private static func update() {
        let wanted = enabled && active
        guard wanted != engaged else { return }
        engaged = wanted
        _ = wanted ? EnableSecureEventInput() : DisableSecureEventInput()
    }
}
