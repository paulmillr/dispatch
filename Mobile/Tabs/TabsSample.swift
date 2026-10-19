#if DEBUG
import SwiftUI

/// A compact way to write a helper topology (previews, the screenshot sample, tests): spaces of tabs of panes, ids
/// numbered in order from `first`, each window's layout splitting its panes in columns and focusing `focus`.
struct TopologySketch {
    struct Pane {
        var key: String
        var name = "terminal"
        var cwd: String?
        var agent: String? = nil
    }
    struct Tab {
        var key: String
        var name: String
        var renamed = false
        var panes: [Pane]
        var focus = 0
        var detached = false
    }
    struct Space {
        var key: String
        var name: String
        var cwd: String? = nil
        var tabs: [Tab]
    }

    var backend: UInt64 = 1
    var first: UInt64 = 10
    var spaces: [Space]

    /// The ids `topology` gives, by key.
    var ids: [String: UInt64] {
        var next = first, ids: [String: UInt64] = [:]
        for space in spaces {
            ids[space.key] = next; next += 1
            for tab in space.tabs {
                ids[tab.key] = next; next += 1
                for pane in tab.panes { ids[pane.key] = next; next += 1 }
                if tab.panes.count > 1 { next += 1 }
            }
        }
        return ids
    }

    var topology: HelperTopology {
        var next = first
        var nodes: [[String: Any]] = [], layouts: [[String: Any]] = []
        func node(_ id: UInt64, _ parent: UInt64?, _ key: String, _ kind: String, _ name: String, cwd: String? = nil,
                  renamed: Bool? = nil, agent: String? = nil, detached: Bool = false) -> [String: Any] {
            var object: [String: Any] = ["id": id, "key": key, "kind": kind, "name": name, "detached": detached,
                                         "parent": parent.map { $0 as Any } ?? NSNull()]
            if let cwd { object["cwd"] = cwd }
            if let renamed { object["renamed"] = renamed }
            if let agent {
                object["agent"] = ["session": agent, "transcript": NSNull(), "pid": NSNull(), "start": NSNull(), "executable": NSNull()]
            }
            return object
        }
        for space in spaces {
            let spaceID = next; next += 1
            nodes.append(node(spaceID, nil, space.key, "workspace", space.name, cwd: space.cwd))
            for tab in space.tabs {
                let tabID = next; next += 1
                nodes.append(node(tabID, spaceID, tab.key, "tab", tab.name, renamed: tab.renamed, detached: tab.detached))
                var paneIDs: [UInt64] = []
                for pane in tab.panes {
                    paneIDs.append(next)
                    nodes.append(node(next, tabID, pane.key, "terminal", pane.name, cwd: pane.cwd, agent: pane.agent))
                    next += 1
                }
                let split: [String: Any]
                if paneIDs.count > 1 {
                    split = ["id": next, "axis": "columns", "children": paneIDs.map { ["weight": 1, "split": ["terminal": $0]] }]
                    next += 1
                } else {
                    split = ["terminal": paneIDs.first ?? 0]
                }
                layouts.append(["container": tabID, "full": split, "visible": split,
                                "focus": paneIDs.indices.contains(tab.focus) ? paneIDs[tab.focus] : NSNull()])
            }
        }
        let object: [String: Any] = ["backend": backend, "nodes": nodes, "layouts": layouts, "focus": NSNull()]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(HelperTopology.self, from: data)
    }
}

/// The mockup's hosts and tabs (M2a, M2b, M2c), for previews and `-DispatchTabsSample` screenshots.
@MainActor
enum TabsSample {
    static let mba2 = TabsHost(id: UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!, name: "mba2",
                               tint: Color(red: 0x7e / 255, green: 0xa6 / 255, blue: 0xc9 / 255), system: .mac, home: "/Users/alex", order: 0)
    static let studio = TabsHost(id: UUID(uuidString: "00000000-0000-0000-0000-00000000A003")!, name: "studio",
                                 tint: Color(red: 0xc9 / 255, green: 0xc9 / 255, blue: 0xce / 255), system: .mac, home: "/Users/alex", order: 1)
    static let ai = TabsHost(id: UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!, name: "ai",
                             tint: Color(red: 0xa9 / 255, green: 0x8a / 255, blue: 0xe0 / 255),
                             system: HostSystem(os: "Linux", distribution: "ubuntu", name: "Ubuntu 24.04"), home: "/home/alex", order: 2)

