import XCTest
@_spi(Test) import Term
@testable import DispatchApp

/// OSC 7501 program status: the engine keeps each terminal's records as the protocol defines them,
/// and Dispatch shows what they ask of the user.
@MainActor
final class ProgramStatusTests: XCTestCase {
    private func surface() -> Surface {
        Surface(terminal: Terminal(TerminalOptions(cols: 20, rows: 6)), options: HandlerOptions(),
                size: RenderSize(screen: (200, 120), cell: (10, 20)), now: { 0 }, entropy: { [UInt8](repeating: 0, count: $0) })
    }

    private func feed(_ surface: Surface, _ text: String) { Array(text.utf8).withUnsafeBufferPointer { surface.feed($0) } }

    private func report(_ surface: Surface, _ body: String) { feed(surface, "\u{1B}]7501;\(body)\u{1B}\\") }

    private func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    private func records(_ surface: Surface) -> [ProgramStatus] { surface.stream.handler.programs.all }

    /// What the host was told, in order (each message carries every record).
    private func messages(_ surface: Surface) -> [[ProgramStatus]] {
        var out: [[ProgramStatus]] = []
        surface.takeMessages { if case .programStatus(let r) = $0 { out.append(r) } }
        return out
    }

    func testQueryRepliesWithTheSameBodyAndTerminator() {
        let s = surface()
        var replies: [UInt8] = []
        feed(s, "\u{1B}]7501;?\u{1B}\\")
        feed(s, "\u{1B}]7501;?\u{07}")
        s.drain(reply: { replies += $0 }, event: { _ in })
        XCTAssertEqual(String(decoding: replies, as: UTF8.self), "\u{1B}]7501;?\u{1B}\\\u{1B}]7501;?\u{07}")
        // Reports are never answered or read back.
        report(s, "state=working:app=brew:msg=\(b64("secret"))")
        replies = []
        s.drain(reply: { replies += $0 }, event: { _ in })
        XCTAssertEqual(replies, [])
    }

    func testOneProgramReplacesItsRootRecord() {
        let s = surface()
        report(s, "state=working:app=brew:msg=SW5zdGFsbGluZyB1cGRhdGVz")
        XCTAssertEqual(records(s), [ProgramStatus(state: .working, app: "brew", message: "Installing updates", serial: 1)])
        report(s, "state=blocked:kind=auth:app=brew:msg=UGFzc3dvcmQgcmVxdWlyZWQgdG8gaW5zdGFsbCB1cGRhdGVz")
        XCTAssertEqual(records(s), [ProgramStatus(state: .blocked, kind: .auth, app: "brew", message: "Password required to install updates", serial: 2)])
        // A report replaces its record whole: keys it leaves out are gone.
        report(s, "state=done")
        XCTAssertEqual(records(s), [ProgramStatus(state: .done, serial: 3)])
        XCTAssertEqual(messages(s).map(\.count), [1, 1, 1])
        // Padding is optional; the message keeps its exact text.
        report(s, "state=done:app=brew:msg=VXBncmFkZWQgMTIgcGFja2FnZXM")
        XCTAssertEqual(records(s).first?.message, "Upgraded 12 packages")
    }

    func testChildrenInheritAppAndClearWithTheirParent() {
        let s = surface()
        report(s, "state=working:app=deploy:msg=\(b64("Deploying v2.4.1"))")
        report(s, "state=working:id=us-east:title=\(b64("US East")):progress=40:msg=\(b64("Pushing image"))")
        report(s, "state=blocked:kind=permission:id=eu-west:title=\(b64("EU West"))")
        report(s, "state=idle:id=eu-west/canary:app=canary")
        report(s, "state=working:id=eu-west/canary/a")
        let r = records(s)
        XCTAssertEqual(r.map(\.id), ["", "eu-west", "eu-west/canary", "eu-west/canary/a", "us-east"])
        XCTAssertEqual(r.map(\.app), ["deploy", "deploy", "canary", "canary", "deploy"])
        XCTAssertEqual(r.last?.progress, 40)
        XCTAssertEqual(r.last?.title, "US East")
        // A parent need not exist: the root lends its app across the gap.
        report(s, "state=idle:id=x/y")
        XCTAssertEqual(records(s).first { $0.id == "x/y" }?.app, "deploy")
        report(s, "state=clear:id=x")
        report(s, "state=clear:id=eu-west")
        XCTAssertEqual(records(s).map(\.id), ["", "us-east"])
        // "us" is not an ancestor of "us-east".
        report(s, "state=clear:id=us")
        XCTAssertEqual(records(s).map(\.id), ["", "us-east"])
        report(s, "state=clear")
        XCTAssertEqual(records(s), [])
        _ = messages(s)
        // Clearing nothing tells the host nothing.
        report(s, "state=clear")
        XCTAssertEqual(messages(s).count, 0)
    }

