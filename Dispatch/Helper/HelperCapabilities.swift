import Foundation

/// Helper permission groups shared by the desktop grant and the phone's narrower grant. These describe authority;
/// hello features only negotiate protocol behavior and never add permissions.
enum HelperCapabilities {
    enum Feature: String, Codable, CaseIterable, Sendable {
        case statistics, files, filesWrite, chat, hooks, git, tmux, herdr

        var capabilities: Set<String> {
            switch self {
            case .statistics: ["stats.sample", "stats.ping", "stats.processes"]
            case .files: ["file.read", "file.text"]
            case .filesWrite: ["file.read", "file.text", "file.write"]
            case .git: ["file.read", "file.text", "git.read"]
            case .chat: ["agent.inspect", "agent.version", "agent.submit", "agent.events", "agent.queue", "agent.side", "backend.register", "file.read", "file.text"]
            case .hooks: ["hooks.configure", "agent.pi", "agent.pi.configure", "backend.register"]
            case .tmux: ["tmux.pane", "backend.register"]
            case .herdr: ["herdr.start", "herdr.rpc", "herdr.terminal", "backend.register"]
            }
        }
    }

    /// The transport and account operations every enabled helper needs, even with no optional feature selected.
    private static let base: Set<String> = ["host.identity", "shell.lifecycle", "cancel", "events", "input.window"]

    static func selected(_ features: Set<Feature>) -> Set<String> {
        features.reduce(into: base) { $0.formUnion($1.capabilities) }
    }

    static let statistics = selected([.statistics])

    static func full(hooks: Bool) -> Set<String> {
        // Preserve the legacy profile's insertion order: synthesized grant encoding writes Set iteration order,
        // and existing host.reply replay keys contain that exact array under deterministic hashing.
        var values = statistics
        values.formUnion(["agent.inspect", "agent.version", "agent.submit", "agent.events", "agent.queue", "agent.side", "backend.register", "tmux.pane", "herdr.start", "herdr.rpc", "herdr.terminal", "file.read", "file.text", "file.write", "git.read"])
        if hooks { values.formUnion(["hooks.configure", "agent.pi", "agent.pi.configure"]) }
        return values
    }

    /// Explicit phone features keep file writes out of its grant. Chat off removes both agent access and hooks;
    /// Files & git off removes only git metadata, retaining the file reads terminal/chat operations need.
    static func mobile(chat: Bool = true, files: Bool = true) -> [String] {
        selected([.statistics, .files, .chat, .hooks, .git, .tmux, .herdr])
            .filter { (chat || !isChat($0)) && (files || $0 != git) }
            .sorted()
    }

    static func isChat(_ capability: String) -> Bool {
        capability.hasPrefix("agent.") || capability == "hooks.configure"
    }

    static let git = "git.read"
}
