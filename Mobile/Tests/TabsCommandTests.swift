import Foundation
import XCTest
@testable import DispatchMobile

/// The Tabs commands against a scripted helper over `Pipe()`: what the production client sends and how the replies
/// are taken, including the Mac's close policy.
@MainActor
final class TabsCommandTests: XCTestCase {
    private nonisolated static func multiplexers(_ names: [(UInt64, String, Bool)]) -> ScriptedHelper.Reply {
        .binary(.array(names.map { mux, name, external in
            .object(["mux": .unsigned(mux), "name": .string(name), "external": .bool(external), "claimed": .bool(true), "program": .null])
        }))
    }

    private nonisolated static func backends(_ list: [(UInt64, String, Bool)]) -> ScriptedHelper.Reply {
        .binary(.array(list.map { mux, key, isDefault in
            .object(["mux": .unsigned(mux), "key": .string(key), "label": .string(key), "default": .bool(isDefault), "external": .bool(true)])
        }))
    }

    private func params(_ request: ScriptedHelper.Request) -> NSDictionary { request.params as NSDictionary }

    func testDetectPrefersHerdrOverTmux() async throws {
        let helper = ScriptedHelper.scripted { request in
            switch request.method {
            case "multiplexers.list": Self.multiplexers([(0, "native", false), (1, "tmux", true), (2, "herdr", true)])
            case "backends.list": Self.backends([(0, "native", true), (1, "tmux", true), (2, "herdr", true)])
            default: nil
            }
        }
        defer { helper.close() }
        let workspace = TabsFixtures.workspace(client: helper.client)
        let choice = try await workspace.detect()
        XCTAssertEqual(choice, MultiplexerChoice(mux: 2, name: "herdr", route: .init(mux: 2, key: "herdr")))
        XCTAssertEqual(Set(helper.methods), ["multiplexers.list", "backends.list"])
        XCTAssertEqual(workspace.choice, choice)
        let tmux = try await workspace.detect(override: "tmux")
        XCTAssertEqual(tmux?.name, "tmux")
    }

    func testChoiceNeedsAServerOwnedMultiplexerWithABackend() {
        let kinds = [TabsMultiplexer(mux: 0, name: "native", external: false),
                     TabsMultiplexer(mux: 1, name: "tmux", external: true),
                     TabsMultiplexer(mux: 2, name: "herdr", external: true)]
        let native = [HelperBackend(mux: 0, key: "native", label: "native", isDefault: true)]
        XCTAssertNil(MultiplexerChoice.choose(multiplexers: kinds, backends: native), "native sessions die with the connection")
        let tmuxOnly = native + [HelperBackend(mux: 1, key: "a.sock", label: "a", isDefault: false),
                                 HelperBackend(mux: 1, key: "tmux", label: "tmux", isDefault: true)]
        let choice = MultiplexerChoice.choose(multiplexers: kinds, backends: tmuxOnly, override: "herdr")
        XCTAssertEqual(choice?.name, "tmux", "an override the host cannot serve falls back")
        XCTAssertEqual(choice?.route.key, "tmux", "the default backend")
        XCTAssertNil(choice?.warning)
    }

    /// With `multiplexers.versions`: a herdr the helper says is not installed does not count, the version comes along
    /// for Host detail's line, and tmux without bracketed-paste state (before 3.7) gets the Mac's warning.
    func testVersionedRowsDecideInstallVersionAndWarning() async throws {
        let helper = ScriptedHelper.scripted { request in
            switch request.method {
            case "multiplexers.list":
                .binary(.array([
                    .object(["mux": .unsigned(0), "name": .string("tmux"), "external": .bool(true), "claimed": .bool(true), "program": .null,
                             "installed": .bool(true), "version": .string("3.6a"), "paste_state": .bool(false)]),
                    .object(["mux": .unsigned(2), "name": .string("herdr"), "external": .bool(true), "claimed": .bool(true), "program": .null,
                             "installed": .bool(false), "version": .null]),
                ]))
            case "backends.list": Self.backends([(0, "tmux", true), (2, "herdr", true)])
            default: nil
            }
        }
        defer { helper.close() }
        let workspace = TabsFixtures.workspace(client: helper.client)
        let choice = try await workspace.detect()
        XCTAssertEqual(choice, MultiplexerChoice(mux: 0, name: "tmux", route: .init(mux: 0, key: "tmux"), version: "3.6a",
                                                 warning: "This tmux server cannot report bracketed-paste state. Use the terminal to send input."))
    }

