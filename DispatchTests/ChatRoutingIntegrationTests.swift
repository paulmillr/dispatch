import AppKit
import SwiftUI
import XCTest
import Term
@testable import DispatchApp

@MainActor
final class ChatRoutingIntegrationTests: XCTestCase {
    func testTwoRealCodexProcessesInSameDirectoryAndResumeRouting() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        let binary = try CodexTestSupport.requireBinary()
        let runtime = TerminalRuntime.shared
        let controller = AppDelegate()
        runtime.chat = ChatCoordinator(enabled: true)
        let workspace = controller.workspace
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-codex-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { CodexTestSupport.removeFixture(directory) }
        runtime.workspace = workspace; runtime.start(preferences: Preferences())
        workspace.defaultDirectory = directory.path
        workspace.onCloseTabs = { runtime.close($0) }
        workspace.newSpace()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentView = nil; runtime.stop() }
        let firstID = workspace.activeTab!.id
        try await eventually { runtime.views[firstID]?.surface != nil }
        let first = runtime.views[firstID]!
        TerminalTestSupport.send(CodexTestSupport.command("routing", state: directory.appendingPathComponent("one"), binary: binary), to: first)
        try await eventually { self.process(first) != nil }
        let firstProcess = try XCTUnwrap(process(first))
        workspace.newTab()
        let secondID = workspace.activeTab!.id
        try await eventually { runtime.views[secondID]?.surface != nil }
        let second = runtime.views[secondID]!
        TerminalTestSupport.send(CodexTestSupport.command("routing", state: directory.appendingPathComponent("two"), binary: binary), to: second)
        try await eventually { self.process(second) != nil }
        let secondProcess = try XCTUnwrap(process(second))
        XCTAssertNotEqual(firstProcess, secondProcess)
        // Same directory: each terminal's chat is bound to its own process (hook routing and its
        // authorization are the codex harness's).
        let a = runtime.chat.session(for: firstID), b = runtime.chat.session(for: secondID)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "a=\(a.status ?? "nil") b=\(b.status ?? "nil")") {
            a.active && b.active && a.binding?.process != nil && b.binding?.process != nil
        }
        XCTAssertEqual(a.binding?.process?.pid, firstProcess.pid)
        XCTAssertEqual(b.binding?.process?.pid, secondProcess.pid)
        XCTAssertNotEqual(a.helper?.route.terminal, b.helper?.route.terminal)
        // Moving the tab around keeps its terminal and its agent.
        let savedSurface = first.surface
        workspace.newTab()
        workspace.split(.columns)
        workspace.moveTab(firstID, to: workspace.current!.focusedPane)
        workspace.newSpace()
        XCTAssertTrue(first.surface === savedSurface)
        XCTAssertTrue(firstProcess.alive)
        XCTAssertTrue(secondProcess.alive)
        // After its process exits, the chat keeps read-only history and input never falls through to the shell.
        let conversation = a.sessionID
        first.drainCodexForTest()
        try await eventually { !firstProcess.alive && !a.active }
        if let conversation {
            let refused = try await XCTUnwrap(a.helper).refuses("must not reach shell", conversation: conversation)
            XCTAssertTrue(refused)
        }
        XCTAssertNotNil(first.surface)
        XCTAssertTrue(secondProcess.alive && b.active, "The other terminal's agent is unaffected")
    }
    private func process(_ view: TerminalView) -> CodexProcess? {
        CodexTestSupport.process(view)
    }
    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        try await TestSupport.eventually(file: file, line: line, diagnostic: "Condition did not become true", condition)
    }
}

private extension TerminalView {
    func drainCodexForTest() {
        guard surface != nil else { return }
        if let process = CodexTestSupport.process(self) { kill(process.pid, SIGTERM) }
    }
}
