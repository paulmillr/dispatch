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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-bootstrap-policy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func run(_ script: String, home: URL) async throws -> SSHCommand.Result {
        try await SSHCommand.run(executable: "/bin/sh", arguments: ["-c", "HOME=" + HerdrLaunch.quote(home.path) + "; export HOME; " + script], timeout: 5)
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
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("helper4"), withIntermediateDirectories: true)
        do { _ = try await SSHBootstrap.startHelper4(master: master, resources: resources, sessionID: session, publish: true); XCTFail("An unmarked bundle must refuse") }
        catch { }
        try "2\n".write(to: resources.appendingPathComponent("helper4/protocol-version"), atomically: true, encoding: .utf8)
        do { _ = try await SSHBootstrap.startHelper4(master: master, resources: resources, sessionID: session, publish: true); XCTFail("Another protocol's bundle must refuse") }
        catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
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
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
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
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("count"), encoding: .utf8), "x")
    }

    func testStartedHelperFailureNeverReplaysCommandAndPublicSessionHasNoCredential() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let session = "0123456789abcdef01234567", count = root.appendingPathComponent("count")
        let helper = Data(("#!/bin/sh\nprintf '%s\\n' \"$@\"\nprintf x >> " + HerdrLaunch.quote(count.path) + "\nexit 31\n").utf8)
        let digest = SHA256.hash(data: helper).map { String(format: "%02x", $0) }.joined()
        let prepared = try await run(SSHBootstrap.cachePreamble(digest: digest), home: root)
        XCTAssertEqual(prepared.status, 0)
        let relative = ".dispatch/bin/" + digest + "/dsptch", path = root.appendingPathComponent(relative)
        try helper.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        let published = try await run(SSHBootstrap.publish(sessionID: session, relativePath: relative), home: root)
        XCTAssertEqual(published.status, 0)
        let command = "printf replay >> " + HerdrLaunch.quote(count.path)
        let script = SSHLauncherCommand.remoteCommand(sessionID: session, grant: .init(profile: .full), command: command)
        let result = try await run(script, home: root)
        XCTAssertEqual(result.status, 31)
        XCTAssertEqual(try String(contentsOf: count, encoding: .utf8), "x")
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self).split(separator: "\n").map(String.init), ["login", "full", "--session", session, command])
        XCTAssertFalse(script.contains("DISPATCH_SSH_TOKEN"))
        XCTAssertFalse(script.contains("/tmp/dispatch-ssh-"))
    }

    func testUnverifiedBinaryAndPlantedReadyLinkAreNeverExecuted() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let digest = String(repeating: "b", count: 64), session = "0123456789abcdef01234567"
        let prepared = try await run(SSHBootstrap.cachePreamble(digest: digest), home: root)
        XCTAssertEqual(prepared.status, 0)
        let relative = ".dispatch/bin/" + digest + "/dsptch"
        let helper = root.appendingPathComponent(relative)
        try "#!/bin/sh\nexit 88\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let published = try await run(SSHBootstrap.publish(sessionID: session, relativePath: relative), home: root)
        XCTAssertEqual(published.status, 0)
        let script = SSHLauncherCommand.remoteCommand(sessionID: session, grant: .init(profile: .statistics), command: "exit 24")
        let mismatch = try await run(script, home: root)
        XCTAssertEqual(mismatch.status, 24)
        let second = try await run(SSHBootstrap.publish(sessionID: session, relativePath: relative), home: root)
        XCTAssertEqual(second.status, 0)
        let ready = root.appendingPathComponent(".dispatch/launches/" + session + "/ready")
        let target = root.appendingPathComponent("target")
        try (relative + "\n").write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: ready)
        try FileManager.default.createSymbolicLink(at: ready, withDestinationURL: target)
        let linked = try await run(script, home: root)
        XCTAssertEqual(linked.status, 24)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), relative + "\n")
    }
}
