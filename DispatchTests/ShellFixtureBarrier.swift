import Foundation
import Darwin
import XCTest
@testable import DispatchApp

/// The real shell publishes readiness and waits on a FIFO, without a race sleep.
@MainActor
final class ShellFixtureBarrier {
    let directory: URL
    private(set) var process: AgentProcess?
    private(set) var parent: AgentProcess?
    private var released = false

    init(in root: URL) throws {
        directory = root.appendingPathComponent("shell-barrier-" + System.uuid().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard mkfifo(directory.appendingPathComponent("release").path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    var command: String {
        ["/usr/bin/python3", CodexTestSupport.root.appendingPathComponent("scripts/shell_fixture_barrier.py").path,
         directory.path].map(HerdrLaunch.quote).joined(separator: " ")
    }

    func ready() async throws {
        let path = directory.appendingPathComponent("ready.json")
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "Shell barrier did not start: " + directory.path) {
            System.exists(path)
        }
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: System.read(path)) as? [String: Int32])
        process = try XCTUnwrap(AgentProcess.capture(XCTUnwrap(record["pid"])))
        parent = try XCTUnwrap(AgentProcess.capture(XCTUnwrap(record["parent"])))
    }

    func release() throws {
        guard !released else { return }
        if let process, !process.alive { released = true; return }
        // Cancellation may close the reader while its process is still exiting.
        // The fixture publishes that outcome before closing, so only that receipt
        // makes a missing reader an expected cancellation instead of a FIFO error.
        func failed(_ code: Int32) throws {
            if code == ENXIO || code == EPIPE,
               let data = try? System.read(directory.appendingPathComponent("completed.json")),
               let record = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               record["outcome"] == "cancelled" { released = true; return }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        // The write reaches the fixture's live shell: a recorded action (replay has no reader); its outcome is errno.
        let code = try System.act("barrier.release", directory.path) { () -> Int32 in
            let fd = open(directory.appendingPathComponent("release").path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return errno }
            defer { Darwin.close(fd) }
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            var byte: UInt8 = 49
            return Darwin.write(fd, &byte, 1) == 1 ? 0 : errno
        }
        guard code == 0 else { return try failed(code) }
        released = true
    }

    func completed() async throws {
        let path = directory.appendingPathComponent("completed.json")
        try await TestSupport.eventually(timeout: .seconds(20)) { System.exists(path) }
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: System.read(path)) as? [String: String])
        XCTAssertEqual(record["outcome"], "released")
    }
}
