import Foundation
import CryptoKit
import XCTest
@testable import DispatchApp

final class SSHBootstrapPolicyTests: XCTestCase {
    func testDeadlineReapsAnAuxiliaryCommandIgnoringTermination() async throws {
        let started = ContinuousClock.now
        do {
            _ = try await SSHCommand.run(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.05)
            XCTFail("The command must time out")
        } catch { }
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    }

    private func temporary() throws -> URL {
        let root = System.temporary.appendingPathComponent("dispatch-bootstrap-policy-" + System.uuid().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func run(_ script: String, home: URL) async throws -> SSHCommand.Result {
        try await SSHCommand.run(executable: "/bin/sh", arguments: ["-c", "HOME=" + HerdrLaunch.quote(home.path) + "; export HOME; " + script], timeout: 5)
    }

    /// Whether two callers send one `-O exit` or two never depends on when the first one finished.
    @MainActor
    func testMasterExitIsSentOnceUnlessItFailed() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let count = root.appendingPathComponent("count"), status = root.appendingPathComponent("status")
        let executable = root.appendingPathComponent("ssh")
        try ("#!/bin/sh\nprintf x >> " + HerdrLaunch.quote(count.path) + "\nexit $(cat " + HerdrLaunch.quote(status.path) + ")\n")
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let master = SSHMaster(executable: executable.path, controlPath: root.appendingPathComponent("control").path, destination: "test")
        func sent() throws -> String { String(decoding: try System.read(count), as: UTF8.self) }
        // The master was not listening yet: callers meanwhile share the failed exit, a later one sends another.
        try "255".write(to: status, atomically: true, encoding: .utf8)
        let first = master.exit(), second = master.exit()
        await first.value; await second.value
        XCTAssertEqual(try sent(), "x")
        try "0".write(to: status, atomically: true, encoding: .utf8)
        await master.exit().value
        XCTAssertEqual(try sent(), "xx")
        await master.exit().value
        XCTAssertEqual(try sent(), "xx", "An ended master is not asked again")
    }

    func testOrdinaryAndUnmarkedBundlesNeverStartAnAuxiliaryCommand() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("invoked")
        let executable = root.appendingPathComponent("ssh")
        try ("#!/bin/sh\nprintf invoked > " + HerdrLaunch.quote(marker.path) + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let master = SSHMaster(executable: executable.path, controlPath: root.appendingPathComponent("control").path, destination: "test")
        let session = String(repeating: "a", count: 24)
        // An unmarked bundle, then one marked for another helper protocol (the old relay's "2").
        let resources = root.appendingPathComponent("ssh-resources")
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("helper"), withIntermediateDirectories: true)
        do { _ = try await SSHBootstrap.startHelper(master: master, resources: resources, sessionID: session, publish: true); XCTFail("An unmarked bundle must refuse") }
        catch { }
        try "2\n".write(to: resources.appendingPathComponent("helper/protocol-version"), atomically: true, encoding: .utf8)
        do { _ = try await SSHBootstrap.startHelper(master: master, resources: resources, sessionID: session, publish: true); XCTFail("Another protocol's bundle must refuse") }
        catch { }
        XCTAssertFalse(System.exists(marker))
    }

