import Foundation

/// The common chat wire. Native transcript and control formats stay in the helper.
@MainActor
final class HelperChat {
  struct Route: Encodable, Equatable {
    let terminal: UInt64
    var session: String?
  }

  struct Input: Encodable {
    var terminal: UInt64?
    let session: String?
    var text: String?
    var mode: String?
    var command: Bool?
    var earlier: String?
    var model: String?
    var effort: String?
    var record: String?
    var interaction: String?
    var answers: [String: Answer]?
    var question: String?
    var read_only: Bool?
    var item: String?
    var revision: UInt64?
    var items: [String]?
    var held: Bool?
    var transcript: Transcript?

    init(_ route: Route) {
      terminal = route.terminal
      session = route.session
    }
  }

  enum Answer: Encodable, Equatable {
    case options([Int])
    case text(String)
    case skip

    func encode(to encoder: any Encoder) throws {
      var value = encoder.singleValueContainer()
      switch self {
      case .options(let indices): try value.encode(indices)
      case .text(let text): try value.encode(text)
      case .skip: try value.encodeNil()
      }
    }
  }

  struct Record: Codable, Equatable, Sendable {
    let id: String
    let turn: String?
    let kind: String
    let text: String
    let title: String
    let output: String
    let blocks: [Block]
    let completed: Bool
    let exit_code: Int32?
    let patch: String?
    let time_ms: Int64?
    var documents: [Document]
    var tool: Tool?
    let inline_reasoning: Bool

    var display: ChatRecord? { display(at: Date(timeIntervalSince1970: 0)) }

    /// A tool's call and its result can be separate records under one id, and
    /// only the call carries the presentation. Keep it whichever lands last.
    func filled(from other: Record) -> Record {
      var record = self
      if record.tool == nil { record.tool = other.tool }
      if record.documents.isEmpty { record.documents = other.documents }
      return record
    }

    func display(at date: Date) -> ChatRecord? {
      let action: ChatRecord.Action
      switch kind {
      case "turn_started": action = .started
      case "turn_ended": action = .ended
      // What a native command printed: the pending command's result, never a chat row.
      case "output": action = .commandOutput(text)
      default:
        guard let kind = ChatItem.Kind(rawValue: kind) else { return nil }
        var item = ChatItem(
          id: id, kind: kind, text: text, title: title,
          output: output, completed: completed, exitCode: exit_code.map(Int.init))
        item.source = self
        item.directory = tool?.directory
        if !documents.isEmpty {
          item.patch = ChatPatch(
            documents: documents.map {
              ToolDocument(path: $0.path, diff: $0.diff, workingDirectory: $0.workdir)
            },
            state: patch.flatMap(ChatPatch.State.init(rawValue:))
              ?? (completed ? (exit_code == nil || exit_code == 0 ? .completed : .failed) : .generating))
        }
        action = .item(item)
      }
      // Keep native event identity and a content revision, so the row merger
      // can replace a partial result with its completion.
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      let key = ChatRecord.contentKey((try? encoder.encode(self)) ?? Data())
      return ChatRecord(
        key: "\(key):\(id)", turnID: turn ?? "history",
        date: time_ms.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? date,
        action: action)
    }
  }

  struct Page: Decodable, Sendable {
    let records: [Record]
    let earlier: String?
    /// What the transcript says about its conversation (an archive's title).
    let state: State?
    /// The read itself; nil where the reply has none (a live chat's replaced records).
    let snapshot: Snapshot?
    struct Snapshot: Decodable, Sendable {
      /// The transcript has no conversation metadata yet (an agent before its first save).
      let awaiting_creation: Bool
      /// A fresh read of the file (first, or the file was replaced), not records appended since the last.
      let initial: Bool
    }
  }

  struct Queued: Decodable, Equatable, Sendable {
    struct Preview: Decodable, Equatable, Sendable {
      let kind: String
      let text: String?
      let type: String?
    }
    let id: String
    let mode: String
    let revision: UInt64
    let preview: [Preview]
    let editable: Bool
    let editing: Bool
    let paused: String?
    let error: HelperFailure?

