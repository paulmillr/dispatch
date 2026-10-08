import Foundation
import CryptoKit
import XCTest
@testable import DispatchApp

@MainActor
final class SSHTransportTests: XCTestCase {
    func testBootstrapUsesAuthenticatedMasterAndNeverRedialsAfterLoss() async throws {
        try await remote { app, server, _ in
            let link = try XCTUnwrap(app.runtime.ssh.links.values.first)
            let resources = try SSHHelperTestResources.prepare(under: server.root)
            let installed = try await SSHBootstrap.startHelper4(master: link.launch.master, resources: resources,
                sessionID: link.launch.sessionID, publish: false)
            defer { installed.session.close() }
            let cached = try await SSHBootstrap.startHelper4(master: link.launch.master, resources: resources,
                sessionID: link.launch.sessionID, publish: false)
            defer { cached.session.close() }
            XCTAssertEqual(cached.relativePath, installed.relativePath)
            XCTAssertEqual(cached.session.info.version, installed.session.info.version)
            let launches = try await HelperClient(cached.session.connection).launches()
            XCTAssertFalse(launches.isEmpty)
            let master = link.launch.master
            let closed = try await SSHCommand.run(executable: master.executable,
                arguments: master.controlArguments("exit"))
            XCTAssertEqual(closed.status, 0)
            let lost = try await SSHCommand.run(executable: master.executable,
                arguments: master.arguments(command: "printf SHOULD_NOT_RUN"))
            XCTAssertNotEqual(lost.status, 0)
            XCTAssertFalse(String(decoding: lost.output, as: UTF8.self).contains("SHOULD_NOT_RUN"))
        }
    }

    func testRemoteTranscriptPagingMatchesLocalAndDetectsReplacement() async throws {
        try await remote { app, server, _ in
            let link = try XCTUnwrap(app.runtime.ssh.links.values.first)
            let path = server.root.appendingPathComponent("history.jsonl"), id = UUID().uuidString
            func line(_ type: String, _ payload: [String: String]) throws -> Data {
                try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": "2000-01-01T00:00:00Z", "payload": payload], options: [.sortedKeys]) + Data([10])
            }
            let header = try line("session_meta", ["id": id, "cli_version": "99.0.0"])
            var history = header
            for index in 0..<800 {
                history += try line("event_msg", ["type": "task_started", "turn_id": "turn-\(index)"])
                history += try line("event_msg", ["type": "user_message", "turn_id": "turn-\(index)", "message": "Message \(index)"])
                history += try line("event_msg", ["type": "task_complete", "turn_id": "turn-\(index)"])
            }
            try history.write(to: path)
            let source = HelperChat.Transcript(key: "codex", path: path.path, session: id)
            let local = HelperChat(archive: source), remote = HelperChat(archive: source, endpoint: .remote(link.launch.connectionID))
            var localPage = try await local.page(earlier: nil), remotePage = try await remote.page(earlier: nil)
            let oldCursor = try XCTUnwrap(remotePage.earlier)
            var records: [HelperChat.Record] = []
            for _ in 0..<30 {
                XCTAssertEqual(remotePage.records, localPage.records)
                records = remotePage.records + records
                guard let a = localPage.earlier, let b = remotePage.earlier else {
                    XCTAssertNil(localPage.earlier); XCTAssertNil(remotePage.earlier)
                    break
                }
                localPage = try await local.page(earlier: a)
                remotePage = try await remote.page(earlier: b)
            }
            XCTAssertEqual(records.filter { $0.kind == "user" }.map(\.text), (0..<800).map { "Message \($0)" })
            let appended = try line("event_msg", ["type": "user_message", "turn_id": "new", "message": "Incremental"])
            let file = try FileHandle(forWritingTo: path)
            try file.seekToEnd(); try file.write(contentsOf: appended); try file.close()
            let liveA = try await local.page(earlier: nil), liveB = try await remote.page(earlier: nil)
            XCTAssertEqual(liveB.records, liveA.records)
            XCTAssertTrue(liveB.records.contains { $0.text == "Incremental" })
            try (header + appended).write(to: path, options: .atomic)
            do {
                let stale = try await remote.page(earlier: oldCursor)
                XCTAssertTrue(stale.records.isEmpty)
            } catch let failure as HelperFailure { XCTAssertEqual(failure.code, "history") }
            let replaced = try await remote.page(earlier: nil)
            XCTAssertEqual(replaced.records.filter { $0.kind == "user" }.map(\.text), ["Incremental"])
        }
    }

