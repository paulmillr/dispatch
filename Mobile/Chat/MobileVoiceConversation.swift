@preconcurrency import AVFoundation
import Dictation
import Foundation
import Observation

/// Conversation mode (C5): hands-free chat with one conversation. The microphone listens continuously (`Dictation`,
/// cut into utterances at the speaker's pauses); what is said collects into a message that is sent when the user says
/// "send" (or "Dispatch, send", or ends a sentence with it) or pauses for `sendDelay`; the agent's reply is read aloud
/// once its turn ends, as are the requests and questions it stops for. Half-duplex, as the Mac's (`VoiceConversation`):
/// the microphone is ignored while it speaks, and it never speaks over an utterance being spoken. The chat commands
/// of the Dictation package (`VoiceCommand`: send, steer, new line, scratch that, clear, stop, deny, stop listening,
/// read that, quiet) work with or without the wake word; permission is never granted by voice. Listening and speaking
/// are protocols so the state machine runs in tests without audio.
@MainActor @Observable
final class MobileVoiceConversation {
    /// The app's one conversation mode (the Debug demo puts a scripted one in its place).
    static var shared = MobileVoiceConversation(listener: DictationVoiceListener(), speaker: SystemVoiceSpeaker())

    enum Phase: Equatable {
        case off
        case listening
        /// Reading a reply or request aloud; the microphone is muted.
        case speaking
    }

    private(set) var phase = Phase.off
    /// The conversation it talks with.
    private(set) weak var session: MobileChatSession?
    /// What the recognizer hears of the utterance being spoken.
    private(set) var heard = ""
    /// The utterances said since the last send: the message on its way.
    private(set) var message = ""
    /// The reply being read: its row and when reading began ("Reading aloud · 0:08").
    private(set) var reading: (row: String, since: Date)?
    /// What the last command did ("Sent", "Nothing to send"), until the next utterance.
    private(set) var note: String?
    /// Why listening stopped by itself (the microphone refused, a missing model).
    private(set) var failure: String?
    /// A pause this long after an utterance sends the message.
    @ObservationIgnored var sendDelay: Duration = .milliseconds(1600)
    /// How long after reading the microphone stays muted (the room's echo of the last words).
    @ObservationIgnored var echoDelay: Duration = .milliseconds(300)
    /// A partial with no newer one for this long is stale: well past the recognizer's pause (`Dictation.utterancePause`)
    /// and its transcription.
    @ObservationIgnored var heardTimeout: Duration = .milliseconds(2500)
    @ObservationIgnored private var heardExpiry: Task<Void, Never>?

    @ObservationIgnored private let listener: any VoiceListener
    @ObservationIgnored private let speaker: any VoiceSpeaker
    /// Replies, requests and questions already read (or there before listening began).
    @ObservationIgnored private var announced: Set<String> = []
    @ObservationIgnored private var queue: [(text: String, row: String?)] = []
    @ObservationIgnored private var pendingSend: Task<Void, Never>?
    @ObservationIgnored private var resumeListening: Task<Void, Never>?
    /// What each utterance added to `message`, for "scratch that".
    @ObservationIgnored private var added: [String] = []
    @ObservationIgnored private var run = 0

    init(listener: any VoiceListener, speaker: any VoiceSpeaker) {
        self.listener = listener
        self.speaker = speaker
    }

    var level: Float { listener.level }

    func active(for session: MobileChatSession) -> Bool { phase != .off && self.session === session }

    /// Conversation mode on for `session` (off for any other first).
    func start(_ session: MobileChatSession) {
        if phase != .off { stop() }
        run += 1
        let token = run
        self.session = session
        phase = .listening
        heard = ""; message = ""; note = nil; failure = nil; reading = nil; added = []; queue = []
        // What is already there was seen; only what comes next is read.
        announced = Set(Self.events(session).map(\.key))
        listener.start { [weak self] update in
            guard let self, self.run == token else { return }
            self.receive(update)
        }
    }

