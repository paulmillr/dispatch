#if DEBUG
import SwiftUI

/// The Spaces redesign's mockup data (mockups/Sources/SpacesScreens.swift: P1–P3, W0), for `-DispatchTabsSample YES
/// -DispatchSpacesMockup P1|W0` screenshots: mba2 on herdr with app (five tabs as P2 draws them, on `dark-mode`), e2e
/// and two detached tabs; studio on tmux with docs and billing; ai offline since two hours (W0 adds build, offline since
/// yesterday). The plain sample (`TabsSample.model`) stays as it is for the other screens and tests.
@MainActor
extension TabsSample {
    static let build = TabsHost(id: UUID(uuidString: "00000000-0000-0000-0000-00000000A005")!, name: "build",
                                tint: Color(red: 0xd9 / 255, green: 0xa4 / 255, blue: 0x6a / 255),
                                system: HostSystem(os: "Linux", distribution: nil, name: "Linux"), home: "/home/alex", order: 3)

    /// The mockup's spaces; `variant` "W0" adds the second offline host.
    static func spacesMockup(variant: String, now: Date = Date()) -> MobileTabs {
        let defaults = UserDefaults(suiteName: "tabs-sample-spaces")!
        defaults.removePersistentDomain(forName: "tabs-sample-spaces")
        let store = TabActivityStore(url: nil)
        let model = MobileTabs(activity: store, defaults: defaults,
                               deviceState: SpacesDeviceState(url: nil, migrating: defaults))
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let src = "/Users/alex/src"
        let mba = TopologySketch(backend: 1, first: 10, spaces: [
            .init(key: "herdr:app", name: "app", cwd: "\(src)/app", tabs: [
                .init(key: "herdr:app:1", name: "claude", panes: [.init(key: "p:app:sidebar", name: "claude", cwd: "\(src)/app", agent: "m1")]),
                .init(key: "herdr:app:2", name: "pnpm dev", renamed: true, panes: [.init(key: "p:app:dev", name: "pnpm", cwd: "\(src)/app")]),
                .init(key: "herdr:app:3", name: "zsh", renamed: true, panes: [.init(key: "p:app:zsh", name: "zsh", cwd: "\(src)/app")]),
                .init(key: "herdr:app:4", name: "codex", panes: [.init(key: "p:app:rate", name: "codex", cwd: "\(src)/app", agent: "m2")]),
                .init(key: "herdr:app:5", name: "claude", panes: [.init(key: "p:app:docs", name: "claude", cwd: "\(src)/app", agent: "m3")]),
            ]),
            .init(key: "herdr:e2e", name: "e2e", cwd: "\(src)/e2e", tabs: [
                .init(key: "herdr:e2e:1", name: "zsh", renamed: true, panes: [.init(key: "p:e2e:zsh", name: "zsh", cwd: "\(src)/e2e")]),
                .init(key: "herdr:e2e:2", name: "playwright", renamed: true, panes: [.init(key: "p:e2e:pw", name: "node", cwd: "\(src)/e2e")],
                      detached: true),
                .init(key: "herdr:e2e:3", name: "storybook", renamed: true, panes: [.init(key: "p:e2e:sb", name: "node", cwd: "\(src)/e2e")],
                      detached: true),
            ]),
        ])
        let studioSketch = TopologySketch(backend: 1, first: 100, spaces: [
            .init(key: "tmux:docs", name: "docs", cwd: "\(src)/docs", tabs: [
                .init(key: "tmux:docs:@1", name: "claude", panes: [.init(key: "p:docs:claude", name: "claude", cwd: "\(src)/docs", agent: "m4")]),
                .init(key: "tmux:docs:@2", name: "zsh", panes: [.init(key: "p:docs:zsh", name: "zsh", cwd: "\(src)/docs")]),
            ]),
            .init(key: "tmux:billing", name: "billing", cwd: "\(src)/billing", tabs: [
                .init(key: "tmux:billing:@3", name: "codex", panes: [.init(key: "p:billing:codex", name: "codex", cwd: "\(src)/billing", agent: "m5")]),
                .init(key: "tmux:billing:@4", name: "zsh", panes: [.init(key: "p:billing:zsh", name: "zsh", cwd: "\(src)/billing")]),
            ]),
        ])
        let curves = TopologySketch(backend: 1, first: 200, spaces: [
            .init(key: "herdr:curves", name: "curves", cwd: "/home/alex/curves", tabs: [
                .init(key: "herdr:curves:1", name: "zsh", renamed: true, panes: [.init(key: "p:curves:zsh", name: "zsh", cwd: "/home/alex/curves")]),
            ]),
        ])
        let ci = TopologySketch(backend: 1, first: 300, spaces: [
            .init(key: "tmux:ci", name: "ci", cwd: "/home/alex/ci", tabs: [
                .init(key: "tmux:ci:@1", name: "zsh", panes: [.init(key: "p:ci:zsh", name: "zsh", cwd: "/home/alex/ci")]),
            ]),
        ])
        var hosts: [(TabsHost, TopologySketch, String)] = [(mba2, mba, "herdr"), (studio, studioSketch, "tmux"), (ai, curves, "herdr")]
        if variant == "W0" { hosts.append((build, ci, "tmux")) }
        let times: [String: Date] = [
            "p:app:sidebar": now, "p:app:dev": ago(56), "p:app:zsh": ago(78), "p:app:rate": ago(93), "p:app:docs": ago(192),
            "p:e2e:zsh": ago(240), "p:docs:claude": ago(30), "p:docs:zsh": ago(300), "p:billing:codex": ago(600),
            "p:billing:zsh": ago(700),
        ]
        // Before the snapshots: a tab takes its time when its topology is applied.
        for (sample, _, _) in hosts { for (key, date) in times { store.note(host: sample.id, key: key, at: date) } }
        var keys: [UInt64: String] = [:]
        // A minute past the hours: the rows read "as of" on the minute's timeline.
        var offline: [UUID: Date] = [ai.id: now.addingTimeInterval(-2 * 3600 - 60)]
        offline[build.id] = Calendar.current.date(byAdding: .day, value: -1, to: now)
        for (sample, sketch, multiplexer) in hosts {
            var host = sample
            host.multiplexer = multiplexer
            // The mockup draws studio's glyph in the label colour.
            if sample.id == studio.id { host.tint = .primary }
            let up = offline[sample.id] == nil
            if !up {
                host.state = .offline
                host.live = false
                host.offlineSince = offline[sample.id]
            }
            let workspace = MobileWorkspace(host: host, client: up ? sampleClient : nil, activity: store, now: { now })
            workspace.features = ["projects.recent", "multiplexers.versions"]
            workspace.multiplexers = multiplexers([multiplexer])
            workspace.choice = workspace.multiplexers.first
            workspace.apply(sketch.topology)
            model.insert(workspace)
            for (key, id) in sketch.ids { keys[id] = key }
        }
        let titles = ["p:app:sidebar": "Sidebar theme toggle", "p:app:rate": "Rate limiter for the API",
                      "p:app:docs": "Docs site migration", "p:docs:claude": "Versioned docs search",
                      "p:billing:codex": "Invoice PDF rounding"]
        let status = ["p:app:sidebar": "Editing Sidebar.tsx", "p:app:rate": "Allow cargo test --workspace?",
                      "p:app:docs": "Moved the docs to Starlight; the old MkDocs config is gone.",
                      "p:docs:claude": "Should the search index include drafts?",
                      "p:billing:codex": "Rounded every line before the total."]
        let urgency: [String: TabUrgency] = ["p:app:sidebar": .working, "p:app:rate": .needsYou, "p:docs:claude": .needsYou]
        let agents = ["p:app:sidebar": "claude", "p:app:rate": "codex", "p:app:docs": "claude", "p:docs:claude": "claude",
                      "p:billing:codex": "codex"]
        let paneTitles = ["p:app:dev": "vite ready · localhost:5173"]
        model.urgency = { _, terminal in keys[terminal].flatMap { urgency[$0] } }
        // The working agent counts from its turn's start, 48 s before the sample was made.
        let started = now.addingTimeInterval(-48)
        model.status = { _, terminal in
            keys[terminal].flatMap { key in status[key].map { TabsStatus(text: $0, since: key == "p:app:sidebar" ? started : nil) } }
        }
        model.conversationTitle = { _, terminal in keys[terminal].flatMap { titles[$0] } }
        model.agentKey = { _, terminal in keys[terminal].flatMap { agents[$0] } }
        model.paneTitle = { _, key in paneTitles[key] }
        model.updated = { host in offline[host] ?? now }
        // P2's "open" chip: the dev tab, as if just shown.
        if let dev = model.tab(TabRef(host: mba2.id, key: "herdr:app:2")) { model.opened(dev) }
        return model
    }

    /// The mockup's branches by space (P1): app on dark-mode, docs on main, billing on fix/invoices; e2e none.
    static let spaceBranches = ["herdr:app": "dark-mode", "tmux:docs": "main", "tmux:billing": "fix/invoices"]

    /// New tab's agents on the sample's hosts (P2e): Claude, Codex and Pi with the models New chat would use.
    static let agentLauncher = SpacesAgentLauncher(choices: { _ in
        [SpacesAgentChoice(key: "claude", label: "Claude", note: "fable-5.1"),
         SpacesAgentChoice(key: "codex", label: "Codex", note: "astra-6"),
         SpacesAgentChoice(key: "pi", label: "Pi", note: "pi 1.3")]
    }, start: { _, _ in throw TabsFailure(message: "The sample's hosts start no agents.") })

    /// P3's host row on the sample's hosts.
    static func statsLine(_ host: UUID) -> String? { host == mba2.id ? "34% cpu · 34% mem · 18 ms" : nil }
}
#endif
