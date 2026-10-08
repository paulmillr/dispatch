import Foundation
import Observation

enum ChatSideMode: String {
    case btw, side
    var readOnly: Bool { self == .btw }
    static func parse(_ text: String) -> (mode: Self, question: String)? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let name = parts.first, let mode = Self(rawValue: String(name.dropFirst())), name.first == "/" else { return nil }
        return (mode, parts.count > 1 ? String(parts[1]) : "")
    }
    static let boundary = "You are in a separate side conversation. The inherited thread is reference context only. Do not continue its task or goal. Answer only new messages in this side conversation. Do not interact with the main thread or its agents."

    /// Read-only forks also remove environment tools, apps, MCP servers and
    /// delegation. A prompt alone is not a permissions boundary.

}

struct ChatSidePermission: Equatable {
    let title: String
    let operation: String
    let language: String
}

@MainActor @Observable
final class ChatSideConversation: Identifiable {
    struct Message: Identifiable {
        let id: String
        let user: Bool
        var text: String
    }
    let id = UUID()
    let mode: ChatSideMode
    let parentID: String
    let agentID: String
    /// Helper-provided agent name; the opaque key is not shown.
    var title: String?
    var messages: [Message] = []
    var draft = "" {
        didSet { if draft.contains("\n") || draft.contains("\r") { draftMultiline = true } }
    }
    var draftMultiline = false
    var draftSelection = NSRange(location: 0, length: 0)
    var composerHeight: CGFloat = 28
    var composingText = false
    var busy = false
    var ready = false
    var failure: String?
    var permission: ChatSidePermission?
    var questions: [ChatSideQuestion] = []
    var hasQuestions: Bool { !questions.isEmpty || permission != nil }
    var waitingForAnswer: Bool { questions.contains { $0.blocking && !$0.submitted } }
    var steps = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    var model: String
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var parent: HelperChat?
    @ObservationIgnored private var helper: HelperChat?
    @ObservationIgnored private var interaction: HelperChat.Interaction?

    init(mode: ChatSideMode, parentID: String, agentID: String, model: String) {
        self.mode = mode; self.parentID = parentID; self.agentID = agentID; self.model = model
    }

    func send() {
        sendHelper()
    }

    private func append(id: String, text: String, replace: Bool) {
        guard text.utf8.count <= 1_048_576 else { failure = "Side reply exceeded the display limit."; close(); return }
        if let index = messages.firstIndex(where: { $0.id == id }) {
            if replace { messages[index].text = text }
            else if messages[index].text.utf8.count + text.utf8.count <= 1_048_576 { messages[index].text += text }
        } else { messages.append(.init(id: id, user: false, text: text)) }
    }

    func answerQuestion(_ question: ChatSideQuestion, skip: Bool = false) {
        answerHelper(question, skip: skip)
    }

    private func clearQuestions() {
        questions.forEach { $0.clearAnswers() }
        questions.removeAll()
    }

    func resolvePermission(_ allow: Bool) {
        guard let helper, let interaction, let question = interaction.questions.first else { return }
        // Read-only side chats never allow; option 0 allows, 1 denies.
        var input = HelperChat.Input(helper.route)
        input.interaction = interaction.id
        input.answers = [question.id: .options([allow && !mode.readOnly ? 0 : 1])]
        clearPermission()
        call("interactions.answer", input)
    }

    private func clearPermission() {
        permission = nil; interaction = nil
    }

    func close() {
        guard !closed else { return }
        closed = true; task?.cancel(); task = nil; ready = false; busy = false
        helper?.close(); helper = nil
        if let parent {
            let route = parent.route
            Task { let _: HelperClient.Empty? = try? await parent.call("chat.side.close", input: .init(route)) }
            self.parent = nil
        }
        messages = []; draft = ""; draftMultiline = false; composingText = false
        draftSelection = NSRange(location: 0, length: 0)
        clearQuestions()
        clearPermission()
    }
}

