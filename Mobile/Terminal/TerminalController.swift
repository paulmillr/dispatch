import SwiftUI
import UIKit
@preconcurrency import Term

/// The Terminal segment's state (M6a): the host view showing a `TerminalPresence`, the key capsule's model and its
/// timers, and the keyboard. The presence is Tabs' (shared with Chat through `TerminalPresences`), or the
/// controller's own when made from a feed, in which case leaving the segment stops observing the terminal.
@MainActor @Observable
final class TerminalController {
    @ObservationIgnored let presence: TerminalPresence
    @ObservationIgnored let hostView: TerminalHostView
    @ObservationIgnored private let ownsPresence: Bool
    private(set) var capsule = KeyCapsuleModel()
    /// Where the software keyboard is: docked (the capsule rides on it), floating or split (the capsule stays at the
    /// bottom), or hidden (also when a hardware keyboard leaves only the shortcut bar).
    private(set) var keyboard = TerminalAdaptation.Keyboard.hidden
    /// The software keyboard is on screen.
    var keyboardVisible: Bool { keyboard != .hidden }
    /// The device class (iPad: the capsule collapses with a hardware keyboard); tests set it.
    var idiom = UIDevice.current.userInterfaceIdiom
    /// Whether a hardware keyboard is attached (`HardwareKeyboard.shared`; tests give their own).
    var hardwareKeyboard = HardwareKeyboard.shared
    /// The user brought the capsule's keys back while a hardware keyboard was attached (remembered).
    private(set) var keysShown: Bool
    /// The capsule's form: the six keys, or the small button that brings them back.
    var capsuleForm: TerminalAdaptation.CapsuleForm {
        TerminalAdaptation.capsuleForm(idiom: idiom, hardwareKeyboard: hardwareKeyboard.attached, shown: keysShown)
    }
    /// The capsule's last key collapses it instead of toggling the software keyboard (an iPad with a hardware one).
    var keysCanHide: Bool { idiom == .pad && hardwareKeyboard.attached }
    /// What the header shows (title, OSC 7 directory) and whether the terminal ended.
    var title: String? { presence.title }
    var directory: String? { presence.directory }
    var ended: TerminalFeedEvent? { presence.ended }

    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private let origin = ContinuousClock.now
    /// The clock the capsule's hold and repeat run on.
    @ObservationIgnored var now: () -> Duration

    static let fontSizeKey = "terminal.fontSize"
    static let keysShownKey = "terminal.keysShown"

    /// The font size of a terminal before any pinch or Settings choice: the device class's.
    static var defaultFontSize: Double { TerminalAdaptation.defaultFontSize(idiom: UIDevice.current.userInterfaceIdiom) }

    /// Shows a presence someone else keeps (Tabs, shared with Chat).
    convenience init(presence: TerminalPresence) { self.init(presence: presence, owns: false) }

    /// Shows a feed's terminal through a presence of its own.
    convenience init(feed: any TerminalFeed, scrollback: TerminalScrollback = .unknown,
                     configuration: TerminalConfiguration = TerminalController.storedConfiguration()) {
        self.init(presence: TerminalPresence(feed: feed, scrollback: scrollback, configuration: configuration), owns: true)
    }

    private init(presence: TerminalPresence, owns: Bool) {
        self.presence = presence
        ownsPresence = owns
        hostView = TerminalHostView(presence: presence)
        keysShown = UserDefaults.standard.bool(forKey: Self.keysShownKey)
        let origin = origin
        now = { ContinuousClock.now - origin }
        // A collapsed capsule's latches are not on screen: they modify nothing.
        hostView.pendingMods = { [weak self] in self.map { $0.capsuleForm == .full ? $0.capsule.mods : [] } ?? [] }
        hostView.onKeySent = { [weak self] in _ = self?.capsule.consume() }
        hostView.onFontSize = { size in UserDefaults.standard.set(size, forKey: Self.fontSizeKey) }
        hostView.onKeyboardFrame = { [weak self] frame in self?.keyboardChanged(frame) }
    }

    isolated deinit {
        timer?.cancel()
    }

    /// The configuration with the font size a pinch (or Settings) last chose, else the device class's default.
    static func storedConfiguration() -> TerminalConfiguration {
        var configuration = TerminalConfiguration()
        let stored = UserDefaults.standard.double(forKey: fontSizeKey)
        configuration.fontSize = TerminalConfiguration.fontSizes.contains(stored) ? stored : defaultFontSize
        return configuration
    }