    /// Conversation mode off: listening and reading stop; words not sent yet go to the composer's draft.
    func stop() {
        guard phase != .off else { return }
        run += 1
        pendingSend?.cancel(); pendingSend = nil
        resumeListening?.cancel(); resumeListening = nil
        heardExpiry?.cancel(); heardExpiry = nil
        let unsent = (message + (heard.isEmpty ? "" : (message.isEmpty ? "" : " ") + heard)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !unsent.isEmpty, let session {
            let draft = session.drafts.current.text
            session.drafts.edit(text: draft.isEmpty ? unsent : draft + " " + unsent)
        }
        queue = []
        speaker.stop()
        listener.stop()
        phase = .off
        heard = ""; message = ""; reading = nil; added = []
        session = nil
    }

    // MARK: What it hears

    func receive(_ update: DictationUpdate) {
        switch update {
        case .heard(let text):
            heard = text
            heardExpiry?.cancel()
            if !text.isEmpty {
                pendingSend?.cancel(); pendingSend = nil; note = nil
                expireHeard()
            }
        case .utterance(let text):
            heard = ""
            heardExpiry?.cancel()
            take(text)
        case .finished(let text):
            // Continuous listening finishes only when it stops by itself (a long silence): conversation mode ends,
            // the words not sent going to the draft.
            heard = ""
            take(text)
            if phase != .off { stop() }
        case .ended:
            // The listener stopped by itself (refused, failed, a long silence): conversation mode ends.
            if phase != .off {
                failure = listener.error
                stop()
            }
        }
    }

    /// A partial the recognizer never finalizes (an utterance that turns out empty reports nothing) would hold back
    /// the send and the reading for ever: after `heardTimeout` without a newer partial it counts as finished silence.
    private func expireHeard() {
        let token = run, timeout = heardTimeout, partial = heard
        heardExpiry = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.run == token, self.heard == partial else { return }
            self.heard = ""
            self.scheduleSend()
            self.speakNext()
        }
    }

