import Foundation
import XCTest
@testable import DispatchMobile

/// The Agents list (M3a): rows from topology bindings, urgency, seen markers, mutes and the providers Hosts and Tabs read.
@MainActor
final class ChatConversationsTests: XCTestCase {
    final class Source: ChatConversationSource, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UInt64: ChatConversationSummary] = [:]
        private(set) var calls = 0
        func set(_ terminal: UInt64, _ summary: ChatConversationSummary) { lock.withLock { values[terminal] = summary } }
        func summaries(_ terminals: [UInt64], client: HelperClient) async -> [UInt64: ChatConversationSummary] {
            lock.withLock { calls += 1; return values.filter { terminals.contains($0.key) } }
        }
    }

    private let host = UUID()
    private let helper = ScriptedHelper()

    /// `offset` renumbers every node as a new helper would (same keys, other ids).
    private func topology(agents: [UInt64: String] = [3: "conv-e2e", 5: "conv-app"], offset: Int = 0) throws -> HelperTopology {
        func binding(_ session: String) -> Any {
            ["session": session, "transcript": NSNull(), "pid": 100, "start": [1, 2], "executable": "/bin/claude"]
        }
        let nodes: [[String: Any]] = [
            ["id": 1, "key": "tmux:s:$0", "parent": NSNull(), "kind": "workspace", "name": "app", "detached": false],
            ["id": 2, "key": "tmux:s:$0:@0", "parent": 1, "kind": "tab", "name": "e2e", "detached": false],
            ["id": 3, "key": "tmux:s:$0:%3", "parent": 2, "kind": "terminal", "name": "claude", "cwd": "/work/app",
             "agent": agents[3].map(binding) ?? NSNull(), "detached": false],
            ["id": 4, "key": "tmux:s:$0:@1", "parent": 1, "kind": "tab", "name": "app", "detached": false],
            ["id": 5, "key": "tmux:s:$0:%5", "parent": 4, "kind": "terminal", "name": "claude", "cwd": "/work/app",
             "agent": agents[5].map(binding) ?? NSNull(), "detached": false],
            ["id": 6, "key": "tmux:s:$0:%6", "parent": 4, "kind": "terminal", "name": "zsh", "agent": NSNull(), "detached": false],
        ]
        let renumbered = nodes.map { node -> [String: Any] in
            var node = node
            node["id"] = (node["id"] as! Int) + offset
            if let parent = node["parent"] as? Int { node["parent"] = parent + offset }
            return node
        }
        let object: [String: Any] = ["backend": 9, "nodes": renumbered, "layouts": [], "focus": NSNull()]
        return try JSONDecoder().decode(HelperTopology.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func list(_ source: Source, markers: ChatMarkers = ChatMarkers(store: ChatMarkerMemoryStore())) -> ChatConversations {
        ChatConversations(source: source, markers: markers, outbox: ChatOutbox(store: ChatOutboxMemoryStore()),
                          drafts: ChatDraftRepository(store: ChatDraftMemoryStore()))
    }

    private func snapshot(_ topology: HelperTopology?, link: HostLink = .connected) -> ChatHostSnapshot {
        ChatHostSnapshot(id: host, name: "mba2", link: link, client: link == .connected ? helper.client : nil, topology: topology)
    }

    private let now = Date()
    /// A summary whose newest record is `record` seconds after `now`.
    private func summary(busy: Bool = false, attention: String? = nil, record: Int, finished: Bool = true,
                         preview: String = "Moving the check into a shared middleware.") -> ChatConversationSummary {
        ChatConversationSummary(busy: busy, attention: attention, preview: preview, finished: finished,
                                lastActivity: now.addingTimeInterval(TimeInterval(record)))
    }
    private func milliseconds(_ record: Int) -> Int64 { ChatConversations.milliseconds(now.addingTimeInterval(TimeInterval(record))) }

    /// The Mac's urgency for a row not open on the phone: an open approval (`chat.list` `waiting`) needs you, and
    /// subagents left running after the turn ended do not hold back its unseen result. An unrenamed tab's row takes the
    /// conversation's title, as the Mac's automatic tab names do.
    func testAnOpenApprovalNeedsYouAndLeftoverSubagentsDoNotCountAsWorking() async throws {
        let source = Source()
        var waiting = summary(record: 1)
        waiting.waiting = true
        waiting.title = "Fix the retry loop"
        source.set(3, waiting)
        var subagents = summary(record: 9)
        subagents.subagents = 2
        source.set(5, subagents)
        let markers = ChatMarkers(store: ChatMarkerMemoryStore())
        markers.markSeen(host: host, conversation: "conv-app", through: milliseconds(1))
        let conversations = list(source, markers: markers)
        conversations.update(snapshot(try topology()))
        try await TestSupport.eventually { conversations.dot(host: host, terminal: 3) != nil && conversations.dot(host: host, terminal: 5) != nil }
        XCTAssertEqual(conversations.conversations.first { $0.terminal == 3 }?.urgency, .waiting)
        XCTAssertEqual(conversations.conversations.first { $0.terminal == 5 }?.urgency, .unread)
        XCTAssertEqual(conversations.needsYouCount, 1)
        XCTAssertEqual(conversations.conversations.first { $0.terminal == 3 }?.name, "Fix the retry loop")
        XCTAssertEqual(conversations.conversations.first { $0.terminal == 5 }?.name, "app")
    }

    func testRowsComeFromAgentBoundTerminalsWithTheirUrgency() async throws {
        let source = Source()
        source.set(3, summary(attention: "Waiting for approval", record: 1))
        source.set(5, summary(busy: true, record: 9, finished: false))
        let conversations = list(source)
        conversations.update(snapshot(try topology()))
        try await TestSupport.eventually { conversations.conversations.count == 2 && source.calls > 0 && conversations.dot(host: host, terminal: 5) != nil }
        XCTAssertEqual(Set(conversations.conversations.map(\.name)), ["e2e", "app"], "Rows are named by their tab")
        XCTAssertEqual(conversations.conversations.first?.space, "app")
        XCTAssertEqual(conversations.dot(host: host, terminal: 3), .unread)
        XCTAssertEqual(conversations.dot(host: host, terminal: 5), .working)
        XCTAssertNil(conversations.dot(host: host, terminal: 6), "A shell is no conversation")
        XCTAssertEqual(conversations.dot(host: host), .unread, "A host shows its most urgent conversation")
        XCTAssertEqual(conversations.needsYouCount, 1)
        XCTAssertNil(conversations.dot(host: UUID()))
    }

    func testAResultIsUnreadUntilSeenAndTheFirstSightIsTheBaseline() async throws {
        let source = Source(), markers = ChatMarkers(store: ChatMarkerMemoryStore())
        source.set(3, summary(record: 1))
        let conversations = list(source, markers: markers)
        conversations.update(snapshot(try topology(agents: [3: "conv-e2e"])))
        try await TestSupport.eventually { source.calls == 1 && conversations.conversations.first?.summary.preview != nil }
        XCTAssertNil(conversations.dot(host: host, terminal: 3), "What a conversation already held when first seen is not news")
        // A new result arrives while the phone is elsewhere.
        source.set(3, summary(record: 2))
        await conversations.refresh(host: host)
        XCTAssertEqual(conversations.dot(host: host, terminal: 3), .unread)
        XCTAssertTrue(conversations.conversations[0].unread)
        // Still working on it: amber wins until the turn ends.
        source.set(3, summary(busy: true, record: 3, finished: false))
        await conversations.refresh(host: host)
        XCTAssertEqual(conversations.dot(host: host, terminal: 3), .working)
        source.set(3, summary(record: 3))
        await conversations.refresh(host: host)
        XCTAssertEqual(conversations.dot(host: host, terminal: 3), .unread)
        markers.markSeen(host: host, conversation: "conv-e2e", through: milliseconds(3))
        await conversations.refresh(host: host)
        XCTAssertNil(conversations.dot(host: host, terminal: 3))
        XCTAssertEqual(ChatMarkers(store: markersStore(markers)).seen(host: host, conversation: "conv-e2e"), milliseconds(3), "Seen markers persist")
    }

    private func markersStore(_ markers: ChatMarkers) -> ChatMarkerMemoryStore {
        let store = ChatMarkerMemoryStore()
        store.document = markers.document
        return store
    }

    func testMutingKeepsOnlyNeedsYouAndTheUnreadFilterKeepsRowsWithADot() async throws {
        let source = Source()
        source.set(3, summary(attention: "Approve?", record: 1))
        source.set(5, summary(busy: true, record: 2, finished: false))
        let conversations = list(source)
        conversations.update(snapshot(try topology()))
        try await TestSupport.eventually { conversations.dot(host: host, terminal: 5) == .working }
        for row in conversations.conversations { conversations.setMuted(true, row) }
        XCTAssertEqual(conversations.dot(host: host, terminal: 3), .unread, "An agent blocked on the user stays visible")
        XCTAssertNil(conversations.dot(host: host, terminal: 5))
        XCTAssertTrue(conversations.conversations.allSatisfy(\.muted))
        conversations.unreadOnly = true
        XCTAssertEqual(conversations.visible.map(\.terminal), [3])
        conversations.setMuted(false, conversations.conversations.first { $0.terminal == 5 }!)
        XCTAssertEqual(Set(conversations.visible.map(\.terminal)), [3, 5])
    }

    func testAnOpenSessionsLiveStateReplacesTheProbe() async throws {
        let source = Source()
        source.set(3, summary(record: 1))
        helper.script { request in request.method == "chat.open" ? .open : .result([Any]()) }
        let conversations = list(source)
        conversations.update(snapshot(try topology(agents: [3: "00000000-0000-4000-8000-000000000201"])))
        try await TestSupport.eventually { source.calls == 1 }
        let session = conversations.session(for: ChatConversationKey(host: host, node: "tmux:s:$0:%3"))
        XCTAssertTrue(session === conversations.session(for: ChatConversationKey(host: host, node: "tmux:s:$0:%3")))
        try await TestSupport.eventually { helper.subscription("chat.open") != nil }
        var binding = ChatFixture.binding
        binding["pid"] = 100; binding["start"] = [1, 2]
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        helper.notify(id, "chat.history", ChatFixture.history(terminal: 3, records: try ChatFixture.records("claude-thread"),
                                                              state: ChatFixture.state(busy: false), binding: binding))
        try await TestSupport.eventually { session.phase == .verified }
        XCTAssertTrue(conversations.conversations.first?.summary.preview?.hasPrefix("Right, the invoice.paid path") == true)
        helper.notify(id, "chat.state", ["terminal": 3, "session": "00000000-0000-4000-8000-000000000201",
                                         "state": ChatFixture.state(busy: true)])
        try await TestSupport.eventually { conversations.dot(host: host, terminal: 3) == .working }
        // Offline: the session keeps its thread; the row stays.
        conversations.update(snapshot(nil, link: .reconnecting(attempt: 1, since: Date())))
        XCTAssertEqual(session.phase, .detached)
        XCTAssertEqual(session.transcript.rows.count, 4)
    }

    func testAHelperWithTheChatListFeatureAnswersInOneRequest() async throws {
        let probe = Source()
        helper.script { request in
            guard request.method == "chat.list" else { return .result(NSNull()) }
            return .result([["terminal": 3, "session": "conv-e2e", "key": "claude", "label": "Claude Code", "name": "claude",
                             "cwd": "/work/app", "busy": false, "attention": "Waiting for approval", "activity": NSNull(),
                             "title": NSNull(), "state_error": NSNull(), "preview": "Run playwright test --headed?",
                             "time_ms": 946_719_000_000, "history_error": NSNull(),
                             "binding": ["session": "conv-e2e", "transcript": NSNull(), "pid": 100, "start": [1, 2], "executable": "/bin/claude"]],
                            ["terminal": 5, "busy": true, "preview": "Moving the check", "time_ms": 946_719_100_000]])
        }
        let conversations = list(probe)
        var host = snapshot(try topology())
        host.features = ["chat.list"]
        conversations.update(host)
        try await TestSupport.eventually { conversations.dot(host: self.host, terminal: 5) == .working }
        XCTAssertEqual(conversations.dot(host: self.host, terminal: 3), .unread)
        XCTAssertEqual(conversations.conversations.first { $0.terminal == 3 }?.summary.preview, "Run playwright test --headed?")
        XCTAssertEqual(helper.requests("chat.list").count, 1)
        XCTAssertTrue(helper.requests("chat.state").isEmpty, "No per-conversation probes")
        XCTAssertEqual(probe.calls, 0)
    }

    /// An older `chat-markers.json` without mutes (or with a key this build does not know) keeps its seen markers.
    func testMarkersOfAnOlderShapeKeepWhatTheyHave() throws {
        let file = Data(#"{"version":2,"seen":{"h:c":1700000000000,"h:bad":"x"},"extra":true}"#.utf8)
        let document = try JSONDecoder().decode(ChatMarkers.Document.self, from: file)
        XCTAssertEqual(document.seen, ["h:c": 1_700_000_000_000], "the unreadable entry alone is left out")
        XCTAssertEqual(document.muted, [])
        XCTAssertEqual(document.version, 2)
        let store = ChatMarkerMemoryStore()
        store.document = document
        XCTAssertEqual(ChatMarkers(store: store).document.seen["h:c"], 1_700_000_000_000)
    }

    /// An older `chat-models.json` (no last agent, an agent without menus, a choice without a label) keeps its models.
    func testModelMemoryOfAnOlderShapeKeepsItsChoices() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("chat-models.json")
        try Data(#"{"agents":{"claude":{"model":"opus","efforts":{"opus":[{"id":"high"}]}},"codex":{"models":[{"id":"gpt"},{"label":"no id"}]}}}"#.utf8)
            .write(to: url)
        let memory = ChatModelMemory(url: url)
        XCTAssertNil(memory.lastAgent)
        XCTAssertEqual(memory.agent("claude").model, "opus")
        XCTAssertEqual(memory.agent("claude").efforts["opus"], [.init(id: "high", label: "high")])
        XCTAssertEqual(memory.agent("codex").models, [.init(id: "gpt", label: "gpt")], "the choice without an id alone goes")
    }

    /// New chat keeps its space by topology key: a reconnect that renumbers the nodes while the sheet is open starts the
    /// chat in the same space under its new id, never under the previous helper's.
    func testNewChatStartsInItsSpaceByKeyAfterARenumbering() async throws {
        let conversations = list(Source())
        conversations.update(snapshot(try topology()))
        let space = try XCTUnwrap(conversations.spaces.first)
        XCTAssertEqual(space.key, "tmux:s:$0")
        let renumbered = ScriptedHelper.scripted { request in
            switch request.method {
            case "installation.audit": .result(["edits": [], "restart": false, "installed": true, "optional": false])
            case "terminals.create": .result(13)
            default: nil
            }
        }
        defer { renumbered.close() }
        conversations.update(ChatHostSnapshot(id: host, name: "mba2", link: .connected, client: renumbered.client,
                                              topology: try topology(offset: 10)))
        XCTAssertEqual(conversations.spaces, [space], "the same choice across the reconnect")
        let launch = try JSONDecoder().decode(HelperClient.Launch.self,
                                              from: Data(#"{"launch":4,"key":"claude","label":"Claude","program":"claude"}"#.utf8))
        let key = try await conversations.start(launch, in: space, settings: nil)
        XCTAssertEqual(key.node, "tmux:s:$0:%3")
        let create = try XCTUnwrap(renumbered.requests("terminals.create").first)
        XCTAssertEqual((create.params as? NSDictionary)?["parent"] as? Int, 11, "the space's id on this connection")
    }

    /// Picking another model keeps the previous model's efforts on screen, not choosable, and Done waits, until the new
    /// model's efforts load.
    func testEffortsBelongToTheirModelWhileAnotherLoads() {
        let high = AgentModelMenu.Choice(number: 1, name: "high", detail: "", current: true, isDefault: true)
        var efforts = ChatEffortChoices()
        XCTAssertTrue(efforts.loading(for: "opus"), "before the first load")
        XCTAssertTrue(efforts.shown(for: "opus"), "a loading state, not nothing")
        XCTAssertFalse(efforts.shown(for: nil))
        efforts = ChatEffortChoices(choices: [high], model: "opus")
        XCTAssertFalse(efforts.loading(for: "opus"))
        XCTAssertTrue(efforts.loading(for: "sonnet"), "opus's efforts stay shown while sonnet's load")
        XCTAssertTrue(efforts.shown(for: "sonnet"))
        efforts = ChatEffortChoices(choices: [], model: "haiku")
        XCTAssertFalse(efforts.shown(for: "haiku"), "a model without efforts has no section")
    }

    func testTimeLabelsFollowMessages() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 946_719_000) // 2000-01-01 09:30 UTC, a Saturday
        // M3a's rows write times as Spaces' do (`TabsTime`).
        XCTAssertEqual(TabsTime.label(now.addingTimeInterval(-20), now: now, calendar: calendar), "now")
        XCTAssertEqual(TabsTime.label(now.addingTimeInterval(-24 * 3600), now: now, calendar: calendar), "Yesterday")
        XCTAssertFalse(TabsTime.label(now.addingTimeInterval(-3600), now: now, calendar: calendar)?.isEmpty ?? true)
        XCTAssertNotEqual(TabsTime.label(now.addingTimeInterval(-5 * 24 * 3600), now: now, calendar: calendar), "Yesterday")
    }

    func testPreviewsCollapseToOneParagraph() {
        XCTAssertEqual(ChatConversationSummary.preview("Done.\n\n```swift\nlet a = 1\n```\nTests   green."),
                       "Done. let a = 1 Tests green.")
    }
}
