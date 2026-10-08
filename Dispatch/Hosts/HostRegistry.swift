import Foundation
import Observation

/// Verified machines group accounts; provisional logins use their resolved route.
/// Neither identity authorizes helper operations or identifies a backend.
struct HostID: Hashable, Codable, Sendable {
    let rawValue: String
    static let local = HostID(rawValue: "local")
    static func authenticated(_ identity: String) -> Self { .init(rawValue: "ssh:" + identity) }
    static func provisional(_ generation: UUID) -> Self { .init(rawValue: "pending:" + generation.uuidString) }
    static func login(_ scope: SSHIntegrationScope) -> Self { .init(rawValue: "login:" + scope.key) }
    var isProvisional: Bool { rawValue.hasPrefix("pending:") || rawValue.hasPrefix("login:") }
}

struct HostSystem: Equatable, Codable, Sendable {
    var os: String
    var distribution: String?
    var name: String?
    static let mac = HostSystem(os: "Darwin", name: "macOS")
    var label: String { name ?? (os == "Darwin" ? "macOS" : os) }
}

enum HostConnectionState: String, Hashable, Codable, Sendable {
    case connecting, connected, disconnected, unverified
    var label: String {
        switch self {
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnected: "disconnected"
        case .unverified: "identity unavailable"
        }
    }
    var shortLabel: String {
        switch self { case .connecting: "connecting"; case .connected: "ssh"; case .disconnected: "offline"; case .unverified: "ssh · ?" }
    }
}

struct TerminalHostContext: Equatable, Codable, Sendable {
    let host: HostID
    let generation: UUID
    var state: HostConnectionState
    var authenticated: Bool
}

struct HostRecord: Identifiable, Equatable, Codable, Sendable {
    let id: HostID
    var name: String
    var hostname: String?
    var system: HostSystem?
    var destinations: [String]
    var order: Int
    /// The automatic color given when the host was first remembered. A name, so a
    /// color later removed from HostColor costs only this choice, not the record.
    var colorName: String?
    var color: HostColor? { colorName.flatMap(HostColor.init(rawValue:)) }
    static let local = HostRecord(id: .local, name: "Local", system: .mac, destinations: [], order: -1)
    var details: String {
        ([hostname, system?.label].compactMap { $0 } + destinations).joined(separator: " · ")
    }
}

/// Contains presentation metadata and terminal associations, never connection
/// credentials, SSH control paths, or ownership of tmux/herdr sessions.
@MainActor @Observable
final class HostRegistry {
    private(set) var records: [HostID: HostRecord] = [.local: .local]
    private(set) var terminals: [UUID: TerminalHostContext] = [:]
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var nextOrder = 0
    // Presentation grouping only: never a source of integration permissions.
    @ObservationIgnored private var loginScopes: [UUID: String] = [:]

