import Foundation
import Darwin
import XCTest
@testable import DispatchApp

/// The app's packaged helper (rewritten from upstream Helper2Tests for helper4). Each harness's hook payload
/// normalization moved into the helper: Helpers/helper4/bin/tests/hooks.rs bundled_native_hook_round and
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

    func testAppJournalRequiresNativeGenerationOutcomeBeforeFooter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for retire in [false, true] {
            let journal = try AppReplay(url: directory.appendingPathComponent("\(retire).jsonl"), replaying: false)
            let native = try journal.boundary(kind: "renderer", data: Data([1]))
            XCTAssertFalse(journal.settled)
            if retire {
                native.cancel()
                XCTAssertTrue(journal.settled)
                try journal.finish()
            } else { XCTAssertThrowsError(try journal.finish()) }
        }
    }

    func testAppJournalRetiredNativeGenerationNeverInventsReadiness() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("retired.jsonl")
        let captured = try AppReplay(url: path, replaying: false)
        let request = try captured.open(kind: "command", input: Data())
        let native = try captured.boundary(kind: "renderer", data: Data([1]))
        try request.action(kind: "start")
        native.cancel()
        try request.emit(kind: "result")
        try captured.finish()
        for early in [false, true] {
            let journal = try AppReplay(url: path, replaying: true)
            let request = try journal.open(kind: "command", input: Data())
            let native = try journal.boundary(kind: "renderer", data: Data([1]))
            var received: [String] = []
            try request.listen({ received.append($0.kind) }, failed: { XCTFail(String(describing: $0)) })
            if early { try native.arrive(ready: { XCTFail("Recorded retirement must not invent readiness") }, failed: { XCTFail(String(describing: $0)) }) }
            try request.action(kind: "start")
            XCTAssertEqual(received, [])
            native.cancel()
            XCTAssertEqual(received, ["in.result"])
            try journal.finish()
        }
    }

    func testAppJournalNativeBoundaryWaitsForBothOrdersAndRetainsItsOwner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("native.jsonl")
        let captured = try AppReplay(url: path, replaying: false)
        let call = try captured.open(kind: "command", input: Data())
        let old = try captured.boundary(kind: "renderer", data: Data([1]))
        try call.action(kind: "start")
        try old.arrive(ready: {}, failed: { XCTFail(String(describing: $0)) })
        try call.emit(kind: "result", data: Data([2]))
        try captured.finish()
        for early in [true, false] {
            let journal = try AppReplay(url: path, replaying: true)
            let request = try journal.open(kind: "command", input: Data())
            let boundary = try journal.boundary(kind: "renderer", data: Data([1]))
            var events: [String] = []
            try request.listen({ _ in events.append("result") }, failed: { XCTFail(String(describing: $0)) })
            if early { try boundary.arrive(ready: { events.append("ready") }, failed: { XCTFail(String(describing: $0)) }) }
            XCTAssertEqual(events, [])
            try request.action(kind: "start")
            if !early {
                XCTAssertEqual(events, [], "Recorded readiness cannot synthesize a native connection")
                try boundary.arrive(ready: { events.append("ready") }, failed: { XCTFail(String(describing: $0)) })
            }
            XCTAssertEqual(events, ["ready", "result"])
            try journal.finish()
        }
        let next = try AppReplay(url: directory.appendingPathComponent("next.jsonl"), replaying: false)
        XCTAssertThrowsError(try old.arrive(ready: { XCTFail("Retired generation delivered") }, failed: { _ in }))
        try next.finish()
    }

    func testAppJournalNativeBoundaryCancellationReleasesPendingCallbacks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("native.jsonl")
        let captured = try AppReplay(url: path, replaying: false)
        let call = try captured.open(kind: "command", input: Data())
        let boundary = try captured.boundary(kind: "renderer", data: Data([1]))
        try call.action(kind: "start")
        try boundary.arrive(ready: {}, failed: { _ in })
        try call.emit(kind: "result")
        try captured.finish()
        for outcome in ["cancel", "mismatch", "finish"] {
            let journal = try AppReplay(url: path, replaying: true)
            let call = try journal.open(kind: "command", input: Data())
            let boundary = try journal.boundary(kind: "renderer", data: Data([1]))
            var failures: [HelperFailure] = []
            try call.listen({ _ in XCTFail("Unexpected input") }, failed: { failures.append($0 as! HelperFailure) })
            try boundary.arrive(ready: { XCTFail("Native ready crossed an unconsumed action") }, failed: { failures.append($0 as! HelperFailure) })
            if outcome == "cancel" { boundary.cancel() }
            else if outcome == "mismatch" { XCTAssertThrowsError(try call.action(kind: "wrong")) }
            else { XCTAssertThrowsError(try journal.finish()) }
            XCTAssertEqual(failures.count, 2)
            XCTAssertEqual(failures.first, failures.last)
            boundary.cancel()
            XCTAssertEqual(failures.count, 2)
            XCTAssertThrowsError(try journal.finish())
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let first = try journal.open(kind: "command", input: Data("first".utf8))
        let second = try journal.open(kind: "command", input: Data("second".utf8))
        try first.action(kind: "write", data: Data([1]))
        try first.emit(kind: "result")
        try second.emit(kind: "result")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        let pending = try journal.open(kind: "command", input: Data("first".utf8))
        let late = try journal.open(kind: "command", input: Data("second".utf8))
        var failures: [HelperFailure] = []
        var events: [AppReplay.Event] = []
        try pending.listen({ events.append($0) }, failed: { failures.append($0 as! HelperFailure) })
        var firstFailure: HelperFailure?
        XCTAssertThrowsError(try pending.action(kind: "write", data: Data([2]))) {
            firstFailure = $0 as? HelperFailure
        }
        try late.listen({ events.append($0) }, failed: { failures.append($0 as! HelperFailure) })
        let expected = try XCTUnwrap(firstFailure)
        XCTAssertEqual(failures, [expected, expected])
        XCTAssertEqual(events, [])
        XCTAssertThrowsError(try pending.action(kind: "write", data: Data([3]))) {
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
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let path = directory.appendingPathComponent("app.jsonl")
            defer { try? FileManager.default.removeItem(at: directory) }
            var journal = try AppReplay(url: path, replaying: false)
            let first = try journal.open(kind: kind, input: Data())
            for event in before { try first.emit(kind: event) }
            let pending = try journal.open(kind: "command", input: Data())
            try pending.action(kind: "write", data: Data([1]))
            for event in after { try first.emit(kind: event) }
            try pending.emit(kind: "result")
            try journal.finish()
            journal = try AppReplay(url: path, replaying: true)
            var received: [String] = []
            var failed: [String] = []
            let previous = try journal.open(kind: kind, input: Data())
            try previous.listen({ received.append($0.kind) }, failed: { _ in failed.append("previous") })
            let current = try journal.open(kind: "command", input: Data())
            try current.listen({ received.append($0.kind) }, failed: { _ in failed.append("current") })
            XCTAssertThrowsError(try current.action(kind: "write", data: Data([2])))
            XCTAssertEqual(received, before.map { "in." + $0 })
            XCTAssertEqual(failed.sorted(), after.isEmpty ? ["current"] : ["current", "previous"])
            XCTAssertThrowsError(try journal.finish())
        }
    }

    func testAppJournalRoutesOverlappingLifetimesAndKeepsTheirActionsOrdered() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let command = try journal.open(kind: "command", input: Data("probe".utf8))
        let helper = try journal.open(kind: "helper", input: Data("stdio".utf8))
        try helper.action(kind: "write", data: Data([1]))
        try helper.action(kind: "write", data: Data([2]))
        try command.emit(kind: "result", data: Data([3]))
        try helper.emit(kind: "end")
        try helper.emit(kind: "exit")
        try journal.finish()
        for ordered in [true, false] {
            journal = try AppReplay(url: path, replaying: true)
            var events: [AppReplay.Event] = []
            let first = try journal.open(kind: "helper", input: Data("stdio".utf8))
            let second = try journal.open(kind: "command", input: Data("probe".utf8))
            XCTAssertEqual([first.id, second.id], [2, 1])
            try first.listen({ events.append($0) }, failed: { _ in })
            try second.listen({ events.append($0) }, failed: { _ in })
            if ordered {
                try first.action(kind: "write", data: Data([1]))
                try first.action(kind: "write", data: Data([2]))
                try journal.finish()
                XCTAssertEqual(events, [.init(kind: "in.result", id: 1, data: Data([3])),
                                        .init(kind: "in.end", id: 2, data: Data()),
                                        .init(kind: "in.exit", id: 2, data: Data())])
            } else {
                XCTAssertThrowsError(try first.action(kind: "write", data: Data([2])))
                XCTAssertThrowsError(try journal.finish())
            }
        }
    }

    func testAppJournalDistinguishesSequentialAndAmbiguousIdenticalCreations() throws {
        for overlap in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let path = directory.appendingPathComponent("app.jsonl")
            defer { try? FileManager.default.removeItem(at: directory) }
            var journal = try AppReplay(url: path, replaying: false)
            let first = try journal.open(kind: "command", input: Data())
            if !overlap { try first.emit(kind: "result", data: Data([1])) }
            let second = try journal.open(kind: "command", input: Data())
            if overlap { try first.emit(kind: "result", data: Data([1])) }
            try second.emit(kind: "result", data: Data([2]))
            try journal.finish()
            journal = try AppReplay(url: path, replaying: true)
            if overlap {
                XCTAssertThrowsError(try journal.open(kind: "command", input: Data()))
                XCTAssertThrowsError(try journal.finish())
            } else {
                var events: [AppReplay.Event] = []
                for _ in 0..<2 {
                    let ticket = try journal.open(kind: "command", input: Data())
                    try ticket.listen({ events.append($0) }, failed: { XCTFail("Unexpected replay failure: \($0)") })
                }
                try journal.finish()
                XCTAssertEqual(events, [.init(kind: "in.result", id: 1, data: Data([1])),
                                        .init(kind: "in.result", id: 2, data: Data([2]))])
            }
        }
    }

    func testAppJournalCreationValuesPreserveJSONTypes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let capture = try journal.open(kind: "command", input: Data(#"{"value":true}"#.utf8))
        try capture.emit(kind: "result")
        try journal.finish()
        journal = try AppReplay(url: path, replaying: true)
        XCTAssertThrowsError(try journal.open(kind: "command", input: Data(#"{"value":1}"#.utf8)))
        let diagnostic = try XCTUnwrap(journal.diagnostic)
        let events = try JSONDecoder().decode([AppReplay.Event].self, from: Data(contentsOf: diagnostic))
        XCTAssertEqual(events, [
            AppReplay.Event(kind: "open.command", id: 1, data: Data(#"{"value":true}"#.utf8)),
            AppReplay.Event(kind: "open.command", id: 1, data: Data(#"{"value":1}"#.utf8)),
        ])
        let permissions = try FileManager.default.attributesOfItem(atPath: diagnostic.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertThrowsError(try journal.finish())
    }

    func testAppJournalBindsWireIDsWithoutChangingValuesOrCancellation() throws {
        for identity: UInt64 in [72, 41] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let path = directory.appendingPathComponent("app.jsonl")
            defer { try? FileManager.default.removeItem(at: directory) }
            let body = try HelperBinary.encode(.object(["method": .string("hello"), "params": .object([:])]))
            let answer = try HelperBinary.encode(.object(["result": .array([])]))
            var journal = try AppReplay(url: path, replaying: false)
            let capture = try journal.open(kind: "helper", input: Data(#"{"arguments":["--stdio"],"role":"local"}"#.utf8))
            try capture.action(kind: "wire", data: HelperWire.encode(.init(kind: .request, id: 41, body: body)))
            let response = try HelperWire.encode(.init(kind: .response, id: 41, body: answer))
            try capture.emit(kind: "read", data: response.prefix(4))
            try capture.action(kind: "wire", data: HelperWire.encode(.init(kind: .request, id: 42, body: body)))
            try capture.emit(kind: "read", data: response.dropFirst(4))
            try capture.action(kind: "wire", data: HelperWire.encode(.init(kind: .cancel, id: 42, body: Data())))
            try capture.emit(kind: "end")
            try capture.emit(kind: "exit")
            try journal.finish()

            journal = try AppReplay(url: path, replaying: true)
            let replay = try journal.open(kind: "helper", input: Data(#"{"role":"local","arguments":["--stdio"]}"#.utf8))
            var bytes = Data()
            try replay.listen({ if $0.kind == "in.read" { bytes.append($0.data) } }, failed: { XCTFail("Unexpected replay failure: \($0)") })
            try replay.action(kind: "wire", data: HelperWire.encode(.init(kind: .request, id: identity, body: body)))
            try replay.action(kind: "wire", data: HelperWire.encode(.init(kind: .request, id: 73, body: body)))
            try replay.action(kind: "wire", data: HelperWire.encode(.init(kind: .cancel, id: 73, body: Data())))
            try journal.finish()
            XCTAssertEqual(bytes, try HelperWire.encode(.init(kind: .response, id: identity, body: answer)))
        }
    }

    func testAppJournalPreservesEveryLifetimeAndRejectsDifferentActions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("app.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AppReplay(url: path, replaying: false)
        let first = try XCTUnwrap(journal.open(kind: "helper", input: Data("local".utf8)))
        try first.emit(kind: "read", data: Data([1, 2]))
        let second = try XCTUnwrap(journal.open(kind: "command", input: Data("ssh".utf8)))
        try first.action(kind: "write", data: Data([3]))
        try second.emit(kind: "result", data: Data([4]))
        try first.emit(kind: "exit", data: Data([0]))
        try first.emit(kind: "end", data: Data())
        try journal.finish()

        journal = try AppReplay(url: path, replaying: true)
        var events: [AppReplay.Event] = []
        let replayFirst = try XCTUnwrap(journal.open(kind: "helper", input: Data("local".utf8)))
        try replayFirst.listen({ events.append($0) }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        let replaySecond = try XCTUnwrap(journal.open(kind: "command", input: Data("ssh".utf8)))
        try replaySecond.listen({ events.append($0) }, failed: { XCTFail("Unexpected replay failure: \($0)") })
        try replayFirst.action(kind: "write", data: Data([3]))
        try journal.finish()
        XCTAssertEqual(events, [
            .init(kind: "in.read", id: 1, data: Data([1, 2])),
            .init(kind: "in.result", id: 2, data: Data([4])),
            .init(kind: "in.exit", id: 1, data: Data([0])),
            .init(kind: "in.end", id: 1, data: Data())
        ])
        XCTAssertThrowsError(try AppReplay(url: path, replaying: false))
        journal = try AppReplay(url: path, replaying: true)
        XCTAssertThrowsError(try journal.open(kind: "helper", input: Data("different".utf8)))
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
}