    /// A version without the paste flag reads the same way; Mac-era rows (no feature fields) give no warning.
    func testOldTmuxGetsTheMacWarning() {
        let list = [HelperBackend(mux: 1, key: "tmux", label: "tmux", isDefault: true)]
        let old = MultiplexerChoice.choose(multiplexers: [TabsMultiplexer(mux: 1, name: "tmux", external: true, version: "3.6a")], backends: list)
        XCTAssertEqual(old?.warning, MultiplexerChoice.tmuxWarning)
        XCTAssertNil(MultiplexerChoice.choose(multiplexers: [TabsMultiplexer(mux: 1, name: "tmux", external: true, version: "3.7")], backends: list)?.warning)
        XCTAssertNil(MultiplexerChoice.choose(multiplexers: [TabsMultiplexer(mux: 1, name: "tmux", external: true)], backends: list)?.warning)
        XCTAssertTrue(MultiplexerChoice.tmuxSupported("next-3.8"))
        XCTAssertTrue(MultiplexerChoice.tmuxSupported("4.0"))
        XCTAssertFalse(MultiplexerChoice.tmuxSupported("2.9a"))
    }

    /// M7a's recent folders: `projects.recent` only when the hello accepted the feature; folders that are gone are left
    /// out; a reply without the optional fields still parses.
    func testRecentProjectsNeedTheFeature() async throws {
        let helper = ScriptedHelper.scripted { request in
            guard request.method == "projects.recent" else { return nil }
            return .binary(.array([
                .object(["path": .string("/Users/alex/src/api"), "time_ms": .unsigned(1_800_000_000_000), "agents": .array([.string("claude")]),
                         "exists": .bool(true)]),
                .object(["path": .string("/Users/alex/old"), "time_ms": .unsigned(1_700_000_000_000), "agents": .array([]), "exists": .bool(false)]),
                .object(["path": .string("/Users/alex/notes")]),
            ]))
        }
        defer { helper.close() }
        let workspace = TabsFixtures.workspace(client: helper.client)
        let without = await workspace.recentProjects()
        XCTAssertEqual(without, [])
        XCTAssertEqual(helper.methods, [], "no request without the feature")
        workspace.features = ["projects.recent"]
        let rows = await workspace.recentProjects(limit: 12)
        XCTAssertEqual(rows.map(\.path), ["/Users/alex/src/api", "/Users/alex/notes"])
        XCTAssertEqual(rows.first?.time, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(rows.first?.agents, ["claude"])
        XCTAssertEqual(helper.requests.first?.params as NSDictionary?, ["limit": 12])
    }

    /// The server's last-activity times: `terminals.activity` only when the hello accepted the feature and the spaces are
    /// this connection's; rows by topology key date their tab (a tmux window's key, or a pane's), unreadable rows are
    /// left out, and the times stay in the store for the next launch. A live snapshot asks for them again.
    func testServerActivityNeedsTheFeature() async throws {
        let helper = ScriptedHelper.scripted { request in
            guard request.method == "terminals.activity" else { return nil }
            return .binary(.array([
                .object(["node": .unsigned(12), "key": .string("herdr:app:3"), "kind": .string("tab"),
                         "time_ms": .unsigned(1_800_000_100_000)]),
                .object(["node": .unsigned(13), "key": .string("p:dev"), "kind": .string("terminal"),
                         "time_ms": .unsigned(1_800_000_050_000)]),
                .object(["node": .unsigned(14), "key": .string("herdr:app:1")]),
                .object(["node": .unsigned(15), "key": .string("herdr:elsewhere:1"), "time_ms": .unsigned(1_800_000_200_000)]),
            ]))
        }
        defer { helper.close() }
        let store = TabActivityStore(url: nil)
        let workspace = TabsFixtures.workspace(client: helper.client, store: store)
        workspace.apply(TabsFixtures.app().topology)
        let refreshed = await workspace.refreshActivity()
        XCTAssertFalse(refreshed)
        XCTAssertEqual(helper.methods, [], "no request without the feature")
        workspace.features = [MobileWorkspace.activityFeature]
        var stale = TabsFixtures.host
        stale.live = false
        workspace.update(host: stale)
        let early = await workspace.refreshActivity()
        XCTAssertFalse(early)
        XCTAssertEqual(helper.methods, [], "no request while the spaces are the cache's")
        workspace.update(host: TabsFixtures.host)
        let read = await workspace.refreshActivity()
        XCTAssertTrue(read)
        XCTAssertEqual(helper.requests.first?.params as NSDictionary?, [:])
        XCTAssertEqual(workspace.tab("herdr:app:3")?.activity, Date(timeIntervalSince1970: 1_800_000_100))
        XCTAssertEqual(workspace.tab("herdr:app:2")?.activity, Date(timeIntervalSince1970: 1_800_000_050), "by its pane's key")
        XCTAssertNil(workspace.tab("herdr:app:1")?.activity, "a row without a time is left out")
        XCTAssertEqual(store.date(host: TabsFixtures.host.id, key: "herdr:app:3"), Date(timeIntervalSince1970: 1_800_000_100))
        // The next launch shows the kept time before the host connects.
        var cached = TabsFixtures.host
        cached.live = false
        let relaunched = MobileWorkspace(host: cached, activity: store)
        relaunched.apply(TabsFixtures.app(first: 70).topology)
        XCTAssertEqual(relaunched.tab("herdr:app:3")?.activity, Date(timeIntervalSince1970: 1_800_000_100))
        // A live snapshot reads them again.
        workspace.apply(TabsFixtures.app(extraTab: true).topology)
        try await TestSupport.eventually { helper.requests("terminals.activity").count == 2 }
    }

    /// New space: backends.create for the chosen multiplexer, a terminal under its backend in the directory, then the
    /// space is named once the topology shows it.
    func testCreateSpaceCreatesNamesAndOpens() async throws {
        let sketch = TabsFixtures.app(backend: 7, first: 10, extraTab: false)
        let fresh = TopologySketch(backend: 7, first: 300, spaces: sketch.spaces + [
            .init(key: "herdr:new", name: "3", tabs: [.init(key: "herdr:new:1", name: "zsh", panes: [.init(key: "p:fresh", cwd: "/Users/alex/src/billing")])]),
        ])
        let terminal = fresh.ids["p:fresh"]!
        let helper = ScriptedHelper.scripted { request in
            switch request.method {
            case "backends.create": .value(UInt64(7))
            case "terminals.create": .value(terminal)
            case "entities.rename": .empty
            default: nil
            }
        }
        defer { helper.close() }
        let workspace = TabsFixtures.workspace(client: helper.client)
        workspace.apply(sketch.topology)
        workspace.choice = MultiplexerChoice(mux: 2, name: "herdr", route: .init(mux: 2, key: "herdr"))
        async let created = workspace.createSpace(name: " billing ", directory: "~/src/billing")
        try await TestSupport.eventually { helper.methods.contains("terminals.create") }
        workspace.apply(fresh.topology)
        let tab = try await created
        XCTAssertEqual(tab.ref.key, "herdr:new:1")
        XCTAssertEqual(helper.methods, ["backends.create", "terminals.create", "entities.rename"])
        XCTAssertEqual(params(helper.requests[0]), ["mux": 2, "key": "herdr"])
        XCTAssertEqual(params(helper.requests[1]), ["parent": 7, "cwd": "/Users/alex/src/billing", "environment": []])
        XCTAssertEqual(params(helper.requests[2]), ["node": fresh.ids["herdr:new"]!, "name": "billing"])
    }

    /// New space's Multiplexer lists the installed server-owned multiplexers with a backend, herdr first; never the
    /// helper's native one (its sessions end with the connection). Detection keeps the list beside the choice.
    func testAvailableMultiplexersLeaveOutNativeAndTheUninstalled() async throws {
        var kinds = [TabsMultiplexer(mux: 0, name: "native", external: false),
                     TabsMultiplexer(mux: 1, name: "tmux", external: true, installed: true, version: "3.7"),
                     TabsMultiplexer(mux: 2, name: "herdr", external: true, installed: true)]
        let backends = [HelperBackend(mux: 0, key: "native", label: "native", isDefault: true),
                        HelperBackend(mux: 1, key: "tmux", label: "tmux", isDefault: true),
                        HelperBackend(mux: 2, key: "herdr", label: "herdr", isDefault: true)]
        XCTAssertEqual(MultiplexerChoice.available(multiplexers: kinds, backends: backends).map(\.name), ["herdr", "tmux"])
        kinds[2].installed = false
        XCTAssertEqual(MultiplexerChoice.available(multiplexers: kinds, backends: backends).map(\.name), ["tmux"])
        XCTAssertEqual(MultiplexerChoice.available(multiplexers: kinds, backends: Array(backends.prefix(1))), [])

        let helper = ScriptedHelper.scripted { request in
            switch request.method {
            case "multiplexers.list": Self.multiplexers([(0, "native", false), (1, "tmux", true), (2, "herdr", true)])
            case "backends.list": Self.backends([(0, "native", true), (1, "tmux", true), (2, "herdr", true)])
            default: nil
            }
        }
        defer { helper.close() }
        let workspace = TabsFixtures.workspace(client: helper.client)
        try await workspace.detect(override: "tmux")
        XCTAssertEqual(workspace.choice?.name, "tmux")
        XCTAssertEqual(workspace.multiplexers.map(\.name), ["herdr", "tmux"])
    }

    /// New space on another multiplexer than the one the host shows: its backend first (its server starts), then the
    /// host follows it (`MobileTabs.follow`, the saved preference), and the space opens once that one's topology shows it.
    func testCreateSpaceOnAnotherMultiplexerSwitchesTheHost() async throws {
        let herdrSketch = TabsFixtures.app(backend: 7, first: 10)
        let tmuxSketch = TopologySketch(backend: 8, first: 400, spaces: [
            .init(key: "tmux:new", name: "0", tabs: [.init(key: "tmux:new:@1", name: "zsh", panes: [.init(key: "%9", cwd: "/Users/alex")])]),
        ])
        let terminal = tmuxSketch.ids["%9"]!
        let helper = ScriptedHelper.scripted { request in
            switch request.method {
            case "backends.create": .value(UInt64(8))
            case "terminals.create": .value(terminal)
            case "entities.rename": .empty
            default: nil
            }
        }
        defer { helper.close() }
        let defaults = UserDefaults(suiteName: "tabs-commands-\(#function)")!
        defaults.removePersistentDomain(forName: "tabs-commands-\(#function)")
        let model = MobileTabs(activity: TabActivityStore(url: nil), defaults: defaults)
        let workspace = TabsFixtures.workspace(client: helper.client)
        let herdr = MultiplexerChoice(mux: 2, name: "herdr", route: .init(mux: 2, key: "herdr"))
        let tmux = MultiplexerChoice(mux: 1, name: "tmux", route: .init(mux: 1, key: "tmux"))
        workspace.multiplexers = [herdr, tmux]
        workspace.choice = herdr
        workspace.apply(herdrSketch.topology)
        model.insert(workspace)
        let followed = Followed()
        model.follow = { host, name in
            followed.hosts.append(host)
            followed.names.append(name)
            followed.sent = helper.methods
        }
        async let created = model.createSpace(on: workspace.id, name: "notes", directory: "~", multiplexer: tmux)
        try await TestSupport.eventually { helper.methods.contains("terminals.create") }
        XCTAssertEqual(followed.hosts, [workspace.id])
        XCTAssertEqual(followed.names, ["tmux"])
        XCTAssertEqual(followed.sent, ["backends.create"], "after its server runs")
        XCTAssertEqual(workspace.choice, tmux)
        // The host now follows tmux: herdr's spaces go and tmux's come.
        workspace.remove(backend: 7)
        workspace.apply(tmuxSketch.topology)
        let tab = try await created
        XCTAssertEqual(tab.ref.key, "tmux:new:@1")
        XCTAssertEqual(params(helper.requests[0]), ["mux": 1, "key": "tmux"])
        XCTAssertEqual(params(helper.requests[2]), ["node": tmuxSketch.ids["tmux:new"]!, "name": "notes"])
    }

    /// The shown multiplexer, or none named: no switch.
    func testCreateSpaceOnTheShownMultiplexerFollowsNothing() async throws {
        let sketch = TabsFixtures.app(backend: 7, first: 10)
        let fresh = TopologySketch(backend: 7, first: 300, spaces: sketch.spaces + [
            .init(key: "herdr:new", name: "space", tabs: [.init(key: "herdr:new:1", name: "zsh", panes: [.init(key: "p:fresh", cwd: "/Users/alex")])]),
        ])
        let helper = ScriptedHelper.scripted { request in
            switch request.method {
            case "backends.create": .value(UInt64(7))
            case "terminals.create": .value(fresh.ids["p:fresh"]!)
            default: nil
            }
        }
        defer { helper.close() }
        let workspace = TabsFixtures.workspace(client: helper.client)
        let herdr = MultiplexerChoice(mux: 2, name: "herdr", route: .init(mux: 2, key: "herdr"))
        workspace.choice = herdr
        workspace.apply(sketch.topology)
        let followed = Followed()
        async let created = workspace.createSpace(name: "space", directory: nil, on: herdr, follow: { followed.names.append($0) })
        try await TestSupport.eventually { helper.methods.contains("terminals.create") }
        workspace.apply(fresh.topology)
        _ = try await created
        XCTAssertEqual(followed.names, [])
        XCTAssertEqual(helper.methods, ["backends.create", "terminals.create"], "already named")
    }

    /// Quick create (and New space's Name left empty): no rename, so the server names the space after its folder and
    /// keeps following it, as the Mac's new spaces do.
    func testCreateSpaceWithoutANameLeavesTheNameToTheServer() async throws {
        let sketch = TabsFixtures.app(backend: 7, first: 10)
        let fresh = TopologySketch(backend: 7, first: 300, spaces: sketch.spaces + [
            .init(key: "herdr:new", name: "alex", tabs: [.init(key: "herdr:new:1", name: "zsh", panes: [.init(key: "p:fresh", cwd: "/Users/alex")])]),
        ])
        let helper = ScriptedHelper.scripted { request in
            switch request.method {
            case "backends.create": .value(UInt64(7))
            case "terminals.create": .value(fresh.ids["p:fresh"]!)
            default: nil
            }
        }
        defer { helper.close() }
        let workspace = TabsFixtures.workspace(client: helper.client)
        workspace.choice = MultiplexerChoice(mux: 2, name: "herdr", route: .init(mux: 2, key: "herdr"))
        workspace.apply(sketch.topology)
        async let created = workspace.createSpace(name: "", directory: "~")
        try await TestSupport.eventually { helper.methods.contains("terminals.create") }
        workspace.apply(fresh.topology)
        let tab = try await created
        XCTAssertEqual(workspace.space(of: tab)?.name, "alex")
        XCTAssertEqual(helper.methods, ["backends.create", "terminals.create"])
        XCTAssertEqual(params(helper.requests[1]), ["parent": 7, "cwd": "/Users/alex", "environment": []])
    }

    /// No herdr or tmux: no space, and nothing is sent.
    func testCreateSpaceWithoutMultiplexerFails() async {
        let helper = ScriptedHelper.scripted { _ in nil }
        defer { helper.close() }
        let workspace = TabsFixtures.workspace(client: helper.client)
        do {
            _ = try await workspace.createSpace(name: "x", directory: nil)
            XCTFail("created without a multiplexer")
        } catch { XCTAssertEqual(error as? TabsFailure, .noMultiplexer) }
        XCTAssertEqual(helper.methods, [])
    }

    /// New tab: a terminal under the space's node, with no folder (the multiplexer opens it in its focused pane's live
    /// directory, as the Mac's do); it opens once the topology shows it.
    func testNewTabCreatesUnderTheSpace() async throws {
        let sketch = TabsFixtures.app()
        let grown = TabsFixtures.app(extraTab: true)
        let helper = ScriptedHelper.scripted { request in request.method == "terminals.create" ? .value(grown.ids["p:new"]!) : nil }
        defer { helper.close() }
        let workspace = TabsFixtures.workspace(client: helper.client)
        workspace.apply(sketch.topology)
        let space = try XCTUnwrap(workspace.space("herdr:app"))
        async let created = workspace.newTab(in: space)
        try await TestSupport.eventually { !helper.methods.isEmpty }
        workspace.apply(grown.topology)
        let tab = try await created
        XCTAssertEqual(tab.ref.key, "herdr:app:4")
        XCTAssertEqual(params(helper.requests[0]), ["parent": sketch.ids["herdr:app"]!, "environment": []])
    }

    /// A creation the host never shows ends with an error instead of waiting forever.
    func testNewTabTimesOut() async throws {
        let helper = ScriptedHelper.scripted { request in request.method == "terminals.create" ? .value(UInt64(4242)) : nil }
        defer { helper.close() }
        let workspace = TabsFixtures.workspace(client: helper.client)
        workspace.apply(TabsFixtures.app().topology)
        do {
            _ = try await workspace.newTab(in: workspace.space("herdr:app")!, timeout: .milliseconds(200))
            XCTFail("no tab appeared")
        } catch { XCTAssertNotNil(error as? TabsFailure) }
    }

    func testRename() async throws {
        let helper = ScriptedHelper.scripted { request in request.method == "entities.rename" ? .empty : nil }
        defer { helper.close() }
        let sketch = TabsFixtures.app()
        let workspace = TabsFixtures.workspace(client: helper.client)
        workspace.apply(sketch.topology)
        try await workspace.rename(tab: workspace.tab("herdr:app:2")!, to: "server")
        try await workspace.rename(space: workspace.space("herdr:app")!, to: "web")
        XCTAssertEqual(helper.requests.map { params($0) },
                       [["node": sketch.ids["herdr:app:2"]!, "name": "server"], ["node": sketch.ids["herdr:app"]!, "name": "web"]])
    }

    /// backends.open: the subscription's topology updates reach the workspace.
    func testOpenFeedsTopology() async throws {
        let topology = try HelperBinary.value(encoding: TabsFixtures.app(backend: 3).topology)
        let helper = ScriptedHelper.scripted { request in
            request.method == "backends.open" ? .notify([("backend.opened", .unsigned(3)), ("topology", topology)]) : nil
        }
        defer { helper.close() }
        let workspace = TabsFixtures.workspace(client: helper.client)
        _ = try await workspace.open(.init(mux: 2, key: "herdr"))
        try await TestSupport.eventually { workspace.spaces.count == 2 }
        XCTAssertEqual(params(helper.requests[0]), ["mux": 2, "key": "herdr"])
        XCTAssertEqual(workspace.space("herdr:app")?.backend, 3)
    }

    func testCommandsNeedAConnection() async {
        let workspace = TabsFixtures.workspace()
        workspace.apply(TabsFixtures.app().topology)
        do {
            try await workspace.close(tab: workspace.tab("herdr:app:2")!, .close)
            XCTFail("closed while disconnected")
        } catch { XCTAssertEqual(error as? TabsFailure, .disconnected) }
        XCTAssertNotNil(workspace.tab("herdr:app:2"))
    }

    private func closing(_ replies: [ScriptedHelper.Reply]) -> (ScriptedHelper, MobileWorkspace, TopologySketch) {
        let queue = ReplyQueue(replies)
        let helper = ScriptedHelper.scripted { request in request.method == "close.request" ? queue.next() : nil }
        let sketch = TabsFixtures.app()
        let workspace = TabsFixtures.workspace(client: helper.client)
        workspace.apply(sketch.topology)
        return (helper, workspace, sketch)
    }

    /// Close Tab on an idle tab: the check (nothing changes), then prompt, which terminates it on the server.
    func testCloseIdleTabTerminates() async throws {
        let (helper, workspace, sketch) = closing([.closed(false, confirmation: false), .closed(true, confirmation: false)])
        defer { helper.close() }
        let node = sketch.ids["herdr:app:2"]!
        let outcome = try await workspace.close(tab: workspace.tab("herdr:app:2")!, .close)
        XCTAssertEqual(outcome, .terminated)
        XCTAssertEqual(helper.requests.map { params($0) },
                       [["node": node, "policy": "prompt", "check": true], ["node": node, "policy": "prompt", "check": false]])
    }

    /// Close Tab on a busy tab (a job, a stopped job, an agent): detach, the work keeps running.
    func testCloseBusyTabDetaches() async throws {
        let (helper, workspace, sketch) = closing([.closed(false, confirmation: true), .closed(true, confirmation: false)])
        defer { helper.close() }
        let node = sketch.ids["herdr:app:1"]!
        let outcome = try await workspace.close(tab: workspace.tab("herdr:app:1")!, .close)
        XCTAssertEqual(outcome, .detached)
        XCTAssertEqual(helper.requests.map { params($0) },
                       [["node": node, "policy": "prompt", "check": true], ["node": node, "policy": "detach", "check": false]])
    }

    /// A tab that turned busy between the check and the close is detached, never killed.
    func testTabTurningBusyAfterTheCheckDetaches() async throws {
        let (helper, workspace, _) = closing([.closed(false, confirmation: false), .closed(false, confirmation: true), .closed(true, confirmation: false)])
        defer { helper.close() }
        let outcome = try await workspace.close(tab: workspace.tab("herdr:app:2")!, .close)
        XCTAssertEqual(outcome, .detached)
        XCTAssertEqual(helper.requests.map { $0.params["policy"] as? String }, ["prompt", "prompt", "detach"])
    }

    /// An unavailable inspection (older multiplexer, lost server) keeps the work: detach.
    func testFailedCheckDetaches() async throws {
        let (helper, workspace, _) = closing([.failure(code: "unsupported", message: "Idle check unavailable"), .closed(true, confirmation: false)])
        defer { helper.close() }
        let outcome = try await workspace.close(tab: workspace.tab("herdr:app:3")!, .close)
        XCTAssertEqual(outcome, .detached)
        XCTAssertEqual(helper.requests.map { $0.params["policy"] as? String }, ["prompt", "detach"])
    }

    /// Close Space detaches, idle or not, as the Mac's does (docs/integrations.md): nothing is checked or ended.
    func testCloseSpaceAlwaysDetaches() async throws {
        let (helper, workspace, sketch) = closing([.closed(true, confirmation: false)])
        defer { helper.close() }
        let node = sketch.ids["herdr:docs"]!
        let outcome = try await workspace.close(space: workspace.space("herdr:docs")!, .close)
        XCTAssertEqual(outcome, .detached)
        XCTAssertEqual(helper.requests.map { params($0) }, [["node": node, "policy": "detach", "check": false]])
    }

    /// Detach and Terminate ask nothing of the helper first.
    func testDetachAndTerminateAreDirect() async throws {
        let (helper, workspace, sketch) = closing([.closed(true, confirmation: false), .closed(true, confirmation: false)])
        defer { helper.close() }
        let detached = try await workspace.close(tab: workspace.tab("herdr:app:1")!, .detach)
        let terminated = try await workspace.close(space: workspace.space("herdr:docs")!, .terminate)
        XCTAssertEqual(detached, .detached)
        XCTAssertEqual(terminated, .terminated)
        XCTAssertEqual(helper.requests.map { params($0) },
                       [["node": sketch.ids["herdr:app:1"]!, "policy": "detach", "check": false],
                        ["node": sketch.ids["herdr:docs"]!, "policy": "terminate", "check": false]])
    }

    /// A closing tab leaves the list at once; a refused close brings it back (the same object).
    func testClosingHidesAndFailureReveals() async throws {
        let gate = Gate()
        let helper = ScriptedHelper.scripted { request in
            guard request.method == "close.request" else { return nil }
            gate.wait()
            return .failure(code: "expired", message: "The close destination has ended")
        }
        defer { helper.close() }
        let workspace = TabsFixtures.workspace(client: helper.client)
        workspace.apply(TabsFixtures.app().topology)
        let dev = workspace.tab("herdr:app:2")!
        let task = Task { try await workspace.close(tab: dev, .detach) }
        try await TestSupport.eventually { workspace.tab("herdr:app:2") == nil }
        XCTAssertEqual(workspace.space("herdr:app")?.tabs.map(\.name), ["claude", "zsh"])
        gate.open()
        do {
            _ = try await task.value
            XCTFail("the close was refused")
        } catch { XCTAssertEqual((error as? HelperFailure)?.code, "expired") }
        XCTAssertTrue(workspace.tab("herdr:app:2") === dev)
    }

    /// The Mac's words for Terminate, verbatim.
    func testTerminateCopyIsTheMacs() {
        XCTAssertEqual(TabsTerminateCopy.title(tab: "dev"), "Terminate tab “dev”?")
        XCTAssertEqual(TabsTerminateCopy.title(space: "app"), "Terminate space “app”?")
        XCTAssertEqual(TabsTerminateCopy.message,
                       "This ends its server windows or panes and the processes running inside them. To keep work running, use Detach.")
    }
}

/// Replies in order, one per request.
private final class ReplyQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [ScriptedHelper.Reply]
    init(_ replies: [ScriptedHelper.Reply]) { self.replies = replies }
    func next() -> ScriptedHelper.Reply? { lock.withLock { replies.isEmpty ? nil : replies.removeFirst() } }
}

