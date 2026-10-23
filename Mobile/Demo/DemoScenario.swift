#if DEBUG
import Foundation

/// The simulator demo (`./run.sh --ios --demo`, `DISPATCH_MOBILE_DEMO=1`): three hosts a day of work left behind, over
/// the scripted driver and an in-process helper (`DemoHelper`) that speaks the real protocol, so Spaces, Agents, chat
/// threads, approvals and terminals all run the app's own code. Conversations are the real helper's records of
/// authored transcripts and terminals recorded sessions (`Mobile/Demo/Fixtures`, `test/mobile-demo-fixtures.py`);
/// nothing reaches a host, and the names are fictional.
enum DemoScenario {
    enum Agent: Sendable {
        case claude, codex

        var model: String { self == .claude ? "fable-5.1" : "astra-6" }
        var key: String { self == .claude ? "claude" : "codex" }
        var executable: String { self == .claude ? "/usr/local/bin/claude" : "/opt/homebrew/bin/codex" }
    }

    /// What the agent is doing as the demo opens.
    enum State: Sendable {
        /// Mid-turn: the thinking row counts from `started` seconds ago.
        case working(started: Int)
        /// A command waits for Allow.
        case approval(command: String, description: String)
        /// A question with these options waits for an answer.
        case question(header: String, text: String, options: [(label: String, detail: String)])
        /// Done; the user has not looked yet.
        case finished
        /// Done and seen.
        case idle
    }

    enum Content: Sendable {
        /// A shell: `terminals/<name>.vt`; `live` appends `live/<name>.txt` a line at a time.
        case shell(String, live: Bool = false)
        /// An agent: `chats/<name>.json`, its last record `minutesAgo` before launch.
        case agent(chat: String, Agent, State, minutesAgo: Double)
    }

    struct Host: Sendable {
        let record: HostRecord
        let hello: HelperSession.Info
        let multiplexer: String
        let version: String
        let latency: Duration
        let sketch: TopologySketch
        /// By pane key.
        let content: [String: Content]

