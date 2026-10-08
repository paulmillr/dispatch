import AppKit
import XCTest
@testable import DispatchApp

/// Temporary reproduction (not for commit): a new tab in a 2x2 tmux window attached over a managed SSH
/// login stayed "Connecting…" while one split was in tmux copy-mode.
@MainActor
final class ConnectingReproTests: XCTestCase {
    func testNewTabInSplitWhilePaneIsInCopyMode() async throws { try await newTab(copyMode: true) }

    func testNewTabInSplitControlWithoutCopyMode() async throws { try await newTab(copyMode: false) }

    /// Wheel gestures through the app's own scroll route (the helper that entered copy-mode itself).
    func testNewTabInSplitAfterWheelScrolls() async throws { try await newTab(copyMode: false, wheel: true) }

    private func newTab(copyMode: Bool, wheel: Bool = false) async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        // A 2x2 grid in one window, with some history in every pane.
        for _ in 0..<3 { _ = try app.server(["split-window", "-t", "edge:0", "/bin/sh"]) }
        _ = try app.server(["select-layout", "-t", "edge:0", "tiled"])
        for pane in try app.server(["list-panes", "-t", "edge:0", "-F", "#{pane_id}"]).split(separator: "\n") {
            _ = try app.server(["send-keys", "-t", String(pane), "seq 1 200", "Enter"])
        }
        let server = try await SSHTestServer(); defer { server.stop() }
        let source = try XCTUnwrap(app.workspace.activeTab?.id)
        _ = try await app.login(server, surface: source)
        try await app.attach(); try await app.ready()
        let space = try XCTUnwrap(app.workspace.current)
        XCTAssertEqual(space.containers.count, 1, describe(app))
        let window = try XCTUnwrap(space.containers.first)
        XCTAssertEqual(window.terminals.count, 4, describe(app))
        // The split to use: not the one focused at attach.
        let tab = try XCTUnwrap(window.terminals.first { $0.id != app.workspace.activeTab?.id })
        let pane = try XCTUnwrap(app.target(tab))
        app.workspace.selectTab(tab.id); try await app.ready()
        XCTAssertEqual(app.workspace.activeTab?.id, tab.id)
        if copyMode {
            // The two commands the earlier helper sent for a wheel scroll.
            _ = try app.server(["copy-mode", "-t", pane])
            _ = try app.server(["send-keys", "-X", "-N", "3", "-t", pane, "scroll-up"])
            XCTAssertEqual(try app.server(["display-message", "-p", "-t", pane, "#{pane_in_mode}"]), "1\n")
        }
        if wheel {
            let helper = try XCTUnwrap(app.workspace.helper(containing: tab.id))
            XCTAssertTrue(helper.scrolls(tab.id), "The multiplexer owns this pane's wheel")
            // A trackpad flick up and back down: many small gestures, none awaited.
            for lines in Array(repeating: Int64(3), count: 15) + Array(repeating: Int64(-3), count: 15) {
                helper.scroll(tab.id, lines: lines, page: false, at: (column: 10, row: 5), modifiers: 0) {}
            }
            try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "Repro: wheel never settled: \(describe(app))") {
                helper.operations == 0
            }
            print("Repro: after wheel: multiplexerScrolls=\(helper.scrolls(tab.id)) in_mode=\(try app.server(["display-message", "-p", "-t", pane, "#{pane_in_mode} #{scroll_position}"])) \(describe(app))")
        }
        print("Repro: new tab in \(pane), copyMode=\(copyMode); before: \(describe(app))")
        app.workspace.newTab()
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "Repro: new tab never settled: \(describe(app))") {
            guard let now = app.workspace.spaces.first(where: { $0.id == space.id }) else { return false }
            return now.containers.count == 2 && !now.tabs.contains(where: \.isConnecting)
        }
        print("Repro: settled: \(describe(app))")
    }

    private func describe(_ app: TmuxWalkthrough) -> String {
        let spaces = app.workspace.spaces.map { space in
            "\(space.name)[structured=\(space.structured) windows=\(space.containers.map { "\($0.terminals.count)\($0.terminals.contains(where: \.isConnecting) ? "c" : "")" }) connecting=\(space.tabs.filter(\.isConnecting).count)\(space.id == app.workspace.selectedSpace ? " selected" : "")]"
        }.joined(separator: " ")
        let helpers = app.runtime.helpers.map { "\($0.key): operations=\($0.value.operations) error=\($0.value.error ?? "none")" }.joined(separator: "; ")
        let windows = (try? app.server(["list-windows", "-a", "-F", "#{window_id}:#{window_panes}:#{window_name}"])) ?? "?"
        let panes = (try? app.server(["list-panes", "-a", "-F", "#{pane_id}:in_mode=#{pane_in_mode}"])) ?? "?"
        let clients = (try? app.server(["list-clients", "-F", "#{client_pid}:#{client_flags}"])) ?? "?"
        return "spaces=\(spaces) helpers=[\(helpers)] tmux windows=\(windows.split(separator: "\n")) panes=\(panes.split(separator: "\n")) clients=\(clients.split(separator: "\n"))"
    }
}