    func testMasterCommandPreservesSSHChildIdentityWithShellExitTrap() async throws {
        let master = SSHMaster(executable: "/usr/bin/ssh", controlPath: "/tmp/unused-control", destination: "fixture")
        let command = try XCTUnwrap(master.arguments(command: "printf '%s\\n' \"$$\"").last)
        // A login-shell cleanup trap prevents implicit tail-command exec.
        // The helper must still inherit sshd's original child PID, since its
        // authentication checks require sshd to be its direct parent.
        let script = "printf '%s\\n' \"$$\"; trap ':' EXIT; " + command
        let result = try await SSHCommand.run(executable: "/bin/bash", arguments: ["-c", script])
        XCTAssertEqual(result.status, 0)
        let pids = String(decoding: result.output, as: UTF8.self).split(whereSeparator: \.isNewline)
        XCTAssertEqual(pids.count, 2)
        XCTAssertEqual(pids.first, pids.last)
    }

    func testInvocationPreservesOptionsAndOpenSSHCommandJoining() throws {
        let parsed = try XCTUnwrap(SSHInvocation.parse(["-vv", "-p2222", "-i", "/tmp/key with spaces", "-J", "jump", "-tt", "--", "user@host", "printf", "'%s'", "hello"], isTerminal: true))
        XCTAssertEqual(parsed.options, ["-v", "-v", "-p", "2222", "-i", "/tmp/key with spaces", "-J", "jump"])
        XCTAssertEqual(parsed.destination, "user@host")
        XCTAssertEqual(parsed.command, "printf '%s' hello")
        XCTAssertTrue(parsed.forcedTTY)
        XCTAssertEqual(SSHInvocation.parse(["-t", "host", "ls", "-la"], isTerminal: true)?.command, "ls -la")
        XCTAssertNotNil(SSHInvocation.parse(["host"], isTerminal: true))
        XCTAssertNil(SSHInvocation.parse(["host"], isTerminal: false))
    }

    func testUnsupportedInvocationsPassThrough() {
        for args in [["-N", "host"], ["-T", "host"], ["-f", "host"], ["-s", "host", "sftp"], ["-G", "host"], ["-O", "check", "host"],
                     ["-S", "/tmp/control", "host"], ["-M", "host"], ["host", "uptime"], ["-W", "host:80", "jump"],
                     ["-o", "RemoteCommand=top", "host"], ["-oControlMaster=auto", "host"], ["-o", "controlpath /tmp/socket", "host"],
                     ["-t", "-o", "SessionType=none", "host"], ["-p"], ["--"], ["-Z", "host"],
                     // OpenSSH reads these as options, not a remote command.
                     ["-t", "host", "-l", "alice"], ["-t", "host", "--", "top"]] {
            XCTAssertNil(SSHInvocation.parse(args, isTerminal: true), args.description)
        }
    }

    func testResolvedConfigurationHonorsUserOverrides() async throws {
        let parsed = try XCTUnwrap(SSHInvocation.parse(["host"], isTerminal: true))
        let normal = "hostname host\nuser user\ncontrolmaster false\ncontrolpersist no\nremotecommand none\nrequesttty auto\n"
        XCTAssertTrue(parsed.supports(configuration: normal))
        XCTAssertFalse(parsed.supports(configuration: ""))
        for extra in ["controlmaster auto", "controlpath /tmp/existing", "remotecommand tmux attach", "requesttty no", "sessiontype none", "forkafterauthentication yes"] {
            XCTAssertFalse(parsed.supports(configuration: normal + extra + "\n"), extra)
        }
        let actual = try await SSHCommand.run(executable: "/usr/bin/ssh", arguments: ["-G", "-F", "/dev/null", "example.invalid"])
        XCTAssertEqual(actual.status, 0)
        XCTAssertTrue(parsed.supports(configuration: String(decoding: actual.output, as: UTF8.self)))
    }

