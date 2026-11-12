import XCTest
@testable import DispatchMobile

/// "Jump to latest" (C7, `ChatFollow`) per state transition: it never shows while the thread follows its end, whatever
/// takes the end out of view without moving the offset up (rows, the keyboard, the composer) and whatever arrives
/// meanwhile; any scroll toward older rows that is not the app's leaves the end (a drag at once, VoiceOver, the status
/// bar, keys); a drag that only took the keyboard down keeps following; back at the end, or after a send or the button,
/// it is gone in the same transition. These are the no-flash guarantees: the UI tests sample far too slowly for them.
final class ChatFollowTests: XCTestCase {
    /// At the end, rows growing the content and a keyboard shrinking the view: the end leaves the view with the offset
    /// unchanged or moving down; rows that come then never raise the button, and the thread asks to go back.
    func testGrowthAndTheKeyboardKeepFollowing() {
        var follow = ChatFollow()
        XCTAssertFalse(follow.moved(offset: 100, atEnd: true))
        XCTAssertTrue(follow.moved(offset: 100, atEnd: false), "content grew: back to the end")
        XCTAssertTrue(follow.following)
        follow.appended(1)
        XCTAssertFalse(follow.showsJump, "a row that comes in that moment does not raise the button")
        XCTAssertTrue(follow.moved(offset: 140, atEnd: false), "the keyboard rose and the anchor moved down, not yet there")
        XCTAssertFalse(follow.moved(offset: 160, atEnd: true))
        XCTAssertFalse(follow.showsJump)
        XCTAssertEqual(follow.unseen, 0)
    }

