import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class WorkspaceFooterTests: XCTestCase {
    func testFooterAlignmentAcrossHostsWrappingAndSpaceChanges() async throws {
        try DesktopTestSupport.requireUnlocked()
        let workspace = Workspace()
        workspace.newLocalSpace()
        let space = try XCTUnwrap(workspace.selectedSpace)
        let surface = try XCTUnwrap(workspace.activeSurfaceID)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        func tree(hostHeight: CGFloat = 36, showChat: Bool = true) -> some View {
            NativeSplit(first: AnyView(VStack(spacing: 0) {
                Spacer()
                Color.gray.frame(height: hostHeight)
                    .modifier(WorkspaceFooter(workspace: workspace))
                    .background(FooterProbe(name: "sidebar"))
            }), second: AnyView(VStack(spacing: 0) {
                Spacer()
                if showChat {
                    Text("codex · model and reasoning effort · session statistics · reply shortcuts")
                        .font(.system(size: 16)).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8).padding(.bottom, 14)
                        .modifier(WorkspaceFooter(workspace: workspace, surface: surface))
                        .background(FooterProbe(name: "chat"))
                }
            }), axis: .columns, initialFraction: 0.25)
        }
        let host = NSHostingView(rootView: tree())
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        func frame(_ name: String) -> CGRect? {
            PresentationTestSupport.views(of: FooterProbeView.self, in: host)
                .first { $0.identifier?.rawValue == name }.map { $0.convert($0.bounds, to: nil) }
        }
        func aligned() async throws -> CGFloat {
            try await TestSupport.eventually(diagnostic: "Footer borders should share their window position") {
                guard let sidebar = frame("sidebar"), let chat = frame("chat") else { return false }
                return sidebar.height >= 36 && abs(sidebar.maxY - chat.maxY) < 0.5
                    && abs(sidebar.minY - chat.minY) < 0.5
            }
            return try XCTUnwrap(frame("sidebar")).height
        }
        let wide = try await aligned()
        window.setContentSize(NSSize(width: 550, height: 500))
        try await TestSupport.eventually { (frame("chat")?.height ?? 0) > wide }
        let narrow = try await aligned()
        XCTAssertGreaterThan(narrow, wide)
        window.setContentSize(NSSize(width: 1000, height: 500))
        try await TestSupport.eventually { abs((frame("sidebar")?.height ?? 0) - wide) < 0.5 }
        host.rootView = tree(hostHeight: 100)
        try await TestSupport.eventually { (frame("chat")?.height ?? 0) >= 100 }
        let tall = try await aligned()
        XCTAssertEqual(tall, 100, accuracy: 0.5)
        host.rootView = tree()
        try await TestSupport.eventually { abs((frame("sidebar")?.height ?? 0) - wide) < 0.5 }
        // A retained chat in another space must not enlarge the current footer.
        window.setContentSize(NSSize(width: 550, height: 500))
        try await TestSupport.eventually { (frame("sidebar")?.height ?? 0) > wide }
        workspace.newLocalSpace()
        try await TestSupport.eventually { abs((frame("sidebar")?.height ?? 0) - 36) < 0.5 }
        workspace.selectSpace(space)
        _ = try await aligned()
        host.rootView = tree(showChat: false)
        try await TestSupport.eventually {
            workspace.footerLayout.measurements.values.allSatisfy { $0.surface == nil }
                && abs((frame("sidebar")?.height ?? 0) - 36) < 0.5
        }
    }
}

private struct FooterProbe: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> FooterProbeView {
        let view = FooterProbeView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        return view
    }
    func updateNSView(_ view: FooterProbeView, context: Context) {}
}

private final class FooterProbeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
