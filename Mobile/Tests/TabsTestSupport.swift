import Foundation
import SwiftUI
import XCTest
@testable import DispatchMobile

@MainActor
enum TabsFixtures {
    static let host = TabsHost(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!, name: "mba2", tint: .blue,
                               system: .mac, home: "/Users/alex")

    /// The real tmux topologies the helper published in `live-tmux` (DispatchTests/HelperClient/Fixtures): two
    /// sessions with one window of two panes each, split in columns and in rows.
    static func liveTmux() throws -> [HelperTopology] {
        try HelperClientTests.fixture("live-tmux").frames["write"]!.compactMap { frame in
            guard frame.kind == HelperWire.Kind.notify.rawValue,
                  case .object(let object) = try HelperBinary.decode(frame.body),
                  object["method"] == .string("topology"), let params = object["params"] else { return nil }
            return try HelperBinary.decode(HelperTopology.self, from: params)
        }
    }

    /// The app space of the mockup: claude (an agent), dev, and zsh with two panes.
    static func app(backend: UInt64 = 1, first: UInt64 = 10, devName: String = "dev", extraTab: Bool = false,
                    focus: Int = 1, detachDev: Bool = false) -> TopologySketch {
        var tabs: [TopologySketch.Tab] = [
            .init(key: "herdr:app:1", name: "claude", panes: [.init(key: "p:claude", cwd: "/Users/alex/src/app", agent: "s1")]),
            .init(key: "herdr:app:2", name: devName, renamed: true, panes: [.init(key: "p:dev", cwd: "/Users/alex/src/app")],
                  detached: detachDev),
            .init(key: "herdr:app:3", name: "zsh", panes: [.init(key: "p:zsh1", cwd: "/Users/alex/src/app"),
                                                         .init(key: "p:zsh2", cwd: "/Users/alex/src/app/web")], focus: focus),
        ]
        if extraTab { tabs.append(.init(key: "herdr:app:4", name: "zsh", panes: [.init(key: "p:new", cwd: "/Users/alex/src/app")])) }
        return TopologySketch(backend: backend, first: first, spaces: [
            .init(key: "herdr:app", name: "app", tabs: tabs),
            .init(key: "herdr:docs", name: "docs", tabs: [
                .init(key: "herdr:docs:1", name: "zsh", panes: [.init(key: "p:docs", cwd: "/Users/alex/src/docs")]),
            ]),
        ])
    }

    static func workspace(client: HelperClient? = nil, now: @escaping () -> Date = Date.init,
                          store: TabActivityStore = TabActivityStore(url: nil)) -> MobileWorkspace {
        MobileWorkspace(host: host, client: client, activity: store, now: now)
    }
}

/// A clock tests move by hand.
@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// A plain SSH host's shells for the Tabs tests: `ShellSessions` over a `ScriptedShellOpener` with private presences,
/// and the host's input as the composition makes it.
@MainActor
enum ShellFixtures {
    static let host = TabsHost(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!, name: "pi", tint: .green,
                               system: nil, home: nil, plain: true)

    /// `opener` nil: the host is not plain-connected (New tab opens nothing). `now`: the tabs' creation and output times.
    static func sessions(opener: ScriptedShellOpener? = ScriptedShellOpener(), now: (@Sendable () -> Date)? = nil,
                         presences: TerminalPresences = TerminalPresences()) -> ShellSessions {
        let shells = ShellSessions(host: host.id)
        shells.presences = presences
        shells.opener = { opener }
        if let now { shells.now = now }
        return shells
    }

    /// The host as Spaces takes it: plain (`mode`), connected or not, with the shells' tabs.
    static func input(_ shells: ShellSessions?, mode: HostSession.Mode? = .plain(reason: nil), state: SpacesHostState = .connected,
                      topology: HelperTopology? = nil) -> TabsHostInput {
        var host = host
        host.state = state
        host.plain = state == .connected && mode != nil && mode != .helper
        return TabsHostInput(host: host, client: nil, topology: topology, mode: mode, shells: shells?.tabs ?? [])
    }

    static func model(_ suite: String = #function) -> MobileTabs {
        let defaults = UserDefaults(suiteName: "tabs-shells-\(suite)")!
        defaults.removePersistentDomain(forName: "tabs-shells-\(suite)")
        return MobileTabs(activity: TabActivityStore(url: nil), defaults: defaults, deviceState: SpacesDeviceState(url: nil, migrating: defaults))
    }

    /// The tab of a shell, once its presence attached: the scripted shell its feed opened.
    static func shell(_ opener: ScriptedShellOpener, _ index: Int) async throws -> ScriptedShell {
        try await TestSupport.eventually { opener.shells.count > index }
        return opener.shells[index]
    }
}
