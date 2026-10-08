import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class SplitSizingTests: XCTestCase {
    func testTypographyUpdatesAcrossNativeSplitsAndMotionHosts() async throws {
        let space = UUID(), pane = UUID()
        func tree(size: CGFloat) -> some View {
            NativeSplit(first: AnyView(TypographyProbe()), second: AnyView(
                MotionContent(content: AnyView(NativeSplit(first: AnyView(TypographyProbe()),
                    second: AnyView(TypographyProbe()), axis: .rows)),
                    identity: "same", spaceID: space, layout: .pane(pane))), axis: .columns)
                .environment(\.appTypography, AppTypography(contentSize: size))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: tree(size: 12.5))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentView = nil }
        for size: CGFloat in [12.5, 22, 8] {
            host.rootView = tree(size: size)
            try await TestSupport.eventually {
                let labels = PresentationTestSupport.views(of: NSTextField.self, in: host)
                return labels.count == 3 && labels.allSatisfy { $0.font?.pointSize == size }
            }
        }
    }

    func testMinimumSizeAccountsForTheWholeLayout() {
        XCTAssertEqual(nested(.columns, count: 3).minimumSize, CGSize(width: 542, height: 120))
        XCTAssertEqual(nested(.columns, count: 4).minimumSize, CGSize(width: 723, height: 120))
        XCTAssertEqual(nested(.rows, count: 4).minimumSize, CGSize(width: 180, height: 483))
        let grid = PaneLayout.split(UUID(), .rows, nested(.columns, count: 2), nested(.columns, count: 2))
        XCTAssertEqual(grid.minimumSize, CGSize(width: 361, height: 241))
    }

    func testNestedNativeSplitsPreservePaneMinimaOnResizeAndDividerDrags() {
        let grid = PaneLayout.split(UUID(), .rows, nested(.columns, count: 2), nested(.columns, count: 2))
        for layout in [nested(.columns, count: 3), nested(.columns, count: 4), nested(.rows, count: 4), grid] {
            let view = makeView(layout)
            view.frame.size = CGSize(width: layout.minimumSize.width + 300, height: layout.minimumSize.height + 150)
            resize(view)
            assertPaneMinima(view)
            view.frame.size = layout.minimumSize
            resize(view)
            assertPaneMinima(view)
            for split in splits(in: view) {
                let length = (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
                for proposed in [CGFloat(0), length] {
                    let position = split.splitView(split, constrainSplitPosition: proposed, ofSubviewAt: 0)
                    split.setPosition(position, ofDividerAt: 0)
                    resize(view)
                    assertPaneMinima(view)
                }
            }
        }
    }

    func testSidebarLeavesEnoughRoomForFourColumnsAndRestoresAfterHiding() {
        let layout = nested(.columns, count: 4)
        let sidebar = TerminalSplitView()
        sidebar.sidebar = true
        sidebar.isVertical = true
        sidebar.dividerStyle = .thin
        sidebar.delegate = sidebar
        sidebar.secondMinimumSize = layout.minimumSize
        sidebar.addArrangedSubview(NSView())
        let content = makeView(layout)
        sidebar.addArrangedSubview(content)
        sidebar.frame.size = CGSize(width: 1200, height: 400)
        resize(sidebar)
        sidebar.frame.size.width = 200 + sidebar.dividerThickness + layout.minimumSize.width
        resize(sidebar)
        XCTAssertEqual(sidebar.arrangedSubviews[0].frame.width, 200, accuracy: 0.01)
        assertPaneMinima(content)
        sidebar.firstMinimumSize.width = 352
        sidebar.frame.size.width = 352 + sidebar.dividerThickness + layout.minimumSize.width
        resize(sidebar)
        XCTAssertEqual(sidebar.arrangedSubviews[0].frame.width, 352, accuracy: 0.01)
        assertPaneMinima(content)
        sidebar.setSidebarHidden(true)
        resize(sidebar)
        XCTAssertEqual(content.frame.width, sidebar.bounds.width, accuracy: 0.01)
        assertPaneMinima(content)
        sidebar.setSidebarHidden(false)
        resize(sidebar)
        XCTAssertEqual(sidebar.arrangedSubviews[0].frame.width, 352, accuracy: 0.01)
        assertPaneMinima(content)
    }

    private func nested(_ axis: SplitAxis, count: Int) -> PaneLayout {
        guard count > 1 else { return .pane(UUID()) }
        return .split(UUID(), axis, nested(axis, count: count - 1), .pane(UUID()))
    }

    private func makeView(_ layout: PaneLayout) -> NSView {
        guard case .split(_, let axis, let first, let second) = layout else { return NSView() }
        let split = TerminalSplitView()
        split.isVertical = axis == .columns
        split.dividerStyle = .thin
        split.delegate = split
        split.firstMinimumSize = first.minimumSize
        split.secondMinimumSize = second.minimumSize
        split.addArrangedSubview(makeView(first))
        split.addArrangedSubview(makeView(second))
        return split
    }

    private func resize(_ view: NSView) {
        guard let split = view as? TerminalSplitView else { return }
        split.resizeSubviews(withOldSize: split.bounds.size)
        split.arrangedSubviews.forEach(resize)
    }

    private func splits(in view: NSView) -> [TerminalSplitView] {
        guard let split = view as? TerminalSplitView else { return [] }
        return [split] + split.arrangedSubviews.flatMap(splits)
    }

    private func assertPaneMinima(_ view: NSView, file: StaticString = #filePath, line: UInt = #line) {
        if let split = view as? TerminalSplitView {
            split.arrangedSubviews.forEach { assertPaneMinima($0, file: file, line: line) }
        } else {
            XCTAssertGreaterThanOrEqual(view.bounds.width + 0.01, PaneLayout.minimumPaneSize.width, file: file, line: line)
            XCTAssertGreaterThanOrEqual(view.bounds.height + 0.01, PaneLayout.minimumPaneSize.height, file: file, line: line)
        }
    }
}

private struct TypographyProbe: NSViewRepresentable {
    @Environment(\.appTypography) private var typography
    func makeNSView(context: Context) -> NSTextField { NSTextField(labelWithString: "Typography") }
    func updateNSView(_ view: NSTextField, context: Context) {
        view.font = AppFont.native(size: typography.contentSize)
    }
}
