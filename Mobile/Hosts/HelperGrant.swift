import Foundation

/// The one grant the phone runs the helper with (docs/ios.md, Helper contract): the Mac's full profile with hooks on
/// (`SSHIntegrationGrant.capabilities(.full, hooks: true)`). On the phone the helper is not optional, so there is no
/// per-host choice; the New host sheet states what this grant lets it do (`disclosures`), and the SSH driver runs
/// `command(sha256:)` on a plain exec channel: no PTY, no extra environment.
enum HelperGrant {
    static let capabilities = [
        "agent.events", "agent.inspect", "agent.pi", "agent.pi.configure", "agent.queue", "agent.side", "agent.submit",
        "agent.version", "backend.register", "cancel", "events", "file.read", "file.text", "herdr.rpc", "herdr.start",
        "herdr.terminal", "hooks.configure", "host.identity", "input.window", "shell.lifecycle", "stats.ping",
        "stats.processes", "stats.sample", "tmux.pane",
    ]

    /// The `--capabilities` argument.
    static var capabilityList: String { capabilities.joined(separator: ",") }

    /// The grant with Chat off for a host (Settings): no hooks and no agent capabilities, so the helper neither installs
    /// hooks nor reads or drives agents; tmux, herdr, files and stats stay.
    static let chatOffCapabilities = capabilities.filter { !$0.hasPrefix("agent.") && $0 != "hooks.configure" }

    static func capabilities(chat: Bool) -> [String] { chat ? capabilities : chatOffCapabilities }

    static func capabilityList(chat: Bool) -> String { capabilities(chat: chat).joined(separator: ",") }

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

    static let statement = "Dispatch installs its helper in ~/.dispatch on the host and runs it over this connection, as your user. It reads your tmux and herdr sessions, your coding agents’ transcripts and the files they show, the host’s CPU, memory and processes, and which machine it is; it adds hooks to Claude Code, Codex and Pi so you can answer them here, and opens terminals and types into them when you ask. "
}