        /// By terminal id, as the helper's requests name them.
        var terminals: [UInt64: Content] {
            Dictionary(uniqueKeysWithValues: sketch.ids.compactMap { key, id in content[key].map { (id, $0) } })
        }
    }

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["DISPATCH_MOBILE_DEMO"].map { $0 != "0" } ?? false
            || UserDefaults.standard.bool(forKey: "DispatchDemo")
    }

    /// The demo's sessions: in memory, nothing saved, every host connected through its `DemoHelper`.
    @MainActor static func sessions() -> HostSessions {
        // `-DispatchHostStatsState plain`: the stats screenshots' host without its helper (W6).
        let hosts = Self.hosts().map { host in
            guard host.record.name == HostStatsDemo.plainHost else { return host }
            var record = host.record
            record.helper = false
            return Host(record: record, hello: host.hello, multiplexer: host.multiplexer, version: host.version,
                        latency: host.latency, sketch: host.sketch, content: host.content)
        }
        let driver = ScriptedHostSessionDriver { record in
            guard let host = hosts.first(where: { $0.record.id == record.id }) else { return [.event(.link(.failed("Not in the demo")))] }
            if !record.helper {
                return [.event(.link(.connecting)), .sleep(.milliseconds(60)), .event(.link(.authenticating)),
                        .sleep(.milliseconds(40)), .plain(reason: nil), .hold]
            }
            return [.event(.link(.connecting)), .sleep(.milliseconds(60)), .event(.link(.authenticating)), .sleep(.milliseconds(40)),
                    .event(.link(.bootstrapping)), .sleep(.milliseconds(50)), .event(.following(host.multiplexer)),
                    .readyWith(client: { DemoHelper.connect(host) }, hello: host.hello,
                               multiplexers: HostFixture.multiplexers([host.multiplexer]), versions: [host.multiplexer: host.version],
                               topology: host.sketch.topology),
                    .event(.latency(host.latency)), .hold]
        }
        let keys = KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none, secureEnclaveAvailable: false)
        let sessions = HostSessions(store: HostStore(url: nil, hosts: hosts.map(\.record)), keys: keys,
                                    knownHosts: KnownHostStore(url: nil), driver: driver, active: true)
        // The 15 minutes before launch, so the stats' chart is full at once.
        for session in sessions.ordered {
            let home = hosts.first { $0.record.id == session.id }?.hello.account?.home ?? "/Users/alex"
            HostStatsDemo.seed(session.stats, host: session.host.name, home: home)
        }
        return sessions
    }

    static func hosts(now: Date = Date()) -> [Host] {
        let mac = { (name: String, home: String) in
            HostFixture.hello(identity: "demo-\(name)", hostname: name, home: home)
        }
        let mba2 = Host(
            record: HostRecord(name: "mba2", address: "mba2.tail3f.ts.net", user: "alex", auth: .password, order: 0,
                               lastConnected: now, tintSeed: "demo-mba2", system: .mac, osLabel: "macOS 26.1"),
            hello: mac("mba2", "/Users/alex"), multiplexer: "herdr", version: "0.9.5", latency: .milliseconds(18),
            sketch: TopologySketch(backend: 1, first: 10, spaces: [
                .init(key: "herdr:web", name: "web", cwd: "/Users/alex/src/web", tabs: [
                    .init(key: "herdr:web:1", name: "claude", panes: [
                        .init(key: "p:web:claude", name: "claude", cwd: "/Users/alex/src/web", agent: "web-dark-mode")]),
                    .init(key: "herdr:web:2", name: "pnpm", panes: [.init(key: "p:web:dev", name: "pnpm dev", cwd: "/Users/alex/src/web")]),
                    .init(key: "herdr:web:3", name: "zsh", panes: [.init(key: "p:web:zsh", name: "zsh", cwd: "/Users/alex/src/web")]),
                ]),
                .init(key: "herdr:billing", name: "billing", cwd: "/Users/alex/src/billing", tabs: [
                    .init(key: "herdr:billing:1", name: "claude", panes: [
                        .init(key: "p:billing:claude", name: "claude", cwd: "/Users/alex/src/billing", agent: "billing-idempotency")]),
                    .init(key: "herdr:billing:2", name: "zsh", panes: [
                        .init(key: "p:billing:zsh", name: "zsh", cwd: "/Users/alex/src/billing")]),
                ]),
            ]),
            content: [
                "p:web:claude": .agent(chat: "web-dark-mode", .claude, .working(started: 48), minutesAgo: 0),
                "p:web:dev": .shell("web-dev", live: true),
                "p:web:zsh": .shell("web-git"),
                "p:billing:claude": .agent(chat: "billing-idempotency", .claude, .finished, minutesAgo: 22),
                "p:billing:zsh": .shell("billing-tests"),
            ])
        let studio = Host(
            record: HostRecord(name: "studio", address: "studio.tail3f.ts.net", user: "alex", auth: .password, order: 1,
                               lastConnected: now.addingTimeInterval(-1800), tintSeed: "demo-studio", system: .mac, osLabel: "macOS 26.1"),
            hello: mac("studio", "/Users/alex"), multiplexer: "tmux", version: "3.7", latency: .milliseconds(31),
            sketch: TopologySketch(backend: 1, first: 100, spaces: [
                .init(key: "tmux:api", name: "api", cwd: "/Users/alex/src/api", tabs: [
                    .init(key: "tmux:api:@1", name: "codex", panes: [
                        .init(key: "p:api:codex", name: "codex", cwd: "/Users/alex/src/api", agent: "api-rate-limit")]),
                    .init(key: "tmux:api:@2", name: "zsh", panes: [.init(key: "p:api:zsh", name: "zsh", cwd: "/Users/alex/src/api")]),
                    .init(key: "tmux:api:@3", name: "cargo", panes: [.init(key: "p:api:logs", name: "cargo run", cwd: "/Users/alex/src/api")]),
                ]),
                .init(key: "tmux:docs", name: "docs", cwd: "/Users/alex/src/docs", tabs: [
                    .init(key: "tmux:docs:@4", name: "claude", panes: [
                        .init(key: "p:docs:claude", name: "claude", cwd: "/Users/alex/src/docs", agent: "docs-question")]),
                    .init(key: "tmux:docs:@5", name: "zsh", panes: [.init(key: "p:docs:zsh", name: "zsh", cwd: "/Users/alex/src/docs")]),
                ]),
            ]),
            content: [
                "p:api:codex": .agent(chat: "api-rate-limit", .codex,
                                      .approval(command: "cargo test --workspace",
                                                description: "Run the full test suite to check the new rate limiter against every route."),
                                      minutesAgo: 3),
                "p:api:zsh": .shell("api-cargo"),
                "p:api:logs": .shell("api-logs", live: true),
                "p:docs:claude": .agent(chat: "docs-question", .claude,
                                        .question(header: "Docs site", text: "Which should we move the docs to?", options: [
                                            ("Astro Starlight", "Fast builds, MDX, theming through CSS variables"),
                                            ("Docusaurus", "React-based, versioned docs and a big plugin ecosystem"),
                                            ("Keep MkDocs", "Tune the build: drop the unused plugins and cache the site"),
                                        ]),
                                        minutesAgo: 41),
                "p:docs:zsh": .shell("docs-shell"),
            ])
        let ai = Host(
            record: HostRecord(name: "ai", address: "ai.tail3f.ts.net", user: "alex", auth: .password, order: 2,
                               lastConnected: now.addingTimeInterval(-7200), tintSeed: "demo-ai",
                               system: HostSystem(os: "Linux", distribution: "ubuntu", name: "Ubuntu 24.04.1 LTS"), osLabel: "Ubuntu 24.04"),
            hello: HostFixture.hello(identity: "demo-ai", hostname: "ai", os: "Linux", distribution: "ubuntu",
                                     osName: "Ubuntu 24.04.1 LTS", label: "Ubuntu 24.04", version: "24.04", home: "/home/alex"),
            multiplexer: "tmux", version: "3.7", latency: .milliseconds(46),
            sketch: TopologySketch(backend: 1, first: 200, spaces: [
                .init(key: "tmux:train", name: "train", cwd: "/home/alex/train", tabs: [
                    .init(key: "tmux:train:@1", name: "codex", panes: [
                        .init(key: "p:train:codex", name: "codex", cwd: "/home/alex/train", agent: "train-eval")]),
                    .init(key: "tmux:train:@2", name: "python", panes: [
                        .init(key: "p:train:watch", name: "python train.py", cwd: "/home/alex/train")]),
                    .init(key: "tmux:train:@3", name: "bash", panes: [.init(key: "p:train:zsh", name: "bash", cwd: "/home/alex/train")]),
                ]),
            ]),
            content: [
                "p:train:codex": .agent(chat: "train-eval", .codex, .idle, minutesAgo: 9 * 60),
                "p:train:watch": .shell("train-gpu", live: true),
                "p:train:zsh": .shell("train-shell"),
            ])
        return [mba2, studio, ai]
    }

    // MARK: Fixtures

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// A chat's records as the helper's archive read produced them, oldest first.
    static func records(_ name: String) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: fixtures.appendingPathComponent("chats/\(name).json")),
              let pages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return pages.flatMap { $0["records"] as? [[String: Any]] ?? [] }
    }

    /// A shell's recorded screen; a stand-in line when the fixture is missing.
    static func terminal(_ name: String) -> Data {
        (try? Data(contentsOf: fixtures.appendingPathComponent("terminals/\(name).vt")))
            ?? Data("(demo terminal \(name) is missing: python3 test/mobile-demo-fixtures.py)\r\n$ ".utf8)
    }

    static func liveLines(_ name: String) -> [String] {
        guard let text = try? String(contentsOf: fixtures.appendingPathComponent("live/\(name).txt"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
#endif
