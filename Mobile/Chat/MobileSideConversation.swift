import Foundation
import Observation

/// A side conversation (C3), `/btw` (read-only) or `/side` (full permissions): a fork of the main conversation the
/// helper starts with the first question (`chat.side {question, read_only}`, PROTOCOL.md), read and driven as a chat of
/// its own on the same terminal under the fork's session (`chat.open`, `chat.send`), and ended with `chat.side.close`,
/// which ends the fork's process. Its replies never enter the main thread; "Bring into main thread" quotes the last one
/// into the main composer. It belongs to the main conversation's connection: a lost link or a new helper ends it.
@MainActor @Observable
final class MobileSideConversation: Identifiable {
    let id = UUID()
    let mode: ChatSideMode
    /// The first question (also what "Allow changes" asks again, writable); nil until one is asked.
    private(set) var question: String?
    private(set) var transcript = MobileTranscript()
    /// Questions sent and not yet in the fork's transcript, in order.
    private(set) var pending: [ChatItem] = []
    private(set) var busy = false
    /// The fork's session once the helper started it.
    private(set) var session: String?
    private(set) var ended = false
    /// A permission request of the fork (a /side's edit or command): answered here; a /btw's is always refused.
    private(set) var permission: (interaction: HelperChat.Interaction, display: ChatSidePermission)?
    var failure: String?
    /// The side composer's text.
    var draft = ""

    @ObservationIgnored private weak var parent: MobileChatSession?
    @ObservationIgnored private let client: HelperClient
    @ObservationIgnored private let terminal: UInt64
    @ObservationIgnored private let parentSession: String?
    @ObservationIgnored private var observation: UInt64?
    /// False once the link went: ending sends nothing.
    @ObservationIgnored private var connected = true
    /// The helper started a fork with this session (the main conversation remembers it until it is closed).
    @ObservationIgnored var forked: @MainActor (String) -> Void = { _ in }
    /// The helper closed the fork with this session.
    @ObservationIgnored var closed: (@MainActor (String) -> Void)?

    var readOnly: Bool { mode.readOnly }
    var title: String { mode.rawValue }

    /// The fork's rows, then the questions on their way.
    var rows: [ChatThreadRow] { transcript.rows }

    /// The newest answer, for "Bring into main thread" and Copy.
    var lastAnswer: String? { transcript.lastAgentItem?.text }

    /// Nil when the main conversation cannot take a side question now (no live, verified binding).
    init?(mode: ChatSideMode, parent: MobileChatSession) {
        guard parent.phase == .verified, let client = parent.client, let terminal = parent.terminal else { return nil }
        self.mode = mode
        self.parent = parent
        self.client = client
        self.terminal = terminal
        parentSession = parent.conversation
    }

    /// Starts the fork with the first question.
    func start(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.question == nil, !question.isEmpty, !ended else { return }
        self.question = question
        busy = true
        failure = nil
        appendPending(question)
        var input = HelperChat.Input(HelperChat.Route(terminal: terminal, session: parentSession))
        input.question = question
        input.read_only = mode.readOnly
        let connection = client.connection, terminal = terminal
        let forked = self.forked
        // The fork is never abandoned mid-start: `end()` does not cancel this request, and a fork that answers after
        // the user ended the side conversation (or after this object is gone) is closed at once.
        Task { [weak self] in
            let binding: HelperTopology.Binding
            do {
                binding = try await connection.request("chat.side", params: input)
            } catch {
                guard let self, !self.ended else { return }
                self.failure = error.localizedDescription
                self.busy = false
                return
            }
            forked(binding.session)
            guard let self, !self.ended else {
                if self?.connected ?? true {
                    Self.close(connection, terminal: terminal, session: binding.session, closed: self?.closed)
                }
                return
            }
            self.session = binding.session
            do {
                try await self.open(connection, session: binding.session)
            } catch {
                guard !self.ended else { return }
                self.failure = error.localizedDescription
                self.busy = false
            }
        }
    }