    func testPairsAndValuesFollowTheGrammar() {
        let s = surface()
        // Malformed pairs are skipped, unknown keys ignored, the last of a key wins, space is trimmed.
        report(s, "nonsense:=x:Key=v:state=idle:app=a b:future=1: state = working :app=x")
        XCTAssertEqual(records(s), [ProgramStatus(state: .working, app: "x", serial: 1)])
        // kind belongs to blocked, progress to working and blocked; bad values are absent.
        report(s, "state=done:kind=permission:progress=50")
        XCTAssertEqual(records(s).first.map { [$0.kind == nil, $0.progress == nil] }, [true, true])
        for (value, expected) in [("0", UInt8(0)), ("100", 100), ("101", nil), ("-1", nil), ("4.5", nil), ("", nil), ("1000", nil)] as [(String, UInt8?)] {
            report(s, "state=blocked:kind=other:progress=\(value)")
            XCTAssertEqual(records(s).first?.progress, expected, value)
            XCTAssertNil(records(s).first?.kind)
        }
        // An app outside its character set is absent; one past its limit discards the report.
        report(s, "state=idle:app=a,b")
        XCTAssertEqual(records(s).first.map { $0.state == .idle && $0.app == nil }, true)
        report(s, "state=working:app=" + String(repeating: "a", count: 33))
        XCTAssertEqual(records(s).first?.state, .idle)
    }

    func testDiscardedReportsChangeNothing() {
        let s = surface()
        report(s, "state=working:app=keep")
        _ = messages(s)
        let id33 = String(repeating: "x", count: 33)
        let bodies = [
            "app=nostate",                                      // no state
            "state=paused",                                     // unknown state (not idle)
            "state=Working",                                    // states are lowercase words
            "state=done:id=a//b", "state=done:id=/a", "state=done:id=a/", "state=done:id=\(id33)", "state=done:id=a,b",   // bad ids never fall back to the root
            "state=done:id=" + Array(repeating: "a", count: 9).joined(separator: "/"),               // nine levels
            "state=done:msg=Zg=", "state=done:msg=Z",           // not base64
            "state=done:msg=\(b64("line\nbreak"))", "state=done:title=\(b64("bell\u{07}"))", "state=done:msg=\(b64("c1 \u{85}"))",
            "state=done:msg=/w==",                              // not UTF-8
            "state=done:title=\(b64(String(repeating: "t", count: 193)))",
            "state=done:msg=\(b64(String(repeating: "m", count: 2049)))",
            "state=done:" + String(repeating: "k", count: 17) + "=1",   // a key past 16 bytes
        ]
        for body in bodies {
            report(s, body)
            XCTAssertEqual(records(s), [ProgramStatus(state: .working, app: "keep", serial: 1)], body)
        }
        XCTAssertEqual(messages(s).count, 0)
        // The largest messages fit.
        report(s, "state=done:title=\(b64(String(repeating: "t", count: 192))):msg=\(b64(String(repeating: "é", count: 1024)))")
        XCTAssertEqual(records(s).first?.message?.count, 1024)
    }

    func testSequencesPastFourKilobytesAreDiscarded() {
        let s = surface()
        let filler = ":pad=" + String(repeating: "x", count: 4096)
        // 7 bytes of "ESC ] 7501 ;", the body, and the terminator: 4096 at most.
        let fits = "state=idle:app=a:pad=" + String(repeating: "x", count: 4096 - 7 - 2 - "state=idle:app=a:pad=".count)
        report(s, fits)
        XCTAssertEqual(records(s).first?.app, "a")
        report(s, fits + "x")
        report(s, "state=done" + filler)
        feed(s, "\u{1B}]7501;state=done" + filler + "\u{07}")
        XCTAssertEqual(records(s).first?.state, .idle)
        // With BEL the same body has one byte more.
        feed(s, "\u{1B}]7501;" + fits.replacingOccurrences(of: "app=a", with: "app=b") + "x\u{07}")
        XCTAssertEqual(records(s).first?.app, "b")
    }