    /// Same text the old queue row showed: one line per input, attachments by type.
    var text: String { preview.map { $0.text ?? "[\($0.type ?? "attachment")]" }.joined(separator: "\n") }
  }

  struct Document: Codable, Equatable, Sendable {
    let path: String
    let kind: String?
    let diff: String
    let workdir: String?
  }

  struct Block: Codable, Equatable, Sendable {
    let kind: String
    let language: String?
    let text: String?
    let path: String?

    var display: ToolOutput.Block {
      switch kind {
      case "markdown": .init(kind: .markdown, text: text ?? "")
      case "attachment": .init(kind: .attachment, text: path ?? "")
      default: .init(kind: .code(language ?? "text"), text: text ?? "")
      }
    }
  }

  struct Tool: Codable, Equatable, Sendable {
    struct Read: Codable, Equatable, Sendable {
      struct Selection: Codable, Equatable, Sendable {
        let kind: String
        let start: Int?
        let end: Int?
        let count: Int?
      }
      let path: String
      let selection: Selection
      let source: Bool
    }
    struct Search: Codable, Equatable, Sendable {
      let pattern: String
      let paths: [String]
      let filters: [String]
      let standard_input: Bool
    }
    struct Shell: Codable, Equatable, Sendable {
      let command: String
      let kind: String
      let swift_tests: Bool
    }
    let kind: String
    let title: String
    let symbol: String
    let summary: String
    let input: String
    let language: String
    let directory: String?
    let failed: Bool
    let read: Read?
    let search: Search?
    let shell: Shell?
    let children: [Record]
    let orchestration: Bool
    let patch: Bool
    let confirmed_result: String?
    let additions: Int
    let deletions: Int
  }

  struct Installation: Decodable {
    struct Edit: Decodable, Identifiable {
      let path: String
      let before: Data?
      let after: Data?
      let backup: String?
      var id: String { path }
    }
    let edits: [Edit]
    let restart: Bool
    /// Absent from older helpers.
    let installed: Bool?
    let optional: Bool?
    let reload: String?
    let trust: String?
    /// Core-derived: off, restart (an agent predates the install) or ready.
    let status: String?
  }

  struct Setup: Encodable {
    let launch: UInt64
    let enabled: Bool?
    let terminal: UInt64?
  }

  /// Audits (`enabled` nil) or installs/removes one harness integration on a helper's host, for the
  /// account or (`terminal`) for the agent running there, in its own config root (core 87af25a7);
  /// nil when that host's helper does not list the harness.
  static func setup(
    _ endpoint: HelperWorkspace.Endpoint, key: String, enabled: Bool?, terminal: UInt64?
  ) async throws -> Installation? {
    let client = HelperClient(try await HelperApp.shared.connection(endpoint))
    guard let launch = try await client.launches().first(where: { $0.key == key }) else { return nil }
    return try await client.connection.request(
      enabled == nil ? "installation.audit" : "installation.install",
      params: Setup(launch: launch.launch, enabled: enabled, terminal: terminal))
  }

  struct History: Decodable {
    let terminal: UInt64
    let binding: HelperTopology.Binding
    let session: String
    let key: String
    let label: String
    let commands: [String]
    let native_queue: Bool
    let state: State?
    let state_error: HelperFailure?
    let records: [Record]
    let earlier: String?
    let history_error: HelperFailure?
    let history_pending: Bool
    let capabilities: [String]
  }

  struct State: Decodable, Sendable {
    var version: String? = nil
    let busy: Bool
    let activity: String?
    let model: String?
    let model_label: String?
    let effort: String?
    let usage: String?
    let goal: String?
    let draft: String?
    let attention: String?
    var dialog: String? = nil
    /// Native session title (absent from older helpers).
    let title: String?
    /// The agent is compacting its context (its own caption, as the terminal shows it).
    let compacting: Bool
    /// The agent's service tier ("priority" is Codex's /fast), when it reports one.
    let service_tier: String?
    var mode: String? = nil
  }

  struct Choice: Decodable, Sendable {
    let id: String
    let label: String
    let detail: String?
  }

