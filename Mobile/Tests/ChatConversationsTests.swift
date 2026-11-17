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
        private var failing = false
        private var delay = Duration.zero
        /// Requests fail (nil) until set back.
        func fail(_ on: Bool) { lock.withLock { failing = on } }
        /// Each request takes `delay` to answer.
        func slow(_ delay: Duration) { lock.withLock { self.delay = delay } }
        func summaries(_ terminals: [UInt64], client: HelperClient) async -> [UInt64: ChatConversationSummary] {
            lock.withLock { calls += 1; return values.filter { terminals.contains($0.key) } }
        }
        func fetch(_ terminals: [UInt64], client: HelperClient) async -> [UInt64: ChatConversationSummary]? {
            let (failing, delay) = lock.withLock { (self.failing, self.delay) }
            if delay > .zero { try? await Task.sleep(for: delay) }
            if failing {
                lock.withLock { calls += 1 }
                return nil
            }
            return await summaries(terminals, client: client)
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
        conversations.filter = .unread
        XCTAssertEqual(conversations.visible.map(\.terminal), [3])
        conversations.setMuted(false, conversations.conversations.first { $0.terminal == 5 }!)
        XCTAssertEqual(conversations.visible.map(\.terminal), [3], "Working is not unread")
        conversations.filter = .needsYou
        XCTAssertEqual(conversations.visible.map(\.terminal), [3])
        conversations.filter = .all
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
        try await TestSupport.eventually {
            conversations.conversations.first?.summary.preview?.hasPrefix("Right, the invoice.paid path") == true
        }
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
    // MARK: Freshness (docs/ios.md, Agents)

    /// Pull to refresh, the foreground and the timer read the rows again (`refreshAll`); a request that fails keeps the
    /// rows as they were, stale, never live with old data.
    func testRowsAreReadAgainAndAFailedReadLeavesThemStale() async throws {
        let source = Source()
        source.set(3, summary(busy: true, record: 1, finished: false))
        let conversations = list(source)
        conversations.update(snapshot(try topology(agents: [3: "conv-e2e"])))
        try await TestSupport.eventually { conversations.dot(host: self.host, terminal: 3) == .working }
        XCTAssertFalse(conversations.conversations[0].stale)
        source.set(3, summary(record: 2))
        await conversations.refreshAll()
        XCTAssertEqual(conversations.dot(host: host, terminal: 3), .unread, "The finished turn shows without opening the thread")
        source.fail(true)
        conversations.update(snapshot(try topology(agents: [3: "conv-e2e"]), link: .reconnecting(attempt: 1, since: now)))
        XCTAssertTrue(conversations.conversations[0].stale)
        // A new connection whose first read fails: still the previous connection's rows, stale.
        let other = ScriptedHelper()
        conversations.update(ChatHostSnapshot(id: host, name: "mba2", link: .connected, client: other.client,
                                              topology: try topology(agents: [3: "conv-e2e"])))
        try await TestSupport.eventually { source.calls >= 3 }
        XCTAssertTrue(conversations.conversations[0].stale, "Rows stay stale until a read over this connection answers")
        source.fail(false)
        await conversations.refreshAll()
        XCTAssertFalse(conversations.conversations[0].stale)
    }

    /// A refresh asked while one is on its way runs again when it ends, instead of being dropped.
    func testARefreshAskedDuringAReadRunsAgain() async throws {
        let source = Source()
        source.set(3, summary(record: 1))
        let conversations = list(source)
        conversations.update(snapshot(try topology(agents: [3: "conv-e2e"])))
        try await TestSupport.eventually { source.calls == 1 }
        source.slow(.milliseconds(300))
        source.set(3, summary(record: 2))
        let host = host
        let first = Task { await conversations.refresh(host: host) }
        try await Task.sleep(for: .milliseconds(50))
        source.set(3, summary(record: 3))
        await conversations.refresh(host: host)
        await first.value
        XCTAssertEqual(source.calls, 3)
        XCTAssertEqual(conversations.conversations[0].summary.lastActivity, now.addingTimeInterval(3))
    }

    /// A state the helper could not read (`state_error`) keeps the row's state; a read without a message keeps its
    /// message and time; Claude waiting at a prompt in its terminal (`activity` "waiting") needs the user.
    func testAPartialReadKeepsWhatTheRowHadAndAWaitingAgentNeedsYou() throws {
        func row(_ object: [String: Any]) throws -> ChatConversationSummary {
            try JSONDecoder().decode(ChatListOperation.Row.self, from: JSONSerialization.data(withJSONObject: object)).summary
        }
        let previous = summary(busy: true, record: 5, finished: false)
        let unknown = try row(["terminal": 3, "busy": NSNull(), "state_error": "registry changed", "preview": "Later text",
                               "time_ms": milliseconds(6)])
        XCTAssertTrue(unknown.partial)
        let merged = unknown.merged(over: previous)
        XCTAssertTrue(merged.busy, "Not turned idle (and so unread) by a state it could not read")
        XCTAssertEqual(merged.preview, "Later text")
        let empty = try row(["terminal": 3, "busy": false, "history_error": "changed"])
        let kept = empty.merged(over: summary(record: 4))
        XCTAssertEqual(kept.preview, "Moving the check into a shared middleware.")
        XCTAssertEqual(kept.lastActivity, now.addingTimeInterval(4))
        let blocked = try row(["terminal": 3, "busy": true, "activity": "waiting", "preview": "Run it?", "time_ms": milliseconds(7),
                               "reply_ms": milliseconds(6)])
        XCTAssertTrue(blocked.needsYou)
        XCTAssertFalse(blocked.busy)
        XCTAssertEqual(blocked.replied.map(ChatConversations.milliseconds), milliseconds(6))
    }

    /// A conversation first seen now whose newest message came after the phone last heard from the host is unread (it
    /// arrived while the phone was away); one that had said nothing yet makes its first result unread.
    func testResultsWhileAwayAndFirstResultsAreUnread() async throws {
        let source = Source()
        source.set(3, summary(record: 10))
        source.set(5, summary(record: -10))
        let conversations = list(source)
        conversations.restore(host: host, summaries: [:], heard: now)
        conversations.update(snapshot(try topology()))
        try await TestSupport.eventually { conversations.conversations.count == 2 && !conversations.conversations[0].stale }
        XCTAssertEqual(conversations.dot(host: host, terminal: 3), .unread, "Written after the phone last heard from the host")
        XCTAssertNil(conversations.dot(host: host, terminal: 5), "Older than that: the baseline")

        let fresh = Source()
        fresh.set(3, ChatConversationSummary(busy: true))
        let later = list(fresh)
        later.update(snapshot(try topology(agents: [3: "conv-new"])))
        try await TestSupport.eventually { fresh.calls == 1 }
        fresh.set(3, summary(record: 1))
        await later.refresh(host: host)
        XCTAssertEqual(later.dot(host: host, terminal: 3), .unread, "A new conversation's first result is news")
    }

    /// A busy row with no open thread says what the agent wrote in this turn (`workingNote`): the host's newest message
    /// once it is newer than the turn's start as the list saw it, never the previous turn's answer; the time counts
    /// from that start only when the list saw the row idle first.
    func testABusyRowsNoteIsWhatItWroteInThisTurn() async throws {
        let source = Source()
        source.set(3, summary(record: 1, preview: "Done: the guard is in."))
        let conversations = list(source)
        conversations.update(snapshot(try topology(agents: [3: "conv-e2e"])))
        try await TestSupport.eventually { conversations.conversations.first.map { !$0.stale } == true }
        XCTAssertNil(conversations.conversations[0].workingNote)

        // The next turn begins: the newest record is the prompt; the preview is still the last turn's answer.
        var begun = summary(busy: true, record: 5, finished: false, preview: "Done: the guard is in.")
        begun.reply = now.addingTimeInterval(1)
        source.set(3, begun)
        await conversations.refresh(host: host)
        var row = try XCTUnwrap(conversations.conversations.first)
        XCTAssertNil(row.workingNote, "the previous turn's answer is no progress")
        XCTAssertEqual(row.workingSince, now.addingTimeInterval(5), "seen idle first: the turn's start")
        XCTAssertEqual(MobileComposition.status(row, session: nil, detail: false), TabsStatus(text: "working", since: now.addingTimeInterval(5)))

        // It writes: a message newer than the start.
        var wrote = summary(busy: true, record: 9, finished: false, preview: "**Tests pass**, now updating the docs.\n\nMore.")
        wrote.reply = now.addingTimeInterval(8)
        source.set(3, wrote)
        await conversations.refresh(host: host)
        row = try XCTUnwrap(conversations.conversations.first)
        XCTAssertEqual(row.workingNote, "Tests pass, now updating the docs.", "its first line")
        XCTAssertEqual(MobileComposition.status(row, session: nil, detail: false)?.note, row.workingNote)

        // A row first seen busy: no start to count from, and only what it writes after it was seen.
        let fresh = Source()
        var busy = summary(busy: true, record: 4, finished: false, preview: "Old answer")
        busy.reply = now.addingTimeInterval(2)
        fresh.set(5, busy)
        let other = list(fresh)
        other.update(snapshot(try topology(agents: [5: "conv-app"])))
        try await TestSupport.eventually { other.conversations.first.map { !$0.stale } == true }
        XCTAssertNil(other.conversations[0].workingSince)
        XCTAssertNil(other.conversations[0].workingNote)
    }

    /// An agent that has written nothing yet sorts by when it appeared: at the top, not under every other row.
    func testANewAgentWithNothingWrittenSortsByWhenItAppeared() async throws {
        let source = Source()
        source.set(3, summary(record: -3600))
        let conversations = list(source)
        conversations.update(snapshot(try topology(agents: [3: "conv-e2e"])))
        try await TestSupport.eventually { source.calls == 1 }
        conversations.update(snapshot(try topology()))
        try await TestSupport.eventually { conversations.conversations.count == 2 }
        XCTAssertEqual(conversations.conversations.map(\.terminal), [5, 3])
    }

    /// Threads not on screen beyond the last few shown give their sessions up; their rows read `chat.list` again.
    func testThreadsNoLongerShownReleaseTheirSessions() async throws {
        let source = Source()
        source.set(3, summary(record: 1))
        helper.script { request in request.method == "chat.open" ? .open : .result([Any]()) }
        let conversations = list(source)
        conversations.keptSessions = 0
        conversations.update(snapshot(try topology(agents: [3: "conv-e2e"])))
        try await TestSupport.eventually { source.calls == 1 }
        let key = ChatConversationKey(host: host, node: "tmux:s:$0:%3")
        _ = conversations.session(for: key)
        conversations.shown(key)
        conversations.hidden(key)
        XCTAssertNil(conversations.sessions[key])
        try await TestSupport.eventually { source.calls >= 2 }
    }

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

    /// An older `chat-models.json` (no last agent, an agent without menus, a choice without a label, a last model and
    /// effort) keeps its menus; the last model goes (a new chat starts on the agent's own default).
    func testModelMemoryOfAnOlderShapeKeepsItsChoices() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("chat-models.json")
        try Data(#"{"agents":{"claude":{"model":"opus","efforts":{"opus":[{"id":"high"}]}},"codex":{"models":[{"id":"gpt"},{"label":"no id"}]}}}"#.utf8)
            .write(to: url)
        let memory = ChatModelMemory(url: url)
        XCTAssertNil(memory.lastAgent)
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
                       "Done. Tests green.", "Code is left out of a line that says something else")
        XCTAssertEqual(ChatConversationSummary.preview("```sh\ncargo test\n```"), "cargo test", "Unless the code is all there is")
    }

    /// Previews read as text: the Agents rows and Spaces lines showed `**bold**`, backticks and a table's pipes as typed.
    func testPreviewsDropTheirMarkdown() {
        XCTAssertEqual(ChatConversationSummary.preview("Done. Retries are keyed on the Stripe **event id**, see `idempotency_keys`."),
                       "Done. Retries are keyed on the Stripe event id, see idempotency_keys.")
        XCTAssertEqual(ChatConversationSummary.preview("## Plan\n- Add a **theme** column\n1. Read [the docs](https://example.com)\n> Quoted"),
                       "Plan Add a theme column Read the docs Quoted")
        XCTAssertEqual(ChatConversationSummary.preview("**run-0412 vs run-0411**\n\n| suite | metric |\n|---|---|\n| held-out | `val_loss` |"),
                       "run-0412 vs run-0411 suite · metric held-out · val_loss")
        XCTAssertEqual(ChatConversationSummary.preview("snake_case_names and a_b stay"), "snake_case_names and a_b stay",
                       "Intraword underscores are not emphasis")
    }

    // MARK: Opening ahead of the thread

    private func k3(_ host: UUID) -> ChatConversationKey { ChatConversationKey(host: host, node: "tmux:s:$0:%3") }
    private func k5(_ host: UUID) -> ChatConversationKey { ChatConversationKey(host: host, node: "tmux:s:$0:%5") }

    /// A list over the scripted helper whose `chat.open` stays open, terminals counted as attached once retained.
    private func opening(_ source: Source = Source(), presence: ChatTerminalPresenceStub = ChatTerminalPresenceStub(),
                         markers: ChatMarkers = ChatMarkers(store: ChatMarkerMemoryStore()),
                         outbox: ChatOutbox = ChatOutbox(store: ChatOutboxMemoryStore())) -> ChatConversations {
        helper.script { request in
            switch request.method {
            case "chat.open": .open
            case "queue.list": .result([Any]())
            default: .result(NSNull())
            }
        }
        return ChatConversations(source: source, presence: presence, markers: markers, outbox: outbox,
                                 drafts: ChatDraftRepository(store: ChatDraftMemoryStore()))
    }

    /// The `count`th `chat.open` subscription of `terminal`, once it is on its way.
    private func subscription(_ terminal: UInt64, count: Int = 1) async throws -> UInt64 {
        let opens = { self.helper.requests("chat.open").filter { $0.params["terminal"] as? UInt64 == terminal } }
        try await TestSupport.eventually { opens().count >= count }
        return try XCTUnwrap(opens().dropFirst(count - 1).first, "chat.open \(count) of terminal \(terminal)").id
    }

    /// `chat.open`'s history on that subscription, as the helper answers for the fixture topology's binding.
    private func answer(_ id: UInt64, terminal: UInt64, session: String, records: [[String: Any]],
                        state: [String: Any] = ChatFixture.state(busy: false)) {
        var binding = ChatFixture.binding
        binding["session"] = session; binding["pid"] = 100; binding["start"] = [1, 2]
        helper.notify(id, "chat.history", ChatFixture.history(terminal: terminal, session: session, records: records, state: state,
                                                              binding: binding))
    }

    /// A shown thread let go keeps what it read; the conversation's next session shows it before its `chat.open`
    /// answers. A kept transcript of a conversation the pane no longer runs (/clear, a new agent) is dropped instead.
    func testAReleasedThreadsTranscriptOpensItsNextSessionAtOnce() async throws {
        let conversations = opening()
        conversations.keptSessions = 0
        let conversation = "00000000-0000-4000-8000-000000000201"
        conversations.update(snapshot(try topology(agents: [3: conversation])))
        let key = k3(host)
        let first = conversations.session(for: key)
        answer(try await subscription(3), terminal: 3, session: conversation, records: try ChatFixture.records("claude-thread"))
        try await TestSupport.eventually { first.phase == .verified && !first.loadingHistory }
        let rows = first.transcript.rows
        conversations.shown(key)
        conversations.hidden(key)
        XCTAssertNil(conversations.sessions[key])
        XCTAssertEqual(conversations.transcripts.keys, [key])
        try await TestSupport.eventually { self.helper.cancellations.contains(self.helper.requests("chat.open")[0].id) }

        let next = conversations.session(for: key)
        XCTAssertFalse(next === first)
        XCTAssertEqual(next.transcript.rows.map(\.id), rows.map(\.id), "its first frame")
        XCTAssertTrue(next.seeded)
        XCTAssertTrue(conversations.transcripts.keys.isEmpty, "the session holds it now")
        answer(try await subscription(3, count: 2), terminal: 3, session: conversation, records: try ChatFixture.records("claude-thread"))
        try await TestSupport.eventually { next.phase == .verified && !next.seeded }
        XCTAssertEqual(next.transcript.rows.map(\.id), rows.map(\.id))

        conversations.shown(key)
        conversations.hidden(key)
        XCTAssertEqual(conversations.transcripts.keys, [key])
        conversations.update(snapshot(try topology(agents: [3: "00000000-0000-4000-8000-000000000301"])))
        let cleared = conversations.session(for: key)
        XCTAssertTrue(cleared.transcript.isEmpty, "another conversation's rows never show")
        XCTAssertFalse(cleared.seeded)
        XCTAssertTrue(conversations.transcripts.keys.isEmpty, "and are not kept")
    }

    /// Kept transcripts are bounded by their estimated bytes, the least recently kept going first; one larger than the
    /// whole store is not kept; a host's go with it.
    func testKeptTranscriptsAreBoundedByBytesOldestFirst() throws {
        let store = ChatTranscriptStore(limit: 1_000)
        let other = UUID()
        func kept(_ bytes: Int) -> MobileChatSession.Kept {
            .init(transcript: MobileTranscript(), conversation: "conv", earlier: nil, readingPosition: nil, bytes: bytes)
        }
        let a = ChatConversationKey(host: host, node: "a"), b = ChatConversationKey(host: host, node: "b")
        let c = ChatConversationKey(host: other, node: "c"), d = ChatConversationKey(host: host, node: "d")
        store.keep(kept(400), for: a)
        store.keep(kept(400), for: b)
        XCTAssertEqual(store.bytes, 800)
        store.keep(kept(400), for: c)
        XCTAssertEqual(store.keys, [b, c], "the oldest went")
        XCTAssertEqual(store.bytes, 800)
        store.keep(kept(300), for: b)
        store.keep(kept(400), for: a)
        XCTAssertEqual(store.keys, [b, a], "b kept again is newer than c")
        XCTAssertEqual(store.bytes, 700)
        store.keep(kept(1_001), for: d)
        XCTAssertEqual(store.keys, [b, a], "too large for the store")
        XCTAssertNotNil(store.take(b))
        XCTAssertNil(store.take(b), "taken out")
        XCTAssertEqual(store.bytes, 400)
        store.keep(kept(100), for: c)
        store.remove(host: host)
        XCTAssertEqual(store.keys, [c], "another host's stays")
        store.removeAll()
        XCTAssertEqual(store.bytes, 0)

        // The estimate follows what the transcript holds: each text about once (an item shares its record's strings).
        var transcript = MobileTranscript()
        let empty = transcript.estimatedBytes
        let record = ChatFixture.record("r", "assistant", turn: "t", text: String(repeating: "x", count: 100_000))
        transcript.apply([try JSONDecoder().decode(HelperChat.Record.self, from: JSONSerialization.data(withJSONObject: record))],
                         historical: true)
        XCTAssertGreaterThan(transcript.estimatedBytes - empty, 100_000)
        XCTAssertLessThan(transcript.estimatedBytes - empty, 200_000)
    }

    /// Removing a host ends its sessions and forgets what they read; another host's kept transcripts stay.
    func testRemovingAHostForgetsItsKeptTranscripts() async throws {
        let conversations = opening()
        let conversation = "00000000-0000-4000-8000-000000000201"
        conversations.update(snapshot(try topology(agents: [3: conversation])))
        let key = k3(host)
        let session = conversations.session(for: key)
        answer(try await subscription(3), terminal: 3, session: conversation, records: try ChatFixture.records("claude-thread"))
        try await TestSupport.eventually { session.phase == .verified && !session.loadingHistory }
        let elsewhere = ChatConversationKey(host: UUID(), node: "tmux:s:$1:%1")
        conversations.transcripts.keep(try XCTUnwrap(session.kept()), for: elsewhere)
        conversations.remove(host: host)
        XCTAssertNil(conversations.sessions[key])
        XCTAssertEqual(conversations.transcripts.keys, [elsewhere], "the released session's is gone with its host")
    }

    /// The Agents list's first rows open ahead of a tap, in its order and one at a time, without counting as shown: no
    /// terminal attached, the rows stay `chat.list`'s (no state of the session's, no seen marker moved, a new result
    /// still arrives as one, for the banners), and nothing else sees the session.
    func testTheListsFirstRowsWarmOneAtATimeWithoutBeingShown() async throws {
        let source = Source()
        source.set(3, summary(record: 1))
        source.set(5, summary(record: 2))
        let presence = ChatTerminalPresenceStub()
        let markers = ChatMarkers(store: ChatMarkerMemoryStore())
        let conversations = opening(source, presence: presence, markers: markers)
        conversations.update(snapshot(try topology()))
        try await TestSupport.eventually {
            conversations.conversation(self.k3(self.host))?.summary.preview != nil
                && conversations.conversation(self.k5(self.host))?.summary.preview != nil
        }
        let seen = markers.document
        var arrivals: [ChatConversationKey] = []
        conversations.arrived = { _, current in if let current { arrivals.append(current.key) } }

        conversations.agentsListShown([k5(host), k3(host)])
        // Opening is decided in the call: the second row has no session while the first is opening.
        XCTAssertEqual(Set(conversations.warm.keys), [k5(host)], "one at a time, the list's first first")
        XCTAssertEqual(conversations.warm[k5(host)]?.phase, .opening)
        let five = try await subscription(5)
        XCTAssertNil(conversations.warm[k3(host)])
        answer(five, terminal: 5, session: "conv-app", records: try ChatFixture.records("claude-thread"),
               state: ChatFixture.state(busy: true))
        let three = try await subscription(3)
        answer(three, terminal: 3, session: "conv-e2e", records: try ChatFixture.records("claude-thread"))
        try await TestSupport.eventually { conversations.warm.values.allSatisfy { $0.phase == .verified } && conversations.warm.count == 2 }

        XCTAssertTrue(conversations.sessions.isEmpty, "no one else sees them")
        XCTAssertTrue(presence.retained.isEmpty, "no terminal attached")
        await conversations.refresh(host: host)
        conversations.rebuild()
        XCTAssertEqual(conversations.conversation(k5(host))?.summary.busy, false, "the row is chat.list's, not the session's")
        XCTAssertNotEqual(conversations.dot(k5(host)), .working)
        XCTAssertEqual(markers.document, seen, "nothing marked seen")
        source.set(5, summary(record: 9))
        await conversations.refresh(host: host)
        XCTAssertEqual(arrivals, [k5(host)], "a new result still arrives (its banner)")
        XCTAssertTrue(conversations.conversation(k5(host))?.unread == true)
    }

    /// A warm session outlives its row's place among the first rows, or the list on screen, by `prewarmLinger`, then
    /// goes as any session does (what it read kept); in the background it goes at once, and comes back seeded.
    func testWarmSessionsFollowTheListAndGoAfterItLeaves() async throws {
        let conversations = opening()
        let clock = LifecycleClock()
        conversations.now = { clock.now }
        conversations.update(snapshot(try topology()))
        conversations.agentsListShown([k5(host)])
        let five = try await subscription(5)
        answer(five, terminal: 5, session: "conv-app", records: try ChatFixture.records("claude-thread"))
        try await TestSupport.eventually { conversations.warm[self.k5(self.host)]?.phase == .verified }

        conversations.agentsListShown([k3(host)])
        XCTAssertNotNil(conversations.warm[k5(host)], "cooling, not gone")
        let three = try await subscription(3)
        answer(three, terminal: 3, session: "conv-e2e", records: try ChatFixture.records("claude-thread"))
        try await TestSupport.eventually { conversations.warm[self.k3(self.host)]?.phase == .verified }
        clock.advance(by: 9)
        conversations.tick()
        XCTAssertNotNil(conversations.warm[k5(host)], "9 s: still cooling")
        clock.advance(by: 2)
        conversations.tick()
        XCTAssertNil(conversations.warm[k5(host)], "past the linger")
        try await TestSupport.eventually { self.helper.cancellations.contains(five) }
        XCTAssertTrue(conversations.transcripts.keys.contains(k5(host)), "what it read is kept")
        XCTAssertEqual(conversations.warm[k3(host)]?.phase, .verified)

        // The released row comes back seeded from what it read; the other, back among the first rows before its linger
        // ended, stays warm: nothing opens it again.
        conversations.agentsListShown([k5(host)])
        conversations.agentsListShown([k3(host), k5(host)])
        try await TestSupport.eventually { conversations.warm[self.k5(self.host)] != nil }
        XCTAssertTrue(conversations.warm[k5(host)]?.seeded == true, "seeded from what it read")
        XCTAssertEqual(helper.requests("chat.open").filter { $0.params["terminal"] as? UInt64 == 3 }.count, 1)
        let reopened = try await subscription(5, count: 2)
        answer(reopened, terminal: 5, session: "conv-app", records: try ChatFixture.records("claude-thread"))
        try await TestSupport.eventually { conversations.warm.values.allSatisfy { $0.phase == .verified } }
        let opens = helper.requests("chat.open").count

        conversations.agentsListHidden()
        clock.advance(by: 5)
        conversations.tick()
        XCTAssertEqual(conversations.warm.count, 2, "the list left a moment ago")
        clock.advance(by: 6)
        conversations.tick()
        XCTAssertTrue(conversations.warm.isEmpty)

        conversations.agentsListShown([k3(host)])
        try await TestSupport.eventually { conversations.warm[self.k3(self.host)] != nil }
        conversations.foreground = false
        XCTAssertTrue(conversations.warm.isEmpty, "the background lets them go at once")
        conversations.foreground = true
        XCTAssertNotNil(conversations.warm[k3(host)], "back in the foreground with the list still shown")
        // Both opens of k3 after the list came back reach the helper (its transport reads on its own thread).
        try await TestSupport.eventually { self.helper.requests("chat.open").count >= opens + 2 }
    }

    /// Rows on a host not reached, and rows with messages in the device's queue (a warm session would send them), are
    /// not warmed; the host's connection warms its rows.
    func testWarmingSkipsHostsNotReachedAndRowsWithQueuedMessages() async throws {
        let outbox = ChatOutbox(store: ChatOutboxMemoryStore())
        let conversations = opening(outbox: outbox)
        XCTAssertTrue(outbox.add(ChatOutboxItem(key: k3(host), conversation: "conv-e2e", text: "Run the suite")))
        conversations.update(snapshot(try topology(), link: .reconnecting(attempt: 1, since: Date())))
        conversations.agentsListShown([k3(host), k5(host)])
        XCTAssertTrue(conversations.warm.isEmpty)
        conversations.update(snapshot(try topology()))
        let five = try await subscription(5)
        answer(five, terminal: 5, session: "conv-app", records: [])
        try await TestSupport.eventually { conversations.warm[self.k5(self.host)]?.phase == .verified }
        // Its verification asked the queue again, in the same turn: k3 would be warm now.
        XCTAssertNil(conversations.warm[k3(host)], "its queued message waits for its thread")
        XCTAssertFalse(helper.requests("chat.open").contains { $0.params["terminal"] as? UInt64 == 3 })
    }

    /// A tap takes the warm session over: verified, its rows in the first frame, its terminal attached as the thread
    /// shows; the row follows it from then on.
    func testATapTakesOverAWarmSessionAndAttachesItsTerminalAsItShows() async throws {
        let presence = ChatTerminalPresenceStub()
        let conversations = opening(presence: presence)
        conversations.update(snapshot(try topology()))
        conversations.agentsListShown([k5(host)])
        answer(try await subscription(5), terminal: 5, session: "conv-app", records: try ChatFixture.records("claude-thread"))
        try await TestSupport.eventually { conversations.warm[self.k5(self.host)]?.phase == .verified }
        let warm = try XCTUnwrap(conversations.warm[k5(host)])
        try await TestSupport.eventually { !conversations.rebuildPending }
        conversations.opening(k5(host))
        XCTAssertTrue(conversations.sessions[k5(host)] === warm)
        XCTAssertFalse(conversations.rebuildPending, "the row's rebuild waits for the first frame, out of the push")
        XCTAssertTrue(conversations.warm.isEmpty)
        XCTAssertFalse(warm.holding, "verified already: nothing to hold")
        XCTAssertTrue(presence.retained.isEmpty, "not on screen yet")
        XCTAssertTrue(conversations.session(for: k5(host)) === warm, "the screen's own ask keeps it waiting")
        XCTAssertTrue(presence.retained.isEmpty)
        conversations.agentsListHidden()
        conversations.shown(k5(host))
        // Its appearance may come before the push's layout: whatever it scheduled has run now, and nothing attached.
        await mainQueueTurn()
        XCTAssertTrue(presence.retained.isEmpty, "not inside the push")
        XCTAssertTrue(conversations.session(for: k5(host)) === warm)
        XCTAssertTrue(presence.retained.isEmpty, "nor when the screen asks for its session again")
        warm.firstFrameShown()
        XCTAssertEqual(presence.retained[k5(host)], 5, "after the first frame")
        XCTAssertTrue(conversations.rebuildPending, "and the row follows it from then")
        XCTAssertTrue(conversations.pending.isEmpty)
        XCTAssertEqual(helper.requests("chat.open").count, 1, "nothing opened again")
    }

    /// The thread the user opened comes first: while it is being pushed or on screen and still opening, the list (an
    /// iPad's sidebar beside it) warms nothing; once it is open, the list's first rows warm.
    func testNothingWarmsWhileTheUsersThreadOpens() async throws {
        let conversations = opening()
        conversations.holdLimit = .seconds(3600)
        conversations.update(snapshot(try topology()))
        conversations.opening(k3(host))
        conversations.agentsListShown([k3(host), k5(host)])
        XCTAssertTrue(conversations.warm.isEmpty, "the user's thread is opening")
        answer(try await subscription(3), terminal: 3, session: "conv-e2e", records: try ChatFixture.records("claude-thread"))
        try await TestSupport.eventually { conversations.sessions[self.k3(self.host)]?.heldUpdates == 1 }
        XCTAssertTrue(conversations.warm.isEmpty, "held for its first frame, still opening")
        conversations.shown(k3(host))
        conversations.sessions[k3(host)]?.firstFrameShown()
        try await TestSupport.eventually { conversations.sessions[self.k3(self.host)]?.phase == .verified }
        _ = try await subscription(5)
        XCTAssertNotNil(conversations.warm[k5(host)])
        XCTAssertNil(conversations.warm[k3(host)], "open already")
    }

    /// A tap's session is kept until its thread shows, and what the helper answers meanwhile waits for the thread's
    /// first frame; a push that never shows it makes it an ordinary session, trimmed as one.
    func testATappedThreadIsKeptUntilShownAndAnAbandonedOneGoes() async throws {
        let conversations = opening()
        conversations.keptSessions = 0
        conversations.holdLimit = .seconds(3600)
        conversations.update(snapshot(try topology()))
        conversations.opening(k3(host))
        let session = try XCTUnwrap(conversations.sessions[k3(host)])
        XCTAssertTrue(session.holding)
        XCTAssertEqual(session.phase, .opening)
        answer(try await subscription(3), terminal: 3, session: "conv-e2e", records: try ChatFixture.records("claude-thread"))
        try await TestSupport.eventually { session.heldUpdates == 1 }
        XCTAssertEqual(session.phase, .opening, "held for the first frame")
        conversations.trimSessions()
        XCTAssertTrue(conversations.sessions[k3(host)] === session, "never trimmed before it shows")
        conversations.shown(k3(host))
        // Its appearance can come before its view is in a window: what it scheduled has run, and the hold stands.
        await mainQueueTurn()
        XCTAssertTrue(session.holding, "until the first frame is committed")
        session.firstFrameShown()
        XCTAssertFalse(session.holding)
        XCTAssertEqual(session.phase, .verified)

        conversations.opening(k5(host))
        let abandoned = try XCTUnwrap(conversations.sessions[k5(host)])
        let id = try await subscription(5)
        conversations.abandoned(k5(host))
        XCTAssertNil(conversations.sessions[k5(host)], "trimmed as any session not shown")
        XCTAssertFalse(abandoned.holding)
        try await TestSupport.eventually { self.helper.cancellations.contains(id) }
        XCTAssertTrue(conversations.pending.isEmpty)
        XCTAssertNotNil(conversations.sessions[k3(host)], "the shown one stays")
    }

    /// A thread shown without its view entering a window (no first frame reported) still gets its held answers and
    /// its deferred terminal, after `holdLimit` from its showing.
    func testAThreadShownWithoutItsFirstFrameGetsItAfterTheLimit() async throws {
        let presence = ChatTerminalPresenceStub()
        let conversations = opening(presence: presence)
        conversations.holdLimit = .milliseconds(100)
        conversations.update(snapshot(try topology()))
        conversations.agentsListShown([k5(host)])
        answer(try await subscription(5), terminal: 5, session: "conv-app", records: try ChatFixture.records("claude-thread"))
        try await TestSupport.eventually { conversations.warm[self.k5(self.host)]?.phase == .verified }
        conversations.opening(k5(host))
        conversations.agentsListHidden()
        conversations.shown(k5(host))
        XCTAssertTrue(presence.retained.isEmpty)
        try await TestSupport.eventually { presence.retained[self.k5(self.host)] == 5 }
    }

    /// A push whose thread never shows (its tab opened on another segment, say) stops protecting its session after
    /// `pendingLimit`: it is trimmed as any other.
    func testAPushWhoseThreadNeverShowsIsLetGoAfterItsLimit() async throws {
        let conversations = opening()
        let clock = LifecycleClock()
        conversations.now = { clock.now }
        conversations.update(snapshot(try topology()))
        conversations.opening(k3(host))
        let id = try await subscription(3)
        clock.advance(by: 4)
        conversations.tick()
        XCTAssertTrue(conversations.pending.contains(k3(host)), "a push takes well under a second, but 4 s are allowed")
        clock.advance(by: 2)
        conversations.tick()
        XCTAssertTrue(conversations.pending.isEmpty)
        XCTAssertNil(conversations.sessions[k3(host)], "trimmed: never shown")
        try await TestSupport.eventually { self.helper.cancellations.contains(id) }
    }

    /// A reconnect (or a pane rebound) while Agents shows does not reopen every warm session at once: they are let go
    /// and warmed again through the queue, one at a time and only once the user's own thread has opened again.
    func testANewConnectionWarmsTheRowsAgainThroughTheQueue() async throws {
        let conversations = opening()
        conversations.update(snapshot(try topology()))
        conversations.agentsListShown([k5(host), k3(host)])
        answer(try await subscription(5), terminal: 5, session: "conv-app", records: try ChatFixture.records("claude-thread"))
        answer(try await subscription(3), terminal: 3, session: "conv-e2e", records: try ChatFixture.records("claude-thread"))
        try await TestSupport.eventually { conversations.warm.count == 2 && conversations.warm.values.allSatisfy { $0.phase == .verified } }

        let other = ScriptedHelper.scripted { request in request.method == "queue.list" ? .result([Any]()) : nil }
        defer { other.close() }
        conversations.update(ChatHostSnapshot(id: host, name: "mba2", link: .connected, client: other.client, topology: try topology()))
        XCTAssertEqual(conversations.warm.count, 1, "one opens again, through the queue")
        XCTAssertTrue(conversations.warm.values.allSatisfy { $0.client === other.client && $0.phase == .opening })
        XCTAssertTrue(conversations.transcripts.keys.contains(k3(host)), "the other waits with what it read")

        // The user's thread first: on screen, it opens again with the next connection, and nothing warms meanwhile.
        conversations.opening(k3(host))
        conversations.shown(k3(host))
        try await TestSupport.eventually { conversations.sessions[self.k3(self.host)]?.phase == .opening }
        let third = ScriptedHelper.scripted { request in request.method == "queue.list" ? .result([Any]()) : nil }
        defer { third.close() }
        conversations.update(ChatHostSnapshot(id: host, name: "mba2", link: .connected, client: third.client, topology: try topology()))
        XCTAssertTrue(conversations.warm.isEmpty, "nothing warms while the user's thread opens")
        XCTAssertEqual(conversations.sessions[k3(host)]?.phase, .opening)
    }

    /// A warm `chat.open` the helper refuses is let go and the queue moves on; a tap on that row opens it afresh instead
    /// of showing the old failure.
    func testAFailedWarmOpenIsLetGoAndATapOpensAfresh() async throws {
        let conversations = opening()
        helper.script { request in
            switch request.method {
            case "chat.open": request.params["terminal"] as? UInt64 == 5 ? .error(code: "busy", message: "Busy.") : .open
            case "queue.list": .result([Any]())
            default: .result(NSNull())
            }
        }
        conversations.update(snapshot(try topology()))
        conversations.agentsListShown([k5(host), k3(host)])
        try await TestSupport.eventually { conversations.warm[self.k5(self.host)] == nil && conversations.warm[self.k3(self.host)] != nil }
        conversations.opening(k5(host))
        let tapped = try XCTUnwrap(conversations.sessions[k5(host)])
        XCTAssertEqual(tapped.phase, .opening, "a fresh open, not the failure")
        _ = try await subscription(5, count: 2)
    }

    /// A warm `chat.open` that never answers is let go after `warmOpenLimit`, its row given up on this connection, and
    /// the queue moves on; one tapped after the limit is let go and the tap opens the row afresh.
    func testAWarmOpenThatNeverAnswersIsLetGoAndATapOpensAfresh() async throws {
        let conversations = opening()
        let clock = LifecycleClock()
        conversations.now = { clock.now }
        conversations.update(snapshot(try topology()))
        conversations.agentsListShown([k5(host), k3(host)])
        _ = try await subscription(5)
        clock.advance(by: 9)
        conversations.tick()
        XCTAssertNotNil(conversations.warm[k5(host)], "still within the limit")
        XCTAssertNil(conversations.warm[k3(host)])
        clock.advance(by: 2)
        conversations.tick()
        XCTAssertNil(conversations.warm[k5(host)], "unanswered past the limit")
        XCTAssertEqual(conversations.warm[k3(host)]?.phase, .opening, "the queue moved on")
        conversations.agentsListShown([k5(host), k3(host)])
        XCTAssertNil(conversations.warm[k5(host)], "given up on this connection")

        // k3 never answers either; tapped after the limit, the tap opens it afresh.
        _ = try await subscription(3)
        let waiting = try XCTUnwrap(conversations.warm[k3(host)])
        clock.advance(by: 11)
        conversations.opening(k3(host))
        let tapped = try XCTUnwrap(conversations.sessions[k3(host)])
        XCTAssertFalse(tapped === waiting)
        XCTAssertEqual(tapped.phase, .opening)
        _ = try await subscription(3, count: 2)
    }

    /// A kept transcript waits while the topology names no conversation for its pane (a new helper's first snapshots,
    /// a provisional binding): only another named conversation drops it.
    func testAKeptTranscriptWaitsWhileThePaneNamesNoConversation() async throws {
        let conversations = opening()
        conversations.keptSessions = 0
        let conversation = "00000000-0000-4000-8000-000000000201"
        conversations.update(snapshot(try topology(agents: [3: conversation])))
        let key = k3(host)
        let first = conversations.session(for: key)
        answer(try await subscription(3), terminal: 3, session: conversation, records: try ChatFixture.records("claude-thread"))
        try await TestSupport.eventually { first.phase == .verified && !first.loadingHistory }
        conversations.shown(key)
        conversations.hidden(key)
        XCTAssertEqual(conversations.transcripts.keys, [key])
        conversations.update(snapshot(try topology(agents: [3: ""])))
        let unnamed = conversations.session(for: key)
        XCTAssertFalse(unnamed.seeded)
        conversations.shown(key)
        conversations.hidden(key)
        XCTAssertEqual(conversations.transcripts.keys, [key], "kept for when the conversation is named again")
        conversations.update(snapshot(try topology(agents: [3: conversation])))
        XCTAssertTrue(conversations.session(for: key).seeded)
    }

    /// The store's estimate counts what a transcript holds: tool output blocks, diffs, a tool's input and the records
    /// nested in it, and the thumbnails merged into sent messages, each about once.
    func testTheByteEstimateCountsWhatTheTranscriptHolds() throws {
        let big = String(repeating: "x", count: 100_000)
        func record(_ extra: [String: Any], kind: String = "tool", id: String = "r") throws -> HelperChat.Record {
            var value = ChatFixture.record(id, kind, turn: "t", text: "", time: 946_719_000_000)
            value.merge(extra) { $1 }
            return try JSONDecoder().decode(HelperChat.Record.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let tool: [String: Any] = ["kind": "shell", "title": "Run", "symbol": "terminal", "summary": "", "input": big,
                                   "language": "sh", "directory": NSNull(), "failed": false, "read": NSNull(),
                                   "search": NSNull(), "shell": NSNull(), "orchestration": false, "patch": false,
                                   "confirmed_result": NSNull(), "additions": 0, "deletions": 0,
                                   "children": [ChatFixture.record("child", "tool", turn: "t", text: big)]]
        let cases: [(String, HelperChat.Record)] = [
            ("blocks", try record(["blocks": [["kind": "code", "language": "text", "text": big, "path": NSNull()]]])),
            ("diffs", try record(["documents": [["path": "/work/a.swift", "kind": NSNull(), "diff": big, "workdir": NSNull()]]])),
            ("tool", try record(["tool": tool])),
        ]
        for (name, heavy) in cases {
            var transcript = MobileTranscript()
            let empty = transcript.estimatedBytes
            transcript.apply([heavy], historical: true)
            let grown = transcript.estimatedBytes - empty
            XCTAssertGreaterThan(grown, 100_000, name)
            XCTAssertLessThan(grown, 260_000, "\(name): about once, not twice or more")
        }
        // A sent message's thumbnail, merged into its row.
        var transcript = MobileTranscript()
        let thumbnail = ChatAttachment(id: "a1", name: "shot.png", kind: .image, size: 2048, path: "/stored/shot.png",
                                       thumbnail: Data(count: 100_000))
        let prompt = try record([:], kind: "user", id: "u")
        let before = transcript.estimatedBytes
        transcript.apply([prompt], historical: false, prepare: { item, _ in
            var item = item
            item.attachments = [thumbnail]
            return item
        })
        XCTAssertGreaterThan(transcript.estimatedBytes - before, 100_000, "thumbnails")
    }
}

/// Runs the main queue once: what was queued on it before has run.
@MainActor private func mainQueueTurn() async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { done.resume() } }
}

/// A clock the lifecycle's deadlines read (`ChatConversations.now`), moved by the test.
private final class LifecycleClock {
    var now = Date(timeIntervalSince1970: 946_719_000)
    func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

