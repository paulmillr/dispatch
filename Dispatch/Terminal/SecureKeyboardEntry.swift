import Carbon.HIToolbox
import Foundation

/// Secure keyboard entry, as Terminal's: while engaged, macOS keeps Dispatch's keystrokes from other apps' event taps
/// and keyloggers (Input Monitoring), and withholds other apps' Option-only global hotkeys. It is the whole system's
/// while on, so it follows the app: on while active, off once another app is. The setting engages it for as long as
/// Dispatch is active; without the setting, only while the focused terminal waits for a password (as Ghostty's
/// macos-auto-secure-input).
@MainActor enum SecureKeyboardEntry {
    /// Settings › General › Security › Secure keyboard entry.
    static var enabled = false { didSet { update() } }
    /// The app is the active one (AppDelegate, through TerminalRuntime.setActive).
    static var active = false { didSet { update() } }
    private(set) static var engaged = false

    private static var focused: (owner: ObjectIdentifier, atPasswordPrompt: () -> Bool)?
    /// Terminal modes change without an event: only the focused terminal is asked, and only while the answer matters.
    private static var poll: DispatchSourceTimer?

    /// `owner`'s terminal has the keyboard; `atPasswordPrompt` is asked now and while it keeps it.
    static func focus(_ owner: AnyObject, atPasswordPrompt: @escaping () -> Bool) {
        focused = (ObjectIdentifier(owner), atPasswordPrompt)
        update()
    }

    static func blur(_ owner: AnyObject) {
        guard focused?.owner == ObjectIdentifier(owner) else { return }
        focused = nil
        update()
    }

    private static func update() {
        let watching = active && !enabled ? focused : nil
        if watching == nil {
            poll?.cancel()
            poll = nil
        } else if poll == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200), leeway: .milliseconds(50))
            timer.setEventHandler { MainActor.assumeIsolated { update() } }
            timer.resume()
            poll = timer
        }
        let wanted = active && (enabled || watching?.atPasswordPrompt() == true)
        guard wanted != engaged else { return }
        engaged = wanted
        _ = wanted ? EnableSecureEventInput() : DisableSecureEventInput()
    }
}
