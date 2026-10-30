import Dictation
import Foundation

/// The Mac app's chat dictation (Packages/Dictation): one model store in Dispatch's support folder (Whisper/ and
/// Parakeet/), and one dictation at a time for every composer.
extension DictationModelStore {
    static let shared = DictationModelStore(whisper: Home.support.appendingPathComponent("Whisper"),
                                            parakeet: Home.support.appendingPathComponent("Parakeet"))
}

extension Dictation {
    static let shared = Dictation(models: .shared)
}

/// A chat's dictation into its draft. What it hears takes the selection's place as it comes (the composer shows it
/// muted and takes no typing meanwhile); cancelling or failing puts the draft back as it was. The microphone button and
/// the voice key shortcut both use it:
/// - one message (voice key held): stopping keeps the transcript, stopping with ↩ sends the draft;
/// - conversation mode (voice key tapped, or the button): it listens until stopped, and each utterance goes into the
///   draft as the speaker pauses. "Dispatch, send", "steer", "new line", "scratch that", "clear", "stop", "deny" and
///   "option 2" act on the chat, "Dispatch, billing" and the rest of VoiceNavigation move the window and the listening
///   with it (to the chat there, or commands only where there is none), and VoiceConversation reads replies aloud.
@MainActor @Observable
final class ChatDictation {
    static let shared = ChatDictation()

    struct Live {
        let session: UUID
        /// The draft dictated into, and its text and selection before the words being heard: what they are placed
        /// into each time.
        var draft: UUID
        var text: String
        var selection: NSRange
        /// The words being heard, in the draft.
        var heard: NSRange?
        /// Send the draft once the words being heard are in.
        var send = false
    }

    private(set) var live: Live?
    /// Listening continuously, following the active chat.
    private(set) var conversation = false
    /// Words being heard that start with "Dispatch": a command on its way, shown over the window, not in the draft.
    private(set) var command: String?
    /// What the conversation's utterances added to the draft, latest last ("scratch that").
    @ObservationIgnored private var added: [(draft: UUID, range: NSRange, text: String)] = []
    @ObservationIgnored private var token = System.uuid()
    @ObservationIgnored private var conversationNext = false

    private var chat: ChatCoordinator { TerminalRuntime.shared.chat }

    /// The dictated words in `session`'s draft while they are being heard.
    func provisional(_ session: UUID) -> NSRange? {
        guard let live, live.session == session else { return nil }
        if conversation { return live.heard }
        return live.heard ?? NSRange(location: live.selection.location, length: 0)
    }

    func dictating(_ session: UUID) -> Bool { live?.session == session }

    /// Whether typing in `session`'s composer would be overwritten: always while one message is dictated, and in
    /// conversation mode while words are being heard.
    func blocksTyping(_ session: UUID) -> Bool {
        guard let live, live.session == session else { return false }
        return !conversation || live.heard != nil
    }

    /// The microphone button: conversation mode on or off.
    func toggle(_ session: ChatSession) {
        if conversation || dictating(session.id) { stop(session) } else { startConversation(session) }
    }

    /// One message, into `session`'s draft.
    func start(_ session: ChatSession) {
        begin(session, continuous: false)
    }

    /// Conversation mode, from `session`'s chat, or commands only (nil).
    func startConversation(_ session: ChatSession?) {
        begin(session, continuous: true)
    }

    private func begin(_ session: ChatSession?, continuous: Bool) {
        // Another dictation ends first, putting its draft back.
        Dictation.shared.cancel()
        let token = System.uuid()
        self.token = token
        added = []
        conversation = continuous
        live = session.map(fresh)
        let preferences = TerminalRuntime.shared.preferences
        Dictation.shared.start(owner: owner, engine: preferences.dictationEngine, model: preferences.whisperModel,
                               continuous: continuous) { [weak self] update in
            guard let self, self.token == token else { return }
            self.receive(update)
        }
        if let session { session.focusRequest = System.uuid() }
        if continuous {
            VoiceNavigation.shared.startTracking()
            VoiceConversation.shared.began()
        }
    }

    /// Who the dictation is for: the chat, or commands only.
    private var owner: AnyHashable { live.map { AnyHashable($0.session) } ?? AnyHashable(VoiceNavigation.owner) }

