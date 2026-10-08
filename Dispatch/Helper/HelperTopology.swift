import Foundation

struct HelperTopology: Codable, Equatable, Sendable {
  let backend: UInt64
  let nodes: [Node]
  let layouts: [Layout]
  /// Deepest focused node; its parents give the focused tab and workspace.
  let focus: UInt64?
  var key: String? = nil

  enum CodingKeys: String, CodingKey { case backend, nodes, layouts, focus, key }

  func encode(to encoder: any Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    try fields.encode(backend, forKey: .backend)
    try fields.encode(nodes, forKey: .nodes)
    try fields.encode(layouts, forKey: .layouts)
    try fields.encode(focus, forKey: .focus)
    try fields.encodeIfPresent(key, forKey: .key)
  }

  enum Kind: String, Codable, Sendable { case workspace, tab, terminal }
  enum Axis: String, Codable, Sendable { case rows, columns }

  struct Grid: Codable, Equatable, Sendable {
    let columns: UInt16
    let rows: UInt16
    /// One cell in pixels when the renderer knows it (images such as Kitty graphics size by it).
    var cell_width: UInt16? = nil
    var cell_height: UInt16? = nil
  }

  /// The agent session a terminal runs.
  struct Binding: Codable, Equatable, Sendable {
    let session: String
    let transcript: String?
    /// The bound agent process (pid, start [seconds, microseconds], executable).
    let pid: UInt64?
    let start: [UInt64]?
    let executable: String?

    enum CodingKeys: String, CodingKey { case session, transcript, pid, start, executable }

    func encode(to encoder: any Encoder) throws {
      var fields = encoder.container(keyedBy: CodingKeys.self)
      try fields.encode(session, forKey: .session)
      try fields.encode(transcript, forKey: .transcript)
      try fields.encode(pid, forKey: .pid)
      try fields.encode(start, forKey: .start)
      try fields.encode(executable, forKey: .executable)
    }
  }

  struct Node: Codable, Equatable, Sendable {
    let id: UInt64
    let key: String
    let parent: UInt64?
    let kind: Kind
    let name: String
    let renamed: Bool?
    let cwd: String?
    let size: Grid?
    /// The terminal's PTY device (macOS st_rdev), for attributing an ssh started in it.
    let tty: UInt64?
    let agent: Binding?
    /// Dismissed but still addressable; memberships.place or move restores it.
    let detached: Bool

    enum CodingKeys: String, CodingKey {
      case id, key, parent, kind, name, renamed, cwd, size, tty, agent, detached
    }

    // Older helpers omit optional fields; preserve omission separately from an explicit null.
    private let fields: Set<CodingKeys>

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      fields = Set(container.allKeys)
      id = try container.decode(UInt64.self, forKey: .id)
      key = try container.decode(String.self, forKey: .key)
      parent = try container.decodeIfPresent(UInt64.self, forKey: .parent)
      kind = try container.decode(Kind.self, forKey: .kind)
      name = try container.decode(String.self, forKey: .name)
      renamed = try container.decodeIfPresent(Bool.self, forKey: .renamed)
      cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
      size = try container.decodeIfPresent(Grid.self, forKey: .size)
      tty = try container.decodeIfPresent(UInt64.self, forKey: .tty)
      agent = try container.decodeIfPresent(Binding.self, forKey: .agent)
      detached = try container.decode(Bool.self, forKey: .detached)
    }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(id, forKey: .id)
      try container.encode(key, forKey: .key)
      if fields.contains(.parent) { try container.encode(parent, forKey: .parent) }
      try container.encode(kind, forKey: .kind)
      try container.encode(name, forKey: .name)
      if fields.contains(.renamed) { try container.encode(renamed, forKey: .renamed) }
      if fields.contains(.cwd) { try container.encode(cwd, forKey: .cwd) }
      if fields.contains(.size) { try container.encode(size, forKey: .size) }
      if fields.contains(.tty) { try container.encode(tty, forKey: .tty) }
      if fields.contains(.agent) { try container.encode(agent, forKey: .agent) }
      try container.encode(detached, forKey: .detached)
    }
  }

  struct Layout: Codable, Equatable, Sendable {
    let container: UInt64
    let full: Split
    let visible: Split
    let focus: UInt64?

    enum CodingKeys: String, CodingKey { case container, full, visible, focus }

    func encode(to encoder: any Encoder) throws {
      var fields = encoder.container(keyedBy: CodingKeys.self)
      try fields.encode(container, forKey: .container)
      try fields.encode(full, forKey: .full)
      try fields.encode(visible, forKey: .visible)
      try fields.encode(focus, forKey: .focus)
    }
  }

  indirect enum Split: Codable, Equatable, Sendable {
    case leaf(UInt64)
    case branch(id: UInt64, axis: Axis, children: [Child])

    struct Child: Codable, Equatable, Sendable {
      let weight: UInt32
      let split: Split
    }

    enum CodingKeys: String, CodingKey { case terminal, id, axis, children }

    init(from decoder: any Decoder) throws {
      let fields = try decoder.container(keyedBy: CodingKeys.self)
      if fields.contains(.terminal) {
        self = .leaf(try fields.decode(UInt64.self, forKey: .terminal))
      } else {
        self = .branch(
          id: try fields.decode(UInt64.self, forKey: .id),
          axis: try fields.decode(Axis.self, forKey: .axis),
          children: try fields.decode([Child].self, forKey: .children))
      }
    }

    func encode(to encoder: any Encoder) throws {
      var fields = encoder.container(keyedBy: CodingKeys.self)
      switch self {
      case .leaf(let terminal):
        try fields.encode(terminal, forKey: .terminal)
      case .branch(let id, let axis, let children):
        try fields.encode(id, forKey: .id)
        try fields.encode(axis, forKey: .axis)
        try fields.encode(children, forKey: .children)
      }
    }
  }
}
