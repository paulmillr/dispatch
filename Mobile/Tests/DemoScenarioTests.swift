import XCTest
@testable import DispatchMobile

/// The simulator demo's scenario (`./run.sh --ios --demo`) and its fixtures (`test/mobile-demo-fixtures.py`): every
/// agent tab has a conversation the real helper recorded, every shell a screen, every live tab its lines.
@MainActor
final class DemoScenarioTests: XCTestCase {
    func testEveryTabHasItsFixture() {
        let hosts = DemoScenario.hosts()
        XCTAssertEqual(hosts.map(\.record.name), ["mba2", "studio", "ai"])
        for host in hosts {
            XCTAssertEqual(host.terminals.count, host.content.count, "\(host.record.name): every pane is in the topology")
            for (key, content) in host.content {
                switch content {
                case .agent(let chat, _, _, _):
                    XCTAssertGreaterThan(DemoScenario.records(chat).count, 5, "\(key): \(chat)")
                case .shell(let name, let live):
                    let screen = String(decoding: DemoScenario.terminal(name), as: UTF8.self)
                    XCTAssertFalse(screen.contains("is missing"), "\(key): \(name)")
                    XCTAssertTrue(screen.contains("\r\n"), "\(key): CRLF, as a pane replays")
                    if live { XCTAssertGreaterThan(DemoScenario.liveLines(name).count, 10, "\(key): live lines") }
                }
            }
        }
        for agent in ["claude", "codex"] {
            XCTAssertFalse(String(decoding: DemoScenario.terminal("agent-\(agent)"), as: UTF8.self).contains("is missing"))
        }
    }
}