    func testQueuedFramesPreserveOrderAcrossPartialDrainsAndReuse() throws {
        // The helper transport's output queue, written in rounds while the peer drains part of each round.
        let output = Pipe(), unused = Pipe()
        let transport = HelperTransport(read: unused.fileHandleForReading, write: output.fileHandleForWriting)
        defer { transport.close() }
        var decoder = HelperWire.Decoder(), received: [HelperWire.Message] = [], expected: [HelperWire.Message] = []
        func drain(_ frames: Int) throws {
            var bytes = Data()
            for _ in 0..<1000 where bytes.count < frames * 14 {
                bytes += try XCTUnwrap(output.fileHandleForReading.read(upToCount: frames * 14 - bytes.count))
            }
            try decoder.feed(bytes) { received.append($0) }
        }
        for round in 0..<30 {
            for index in 0..<300 {
                let message = HelperWire.Message(kind: .chunk, id: UInt64(round * 300 + index), body: Data([UInt8(truncatingIfNeeded: index)]))
                transport.send(try HelperWire.encode(message)); expected.append(message)
            }
            try drain(250)
            XCTAssertEqual(received, Array(expected.prefix(received.count)))
        }
        try drain(expected.count - received.count)
        XCTAssertEqual(received, expected)
        try decoder.finish()
    }

    func testFramesSurviveEverySplitAndRejectInvalidLengths() throws {
        let frames = [HelperWire.Message(kind: .request, id: 0, body: Data("{}".utf8)),
                      HelperWire.Message(kind: .chunk, id: 0x1234_5678_9abc, body: Data(0...255)),
                      HelperWire.Message(kind: .response, id: 42, body: Data())]
        let wire = try frames.reduce(into: Data()) { $0.append(try HelperWire.encode($1)) }
        func decode(_ parts: [Data]) throws -> [HelperWire.Message] {
            var decoder = HelperWire.Decoder(), decoded: [HelperWire.Message] = []
            for part in parts { try decoder.feed(part) { decoded.append($0) } }
            try decoder.finish()
            return decoded
        }
        for offset in 0...wire.count {
            XCTAssertEqual(try decode([Data(wire.prefix(offset)), Data(wire.dropFirst(offset))]), frames)
        }
        XCTAssertEqual(try decode(wire.map { Data([$0]) }), frames)
        // Header: u32 LE length (kind + id + body), u8 kind, u64 LE id.
        let id = Data(repeating: 0, count: 8)
        for (header, failure) in [(Data([4, 0, 0, 0, 1]) + id, HelperWire.Failure.length),
                                  (Data([9, 0, 0, 0, 0]) + id, .kind),
                                  (Data([255, 255, 255, 255, 1]) + id, .limit)] {
            var invalid = HelperWire.Decoder(); invalid.limit = 65_536
            XCTAssertThrowsError(try invalid.feed(header) { _ in }) { XCTAssertEqual($0 as? HelperWire.Failure, failure) }
        }
        var incomplete = HelperWire.Decoder()
        try incomplete.feed(Data(wire.dropLast())) { _ in }
        XCTAssertThrowsError(try incomplete.finish()) { XCTAssertEqual($0 as? HelperWire.Failure, .truncated) }
    }

    func testRemoteHelperCannotRaiseTheFrameLimit() async throws {
        // Before hello, and after a hostile hello advertising the largest representable frame.
        for advertised in [nil, UInt32(HelperWire.maximum)] {
            let incoming = Pipe(), outgoing = Pipe()
            let connection = HelperConnection(read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting)
            defer { connection.close() }
            if let advertised {
                try await connection.configure(limit: advertised, chunkKind: HelperWire.Kind.chunk.rawValue, chunkLimit: 65_536)
            }
            let reply = Task { () -> [String: String] in try await connection.request("echo", params: [String: String]()) }
            // A response header one byte over the helper's own limit, then EOF: the header alone fails
            // the connection with .limit, where an accepted header would end as .truncated.
            var header = Data()
            withUnsafeBytes(of: UInt32(HelperWire.limit + 1 + 9).littleEndian) { header.append(contentsOf: $0) }
            header.append(HelperWire.Kind.response.rawValue)
            withUnsafeBytes(of: UInt64(1).littleEndian) { header.append(contentsOf: $0) }
            try incoming.fileHandleForWriting.write(contentsOf: header)
            try incoming.fileHandleForWriting.close()
            do {
                _ = try await reply.value
                XCTFail("An oversized frame was accepted (advertised \(String(describing: advertised)))")
            } catch {
                XCTAssertEqual(error as? HelperWire.Failure, .limit, "advertised \(String(describing: advertised))")
            }
        }
    }

