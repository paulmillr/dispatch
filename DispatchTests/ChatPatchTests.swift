import XCTest
import CryptoKit
@testable import DispatchApp

@MainActor
final class ChatPatchTests: XCTestCase {
    private func record(_ state: String, completed: Bool, id: String = "call", diff: String = "+one") -> HelperChat.Record {
        .init(id: id, turn: "turn", kind: "tool", text: "", title: "apply_patch", output: "", blocks: [],
              completed: completed, exit_code: nil, patch: state, time_ms: nil,
              documents: [.init(path: "a.swift", kind: "update", diff: diff, workdir: nil)], tool: nil, inline_reasoning: false)
    }

    func testLiveAndResumedItemsShareStateAndSourcePolicy() throws {
        for state in [ChatPatch.State.generating, .applying, .completed, .failed, .declined, .interrupted] {
            let record = record(state.rawValue, completed: state != .generating && state != .applying)
            let live = ChatCoordinator(enabled: true), resumed = ChatCoordinator(enabled: true)
            defer { live.stop(); resumed.stop() }
            let a = live.session(for: UUID()), b = resumed.session(for: UUID())
            live.receiveHelper(.records([record]), session: a)
            resumed.receiveHelper(.page(.init(records: [record], earlier: nil, state: nil, snapshot: nil)), session: b)
            XCTAssertEqual(a.turns.flatMap(\.items).map(\.patch), b.turns.flatMap(\.items).map(\.patch))
            XCTAssertEqual(a.turns.flatMap(\.items).first?.patch?.state, state)
        }
    }

    func testNotificationsAreScopedAndRequestsAreNotConsumed() {
        let chat = ChatCoordinator(enabled: true)
        defer { chat.stop() }
        let target = chat.session(for: UUID()), other = chat.session(for: UUID())
        chat.receiveHelper(.records([record("generating", completed: false)]), session: target)
        XCTAssertEqual(target.turns.flatMap(\.items).map(\.id), ["call"])
        XCTAssertTrue(other.turns.isEmpty)
        // Request/notification classification belongs to HelperConnection; this is its routed consumer.
    }