// Side chat through the helper: chat.side opens a binding that is read and answered like any chat.
extension ChatSideConversation {
    func start(helper parent: HelperChat, question: String) {
        self.parent = parent
        messages.append(.init(id: "pending-" + UUID().uuidString, user: true, text: question))
        busy = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let side = try await parent.side(question: question, readOnly: mode.readOnly)
                guard !closed else { side.close(); return }
                helper = side
                side.receive = { [weak self] in self?.receive($0) }
                side.failed = { [weak self] error in self?.failure = error.localizedDescription; self?.busy = false }
                try await side.open()
                ready = true
            } catch {
                guard !closed else { return }
                failure = error.localizedDescription; busy = false
            }
        }
    }

    func receive(_ event: HelperChat.Event) {
        guard !closed else { return }
        switch event {
        case .history(let chat):
            apply(chat.records)
            if let state = chat.state { busy = state.busy }
        case .replacement(let page):
            messages = []
            apply(page.records)
        case .page(let page), .archive(let page): apply(page.records)
        case .records(let records): apply(records)
        case .state(let state): busy = state.busy
        case .interaction(let value): receive(value)
        case .queue: break
        case .exit: failure = "The agent exited."; busy = false; ready = false
        }
    }

    /// User and assistant text only; a user record replaces the pending copy of its text.
    private func apply(_ records: [HelperChat.Record]) {
        for record in records where record.kind == "user" || record.kind == "assistant" {
            let user = record.kind == "user"
            if user { messages.removeAll { $0.id.hasPrefix("pending-") && $0.text == record.text } }
            if let index = messages.firstIndex(where: { $0.id == record.id }) { messages[index].text = record.text }
            else { messages.append(.init(id: record.id, user: user, text: record.text)) }
        }
    }

    private func receive(_ value: HelperChat.Interaction) {
        if value.questions.isEmpty {
            if interaction?.id == value.id { clearPermission() }
            questions.removeAll { $0.id == value.id }
            return
        }
        if let display = value.permission {
            interaction = value; permission = display
        } else if let session = helper?.route.session, !questions.contains(where: { $0.id == value.id }),
                  let question = ChatSideQuestion(interaction: value, session: session) {
            questions.append(question)
        }
    }

    private func sendHelper() {
        guard ready, !busy, !hasQuestions, !closed, let helper else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 1_048_576 else { return }
        messages.append(.init(id: "pending-" + UUID().uuidString, user: true, text: text))
        draft = ""; draftMultiline = false; draftSelection = NSRange(location: 0, length: 0)
        busy = true; failure = nil
        var input = HelperChat.Input(helper.route)
        input.text = text; input.mode = "prompt"; input.command = false
        call("chat.send", input) { [weak self] in
            guard let self, draft.isEmpty else { return }
            draft = text
        }
    }

    private func answerHelper(_ question: ChatSideQuestion, skip: Bool) {
        guard !closed, ready, let helper, questions.contains(where: { $0 === question }),
              !question.submitted, skip || question.complete else { return }
        var input = HelperChat.Input(helper.route)
        input.interaction = question.id
        input.answers = skip ? Dictionary(uniqueKeysWithValues: question.questions.map { ($0.id, .skip) }) : question.answers
        question.submitted = true
        messages.append(.init(id: UUID().uuidString, user: true, text: question.summary(skip: skip)))
        question.clearAnswers()
        call("interactions.answer", input)
    }

    /// One user action on the side binding; failure shows in the sheet and runs `failed`.
    private func call(_ method: String, _ input: HelperChat.Input, failed: (() -> Void)? = nil) {
        guard let helper = helper ?? parent else { return }
        Task { [weak self] in
            do {
                let sent: HelperChat.Sent = try await helper.call(method, input: input)
                try sent.confirmed()
            } catch {
                guard let self, !closed else { return }
                self.failure = error.localizedDescription; self.busy = false
                failed?()
            }
        }
    }
}

extension ChatCoordinator {
    @discardableResult
    func openSideConversation(_ mode: ChatSideMode, question: String, session: ChatSession, consumeDraft: Bool = true) -> Bool {
        guard enabled, sessions[session.id] === session, session.active, session.sideConversation == nil,
              !session.inputBlocked, !session.reviewing, session.command == nil, session.submissionID == nil, session.modelPicker == nil,
              session.nativePrompt == nil, session.commandEditor == nil, !session.nativeInputInFlight,
              !session.loadingHistory, !session.approvals.contains(where: \.pending),
              let parent = session.sessionID, let helper = session.helper else { return false }
        let side = ChatSideConversation(mode: mode, parentID: parent, agentID: session.agentID, model: session.model)
        side.title = session.agentTitle
        session.sideConversation = side
        if consumeDraft { session.clearDraft() }
        side.start(helper: helper, question: question)
        return true
    }

    func closeSideConversation(_ session: ChatSession) {
        session.sideConversation?.close(); session.sideConversation = nil
        session.focusRequest = UUID()
    }
}