    func testTheLeastRecentlyUpdatedRecordMakesRoom() {
        let s = surface()
        for i in 0..<ProgramStatusRecords.capacity { report(s, "state=idle:id=r\(i)") }
        // Updating keeps the count and makes the record recent.
        report(s, "state=working:id=r0")
        XCTAssertEqual(records(s).count, ProgramStatusRecords.capacity)
        report(s, "state=idle:id=new")
        let ids = Set(records(s).map(\.id))
        XCTAssertEqual(ids.count, ProgramStatusRecords.capacity)
        XCTAssertTrue(ids.contains("r0") && ids.contains("new"))
        XCTAssertFalse(ids.contains("r1"))
    }

    func testPromptsAndExitsEndWorkingAndBlockedRecords() {
        let s = surface()
        func fill() {
            for (id, state) in [("w", "working"), ("b", "blocked"), ("d", "done"), ("e", "error"), ("i", "idle")] { report(s, "state=\(state):id=\(id)") }
        }
        fill()
        _ = messages(s)
        // Switching screens keeps them (they belong to the terminal).
        feed(s, "\u{1B}[?1049h\u{1B}[?1049l")
        XCTAssertEqual(records(s).count, 5)
        feed(s, "\u{1B}]133;A\u{07}$ ")
        XCTAssertEqual(records(s).map(\.id), ["d", "e", "i"])
        XCTAssertEqual(messages(s).map { $0.map(\.id) }, [["d", "e", "i"]])
        // Another prompt with nothing to end tells the host nothing.
        feed(s, "\u{1B}]133;A\u{07}")
        XCTAssertEqual(messages(s).count, 0)

        fill()
        s.processExited()
        XCTAssertEqual(records(s).map(\.id), ["d", "e", "i"])
        // DECSTR keeps them; a full reset drops every one.
        feed(s, "\u{1B}[!p")
        XCTAssertEqual(records(s).count, 3)
        _ = messages(s)
        feed(s, "\u{1B}c")
        XCTAssertEqual(records(s), [])
        XCTAssertEqual(messages(s).last?.count, 0)
    }

    func testFinishedRecordsShowUntilTheUserTypes() {
        let store = ProgramStatusStore(), tab = UUID()
        store.update(tab, [ProgramStatus(state: .done, app: "brew", serial: 1), ProgramStatus(id: "x", state: .working, serial: 2)])
        XCTAssertEqual(PaneUrgency(session: nil, programs: store.visible(tab)), .running)
        XCTAssertEqual(store.visible(tab).count, 2)
        store.acknowledge(tab)
        XCTAssertEqual(store.visible(tab).map(\.id), ["x"])
        // A later report of the same record is new again.
        store.update(tab, [ProgramStatus(state: .error, app: "brew", serial: 3)])
        XCTAssertEqual(PaneUrgency(session: nil, programs: store.visible(tab)), .unread)
        store.update(tab, [ProgramStatus(state: .blocked, kind: .question, serial: 4)])
        XCTAssertEqual(PaneUrgency(session: nil, programs: store.visible(tab)), .waiting)
        store.close(tab)
        XCTAssertEqual(store.visible(tab), [])
        XCTAssertEqual(PaneUrgency(session: nil, programs: store.visible(tab)), .idle)
    }

    func testShownTextIsDisarmed() {
        // Bidirectional overrides, isolates and zero-width characters go; the program is named.
        let record = ProgramStatus(state: .blocked, kind: .permission, app: "terraform", message: "Apply\u{202E}  3\u{2066} changes\u{200B}?")
        XCTAssertEqual(record.summary, "terraform · Awaiting approval: Apply 3 changes?")
        XCTAssertEqual(ProgramStatus(state: .working, progress: 40, title: "\u{200F}").summary, "Program · Working 40%")
        XCTAssertEqual(ProgramStatus(state: .done, app: "x", title: "US East", message: String(repeating: "m", count: 200)).summary.count,
                       "US East · Done: ".count + 120)
    }
}
