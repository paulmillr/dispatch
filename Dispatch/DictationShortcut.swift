import AppKit
import Dictation

/// Dictation from the keyboard (Settings › Dictation › Hold right ⌘), into the active chat, or on a terminal or files
/// pane as "Dispatch, …" commands only (VoiceNavigation, with Navigate by voice on):
/// - hold right ⌘ alone: listen while it is down; releasing it inserts the transcript (or runs the command), ↩ before
///   releasing sends the draft;
/// - tap it: conversation mode (ChatDictation) until the next tap: each utterance goes into the draft, ↩ sends and it
///   goes on listening;
/// - esc stops reading aloud, else cancels, putting the draft back (what conversation mode already added stays).
/// Right ⌘ with another key or a click is an ordinary chord: listening starts only once the key has been held alone for
/// a moment, so a chord never turns the microphone on.
@MainActor
final class DictationShortcut {
    /// kVK_RightCommand, and its device bit in the event's flags (NX_DEVICERCMDKEYMASK).
    static let rightCommand: UInt16 = 54
    static let rightCommandBit: UInt = 0x10
    /// Held this long alone, right ⌘ starts listening.
    static let hold: TimeInterval = 0.15
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
            // A click with right ⌘ down (⌘-click) is a chord.
            if let press, !press.started { abandon() }
            return event
        }
    }

    private func flagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags
        let rightDown = flags.rawValue & Self.rightCommandBit != 0
        guard event.keyCode == Self.rightCommand else {
            // Another modifier joined in before listening started: a chord.
            if let press, !press.started { abandon() }
            return
        }
        if rightDown {
            guard DictationStore.shared.enabled, DictationStore.shared.rightCommand,
                  flags.intersection([.shift, .control, .option, .function]).isEmpty,
                  // Left ⌘ is down too (NX_DEVICELCMDKEYMASK).
                  flags.rawValue & 0x08 == 0 else { return }
            let live = self.live
            guard let target = live ?? target() else { return }
            press = Press(at: event.timestamp, target: target, wasListening: live != nil)
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
