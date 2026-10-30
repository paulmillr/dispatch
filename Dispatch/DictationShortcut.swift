import AppKit
import Dictation

/// Dictation from the keyboard (Settings › Keyboard › Voice: right ⌘ unless another key is chosen), into the active
/// chat, or on a terminal or files pane as "Dispatch, …" commands only (VoiceNavigation, with Navigate by voice on):
/// - hold the key alone: listen while it is down; releasing it inserts the transcript (or runs the command), ↩ before
///   releasing sends the draft;
/// - tap it: conversation mode (ChatDictation) until the next tap: each utterance goes into the draft, ↩ sends and it
///   goes on listening;
/// - esc stops reading aloud, else cancels, putting the draft back (what conversation mode already added stays).
/// The key with another key or a click is an ordinary chord: listening starts only once the key has been held alone for
/// a moment, so a chord never turns the microphone on.
@MainActor
final class DictationShortcut {
    /// Held this long alone, the key starts listening. Longer than a chord takes to reach its key (⌘/ came in at
    /// 0.15 s and turned the microphone on before the / cancelled it).
    static let hold: TimeInterval = 0.3
    /// Released sooner than this, it was a tap: listening goes on hands-free.
    static let tap: TimeInterval = 0.4

    /// What the shortcut dictates into.
    enum Target {
        case chat(ChatSession)
        /// Commands only: the frontmost pane has no chat.
        case commands
        /// Conversation mode, wherever it listens.
        case conversation

        /// Held: one message (or one command).
        @MainActor func start() {
            switch self {
            case .chat(let session): ChatDictation.shared.start(session)
            case .commands: VoiceNavigation.shared.listen()
            case .conversation: break
            }
        }

        /// Tapped: conversation mode.
        @MainActor func converse() {
            switch self {
            case .chat(let session): ChatDictation.shared.startConversation(session)
            case .commands: ChatDictation.shared.startConversation(nil)
            case .conversation: break
            }
        }

        /// Conversation mode sends with `send` and goes on listening.
        @MainActor func stop(send: Bool = false) {
            switch self {
            case .chat(let session): ChatDictation.shared.stop(session, send: send)
            case .commands: VoiceNavigation.shared.stopListening()
            case .conversation: ChatDictation.shared.stop(send: send)
            }
        }
    }

    /// The frontmost pane's target, if the main window is frontmost.
    private let target: () -> Target?
    private var monitor: Any?
    private var press: Press?
    private var holdTimer: DispatchWorkItem?

    private struct Press {
        let at: TimeInterval
        /// The voice key pressed: a release still ends it if Settings chose another meanwhile.
        let key: VoiceKey
        let target: Target
        /// It started this dictation (rather than stopping one already listening).
        var started = false
        let wasListening: Bool
    }

    init(target: @escaping () -> Target?) {
        self.target = target
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func invalidate() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        abandon()
    }

