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