    func testBootstrapConcurrentUploadsRepairCorruptCacheAndRecoverFromPartialUpload() async throws {
        let fixture = try BootstrapFixture()
        defer { fixture.remove() }
        // Four independent helpers share one cache, as simultaneous SSH logins do.
        let installed = await withTaskGroup(of: (any Error)?.self) { group in
            for _ in 0..<4 { group.addTask { await fixture.bootstrap() } }
            var results: [(any Error)?] = []
            for await value in group { results.append(value) }
            return results
        }
        XCTAssertFalse(installed.contains { BootstrapFixture.installFailed($0) })
        let cached = fixture.cached
        let bytes = try Data(contentsOf: fixture.binary)
        XCTAssertEqual(try Data(contentsOf: cached), bytes)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: cached.deletingLastPathComponent().path).contains { $0.hasPrefix("upload-") })
        let beforeReuse = try fixture.uploadCount()
        let outcome1 = await fixture.bootstrap()
        XCTAssertFalse(BootstrapFixture.installFailed(outcome1))
        XCTAssertEqual(try fixture.uploadCount(), beforeReuse)

        try Data(repeating: 0, count: bytes.count).write(to: cached)
        let outcome2 = await fixture.bootstrap()
        XCTAssertFalse(BootstrapFixture.installFailed(outcome2))
        XCTAssertEqual(try Data(contentsOf: cached), bytes, "Equal-length corrupted bytes must not be executed")
        XCTAssertEqual(try fixture.uploadCount(), beforeReuse + 1)

        try FileManager.default.removeItem(at: cached)
        let partial = fixture.bin.appendingPathComponent("cat")
        try fixture.executable("#!/bin/sh\nprintf partial-upload; exit 1\n", at: partial)
        let outcome3 = await fixture.bootstrap()
        XCTAssertTrue(BootstrapFixture.installFailed(outcome3), "A partial upload must fail")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: cached.deletingLastPathComponent().path).contains { $0.hasPrefix("upload-") })
        try FileManager.default.removeItem(at: partial)
        let outcome4 = await fixture.bootstrap()
        XCTAssertFalse(BootstrapFixture.installFailed(outcome4))
        XCTAssertEqual(try Data(contentsOf: cached), bytes)
    }

    func testBootstrapRequiresChecksumsAndRejectsLinkedCachePaths() async throws {
        let missing = try BootstrapFixture(checksums: false)
        defer { missing.remove() }
        let outcome5 = await missing.bootstrap()
        XCTAssertTrue(BootstrapFixture.installFailed(outcome5), "Unverifiable upload bytes must never become an installed helper")
        XCTAssertEqual(try missing.uploadCount(), 1)
        let fixture = try BootstrapFixture()
        defer { fixture.remove() }
        let outcome6 = await fixture.bootstrap()
        XCTAssertFalse(BootstrapFixture.installFailed(outcome6))
        let cached = fixture.cached
        let directory = cached.deletingLastPathComponent()
        let elsewhere = fixture.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        let sentinel = elsewhere.appendingPathComponent("helper")
        try Data("preserve me".utf8).write(to: sentinel)
        try FileManager.default.removeItem(at: cached)
        try FileManager.default.createSymbolicLink(at: cached, withDestinationURL: elsewhere)
        let outcome7 = await fixture.bootstrap()
        XCTAssertTrue(BootstrapFixture.installFailed(outcome7), "Linked helper destination must fail before upload")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), ["helper"], "mv must not place upload bytes inside a linked directory")
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve me".utf8))

        try FileManager.default.removeItem(at: cached)
        try FileManager.default.createDirectory(at: cached, withIntermediateDirectories: false)
        let outcome8 = await fixture.bootstrap()
        XCTAssertTrue(BootstrapFixture.installFailed(outcome8), "Directory helper destination must fail before upload")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cached.path), [])

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: elsewhere)
        let outcome9 = await fixture.bootstrap()
        XCTAssertTrue(BootstrapFixture.installFailed(outcome9), "Symlinked cache directory must fail")
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve me".utf8))
    }

    func testBootstrapCancellationAndUnsupportedPlatformLeaveNoLiveChannel() async throws {
        for stage in ["probe", "upload", "connect"] {
            let fixture = try BootstrapFixture(paused: stage)
            defer { fixture.remove() }
            let task = Task { _ = try await SSHBootstrap.startHelper4(master: fixture.master, resources: fixture.resources, sessionID: BootstrapFixture.session, publish: false) }
            try await TestSupport.eventually { FileManager.default.fileExists(atPath: fixture.marker.path) }
            let pid = try XCTUnwrap(Int32(String(contentsOf: fixture.marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            let start = ContinuousClock.now
            task.cancel()
            do { _ = try await task.value; XCTFail("Cancelled bootstrap must not publish a connection") } catch {}
            XCTAssertLessThan(start.duration(to: .now), .seconds(3))
            try await TestSupport.eventually { kill(pid, 0) != 0 && errno == ESRCH }
        }
        let fixture = try BootstrapFixture(paused: "unsupported")
        defer { fixture.remove() }
        let unsupported = await fixture.bootstrap()
        XCTAssertTrue(unsupported?.localizedDescription.contains("requires Linux or macOS") == true, "Unsupported platforms must fail enhancement")
        XCTAssertEqual(try fixture.uploadCount(), 0)
    }

    // The old exec-stream cases (ledger S-8, S-41, S-62, S-217, S-442, S-456, S-601) on helper4's own streams
    // over a real SSH login: one large, cancelled or stalled stream never blocks or poisons the other requests
    // on the connection, and bytes and exit status arrive exactly.
    private struct Read: Encodable { let path: String; let offset: UInt64; let length: UInt64 }
    private struct Metadata: Decodable { let size: UInt64 }
    private struct Echo: Codable, Equatable, Sendable { let value: String }

    private func remote(_ body: (TmuxWalkthrough, SSHTestServer, HelperConnection) async throws -> Void) async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let link = try await app.login(server, surface: XCTUnwrap(app.workspace.activeSurfaceID))
        try await TestSupport.eventually(timeout: .seconds(20)) { app.runtime.ssh.helper4(for: link.launch.tabID) != nil }
        try await body(app, server, try await HelperApp.shared.connection(.remote(link.launch.connectionID)))
    }

    private func pattern(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

    // c1654cc used a persistent "wait" stream. Large files can finish before cancellation,
    // and files.read rejects FIFOs; observe the live login terminal to keep a request pending.
    private func observe(_ connection: HelperConnection) async throws -> (UInt64, AsyncStream<Bool>) {
        let info: HelperSession.Info = try await connection.request("hello", params: [String: String]())
        let terminal = try XCTUnwrap(info.terminal)
        let (ends, end) = AsyncStream<Bool>.makeStream()
        let id = try await connection.subscribe("terminals.observe", params: ["terminal": terminal],
            notify: { _, _ in }, ended: { result in
                if case .failure(let error) = result {
                    if !(error is CancellationError) { print("SSH pending stream failed before cancellation: \(error)") }
                    end.yield(error is CancellationError)
                } else {
                    print("SSH pending stream completed before cancellation")
                    end.yield(false)
                }
                end.finish()
            })
        return (id, ends)
    }

    /// S-8, S-601: a large read streams while independent requests on the same connection keep answering.
    func testLargeRemoteReadDoesNotBlockIndependentRequests() async throws {
        try await remote { _, server, connection in
            let bytes = pattern(8 << 20), file = server.root.appendingPathComponent("large.bin")
            try bytes.write(to: file)
            async let large: (result: Metadata, bytes: Data) = connection.requestBinary(
                "files.read", params: Read(path: file.path, offset: 0, length: UInt64(bytes.count)))
            var echoes: [Echo] = []
            for index in 0..<20 { echoes.append(try await connection.request("echo", params: Echo(value: "independent \(index)"))) }
            XCTAssertEqual(echoes, (0..<20).map { Echo(value: "independent \($0)") })
            let read = try await large
            XCTAssertEqual(read.result.size, UInt64(bytes.count))
            XCTAssertEqual(read.bytes, bytes, "Every byte of the large read arrives exactly")
        }
    }

    /// S-41, S-217: cancelling one large read ends only that stream; a concurrent read completes exactly and the
    /// connection keeps answering.
    func testCancelledRemoteReadLeavesOtherStreamsAndTheConnectionUsable() async throws {
        try await remote { _, server, connection in
            let bytes = pattern(32 << 20), file = server.root.appendingPathComponent("cancelled.bin")
            try bytes.write(to: file)
            let (id, ends) = try await observe(connection)
            async let other: (result: Metadata, bytes: Data) = connection.requestBinary(
                "files.read", params: Read(path: file.path, offset: 0, length: 1 << 20))
            connection.cancel(id)
            var iterator = ends.makeAsyncIterator()
            let cancelled = await iterator.next()
            XCTAssertEqual(cancelled, true, "The cancelled read ends as cancelled, not with data")
            let read = try await other
            XCTAssertEqual(read.bytes, bytes.prefix(1 << 20), "The concurrent read is exact")
            let echo: Echo = try await connection.request("echo", params: Echo(value: "after cancel"))
            XCTAssertEqual(echo, Echo(value: "after cancel"))
        }
    }

    /// S-442: a persistent request is abandoned while the terminal is still alive;
    /// the other requests and a later read keep working.
    func testStalledRemoteRequestDoesNotPoisonTheConnection() async throws {
        try await remote { _, server, connection in
            let (id, ends) = try await observe(connection)
            let echo: Echo = try await connection.request("echo", params: Echo(value: "while stalled"))
            XCTAssertEqual(echo, Echo(value: "while stalled"), "A stalled read never blocks the connection")
            connection.cancel(id)
            var iterator = ends.makeAsyncIterator()
            let cancelled = await iterator.next()
            XCTAssertEqual(cancelled, true, "The stalled request must remain pending until cancellation")
            let bytes = pattern(4096), file = server.root.appendingPathComponent("after.bin")
            try bytes.write(to: file)
            let read: (result: Metadata, bytes: Data) = try await connection.requestBinary(
                "files.read", params: Read(path: file.path, offset: 0, length: 4096))
            XCTAssertEqual(read.bytes, bytes)
        }
    }

    /// S-62, S-456: a remote command that finishes while its input is still open keeps its exact output and
    /// exit status.
    func testRemoteCommandExitKeepsOutputAndStatusWhileInputIsOpen() async throws {
        try await remote { app, _, _ in
            let terminal = try XCTUnwrap(app.runtime.views[XCTUnwrap(app.workspace.activeSurfaceID)])
            TerminalTestSupport.send("sh -c 'printf \"OUTPUT_%s\\n\" BEFORE_EXIT; exit 23'; printf 'STATUS_%s\\n' \"$?\"", to: terminal)
            try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("STATUS_23") }
            XCTAssertTrue(TerminalTestSupport.screen(terminal: terminal).contains("OUTPUT_BEFORE_EXIT"))
        }
    }

    /// SSHHookSetupTests on the helper route: rapid integration toggles end in the last choice on this Mac and on
    /// the SSH host's helper (an older toggle never overtakes a newer one).
    func testRapidIntegrationTogglesEndInTheLastChoiceOverSSH() async throws {
        try await remote { app, _, _ in
            let chat = app.runtime.chat
            let link = try XCTUnwrap(app.runtime.ssh.links.values.first)
            func status(_ endpoint: HelperWorkspace.Endpoint) async throws -> String? {
                try await HelperChat.setup(endpoint, key: "codex", enabled: nil, terminal: nil)?.status
            }
            defer { chat.setHelperIntegration("codex", enabled: true) }
            for (index, last) in [false, true].enumerated() {
                for enabled in [true, false, true, false, true, false, true] + [last] { chat.setHelperIntegration("codex", enabled: enabled) }
                await chat.integrationChanges?.value
                for endpoint in [HelperWorkspace.Endpoint.local, .remote(link.launch.connectionID)] {
                    let current = try await status(endpoint)
                    XCTAssertEqual(current == "off", !last, "round \(index): \(endpoint) ends in the last choice")
                }
            }
        }
    }

    /// The remote half of hook setup (old ssh-hooks-rust managed install): installing over SSH merges into the
    /// SSH account's hooks.json, keeping the user's handlers and keys; a second install changes nothing.
    func testRemoteHookSetupKeepsTheUsersHandlers() async throws {
        try await remote { app, server, _ in
            let link = try XCTUnwrap(app.runtime.ssh.links.values.first)
            let endpoint = HelperWorkspace.Endpoint.remote(link.launch.connectionID)
            let hooks = server.agents.appendingPathComponent("codex/hooks.json")
            try Data(#"{"description":"Mine","future":true,"hooks":{"Stop":[{"matcher":".*","hooks":[{"type":"command","command":"echo mine","timeout":7}]}]}}"#.utf8)
                .write(to: hooks)
            _ = try await HelperChat.setup(endpoint, key: "codex", enabled: true, terminal: nil)
            let first = try Data(contentsOf: hooks)
            _ = try await HelperChat.setup(endpoint, key: "codex", enabled: true, terminal: nil)
            XCTAssertEqual(try Data(contentsOf: hooks), first, "A second install changes nothing")
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
            XCTAssertEqual(root["description"] as? String, "Mine")
            XCTAssertEqual(root["future"] as? Bool, true)
            let stop = try XCTUnwrap((root["hooks"] as? [String: [[String: Any]]])?["Stop"]?.flatMap { $0["hooks"] as? [[String: Any]] ?? [] })
            XCTAssertEqual(stop.filter { $0["command"] as? String == "echo mine" }.map { $0["timeout"] as? Int }, [7])
            XCTAssertTrue(String(decoding: first, as: UTF8.self).contains("dispatch-helper4"), "The helper's own handler is installed")
        }
    }

    func testGreetingCancellationAndLateCallbacksStayWithTheirConnection() async throws {
        // helper4's hello: a cancelled handshake ends its own helper process, so a hello it would send later
        // reaches nothing; truncated replies and malformed reported identities fail.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("greeting-barriers-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try XCTUnwrap(HelperApp.executable)
        func shell(_ script: String) -> Process {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", script]
            return process
        }
        let barrier = try ShellFixtureBarrier(in: root)
        defer { try? barrier.release() }
        let old = shell(barrier.command + " && exec " + HerdrLaunch.quote(helper.path) + " --stdio")
        let abandoned = Task { try await HelperSession(process: old) }
        try await barrier.ready()
        abandoned.cancel()
        do { _ = try await abandoned.value; XCTFail("A cancelled handshake must fail") } catch {}
        try barrier.release()
        try await TestSupport.eventually(timeout: .seconds(3)) { !old.isRunning }
        let fresh = Process(); fresh.executableURL = helper; fresh.arguments = ["--stdio"]
        let live = try await HelperSession(process: fresh)
        defer { live.close() }
        XCTAssertEqual(live.info.version, HelperBinary.version)
        let launches = try await HelperClient(live.connection).launches()
        XCTAssertFalse(launches.isEmpty, "A fresh session answers after the old one was abandoned")

        do { _ = try await HelperSession(process: shell(printBytes(Data([0, 0, 0, 12, 74])))); XCTFail("Truncated greeting must fail") } catch {}

        let valid = SSHGreeting(version: 4, host: "fixture", boot: "boot", uid: getuid(), home: "/tmp", capabilities: ["stats.sample"])
        XCTAssertNoThrow(try valid.validate())
        let incompatible = [
            SSHGreeting(version: valid.version, host: "", boot: "boot", uid: getuid(), home: "/tmp", capabilities: []),
            SSHGreeting(version: valid.version, host: "fixture", boot: "", uid: getuid(), home: "/tmp", capabilities: []),
            SSHGreeting(version: valid.version, host: "fixture", boot: "boot", uid: getuid(), home: "relative", capabilities: []),
            SSHGreeting(version: valid.version, host: "fixture\n", boot: "boot", uid: getuid(), home: "/tmp", capabilities: []),
            SSHGreeting(version: valid.version, host: "fixture", boot: "boot", uid: getuid(), home: "/tmp", capabilities: ["exec", "exec"]),
        ]
        for greeting in incompatible { XCTAssertThrowsError(try greeting.validate(), "Incompatible greeting must fail") }
    }

    private func printBytes(_ bytes: Data) -> String {
        "printf '" + bytes.map { String(format: "\\%03o", $0) }.joined() + "'"
    }
}

/// Runs the actual bootstrap shell commands against a disposable local HOME.
/// Real authenticated-master behavior is covered separately by SSHTestServer;
/// this fixture controls upload failures without damaging that server's cache.
private struct BootstrapFixture: Sendable {
    let root: URL
    let home: URL
    let bin: URL
    let resources: URL
    let master: SSHMaster
    let marker: URL

    init(checksums: Bool = true, paused: String = "") throws {
        root = URL(fileURLWithPath: "/tmp/hb-\(UUID().uuidString.prefix(8))")
        home = root.appendingPathComponent("home"); bin = root.appendingPathComponent("bin")
        resources = try SSHHelperTestResources.prepare(under: root)
        marker = root.appendingPathComponent("paused")
        let executable = root.appendingPathComponent("ssh")
        master = SSHMaster(executable: executable.path, controlPath: root.appendingPathComponent("master").path, destination: "fixture.invalid")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
        if !checksums {
            for command in ["uname", "id", "stat", "cut", "wc", "tr", "mkdir", "rmdir", "chmod", "mv", "rm", "cat"] {
                let path = ["/usr/bin/", "/bin/"].map { $0 + command }.first { FileManager.default.isExecutableFile(atPath: $0) }!
                try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent(command).path, withDestinationPath: path)
            }
        }
        let script = """
        #!/bin/sh
        export HOME=\(HerdrLaunch.quote(home.path))
        export PATH=\(HerdrLaunch.quote(bin.path + (checksums ? ":/usr/bin:/bin" : "")))
        for argument do command=$argument; done
        case "$command" in
          *DISPATCH_PLATFORM*) stage=probe ;;
          *'cat >'*) stage=upload; printf 'upload\\n' >> \(HerdrLaunch.quote(root.appendingPathComponent("uploads").path)) ;;
          *' connect --session'*) stage=connect ;;
          *) stage=check ;;
        esac
        if test \(HerdrLaunch.quote(paused)) = unsupported && test "$stage" = probe; then printf 'DISPATCH_PLATFORM=Unknown:mips\\n'; exit; fi
        if test "$stage" = \(HerdrLaunch.quote(paused)); then printf '%s\\n' "$$" > \(HerdrLaunch.quote(marker.path)); exec /bin/sleep 30; fi
        exec /bin/sh -c "$command"
        """
        try self.executable(script, at: executable)
    }
    func executable(_ script: String, at url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    static let session = String(repeating: "a", count: 24)
    /// The bundle's binary for this Mac and where the bootstrap caches it in the fixture HOME.
    var binary: URL { resources.appendingPathComponent("helper4/darwin-universal") }
    var cached: URL {
        let digest = SHA256.hash(data: (try? Data(contentsOf: binary)) ?? Data()).map { String(format: "%02x", $0) }.joined()
        return home.appendingPathComponent(".dispatch/bin/" + digest + "/dsptch")
    }
    /// One bootstrap: install, then `connect`, which finds no login here and fails; the error tells an
    /// install failure from that expected end.
    func bootstrap() async -> (any Error)? {
        do { _ = try await SSHBootstrap.startHelper4(master: master, resources: resources, sessionID: Self.session, publish: false); return nil }
        catch { return error }
    }
    static func installFailed(_ error: (any Error)?) -> Bool { error?.localizedDescription.contains("install") == true }

    func uploadCount() throws -> Int {
        let path = root.appendingPathComponent("uploads")
        guard FileManager.default.fileExists(atPath: path.path) else { return 0 }
        return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").count
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