    /// A connected host with no spaces yet (`-DispatchTabsEmptyHost YES`): M2b's New space line.
    static let vps = TabsHost(id: UUID(uuidString: "00000000-0000-0000-0000-00000000A004")!, name: "vps",
                              tint: Color(red: 0x8f / 255, green: 0xc9 / 255, blue: 0x9b / 255),
                              system: HostSystem(os: "Linux", distribution: "ubuntu", name: "Ubuntu 24.04"), home: "/root", order: 3)

    /// The sample's multiplexers: herdr shown where its keys say so, tmux beside it on mba2 and ai.
    static func multiplexers(_ names: [String]) -> [MultiplexerChoice] {
        names.map { name in
            let mux: UInt64 = name == "herdr" ? 2 : 0
            return MultiplexerChoice(mux: mux, name: name, route: .init(mux: mux, key: name), version: name == "herdr" ? "0.9.5" : "3.7")
        }
    }

    static func model(now: Date = Date(), emptyHost: Bool = UserDefaults.standard.bool(forKey: "DispatchTabsEmptyHost")) -> MobileTabs {
        let defaults = UserDefaults(suiteName: "tabs-sample")!
        defaults.removePersistentDomain(forName: "tabs-sample")
        let store = TabActivityStore(url: nil)
        let model = MobileTabs(activity: store, defaults: defaults)
        let calendar = Calendar.current
        func at(_ hour: Int, _ minute: Int, daysAgo: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        let mbaSketch = TopologySketch(backend: 1, first: 10, spaces: [
            .init(key: "herdr:e2e", name: "e2e", tabs: [
                .init(key: "herdr:e2e:1", name: "codex", panes: [.init(key: "p:e2e:codex", cwd: "/Users/alex/src/e2e", agent: "s1")]),
                .init(key: "herdr:e2e:2", name: "zsh", panes: [.init(key: "p:e2e:zsh", cwd: "/Users/alex/src/e2e")]),
            ]),
            .init(key: "herdr:app", name: "app", tabs: [
                .init(key: "herdr:app:1", name: "claude", panes: [.init(key: "p:app:claude", cwd: "/Users/alex/src/app", agent: "s2")]),
                .init(key: "herdr:app:2", name: "dev", panes: [.init(key: "p:app:dev", cwd: "/Users/alex/src/app")]),
                .init(key: "herdr:app:3", name: "zsh", panes: [
                    .init(key: "p:app:zsh", cwd: "/Users/alex/src/app"), .init(key: "p:app:zsh2", cwd: "/Users/alex/src/app/web")]),
            ]),
        ])
        let studioSketch = TopologySketch(backend: 1, first: 100, spaces: [
            .init(key: "tmux:docs", name: "docs", tabs: [
                .init(key: "tmux:docs:@1", name: "claude", panes: [.init(key: "p:docs:claude", cwd: "/Users/alex/src/docs", agent: "s3")]),
                .init(key: "tmux:docs:@2", name: "zsh", panes: [.init(key: "p:docs:zsh", cwd: "/Users/alex/src/docs")]),
            ]),
            .init(key: "tmux:billing", name: "billing", tabs: [
                .init(key: "tmux:billing:@3", name: "codex", panes: [.init(key: "p:billing:codex", cwd: "/Users/alex/src/billing", agent: "s4")]),
                .init(key: "tmux:billing:@4", name: "zsh", panes: [.init(key: "p:billing:zsh", cwd: "/Users/alex/src/billing")]),
            ]),
        ])
        let aiSketch = TopologySketch(backend: 1, first: 200, spaces: [
            .init(key: "herdr:curves", name: "curves", tabs: [
                .init(key: "herdr:curves:1", name: "claude", panes: [.init(key: "p:curves:claude", cwd: "/home/alex/curves", agent: "s5")]),
                .init(key: "herdr:curves:2", name: "zsh", panes: [.init(key: "p:curves:zsh", cwd: "/home/alex/curves")]),
            ]),
        ])
        // Minutes before now, in the mockup's order (M2a: now, 9:31, 9:02, 8:48, 8:40, 8:12, Yesterday, …).
        func ago(_ minutes: Int) -> Date { now.addingTimeInterval(-Double(minutes) * 60) }
        let times: [(UUID, String, Date)] = [
            (mba2.id, "p:app:claude", now), (mba2.id, "p:e2e:codex", ago(29)), (mba2.id, "p:app:dev", ago(58)),
            (studio.id, "p:docs:claude", ago(72)), (mba2.id, "p:app:zsh", ago(80)), (mba2.id, "p:e2e:zsh", ago(108)),
            (ai.id, "p:curves:claude", at(17, 5, daysAgo: 1)), (studio.id, "p:docs:zsh", at(16, 20, daysAgo: 1)),
            (studio.id, "p:billing:codex", at(11, 0, daysAgo: 3)), (studio.id, "p:billing:zsh", at(10, 0, daysAgo: 4)),
            (ai.id, "p:curves:zsh", at(9, 0, daysAgo: 5)),
        ]
        for (host, key, date) in times { store.note(host: host, key: key, at: date) }
        var urgency: [String: TabUrgency] = [:], status: [String: String] = [:]
        urgency["p:e2e:codex"] = .needsYou; status["p:e2e:codex"] = "astra-6 · needs approval"
        urgency["p:app:claude"] = .working; status["p:app:claude"] = "fable-5.1 · thinking 48s"
        urgency["p:docs:claude"] = .needsYou; status["p:docs:claude"] = "fable-5.1 · asked a question"
        urgency["p:curves:claude"] = .unseen; status["p:curves:claude"] = "fable-5.1 · finished"
        status["p:billing:codex"] = "astra-6 · idle"
        var keys: [UInt64: String] = [:]
        let installed = [mba2.id: ["herdr", "tmux"], studio.id: ["tmux"], ai.id: ["herdr", "tmux"], vps.id: ["tmux"]]
        var hosts = [(mba2, mbaSketch), (studio, studioSketch), (ai, aiSketch)]
        if emptyHost { hosts.append((vps, TopologySketch(backend: 1, first: 300, spaces: []))) }
        for (sample, sketch) in hosts {
            // The multiplexer each host shows: tmux on studio and vps, herdr on the others.
            var host = sample
            host.multiplexer = sample.id == studio.id || sample.id == vps.id ? "tmux" : "herdr"
            let workspace = MobileWorkspace(host: host, client: sampleClient, activity: store, now: { now })
            workspace.features = ["projects.recent", "multiplexers.versions"]
            workspace.multiplexers = multiplexers(installed[host.id] ?? [])
            workspace.choice = workspace.multiplexers.first { $0.name == host.multiplexer }
            workspace.apply(sketch.topology)
            model.insert(workspace)
            for (key, id) in sketch.ids { keys[id] = key }
        }
        model.urgency = { _, terminal in keys[terminal].flatMap { urgency[$0] } }
        model.status = { _, terminal in keys[terminal].flatMap { status[$0] } }
        return model
    }

    /// A client answered in process: the sample's hosts count as connected, so the screens offer their actions;
    /// `projects.recent` gives the mockup's folders (M7a), anything else an "unavailable" error.
    private static let sampleClient: HelperClient = {
        let incoming = Pipe(), outgoing = Pipe()
        let peer = HelperTransport(read: outgoing.fileHandleForReading, write: incoming.fileHandleForWriting)
        nonisolated(unsafe) var decoder = HelperWire.Decoder()
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        peer.start(receive: { bytes in
            try? decoder.feed(bytes) { message in
                guard message.kind == .request,
                      case .object(let request) = try HelperBinary.decode(message.body) else { return }
                let reply: HelperBinary.Value
                if request["method"] == .string("projects.recent") {
                    let rows: [(String, UInt64)] = [("/home/alex/src/api", 2 * 3600_000), ("/home/alex/src/web", 26 * 3600_000),
                                                    ("/home/alex/notes", 5 * 86400_000)]
                    reply = .object(["result": .array(rows.map { path, age in
                        .object(["path": .string(path), "time_ms": .unsigned(now - age), "agents": .array([.string("claude")]),
                                 "exists": .bool(true)])
                    })])
                } else {
                    reply = .object(["error": .object(["code": .string("unavailable"), "message": .string("Sample host")])])
                }
                peer.send(try HelperWire.encode(.init(kind: .response, id: message.id, body: try HelperBinary.encode(reply))))
            }
        }, closed: { _ in })
        sampleTransport = peer
        return HelperClient(HelperConnection(read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting))
    }()
    nonisolated(unsafe) private static var sampleTransport: HelperTransport?
}

#Preview("M2a Tabs") {
    let model = TabsSample.model()
    return NavigationStack {
        SpacesRoot(navigator: SpacesNavigator(model: model), hostActions: FakeSpacesHostActions(model: model), addHost: {})
    }
        .preferredColorScheme(.dark)
        .tint(.dispatchPink)
}
#endif
