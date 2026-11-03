import XCTest
@testable import DispatchMobile

/// "Jump to latest" (C6, `ChatFollow`) per state transition: it never shows while the thread follows its end, whatever
/// takes the end out of view without moving the offset up (rows, the keyboard, the composer) and whatever arrives
/// meanwhile; any scroll toward older rows that is not the app's leaves the end (a drag at once, VoiceOver, the status
/// bar, keys); a drag that only took the keyboard down keeps following; back at the end, or after a send or the pill,
/// it is gone in the same transition. These are the no-flash guarantees: the UI tests sample far too slowly for them.
final class ChatFollowTests: XCTestCase {
    /// At the end, rows growing the content and a keyboard shrinking the view: the end leaves the view with the offset
    /// unchanged or moving down; rows that come then never raise the pill, and the thread asks to go back.
    func testGrowthAndTheKeyboardKeepFollowing() {
        var follow = ChatFollow()
        XCTAssertFalse(follow.moved(offset: 100, atEnd: true))
        XCTAssertTrue(follow.moved(offset: 100, atEnd: false), "content grew: back to the end")
        XCTAssertTrue(follow.following)
        follow.appended(1)
        XCTAssertFalse(follow.showsJump, "a row that comes in that moment does not raise the pill")
        XCTAssertTrue(follow.moved(offset: 140, atEnd: false), "the keyboard rose and the anchor moved down, not yet there")
        XCTAssertFalse(follow.moved(offset: 160, atEnd: true))
        XCTAssertFalse(follow.showsJump)
        XCTAssertEqual(follow.unseen, 0)
    }

    /// Sending: the optimistic bubble, the working row, the user's record and the streamed answer each move the end;
    /// at every step the pill stays away and the thread asks to stay at the end.
    func testSendingStaysAtTheEndAtEveryStep() {
        var follow = ChatFollow()
        follow.follow() // the send
        var offset: CGFloat = 200
        for _ in 0..<6 {
            XCTAssertTrue(follow.moved(offset: offset, atEnd: false))
            XCTAssertFalse(follow.showsJump)
            follow.appended(1)
            XCTAssertFalse(follow.showsJump)
            offset += 40
            XCTAssertFalse(follow.moved(offset: offset, atEnd: true))
            XCTAssertFalse(follow.showsJump)
        }
    }

    /// A scroll toward older rows that the app did not ask for leaves the end: VoiceOver's three-finger scroll or focus,
    /// the status bar's tap, Page Up and the arrow keys come with no drag.
    func testAnyScrollUpThatIsNotTheAppsLeavesTheEnd() {
        var follow = ChatFollow()
        XCTAssertFalse(follow.moved(offset: 500, atEnd: true))
        XCTAssertFalse(follow.moved(offset: 200, atEnd: false), "moved up by something other than a drag: stays there")
        XCTAssertFalse(follow.following)
        follow.appended(2)
        XCTAssertTrue(follow.showsJump)
        XCTAssertFalse(follow.moved(offset: 210, atEnd: false), "and nothing pulls it back")
    }

    /// A drag stops following the moment it starts, also when the end is out of view for another reason (right after
    /// the pill, during the keyboard's animation, while an answer streams): nothing snaps back when it ends.
    func testADragStopsFollowingAtOnce() {
        var follow = ChatFollow()
        XCTAssertTrue(follow.moved(offset: 100, atEnd: false), "the end left the view: growth")
        follow.dragBegan()
        XCTAssertFalse(follow.following)
        XCTAssertFalse(follow.moved(offset: 90, atEnd: false))
        XCTAssertFalse(follow.dragEnded(atEnd: false), "no snap back when the finger lifts")
        XCTAssertFalse(follow.following)
        // A drag that ends at the end follows again, the pill gone while the finger is still down.
        follow.appended(1)
        XCTAssertTrue(follow.showsJump)
        follow.dragBegan()
        XCTAssertFalse(follow.moved(offset: 300, atEnd: true))
        XCTAssertFalse(follow.showsJump, "gone as soon as the end is in view")
        XCTAssertFalse(follow.dragEnded(atEnd: true))
        XCTAssertTrue(follow.following)
        follow.appended(1)
        XCTAssertFalse(follow.showsJump)
    }

