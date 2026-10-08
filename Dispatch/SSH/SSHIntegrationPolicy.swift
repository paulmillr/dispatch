import Foundation
import CryptoKit
import Observation

enum SSHIntegrationProfile: String, Codable, CaseIterable, Sendable {
    case ordinary, statistics, full

    var label: String {
        switch self {
        case .ordinary: "Ordinary SSH"
        case .statistics: "Stats only"
        case .full: "Full integration"
        }
    }

    var shortLabel: String {
        switch self {
        case .ordinary: "no helper"
        case .statistics: "stats only"
        case .full: "all features"
        }
    }
}

/// Authorization identity is independent of HostRegistry and reported machine
/// identity. Preserve the complete resolved configuration, including account,
/// when hashing: differing aliases and executables never share a grant.
/// The launcher resolves forwarding definitions independently of the temporary
/// listener suppression used when Command-N clones a connection.
struct SSHIntegrationScope: Hashable, Codable, Sendable {
    let executable: String
    let destination: String
    let configurationFingerprint: String
    let account: String

    init?(executable: String, destination: String, configuration: String) {
        guard executable.hasPrefix("/"), !destination.isEmpty,
              configuration.utf8.count <= 1_048_576 else { return nil }
        let lines = configuration.split(separator: "\n", omittingEmptySubsequences: true)
        let users = lines.compactMap { line -> String? in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            return fields.count == 2 && fields[0].lowercased() == "user" ? String(fields[1]) : nil
        }
        guard users.count == 1, let account = users.first, !account.isEmpty else { return nil }
        self.executable = executable
        self.destination = destination
        self.account = account
        // Normalize line endings only. Preserve ordering and repeated options;
        // IdentityFile/SendEnv order may affect authentication or the session.
        let normalized = configuration.replacingOccurrences(of: "\r\n", with: "\n")
        configurationFingerprint = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var key: String {
        // Length framing prevents concatenation collisions between components.
        let bytes = [executable, destination, configurationFingerprint, account].reduce(into: Data()) { data, value in
            var count = UInt64(value.utf8.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(contentsOf: value.utf8)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// Independently selected helper features. Shared transport methods remain internal.
enum SSHIntegrationFeature: String, Codable, CaseIterable, Sendable {
    case statistics, files, chat, hooks, git, tmux, herdr

    var title: String {
        switch self {
        case .statistics: "Stats"
        case .files: "File access"
        case .chat: "Chat transcripts"
        case .hooks: "Agent hooks"
        case .git: "Git metadata"
        case .tmux: "tmux control mode"
        case .herdr: "herdr socket"
        }
    }
    var detail: String {
        switch self {
        case .statistics: "cpu · mem · disk · processes"
        case .files: "browse remote files"
        case .chat: "sessions as chat"
        case .hooks: "attention · notifications"
        case .git: "branch · status"
        case .tmux: "sessions → tabs"
        case .herdr: "follow sessions"
        }
    }
    var capabilities: Set<String> {
        switch self {
        case .statistics: ["stats.sample", "stats.ping", "stats.processes"]
        case .files, .git: ["file.read", "file.text"]
        case .chat: ["agent.inspect", "agent.version", "agent.submit", "agent.events", "agent.queue", "agent.side", "backend.register", "file.read", "file.text"]
        case .hooks: ["hooks.configure", "agent.pi", "agent.pi.configure", "backend.register"]
        case .tmux: ["tmux.pane", "backend.register"]
        case .herdr: ["herdr.start", "herdr.rpc", "herdr.terminal", "backend.register"]
        }
    }
}

struct SSHIntegrationGrant: Codable, Equatable, Sendable {
    static let currentRevision = 1
    let profile: SSHIntegrationProfile
    let hooks: Bool
    let revision: Int
    let capabilities: Set<String>
    private(set) var features: Set<SSHIntegrationFeature>? = nil

    init(profile: SSHIntegrationProfile, hooks: Bool = false) {
        self.profile = profile
        self.hooks = hooks && profile == .full
        revision = Self.currentRevision
        capabilities = Self.capabilities(profile, hooks: self.hooks)
    }

    static func capabilities(_ profile: SSHIntegrationProfile, hooks: Bool) -> Set<String> {
        guard profile != .ordinary else { return [] }
        var values: Set<String> = ["host.identity", "stats.sample", "stats.ping", "stats.processes", "shell.lifecycle", "cancel", "events", "input.window"]
        if profile == .full {
            values.formUnion(["agent.inspect", "agent.version", "agent.submit", "agent.events", "agent.queue", "agent.side", "backend.register", "tmux.pane", "herdr.start", "herdr.rpc", "herdr.terminal", "file.read", "file.text"])
            if hooks { values.formUnion(["hooks.configure", "agent.pi", "agent.pi.configure"]) }
        }
        return values
    }

    init(helperEnabled: Bool, features: Set<SSHIntegrationFeature>) {
        let profile: SSHIntegrationProfile = !helperEnabled ? .ordinary : features.isSubset(of: [.statistics]) ? .statistics : .full
        self.profile = profile
        self.hooks = helperEnabled && features.contains(.hooks)
        revision = Self.currentRevision
        self.features = helperEnabled ? features : []
        capabilities = Self.selectedCapabilities(profile: profile, features: helperEnabled ? features : [])
    }

    var selectedFeatures: Set<SSHIntegrationFeature> {
        if let features { return features }
        switch profile {
        case .ordinary: return []
        case .statistics: return [.statistics]
        case .full: return Set(SSHIntegrationFeature.allCases).subtracting(hooks ? [] : [.hooks])
        }
    }

    var shortLabel: String {
        if profile == .ordinary { return "no helper" }
        if selectedFeatures == [.statistics] { return "stats only" }
        if selectedFeatures == Set(SSHIntegrationFeature.allCases) { return "all features" }
        return "\(selectedFeatures.count) features"
    }

    private static func selectedCapabilities(profile: SSHIntegrationProfile, features: Set<SSHIntegrationFeature>) -> Set<String> {
        guard profile != .ordinary else { return [] }
        return features.reduce(into: Set(["host.identity", "shell.lifecycle", "cancel", "events", "input.window"])) {
            $0.formUnion($1.capabilities)
        }
    }

    var isCurrent: Bool {
        guard revision == Self.currentRevision, !hooks || profile == .full else { return false }
        if let features {
            return capabilities == Self.selectedCapabilities(profile: profile, features: features)
                && (profile != .ordinary || features.isEmpty)
                && hooks == features.contains(.hooks)
                && capabilities.isSubset(of: Self.capabilities(profile, hooks: hooks))
        }
        return Self.capabilities(profile, hooks: hooks).isSubset(of: capabilities)
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profile = try values.decode(SSHIntegrationProfile.self, forKey: .profile)
        hooks = try values.decode(Bool.self, forKey: .hooks)
        revision = try values.decode(Int.self, forKey: .revision)
        features = try values.decodeIfPresent(Set<SSHIntegrationFeature>.self, forKey: .features)
        var capabilities = try values.decode(Set<String>.self, forKey: .capabilities)
        // A latency echo is part of the existing statistics profile. Preserve
        // remembered choices from before its addition without widening profiles.
        if revision == Self.currentRevision, profile != .ordinary, capabilities.contains("stats.sample") {
            capabilities.insert("stats.ping")
        }
        self.capabilities = capabilities
    }

    /// The live policy only loses permissions. Newly selected capabilities wait
    /// for a new explicit SSH connection, even when a change mixes both kinds.
    func reduced(to requested: Self) -> Self {
        if features != nil || requested.features != nil {
            let selection = Self(helperEnabled: profile != .ordinary && requested.profile != .ordinary,
                                 features: selectedFeatures.intersection(requested.selectedFeatures))
            return Self(profile: selection.profile, hooks: selection.hooks, revision: revision,
                        capabilities: selection.capabilities.intersection(capabilities).intersection(requested.capabilities),
                        features: selection.features)
        }
        let profile: SSHIntegrationProfile
        if self.profile == .ordinary || requested.profile == .ordinary { profile = .ordinary }
        else if self.profile == .statistics || requested.profile == .statistics { profile = .statistics }
        else { profile = .full }
        let hooks = hooks && requested.hooks && profile == .full
        return Self(profile: profile, hooks: hooks, revision: revision,
                    capabilities: capabilities.intersection(requested.capabilities)
                        .intersection(Self.capabilities(profile, hooks: hooks)))
    }

    private init(profile: SSHIntegrationProfile, hooks: Bool, revision: Int, capabilities: Set<String>, features: Set<SSHIntegrationFeature>? = nil) {
        self.profile = profile
        self.hooks = hooks
        self.revision = revision
        self.capabilities = capabilities
        self.features = features
    }
}

/// A consent sheet's answer: the helper grant plus the per-agent Chat hook
/// decisions made in the same sheet, so connecting never asks again per agent.
struct SSHIntegrationSelection: Equatable, Sendable {
    var grant: SSHIntegrationGrant
    /// Only agents the user decided; missing agents are asked when first seen.
    var agents: [SSHHookAgent: Bool] = [:]
}

/// The helper choices the consent sheet and Settings both edit: the helper,
/// then stats, files and one Chat-hook answer per agent. Chat transcripts,
/// tmux and herdr come with the helper.
struct SSHIntegrationDraft: Equatable {
    enum Choice: Hashable {
        case stats, files, agent(SSHHookAgent)
        static let all: [Choice] = [.stats, .files] + SSHHookAgent.allCases.map { .agent($0) }
        var title: String {
            switch self {
            case .stats: "Stats"
            case .files: "File access"
            case .agent(.codex): "Codex"
            case .agent(.claude): "Claude"
            case .agent(.pi): "Pi"
            }
        }
        var detail: String {
            switch self {
            case .stats: "cpu · mem · disk · processes"
            case .files: "browse files · git status"
            case .agent: "chat hooks · attention"
            }
        }
    }
    static let implied: Set<SSHIntegrationFeature> = [.chat, .tmux, .herdr]
    private(set) var helper: Bool
    private(set) var checked: Set<Choice>
    /// Older grants may lack implied features; keep them as saved until the
    /// user adds something, so opening an editor never shows phantom additions.
    private var implied: Set<SSHIntegrationFeature>

    init(current: SSHIntegrationGrant?, agents: [SSHHookAgent: Bool]) {
        let features = current?.selectedFeatures ?? Set(SSHIntegrationFeature.allCases)
        checked = Set(Choice.all.filter { choice in
            switch choice {
            case .stats: features.contains(.statistics)
            case .files: features.contains(.files)
            // Unanswered agents follow the grant's hook permission (on for new hosts).
            case .agent(let agent): agents[agent] ?? (current?.hooks ?? true)
            }
        })
        helper = current?.profile != .ordinary
        implied = current.map { $0.selectedFeatures.intersection(Self.implied) } ?? Self.implied
    }

    var features: Set<SSHIntegrationFeature> {
        var features = implied
        if checked.contains(.stats) { features.insert(.statistics) }
        if checked.contains(.files) { features.formUnion([.files, .git]) }
        if SSHHookAgent.allCases.contains(where: { checked.contains(.agent($0)) }) { features.insert(.hooks) }
        return features
    }
    var grant: SSHIntegrationGrant { .init(helperEnabled: helper, features: features) }
    var selection: SSHIntegrationSelection {
        var agents: [SSHHookAgent: Bool] = [:]
        if helper { for agent in SSHHookAgent.allCases { agents[agent] = checked.contains(.agent(agent)) } }
        return .init(grant: grant, agents: agents)
    }
    var isDefault: Bool { helper && checked == Set(Choice.all) && implied == Self.implied }

    /// Whether these choices add anything a live connection's helper lacks;
    /// additions start only after reconnecting.
    func needsReconnect(_ active: [SSHIntegrationGrant]) -> Bool {
        let draft = grant
        return helper && active.contains {
            $0.profile == .ordinary || !features.isSubset(of: $0.selectedFeatures) || !draft.capabilities.isSubset(of: $0.capabilities)
        }
    }

    mutating func toggleHelper() {
        helper.toggle()
        if helper, implied.isEmpty { implied = Self.implied }
    }
    mutating func toggle(_ choice: Choice) {
        if checked.contains(choice) { checked.remove(choice) } else { checked.insert(choice); implied = Self.implied }
    }
    mutating func useDefaults() { self = .init(current: nil, agents: [:]) }
}

@MainActor @Observable
final class SSHIntegrationPermissions {
    struct Entry: Codable, Sendable, Identifiable {
        let scope: SSHIntegrationScope
        var grant: SSHIntegrationGrant
        var hooks: [String: Bool]?
        var id: String { scope.key }
    }
    private(set) var entries: [String: Entry] = [:]
    @ObservationIgnored private let defaults: UserDefaults?
    private struct PendingChoice<Value: Sendable> {
        let id = UUID()
        let task: Task<Value?, Never>
        var waiters: Set<UUID> = []
    }
    @ObservationIgnored private var pending: [String: PendingChoice<SSHIntegrationSelection>] = [:]
    @ObservationIgnored private var pendingHooks: [String: [SSHHookAgent: PendingChoice<Bool>]] = [:]
    @ObservationIgnored var onChange: ((SSHIntegrationScope, SSHIntegrationGrant) -> Void)?

    init(defaults: UserDefaults? = .app) {
        self.defaults = defaults
        if let bytes = defaults?.data(forKey: "SSHIntegrationPermissions.v2"), bytes.count <= 4_194_304,
           let records = try? JSONDecoder().decode([Entry].self, from: bytes) {
            for entry in records.prefix(4096) { entries[entry.scope.key] = entry }
        }
    }

    func remembered(_ scope: SSHIntegrationScope) -> SSHIntegrationGrant? {
        guard let entry = entries[scope.key], entry.scope == scope, entry.grant.isCurrent else { return nil }
        return entry.grant
    }

    func choose(_ scope: SSHIntegrationScope,
                present: @escaping @MainActor (SSHIntegrationScope) async -> SSHIntegrationSelection?) async -> SSHIntegrationGrant? {
        if let grant = remembered(scope) { return grant }
        let choice: PendingChoice<SSHIntegrationSelection>
        if let existing = pending[scope.key] { choice = existing }
        else {
            choice = PendingChoice(task: Task { @MainActor in await present(scope) })
            pending[scope.key] = choice
        }
        let selection = await choice.task.value
        // Settings may have changed while the shared prompt was open. Only its
        // current generation may persist a result; every waiter uses the latest
        // remembered decision, never a superseded prompt's permission increase.
        if pending[scope.key]?.id == choice.id {
            pending[scope.key] = nil
            if let selection { save(selection, for: scope) }
        }
        // Cancellation aborts the login and saves no choice. Ordinary SSH is
        // an explicit, remembered decision from the separate Don't install action.
        return remembered(scope)
    }

    /// Forget the remembered choice and revoke live enhancement permissions.
    /// Ordinary terminals remain usable; the next login must ask again.
    func reset(_ scope: SSHIntegrationScope) {
        pending.removeValue(forKey: scope.key)?.task.cancel()
        cancelHooks(scope)
        entries.removeValue(forKey: scope.key)
        persist()
        onChange?(scope, .init(profile: .ordinary))
    }

    /// Clear all saved scopes, including disconnected hosts, and invalidate
    /// outstanding choices before publishing live permission reductions.
    func resetAll() {
        let scopes = entries.values.map(\.scope)
        let choices = Array(pending.values)
        pending.removeAll()
        for choice in choices { choice.task.cancel() }
        for scope in scopes { cancelHooks(scope) }
        entries.removeAll()
        persist()
        for scope in scopes { onChange?(scope, .init(profile: .ordinary)) }
    }

    func save(_ grant: SSHIntegrationGrant, for scope: SSHIntegrationScope) {
        guard grant.isCurrent else { return }
        pending.removeValue(forKey: scope.key)?.task.cancel()
        if !grant.hooks { cancelHooks(scope) }
        entries[scope.key] = Entry(scope: scope, grant: grant, hooks: entries[scope.key]?.hooks)
        persist()
        onChange?(scope, grant)
    }

    func save(_ selection: SSHIntegrationSelection, for scope: SSHIntegrationScope) {
        save(selection.grant, for: scope)
        for (agent, enabled) in selection.agents.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            saveHooks(enabled, for: scope, agent: agent)
        }
    }

    /// Per-agent answers for the consent sheet, including ones not yet asked.
    func agentHooks(_ scope: SSHIntegrationScope) -> [SSHHookAgent: Bool] {
        guard let entry = entries[scope.key] else { return [:] }
        return Dictionary(uniqueKeysWithValues: SSHHookAgent.allCases.compactMap { agent in
            entry.hooks?[agent.rawValue].map { (agent, $0) }
        })
    }

    func hooks(_ scope: SSHIntegrationScope, agent: SSHHookAgent) -> Bool? {
        guard remembered(scope)?.hooks == true else { return nil }
        return entries[scope.key]?.hooks?[agent.rawValue]
    }

    func chooseHooks(_ scope: SSHIntegrationScope, agent: SSHHookAgent,
                     present: @escaping @MainActor () async -> Bool?) async -> Bool? {
        guard !Task.isCancelled, remembered(scope)?.hooks == true else { return nil }
        if let answer = hooks(scope, agent: agent) { return answer }
        let choice: PendingChoice<Bool>
        if let existing = pendingHooks[scope.key]?[agent] { choice = existing }
        else {
            choice = PendingChoice(task: Task { @MainActor in await present() })
            pendingHooks[scope.key, default: [:]][agent] = choice
        }
        let waiter = UUID()
        pendingHooks[scope.key]?[agent]?.waiters.insert(waiter)
        let answer = await withTaskCancellationHandler {
            await choice.task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, pendingHooks[scope.key]?[agent]?.id == choice.id else { return }
                pendingHooks[scope.key]?[agent]?.waiters.remove(waiter)
                if pendingHooks[scope.key]?[agent]?.waiters.isEmpty == true {
                    pendingHooks[scope.key]?.removeValue(forKey: agent)?.task.cancel()
                }
            }
        }
        guard !Task.isCancelled else { return nil }
        if pendingHooks[scope.key]?[agent]?.id == choice.id {
            pendingHooks[scope.key]?[agent] = nil
            if let answer { saveHooks(answer, for: scope, agent: agent) }
        }
        return hooks(scope, agent: agent)
    }

    func saveHooks(_ enabled: Bool, for scope: SSHIntegrationScope, agent: SSHHookAgent) {
        pendingHooks[scope.key]?.removeValue(forKey: agent)?.task.cancel()
        guard remembered(scope)?.hooks == true, var entry = entries[scope.key] else { return }
        if entry.hooks == nil { entry.hooks = [:] }
        entry.hooks?[agent.rawValue] = enabled
        entries[scope.key] = entry
        persist()
    }

    private func cancelHooks(_ scope: SSHIntegrationScope) {
        for choice in pendingHooks.removeValue(forKey: scope.key)?.values ?? [:].values { choice.task.cancel() }
    }

    private func persist() {
        guard !entries.isEmpty else { defaults?.removeObject(forKey: "SSHIntegrationPermissions.v2"); return }
        if let bytes = try? JSONEncoder().encode(Array(entries.values)) {
            defaults?.set(bytes, forKey: "SSHIntegrationPermissions.v2")
        }
    }
}