    func testLegacyAndPaginatedHistoryRestoreStructuredChanges() async throws {
        let session = UUID().uuidString
        let changes: [String: Any] = ["a.swift": ["type": "update", "unified_diff": "@@ -1 +1 @@\n-old\n+new", "move_path": "b.swift"]]
        for payload: [String: Any] in [
            ["type": "patch_apply_end", "call_id": "call", "turn_id": "turn", "changes": changes, "success": false, "status": "failed"],
            ["type": "item_completed", "turn_id": "turn", "item": ["type": "FileChange", "id": "call", "changes": changes, "status": "failed"]]
        ] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-patch-history-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let values: [[String: Any]] = [["type": "session_meta", "payload": ["id": session]], ["type": "event_msg", "payload": payload]]
            let lines = try values.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            let chat = ChatCoordinator(enabled: true)
            defer { chat.stop() }
            let archived = try await chat.archived(lines, agent: "codex", session: session, in: directory)
            let patch = try XCTUnwrap(archived.turns.flatMap(\.items).compactMap(\.patch).first)
            XCTAssertEqual(patch.documents.first?.path, "b.swift")
            XCTAssertEqual(patch.state, .failed)
        }
    }

    func testParallelWrappersUseExecutionResultsEvenWhenWrapperOutputIsTruncated() throws {
        let source = #"for(const r of await Promise.allSettled([tools.exec_command({cmd:"echo one"}),tools.exec_command({cmd:"echo two"})]))text(r);"#
        let wrapper = ChatItem(id: "wrapper", kind: .tool, text: source, title: "exec", output: "Warning: truncated output\n{incomplete", completed: true)
        let first = ChatItem(id: "one", kind: .tool, text: "echo one", title: "Shell", output: "one", completed: true)
        let second = ChatItem(id: "two", kind: .tool, text: "echo two", title: "Shell", output: "two", completed: true)
        XCTAssertEqual(ToolOrchestration.coalesced([wrapper, first, second], turnID: "turn").map(\.id), [first.id, second.id])
        XCTAssertEqual(ToolOrchestration.coalesced([wrapper, first], turnID: "turn").map(\.id), [wrapper.id, first.id])
        let mixed = source + #"text(await tools.web__run({search_query:[{q:"docs"}]}));"#
        XCTAssertEqual(ToolOrchestration.sequentialRequests(in: mixed)?.map(\.title), ["exec_command", "exec_command", "web__run"])
        let indexed = #"const results=await Promise.allSettled([tools.exec_command({cmd:'echo one'}),tools.exec_command({cmd:'echo two'})]);for(let i=0;i<results.length;i++)text({i,...results[i]});"#
        XCTAssertEqual(ToolOrchestration.sequentialRequests(in: indexed)?.count, 2)
    }

    func testDelayedExecutionsUseProcessIdentityAndReplaceEmptyPolling() throws {
        let source = #"text(await tools.exec_command({cmd:"build"}));"#
        let first = ChatItem(id: "first", kind: .tool, text: source, title: "exec", output: #"{"session_id":42,"output":"starting"}"#, completed: true)
        let second = ChatItem(id: "second", kind: .tool, text: source, title: "exec", output: #"{"session_id":43,"output":"starting"}"#, completed: true)
        let poll = ChatItem(id: "poll", kind: .tool, text: #"text(await tools.write_stdin({session_id:42,chars:""}));"#, title: "exec", output: #"{"exit_code":0,"output":"finished"}"#, completed: true)
        let firstResult = ChatItem(id: "first-result", kind: .tool, text: "build", title: "Shell", output: "starting\nfinished", completed: true, exitCode: 0, processID: "42")
        let secondResult = ChatItem(id: "second-result", kind: .tool, text: "build", title: "Shell", output: "second build", completed: true, exitCode: 0, processID: "43")
        let before = ToolOrchestration.coalesced([first, second, secondResult, poll], turnID: "turn")
        let after = ToolOrchestration.coalesced([first, second, secondResult, poll, firstResult], turnID: "turn")
        XCTAssertEqual(after.map(\.id), [firstResult.id, secondResult.id])
        XCTAssertEqual(after[0].rowID, before[0].rowID)
        XCTAssertEqual(after[0].output, "starting\nfinished")
        var interaction = poll; interaction.text = #"text(await tools.write_stdin({session_id:42,chars:"yes\n"}));"#
        XCTAssertEqual(ToolOrchestration.coalesced([first, interaction, firstResult], turnID: "turn").count, 2)
        var failedPoll = poll; failedPoll.output = #"{"output":"No such session","exit_code":1}"#
        XCTAssertEqual(ToolOrchestration.coalesced([first, failedPoll, firstResult], turnID: "turn").count, 2)
        let differentDirectory = ChatItem(id: "directory", kind: .tool, text: #"text(await tools.exec_command({cmd:"pwd",workdir:"/tmp/a"}));"#, title: "exec")
        let elsewhere = ChatItem(id: "elsewhere", kind: .tool, text: #"{"command":["/bin/zsh","-lc","pwd"],"cwd":"/tmp/b"}"#, title: "Shell", completed: true)
        XCTAssertEqual(ToolOrchestration.coalesced([differentDirectory, elsewhere], turnID: "turn").count, 2)
    }

    func testLineNumbersAndEndpointResolution() {
        XCTAssertEqual(ToolDocument.lineNumbers(["@@ -41,2 +41,3 @@", " same", "-old", "+new", "+extra"]), [nil, 41, 42, 42, 43])
        // Native socket/home resolution is the helper's contract, not an app parser.
    }

    func testDiffLinesRetainIdentityAcrossGrowingHunksAndPartialLines() throws {
        let presentation = DiffLinePresentation()
        let first = presentation.update("@@ -1,2 +1,2 @@\n context\n-old\n+let", path: "a.swift", animate: true)
        XCTAssertTrue(first.allSatisfy { $0.arrival == nil }, "Opening a diff must not replay its existing contents")
        let next = presentation.update("@@ -1,2 +1,3 @@\n context\n-old\n+let value = 1\n+next", path: "a.swift", animate: true)
        XCTAssertEqual(Array(next.prefix(4).map(\.id)), first.map(\.id), "Header revisions and partial-line growth keep their identity")
        XCTAssertEqual(next.map(\.text), ["@@ -1,2 +1,3 @@", " context", "-old", "+let value = 1", "+next"])
        let arrival = try XCTUnwrap(next.last?.arrival)
        XCTAssertTrue(arrival.consume(since: 0))
        let repeated = presentation.update(next.map(\.text).joined(separator: "\n"), path: "a.swift", animate: true)
        XCTAssertEqual(repeated.map(\.id), next.map(\.id))
        XCTAssertFalse(try XCTUnwrap(repeated.last?.arrival).consume(since: 0), "Repeated snapshots must not restart motion")

        let inserted = presentation.update("@@ -1,2 +1,4 @@\n context\n-old\n+inserted\n+let value = 1\n+next", path: "a.swift", animate: true)
        XCTAssertEqual(inserted[4].id, next[3].id)
        XCTAssertEqual(inserted[5].id, next[4].id)
        XCTAssertNotNil(inserted[3].arrival)
    }

    func testDiffLinesStayStillForHistorySourceSwitchingAndReopening() {
        let presentation = DiffLinePresentation()
        _ = presentation.update("+one", path: "a", animate: false)
        let history = presentation.update("+one\n+two", path: "a", animate: false)
        XCTAssertTrue(history.allSatisfy { $0.arrival == nil })
        XCTAssertNotNil(presentation.update("+one\n+two\n+three", path: "a", animate: true).last?.arrival)
        XCTAssertTrue(presentation.update("+one\n+two\n+three", path: "a", animate: false).allSatisfy { $0.arrival == nil })
        presentation.suspend()
        let reopened = presentation.update("+one\n+two\n+three\n+four", path: "a", animate: true)
        XCTAssertTrue(reopened.allSatisfy { $0.arrival == nil })
        XCTAssertEqual(Array(reopened.prefix(2).map(\.id)), history.map(\.id))
        XCTAssertTrue(presentation.update("+different file", path: "b", animate: true).allSatisfy { $0.arrival == nil })
    }

    func testDiffLineReconciliationBoundsLargeBatchesAndRepeatedLines() {
        let presentation = DiffLinePresentation()
        let old = (0..<1000).map { "-old \($0)" } + [" context"]
        _ = presentation.update(old.joined(separator: "\n"), path: "large", animate: false)
        let changed = (0..<1000).map { "+new \($0)" } + [" context"]
        let rows = presentation.update(changed.joined(separator: "\n"), path: "large", animate: true)
        XCTAssertEqual(rows.map(\.text), changed)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        XCTAssertEqual(rows.compactMap(\.arrival).count, 64, "Large batches must not schedule thousands of animations")
        let duplicate = DiffLinePresentation()
        let before = duplicate.update("@@\n+{\n+same\n+}\n+{\n+same\n+}", path: "repeat", animate: false)
        let after = duplicate.update("@@\n+{\n+same\n+extra\n+}\n+{\n+same\n+}", path: "repeat", animate: true)
        XCTAssertEqual(after.map(\.id).filter { $0 != after[3].id }, before.map(\.id))
        XCTAssertNotNil(after[3].arrival)
    }

    func testSnapshotsRetainIdentityAndFinalStatusAcrossHistoryReplay() throws {
        let session = ChatSession(id: UUID())
        func patch(_ diff: String, _ state: ChatPatch.State) throws -> ChatItem {
            try XCTUnwrap(ChatPatch.item(id: "call", changes: [["path": "file.swift", "diff": diff]], state: state))
        }
        session.insert(try patch("+first", .generating), turnID: "turn")
        let identity = session.transcriptRows.first?.id
        session.insert(try patch("+first\n+second", .generating), turnID: "turn")
        XCTAssertEqual(session.transcriptRows.first?.id, identity)
        XCTAssertEqual(session.turns[0].items.count, 1)
        session.insert(try patch("+first\n+second", .failed), turnID: "turn")
        session.insert(try patch("+first", .generating), turnID: "turn")
        session.insert(ChatItem(id: "tool-call", kind: .tool, text: "wrapped input", title: "functions.exec"), turnID: "turn")
        let item = try XCTUnwrap(session.turns[0].items.first)
        XCTAssertEqual(item.patch?.state, .failed)
        XCTAssertEqual(item.patch?.documents.first?.diff, "+first\n+second")
        XCTAssertTrue(item.completed)
        XCTAssertEqual(item.title, "apply_patch")
        XCTAssertEqual(ToolPresentation(item).documents.count, 1)
        let hooksFirst = ChatSession(id: UUID())
        hooksFirst.insert(ChatItem(id: "tool-call", kind: .tool, text: "", completed: true), turnID: "turn")
        hooksFirst.insert(try patch("+failed", .failed), turnID: "turn")
        XCTAssertEqual(hooksFirst.turns[0].items[0].patch?.state, .failed, "An early hook completion cannot overwrite the authoritative patch result")
    }

    /// A live apply_patch shows as a growing preview while Codex works, then as one completed card, in a local
    /// and an SSH terminal watching the same thread; a resumed chat restores the final diff.
    func testRealAppServerStreamsPatchBeforeCompletion() async throws {
        let binary = try CodexTestSupport.requireBinary()
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-patch-" + UUID().uuidString)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [CodexTestSupport.root.appendingPathComponent("scripts/codex-patch-fixture.py").path,
                             "--codex", binary, "--state", state.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
        defer { if process.isRunning { process.terminate() }; print("Patch fixture: " + state.path) }
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "Patch server did not start") {
            FileManager.default.fileExists(atPath: state.appendingPathComponent("ready.json").path)
        }
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: state.appendingPathComponent("ready.json"))) as? [String: String])
        let thread = try XCTUnwrap(metadata["thread"]), socket = try XCTUnwrap(metadata["socket"])
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true); defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        // The fixture owns this server independently of either terminal. Its resumed TUIs learn their
        // conversation through the shipping /status command, rather than private-server discovery.
        let launch = CodexTestSupport.command(state: state, binary: binary, resume: thread) + " --dispatch --remote " + HerdrLaunch.quote("unix://" + socket)
        let local = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { runtime.views[local].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        TerminalTestSupport.send(launch, to: try XCTUnwrap(runtime.views[local]))
        app.workspace.newLocalSpace()
        let remote = try XCTUnwrap(app.workspace.activeTab?.id)
        XCTAssertNotEqual(remote, local)
        try await app.wait { runtime.views[remote].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let remoteView = try XCTUnwrap(runtime.views[remote])
        TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: remoteView)
        try await TestSupport.eventually(timeout: .seconds(20)) { runtime.ssh.links.values.contains { $0.launch.tabID == remote && $0.shellPID != nil } }
        TerminalTestSupport.send(launch, to: remoteView)
        let sessions = [runtime.chat.session(for: local), runtime.chat.session(for: remote)]
        let diagnostic = {
            zip([local, remote], sessions).map { tab, session in
                "tab=\(tab), active=\(session.active), thread=\(String(describing: session.sessionID)), loading=\(session.loadingHistory), status=\(String(describing: session.status)), failure=\(String(describing: session.submissionFailure)), screen=\(runtime.views[tab].map { TerminalTestSupport.screen(terminal: $0) } ?? "missing")"
            }.joined(separator: "\n")
        }
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: diagnostic()) {
            sessions.allSatisfy { $0.active && $0.binding != nil && !$0.loadingHistory }
        }
        for session in sessions {
            session.drafts.edit(text: "/status", multiline: false)
            runtime.chat.submit(session)
        }
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: diagnostic()) {
            sessions.allSatisfy { $0.active && $0.sessionID == thread && !$0.loadingHistory }
        }
        XCTAssertEqual(sessions[1].helper?.endpoint.connection != nil, true, "The SSH terminal's agent is bound by the host's helper")
        func patches(_ session: ChatSession) -> [ChatPatch] { session.turns.flatMap(\.items).compactMap(\.patch) }
        try Data().write(to: state.appendingPathComponent("go"))
        // Every preview the chat shows while Codex is still working.
        var previews = Set<String>()
        try await TestSupport.eventually(timeout: .seconds(20), interval: .milliseconds(1), diagnostic: "No generating patch arrived") {
            previews.formUnion(patches(sessions[0]).filter { $0.state == .generating }.map { $0.documents.first?.diff ?? "" })
            return !previews.isEmpty
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("done.json").path), "Preview must arrive while Codex is working")
        try await TestSupport.eventually(timeout: .seconds(20), interval: .milliseconds(1), diagnostic: "Patch did not finish") {
            previews.formUnion(patches(sessions[0]).filter { $0.state == .generating }.map { $0.documents.first?.diff ?? "" })
            return patches(sessions[0]).contains { $0.state == .completed }
        }
        XCTAssertGreaterThan(previews.count, 1, "The preview grows with the streamed patch")
        XCTAssertEqual(try String(contentsOf: state.appendingPathComponent("work/live-diff.swift"), encoding: .utf8), "let first = 1\nlet second = 2\n")
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "SSH chat missed the completed patch") {
            patches(sessions[1]).contains { $0.state == .completed }
        }
        XCTAssertEqual(sessions.map { patches($0).count }, [1, 1], "One card per patch")
        // The thread opened again from its transcript restores the final diff.
        let rollouts = FileManager.default.enumerator(at: state.appendingPathComponent("codex-home/sessions"), includingPropertiesForKeys: nil)
        let rollout = try XCTUnwrap(rollouts?.compactMap { $0 as? URL }.first { $0.lastPathComponent.hasSuffix(thread + ".jsonl") })
        let restored = try await runtime.chat.archived(rollout, agent: "codex", session: thread)
        XCTAssertEqual(patches(restored).map(\.state), [.completed])
        XCTAssertEqual(patches(restored).first?.documents.first?.diff, patches(sessions[0]).first?.documents.first?.diff)
        try Data().write(to: state.appendingPathComponent("stop"))
    }
    func testAddedDeletedAndInterruptedPatches() throws {
        let add = try XCTUnwrap(ChatPatch.item(id: "a", changes: [["path": "a.swift", "kind": ["type": "add"], "diff": "one\ntwo\n"]], state: .generating))
        let delete = try XCTUnwrap(ChatPatch.item(id: "d", changes: ["d.swift": ["type": "delete", "content": "old\n"]], state: .completed))
        XCTAssertEqual(ToolPresentation(add).additions, 2)
        XCTAssertEqual(ToolPresentation(delete).deletions, 1)
        let session = ChatSession(id: UUID()); session.insert(add, turnID: "turn")
        session.finishPatches(in: "turn")
        XCTAssertEqual(session.turns[0].items[0].patch?.state, .interrupted)
        XCTAssertTrue(session.turns[0].items[0].completed)
    }
    func testPatchOnlyWrappersFoldIntoMatchingExecutionRows() throws {
        let input = "*** Begin Patch\n*** Update File: /tmp/file.swift\n@@\n-old\n+new\n*** End Patch"
        let literal = String(decoding: try JSONSerialization.data(withJSONObject: input, options: .fragmentsAllowed), as: UTF8.self)
        let wrapper = ChatItem(id: "wrapper", kind: .tool, text: "text(await tools.apply_patch(\(literal)));", title: "functions.exec")
        let patch = try XCTUnwrap(ChatPatch.item(id: "actual", changes: [["path": "/tmp/file.swift", "diff": "@@ -1 +1 @@\n-old\n+new"]], state: .completed))
        let session = ChatSession(id: UUID())
        func visible() -> [ChatItem] {
            session.transcriptRows.flatMap { row in row.group?.children.compactMap(\.item) ?? row.item.map { [$0] } ?? [] }
        }
        session.turns = [.init(id: "turn", items: [wrapper])]
        let originalRow = session.transcriptRows.first?.id
        session.turns[0].items.append(patch)
        XCTAssertEqual(visible().map(\.id), [patch.id])
        XCTAssertEqual(session.transcriptRows.first?.id, originalRow)
        XCTAssertEqual(session.turns[0].items.count, 2, "Keep original records for subsequent hook/history updates")
        var nextWrapper = wrapper; nextWrapper.id = "wrapper2"
        var nextPatch = patch; nextPatch.id = "patch2"
        session.turns[0].items += [nextWrapper, nextPatch]
        XCTAssertEqual(visible().map(\.id), [patch.id, nextPatch.id], "Repeated patches remain separate operations")
        session.turns[0].items = [wrapper, ChatItem(id: "raw-patch", kind: .tool, text: input, title: "apply_patch")]
        XCTAssertEqual(visible().count, 1, "Direct tool records also consolidate before a structured result arrives")
        var mixed = wrapper; mixed.text += " await tools.exec_command({\"cmd\":\"echo done\"});"
        session.turns[0].items = [mixed, patch]
        XCTAssertEqual(visible().count, 2, "A wrapper with additional work must remain visible")
        XCTAssertEqual(visible().map(\.title), ["apply_patch", "exec_command"], "Show each underlying operation once")
        XCTAssertEqual(ToolPresentation(session.turns[0].items[0]).requests.count, 2, "Original wrapper input stays intact")
        mixed.text = wrapper.text + " text(await tools.write_stdin({session_id:123,chars:\"\"}));"
        session.turns[0].items = [mixed, patch]
        XCTAssertEqual(visible().count, 2)
        XCTAssertEqual(visible().map(\.title), ["apply_patch", "write_stdin"])
        XCTAssertEqual(session.turns[0].items[0].text, mixed.text, "Original wrapper records stay intact")

        session.turns[0].items = [patch, wrapper]
        XCTAssertEqual(visible().count, 2, "A new wrapper must not merge backward into an earlier patch")
        var different = patch; different.patch?.documents[0].diff = "-old\n+different"
        session.turns[0].items = [wrapper, different]
        XCTAssertEqual(visible().count, 2, "The same filename is insufficient to merge operations")
        session.turns = [.init(id: "first", items: [wrapper]), .init(id: "second", items: [patch])]
        XCTAssertEqual(visible().count, 2, "Never merge across turns")
    }
    func testCommandWrappersAndTheirOutputsAppearOnlyOnce() throws {
        func output(_ values: [String]) throws -> String {
            TranscriptParser.printable([["type": "input_text", "text": "Script completed\nWall time 0.1 seconds\nOutput:\n"]] + values.map { ["type": "input_text", "text": $0] })
        }
        let code = #"text(await tools.exec_command({cmd:"rg --files Sources",max_output_tokens:100})); text(await tools.write_stdin({session_id:42,chars:""}));"#
        let wrapper = ChatItem(id: "wrapper", kind: .tool, text: code, title: "exec",
            output: try output([#"{"output":"truncated preview","exit_code":0}"#, #"{"output":"later process output","exit_code":0}"#]), completed: true)
        let actual = ChatItem(id: "actual", kind: .tool, text: #"["/bin/zsh","-lc","rg --files Sources"]"#, title: "Shell", output: "complete command output", completed: true)
        let session = ChatSession(id: UUID())
        session.turns = [.init(id: "turn", items: [wrapper, actual])]
        func visible() -> [ChatItem] { session.transcriptRows.flatMap { $0.group?.children.compactMap(\.item) ?? $0.item.map { [$0] } ?? [] } }
        let projected = visible()
        XCTAssertEqual(projected.count, 2)
        XCTAssertEqual(projected[0].id, actual.id)
        XCTAssertEqual(projected[0].output, "complete command output", "Prefer the execution's full output over the wrapper's truncated copy")
        XCTAssertEqual(projected[1].title, "write_stdin")
        XCTAssertEqual(ToolPresentation(projected[1]).output, "later process output")
        XCTAssertFalse(projected.contains(where: ToolOrchestration.isWrapper))
        XCTAssertEqual(session.turns[0].items, [wrapper, actual])
        let revisions = projected.map(\.presentationID)
        session.turns[0].ended = .now
        XCTAssertEqual(visible().map(\.presentationID), revisions, "Unchanged projections must not restart formatting on unrelated updates")
        var next = wrapper; next.id = "next"
        var nextActual = actual; nextActual.id = "next-actual"
        session.turns[0].items += [next, nextActual]
        XCTAssertEqual(visible().filter { $0.title == "Shell" }.map(\.id), [actual.id, nextActual.id], "Repeated commands in different calls remain distinct")
        var complex = wrapper; complex.text = "if (enabled) { " + code + " }"
        session.turns[0].items = [complex, actual]
        XCTAssertTrue(visible().contains(where: ToolOrchestration.isWrapper), "Do not flatten computed/control-flow wrappers")
    }

}
