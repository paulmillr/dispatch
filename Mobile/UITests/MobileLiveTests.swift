import XCTest

/// Dispatch for iPhone end to end against this Mac (docs/ios.md, Testing): `scripts/mobile-live-fixture.py start
/// /tmp/sim-…` (a loopback sshd, a private tmux server, `claude` on the login PATH talking to the Claude fixture) and
/// `… serve` must run; `TEST_RUNNER_DISPATCH_LIVE_FIXTURE=/tmp/sim-…/live.json` points here (skipped without it).
/// Adds the Mac as a host with a new key (M8a, trust on first use), sees its session in Spaces, makes a space (M7a)
/// and types into its terminal, starts a chat (M9a), answers an approval (M4b), sees the banner while the sshd is down
/// (M4c) and the thread resume. `TEST_RUNNER_DISPATCH_LIVE_LINUX` (JSON: host, port, user, key, root) adds a Linux
/// host by importing its key file. A second case types into a tab with a long tmux history. Timings print as MEASURE
/// lines; screenshots are attachments.
@MainActor
final class MobileLiveTests: XCTestCase {
    struct Live: Decodable {
        let host: String
        let port: Int
        let user: String
        let root: String
        /// The fixture's project folder (Claude trusts it).
        let work: String
    }

    struct Linux: Decodable {
        let name: String
        let host: String
        let port: Int
        let user: String
        let key: String
        /// The private root on the host: HOME, tmux and herdr sockets for the helper (nothing in the real home).
        let root: String
    }

