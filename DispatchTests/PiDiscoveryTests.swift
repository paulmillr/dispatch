import Foundation
import XCTest
@testable import DispatchApp

@MainActor
final class PiDiscoveryTests: XCTestCase {
    func testPiSetupHomeTreatsEmptyEnvironmentAsDefault() async throws {
        let base = System.temporary.path
        let root = System.resolve(URL(fileURLWithPath: base).appendingPathComponent("pi-" + System.uuid().uuidString))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, value) in [nil, "", "~/private-pi", "~"].enumerated() {
            let home = root.appendingPathComponent(String(index))
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let expected = home.appendingPathComponent(value == "~" ? "" : value == "~/private-pi" ? "private-pi" : ".pi/agent")
            let process = Process()
            process.executableURL = try XCTUnwrap(HelperApp.executable)
            process.arguments = ["--stdio"]
            var environment = System.inherited
            environment["HOME"] = home.path
            environment["DISPATCH_TEST_ROOT"] = base
            environment["PI_CODING_AGENT_DIR"] = value
            process.environment = environment; process.currentDirectoryURL = home
            let session = try await HelperSession(process: process)
            defer { session.close() }
            let client = HelperClient(session.connection)
            let launches = try await client.launches()
            let launch = try XCTUnwrap(launches.first { $0.key == "pi" })
            let installed: HelperChat.Installation = try await session.connection.request("installation.install",
                params: HelperChat.Setup(launch: launch.launch, enabled: true, terminal: nil))
            let script = expected.appendingPathComponent("extensions/dispatch-chat.js")
            XCTAssertEqual(installed.edits.filter { $0.path.hasSuffix("extensions/dispatch-chat.js") }.map(\.path), [script.path])
            XCTAssertTrue(System.exists(script))
            let _: HelperChat.Installation = try await session.connection.request("installation.install",
                params: HelperChat.Setup(launch: launch.launch, enabled: false, terminal: nil))
            XCTAssertFalse(System.exists(script))
            session.close()
            for await status in session.exited { XCTAssertEqual(status, 0); break }
        }
    }
}
