import Foundation

/// User actions and renderer events on the common interface.
final class HelperClient: Sendable {
  struct Empty: Codable, Equatable, Sendable {
    init() {}
    init(from decoder: any Decoder) throws {
      let value = try decoder.singleValueContainer()
      guard value.decodeNil() else {
        throw DecodingError.dataCorruptedError(in: value, debugDescription: "Expected null")
      }
    }
    func encode(to encoder: any Encoder) throws {
      var value = encoder.singleValueContainer()
      try value.encodeNil()
    }
  }

  struct Output: Codable, Equatable, Sendable {
    let terminal: UInt64
    let bytes: Data
  }

  struct Control: Encodable, Sendable {
    enum Event: String, Encodable, Sendable { case start, data, end }
    let terminal: UInt64
    let event: Event
    let bytes: Data?
  }

  struct ControlRoute: Decodable, Sendable {
    let mux: UInt64
    let key: String
    let backend: UInt64
  }

  struct Exit: Codable, Equatable, Sendable {
    let terminal: UInt64
    let status: Int32?
  }

  struct Backend: Codable, Equatable, Sendable {
    let terminal: UInt64
    let mux: UInt64?
    let key: String?
    let backend: UInt64?
    let error: HelperFailure?
  }

  /// The helper reports history from the bottom; presentation counts from the oldest line.
  struct History: Codable, Equatable, Sendable {
    let terminal: UInt64
    let offset: UInt64
    let max: UInt64
    let viewport: UInt32

    var state: TerminalScrollState {
      let visible = UInt64(viewport)
      let maximum = min(max, UInt64.max - visible)
      return .init(total: maximum + visible,
                   offset: maximum - min(maximum, offset), visible: visible)
    }
  }

  struct Clipboard: Codable, Equatable, Sendable {
    let bytes: Data
  }

  struct Agent: Codable, Equatable, Sendable {
    struct Summary: Codable, Equatable, Sendable {
      let waiting: String?
      let busy: Bool
      let activity: String?
      let revision: UInt64

      enum CodingKeys: String, CodingKey { case waiting, busy, activity, revision }

