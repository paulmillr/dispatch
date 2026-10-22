import AppKit
@preconcurrency import AVFoundation
import Dictation

/// What conversation mode (ChatDictation) does besides listening, so it works without looking:
/// - short sounds for listening on and off, a sent message, a command done and one that went nowhere;
/// - with Settings › Dictation › Read replies aloud: the reply of the chat it listens to, read aloud once its turn
///   ends, the request or question that chat's agent stops for, and a word when another chat's agent finishes or
///   needs you. The microphone is ignored while it speaks (it would hear itself), and it waits for the user to finish
///   an utterance before speaking. Esc, a tap of right ⌘ or "Dispatch, quiet" (said after it finishes) stop it;
/// - it stops listening while Dispatch isn't frontmost or the screen is locked, and listens again after.
@MainActor
final class VoiceConversation: NSObject {
    static let shared = VoiceConversation()

    enum Cue: String {
        case on = "Tink", off = "Bottle", sent = "Glass", done = "Pop", failed = "Funk"
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var queue: [String] = []
    private var speaking = false
    private var watching: Timer?
    /// The responses, requests and questions already announced (or there before listening started).
    private var announced: Set<String> = []
    private var paused = false
    private var locked = false

    override init() {
        super.init()
        synthesizer.delegate = self
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { VoiceConversation.shared.pause() }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { VoiceConversation.shared.resume() }
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                VoiceConversation.shared.locked = true
                VoiceConversation.shared.pause()
            }
        }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                VoiceConversation.shared.locked = false
                VoiceConversation.shared.resume()
            }
        }
    }

    private var conversing: Bool { ChatDictation.shared.conversation }
    private var reading: Bool { DictationStore.shared.readReplies }

    // MARK: Conversation mode

    func began() {
        paused = false
        cue(.on)
        // What is already there was seen; only what comes next is announced.
        announced = Set(TerminalRuntime.shared.chat.sessions.values.flatMap { events($0).map(\.key) })
        watching?.invalidate()
        watching = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { VoiceConversation.shared.watch() }
        }
    }

    func ended() {
        watching?.invalidate()
        watching = nil
        quiet()
        if !paused { cue(.off) }
    }

    private func pause() {
        guard conversing else { return }
        paused = true
        ChatDictation.shared.stop()
        VoiceNavigation.shared.show("Conversation paused: Dispatch isn't in front", failed: false)
    }

    private func resume() {
        guard paused, NSApp.isActive, !locked, !conversing, DictationStore.shared.enabled else { return }
        paused = false
        ChatDictation.shared.startConversation(ChatDictation.activeChat())
    }

    func cue(_ cue: Cue) {
        guard conversing || cue == .off else { return }
        guard let sound = NSSound(named: cue.rawValue)?.copy() as? NSSound else { return }
        sound.volume = 0.35
        sound.play()
    }

    // MARK: Reading aloud

    /// The latest reply of `session`, again.
    func readLast(_ session: ChatSession) {
        guard let reply = session.turns.last(where: { $0.ended != nil })?.items.last(where: { $0.kind == .assistant })?.text,
              !reply.isEmpty else {
            return VoiceNavigation.shared.show("No reply to read", failed: true)
        }
        say(Self.spoken(reply))
    }

    /// Stops reading, and drops what was waiting to be read.
    var isSpeaking: Bool { speaking || !queue.isEmpty }

    func quiet() {
        queue = []
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    private func say(_ text: String) {
        guard !text.isEmpty else { return }
        queue.append(text)
        speakNext()
    }

    private func speakNext() {
        guard !speaking, let next = queue.first else { return }
        // Never over the user: wait for the utterance being spoken to end.
        if Dictation.shared.partial.isEmpty == false || ChatDictation.shared.live?.heard != nil {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.speakNext()
            }
            return
        }
        queue.removeFirst()
        speaking = true
        Dictation.shared.mute(true)
        synthesizer.speak(AVSpeechUtterance(string: next))
    }

    private func spoke() {
        speaking = false
        if !queue.isEmpty { return speakNext() }
        // The room's echo of the last words, before listening again.
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            if !self.speaking { Dictation.shared.mute(false) }
        }
    }

    // MARK: What agents do meanwhile

    private struct Event {
        let key: String
        let session: ChatSession
        enum Kind { case reply(String), permission(String), question(String, [String]) }
        let kind: Kind
    }

    private func watch() {
        guard conversing else { return }
        for session in TerminalRuntime.shared.chat.sessions.values {
            for event in events(session) where !announced.contains(event.key) {
                announced.insert(event.key)
                if reading { announce(event) }
            }
        }
    }

    /// A finished reply, a pending permission request, an open question: what `session`'s agent waits on.
    private func events(_ session: ChatSession) -> [Event] {
        var events: [Event] = []
        if let approval = session.approvals.first(where: \.pending) {
            if let question = approval.questions?.questions.first {
                events.append(Event(key: "question-" + approval.id.uuidString, session: session,
                                    kind: .question(question.text, question.multiple ? [] : question.options.map(\.label))))
            } else {
                events.append(Event(key: "waiting-" + approval.id.uuidString, session: session, kind: .permission(approval.operation)))
            }
        }
        if let question = session.questions.first(where: { !$0.submitted }) {
            let options = question.question.multiple ? [] : (question.question.options ?? []).map(\.label)
            events.append(Event(key: "question-" + question.id, session: session, kind: .question(question.question.question, options)))
        }
        // As Attention's "response ready": an ended turn whose last word is the agent's.
        if session.active, !session.busy, !session.awaitingPromptAck, session.submissionID == nil, session.interruptionID == nil,
           let turn = session.turns.last, turn.ended != nil, session.activeTurnID == nil || session.activeTurnID == turn.id,
           let response = turn.items.last(where: { $0.kind != .notice }), response.kind == .assistant,
           !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            events.append(Event(key: "response-" + session.id.uuidString + ":" + turn.id, session: session, kind: .reply(response.text)))
        }
        return events
    }

    private func announce(_ event: Event) {
        let here = ChatDictation.shared.live?.session == event.session.id
        let name = Self.name(of: event.session)
        switch event.kind {
        case .reply(let text):
            say(here ? Self.spoken(text) : "\(name) finished.")
        case .permission(let operation):
            say(here ? "Permission needed: \(Self.bounded(operation, 200)). Say Dispatch, deny, or allow it on screen."
                : "\(name) needs permission.")
        case .question(let text, let options):
            guard here else { return say("\(name) has a question.") }
            let choices = options.enumerated().map { "Option \($0.offset + 1): \($0.element)." }.joined(separator: " ")
            say(Self.bounded(text, 400) + " " + choices)
        }
    }

    /// A chat's space, and its tab when the space has several: "billing", "billing, claude".
    private static func name(of session: ChatSession) -> String {
        guard let workspace = TerminalRuntime.shared.workspace,
              let space = workspace.presentationSpaces.first(where: { $0.tabs.contains { $0.surfaceIDs.contains(session.id) } }) else {
            return session.agentTitle
        }
        let tab = space.tabs.first { $0.surfaceIDs.contains(session.id) }
        return space.tabs.count > 1 ? "\(space.name), \(tab?.label ?? session.agentTitle)" : space.name
    }

    /// A reply as words to say: Markdown's marks gone, code blocks named rather than read, long ones cut short.
    static func spoken(_ markdown: String) -> String {
        let blocks = ChatMarkdownBlock.parse(TextRendering.visible(markdown))
        let parts = blocks.compactMap { block -> String? in
            let source: String
            switch block.kind {
            case .rule: return nil
            case .code: return "There's a code block on screen."
            case .table: return "There's a table on screen."
            default: source = block.text
            }
            let value = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            return value.map { String($0.characters) } ?? source
        }
        return bounded(parts.joined(separator: "\n"), 1_500, more: " The rest is on screen.")
    }

    private static func bounded(_ text: String, _ limit: Int, more: String = "…") -> String {
        let prefix = TextRendering.prefix(text, scalars: limit)
        return prefix.text + (prefix.truncated ? more : "")
    }
}

