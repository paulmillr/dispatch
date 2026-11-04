import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

/// What a reader sees move when a pane switches to another chat tab: every mounted row's place in the window, sampled
/// every few milliseconds from `selectTab` until the chat has rested, with the viewport's frame, the clip's offset and
/// the transcript's opacity. Once a chat shows its rows, nothing in it may move.
@MainActor
final class ChatTabSwitchMotionTests: XCTestCase {
    private struct Shot {
        let time: Double
        let viewport: NSRect
        let clipY: CGFloat
        let documentHeight: CGFloat
        let opacity: CGFloat
        /// Mounted rows intersecting the viewport, by ID: their top edge in window coordinates (y up).
        let rows: [String: CGFloat]
    }

    func testSwitchingToAChatTabMovesNoText() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let app = try TmuxWalkthrough(); defer { app.close() }
        var tabs: [UUID] = []
        for index in 0..<3 {
            if index > 0 { app.workspace.newTab() }
            let surface = try XCTUnwrap(app.workspace.activeSurfaceID)
            try await TestSupport.eventually(timeout: .seconds(15)) {
                app.runtime.views[surface].map { $0.window === app.window && !TerminalTestSupport.viewport(terminal: $0).isEmpty } == true
            }
            tabs.append(try XCTUnwrap(app.workspace.activeTab).id)
        }
        let sessions = tabs.enumerated().map { index, tab in
            let session = app.runtime.chat.session(for: tab)
            session.sessionID = "tab-motion-\(index)"
            session.turns = Self.fixture(index)
            session.setView(true, reason: "motion")
            return session
        }
        func document(_ session: ChatSession) -> ChatTranscriptDocument? {
            app.window.contentView.flatMap { root in
                PresentationTestSupport.views(of: ChatTranscriptDocument.self, in: root).first { $0.position === session.scrollPosition }
            }
        }
        func shot(_ session: ChatSession, since start: Double) -> Shot? {
            guard let document = document(session), let scroll = document.enclosingScrollView, document.window != nil else { return nil }
            let clip = scroll.contentView.bounds
            var rows: [String: CGFloat] = [:]
            for (id, row) in document.mountedRows where row.frame.maxY > clip.minY && row.frame.minY < clip.maxY {
                rows[id] = row.convert(row.bounds, to: nil).maxY
            }
            var opacity: CGFloat = 1
            var view: NSView? = scroll
            while let current = view {
                opacity *= current.alphaValue * CGFloat(current.layer?.presentation()?.opacity ?? current.layer?.opacity ?? 1)
                view = current.superview
            }
            return Shot(time: CACurrentMediaTime() - start, viewport: scroll.convert(scroll.bounds, to: nil), clipY: clip.minY,
                        documentHeight: document.frame.height, opacity: opacity, rows: rows)
        }
        /// Switches, then samples until 1.2 s have passed; returns every sample from the first that showed rows.
        func record(_ index: Int) async throws -> [Shot] {
            let start = CACurrentMediaTime()
            app.workspace.selectTab(tabs[index])
            var shots: [Shot] = []
            while CACurrentMediaTime() - start < 1.2 {
                if let shot = shot(sessions[index], since: start), !shot.rows.isEmpty || !shots.isEmpty { shots.append(shot) }
                try await Task.sleep(for: .milliseconds(3))
            }
            return shots
        }
        for index in [0, 1, 2] { _ = try await record(index) }
        // The third reader is in history.
        let rows = sessions[2].visibleTranscriptRows
        let anchor = rows[max(0, rows.count - 30)].id
        sessions[2].scrollPosition.userWillScroll(deltaY: 1)
        sessions[2].atBottom = false; sessions[2].followRevision = nil
        sessions[2].scrollPosition.restore(.init(id: anchor, offset: 0))
        try await TestSupport.eventually { sessions[2].scrollPosition.visibleAnchor(retaining: [anchor]) != nil }
        try await Task.sleep(for: .seconds(1))

        var report: [String] = ["glass=\(LiquidGlassStore.shared.active)"]
        var moved: [String] = []
        for (step, index) in [0, 1, 2, 0, 2, 1, 2].enumerated() {
            let shots = try await record(index)
            guard let first = shots.first else { moved.append("switch \(step) to tab \(index): never showed rows"); continue }
            report.append("switch \(step) to tab \(index): rows at \(Int(first.time * 1000)) ms, viewport \(first.viewport), "
                + "clip \(first.clipY), opacity \(String(format: "%.2f", first.opacity))")
            var previous = first
            for shot in shots.dropFirst() {
                var changes: [String] = []
                let shared = Set(previous.rows.keys).intersection(shot.rows.keys)
                let deltas = shared.map { shot.rows[$0]! - previous.rows[$0]! }.filter { abs($0) > 0.5 }
                if let delta = deltas.max(by: { abs($0) < abs($1) }) { changes.append("rows \(String(format: "%+.1f", delta)) pt") }
                if shot.viewport != previous.viewport { changes.append("viewport \(previous.viewport) -> \(shot.viewport)") }
                if abs(shot.clipY - previous.clipY) > 0.5 { changes.append("clip \(previous.clipY) -> \(shot.clipY)") }
                if abs(shot.documentHeight - previous.documentHeight) > 0.5 {
                    changes.append("document \(previous.documentHeight) -> \(shot.documentHeight)")
                }
                if abs(shot.opacity - previous.opacity) > 0.02 { changes.append(String(format: "opacity %.2f", shot.opacity)) }
                if !changes.isEmpty {
                    let line = "  \(Int(shot.time * 1000)) ms: " + changes.joined(separator: ", ")
                    report.append(line)
                    if !deltas.isEmpty { moved.append("switch \(step) to tab \(index)" + line) }
                }
                previous = shot
            }
        }
        print("CHAT_TAB_MOTION\n" + report.joined(separator: "\n"))
        XCTAssertEqual(moved, [], "A chat that shows its rows keeps them in place")
    }

    /// Replies of varied length, so offscreen estimates never match.
    private static func fixture(_ tab: Int) -> [ChatTurn] {
        (0..<120).map { turn in
            let prose = (0..<(turn % 4 + 1)).map {
                "Tab \(tab), paragraph \(turn)/\($0): check the queued change and keep the reading position with **formatted text**."
            }.joined(separator: "\n\n")
            return ChatTurn(id: "turn-\(turn)", items: [
                .init(id: "prompt-\(turn)", kind: .user, text: "Check change \(turn)."),
                .init(id: "reply-\(turn)", kind: .assistant, text: prose),
                .init(id: "tool-\(turn)", kind: .tool, text: #"{"cmd":"rg result Sources"}"#, title: "exec_command",
                      output: "Sources/Queue.swift:\(turn): result", completed: true, exitCode: 0)])
        }
    }
}
