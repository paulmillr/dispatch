import XCTest
@testable import DispatchMobile

/// Pull to refresh in Spaces and Agents, and each host's last update under it.
@MainActor
final class HostFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheLabelSaysTheConnectionThenWhenTheHostLastAnswered() {
        XCTAssertEqual(HostFreshness.label(state: .connected, updated: now.addingTimeInterval(-5), now: now), "Updated just now")
        XCTAssertEqual(HostFreshness.label(state: .connected, updated: now.addingTimeInterval(-720), now: now), "Updated 12m ago")
        XCTAssertEqual(HostFreshness.label(state: .connecting, updated: now.addingTimeInterval(-180), now: now),
                       "Connecting · updated 3m ago")
        XCTAssertEqual(HostFreshness.label(state: .offline, updated: now.addingTimeInterval(-60), now: now), "Offline · updated 1m ago")
        XCTAssertEqual(HostFreshness.label(state: .connected, updated: nil, now: now), "Connected")
        XCTAssertEqual(HostFreshness.label(state: .connecting, updated: nil, now: now), "Connecting")
        XCTAssertEqual(HostFreshness.label(state: .offline, updated: nil, now: now), "Offline", "never heard from")
    }

    /// The subtitle says "Updated just now" for the hosts that answered within the minute, then names two of the others.
    func testTheSubtitleNamesOnlyTheHostsBehind() {
        func host(_ name: String, _ state: SpacesHostState, _ age: TimeInterval?) -> HostFreshness {
            HostFreshness(id: UUID(), name: name, tint: .gray, state: state, updated: age.map { now.addingTimeInterval(-$0) })
        }
        XCTAssertNil(HostFreshness.summary([], now: now))
        XCTAssertEqual(HostFreshness.summary([host("ai", .connected, 5), host("studio", .connected, 30)], now: now),
                       "Updated just now")
        XCTAssertEqual(HostFreshness.summary([host("ai", .connected, 5), host("vps", .offline, nil), host("studio", .connected, 720)],
                                             now: now), "Updated just now · vps offline · studio updated 12m ago")
        XCTAssertEqual(HostFreshness.summary([host("vps", .offline, nil), host("studio", .connected, 720)], now: now),
                       "vps offline · studio updated 12m ago", "no host fresh")
        XCTAssertEqual(HostFreshness.summary([host("a", .offline, nil), host("b", .connecting, 60), host("c", .offline, 9),
                                              host("d", .offline, nil)], now: now), "a offline · b connecting · +2 more")
    }

    /// VoiceOver reads the host's last update after the rest of its header.
    func testTheHostHeaderReadsTheLastUpdate() {
        XCTAssertEqual(SpacesHostHeader.value(collapsed: false, unread: 0, multiplexer: "tmux", freshness: "Updated just now"),
                       "tmux, Expanded, Updated just now")
        XCTAssertEqual(SpacesHostHeader.value(collapsed: true, unread: 2), "Collapsed, 2 unread", "no line, nothing read")
    }

    /// Each answer of the helper moves the host's last update on; a retry while connected (pull to refresh, a network
    /// change) is answered with a round trip.
    func testAHostIsUpdatedWhenItsHelperAnswers() async throws {
        let session = ResilienceFixture.sessions([ResilienceFixture.host("studio")], active: false).ordered[0]
        XCTAssertNil(session.updated)
        session.connect()
        try await TestSupport.eventually { session.latency != nil }
        let first = try XCTUnwrap(session.updated)
        session.retryNow()
        try await TestSupport.eventually { (session.updated ?? first) > first }
        session.disconnect()
        XCTAssertNotNil(session.updated, "kept for the offline host's label")
    }

    /// The pull ends once every host answered or is down again: a connected host's check, a refused one's attempt.
    func testRefreshReturnsOnceEveryHostAnswered() async throws {
        let driver = ScriptedHostSessionDriver { host in
            host.name == "vps" ? [.event(.link(.connecting)), .event(.link(.failed("Connection refused")))]
                : ScriptedHostSessionDriver.connects(host)
        }
        let hosts = ResilienceFixture.sessions([ResilienceFixture.host("studio"), ResilienceFixture.host("vps", order: 1)],
                                               driver: driver, active: true)
        let studio = hosts.ordered[0], vps = hosts.ordered[1]
        try await TestSupport.eventually { studio.latency != nil && vps.link == .failed("Connection refused") }
        let before = try XCTUnwrap(studio.updated)
        let started = ContinuousClock.now
        await hosts.refresh(timeout: .seconds(30))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10), "returned on the answers, not the timeout")
        XCTAssertGreaterThan(try XCTUnwrap(studio.updated), before)
        XCTAssertEqual(vps.link, .failed("Connection refused"), "tried again and refused again")
        XCTAssertEqual(driver.runs(vps.id), 2)
        XCTAssertNil(vps.updated, "never heard from")
    }

    /// The cache keeps when each host last answered, for its label after a relaunch; an older cache's save time stands in.
    func testTheCacheKeepsWhenAHostLastAnswered() throws {
        let host = UUID()
        let cache = HostCache(url: nil, now: { self.now })
        XCTAssertNil(cache.updated(host))
        cache.replace(HostCacheEntry(saved: now), for: host)
        XCTAssertNil(cache.updated(host), "no hello: never a helper's answer")
        var answered = HostCacheEntry(saved: now)
        answered.hello = HostFixture.hello()
        cache.replace(answered, for: host)
        XCTAssertEqual(cache.updated(host), now, "no answer recorded: the save time")
        cache.record(heard: now.addingTimeInterval(60), host: host)
        cache.record(heard: now.addingTimeInterval(30), host: host)
        XCTAssertEqual(cache.updated(host), now.addingTimeInterval(60), "never moves back")
        let entry = try XCTUnwrap(cache.entry(host))
        let decoded = try JSONDecoder().decode(HostCacheEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.heard, now.addingTimeInterval(60))

        var cached = ResilienceFixture.entry(saved: now)
        cached.heard = now.addingTimeInterval(-90)
        let restoring = HostCache(url: nil)
        let record = ResilienceFixture.host("studio")
        restoring.replace(cached, for: record.id)
        let composition = ResilienceFixture.composition(ResilienceFixture.sessions([record], active: false), cache: restoring)
        XCTAssertEqual(composition.hosts.ordered[0].updated, now.addingTimeInterval(-90), "restored at launch")
    }
}
