import XCTest

/// The thread on a phone, driven as a user does through the Chat demo (`ChatDemo`, M4a's thread) with the demo peer
/// answering what is sent (`DISPATCH_MOBILE_CHAT_DEMO_ECHO`): "Jump to latest" stays away while the thread follows its
/// end, sending keeps it there, the button leaves once the user is back at the end; the code keys, send's long press and
/// the keyboard's drag down. The samples here run at XCUITest's snapshot pace (50 to 300 ms each): they catch a state
/// that lasts, not one frame. That nothing shows for a frame is `ChatFollowTests`' per-transition check.
@MainActor
final class ChatThreadUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone only") }
    }

    private func launch(echo seconds: Double, codeKeys: Bool = false, demo: String = "M4a") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-appearance", "dark", "-DispatchHardwareKeyboard", "NO"]
        // The code keys' choice is kept in the app's defaults; an argument would hide the choice the case makes, so only
        // a case that needs them on names it.
        if codeKeys { app.launchArguments += ["-composer.codeKeys", "YES"] }
        app.launchEnvironment = ["DISPATCH_MOBILE_STORE": "memory", "DISPATCH_MOBILE_CHAT_DEMO": demo,
                                 "DISPATCH_MOBILE_CHAT_DEMO_ECHO": String(seconds)]
        app.launch()
        return app
    }

    /// A screenshot attached to the result, and written to `DISPATCH_UI_SHOTS` when set (for review).
    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["DISPATCH_UI_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    private func jump(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chat-jump-latest").firstMatch
    }

    /// Types `text` into the idle composer and taps Send.
    private func send(_ text: String, in app: XCUIApplication) {
        type(text, in: app)
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
    }

    /// Focuses the composer (`placeholder`) and types `text`.
    private func type(_ text: String, in app: XCUIApplication, placeholder: String = "Message") {
        let field = app.textViews[placeholder]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        // The demo's thread settles after launch; a tap during that can miss focus.
        for _ in 0..<5 where !(field.value(forKey: "hasKeyboardFocus") as? Bool ?? false) {
            field.tap()
            _ = eventually(1) { field.value(forKey: "hasKeyboardFocus") as? Bool ?? false }
        }
        field.typeText(text)
    }

    /// A flick on the thread, between the header and the composer: `down` reads back up.
    private func scroll(_ app: XCUIApplication, down: Bool) {
        let window = app.windows.firstMatch
        let top = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let bottom = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        (down ? top : bottom).press(forDuration: 0.05, thenDragTo: down ? bottom : top, withVelocity: .fast,
                                    thenHoldForDuration: 0)
    }

    /// Samples `condition` for `seconds` at XCUITest's snapshot pace (each sample takes 50 to 300 ms); the times it held.
    private func sample(for seconds: TimeInterval, _ condition: () -> Bool) -> Int {
        let end = Date().addingTimeInterval(seconds)
        var held = 0
        while Date() < end { if condition() { held += 1 } }
        return held
    }

    private func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    /// The answer's last line is on screen, above the composer: the thread followed its end.
    private func atEnd(_ app: XCUIApplication, line: String) -> Bool {
        let answer = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", line)).firstMatch
        let field = app.textViews.firstMatch
        guard answer.exists, field.exists else { return false }
        return answer.frame.maxY <= field.frame.minY && answer.frame.maxY > field.frame.minY - 200
    }

    /// Sent at the end, the message and its answer arrive with the thread still following: no button in any sample, and
    /// the answer's end is what shows.
    func testSendingKeepsTheThreadAtItsEndWithoutTheJumpPill() {
        let app = launch(echo: 1.5)
        send("Check the retry path", in: app)
        let shown = sample(for: 3.5) { jump(app).exists }
        XCTAssertEqual(shown, 0, "Jump to latest showed while the thread followed its end")
        XCTAssertTrue(eventually { atEnd(app, line: "Line 6 of the answer to “Check the retry path”") },
                      "the answer's end shows")
        // A second exchange, on the longer thread.
        send("And the refund path", in: app)
        XCTAssertEqual(sample(for: 3.5) { jump(app).exists }, 0, "Jump to latest showed after the second send")
        XCTAssertTrue(eventually { atEnd(app, line: "Line 6 of the answer to “And the refund path”") })
    }

    /// Scrolled up while an answer arrives, the button shows with its count; back at the end it leaves at once and does
    /// not come back.
    func testTheJumpPillLeavesAsSoonAsTheThreadIsBackAtItsEnd() {
        let app = launch(echo: 3)
        send("Check the retry path", in: app)
        let followed = eventually(6) { atEnd(app, line: "Line 6 of the answer to “Check the retry path”") }
        shot("jump-first-answer")
        XCTAssertTrue(followed, "the first answer's end shows")
        XCTAssertFalse(jump(app).exists)
        send("And the refund path", in: app)
        // Read back up before the answer comes.
        scroll(app, down: true)
        shot("jump-scrolled-up")
        let arrived = jump(app).waitForExistence(timeout: 6)
        shot("jump-answer-arrived")
        XCTAssertTrue(arrived, "the answer arrived while scrolled up")
        // Back to the end by hand.
        for _ in 0..<4 where jump(app).exists { scroll(app, down: false) }
        XCTAssertTrue(eventually(2) { !jump(app).exists }, "the button leaves at the end")
        XCTAssertEqual(sample(for: 2) { jump(app).exists }, 0, "and stays away")
    }

    /// The button's own tap goes to the end and the button leaves.
    func testTheJumpPillTakesTheThreadToItsEnd() {
        let app = launch(echo: 3)
        send("Check the retry path", in: app)
        let followed = eventually(6) { atEnd(app, line: "Line 6 of the answer to “Check the retry path”") }
        shot("jump-first-answer")
        XCTAssertTrue(followed, "the first answer's end shows")
        send("And the refund path", in: app)
        scroll(app, down: true)
        let button = jump(app)
        XCTAssertTrue(button.waitForExistence(timeout: 6))
        button.tap()
        XCTAssertTrue(eventually(2) { !jump(app).exists }, "the button leaves")
        XCTAssertEqual(sample(for: 1.5) { jump(app).exists }, 0)
    }

    /// The button tapped while a fling toward older rows still runs (its inertia): the fling stops and the thread goes to
    /// its end; the button leaves and stays away.
    func testTheJumpButtonStopsAFlingAndGoesToTheEnd() {
        let app = launch(echo: 0.5)
        for (index, text) in ["Check the retry path", "And the refund path", "Then the webhook path"].enumerated() {
            send(text, in: app)
            XCTAssertTrue(eventually(6) { atEnd(app, line: "Line 6 of the answer to “\(text)”") }, "answer \(index + 1)")
        }
        // A long, fast fling toward the top, and the button the moment it shows, the thread still moving.
        let window = app.windows.firstMatch
        // Above the keyboard: a drag into it takes it down and keeps the thread following.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            .press(forDuration: 0.02, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)),
                   withVelocity: XCUIGestureVelocity(4000), thenHoldForDuration: 0)
        let button = jump(app)
        XCTAssertTrue(button.waitForExistence(timeout: 2))
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let reached = eventually(3) { atEnd(app, line: "Line 6 of the answer to “Then the webhook path”") }
        shot("jump-after-fling")
        XCTAssertTrue(reached, "at the end")
        XCTAssertEqual(sample(for: 1.5) { jump(app).exists }, 0, "the button stays away")
    }

    // MARK: The composer

    private func keyRow(_ app: XCUIApplication) -> XCUIElement { app.buttons["Code block"] }

    /// The code keys stay away by default, focused or not; "+" › Toggle › Code keys brings them above the field, and
    /// again takes them away.
    func testTheCodeKeysShowOnlyAfterPickingThemUnderPlus() {
        let app = launch(echo: 1.5)
        type("Typed", in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        if keyRow(app).exists {
            // An earlier run left them on: start from off.
            app.buttons["Attach"].tap()
            app.buttons["Code keys"].tap()
            XCTAssertTrue(eventually { !keyRow(app).exists })
        }
        XCTAssertFalse(keyRow(app).exists, "no key row when not picked")
        shot("keys-default")
        app.buttons["Attach"].tap()
        let show = app.buttons["Code keys"]
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        show.tap()
        XCTAssertTrue(keyRow(app).waitForExistence(timeout: 5), "picked: the row shows")
        let field = app.textViews.firstMatch
        XCTAssertLessThanOrEqual(keyRow(app).frame.maxY, field.frame.minY, "above the field")
        shot("keys-shown")
        app.buttons["Attach"].tap()
        let hide = app.buttons["Code keys"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        hide.tap()
        XCTAssertTrue(eventually { !keyRow(app).exists }, "hidden again")
    }

    /// Kept: picked in one launch, the keys show in the next one at once; hidden again, they stay away after a relaunch.
    func testTheCodeKeysChoiceIsKept() {
        var app = launch(echo: 1.5)
        type("Typed", in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        if !keyRow(app).exists {
            app.buttons["Attach"].tap()
            app.buttons["Code keys"].tap()
            XCTAssertTrue(keyRow(app).waitForExistence(timeout: 5))
        }
        app.terminate()
        app = launch(echo: 1.5)
        type("Typed", in: app)
        XCTAssertTrue(keyRow(app).waitForExistence(timeout: 5), "kept across launches")
        app.buttons["Attach"].tap()
        app.buttons["Code keys"].tap()
        XCTAssertTrue(eventually { !keyRow(app).exists })
        app.terminate()
        app = launch(echo: 1.5)
        type("Typed", in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(keyRow(app).exists, "hidden, also after a relaunch")
    }

    /// The menu's items (menus draw their items as buttons in a collection).
    private func item(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.collectionViews.buttons[title]
    }

    /// Idle: a long press on send presents one item, Send, and sends nothing; the item sends.
    func testALongPressOnSendOffersSendAloneWhenNothingQueues() {
        let app = launch(echo: 1.5)
        type("Check the retry path", in: app)
        app.buttons["Send"].press(forDuration: 1.2)
        XCTAssertTrue(item(app, "Send").waitForExistence(timeout: 5), "the menu's Send")
        shot("send-menu-idle")
        XCTAssertFalse(item(app, "Queue").exists)
        XCTAssertFalse(item(app, "Send now").exists)
        XCTAssertEqual(app.textViews.firstMatch.value as? String, "Check the retry path", "the long press sent nothing")
        XCTAssertFalse(app.staticTexts["Check the retry path"].exists, "no bubble")
        item(app, "Send").tap()
        XCTAssertTrue(app.staticTexts["Check the retry path"].waitForExistence(timeout: 5), "the item sends")
    }

    /// While the agent works: Send now and Queue, nothing sent by the press; Queue queues.
    func testALongPressOnSendOffersSendNowAndQueueWhileTheAgentWorks() {
        let app = launch(echo: 30)
        send("Check the retry path", in: app)
        type("Also cover invoice.paid", in: app)
        app.buttons["Send"].press(forDuration: 1.2)
        XCTAssertTrue(item(app, "Queue").waitForExistence(timeout: 5))
        XCTAssertTrue(item(app, "Send now").exists)
        XCTAssertFalse(item(app, "Send").exists)
        shot("send-menu-working")
        XCTAssertEqual(app.textViews.firstMatch.value as? String, "Also cover invoice.paid", "the long press sent nothing")
        item(app, "Queue").tap()
        XCTAssertTrue(eventually { (app.textViews.firstMatch.value as? String) != "Also cover invoice.paid" }, "queued: the draft left")
        // The queued bubble's menu opens on a hold only: a tap in passing opens nothing.
        let queued = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Queued:'")).firstMatch
        XCTAssertTrue(queued.waitForExistence(timeout: 5), "the queued bubble")
        queued.tap()
        XCTAssertFalse(item(app, "Delete").waitForExistence(timeout: 1.5), "a tap opens no menu")
        queued.press(forDuration: 1.2)
        XCTAssertTrue(item(app, "Delete").waitForExistence(timeout: 5), "the hold's menu")
        shot("queued-menu")
    }

    /// Reply (Y1): the agent's message's Reply puts its first sentence over the composer, which stays empty; the sent
    /// bubble shows it as a quote on top of the words, and the bar goes.
    func testReplyQuotesTheExcerptOverTheComposer() {
        let app = launch(echo: 1.5)
        let message = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Stripe retries the same event'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10), "the demo's reply")
        message.press(forDuration: 1.2)
        XCTAssertTrue(item(app, "Reply").waitForExistence(timeout: 5), "the long press's Reply")
        item(app, "Reply").tap()
        let bar = app.descendants(matching: .any)["chat-reply-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "the reply bar")
        XCTAssertEqual(app.textViews.firstMatch.value as? String ?? "", "", "the composer stays the user's")
        type("Keep them forever", in: app)
        shot("reply-bar")
        app.buttons["Send"].tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5), "sent: the bar goes")
        let quote = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Replying to'")).firstMatch
        XCTAssertTrue(quote.waitForExistence(timeout: 5), "the sent bubble's quote")
        XCTAssertTrue(app.staticTexts["Keep them forever"].exists, "the words under it")
        shot("reply-sent")
    }

    /// The working row unfolds from a tap anywhere along it but Stop: between Stop and the steps' count too, upright and
    /// on a phone's side. A tap on Stop only brings up its capsule.
    func testATapBetweenStopAndTheStepsUnfoldsTheRow() {
        let app = launch(echo: 1.5, demo: "S6e")
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        let stop = app.descendants(matching: .any)["chat-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "the working row's Stop")
        stop.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-stop-hold"].waitForExistence(timeout: 3), "Stop's capsule")
        XCTAssertFalse(app.buttons["Hide steps"].exists, "a tap on Stop does not unfold the row")
        for side in [false, true] {
            if side {
                XCUIDevice.shared.orientation = .landscapeLeft
                Thread.sleep(forTimeInterval: 2)
            }
            let show = app.buttons["Show steps"]
            XCTAssertTrue(show.waitForExistence(timeout: 5), "folded")
            // Midway between Stop and the chevron, on the line (which unfolding moves up).
            func gap(_ chevron: XCUIElement) -> CGVector {
                CGVector(dx: (stop.frame.maxX + chevron.frame.minX) / 2, dy: stop.frame.midY)
            }
            XCTAssertGreaterThan(show.frame.minX - stop.frame.maxX, 40, "room between Stop and the chevron")
            app.coordinate(withNormalizedOffset: .zero).withOffset(gap(show)).tap()
            let hide = app.buttons["Hide steps"]
            XCTAssertTrue(hide.waitForExistence(timeout: 3), "unfolded from the gap")
            Thread.sleep(forTimeInterval: 0.6)
            shot(side ? "working-unfolded-side" : "working-unfolded")
            app.coordinate(withNormalizedOffset: .zero).withOffset(gap(hide)).tap()
            XCTAssertTrue(app.buttons["Show steps"].waitForExistence(timeout: 3), "folded again from the gap")
        }
    }

    /// "+" groups Code keys, Mine only and Dialog under Toggle; Mine only leaves the user's messages in the thread and the
    /// bar over the composer brings the agent's back.
    func testMineOnlyHidesTheAgentsMessages() {
        let app = launch(echo: 1.5)
        let agent = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Stripe retries the same event'")).firstMatch
        let mine = app.staticTexts["Make billing webhook retries idempotent."].firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: 10), "the agent's reply")
        app.buttons["Attach"].tap()
        let keys = app.buttons["Code keys"], only = app.buttons["Mine only"], dialog = app.buttons["Dialog"]
        XCTAssertTrue(only.waitForExistence(timeout: 5), "Mine only")
        XCTAssertTrue(app.staticTexts["Toggle"].exists, "the group's title")
        // Between the two (the menu opens up from "+", which lists its first items nearest it).
        XCTAssertEqual([keys, only, dialog].map(\.frame.minY).sorted()[1], only.frame.minY, "Mine only between Code keys and Dialog")
        shot("plus-menu")
        only.tap()
        XCTAssertTrue(agent.waitForNonExistence(timeout: 5), "the agent's messages hidden")
        XCTAssertTrue(mine.exists, "the user's stay")
        let bar = app.descendants(matching: .any)["chat-mine-only"]
        XCTAssertTrue(bar.waitForExistence(timeout: 3), "the bar says so")
        shot("mine-only")
        app.buttons["chat-mine-only-show-all"].tap()
        XCTAssertTrue(agent.waitForExistence(timeout: 5), "Show all brings them back")
        XCTAssertFalse(bar.exists)
    }

    /// A user's message's long press has Info, as an agent's has: its details, titled You.
    func testAUserMessagesInfoOpensItsDetails() {
        let app = launch(echo: 1.5)
        let message = app.staticTexts["Make billing webhook retries idempotent."].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10), "the demo's first message")
        message.press(forDuration: 1.2)
        XCTAssertTrue(item(app, "Info").waitForExistence(timeout: 5), "the long press's Info")
        shot("user-message-menu")
        item(app, "Info").tap()
        XCTAssertTrue(app.navigationBars.staticTexts["You"].waitForExistence(timeout: 5), "its details, titled You")
        shot("user-message-details")
    }

    /// With the slash list up, the tap completes the lit command into the draft: the long press says so and sends
    /// nothing.
    func testALongPressOnSendNamesACompletion() {
        let app = launch(echo: 1.5)
        type("/mod", in: app)
        app.buttons["Send"].press(forDuration: 1.2)
        let complete = item(app, "Complete /model")
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        XCTAssertFalse(item(app, "Send").exists)
        shot("send-menu-complete")
        complete.tap()
        XCTAssertTrue(eventually { app.textViews.firstMatch.value as? String == "/model " }, "completed into the draft")
    }

    // MARK: The keyboard

    /// A first exchange, so the thread is longer than the screen, then a second message whose answer comes `echo`
    /// seconds later; the keyboard is up.
    private func secondExchange(_ app: XCUIApplication) {
        send("Check the retry path", in: app)
        XCTAssertTrue(eventually(8) { atEnd(app, line: "Line 6 of the answer to “Check the retry path”") })
        send("And the refund path", in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    }

    /// Drags from the thread's upper part down to `y` (window points).
    private func drag(_ app: XCUIApplication, to y: CGFloat) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.frame.midX, dy: y))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 600, thenHoldForDuration: 0.2)
    }

    /// The keyboard is down and stays down; the thread still follows its end: the answer that comes next shows at the
    /// end with no button.
    private func keyboardDownAndFollowing(_ app: XCUIApplication, shot name: String) {
        let keyboard = app.keyboards.firstMatch
        let window = app.windows.firstMatch
        let down = eventually(3) { !keyboard.exists || keyboard.frame.minY >= window.frame.maxY - 1 }
        shot(name)
        XCTAssertTrue(down, "the keyboard went down")
        XCTAssertEqual(sample(for: 1.5) { keyboard.exists && keyboard.frame.minY < window.frame.maxY - 1 }, 0,
                       "and stays down")
        XCTAssertTrue(eventually(6) { atEnd(app, line: "Line 6 of the answer to “And the refund path”") },
                      "the answer shows at the end: the drag that took the keyboard down kept the thread following")
        shot(name + "-answer")
        XCTAssertEqual(sample(for: 1.5) { jump(app).exists }, 0, "no Jump to latest")
    }

    /// A drag down the thread takes the keyboard down: from the middle of the thread to the field's height (the
    /// composer rides on the keyboard, so the finger meets the keyboard there).
    func testDraggingTheThreadDownDismissesTheKeyboard() {
        let app = launch(echo: 4)
        secondExchange(app)
        drag(app, to: app.textViews.firstMatch.frame.midY)
        keyboardDownAndFollowing(app, shot: "keyboard-dragged-down")
    }

    /// A drag that carries on into the keyboard takes it down as UIKit's interactive dismissal does, and it stays down:
    /// the field does not take focus back when the drag ends.
    func testDraggingIntoTheKeyboardDismissesItForGood() {
        let app = launch(echo: 4)
        secondExchange(app)
        drag(app, to: app.keyboards.firstMatch.frame.minY + 160)
        keyboardDownAndFollowing(app, shot: "keyboard-dragged-into")
    }
}
