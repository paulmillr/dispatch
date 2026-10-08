import Foundation
import XCTest
@testable import DispatchApp

@MainActor
final class SSHFileConsistencyTests: XCTestCase {
    func testSameInodeMiddleRewriteInvalidatesRemoteHistoryAndLiveGeneration() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let link = try await app.login(server, surface: XCTUnwrap(app.workspace.activeSurfaceID))
        try await TestSupport.eventually(timeout: .seconds(20)) { app.runtime.ssh.helper4(for: link.launch.tabID) != nil }
        let path = server.root.appendingPathComponent("rollout.jsonl"), session = UUID().uuidString
        func line(_ type: String, _ payload: [String: String]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": "2000-01-01T00:00:00Z", "payload": payload], options: .sortedKeys) + Data([10])
        }
        var bytes = try line("session_meta", ["id": session, "cli_version": "0.153.4"])
        for index in 0..<300 {
            bytes += try line("event_msg", ["type": "task_started", "turn_id": "turn-\(index)"])
            bytes += try line("event_msg", ["type": "user_message", "message": "ORIGINAL_\(index)", "turn_id": "turn-\(index)"])
            bytes += try line("event_msg", ["type": "task_complete", "turn_id": "turn-\(index)"])
        }
        try bytes.write(to: path)
        let chat = HelperChat(archive: .init(key: "codex", path: path.path, session: session), endpoint: .remote(link.launch.connectionID))
        let initial = try await chat.page(earlier: nil), cursor = try XCTUnwrap(initial.earlier)
        let before = try FileManager.default.attributesOfItem(atPath: path.path)
        let range = try XCTUnwrap(bytes.range(of: Data("ORIGINAL_280".utf8)))
        XCTAssertGreaterThan(range.lowerBound, 256); XCTAssertLessThan(range.upperBound, bytes.count - 256)
        let file = try FileHandle(forWritingTo: path)
        try file.seek(toOffset: UInt64(range.lowerBound)); try file.write(contentsOf: Data("REPLACED_280".utf8)); try file.close()
        try FileManager.default.setAttributes([.modificationDate: XCTUnwrap(before[.modificationDate])], ofItemAtPath: path.path)
        let after = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual(after[.systemFileNumber] as? UInt64, before[.systemFileNumber] as? UInt64)
        XCTAssertEqual(after[.size] as? UInt64, before[.size] as? UInt64)
        do {
            let stale = try await chat.page(earlier: cursor)
            XCTAssertTrue(stale.records.isEmpty, "A rewritten file cannot answer the old generation")
        } catch let failure as HelperFailure { XCTAssertEqual(failure.code, "history") }
        let fresh = try await chat.page(earlier: nil)
        XCTAssertTrue(fresh.records.contains { $0.text == "REPLACED_280" })
        XCTAssertFalse(fresh.records.contains { $0.text == "ORIGINAL_280" })
    }
    func testConcurrentFileRangesAndPreviewsShareTheBoundedWorker() async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let origin = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { app.runtime.views[origin]?.surface != nil }
        TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "),
                                 to: try XCTUnwrap(app.runtime.views[origin]))
        try await TestSupport.eventually(timeout: .seconds(20)) {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == origin && $0.shellPID != nil }
        }
        let endpoint = HelperWorkspace.Endpoint.remote(try XCTUnwrap(app.runtime.link(of: origin)).launch.connectionID)
        let path = server.root.appendingPathComponent("ssh-concurrent-" + UUID().uuidString + ".txt")
        let contents = String(repeating: "Stable remote content · λ\n", count: 4096)
        try Data(contents.utf8).write(to: path)
        let responses = try await withThrowingTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<24 {
                group.addTask { try await ToolDocument(path: path.path, diff: "").source(in: "/", endpoint: endpoint) }
            }
            var result: [String] = []
            for try await response in group { result.append(response) }
            return result
        }
        XCTAssertEqual(responses, Array(repeating: contents, count: 24), "Concurrent previews through one remote helper must not collide or mix their responses")
    }
}
