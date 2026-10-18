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
    /// The software keyboard is on screen.
    private(set) var keyboardVisible = false
    /// What the header shows (title, OSC 7 directory) and whether the terminal ended.
    var title: String? { presence.title }
    var directory: String? { presence.directory }
    var ended: TerminalFeedEvent? { presence.ended }

    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private let origin = ContinuousClock.now
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The clock the capsule's hold and repeat run on.
    @ObservationIgnored var now: () -> Duration

    static let fontSizeKey = "terminal.fontSize"

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
        let origin = origin
        now = { ContinuousClock.now - origin }
        hostView.pendingMods = { [weak self] in self?.capsule.mods ?? [] }
        hostView.onKeySent = { [weak self] in _ = self?.capsule.consume() }
        hostView.onFontSize = { size in UserDefaults.standard.set(size, forKey: Self.fontSizeKey) }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated { self?.keyboardChanged(frame) }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardChanged(nil) }
        })
    }

    isolated deinit {
        timer?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// The configuration with the font size a pinch last chose.
    static func storedConfiguration() -> TerminalConfiguration {
        var configuration = TerminalConfiguration()
        let stored = UserDefaults.standard.double(forKey: fontSizeKey)
        if TerminalConfiguration.fontSizes.contains(stored) { configuration.fontSize = stored }
        return configuration
    }

    /// The segment is shown: the terminal is attached (a no-op when the presence already is), at the view's grid:
    /// before its first layout the attachment waits for it, so the first screen is never drawn for another size.
    func appear() {
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

    private func keyboardChanged(_ frame: CGRect?) {
        guard let frame, let screen = hostView.window?.windowScene?.screen else { keyboardVisible = false; return }
        keyboardVisible = frame.height > 120 && frame.minY < screen.bounds.maxY - 1
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
