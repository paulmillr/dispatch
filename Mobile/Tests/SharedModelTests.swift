import Foundation
import XCTest
@testable import DispatchMobile

/// The shared Foundation sources behave on iOS as on the Mac.
final class SharedModelTests: XCTestCase {
    /// Needs you, then working, then an unseen result (docs/ios.md, attention).
    func testPaneUrgencyPrecedence() {
        XCTAssertEqual(PaneUrgency(waiting: true, working: true, unread: true), .waiting)
        XCTAssertEqual(PaneUrgency(waiting: false, working: true, unread: true), .running)
        XCTAssertEqual(PaneUrgency(waiting: false, working: false, unread: true), .unread)
        XCTAssertEqual(PaneUrgency(waiting: false, working: false, unread: false), .idle)
    }

    /// A machine keeps its tint across logins and app runs: the seed comes from the machine part of its identity.
    func testHostTintIsStablePerMachine() {
        let first = HostTint(hostID: "machine-identity:501"), second = HostTint(hostID: "machine-identity:502")
        XCTAssertEqual(first.seed, second.seed)
        XCTAssertEqual(first.machine, second.machine)
        XCTAssertNotEqual(HostTint(hostID: "other-machine").machine, first.machine)
        XCTAssertEqual(first.machine.count, 32)
    }

    func testWorkspaceValueTypesRoundTrip() throws {
        var tab = TerminalTab(directory: "/srv/app")
        tab.customTitle = "deploy"
        tab.terminal = 7
        let pane = Pane(tabs: [tab, TerminalTab(directory: "/")])
        let decoded = try JSONDecoder().decode(Pane.self, from: JSONEncoder().encode(pane))
        XCTAssertEqual(decoded, pane)
        XCTAssertEqual(decoded.tabs.first?.label, "deploy")
        XCTAssertEqual(decoded.tabs.last?.title, "/")
    }

    func testEditToolBecomesAUnifiedDiff() {
        let input = #"{"file_path":"/work/a.swift","old_string":"let a = 1","new_string":"let a = 2"}"#
        let item = ChatItem(id: "tool", kind: .tool, text: input, title: "Edit")
        let documents = ToolDocument.parse(item)
        XCTAssertEqual(documents.map(\.path), ["/work/a.swift"])
        XCTAssertEqual(documents.first?.diff.components(separatedBy: "\n").filter { $0.hasPrefix("-") || $0.hasPrefix("+") },
                       ["-let a = 1", "+let a = 2"])
    }
}
