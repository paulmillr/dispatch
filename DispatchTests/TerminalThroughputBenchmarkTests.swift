import XCTest

/// scripts/benchmark-terminal-throughput.py measures any terminal from inside it. Its self-test
/// plays the terminal under a pty: every line must arrive whole and in order per stream, and
/// every end check (the cursor column after the sentinel) must pass.
@MainActor
final class TerminalThroughputBenchmarkTests: XCTestCase {
    func testSelfTestSeesEveryLineInOrder() throws {
        let python = Process(), output = Pipe()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = ["-B", CodexTestSupport.root.appendingPathComponent("scripts/benchmark-terminal-throughput.py").path, "--self-test", "--mib", "1"]
        python.standardOutput = output
        try python.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        python.waitUntilExit()
        XCTAssertEqual(python.terminationStatus, 0, text)
        XCTAssertTrue(text.hasSuffix("self-test: ok\n"), text)
    }
}