    /// A drag at the end that never leaves it follows again when it ends.
    func testADragThatStaysAtTheEndKeepsFollowing() {
        var follow = ChatFollow()
        follow.dragBegan()
        XCTAssertFalse(follow.dragEnded(atEnd: true))
        XCTAssertTrue(follow.following)
    }

    /// A drag that took the keyboard down from a following thread keeps it following and goes back to the end, however
    /// far the drag scrolled; the next answer brings no pill. Without the keyboard, the same drag leaves the end.
    func testADragThatTookTheKeyboardDownKeepsFollowing() {
        var follow = ChatFollow()
        XCTAssertFalse(follow.moved(offset: 800, atEnd: true))
        follow.dragBegan()
        XCTAssertFalse(follow.moved(offset: 400, atEnd: false))
        follow.draggedKeyboardDown()
        XCTAssertTrue(follow.dragEnded(atEnd: false), "back to the end")
        XCTAssertTrue(follow.following)
        follow.appended(1)
        XCTAssertFalse(follow.showsJump)

        follow.dragBegan()
        XCTAssertFalse(follow.moved(offset: 400, atEnd: false))
        XCTAssertFalse(follow.dragEnded(atEnd: false))
        XCTAssertFalse(follow.following, "reading back up without the keyboard")

        // Scrolled up before the drag: the keyboard going down does not bring it to the end.
        follow.dragBegan()
        follow.draggedKeyboardDown()
        XCTAssertFalse(follow.dragEnded(atEnd: false))
        XCTAssertFalse(follow.following)
    }

    /// The pill's animated scroll to the end runs: its offsets never ask for a plain scroll over it, and it follows.
    func testThePillsAnimatedScrollIsLetRun() {
        var follow = ChatFollow()
        follow.dragBegan()
        _ = follow.moved(offset: 100, atEnd: false)
        _ = follow.dragEnded(atEnd: false)
        follow.appended(1)
        XCTAssertTrue(follow.showsJump)
        follow.follow(scrolling: true)
        XCTAssertFalse(follow.showsJump, "gone with the tap")
        XCTAssertFalse(follow.moved(offset: 300, atEnd: false), "the animation's own frames")
        XCTAssertFalse(follow.moved(offset: 900, atEnd: false))
        XCTAssertFalse(follow.moved(offset: 1200, atEnd: true))
        XCTAssertFalse(follow.scrollingToEnd)
        XCTAssertTrue(follow.moved(offset: 1200, atEnd: false), "growth after it re-pins again")
    }

    /// A send while scrolled up follows the end again, the pill gone in the same change.
    func testASendWhileScrolledUpFollowsAgain() {
        var follow = ChatFollow()
        _ = follow.moved(offset: 500, atEnd: true)
        _ = follow.moved(offset: 100, atEnd: false)
        follow.appended(2)
        XCTAssertTrue(follow.showsJump)
        follow.follow()
        XCTAssertFalse(follow.showsJump)
        XCTAssertTrue(follow.moved(offset: 100, atEnd: false), "and goes to the end")
    }

    /// C6's demo opens at the top: not following, so rows count from the start and nothing pulls it down.
    func testAThreadOpenedAtItsTopDoesNotFollow() {
        var follow = ChatFollow(following: false)
        XCTAssertFalse(follow.moved(offset: 0, atEnd: false))
        follow.appended(2)
        XCTAssertTrue(follow.showsJump)
        XCTAssertFalse(follow.moved(offset: 900, atEnd: true))
        XCTAssertTrue(follow.following)
        XCTAssertFalse(follow.showsJump)
    }

    /// A search match scrolls away on the user's request: the thread stays there.
    func testASearchMatchLeavesTheEnd() {
        var follow = ChatFollow()
        follow.leave()
        XCTAssertFalse(follow.moved(offset: 100, atEnd: false))
    }
}