    func testPrivateCacheRejectsSymlinksAndUnsafeModesWithoutChangingThem() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let runtime = root.appendingPathComponent(".dispatch")
        try FileManager.default.createSymbolicLink(at: runtime, withDestinationURL: outside)
        let digest = String(repeating: "a", count: 64)
        let linked = try await run(SSHBootstrap.cachePreamble(digest: digest), home: root)
        XCTAssertNotEqual(linked.status, 0)
        XCTAssertEqual(try System.list(outside), [])
        try FileManager.default.removeItem(at: runtime)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let unsafe = try await run(SSHBootstrap.cachePreamble(digest: digest), home: root)
        XCTAssertNotEqual(unsafe.status, 0)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: runtime.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func testFailureRunsOriginalCommandOnceWithExactQuotingAndStatus() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let session = "0123456789abcdef01234567"
        let publish = try await run(SSHBootstrap.publish(sessionID: session, relativePath: nil), home: root)
        XCTAssertEqual(publish.status, 0)
        let script = SSHLauncherCommand.remoteCommand(sessionID: session, grant: .init(profile: .statistics),
            command: "printf '%s\\n' \"quoted 'value' $(printf nested)\"; printf x >> '$HOME/never'; exit 23".replacingOccurrences(of: "'$HOME/never'", with: HerdrLaunch.quote(root.appendingPathComponent("count").path)))
        let result = try await run(script, home: root)
        XCTAssertEqual(result.status, 23)
        XCTAssertTrue(String(decoding: result.output, as: UTF8.self).contains("quoted 'value' nested"))
        XCTAssertEqual(String(decoding: try System.read(root.appendingPathComponent("count")), as: UTF8.self), "x")
    }

    func testStartedHelperFailureNeverReplaysCommandAndPublicSessionHasNoCredential() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let session = "0123456789abcdef01234567", count = root.appendingPathComponent("count")
        let helper = Data(("#!/bin/sh\nprintf '%s\\n' \"$@\"\nprintf x >> " + HerdrLaunch.quote(count.path) + "\nexit 31\n").utf8)
        let digest = SHA256.hash(data: helper).map { String(format: "%02x", $0) }.joined()
        let prepared = try await run(SSHBootstrap.cachePreamble(digest: digest), home: root)
        XCTAssertEqual(prepared.status, 0)
        let relative = ".dispatch/bin/versions/" + digest + "/dispatch-helper", path = root.appendingPathComponent(relative)
        try System.write(helper, to: path, permissions: 0o700)
        let published = try await run(SSHBootstrap.publish(sessionID: session, relativePath: relative), home: root)
        XCTAssertEqual(published.status, 0)
        let command = "printf replay >> " + HerdrLaunch.quote(count.path)
        let script = SSHLauncherCommand.remoteCommand(sessionID: session, grant: .init(profile: .full), command: command)
        let result = try await run(script, home: root)
        XCTAssertEqual(result.status, 31)
        XCTAssertEqual(String(decoding: try System.read(count), as: UTF8.self), "x")
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self).split(separator: "\n").map(String.init), ["login", "full", "--session", session, command])
        XCTAssertFalse(script.contains("DISPATCH_SSH_TOKEN"))
        XCTAssertFalse(script.contains("/tmp/dispatch-ssh-"))
    }

    /// The app publishes the session while the login starts: when the publish's `mkdir` of the session folder wins,
    /// the login's own fails with "File exists". The login checks that folder as one already there and goes on to the
    /// helper, never to the plain shell. A shim plays the winner: it creates the folder and publishes, then fails.
    func testLoginThatLosesTheSessionFolderRaceStillStartsTheHelper() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let session = "0123456789abcdef01234567", other = "76543210fedcba9876543210"
        let helper = Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\nexit 0\n".utf8)
        let digest = SHA256.hash(data: helper).map { String(format: "%02x", $0) }.joined()
        let prepared = try await run(SSHBootstrap.cachePreamble(digest: digest), home: root)
        XCTAssertEqual(prepared.status, 0)
        let relative = ".dispatch/bin/versions/" + digest + "/dispatch-helper"
        try System.write(helper, to: root.appendingPathComponent(relative), permissions: 0o700)
        // `sessions` exists from an earlier connection; this session's folder does not yet.
        let earlier = try await run(SSHBootstrap.publish(sessionID: other, relativePath: nil), home: root)
        XCTAssertEqual(earlier.status, 0)
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
        let publish = HerdrLaunch.quote(SSHBootstrap.publish(sessionID: session, relativePath: relative))
        try System.write(Data("""
        #!/bin/sh
        PATH=/usr/bin:/bin /bin/sh -c \(publish) >/dev/null 2>&1
        echo "mkdir: cannot create directory '$1': File exists" >&2
        exit 1

        """.utf8), to: bin.appendingPathComponent("mkdir"), permissions: 0o700)
        let script = SSHLauncherCommand.remoteCommand(sessionID: session, grant: .init(profile: .statistics), command: nil)
        let result = try await SSHCommand.run(executable: "/bin/sh", arguments: ["-c",
            "HOME=" + HerdrLaunch.quote(root.path) + "; PATH=" + HerdrLaunch.quote(bin.path) + ":/usr/bin:/bin; export HOME PATH; " + script],
            timeout: 10)
        let output = String(decoding: result.output, as: UTF8.self)
        XCTAssertEqual(result.status, 0, output)
        XCTAssertEqual(output.split(separator: "\n").map(String.init).filter { !$0.contains("File exists") },
                       ["login", "statistics", "--session", session], output)
        XCTAssertFalse(output.contains("integration unavailable"), output)
    }

    func testUnverifiedBinaryAndPlantedReadyLinkAreNeverExecuted() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let digest = String(repeating: "b", count: 64), session = "0123456789abcdef01234567"
        let prepared = try await run(SSHBootstrap.cachePreamble(digest: digest), home: root)
        XCTAssertEqual(prepared.status, 0)
        let relative = ".dispatch/bin/versions/" + digest + "/dispatch-helper"
        let helper = root.appendingPathComponent(relative)
        try System.write(Data("#!/bin/sh\nexit 88\n".utf8), to: helper, permissions: 0o700)
        let published = try await run(SSHBootstrap.publish(sessionID: session, relativePath: relative), home: root)
        XCTAssertEqual(published.status, 0)
        let script = SSHLauncherCommand.remoteCommand(sessionID: session, grant: .init(profile: .statistics), command: "exit 24")
        let mismatch = try await run(script, home: root)
        XCTAssertEqual(mismatch.status, 24)
        let second = try await run(SSHBootstrap.publish(sessionID: session, relativePath: relative), home: root)
        XCTAssertEqual(second.status, 0)
        let ready = root.appendingPathComponent(".dispatch/sessions/" + session + "/ready")
        let target = root.appendingPathComponent("target")
        try (relative + "\n").write(to: target, atomically: true, encoding: .utf8)
        // The published ready file belongs to the commands' tree: replacing it is recorded with them.
        _ = try System.act("file.link", [ready.path, target.path]) {
            try FileManager.default.removeItem(at: ready)
            try FileManager.default.createSymbolicLink(at: ready, withDestinationURL: target)
            return true
        }
        let linked = try await run(script, home: root)
        XCTAssertEqual(linked.status, 24)
        XCTAssertEqual(String(decoding: try System.read(target), as: UTF8.self), relative + "\n")
    }
}