    private func open(_ connection: HelperConnection, session: String) async throws {
        struct Open: Encodable { let terminal: UInt64; let session: String }
        let id = try await connection.subscribe(
            "chat.open", params: Open(terminal: terminal, session: session),
            notify: { [weak self] method, value in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.notify(method, value) } }
            },
            ended: { [weak self] result in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, !self.ended else { return }
                        if case .failure(let error) = result, !(error is CancellationError) {
                            self.failure = error.localizedDescription
                        }
                        self.busy = false
                    }
                }
            })
        if ended { connection.cancel(id) } else { observation = id }
    }

    private struct History: Decodable {
        let terminal: UInt64
        let session: String
        let records: [HelperChat.Record]
        let state: HelperChat.State?
        let history_pending: Bool
    }
    private struct Records: Decodable {
        let terminal: UInt64
        let session: String
        let records: [HelperChat.Record]
        let replace: Bool?
    }
    private struct Status: Decodable {
        let terminal: UInt64
        let session: String
        let state: HelperChat.State
    }
    private struct Opened: Decodable {
        let terminal: UInt64
        let session: String
        let interaction: HelperChat.Interaction
    }

    /// One notification of the fork's subscription (testable: the helper's shapes).
    func notify(_ method: String, _ value: HelperBinary.Value) {
        guard !ended else { return }
        do {
            switch method {
            case "chat.history":
                let history = try HelperBinary.decode(History.self, from: value)
                guard accepts(history.terminal, history.session) else { return }
                if !history.history_pending { apply(history.records, historical: true) }
                if let state = history.state { busy = state.busy } else if !history.history_pending, transcript.openTurn == nil,
                                                                         !history.records.isEmpty { busy = false }
            case "chat.records":
                let records = try HelperBinary.decode(Records.self, from: value)
                guard accepts(records.terminal, records.session) else { return }
                if records.replace == true { transcript.clear() }
                apply(records.records, historical: records.replace == true)
            case "chat.state":
                let status = try HelperBinary.decode(Status.self, from: value)
                guard accepts(status.terminal, status.session) else { return }
                busy = status.state.busy
            case "interaction.opened":
                let opened = try HelperBinary.decode(Opened.self, from: value)
                guard accepts(opened.terminal, opened.session) else { return }
                receive(opened.interaction)
            case "terminal.exit":
                let exit = try HelperBinary.decode(HelperClient.Exit.self, from: value)
                if exit.terminal == terminal { failure = "The agent exited."; busy = false }
            default: return
            }
        } catch { failure = error.localizedDescription }
    }

    private func accepts(_ terminal: UInt64, _ session: String) -> Bool {
        terminal == self.terminal && (self.session == nil || self.session == session)
    }

    /// The fork's records; a user record takes its question's pending bubble (ChatSideConversation's rule).
    private func apply(_ records: [HelperChat.Record], historical: Bool) {
        for record in records where record.kind == "user" {
            if let index = pending.firstIndex(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                == record.text.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                pending.remove(at: index)
            }
        }
        // Without a state the records say whether the fork works: a turn that started, or ended.
        for change in transcript.apply(records, historical: historical) {
            switch change {
            case .started: busy = true
            case .ended: busy = false
            default: break
            }
        }
    }

    private func receive(_ interaction: HelperChat.Interaction) {
        if interaction.questions.isEmpty {
            if permission?.interaction.id == interaction.id { permission = nil }
            return
        }
        if let display = interaction.permission {
            permission = (interaction, display)
        } else {
            // A question form in a side conversation goes unanswered here; its terminal has it.
            failure = "\(parent?.agentName ?? "The agent") asked a question on the side. Answer it in Terminal."
        }
    }

    /// The side composer's text, asked in the fork (the first one starts it).
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !ended, permission == nil else { return }
        if question == nil {
            draft = ""
            return start(text)
        }
        guard let session, !busy else { return }
        draft = ""
        appendPending(text)
        busy = true
        failure = nil
        var input = HelperChat.Input(HelperChat.Route(terminal: terminal, session: session))
        input.text = text
        input.mode = "prompt"
        input.command = false
        let connection = client.connection
        Task {
            do {
                let sent: HelperChat.Sent = try await connection.request("chat.send", params: input)
                try sent.confirmed()
            } catch {
                guard !self.ended else { return }
                // Not retried: the question comes back to the composer.
                self.pending.removeAll { $0.text == text }
                if self.draft.isEmpty { self.draft = text }
                self.failure = error.localizedDescription
                self.busy = false
            }
        }
    }

    /// Answers the fork's permission request; a read-only side only ever refuses (option 1).
    func answer(allow: Bool) {
        guard let permission, let session, let question = permission.interaction.questions.first else { return }
        var input = HelperChat.Input(HelperChat.Route(terminal: terminal, session: session))
        input.interaction = permission.interaction.id
        input.answers = [question.id: .options([allow && !readOnly ? 0 : 1])]
        self.permission = nil
        let connection = client.connection
        Task {
            do {
                let sent: HelperChat.Sent = try await connection.request("interactions.answer", params: input)
                try sent.confirmed()
            } catch { if !self.ended { self.failure = error.localizedDescription } }
        }
    }

    /// Ends the fork: the subscription, then its process (`chat.side.close` on the fork's session; a fork still
    /// starting is closed when the helper answers). `connected` false: the link is gone, so nothing is sent; the main
    /// conversation asks the next helper to close it (`MobileChatSession.closeOrphanedSides`).
    func end(connected: Bool = true) {
        guard !ended else { return }
        ended = true
        self.connected = connected
        busy = false
        if let observation, connected { client.connection.cancel(observation) }
        observation = nil
        if let session, connected { Self.close(client.connection, terminal: terminal, session: session, closed: closed) }
    }

    /// `chat.side.close` for `session`; `closed` hears that the helper closed it.
    static func close(_ connection: HelperConnection, terminal: UInt64, session: String,
                      closed: (@MainActor (String) -> Void)? = nil) {
        let input = HelperChat.Input(HelperChat.Route(terminal: terminal, session: session))
        Task { @MainActor in
            do {
                let _: HelperClient.Empty? = try await connection.request("chat.side.close", params: input)
                closed?(session)
            } catch {}
        }
    }

    private func appendPending(_ text: String) {
        pending.append(ChatItem(id: "pending-" + UUID().uuidString, kind: .user, text: text))
    }
}
