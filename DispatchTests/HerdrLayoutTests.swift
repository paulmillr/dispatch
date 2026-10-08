import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class HerdrLayoutTests: XCTestCase {
    func testSplitPathsAndPreviewCoordinates() async throws {
        let herdr = try await HerdrSession(); defer { herdr.close() }
        let pane = try XCTUnwrap(herdr.snapshot().panes.first).pane_id
        _ = try herdr.api("pane.split", ["target_pane_id": pane, "direction": "right", "ratio": 0.5])
        let workspace = herdr.app.workspace
        try await TestSupport.eventually { workspace.current?.activeWindow?.arrangement.panes.count == 2 }
        let space = try XCTUnwrap(workspace.current)
        let divider = try XCTUnwrap(space.activeWindow?.arrangement.layout.splitIDs.first)
        for ratio in [0.5, 0.7] {
            workspace.resizeDivider(divider, in: space.id, fraction: ratio)
            var split: TerminalSplitView?
            try await TestSupport.eventually {
                split = PresentationTestSupport.views(of: TerminalSplitView.self,
                    in: herdr.app.window.contentView!, includingNestedMatches: true).first { !$0.sidebar && $0.isVertical && $0.arrangedSubviews.count == 2 }
                guard let split else { return false }
                let length = split.bounds.width - split.dividerThickness
                return length > 0 && abs(split.arrangedSubviews[0].frame.width / length - ratio) < 0.001
            }
            let view = try XCTUnwrap(split)
            let scale = 100 / (view.bounds.width - view.dividerThickness)
            let actual = view.arrangedSubviews.enumerated().map { index, child in
                let rect = child.frame
                return [10 + (rect.minX - (index == 0 ? 0 : view.dividerThickness)) * scale,
                    5 + rect.minY * 40 / view.bounds.height, rect.width * scale, rect.height * 40 / view.bounds.height]
                    .map { $0.rounded() }
            }
            let expected: [[CGFloat]] = ratio == 0.5
                ? [[10, 5, 50, 40], [60, 5, 50, 40]]
                : [[10, 5, 70, 40], [80, 5, 30, 40]]
            XCTAssertEqual(actual, expected)
        }
        // Wire split-path parsing belongs to herdr; these checks cover the app's rendered projection.
    }

    func testDividerEscapeCancelsAndDoubleClickBalances() async throws {
        for cancel in [true, false] {
            let herdr = try await HerdrSession(); defer { herdr.close() }
            let pane = try XCTUnwrap(herdr.snapshot().panes.first).pane_id
            _ = try herdr.api("pane.split", ["target_pane_id": pane, "direction": "down", "ratio": 0.7])
            let workspace = herdr.app.workspace, window = herdr.app.window
            try await TestSupport.eventually { workspace.current?.activeWindow?.arrangement.panes.count == 2 }
            var split: TerminalSplitView?
            try await TestSupport.eventually {
                split = PresentationTestSupport.views(of: TerminalSplitView.self,
                    in: window.contentView!, includingNestedMatches: true).first { !$0.sidebar && !$0.isVertical && $0.arrangedSubviews.count == 2 }
                guard let split else { return false }
                let length = split.bounds.height - split.dividerThickness
                return length > 0 && abs(split.arrangedSubviews[0].frame.height / length - 0.7) < 0.01
            }
            let view = try XCTUnwrap(split)
            var commits: [CGFloat] = [], previews: [Double] = []
            let commit = view.onDividerChange, preview = view.fractionChanged
            view.onDividerChange = { commits.append($0); commit?($0) }
            view.fractionChanged = { previews.append($0); preview?($0) }
            let first = view.arrangedSubviews[0].frame, second = view.arrangedSubviews[1].frame
            let length = view.bounds.height - view.dividerThickness
            let direction: CGFloat = first.minY < second.minY ? 1 : -1
            let y = direction > 0 ? first.maxY + view.dividerThickness / 2 : first.minY - view.dividerThickness / 2
            let start = view.convert(NSPoint(x: view.bounds.midX, y: y), to: nil)
            let end = view.convert(NSPoint(x: view.bounds.midX, y: y + direction * (length * 0.5 - first.height)), to: nil)
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: start,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: cancel ? 1 : 2, pressure: 1))
            if cancel {
                let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: end, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
                let events = [try PresentationTestSupport.mouseEvent(.leftMouseDragged, in: window, at: end),
                    escape, try PresentationTestSupport.mouseEvent(.leftMouseUp, in: window, at: end)]
                for event in events.reversed() { NSApp.postEvent(event, atStart: true) }
            } else {
                NSApp.postEvent(try PresentationTestSupport.mouseEvent(.leftMouseUp, in: window, at: start), atStart: true)
            }
            window.sendEvent(down)
            if cancel {
                try await TestSupport.eventually { !previews.isEmpty }
                XCTAssertTrue(previews.contains { abs($0 - 0.5) < 0.01 }, "A downward divider uses flipped window coordinates")
                XCTAssertTrue(commits.isEmpty, "Escape cancels without sending a server resize")
                XCTAssertEqual(view.arrangedSubviews[0].frame.height / (view.bounds.height - view.dividerThickness), 0.7, accuracy: 0.01)
            } else {
                XCTAssertEqual(commits.count, 1)
                XCTAssertEqual(try XCTUnwrap(commits.last), 0.5, accuracy: 0.01)
                XCTAssertEqual(view.arrangedSubviews[0].frame.height / (view.bounds.height - view.dividerThickness), 0.5, accuracy: 0.01)
            }
        }
    }
}