    /// Sending: the optimistic bubble, the working row, the user's record and the streamed answer each move the end;
    /// at every step the button stays away and the thread asks to stay at the end.
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
        XCTAssertTrue(follow.showsJump, "away from the end with nothing new: the way back shows (C7)")
        XCTAssertEqual(follow.shown.unseen, 0)
        follow.appended(2)
        XCTAssertTrue(follow.showsJump)
        XCTAssertEqual(follow.shown.unseen, 2, "the badge")
        XCTAssertFalse(follow.moved(offset: 210, atEnd: false), "and nothing pulls it back")
    }

    /// A pushed thread is laid out at its end before the navigation bar's inset arrives, which moves the offset up by
    /// the bar's height: that is the layout, so the thread goes back to its end.
    func testAnInsetArrivingIsNotAScrollUp() {
        var follow = ChatFollow()
        XCTAssertFalse(follow.moved(offset: 1262, atEnd: true))
        XCTAssertTrue(follow.moved(offset: 1140, atEnd: false, resized: true), "back to the end")
        XCTAssertTrue(follow.following)
        XCTAssertFalse(follow.moved(offset: 1262, atEnd: true))
    }

    /// A drag stops following the moment it starts, also when the end is out of view for another reason (right after
    /// the button, during the keyboard's animation, while an answer streams): nothing snaps back when it ends.
    func testADragStopsFollowingAtOnce() {
        var follow = ChatFollow()
        XCTAssertTrue(follow.moved(offset: 100, atEnd: false), "the end left the view: growth")
        follow.dragBegan()
        XCTAssertFalse(follow.following)
        XCTAssertFalse(follow.moved(offset: 90, atEnd: false))
        XCTAssertFalse(follow.dragEnded(atEnd: false), "no snap back when the finger lifts")
        XCTAssertFalse(follow.following)
        // A drag that ends at the end follows again, the button gone while the finger is still down.
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

    /// A drag at the end that never leaves it follows again when it ends, and shows no button meanwhile.
    func testADragThatStaysAtTheEndKeepsFollowing() {
        var follow = ChatFollow()
        follow.dragBegan()
        XCTAssertFalse(follow.showsJump, "the end is still in view")
        XCTAssertFalse(follow.moved(offset: 10, atEnd: true))
        XCTAssertFalse(follow.showsJump)
        XCTAssertFalse(follow.dragEnded(atEnd: true))
        XCTAssertTrue(follow.following)
    }

    /// A drag that took the keyboard down from a following thread keeps it following and goes back to the end, however
    /// far the drag scrolled; the next answer brings no button. Without the keyboard, the same drag leaves the end.
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

    /// The button's animated scroll to the end runs: its offsets never ask for a plain scroll over it, and it follows.
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

    /// The button tapped while a fling toward older rows still runs: the fling's own frames do not end the follow, and
    /// if its inertia outran the scroll to the end, the thread asks to go there once it rests (no button meanwhile).
    func testTheButtonDuringAFlingStillGoesToTheEnd() {
        var follow = ChatFollow()
        XCTAssertFalse(follow.moved(offset: 900, atEnd: true))
        follow.dragBegan()
        _ = follow.moved(offset: 600, atEnd: false)
        // The finger lifted, the thread still moving: the button.
        follow.follow(scrolling: true)
        XCTAssertFalse(follow.showsJump)
        XCTAssertFalse(follow.moved(offset: 400, atEnd: false), "the fling's frames")
        XCTAssertFalse(follow.dragEnded(atEnd: false))
        XCTAssertTrue(follow.rested(atEnd: false), "at rest away from the end: to the end")
        XCTAssertTrue(follow.scrollingToEnd, "that scroll let run")
        XCTAssertFalse(follow.moved(offset: 700, atEnd: false), "its frames")
        XCTAssertFalse(follow.rested(atEnd: true), "at the end: nothing more")
        XCTAssertFalse(follow.scrollingToEnd)
        XCTAssertFalse(follow.showsJump)
    }

    /// The user's own scroll coming to rest up the thread asks for nothing.
    func testAUsersScrollRestsWhereItStops() {
        var follow = ChatFollow()
        follow.dragBegan()
        _ = follow.moved(offset: 300, atEnd: false)
        XCTAssertFalse(follow.dragEnded(atEnd: false))
        XCTAssertFalse(follow.rested(atEnd: false))
        XCTAssertTrue(follow.showsJump)
    }

    /// A send while scrolled up follows the end again, the button gone in the same change.
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

extension ChatFollowTests {
    /// The link's haptic (`ChatLinkHaptic`): a drop warns once the app has been in use a moment, its return is told
    /// after the banner showed for a while; a drop in the background, the reconnect on returning to the app, and a
    /// blink shorter than the banner's read get none.
    func testTheLinkHapticSkipsReconnectsOnReturning() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        var haptic = ChatLinkHaptic(now: start)
        haptic.link(connected: false, now: start.addingTimeInterval(1))
        XCTAssertEqual(haptic.count, 0, "a drop right after the thread opens is the reconnect it opened into")
        haptic.link(connected: true, now: start.addingTimeInterval(2))
        XCTAssertEqual(haptic.count, 0)

        haptic.link(connected: false, now: start.addingTimeInterval(10))
        XCTAssertEqual(haptic.count, 1)
        XCTAssertEqual(haptic.feedback, .warning)
        haptic.link(connected: false, now: start.addingTimeInterval(11))
        XCTAssertEqual(haptic.count, 1, "still down: one warning")
        haptic.link(connected: true, now: start.addingTimeInterval(20))
        XCTAssertEqual(haptic.count, 2)
        XCTAssertEqual(haptic.feedback, .success)

        haptic.link(connected: false, now: start.addingTimeInterval(30))
        haptic.link(connected: true, now: start.addingTimeInterval(31))
        XCTAssertEqual(haptic.count, 3, "back within the moment: only the warning")

        haptic.scene(active: false, now: start.addingTimeInterval(40))
        haptic.link(connected: false, now: start.addingTimeInterval(41))
        haptic.scene(active: true, now: start.addingTimeInterval(100))
        haptic.link(connected: true, now: start.addingTimeInterval(101))
        XCTAssertEqual(haptic.count, 3, "dropped in the background and back on returning: none")
    }
}