      func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(waiting, forKey: .waiting)
        try fields.encode(busy, forKey: .busy)
        try fields.encode(activity, forKey: .activity)
        try fields.encode(revision, forKey: .revision)
      }
    }
    let terminal: UInt64
    let summary: Summary
  }

  enum Update: Equatable, Sendable {
    case opened(UInt64)
    case attached
    case topology(HelperTopology)
    case output(Output)
    case history(History)
    case exit(Exit)
    case agent(Agent)
    case backend(Backend)
    /// A program in a multiplexer copied text (tmux load-buffer -w): it belongs on this Mac's pasteboard.
    case clipboard(Clipboard)

    static func decode(_ method: String, _ data: Data) throws -> Self? {
      let decoder = JSONDecoder()
      switch method {
      case "backend.opened": return .opened(try decoder.decode(UInt64.self, from: data))
      case "terminal.attached":
        _ = try decoder.decode(Empty.self, from: data)
        return .attached
      case "topology": return .topology(try decoder.decode(HelperTopology.self, from: data))
      case "terminal.output": return .output(try decoder.decode(Output.self, from: data))
      case "terminal.scroll": return .history(try decoder.decode(History.self, from: data))
      case "terminal.exit": return .exit(try decoder.decode(Exit.self, from: data))
      case "agent.changed": return .agent(try decoder.decode(Agent.self, from: data))
      case "terminal.backend": return .backend(try decoder.decode(Backend.self, from: data))
      case "clipboard": return .clipboard(try decoder.decode(Clipboard.self, from: data))
      default: return nil
      }
    }

    func encode() throws -> Data {
      let encoder = JSONEncoder()
      switch self {
      case .opened(let id): return try encoder.encode(id)
      case .attached: return try encoder.encode(Empty())
      case .topology(let value): return try encoder.encode(value)
      case .output(let value): return try encoder.encode(value)
      case .history(let value): return try encoder.encode(value)
      case .exit(let value): return try encoder.encode(value)
      case .agent(let value): return try encoder.encode(value)
      case .backend(let value): return try encoder.encode(value)
      case .clipboard(let value): return try encoder.encode(value)
      }
    }
  }

  struct Node: Encodable, Sendable { let node: UInt64 }
  struct Terminal: Encodable, Sendable { let terminal: UInt64 }
  struct Attach: Encodable, Sendable {
    let terminal: UInt64
    let size: HelperTopology.Grid
    let takeover: Bool
  }
  struct Resize: Encodable, Sendable {
    let terminal: UInt64
    let size: HelperTopology.Grid
  }
  struct Screen: Encodable, Equatable, Sendable {
    struct Cursor: Encodable, Equatable, Sendable {
      let column: UInt32
      let row: UInt32
    }
    let terminal: UInt64
    let text: String
    let cursor: Cursor
    let faint_tail: Bool
  }
  /// One scroll gesture: positive lines go toward older output; a wheel step names its pointer cell.
  struct Scroll: Encodable, Sendable {
    let terminal: UInt64
    let lines: Int64
    let page: Bool
    let column: UInt16?
    let row: UInt16?
    /// shift 1, alt 2, control 4.
    let modifiers: UInt8
  }
  struct Split: Encodable, Sendable {
    let node: UInt64
    let ratio: Double
  }
  struct Create: Encodable, Sendable {
    let parent: UInt64
    let beside: UInt64?
    let cwd: String?
    let launch: UInt64?
    var command: String? = nil
    var environment: [String] = []
  }
  enum Policy: String, Encodable, Sendable { case prompt, detach, terminate }
  struct Close: Encodable, Sendable {
    let node: UInt64
    let policy: Policy
    var check: Bool = false
  }
  struct Closed: Decodable, Equatable, Sendable {
    let closed: Bool
    let confirmation: Bool
  }
  /// A multiplexer's own command for the node's server (a prefix binding such as tmux `select-pane -U`).
  struct Command: Encodable, Sendable {
    let node: UInt64
    let command: String
  }
  /// A reply whose value the caller does not need.
  struct Ignored: Decodable { init(from decoder: any Decoder) throws {} }

  struct Rename: Encodable, Sendable {
    let node: UInt64
    let name: String
  }
  struct Membership: Encodable, Sendable {
    let node: UInt64
    let parent: UInt64
    let before: UInt64?
  }
  /// memberships.place; `kind` names the place ("workspace": a new space labelled `label`).
  struct Placement: Encodable, Sendable {
    struct Place: Encodable, Sendable {
      let kind: String
      let label: String
    }
    let node: UInt64
    let place: Place
  }

  let connection: HelperConnection

  init(_ connection: HelperConnection) { self.connection = connection }

  nonisolated(nonsending) func backends() async throws -> [HelperBackend] {
    try await connection.request("backends.list", params: [String: String]())
  }

  /// An agent the helper can start; `key` is opaque, `label` is for display.
  struct Launch: Decodable, Sendable {
    let launch: UInt64
    let key: String
    let label: String
    /// The command a terminal user types to start this harness; the app wraps it.
    let program: String?
  }

  nonisolated(nonsending) func launches() async throws -> [Launch] {
    try await connection.request("launches.list", params: [String: String]())
  }

  /// A multiplexer kind the helper hosts, running or not; `name` is for display and settings keys.
  struct Multiplexer: Decodable, Sendable {
    let mux: UInt64
    let name: String
    /// Its sessions are started outside the app (e.g. in a terminal) and can open as spaces.
    let external: Bool
    /// The command a new terminal runs to start a session this multiplexer claims.
    let program: String?
  }

  /// enabled: false stops the helper from claiming that multiplexer's clients started in terminals.
  nonisolated(nonsending) func claim(_ mux: UInt64, enabled: Bool) async throws {
    struct Claim: Encodable { let mux: UInt64; let enabled: Bool }
    let _: Empty = try await connection.request("backends.claim", params: Claim(mux: mux, enabled: enabled))
  }

  nonisolated(nonsending) func open(
    _ route: HelperBackend.Route,
    update: @escaping @Sendable (Result<Update, any Error>) -> Void
  ) async throws -> UInt64 {
    try await observe("backends.open", params: route, update: update)
  }

  nonisolated(nonsending) func create(_ route: HelperBackend.Route) async throws -> UInt64 {
    try await connection.request("backends.create", params: route)
  }

  nonisolated(nonsending) func create(_ params: Create) async throws -> UInt64 {
    try await connection.request("terminals.create", params: params)
  }

  nonisolated(nonsending) func attach(
    _ params: Attach, update: @escaping @Sendable (Result<Update, any Error>) -> Void
  ) async throws -> UInt64 {
    try await observe("terminals.attach", params: params, update: update)
  }

  /// A terminal's claims and exit, without its output.
  nonisolated(nonsending) func observe(
    _ params: Terminal, update: @escaping @Sendable (Result<Update, any Error>) -> Void
  ) async throws -> UInt64 {
    try await observe("terminals.observe", params: params, update: update)
  }

  nonisolated(nonsending) func input(_ params: Output) async throws {
    let _: Empty = try await connection.request("terminals.input", params: params)
  }

  nonisolated(nonsending) func control(_ params: Control) async throws -> ControlRoute? {
    do {
      return try await connection.request("terminals.control", params: params)
    } catch HelperWire.Failure.limit {
      guard params.event == .data, let bytes = params.bytes, bytes.count > 1 else {
        throw HelperWire.Failure.limit
      }
      let middle = bytes.count / 2
      _ = try await control(.init(terminal: params.terminal, event: .data, bytes: Data(bytes.prefix(middle))))
      return try await control(.init(terminal: params.terminal, event: .data, bytes: Data(bytes.dropFirst(middle))))
    }
  }

  nonisolated(nonsending) func resize(_ params: Resize) async throws {
    let _: Empty = try await connection.request("terminals.resize", params: params)
  }

  nonisolated(nonsending) func scroll(_ params: Scroll) async throws {
    let _: Empty = try await connection.request("terminals.scroll", params: params)
  }

  nonisolated(nonsending) func publish(_ params: Screen) async throws {
    let _: Empty = try await connection.request("terminals.publish", params: params)
  }

  nonisolated(nonsending) func resize(_ params: Split) async throws {
    let _: Empty = try await connection.request("layouts.resize", params: params)
  }

  nonisolated(nonsending) func focus(_ params: Node) async throws {
    let _: Empty = try await connection.request("entities.focus", params: params)
  }

  nonisolated(nonsending) func move(_ params: Membership) async throws {
    let _: Empty = try await connection.request("memberships.move", params: params)
  }

  nonisolated(nonsending) func place(_ params: Placement) async throws {
    let _: Empty = try await connection.request("memberships.place", params: params)
  }

  nonisolated(nonsending) func command(_ params: Command) async throws {
    let _: Ignored = try await connection.request("backends.command", params: params)
  }

  nonisolated(nonsending) func rename(_ params: Rename) async throws {
    let _: Empty = try await connection.request("entities.rename", params: params)
  }

  nonisolated(nonsending) func close(_ params: Close) async throws -> Closed {
    try await connection.request("close.request", params: params)
  }

  private nonisolated(nonsending) func observe<P: Encodable>(
    _ method: String, params: P,
    update: @escaping @Sendable (Result<Update, any Error>) -> Void
  ) async throws -> UInt64 {
    try await connection.subscribe(
      method, params: params,
      notify: { method, data in
        do {
          if let value = try Update.decode(method, data) { update(.success(value)) }
        } catch { update(.failure(error)) }
      },
      ended: { result in
        if case .failure(let error) = result, !(error is CancellationError) {
          update(.failure(error))
        }
      })
  }
}
