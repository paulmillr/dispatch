import XCTest
@testable import DispatchApp

@MainActor
final class ChatOperationsTests: XCTestCase {
    func testCancelledActorCallRemainsPendingUntilItsLateCallbackReturns() async throws {
        let operations = ChatOperations(), session = UUID()
        var release: CheckedContinuation<Void, Never>?
        var settled = false
        let task = operations.run(for: session) {
            await withCheckedContinuation { release = $0 }
            settled = true
        }
        try await TestSupport.eventually { release != nil }
        task.cancel()
        XCTAssertEqual(operations.pending(for: session), 1)
        XCTAssertFalse(settled, "Cancellation cannot claim that an actor callback finished")
        release?.resume()
        await operations.wait(for: session)
        XCTAssertTrue(settled)
        XCTAssertEqual(operations.pending(for: session), 0)
    }

    func testSettlementIncludesFollowupWorkAndKeepsSessionsIndependent() async throws {
        let operations = ChatOperations(), session = UUID(), other = UUID()
        var release: CheckedContinuation<Void, Never>?
        var otherRelease: CheckedContinuation<Void, Never>?
        var followedUp = false
        operations.run(for: other) { await withCheckedContinuation { otherRelease = $0 } }
        operations.run(for: session) {
            operations.run(for: session) {
                await withCheckedContinuation { release = $0 }
                followedUp = true
            }
        }
        try await TestSupport.eventually { release != nil && otherRelease != nil }
        release?.resume()
        await operations.wait(for: session)
        XCTAssertTrue(followedUp)
        XCTAssertEqual(operations.pending(for: session), 0)
        XCTAssertEqual(operations.pending(for: other), 1)
        otherRelease?.resume()
        await operations.wait()
        XCTAssertEqual(operations.pending(), 0)
    }
}
