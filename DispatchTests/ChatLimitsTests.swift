import XCTest
@testable import DispatchApp

/// An agent's limits are read only after consent for that agent, as a popover opens, at most once a minute.
@MainActor final class ChatLimitsTests: XCTestCase {
    private var time = Date(timeIntervalSince1970: 1_794_000_000)
    private var reads = 0
    private let window = ChatLimitWindow(name: "seven_day", used: 18, resets_at: 1_794_866_400)
    private let claude = ChatLimitsStore.Key(endpoint: "host", agent: "claude")
    private let codex = ChatLimitsStore.Key(endpoint: "host", agent: "codex")

    private func store() -> ChatLimitsStore { ChatLimitsStore(defaults: nil, clock: { [unowned self] in time }) }

    private func open(_ store: ChatLimitsStore, _ key: ChatLimitsStore.Key, failing: Bool = false) async throws {
        store.open(key) { [unowned self] in
            reads += 1
            if failing { throw CancellationError() }
            return .windows([window])
        }
        try await TestSupport.eventually { store.phases[key] != .reading }
    }

    func testNothingIsReadBeforeConsent() async throws {
        let store = store()
        store.open(claude) { [unowned self] in reads += 1; return .windows([]) }
        await Task.yield()
        XCTAssertEqual(reads, 0)
        XCTAssertNil(store.phases[claude])
    }

    func testConsentAndDeclineAreEachAgentsOwn() async throws {
        let store = store()
        store.accept("claude")
        store.decline("codex")
        XCTAssertTrue(store.consented("claude"))
        XCTAssertFalse(store.consented("codex"))
        XCTAssertFalse(store.declined("claude"))
        XCTAssertTrue(store.declined("codex"))
        store.open(codex) { [unowned self] in reads += 1; return .windows([]) }
        await Task.yield()
        XCTAssertEqual(reads, 0, "Agreeing for Claude says nothing about Codex")
    }

    func testAReadingAnswersForAMinuteAndNoLonger() async throws {
        let store = store()
        store.accept("claude")
        try await open(store, claude)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(store.phases[claude], .shown(.windows([window]), at: time))
        time += 59
        try await open(store, claude)
        XCTAssertEqual(reads, 1, "Within the minute the agent is not asked")
        time += 1
        try await open(store, claude)
        XCTAssertEqual(reads, 2)
    }

    func testAFailureIsNotKept() async throws {
        let store = store()
        store.accept("claude")
        try await open(store, claude, failing: true)
        XCTAssertEqual(store.phases[claude], .failed)
        try await open(store, claude)
        XCTAssertEqual(reads, 2, "Try Again always asks")
    }

    func testEachHelperAndAgentHasItsOwnMinute() async throws {
        let store = store()
        store.accept("claude"); store.accept("codex")
        try await open(store, claude)
        try await open(store, codex)
        XCTAssertEqual(reads, 2, "Claude and Codex on one helper are different accounts")
        try await open(store, .init(endpoint: "other", agent: "claude"))
        XCTAssertEqual(reads, 3)
    }

    func testOnlyAgentsThatReportLimitsHaveWording() {
        XCTAssertEqual(ChatLimitsWording.of("claude")?.agent, "Claude Code")
        XCTAssertEqual(ChatLimitsWording.of("codex")?.plan, "Your ChatGPT plan")
        XCTAssertNil(ChatLimitsWording.of("pi"))
    }

    func testAnExtensionIsItsOwnSubject() async throws {
        let store = store()
        let row = ChatLimitRow(label: "Today", detail: "", value: "$1.20", used: nil)
        let key = ChatLimitsStore.Key(endpoint: "host", agent: "pi:sam-limits")
        store.open(key) { [unowned self] in reads += 1; return .rows([row]) }
        await Task.yield()
        XCTAssertEqual(reads, 0, "Nothing reaches an extension before the user agrees to it")
        store.accept("pi:sam-limits")
        XCTAssertFalse(store.consented("pi:other-limits"), "Agreeing names one extension")
        store.open(key) { [unowned self] in reads += 1; return .rows([row]) }
        try await TestSupport.eventually { store.phases[key] != .reading }
        XCTAssertEqual(store.phases[key], .shown(.rows([row]), at: time))
        XCTAssertEqual(ChatLimitsWording.extension("sam-limits").plan, "From sam-limits")
    }

    func testTitles() {
        func title(_ name: String) -> String { ChatLimitWindow(name: name, used: 0, resets_at: 0).title }
        XCTAssertEqual(title("five_hour"), "5-hour")
        XCTAssertEqual(title("seven_day"), "Weekly")
        XCTAssertEqual(title("window_1440"), "1-day")
        XCTAssertEqual(title("window_120"), "2-hour")
        XCTAssertEqual(title("window_45"), "45-minute")
    }

    func testResetTimes() {
        let utc = TimeZone(identifier: "UTC")!
        let soon = ChatLimitWindow(name: "five_hour", used: 42, resets_at: time.timeIntervalSince1970 + 8_280)
        XCTAssertEqual(soon.resetText(now: time, timeZone: utc), "resets in 2h 18m")
        XCTAssertEqual(window.resetText(now: time, timeZone: utc), "resets Mon 10:00pm")
    }

    func testAge() {
        XCTAssertEqual(ChatLimitsSection.age(2), "read just now")
        XCTAssertEqual(ChatLimitsSection.age(40), "read 40s ago")
    }
}
