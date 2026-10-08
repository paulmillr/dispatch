#if canImport(AppKit)
  import AppKit
  import Term
  import TermApple
  import Observation

  /// App state and rendering for the common terminal family.
  @MainActor @Observable
  final class HelperWorkspace {
    struct Detached: Codable, Equatable {
      let route: HelperBackend.Route
      var presentation: [Space]
      var nodes: [String: UUID]
      var key: String? = nil
    }
    private(set) var detachedRoutes: [Detached] = []
    var recovery: SSHReconnectController.Recipe?
    @ObservationIgnored private var dismissals: [UInt64: (route: HelperBackend.Route?, task: Task<Void, Never>)] = [:]
    /// Windows the helper reports detached (Node.detached): hidden from their space and listed until
    /// restored (memberships.move back into their space) or forgotten.
    struct DetachedWindow: Equatable {
      let id: UUID
      let node: UInt64
      /// Where it goes back: its own parent, else its session's space; nil: a new space.
      let parent: UInt64?
      let name: String
      let route: HelperBackend.Route
      let host: HostID
    }
    private(set) var detachedWindows: [DetachedWindow] = []
    private var forgottenWindows: Set<UUID> = []
    /// Immutable detached descriptors whose original native terminals no longer exist.
    private var missingWindows: [UUID: HelperFailure] = [:]
    private var restoringWindows: Set<UUID> = []
    private var restoreRequests: [UUID: (route: HelperBackend.Route, node: UInt64, task: Task<Void, Never>)] = [:]
    private var restoreSpaces: [HelperBackend.Route: UUID] = [:]
    @ObservationIgnored private var restoration = UUID()
    private var restoring: [HelperBackend.Route: Detached] = [:]
    private(set) var backends: [HelperBackend] = []
    private(set) var error: String?
    @ObservationIgnored private(set) var operations = 0
    @ObservationIgnored private var creations: [HelperBackend.Route: [UUID: Task<Void, Never>]] = [:]
    /// Shared by every endpoint; TerminalRuntime owns its lifetime.
    @ObservationIgnored private let renderer: HelperRenderer?
    let endpoint: Endpoint
    /// Native shells inherit this scope after their launcher closes. The launch manager retires it.
    @ObservationIgnored private let scope = UUID()
    /// Multiplexer names the user let this helper open as spaces (an SSH link's consent); nil on this Mac.
    private(set) var granted: Set<String>?
    /// The machine its backends run on, for the spaces they open.
    let host: HostID
    @ObservationIgnored private let ready: Task<HelperConnection, any Error>
    private typealias Catalogs = (
      kinds: HelperConnection.Call<[HelperClient.Multiplexer]>,
      backends: HelperConnection.Call<[HelperBackend]>,
      launches: HelperConnection.Call<[HelperClient.Launch]>?
    )
    @ObservationIgnored private let discovery: Task<Catalogs, any Error>
    @ObservationIgnored private let catalog: Task<[HelperBackend], any Error>
    @ObservationIgnored private let kinds: Task<[HelperClient.Multiplexer], any Error>
    /// Wraps the helper's listed programs in new terminals; creation waits for it.
    @ObservationIgnored private let launchers: Task<Void, any Error>
    @ObservationIgnored private weak var workspace: Workspace?
    @ObservationIgnored private var connection: HelperConnection?
    /// Calls made before the connection is ready, resumed in call order so their requests go out in that order.
    @ObservationIgnored private var waiting: [CheckedContinuation<HelperConnection, any Error>] = []
    @ObservationIgnored private var failure: (any Error)?
    @ObservationIgnored private var routes: [UInt64: HelperBackend.Route] = [:]
    @ObservationIgnored private var observations: [HelperBackend.Route: UInt64] = [:]
    @ObservationIgnored private var attachments: [UUID: UInt64] = [:]
    @ObservationIgnored private var terminals: [UUID: HelperTerminal] = [:]
    @ObservationIgnored private var identity: [Key: UUID] = [:]
    @ObservationIgnored private var dividers: [UUID: UInt64] = [:]
    @ObservationIgnored private var opening: [HelperBackend.Route: Task<UInt64, any Error>] =
      [:]
    @ObservationIgnored private var pending: [UUID: Task<UInt64, any Error>] = [:]
    @ObservationIgnored private var assigned: [UInt64: UUID] = [:]
    @ObservationIgnored private(set) var snapshots: [HelperBackend.Route: HelperTopology] = [:]
    /// Tabs whose terminal started a claimed client, closed once it opens when the user wants that.
    @ObservationIgnored private var imports: [HelperBackend.Route: Set<UUID>] = [:]
    @ObservationIgnored private var gateways: [UUID: (backend: UInt64, terminal: UInt64)] = [:]
    /// The host of the tab whose terminal started each imported backend's client (an SSH login's host
    /// for tmux -CC there): that backend's tabs are on the same host (old HostCoordinator: tmux tabs
    /// inherit their gateway's context, herdr surfaces their endpoint's).
    @ObservationIgnored private var origins: [UInt64: TerminalHostContext] = [:]
    @ObservationIgnored private var hosts: [HelperBackend.Route: HostID] = [:]
    /// The backend each terminal's control client claimed, and backends whose client's transport is gone
    /// while their spaces stay shown (C11: ops fail until the same server is claimed again): offline.
    @ObservationIgnored private var controlBackends: [UUID: UInt64] = [:]
    private(set) var lost: Set<UInt64> = []
    @ObservationIgnored private var creating: [HelperBackend.Route: Int] = [:]
    /// Names shown before the server confirms them (app identity -> name); a failed rename returns to the server's
    /// name at the next topology, a confirmed one when a topology shows it.
    @ObservationIgnored private var renaming: [UUID: (name: String, node: UInt64?, failed: Bool)] = [:]
    /// Spaces and windows hidden while the server closes them; a failed close shows them again.
    @ObservationIgnored private var closing: Set<UInt64> = []
    /// Closing nodes no topology has shown yet (a dismissed creation's terminal): kept closing until one does.
    @ObservationIgnored private var unseen: Set<UInt64> = []
    /// Created terminals of dismissed windows: their window is detached once a topology shows it.
    @ObservationIgnored private var detaching: Set<UInt64> = []
    /// Focus commands in flight per route: their topologies don't move the app's selection.
    @ObservationIgnored private var focusing: [HelperBackend.Route: Int] = [:]
    @ObservationIgnored private var focusTargets: [UInt64: Int] = [:]
    @ObservationIgnored private var commanding: [HelperBackend.Route: Int] = [:]
    /// The focus each route's last topology reported: a change is the server's (another client's) selection.
    @ObservationIgnored private var lastFocus: [HelperBackend.Route: UInt64] = [:]
    /// Spaces shown while their creation is pending: created terminal -> the space it fills.
    @ObservationIgnored private var adoptedSpaces: [UInt64: UUID] = [:]
    /// Windows dismissed while their creation was in flight: what the server creates for them is detached.
    @ObservationIgnored private var dismissed: Set<UUID> = []
    /// Spaces shown before the server has them (a creation or a move in flight): topologies keep them until adopted.
    @ObservationIgnored private var pendingSpaces: Set<UUID> = []
    @ObservationIgnored private var confirming: Set<UUID> = []
    @ObservationIgnored private var placing: [UUID: Task<Void, Never>] = [:]
    /// Terminals of a window moving to a new space -> the space node they leave (hidden there until it shows them elsewhere).
    @ObservationIgnored private var movedFrom: [UInt64: UInt64] = [:]
    /// Moving terminals the selection follows: terminal -> the space it leaves.
    @ObservationIgnored private var following: [UInt64: UUID] = [:]
    @ObservationIgnored private var selections:
      [UInt64: (space: UUID, split: Workspace.NativeSplitPlacement?)] = [:]
    @ObservationIgnored private var sending: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var controlling: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var controlEvents: [UUID: [(event: HelperClient.Control.Event, bytes: Data?, session: Int)]] = [:]
    @ObservationIgnored private var controlTerminals: [UUID: UInt64] = [:]
    @ObservationIgnored private var controlInput: [UUID: (session: Int, stream: AsyncStream<Void>, end: AsyncStream<Void>.Continuation)] = [:]
    /// The control session (the id Surface.control events carry) whose route the helper refused, per tab.
    @ObservationIgnored private var refused: [UUID: Int] = [:]
    @ObservationIgnored private var activating: Set<HelperBackend.Route> = []
    @ObservationIgnored private var unrouted: [UInt64: HelperTopology] = [:]
    @ObservationIgnored private var keys: [UUID: (Keys.Binding, Endpoint)] = [:]
    @ObservationIgnored private var screens: [UInt64: HelperClient.Screen] = [:]
    @ObservationIgnored private var suspensions: [UUID: Set<UUID>] = [:]
    @ObservationIgnored private var published: [UInt64: HelperClient.Screen] = [:]
    @ObservationIgnored private var publishing: [UInt64: Task<Void, Never>] = [:]

    @ObservationIgnored private(set) var stopped = false
    @ObservationIgnored private var available: [UInt64: HelperTopology.Grid] = [:]
    @ObservationIgnored private(set) var sized: [UInt64: UUID] = [:]
    /// Windows shown while their creation is pending (no helper node yet).
    @ObservationIgnored private var placeholders: Set<UUID> = []
    /// Terminals some topology has published; only these can be gone from a later one.
    @ObservationIgnored private var seen: Set<UInt64> = []
    @ObservationIgnored private var subscribing: [HelperBackend.Route: (id: UUID, task: Task<Void, Never>)] = [:]
    /// Created terminal -> the placeholder window it fills: the window keeps the id it showed while connecting.
    @ObservationIgnored private var adopted: [UInt64: UUID] = [:]
    /// Terminals this helper runs but no shown tab holds (an SSH login) -> the tab they belong to.
    @ObservationIgnored private var observed: [UInt64: UUID] = [:]
    /// Observed logins of a remote helper whose tab surface marked its earlier text (Surface.markRows):
    /// only these get a screen, and only its unmarked rows. Gone once the login ends.
    @ObservationIgnored private var marked: [UInt64: ObjectIdentifier] = [:]
    /// Terminals whose history the app's renderer keeps (their helper said so): they scroll locally.
    @ObservationIgnored private var scrollback: Set<UInt64> = []
    /// Every multiplexer kind the helper hosts (Settings rows, per-name preferences).
    private(set) var multiplexers: [HelperClient.Multiplexer] = []

    private struct Key: Hashable {
      enum Entity: Hashable {
        case node(String)
        case divider(UInt64, Int)
      }
      let route: HelperBackend.Route
      let entity: Entity
    }

    enum Endpoint: Hashable, Sendable {
      case local
      case remote(SSHConnectionID)
      var connection: SSHConnectionID? {
        if case .remote(let id) = self { id } else { nil }
      }
    }

    struct Keys: Encodable {
      struct Binding: Encodable {
        let session: String
        let pid: Int32
        let start: [UInt64]
      }
      let terminal: UInt64
      let keys: Data
      let binding: Binding
    }

    func key(_ tab: UUID, binding: Keys.Binding, endpoint: Endpoint, encode: () -> Void) -> Bool {
      guard !stopped, terminals[tab] != nil else { return false }
      keys[tab] = (binding, endpoint)
      encode()
      return true
    }

    var retained: [Detached] {
      var entries = Set(owned.compactMap { $0.backend.flatMap { routes[$0] } }).map { route in
        Detached(route: route, presentation: owned.filter { $0.backend.flatMap { routes[$0] } == route },
          nodes: Dictionary(uniqueKeysWithValues: identity.compactMap { key, id in
            guard key.route == route, case .node(let node) = key.entity else { return nil }
            return (node, id)
          }), key: snapshots[route]?.key)
      }
      for var entry in restoring.values {
        let known = Set(entries.flatMap(\.presentation).map(\.id))
        entry.presentation = entry.presentation.compactMap { saved in
          guard !known.contains(saved.id) else { return nil }
          return workspace?.spaces.first { $0.id == saved.id }
        }
        guard !entry.presentation.isEmpty else { continue }
        if let index = entries.firstIndex(where: { $0.route == entry.route }) {
          entries[index].presentation += entry.presentation
          entries[index].nodes.merge(entry.nodes) { current, _ in current }
        } else { entries.append(entry) }
      }
      return entries
    }

    init(
      workspace: Workspace?, renderer: HelperRenderer?, endpoint: Endpoint = .local, granted: Set<String>? = nil,
      host: HostID = .local, previous: HelperWorkspace? = nil, retained saved: [Detached] = []
    ) {
      self.workspace = workspace
      self.renderer = renderer
      self.endpoint = endpoint
      self.granted = granted
      self.host = host
      // Explicit restoration survives reassociation of the old workspace to the new connection.
      let retained = saved.isEmpty ? previous?.retained ?? [] : saved
      if let previous {
        identity = previous.identity
        if saved.isEmpty { detachedRoutes = previous.detachedRoutes }
        terminals = previous.terminals
        pendingSpaces = previous.pendingSpaces
        renaming = previous.renaming.mapValues { (name: $0.name, node: nil, failed: false) }
      }
      let shutdown = TerminalRuntime.shared.shutdown
      let ready = Task {
        await shutdown?.value
        try Task.checkCancellation()
        return try await HelperApp.shared.connection(endpoint)
      }
      self.ready = ready
      let discovery = Task<Catalogs, any Error> {
        let connection = try await ready.value
        // Enqueue in order without waiting for any catalog's response.
        let kinds: HelperConnection.Call<[HelperClient.Multiplexer]> = await connection.submit(
          "multiplexers.list", params: [String: String]())
        let backends: HelperConnection.Call<[HelperBackend]> = await connection.submit(
          "backends.list", params: [String: String]())
        let launches: HelperConnection.Call<[HelperClient.Launch]>?
        if endpoint == .local {
          launches = await connection.submit("launches.list", params: [String: String]())
        } else { launches = nil }
        return (kinds, backends, launches)
      }
      self.discovery = discovery
      catalog = Task { try await discovery.value.backends.value }
      let kinds = Task { try await discovery.value.kinds.value }
      self.kinds = kinds
      launchers = Task {
        // The wrappers go into this Mac's shells.
        guard let request = try await discovery.value.launches else { return }
        let launches = try await request.value
        try TerminalRuntime.shared.herdrLaunch.install(
          launches.compactMap { launch in
            launch.program.map { ShellCommandWrapper.helper(program: $0, key: launch.key) }
          })
      }
      Task {
        do {
          let connection = try await ready.value
          guard !stopped else {
            return
          }
          self.connection = connection
          connected(.success(connection))
          multiplexers = try await kinds.value
          for var entry in retained where permitted(entry.route.mux) {
            if saved.isEmpty, previous != nil {
              entry.presentation.removeAll { space in workspace?.spaces.contains(where: { $0.id == space.id }) != true }
            }
            if !entry.presentation.isEmpty { reopen(entry) }
          }
          claim(TerminalRuntime.shared.preferences.spaces)
          backends = try await catalog.value
          try await launchers.value
        } catch {
          connected(.failure(error))
          fail(error)
        }
      }
    }

    private func connected(_ result: Result<HelperConnection, any Error>) {
      if case .failure(let error) = result, connection == nil { failure = error }
      let callers = waiting
      waiting = []
      callers.forEach { $0.resume(with: result) }
    }

    /// The name of the multiplexer behind a backend id; nil before that backend opened.
    func multiplexer(of backend: UInt64) -> String? { kind(of: backend)?.name }

    func source(_ route: HelperBackend.Route) -> String {
      backends.first { $0.route == route && $0.label != $0.key }?.label
        ?? multiplexers.first { $0.mux == route.mux }?.name ?? "Terminal"
    }

    /// Whether a backend's sessions live outside the app (tmux, herdr servers), so the app can let go of them.
    func external(_ backend: UInt64) -> Bool { kind(of: backend)?.external == true }

    func kind(of backend: UInt64) -> HelperClient.Multiplexer? {
      routes[backend].flatMap { route in multiplexers.first { $0.mux == route.mux } }
    }

    /// Whether each external multiplexer's clients started in terminals open as spaces (by name).
    func claim(_ spaces: [String: Bool]) {
      for kind in multiplexers where kind.external {
        if stopped {
          if !spaces[on: kind.name] || !permitted(kind.mux) {
            for space in owned where space.backend.flatMap({ routes[$0]?.mux }) == kind.mux {
              if let node = space.node { close(node, policy: .terminate) }
            }
          }
          continue
        }
        perform { [self] client in
          guard permitted(kind.mux) else {
            print("Helper claim omitted: endpoint=\(endpoint), mux=\(kind.name), reason=not-granted")
            return
          }
          try await client.claim(kind.mux, enabled: spaces[on: kind.name])
        }
      }
    }

    var disposable: Bool {
      stopped && owned.isEmpty && detachedRoutes.isEmpty && detachedWindows.isEmpty
    }

    /// The spaces this helper's backends show: ids are only unique within one helper.
    private var owned: [Space] {
      workspace?.spaces.filter { $0.remote == endpoint.connection } ?? []
    }

    /// The tab showing a terminal of this helper, or the tab an observed terminal belongs to.
    func tab(of terminal: UInt64) -> UUID? {
      owned.flatMap(\.tabs).first { $0.terminal == terminal }?.id ?? observed[terminal]
        ?? controlTerminals.first { $0.value == terminal }?.key
        ?? gateways.first { $0.value.terminal == terminal }?.key
        ?? assigned[terminal].flatMap { terminals[$0] == nil ? nil : $0 }
    }

    /// The tab whose renderer receives `terminal`'s output: the one that attached it here (it had
    /// that terminal's snapshot) while it still shows it, else the first tab showing it. A retained
    /// tab can keep a terminal id an earlier helper process gave another pane: as the first tab
    /// with that id it would get this pane's output on a renderer that never had its snapshot.
    static func receiver(
      of terminal: UInt64, attached: [UInt64: UUID], connected: Set<UUID>, shown: UUID?,
      showing: (UUID) -> UInt64?
    ) -> UUID? {
      if let tab = attached[terminal], connected.contains(tab), showing(tab) == terminal { return tab }
      return shown
    }

    func terminal(of tab: UUID) -> UInt64? {
      Self.target(tab, in: owned) ?? observedTerminal(tab) ?? controlTerminals[tab]
        ?? gateways[tab]?.terminal ?? assigned.first { $0.value == tab }?.key
    }

    private func permitted(_ mux: UInt64) -> Bool {
      guard let granted else { return true }
      return multiplexers.first { $0.mux == mux }.map { !$0.external || granted.contains($0.name) } ?? false
    }

    /// Retire only withdrawn backend routes; their terminal views stay available for recovery.
    func reduce(to features: Set<String>) -> Set<UUID> {
      granted = granted.map { $0.intersection(features) } ?? features
      let withdrawn = Set(routes.values.filter { !permitted($0.mux) })
      let spaces = owned.filter { space in space.backend.flatMap { routes[$0] }.map(withdrawn.contains) == true }
      let tabs = Set(spaces.flatMap(\.tabs).map(\.id))
      for route in withdrawn {
        opening.removeValue(forKey: route)?.cancel()
        subscribing.removeValue(forKey: route)?.task.cancel()
        observations.removeValue(forKey: route).map { connection?.cancel($0) }
        activating.remove(route)
      }
      for (backend, route) in routes where withdrawn.contains(route) { lost.insert(backend) }
      for tab in tabs {
        if let terminal = spaces.flatMap(\.tabs).first(where: { $0.id == tab })?.terminal {
          TerminalRuntime.shared.chat.helperExited(endpoint, terminal: terminal,
            status: "The terminal's integration is disabled. This transcript is read-only.", disabled: true)
        }
        pending.removeValue(forKey: tab)?.cancel()
        sending.removeValue(forKey: tab)?.cancel()
        attachments.removeValue(forKey: tab).map { connection?.cancel($0) }
        terminals[tab]?.onInput = { _ in }
        terminals[tab]?.onResize = { _ in }
        TerminalRuntime.shared.views[tab]?.history?.setActive(false)
      }
      backends.removeAll { !permitted($0.mux) }
      return tabs.union(spaces.flatMap(\.containers).map(\.id))
    }

    func bind(_ workspace: Workspace?) {
      self.workspace = workspace
    }

    func prepare(_ tab: TerminalTab) {
      // A connecting placeholder has no terminal of its own: the helper's reply brings it.
      guard tab.terminal == nil, !tab.isConnecting, pending[tab.id] == nil,
        !TerminalRuntime.shared.hosts.reconnect.awaitingRestore(tab.id) else { return }
      pending[tab.id] = Task {
        defer { pending.removeValue(forKey: tab.id) }
        do {
          let backends = try await catalog.value
          guard let backend = backends.first(where: { $0.isDefault == true }) else {
            throw HelperFailure(
              code: "unavailable", message: "Default backend is unavailable.")
          }
          let parent = try await root(backend)
          let client = try await client()
          // Without the wrappers a terminal still works; the failure is reported once.
          try? await launchers.value
          creating[backend.route, default: 0] += 1
          defer {
            creating[backend.route, default: 0] -= 1
            if creating[backend.route] == 0, let topology = snapshots[backend.route] {
              do { try apply(topology, route: backend.route) } catch { fail(error) }
            }
          }
          // A remote helper gets nothing of this Mac: no environment (tokens, mailbox paths, PATH) and
          // no Mac path to start in; its terminal starts where its parent is.
          let local = endpoint == .local
          let terminal = try await client.create(
            .init(
              parent: parent, beside: nil, cwd: local ? (tab.machine == .local ? tab.directory : Home.url.path) : nil, launch: nil,
              command: tab.launchCommand ?? tab.machine.command(), environment: local ? environment() : []))
          guard !stopped, owned.flatMap(\.tabs).contains(where: { $0.id == tab.id }) else {
            _ = try await client.close(.init(node: terminal, policy: .terminate))
            throw CancellationError()
          }
          assigned[terminal] = tab.id
          workspace?.updateLayout { next in
            if let (s, p, t) = next.location(ofTab: tab.id) {
              next.spaces[s].panes[p].tabs[t].terminal = terminal
            }
          }
          if let channel = terminals[tab.id] { attach(tab.id, channel) }
          return terminal
        } catch {
          if !stopped { fail(error) }
          throw error
        }
      }
    }

    private func root(_ backend: HelperBackend) async throws -> UInt64 {
      if let task = opening[backend.route] { return try await task.value }
      let task = Task<UInt64, any Error> {
        let client = try await client()
        let (stream, continuation) = AsyncThrowingStream<UInt64, any Error>.makeStream(
          bufferingPolicy: .bufferingNewest(1))
        let observer = try await client.open(backend.route) { [weak self] result in
          DispatchQueue.main.async {
            MainActor.assumeIsolated {
              self?.update(result, route: backend.route)
              switch result {
              case .success(.topology(let topology)):
                if let root = topology.nodes.first(where: { $0.kind == .workspace }) {
                  continuation.yield(root.id)
                  continuation.finish()
                }
              case .failure(let error): continuation.finish(throwing: error)
              default: break
              }
            }
          }
        }
        observations[backend.route] = observer
        for try await root in stream { return root }
        throw CancellationError()
      }
      opening[backend.route] = task
      return try await task.value
    }

    private func id(_ key: Key) -> UUID {
      if let id = identity[key] { return id }
      let id = UUID()
      identity[key] = id
      return id
    }

    func open(_ backend: HelperBackend) {
      open(backend.route)
    }

    private func open(_ route: HelperBackend.Route) {
      // A claim can arrive on several subscriptions at once (backend and attach streams): one open.
      guard !stopped, observations[route] == nil, subscribing[route] == nil else { return }
      let generation = UUID()
      operations += 1
      let task = Task {
        defer { operations -= 1; retire() }
        do {
          try Task.checkCancellation()
          let client = try await client()
          try Task.checkCancellation()
          guard !stopped, subscribing[route]?.id == generation else { return }
          let key = restoring[route]?.key ?? snapshots[route]?.key ?? route.key
          // Reopening registers a new backend generation. Restore against the old one first.
          if let entry = restoring[route], let topology = snapshots[route] {
            for node in entry.presentation.compactMap(\.node) where topology.nodes.contains(where: { $0.id == node && $0.detached }) {
              print("Helper restore membership: route=\(route), node=\(node), parent=\(topology.backend)")
              try await client.move(.init(node: node, parent: topology.backend, before: nil))
              try Task.checkCancellation()
              guard !stopped, subscribing[route]?.id == generation else { return }
            }
          }
          let observer = try await client.open(.init(mux: route.mux, key: key)) { [weak self] result in
            DispatchQueue.main.async {
              MainActor.assumeIsolated {
                guard let self, self.subscribing[route]?.id == generation else { return }
                self.update(result, route: route)
              }
            }
          }
          if stopped || Task.isCancelled || subscribing[route]?.id != generation {
            client.connection.cancel(observer)
          } else { observations[route] = observer }
        } catch {
          guard !stopped, !Task.isCancelled, subscribing[route]?.id == generation else { return }
          update(.failure(error), route: route)
        }
      }
      subscribing[route] = (generation, task)
    }

    /// Claims and exit of a terminal this helper runs that the app shows another way (an SSH login):
    /// clients started in it open as spaces like those started in a shown tab.
    func observe(_ terminal: UInt64, tab: UUID) {
      observed[terminal] = tab
      // The tab still shows what this Mac ran before SSH: a remote helper must never read it.
      if endpoint != .local, let surface = TerminalRuntime.shared.views[tab]?.surface {
        surface.markRows()
        marked[terminal] = ObjectIdentifier(surface)
      }
      perform { client in
        // Claims are checked against the multiplexer names, so those come first.
        self.multiplexers = try await self.kinds.value
        let request = try await client.observe(.init(terminal: terminal)) { [weak self] result in
          DispatchQueue.main.async {
            MainActor.assumeIsolated {
              guard let self, self.observed[terminal] == tab else { return }
              self.update(result)
            }
          }
        }
        if self.stopped || self.observed[terminal] != tab { client.connection.cancel(request) }
        else { self.attachments[tab] = request }
      }
    }

    /// Retire the completed login observation without disconnecting its external backends.
    func unobserve(_ tab: UUID) {
      guard observes(tab) else { return }
      for terminal in observed.filter({ $0.value == tab }).keys { marked.removeValue(forKey: terminal) }
      observed = observed.filter { $0.value != tab }
      attachments.removeValue(forKey: tab).map { connection?.cancel($0) }
      print("Helper login observation retired: endpoint=\(endpoint), tab=\(tab)")
    }

    /// This helper observes the terminal shown in `tab` (an SSH login on its host).
    func observes(_ tab: UUID) -> Bool { observed.values.contains(tab) }

    /// `space`'s multiplexer client lost its transport (old app: an offline tmux gateway).
    func offline(_ space: Space) -> Bool { space.backend.map(lost.contains) == true }

    /// This helper's id for the terminal it observes in `tab` (an SSH login on its host).
    func observedTerminal(_ tab: UUID) -> UInt64? { observed.first { $0.value == tab }?.key }

    /// The observed login's screen text for this helper: all of it for the local helper; for a remote
    /// one only the rows its session wrote, and nothing unless the tab's surface was marked when the
    /// login started (Surface.readUnmarkedText) or once the login ended.
    func observedText(_ terminal: UInt64, surface: any TerminalBackend) -> String? {
      guard endpoint != .local else { return surface.readText(.active) }
      return marked[terminal] == ObjectIdentifier(surface) ? surface.readUnmarkedText() : nil
    }

    /// This helper owns the tab's control transport, including a hidden gateway between sessions.
    func controls(_ tab: UUID, session: Int? = nil) -> Bool {
      if let session { return controlInput[tab]?.session == session }
      return controlTerminals[tab] != nil || gateways[tab] != nil
    }

    /// A launcher hidden as some helper's gateway. An SSH login's tmux -CC is the remote helper's gateway,
    /// while the login's own terminal stays in this Mac's topology: no topology may show it as a space again.
    private func carried(_ tab: UUID) -> Bool {
      gateways[tab] != nil || workspace?.helpers.values.contains { $0.gateways[tab] != nil } == true
    }

    /// Terminal clients carrying this backend, including ordinary SSH control mode.
    func sources(_ backend: UInt64) -> [UUID] {
      controlBackends.compactMap { $0.value == backend ? $0.key : nil }
    }

    /// Explicit disconnect dismisses this origin's imported work; transport loss retains it.
    func disconnect(_ tab: UUID) {
      guard let backend = controlBackends[tab] ?? gateways[tab]?.backend else { return }
      let nodes = owned.filter { $0.backend == backend }.compactMap(\.node)
      print("Helper control disconnect: tab=\(tab), backend=\(backend), spaces=\(nodes)")
      for node in nodes { close(node, policy: .detach) }
    }

    /// A closed launcher can still carry the transport of its shown backend.
    func retains(_ tab: UUID) -> Bool {
      guard !stopped, workspace?.allTabIDs.contains(tab) == false,
        let gateway = gateways[tab],
        let topology = snapshots.values.first(where: { $0.backend == gateway.backend })
      else { return false }
      return topology.nodes.contains { $0.kind == .workspace && !$0.detached }
    }

    /// The renderer control protocol is tmux DCS, independently of remote statistics.
    var allowsControl: Bool { granted?.contains("tmux") ?? true }

    func control(_ tab: UUID, event: HelperClient.Control.Event, bytes: Data?, session: Int) {
      guard !stopped, event != .start || allowsControl else { return }
      if event == .start {
        controlInput.removeValue(forKey: tab)?.end.finish()
        let (stream, end) = AsyncStream<Void>.makeStream()
        controlInput[tab] = (session, stream, end)
      }
      if event == .data, let bytes, let last = controlEvents[tab]?.indices.last,
        controlEvents[tab]?[last].event == .data, controlEvents[tab]?[last].session == session,
        controlEvents[tab]?[last].bytes != nil {
        controlEvents[tab]?[last].bytes?.append(bytes)
      } else {
        controlEvents[tab, default: []].append((event, bytes, session))
      }
      if controlling[tab] == nil { flush(tab) }
    }

    private func flush(_ tab: UUID) {
      guard !stopped, let events = controlEvents.removeValue(forKey: tab) else { return }
      controlling[tab] = Task {
        defer {
          controlling.removeValue(forKey: tab)
          flush(tab)
        }
        for (event, bytes, session) in events {
          defer {
            if controlTerminals[tab] == nil, controlInput[tab]?.session == session {
              controlInput.removeValue(forKey: tab)?.end.finish()
              print("Helper control input released: tab=\(tab), session=\(session), event=\(event)")
            }
          }
          // A refused route reads its bytes as plain output; a later session starts a fresh claim.
          let plain = { if let bytes { TerminalRuntime.shared.views[tab]?.surface?.plain(bytes, session: session) } }
          if refused[tab] == session { plain(); continue }
          do {
            try Task.checkCancellation()
            let client = try await client()
            if event == .start {
              let terminal = owned.flatMap(\.tabs).first { $0.id == tab }?.terminal
                ?? observedTerminal(tab) ?? gateways[tab]?.terminal
              guard let terminal else { continue }
              controlTerminals[tab] = terminal
            }
            guard let terminal = controlTerminals[tab] else { continue }
            let claimed = try await client.control(
              .init(terminal: terminal, event: event, bytes: bytes))
            if event == .start {
              guard let claimed else {
                controlTerminals.removeValue(forKey: tab)
                continue
              }
              let route = HelperBackend.Route(mux: claimed.mux, key: claimed.key)
              if routes[claimed.backend] == nil { routes[claimed.backend] = route }
              if let context = workspace?.hosts.terminals[tab] { origins[claimed.backend] = context }
              controlBackends[tab] = claimed.backend
              imports[route, default: []].insert(tab)
              lost.remove(claimed.backend)
              activating.insert(route)
              open(route)
            } else if event == .end {
              controlTerminals.removeValue(forKey: tab)
              if let backend = controlBackends.removeValue(forKey: tab) { lost.insert(backend) }
            }
          } catch let failure as HelperFailure where failure.code == "terminal_unavailable" && event == .data {
            controlTerminals.removeValue(forKey: tab)
            if let backend = controlBackends.removeValue(forKey: tab) { lost.insert(backend) }
            refused[tab] = session
            plain()
          } catch {
            controlTerminals.removeValue(forKey: tab)
            if let backend = controlBackends.removeValue(forKey: tab) { lost.insert(backend) }
            if !stopped { fail(error) }
          }
        }
      }
    }

    func detachSpace(_ space: Space) {
      guard let node = space.node, !space.containers.isEmpty else { return }
      close(node, policy: .detach)
    }

    /// Reopens the routes holding these detached spaces and shows only the requested ones.
    func restore(_ ids: Set<UUID>) {
      if stopped {
        let entries = detachedRoutes.compactMap { source -> Detached? in
          guard restoring[source.route] == nil else { return nil }
          var entry = source; entry.presentation.removeAll { !ids.contains($0.id) }
          return entry.presentation.isEmpty ? nil : entry
        }
        guard !entries.isEmpty else { return }
        guard let recovery else { fail(HerdrFailure("The original SSH connection cannot be restored.")); return }
        for entry in entries { restoring[entry.route] = entry }
        Task {
          defer { for entry in entries { restoring[entry.route] = nil } }
          do {
            try await TerminalRuntime.shared.ssh.restore(recovery, entries: entries)
            for id in ids { forget(id) }
            if detachedRoutes.isEmpty, let id = endpoint.connection,
              TerminalRuntime.shared.helpers[endpoint] === self {
              TerminalRuntime.shared.disconnect(id)
            }
          } catch {
            let names = Set(entries.compactMap { entry in multiplexers.first { $0.mux == entry.route.mux }?.name }).sorted().joined(separator: ", ")
            fail(HerdrFailure("Could not restore detached \(names) work. " + error.localizedDescription))
          }
        }
        return
      }
      let requested = Set(detachedRoutes.filter { $0.presentation.contains { ids.contains($0.id) } }.map(\.route)
        + detachedWindows.filter { ids.contains($0.id) }.map(\.route))
      // A dismissal withholds the whole route's topology, including other restored tabs.
      let waiting = dismissals.values.filter { $0.route.map(requested.contains) == true }.map(\.task)
      if !waiting.isEmpty {
        for entry in detachedRoutes {
          if let space = entry.presentation.first(where: { ids.contains($0.id) }) {
            placeholder(entry.route, name: space.name, host: space.hostID)
          }
        }
        var selected: [HelperBackend.Route: Set<UUID>] = [:]
        for entry in detachedRoutes {
          let values = Set(entry.presentation.map(\.id)).intersection(ids)
          if !values.isEmpty { selected[entry.route, default: []].formUnion(values) }
        }
        for window in detachedWindows where ids.contains(window.id) {
          placeholder(window.route, name: window.name, host: window.host)
          selected[window.route, default: []].insert(window.id)
        }
        let pending = selected.map { ($0.key, restoreSpaces[$0.key], $0.value) }
        let generation = restoration
        Task {
          for task in waiting { await task.value }
          let pending = pending.filter {
            self.restoration == generation && self.restoreSpaces[$0.0] == $0.1
          }
          let selected = pending.flatMap { $0.2 }
          if !selected.isEmpty { self.restore(Set(selected)) }
          for (route, _, _) in pending { self.restored(route) }
        }
        return
      }
      for window in detachedWindows where ids.contains(window.id) {
        if let failure = missingWindows[window.id] {
          imports.removeValue(forKey: window.route)
          fail(failure)
          continue
        }
        guard restoringWindows.insert(window.id).inserted else { continue }
        placeholder(window.route, name: window.name, host: window.host)
        let task = perform { client in
          var complete = false
          defer {
            if !Task.isCancelled {
              self.restoreRequests.removeValue(forKey: window.id)
              self.restoringWindows.remove(window.id)
              self.restored(window.route)
              if complete {
                self.forget(window.id)
                if let topology = self.snapshots[window.route] {
                  self.imported(topology, route: window.route)
                }
              } else { self.imports.removeValue(forKey: window.route) }
            }
          }
          do {
            if let parent = window.parent {
              try await client.move(.init(node: window.node, parent: parent, before: nil))
            } else {
              try await client.place(.init(node: window.node, place: .init(kind: "workspace", label: window.name)))
            }
          } catch {
            if let failure = error as? HelperFailure, failure.code == "missing" { self.missingWindows[window.id] = failure }
            throw error
          }
          await self.published()
          try Task.checkCancellation()
          complete = true
        }
        restoreRequests[window.id] = (window.route, window.node, task)
      }
      for var entry in detachedRoutes where restoring[entry.route] == nil {
        entry.presentation.removeAll { !ids.contains($0.id) }
        if let space = entry.presentation.first {
          placeholder(entry.route, name: space.name, host: space.hostID)
          reopen(entry)
        }
      }
    }

    private func placeholder(_ route: HelperBackend.Route, name: String, host: HostID) {
      guard let workspace, restoreSpaces[route] == nil,
        !owned.contains(where: { $0.structured && $0.backend.flatMap { routes[$0] } == route })
      else { return }
      var tab = TerminalTab(directory: workspace.defaultDirectory)
      tab.isConnecting = true
      var space = Space(name: name, tab: tab)
      space.hostID = host
      space.remote = endpoint.connection
      restoreSpaces[route] = space.id
      workspace.addSpace(space)
    }

    private func restored(_ route: HelperBackend.Route) {
      guard restoring[route] == nil, !restoreRequests.values.contains(where: { $0.route == route }),
        let space = restoreSpaces.removeValue(forKey: route) else { return }
      workspace?.updateLayout { next in
        if let index = next.spaces.firstIndex(where: { $0.id == space }) { next.removeSpace(at: index) }
      }
    }

    private func cancel(_ id: UUID) {
      guard let request = restoreRequests.removeValue(forKey: id) else { return }
      request.task.cancel()
      imports.removeValue(forKey: request.route)
      restoringWindows.remove(id)
      restored(request.route)
      perform { try await $0.close(.init(node: request.node, policy: .detach)) }
    }

    func forget(_ id: UUID) {
      cancel(id)
      missingWindows.removeValue(forKey: id)
      if let window = detachedWindows.first(where: { $0.id == id }) {
        forgottenWindows.insert(id)
        detachedWindows.removeAll { $0.id == id }
        if let descriptor = node(window.node), descriptor.parent == nil {
          perform { try await $0.close(.init(node: window.node, policy: .terminate)) }
        }
      }
      for index in detachedRoutes.indices { detachedRoutes[index].presentation.removeAll { $0.id == id } }
      detachedRoutes.removeAll { $0.presentation.isEmpty }
    }

    func isRestoring(_ id: UUID) -> Bool {
      pendingSpaces.contains(id) || restoringWindows.contains(id) || restoring.values.contains { $0.presentation.contains { $0.id == id } }
    }

    private func reopen(_ entry: Detached) {
      let route = entry.route
      for (key, value) in entry.nodes {
        identity[Key(route: route, entity: .node(key))] = value
      }
      restoring[route] = entry
      opening.removeValue(forKey: route)?.cancel()
      subscribing.removeValue(forKey: route)?.task.cancel()
      if let request = observations.removeValue(forKey: route) {
        connection?.cancel(request)
      }
      open(
        HelperBackend(
          mux: route.mux, key: route.key,
          label: entry.presentation.first?.name ?? "", isDefault: nil))
    }

    func restoreDetached(_ entries: [Detached]) {
      detachedRoutes = entries
      for entry in entries { reopen(entry) }
    }

    /// What an app-spawned shell gets, for a helper shell: the app's integration (ssh/launch wrappers,
    /// launch mailbox) and Ghostty's shell integration (prompt marks, title, cursor) as the terminal
    /// engine would launch it (Term Launch). Only variables that differ from this process are sent.
    func environment() -> [String] {
      let process = ProcessInfo.processInfo.environment
      var environment = process.merging(TerminalRuntime.shared.herdrLaunch.nativeEnvironment(for: scope)) { _, new in new }
      // Tests isolate shells from the account's startup files like app-spawned ones (TerminalView);
      // here the user layer sits behind the native wrapper files, so it is that layer that goes empty.
      let testing: [(String, String)] =
        process["DISPATCH_TESTING"] == "1"
        ? [("HOME", Home.url.path), ("DISPATCH_NATIVE_ZDOTDIR", "/var/empty"), ("DISPATCH_TESTING", "1")] : []
      let identifier: UInt64?
      do {
        identifier = try TerminalRuntime.shared.config.map { _ in
          try JSONDecoder().decode(UInt64.self, from: AppReplay.query(kind: "terminal.launch", input: Data()) {
            try JSONEncoder().encode(UInt64.random(in: 1 ... .max))
          })
        }
      } catch { AppReplay.fail(error); return [] }
      if let config = TerminalRuntime.shared.config, let identifier,
        let launch = try? Launch(
          command: nil, directory: nil, overrides: testing, config: config, environment: environment,
          resources: process["GHOSTTY_RESOURCES_DIR"].flatMap { $0.isEmpty ? nil : $0 },
          id: identifier)
      {
        environment = launch.env
      }
      return environment.filter { process[$0.key] != $0.value }
        .sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }
    }

    func create(
      _ parent: UInt64, in space: Space?,
      splitting split: Workspace.NativeSplitPlacement? = nil
    ) {
      guard let space, let backend = space.backend, !lost.contains(backend),
        let route = routes[backend]
      else { return }
      // A new space (created under the backend) or window shows at once as connecting; the next topology
      // replaces it keeping its ids, an error removes it.
      let newSpace = split == nil && parent == backend ? addSpacePlaceholder(after: space) : nil
      let placeholder = newSpace == nil && !space.containers.isEmpty ? addPlaceholder(to: space, splitting: split) : nil
      let selected = workspace?.activeTab?.id
      // Counted before the request so no topology applies (and drops the placeholder) in between.
      creating[route, default: 0] += 1
      // A creation focuses what it creates: that is this app's focus, not another client's.
      focusing[route, default: 0] += 1
      let operation = UUID()
      operations += 1
      let task = Task {
        defer {
          creations[route]?.removeValue(forKey: operation)
          if creations[route]?.isEmpty == true { creations.removeValue(forKey: route) }
          creating[route, default: 0] -= 1
          if !stopped, creating[route] == 0, let topology = snapshots[route] {
            do { try apply(topology, route: route) } catch { fail(error) }
          }
          print("Helper creation settled: route=\(route), placeholder=\(String(describing: placeholder)), selectedAtStart=\(String(describing: selected)), selected=\(String(describing: workspace?.activeTab?.id)), window=\(String(describing: workspace?.current?.selectedContainer)), server=\(String(describing: snapshots[route]?.focus)), creating=\(creating[route, default: 0])")
          // Native creation changes focus; a later selection wins after its identities are published.
          if !stopped, let workspace, workspace.activeTab?.id != selected,
            workspace.current?.backend == backend, let terminal = workspace.activeTab?.terminal
          {
            focus(terminal)
          }
          settled(route)
          operations -= 1
          retire()
        }
        do {
          let client = try await client()
          try? await launchers.value
          if external(backend), newSpace == nil, let anchor = space.activeTab?.terminal {
            try await client.focus(.init(node: anchor))
          }
          let terminal = try await client.create(
            .init(
              // A multiplexer server knows its focused pane's directory (old app: tmux -c #{pane_current_path}).
              parent: parent, beside: nil, cwd: external(backend) ? nil : space.activeTab?.directory,
              launch: nil, environment: endpoint == .local ? environment() : []))
          await published()
          print("Helper creation reply: terminal=\(terminal), placeholder=\(String(describing: placeholder)), selected=\(String(describing: workspace?.activeTab?.id)), server=\(String(describing: snapshots[route]?.focus))")
          // A window dismissed while pending: the server's window is detached (kept running, listed), never shown.
          if let placeholder, dismissed.remove(placeholder) != nil {
            unseen.insert(terminal)
            closing.insert(terminal)
            detaching.insert(terminal)
            return
          }
          if !stopped, newSpace == nil { selections[terminal] = (space.id, placeholder == nil ? split : nil) }
          if let newSpace, let tab = workspace?.spaces.first(where: { $0.id == newSpace })?.tabs.first {
            assigned[terminal] = tab.id
            adoptedSpaces[terminal] = newSpace
          }
          // Selection, drafts and chat follow the ids the connecting window showed.
          if let placeholder,
            let tab = owned.flatMap(\.containers).first(where: { $0.id == placeholder })?.terminals.first
          {
            assigned[terminal] = tab.id
            adopted[terminal] = placeholder
          }
        } catch {
          if let placeholder { _ = dismiss(placeholder) }
          if let newSpace {
            pendingSpaces.remove(newSpace)
            workspace?.updateLayout { $0.spaces.removeAll { $0.id == newSpace } }
          }
          if !stopped { fail(error) }
        }
      }
      creations[route, default: [:]][operation] = task
    }

    /// A connecting space after `space`'s server's spaces, selected like the server's new focused workspace.
    private func addSpacePlaceholder(after space: Space) -> UUID {
      var tab = TerminalTab(directory: space.activeTab?.directory ?? workspace?.defaultDirectory ?? "/")
      tab.isConnecting = true
      var placeholder = Space(name: Workspace.nextSpaceName(in: workspace?.spaces ?? []), tab: tab, usesDirectoryName: true)
      placeholder.backend = space.backend
      placeholder.remote = space.remote
      pendingSpaces.insert(placeholder.id)
      placeholder.hostID = space.hostID
      workspace?.updateLayout { next in
        let last = next.spaces.lastIndex { $0.backend == space.backend && $0.remote == space.remote }
        next.spaces.insert(placeholder, at: last.map { $0 + 1 } ?? next.spaces.endIndex)
        next.selectedSpace = placeholder.id
      }
      return placeholder.id
    }

    private func addPlaceholder(to space: Space, splitting split: Workspace.NativeSplitPlacement?) -> UUID {
      var tab = TerminalTab(directory: space.activeTab?.directory ?? workspace?.defaultDirectory ?? "/")
      tab.isConnecting = true
      var arrangement = PaneArrangement(tab: tab)
      arrangement.panes = [Pane(id: tab.id, tabs: [tab])]
      arrangement.layout = .pane(tab.id)
      arrangement.focusedPane = tab.id
      let container = ContainerTab(id: UUID(), node: 0, name: "", arrangement: arrangement)
      placeholders.insert(container.id)
      workspace?.updateLayout { next in
        guard let s = next.spaces.firstIndex(where: { $0.id == space.id }) else { return }
        next.spaces[s].containers.append(container)
        let windows = next.spaces[s].containers.map(\.id), near = next.spaces[s].selectedContainer
        next.spaces[s].presentation?.reconcile(windows, near: near)
        next.spaces[s].selectedContainer = container.id
        // The new window is the active one at once, as the old native new window was.
        if split?.apply(to: &next, createdTab: tab.id) != true { next.selectTab(tab.id) }
      }
      return container.id
    }

    /// Removes a pending window (by its id or its tab's); false when `id` is not a placeholder.
    func dismiss(_ id: UUID) -> Bool {
      if let route = restoreSpaces.first(where: { route, space in
        space == id || workspace?.spaces.first(where: { $0.id == space })?.tabs.contains(where: { $0.id == id }) == true
      })?.key {
        if restoring.removeValue(forKey: route) != nil {
          subscribing.removeValue(forKey: route)?.task.cancel()
          if let request = observations.removeValue(forKey: route) { connection?.cancel(request) }
        }
        for id in restoreRequests.filter({ $0.value.route == route }).map(\.key) { cancel(id) }
        restored(route)
        return true
      }
      guard let workspace,
        let container = owned.flatMap(\.containers).first(where: {
          placeholders.contains($0.id) && ($0.id == id || $0.terminals.contains { $0.id == id })
        })
      else { return false }
      placeholders.remove(container.id)
      dismissed.insert(container.id)
      for id in [container.id] + container.terminals.map(\.id) { renaming.removeValue(forKey: id) }
      workspace.updateLayout { next in
        for s in next.spaces.indices where next.spaces[s].containers.contains(where: { $0.id == container.id }) {
          next.spaces[s].containers.removeAll { $0.id == container.id }
          let windows = next.spaces[s].containers.map(\.id)
          if next.spaces[s].selectedContainer == container.id { next.spaces[s].selectedContainer = windows.last }
          let selected = next.spaces[s].selectedContainer
          next.spaces[s].presentation?.reconcile(windows, near: selected)
        }
      }
      return true
    }

    /// Panes of structured spaces render the grid their server keeps (another client may hold it
    /// smaller) and report the cells they could show, so the server can grow back; others follow
    /// their own PTY size.
    func constrain(_ tab: TerminalTab) {
      guard let terminal = tab.terminal, let view = TerminalRuntime.shared.views[tab.id] else { return }
      let structured = owned.contains { $0.structured && $0.tabs.contains { $0.id == tab.id } }
      let size = structured ? snapshots.values.lazy.flatMap(\.nodes).first { $0.id == terminal }?.size : nil
      view.reportAvailable = size == nil ? nil : { [weak self] _, _ in
        guard let self else { return }
        self.operations += 1
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          defer { self.operations -= 1; self.retire() }
          guard !self.stopped, let container = self.owned.flatMap(\.containers).first(where: {
            $0.terminals.contains { $0.terminal == terminal }
          }) else { return }
          var sizes: [UUID: CGSize] = [:]
          @MainActor func measure(_ layout: PaneLayout) -> CGSize? {
            let id: UUID = switch layout {
            case .pane(let id), .split(let id, _, _, _): id
            }
            if let size = sizes[id] { return size }
            let size: CGSize
            switch layout {
            case .pane(let id):
              guard let tab = container.arrangement.panes.first(where: { $0.id == id })?.activeTab,
                let available = TerminalRuntime.shared.views[tab.id]?.availableSize else { return nil }
              size = available
            case .split(_, let axis, let first, let second):
              guard let a = measure(first), let b = measure(second) else { return nil }
              size = axis == .columns
                ? CGSize(width: a.width + b.width + 1, height: max(a.height, b.height))
                : CGSize(width: max(a.width, b.width), height: a.height + b.height + 1)
            }
            sizes[id] = size
            return size
          }
          guard let total = measure(container.arrangement.layout) else { return }
          @MainActor func resize(_ layout: PaneLayout, at origin: CGPoint) {
            switch layout {
            case .pane(let id):
              guard let size = sizes[id],
                let terminal = container.arrangement.panes.first(where: { $0.id == id })?.activeTab?.terminal else { return }
              let grid = HelperTopology.Grid(
                columns: UInt16(clamping: max(1, Int(origin.x + size.width) - Int(origin.x))),
                rows: UInt16(clamping: max(1, Int(origin.y + size.height) - Int(origin.y))))
              guard self.available[terminal] != grid else { return }
              self.available[terminal] = grid
              self.resize(terminal)
            case .split(_, let axis, let first, let second):
              guard let size = measure(first) else { return }
              resize(first, at: origin)
              resize(second, at: CGPoint(x: origin.x + (axis == .columns ? size.width + 1 : 0),
                                        y: origin.y + (axis == .rows ? size.height + 1 : 0)))
            }
          }
          resize(container.arrangement.layout, at: .zero)
        }
      }
      view.tmuxGrid = size.map { CGSize(width: Double($0.columns), height: Double($0.rows)) }
    }

    /// Available geometry can precede attachment; only a confirmed subscription accepts sizes.
    private func resize(_ terminal: UInt64) {
      guard let generation = sized[terminal] else { return }
      perform { client in
        guard !self.stopped, self.sized[terminal] == generation,
          let size = self.available[terminal] else { return }
        try await client.resize(.init(terminal: terminal, size: size))
      }
    }

    /// A node the helper published (its key, PTY device, ...).
    func node(_ id: UInt64) -> HelperTopology.Node? {
      snapshots.values.lazy.flatMap(\.nodes).first { $0.id == id }
    }

    /// Whether a tab's terminal scrolls in its multiplexer (until its helper says the renderer keeps
    /// that history).
    func scrolls(_ tab: UUID) -> Bool {
      owned.flatMap(\.tabs).first { $0.id == tab }?.terminal.map { !scrollback.contains($0) } ?? false
    }

    func seek(_ tab: UUID, offset: UInt64) async throws {
      guard let terminal = owned.flatMap(\.tabs).first(where: { $0.id == tab })?.terminal else {
        throw CancellationError()
      }
      let client = try await client()
      let _: HelperClient.Empty = try await client.connection.request("terminals.seek", params: ["terminal": terminal, "offset": offset])
    }

    /// Sends a gesture to the tab's multiplexer; when the renderer keeps that history instead, `local`
    /// replays the gesture there (scrolls(tab) is false from then on).
    func scroll(
      _ tab: UUID, lines: Int64, page: Bool, at cell: (column: UInt16, row: UInt16)?, modifiers: UInt8,
      local: @escaping @MainActor () -> Void
    ) {
      guard let terminal = owned.flatMap(\.tabs).first(where: { $0.id == tab })?.terminal else { return }
      perform { client in
        do {
          try await client.scroll(
            .init(
              terminal: terminal, lines: lines, page: page, column: cell?.column, row: cell?.row,
              modifiers: modifiers))
        } catch let failure as HelperFailure where failure.code == "scrollback_app_owned" {
          self.scrollback.insert(terminal)
          TerminalRuntime.shared.views[tab]?.history?.setActive(false)
          TerminalRuntime.shared.views[tab]?.history = nil
          local()
        }
      }
    }

    func focus(_ node: UInt64) {
      let route = owned.first { space in
        space.node == node || space.containers.contains { $0.node == node }
          || space.tabs.contains { $0.terminal == node }
      }?.backend.flatMap { routes[$0] }
      let previous = route.flatMap { snapshots[$0] }
      let leaf = owned.flatMap(\.tabs).contains { $0.terminal == node }
      if leaf { focusTargets[node, default: 0] += 1 }
      print("Helper focus intent: node=\(node), leaf=\(leaf), pending=\(focusTargets[node, default: 0])")
      if let route { focusing[route, default: 0] += 1 }
      let task = perform { client in
        try await client.focus(.init(node: node))
        await self.published()
      }
      Task {
        // client() can fail before perform enters its operation closure.
        await task.value
        if leaf {
          focusTargets[node, default: 1] -= 1
          if focusTargets[node] == 0 { focusTargets.removeValue(forKey: node) }
        }
        if let route { settled(route, unchanged: previous) }
      }
    }

    /// Focus updates held during our requests become authoritative when the requests settle.
    private func settled(_ route: HelperBackend.Route, unchanged: HelperTopology? = nil) {
      focusing[route, default: 1] -= 1
      print("Helper focus settled: route=\(route), pending=\(focusing[route, default: 0]), creating=\(creating[route, default: 0]), selected=\(String(describing: workspace?.activeTab?.terminal)), server=\(String(describing: snapshots[route]?.focus))")
      guard !stopped, focusing[route, default: 0] == 0, creating[route, default: 0] == 0,
        let topology = snapshots[route]
      else { return }
      // An unchanged focus reply needs no reconcile when the native selection is already
      // visible. Lifecycle callers never supply unchanged; deferred work still reconciles.
      if topology == unchanged, let focus = topology.focus, lastFocus[route] == focus,
        workspace?.current?.remote == endpoint.connection, workspace?.current?.backend == topology.backend,
        workspace?.activeTab?.terminal == focus, operations == 0,
        restoring.isEmpty, restoreRequests.isEmpty, pendingSpaces.isEmpty, placing.isEmpty,
        imports[route] == nil, !dismissals.values.contains(where: { $0.route == route })
      { return }
      lastFocus[route] = workspace?.activeTab?.terminal
      do { try apply(topology, route: route) } catch { fail(error) }
    }

    @discardableResult
    func resize(_ divider: UUID, fraction: Double) -> Bool {
      guard let node = dividers[divider] else { return false }
      perform { try await $0.resize(.init(node: node, ratio: fraction)) }
      return true
    }

    enum Target {
      case node(UInt64)
      case item(UUID)
    }

    @discardableResult
    func move(_ target: Target, parent: Target, before: Target?, select: Bool = false) -> Bool {
      let resolve: (Target) -> UInt64? = { target in
        switch target {
        case .node(let node): node
        case .item(let id): Self.target(id, in: self.owned)
        }
      }
      let source = owned.first { space in
        switch target {
        case .node(let node): space.node == node || space.containers.contains { $0.node == node }
        case .item(let id): space.id == id || space.containers.contains { $0.id == id }
        }
      }
      let waiting = source?.backend.flatMap { routes[$0] }.flatMap { creations[$0] }.map { Array($0.values) } ?? []
      let departure = source.flatMap { placing[$0.id] }
      let placement: Task<Void, Never>?
      switch parent {
      case .node: placement = nil
      case .item(let id):
        guard owned.contains(where: { $0.id == id && $0.node != nil }) || placing[id] != nil else { return false }
        placement = placing[id]
      }
      let window = detachedWindows.first { $0.node == resolve(target) }?.id
      let selected: UUID? = select ? source?.containers.first { container in
        switch target {
        case .node(let node): container.node == node
        case .item(let id): container.id == id
        }
      }?.id : nil
      let focused = workspace?.activeTab?.id
      let route = selected.flatMap { _ in source?.backend.flatMap { routes[$0] } }
      if let route { focusing[route, default: 0] += 1 }
      perform { client in
        defer {
          if let window { self.restoringWindows.remove(window) }
          if let route { self.settled(route) }
        }
        // A provisional source must settle before another move can consume its native identity.
        await departure?.value
        await placement?.value
        for task in waiting { await task.value }
        guard let node = resolve(target), let parent = resolve(parent),
          before == nil || before.flatMap(resolve) != nil else { throw CancellationError() }
        try await client.move(.init(node: node, parent: parent, before: before.flatMap(resolve)))
        await self.published()
        if let selected, self.workspace?.activeTab?.id == focused {
          try await client.focus(.init(node: node))
          await self.published()
          for (route, topology) in self.snapshots where topology.nodes.contains(where: { $0.id == node }) {
            try self.apply(topology, route: route)
          }
          if self.workspace?.activeTab?.id == focused { self.workspace?.selectContainer(selected) }
        }
        if let window { self.forget(window) }
      }
      return true
    }

    /// The topology that shows `terminal` outside `space` selects it there if `space` is still selected.
    func follow(_ terminal: UInt64, from space: UUID) {
      following[terminal] = space
    }

    /// Partial moves are published by the owning backend; moving a leaf must not remove its whole window.
    func relocate(_ node: UInt64, to place: HelperClient.Placement.Place, optional: Bool = false) {
      perform { client in
        do {
          try await client.place(.init(node: node, place: place))
          await self.published()
        } catch let failure as HelperFailure where optional && failure.code == "unsupported" {
          self.following.removeValue(forKey: node)
          NSLog("[HelperPlacement] optional %@ unsupported for terminal=%llu: %@", place.kind, node, failure.message)
        }
      }
    }

    /// Moves a window (by its node or its only terminal) into a new space of its session. It shows there at
    /// once and keeps its ids when the server's topology moves it; a refused move shows the server's state again.
    /// `select`: show the new space (a user's move); otherwise only when it holds the active terminal.
    func place(_ node: UInt64, inNewSpace label: String, select: Bool = false, optional: Bool = false) {
      guard let workspace,
        let origin = owned.first(where: { $0.containers.contains { $0.node == node || $0.terminals.contains { $0.terminal == node } } }),
        let window = origin.containers.first(where: { $0.node == node || $0.terminals.contains { $0.terminal == node } }),
        // A window still moving (its space pending) leaves the server space it left first.
        let from = origin.node ?? window.terminals.lazy.compactMap({ $0.terminal.flatMap { self.movedFrom[$0] } }).first
      else {
        let window = detachedWindows.first { $0.node == node }?.id
        perform { client in
          defer { if let window { self.restoringWindows.remove(window) } }
          try await client.place(.init(node: node, place: .init(kind: "workspace", label: label)))
          await self.published()
          if let window { self.forget(window) }
        }
        return
      }
      if window.node != node, window.terminals.count > 1 {
        if select || workspace.activeSurfaceID == window.terminals.first(where: { $0.terminal == node })?.id {
          follow(node, from: origin.id)
        }
        relocate(node, to: .init(kind: "extract", label: label), optional: optional)
        return
      }
      var moved = Space(name: label, tab: window.terminals[0])
      let departure = placing[origin.id]
      moved.backend = origin.backend
      moved.remote = origin.remote
      pendingSpaces.insert(moved.id)
      moved.containers = [window]
      moved.hostID = workspace.loggedHost(moved) ?? origin.hostID
      moved.selectedContainer = window.id
      let terminals = window.terminals.compactMap(\.terminal)
      for terminal in terminals {
        adoptedSpaces[terminal] = moved.id
        movedFrom[terminal] = from
      }
      let selected = select || workspace.activeSurfaceID.map { active in window.terminals.contains { $0.id == active } } == true
      workspace.updateLayout { next in
        guard let s = next.spaces.firstIndex(where: { $0.id == origin.id }) else { return }
        next.spaces[s].containers.removeAll { $0.id == window.id }
        if next.spaces[s].selectedContainer == window.id { next.spaces[s].selectedContainer = next.spaces[s].containers.first?.id }
        let windows = next.spaces[s].containers.map(\.id), near = next.spaces[s].selectedContainer
        next.spaces[s].presentation?.reconcile(windows, near: near)
        next.spaces.insert(moved, at: s + 1)
        if next.spaces[s].containers.isEmpty { next.spaces.remove(at: s) }
        self.pendingSpaces.remove(origin.id)
        if selected { next.selectedSpace = moved.id }
      }
      if stopped { return }
      confirming.insert(moved.id)
      let focused = workspace.activeSurfaceID
      let route = origin.backend.flatMap { routes[$0] }
      if selected, let route { focusing[route, default: 0] += 1 }
      var complete = false
      let task = perform { client in
        await departure?.value
        try Task.checkCancellation()
        try await client.place(.init(node: node, place: .init(kind: "workspace", label: label)))
        await self.published()
        try Task.checkCancellation()
        guard !self.stopped else { throw CancellationError() }
        self.confirming.remove(moved.id)
        print("Helper placement confirmed: space=\(moved.id), node=\(node), selected=\(String(describing: self.workspace?.selectedSpace))")
        if let route, let topology = self.snapshots[route] { try self.apply(topology, route: route) }
        if selected, let focused, self.workspace?.activeSurfaceID == focused,
          let container = self.owned.flatMap(\.containers).first(where: { $0.terminals.contains { $0.id == focused } })
        {
          try await client.focus(.init(node: container.node))
          await self.published()
        }
        complete = true
      }
      placing[moved.id] = task
      Task {
        // Client acquisition can fail before perform enters the operation closure.
        await task.value
        self.placing.removeValue(forKey: moved.id)
        self.confirming.remove(moved.id)
        if !self.stopped, !complete {
          for terminal in terminals where self.adoptedSpaces[terminal] == moved.id {
            self.adoptedSpaces.removeValue(forKey: terminal)
            self.movedFrom.removeValue(forKey: terminal)
          }
          self.pendingSpaces.remove(moved.id)
          self.workspace?.updateLayout { $0.spaces.removeAll { $0.id == moved.id } }
          if let route, let topology = self.snapshots[route] {
            do { try self.apply(topology, route: route) } catch { self.fail(error) }
          }
        }
        if selected, let route {
          if self.stopped { self.focusing[route, default: 1] -= 1 }
          else { self.settled(route) }
        }
      }
    }

    @discardableResult
    func close(_ node: UInt64, policy: HelperClient.Policy) -> Task<Void, Never> {
      if policy == .detach, let pending = dismissals[node] { return pending.task }
      let source = owned.first { space in
        space.node == node || space.containers.contains { $0.node == node }
          || space.tabs.contains { $0.terminal == node }
      }
      let route = source?.backend.flatMap { routes[$0] }
      if let source, let route { hosts[route] = source.hostID }
      let waiting = route.flatMap { creations[$0] }.map { Array($0.values) } ?? []
      let spaces = owned.filter { $0.node == node }
      let entry = (spaces.isEmpty ? nil : route).map { route in
        Detached(
          route: route, presentation: spaces,
          nodes: Dictionary(
            uniqueKeysWithValues: identity.compactMap { key, id in
              guard key.route == route, case .node(let node) = key.entity else { return nil }
              return (node, id)
            }), key: snapshots[route]?.key)
      }
      // Gone at once; a refused close shows it again from the server's next topology.
      closing.insert(node)
      // A space whose last window this closes goes too.
      let removed = Set(owned.filter { $0.node == node }.map(\.id))
      let terminals = owned.flatMap { space in
        space.tabs.filter { tab in
          tab.terminal == node || space.containers.contains { container in
            container.node == node && container.terminals.contains { $0.id == tab.id }
          }
        }.map(\.id)
      }
      let continuing = route.map { route in
        owned.contains { space in
          space.backend.flatMap { routes[$0] } == route
            && space.node.map { !closing.contains($0) } == true
        }
      } ?? false
      var seen = Set<UUID>()
      let released = (terminals + spaces.flatMap { $0.tabs.flatMap(\.surfaceIDs) }).filter { seen.insert($0).inserted }
      var dismissed = false
      let dismiss = { [self] in
        guard !dismissed else { return }
        dismissed = true
        let selected = workspace?.activeTab?.id
        workspace?.updateLayout { next in
          for s in next.spaces.indices.reversed() where removed.contains(next.spaces[s].id) {
            next.removeSpace(at: s)
          }
          for id in terminals { next.detachTab(id) }
        }
        if let workspace, workspace.activeTab?.id != selected, let tab = workspace.activeTab {
          workspace.selectTab(tab.id)
        }
        if policy == .detach, let entry {
          if let index = detachedRoutes.firstIndex(where: { $0.route == entry.route }) {
            let saved = Set(entry.presentation.map(\.id))
            detachedRoutes[index].presentation.removeAll { saved.contains($0.id) }
            detachedRoutes[index].presentation += entry.presentation
            detachedRoutes[index].nodes.merge(entry.nodes) { _, latest in latest }
          } else {
            detachedRoutes.append(entry)
          }
        }
        if policy == .detach {
          workspace?.onCloseTabs(released)
        }
      }
      // Last remote consumers keep their helper alive; a local control client must return to its shell.
      let barrier = endpoint.connection != nil || source?.backend.map { backend in
        sources(backend).contains { controlInput[$0] != nil }
      } == true
      if policy != .detach || entry == nil || stopped || continuing || !barrier { dismiss() }
      print("Helper close: node=\(node), policy=\(policy), barrier=\(barrier), terminals=\(terminals), selected=\(String(describing: workspace?.activeTab?.id))")
      var confirmed = false
      if stopped {
        if policy != .detach { workspace?.onCloseTabs(released) }
        return Task {}
      }
      let task = perform { client in
        for task in waiting { await task.value }
        guard !self.stopped, !Task.isCancelled else { return }
        let result: HelperClient.Closed
        do { result = try await client.close(.init(node: node, policy: policy)) } catch {
          if !self.stopped, !Task.isCancelled, policy != .detach { self.reveal(node) }
          throw error
        }
        guard !self.stopped, !Task.isCancelled else {
          print("Helper close retired: node=\(node), policy=\(policy)")
          return
        }
        confirmed = result.closed
        if result.closed, policy != .detach {
          print("Helper close confirmed: node=\(node), terminals=\(terminals)")
          self.workspace?.onCloseTabs(terminals)
        }
        if !result.closed, !result.confirmation, policy != .detach { self.reveal(node) }
        // A detached node stays in the server's topology (marked detached): it is no longer closing.
        if policy == .detach { self.closing.remove(node) }
        if policy == .detach, result.closed {
          await self.published()
          guard !self.stopped, !Task.isCancelled else { return }
          if let route, let topology = self.snapshots[route],
            !topology.nodes.contains(where: { $0.kind == .workspace && !$0.detached }) {
            let streams = self.controlBackends.compactMap { tab, backend in
              backend == topology.backend ? self.controlInput[tab]?.stream : nil
            }
            for stream in streams { for await _ in stream {} }
          }
          guard !self.stopped, !Task.isCancelled else { return }
          dismiss()
        }
        // A busy multiplexer window keeps its work: it is detached without asking (old NativeTabClose:
        // busy or unknown detaches); only the app's own shells ask before ending their processes.
        if result.confirmation, self.snapshots.values.contains(where: { topology in
          topology.nodes.contains { $0.id == node } && self.external(topology.backend)
        }) {
          self.close(node, policy: .detach)
        } else if result.confirmation {
          if AppDelegate.confirmClose() {
            guard !self.stopped, !Task.isCancelled else { return }
            do { _ = try await client.close(.init(node: node, policy: .terminate)) }
            catch {
              if !self.stopped, !Task.isCancelled { self.reveal(node) }
              throw error
            }
          } else if !self.stopped, !Task.isCancelled { self.reveal(node) }
        }
      }
      if policy == .detach {
        let dismissal = Task {
          await task.value
          print("Helper detach settled: node=\(node), confirmed=\(confirmed), stopped=\(self.stopped), saved=\(entry?.presentation.map(\.id) ?? [])")
          self.dismissals.removeValue(forKey: node)
          guard !self.stopped, !Task.isCancelled else { return }
          if !confirmed {
            entry?.presentation.forEach { self.forget($0.id) }
            self.reveal(node)
          }
          if let route, let topology = self.snapshots[route] {
            do { try self.apply(topology, route: route) } catch { self.fail(error) }
          }
        }
        dismissals[node] = (route, dismissal)
        return dismissal
      }
      return task
    }

    /// Shown at once; a failed rename shows the server's name again from its latest topology.
    /// Runs a multiplexer command on the server of `node` (its own prefix bindings).
    func command(_ node: UInt64, _ text: String) {
      let route = snapshots.first { $0.value.nodes.contains { $0.id == node } }?.key
      if let route { commanding[route, default: 0] += 1 }
      perform { client in
        defer { if let route { self.commanding[route, default: 1] -= 1 } }
        try await client.command(.init(node: node, command: text))
        await self.published()
        if let route, let topology = self.snapshots[route] { try self.apply(topology, route: route) }
      }
    }

    func rename(_ id: UUID, name: String) {
      guard let space = owned.first(where: { $0.id == id || $0.containers.contains { $0.id == id } || $0.tabs.contains { $0.id == id } }),
        space.backend.map(lost.contains) != true else { return }
      let node = Self.target(id, in: owned)
      renaming[id] = (name, node, false)
      workspace?.updateLayout { next in Self.name(id, name, in: &next.spaces) }
      guard let node else { return }
      perform { client in
        do { try await client.rename(.init(node: node, name: name)) } catch {
          if self.renaming[id]?.name == name {
            self.renaming[id]?.failed = true
            self.reapply(node)
          }
          throw error
        }
      }
    }

    private static func target(_ id: UUID, in spaces: [Space]) -> UInt64? {
      for space in spaces {
        if space.id == id { return space.node }
        for container in space.containers {
          if container.id == id { return container.node == 0 ? nil : container.node }
        }
        if let tab = space.tabs.first(where: { $0.id == id }) { return tab.terminal }
      }
      return nil
    }

    private static func name(_ id: UUID, _ name: String, in spaces: inout [Space]) {
      for s in spaces.indices {
        if spaces[s].id == id { spaces[s].name = name }
        for c in spaces[s].containers.indices {
          if spaces[s].containers[c].id == id {
            spaces[s].containers[c].name = name
            spaces[s].containers[c].renamed = true
          }
        }
        for p in spaces[s].panes.indices {
          for t in spaces[s].panes[p].tabs.indices where spaces[s].panes[p].tabs[t].id == id {
            spaces[s].panes[p].tabs[t].customTitle = name.isEmpty ? nil : name
          }
        }
      }
    }

    /// A close that didn't happen: the latest topology shows the node again with its identities.
    private func reveal(_ node: UInt64) {
      closing.remove(node)
      reapply(node)
    }

    /// The latest topology that has `node`, shown again (a refused change needs no new publication).
    private func reapply(_ node: UInt64) {
      for (route, topology) in snapshots where topology.nodes.contains(where: { $0.id == node }) {
        do { try apply(topology, route: route) } catch { fail(error) }
      }
    }

    func publish(_ screen: HelperClient.Screen) {
      guard !stopped, (screens[screen.terminal] ?? published[screen.terminal]) != screen
      else {
        return
      }
      screens[screen.terminal] = screen
      guard publishing[screen.terminal] == nil else { return }
      publishing[screen.terminal] = Task {
        defer { publishing.removeValue(forKey: screen.terminal) }
        do {
          let client = try await client()
          while let next = screens[screen.terminal] {
            try Task.checkCancellation()
            try await client.publish(next)
            published[screen.terminal] = next
            if screens[screen.terminal] == next {
              screens.removeValue(forKey: screen.terminal)
            }
          }
        } catch { if !stopped { fail(error) } }
      }
    }

    func detach(_ tab: UUID) {
      guard !retains(tab) else { return }
      gateways.removeValue(forKey: tab)
      keys.removeValue(forKey: tab)
      if let request = attachments.removeValue(forKey: tab) {
        connection?.cancel(request)
      }
      terminals.removeValue(forKey: tab)?.close()
      renderer?.revoke(tab)
    }

    func cancelRestores() { restoration = UUID() }

    func stop(retaining: Bool = false) {
      if !retaining { cancelRestores() }
      guard !stopped else { return }
      stopped = true
      marked.removeAll()
      sized.removeAll()
      // An unconfirmed creation has no native terminal to retain across transport loss.
      let unconfirmed = owned.flatMap { space in
        (pendingSpaces.contains(space.id) ? space.tabs : space.containers
          .filter { placeholders.contains($0.id) }.flatMap(\.terminals))
          .filter { $0.terminal == nil }.map(\.id)
      }
      workspace?.updateLayout { next in
        for tab in unconfirmed { next.detachTab(tab) }
      }
      placeholders.formIntersection(owned.flatMap(\.containers).map(\.id))
      pendingSpaces.formIntersection(owned.map(\.id))
      if !unconfirmed.isEmpty {
        print("Helper pending creations retired: endpoint=\(endpoint), terminals=\(unconfirmed)")
      }
      placing.values.forEach { $0.cancel() }
      confirming.removeAll()
      ready.cancel()
      discovery.cancel()
      connected(.failure(CancellationError()))
      catalog.cancel()
      kinds.cancel()
      launchers.cancel()
      opening.values.forEach { $0.cancel() }
      subscribing.values.forEach { $0.task.cancel() }
      subscribing.removeAll()
      pending.values.forEach { $0.cancel() }
      sending.values.forEach { $0.cancel() }
      controlling.values.forEach { $0.cancel() }
      controlInput.values.forEach { $0.end.finish() }
      controlInput.removeAll()
      controlEvents.removeAll()
      restoreRequests.values.forEach { $0.task.cancel() }
      restoreRequests.removeAll()
      // A queued restore may still be awaiting final detach when its transport retires.
      // Preserve its cancellation token so it can resume through authenticated recovery.
      if !retaining { restoreSpaces.removeAll() }
      restoringWindows.removeAll()
      controlTerminals.removeAll()
      activating.removeAll()
      unrouted.removeAll()
      publishing.values.forEach { $0.cancel() }
      screens.removeAll()
      published.removeAll()
      selections.removeAll()
      for tab in Array(terminals.keys) {
        TerminalRuntime.shared.views[tab]?.history?.setActive(false)
        if retaining {
          attachments.removeValue(forKey: tab).map { connection?.cancel($0) }
          terminals[tab]?.onInput = { _ in }
          terminals[tab]?.onResize = { _ in }
        } else { detach(tab) }
      }
      for tab in observed.values { attachments.removeValue(forKey: tab).map { connection?.cancel($0) } }
      for request in observations.values { connection?.cancel(request) }
      connection = nil
    }

    func client(_ endpoint: Endpoint? = nil) async throws -> HelperClient {
      let endpoint = endpoint ?? self.endpoint
      guard !stopped else { throw CancellationError() }
      // Keys of a remote agent shown in a local tab go to that agent's helper.
      guard endpoint == self.endpoint else { return HelperClient(try await HelperApp.shared.connection(endpoint)) }
      if let connection { return HelperClient(connection) }
      if let failure { throw failure }
      let connection = try await withCheckedThrowingContinuation { waiting.append($0) }
      guard !stopped else { throw CancellationError() }
      return HelperClient(connection)
    }

    /// Deliver topology notifications queued before a mutation's acknowledgement.
    private func published() async {
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
      }
    }

    private func retire() {
      guard operations == 0, let workspace else { return }
      let ended = gateways.compactMap { tab, gateway -> UUID? in
        guard TerminalRuntime.shared.views[tab] != nil,
          let topology = snapshots.values.first(where: { $0.backend == gateway.backend }),
          !topology.nodes.contains(where: { $0.kind == .workspace && !$0.detached })
        else { return nil }
        return tab
      }
      for tab in ended {
        guard let gateway = gateways[tab], !closing.contains(gateway.terminal) else { continue }
        // The renderer is only a subscription. Retire its owned shell too, or a later native
        // topology will import the hidden launcher again as an ordinary space. An SSH login's shell
        // is the terminal this Mac's helper started for its tab, never the remote login observed here.
        let shell = workspace.helpers.values.compactMap { helper in
          helper.assigned.first { $0.value == tab }.map { (helper: helper, terminal: $0.key) }
        }.first
        if let shell {
          if shell.helper.snapshots.values.contains(where: { $0.nodes.contains { $0.id == shell.terminal } }) {
            shell.helper.close(shell.terminal, policy: .terminate)
          }
        } else if !observes(tab) {
          close(gateway.terminal, policy: .terminate)
        }
      }
      workspace.onCloseTabs(ended)
    }

    @discardableResult
    private func perform(_ operation: @escaping @MainActor (HelperClient) async throws -> Void) -> Task<Void, Never> {
      operations += 1
      return Task {
        defer { operations -= 1; retire() }
        do {
          let client = try await client()
          try await operation(client)
        } catch { if !stopped && !Task.isCancelled { fail(error) } }
      }
    }

    func dismissError() { error = nil }

    private func fail(_ failure: any Error) {
      // Canceling this app's retired subscriptions is ordinary lifetime cleanup.
      // A target that ended meanwhile (a session that exited, a closed window) is shown by the topology;
      // its refused operation is not an error (c1654cc: tmux %exit was a clean detach).
      guard !(failure is CancellationError), (failure as? HelperFailure)?.code != "expired" else { return }
      error = failure.localizedDescription
    }

    func suspend(_ tab: UUID) -> () -> Void {
      let token = UUID()
      suspensions[tab, default: []].insert(token)
      terminals[tab]?.suspend(token, true)
      print("Helper output suspended: endpoint=\(endpoint), tab=\(tab), token=\(token)")
      return { [weak self] in
        guard let self, suspensions[tab]?.remove(token) != nil else { return }
        if suspensions[tab]?.isEmpty == true { suspensions.removeValue(forKey: tab) }
        terminals[tab]?.suspend(token, false)
        print("Helper output released: endpoint=\(endpoint), tab=\(tab), token=\(token)")
      }
    }

    func attach(_ tab: UUID, _ channel: HelperTerminal) {
      terminals[tab] = channel
      for token in suspensions[tab] ?? [] { channel.suspend(token, true) }
      guard let terminal = owned.flatMap(\.tabs).first(where: { $0.id == tab })?.terminal else {
        return
      }
      assigned[terminal] = tab
      let generation = UUID()
      sized.removeValue(forKey: terminal)
      TerminalRuntime.shared.views[tab]?.onProcessExit = nil
      // Bytes and sizes go to the terminal the tab still shows: after the terminal closed (handoff,
      // close, exit) a tearing-down view still reports focus-out and sizes, and they have no target.
      let bound: @MainActor @Sendable () -> Bool = { [weak self] in
        guard let self else { return false }
        let space = owned.first { $0.tabs.contains { $0.id == tab && $0.terminal == terminal } }
        let gateway = gateways[tab].flatMap { $0.terminal == terminal ? $0 : nil }
        guard space != nil || gateway != nil else { return false }
        let route = (gateway?.backend ?? space?.backend).flatMap { routes[$0] }
        return route.map { permitted($0.mux) } ?? (granted == nil)
      }
      // Input waits for the helper to confirm the attach (terminal.attached), in order: a multiplexer
      // may refuse input to a terminal it has not attached yet. A failed or closed attach releases it.
      let (attached, confirm) = AsyncStream<Void>.makeStream()
      channel.onInput = { [weak self] bytes in
        guard let self, bound() else { return }
        let checked = keys.removeValue(forKey: tab)
        let previous = sending[tab]
        sending[tab] = Task {
          await previous?.value
          for await _ in attached {}
          // The original terminal can be shown before detach-client finishes. Its input still
          // belongs to the shell, never to the multiplexer's protocol running in that PTY.
          while let control = controlInput[tab], !Task.isCancelled { for await _ in control.stream {} }
          guard !Task.isCancelled, bound() else { return }
          do {
            let client = try await client(checked?.1)
            guard !Task.isCancelled, bound() else { return }
            if let checked {
              let _: HelperClient.Empty = try await client.connection.request(
                "terminals.keys",
                params: Keys(terminal: terminal, keys: bytes, binding: checked.0))
            } else {
              try await client.input(.init(terminal: terminal, bytes: bytes))
            }
          } catch { if !stopped { fail(error) } }
        }
      }
      channel.onResize = { [weak self] size in
        // A pane rendering its server grid reports the cells it could show instead (constrain).
        guard TerminalRuntime.shared.views[tab]?.tmuxGrid == nil, bound() else { return }
        guard let self, available[terminal] != size else { return }
        available[terminal] = size
        resize(terminal)
      }
      channel.onClose = { [weak self] in
        confirm.finish()
        if self?.sized[terminal] == generation { self?.sized.removeValue(forKey: terminal) }
        self?.controlInput.removeValue(forKey: tab)?.end.finish()
        self?.keys.removeValue(forKey: tab)
        if let request = self?.attachments.removeValue(forKey: tab) {
          self?.connection?.cancel(request)
        }
        self?.terminals.removeValue(forKey: tab)
      }
      NSLog("[HelperOrder] attach schedule terminal=%llu tab=%@", terminal, tab.uuidString)
      perform { client in
        guard bound() else { confirm.finish(); return }
        let request: UInt64
        do {
          NSLog("[HelperOrder] attach submit terminal=%llu tab=%@", terminal, tab.uuidString)
          let size = self.available[terminal] ?? channel.grid
          request = try await client.attach(
            .init(terminal: terminal, size: size, takeover: false)
          ) { [weak self] result in
            switch result {
            case .success(.attached), .failure: confirm.finish()
            default: break
            }
            DispatchQueue.main.async {
              MainActor.assumeIsolated {
                // A hidden SSH origin still carries output for another helper's control gateway.
                guard let self, !self.stopped, self.terminals[tab] === channel,
                  self.assigned[terminal] == tab else { return }
                switch result {
                case .success(.attached):
                  self.sized[terminal] = generation
                  if bound(), let latest = self.available[terminal], latest != size { self.resize(terminal) }
                case .failure: self.sized.removeValue(forKey: terminal)
                default: break
                }
                self.update(result)
              }
            }
          }
        } catch {
          confirm.finish()
          throw error
        }
        if self.stopped || self.terminals[tab] !== channel || !bound() {
          client.connection.cancel(request)
        } else {
          self.attachments[tab] = request
        }
      }
    }

    private func update(
      _ result: Result<HelperClient.Update, any Error>, route: HelperBackend.Route? = nil
    ) {
      guard !stopped else { return }
      if case .failure = result, let route {
        subscribing.removeValue(forKey: route)?.task.cancel()
        observations.removeValue(forKey: route)
        // An offline visible target remains required after a failed reopen. Retrying
        // must not turn its missing native identity into an empty successful restore.
        let visible = restoring[route]?.presentation.contains { saved in
          workspace?.spaces.contains { $0.id == saved.id } == true
        } == true
        if !visible, restoring.removeValue(forKey: route) != nil { restored(route) }
      }
      if let route, !permitted(route.mux) { return }
      do {
        switch try result.get() {
        case .opened(let backend):
          lost.remove(backend)
          if let route {
            for tab in imports[route] ?? [] where controlBackends[tab] != nil {
              controlBackends[tab] = backend
            }
            if let canonical = routes[backend], canonical != route {
              if let sources = imports.removeValue(forKey: route) {
                imports[canonical, default: []].formUnion(sources)
                if activating.remove(route) != nil { activating.insert(canonical) }
                if let entry = detachedRoutes.first(where: { $0.route == canonical }) {
                  reopen(entry)
                } else {
                  subscribing.removeValue(forKey: canonical)?.task.cancel()
                  if let request = observations.removeValue(forKey: canonical) {
                    connection?.cancel(request)
                  }
                  open(canonical)
                }
              }
            } else { routes[backend] = route }
          }
          if let topology = unrouted.removeValue(forKey: backend) {
            update(.success(.topology(topology)))
          }
        case .topology(let topology):
          guard let route = routes[topology.backend] else {
            unrouted[topology.backend] = topology
            return
          }
          guard permitted(route.mux) else { return }
          guard snapshots[route] != topology else { return }
          var adopted: [(HelperWorkspace, UUID)] = []
          if imports[route] != nil, creating[route, default: 0] == 0, let workspace {
            let roots = topology.nodes.filter { $0.kind == .workspace && !$0.detached }.map(\.key)
            var presentation: [Space] = []
            var names: [String: UUID] = [:]
            for helper in workspace.helpers.values where helper.host == host {
              for entry in helper.detachedRoutes
                where helper.multiplexers.first(where: { $0.mux == entry.route.mux })?.name == kind(of: topology.backend)?.name {
                let matched = Set(roots.compactMap { entry.nodes[$0] })
                let saved = entry.presentation.filter { matched.contains($0.id) }
                guard !saved.isEmpty else { continue }
                presentation += saved
                try names.merge(entry.nodes) { current, next in
                  guard current == next else { throw HerdrFailure("Detached terminal identity is ambiguous.") }
                  return current
                }
                adopted += saved.map { (helper, $0.id) }
              }
            }
            if !presentation.isEmpty {
              for (key, value) in names { identity[Key(route: route, entity: .node(key))] = value }
              restoring[route] = Detached(route: route, presentation: presentation, nodes: names, key: topology.key)
            }
          }
          snapshots[route] = topology
          if creating[route, default: 0] == 0 { try apply(topology, route: route) }
          for (helper, id) in adopted {
            helper.forget(id)
          }
          if !adopted.isEmpty { TerminalRuntime.shared.prune() }
          inherit(topology.backend)
          if activating.contains(route), !(multiplexer(of: topology.backend) == "herdr" && imports[route] != nil),
            let space = owned.first(where: { $0.backend == topology.backend }) {
            activating.remove(route)
            workspace?.selectSpace(space.id)
          }
          imported(topology, route: route)
        case .output(let output):
          guard route == nil,
            let tab = Self.receiver(
              of: output.terminal, attached: assigned, connected: Set(terminals.keys), shown: tab(of: output.terminal),
              showing: { tab in self.owned.flatMap(\.tabs).first { $0.id == tab }?.terminal })
          else { return }
          terminals[tab]?.write(output.bytes)
        case .history(let history):
          guard route == nil, let tab = tab(of: history.terminal) else { return }
          TerminalRuntime.shared.views[tab]?.updateHistory(history)
        case .exit(let exit):
          marked.removeValue(forKey: exit.terminal)
          TerminalRuntime.shared.chat.helperExited(endpoint, terminal: exit.terminal)
          selections.removeValue(forKey: exit.terminal)
          publishing.removeValue(forKey: exit.terminal)?.cancel()
          screens.removeValue(forKey: exit.terminal)
          published.removeValue(forKey: exit.terminal)
          if let tab = tab(of: exit.terminal) {
            TerminalRuntime.shared.views[tab]?.onProcessExit = {}
            terminals[tab]?.finish()
          }
        case .agent(let agent):
          NSLog("[ChatHelperTrace] agent.changed terminal=%llu tab=%@", agent.terminal, tab(of: agent.terminal)?.uuidString ?? "none")  // TEMP diagnostics (todo cleanup)
          if let tab = tab(of: agent.terminal) { TerminalRuntime.shared.chat.helperChanged(tab) }
        case .backend(let event):
          if let error = event.error {
            if let mux = event.mux, let kind = multiplexers.first(where: { $0.mux == mux }) {
              let location = endpoint.connection == nil ? "" : "remote "
              throw HelperFailure(code: error.code, message: "Could not start the \(location)\(kind.name) server. " + error.message)
            }
            throw error
          }
          guard let mux = event.mux, let key = event.key, let backend = event.backend else {
            throw HelperFailure(code: "invalid_response", message: "Missing backend route")
          }
          guard let tab = tab(of: event.terminal), permitted(mux) else { return }
          let route = HelperBackend.Route(mux: mux, key: key)
          if routes[backend] == nil { routes[backend] = route }
          imports[route, default: []].insert(tab)
          // Explicit launch restores this server's detached spaces and individual windows.
          let detached = Set(detachedRoutes.filter { $0.route == route }.flatMap { $0.presentation.map(\.id) }
            + detachedWindows.filter { $0.route == route }.map(\.id))
          if !detached.isEmpty {
            print("Helper launch restoring: route=\(route), entries=\(detached)")
            restore(detached)
            return
          }
          if let topology = snapshots[route] { imported(topology, route: route) }
          open(HelperBackend(mux: mux, key: key, label: key, isDefault: nil))
        case .attached: break
        case .clipboard(let clipboard):
          guard TerminalRuntime.shared.allowsClipboardWrite(over: endpoint.connection) else { return }
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(String(decoding: clipboard.bytes, as: UTF8.self), forType: .string)
        }
      } catch { fail(error) }
    }

    /// Tabs without a host of their own take their backend's origin or authenticated endpoint.
    func inherit(_ backend: UInt64) {
      guard let workspace else { return }
      if let context = sources(backend).compactMap({ workspace.hosts.terminals[$0] }).first {
        origins[backend] = context
      }
      if origins[backend] == nil, let connection = endpoint.connection, host != .local, !host.isProvisional {
        origins[backend] = .init(host: host, generation: connection.rawValue, state: .connected, authenticated: true)
      }
      guard let context = origins[backend] else { return }
      for surface in owned.filter({ $0.backend == backend }).flatMap(\.tabs).flatMap(\.surfaceIDs)
      where workspace.hosts.terminals[surface] == nil {
        workspace.hosts.associate(surface, context: context)
        print("Helper host inherited: endpoint=\(endpoint), backend=\(backend), surface=\(surface), host=\(context.host), generation=\(context.generation)")
      }
    }

    private func imported(_ topology: HelperTopology, route: HelperBackend.Route) {
      let under = { (node: UInt64, root: UInt64) in
        sequence(first: node) { id in topology.nodes.first { $0.id == id }?.parent }.contains(root)
      }
      // The server's focused space, else its first.
      let shown = owned.filter { $0.backend == topology.backend }
      guard !stopped, restoring[route] == nil,
        !restoreRequests.values.contains(where: { $0.route == route }),
        let workspace, let sources = imports[route],
        let target = shown.first(where: { space in
          topology.focus.flatMap { focus in space.node.map { under(focus, $0) } } == true
        }) ?? shown.first
      else { return }
      imports.removeValue(forKey: route)
      if let context = sources.lazy.compactMap({ workspace.hosts.terminals[$0] }).first { origins[topology.backend] = context }
      inherit(topology.backend)
      let selected = workspace.activeTab?.id
      let releases = multiplexer(of: topology.backend) == "herdr"
      if releases { activating.remove(route) } else { workspace.selectSpace(target.id) }
      let terminals = Dictionary(uniqueKeysWithValues: sources.compactMap { tab in
        (controlTerminals[tab] ?? observedTerminal(tab)
          ?? owned.flatMap(\.tabs).first(where: { $0.id == tab })?.terminal)
          .map { (tab, $0) }
      })
      func handOff() {
        guard workspace.closeLaunching[on: multiplexer(of: topology.backend) ?? ""] else { return }
        // A control gateway hides its UI but keeps carrying the mux. An observed SSH login carries the link
        // these spaces live on: it stays for tmux, while Herdr's views keep that connection through the SSH
        // master until the last one detaches (SSHCoordinator), so the login closes like tmux -CC's tab.
        let sources = sources.filter { controlTerminals[$0] != nil || !observes($0) || releases }
        print("Helper handoff: route=\(route), controls=\(controlTerminals.keys), observed=\(observed.values), hidden=\(sources)")
        for tab in sources {
          if let terminal = controlTerminals[tab] {
            self.gateways[tab] = (topology.backend, terminal)
          } else if observes(tab) {
            // Retire the origin first: its channel then closes without reporting the retained link lost.
            print("Helper login close: source=\(tab)")
            TerminalRuntime.shared.ssh.closeTab(tab)
            workspace.closeTab(tab)
          } else if let terminal = terminals[tab] {
            // Closing a renderer only detaches it: end the ordinary launcher so its next topology cannot reopen it.
            print("Helper launcher close: source=\(tab), terminal=\(terminal)")
            close(terminal, policy: .terminate)
          }
        }
        let gateways = sources.filter { self.gateways[$0] != nil }
        workspace.updateLayout { next in
          for tab in gateways { next.detachTab(tab) }
        }
        workspace.onCloseTabs(Array(gateways))
      }
      // tmux hands off in the turn that showed its spaces: a later turn could draw them beside the launcher's,
      // and a sidebar hidden for a single space would flash in and out.
      guard releases else { return handOff() }
      // Herdr's launchers stay shown until it releases them. They count as leaving meanwhile, so the round trip
      // does not flash the sidebar either; whatever the release's outcome, they count again once it ends.
      let retiring = workspace.closeLaunching[on: "herdr"] ? sources : []
      workspace.retiringLaunchers.formUnion(retiring)
      let release = perform { client in
        // The retiring frontend can still request mouse reports until its reset output arrives.
        let views = sources.compactMap { TerminalRuntime.shared.views[$0] }
        for view in views { view.inputSuspensions += 1 }
        defer { for view in views { view.inputSuspensions -= 1 } }
        struct Release: Encodable { let mux: UInt64; let terminal: UInt64 }
        for (tab, terminal) in terminals {
          // The helper resolves and rechecks its saved foreground probe. The app never signals a PID.
          let _: HelperClient.Empty = try await client.connection.request(
            "terminals.release", params: Release(mux: route.mux, terminal: terminal))
          print("Helper launcher released: route=\(route), source=\(tab), terminal=\(terminal)")
        }
        guard !self.stopped else { return }
        if workspace.activeTab?.id == selected {
          // Import adopts the server's selection; echoing it as a command can overwrite newer server focus.
          workspace.updateLayout { next in
            next.selectedSpace = target.id
            if let tab = target.tabs.first(where: { $0.terminal == topology.focus }) { next.selectTab(tab.id) }
          }
          print("Helper import selected: route=\(route), server=\(String(describing: topology.focus)), selected=\(String(describing: workspace.activeTab?.terminal))")
        }
        handOff()
      }
      guard !retiring.isEmpty else { return }
      Task {
        await release.value
        workspace.retiringLaunchers.subtract(retiring)
      }
    }

    private func apply(_ topology: HelperTopology, route: HelperBackend.Route) throws {
      // A detached view remains visible until its native control session has ended.
      // Keep processing snapshots, but publish the completed dismissal atomically.
      guard !dismissals.values.contains(where: { $0.route == route }) else { return }
      guard let workspace, permitted(route.mux) else { return }
      let selected = workspace.selectedSpace
      let previous = owned + (restoring[route]?.presentation ?? [])
      if let space = previous.first(where: { $0.backend == topology.backend }) {
        hosts[route] = space.hostID
      }
      routes[topology.backend] = route
      let nodes = Dictionary(uniqueKeysWithValues: topology.nodes.map { ($0.id, $0) })
      if let restored = restoring[route] {
        let requested = Set(restored.presentation.flatMap(\.tabs).filter { $0.terminal != nil }.map(\.id))
        let terminals = topology.nodes.filter { $0.kind == .terminal }
        let available = Set(terminals.compactMap { restored.nodes[$0.key] })
        guard requested.isSubset(of: available) else {
          throw HerdrFailure("A retained terminal no longer exists on the server. Its saved view remains offline.")
        }
        let roots = Set(restored.presentation.map(\.id))
        // Closing a retained pane while offline changes only its presentation, never the server.
        for terminal in terminals {
          guard let id = restored.nodes[terminal.key], !requested.contains(id),
            sequence(first: terminal.id, next: { nodes[$0]?.parent }).contains(where: {
              nodes[$0].flatMap { restored.nodes[$0.key] }.map(roots.contains) == true
            }) else { continue }
          closing.insert(terminal.id)
        }
        // Offline moves become native operations only after this server generation and
        // every retained terminal have been verified against the new topology.
        for space in restored.presentation where pendingSpaces.contains(space.id) && placing[space.id] == nil {
          guard let window = space.containers.first,
            let node = topology.nodes.first(where: {
              $0.kind == .tab && restored.nodes[$0.key] == window.id
            }), let parent = node.parent else { continue }
          for terminal in terminals where sequence(first: terminal.id, next: { nodes[$0]?.parent }).contains(node.id) {
            adoptedSpaces[terminal.id] = space.id
            movedFrom[terminal.id] = parent
          }
          placing[space.id] = perform { client in
            defer { self.placing.removeValue(forKey: space.id) }
            try await client.place(.init(node: node.id, place: .init(kind: "workspace", label: space.name)))
            await self.published()
          }
        }
      }
      let hidden = topology.nodes.filter { $0.kind == .tab && $0.detached }.map { node in
        DetachedWindow(id: id(Key(route: route, entity: .node(node.key))), node: node.id, parent: node.parent, name: node.name, route: route, host: hosts[route] ?? host)
      }
      detachedWindows = detachedWindows.filter { $0.route != route } + hidden.filter { !forgottenWindows.contains($0.id) }
      // A tab leaves only when the helper published its terminal before and no longer does: a tab
      // can hold a terminal newer than this topology (the create reply and the notification race),
      // and tabs whose terminal is not created yet (their view has not appeared) have none.
      let current = Set(topology.nodes.filter { $0.kind == .terminal }.map(\.id))
      let gone = { [seen] (tab: TerminalTab) in tab.terminal.map { seen.contains($0) && !current.contains($0) } == true }
      // A move racing a detach can finish with no destination terminal at all.
      for space in previous where space.backend == topology.backend && pendingSpaces.contains(space.id)
        && !space.tabs.isEmpty && space.tabs.allSatisfy(gone) {
        pendingSpaces.remove(space.id)
        adoptedSpaces = adoptedSpaces.filter { $0.value != space.id }
        movedFrom = movedFrom.filter { adoptedSpaces[$0.key] != nil }
      }
      defer { seen.formUnion(current) }
      let layouts = Dictionary(
        uniqueKeysWithValues: topology.layouts.map { ($0.container, $0) })
      var spaces: [Space] = []
      let under = { (node: UInt64, root: UInt64) in sequence(first: node) { nodes[$0]?.parent }.contains(root) }
      for root in topology.nodes where root.kind == .workspace && !root.detached {
        // A space shown while its creation was pending keeps its id: selection and drafts stay with it.
        if let created = topology.nodes.first(where: {
          $0.kind == .terminal && adoptedSpaces[$0.id].map { !confirming.contains($0) } == true
            && under($0.id, root.id) && movedFrom[$0.id] != root.id
        }),
          let placeholder = adoptedSpaces.removeValue(forKey: created.id)
        {
          // Herdr gives a moved window a new native key; keep its app identity with its terminals.
          if let window = previous.first(where: { $0.id == placeholder })?.containers.first(where: {
            $0.terminals.contains { $0.terminal == created.id }
          }) {
            adopted[created.id] = window.id
          }
          for (terminal, space) in adoptedSpaces where space == placeholder { adoptedSpaces.removeValue(forKey: terminal) }
          movedFrom = movedFrom.filter { adoptedSpaces[$0.key] != nil }
          identity[Key(route: route, entity: .node(root.key))] = placeholder
          pendingSpaces.remove(placeholder)
        }
        let identifier = id(Key(route: route, entity: .node(root.key)))
        if restoring[route]?.presentation.contains(where: { $0.id == identifier }) != true,
          detachedRoutes.first(where: { $0.route == route })?.presentation.contains(where: {
            $0.id == identifier
          }) == true
        {
          continue
        }
        let children = topology.nodes.filter { $0.parent == root.id }
        let containers = children.filter { $0.kind == .tab && !$0.detached }
        // Every window of this space is detached: the space leaves until one is restored.
        if containers.isEmpty, children.contains(where: { $0.kind == .tab }) || hidden.contains(where: { $0.parent == root.id }) { continue }
        if containers.isEmpty {
          let values = children.filter { $0.kind == .terminal && !closing.contains($0.id) }.map {
            node -> TerminalTab in
            let key = Key(route: route, entity: .node(node.key))
            let identifier = assigned[node.id] ?? id(key)
            identity[key] = identifier
            var tab =
              previous.flatMap(\.tabs).first { $0.id == identifier }
              ?? TerminalTab(
                id: identifier, directory: node.cwd ?? workspace.defaultDirectory)
            tab.title = node.name
            tab.directory = node.cwd ?? tab.directory
            tab.terminal = node.id
            // A pending tab this terminal fills (its creation's placeholder) is connected now.
            tab.isConnecting = TerminalRuntime.shared.hosts.reconnect.awaitingRestore(tab.id)
            return tab
          }
          let removed = owned.filter { $0.backend == topology.backend }.flatMap(\.tabs).filter(gone).map(\.id)
          workspace.updateLayout { next in
            for id in removed { next.detachTab(id) }
            for tab in values where !carried(tab.id) {
              if let (s, p, t) = next.location(ofTab: tab.id) {
                next.spaces[s].panes[p].tabs[t] = tab
                next.spaces[s].backend = topology.backend
                next.spaces[s].node = root.id
              } else {
                var space = Space(
                  name: Workspace.nextSpaceName(in: next.spaces), tab: tab,
                  usesDirectoryName: true)
                space.backend = topology.backend
                space.node = root.id
                space.remote = endpoint.connection
                space.hostID = hosts[route] ?? host
                next.spaces.append(space)
                if next.selectedSpace == nil { next.selectedSpace = space.id }
              }
            }
          }
          workspace.onCloseTabs(removed)
          continue
        }
        let sources = containers.isEmpty ? [root] : containers
        var tabs: [ContainerTab] = []
        for source in sources {
          let terminals = topology.nodes.filter {
            $0.kind == .terminal && $0.parent == source.id
          }
          guard let first = terminals.first else { continue }
          let values = terminals.map { node -> TerminalTab in
            let key = Key(route: route, entity: .node(node.key))
            let identifier = assigned[node.id] ?? id(key)
            identity[key] = identifier
            var tab =
              previous.flatMap(\.tabs).first { $0.id == identifier }
              ?? TerminalTab(
                id: identifier, directory: node.cwd ?? workspace.defaultDirectory)
            tab.title = node.name
            tab.directory = node.cwd ?? tab.directory
            tab.terminal = node.id
            // A pending tab this terminal fills (its creation's placeholder) is connected now.
            tab.isConnecting = TerminalRuntime.shared.hosts.reconnect.awaitingRestore(tab.id)
            return tab
          }
          var arrangement = PaneArrangement(tab: values[0])
          if let layout = layouts[source.id] {
            var fractions: [UUID: CGFloat] = [:]
            let full = try tree(
              layout.full, route: route, nodes: nodes, fractions: &fractions)
            let visible = try tree(
              layout.visible, route: route, nodes: nodes, fractions: &fractions)
            let values = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
            arrangement.panes = full.paneIDs.compactMap { pane in
              values[pane].map { Pane(id: pane, tabs: [$0]) }
            }
            arrangement.layout = visible
            arrangement.focusedPane =
              layout.focus.flatMap { nodes[$0] }.map {
                id(Key(route: route, entity: .node($0.key)))
              }
              ?? visible.paneIDs[0]
            // Existing-pane focus stays local. A newly created pane takes focus unless
            // this app has an explicit inner-pane selection in flight; container selection
            // must not pin the old pane when that container gains a split.
            if commanding[route, default: 0] == 0,
              let prior = previous.flatMap(\.containers).first(where: { $0.id == id(Key(route: route, entity: .node(source.key))) })?.arrangement,
              let kept = prior.panes.first(where: { $0.id == prior.focusedPane }),
              prior.panes.contains(where: { $0.id == arrangement.focusedPane })
                || kept.activeTab?.terminal.map({ focusTargets[$0, default: 0] > 0 }) == true,
              arrangement.panes.contains(where: { $0.id == kept.id })
            {
              arrangement.focusedPane = kept.id
            }
            arrangement.splitFractions = fractions
            arrangement.preset = nil
            if full == visible, fractions.values.allSatisfy({ abs($0 - 0.5) < 0.015 }) {
              switch full {
              case .pane: arrangement.preset = .single
              case .split(_, .columns, .pane, .pane): arrangement.preset = .columns
              case .split(_, .rows, .pane, .pane): arrangement.preset = .rows
              case .split(_, .rows, .split(_, .columns, .pane, .pane), .pane): arrangement.preset = .twoAbove
              case .split(_, .rows, .split(_, .columns, .pane, .pane), .split(_, .columns, .pane, .pane)): arrangement.preset = .grid
              default: break
              }
            }
          } else {
            let saved = previous.first {
              $0.id == id(Key(route: route, entity: .node(root.key)))
            }?.containers.first?.arrangement
            arrangement = saved ?? arrangement
            let live = Set(values.map(\.id))
            for index in arrangement.panes.indices {
              arrangement.panes[index].tabs = arrangement.panes[index].tabs.compactMap { old in
                values.first { $0.id == old.id }
              }
              if !live.contains(arrangement.panes[index].selected),
                let tab = arrangement.panes[index].tabs.first
              {
                arrangement.panes[index].selected = tab.id
              }
            }
            let known = Set(arrangement.panes.flatMap { $0.tabs.map(\.id) })
            arrangement.panes[0].tabs += values.filter { !known.contains($0.id) }
          }
          let key = Key(route: route, entity: .node(source.key))
          // Not lazy.compactMap: `first` evaluates a lazy closure twice, and the second removal finds nothing.
          if let terminal = terminals.first(where: { self.adopted[$0.id] != nil }), let window = self.adopted.removeValue(forKey: terminal.id) {
            identity[key] = window
            placeholders.remove(window)
          }
          let identifier = id(key)
          tabs.append(
            ContainerTab(
              id: identifier, node: source.id, name: source.name, renamed: source.renamed,
              arrangement: arrangement))
          _ = first
        }
        // Pending windows keep their presentation groups even when a topology predates their creation.
        let kept = Set(tabs.map(\.id))
        tabs += (previous.first { $0.id == identifier }?.containers ?? [])
          .filter { placeholders.contains($0.id) && !kept.contains($0.id) }
        guard let first = tabs.first else { continue }
        var space =
          previous.first { $0.id == identifier }
          ?? Space(name: root.name, tab: first.terminals[0])
        space.id = identifier
        space.name = root.name
        space.backend = topology.backend
        space.node = root.id
        space.remote = endpoint.connection
        space.containers = tabs
        // A space whose every terminal runs an SSH login shows under that host (a host move).
        space.hostID = workspace.loggedHost(space) ?? hosts[route] ?? host
        let focused = tabs.first { tab in
          topology.focus.map { sequence(first: $0) { nodes[$0]?.parent }.contains(tab.node) } == true
        }?.id
        // A reattached space shows the server's selection (it may have moved while detached).
        let reattached = restoring[route]?.presentation.contains { $0.id == identifier } == true
        space.selectedContainer =
          (reattached ? focused : nil)
          ?? space.selectedContainer.flatMap { selected in
            tabs.contains { $0.id == selected } ? selected : nil
          } ?? focused ?? first.id
        if space.presentation == nil {
          space.presentation = TabPresentation(
            windows: tabs.map(\.id), selected: space.selectedContainer!, preset: .single
          )
        } else {
          space.presentation?.reconcile(tabs.map(\.id), near: space.selectedContainer)
        }
        spaces.append(space)
      }
      // Pending placements stay in their optimistic space, including across an older move's confirmation.
      for index in spaces.indices {
        guard let node = spaces[index].node else { continue }
        spaces[index].containers.removeAll { $0.terminals.contains { tab in
          guard let terminal = tab.terminal else { return false }
          return self.movedFrom[terminal] == node
            || self.adoptedSpaces[terminal].map { self.confirming.contains($0) } == true
        } }
      }
      // Closing nodes stay hidden while the topology still has them; pending names show until confirmed.
      unseen.subtract(topology.nodes.map(\.id))
      // A dismissed creation's window arrived: detach it (it stays hidden until the server reports it detached).
      for terminal in detaching {
        guard let window = nodes[terminal]?.parent, nodes[window]?.kind == .tab else { continue }
        detaching.remove(terminal)
        closing.remove(terminal)
        close(window, policy: .detach)
      }
      closing = closing.filter { node in unseen.contains(node) || topology.nodes.contains { $0.id == node } }
      spaces.removeAll { $0.node.map(closing.contains) == true }
      for index in spaces.indices {
        spaces[index].containers.removeAll { closing.contains($0.node) || $0.terminals.allSatisfy { $0.terminal.map(closing.contains) == true } }
      }
      spaces.removeAll { $0.containers.isEmpty }
      var visible = WorkspaceLayout(spaces: spaces, selectedSpace: nil)
      for tab in spaces.flatMap(\.tabs) where tab.terminal.map(closing.contains) == true || carried(tab.id) {
        visible.detachTab(tab.id)
      }
      spaces = visible.spaces
      for (id, pending) in renaming {
        let node = Self.target(id, in: spaces)
        if let shown = topology.nodes.first(where: { $0.id == node }), pending.failed || shown.name == pending.name {
          renaming.removeValue(forKey: id)
        } else {
          Self.name(id, pending.name, in: &spaces)
        }
      }
      // A transiently empty topology keeps what is shown; detached or closing windows really leave.
      if topology.nodes.contains(where: { $0.kind == .workspace && !$0.detached }), spaces.isEmpty, hidden.isEmpty, closing.isEmpty { return }
      let old = owned.filter { $0.backend == topology.backend }
      let removed = old.flatMap(\.tabs).filter(gone).map(\.id)
      workspace.updateLayout { next in
        // The topology's spaces replace those it showed before and any space with the same identity: one server
        // reached under another backend id (another socket path to it) must not list its spaces twice.
        let identities = Set(spaces.map(\.id))
        let shown = { (space: Space) in
          identities.contains(space.id)
            || !space.containers.isEmpty && !self.pendingSpaces.contains(space.id) && space.backend == topology.backend && space.remote == self.endpoint.connection
        }
        // Shown spaces keep the user's order (other spaces may sit between them); new ones follow the last.
        let incoming = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0) })
        var result: [Space] = []
        for space in next.spaces {
          if !shown(space) { result.append(space) } else if let latest = incoming[space.id] { result.append(latest) }
        }
        let placed = Set(result.map(\.id))
        let at = result.lastIndex(where: { identities.contains($0.id) }).map { $0 + 1 } ?? result.endIndex
        result.insert(contentsOf: spaces.filter { !placed.contains($0.id) }, at: at)
        next.spaces = result
        if !next.spaces.contains(where: { $0.id == next.selectedSpace }) {
          next.selectedSpace = spaces.first?.id ?? next.spaces.first?.id
        }
      }
      workspace.onCloseTabs(removed)
      retire()
      for (id, pending) in renaming where pending.node == nil {
        if Self.target(id, in: owned) != nil { rename(id, name: pending.name) }
      }
      // Another client's focus change selects its space, unless this app's own focus commands are in flight
      // or the app shows another server's or a local view.
      if let focus = topology.focus, let earlier = lastFocus[route], focus != earlier, focusing[route, default: 0] == 0,
        let selected = workspace.selectedSpace, spaces.contains(where: { $0.id == selected }),
        let target = spaces.first(where: { space in space.node.map { under(focus, $0) } == true }),
        let container = target.containers.first(where: { under(focus, $0.node) })
      {
        workspace.updateLayout { next in
          next.selectedSpace = target.id
          if let index = next.spaces.firstIndex(where: { $0.id == target.id }) {
            next.spaces[index].selectedContainer = container.id
            next.spaces[index].presentation?.select(container.id)
          }
          if let terminal = container.terminals.first(where: { $0.terminal == focus }) {
            next.selectTab(terminal.id)
          }
        }
        print("Helper native focus: route=\(route), previous=\(earlier), focus=\(focus), selected=\(String(describing: workspace.activeTab?.terminal))")
      }
      if let focus = topology.focus { lastFocus[route] = focus }
      if let restored = restoring[route],
        restored.presentation.allSatisfy({ requested in spaces.contains { $0.id == requested.id } })
      {
        print("Helper restore complete: route=\(route), requested=\(restored.presentation.map(\.id)), shown=\(spaces.map(\.id))")
        let requested = Set(restored.presentation.map(\.id))
        let detached = workspace.helpers.values.filter { helper in
          helper !== self && helper.stopped && helper.host == host
            && helper.detachedRoutes.contains { entry in entry.presentation.contains { requested.contains($0.id) } }
        }
        inherit(topology.backend)
        for tab in spaces.flatMap(\.tabs) { _ = TerminalRuntime.shared.view(for: tab) }
        restoring.removeValue(forKey: route)
        restored.presentation.forEach { forget($0.id) }
        for helper in detached { for id in requested { helper.forget(id) } }
        self.restored(route)
        if !detached.isEmpty, let space = restored.presentation.first { workspace.selectSpace(space.id) }
        for tab in spaces.flatMap(\.tabs) {
          if let channel = terminals[tab.id] { attach(tab.id, channel) }
        }
      }
      spaces.flatMap(\.tabs).forEach(constrain)
      placeholders.formIntersection(owned.flatMap(\.containers).map(\.id))
      for tab in spaces.flatMap(\.tabs) {
        guard let terminal = tab.terminal,
          let selection = selections.removeValue(forKey: terminal),
          workspace.selectedSpace == selection.space, workspace.activeTab?.id == tab.id
        else { continue }
        workspace.updateLayout { next in
          if let split = selection.split {
            _ = split.apply(to: &next, createdTab: tab.id)
          } else {
            _ = next.selectTab(tab.id)
          }
        }
        workspace.selectTab(tab.id)
      }
      for space in spaces {
        for tab in space.tabs {
          guard let terminal = tab.terminal, let from = following[terminal], from != space.id else { continue }
          following.removeValue(forKey: terminal)
          if selected == from { workspace.selectTab(tab.id) }
        }
      }
    }

    private func tree(
      _ split: HelperTopology.Split, route: HelperBackend.Route,
      nodes: [UInt64: HelperTopology.Node], fractions: inout [UUID: CGFloat]
    ) throws -> PaneLayout {
      switch split {
      case .leaf(let terminal):
        guard let node = nodes[terminal] else {
          throw HelperFailure(
            code: "invalid_response", message: "Missing layout terminal")
        }
        return .pane(id(Key(route: route, entity: .node(node.key))))
      case .branch(let node, let axis, let children):
        guard children.count >= 2, children.allSatisfy({ $0.weight > 0 }) else {
          throw HelperFailure(code: "invalid_response", message: "Invalid split layout")
        }
        func combine(_ remaining: ArraySlice<HelperTopology.Split.Child>) throws
          -> PaneLayout
        {
          let first = remaining.first!
          if remaining.count == 1 {
            return try tree(
              first.split, route: route, nodes: nodes, fractions: &fractions)
          }
          let identifier = id(
            Key(route: route, entity: .divider(node, remaining.startIndex)))
          dividers[identifier] = node
          let extent =
            remaining.reduce(UInt64(0)) { $0 + UInt64($1.weight) }
            + UInt64(remaining.count - 2)
          fractions[identifier] = CGFloat(first.weight) / CGFloat(extent)
          return .split(
            identifier, axis == .rows ? .rows : .columns,
            try tree(first.split, route: route, nodes: nodes, fractions: &fractions),
            try combine(remaining.dropFirst()))
        }
        return try combine(children[...])
      }
    }
  }
#endif