  struct Question: Decodable, Sendable {
    let id: String
    let header: String
    let text: String
    let secret: Bool
    let options: [Choice]
    let multiple: Bool
    let custom: Bool
    /// Complete presentation (e.g. an approval operation as a code block); absent from older helpers.
    let blocks: [Block]?
  }

  struct Interaction: Decodable, Sendable {
    let id: String
    let key: String?
    let approval: Bool
    let blocking: Bool
    let questions: [Question]
    /// The turn and tool record it belongs to (Record.turn / Record.id); absent when the producer can't tell.
    let turn: String?
    let record: String?

    /// The tool card an approval shows: built from the request (the tool and its input; an approval's text is
    /// "<tool>\n<input>"), with the tool record's input once the producer names it.
    func tool(in turns: [ChatTurn]) -> ChatItem? {
      guard let question = questions.first else { return nil }
      if let record, let item = turns.flatMap(\.items).first(where: { $0.id == record }) {
        return ChatItem(id: id, kind: .tool, text: item.text, title: question.header)
      }
      let prefix = question.header + "\n"
      let input = question.text.hasPrefix(prefix) ? String(question.text.dropFirst(prefix.count)) : question.text
      return ChatItem(id: id, kind: .tool, text: input, title: question.header)
    }

    /// A completed question form's answers (question text -> the chosen labels joined by ", ", or the
    /// typed text; ClaudeQuestionDraft.answer) as the helper's answer per question id.
    func answers(_ chosen: [String: String]) -> [String: Answer] {
      Dictionary(uniqueKeysWithValues: questions.map { question in
        let text = chosen[question.text] ?? "", labels = question.options.map(\.label)
        let parts = labels.contains(text) ? [text] : text.components(separatedBy: ", ")
        let indices = parts.compactMap { labels.firstIndex(of: $0) }
        return (question.id, !text.isEmpty && indices.count == parts.count ? .options(indices) : .text(text))
      })
    }

    /// Approvals use the existing approval card: option 0 allows, option 1 denies, dismiss defers to Terminal.
    var permission: ChatSidePermission? {
      guard approval, questions.count == 1, let question = questions.first,
        question.options.count >= 2, !question.custom, !question.multiple
      else { return nil }
      let title = question.header.hasSuffix("?") ? question.header : "Allow \(question.header)?"
      // Operation text matches the old card; the producer's code block names its language.
      let language = question.blocks?.first(where: { $0.kind == "code" })?.language ?? "json"
      return .init(
        title: title, operation: question.text.isEmpty ? question.header : question.text,
        language: language)
    }
  }

  struct Menu: Decodable, Sendable {
    let choices: [Choice]
    let current: String?
    var `default`: String? = nil
  }

  struct Sent: Decodable {
    let written: Bool
    let may_have_sent: Bool
    let reason: String?

    func confirmed() throws {
      guard written else {
        throw Delivery(
          errorDescription: reason ?? "The message was not sent. Your draft is preserved.",
          uncertain: may_have_sent)
      }
    }
  }

  /// chat.command result; captions are the app's (c1654cc ChatCommands shell/stop results).
  struct Outcome: Decodable {
    let kind: String
    let sent: Sent?
    let command: String?
    let output: String?
    /// A command the harness answered itself (Outcome::Result, core 36595f6f).
    let title: String?
    let text: String?

    func confirmed() throws { try sent?.confirmed() }

    func result(agent: String) -> ChatCommandResult? {
      switch kind {
      case "shell":
        let output = output ?? ""
        return .init(title: "!" + (command ?? ""), text: output.isEmpty ? "Command completed with no output." : output)
      case "stopping":
        return .init(title: "Background terminals", text: "\(agent) is stopping all background terminals.")
      case "result":
        return .init(title: title ?? "", text: text ?? "")
      default: return nil
      }
    }
  }

  struct Delivery: LocalizedError {
    let errorDescription: String?
    let uncertain: Bool
  }

  struct Transcript: Encodable, Sendable {
    let key: String
    let path: String
    let session: String
    var earlier: String?

    enum CodingKeys: String, CodingKey { case key, path, session, earlier }