    /// Stops: one message ends with its transcript (sent with `send`); conversation mode ends after the utterance being
    /// spoken. Before the microphone is on, it cancels.
    func stop(_ session: ChatSession? = nil, send: Bool = false) {
        if conversation, send {
            guard let session = session ?? live.flatMap({ chat.sessions[$0.session] }) else { return }
            // Mid-utterance, its words go first.
            if live?.heard != nil { live?.send = true } else { self.send(session) }
            return
        }
        guard conversation || session.map({ dictating($0.id) }) == true else { return }
        if send { live?.send = true }
        if Dictation.shared.phase == .listening { Dictation.shared.stop() }
        else if Dictation.shared.phase != .transcribing { Dictation.shared.cancel() }
    }

    func cancel() { Dictation.shared.cancel() }

    // MARK: What the dictation reports

    private func receive(_ update: DictationUpdate) {
        switch update {
        case .heard(let text):
            preview(text)
        case .utterance(let text):
            take(text)
        case .finished(let text):
            take(text)
            end()
        case .ended:
            withdraw()
            end()
        }
    }

    private func end() {
        let wasConversation = conversation
        let follow = conversationNext
        live = nil
        conversation = false
        command = nil
        conversationNext = false
        added = []
        if wasConversation { VoiceConversation.shared.ended() }
        if follow { startConversation(Self.activeChat()) }
    }

    /// The words being heard, in the draft in place of the selection (or after what the last utterance added).
    private func preview(_ text: String) {
        if VoiceCommand.addressed(text, wakeWords: DictationStore.shared.wakeWords) {
            withdraw()
            command = text
            return
        }
        command = nil
        guard let current = live, let session = chat.sessions[current.session] else { return }
        // A new utterance starts from the draft as it is now: typed between utterances, or moved to another draft.
        if current.heard == nil || session.drafts.current.id != current.draft { rebase(session) }
        guard let live else { return }
        let next = place(text, live: live)
        session.drafts.edit(text: next.text, selection: next.selection)
        self.live?.heard = text.isEmpty ? nil : next.heard
    }

    /// The draft as it was before the words being heard.
    private func withdraw() {
        guard let live, live.heard != nil, let session = chat.sessions[live.session],
              session.drafts.current.id == live.draft else { return }
        session.drafts.edit(text: live.text, selection: live.selection)
        self.live?.heard = nil
    }

    /// An utterance's transcript (or one message's): a command, words with a command after them, or words for the
    /// draft.
    private func take(_ transcript: String) {
        command = nil
        withdraw()
        let session = live.flatMap { chat.sessions[$0.session] }
        let send = live?.send == true
        live?.send = false
        defer { if send, let session { self.send(session) } }
        guard !transcript.isEmpty else { return }
        switch VoiceCommand.read(transcript, wakeWords: DictationStore.shared.wakeWords) {
        case .command(let command) where Self.chatCommand(command):
            perform(command, session)
            return
        case .command, .unrecognized:
            if DictationStore.shared.navigation, VoiceNavigation.shared.handle(transcript, fromChat: session != nil) {
                if conversation { follow() }
                return
            }
        case .text:
            break
        }
        if let (text, command) = VoiceCommand.trailing(transcript, wakeWords: DictationStore.shared.wakeWords) {
            if let session { insert(text, into: session) }
            perform(command, session)
            return
        }
        guard let session else {
            // Commands only here: say how to give one.
            _ = VoiceNavigation.shared.handle(transcript, fromChat: false)
            return
        }
        insert(transcript, into: session)
    }

    private func insert(_ text: String, into session: ChatSession) {
        rebase(session)
        guard let live else { return }
        let next = place(text, live: live)
        session.drafts.edit(text: next.text, selection: next.selection)
        added.append((live.draft, next.heard, (next.text as NSString).substring(with: next.heard)))
        rebase(session)
        session.focusRequest = System.uuid()
    }

    // MARK: Commands

    /// A chat command said where there is no chat (voice key held on a terminal): "Dispatch, listen" starts conversation
    /// mode, "Dispatch, quiet" stops reading; the rest need a chat. False when `transcript` is no chat command.
    func takeCommand(_ transcript: String) -> Bool {
        guard case .command(let command) = VoiceCommand.read(transcript, wakeWords: DictationStore.shared.wakeWords),
              Self.chatCommand(command) else { return false }
        if command == .listen { startConversation(Self.activeChat()) } else { perform(command, Self.activeChat()) }
        return true
    }