/// Holds the scripted peer's reply until the test opens it.
private final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() { semaphore.wait() }
    func open() { semaphore.signal() }
}

/// tmux with several sessions attached refuses a new space under its backend; the phone then makes a window in one
/// of its spaces and places it into a new space. The helper names a placed space after its folder (the label only
/// while the folder is unknown), so a typed name is set once the window shows in its own space.
@MainActor
final class TabsCreateFallbackTests: XCTestCase {
    private func scripted(_ terminal: UInt64) -> ScriptedHelper {
        ScriptedHelper.scripted { request in
            switch request.method {
            case "backends.create": .value(UInt64(4))
            case "terminals.create" where request.params["parent"] as? UInt64 == 4:
                .failure(code: "invalid", message: "Tmux creation needs an unambiguous session")
            case "terminals.create": .value(terminal)
            case "memberships.place", "entities.rename": .empty
            default: nil
            }
        }
    }

    /// The topology once the helper placed the new window (the anchor's last tab) into a space of its own, named after
    /// its folder.
    private func placed(_ grown: TopologySketch, name: String) -> TopologySketch {
        var spaces = grown.spaces
        let moved = spaces[0].tabs.removeLast()
        spaces.append(.init(key: "$1:group:new", name: name, tabs: [moved]))
        return TopologySketch(backend: grown.backend, first: grown.first, spaces: spaces)
    }