    /// The dictation listening or transcribing now, if the shortcut's.
    private var live: Target? {
        if ChatDictation.shared.conversation { return .conversation }
        if let live = ChatDictation.shared.live, let session = TerminalRuntime.shared.chat.sessions[live.session] {
            return .chat(session)
        }
        return VoiceNavigation.shared.listening ? .commands : nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            flagsChanged(event)
            return event
        case .keyDown:
            return keyDown(event)
        default:
            // A click with the key down (⌘-click) is a chord.
            if let press, !press.started { abandon() }
            return event
        }
    }

    private func flagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags
        guard let key = press?.key ?? DictationStore.shared.shortcut, event.keyCode == key.keyCode else {
            // Another modifier joined in before listening started: a chord.
            if let press, !press.started { abandon() }
            return
        }
        if key.isDown(flags) {
            guard key.alone(flags) else { return }
            let live = self.live
            guard let target = live ?? target() else { return }
            press = Press(at: event.timestamp, key: key, target: target, wasListening: live != nil)
            guard live == nil else { return }
            let preferences = TerminalRuntime.shared.preferences
            Dictation.shared.prepare(engine: preferences.dictationEngine, model: preferences.whisperModel)
            let timer = DispatchWorkItem { [weak self] in self?.held() }
            holdTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hold, execute: timer)
        } else if let press {
            holdTimer?.cancel()
            holdTimer = nil
            self.press = nil
            let tapped = event.timestamp - press.at < Self.tap
            if press.wasListening {
                // A tap while it reads aloud only stops the reading.
                if tapped, VoiceConversation.shared.isSpeaking { VoiceConversation.shared.quiet() } else { press.target.stop() }
            } else if !press.started {
                // Released before listening started: a tap, so conversation mode until the next one.
                if tapped { press.target.converse() }
            } else if tapped {
                // Held only briefly: the one message becomes a conversation.
                Dictation.shared.cancel()
                press.target.converse()
            } else {
                press.target.stop()
            }
        }
    }

    private func held() {
        guard var press, !press.started, !press.wasListening else { return }
        holdTimer = nil
        press.started = true
        self.press = press
        press.target.start()
    }

    private func keyDown(_ event: NSEvent) -> NSEvent? {
        if let press, !press.started, !press.wasListening {
            abandon()
            return event
        }
        guard let live else { return event }
        // Held or hands-free, ↩ and esc belong to the dictation of the pane on screen; elsewhere they are typing.
        switch (live, target()) {
        case (_, _) where press != nil: break
        case (.chat(let session), .chat(let frontmost)) where session === frontmost: break
        case (.commands, .some): break
        // Conversation mode takes them only in the chat it listens to: a terminal keeps its ↩ and esc.
        case (.conversation, .chat(let frontmost)) where ChatDictation.shared.live?.session == frontmost.id: break
        default: return event
        }
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if (event.keyCode == 36 || event.keyCode == 76), flags.isEmpty || flags == .command {
            press = nil
            live.stop(send: true)
            return nil
        }
        if event.keyCode == 53, flags.isEmpty || flags == .command {
            press = nil
            // Reading aloud stops first; the next esc ends the dictation.
            if VoiceConversation.shared.isSpeaking { VoiceConversation.shared.quiet() } else { Dictation.shared.cancel() }
            return nil
        }
        if press != nil {
            // Another ⌘ chord while holding to talk: the hold was for that, not for dictation.
            press = nil
            Dictation.shared.cancel()
        }
        return event
    }

    private func abandon() {
        holdTimer?.cancel()
        holdTimer = nil
        press = nil
    }
}

/// The voice key in modifier events: its key code, whether it is down, and whether it is the only modifier down.
extension VoiceKey {
    /// kVK_RightCommand, kVK_RightOption, kVK_Function.
    var keyCode: UInt16? {
        switch self {
        case .rightCommand: 54
        case .rightOption: 61
        case .function: 63
        case .off: nil
        }
    }

    /// The right-hand keys by their device bits (NX_DEVICERCMDKEYMASK, NX_DEVICERALTKEYMASK): the other side's
    /// key sets the same modifier.
    func isDown(_ flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .rightCommand: flags.rawValue & 0x10 != 0
        case .rightOption: flags.rawValue & 0x40 != 0
        case .function: flags.contains(.function)
        case .off: false
        }
    }

    /// No other modifier is down, the same one on the other side included (NX_DEVICELCMDKEYMASK, NX_DEVICELALTKEYMASK).
    func alone(_ flags: NSEvent.ModifierFlags) -> Bool {
        let all: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .function]
        switch self {
        case .rightCommand: return flags.intersection(all.subtracting(.command)).isEmpty && flags.rawValue & 0x08 == 0
        case .rightOption: return flags.intersection(all.subtracting(.option)).isEmpty && flags.rawValue & 0x20 == 0
        case .function: return flags.intersection(all.subtracting(.function)).isEmpty
        case .off: return false
        }
    }
}