    private func take(_ transcript: String) {
        let transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return scheduleSend() }
        if let command = Self.command(transcript) { return perform(command) }
        if let (text, command) = VoiceCommand.trailing(transcript) {
            append(text)
            return perform(command)
        }
        // "Dispatch, …" that is no chat command (navigation, or words it does not know) is not part of the message.
        if case .text = VoiceCommand.read(transcript) {} else {
            note = "Not a chat command"
            return
        }
        append(transcript)
        scheduleSend()
    }

    /// A command said alone: "Dispatch, send", or the chat's words without the wake word ("send", "stop listening").
    static func command(_ transcript: String) -> VoiceCommand? {
        if case .command(let command) = VoiceCommand.read(transcript), chat(command) { return command }
        let words = VoiceMatch.words(transcript).filter { $0 != "please" }
        guard let command = VoiceCommand.phrases[words], chat(command) else { return nil }
        return command
    }

    private static func chat(_ command: VoiceCommand) -> Bool {
        switch command {
        case .send, .steer, .newLine, .scratch, .clear, .interrupt, .deny, .option, .listen, .stopListening, .readAgain, .quiet: true
        case .back, .step, .go, .named, .sidebar: false
        }
    }

    private func append(_ text: String) {
        let piece = message.isEmpty || message.hasSuffix("\n") ? text : " " + text
        message += piece
        added.append(piece)
        note = nil
    }

    private func scheduleSend() {
        pendingSend?.cancel()
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let delay = sendDelay
        pendingSend = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.heard.isEmpty else { return }
            self.send(steer: false)
        }
    }

    private func perform(_ command: VoiceCommand) {
        pendingSend?.cancel(); pendingSend = nil
        switch command {
        case .send: send(steer: false)
        case .steer: send(steer: true)
        case .newLine:
            message += "\n"; added.append("\n")
        case .scratch:
            guard let last = added.popLast(), message.hasSuffix(last) else { note = "Nothing to scratch"; return }
            message.removeLast(last.count)
            note = "Scratched"
        case .clear:
            message = ""; added = []; note = "Cleared"
        case .interrupt:
            session?.stop(); note = "Stopping"
        case .deny:
            deny()
        case .option:
            note = "Answer the question on screen"
        case .stopListening:
            stop()
        case .readAgain:
            readLast()
        case .quiet:
            quiet()
        case .listen, .back, .step, .go, .named, .sidebar:
            break
        }
    }

    private func send(steer: Bool) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session, !text.isEmpty else { note = "Nothing to send"; return }
        guard session.send(text: text, steer: steer) != nil else {
            note = session.failure ?? "Not sent"
            return
        }
        message = ""; added = []
        note = steer ? "Steered" : "Sent"
    }

    /// "Dispatch, deny": the agent's pending permission request is refused.
    private func deny() {
        guard let session, let approval = session.approvals.first(where: { $0.pending.pending }) else {
            note = "Nothing to deny"; return
        }
        if approval.pending.questions != nil { session.answer(approval, answers: nil) }
        else if let deny = MobileChatSession.choices(for: approval.interaction).first(where: { $0.role == .deny }) {
            session.answer(approval, with: deny)
        }
        note = "Denied"
    }

    // MARK: What it reads

    /// Looks for a reply, request or question not read yet (the thread calls it on every change of the conversation).
    func check() {
        guard phase != .off, let session else { return }
        for event in Self.events(session) where !announced.contains(event.key) {
            announced.insert(event.key)
            say(event.text, row: event.row)
        }
    }

    struct Event: Equatable {
        let key: String
        let text: String
        /// The reply's row, for the footnote under it.
        let row: String?
    }

    /// A finished reply, a pending permission request, an open question: what the agent waits on.
    static func events(_ session: MobileChatSession) -> [Event] {
        var events: [Event] = []
        if let approval = session.approvals.first(where: { $0.pending.pending }) {
            if let question = approval.pending.questions?.questions.first {
                let options = question.multiple ? "" : " " + question.options.enumerated()
                    .map { "Option \($0.offset + 1): \($0.element.label)." }.joined(separator: " ")
                events.append(Event(key: "question-" + approval.id.uuidString, text: bounded(question.text, 400) + options, row: nil))
            } else {
                let operation = approval.interaction.approvalPresentation.text
                events.append(Event(key: "waiting-" + approval.id.uuidString,
                                    text: "Permission needed: \(bounded(operation, 200)). Allow it on screen, or say deny.", row: nil))
            }
        }
        if let question = session.questions.first(where: { !$0.submitted }) {
            events.append(Event(key: "question-" + question.id, text: bounded(question.question.question, 400), row: nil))
        }
        // As the Mac's "response ready": an ended turn whose last word is the agent's.
        if !session.working, let turn = session.transcript.turns.last, turn.ended != nil,
           let row = session.transcript.rows.last(where: { $0.turnID == turn.id }), case .agent = row.kind,
           !row.item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            events.append(Event(key: "response-" + turn.id + ":" + row.id, text: spoken(row.item.text), row: row.id))
        }
        return events
    }

    /// The latest reply, again.
    func readLast() {
        guard let session, let row = session.transcript.rows.last(where: { if case .agent = $0.kind { true } else { false } }) else {
            note = "No reply to read"; return
        }
        say(Self.spoken(row.item.text), row: row.id)
    }

    /// Stops reading and drops what waits to be read.
    func quiet() {
        queue = []
        speaker.stop()
    }

    private func say(_ text: String, row: String?) {
        guard !text.isEmpty else { return }
        queue.append((text, row))
        speakNext()
    }

    private func speakNext() {
        guard phase == .listening, let next = queue.first else { return }
        // Never over the user: wait for the utterance being spoken to end.
        if !heard.isEmpty {
            let token = run
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.run == token else { return }
                self.speakNext()
            }
            return
        }
        queue.removeFirst()
        resumeListening?.cancel()
        phase = .speaking
        reading = next.row.map { ($0, Date()) }
        listener.mute(true)
        let token = run
        speaker.speak(next.text) { [weak self] in
            guard let self, self.run == token else { return }
            self.spoke()
        }
    }

    private func spoke() {
        reading = nil
        phase = .listening
        if !queue.isEmpty { return speakNext() }
        // The room's echo of the last words, before listening again.
        let token = run, delay = echoDelay
        resumeListening = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.run == token, self.phase == .listening else { return }
            self.listener.mute(false)
        }
    }

    /// A reply as words to say (the Mac's `VoiceConversation.spoken`): Markdown's marks gone, code blocks and tables
    /// named rather than read, long ones cut short.
    static func spoken(_ markdown: String) -> String {
        let blocks = ChatMarkdownBlock.parse(TextRendering.visible(markdown))
        let parts = blocks.compactMap { block -> String? in
            switch block.kind {
            case .rule: return nil
            case .code: return "There's a code block on screen."
            case .table: return "There's a table on screen."
            default:
                let value = try? AttributedString(markdown: block.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
                return value.map { String($0.characters) } ?? block.text
            }
        }
        return bounded(parts.joined(separator: "\n"), 1_500, more: " The rest is on screen.")
    }

    private static func bounded(_ text: String, _ limit: Int, more: String = "…") -> String {
        let prefix = TextRendering.prefix(text, scalars: limit)
        return prefix.text + (prefix.truncated ? more : "")
    }

    /// "0:08", "1:12": how long it has been reading.
    static func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

/// Where conversation mode's words come from.
@MainActor protocol VoiceListener: AnyObject {
    /// 0 to 1, for the listening bar's waveform.
    var level: Float { get }
    /// Why the last listening failed.
    var error: String? { get }
    /// Listens continuously until `stop`, reporting what it hears.
    func start(update: @escaping @MainActor (DictationUpdate) -> Void)
    /// Ignores the microphone (while speaking), or listens again.
    func mute(_ muted: Bool)
    func stop()
}

/// What reads aloud.
@MainActor protocol VoiceSpeaker: AnyObject {
    /// Speaks `text`, then calls `finished` (also when stopped).
    func speak(_ text: String, finished: @escaping @MainActor () -> Void)
    func stop()
}

/// The app's dictation, continuous, on an audio session that also plays (so replies can be read aloud: the
/// `.playAndRecord` category, through the speaker unless headphones are in; it plays whatever the silent switch says,
/// as a call does).
@MainActor final class DictationVoiceListener: VoiceListener {
    static let owner = "conversation-mode"
    private var dictation: Dictation { .shared }

    var level: Float { dictation.active(Self.owner) && !dictation.muted ? dictation.level : 0 }
    var error: String? { dictation.error(for: Self.owner) }

    func start(update: @escaping @MainActor (DictationUpdate) -> Void) {
        let choice = MobileSettings.dictation()
        dictation.start(owner: Self.owner, engine: choice.engine, model: choice.model, continuous: true, playback: true) { value in
            update(value)
        }
    }

    func mute(_ muted: Bool) { dictation.mute(muted) }

    func stop() { if dictation.active(Self.owner) { dictation.cancel() } }
}

/// Reads aloud with the system's voice.
@MainActor final class SystemVoiceSpeaker: NSObject, VoiceSpeaker, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var finished: (@MainActor () -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, finished: @escaping @MainActor () -> Void) {
        self.finished = finished
        synthesizer.speak(AVSpeechUtterance(string: text))
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) } else { done() }
    }

    private func done() {
        let finished = finished
        self.finished = nil
        finished?()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.done() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.done() }
    }
}
