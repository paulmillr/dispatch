import AppKit
import XCTest
@testable import DispatchApp

/// Settings › On launch › Reopen spaces and history saves each tab's chat as the app quits (`SavedChatStore`): what it
/// had loaded, read once at the next launch, read-only until its agent binds again.
@MainActor
final class SavedChatTests: XCTestCase {
    private func turns(_ count: Int, items: Int = 3, text: Int = 40, prefix: String = "turn") -> [ChatTurn] {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        return (0..<count).map { index in
            let id = "\(prefix)-\(index)"
            let shown = (0..<items).map { item -> ChatItem in
                let kind: ChatItem.Kind = item == 0 ? .user : item == items - 1 ? .assistant : .tool
                var value = ChatItem(id: "\(id)-item-\(item)", kind: kind,
                                     text: String(repeating: "Retries use the event ID. ", count: max(1, text / 26)))
                if kind == .tool { value.title = "exec_command"; value.output = "ok"; value.completed = true; value.exitCode = 0 }
                return value
            }
            var turn = ChatTurn(id: id, started: start.addingTimeInterval(Double(index) * 60), items: shown)
            turn.ended = turn.started.addingTimeInterval(30)
            return turn
        }
    }

    private func chat(turns: [ChatTurn], shown: Bool = true, multiplexed: Bool = false) -> SavedChat {
        var index = ChatTranscript.Index()
        for turn in turns {
            for item in turn.items {
                index.itemDates[.init(turn: turn.id, item: item.id)] = turn.started
                index.seen.insert("record:" + item.id)
            }
        }
        return SavedChat(conversation: "conversation-1", agent: "claude", agentTitle: "Claude Code", host: "build-box",
                         title: "Fix retries", transcriptTitle: nil, model: "opus", effort: "high", shown: shown,
                         multiplexed: multiplexed, turns: turns, index: index)
    }