    /// `earlier` is "string or null" on the wire: the first page sends null, not an absent field.
    func encode(to encoder: any Encoder) throws {
      var fields = encoder.container(keyedBy: CodingKeys.self)
      try fields.encode(key, forKey: .key)
      try fields.encode(path, forKey: .path)
      try fields.encode(session, forKey: .session)
      try fields.encode(earlier, forKey: .earlier)
    }
  }


  /// Live records, or with `replace` the newest history page.
  private struct Records: Decodable {
    let terminal: UInt64
    let session: String
    let records: [Record]
    let replace: Bool?
    let earlier: String?
  }

  private struct Items: Decodable {
    let terminal: UInt64
    let session: String
    let items: [Queued]
    /// A queue operation the producer could not complete (absent from older helpers).
    let error: HelperFailure?
  }

  private struct Status: Decodable {
    let terminal: UInt64
    let session: String
    let state: State
  }

  private struct Opened: Decodable {
    let terminal: UInt64
    let session: String
    let interaction: Interaction
  }

  enum Event {
    case history(History)
    case records([Record])
    case page(Page)
    case replacement(Page)
    /// A watched transcript's read: the whole recent page when `snapshot.initial` (first read or a
    /// replaced file), else only the records appended since the previous read.
    case archive(Page)
    case state(State)
    case queue([Queued], HelperFailure?)
    case interaction(Interaction)
    case exit
  }

  private(set) var route: Route
  private let selector: String?
  /// Set for an archived conversation read from its transcript without a live terminal.
  let transcript: Transcript?
  let endpoint: HelperWorkspace.Endpoint
  private var connection: HelperConnection?
  private var observation: UInt64?
  private var pending: (stream: UUID, id: UInt64?)?
  private var opening = false
  private var generation = UUID()
  private var stream = UUID()
  var receive: ((Event) -> Void)?
  var failed: ((any Error) -> Void)?

  init(
    terminal: UInt64, session: String? = nil, endpoint: HelperWorkspace.Endpoint = .local
  ) {
    route = Route(terminal: terminal, session: session)
    selector = session
    self.endpoint = endpoint
    transcript = nil
  }

  /// A transcript the harness reads directly (chat.page transcript): pages only, no live updates.
  init(archive: Transcript, endpoint: HelperWorkspace.Endpoint = .local) {
    route = Route(terminal: 0, session: archive.session)
    selector = archive.session
    self.endpoint = endpoint
    transcript = archive
  }

  /// One history page before `earlier` (nil: the newest), live or archived.
  func page(earlier: String?) async throws -> Page {
    var input = Input(route)
    if var source = transcript {
      // A file-only read carries no terminal: core rejects transcript + terminal.
      source.earlier = earlier
      input.terminal = nil
      input.transcript = source
    } else {
      input.earlier = earlier
    }
    return try await call("chat.page", input: input)
  }

  func open(refresh: Bool = false) async throws {
    guard !opening, pending == nil, observation == nil || refresh else { return }
    let generation = generation
    let connection = try await client()
    guard self.generation == generation else { throw CancellationError() }
    try await open(connection: connection, refresh: refresh)
  }

  func open(connection: HelperConnection, refresh: Bool = false) async throws {
    guard !opening, pending == nil, observation == nil || refresh else { return }
    self.connection = connection
    let next = UUID()
    pending = (next, nil)
    opening = true
    defer { opening = false }
    var archive = Input(route)
    archive.terminal = nil
    archive.transcript = transcript
    func subscribe<P: Encodable & Sendable>(_ params: P) async throws -> UInt64 {
      try await connection.subscribe(
      "chat.open", params: params,
      notify: { [weak self] method, data in
        DispatchQueue.main.async {
          guard let self, self.stream == next || self.pending?.stream == next else { return }
          if self.pending?.stream == next {
            // Both watches decode on one transport queue and deliver on the main queue.
            // The first new notification follows every earlier old callback, including
            // question closures. Retiring the old watch before this barrier loses events.
            if let observation = self.observation { connection.cancel(observation) }
            self.observation = self.pending?.id
            self.pending = nil
            self.stream = next
          }
          self.notify(method, data: data)
        }
      },
      ended: { [weak self] result in
        DispatchQueue.main.async {
          guard let self, self.stream == next || self.pending?.stream == next else { return }
          if self.pending?.stream == next { self.pending = nil }
          else { self.observation = nil; self.stream = UUID() }
          if case .failure(let error) = result, !(error is CancellationError) {
            self.failed?(error)
          }
        }
      })
    }
    do {
      let id = transcript == nil ? try await subscribe(Route(terminal: route.terminal, session: selector)) : try await subscribe(archive)
      if pending?.stream == next { pending?.id = id }
      else if stream == next { observation = id }
      else { connection.cancel(id) }
    } catch {
      if pending?.stream == next { pending = nil }
      throw error
    }
  }

