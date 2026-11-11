import Observation

/// Where Settings goes next: a page and, on Hosts, the row to open ("local" for This Mac, else a host's id). Other
/// places ask for it (Check for Updates…, a host's stats, Features' agent rows); Settings takes the request as it
/// shows, or at once while it shows, and clears it.
@MainActor @Observable final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var page: SettingsView.SettingsTab?
    var host: String?

    /// Hosts, with `host`'s row open.
    func hosts(_ host: String) {
        self.host = host
        page = .hosts
    }
}

/// The files an agent's hooks on this Mac edit, as the Install confirmation and Settings name them.
enum LocalAgentHooks {
    static func file(_ key: String) -> String? {
        func folder(_ variable: String, _ fallback: String) -> String {
            let value = System.environment(variable).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            let home = System.home.path
            return value.hasPrefix(home + "/") ? "~" + value.dropFirst(home.count) : value
        }
        switch key {
        case "claude": return folder("CLAUDE_CONFIG_DIR", "~/.claude") + "/settings.json"
        case "codex": return folder("CODEX_HOME", "~/.codex") + "/hooks.json"
        case "pi": return "~/.pi/agent/extensions/dispatch-chat.js"
        default: return nil
        }
    }

    /// What installing `label`'s hooks does here, for its confirmation.
    static func installMessage(_ key: String, label: String) -> String {
        let file = file(key).map { "Dispatch adds its hooks to \($0)" } ?? "Dispatch adds its hooks to \(label)’s own configuration"
        let how = key == "pi" ? "." : ", rewriting the file pretty-printed with sorted keys and no backup."
        return file + how + " \(label) then sends its approvals, questions and activity to Chat. Remove takes them out again"
            + (key == "codex" ? " from Chat; Codex’s entries stay in the file, unused, so its /hooks trust is kept." : ".")
    }
}