    init(defaults: UserDefaults? = .app) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: "HostRegistry.v1"),
           let saved = try? JSONDecoder().decode([HostRecord].self, from: data) {
            // Local is saved only once the user reorders hosts; until then it stays first.
            for var record in saved.sorted(by: { $0.order < $1.order }) where record.id == .local || record.order >= 0 {
                if record.id == .local { records[.local]?.order = nextOrder; nextOrder += 1; continue }
                record.order = nextOrder
                record.name = Self.label(record.name)
                records[record.id] = record
                nextOrder += 1
            }
        }
        assignColors()
    }

    func record(_ id: HostID) -> HostRecord {
        records[id] ?? HostRecord(id: id, name: "Remote", destinations: [], order: Int.max)
    }

    func ordered(_ live: Set<HostID>) -> [HostRecord] {
        live.union([.local]).map(record).sorted {
            $0.order == $1.order ? $0.id.rawValue < $1.id.rawValue : $0.order < $1.order
        }
    }

    func state(_ host: HostID) -> HostConnectionState {
        if host == .local { return .connected }
        let states = Set(terminals.values.filter { $0.host == host }.map(\.state))
        if states.contains(.connected) { return .connected }
        if states.contains(.connecting) { return .connecting }
        if states.contains(.unverified) { return .unverified }
        return .disconnected
    }

    /// Connection-only flags (TTY, forwarding, ControlPath, remote command)
    /// change when opening another tab. Group by the resolved route/account,
    /// while the permission store continues to fingerprint the complete config.
    nonisolated static func loginScope(executable: String, destination: String, configuration: String) -> SSHIntegrationScope? {
        let keys: Set<String> = ["hostname", "user", "port", "proxyjump", "proxycommand", "hostkeyalias"]
        let lines = configuration.split(separator: "\n").filter {
            $0.split(maxSplits: 1, whereSeparator: \.isWhitespace).first.map { keys.contains($0.lowercased()) } == true
        }
        guard ["hostname", "user", "port"].allSatisfy({ key in
            lines.contains { $0.split(maxSplits: 1, whereSeparator: \.isWhitespace).first == key }
        }) else { return nil }
        return SSHIntegrationScope(executable: executable, destination: destination, configuration: lines.joined(separator: "\n"))
    }

    func begin(_ terminal: UUID, generation: UUID, destination: String, seed: HostID? = nil,
               state: HostConnectionState = .connecting, scope: SSHIntegrationScope? = nil) {
        let live = Set(terminals.values.map(\.generation))
        loginScopes = loginScopes.filter { live.contains($0.key) }
        let host: HostID
        if let scope {
            let matches = Set(terminals.values.filter { loginScopes[$0.generation] == scope.key }.map(\.host))
            // A load-balanced login can have multiple verified identities. Do
            // not guess which machine the next connection will reach.
            host = matches.count == 1 ? matches.first! : .login(scope)
            loginScopes[generation] = scope.key
        } else {
            host = seed.flatMap { records[$0] == nil ? nil : $0 } ?? .provisional(generation)
        }
        terminals[terminal] = TerminalHostContext(host: host, generation: generation, state: state, authenticated: false)
        update(terminal, generation: generation, destination: destination, state: state)
    }

    @discardableResult
    func update(_ terminal: UUID, generation: UUID, destination: String,
                greeting: SSHGreeting? = nil, state: HostConnectionState) -> TerminalHostContext? {
        guard let previous = terminals[terminal], previous.generation == generation else { return nil }
        let identity = greeting.flatMap { value in
            !value.host.isEmpty && value.host.utf8.count <= 256 ? HostID.authenticated(value.host) : nil
        }
        let id = identity ?? previous.host
        let destination = Self.label(destination)
        // A seeded connection can resolve to a different machine. Only a
        // provisional identity transfers its label/order to the verified host.
        let prior = previous.host == id || previous.host.isProvisional ? records[previous.host] : nil
        var record = records[id] ?? HostRecord(id: id, name: prior?.name ?? Self.displayName(destination),
                                              destinations: prior?.destinations ?? [], order: prior?.order ?? nextOrder)
        if records[id] == nil, prior == nil { nextOrder += 1 }
        // A new machine keeps the color its connection previewed while it was identified, so it doesn't change color
        // as it connects.
        if records[id] == nil, identity != nil, let preview = previewColor(previous.host) { record.colorName = preview.rawValue }
        if let prior, prior.order < record.order {
            record.name = prior.name; record.order = prior.order
        }
        for alias in prior?.destinations ?? [] where !record.destinations.contains(alias) { record.destinations.append(alias) }
        if !destination.isEmpty, !record.destinations.contains(destination) { record.destinations.append(destination) }
        if let hostname = greeting?.hostname.map(Self.label), !hostname.isEmpty { record.hostname = hostname }
        if let os = greeting?.os.map(Self.label), !os.isEmpty {
            record.system = HostSystem(os: os, distribution: greeting?.distribution.map(Self.label), name: greeting?.osName.map(Self.label))
        }
        if records[id] != record { records[id] = record; recordsChanged() }
        let context = TerminalHostContext(host: id, generation: generation, state: state,
                                          authenticated: identity != nil || previous.authenticated)
        if previous != context { terminals[terminal] = context }
        if identity != nil, previous.host != id {
            for (other, value) in terminals where value.host == previous.host {
                if value.generation == generation { terminals[other] = context }
                else if previous.host.isProvisional, let scope = loginScopes[generation],
                        loginScopes[value.generation] == scope {
                    // Matching logins share a sidebar group, but only this
                    // connection's greeting authenticates its own generation.
                    terminals[other] = TerminalHostContext(host: id, generation: value.generation,
                        state: value.state, authenticated: value.authenticated)
                }
            }
            if previous.host.isProvisional, !terminals.values.contains(where: { $0.host == previous.host }) {
                records[previous.host] = nil; recordsChanged()
            }
        }
        return context
    }

    func seed(_ terminal: UUID, from host: HostID, generation: UUID) {
        guard host != .local, records[host] != nil else { return }
        terminals[terminal] = TerminalHostContext(host: host, generation: generation, state: .connecting, authenticated: false)
    }

    func inherit(_ terminal: UUID, from source: UUID) {
        guard let context = terminals[source], terminals[terminal] != context else { return }
        terminals[terminal] = context
    }

    func associate(_ terminal: UUID, context: TerminalHostContext) {
        if terminals[terminal] != context { terminals[terminal] = context }
    }

    func setState(_ state: HostConnectionState, generation: UUID) {
        for (terminal, context) in terminals where context.generation == generation && context.state != state {
            var value = context; value.state = state; terminals[terminal] = value
        }
    }

    func remove(_ terminal: UUID, generation: UUID? = nil) {
        guard generation == nil || terminals[terminal]?.generation == generation else { return }
        terminals.removeValue(forKey: terminal)
    }

    func restore(_ saved: [HostRecord]) {
        for record in saved where record.id != .local { records[record.id] = record }
        // Unknown hosts use Int.max as their display order. Compact the saved
        // order just as startup does, without incrementing that sentinel.
        let ordered = records.values.sorted {
            $0.order == $1.order ? $0.id.rawValue < $1.id.rawValue : $0.order < $1.order
        }
        for (order, var record) in ordered.enumerated() {
            record.order = order; records[record.id] = record
        }
        nextOrder = ordered.count
        assignColors()
    }

    /// Sidebar tree order. Local takes part so it can move below remote hosts.
    func move(_ host: HostID, relativeTo target: HostID, after: Bool) {
        guard host != target, records[host] != nil, records[target] != nil else { return }
        var ids = records.values.sorted {
            $0.order == $1.order ? $0.id.rawValue < $1.id.rawValue : $0.order < $1.order
        }.map(\.id).filter { $0 != host }
        guard let index = ids.firstIndex(of: target) else { return }
        ids.insert(host, at: after ? index + 1 : index)
        for (order, id) in ids.enumerated() { records[id]?.order = order }
        nextOrder = ids.count
        persist()
    }

    func forget(_ host: HostID) {
        guard host != .local, !terminals.values.contains(where: { $0.host == host }) else { return }
        records[host] = nil
        recordsChanged()
    }

    func clear() { terminals.removeAll(); loginScopes.removeAll() }

    func reset() {
        clear()
        records = [.local: .local]
        nextOrder = 0
        defaults?.removeObject(forKey: "HostRegistry.v1")
        assignColors()
    }

    private func recordsChanged() {
        assignColors()
        persist()
    }

    /// Each verified host keeps the automatic color it was first given. A new host takes a color no connected host
    /// shows when there is one, then the one fewest remembered hosts show (a chosen color counts instead), its own hash
    /// breaking ties. Forgetting a host frees its color for the next new one. A connection not yet identified previews
    /// the color a new host would get, without keeping it, so it doesn't borrow one already on screen either.
    private func assignColors() {
        let store = HostColorStore.shared
        let ordered = records.values.sorted { $0.order == $1.order ? $0.id.rawValue < $1.id.rawValue : $0.order < $1.order }
        let live = Set(terminals.values.map(\.host))
        var used: [HostColor: Int] = [:], shown: [HostColor: Int] = [:]
        func count(_ color: HostColor, live connected: Bool) {
            used[color, default: 0] += 1
            if connected { shown[color, default: 0] += 1 }
        }
        for record in ordered {
            guard let tint = record.tint, let color = store.choices[tint.machine] ?? record.color else { continue }
            count(color, live: live.contains(record.id))
        }
        // A preview already on screen keeps its color while its connection lasts, and counts as shown.
        var previews: [String: HostColor] = [:]
        for record in ordered where record.id.isProvisional {
            guard let tint = record.tint, store.choices[tint.machine] == nil,
                  let color = store.automatic[tint.machine] else { continue }
            previews[tint.machine] = color
            count(color, live: true)
        }
        func free(_ seed: UInt32) -> HostColor {
            let rank = { (color: HostColor) in (shown[color, default: 0], used[color, default: 0]) }
            let best = HostColor.allCases.map(rank).min { $0 < $1 } ?? (0, 0)
            let candidates = HostColor.allCases.filter { rank($0) == best }
            return candidates[Int(seed % UInt32(candidates.count))]
        }
        for record in ordered where record.id.rawValue.hasPrefix("ssh:") && record.color == nil {
            guard let tint = record.tint else { continue }
            let color = free(tint.seed)
            records[record.id]?.colorName = color.rawValue
            if store.choices[tint.machine] == nil { count(color, live: live.contains(record.id)) }
        }
        for record in ordered where record.id.isProvisional {
            guard let tint = record.tint, store.choices[tint.machine] == nil, previews[tint.machine] == nil else { continue }
            let color = free(tint.seed)
            previews[tint.machine] = color
            count(color, live: true)
        }
        store.automatic = Dictionary(records.values.compactMap { record in
            record.tint.flatMap { tint in record.color.map { (tint.machine, $0) } }
        }, uniquingKeysWith: { first, _ in first }).merging(previews) { assigned, _ in assigned }
    }

    /// The color a connection not yet identified previews (assignColors), which a new host it turns out to be keeps.
    private func previewColor(_ host: HostID) -> HostColor? {
        guard host.isProvisional, let tint = records[host]?.tint else { return nil }
        return HostColorStore.shared.automatic[tint.machine]
    }

    private func persist() {
        guard let defaults, let data = try? JSONEncoder().encode(Array(records.values)) else { return }
        defaults.set(data, forKey: "HostRegistry.v1")
    }

    static func displayName(_ destination: String) -> String {
        let value = destination.hasPrefix("ssh://") ? String(destination.dropFirst(6)) : destination
        let host = value.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? value
        return host.isEmpty ? "Remote" : host
    }

    private static func label(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.prefix(256).filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
