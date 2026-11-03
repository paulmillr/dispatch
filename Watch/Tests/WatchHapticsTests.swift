import XCTest
@testable import DispatchWatch

/// The wrist taps while the app is frontmost: needs you (`.notification`) before finished (`.success`), none for working
/// updates, launch or muted rows.
@MainActor
final class WatchHapticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    func testNeedsYouAndFinishedTapTheWristWorkingDoesNot() {
        let before = WatchFixtures.demo(now: now)
        XCTAssertNil(WatchHaptic.event(from: nil, to: before), "launch is not news")
        XCTAssertNil(WatchHaptic.event(from: before, to: before))

        // A working row's step changes: nothing.
        var next = before
        let working = next.conversations.firstIndex { $0.key == WatchFixtures.working }!
        next.conversations[working].step = "Editing drain.rs"
        XCTAssertNil(WatchHaptic.event(from: before, to: next))

        // It finishes.
        next.conversations[working].busy = false
        next.conversations[working].dot = .unread
        XCTAssertEqual(WatchHaptic.event(from: before, to: next), .finished)

        // It finishes waiting for the user: needs you, which wins over another finishing.
        next.conversations[working].needsYou = true
        XCTAssertEqual(WatchHaptic.event(from: before, to: next), .needsYou)

        // A muted row stays quiet; a row the phone did not list before is not news.
        next.conversations[working].muted = true
        XCTAssertNil(WatchHaptic.event(from: before, to: next))
        var fresh = before
        fresh.conversations = fresh.conversations.filter { $0.key != WatchFixtures.working }
        XCTAssertNil(WatchHaptic.event(from: fresh, to: next))
    }

    /// The model plays one per snapshot it takes, through its `haptic` hook: nothing before the phone answered this
    /// launch's `hello` (what changed while away is not news), nothing for a turn the user stopped here.
    func testTheModelPlaysWhatTheSnapshotBrings() async throws {
        final class Clock { var now: Date; init(_ now: Date) { self.now = now } }
        let clock = Clock(now)
        let link = ScriptedWatchLink(scenario: .demo, now: { clock.now })
        var played: [WatchHaptic] = []
        let model = WatchModel(link: link, now: { clock.now }, haptic: { played.append($0) })
        var next = try XCTUnwrap(model.snapshot)
        let notes = next.conversations.firstIndex { $0.key == WatchFixtures.notes }!
        next.generated = now.addingTimeInterval(1)
        next.conversations[notes].needsYou = true
        link.push(next)
        XCTAssertTrue(played.isEmpty, "the stored context and what came before hello are not news")

        clock.now = now.addingTimeInterval(10)
        await model.start()
        // The user stops the working turn from the watch: its end is theirs.
        await model.open(WatchFixtures.working)
        clock.now = now.addingTimeInterval(20)
        _ = await model.stop(WatchFixtures.working)
        XCTAssertEqual(model.conversation(WatchFixtures.working)?.busy, false)
        XCTAssertTrue(played.isEmpty, "\(played)")

        // Another conversation finishes by itself.
        next = try XCTUnwrap(model.snapshot)
        next.generated = now.addingTimeInterval(60)
        let row = next.conversations.firstIndex { $0.key == WatchFixtures.notes }!
        next.conversations[row].needsYou = false
        next.conversations[row].busy = true
        link.push(next)
        next.generated = now.addingTimeInterval(61)
        next.conversations[row].busy = false
        link.push(next)
        XCTAssertEqual(played, [.finished])
    }

    /// A turn the user stopped here is ignored; others still count.
    func testAStopFromTheWatchIsNotNews() {
        let before = WatchFixtures.demo(now: now)
        var next = before
        let working = next.conversations.firstIndex { $0.key == WatchFixtures.working }!
        next.conversations[working].busy = false
        XCTAssertNil(WatchHaptic.event(from: before, to: next, ignoring: [WatchFixtures.working]))
        XCTAssertEqual(WatchHaptic.event(from: before, to: next, ignoring: [WatchFixtures.notes]), .finished)
    }
}
