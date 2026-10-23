import Foundation
import XCTest
@testable import DispatchWatch

/// The phone↔watch wire (Watch/Shared): every message round-trips, a newer peer's kinds, values and fields are
/// tolerated, and what the phone sends stays inside WatchConnectivity's limits.
final class WatchProtocolTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)
    private let key = WatchConversationKey(host: "5E1D1A5C-57D1-4C0A-8000-000000000001", node: "tmux:s:$1:%3")

    func testEveryRequestKindRoundTrips() throws {
        let actions: [WatchAction] = [
            .hello, .refresh(host: nil), .refresh(host: key.host), .thread(key, limit: 25),
            .answer(key, request: "interaction-7", WatchAnswer(choice: 2)),
            .answer(key, request: "interaction-12", WatchAnswer(options: ["schedule": [0, 2]], texts: ["note": "after lunch"])),
            .answer(key, request: "interaction-12", .skipped),
            .send(key, text: "Run it again", steer: false), .send(key, text: "Stop after this file", steer: true),
            .stop(key), .resume(key), .removeQueued(key, item: "helper:q-1"), .sendQueuedNow(key, item: "B2C1D7E0-0000-4000-8000-000000000001"),
            .markSeen(key, through: now), .openOnPhone(key), .undoReview(id: "review-1"),
        ]
        for action in actions {
            let request = WatchRequest(action, id: "r-1")
            let decoded = try WatchCodec.decode(WatchRequest.self, from: WatchCodec.encode(request))
            XCTAssertEqual(decoded, request, action.kind)
            XCTAssertEqual(decoded.action.kind, action.kind)
        }
    }

    func testEveryReplyKindRoundTrips() throws {
        let thread = try XCTUnwrap(WatchFixtures.threads(now: now)[WatchFixtures.question])
        let results: [WatchResult] = [
            .snapshot(WatchFixtures.demo(now: now)), .thread(thread), .done, .failure(.phoneLocked),
            .snapshot(WatchFixtures.mockup(now: now, review: true)), .thread(WatchFixtures.mockupThreads(now: now)[WatchFixtures.limiter]!),
            .opened(.shown), .opened(.notified), .opened(.unavailable),
            .failure(WatchFailure.openPhone(host: "pi")),
        ]
        for result in results {
            let reply = WatchReply(id: "r-2", result)
            XCTAssertEqual(try WatchCodec.decode(WatchReply.self, from: WatchCodec.encode(reply)), reply, result.kind)
        }
    }

    /// The redesign's fields (rows' step, time and question, hosts' latency and statistics with gaps in their CPU line,
    /// review events, turn summaries, approval verbs) travel and come back as they were.
    func testTheRedesignsFieldsRoundTrip() throws {
        let snapshot = WatchFixtures.mockup(now: now, review: true)
        let decoded = try WatchCodec.decode(WatchSnapshot.self, from: WatchCodec.encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        let host = try XCTUnwrap(decoded.hosts.first)
        XCTAssertEqual(host.latency, 18)
        XCTAssertEqual(host.stats?.history.count, WatchHostStats.historyCount)
        XCTAssertEqual(host.stats?.history.filter { $0 == nil }.count, 4, "the gap stays a gap")
        XCTAssertEqual(host.stats?.warnings, [.disk])
        XCTAssertEqual(host.stats?.peak, 82)
        XCTAssertEqual(decoded.conversations[0].step, "Editing Sidebar.tsx")
        XCTAssertEqual(decoded.conversations[1].waitingText, "Allow cargo test --workspace?")
        XCTAssertEqual(decoded.reviews.map(\.comments), [3])
        let thread = try XCTUnwrap(WatchFixtures.mockupThreads(now: now)[WatchFixtures.sidebar])
        let page = try WatchCodec.decode(WatchThread.self, from: WatchCodec.encode(thread))
        XCTAssertEqual(page.items.last?.summary, WatchTurnSummary(steps: 5, seconds: 86, files: 4, additions: 61, deletions: 9))
        let limiter = try XCTUnwrap(WatchFixtures.mockupThreads(now: now)[WatchFixtures.limiter])
        XCTAssertEqual(try WatchCodec.decode(WatchThread.self, from: WatchCodec.encode(limiter)).approvals.first?.verb, .run)
    }

    /// An older phone's snapshot (none of the redesign's fields) reads with them empty; a newer one's unknown warning or
    /// verb reads as unknown; statistics that do not decode leave the host without them, not the host out.
    func testOlderAndNewerPeersReadTheRedesignsFields() throws {
        let data = try WatchCodec.encode(WatchFixtures.mockup(now: now, review: true))
        var object = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        var hosts = try XCTUnwrap(object["hosts"] as? [[String: Any]])
        var stats = try XCTUnwrap(hosts[0]["stats"] as? [String: Any])
        stats["warnings"] = ["disk", "battery"]
        stats["cpu"] = "high"
        hosts[0]["stats"] = stats
        object["hosts"] = hosts
        var newer = try WatchCodec.decode(WatchSnapshot.self, from: PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0))
        XCTAssertEqual(newer.hosts.first?.stats?.warnings, [.disk, .unknown])
        XCTAssertNil(newer.hosts.first?.stats?.cpu)
        XCTAssertNotNil(newer.hosts.first?.stats?.memoryUsed)

        for host in hosts.indices { hosts[host]["stats"] = nil; hosts[host]["latency"] = nil; hosts[host]["offlineSince"] = nil }
        object["hosts"] = hosts
        object["reviews"] = nil
        var rows = try XCTUnwrap(object["conversations"] as? [[String: Any]])
        for row in rows.indices { for field in ["title", "step", "workingSince", "waitingText"] { rows[row][field] = nil } }
        object["conversations"] = rows
        newer = try WatchCodec.decode(WatchSnapshot.self, from: PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0))
        XCTAssertEqual(newer.hosts.count, 1)
        XCTAssertNil(newer.hosts[0].stats)
        XCTAssertEqual(newer.reviews, [])
        XCTAssertNil(newer.conversations[0].step)
        XCTAssertEqual(newer.conversations.count, 3)

        let opened = try plist(["id": "r", "version": 1, "kind": "opened", "opened": "teleported"])
        XCTAssertEqual(try WatchCodec.decode(WatchReply.self, from: opened).result, .opened(.unknown))

        let approval = try plist(["id": "i", "title": "Fetch it?", "arrived": now, "choices": [[String: Any]](), "verb": "teleport"])
        XCTAssertEqual(try WatchCodec.decode(WatchApproval.self, from: approval).verb, .unknown)
    }

    /// The snapshot clips the rows' new texts as it clips their previews, and a host's CPU line to its 15 minutes.
    func testFittingClipsTheRowsNewTexts() {
        var snapshot = WatchFixtures.mockup(now: now)
        let long = String(repeating: "cargo test --workspace --all-features ", count: 20)
        snapshot.conversations[0].step = long
        snapshot.conversations[1].waitingText = long
        snapshot.conversations[2].title = long
        snapshot.hosts[0].stats?.history = Array(repeating: 50, count: 240) + [12]
        let fitted = WatchCodec.fit(snapshot)
        XCTAssertEqual(fitted.hosts[0].stats?.history.count, WatchHostStats.historyCount, "the newest 15 minutes")
        XCTAssertEqual(fitted.hosts[0].stats?.history.last, 12)
        XCTAssertLessThanOrEqual(fitted.conversations[0].step?.count ?? 0, WatchLimits.preview)
        XCTAssertLessThanOrEqual(fitted.conversations[1].waitingText?.count ?? 0, WatchLimits.preview)
        XCTAssertLessThanOrEqual(fitted.conversations[2].title?.count ?? 0, WatchLimits.line)
    }

    /// A newer watch may ask for a terminal's screen; a newer phone may reply with kinds this build lacks. Both decode
    /// as `unknown`, so the phone can answer `unsupported` and the watch can say so.
    func testAnUnknownKindDecodesAsUnknown() throws {
        let request = try plist(["id": "r-3", "version": 2, "kind": "terminal.screen", "host": key.host, "node": key.node, "rows": 24])
        let decoded = try WatchCodec.decode(WatchRequest.self, from: request)
        XCTAssertEqual(decoded.action, .unknown("terminal.screen"))
        XCTAssertEqual(decoded.version, 2)

        let reply = try plist(["id": "r-3", "version": 2, "kind": "screen", "screen": ["lines": ["$ ls"]]])
        XCTAssertEqual(try WatchCodec.decode(WatchReply.self, from: reply).result, .unknown("screen"))
    }

    /// A newer phone's snapshot: an unknown host state reads as unknown, an unknown field is ignored, and a row this
    /// build cannot read drops that row only.
    func testANewerPhonesSnapshotStillReads() throws {
        let data = try WatchCodec.encode(WatchFixtures.demo(now: now))
        var object = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        var hosts = try XCTUnwrap(object["hosts"] as? [[String: Any]])
        hosts[0]["state"] = "sleeping"
        hosts[0]["battery"] = 0.4
        object["hosts"] = hosts
        var conversations = try XCTUnwrap(object["conversations"] as? [[String: Any]])
        conversations.insert(["host": key.host, "name": 42], at: 0)
        object["conversations"] = conversations
        object["widgets"] = ["something new"]

        let snapshot = try WatchCodec.decode(WatchSnapshot.self, from: plist(object))
        XCTAssertEqual(snapshot.hosts.first?.state, .unknown)
        XCTAssertEqual(snapshot.hosts.count, 3)
        XCTAssertEqual(snapshot.conversations.count, 6, "the unreadable row goes, the others stay")
        XCTAssertEqual(snapshot.conversations.map(\.key), WatchFixtures.demo(now: now).conversations.map(\.key))
    }

    func testAWatchConnectivityDictionaryCarriesOneDataValue() throws {
        let request = WatchRequest(.thread(key, limit: 10), id: "r-4")
        let message = try WatchCodec.message(request)
        XCTAssertEqual(Array(message.keys), [WatchCodec.key])
        XCTAssertTrue(message[WatchCodec.key] is Data)
        // What WatchConnectivity accepts: a property list.
        XCTAssertTrue(PropertyListSerialization.propertyList(message, isValidFor: .binary))
        XCTAssertEqual(try WatchCodec.value(WatchRequest.self, in: message), request)
        XCTAssertNil(try WatchCodec.value(WatchRequest.self, in: ["other": "value"]))
    }

    /// The size bound (docs/watch.md, Limits): five hosts with six conversations each, every text at its longest, fits in
    /// half the budget's room without leaving anything out.
    func testFiveHostsWithSixConversationsEachFitWithoutTruncation() throws {
        let sample = WatchFixtures.crowded(hosts: 5, conversations: 6, now: now)
        let fitted = WatchCodec.fit(sample)
        let bytes = try WatchCodec.encode(fitted).count
        XCTAssertFalse(fitted.truncated)
        XCTAssertEqual(fitted.conversations.count, 30)
        XCTAssertEqual(fitted.tabs.count, sample.tabs.count)
        XCTAssertEqual(fitted.hosts.map { $0.stats?.history.count }, Array(repeating: WatchHostStats.historyCount, count: 5),
                       "every CPU line kept")
        XCTAssertEqual(fitted.conversations.map(\.step), sample.conversations.map { $0.step.map { WatchText.clip($0, to: WatchLimits.preview) } })
        XCTAssertEqual(fitted.conversations.compactMap(\.waitingText).count, 10)
        XCTAssertLessThanOrEqual(bytes, 28 * 1024, "measured 24.9 KB when written (15.0 before the statistics and the rows' steps)")
        // The application context as WatchConnectivity serializes it.
        let context = try PropertyListSerialization.data(fromPropertyList: WatchCodec.message(fitted), format: .binary, options: 0)
        XCTAssertLessThanOrEqual(context.count, WatchLimits.snapshotBytes)
        print("Watch snapshot, 5 hosts × 6 conversations: \(bytes) bytes, \(context.count) as a context")
        for row in fitted.conversations { XCTAssertLessThanOrEqual(row.preview?.count ?? 0, WatchLimits.preview) }
    }

    /// Too many rows for the budget: the oldest quiet ones go first, everything that needs the user stays, and the
    /// snapshot says it is partial.
    func testAnOversizedSnapshotKeepsWhatNeedsYou() throws {
        let sample = WatchFixtures.crowded(hosts: 8, conversations: 12, now: now)
        XCTAssertGreaterThan(WatchCodec.size(sample), WatchLimits.snapshotBytes)
        let fitted = WatchCodec.fit(sample)
        XCTAssertTrue(fitted.truncated)
        XCTAssertLessThanOrEqual(WatchCodec.size(fitted), WatchLimits.snapshotBytes)
        XCTAssertEqual(Set(fitted.conversations.filter(\.needsYou).map(\.key)), Set(sample.conversations.filter(\.needsYou).map(\.key)))
        // The hosts stay, their strips too; their CPU lines went first, then the rows' steps and requests were cut short.
        XCTAssertEqual(fitted.hosts.map(\.id), sample.hosts.map(\.id))
        XCTAssertTrue(fitted.hosts.allSatisfy { $0.stats?.history.isEmpty == true && $0.stats?.cpu != nil })
        XCTAssertTrue(fitted.conversations.allSatisfy { ($0.step?.count ?? 0) <= WatchLimits.short && ($0.waitingText?.count ?? 0) <= WatchLimits.short })
    }

    /// Just over the budget: the CPU lines go and nothing else.
    func testTheCPULinesGoBeforeAnyRow() throws {
        let sample = WatchFixtures.crowded(hosts: 5, conversations: 6, now: now)
        let lines = WatchCodec.size(sample)
        var withoutLines = sample
        for index in withoutLines.hosts.indices { withoutLines.hosts[index].stats?.history = [] }
        let budget = WatchCodec.size(withoutLines) + 10
        XCTAssertLessThan(budget, lines)
        let fitted = WatchCodec.fit(sample, budget: budget)
        XCTAssertFalse(fitted.truncated)
        XCTAssertEqual(fitted.conversations, WatchCodec.fit(sample).conversations, "rows and their texts as they were")
        XCTAssertTrue(fitted.hosts.allSatisfy { $0.stats?.history.isEmpty == true })
    }

    func testAThreadPageFitsByLeavingOutItsOldestItems() throws {
        let text = String(repeating: "A long agent message about the replay corpus. ", count: 40)
        let items = (0..<200).map { WatchItem(id: "i\($0)", kind: .agent, text: "\($0) " + text, time: now.addingTimeInterval(Double($0))) }
        let thread = WatchThread(key: key, generated: now, title: "Long", items: items)
        let fitted = WatchCodec.fit(thread)
        XCTAssertLessThanOrEqual(WatchCodec.size(fitted), WatchLimits.replyBytes)
        XCTAssertTrue(fitted.earlier)
        XCTAssertEqual(fitted.items.last?.id, "i199", "the newest stays")
        XCTAssertTrue(fitted.items.allSatisfy { $0.text.count <= WatchLimits.itemText })
        XCTAssertTrue(fitted.items.last?.text.hasSuffix("…") == true)
    }

    func testMarkdownFlattensForTheWrist() {
        let markdown = """
        # Summary

        The **build** passed; see [the log](https://example.com/log) and `make test`.

        - first *point*
        - [x] done item
        > quoted line

        ```swift
        let x = 1
        ```
        | File | Lines |
        |------|------:|
        | a.swift | 12 |

        ---
        Globs like *.swift and 2 * 3 stay.
        """
        XCTAssertEqual(WatchText.plain(markdown), """
        Summary

        The build passed; see the log and make test.

        • first point
        • done item
        quoted line

        let x = 1
        File · Lines
        a.swift · 12

        Globs like *.swift and 2 * 3 stay.
        """)
    }

    func testAPreviewIsOneClippedLine() {
        let preview = WatchText.preview("**Done.**\n\n" + String(repeating: "word ", count: 60))
        XCTAssertLessThanOrEqual(preview.count, WatchLimits.preview)
        XCTAssertTrue(preview.hasPrefix("Done. word"))
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertFalse(preview.contains("\n"))
        XCTAssertEqual(WatchText.clip("short", to: 10), "short")
    }

    /// The phone's agent notifications carry the conversation as `host` and `node` (`RefreshNotification.userInfo`).
    func testANotificationNamesItsConversation() {
        XCTAssertEqual(WatchNotification.key([WatchNotification.hostKey: key.host, WatchNotification.nodeKey: key.node]), key)
        XCTAssertEqual(WatchNotification.hostKey, "host")
        XCTAssertEqual(WatchNotification.nodeKey, "node")
        XCTAssertNil(WatchNotification.key(["host": "not-a-uuid", "node": key.node]))
        XCTAssertNil(WatchNotification.key(["host": key.host]))
    }

    func testATintRoundTripsThroughHex() throws {
        XCTAssertEqual(WatchTint.hex(red: 1, green: 0.5, blue: 0), "#FF8000")
        let components = try XCTUnwrap(WatchTint.components("#C98BD9"))
        XCTAssertEqual(WatchTint.hex(red: components.red, green: components.green, blue: components.blue), "#C98BD9")
        XCTAssertNil(WatchTint.components("C98BD9"))
        XCTAssertNil(WatchTint.components("#GGGGGG"))
    }

    func testAnAnswerCompletesAQuestionOnlyWhenEveryPartIsAnswered() {
        let question = WatchQuestion(id: "q", parts: [
            WatchQuestion.Part(id: "a", text: "Which?", options: [WatchOption(index: 0, label: "One")]),
            WatchQuestion.Part(id: "b", text: "Why?", custom: true),
        ])
        XCTAssertFalse(WatchAnswer(options: ["a": [0]]).completes(question))
        XCTAssertFalse(WatchAnswer(options: ["a": [0]], texts: ["b": "  "]).completes(question))
        XCTAssertTrue(WatchAnswer(options: ["a": [0]], texts: ["b": "Faster"]).completes(question))
        XCTAssertTrue(WatchAnswer.skipped.completes(question))
    }

    private func plist(_ object: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    }
}