  func call<R: Decodable>(_ method: String, input: Input) async throws -> R {
    let generation = generation
    let connection = try await client()
    try Task.checkCancellation()
    guard self.generation == generation else { throw CancellationError() }
    let result: R = try await connection.request(
      method, params: input,
      notify: { [weak self] method, data in
        DispatchQueue.main.async {
          guard let self, self.generation == generation else { return }
          self.notify(method, data: data)
        }
      })
    guard self.generation == generation else { throw CancellationError() }
    return result
  }

  func close() {
    generation = UUID()
    stream = UUID()
    opening = false
    if let observation { connection?.cancel(observation) }
    if let id = pending?.id { connection?.cancel(id) }
    pending = nil
    observation = nil
    receive = nil
    failed = nil
  }

  func side(question: String, readOnly: Bool) async throws -> HelperChat {
    var input = Input(route)
    input.question = question
    input.read_only = readOnly
    let binding: HelperTopology.Binding = try await call("chat.side", input: input)
    return HelperChat(terminal: route.terminal, session: binding.session, endpoint: endpoint)
  }

  private func client() async throws -> HelperConnection {
    let connection = try await HelperApp.shared.connection(endpoint)
    self.connection = connection
    return connection
  }

  private func accepts(_ terminal: UInt64, session: String) -> Bool {
    guard terminal == route.terminal, route.session == nil || route.session == session else {
      return false
    }
    route.session = session
    return true
  }

  private func notify(_ method: String, data: Data) {
    do {
      let decoder = JSONDecoder()
      switch method {
      case "chat.history":
        let value = try decoder.decode(History.self, from: data)
        if selector == nil, value.terminal == route.terminal, route.session != value.session {
          if route.session?.isEmpty == false { generation = UUID() }
          route.session = value.session
        }
        if accepts(value.terminal, session: value.session) { receive?(.history(value)) }
      case "chat.archive":
        receive?(.archive(try decoder.decode(Page.self, from: data)))
      case "chat.records":
        let value = try decoder.decode(Records.self, from: data)
        if accepts(value.terminal, session: value.session) {
          receive?(
            value.replace == true
              ? .replacement(Page(records: value.records, earlier: value.earlier, state: nil, snapshot: nil))
              : .records(value.records))
        }
      case "chat.queue":
        let value = try decoder.decode(Items.self, from: data)
        if accepts(value.terminal, session: value.session) { receive?(.queue(value.items, value.error)) }
      case "chat.state":
        let value = try decoder.decode(Status.self, from: data)
        if accepts(value.terminal, session: value.session) { receive?(.state(value.state)) }
      case "interaction.opened":
        let value = try decoder.decode(Opened.self, from: data)
        if accepts(value.terminal, session: value.session) {
          receive?(.interaction(value.interaction))
        }
      case "terminal.exit":
        let value = try decoder.decode(HelperClient.Exit.self, from: data)
        if value.terminal == route.terminal { receive?(.exit) }
      default: break
      }
    } catch { failed?(error) }
  }
}

extension HelperTopology.Binding {
  var process: AgentProcess? {
    guard let pid, let start, start.count == 2, let executable else { return nil }
    return AgentProcess(
      executable: executable, pid: pid_t(clamping: pid), startedSeconds: start[0],
      startedMicroseconds: start[1])
  }
}