    func testAmbiguousTmuxPlacesANewWindowIntoANewSpace() async throws {
        let sketch = TabsFixtures.app(backend: 4)
        let grown = TabsFixtures.app(backend: 4, extraTab: true)
        let helper = scripted(grown.ids["p:new"]!)
        defer { helper.close() }
        let workspace = TabsFixtures.workspace(client: helper.client)
        workspace.apply(sketch.topology)
        workspace.choice = MultiplexerChoice(mux: 0, name: "tmux", route: .init(mux: 0, key: "tmux"))
        async let created = workspace.createSpace(name: "billing", directory: "/srv/billing")
        try await TestSupport.eventually { helper.methods.count == 3 }
        workspace.apply(grown.topology)
        try await TestSupport.eventually { helper.methods.contains("memberships.place") }
        let moved = placed(grown, name: "billing")
        workspace.apply(moved.topology)
        let tab = try await created
        XCTAssertEqual(tab.ref.key, "herdr:app:4")
        XCTAssertEqual(tab.space.key, "$1:group:new")
        XCTAssertEqual(helper.methods, ["backends.create", "terminals.create", "terminals.create", "memberships.place", "entities.rename"])
        XCTAssertEqual(helper.requests[2].params as NSDictionary, ["parent": sketch.ids["herdr:app"]!, "cwd": "/srv/billing", "environment": []])
        XCTAssertEqual(helper.requests[3].params as NSDictionary,
                       ["node": grown.ids["herdr:app:4"]!, "place": ["kind": "workspace", "label": "billing"]])
        XCTAssertEqual(helper.requests[4].params as NSDictionary, ["node": moved.ids["$1:group:new"]!, "name": "billing"],
                       "renamed though it reads the same: the typed name stops following the folder")
    }

