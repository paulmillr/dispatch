import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class ChatToolGroupingTests: XCTestCase {
    private func tool(_ id: String) -> ChatItem {
        ChatItem(id: id, kind: .tool, text: "{\"cmd\":\"echo \(id)\"}", title: "exec_command", output: "Output for " + id, completed: true, exitCode: 0)
    }

    func testReplyTimesFollowRecordedMessagesWithAndWithoutSteps() {
        let session = ChatSession(id: UUID())
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        session.insert(ChatItem(id: "prompt", kind: .user, text: "Hello"), turnID: "turn", at: date)
        let reply = ChatItem(id: "reply", kind: .assistant, text: "Checking")
        session.insert(reply, turnID: "turn", at: date.addingTimeInterval(60))
        session.insert(tool("one"), turnID: "turn", at: date.addingTimeInterval(61))
        session.insert(tool("two"), turnID: "turn", at: date.addingTimeInterval(62))
        session.insert(ChatItem(id: "final", kind: .assistant, text: "Done"), turnID: "turn", at: date.addingTimeInterval(120))
        let rows = session.transcriptRows
        XCTAssertNil(rows.first?.replyTime)
        XCTAssertEqual(rows.first { $0.group != nil }?.replyTime, date.addingTimeInterval(60))
        XCTAssertEqual(rows.last?.replyTime, date.addingTimeInterval(120))
        // Recorded history can correct a timestamp first observed through a hook.
        session.insert(reply, turnID: "turn", at: date.addingTimeInterval(50), historical: true)
        XCTAssertEqual(session.transcriptRows.first { $0.group != nil }?.replyTime, date.addingTimeInterval(50))
    }

    func testReplyTimesDoNotCollideAcrossDelimitedTurnAndItemIDs() {
        let session = ChatSession(id: UUID())
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        session.insert(ChatItem(id: "reply", kind: .assistant, text: "First reply"), turnID: "turn:part", at: date)
        session.insert(ChatItem(id: "prompt", kind: .user, text: "Next question"), turnID: "turn", at: date.addingTimeInterval(90))
        session.insert(ChatItem(id: "part:reply", kind: .assistant, text: "Second reply"), turnID: "turn", at: date.addingTimeInterval(120))
        XCTAssertEqual(session.transcriptRows.compactMap(\.replyTime), [date, date.addingTimeInterval(120)])
        XCTAssertEqual(session.turns.last?.items.map(\.id), ["prompt", "part:reply"])
        session.insert(ChatItem(id: "part:reply", kind: .assistant, text: "Second reply"), turnID: "turn", at: date.addingTimeInterval(100), historical: true)
        XCTAssertEqual(session.transcriptRows.compactMap(\.replyTime), [date, date.addingTimeInterval(100)])
        XCTAssertEqual(session.turns.last?.items.map(\.id), ["prompt", "part:reply"])
    }

    func testMockupGroupSummaryCountsOperationsWithoutDecodingOutput() {
        let items = [
            ChatItem(id: "read1", kind: .tool, text: #"{"cmd":"cat billing.swift"}"#, title: "exec_command"),
            ChatItem(id: "read2", kind: .tool, text: #"{"command":["zsh","-lc","head helpers.swift"]}"#, title: "shell"),
            ChatItem(id: "patch", kind: .tool, text: "*** Begin Patch", title: "functions.apply_patch"),
            ChatItem(id: "shell", kind: .tool, text: #"{"cmd":"swift test"}"#, title: "exec_command", output: String(repeating: "large output\n", count: 100_000))
        ]
        XCTAssertEqual(ChatToolGroupHeader.summarize(items), "Patch")
        let webItems = [
            ChatItem(id: "web-search", kind: .tool, text: #"{"search_query":[{"q":"Swift"}]}"#, title: "web.run"),
            ChatItem(id: "web-open", kind: .tool, text: #"{"open":[{"ref_id":"https://example.com"}]}"#, title: "web__run"),
            ChatItem(id: "web-click", kind: .tool, text: #"{"click":[{"ref_id":"turn0view0","id":7}]}"#, title: "functions.web__run")
        ]
        for item in webItems {
            XCTAssertEqual(ChatToolGroupHeader.summarize([item]), "Browse web")
        }
        XCTAssertEqual(ChatToolGroupHeader.summarize(items + webItems), "Patch · Browse web ×3")
        XCTAssertEqual(ChatToolGroupHeader.summarize([
            ChatItem(id: "large", kind: .tool, text: String(repeating: "command", count: 10_000), title: "exec_command"),
            ChatItem(id: "tools", kind: .tool, text: "", title: "functions.exec"),
            ChatItem(id: "read", kind: .tool, text: "", title: "read_file")
        ]), "")
        XCTAssertEqual(ChatToolGroupHeader.summarize([
            ChatItem(id: "search", kind: .tool, text: #"{"cmd":"rg pattern ."}"#, title: "exec_command"),
            ChatItem(id: "search-again", kind: .tool, text: "", title: "search"),
            ChatItem(id: "patch", kind: .tool, text: "", title: "apply_patch"),
            ChatItem(id: "input", kind: .tool, text: "", title: "write_stdin"),
            ChatItem(id: "custom", kind: .tool, text: "", title: "Browser"),
            ChatItem(id: "custom-again", kind: .tool, text: "", title: "Browser")
        ]), "Patch")
    }

    func testConsecutiveToolsGroupWithinTurnsAndKeepApprovalsVisible() {
        let session = ChatSession(id: UUID())
        session.turns = [ChatTurn(id: "first", items: [tool("one"), tool("two"),
            ChatItem(id: "message", kind: .assistant, text: "An explanation"), tool("three")]),
            ChatTurn(id: "second", items: [tool("four"), tool("five")])]
        let approval = PendingApproval(key: "approval", operation: "echo three", turnID: "first") { _ in }
        session.approvals = [approval]
        let rows = session.transcriptRows
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].group?.children.map { $0.item!.id }, ["one", "two"])
        XCTAssertEqual(rows[1].item?.kind, .assistant)
        XCTAssertEqual(rows[1].group?.children.first?.item?.id, "three", "Steps belong to the preceding assistant bubble")
        XCTAssertTrue(rows[2].approval === approval)
        XCTAssertEqual(rows[3].group?.children.map { $0.item!.id }, ["four", "five"])
        XCTAssertEqual(session.visibleTranscriptRows.count, 4)
        session.expandedToolGroups.insert(rows[0].id)
        XCTAssertEqual(session.visibleTranscriptRows.count, 6)
        XCTAssertTrue(session.visibleTranscriptRows.contains { $0.approval === approval })
        XCTAssertTrue(session.expanded.isEmpty, "Opening a group must leave individual tools collapsed")
        let ids = session.visibleTranscriptRows.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testGroupIdentityAndExpansionSurviveNewToolsAndOutput() {
        let session = ChatSession(id: UUID())
        session.turns = [ChatTurn(id: "turn", items: [tool("one"), tool("two")])]
        let groupID = session.transcriptRows[0].id
        let presentationID = session.transcriptRows[0].group!.presentationID
        XCTAssertEqual(session.transcriptRows[0].group!.presentationID, presentationID,
            "Reading cached rows must not restart the summary task")
        let childID = session.transcriptRows[0].group!.children[0].id
        session.expandedToolGroups.insert(groupID)
        session.expanded.insert(childID)
        session.turns[0].items[0].output = "Updated output"
        session.turns[0].items.append(tool("three"))
        XCTAssertEqual(session.transcriptRows[0].id, groupID)
        XCTAssertNotEqual(session.transcriptRows[0].group!.presentationID, presentationID,
            "Changed tools refresh the summary without changing disclosure identity")
        XCTAssertEqual(session.visibleTranscriptRows.count, 4)
        XCTAssertEqual(session.visibleTranscriptRows[1].item?.output, "Updated output")
        session.expandedToolGroups.remove(groupID)
        XCTAssertEqual(session.visibleTranscriptRows.count, 1)
        XCTAssertTrue(session.expanded.contains(childID))
        session.expandedToolGroups.insert(groupID)
        XCTAssertEqual(session.visibleTranscriptRows.count, 4)
        session.resetConversation()
        XCTAssertTrue(session.expandedToolGroups.isEmpty)
        XCTAssertTrue(session.visibleTranscriptRows.isEmpty)
    }

    func testHistoricalMessageSplitsToolGroupsWithoutSharingDisclosureState() throws {
        for reordered in [false, true] {
            let session = ChatSession(id: UUID())
            let tools = (1...4).map { tool(String($0)) }
            session.turns = [ChatTurn(id: "turn", items: tools)]
            let original = try XCTUnwrap(session.transcriptRows.first?.group)
            session.expandedToolGroups.insert(original.id)
            let first = reordered ? Array(tools.suffix(2)) : Array(tools.prefix(2))
            let last = reordered ? Array(tools.prefix(2)) : Array(tools.suffix(2))
            session.turns[0].items = first + [ChatItem(id: "explanation", kind: .assistant, text: "More context from history")] + last
            let groups = session.transcriptRows.compactMap(\.group)
            XCTAssertEqual(groups.count, 2)
            XCTAssertEqual(Set(groups.map(\.id)).count, 2, "Separate groups must not share expansion state after history reconciliation")
            XCTAssertEqual(groups.first?.id, original.id)
            XCTAssertEqual(session.visibleTranscriptRows.filter { $0.toolGroupID != nil }.compactMap { $0.item?.id }, first.map(\.id))
        }
    }

    func testMergingToolGroupsKeepsPreviouslyVisibleToolsExpanded() throws {
        let session = ChatSession(id: UUID())
        let tools = (1...4).map { tool(String($0)) }
        session.turns = [ChatTurn(id: "turn", items: Array(tools.prefix(2))
            + [ChatItem(id: "explanation", kind: .assistant, text: "Temporary message")]
            + Array(tools.suffix(2)))]
        let groups = session.transcriptRows.compactMap(\.group)
        let expanded = try XCTUnwrap(groups.last)
        session.setGroupExpanded(expanded, true)
        session.turns[0].items = tools
        let merged = try XCTUnwrap(session.transcriptRows.first?.group)
        XCTAssertTrue(session.groupIsExpanded(merged, turnID: "turn"), "History merging must not hide tools the user was reading")
        XCTAssertEqual(session.visibleTranscriptRows.filter { $0.toolGroupID != nil }.compactMap { $0.item?.id }, tools.map(\.id))
        session.turns[0].items[3].output = "Updated output"
        XCTAssertEqual(session.transcriptRows.first?.group?.id, merged.id)
        XCTAssertEqual(session.visibleTranscriptRows.last?.item?.output, "Updated output")
    }

    func testMergingLiveToolGroupsPreservesManualCollapse() throws {
        let session = ChatSession(id: UUID())
        session.activeTurnID = "turn"; session.busy = true
        let tools = (1...4).map { tool(String($0)) }
        session.turns = [ChatTurn(id: "turn", items: Array(tools.prefix(2))
            + [ChatItem(id: "explanation", kind: .assistant, text: "Temporary message")]
            + Array(tools.suffix(2)))]
        let group = try XCTUnwrap(session.transcriptRows.last?.group)
        XCTAssertTrue(session.groupIsExpanded(group, turnID: "turn"))
        session.setGroupExpanded(group, false)
        session.turns[0].items = tools
        let merged = try XCTUnwrap(session.transcriptRows.first?.group)
        XCTAssertFalse(session.groupIsExpanded(merged, turnID: "turn"), "History must not reopen a manually collapsed live group")
        XCTAssertTrue(session.visibleTranscriptRows.allSatisfy { $0.toolGroupID == nil })
        session.turns[0].items[3].output = "More output"
        XCTAssertEqual(session.transcriptRows.first?.group?.id, merged.id)
        XCTAssertTrue(session.visibleTranscriptRows.allSatisfy { $0.toolGroupID == nil })
    }

    func testMergedGroupDisclosureSurvivesPresentationRestore() throws {
        for (expanded, historyLoaded) in [(false, false), (false, true), (true, false), (true, true)] {
            let session = ChatSession(id: UUID())
            session.activeTurnID = "turn"; session.busy = !expanded
            let tools = (1...4).map { tool(String($0)) }
            session.turns = [ChatTurn(id: "turn", items: Array(tools.prefix(2))
                + [ChatItem(id: "explanation", kind: .assistant, text: "Temporary message")]
                + Array(tools.suffix(2)))]
            session.setGroupExpanded(try XCTUnwrap(session.transcriptRows.last?.group), expanded)
            session.turns[0].items = tools
            let merged = try XCTUnwrap(session.transcriptRows.first?.group)
            XCTAssertEqual(session.groupIsExpanded(merged, turnID: "turn"), expanded)
            let restored = ChatSession(id: UUID())
            restored.activeTurnID = "turn"; restored.busy = !expanded
            if historyLoaded {
                restored.turns = session.turns
                _ = restored.visibleTranscriptRows
            }
            restored.restorePresentation(session.presentation)
            if !historyLoaded { restored.turns = session.turns }
            let group = try XCTUnwrap(restored.transcriptRows.first?.group)
            XCTAssertEqual(group.id, merged.id)
            XCTAssertEqual(restored.groupIsExpanded(group, turnID: "turn"), expanded)
            XCTAssertEqual(restored.visibleTranscriptRows.filter { $0.toolGroupID != nil }.count, expanded ? 4 : 0)
            restored.turns[0].items.insert(tool("older"), at: 0)
            let paged = try XCTUnwrap(restored.transcriptRows.first?.group)
            XCTAssertEqual(paged.id, merged.id, "Loading earlier tools must keep the restored disclosure identity")
            XCTAssertEqual(restored.groupIsExpanded(paged, turnID: "turn"), expanded)
            XCTAssertEqual(restored.visibleTranscriptRows.filter { $0.toolGroupID != nil }.count, expanded ? 5 : 0)
        }
    }

    func testCollapsedHugeGroupDoesNotFormatHiddenTools() async throws {
        let session = ChatSession(id: UUID())
        session.sessionID = "large-group"
        let output = String(repeating: "large output\n", count: 2_000)
        session.turns = [ChatTurn(id: "turn", items: (0..<10_000).map {
            var item = tool(String($0)); item.output = output; return item
        })]
        let baseline = await ToolPresentationCache.shared.builds
        let window = makeWindow()
        defer { window.close(); window.contentView = nil }
        mount(session, in: window)
        try await Task.sleep(for: .milliseconds(300))
        let builds = await ToolPresentationCache.shared.builds - baseline
        XCTAssertEqual(builds, 0, "Collapsed groups must not parse hidden tool payloads")
        XCTAssertEqual(session.visibleTranscriptRows.count, 1)
        XCTAssertEqual(session.transcriptRows[0].group?.children.count, 10_000)
        try await click(x: 80, y: 700 - 22 - 19, window: window)
        XCTAssertEqual(session.visibleTranscriptRows.count, 10_001)
        let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: try XCTUnwrap(window.contentView)).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        XCTAssertLessThan(scroll.contentView.bounds.minY, 100, "Opening a group must show its first tools, not jump to the last one")
        let openedBuilds = await ToolPresentationCache.shared.builds - baseline
        XCTAssertLessThan(openedBuilds, 150)
    }

    func testNativeGroupAndChildUnwrapIndependentlyAndRetainState() async throws {
        AppFont.register()
        let session = ChatSession(id: UUID())
        session.sessionID = "grouped-tools"; session.atBottom = false
        session.turns = [ChatTurn(id: "turn", items: [tool("one"), tool("two"), tool("three")])]
        let groupID = session.transcriptRows[0].id
        let childID = session.transcriptRows[0].group!.children[0].id
        let window = makeWindow()
        defer { window.close(); window.contentView = nil }
        mount(session, in: window)
        try await Task.sleep(for: .milliseconds(300))
        func capture(_ name: String) async throws -> String {
            try await PresentationTestSupport.capture(window, named: name, in: "chat-group-validation").text()
        }
        let collapsed = try await capture("collapsed")
        // OCR can omit the isolated count at smaller selected label sizes.
        XCTAssertTrue(collapsed.contains("steps"), collapsed)
        XCTAssertEqual(session.transcriptRows.first?.group?.children.count, 3)
        XCTAssertFalse(collapsed.contains("echo one"), collapsed)
        try await click(x: 80, y: 700 - 22 - 19, window: window)
        XCTAssertTrue(session.expandedToolGroups.contains(groupID), "Clicking the step text must open the group")
        XCTAssertTrue(session.expanded.isEmpty)
        let children = try await capture("children")
        XCTAssertTrue(children.contains("echo one"), children)
        XCTAssertFalse(children.contains("Output for one"), children)
        let content = try XCTUnwrap(window.contentView)
        let labels = try await PresentationTestSupport.capture(content).recognizedText()
        let toolLabel = try XCTUnwrap(labels.first { $0.topCandidates(1).first?.string.contains("echo") == true })
        let rowY = toolLabel.boundingBox.midY * content.bounds.height
        let point = content.convert(NSPoint(x: 450, y: content.isFlipped ? content.bounds.height - rowY : rowY), to: nil)
        try await click(x: point.x, y: point.y, window: window)
        XCTAssertTrue(session.expanded.contains(childID))
        XCTAssertTrue(session.expandedToolGroups.contains(groupID), "Child disclosure must not close its group")
        let inner = try await capture("inner-expanded")
        XCTAssertTrue(inner.contains("Output for one"), inner)
        try await click(x: 80, y: 700 - 22 - 19, window: window)
        XCTAssertFalse(session.expandedToolGroups.contains(groupID))
        XCTAssertTrue(session.expanded.contains(childID))
        try await click(x: 80, y: 700 - 22 - 19, window: window)
        let snapshot1 = try await capture("reopened")
        XCTAssertTrue(snapshot1.contains("Output for one"))
        // Remounting is how switching back from the terminal reconstructs chat.
        window.contentView = nil
        session.atBottom = false; session.scrollAnchor = nil
        mount(session, in: window)
        try await Task.sleep(for: .milliseconds(300))
        let snapshot2 = try await capture("restored")
        XCTAssertTrue(snapshot2.contains("Output for one"))
    }

    func testReplyTimeStaysBesideStepsAcrossExpansionAndNarrowLayout() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let session = ChatSession(id: UUID())
        session.sessionID = "reply-time-layout"; session.atBottom = false
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 13, minute: 24)))
        session.insert(ChatItem(id: "reply", kind: .assistant, text: "Checking the handler."), turnID: "turn", at: date)
        session.insert(tool("one"), turnID: "turn", at: date.addingTimeInterval(1))
        session.insert(tool("two"), turnID: "turn", at: date.addingTimeInterval(2))
        let group = try XCTUnwrap(session.transcriptRows.first?.group)
        let window = makeWindow()
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: ChatCoordinator(enabled: false), focused: false, floatingSwitch: false)
            .environment(\.locale, Locale(identifier: "en_GB")))
        window.makeKeyAndOrderFront(nil)
        for (name, width, expanded) in [("collapsed", 900.0, false), ("expanded", 900.0, true), ("narrow", 480.0, true), ("interrupted", 480.0, false)] {
            if name == "interrupted" {
                session.busy = false; session.activeTurnID = nil
                session.terminalAttention = "Response interrupted"
                session.turns[0].items[2].exitCode = 130
            }
            window.setContentSize(NSSize(width: width, height: 700))
            session.setGroupExpanded(group, expanded)
            try await Task.sleep(for: .milliseconds(250))
            let snapshot = try await PresentationTestSupport.capture(window, named: "reply-time-" + name, in: "chat-group-validation")
            func bounds(_ text: String) throws -> CGRect {
                let box = try snapshot.box(of: text)
                let captured = try snapshot.text()
                return try XCTUnwrap(box, "Missing \(text) in \(name): \(captured)")
            }
            let steps = try bounds("steps"), time = try bounds("13:24")
            XCTAssertGreaterThan(time.minX, steps.maxX)
            XCTAssertEqual(time.midY, steps.midY, accuracy: 0.015)
            XCTAssertLessThan(time.maxX, 1)
        }
    }

    func testLiveMessageStepsCollapseAtCompletionAndRespectManualChoice() throws {
        let session = ChatSession(id: UUID())
        session.activeTurnID = "turn"; session.busy = true
        session.turns = [ChatTurn(id: "turn", items: [
            ChatItem(id: "message", kind: .assistant, text: "Updating the handler."), tool("one"), tool("two")])]
        let row = try XCTUnwrap(session.transcriptRows.first)
        let group = try XCTUnwrap(row.group)
        XCTAssertEqual(row.item?.id, "message")
        XCTAssertEqual(session.visibleTranscriptRows.count, 3)
        XCTAssertFalse(session.visibleTranscriptRows[0].bubbleEnd)
        XCTAssertFalse(session.visibleTranscriptRows[1].bubbleStart)
        XCTAssertTrue(session.visibleTranscriptRows[2].bubbleEnd)
        session.setGroupExpanded(group, false)
        XCTAssertEqual(session.visibleTranscriptRows.count, 1)
        session.turns[0].items.append(tool("three"))
        XCTAssertEqual(session.visibleTranscriptRows.count, 1, "Live output must respect a manual collapse")
        session.setGroupExpanded(group, true)
        session.busy = false
        XCTAssertEqual(session.visibleTranscriptRows.count, 4, "Manual expansion survives completion")
        let restored = ChatSession(id: UUID())
        restored.restorePresentation(session.presentation)
        XCTAssertEqual(restored.expandedToolGroups, session.expandedToolGroups)
        session.expandedToolGroups = []
        session.busy = true
        XCTAssertEqual(session.visibleTranscriptRows.count, 4)
        session.busy = false
        XCTAssertEqual(session.visibleTranscriptRows.count, 1, "Automatic expansion ends with the turn")
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
    private func mount(_ session: ChatSession, in window: NSWindow) {
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: ChatCoordinator(enabled: true), focused: false, floatingSwitch: false)
            .foregroundStyle(Chrome.ink).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
    }
    private func click(x: CGFloat, y: CGFloat, window: NSWindow) async throws {
        try PresentationTestSupport.click(window, at: NSPoint(x: x, y: y))
        try await Task.sleep(for: .milliseconds(200))
    }
}