    override func setUp() {
        continueAfterFailure = false
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var started = Date()
    private func measure(_ name: String, since: Date) {
        print(String(format: "MEASURE e2e.%@ %.2f s", name, Date().timeIntervalSince(since)))
    }

    /// Asks the fixture's serve loop for `command` (the simulator cannot start processes) and waits until it ran.
    private func ask(_ command: String, root: String) throws {
        let requests = URL(fileURLWithPath: root).appendingPathComponent("requests")
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(command)"
        try Data().write(to: requests.appendingPathComponent(name))
        let done = requests.appendingPathComponent(name + ".done")
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: done.path) {
            XCTAssertLessThan(Date(), deadline, "the fixture's serve loop did not run \(command)")
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func wait(_ element: XCUIElement, _ timeout: TimeInterval = 20, _ what: String) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), what)
    }

    private func waitGone(_ element: XCUIElement, _ timeout: TimeInterval = 20) {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        wait(for: [gone], timeout: timeout)
    }

    private func type(_ text: String, into field: XCUIElement) {
        field.tap()
        // The keyboard's first-use tip covers the form once.
        let tip = XCUIApplication().buttons["Continue"]
        if tip.exists { tip.tap() }
        // An empty field reports its placeholder: deleting that many characters is harmless.
        if let value = field.value as? String, !value.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText(text)
    }

    /// The back pill of a pushed screen ("Back, 2 need you", "Back to app").
    private func back(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Back'")).firstMatch
    }

    private func text(containing fragment: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    /// Fills New host (M8a) and creates it; `key` picks the key (made or imported before).
    private func addHost(_ app: XCUIApplication, name: String, host: String, port: Int, user: String, key: () -> Void) {
        let fields = app.textFields
        type(name, into: fields["studio"])
        type(host, into: fields["studio.tail3f.ts.net"])
        type(String(port), into: fields["22"])
        type(user, into: fields["alex"])
        key()
        shot("M8a-\(name)")
        let create = Date()
        app.navigationBars["New host"].buttons["Create"].tap()
        wait(app.staticTexts["Trust this host?"], 30, "the host key question (trust on first use)")
        measure("\(name).create_to_trust_question", since: create)
        shot("TOFU-\(name)")
        let trust = Date()
        app.buttons["Trust"].tap()
        waitGone(app.navigationBars["New host"], 60)
        measure("\(name).trust_to_saved", since: trust)
    }

    func testThisMacEndToEnd() throws {
        guard let path = ProcessInfo.processInfo.environment["DISPATCH_LIVE_FIXTURE"] else {
            throw XCTSkip("No live fixture (TEST_RUNNER_DISPATCH_LIVE_FIXTURE)")
        }
        let live = try JSONDecoder().decode(Live.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let app = XCUIApplication()
        app.launchEnvironment["DISPATCH_MOBILE_STORE"] = "memory"
        app.launchEnvironment["DISPATCH_MOBILE_AUTHORIZE_KEYS"] = live.root + "/authorized_keys"
        if let linux = linux() {
            app.launchEnvironment["DISPATCH_MOBILE_HOST_ENV"] = String(decoding: try JSONEncoder().encode(
                ["\(linux.host):\(linux.port)": ["HOME": linux.root + "/h", "TMUX_TMPDIR": linux.root,
                                                  "HERDR_SOCKET_PATH": linux.root + "/herdr.sock",
                                                  "XDG_CONFIG_HOME": linux.root + "/x"]]), as: UTF8.self)
        }
        app.launch()
        wait(app.staticTexts["No hosts yet"], 15, "M1d")

        // M8a: this Mac with a new ED25519 key (the Debug hook authorizes it on the fixture sshd).
        app.buttons["Add host"].tap()
        wait(app.navigationBars["New host"], 5, "M8a")
        addHost(app, name: "this-mac", host: live.host, port: live.port, user: live.user) {
            app.buttons["Create key…"].tap()
            wait(app.navigationBars["Create key"], 5, "Create key")
            app.navigationBars["Create key"].buttons["Create"].tap()
            waitGone(app.navigationBars["Create key"])
        }

        // Spaces: the private tmux server's session, as tabs.
        let spaces = Date()
        wait(text(containing: "this-mac", in: app), 20, "the fixture's tab in Spaces")
        measure("saved_to_spaces_row", since: spaces)
        shot("M2a-this-mac")

        // M7a through New chat's "New space…" (Agents), then its first tab opens in Terminal.
        app.tabBars.buttons["Agents"].tap()
        app.buttons["New chat"].tap()
        wait(app.staticTexts["New chat"], 5, "M9a")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'this-mac' OR label CONTAINS 'Choose a space'")).firstMatch.tap()
        app.buttons["New space…"].tap()
        wait(app.staticTexts["New space"], 10, "M7a")
        type("e2e", into: app.textFields["Space name"])
        app.buttons["Other folder…"].tap()
        type(live.work, into: app.textFields["~/src/project"])
        shot("M7a")
        let space = Date()
        app.buttons["Create"].tap()
        let terminal = app.textViews["Terminal"]
        wait(terminal, 20, "the new space's terminal tab")
        measure("new_space_to_terminal", since: space)
        let prompt = Date()
        let typed = NSPredicate(format: "value CONTAINS '$' OR value CONTAINS '%' OR value CONTAINS '❯'")
        wait(for: [expectation(for: typed, evaluatedWith: terminal)], timeout: 20)
        measure("terminal_to_prompt", since: prompt)
        terminal.tap()
        let printed = Date()
        app.typeText("printf 'DISPATCH_%s\\n' E2E_OK\n")
        wait(for: [expectation(for: NSPredicate(format: "value CONTAINS 'DISPATCH_E2E_OK'"), evaluatedWith: terminal)], timeout: 20)
        measure("printf_to_output", since: printed)
        shot("M6a-printf")

        // M9a: Claude in a new tab of the space, a message, an approval, an answer.
        back(app).tap()
        app.buttons["New chat"].tap()
        wait(app.staticTexts["New chat"], 5, "M9a")
        let agent = app.buttons["claude"]
        wait(agent, 15, "the host's agents (launches.list)")
        agent.tap()
        shot("M9a")
        let chat = Date()
        app.buttons["Start"].tap()
        // The composer is a text view (CodeComposer, M5e), not a field.
        let composer = app.textViews["Message"]
        wait(composer, 60, "the thread with the composer once Claude is bound")
        measure("start_to_thread", since: chat)
        shot("M3b")
        let approval = Date()
        var sent = false
        // A prompt that is still starting refuses input (docs/ios.md, Helper contract); the session sends once more.
        for _ in 0..<3 where !sent {
            type("permission tool please", into: composer)
            app.buttons["Send"].tap()
            sent = app.buttons["Allow"].waitForExistence(timeout: 30)
        }
        XCTAssertTrue(sent, "the approval (M4b)")
        measure("send_to_approval", since: approval)
        shot("M4b")
        let answered = Date()
        app.buttons["Allow"].tap()
        wait(text(containing: "Tool result received: completed.", in: app), 40, "the tool ran after Allow")
        measure("allow_to_result", since: answered)
        shot("M4a-result")

        // M4c: the sshd and its sessions go away; the banner counts; back, the same conversation goes on.
        let down = Date()
        try ask("stop-sshd", root: live.root)
        wait(text(containing: "Reconnecting to this-mac", in: app), 20, "M4c")
        measure("sshd_down_to_banner", since: down)
        Thread.sleep(forTimeInterval: 2)
        shot("M4c")
        let up = Date()
        try ask("start-sshd", root: live.root)
        waitGone(text(containing: "Reconnecting to this-mac", in: app), 90)
        measure("sshd_up_to_reconnected", since: up)
        let resumed = Date()
        type("hello after the reconnect", into: composer)
        app.buttons["Send"].tap()
        wait(text(containing: "Local Claude fixture reply: hello after the reconnect", in: app), 60, "the thread resumed")
        measure("reconnected_send_to_reply", since: resumed)
        shot("M4a-resumed")

        if let linux = linux() { try linuxHost(app, linux) }
    }

    /// A tab whose tmux history is longer than 8 MiB: its attach replays all of it as one output, which used to
    /// overflow the phone's buffers and end the attachment silently (the screen froze mid-history, keys went nowhere).
    /// The window is made from the fixture's own shell, so only its private server is touched; it closes at the end.
    func testALongTmuxHistoryStaysAttached() throws {
        guard let path = ProcessInfo.processInfo.environment["DISPATCH_LIVE_FIXTURE"] else {
            throw XCTSkip("No live fixture (TEST_RUNNER_DISPATCH_LIVE_FIXTURE)")
        }
        let live = try JSONDecoder().decode(Live.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let app = XCUIApplication()
        app.launchEnvironment["DISPATCH_MOBILE_STORE"] = "memory"
        app.launchEnvironment["DISPATCH_MOBILE_AUTHORIZE_KEYS"] = live.root + "/authorized_keys"
        app.launch()
        wait(app.staticTexts["No hosts yet"], 15, "M1d")
        app.buttons["Add host"].tap()
        wait(app.navigationBars["New host"], 5, "M8a")
        addHost(app, name: "this-mac", host: live.host, port: live.port, user: live.user) {
            app.buttons["Create key…"].tap()
            wait(app.navigationBars["Create key"], 5, "Create key")
            app.navigationBars["Create key"].buttons["Create"].tap()
            waitGone(app.navigationBars["Create key"])
        }
        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS 'this-mac'")).firstMatch
        wait(first, 20, "the fixture's tab in Spaces")
        first.tap()
        let terminal = app.textViews["Terminal"]
        wait(terminal, 20, "the terminal")
        wait(for: [expectation(for: NSPredicate(format: "value CONTAINS '%'"), evaluatedWith: terminal)], timeout: 20)
        terminal.tap()
        // About 13 MiB of history in a new window "big" (the fixture shell's $TMUX is the private server).
        app.typeText("\ntmux set -g history-limit 250000 && tmux new-window -d -n big " +
                     "\"seq -f '%08g lorem ipsum dolor sit amet consectetur adipiscing elit' 1 220000; exec zsh\"\n")
        back(app).tap()
        let big = app.buttons.matching(NSPredicate(format: "label CONTAINS 'big'")).firstMatch
        wait(big, 20, "the big window's tab")
        Thread.sleep(forTimeInterval: 5)
        let opened = Date()
        big.tap()
        wait(terminal, 20, "the big window's terminal")
        wait(for: [expectation(for: NSPredicate(format: "value CONTAINS '%'"), evaluatedWith: terminal)], timeout: 60)
        measure("long_history.tab_to_prompt", since: opened)
        terminal.tap()
        app.typeText("\nprintf 'LONG_%s\\n' OK\n")
        wait(for: [expectation(for: NSPredicate(format: "value CONTAINS 'LONG_OK'"), evaluatedWith: terminal)], timeout: 20)
        shot("M6a-long-history")
        app.typeText("exit\n")
    }

    private func linux() -> Linux? {
        ProcessInfo.processInfo.environment["DISPATCH_LIVE_LINUX"].flatMap { try? JSONDecoder().decode(Linux.self, from: Data($0.utf8)) }
    }

    /// The Linux VM: its key file imported, the linux-aarch64 helper uploaded under the private HOME, its OS label and
    /// multiplexer in host detail, one terminal tab.
    private func linuxHost(_ app: XCUIApplication, _ linux: Linux) throws {
        // Back to Spaces' root, then edit mode's Add host.
        while back(app).exists { back(app).tap() }
        app.tabBars.buttons["Spaces"].tap()
        app.buttons["Edit"].tap()
        app.buttons["Add host"].tap()
        wait(app.navigationBars["New host"], 5, "M8a")
        let file = try String(contentsOfFile: linux.key, encoding: .utf8)
        addHost(app, name: linux.name, host: linux.host, port: linux.port, user: linux.user) {
            app.buttons["Import key…"].tap()
            wait(app.navigationBars["Import key"], 5, "Import key")
            let editor = app.textViews.firstMatch
            editor.tap()
            editor.typeText(file)
            app.navigationBars["Import key"].buttons["Import"].tap()
            waitGone(app.navigationBars["Import key"])
        }
        // M1f: the OS label and the multiplexer the helper reported (its version from multiplexers.versions).
        let detail = Date()
        app.buttons["\(linux.name) details"].tap()
        wait(text(containing: "Ubuntu 26.04", in: app), 30, "the OS label from the helper's host.identity")
        wait(text(containing: "Connected", in: app), 30, "connected")
        wait(text(containing: "tmux 3.6", in: app), 30, "the multiplexer line")
        measure("linux.detail_connected", since: detail)
        shot("M1f-\(linux.name)")
        // Host detail keeps the system back button.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Done"].tap()

        // One terminal tab of the VM's private tmux session.
        let tab = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", linux.name)).firstMatch
        wait(tab, 20, "the VM's tab in Spaces")
        shot("M2a-\(linux.name)")
        let opened = Date()
        tab.tap()
        let terminal = app.textViews["Terminal"]
        wait(terminal, 20, "the VM's terminal")
        wait(for: [expectation(for: NSPredicate(format: "value CONTAINS '$'"), evaluatedWith: terminal)], timeout: 20)
        measure("linux.tab_to_prompt", since: opened)
        shot("M6a-\(linux.name)")
    }
}
