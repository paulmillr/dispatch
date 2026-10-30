import Foundation
import Darwin
import XCTest
@testable import DispatchApp

/// The app's packaged helper (rewritten from upstream Helper2Tests for this helper). Each harness's hook payload
/// normalization moved into the helper: helper/bin/tests/hooks.rs bundled_native_hook_round and
/// the harness hook tests cover it.
final class HelperAppTests: XCTestCase {
    private struct Launch: Decodable, Equatable { let key: String }

    func testTransportSuspensionPreservesBoundedOrderedOutput() async throws {
        let incoming = Pipe(), outgoing = Pipe()
        let transport = HelperTransport(read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting, capacity: 5)
        defer { transport.close() }
        let first = UUID(), second = UUID()
        transport.suspend(first, true)
        transport.suspend(second, true)
        transport.send(Data("ab".utf8))
        transport.send(Data("cde".utf8))
        transport.suspend(first, false)
        transport.queue.sync {}
        var descriptor = pollfd(fd: outgoing.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&descriptor, 1, 0), 0)
        let received = expectation(description: "ordered output released")
        let peer = HelperTransport(read: outgoing.fileHandleForReading, write: incoming.fileHandleForWriting)
        defer { peer.close() }
        var output = Data()
        peer.start(receive: { bytes in
            output.append(bytes)
            if output.count == 5 {
                XCTAssertEqual(output, Data("abcde".utf8))
                received.fulfill()
            }
        }, closed: { _ in })
        transport.suspend(second, false)
        await fulfillment(of: [received], timeout: 5)
    }

    func testSuspendedTransportOverflowAndCancellationCloseOnce() async throws {
        for overflow in [false, true] {
            let incoming = Pipe(), outgoing = Pipe()
            let transport = HelperTransport(read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting, capacity: 2)
            let closed = expectation(description: "suspended transport closed")
            closed.assertForOverFulfill = true
            transport.start(receive: { _ in XCTFail("Unexpected input") }, closed: { error in
                XCTAssertEqual((error as? HelperFailure)?.code, overflow ? "limit" : "connection_closed")
                closed.fulfill()
            })
            let token = UUID()
            transport.suspend(token, true)
            transport.send(Data((overflow ? "abc" : "ab").utf8))
            transport.close()
            transport.suspend(token, false)
            await fulfillment(of: [closed], timeout: 5)
        }
    }

    @MainActor
    func testChatRefreshKeepsQuestionClosuresAcrossSubscriptionHandoff() async throws {
        let incoming = Pipe(), outgoing = Pipe()
        let connection = HelperConnection(read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting)
        let peer = HelperTransport(read: outgoing.fileHandleForReading, write: incoming.fileHandleForWriting)
        let chat = HelperChat(terminal: 5)
        defer { chat.close(); connection.close(); peer.close() }
        let retired = expectation(description: "old subscription retired after replacement notification")
        let closed = expectation(description: "close cancels current and pending subscriptions")
        closed.expectedFulfillmentCount = 2
        var decoder = HelperWire.Decoder()
        peer.start(receive: { bytes in
            do {
                try decoder.feed(bytes) { message in
                    if message.kind == .cancel {
                        if message.id == 1 { retired.fulfill() }
                        else if [2, 4].contains(message.id) { closed.fulfill() }
                        else { XCTFail("Unexpected cancellation \(message.id)") }
                    }
                }
            } catch { XCTFail(String(describing: error)) }
        }, closed: { _ in })
        try await connection.configure(limit: 1_048_576, ops: ["chat.open"])
        func event(_ subscription: UInt64, _ id: String) throws -> Data {
            let body: HelperBinary.Value = .object([
                "method": .string("interaction.opened"),
                "params": .object(["terminal": .unsigned(5), "session": .string("thread"),
                    "interaction": .object(["id": .string(id), "approval": .bool(false),
                        "blocking": .bool(false), "questions": .array([])])])])
            return try HelperWire.encode(.init(kind: .notify, id: subscription, body: HelperBinary.encode(body)))
        }
        var received: [String] = []
        let initial = expectation(description: "initial subscription notification")
        let handoff = expectation(description: "ordered handoff notifications")
        let retained = expectation(description: "failed refresh retains original subscription")
        chat.receive = { event in
            guard case .interaction(let interaction) = event else { return }
            received.append(interaction.id)
            if interaction.id == "initial" { initial.fulfill() }
            if interaction.id == "new-close" { handoff.fulfill() }
            if interaction.id == "retained" { retained.fulfill() }
        }
        try await chat.open(connection: connection)
        peer.send(try event(1, "initial"))
        await fulfillment(of: [initial], timeout: 5)
        try await chat.open(connection: connection, refresh: true)
        peer.send(try event(1, "old-close") + event(2, "new-open") + event(1, "late-old") + event(2, "new-close"))
        await fulfillment(of: [handoff, retired], timeout: 5)
        XCTAssertEqual(received, ["initial", "old-close", "new-open", "new-close"])
        let failed = expectation(description: "replacement refusal")
        chat.failed = { error in
            XCTAssertEqual((error as? HelperFailure)?.code, "refused")
            failed.fulfill()
        }
        try await chat.open(connection: connection, refresh: true)
        peer.send(try HelperWire.encode(.init(kind: .response, id: 3, body: HelperBinary.encode(
            .object(["error": .object(["code": .string("refused"), "message": .string("replacement refused")])])))))
        peer.send(try event(2, "retained"))
        await fulfillment(of: [failed, retained], timeout: 5)
        XCTAssertEqual(received, ["initial", "old-close", "new-open", "new-close", "retained"])
        try await chat.open(connection: connection, refresh: true)
        chat.close()
        await fulfillment(of: [closed], timeout: 5)
    }

    /// A chat call first awaits the screen its tab shows (`current`): the publication in flight and, when that one is
    /// older, the next. An agent that redraws before each acknowledgement (a slow link) must not hold the call for its
    /// whole burst, as the publishing loop did: it went on while newer screens came, and `current` awaited the loop.
    @MainActor
    func testCurrentScreenWaitsForAtMostTwoPublicationsWhileTheAgentRedraws() async throws {
        let incoming = Pipe(), outgoing = Pipe(), link = SSHConnectionID()
        let connection = HelperConnection(read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting)
        let peer = HelperTransport(read: outgoing.fileHandleForReading, write: incoming.fileHandleForWriting)
        await HelperApp.shared.borrow(connection, for: link)
        var space = Space(name: "remote", directory: "/remote")
        space.structure([TerminalTab(directory: "/remote")], selected: 0)
        space.remote = link
        let workspace = Workspace()
        workspace.spaces = [space]
        let helper = HelperWorkspace(workspace: workspace, renderer: nil, endpoint: .remote(link), host: .authenticated("remote"))
        let screen = { @Sendable (frame: Int) in
            HelperClient.Screen(terminal: 1, text: "frame \(frame)", cursor: .init(column: 0, row: 0), faint_tail: false)
        }
        final class Agent: @unchecked Sendable { var received: [String] = [], frame = 1 }
        let agent = Agent()
        var decoder = HelperWire.Decoder()
        peer.start(receive: { bytes in
            do {
                try decoder.feed(bytes) { message in
                    guard message.kind == .request, case .object(let body) = try HelperBinary.decode(message.body),
                          body["method"] == .string("terminals.publish"), case .object(let params)? = body["params"],
                          case .string(let text)? = params["text"] else { return }
                    let ack = try HelperWire.encode(.init(kind: .response, id: message.id,
                        body: HelperBinary.encode(.object(["result": .null]))))
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            agent.received.append(text)
                            // The agent redraws before each acknowledgement, up to frame 20.
                            if agent.frame < 20 { agent.frame += 1; helper.publish(screen(agent.frame)) }
                            peer.send(ack)
                        }
                    }
                }
            } catch { XCTFail(String(describing: error)) }
        }, closed: { _ in })
        helper.publish(screen(0))
        helper.publish(screen(1))
        await helper.current(1)
        // Frame 1, shown at the call, was replaced by frame 2 while frame 0 was in flight: frame 2 is the second.
        XCTAssertEqual(agent.received, ["frame 0", "frame 2"])
        helper.stop(); connection.close(); peer.close()
        await HelperApp.shared.forget(link)
    }

    func testSubmittedRequestsKeepOrderAndCompleteIndependently() async throws {
        let incoming = Pipe(), outgoing = Pipe()
        let connection = HelperConnection(read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting)
        let peer = HelperTransport(read: outgoing.fileHandleForReading, write: incoming.fileHandleForWriting)
        let requests = expectation(description: "requests submitted before any response")
        let canceled = expectation(description: "only the abandoned request is canceled")
        var decoder = HelperWire.Decoder()
        var received: [HelperWire.Message] = []
        let expected = try ["first", "second", "third"].enumerated().map { index, method in
            HelperWire.Message(kind: .request, id: UInt64(index + 1), body: try HelperBinary.encode(
                .object(["method": .string(method), "params": .object([:])])))
        }
        peer.start(receive: { bytes in
            do {
                try decoder.feed(bytes) { message in
                    if message.kind == .cancel {
                        XCTAssertEqual(message, .init(kind: .cancel, id: 3, body: Data()))
                        canceled.fulfill()
                    } else {
                        received.append(message)
                        if received.count == expected.count {
                            XCTAssertEqual(received, expected)
                            requests.fulfill()
                        }
                    }
                }
            } catch { XCTFail(String(describing: error)) }
        }, closed: { _ in })
        defer { connection.close(); peer.close() }
        try await connection.configure(limit: 1_048_576, ops: ["first", "second", "third"])
        let refused: HelperConnection.Call<Int> = await connection.submit("unavailable", params: [String: String]())
        do { _ = try await refused.value; XCTFail("Unadvertised request must be refused") }
        catch { XCTAssertEqual((error as? HelperFailure)?.code, "permission_denied") }
        let stopped = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let call: HelperConnection.Call<Int> = await connection.submit("first", params: [String: String]())
            return try await call.value
        }
        do { _ = try await stopped.value; XCTFail("Canceled submission returned a value") }
        catch { XCTAssertTrue(error is CancellationError) }
        let first: HelperConnection.Call<Int> = await connection.submit("first", params: [String: String]())
        let second: HelperConnection.Call<Int> = await connection.submit("second", params: [String: String]())
        let third: HelperConnection.Call<Int> = await connection.submit("third", params: [String: String]())
        await fulfillment(of: [requests], timeout: 5)
        peer.send(try HelperWire.encode(.init(kind: .response, id: 2,
            body: HelperBinary.encode(.object(["result": .unsigned(42)])))))
        let value = try await second.value
        XCTAssertEqual(value, 42, "A later response must be available while the earlier request is pending")
        let failure = HelperFailure(code: "refused", message: "first refused")
        peer.send(try HelperWire.encode(.init(kind: .response, id: 1, body: HelperBinary.encode(
            .object(["error": .object(["code": .string(failure.code), "message": .string(failure.message)])])))))
        do { _ = try await first.value; XCTFail("The first request must fail independently") }
        catch { XCTAssertEqual(error as? HelperFailure, failure) }
        let waiting = Task { try await third.value }
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Canceled request returned a value") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [canceled], timeout: 5)
    }

    func testAppJournalFailureReleasesPendingAndLateListenersOnce() throws {
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let first = try journal.open(kind: "command", input: .string("first"))
        let second = try journal.open(kind: "command", input: .string("second"))
        try first.action(kind: "write", value: .bytes(Data([1])))
        try first.emit(kind: "result")
        try second.emit(kind: "result")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        let pending = try journal.open(kind: "command", input: .string("first"))
        let late = try journal.open(kind: "command", input: .string("second"))
        var failures: [HelperFailure] = []
        var events: [AppReplay.Event] = []
        try pending.listen({ events.append($0) }, failed: { failures.append($0 as! HelperFailure) })
        var firstFailure: HelperFailure?
        XCTAssertThrowsError(try pending.action(kind: "write", value: .bytes(Data([2])))) {
            firstFailure = $0 as? HelperFailure
        }
        try late.listen({ events.append($0) }, failed: { failures.append($0 as! HelperFailure) })
        let expected = try XCTUnwrap(firstFailure)
        XCTAssertEqual(failures, [expected, expected])
        XCTAssertEqual(events, [])
        XCTAssertThrowsError(try pending.action(kind: "write", value: .bytes(Data([3])))) {
            XCTAssertEqual($0 as? HelperFailure, expected)
        }
        XCTAssertEqual(failures, [expected, expected])
        XCTAssertThrowsError(try journal.finish()) { XCTAssertEqual($0 as? HelperFailure, expected) }
    }

    func testAppJournalFailureOnlyNotifiesUnfinishedLifetimes() throws {
        for (kind, before, after) in [
            ("command", ["result"], []),
            ("helper", ["end", "exit"], []),
            ("helper", ["exit", "end"], []),
            ("helper", ["end"], ["exit"]),
        ] {
            let directory = System.temporary.appendingPathComponent(UUID().uuidString)
            let path = directory.appendingPathComponent("app.rpl.zst")
            defer { try? FileManager.default.removeItem(at: directory) }
            var journal = try AppReplay(url: path, replaying: false)
            let first = try journal.open(kind: kind, input: .null)
            for event in before { try first.emit(kind: event) }
            let pending = try journal.open(kind: "command", input: .null)
            try pending.action(kind: "write", value: .bytes(Data([1])))
            for event in after { try first.emit(kind: event) }
            try pending.emit(kind: "result")
            try journal.finish()
            journal = try AppReplay(url: path, replaying: true)
            var received: [String] = []
            var failed: [String] = []
            let previous = try journal.open(kind: kind, input: .null)
            try previous.listen({ received.append($0.kind) }, failed: { _ in failed.append("previous") })
            let current = try journal.open(kind: "command", input: .null)
            try current.listen({ received.append($0.kind) }, failed: { _ in failed.append("current") })
            XCTAssertThrowsError(try current.action(kind: "write", value: .bytes(Data([2]))))
            XCTAssertEqual(received, before.map { "in." + $0 })
            XCTAssertEqual(failed.sorted(), after.isEmpty ? ["current"] : ["current", "previous"])
            XCTAssertThrowsError(try journal.finish())
        }
    }

    func testAppJournalRoutesOverlappingLifetimesAndMatchesReorderedActions() throws {
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let command = try journal.open(kind: "command", input: .string("probe"))
        let helper = try journal.open(kind: "helper", input: .string("stdio"))
        try helper.action(kind: "write", value: .bytes(Data([1])))
        try helper.action(kind: "write", value: .bytes(Data([2])))
        try command.emit(kind: "result", value: .bytes(Data([3])))
        try helper.emit(kind: "end")
        try helper.emit(kind: "exit")
        try journal.finish()
        for order in [[1, 2], [2, 1], [2]] {
            journal = try AppReplay(url: path, replaying: true)
            var events: [AppReplay.Event] = []
            let first = try journal.open(kind: "helper", input: .string("stdio"))
            let second = try journal.open(kind: "command", input: .string("probe"))
            XCTAssertEqual([first.id, second.id], [2, 1])
            try first.listen({ events.append($0) }, failed: { _ in })
            try second.listen({ events.append($0) }, failed: { _ in })
            for value in order { try first.action(kind: "write", value: .bytes(Data([UInt8(value)]))) }
            if order.count == 2 {
                try journal.finish()
                XCTAssertEqual(events, [.init(kind: "in.result", id: 1, value: .bytes(Data([3]))),
                                        .init(kind: "in.end", id: 2, value: .null),
                                        .init(kind: "in.exit", id: 2, value: .null)])
            } else {
                XCTAssertEqual(events, [], "Everything recorded after the missing write waits for it")
                XCTAssertThrowsError(try journal.finish(), "An output whose recorded place is never reached")
            }
        }
    }

    func testAppJournalTakesSequentialAndOverlappingIdenticalCreationsInRecordedOrder() throws {
        for overlap in [false, true] {
            let directory = System.temporary.appendingPathComponent(UUID().uuidString)
            let path = directory.appendingPathComponent("app.rpl.zst")
            defer { try? FileManager.default.removeItem(at: directory) }
            var journal = try AppReplay(url: path, replaying: false)
            let first = try journal.open(kind: "command", input: .null)
            if !overlap { try first.emit(kind: "result", value: .bytes(Data([1]))) }
            let second = try journal.open(kind: "command", input: .null)
            if overlap { try first.emit(kind: "result", value: .bytes(Data([1]))) }
            try second.emit(kind: "result", value: .bytes(Data([2])))
            try journal.finish()
            journal = try AppReplay(url: path, replaying: true)
            var events: [AppReplay.Event] = []
            for _ in 0..<2 {
                let ticket = try journal.open(kind: "command", input: .null)
                try ticket.listen({ events.append($0) }, failed: { XCTFail("Unexpected replay failure: \($0)") })
            }
            try journal.finish()
            XCTAssertEqual(events, [.init(kind: "in.result", id: 1, value: .bytes(Data([1]))),
                                    .init(kind: "in.result", id: 2, value: .bytes(Data([2])))])
        }
    }

    func testAppJournalObservationsAnswerTheStateReplayReached() throws {
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        func ask(_ kind: String, _ value: String = "") throws -> String {
            try AppReplay.decode(String.self, journal.query(kind: "observe." + kind, input: .null) { .string(value) })
        }
        XCTAssertEqual(try ask("alive", "yes"), "yes")
        let command = try journal.open(kind: "command", input: .null)
        try command.action(kind: "kill")
        XCTAssertEqual(try ask("alive", "no"), "no")
        XCTAssertEqual(try ask("started", "late"), "late")
        try command.emit(kind: "result")
        let pending = try journal.open(kind: "pending", input: .null)
        try pending.emit(kind: "result")
        _ = try journal.query(kind: "signal", input: .null) { .null }
        XCTAssertEqual(try ask("alive", "again"), "again")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        // Asked ahead of its recording: its first answer; asked any number of times: what replay reached.
        XCTAssertEqual(try [ask("started"), ask("alive"), ask("alive")], ["late", "yes", "yes"])
        let replayed = try journal.open(kind: "command", input: .null)
        try replayed.listen({ _ in }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        XCTAssertEqual(try ask("alive"), "yes", "The app's own request changes the state only once issued")
        try replayed.action(kind: "kill")
        XCTAssertEqual(try ask("alive"), "no")
        // A synchronous answer is taken at once, even ahead of an earlier input nobody receives yet.
        _ = try journal.open(kind: "pending", input: .null)
        _ = try journal.query(kind: "signal", input: .null) { .null }
        XCTAssertEqual(try ask("alive"), "again", "Its asker observes the state after it")
        // A question capture never asked (a poll got to a process capture's polls never reached) fails to its asker;
        // the replay goes on and lists it.
        XCTAssertThrowsError(try ask("unrecorded")) { XCTAssertEqual(($0 as? HelperFailure)?.code, "unrecorded") }
        XCTAssertEqual(try ask("alive"), "again")
        XCTAssertEqual(journal.relaxed, ["unrecorded observe.unrecorded null"])
    }

    func testAppJournalWorkATestDoesLiveIsNotIdle() throws {
        // Work a test does live on purpose (real shells running the app's wrappers) is not in the journal: while it runs
        // inside `live`, replay waits for it instead of calling the app idle.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let recorded = try journal.open(kind: "connection", input: .null)
        try recorded.action(kind: "write", value: .bytes(Data([1])))
        try recorded.emit(kind: "exit")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        var failures: [String] = []
        let connection = try journal.open(kind: "connection", input: .null), replayed = journal, done = DispatchSemaphore(value: 0)
        try connection.listen({ _ in }, failed: { failures.append("\($0)") })
        DispatchQueue.global().async { replayed.live { Thread.sleep(forTimeInterval: 3.5) }; done.signal() }
        RunLoop.main.run(until: Date().addingTimeInterval(3.5))
        done.wait()
        XCTAssertEqual(failures, [], "Its live work still runs: not idle")
        try connection.action(kind: "write", value: .bytes(Data([1])))
        try journal.finish()
    }

    func testAppJournalAppStillHandlingWhatReplayHandedOverIsNotIdle() throws {
        // Replay hands recorded input over at once; a consumer that handles it on its own queue (a helper connection
        // decoding a burst of topologies) may still be working through it while the main queue answers. What the app
        // sends after that work (a request queued behind it) is not a stall: the app is not idle until those queues answer.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let recorded = try journal.open(kind: "connection", input: .null)
        try recorded.emit(kind: "read", value: .bytes(Data([1])))
        try recorded.action(kind: "write", value: .bytes(Data([2])))
        try recorded.emit(kind: "exit")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        let queue = DispatchQueue(label: "yachts.dispatch.tests.consumer"), backlog = DispatchSemaphore(value: 0)
        var failures: [String] = [], events: [String] = []
        let connection = try journal.open(kind: "connection", input: .null)
        connection.through(queue)
        queue.async { backlog.wait() }
        try connection.listen({ event in queue.async { events.append(event.kind) } }, failed: { failures.append("\($0)") })
        RunLoop.main.run(until: Date().addingTimeInterval(3.5))
        XCTAssertEqual(failures, [], "Its queue still works: not idle")
        backlog.signal()
        queue.sync {}
        try connection.action(kind: "write", value: .bytes(Data([2])))
        queue.sync {}
        XCTAssertEqual(events, ["in.read", "in.exit"])
        try journal.finish()
    }

    func testAppJournalEverythingFinishesInRecordedOrderWhileRequestsGoOutInAnyOrder() throws {
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let command = try journal.open(kind: "command", input: .null), mailbox = try journal.open(kind: "mailbox", input: .null)
        try command.action(kind: "write", value: .bytes(Data([1])))
        try command.emit(kind: "read", value: .bytes(Data([2])))
        try mailbox.emit(kind: "file", value: .bytes(Data([3])))
        try command.action(kind: "close")
        try mailbox.emit(kind: "exit")
        try command.emit(kind: "exit")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        var events: [AppReplay.Event] = []
        try journal.open(kind: "mailbox", input: .null).listen({ events.append($0) }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        XCTAssertEqual(events, [], "The file waits for the command's earlier read")
        let replayed = try journal.open(kind: "command", input: .null)
        try replayed.listen({ events.append($0) }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        try replayed.action(kind: "close")
        XCTAssertEqual(events, [], "Requests go out in any order; the read still waits for the earlier write")
        try replayed.action(kind: "write", value: .bytes(Data([1])))
        try journal.finish()
        XCTAssertEqual(events, [.init(kind: "in.read", id: 1, value: .bytes(Data([2]))), .init(kind: "in.file", id: 2, value: .bytes(Data([3]))),
                                .init(kind: "in.exit", id: 2, value: .null), .init(kind: "in.exit", id: 1, value: .null)])
    }

    /// Steps are the test's (main actor): the wake is reached on the main queue's next turn.
    @MainActor
    func testAppJournalStepHoldsLaterInputsUntilItsCallerReachesIt() async throws {
        // Capture saw the caller's question before or after an input that came in meanwhile: either way the caller
        // asks it before replay delivers that input.
        for late in [false, true] {
            let directory = System.temporary.appendingPathComponent(UUID().uuidString)
            let path = directory.appendingPathComponent("app.rpl.zst")
            defer { try? FileManager.default.removeItem(at: directory) }
            var journal = try AppReplay(url: path, replaying: false)
            let command = try journal.open(kind: "command", input: .null)
            try command.emit(kind: "read", value: .bytes(Data([1])))
            _ = try journal.query(kind: "observe.state", input: .null) { .string("before") }
            try command.action(kind: "write", value: .bytes(Data([9])))
            try await journal.open(kind: "clock", input: .null).reach()
            if late { try command.emit(kind: "read", value: .bytes(Data([2]))) }
            _ = try journal.query(kind: "observe.state", input: .null) { .string("after") }
            if !late { try command.emit(kind: "read", value: .bytes(Data([2]))) }
            try command.emit(kind: "exit")
            try journal.finish()
            journal = try AppReplay(url: path, replaying: true)
            // Its consumer handles input on its own queue, slower than the step is reached.
            let queue = DispatchQueue(label: "consumer")
            var events: [AppReplay.Event] = []
            let replayed = try journal.open(kind: "command", input: .null)
            replayed.through(queue)
            try replayed.listen({ event in queue.async { usleep(20_000); events.append(event) } }, failed: { XCTFail("Unexpected replay failure: \($0)") })
            XCTAssertEqual(try journal.query(kind: "observe.state", input: .null) { .null }, .string("before"))
            // The app's output the recording has before the step comes from another thread, which so reaches the wake.
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) { try? replayed.action(kind: "write", value: .bytes(Data([9]))) }
            try await journal.open(kind: "clock", input: .null).reach()
            XCTAssertEqual(events.map(\.value), [.bytes(Data([1]))],
                           "The caller runs after its consumers handled what came before its step, before anything recorded after it")
            XCTAssertEqual(try journal.query(kind: "observe.state", input: .null) { .null }, .string("after"),
                           "The caller has reached its step: it sees what the recording saw there")
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            queue.sync {}
            XCTAssertEqual(events.map(\.value), [.bytes(Data([1])), .bytes(Data([2])), .null])
            try journal.finish()
        }
    }

    func testAppJournalTestsPolledQueryIsAReadAskedAsOftenAsItPolls() async throws {
        // A test's condition asks the outside world (a fixture's `tmux list-panes`) as often as it checks, and how often
        // it checks is wall time (a check refuses while a sidebar slides): replay answers each such ask with what capture
        // saw as far as the app got, however often it is asked, and owes none of the recorded asks.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        func poll(_ value: String = "") async throws -> String {
            try await journal.checking { try System.$polling.withValue(true) {
                try AppReplay.decode(String.self, journal.query(kind: "fixture.panes", input: .null) { .string(value) })
            } }
        }
        var asked = [try await poll("old")]
        let command = try journal.open(kind: "command", input: .null)
        try command.action(kind: "kill")
        asked += [try await poll("new"), try await poll("new")]
        XCTAssertEqual(asked, ["old", "new", "new"])
        try await journal.open(kind: "step", input: .null).reach(.object(["at": .string("site")]))
        try command.emit(kind: "exit")
        try journal.finish()
        for asks in [5, 1] {
            journal = try AppReplay(url: path, replaying: true)
            let replayed = try journal.open(kind: "command", input: .null)
            try replayed.listen({ _ in }, failed: { XCTFail("Unexpected replay failure: \($0)") })
            var answers: [String] = []
            try await journal.waiting {
                answers.append(try await poll())
                answers.append(try await poll())
                try replayed.action(kind: "kill")
                for _ in 0..<asks { answers.append(try await poll()) }
            }
            try await journal.open(kind: "step", input: .null).reach()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            XCTAssertEqual(answers, ["old", "old"] + Array(repeating: "new", count: asks))
            XCTAssertNoThrow(try journal.finish())
            XCTAssertEqual(journal.relaxed, [])
        }
    }

    func testAppJournalWaitingTestSeesTheStateItsCheckSaw() async throws {
        // Capture reads input while the test checks its condition: what came after the check (a redraw that clears what
        // the test waited for) is still before the step. The step carries where the check was; while the test waits,
        // replay holds what came after it. A check itself may read through the app's connections: those come through.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let screen = try journal.open(kind: "command", input: .string("screen"))
        try screen.emit(kind: "read", value: .bytes(Data([1])))
        let mark = journal.mark
        try screen.emit(kind: "read", value: .bytes(Data([2])))
        let check = try journal.open(kind: "command", input: .string("check"))
        try check.emit(kind: "result", value: .bytes(Data([7])))
        try await journal.open(kind: "step", input: .null).reach(.object(["at": .string("site"), "mark": .unsigned(UInt64(mark))]))
        try screen.emit(kind: "exit")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        let replayed = try journal.open(kind: "command", input: .string("screen"))
        var events: [Data] = [], result: Data?
        try await journal.waiting {
            try replayed.listen({ events.append(AppReplay.bytes($0.value)) }, failed: { XCTFail("Unexpected replay failure: \($0)") })
            XCTAssertEqual(events, [Data([1])], "What capture read after the check waits")
            try await journal.checking {
                let own = try journal.open(kind: "command", input: .string("check"))
                try own.listen({ result = AppReplay.bytes($0.value) }, failed: { XCTFail("Unexpected replay failure: \($0)") })
            }
            XCTAssertEqual(result, Data([7]), "The check's own read, after what was recorded before it")
        }
        try await journal.open(kind: "step", input: .null).reach()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(events, [Data([1]), Data([2]), Data()])
        try journal.finish()
    }

    func testAppJournalFailingCheckFreesWhatItsCheckMayHaveSeen() async throws {
        // Capture reads on while the test checks: an input read while the check ran may be on what it read (pty output
        // parsed before the screen was read) or not (a redraw clearing what the test waited for). A condition that holds
        // on what came before the check gets nothing more; one that fails on the settled state (twice: the app may need
        // a turn to react) frees what the check may have seen: one input, then as many as passed so far (a flood comes in
        // a few rounds), never what was read after the check returned.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let screen = try journal.open(kind: "command", input: .null)
        try screen.emit(kind: "read", value: .bytes(Data([1])))
        let mark = journal.mark
        for byte in 2...9 as ClosedRange<UInt8> { try screen.emit(kind: "read", value: .bytes(Data([byte]))) }
        let end = journal.mark
        try screen.emit(kind: "read", value: .bytes(Data([10])))
        try await journal.open(kind: "step", input: .null).reach(.object([
            "at": .string("site"), "mark": .unsigned(UInt64(mark)), "end": .unsigned(UInt64(end))]))
        try screen.emit(kind: "read", value: .bytes(Data([11])))
        try screen.emit(kind: "exit")
        try journal.finish()
        final class Screen: @unchecked Sendable { let lock = NSLock(); var shown: [UInt8] = [] }
        // What the condition holds on (exactly that: a redraw ends what it waited for); what the checks saw last. The whole
        // window comes within 12 checks (one input per round would take 16).
        for (holds, seen) in [([1], [1]), ([1, 2], [1, 2]), ([1, 2, 3], [1, 2, 3]), (Array(1...9), Array(1...9)), (Array(1...10), Array(1...9))]
            as [([UInt8], [UInt8])] {
            journal = try AppReplay(url: path, replaying: true)
            let replayed = try journal.open(kind: "command", input: .null), queue = DispatchQueue(label: "consumer"), screen = Screen()
            replayed.through(queue)
            let checked = try await journal.waiting { () async throws -> [UInt8] in
                try replayed.listen({ event in
                    queue.async { usleep(1_000); screen.lock.withLock { screen.shown += AppReplay.bytes(event.value) } }
                }, failed: { XCTFail("Unexpected replay failure: \($0)") })
                for _ in 0..<12 {
                    let mark = journal.mark
                    if try await journal.checking({ screen.lock.withLock { screen.shown } == holds }) { break }
                    await journal.advance(mark)
                    try await Task.sleep(for: .milliseconds(5))
                }
                await journal.settle()
                return screen.lock.withLock { screen.shown }
            }
            XCTAssertEqual(checked, seen, "Failing checks free what the check may have seen, none read after it")
            try await journal.open(kind: "step", input: .null).reach()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            queue.sync {}
            XCTAssertEqual(screen.lock.withLock { screen.shown }, Array(1...11))
            try journal.finish()
        }
    }

    func testAppJournalCheckGetsOnlyItsOwnIOPastTheHold() async throws {
        // A check may read through the app's connections (a remote file through the helper) or start its own probe:
        // capture recorded that between where the check began and returned. Replay answers it past the hold; what the
        // check did not ask for (a redraw read meanwhile; the answer to a chat.open the app sent while the check ran, which
        // the test must not see before it continues) stays held until the step. A check that keeps failing still frees
        // what it may have seen: its own I/O is not the app's progress.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        let read = try HelperWire.encode(.init(kind: .request, id: 1, body: HelperBinary.encode(.object([
            "method": .string("files.text"), "params": .object(["path": .string("hooks.json")])]))))
        let answer = try HelperWire.encode(.init(kind: .response, id: 1, body: HelperBinary.encode(.object(["result": .string("hooks")]))))
        let closed = try AppReplay.value(AppReplay.Failure(HelperFailure(code: "connection_closed", message: "Helper disconnected.")))
        let chatOpen = try HelperWire.encode(.init(kind: .request, id: 5, body: HelperBinary.encode(.object([
            "method": .string("chat.open"), "params": .object(["terminal": .unsigned(5)])]))))
        let history = try HelperWire.encode(.init(kind: .notify, id: 5, body: HelperBinary.encode(.object(["method": .string("chat.history")]))))
        var journal = try AppReplay(url: path, replaying: false)
        let screen = try journal.open(kind: "command", input: .null), helper = try journal.open(kind: "helper", input: .null)
        let chat = try journal.open(kind: "helper", input: .string("chat"))
        try screen.emit(kind: "read", value: .bytes(Data([1])))
        let mark = journal.mark
        try screen.emit(kind: "read", value: .bytes(Data([2])))
        try helper.action(kind: "wire", value: .bytes(read))
        try helper.emit(kind: "read", value: .bytes(answer))
        try journal.open(kind: "command", input: .string("probe")).emit(kind: "result", value: .bytes(Data([7])))
        try chat.action(kind: "wire", value: .bytes(chatOpen))
        try chat.emit(kind: "read", value: .bytes(history))
        try await journal.open(kind: "step", input: .null).reach(.object([
            "at": .string("site"), "mark": .unsigned(UInt64(mark)), "end": .unsigned(UInt64(journal.mark))]))
        try screen.emit(kind: "exit")
        try helper.action(kind: "close")
        try helper.emit(kind: "end", value: closed)
        try helper.emit(kind: "exit")
        try chat.action(kind: "close")
        try chat.emit(kind: "end")
        try chat.emit(kind: "exit")
        try journal.finish()
        final class Screen: @unchecked Sendable { let lock = NSLock(); var shown: [UInt8] = [], probe: [UInt8] = [], chat = Data() }
        // The condition: the file's text and the probe's result (all its own), or also the redraw (read while it ran).
        for redraw in [false, true] {
            journal = try AppReplay(url: path, replaying: true)
            let shown = Screen(), replayed = try journal.open(kind: "command", input: .null)
            let connection = HelperConnection(read: Pipe().fileHandleForReading, write: Pipe().fileHandleForWriting,
                                              ticket: try journal.open(kind: "helper", input: .null))
            let app = try journal.open(kind: "helper", input: .string("chat"))
            try app.listen({ event in shown.lock.withLock { shown.chat += AppReplay.bytes(event.value) } }, failed: { XCTFail("Unexpected replay failure: \($0)") })
            let seen = try await journal.waiting { () async throws -> [UInt8] in
                try replayed.listen({ event in shown.lock.withLock { shown.shown += AppReplay.bytes(event.value) } },
                                    failed: { XCTFail("Unexpected replay failure: \($0)") })
                for checks in 0..<8 {
                    let mark = journal.mark
                    let holds = try await journal.checking { () async throws -> Bool in
                        let text: String = try await connection.request("files.text", params: ["path": "hooks.json"])
                        if checks == 0 {
                            // The app's own request, from its own work (no check's task): not the check's.
                            try await Task.detached { try app.action(kind: "wire", value: .bytes(chatOpen)) }.value
                            try journal.open(kind: "command", input: .string("probe")).listen({ event in
                                shown.lock.withLock { shown.probe = [UInt8](AppReplay.bytes(event.value)) }
                            }, failed: { XCTFail("Unexpected replay failure: \($0)") })
                        }
                        return shown.lock.withLock { text == "hooks" && shown.probe == [7] && (!redraw || shown.shown == [1, 2]) }
                    }
                    if holds { break }
                    await journal.advance(mark)
                    try await Task.sleep(for: .milliseconds(5))
                }
                XCTAssertEqual(shown.lock.withLock { shown.chat }, Data(), "The answer to the app's request waits for the step")
                return shown.lock.withLock { shown.shown }
            }
            XCTAssertEqual(seen, redraw ? [1, 2] : [1], "Only the check's own I/O passes the hold; a failing check frees what it may have seen")
            try await journal.open(kind: "step", input: .null).reach()
            connection.close()
            try app.action(kind: "close")
            for _ in 0..<200 where !journal.settled { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(shown.lock.withLock { shown.shown }, [1, 2])
            XCTAssertEqual(shown.lock.withLock { shown.chat }, history)
            try journal.finish()
        }
    }

    func testAppJournalAppObservationIsNotHeldBackByTheTestsStep() async throws {
        // The app polls the world on its own (which process runs in a terminal). In capture a poll asked just after the
        // test stepped saw the world as it was then; in replay the same poll may come before that step: while the test
        // waits for it, or before the test even began that wait (it still runs a reset). A step is not the app's progress:
        // what the app asks answers past it (up to what the app makes next). The test's own reads and checks still see
        // the state as of its next step.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let step = { (journal: AppReplay) in
            try await journal.open(kind: "step", input: .null).reach(.object([
                "at": .string("site"), "mark": .unsigned(UInt64(journal.mark)), "end": .unsigned(UInt64(journal.mark))]))
        }
        _ = try journal.query(kind: "observe.foreground", input: .null) { .string("login") }
        try await step(journal)
        _ = try journal.query(kind: "observe.foreground", input: .null) { .string("ssh") }
        try await step(journal)
        _ = try journal.query(kind: "observe.foreground", input: .null) { .string("shell") }
        let clock = try journal.open(kind: "clock", input: .null)
        try clock.emit(kind: "result")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        let replay = journal
        let read: @Sendable () throws -> HelperBinary.Value = { try replay.query(kind: "observe.foreground", input: .null) { .null } }
        let first = try read()
        try await journal.waiting {}
        try await journal.open(kind: "step", input: .null).reach()
        let own = try read(), polled = try await Task { try read() }.value
        let (checked, waiting) = try await journal.waiting {
            (try await journal.checking { try read() }, try await Task { try read() }.value)
        }
        try await journal.open(kind: "step", input: .null).reach()
        _ = try await journal.open(kind: "clock", input: .null).outcome()
        try journal.finish()
        XCTAssertEqual([first, own, polled, checked, waiting], [.string("login"), .string("ssh"), .string("shell"), .string("ssh"), .string("shell")],
                       "The test's read and check see the state before its next step; the app's polls are not held back by it")
    }

    func testAppJournalTaskIsNotShownTheWorldOlderThanWhatItSawLast() async throws {
        // An app task asks the OS in order (is this ssh alive, then which processes run in its terminal): capture recorded
        // its asks in that order. Replay answers an observation as of the first record the app has not made, which another
        // party's unmade work (the test's next view mounting) can hold before what this task already saw: in capture the
        // task ran after that work. The task is answered from where it can have been: having seen the ssh born, it sees
        // it in its terminal. Tasks that saw nothing newer, and the test's checks, see the world as of that first record;
        // a poll that asked something capture asked only later is not held ahead once the app moved on.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        let group = HelperBinary.Value.unsigned(7), ssh = HelperBinary.Value.unsigned(9), other = HelperBinary.Value.unsigned(11)
        let shell = HelperBinary.Value.array([.string("shell")]), both = HelperBinary.Value.array([.string("shell"), .string("ssh")])
        var journal = try AppReplay(url: path, replaying: false)
        _ = try journal.query(kind: "observe.members", input: group) { shell }
        _ = try journal.query(kind: "observe.info", input: ssh) { .string("ssh") }
        let mount = try journal.open(kind: "clock", input: .string("mount"))
        _ = try journal.query(kind: "observe.members", input: group) { both }
        let poll = try journal.open(kind: "clock", input: .string("poll"))
        try mount.emit(kind: "result")
        try poll.emit(kind: "result")
        _ = try journal.query(kind: "observe.members", input: group) { both }
        _ = try journal.query(kind: "observe.info", input: other) { .string("tmux") }
        let next = try journal.open(kind: "clock", input: .string("poll"))
        _ = try journal.query(kind: "observe.members", input: group) { .array([.string("ssh")]) }
        try next.emit(kind: "result")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        let replay = journal
        let members: @Sendable () throws -> HelperBinary.Value = { try replay.query(kind: "observe.members", input: group) { .null } }
        let (polled, signal) = AsyncStream<HelperBinary.Value>.makeStream()
        let poller = Task { () throws -> HelperBinary.Value in
            signal.yield(try members())
            _ = try replay.query(kind: "observe.info", input: other) { .null }
            _ = try await replay.open(kind: "clock", input: .string("poll")).outcome()
            let seen = try members()
            _ = try await replay.open(kind: "clock", input: .string("poll")).outcome()
            return seen
        }
        var first: HelperBinary.Value?
        for await value in polled { first = value; break }
        let seen = try await Task { [try replay.query(kind: "observe.info", input: ssh) { .null }, try members()] }.value
        let fresh = try await Task { try members() }.value
        _ = try replay.query(kind: "observe.info", input: ssh) { .null }
        let checked = try await replay.checking { try members() }
        _ = try await journal.open(kind: "clock", input: .string("mount")).outcome()
        let later = try await poller.value
        XCTAssertEqual(first, shell, "A poll sees the world as of the frontier")
        XCTAssertEqual(seen, [.string("ssh"), both], "The task that saw the ssh born sees it in its terminal")
        XCTAssertEqual(fresh, shell, "Another task saw nothing newer")
        XCTAssertEqual(checked, shell, "A check sees the state as of the frontier")
        XCTAssertEqual(later, both, "The poll that asked ahead sees where the app is once it moved on")
        try journal.finish()
    }

    func testAppJournalAppSideOfAnEndedConnectionIsDropped() throws {
        // A helper connection ended (the master exited): replay delivers its end to the transport's queue; the app may close
        // its side before that queue takes the end. Capture's transport had stopped first and recorded no close.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try HelperWire.encode(.init(kind: .request, id: 1, body: HelperBinary.encode(.object(["method": .string("launches.list")]))))
        let answer = try HelperWire.encode(.init(kind: .response, id: 1, body: HelperBinary.encode(.object(["result": .array([])]))))
        var journal = try AppReplay(url: path, replaying: false)
        let capture = try journal.open(kind: "helper", input: .null)
        try capture.action(kind: "wire", value: .bytes(request))
        try capture.emit(kind: "read", value: .bytes(answer))
        try capture.emit(kind: "exit", value: AppReplay.value(Int32(255)))
        try capture.emit(kind: "end")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        let replay = try journal.open(kind: "helper", input: .null)
        var kinds: [String] = []
        try replay.action(kind: "wire", value: .bytes(request))
        try replay.listen({ kinds.append($0.kind) }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        try replay.action(kind: "close")
        try journal.finish()
        XCTAssertEqual(kinds, ["in.read", "in.exit", "in.end"])
        XCTAssertEqual(journal.relaxed, ["after its end out.close"])
    }

    func testAppJournalRequestAfterItsConnectionEndedIsDropped() throws {
        // A request (a screen publication) the app sends after replay delivered its connection's end, before its
        // transport's queue took that end: capture's transport had stopped and recorded nothing. Nothing answers it,
        // nothing waits for it: the journal settles (the case's teardown waits for that) and lists it.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        func request(_ id: UInt64, _ method: String) throws -> Data {
            try HelperWire.encode(.init(kind: .request, id: id, body: HelperBinary.encode(.object(["method": .string(method), "params": .object(["terminal": .unsigned(1)])]))))
        }
        let answer = try HelperWire.encode(.init(kind: .response, id: 1, body: HelperBinary.encode(.object(["result": .array([])]))))
        var journal = try AppReplay(url: path, replaying: false)
        let capture = try journal.open(kind: "helper", input: .null)
        try capture.action(kind: "wire", value: .bytes(request(1, "launches.list")))
        try capture.emit(kind: "read", value: .bytes(answer))
        try capture.emit(kind: "exit", value: AppReplay.value(Int32(255)))
        try capture.emit(kind: "end")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        let replay = try journal.open(kind: "helper", input: .null)
        var kinds: [String] = []
        try replay.listen({ kinds.append($0.kind) }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        try replay.action(kind: "wire", value: .bytes(request(1, "launches.list")))
        XCTAssertEqual(kinds, ["in.read", "in.exit", "in.end"])
        try replay.action(kind: "wire", value: .bytes(request(2, "terminals.publish")))
        XCTAssertTrue(journal.settled)
        try journal.finish()
        XCTAssertEqual(journal.relaxed, ["after its end terminals.publish"])
    }

    func testAppJournalSettleLetsConsumersHandleWhatReachedThem() async throws {
        // Capture records input when it is read; the app handles it later on its consumer's queue. A test's condition
        // can hold before that: settling first makes a step follow what was read before it, as replay delivers it.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AppReplay(url: directory.appendingPathComponent("app.rpl.zst"), replaying: false)
        let queue = DispatchQueue(label: "consumer"), command = try journal.open(kind: "command", input: .null)
        command.through(queue)
        final class Handled: @unchecked Sendable { var value = false }
        let handled = Handled()
        try command.emit(kind: "read", value: .bytes(Data([1])))
        queue.async { usleep(20_000); DispatchQueue.main.async { handled.value = true } }
        await journal.settle()
        XCTAssertTrue(handled.value)
    }

    func testAppJournalCancelledWaitsEndAsTheRecordedOnesDid() async throws {
        // The app cancels a sleep (a probe replaced, a grace period ended early): it ends at once, as the recorded one
        // did, not when replay reaches its recorded end (other work the app awaits after it comes first there). A wait
        // the recording saw finish (a process run that ignores its caller's cancellation) still gets its recorded result.
        // A recorded cancellation is a CancellationError again (callers catch it by type). A wait the recording never
        // saw end (still pending at its end, or never begun there) ends at cancellation: nothing else ever will.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let sleeping = try journal.open(kind: "clock", input: .string("probe"))
        let running = try journal.open(kind: "run", input: .null)
        let fetching = try journal.open(kind: "fetch", input: .null)
        let captured = try journal.open(kind: "command", input: .null)
        try captured.action(kind: "write", value: .bytes(Data([1])))
        try sleeping.emit(kind: "error", value: AppReplay.value(AppReplay.Failure(CancellationError())))
        try running.emit(kind: "result", value: .bytes(Data("done".utf8)))
        try fetching.emit(kind: "error", value: AppReplay.value(AppReplay.Failure(CancellationError())))
        try captured.emit(kind: "exit")
        _ = try journal.open(kind: "clock", input: .string("tail"))
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        let replayed = journal
        let wait = Task { try await replayed.open(kind: "clock", input: .string("probe")).outcome() }
        let run = Task { try await replayed.open(kind: "run", input: .null).outcome() }
        let fetch = Task { try await replayed.open(kind: "fetch", input: .null).outcome() }
        wait.cancel(); run.cancel()
        do { _ = try await wait.value; XCTFail("A cancelled wait ends with its cancellation") } catch is CancellationError {}
        let command = try journal.open(kind: "command", input: .null)
        try command.listen({ _ in }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        try command.action(kind: "write", value: .bytes(Data([1])))
        let result = try await run.value
        XCTAssertEqual(result, .bytes(Data("done".utf8)))
        do { _ = try await fetch.value; XCTFail("A recorded cancellation ends the wait") } catch is CancellationError {}
        for input in ["tail", "unseen"] {
            let pending = Task { try await replayed.open(kind: "clock", input: .string(input)).outcome() }
            pending.cancel()
            do { _ = try await pending.value; XCTFail("A wait without a recorded end ends at cancellation") } catch is CancellationError {}
        }
        try journal.finish()
    }

    func testAppJournalSleepItsCallerCancelledEndsOnlyWhenTheCallerCancels() async throws {
        // A sleep ends by elapsing or by its caller's cancellation (a timeout's timer once the work finished first).
        // Replay reaching the recorded cancellation does not end the sleep: it would fail the caller (a timeout reported
        // as an error). Only the caller's cancellation does; the record holds nothing meanwhile (identical concurrent
        // timers may pair with each other's records).
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let timer = try journal.open(kind: "clock", input: .string("timeout"))
        let command = try journal.open(kind: "command", input: .null)
        try timer.emit(kind: "error", value: AppReplay.value(AppReplay.Failure(CancellationError())))
        try command.emit(kind: "read", value: .bytes(Data([1])))
        try command.emit(kind: "exit")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        let replayed = journal
        let wait = Task { () -> Bool in
            do { _ = try await replayed.open(kind: "clock", input: .string("timeout")).outcome(caller: true) } catch {}
            return Task.isCancelled
        }
        // The command's input comes once the wait has begun (whenever its task runs): its recorded cancellation holds nothing.
        var events: [String] = []
        let delivered = expectation(description: "the command's input")
        delivered.assertForOverFulfill = false
        try journal.open(kind: "command", input: .null).listen({ event in
            events.append(event.kind)
            if event.kind == "in.exit" { delivered.fulfill() }
        }, failed: { XCTFail("Unexpected replay failure: \($0)"); delivered.fulfill() })
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(events, ["in.read", "in.exit"], "The recorded cancellation holds nothing")
        wait.cancel()
        let cancelled = await wait.value
        XCTAssertTrue(cancelled, "Only the caller's cancellation ends it")
        try journal.finish()
    }

    func testAppJournalAppWaitsAndProcessesTheRecordingNeverSawBeginNeverAnswerOrFail() throws {
        // The app went on after the recording's teardown cut it: a timer loop's later waits never wake, a view
        // mounted later launches a process that never starts (what the app sends it goes nowhere), a command it runs
        // fails to its caller (it would wait forever otherwise). The test's own steps stay exact (one the recording
        // lacks is a divergence).
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        try journal.open(kind: "clock", input: .string("poll")).emit(kind: "result")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        var answered: [String] = [], failed: [String] = []
        for kind in ["clock", "clock", "pty", "command"] {
            let ticket = try journal.open(kind: kind, input: .string("poll"))
            try ticket.listen({ answered.append($0.kind) }, failed: { failed.append(($0 as? HelperFailure)?.code ?? "\($0)") })
            if kind != "clock" { for action in ["input", "hangup"] { try ticket.action(kind: action, value: .bytes(Data("typed".utf8))) } }
        }
        XCTAssertEqual(answered, ["in.result"])
        XCTAssertEqual(failed, ["unrecorded"])
        try journal.finish()
        XCTAssertEqual(journal.relaxed, [#"unseen pty "poll""#, #"unseen command "poll""#])
        journal = try AppReplay(url: path, replaying: true)
        XCTAssertThrowsError(try journal.open(kind: "step", input: .string("poll")), "A step the recording lacks diverged")
    }

    /// The step is the test's (main actor): its wake is reached on the main queue's next turn.
    @MainActor
    func testAppJournalRendererChildHandsBackOnlyWhatTheAppTyped() async throws {
        // A terminal's renderer child (it connected back) is sent the app's drawing and the app's encoding of keys,
        // pointer and replies; it hands typed bytes back on its slave (a pty not raw yet turns CR into NL). Only that
        // hand-back is replayed, as recorded, once the app typed it: replay never types ahead of the test. What else the
        // app types (a pointer report the recording lacks) is passed over; its drawing is never compared. Focus reports
        // follow window activation, which the cases run before decide: no side waits on them (iso60). A test waiting for
        // its step types nothing: then a hand-back of what this run never typed (a report its screen did not send) goes on.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let pty = try journal.open(kind: "pty", input: .null)
        try pty.action(kind: "input", value: .bytes(Data("ls\r".utf8)))
        try pty.emit(kind: "connect")
        try pty.channel("slave").action(kind: "wire", value: .bytes(Data("drawn".utf8)))
        try pty.emit(kind: "output", value: .bytes(Data("drawn".utf8)))
        try pty.channel("slave").emit(kind: "read", value: .bytes(Data("ls\n".utf8)))
        for report in ["\u{1b}[I\u{1b}[4;1R", "\u{1b}[O", "\u{1b}[5;1R"] {
            try pty.action(kind: "input", value: .bytes(Data(report.utf8)))
            try pty.channel("slave").emit(kind: "read", value: .bytes(Data(report.utf8)))
        }
        try await journal.open(kind: "step", input: .null).reach()
        try pty.action(kind: "hangup")
        try pty.emit(kind: "exit")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        var events: [String] = []
        let replayed = try journal.open(kind: "pty", input: .null)
        for channel in [replayed, replayed.channel("slave")] {
            try channel.listen({ events.append($0.kind + " " + AppReplay.text($0.value)) }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        }
        try replayed.channel("slave").action(kind: "wire", value: .bytes(Data("dra".utf8)))
        try replayed.channel("slave").action(kind: "wire", value: .bytes(Data("wn later".utf8)))
        for typed in ["\u{1b}[<35;1;1M", "l", "\u{1b}[O"] { try replayed.action(kind: "input", value: .bytes(Data(typed.utf8))) }
        let shown = ["in.connect null", #"in.output b"drawn""#]
        XCTAssertEqual(events, shown, "Its hand-back waits for the whole typing")
        try replayed.action(kind: "input", value: .bytes(Data("s\r".utf8)))
        let reads = [#"in.read b"ls\n""#, #"in.read b"\u{1B}[I\u{1B}[4;1R""#, #"in.read b"\u{1B}[O""#, #"in.read b"\u{1B}[5;1R""#]
        XCTAssertEqual(events, shown + reads.prefix(1), "The recorded focus-in waits for nothing; its report waits for the app")
        try replayed.action(kind: "input", value: .bytes(Data("\u{1b}[4;1R".utf8)))
        XCTAssertEqual(events, shown + reads.prefix(3))
        try await journal.open(kind: "step", input: .null).reach()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(events, shown + reads)
        try replayed.action(kind: "hangup")
        try journal.finish()
        XCTAssertEqual(events, shown + reads + ["in.exit null"])
    }

    func testAppJournalRendererChildConnectingAfterItsViewClosedHasNoSlave() throws {
        // A closed tab's renderer child connected in capture before the app took the view down; the app then closed that
        // connection with the view. Replay hands the connect over in recorded order, after the close that took the view
        // down: the app refused it (as live, when a child connects late) and hangs up its pty. What capture recorded on that
        // connection never happens; the hangup is the app's next record of that pty. A connection the app did open still
        // closes as recorded, whichever of its pty's ends the app closes first.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let pty = try journal.open(kind: "pty", input: .null)
        try pty.emit(kind: "output", value: .bytes(Data("login".utf8)))
        try pty.emit(kind: "connect")
        try pty.channel("slave").action(kind: "close")
        try pty.channel("slave").emit(kind: "end")
        try pty.action(kind: "hangup")
        try pty.emit(kind: "exit")
        let open = try journal.open(kind: "pty", input: .null)
        try open.emit(kind: "connect")
        try open.channel("slave").action(kind: "close")
        try open.channel("slave").emit(kind: "end")
        try open.action(kind: "hangup")
        try open.emit(kind: "exit")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        var events: [String] = []
        let replayed = try journal.open(kind: "pty", input: .null)
        try replayed.listen({ events.append($0.kind) }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        try replayed.action(kind: "hangup")
        let opened = try journal.open(kind: "pty", input: .null)
        for channel in [opened, opened.channel("slave")] {
            try channel.listen({ events.append($0.kind) }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        }
        try opened.action(kind: "hangup")
        try opened.channel("slave").action(kind: "close")
        try journal.finish()
        XCTAssertEqual(events, ["in.output", "in.connect", "in.exit", "in.connect", "in.end", "in.exit"])
    }

    func testAppJournalValuesTheAppMadeAreKeptNotRequired() throws {
        // An id the app made (a tab's, a fixture path's) is recorded to hand back the same value for the same key, in
        // order; the app may ask fewer (a cache, another path: the recording does not wait for them) or more (made now).
        // Making one tells the app nothing about other processes: what it observes stays where replay is.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        _ = try journal.query(kind: "observe.state", input: .null) { .string("early") }
        _ = try journal.query(kind: "identity.made", input: .string("first")) { .string("first") }
        let command = try journal.open(kind: "command", input: .null)
        try command.action(kind: "write", value: .bytes(Data([9])))
        try command.emit(kind: "read", value: .bytes(Data([1])))
        _ = try journal.query(kind: "identity.made", input: .string("second")) { .string("second") }
        _ = try journal.query(kind: "observe.state", input: .null) { .string("late") }
        try command.emit(kind: "exit")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        let replayed = try journal.open(kind: "command", input: .null)
        XCTAssertEqual(try journal.query(kind: "identity.made", input: .string("second")) { .null }, .string("second"))
        XCTAssertEqual(try journal.query(kind: "identity.made", input: .string("second")) { .string("made now") },
                       .string("made now"))
        XCTAssertEqual(try journal.query(kind: "observe.state", input: .null) { .null }, .string("early"),
                       "The app has not written yet")
        var events: [Data] = []
        try replayed.listen({ events.append(AppReplay.bytes($0.value)) }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        try replayed.action(kind: "write", value: .bytes(Data([9])))
        XCTAssertEqual(events, [Data([1]), Data()])
        try journal.finish()
    }

    func testAppJournalIdsTheAppMakesFollowTheRecordedSeedPerSite() throws {
        // The app makes ids everywhere (layout, rows, paths, tokens); only the journal's seed is recorded. An id is
        // the seed, its site and how many that site made before: replay makes the same ones in any interleaving of
        // sites, and one site making more shifts nothing elsewhere.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let captured = try ["a", "a", "b"].map { try journal.made($0) }
        XCTAssertEqual(Set(captured).count, 3)
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        let b = try journal.made("b"), a = try (0..<3).map { _ in try journal.made("a") }
        XCTAssertEqual([a[0], a[1], b], captured)
        XCTAssertFalse(captured.contains(a[2]))
        try journal.finish()
        // A site that made another count than the recording is where later ids of that site shifted: listed.
        XCTAssertEqual(journal.drift, ["a: recorded 2, made 3"])
    }

    func testAppJournalQueriesTheRecordingNeverSawFailToTheirCaller() throws {
        // The app got further than the recording before teardown cut it (a shim install after a list arrived): the
        // query fails to its caller as unrecorded (the app's own error path), the journal goes on and lists it.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        _ = try journal.query(kind: "launch.install", input: .string("a")) { .null }
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        XCTAssertEqual(try journal.query(kind: "launch.install", input: .string("a")) { .string("live") }, .null)
        XCTAssertThrowsError(try journal.query(kind: "launch.install", input: .string("a")) { .string("live") }) {
            XCTAssertEqual(($0 as? HelperFailure)?.code, "unrecorded")
        }
        try journal.finish()
        XCTAssertEqual(journal.relaxed, [#"unrecorded launch.install "a""#])
    }

    func testAppJournalCaptureHandsBackWhatReplayReads() throws {
        // A Swift dictionary decoded from a value iterates as that value was built: capture hands the app the value
        // replay reads back from the journal, so what the app iterates is the same in both. Journal runs hash
        // deterministically; otherwise every dictionary has its own seed and no two decodes iterate alike.
        try XCTSkipUnless(System.environment("SWIFT_DETERMINISTIC_HASHING") != nil, "random hashing")
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        func orders(_ journal: AppReplay) throws -> [[String]] {
            try (1...64).map { size in
                let map = Dictionary(uniqueKeysWithValues: (0..<size).map { ("key-\($0 * 7919 % 1000)-\($0)", $0) })
                let value = try journal.query(kind: "map", input: .unsigned(UInt64(size))) { try HelperBinary.value(encoding: map) }
                return Array(try HelperBinary.decode([String: Int].self, from: value).keys)
            }
        }
        var journal = try AppReplay(url: path, replaying: false)
        let captured = try orders(journal)
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        XCTAssertEqual(try orders(journal), captured)
        try journal.finish()
    }

    func testAppJournalCreationValuesPreserveTheirTypes() throws {
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let capture = try journal.open(kind: "command", input: .object(["value": .bool(true)]))
        try capture.emit(kind: "result")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        XCTAssertThrowsError(try journal.open(kind: "command", input: .object(["value": .unsigned(1)])))
        let diagnostic = try XCTUnwrap(journal.diagnostic)
        let events = try AppReplay.events(diagnostic)
        XCTAssertEqual(events, [
            AppReplay.Event(kind: "open.command", id: 1, value: .object(["value": .bool(true)])),
            AppReplay.Event(kind: "open.command", id: 1, value: .object(["value": .unsigned(1)])),
        ])
        let permissions = try FileManager.default.attributesOfItem(atPath: diagnostic.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertThrowsError(try journal.finish())
    }

    func testAppJournalBindsWireIDsWithoutChangingValuesOrCancellation() throws {
        for identity: UInt64 in [72, 41] {
            let directory = System.temporary.appendingPathComponent(UUID().uuidString)
            let path = directory.appendingPathComponent("app.rpl.zst")
            defer { try? FileManager.default.removeItem(at: directory) }
            let body = try HelperBinary.encode(.object(["method": .string("hello"), "params": .object([:])]))
            let answer = try HelperBinary.encode(.object(["result": .array([])]))
            var journal = try AppReplay(url: path, replaying: false)
            let capture = try journal.open(kind: "helper", input: .object(["arguments": .array([.string("--stdio")]), "role": .string("local")]))
            try capture.action(kind: "wire", value: .bytes(HelperWire.encode(.init(kind: .request, id: 41, body: body))))
            let response = try HelperWire.encode(.init(kind: .response, id: 41, body: answer))
            try capture.emit(kind: "read", value: .bytes(response.prefix(4)))
            try capture.action(kind: "wire", value: .bytes(HelperWire.encode(.init(kind: .request, id: 42, body: body))))
            try capture.emit(kind: "read", value: .bytes(response.dropFirst(4)))
            try capture.action(kind: "wire", value: .bytes(HelperWire.encode(.init(kind: .cancel, id: 42, body: Data()))))
            try capture.emit(kind: "end")
            try capture.emit(kind: "exit")
            try journal.finish()

            journal = try AppReplay(url: path, replaying: true)
            let replay = try journal.open(kind: "helper", input: .object(["role": .string("local"), "arguments": .array([.string("--stdio")])]))
            var bytes = Data()
            try replay.listen({ if $0.kind == "in.read" { bytes.append(AppReplay.bytes($0.value)) } }, failed: { XCTFail("Unexpected replay failure: \($0)") })
            try replay.action(kind: "wire", value: .bytes(HelperWire.encode(.init(kind: .request, id: identity, body: body))))
            // A cancel the recording lacks raced the recorded response, which still arrives.
            try replay.action(kind: "wire", value: .bytes(HelperWire.encode(.init(kind: .cancel, id: identity, body: Data()))))
            try replay.action(kind: "wire", value: .bytes(HelperWire.encode(.init(kind: .request, id: 73, body: body))))
            try replay.action(kind: "wire", value: .bytes(HelperWire.encode(.init(kind: .cancel, id: 73, body: Data()))))
            try journal.finish()
            XCTAssertEqual(bytes, try HelperWire.encode(.init(kind: .response, id: identity, body: answer)))
        }
    }

    func testAppJournalRequestsTheRecordingLacksGetItsUnambiguousAnswerOrUnavailableAndUnsentOnesEndWithTheClose() throws {
        // Some requests follow UI timing (a chat opened for a terminal shown just before a test closes it, a refresh,
        // a list read before a connection closes): a run sends them or not. Replay answers one the recording lacks
        // with the recording's answer when that is unambiguous (the same question always answered alike, or a method
        // only ever acknowledged), else as the helper answers what it cannot serve now (an error the app may show).
        // Recorded ones the app has not sent when it closes that connection are dropped. The test's own checks judge
        // whether that changed anything; the journal lists them. A request replay acknowledges itself (a screen
        // publication) is never pending, so the app's recorded cancel of it is not waited for.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        func request(_ id: UInt64, _ method: String, _ params: [String: HelperBinary.Value] = [:]) throws -> Data {
            try HelperWire.encode(.init(kind: .request, id: id, body: HelperBinary.encode(.object(["method": .string(method), "params": .object(params)]))))
        }
        func answer(_ id: UInt64, _ result: HelperBinary.Value) throws -> Data {
            try HelperWire.encode(.init(kind: .response, id: id, body: HelperBinary.encode(.object(["result": result]))))
        }
        func typed(_ id: UInt64, _ text: String) throws -> Data {
            try request(id, "terminals.input", ["terminal": .unsigned(1), "bytes": .bytes(Data(text.utf8))])
        }
        var journal = try AppReplay(url: path, replaying: false)
        let capture = try journal.open(kind: "helper", input: .null)
        for (id, method, params, result) in [(1, "launches.list", [:], HelperBinary.Value.array([])), (2, "entities.focus", ["node": .unsigned(1)], .null),
                                             (3, "backends.list", [:], .array([])), (4, "backends.list", [:], .array([.unsigned(1)]))] as [(UInt64, String, [String: HelperBinary.Value], HelperBinary.Value)] {
            try capture.action(kind: "wire", value: .bytes(request(id, method, params)))
            try capture.emit(kind: "read", value: .bytes(answer(id, result)))
        }
        try capture.action(kind: "wire", value: .bytes(request(7, "terminals.publish", ["terminal": .unsigned(1), "text": .string("x")])))
        try capture.action(kind: "wire", value: .bytes(HelperWire.encode(.init(kind: .cancel, id: 7, body: Data()))))
        try capture.action(kind: "wire", value: .bytes(request(8, "entities.focus", ["node": .unsigned(3)])))
        try capture.emit(kind: "read", value: .bytes(answer(8, .null)))
        try capture.action(kind: "wire", value: .bytes(typed(5, "ab")))
        try capture.action(kind: "wire", value: .bytes(request(6, "chat.open", ["terminal": .unsigned(1)])))
        try capture.action(kind: "close")
        try capture.emit(kind: "end")
        try capture.emit(kind: "exit")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        let replay = try journal.open(kind: "helper", input: .null)
        var replies: [UInt64: HelperBinary.Value] = [:], decoder = HelperWire.Decoder()
        try replay.listen({ event in
            try? decoder.feed(AppReplay.bytes(event.value)) { replies[$0.id] = try HelperBinary.decode($0.body) }
        }, failed: { _ in })
        try replay.action(kind: "wire", value: .bytes(request(1, "launches.list")))
        try replay.action(kind: "wire", value: .bytes(request(2, "chat.open", ["terminal": .unsigned(2)])))
        try replay.action(kind: "wire", value: .bytes(typed(3, "abc")))
        try replay.action(kind: "wire", value: .bytes(request(4, "launches.list")))
        try replay.action(kind: "wire", value: .bytes(request(5, "entities.focus", ["node": .unsigned(1)])))
        try replay.action(kind: "wire", value: .bytes(request(6, "entities.focus", ["node": .unsigned(2)])))
        for id in [7, 8, 9] as [UInt64] { try replay.action(kind: "wire", value: .bytes(request(id, "backends.list"))) }
        try replay.action(kind: "wire", value: .bytes(request(10, "terminals.publish", ["terminal": .unsigned(1), "text": .string("x")])))
        try replay.action(kind: "wire", value: .bytes(request(11, "entities.focus", ["node": .unsigned(3)])))
        let unavailable = HelperBinary.Value.object(["error": .object(["code": .string("unavailable"),
                                                                      "message": .string("Not in the recording: the helper did not answer this request.")])])
        XCTAssertEqual(replies, [1: .object(["result": .array([])]), 2: unavailable, 3: .object(["result": .null]), 4: .object(["result": .array([])]),
                                 5: .object(["result": .null]), 6: .object(["result": .null]),
                                 7: .object(["result": .array([])]), 8: .object(["result": .array([.unsigned(1)])]), 9: unavailable,
                                 10: .object(["result": .null]), 11: .object(["result": .null])])
        try replay.action(kind: "close")
        try journal.finish()
        XCTAssertEqual(journal.relaxed, ["unrecorded chat.open {terminal: 2}", "answered launches.list {}", "answered entities.focus {node: 2}",
                                         "unrecorded backends.list {}", "unsent chat.open {terminal: 1}"])
    }

    func testAppJournalRequestEqualToAnOpenOneGetsNoAnswer() throws {
        // A chat reopened while its recorded open is still unanswered (an agent.changed just before the test moved on;
        // capture's test made that reopen moot first): the recording lacks it, and the helper is still answering the open
        // one, so it gets no answer either. A request equal to one already answered is one the recording lacks.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        func open(_ id: UInt64, _ terminal: UInt64) throws -> Data {
            try HelperWire.encode(.init(kind: .request, id: id, body: HelperBinary.encode(.object(["method": .string("chat.open"),
                "params": .object(["terminal": .unsigned(terminal)])]))))
        }
        let refusal = HelperBinary.Value.object(["error": .object(["code": .string("unavailable"), "message": .string("unbound")])])
        var journal = try AppReplay(url: path, replaying: false)
        let capture = try journal.open(kind: "helper", input: .null)
        try capture.action(kind: "wire", value: .bytes(open(1, 1)))
        try capture.action(kind: "wire", value: .bytes(open(2, 2)))
        try capture.emit(kind: "read", value: .bytes(HelperWire.encode(.init(kind: .response, id: 2, body: HelperBinary.encode(refusal)))))
        try capture.action(kind: "close")
        try capture.emit(kind: "end")
        try capture.emit(kind: "exit")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        let replay = try journal.open(kind: "helper", input: .null)
        var replies: [UInt64: HelperBinary.Value] = [:], decoder = HelperWire.Decoder()
        try replay.listen({ event in
            try? decoder.feed(AppReplay.bytes(event.value)) { replies[$0.id] = try HelperBinary.decode($0.body) }
        }, failed: { _ in })
        for (id, terminal) in [(1, 1), (2, 2), (3, 1), (4, 2)] as [(UInt64, UInt64)] { try replay.action(kind: "wire", value: .bytes(open(id, terminal))) }
        XCTAssertEqual(replies, [2: refusal, 4: refusal])
        try replay.action(kind: "close")
        try journal.finish()
        XCTAssertEqual(journal.relaxed, ["unanswered chat.open {terminal: 1}", "answered chat.open {terminal: 2}"])
    }

    func testAppJournalRequestsCancelledBeforeAnyAnswerOrRefusedHoldNothing() throws {
        // A request the app cancelled before anything came back for it (a terminal created just as the test closed the
        // app), or one the helper refused (a chat reopened just after its permission was withdrawn), changed nothing on
        // the helper: it follows UI timing, a run sends it or not. Unsent, it holds no later record of its open
        // connection; sent after replay passed it, it still gets the recorded refusal.
        func request(_ id: UInt64, _ method: String) throws -> Data {
            try HelperWire.encode(.init(kind: .request, id: id, body: HelperBinary.encode(.object(["method": .string(method), "params": .object([:])]))))
        }
        func response(_ id: UInt64, _ body: HelperBinary.Value) throws -> Data {
            try HelperWire.encode(.init(kind: .response, id: id, body: HelperBinary.encode(body)))
        }
        let cancel = try HelperWire.encode(.init(kind: .cancel, id: 2, body: Data()))
        let answer = try response(1, .object(["result": .array([])]))
        let refusal = try response(3, .object(["error": .object(["code": .string("permission_denied"), "message": .string("off")])]))
        let wire = [1: try request(1, "launches.list"), 2: try request(2, "terminals.create"), -2: cancel, 3: try request(3, "chat.open")]
        for (sends, expected, relaxed) in [([1], answer, ["unsent terminals.create {}", "unsent chat.open {}"]),
                                           ([3, 2, -2, 1], refusal + answer, []),
                                           ([1, 3], answer + refusal, ["unsent terminals.create {}"])] {
            let directory = System.temporary.appendingPathComponent(UUID().uuidString)
            let path = directory.appendingPathComponent("app.rpl.zst")
            defer { try? FileManager.default.removeItem(at: directory) }
            var journal = try AppReplay(url: path, replaying: false)
            let capture = try journal.open(kind: "helper", input: .null)
            for id in [1, 2, -2, 3] { try capture.action(kind: "wire", value: .bytes(wire[id]!)) }
            try capture.emit(kind: "read", value: .bytes(refusal))
            try capture.emit(kind: "read", value: .bytes(answer))
            try capture.action(kind: "close")
            try capture.emit(kind: "end")
            try capture.emit(kind: "exit")
            try journal.finish()
            journal = try AppReplay(url: path, replaying: true)
            let replay = try journal.open(kind: "helper", input: .null)
            var bytes = Data()
            try replay.listen({ if $0.kind == "in.read" { bytes.append(AppReplay.bytes($0.value)) } }, failed: { XCTFail("Unexpected replay failure: \($0)") })
            for id in sends { try replay.action(kind: "wire", value: .bytes(wire[id]!)) }
            try replay.action(kind: "close")
            try journal.finish()
            XCTAssertEqual(bytes, expected)
            XCTAssertEqual(journal.relaxed, relaxed)
        }
    }

    func testAppJournalRequestSentPastItsRecordedRefusalIsTheLaterEqualOne() throws {
        // The app opened a chat, the helper refused it at once (no harness yet), then reported the change that let the
        // app's next open through. A refused request follows UI timing (it holds nothing): replay may reach its refusal
        // and that change before the app sends it. Sent once the app got everything recorded before the later equal
        // request, it is that one (gets its answer; the refused one goes unsent). Sent before its refusal was reached, or
        // before what preceded the later one came (another terminal's output here), it is the refused one.
        let open = { (id: UInt64) in
            try HelperWire.encode(.init(kind: .request, id: id, body: HelperBinary.encode(.object([
                "method": .string("chat.open"), "params": .object(["terminal": .unsigned(5)])]))))
        }
        let refusal = try HelperWire.encode(.init(kind: .response, id: 1, body: HelperBinary.encode(.object([
            "error": .object(["code": .string("unavailable"), "message": .string("No verified harness")])]))))
        let changed = try HelperWire.encode(.init(kind: .notify, id: 9, body: HelperBinary.encode(.object(["method": .string("agent.changed")]))))
        let answer = { (id: UInt64) in try HelperWire.encode(.init(kind: .response, id: id, body: HelperBinary.encode(.object(["result": .null])))) }
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let capture = try journal.open(kind: "helper", input: .null), screen = try journal.open(kind: "command", input: .null)
        try capture.action(kind: "wire", value: .bytes(open(1)))
        try capture.emit(kind: "read", value: .bytes(refusal))
        try screen.emit(kind: "exit")
        try capture.emit(kind: "read", value: .bytes(changed))
        try capture.action(kind: "wire", value: .bytes(open(2)))
        try capture.emit(kind: "read", value: .bytes(answer(2)))
        try capture.action(kind: "close")
        try capture.emit(kind: "end")
        try capture.emit(kind: "exit")
        try journal.finish()
        // When the app sends its first open: before replay reached the refusal, after it and the change, or after the
        // refusal while the other terminal's output (recorded before the change) has not come yet.
        for (late, other, expected, relaxed) in [(true, true, try changed + answer(1), ["unsent chat.open {terminal: 5}"]),
                                                 (false, true, try refusal + changed + answer(2), []), (true, false, try refusal + changed + answer(2), [])] {
            journal = try AppReplay(url: path, replaying: true)
            let replay = try journal.open(kind: "helper", input: .null), screen = try journal.open(kind: "command", input: .null)
            var bytes = Data()
            let listen = { try screen.listen({ _ in }, failed: { XCTFail("Unexpected replay failure: \($0)") }) }
            if !late { try replay.action(kind: "wire", value: .bytes(open(1))) }
            if other { try listen() }
            try replay.listen({ if $0.kind == "in.read" { bytes.append(AppReplay.bytes($0.value)) } }, failed: { XCTFail("Unexpected replay failure: \($0)") })
            if late { try replay.action(kind: "wire", value: .bytes(open(1))) }
            if !other { try listen() }
            if !late || !other { try replay.action(kind: "wire", value: .bytes(open(2))) }
            try replay.action(kind: "close")
            try journal.finish()
            XCTAssertEqual(bytes, expected, "late: \(late), other terminal first: \(other)")
            XCTAssertEqual(journal.relaxed, relaxed)
        }
    }

    func testAppJournalRequestPastItsRefusalIsTheLaterOneWhileAnotherOfItsRequestsIsUnsent() throws {
        // As above, the app sends its open once it got the change that let the later one through, but before another request
        // of that connection recorded between them (its control output: requests go out in any order). What waits only for
        // that unsent request tells nothing about where the app is: the open is the later one, not the refused one.
        let request = { (id: UInt64, method: String) in
            try HelperWire.encode(.init(kind: .request, id: id, body: HelperBinary.encode(.object([
                "method": .string(method), "params": .object(["terminal": .unsigned(5)])]))))
        }
        let refusal = try HelperWire.encode(.init(kind: .response, id: 1, body: HelperBinary.encode(.object([
            "error": .object(["code": .string("unavailable"), "message": .string("No verified harness")])]))))
        let changed = try HelperWire.encode(.init(kind: .notify, id: 9, body: HelperBinary.encode(.object(["method": .string("agent.changed")]))))
        let answer = { (id: UInt64) in try HelperWire.encode(.init(kind: .response, id: id, body: HelperBinary.encode(.object(["result": .null])))) }
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let capture = try journal.open(kind: "helper", input: .null)
        try capture.action(kind: "wire", value: .bytes(request(1, "chat.open")))
        try capture.emit(kind: "read", value: .bytes(refusal))
        try capture.emit(kind: "read", value: .bytes(changed))
        try capture.action(kind: "wire", value: .bytes(request(2, "launches.list")))
        try capture.emit(kind: "read", value: .bytes(answer(2)))
        try capture.action(kind: "wire", value: .bytes(request(3, "chat.open")))
        try capture.emit(kind: "read", value: .bytes(answer(3)))
        try capture.action(kind: "close")
        try capture.emit(kind: "end")
        try capture.emit(kind: "exit")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        let replay = try journal.open(kind: "helper", input: .null)
        var bytes = Data()
        try replay.listen({ if $0.kind == "in.read" { bytes.append(AppReplay.bytes($0.value)) } }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        try replay.action(kind: "wire", value: .bytes(request(1, "chat.open")))
        try replay.action(kind: "wire", value: .bytes(request(2, "launches.list")))
        try replay.action(kind: "close")
        try journal.finish()
        XCTAssertEqual(bytes, try changed + answer(1) + answer(2), "The open's answer does not wait for the request the app sends after it")
        XCTAssertEqual(journal.relaxed, ["unsent chat.open {terminal: 5}"])
    }

    func testAppJournalRefusedRequestTheAppWentPastStaysUnsent() throws {
        // As above, the app sent its open past the refusal, as the later equal one (the refused one stays unsent). Much later
        // it opens again, before another terminal's output recorded before its next open came: equal requests go out in
        // order, so that is the next open, never the refused one it already went past.
        let open = { (id: UInt64) in
            try HelperWire.encode(.init(kind: .request, id: id, body: HelperBinary.encode(.object([
                "method": .string("chat.open"), "params": .object(["terminal": .unsigned(5)])]))))
        }
        let refusal = try HelperWire.encode(.init(kind: .response, id: 1, body: HelperBinary.encode(.object([
            "error": .object(["code": .string("unavailable"), "message": .string("No verified harness")])]))))
        let changed = try HelperWire.encode(.init(kind: .notify, id: 9, body: HelperBinary.encode(.object(["method": .string("agent.changed")]))))
        let answer = { (id: UInt64) in try HelperWire.encode(.init(kind: .response, id: id, body: HelperBinary.encode(.object(["result": .null])))) }
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let capture = try journal.open(kind: "helper", input: .null), screen = try journal.open(kind: "command", input: .null)
        try capture.action(kind: "wire", value: .bytes(open(1)))
        try capture.emit(kind: "read", value: .bytes(refusal))
        try capture.emit(kind: "read", value: .bytes(changed))
        try capture.action(kind: "wire", value: .bytes(open(2)))
        try capture.emit(kind: "read", value: .bytes(answer(2)))
        try screen.emit(kind: "exit")
        try capture.action(kind: "wire", value: .bytes(open(3)))
        try capture.emit(kind: "read", value: .bytes(answer(3)))
        try capture.action(kind: "close")
        try capture.emit(kind: "end")
        try capture.emit(kind: "exit")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        let replay = try journal.open(kind: "helper", input: .null), other = try journal.open(kind: "command", input: .null)
        var bytes = Data()
        try replay.listen({ if $0.kind == "in.read" { bytes.append(AppReplay.bytes($0.value)) } }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        try replay.action(kind: "wire", value: .bytes(open(1)))
        try replay.action(kind: "wire", value: .bytes(open(2)))
        try other.listen({ _ in }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        try replay.action(kind: "close")
        try journal.finish()
        XCTAssertEqual(bytes, try changed + answer(1) + answer(2), "The later open is the next one, not the refused one")
        XCTAssertEqual(journal.relaxed, ["unsent chat.open {terminal: 5}"])
    }

    func testAppJournalRequestRefusedBeforeAStepIsNotTheRetryAfterIt() async throws {
        // A test's condition waits for the refusal of an open (an archive of another session); after its step it retries
        // the equal request, which succeeds. Replay reaches the refusal before the app sends its first open (it holds
        // nothing): sent then, it is still the refused one, as the app has not reached the step the retry comes after.
        let open = { (id: UInt64) in
            try HelperWire.encode(.init(kind: .request, id: id, body: HelperBinary.encode(.object([
                "method": .string("chat.open"), "params": .object(["session": .string("s")])]))))
        }
        let refusal = try HelperWire.encode(.init(kind: .response, id: 1, body: HelperBinary.encode(.object([
            "error": .object(["code": .string("session"), "message": .string("Transcript belongs to another session")])]))))
        let answer = try HelperWire.encode(.init(kind: .response, id: 2, body: HelperBinary.encode(.object(["result": .null]))))
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let capture = try journal.open(kind: "helper", input: .null)
        try capture.action(kind: "wire", value: .bytes(open(1)))
        try capture.emit(kind: "read", value: .bytes(refusal))
        try await journal.open(kind: "step", input: .null).reach(.object(["at": .string("site")]))
        try capture.action(kind: "wire", value: .bytes(open(2)))
        try capture.emit(kind: "read", value: .bytes(answer))
        try capture.action(kind: "close")
        try capture.emit(kind: "end")
        try capture.emit(kind: "exit")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        let replay = try journal.open(kind: "helper", input: .null)
        var bytes = Data()
        try replay.listen({ if $0.kind == "in.read" { bytes.append(AppReplay.bytes($0.value)) } }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        try replay.action(kind: "wire", value: .bytes(open(1)))
        XCTAssertEqual(bytes, refusal, "The condition before the step gets its refusal")
        try await journal.open(kind: "step", input: .null).reach()
        try replay.action(kind: "wire", value: .bytes(open(2)))
        try replay.action(kind: "close")
        try journal.finish()
        XCTAssertEqual(bytes, refusal + answer)
        XCTAssertEqual(journal.relaxed, [])
    }

    func testAppJournalAnswerInAReadWithAnswersToUnsentRequestsComesAlone() throws {
        // A slot limiter sends independent requests in its own order, the next only after an answer. Capture sent A then
        // B and read both answers in one read; replay's app sends B first. B's answer comes; A's waits until A is sent.
        let request = { (id: UInt64, path: String) in
            try HelperWire.encode(.init(kind: .request, id: id, body: HelperBinary.encode(.object([
                "method": .string("files.branch"), "params": .object(["path": .string(path)])]))))
        }
        let answer = { (id: UInt64, text: String) in
            try HelperWire.encode(.init(kind: .response, id: id, body: HelperBinary.encode(.object(["result": .string(text)]))))
        }
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let capture = try journal.open(kind: "helper", input: .null)
        try capture.action(kind: "wire", value: .bytes(request(1, "a")))
        try capture.action(kind: "wire", value: .bytes(request(2, "b")))
        try capture.emit(kind: "read", value: .bytes(answer(1, "topic-a") + answer(2, "topic-b")))
        try capture.action(kind: "close")
        try capture.emit(kind: "end")
        try capture.emit(kind: "exit")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        let replay = try journal.open(kind: "helper", input: .null)
        var bytes = Data()
        try replay.listen({ if $0.kind == "in.read" { bytes.append(AppReplay.bytes($0.value)) } }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        try replay.action(kind: "wire", value: .bytes(request(1, "b")))
        XCTAssertEqual(bytes, try answer(1, "topic-b"), "The sent request's answer does not wait for the unsent one")
        try replay.action(kind: "wire", value: .bytes(request(2, "a")))
        XCTAssertEqual(bytes, try answer(1, "topic-b") + answer(2, "topic-a"))
        try replay.action(kind: "close")
        try journal.finish()
    }

    func testAppJournalResponseDoesNotWaitForRequestsTheAppHasNotSentYet() throws {
        // The app sends independent requests in its own order (a 4-slot limiter, task scheduling). An answer to one it
        // has sent does not wait behind a request recorded earlier that it sends only after that answer.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        func request(_ id: UInt64, _ path: String) throws -> Data {
            try HelperWire.encode(.init(kind: .request, id: id, body: HelperBinary.encode(.object(["method": .string("files.branch"), "params": .object(["path": .string(path)])]))))
        }
        func response(_ id: UInt64, _ branch: String) throws -> Data {
            try HelperWire.encode(.init(kind: .response, id: id, body: HelperBinary.encode(.object(["result": .string(branch)]))))
        }
        var journal = try AppReplay(url: path, replaying: false)
        let capture = try journal.open(kind: "helper", input: .null)
        try capture.action(kind: "wire", value: .bytes(request(1, "a")))
        try capture.action(kind: "wire", value: .bytes(request(2, "b")))
        try capture.emit(kind: "read", value: .bytes(response(1, "topic-a")))
        try capture.emit(kind: "read", value: .bytes(response(2, "topic-b")))
        try capture.action(kind: "close")
        try capture.emit(kind: "end")
        try capture.emit(kind: "exit")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        let replay = try journal.open(kind: "helper", input: .null)
        var bytes = Data()
        try replay.listen({ if $0.kind == "in.read" { bytes.append(AppReplay.bytes($0.value)) } }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        // This run asks for b first and for a only once b is answered (its one slot).
        try replay.action(kind: "wire", value: .bytes(request(1, "b")))
        XCTAssertEqual(bytes, try response(1, "topic-b"))
        try replay.action(kind: "wire", value: .bytes(request(2, "a")))
        XCTAssertEqual(bytes, try response(1, "topic-b") + response(2, "topic-a"))
        try replay.action(kind: "close")
        try journal.finish()
    }

    func testAppJournalGatedInputWaitsForTheAppsOwnState() throws {
        // An input recorded after the app changed its own state (a pty's new size, which tmux's redraw after it is drawn
        // for) waits, with everything recorded after it, until the app has reached that state too. Animation frames pass
        // through other sizes in each run: the gate sees what the lifetime records later too. The stall report names
        // what it waits for.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let pty = try journal.open(kind: "pty", input: .null)
        try pty.emit(kind: "size", value: .unsigned(40))
        try pty.emit(kind: "size", value: .unsigned(44))
        try pty.emit(kind: "output", value: .bytes(Data([1])))
        try pty.emit(kind: "exit")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        let replayed = try journal.open(kind: "pty", input: .null)
        var rows: UInt64 = 35, events: [String] = []
        replayed.gate { event, later in
            event.kind == "in.size" && event.value != .unsigned(rows) && !later.contains { $0.kind == "in.size" && $0.value == .unsigned(rows) }
                ? "rows \(rows)" : nil
        }
        try replayed.listen({ events.append($0.kind) }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        XCTAssertEqual(events, [])
        rows = 43
        replayed.recheck()
        XCTAssertEqual(events, [], "A size no recorded frame had")
        XCTAssertEqual(journal.report, [
            "frontier: in.size lifetime 1 at record 2", "recent: seed lifetime 0 at record 0, open.pty lifetime 1 at record 1",
            "lifetime 0: next made at record 6; waiting []; listening []",
            #"lifetime 1: next in.size at record 2; waiting []; listening [""]; held: rows 43"#].joined(separator: "\n"))
        rows = 44
        replayed.recheck()
        XCTAssertEqual(events, ["in.size", "in.size", "in.output", "in.exit"])
        try journal.finish()
    }

    func testAppJournalGateHoldsNothingOnceTheAppClosesItsLifetime() throws {
        // A gated input waits for the app's own state (a pty's size). Once the app closes that lifetime (hangs it up,
        // closes an endpoint) or asks its helper to close what it shows, that state can no longer matter (a closing
        // view gets no more layout): the gate holds nothing more.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        for name in ["hung up", "closed by its helper"] {
            let pty = try journal.open(kind: "pty", input: .string(name))
            try pty.emit(kind: "size", value: .unsigned(44))
            try pty.emit(kind: "output", value: .bytes(Data([1])))
            try pty.action(kind: "hangup")
            try pty.emit(kind: "exit")
        }
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        var events: [String] = []
        let ptys = try ["hung up", "closed by its helper"].map { name in
            let pty = try journal.open(kind: "pty", input: .string(name))
            pty.gate { event, _ in event.kind == "in.size" ? "the app's pty is 43" : nil }
            try pty.listen({ events.append("\($0.kind) \($0.id)") }, failed: { XCTFail("Unexpected replay failure: \($0)") })
            return pty
        }
        XCTAssertEqual(events, [])
        try ptys[0].action(kind: "hangup")
        XCTAssertEqual(events, ["in.size 1", "in.output 1", "in.exit 1"])
        ptys[1].closing()
        XCTAssertEqual(events, ["in.size 1", "in.output 1", "in.exit 1", "in.size 2", "in.output 2"], "Its exit still follows its hangup")
        try ptys[1].action(kind: "hangup")
        try journal.finish()
        XCTAssertEqual(events, ["in.size 1", "in.output 1", "in.exit 1", "in.size 2", "in.output 2", "in.exit 2"])
    }

    func testAppJournalStallingReplayTakesHeldSizesAtTheAppsSize() throws {
        // A pty size the app's layout never gives its view (the view left the window before the sidebar reached it; a
        // size capture's layout passed through for a moment) would hold that terminal's input for good. When nothing
        // else can come (the replay would stall), those inputs come at the app's size and the journal lists them.
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let pty = try journal.open(kind: "pty", input: .string("launcher"))
        try pty.emit(kind: "size", value: .unsigned(109))
        try pty.emit(kind: "output", value: .bytes(Data([1])))
        try pty.action(kind: "hangup")
        try pty.emit(kind: "exit")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        var events: [String] = []
        let replayed = try journal.open(kind: "pty", input: .string("launcher"))
        replayed.gate { event, _ in event.kind == "in.size" ? "the app's pty is 146; recorded 109" : nil }
        try replayed.listen({ events.append($0.kind) }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        XCTAssertEqual(events, [])
        XCTAssertTrue(journal.waive())
        XCTAssertEqual(events, ["in.size", "in.output"])
        XCTAssertFalse(journal.waive(), "Nothing is held any more")
        try replayed.action(kind: "hangup")
        try journal.finish()
        XCTAssertEqual(events, ["in.size", "in.output", "in.exit"])
        XCTAssertEqual(journal.relaxed, ["size not reached on lifetime 1: the app's pty is 146; recorded 109"])
    }

    func testAppJournalGatedLifetimeInNoWindowWaitsWithoutHoldingTheOthers() throws {
        // A view in no window gets no layout: the size its gate waits for is not reached meanwhile. Its own records wait
        // (a redraw drawn at a stale size is lost when the view shrinks back) while the other lifetimes go on past them;
        // shown again, it holds what follows it until its layout reaches that size (what follows can move it away).
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let view = try journal.open(kind: "pty", input: .string("view")), other = try journal.open(kind: "pty", input: .string("other"))
        try view.emit(kind: "size", value: .unsigned(20))
        try other.emit(kind: "output", value: .bytes(Data([1])))
        try view.emit(kind: "output", value: .bytes(Data([2])))
        try other.emit(kind: "output", value: .bytes(Data([3])))
        for pty in [view, other] { try pty.emit(kind: "exit") }
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        var events: [String] = [], rows: UInt64 = 44
        let replayed = try ["view", "other"].map { name in
            let pty = try journal.open(kind: "pty", input: .string(name))
            if name == "view" { pty.gate { event, _ in event.kind == "in.size" && event.value != .unsigned(rows) ? "the app's pty has \(rows) rows" : nil } }
            try pty.listen({ events.append("\($0.kind) \($0.id) \(AppReplay.text($0.value))") }, failed: { XCTFail("Unexpected replay failure: \($0)") })
            return pty
        }
        XCTAssertEqual(events, [], "Shown, it holds what follows it")
        replayed[0].offscreen(true)
        let others = ["in.output 2 b\"\\u{01}\"", "in.output 2 b\"\\u{03}\"", "in.exit 2 null"]
        XCTAssertEqual(events, others)
        XCTAssertEqual(journal.report, [
            "frontier: made lifetime 0 at record 9",
            "recent: seed lifetime 0 at record 0, open.pty lifetime 1 at record 1, open.pty lifetime 2 at record 2, in.output lifetime 2 at record 4, in.output lifetime 2 at record 6, in.exit lifetime 2 at record 8",
            "lifetime 0: next made at record 9; waiting []; listening []",
            #"lifetime 1: next in.size at record 3; waiting []; listening [""]; held: the app's pty has 44 rows (in no window: the others go on)"#,
        ].joined(separator: "\n"))
        replayed[0].offscreen(false)
        XCTAssertEqual(events, others, "Shown again, it waits for its layout")
        rows = 20
        replayed[0].recheck()
        XCTAssertEqual(events, others + ["in.size 1 20", "in.output 1 b\"\\u{02}\"", "in.exit 1 null"])
        try journal.finish()
    }

    func testAppJournalPreservesEveryLifetimeAndRejectsDifferentActions() throws {
        let directory = System.temporary.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.rpl.zst")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let first = try XCTUnwrap(journal.open(kind: "helper", input: .string("local")))
        try first.emit(kind: "read", value: .bytes(Data([1, 2])))
        let second = try XCTUnwrap(journal.open(kind: "command", input: .string("ssh")))
        try first.action(kind: "write", value: .bytes(Data([3])))
        try second.emit(kind: "result", value: .bytes(Data([4])))
        try first.emit(kind: "exit", value: .bytes(Data([0])))
        try first.emit(kind: "end", value: .null)
        try journal.finish()

        journal = try AppReplay(url: path, replaying: true)
        var events: [AppReplay.Event] = []
        let replayFirst = try XCTUnwrap(journal.open(kind: "helper", input: .string("local")))
        try replayFirst.listen({ events.append($0) }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        let replaySecond = try XCTUnwrap(journal.open(kind: "command", input: .string("ssh")))
        try replaySecond.listen({ events.append($0) }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        try replayFirst.action(kind: "write", value: .bytes(Data([3])))
        try journal.finish()
        XCTAssertEqual(events, [
            .init(kind: "in.read", id: 1, value: .bytes(Data([1, 2]))),
            .init(kind: "in.result", id: 2, value: .bytes(Data([4]))),
            .init(kind: "in.exit", id: 1, value: .bytes(Data([0]))),
            .init(kind: "in.end", id: 1, value: .null)
        ])
        XCTAssertThrowsError(try AppReplay(url: path, replaying: false))
        journal = try AppReplay(url: path, replaying: true)
        XCTAssertThrowsError(try journal.open(kind: "helper", input: .string("different")))
        XCTAssertThrowsError(try journal.finish())
    }

    /// Every request, from any feature, borrows the one helper process and connection.
    func testPackagedHelperIsStartedOnceAndReusedByEveryRequest() async throws {
        let first = try await HelperApp.shared.session()
        var answers: [[Launch]] = []
        for _ in 0..<3 {
            let connection = try await HelperApp.shared.connection()
            XCTAssertTrue(connection === first.connection)
            answers.append(try await connection.request("launches.list", params: [String: String]()))
        }
        let again = try await HelperApp.shared.session()
        XCTAssertTrue(again === first)
        XCTAssertEqual(Set(answers.map { $0.map(\.key) }).count, 1, "The same helper answers every round")
    }

    /// A request the helper refuses leaves the process and connection in place for the next one.
    func testRejectedRequestDoesNotReplaceOrRestartTheConnection() async throws {
        let session = try await HelperApp.shared.session()
        do {
            let _: [String: String] = try await session.connection.request("chat.open", params: [String: String]())
            XCTFail("A malformed request must be refused")
        } catch let failure as HelperFailure {
            XCTAssertEqual(failure.code, "invalid_input")
        }
        let _: [Launch] = try await session.connection.request("launches.list", params: [String: String]())
        let again = try await HelperApp.shared.session()
        XCTAssertTrue(again === session)
    }

    /// Native partial writes report uncertain; preserve the old app warning against retrying them.
    func testErrorPreservesUncertainMutationOutcome() throws {
        let failure = try JSONDecoder().decode(HelperFailure.self, from: Data(#"{"code":"uncertain","message":"Cancelled"}"#.utf8))
        XCTAssertEqual(failure.code, "uncertain")
        XCTAssertTrue(failure.localizedDescription.contains("not retried"))
    }

    /// `uninstall-hooks` removes Dispatch's handlers from any helper path (older helpers' too) and
    /// keeps the user's handlers, other settings, file mode and a symlinked settings file.
    func testUninstallHooksRemovesOnlyDispatchHandlers() throws {
        let manager = FileManager.default
        let home = System.temporary.appendingPathComponent("uninstall-\(System.uuid().uuidString.prefix(8))")
        defer { try? manager.removeItem(at: home) }
        for folder in [".claude", ".codex", "dotfiles"] {
            try manager.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let claude = home.appendingPathComponent("dotfiles/claude-settings.json")
        try Data(#"""
        {"model":"opus","hooks":{
          "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"guard.sh"},
                                                   {"type":"command","command":"'/Users/a/.dispatch/bin/dispatch-helper' hook claude"}]},
                        {"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"'/Users/a/.dispatch/h4/bin/dispatch-helper4' hook claude"}]}],
          "Stop":[{"hooks":[{"type":"command","command":"echo dispatch-helper hook claude"},
                            {"type":"command","command":"'/x/dispatch-helper' hook claude; rm -rf ~"}]}]}}
        """#.utf8).write(to: claude)
        try manager.createSymbolicLink(at: home.appendingPathComponent(".claude/settings.json"), withDestinationURL: claude)
        let codex = home.appendingPathComponent(".codex/hooks.json")
        try Data(#"{"hooks":{"PermissionRequest":[{"hooks":[{"command":"'/Users/a/.dispatch/bin/dispatch-helper' hook codex","timeout":60,"type":"command"}]}],"Stop":[{"hooks":[{"command":"notify.sh","type":"command"}]}]}}"#.utf8).write(to: codex)
        try manager.setAttributes([.posixPermissions: 0o640], ofItemAtPath: codex.path)

        func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
            let process = Process(), pipe = Pipe()
            process.executableURL = try XCTUnwrap(HelperApp.executable)
            process.arguments = ["uninstall-hooks"] + arguments
            var environment = System.inherited
            environment["HOME"] = home.path
            environment["CLAUDE_CONFIG_DIR"] = nil; environment["CODEX_HOME"] = nil
            process.environment = environment
            process.standardOutput = pipe; process.standardError = pipe
            let exit = try TestSupport.live(process)
            return (exit.status, String(decoding: exit.output, as: UTF8.self))
        }
        func hooks(_ file: URL) throws -> [String: [[String: Any]]] {
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            return try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
        }
        func commands(_ groups: [[String: Any]]?) -> [String] {
            (groups ?? []).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        }

        let preview = try run(["--dry-run"])
        XCTAssertEqual(preview.status, 0, preview.output)
        XCTAssertTrue(preview.output.contains("would remove 2 Dispatch hooks"), preview.output)
        XCTAssertEqual(commands(try hooks(codex)["PermissionRequest"]).count, 1, "A dry run changes nothing")

        let removal = try run([])
        XCTAssertEqual(removal.status, 0, removal.output)
        XCTAssertTrue(removal.output.contains("removed 2 Dispatch hooks"), removal.output)
        XCTAssertTrue(removal.output.contains("removed 1 Dispatch hook\n"), removal.output)
        let settings = try hooks(claude)
        XCTAssertEqual(commands(settings["PreToolUse"]), ["guard.sh"], "The user's handler keeps its group; the emptied group goes")
        XCTAssertEqual(settings["PreToolUse"]?.first?["matcher"] as? String, "Bash")
        XCTAssertEqual(commands(settings["Stop"]).count, 2, "Commands that only look like the hook stay")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: claude)) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".claude/settings.json").path), claude.path)
        let events = try hooks(codex)
        XCTAssertNil(events["PermissionRequest"], "An event left empty is dropped")
        XCTAssertEqual(commands(events["Stop"]), ["notify.sh"])
        XCTAssertEqual(try manager.attributesOfItem(atPath: codex.path)[.posixPermissions] as? Int, 0o640)

        let again = try run([])
        XCTAssertEqual(again.status, 0)
        XCTAssertEqual(again.output.components(separatedBy: "no Dispatch hooks").count - 1, 2, again.output)
        XCTAssertEqual(try run(["--force"]).status, 2, "Unknown options are refused")
    }
}

extension HelperAppTests {
    /// A helper whose hello accepted `screens.host` reads its tmux and herdr screens from the multiplexer: the Mac
    /// publishes only its native tabs there (one publication would turn its host reads off), and every tab to a helper
    /// that names no such feature. An SSH login a helper observes in a tab is published to it either way. A terminal
    /// that publishes to nobody schedules no screen read for its output.
    @MainActor
    func testScreensArePublishedOnlyWhereTheHelperDoesNotReadThemItself() async throws {
        for accepted in [true, false] {
            let incoming = Pipe(), outgoing = Pipe(), link = SSHConnectionID()
            let connection = HelperConnection(read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting)
            let peer = HelperTransport(read: outgoing.fileHandleForReading, write: incoming.fileHandleForWriting)
            await HelperApp.shared.borrow(connection, for: link, features: accepted ? [HelperSession.screensHost] : [])
            let workspace = Workspace()
            workspace.spaces = []
            let helper = HelperWorkspace(workspace: workspace, renderer: nil, endpoint: .remote(link), host: .authenticated("remote"))
            workspace.helpers[.remote(link)] = helper
            // Backend 7 is a tmux server with terminal 11, backend 8 the helper's native shells with terminal 21.
            func node(_ id: UInt64, _ key: String, parent: UInt64?, kind: String) -> HelperBinary.Value {
                var fields: [String: HelperBinary.Value] = [
                    "id": .unsigned(id), "key": .string(key), "kind": .string(kind), "name": .string(key), "detached": .bool(false)]
                if let parent { fields["parent"] = .unsigned(parent) }
                return .object(fields)
            }
            func topology(_ backend: UInt64, root: UInt64, terminal: UInt64) -> HelperBinary.Value {
                .object(["backend": .unsigned(backend), "layouts": .array([]), "focus": .null, "nodes": .array([
                    node(root, "space-\(root)", parent: nil, kind: "workspace"),
                    node(terminal, "pane-\(terminal)", parent: root, kind: "terminal")])])
            }
            var decoder = HelperWire.Decoder()
            peer.start(receive: { bytes in
                do {
                    try decoder.feed(bytes) { message in
                        guard message.kind == .request, case .object(let body) = try HelperBinary.decode(message.body),
                              case .string(let method)? = body["method"] else { return }
                        func send(_ kind: HelperWire.Kind, _ value: HelperBinary.Value) throws {
                            peer.send(try HelperWire.encode(.init(kind: kind, id: message.id, body: HelperBinary.encode(value))))
                        }
                        switch method {
                        case "multiplexers.list":
                            try send(.response, .object(["result": .array([
                                .object(["mux": .unsigned(0), "name": .string("native"), "external": .bool(false), "program": .null]),
                                .object(["mux": .unsigned(1), "name": .string("tmux"), "external": .bool(true), "program": .null])])]))
                        case "backends.list": try send(.response, .object(["result": .array([])]))
                        case "backends.open":
                            guard case .object(let route)? = body["params"], case .unsigned(let mux)? = route["mux"] else { return }
                            let (backend, root, terminal): (UInt64, UInt64, UInt64) = mux == 1 ? (7, 10, 11) : (8, 20, 21)
                            try send(.notify, .object(["method": .string("backend.opened"), "params": .unsigned(backend)]))
                            try send(.notify, .object(["method": .string("topology"), "params": topology(backend, root: root, terminal: terminal)]))
                        // Subscriptions stay open; publications and anything else are acknowledged.
                        case "terminals.observe": break
                        default: try send(.response, .object(["result": .null]))
                        }
                    }
                } catch { XCTFail(String(describing: error)) }
            }, closed: { _ in })
            helper.open(HelperBackend(mux: 1, key: "tmux-server", label: "tmux", isDefault: nil))
            helper.open(HelperBackend(mux: 0, key: "native", label: "Terminal", isDefault: nil))
            func tab(_ terminal: UInt64) -> UUID? { workspace.spaces.flatMap(\.tabs).first { $0.terminal == terminal }?.id }
            try await TestSupport.eventually { tab(11) != nil && tab(21) != nil && helper.hostsScreens != nil }
            let tmux = try XCTUnwrap(tab(11)), native = try XCTUnwrap(tab(21))
            func targets(_ tab: UUID) -> [String] {
                ScreenPublication.targets(of: tab, workspace: workspace, helpers: [helper]).map { "\($0.terminal)\($0.observed ? " observed" : "")" }
            }
            XCTAssertEqual(helper.hostsScreens, accepted)
            XCTAssertEqual(targets(native), ["21"], "A native terminal has no host source: always published")
            XCTAssertEqual(targets(tmux), accepted ? [] : ["11"], "Only a helper without screens.host gets tmux screens")
            // An SSH login this helper observes in the tmux tab gets that tab's screen under its own id.
            helper.observe(99, tab: tmux)
            XCTAssertEqual(targets(tmux), accepted ? ["99 observed"] : ["11", "99 observed"])
            helper.unobserve(tmux)
            helper.stop(); connection.close(); peer.close()
            await HelperApp.shared.forget(link)
        }
        // Silent: output schedules no read until who reads it may have changed.
        let view = TerminalView(id: System.uuid(), directory: "/tmp")
        view.screenPublication.withLock { $0.silent = true }
        view.screenChanged()
        XCTAssertFalse(view.screenPublication.withLock { $0.pending })
        view.screenPublication.withLock { $0.silent = false }
        view.screenChanged()
        XCTAssertTrue(view.screenPublication.withLock { $0.pending })
    }
}

extension HelperAppTests {
    /// A chat tab's tmux terminal off screen for `followGrace` asks its helper to hold its output (`terminals.follow`
    /// false, no subscription: the app has one attach of it); on screen again it follows at once. A native tab and a
    /// plain terminal tab never ask, nor does any tab of a helper without the feature.
    @MainActor
    func testHiddenChatTerminalsHoldTheirOutputAfterTheGraceAndFollowWhenShown() async throws {
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        defer { runtime.chat = previous }
        for accepted in [true, false] {
            runtime.chat = ChatCoordinator(enabled: true)
            let incoming = Pipe(), outgoing = Pipe(), link = SSHConnectionID()
            let connection = HelperConnection(read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting)
            let peer = HelperTransport(read: outgoing.fileHandleForReading, write: incoming.fileHandleForWriting)
            await HelperApp.shared.borrow(connection, for: link, features: [HelperSession.screensHost]
                + (accepted ? [HelperSession.terminalsFollow] : []))
            let workspace = Workspace()
            workspace.spaces = []
            let helper = HelperWorkspace(workspace: workspace, renderer: nil, endpoint: .remote(link), host: .authenticated("remote"))
            workspace.helpers[.remote(link)] = helper
            var shown: Set<UUID> = []
            helper.onScreen = { shown.contains($0) }
            final class Seen: @unchecked Sendable { var attached: [UInt64] = [], follows: [String] = [] }
            let seen = Seen()
            func node(_ id: UInt64, _ key: String, parent: UInt64?, kind: String) -> HelperBinary.Value {
                var fields: [String: HelperBinary.Value] = [
                    "id": .unsigned(id), "key": .string(key), "kind": .string(kind), "name": .string(key), "detached": .bool(false)]
                if let parent { fields["parent"] = .unsigned(parent) }
                return .object(fields)
            }
            var decoder = HelperWire.Decoder()
            peer.start(receive: { bytes in
                do {
                    try decoder.feed(bytes) { message in
                        guard message.kind == .request, case .object(let body) = try HelperBinary.decode(message.body),
                              case .string(let method)? = body["method"] else { return }
                        func send(_ kind: HelperWire.Kind, _ value: HelperBinary.Value) throws {
                            peer.send(try HelperWire.encode(.init(kind: kind, id: message.id, body: HelperBinary.encode(value))))
                        }
                        let params: [String: HelperBinary.Value]
                        if case .object(let value)? = body["params"] { params = value } else { params = [:] }
                        switch method {
                        case "multiplexers.list":
                            try send(.response, .object(["result": .array([
                                .object(["mux": .unsigned(0), "name": .string("native"), "external": .bool(false), "program": .null]),
                                .object(["mux": .unsigned(1), "name": .string("tmux"), "external": .bool(true), "program": .null])])]))
                        case "backends.list": try send(.response, .object(["result": .array([])]))
                        case "backends.open":
                            guard case .unsigned(let mux)? = params["mux"] else { return }
                            let (backend, root, terminal): (UInt64, UInt64, UInt64) = mux == 1 ? (7, 10, 11) : (8, 20, 21)
                            try send(.notify, .object(["method": .string("backend.opened"), "params": .unsigned(backend)]))
                            try send(.notify, .object(["method": .string("topology"), "params": .object([
                                "backend": .unsigned(backend), "layouts": .array([]), "focus": .null, "nodes": .array([
                                    node(root, "space-\(root)", parent: nil, kind: "workspace"),
                                    node(terminal, "pane-\(terminal)", parent: root, kind: "terminal")])])]))
                        case "terminals.attach":
                            guard case .unsigned(let terminal)? = params["terminal"] else { return }
                            DispatchQueue.main.async { seen.attached.append(terminal) }
                            try send(.notify, .object(["method": .string("terminal.attached"), "params": .object([:])]))
                        case "terminals.follow":
                            guard case .unsigned(let terminal)? = params["terminal"], case .bool(let following)? = params["following"]
                            else { return }
                            let entry = "\(terminal) \(following)" + (params["subscription"] == nil ? "" : " subscription")
                            DispatchQueue.main.async { seen.follows.append(entry) }
                            try send(.response, .object(["result": .null]))
                        default: try send(.response, .object(["result": .null]))
                        }
                    }
                } catch { XCTFail(String(describing: error)) }
            }, closed: { _ in })
            helper.open(HelperBackend(mux: 1, key: "tmux-server", label: "tmux", isDefault: nil))
            helper.open(HelperBackend(mux: 0, key: "native", label: "Terminal", isDefault: nil))
            func tab(_ terminal: UInt64) -> UUID? { workspace.spaces.flatMap(\.tabs).first { $0.terminal == terminal }?.id }
            try await TestSupport.eventually { tab(11) != nil && tab(21) != nil && helper.followsOutput != nil }
            let tmux = try XCTUnwrap(tab(11)), native = try XCTUnwrap(tab(21))
            // Both are chat tabs; the tmux one shows its transcript, so its terminal is off screen.
            for id in [tmux, native] { runtime.chat.session(for: id).active = true }
            var descriptors: [Int32] = [0, 0]
            XCTAssertEqual(pipe(&descriptors), 0)
            defer { close(descriptors[1]) }
            let channels = [tmux, native].map { _ in
                HelperTerminal(fd: dup(descriptors[0]), validate: { _, _ in true }, ready: { _, _ in }, retired: { _ in })
            }
            helper.attach(tmux, channels[0]); helper.attach(native, channels[1])
            try await TestSupport.eventually { Set(seen.attached) == [11, 21] }
            if accepted {
                try await TestSupport.eventually { seen.follows == ["11 false"] }
                shown.insert(tmux); helper.reconsider(tmux)
                try await TestSupport.eventually { seen.follows == ["11 false", "11 true"] }
                // Back to the transcript and out again within the grace: nothing is held.
                shown.remove(tmux); helper.reconsider(tmux)
                shown.insert(tmux); helper.reconsider(tmux)
                // An agent that exits leaves a plain terminal tab, which follows even off screen.
                shown.remove(tmux); helper.reconsider(tmux)
                try await TestSupport.eventually { seen.follows == ["11 false", "11 true", "11 false"] }
                // This app reading the hidden screen itself follows at once, and holds again once reads stop.
                helper.screenRead(tmux)
                try await TestSupport.eventually { seen.follows == ["11 false", "11 true", "11 false", "11 true"] }
                try await TestSupport.eventually(timeout: .seconds(8)) {
                    seen.follows == ["11 false", "11 true", "11 false", "11 true", "11 false"]
                }
                runtime.chat.session(for: tmux).active = false
                try await TestSupport.eventually { seen.follows == ["11 false", "11 true", "11 false", "11 true", "11 false", "11 true"] }
            } else {
                try await TestSupport.pause(for: .seconds(3))
                XCTAssertEqual(seen.follows, [], "A helper without terminals.follow is never asked")
            }
            try await TestSupport.pause(for: .seconds(3))
            XCTAssertFalse(seen.follows.contains { $0.hasPrefix("21 ") }, "A native terminal always follows")
            channels.forEach { $0.close() }
            helper.stop(); connection.close(); peer.close()
            await HelperApp.shared.forget(link)
        }
    }
}

/// Fewer writes and wakes per unit of helper traffic, same bytes in the same order (HelperTransport).
extension HelperAppTests {
    /// Reads `count` bytes from `fd`, waiting at most 5 s (the transport writes on its own queue).
    private func drain(_ fd: Int32, count: Int) -> Data {
        var received = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        for _ in 0..<50 where received.count < count {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) > 0 else { continue }
            let got = read(fd, &buffer, buffer.count)
            guard got > 0 else { break }
            received.append(contentsOf: buffer.prefix(got))
        }
        return received
    }

    /// A burst of frames queued while the transport is busy leaves in one `write`, byte for byte; a lone frame on an
    /// idle transport is written as soon as its send has run (no timer holds it).
    func testQueuedBurstLeavesInOneWriteAndALoneFrameAtOnce() throws {
        let incoming = Pipe(), outgoing = Pipe()
        let transport = HelperTransport(read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting)
        defer { transport.close() }
        let frames = try (0..<200).map { index in
            try HelperWire.encode(.init(kind: .request, id: UInt64(index + 1), body: Data(repeating: UInt8(index % 251), count: 40)))
        }
        let busy = DispatchSemaphore(value: 0)
        transport.queue.async { busy.wait() }
        for frame in frames { transport.send(frame) }
        busy.signal()
        let expected = frames.reduce(Data(), +)
        let fd = outgoing.fileHandleForReading.fileDescriptor
        XCTAssertEqual(drain(fd, count: expected.count), expected)
        XCTAssertEqual(transport.queue.sync { transport.writes }, 1, "200 queued frames, one write")

        let key = try HelperWire.encode(.init(kind: .request, id: 201, body: Data("k".utf8)))
        transport.send(key)
        // The send's block, then the flush it queued behind itself: the frame is in the pipe already.
        transport.queue.sync {}
        transport.queue.sync {}
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&descriptor, 1, 0), 1, "A lone frame waits for nothing")
        XCTAssertEqual(drain(fd, count: key.count), key)
        XCTAssertEqual(transport.queue.sync { transport.writes }, 2)
    }

    /// Frames the helper wrote in many writes while the transport was busy are read in one wake and handed over in one
    /// `receive`.
    func testInboundBurstIsReadInOneWakeAndHandedOverOnce() async throws {
        let incoming = Pipe(), outgoing = Pipe()
        let transport = HelperTransport(read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting)
        defer { transport.close() }
        final class Received: @unchecked Sendable { var chunks: [Data] = [] }
        let received = Received()
        transport.start(receive: { received.chunks.append($0) }, closed: { _ in })
        transport.queue.sync {}
        let frames = try (0..<50).map { index in
            try HelperWire.encode(.init(kind: .notify, id: 1, body: Data(repeating: UInt8(index), count: 64)))
        }
        let busy = DispatchSemaphore(value: 0)
        transport.queue.async { busy.wait() }
        let fd = incoming.fileHandleForWriting.fileDescriptor
        for frame in frames {
            XCTAssertEqual(frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }, frame.count)
        }
        busy.signal()
        let expected = frames.reduce(Data(), +)
        try await TestSupport.eventually {
            transport.queue.sync { received.chunks.reduce(0) { $0 + $1.count } } >= expected.count
        }
        transport.queue.sync {
            XCTAssertEqual(received.chunks, [expected], "50 writes, one wake, one receive")
            XCTAssertEqual(transport.deliveries, 1)
        }
    }
}

/// The follow policy's grace under reads and `active` flips (HelperWorkspace.reconsider, screenRead).
extension HelperAppTests {
    /// A hidden chat tab whose screen this app reads during its grace keeps following while read, and once the reads stop
    /// its output is held once (one `terminals.follow` false). A brief `active` flip during the grace keeps the grace's
    /// end: the hold comes `followGrace` after the terminal went off screen, not a whole grace after the flip.
    @MainActor
    func testHiddenChatTerminalReadsAndActiveFlipsDuringTheGraceHoldOnceAtItsEnd() async throws {
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        defer { runtime.chat = previous }
        runtime.chat = ChatCoordinator(enabled: true)
        let incoming = Pipe(), outgoing = Pipe(), link = SSHConnectionID()
        let connection = HelperConnection(read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting)
        let peer = HelperTransport(read: outgoing.fileHandleForReading, write: incoming.fileHandleForWriting)
        await HelperApp.shared.borrow(connection, for: link, features: [HelperSession.screensHost, HelperSession.terminalsFollow])
        let workspace = Workspace()
        workspace.spaces = []
        let helper = HelperWorkspace(workspace: workspace, renderer: nil, endpoint: .remote(link), host: .authenticated("remote"))
        workspace.helpers[.remote(link)] = helper
        var shown: Set<UUID> = []
        helper.onScreen = { shown.contains($0) }
        final class Seen: @unchecked Sendable { var attached: [UInt64] = [], follows: [String] = [] }
        let seen = Seen()
        func node(_ id: UInt64, _ key: String, parent: UInt64?, kind: String) -> HelperBinary.Value {
            var fields: [String: HelperBinary.Value] = [
                "id": .unsigned(id), "key": .string(key), "kind": .string(kind), "name": .string(key), "detached": .bool(false)]
            if let parent { fields["parent"] = .unsigned(parent) }
            return .object(fields)
        }
        var decoder = HelperWire.Decoder()
        peer.start(receive: { bytes in
            do {
                try decoder.feed(bytes) { message in
                    guard message.kind == .request, case .object(let body) = try HelperBinary.decode(message.body),
                          case .string(let method)? = body["method"] else { return }
                    func send(_ kind: HelperWire.Kind, _ value: HelperBinary.Value) throws {
                        peer.send(try HelperWire.encode(.init(kind: kind, id: message.id, body: HelperBinary.encode(value))))
                    }
                    let params: [String: HelperBinary.Value]
                    if case .object(let value)? = body["params"] { params = value } else { params = [:] }
                    switch method {
                    case "multiplexers.list":
                        try send(.response, .object(["result": .array([
                            .object(["mux": .unsigned(1), "name": .string("tmux"), "external": .bool(true), "program": .null])])]))
                    case "backends.list": try send(.response, .object(["result": .array([])]))
                    case "backends.open":
                        try send(.notify, .object(["method": .string("backend.opened"), "params": .unsigned(7)]))
                        try send(.notify, .object(["method": .string("topology"), "params": .object([
                            "backend": .unsigned(7), "layouts": .array([]), "focus": .null, "nodes": .array([
                                node(10, "space-10", parent: nil, kind: "workspace"),
                                node(11, "pane-11", parent: 10, kind: "terminal")])])]))
                    case "terminals.attach":
                        guard case .unsigned(let terminal)? = params["terminal"] else { return }
                        DispatchQueue.main.async { seen.attached.append(terminal) }
                        try send(.notify, .object(["method": .string("terminal.attached"), "params": .object([:])]))
                    case "terminals.follow":
                        guard case .unsigned(let terminal)? = params["terminal"], case .bool(let following)? = params["following"]
                        else { return }
                        DispatchQueue.main.async { seen.follows.append("\(terminal) \(following)") }
                        try send(.response, .object(["result": .null]))
                    default: try send(.response, .object(["result": .null]))
                    }
                }
            } catch { XCTFail(String(describing: error)) }
        }, closed: { _ in })
        helper.open(HelperBackend(mux: 1, key: "tmux-server", label: "tmux", isDefault: nil))
        try await TestSupport.eventually {
            workspace.spaces.flatMap(\.tabs).contains { $0.terminal == 11 } && helper.followsOutput != nil
        }
        let tmux = try XCTUnwrap(workspace.spaces.flatMap(\.tabs).first { $0.terminal == 11 }?.id)
        let session = runtime.chat.session(for: tmux)
        session.active = true
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { close(descriptors[1]) }
        let channel = HelperTerminal(fd: dup(descriptors[0]), validate: { _, _ in true }, ready: { _, _ in }, retired: { _ in })
        helper.attach(tmux, channel)
        try await TestSupport.eventually { seen.attached == [11] }
        try await TestSupport.eventually { seen.follows == ["11 false"] }
        shown.insert(tmux); helper.reconsider(tmux)
        try await TestSupport.eventually { seen.follows == ["11 false", "11 true"] }

        // Off screen again, and read every half second for longer than the grace: nothing is held meanwhile.
        shown.remove(tmux); helper.reconsider(tmux)
        for _ in 0..<6 {
            try await TestSupport.pause(for: .milliseconds(500))
            helper.screenRead(tmux)
        }
        XCTAssertEqual(seen.follows, ["11 false", "11 true"], "A tab read during its grace keeps following")
        // Once the reads stop it is held, once.
        try await TestSupport.eventually(timeout: .seconds(10)) { seen.follows == ["11 false", "11 true", "11 false"] }
        try await TestSupport.pause(for: .seconds(3))
        XCTAssertEqual(seen.follows, ["11 false", "11 true", "11 false"], "One hold once the reads stopped")

        // Shown and off screen again; an agent re-binding flips `active` off and on during the grace.
        shown.insert(tmux); helper.reconsider(tmux)
        try await TestSupport.eventually { seen.follows == ["11 false", "11 true", "11 false", "11 true"] }
        shown.remove(tmux); helper.reconsider(tmux)
        let hid = ContinuousClock.now
        try await TestSupport.pause(for: .milliseconds(1200))
        session.active = false
        // The session's observer reconsiders on the next main turn: the grace's timer is cancelled there.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { done.resume() } }
        session.active = true
        try await TestSupport.eventually(timeout: .seconds(5)) {
            seen.follows == ["11 false", "11 true", "11 false", "11 true", "11 false"]
        }
        let waited = hid.duration(to: .now)
        XCTAssertGreaterThan(waited, .milliseconds(1800), "Held only once the grace ended")
        XCTAssertLessThan(waited, .milliseconds(2800), "The flip did not restart the grace (\(waited))")
        channel.close()
        helper.stop(); connection.close(); peer.close()
        await HelperApp.shared.forget(link)
    }
}