    static func chatCommand(_ command: VoiceCommand) -> Bool {
        switch command {
        case .send, .steer, .newLine, .scratch, .clear, .interrupt, .deny, .option, .listen, .stopListening, .readAgain, .quiet:
            true
        case .back, .step, .go, .named, .sidebar:
            false
        }
    }

    private func perform(_ command: VoiceCommand, _ session: ChatSession?) {
        let note = VoiceNavigation.shared
        switch command {
        case .listen:
            if !conversation { conversationNext = true }
            return
        case .stopListening:
            if conversation { stop() }
            return
        case .quiet:
            VoiceConversation.shared.quiet()
            return
        default:
            break
        }
        guard let session else { return note.show("No chat here: “Dispatch, …” switches spaces and tabs", failed: true) }
        switch command {
        case .send:
            send(session)
        case .steer:
            guard !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return note.show("Nothing to steer with", failed: true)
            }
            chat.sendNow(session)
            note.show("Steered", failed: false)
            added = []
        case .newLine:
            let draft = session.drafts.current
            let source = draft.text as NSString
            let at = min(NSMaxRange(draft.selection), source.length)
            let text = source.replacingCharacters(in: NSRange(location: draft.selection.location, length: at - draft.selection.location),
                                                  with: "\n")
            session.drafts.edit(text: text, multiline: true, selection: NSRange(location: draft.selection.location + 1, length: 0))
        case .scratch:
            let draft = session.drafts.current
            guard let last = added.last, last.draft == draft.id, NSMaxRange(last.range) <= (draft.text as NSString).length,
                  (draft.text as NSString).substring(with: last.range) == last.text else {
                return note.show("Nothing to scratch", failed: true)
            }
            added.removeLast()
            var range = last.range
            // The space the words came with.
            if range.location > 0, (draft.text as NSString).substring(with: NSRange(location: range.location - 1, length: 1)) == " " {
                range = NSRange(location: range.location - 1, length: range.length + 1)
            }
            session.drafts.edit(text: (draft.text as NSString).replacingCharacters(in: range, with: ""),
                                selection: NSRange(location: range.location, length: 0))
        case .clear:
            session.drafts.edit(text: "", selection: NSRange(location: 0, length: 0))
            added = []
        case .interrupt:
            note.show(chat.interrupt(session) ? "Stopped the agent" : "Nothing to stop", failed: false)
        case .deny:
            VoiceAnswers.deny(session)
        case .option(let number):
            VoiceAnswers.option(number, session)
        case .readAgain:
            VoiceConversation.shared.readLast(session)
        default:
            break
        }
        rebase(session)
    }

    private func send(_ session: ChatSession) {
        guard !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return VoiceNavigation.shared.show("Nothing to send", failed: true)
        }
        chat.sendFromComposer(session)
        added = []
        rebase(session)
        VoiceConversation.shared.cue(.sent)
    }

    // MARK: Following the window

    /// The chat the active pane shows, if any.
    static func activeChat() -> ChatSession? {
        let runtime = TerminalRuntime.shared
        guard let id = runtime.workspace?.activeSurfaceID, !runtime.files.isShowing(id),
              let session = runtime.chat.sessions[id], session.showChat else { return nil }
        return session
    }

    /// Conversation mode moves with the window: to the active pane's chat, or commands only.
    func follow() {
        guard conversation else { return }
        let target = Self.activeChat()
        guard target?.id != live?.session else { return }
        withdraw()
        added = []
        live = target.map(fresh)
        Dictation.shared.transfer(to: owner)
    }

    private func fresh(_ session: ChatSession) -> Live {
        let draft = session.drafts.current
        return Live(session: session.id, draft: draft.id, text: draft.text, selection: draft.selection)
    }

    /// Takes the draft as it is now as the base for the next words.
    private func rebase(_ session: ChatSession) {
        guard live?.session == session.id else { return }
        let draft = session.drafts.current
        live?.draft = draft.id
        live?.text = draft.text
        live?.selection = draft.selection
        live?.heard = nil
    }

    private func place(_ text: String, live: Live) -> (text: String, selection: NSRange, heard: NSRange) {
        let next = DictationText.insert(text, into: live.text, selection: live.selection)
        let length = (text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).length
        return (next.text, next.selection, NSRange(location: next.selection.location - length, length: length))
    }
}