    private func directory() -> URL {
        let root = System.temporary.appendingPathComponent(System.uuid().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// The file holds each chat as it was, is read once, and is private and excluded from backups; one too old, of
    /// another version or damaged gives nothing.
    func testChatsRoundTripOnceAndOnlyWhileFresh() throws {
        let store = SavedChatStore(url: directory().appendingPathComponent("saved-chats.json"))
        let first = System.uuid(), second = System.uuid()
        let saved = [(first, chat(turns: turns(5))), (second, chat(turns: turns(2, prefix: "other"), multiplexed: true))]
        try store.save(saved.map { (id: $0.0, chat: $0.1) })
        XCTAssertEqual(try store.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let read = store.take()
        XCTAssertEqual(Set(read.keys), [first, second])
        XCTAssertEqual(read[first]?.turns.map(\.id), saved[0].1.turns.map(\.id))
        XCTAssertEqual(read[first]?.turns.last?.items, saved[0].1.turns.last?.items)
        XCTAssertEqual(read[first]?.turns.first?.ended, saved[0].1.turns.first?.ended)
        XCTAssertEqual(read[first]?.index.seen, saved[0].1.index.seen)
        XCTAssertEqual(read[first]?.index.itemDates, saved[0].1.index.itemDates)
        XCTAssertEqual(read[second]?.multiplexed, true)
        XCTAssertEqual(read[first]?.conversation, "conversation-1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path), "read once")
        XCTAssertTrue(store.take().isEmpty)

        // Too old, another version, damaged: nothing comes back, and the file goes.
        try store.save([(id: first, chat: chat(turns: turns(1)))])
        var data = try Data(contentsOf: store.url)
        let newline = try XCTUnwrap(data.firstIndex(of: 0x0A))
        var header = try JSONDecoder().decode(SavedChatStore.Header.self, from: data[..<newline])
        header.saved = Date().addingTimeInterval(-TerminalHistoryStore.maxAge - 60)
        data.replaceSubrange(..<newline, with: try JSONEncoder().encode(header))
        try data.write(to: store.url)
        XCTAssertTrue(store.take().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        try System.write(Data("{\"version\":2}\n".utf8), to: store.url, permissions: 0o600)
        XCTAssertTrue(store.take().isEmpty)
        try store.save([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path), "nothing to save removes the file")
    }

    /// A chat larger than a tab's share keeps its newest turns, and forgets the rest as seen, so a live read brings
    /// them back; past the total, later chats are left out.
    func testLargeChatsKeepTheirNewestTurns() throws {
        let store = SavedChatStore(url: directory().appendingPathComponent("saved-chats.json"))
        let long = chat(turns: turns(64, text: 400))
        let size = try JSONEncoder().encode(long).count
        let id = System.uuid(), other = System.uuid()
        try store.save([(id: id, chat: long), (id: other, chat: long)],
                       limits: .init(tab: size / 3, total: size / 2))
        let read = store.take()
        XCTAssertNil(read[other], "past the total")
        let kept = try XCTUnwrap(read[id])
        XCTAssertLessThan(kept.turns.count, 64)
        XCTAssertEqual(kept.turns.last?.id, "turn-63", "the newest turns stay")
        let dropped = Set(long.turns.map(\.id)).subtracting(kept.turns.map(\.id))
        XCTAssertFalse(dropped.isEmpty)
        XCTAssertTrue(kept.index.itemDates.keys.allSatisfy { !dropped.contains($0.turn) })
        XCTAssertFalse(kept.index.seen.contains("record:turn-0-item-0"), "a dropped turn's records are not seen")
        XCTAssertTrue(kept.index.seen.contains("record:turn-63-item-0"))
    }

    /// A tab whose agent ended with the app keeps the chat as a retained conversation (its terminal shows); a
    /// multiplexer's tab, whose agent lives on, shows the chat again. Either way nothing can be sent until an agent
    /// binds, and a session that already bound keeps its own.
    func testRestoredChatIsRetainedUntilItsAgentBinds() throws {
        let coordinator = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { coordinator.stop() }
        let plain = System.uuid(), multiplexed = System.uuid(), bound = System.uuid()
        coordinator.savedChats = [plain: chat(turns: turns(3)), multiplexed: chat(turns: turns(3), multiplexed: true),
                                  bound: chat(turns: turns(3))]
        let live = coordinator.session(for: bound)
        live.sessionID = "live"
        coordinator.restoreSaved(present: [plain, multiplexed, bound, System.uuid()])
        XCTAssertTrue(coordinator.savedChats.isEmpty)
        let ended = try XCTUnwrap(coordinator.sessions[plain])
        XCTAssertEqual(ended.turns.map(\.id), ["turn-0", "turn-1", "turn-2"])
        XCTAssertEqual(ended.sessionID, "conversation-1")
        XCTAssertEqual(ended.agentTitle, "Claude Code")
        XCTAssertEqual(ended.conversationTitle, "Fix retries")
        XCTAssertEqual(ended.model, "opus")
        XCTAssertTrue(ended.agentExited)
        XCTAssertFalse(ended.showChat, "its terminal shows; the transcript is in the mode switch's menu")
        XCTAssertFalse(coordinator.chatLeads(ended))
        XCTAssertFalse(coordinator.inputReady(ended), "nothing is sent without an agent")
        let back = try XCTUnwrap(coordinator.sessions[multiplexed])
        XCTAssertFalse(back.agentExited)
        XCTAssertTrue(back.showChat)
        XCTAssertFalse(coordinator.inputReady(back))
        XCTAssertTrue(coordinator.chatAvailabilityHint(back).contains("sending paused"))
        XCTAssertEqual(live.sessionID, "live")
        XCTAssertTrue(live.turns.isEmpty, "a bound session keeps its own")

        // The agent's read of the same conversation merges: nothing shows twice.
        let records = back.turns.flatMap { turn in turn.items.map {
            ChatRecord(key: "record:" + $0.id, turnID: turn.id, date: turn.started, action: .item($0))
        } }
        back.mergeHistorical(records)
        XCTAssertEqual(back.turns.map(\.id), ["turn-0", "turn-1", "turn-2"])
        XCTAssertEqual(back.turns.map(\.items.count), [3, 3, 3])
    }

    /// Chats are saved only as the app quits with history on (never mid-session, so never after a crash), and come
    /// back at the next launch on the tab they belong to; turning history off deletes them.
    func testQuitSavesChatsForTheNextLaunchOnly() async throws {
        let runtime = TerminalRuntime.shared, previous = runtime.workspace, previousChat = runtime.chat
        let root = directory()
        let store = HostSessionStore(url: root.appendingPathComponent("host-session.json"))
        let settings = SettingsStore(file: root.appendingPathComponent("settings.json"))
        settings.values.restoreTerminalOutput = true
        let controller = AppDelegate(settings: settings, hostSessionStore: store)
        runtime.workspace = controller.workspace
        runtime.chat = ChatCoordinator(enabled: false, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { runtime.chat.stop(); runtime.chat = previousChat; runtime.workspace = previous; runtime.restoredHistory = [:] }
        controller.workspace.newLocalSpace()
        let tab = try XCTUnwrap(controller.workspace.activeSurfaceID)
        let session = runtime.chat.session(for: tab)
        session.sessionID = "conversation-1"; session.agentID = "claude"; session.helperTitle = "Claude Code"
        for turn in turns(4) {
            for item in turn.items { session.insert(item, turnID: turn.id, at: turn.started) }
        }
        controller.persistHostSession()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.savedChats.url.path), "never saved mid-session")
        var finished = false
        XCTAssertEqual(controller.requestTermination { finished = $0 }, .terminateLater)
        try await TestSupport.eventually { finished }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.savedChats.url.path))

        // The next launch: a new window's workspace and chat.
        let relaunched = AppDelegate(settings: settings, hostSessionStore: store)
        runtime.workspace = relaunched.workspace
        runtime.chat.stop()
        runtime.chat = ChatCoordinator(enabled: false, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        XCTAssertTrue(relaunched.restoreHostSession())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.savedChats.url.path), "read once")
        let restored = try XCTUnwrap(runtime.chat.sessions[tab])
        XCTAssertEqual(restored.turns.map(\.id), ["turn-0", "turn-1", "turn-2", "turn-3"])
        XCTAssertEqual(restored.turns.flatMap(\.items).map(\.text), session.turns.flatMap(\.items).map(\.text))
        XCTAssertEqual(restored.sessionID, "conversation-1")
        XCTAssertTrue(restored.agentExited, "a plain local tab's agent ended with the app")

        // History off: saved chats go, and none are written at the next quit.
        try store.savedChats.save([(id: tab, chat: chat(turns: turns(1)))])
        var preferences = settings.values; preferences.restoreTerminalOutput = false
        try settings.save(preferences)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.savedChats.url.path))
        finished = false
        _ = relaunched.requestTermination { finished = $0 }
        try await TestSupport.eventually { finished }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.savedChats.url.path))
    }

    /// Quitting with many long chats stays quick: they encode in parallel, and read back the same way at launch.
    func testSavingManyLongChatsIsQuick() throws {
        let store = SavedChatStore(url: directory().appendingPathComponent("saved-chats.json"))
        // 24 chats of 400 turns, 6 items of about 1 KB each: about 60 MB of transcript.
        let chats = (0..<24).map { index in (id: System.uuid(), chat: chat(turns: turns(400, items: 6, text: 1000, prefix: "c\(index)"))) }
        let clock = ContinuousClock()
        let saving = clock.measure { try? store.save(chats) }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: store.url.path)[.size] as? Int) ?? 0
        var read: [UUID: SavedChat] = [:]
        let reading = clock.measure { read = store.take() }
        print("Saved chats: \(chats.count) chats, \(bytes / 1_000_000) MB, save \(saving), read \(reading)")
        XCTAssertEqual(read.count, chats.count)
        XCTAssertEqual(read[chats[7].id]?.turns.last?.items.last?.text, chats[7].chat.turns.last?.items.last?.text)
        XCTAssertLessThan(saving, .seconds(2))
        XCTAssertLessThan(reading, .seconds(2))
    }
}
