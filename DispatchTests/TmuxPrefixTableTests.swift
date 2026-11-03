import AppKit
import XCTest
@testable import DispatchApp

/// The prefix table a tmux space answers is its server's own, for the space's session (the 2026-10-31 audit:
/// test/tmux-config-audit.py runs the same cases against the helper and the app's handler with stubs).
@MainActor
final class TmuxPrefixTableTests: XCTestCase {
    private func key(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }

    /// T1, T4: the session's prefix, prefix2 and repeat time and the server's bindings reach the key handler; ⌃B is
    /// the terminal's again; a binding Dispatch cannot run is refused; a `set prefix` made while attached applies
    /// after the next sequence. T2: a window index selects that server window, not a UI position.
    func testTmuxSpaceAnswersItsServersPrefixTable() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        for command in [["set-option", "-t", "edge", "prefix", "C-a"], ["set-option", "-g", "prefix2", "F12"],
                        ["set-option", "-t", "edge", "repeat-time", "1234"], ["bind-key", "c", "split-window", "-h"],
                        ["bind-key", "h", "new-window", "-n", "logs", "tail -f /dev/null"],
                        ["move-window", "-s", "edge:0", "-t", "edge:5"], ["rename-window", "-t", "edge:5", "five"],
                        ["new-window", "-d", "-t", "edge:6", "-n", "six", "/bin/sh"]] {
            _ = try app.server(command)
        }
        try await app.attach()
        try await app.wait { app.workspace.current?.containers.count == 2 }
        let surface = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { app.controller.prefixTable(for: surface)?.prefix == PrefixKey("a", control: true) }
        let table = try XCTUnwrap(app.controller.prefixTable(for: surface))
        XCTAssertEqual(table.prefix2, PrefixKey("F12"))
        XCTAssertEqual(table.repeatTime, 1.234, accuracy: 0.0001)
        XCTAssertEqual(table.bindings[PrefixKey("c")]?.action, .splitRight)
        XCTAssertEqual(table.bindings[PrefixKey("6")]?.action, .selectWindow(6))
        XCTAssertEqual(table.rejected[PrefixKey("h")], #"new-window -n logs "tail -f /dev/null""#)

        let keys = app.workspace.prefixKeys
        XCTAssertFalse(keys.handle(key(11, "b", .control), surface: surface), "⌃B is not this server's prefix")
        XCTAssertTrue(keys.handle(key(111, "\u{F70F}"), surface: surface), "prefix2 arms")
        keys.cancel()
        _ = try app.server(["set-option", "-t", "edge", "prefix", "C-q"])
        XCTAssertTrue(keys.handle(key(0, "a", .control), surface: surface))
        XCTAssertEqual(keys.armed, surface)
        XCTAssertTrue(keys.handle(key(4, "h"), surface: surface), "A refused binding still ends the sequence")
        XCTAssertNil(keys.armed)
        try await app.wait { app.controller.prefixTable(for: surface)?.prefix == PrefixKey("q", control: true) }

        let five = try XCTUnwrap(app.workspace.current?.containers.first { $0.name == "five" })
        let six = try XCTUnwrap(app.workspace.current?.containers.first { $0.name == "six" })
        XCTAssertEqual(app.workspace.current?.selectedContainer, five.id)
        XCTAssertTrue(keys.handle(key(12, "q", .control), surface: surface))
        XCTAssertTrue(keys.handle(key(22, "6"), surface: surface))
        try await app.wait { app.workspace.current?.selectedContainer == six.id }
    }
}
