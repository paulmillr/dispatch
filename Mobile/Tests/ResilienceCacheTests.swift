import XCTest
@testable import DispatchMobile

/// Instant launch from cache: the last-known state of each host is on the device, populates Spaces and Agents before any
/// connection (rows dimmed as stale), and live data reconciles in place without recreating rows or reordering them.
@MainActor
final class ResilienceCacheTests: XCTestCase {
    private func temporaryFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("host-cache.json")
    }

    func testTheCacheIsAPrivateFileThatReadsBack() throws {
        let url = try temporaryFile()
        let host = UUID()
        let cache = HostCache(url: url)
        cache.replace(ResilienceFixture.entry(), for: host)
        cache.flush()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "owner only, as PrivateFile writes")
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

        let read = HostCache(url: url)
        let entry = try XCTUnwrap(read.entry(host))
        XCTAssertEqual(entry.topology, HostFixture.topology())
        XCTAssertEqual(entry.hello?.identity?.os_label, "macOS 26.1")
        XCTAssertEqual(entry.following, "tmux")
        XCTAssertEqual(entry.conversations[ResilienceFixture.billingAgent]?.preview, "Run the migration?")

        read.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(HostCache(url: url).entry(host))
    }

    /// Previews are kept no longer than the list shows; nothing of a transcript beyond them.
    /// An older `host-cache.json` (an entry without versions or a save time, a row without subagents, another host's
    /// entry this build cannot read at all) keeps every readable entry and field.
    func testACacheOfAnOlderShapeKeepsWhatItCanRead() throws {
        let url = try temporaryFile()
        let host = UUID(), other = UUID()
        let file = """
        {"version":1,"hosts":{
          "\(host.uuidString)":{"following":"tmux","multiplexers":[{"mux":1,"name":"tmux"}],
            "conversations":{"tmux:fixture:5":{"busy":true,"preview":"Run the migration?"}},"topology":{"unknown":1}},
          "\(other.uuidString)":["not an entry"]}}
        """
        try Data(file.utf8).write(to: url)
        let cache = HostCache(url: url)
        let entry = try XCTUnwrap(cache.entry(host))
        XCTAssertEqual(entry.following, "tmux")
        XCTAssertEqual(entry.multiplexers.map(\.name), ["tmux"])
        XCTAssertEqual(entry.multiplexers.first?.external, true)
        XCTAssertNil(entry.topology, "another version's topology alone is dropped")
        XCTAssertEqual(entry.conversations["tmux:fixture:5"]?.preview, "Run the migration?")
        XCTAssertEqual(entry.conversations["tmux:fixture:5"]?.subagents, 0)
        XCTAssertEqual(entry.saved, .distantPast)
        XCTAssertNil(cache.entry(other))
    }

    /// A cached hello keeps the features its helper accepted, so the launch's areas know them (`chat.list`, …) before
    /// the helper answers; a hello without features (the Mac's) encodes as before, without the key.
    func testACachedHelloKeepsItsFeatures() throws {
        let url = try temporaryFile()
        let host = UUID()
        let cache = HostCache(url: url)
        cache.replace(ResilienceFixture.entry(), for: host)
        cache.flush()
        XCTAssertEqual(HostCache(url: url).entry(host)?.hello?.features, ["chat.list"])
        var macHello = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ResilienceFixture.hello())) as? [String: Any])
        macHello.removeValue(forKey: "features")
        let decoded = try JSONDecoder().decode(HelperSession.Info.self, from: JSONSerialization.data(withJSONObject: macHello))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertNil(encoded["features"])
    }

    func testOnlyPreviewsAreKept() throws {
        let long = String(repeating: "word ", count: 400)
        let row = HostCacheEntry.Conversation(ChatConversationSummary(preview: long, finished: true))
        XCTAssertEqual(row.preview?.count, HostCacheEntry.Conversation.previewLimit)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        XCTAssertTrue(Set(fields.keys).isSubset(of: ["busy", "subagents", "attention", "preview", "finished", "lastActivity",
                                                     "waiting", "title"]),
                      "a row's state, its preview, title and time: no transcript")
    }

    /// Before any host answers (the first frame), Spaces and Agents show the cached hosts, their spaces and the agents'
    /// previews and times, all marked stale.
    func testLaunchShowsTheCacheBeforeAnyConnection() throws {
        let studio = ResilienceFixture.host("studio")
        let cache = HostCache(url: nil)
        cache.replace(ResilienceFixture.entry(), for: studio.id)
        let hosts = ResilienceFixture.sessions([studio], active: false)
        let app = ResilienceFixture.composition(hosts, cache: cache)

        let session = try XCTUnwrap(hosts.session(studio.id))
        XCTAssertEqual(session.multiplexerLine, "tmux 3.7")
        XCTAssertEqual(session.following, "tmux")
        XCTAssertNil(session.client)
        let workspace = try XCTUnwrap(app.tabs.workspace(studio.id))
        XCTAssertEqual(workspace.spaces.map(\.name), ["docs", "billing"])
        XCTAssertEqual(workspace.host.home, "/Users/alex")
        XCTAssertEqual(workspace.host.state, .offline)
        let rows = app.conversations.conversations
        XCTAssertEqual(rows.map(\.key.node), [ResilienceFixture.docsAgent, ResilienceFixture.billingAgent], "newest first")
        XCTAssertEqual(rows.map(\.summary.preview), ["Docs are rebuilt.", "Run the migration?"])
        XCTAssertTrue(rows.allSatisfy(\.stale))
        XCTAssertEqual(rows.last?.urgency, .waiting, "needs you, as last seen")
    }

    /// The live data replaces the cached in place: the tabs keep their objects (no row is recreated), the order holds,
    /// and the stale mark goes.
    func testLiveDataReconcilesInPlace() async throws {
        let studio = ResilienceFixture.host("studio")
        let cache = HostCache(url: nil)
        cache.replace(ResilienceFixture.entry(), for: studio.id)
        let live = ResilienceFixture.topology(backend: 9)
        let driver = ScriptedHostSessionDriver { _ in
            [.event(.link(.connecting)), .sleep(.milliseconds(50)),
             .ready(hello: ResilienceFixture.hello(), multiplexers: HostFixture.multiplexers(["tmux"]), versions: ["tmux": "3.7"],
                    topology: live), .hold]
        }
        let hosts = ResilienceFixture.sessions([studio], driver: driver)
        let app = ResilienceFixture.composition(hosts, cache: cache)
        let workspace = try XCTUnwrap(app.tabs.workspace(studio.id))
        let before = workspace.tabs.map(ObjectIdentifier.init)
        let spaces = workspace.spaces.map(ObjectIdentifier.init)
        XCTAssertEqual(before.count, 3)
        try await TestSupport.eventually { workspace.host.state == .connected }
        XCTAssertEqual(workspace.tabs.map(ObjectIdentifier.init), before, "the same rows, now live")
        XCTAssertEqual(workspace.spaces.map(ObjectIdentifier.init), spaces)
        XCTAssertEqual(workspace.spaces.first?.backend, 9)
        XCTAssertEqual(cache.entry(studio.id)?.topology, live, "the live snapshot is cached")
    }

    /// Agents' rows keep their order and identity when the live summaries arrive; the stale mark goes per row.
    func testAgentsRowsReconcile() async throws {
        let host = UUID()
        let helper = ScriptedHelper.scripted { _ in nil }
        let conversations = ChatConversations(source: FixedSummaries(), list: FixedSummaries(),
                                              markers: ChatMarkers(store: ChatMarkerMemoryStore()),
                                              outbox: ChatOutbox(store: ChatOutboxMemoryStore()),
                                              drafts: ChatDraftRepository(store: ChatDraftMemoryStore()))
        conversations.restore(host: host, summaries: ResilienceFixture.entry().conversations.mapValues(\.summary))
        conversations.update(ChatHostSnapshot(id: host, name: "studio", link: .connecting, topology: HostFixture.topology()))
        XCTAssertEqual(conversations.conversations.map(\.key.node), [ResilienceFixture.docsAgent, ResilienceFixture.billingAgent])
        XCTAssertTrue(conversations.conversations.allSatisfy(\.stale))
        conversations.update(ChatHostSnapshot(id: host, name: "studio", link: .connected, client: helper.client,
                                              topology: ResilienceFixture.topology(backend: 9), features: ["chat.list"]))
        try await TestSupport.eventually { !conversations.conversations.contains(where: \.stale) }
        XCTAssertEqual(conversations.conversations.map(\.key.node), [ResilienceFixture.docsAgent, ResilienceFixture.billingAgent])
        XCTAssertEqual(conversations.conversations.first?.summary.preview, "Docs are rebuilt.")
        XCTAssertEqual(conversations.liveSummaries(host: host).count, 2)
    }

    /// Connected sessions keep the cache current; a removed host's entry goes.
    func testConnectedSessionsFeedTheCacheAndRemovalForgetsIt() async throws {
        let studio = ResilienceFixture.host("studio")
        let cache = HostCache(url: nil)
        let hosts = ResilienceFixture.sessions([studio])
        let app = ResilienceFixture.composition(hosts, cache: cache)
        try await TestSupport.eventually { cache.entry(studio.id)?.topology != nil }
        let entry = try XCTUnwrap(cache.entry(studio.id))
        XCTAssertEqual(entry.hello?.account?.home, "/Users/alex")
        XCTAssertEqual(entry.multiplexers.map(\.name), ["tmux"])
        XCTAssertEqual(entry.versions, ["tmux": "3.7"])
        app.hosts.remove(studio.id)
        XCTAssertNil(cache.entry(studio.id))
    }
}

/// Summaries as the fixture's agents report them live (docs at 1_800_000_100, billing at 1_800_000_050).
struct FixedSummaries: ChatConversationSource {
    func summaries(_ terminals: [UInt64], client: HelperClient) async -> [UInt64: ChatConversationSummary] {
        var result: [UInt64: ChatConversationSummary] = [:]
        if terminals.contains(5) {
            result[5] = ChatConversationSummary(preview: "Docs are rebuilt.", finished: true,
                                                lastActivity: Date(timeIntervalSince1970: 1_800_000_100))
        }
        if terminals.contains(10) {
            result[10] = ChatConversationSummary(attention: "approval", preview: "Run the migration?",
                                                 lastActivity: Date(timeIntervalSince1970: 1_800_000_050))
        }
        return result
    }
}
