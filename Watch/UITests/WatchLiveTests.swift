import XCTest

/// Taps the watch app (docs/watch.md, Testing). `testScriptedTapsThroughAgentsAndSpaces` plays the scripted phone
/// (`-DispatchWatchScripted 1`) and needs nothing else. `testLiveRoundTripWithThePairedPhone` talks to Dispatch running
/// on the paired iPhone simulator over WatchConnectivity (`./run.sh --watch`) and skips when the phone does not answer.
@MainActor
final class WatchLiveTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// A screenshot attached to the result bundle.
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ app: XCUIApplication, labelStarting text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    private func element(_ app: XCUIApplication, labelContaining text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Waits until `element` is gone (an answered card leaves the page).
    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// Lists are lazy: a row below the screen is not in the tree until scrolled to. True once `element` is on screen.
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 6) -> Bool {
        if element.waitForExistence(timeout: 2), element.isHittable { return true }
        for _ in 0..<swipes {
            // The Digital Crown scrolls a watch list as a wrist does; a swipe can land on a row and only nudge it.
            XCUIDevice.shared.rotateDigitalCrown(delta: 0.3)
            if element.waitForExistence(timeout: 0.5), element.isHittable { return true }
        }
        // A sheet's list does not take the crown in the simulator: drag the frontmost list (the last in the tree).
        let lists = app.collectionViews
        for _ in 0..<swipes where lists.count > 0 {
            lists.element(boundBy: lists.count - 1).swipeUp(velocity: .slow)
            if element.waitForExistence(timeout: 0.5), element.isHittable { return true }
        }
        return element.exists
    }

    private func back(_ app: XCUIApplication) {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        if button.exists { button.tap() } else { app.buttons["BackButton"].tap() }
    }

    // MARK: Scripted

    /// Agents → the approval's thread → Allow; the question's form → an option → Send; a finished thread → Reply → the
    /// confirm screen → Send, then Open on iPhone; Spaces → a host's screen, a space → a tab.
    func testScriptedTapsThroughAgentsAndSpaces() throws {
        let app = launch(["-DispatchWatchScripted", "1"])

        let approvalRow = element(app, labelStarting: "Fix the flaky replay test")
        XCTAssertTrue(approvalRow.waitForExistence(timeout: 15), app.debugDescription)
        approvalRow.tap()
        let allow = app.buttons["Allow"]
        XCTAssertTrue(element(app, labelStarting: "Run the replay tests").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(reveal(allow, in: app), app.debugDescription)
        shot("approval")
        allow.tap()
        XCTAssertTrue(waitForAbsence(allow, timeout: 10), "the card stays after Allow")
        XCTAssertFalse(element(app, labelContaining: "Run the replay tests").exists)
        shot("approved")
        back(app)

        let questionRow = element(app, labelStarting: "Tune the learning rate")
        XCTAssertTrue(questionRow.waitForExistence(timeout: 10), app.debugDescription)
        questionRow.tap()
        let answer = app.buttons["Answer"]
        XCTAssertTrue(reveal(answer, in: app), app.debugDescription)
        answer.tap()
        // The sheet's option, not the agent's message behind it ("Cosine decay won…").
        let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Cosine")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 10), app.debugDescription)
        option.tap()
        let send = app.buttons["Send"]
        XCTAssertTrue(reveal(send, in: app), app.debugDescription)
        XCTAssertTrue(send.isEnabled, "Send stays off with an option chosen")
        shot("question")
        send.tap()
        XCTAssertTrue(waitForAbsence(answer, timeout: 10), "the question stays after Send")
        shot("answered")
        back(app)

        // A finished thread (the release notes): the summary card, Reply through the system input to the confirm screen.
        let notesRow = element(app, labelStarting: "Draft the release notes")
        XCTAssertTrue(reveal(notesRow, in: app), app.debugDescription)
        notesRow.tap()
        XCTAssertTrue(element(app, labelContaining: "first draft grouped by area").waitForExistence(timeout: 10), app.debugDescription)
        self.send("Add the Files changes too", in: app)
        XCTAssertTrue(element(app, labelContaining: "Add the Files changes too").waitForExistence(timeout: 10), app.debugDescription)
        shot("replied")
        let open = app.buttons["Open on iPhone"]
        XCTAssertTrue(reveal(open, in: app), app.debugDescription)
        open.tap()
        XCTAssertTrue(element(app, labelContaining: "on your iPhone").waitForExistence(timeout: 10), app.debugDescription)
        back(app)

        // Spaces is the second vertical page: the Digital Crown scrolls Agents to its end, and a swipe there pages on
        // (the simulated crown stops at the list's end).
        let space = element(app, labelStarting: "dispatch")
        if !reveal(space, in: app, swipes: 4) {
            for _ in 0..<4 where !space.exists {
                app.swipeUp(velocity: .fast)
                _ = space.waitForExistence(timeout: 1)
            }
        }
        XCTAssertTrue(space.waitForExistence(timeout: 5), app.debugDescription)
        shot("spaces")
        // The host's header opens its screen (K6): the statistics strip and its counts.
        let header = app.buttons.matching(NSPredicate(format: "label == 'studio'")).firstMatch
        if !header.isHittable { XCUIDevice.shared.rotateDigitalCrown(delta: -1) }
        XCTAssertTrue(header.waitForExistence(timeout: 5), app.debugDescription)
        header.tap()
        XCTAssertTrue(element(app, labelContaining: "CPU 34 percent").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(element(app, labelStarting: "2 spaces").waitForExistence(timeout: 5) || element(app, labelContaining: "spaces ·").exists,
                      app.debugDescription)
        shot("host")
        back(app)
        XCTAssertTrue(space.waitForExistence(timeout: 5), app.debugDescription)
        space.tap()
        let tab = element(app, labelStarting: "zsh")
        XCTAssertTrue(tab.waitForExistence(timeout: 10), app.debugDescription)
        tab.tap()
        XCTAssertTrue(element(app, labelContaining: "Terminal on your iPhone").waitForExistence(timeout: 10), app.debugDescription)
        shot("tab")
    }

    // MARK: Live

    /// The phone's live fixture (docs/ios.md, Testing, Live fixture: `TEST_RUNNER_DISPATCH_LIVE_FIXTURE`): its Claude Code
    /// answers every message with "Local Claude fixture reply: <text>", runs a tool after Allow and reports "Tool result
    /// received: completed.", and holds a turn whose prompt starts with `FIXTURE_BARRIER_<32 hex>` until it is released
    /// or 20 s pass. Without it the live cases check only that the phone's replies come back without a failure.
    private var fixture: Bool { ProcessInfo.processInfo.environment["DISPATCH_LIVE_FIXTURE"] != nil }

    /// Launches the app and waits for the phone's rows; skips when the phone does not answer.
    private func launchWithThePhone() throws -> (XCUIApplication, rows: XCUIElementQuery, away: XCUIElement) {
        let app = launch()
        let rows = app.collectionViews.firstMatch.buttons.matching(NSPredicate(format: "label != 'Refresh'"))
        let waiting = element(app, labelContaining: "Waiting for your iPhone")
        let away = element(app, labelContaining: "out of reach")
        // The phone answers `hello` within seconds when Dispatch runs there; its rows arrive with it.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, rows.count == 0 || away.exists {
            Thread.sleep(forTimeInterval: 0.5)
        }
        if rows.count == 0 || away.exists || waiting.exists {
            shot("no phone")
            throw XCTSkip("The paired iPhone did not answer within 10 s: run Dispatch there first (./run.sh --watch, "
                          + "docs/watch.md, Testing).")
        }
        return (app, rows, away)
    }

    /// Opens the first row and waits for the phone's page (a host that must connect first takes up to the phone's 15 s
    /// budget; the watch gives up at 20 s).
    private func openFirstThread(_ app: XCUIApplication, rows: XCUIElementQuery) {
        rows.element(boundBy: 0).tap()
        let loading = element(app, labelContaining: "Loading conversation")
        _ = loading.waitForExistence(timeout: 2)
        XCTAssertTrue(waitForAbsence(loading, timeout: 25), "no page within the watch's 20 s timeout")
        XCTAssertFalse(app.buttons["Try Again"].exists, "the thread request failed: \(app.debugDescription)")
    }

    /// A failure line on the page (`ThreadScreen`'s).
    private func failureLine(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "thread.failure").firstMatch
    }

    /// Waits until a text containing `fragment` is on the page, scrolling down with the crown (new items are last).
    private func waitForText(_ fragment: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let target = element(app, labelContaining: fragment)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if target.exists { return true }
            XCUIDevice.shared.rotateDigitalCrown(delta: 0.5)
            _ = target.waitForExistence(timeout: 1)
        }
        return target.exists
    }

    /// Types `text` into Reply (`TextFieldLink`: the system's text input, typed into as a keyboard would), submits it and
    /// sends it from the confirm screen (K5).
    private func send(_ text: String, in app: XCUIApplication) {
        let composer = app.buttons["Reply"]
        XCTAssertTrue(reveal(composer, in: app, swipes: 10), app.debugDescription)
        composer.tap()
        // The system input opens on its keyboard (a 46 mm watch) with the text view focused; Done submits.
        let field = app.textViews.matching(NSPredicate(format: "placeholderValue != nil")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the text input: \(app.debugDescription)")
        field.typeText(text)
        shot("typed")
        let done = app.navigationBars.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3) && done.isEnabled, app.debugDescription)
        done.tap()
        // The confirm screen: the words in the pink bubble, then Send.
        XCTAssertTrue(element(app, labelStarting: "Your reply: " + text).waitForExistence(timeout: 10), app.debugDescription)
        shot("confirm")
        let confirm = app.buttons["Send"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.tap()
    }

    /// The phone app's own rows over WatchConnectivity: the first conversation opens with the phone's page, Open on
    /// iPhone is answered, and an action on it comes back without a failure line. Against the live fixture (the phone's conversation waiting on an
    /// approval, docs/watch.md, Verified on simulators) it goes on: Allow runs the tool, a message from the composer
    /// reaches the agent and its reply shows, and Stop ends a held turn. The phone's side shows in its log
    /// (`yachts.dispatch.mobile`, category `Watch`: "Request answer … received", "Answered answer … with thread").
    func testLiveRoundTripWithThePairedPhone() throws {
        let (app, rows, away) = try launchWithThePhone()
        shot("agents")
        // Refresh: the phone retries its hosts and answers with its lists. While a request is on its way (launch's
        // `hello` first) the button shows a spinner in place of its arrow, whose image names the button.
        let idle = app.navigationBars.buttons.matching(identifier: "arrow.clockwise").firstMatch
        if idle.waitForExistence(timeout: 10) {
            idle.tap()
            _ = waitForAbsence(idle, timeout: 3)
            XCTAssertTrue(idle.waitForExistence(timeout: 25), "no reply to refresh")
            XCTAssertFalse(away.exists, app.debugDescription)
        }
        openFirstThread(app, rows: rows)
        shot("thread")
        // Open on iPhone: the phone shows the conversation (or posts a notification that opens it) and answers `done`.
        let open = app.buttons["Open on iPhone"]
        XCTAssertTrue(reveal(open, in: app, swipes: 10), app.debugDescription)
        open.tap()
        XCTAssertTrue(element(app, labelContaining: "on your iPhone").waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertFalse(failureLine(app).exists, app.debugDescription)
        shot("opened")
        if fixture { return try fixtureActions(app) }

        // The first action the page offers, as a user would pick it: an approval, a question, Stop.
        let action = ["Allow", "Answer", "Stop"].first { reveal(app.buttons[$0], in: app, swipes: 2) }
        switch action {
        case "Allow"?, "Stop"?:
            app.buttons[action!].tap()
        case "Answer"?:
            app.buttons["Answer"].tap()
            let option = app.collectionViews.firstMatch.buttons.element(boundBy: 0)
            XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
            option.tap()
            XCTAssertTrue(reveal(app.buttons["Send"], in: app), app.debugDescription)
            app.buttons["Send"].tap()
        default:
            // Scripted phone hosts (DISPATCH_MOBILE_SCRIPTED) never verify a conversation: no action is offered.
            shot("no action")
            print("No approval, question or Stop on the first conversation: the round trip ends at the page.")
            return
        }
        assertStaysGone(app.buttons[action!], app)
        shot("acted")
    }

    /// The card leaves at once (optimistic); a failed reply puts it back with a failure line (`WatchModel.act`), so it
    /// must stay gone for as long as the phone may take to answer (its 15 s budget and the link's delay).
    private func assertStaysGone(_ element: XCUIElement, _ app: XCUIApplication) {
        XCTAssertTrue(waitForAbsence(element, timeout: 5), app.debugDescription)
        let settled = Date().addingTimeInterval(18)
        while Date() < settled {
            XCTAssertFalse(element.exists, "the action failed and its card came back: \(app.debugDescription)")
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// A question, an approval, a message and Stop on the fixture's conversation. Claude's permission hook waits 60 s
    /// for an answer, then the prompt goes back to Claude's terminal, which the phone shows as a question (Yes / Yes,
    /// and don't ask again / No): an approval left from the phone's side is answered as that question, and the
    /// approval to Allow is asked for from the watch.
    private func fixtureActions(_ app: XCUIApplication) throws {
        let answer = app.buttons["Answer"]
        if !app.buttons["Allow"].exists, reveal(answer, in: app, swipes: 4) {
            shot("question")
            answer.tap()
            let yes = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Yes'")).firstMatch
            // The sheet is a lazy list too: the options sit under the question's text.
            XCTAssertTrue(reveal(yes, in: app, swipes: 8), app.debugDescription)
            yes.tap()
            let send = app.buttons["Send"]
            XCTAssertTrue(reveal(send, in: app), app.debugDescription)
            send.tap()
            assertStaysGone(answer, app)
            XCTAssertTrue(waitForText("Tool result received: completed.", in: app, timeout: 30), app.debugDescription)
            XCTAssertFalse(failureLine(app).exists, app.debugDescription)
            shot("answered")
        }

        let allow = app.buttons["Allow"]
        // The phone's own approval, while its hook still waits, else one asked for from the watch.
        var result = "Tool result received: completed."
        if !allow.exists {
            result = "reply: permission tool please, from the watch"
            send("permission tool please, from the watch", in: app)
            XCTAssertTrue(waitFor(allow, in: app, timeout: 40), "no approval after the message: \(app.debugDescription)")
        }
        XCTAssertTrue(reveal(allow, in: app, swipes: 4), app.debugDescription)
        shot("approval")
        allow.tap()
        assertStaysGone(allow, app)
        // The page follows the phone: the tool ran and the agent said so (the reply quotes the watch's prompt).
        XCTAssertTrue(waitForText(result, in: app, timeout: 30), app.debugDescription)
        XCTAssertFalse(failureLine(app).exists, app.debugDescription)
        shot("allowed")

        try sendAndSeeTheReply(app, text: "hello from the watch")

        // A turn the fixture holds (20 s at most), so the agent works long enough for Stop.
        let barrier = "FIXTURE_BARRIER_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        send(barrier + " hold this turn", in: app)
        let stop = app.buttons["Stop"]
        XCTAssertTrue(waitFor(stop, in: app, timeout: 15), "no Stop while the agent works: \(app.debugDescription)")
        shot("working")
        stop.tap()
        assertStaysGone(stop, app)
        XCTAssertFalse(failureLine(app).exists, app.debugDescription)
        shot("stopped")
    }

    /// Waits for `element` to come on the page (a reply's or a reload's), scrolling down with the crown.
    private func waitFor(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists { return true }
            XCUIDevice.shared.rotateDigitalCrown(delta: 0.5)
            _ = element.waitForExistence(timeout: 1)
        }
        return element.exists
    }

    /// Sends `text` from the composer: it shows as on its way, then as the user's message, and against the fixture the
    /// agent's reply follows.
    private func sendAndSeeTheReply(_ app: XCUIApplication, text: String) throws {
        send(text, in: app)
        XCTAssertTrue(element(app, labelContaining: text).waitForExistence(timeout: 5), "the message on its way: \(app.debugDescription)")
        shot("sending")
        if fixture {
            XCTAssertTrue(waitForText("Local Claude fixture reply: " + text, in: app, timeout: 40), app.debugDescription)
        }
        XCTAssertFalse(failureLine(app).exists, app.debugDescription)
        shot("sent")
    }

    /// One message through the paired phone, nothing else: run with the phone app in the background (docs/watch.md,
    /// Verified on simulators) to see a request wake it, hold its host and send. A suspended phone pushes nothing, so
    /// the agent's reply is fetched as a user would: back, Refresh (the phone holds the host and reads its rows again),
    /// and the thread again.
    func testLiveSendWithThePairedPhone() throws {
        let (app, rows, _) = try launchWithThePhone()
        openFirstThread(app, rows: rows)
        shot("thread")
        let text = "hello while the phone is away"
        send(text, in: app)
        XCTAssertTrue(element(app, labelContaining: text).waitForExistence(timeout: 5), "the message on its way: \(app.debugDescription)")
        shot("sending")
        // The phone's reply (up to its budget) replaces the guess; a failure would put a failure line on the page.
        let settled = Date().addingTimeInterval(18)
        while Date() < settled {
            XCTAssertFalse(failureLine(app).exists, app.debugDescription)
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(element(app, labelContaining: text).exists, app.debugDescription)
        shot("sent")
        guard fixture else { return }
        let reply = "Local Claude fixture reply: " + text
        if !waitForText(reply, in: app, timeout: 5) {
            back(app)
            let idle = app.navigationBars.buttons.matching(identifier: "arrow.clockwise").firstMatch
            XCTAssertTrue(idle.waitForExistence(timeout: 25), app.debugDescription)
            idle.tap()
            _ = waitForAbsence(idle, timeout: 3)
            XCTAssertTrue(idle.waitForExistence(timeout: 25), "no reply to refresh")
            openFirstThread(app, rows: rows)
        }
        XCTAssertTrue(waitForText(reply, in: app, timeout: 30), app.debugDescription)
        shot("reply")
    }
}