extension VoiceConversation: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in VoiceConversation.shared.spoke() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in VoiceConversation.shared.spoke() }
    }
}

/// "Dispatch, deny" and "Dispatch, option 2": the agent's pending request or question in a chat. Permission is never
/// granted by voice.
@MainActor
enum VoiceAnswers {
    private static var note: VoiceNavigation { .shared }

    static func deny(_ session: ChatSession) {
        if let approval = session.approvals.first(where: \.pending) {
            approval.resolve(.deny)
            return note.show(approval.questions == nil ? "Denied" : "Skipped the question", failed: false)
        }
        if let question = session.questions.first(where: { !$0.submitted }) {
            TerminalRuntime.shared.chat.answerQuestion(question, skip: true, session: session)
            return note.show("Skipped the question", failed: false)
        }
        note.show("Nothing to deny", failed: true)
    }

    static func option(_ number: Int, _ session: ChatSession) {
        if let approval = session.approvals.first(where: \.pending) {
            guard let draft = approval.questionDraft else {
                return note.show("Allow a permission request on screen; “Dispatch, deny” refuses it", failed: true)
            }
            let question = draft.question
            guard !question.multiple else { return note.show("Choose several options on screen", failed: true) }
            guard question.options.indices.contains(number - 1) else { return note.show("There is no option \(number)", failed: true) }
            let label = question.options[number - 1].label
            draft.select(label)
            if draft.index + 1 < draft.questionnaire.questions.count {
                draft.next()
                return note.show("“\(label)” · next question", failed: false)
            }
            guard draft.questionnaire.accepts(draft.answers) else { return note.show("Answer the rest on screen", failed: true) }
            approval.answer(draft.answers)
            return note.show("Answered “\(label)”", failed: false)
        }
        guard let question = session.questions.first(where: { !$0.submitted }) else {
            return note.show("No question to answer", failed: true)
        }
        let options = question.question.options ?? []
        guard !question.question.multiple else { return note.show("Choose several options on screen", failed: true) }
        guard options.indices.contains(number - 1) else { return note.show("There is no option \(number)", failed: true) }
        let label = options[number - 1].label
        question.select(label)
        if question.index + 1 < question.questions.count {
            question.index += 1
            return note.show("“\(label)” · next question", failed: false)
        }
        guard question.complete else { return note.show("Answer the rest on screen", failed: true) }
        TerminalRuntime.shared.chat.answerQuestion(question, skip: false, session: session)
        note.show("Answered “\(label)”", failed: false)
    }
}
