import Foundation

/// The grant the phone runs the helper with (docs/ios.md, Helper contract): the Mac's full profile with hooks on
/// (`SSHIntegrationGrant.capabilities(.full, hooks: true)`) less file writes (`file.write`: the phone never changes a
/// file). Two per-host switches narrow it: Chat off drops hooks and the agent capabilities, Files & git off drops
/// `git.read` (read-only `files.git` and `files.branch`). Without the helper (the Helper switch, docs/ios.md Plain SSH)
/// nothing runs at all. The New host sheet states what this grant lets it do (`disclosures`), and the SSH driver runs
/// `command(sha256:)` on a plain exec channel: no PTY, no extra environment.
enum HelperGrant {
    /// Everything with Chat and Files on: the default for a new host.
    static let capabilities = [
        "agent.events", "agent.inspect", "agent.pi", "agent.pi.configure", "agent.queue", "agent.side", "agent.submit",
        "agent.version", "backend.register", "cancel", "events", "file.read", "file.text", "git.read", "herdr.rpc",
        "herdr.start", "herdr.terminal", "hooks.configure", "host.identity", "input.window", "shell.lifecycle", "stats.ping",
        "stats.processes", "stats.sample", "tmux.pane",
    ]

    /// The `--capabilities` argument.
    static var capabilityList: String { capabilities.joined(separator: ",") }

    /// The capabilities Chat brings: hooks and the agents'. Off, the helper neither installs hooks nor reads or drives
    /// agents; tmux, herdr, files and stats stay.
    static func chatCapability(_ capability: String) -> Bool { capability.hasPrefix("agent.") || capability == "hooks.configure" }

    /// The capability Files & git brings: git's read-only commands in the tab's folder (`files.git`, `files.branch`).
    static let gitCapability = "git.read"

    /// The grant with Chat off for a host (Settings), Files & git on.
    static let chatOffCapabilities = capabilities(chat: false, files: true)

    /// The grant for a host's switches.
    static func capabilities(chat: Bool, files: Bool = true) -> [String] {
        capabilities.filter { (chat || !chatCapability($0)) && (files || $0 != gitCapability) }
    }

    static func capabilityList(chat: Bool, files: Bool = true) -> String { capabilities(chat: chat, files: files).joined(separator: ",") }

    /// The hash-named install of the helper build this app ships (`HelperBinary` version file).
    static func path(sha256: String) -> String { "$HOME/.dispatch/bin/versions/\(sha256)/dispatch-helper" }

    /// The exec channel's command.
    static func command(sha256: String) -> String {
        "exec \"\(path(sha256: sha256))\" --remote --capabilities \(capabilityList) --stdio"
    }

    /// Which words of the New host statement disclose each capability, by prefix. Tests keep the statement and the
    /// grant in step: a capability added here without a disclosure fails them.
    static let disclosures: [(prefix: String, phrase: String)] = [
        ("agent.", "coding agents"),
        ("hooks.", "adds hooks"),
        ("file.", "files"),
        ("git.", "git status, diffs and history"),
        ("stats.", "CPU, memory and processes"),
        ("tmux.", "tmux"),
        ("herdr.", "herdr"),
        ("input.", "types into them"),
        ("shell.", "opens terminals"),
        ("backend.", "opens terminals"),
        ("host.identity", "which machine"),
        ("events", "coding agents"),
        ("cancel", "coding agents"),
    ]

    static let statement = "Dispatch installs its helper in ~/.dispatch on the host and runs it over this connection, as your user. It reads your tmux and herdr sessions, your coding agents’ transcripts and the files they show, your repositories’ git status, diffs and history (read only), the host’s CPU, memory and processes, and which machine it is; it adds hooks to Claude Code, Codex and Pi so you can answer them here, and opens terminals and types into them when you ask. "
}