    /// Without a name the placed space keeps the helper's: its folder's, which the label names too (needed by the
    /// helper); nothing is renamed.
    func testAmbiguousTmuxWithoutANameLabelsItWithTheFolder() async throws {
        let sketch = TabsFixtures.app(backend: 4)
        let grown = TabsFixtures.app(backend: 4, extraTab: true)
        let helper = scripted(grown.ids["p:new"]!)
        defer { helper.close() }
        let workspace = TabsFixtures.workspace(client: helper.client)
        workspace.apply(sketch.topology)
        workspace.choice = MultiplexerChoice(mux: 0, name: "tmux", route: .init(mux: 0, key: "tmux"))
        async let created = workspace.createSpace(name: " ", directory: "~/src/billing")
        try await TestSupport.eventually { helper.methods.count == 3 }
        workspace.apply(grown.topology)
        _ = try await created
        XCTAssertEqual(helper.methods, ["backends.create", "terminals.create", "terminals.create", "memberships.place"])
        XCTAssertEqual(helper.requests[3].params as NSDictionary,
                       ["node": grown.ids["herdr:app:4"]!, "place": ["kind": "workspace", "label": "billing"]])
    }
}

/// What `follow` was called with.
@MainActor
private final class Followed {
    var hosts: [UUID] = []
    var names: [String] = []
    var sent: [String] = []
}