    /// The segment is shown: the terminal is attached (a no-op when the presence already is), at the view's grid:
    /// before its first layout the attachment waits for it, so the first screen is never drawn for another size.
    func appear() {
        // With a hardware keyboard on an iPad the terminal takes the keys as soon as it shows, as a Mac's selected tab
        // does; no software keyboard comes up unasked (the hardware one hides it).
        if idiom == .pad, hardwareKeyboard.attached {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.hostView.window != nil, !self.hostView.isFirstResponder else { return }
                _ = self.hostView.becomeFirstResponder()
            }
        }
        guard !presence.attached else { return }
        if hostView.hasSize { presence.start() } else { hostView.onSized = { [weak self] in self?.presence.start() } }
    }

    /// The segment went away: an own presence stops observing; a shared one stays for Chat.
    func disappear() {
        hostView.onSized = nil
        if ownsPresence { presence.stop() }
        capsule.hideCluster()
        timer?.cancel()
        timer = nil
        _ = hostView.resignFirstResponder()
    }

    /// The keyboard layout guide's frame in the window (`TerminalHostView.keyboardTracker`): judged in the window, which
    /// in Split View or Stage Manager is not the screen.
    private func keyboardChanged(_ frame: CGRect?) {
        let next = hostView.window.map { TerminalAdaptation.keyboard(frame: frame, window: $0.bounds) } ?? .hidden
        if next != keyboard { keyboard = next }
    }

    /// The collapsed capsule's button: the six keys again, remembered while a hardware keyboard stays attached.
    func showKeys() {
        keysShown = true
        UserDefaults.standard.set(true, forKey: Self.keysShownKey)
    }

    /// The capsule's last key with a hardware keyboard: back to the small button, latches and the cluster released.
    func hideKeys() {
        keysShown = false
        UserDefaults.standard.set(false, forKey: Self.keysShownKey)
        capsule.reset()
        timer?.cancel()
        timer = nil
    }

    func tap(_ modifier: KeyCapsuleModel.Modifier) { capsule.tap(modifier, at: now()) }

    /// Esc or Tab: sent at once with the latched modifiers.
    func press(_ key: TerminalInputKey) {
        hostView.send(key)
        hostView.afterKey()
    }

    func dpadDown() {
        capsule.dpadDown(at: now())
        schedule()
    }

    func dpadDrag(over arrow: KeyCapsuleModel.Arrow?) {
        send(capsule.drag(over: arrow, at: now()))
        schedule()
    }

    func dpadUp() {
        capsule.dpadUp(at: now())
        schedule()
    }

    func clusterKeyDown(_ arrow: KeyCapsuleModel.Arrow) {
        send(capsule.keyDown(arrow, at: now()))
        schedule()
    }

    func clusterKeyUp() {
        capsule.keyUp()
        schedule()
    }

    private func send(_ arrows: [KeyCapsuleModel.Arrow]) {
        for arrow in arrows { hostView.send(KeyCapsuleModel.key(arrow)) }
        if !arrows.isEmpty { hostView.afterKey() }
    }

    /// Sleeps until the model's next deadline (the cluster's reveal, the next repeat) and advances it.
    private func schedule() {
        timer?.cancel()
        guard let deadline = capsule.nextDeadline else { timer = nil; return }
        let wait = max(.zero, deadline - now())
        timer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.send(self.capsule.advance(to: self.now()))
            self.schedule()
        }
    }

    /// The capsule's keyboard key: shows the software keyboard, or hides it while hardware keys and the capsule
    /// keep working.
    func toggleKeyboard() {
        if !hostView.isFirstResponder {
            hostView.softwareKeyboard = true
            _ = hostView.becomeFirstResponder()
        } else {
            hostView.softwareKeyboard = !keyboardVisible
        }
    }
}

/// The header's subtitle in Terminal (M6a, "mba2 · ~/src/app · zsh" after the host): the working directory with
/// the home folder as `~`, then the shell's name. Tabs supplies both (the topology's cwd, the shell it started);
/// the terminal's own OSC 7 directory (`TerminalController.directory`) is fresher when the shell reports it.
enum TerminalSubtitle {
    static func text(directory: String?, shell: String?, home: String? = nil) -> String {
        text(directory: directory, shell: shell, homes: HomePath(account: home))
    }

    /// The directory by the one "~" rule (`HomePath`), then the shell's name.
    static func text(directory: String?, shell: String?, homes: HomePath) -> String {
        var parts: [String] = []
        if let directory, !directory.isEmpty { parts.append(homes.abbreviate(directory)) }
        if let shell, !shell.isEmpty { parts.append(name(ofShell: shell)) }
        return parts.joined(separator: " · ")
    }

    /// `/bin/zsh`, `-zsh` (a login shell) or `zsh -l`: `zsh`.
    static func name(ofShell shell: String) -> String {
        let command = shell.split(separator: " ").first.map(String.init) ?? shell
        let last = command.split(separator: "/").last.map(String.init) ?? command
        return last.hasPrefix("-") ? String(last.dropFirst()) : last
    }

    /// OSC 7's `file://host/path` (percent-encoded) as a path; a plain path stays.
    static func path(fromWorkingDirectory value: String) -> String? {
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("/") { return value }
        guard let url = URL(string: value), url.scheme == "file" || url.scheme == "kitty-shell-cwd" else { return nil }
        let path = url.path(percentEncoded: false)
        return path.isEmpty ? nil : path
    }
}
