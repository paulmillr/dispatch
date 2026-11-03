import AppKit
import SwiftUI
import XCTest
@_spi(Test) import TermApple
@testable import DispatchApp

/// Through the app: a terminal whose tab is no longer shown (its view leaves the window) gives back its GPU memory
/// after the retention and draws again when its tab is selected; a shown tab whose window is merely covered keeps it
/// until memory pressure.
@MainActor
final class TerminalTabReleaseTests: XCTestCase {
    func testBackgroundTabReleasesAfterTheRetentionAndDrawsWhenSelected() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        let retention = HiddenResources.retention
        defer { HiddenResources.retention = retention }
        HiddenResources.retention = 0.3
        let controller = AppDelegate(), runtime = TerminalRuntime.shared
        let previousWorkspace = runtime.workspace
        runtime.workspace = controller.workspace
        runtime.start(preferences: Preferences())
        controller.workspace.newLocalSpace()
        let first = try XCTUnwrap(controller.workspace.activeSurfaceID)
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: controller.workspace, settings: controller.settings, controller: controller))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil; window.close()
            runtime.stop(); runtime.workspace = previousWorkspace
        }
        func session(_ id: UUID) -> Session? { (runtime.views[id]?.surface as? SwiftBackend)?.session }
        try await TestSupport.eventually(timeout: .seconds(10)) { (session(first)?.drawnFrames ?? 0) > 0 && session(first)!.gpuBytes > 0 }
        let terminal = try XCTUnwrap(runtime.views[first]), drawn = try XCTUnwrap(session(first))

        // Another tab: the first one's view leaves the window and it releases after the retention.
        controller.workspace.newTab()
        let second = try XCTUnwrap(controller.workspace.activeSurfaceID)
        XCTAssertNotEqual(second, first)
        try await TestSupport.eventually(timeout: .seconds(10)) { terminal.window == nil && drawn.gpuBytes == 0 }
        XCTAssertEqual(drawn.hiddenResources.hiddenPolicy, .afterRetention)
        XCTAssertTrue(drawn.hiddenResources.released)

        // Selected again: a frame is in its layer as it shows.
        controller.workspace.selectSurface(first)
        try await TestSupport.eventually(timeout: .seconds(10)) { terminal.window === window && drawn.layer.contents != nil && drawn.gpuBytes > 0 }
        XCTAssertNil(drawn.hiddenResources.hiddenPolicy)

        // Covered: the shown tab's view stays in its window and only memory pressure releases it.
        window.orderOut(nil)
        try await TestSupport.eventually(timeout: .seconds(10)) { drawn.hiddenResources.hiddenPolicy == .onMemoryPressure }
        XCTAssertFalse(drawn.hiddenResources.scheduled)
        window.makeKeyAndOrderFront(nil)
        try await TestSupport.eventually(timeout: .seconds(10)) { drawn.hiddenResources.hiddenPolicy == nil }
    }
}
