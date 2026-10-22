import Foundation
import CryptoKit
import XCTest
@testable import DispatchApp

/// The replay corpus's migrations (test/replay-migrations, docs/replay.md, Migrations) keep up with the code that
/// generates recorded inputs: what the app sends over SSH to set a host up, what it asks git, and the defaults that decide
/// what it lists. Each is fingerprinted here; the last migration naming a fingerprint must name the code's. A change
/// without one would leave every recording that holds the old input failing at replay, found case by case.
final class ReplayMigrationTests: XCTestCase {
    /// The checkout's migrations, read as they are now (live: a recording of this test must not hold an older set).
    private static var directory: URL {
        get throws { try XCTUnwrap(System.checkout, "no test checkout").appendingPathComponent("test/replay-migrations") }
    }

    private static func hash(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The setup scripts as the app sends them for fixed values (SSHBootstrap, SSHLauncherCommand).
    private static var sshSetup: String {
        let digest = String(repeating: "a", count: 64), session = String(repeating: "0", count: 24)
        let relative = SSHBootstrapScript.relativePath(digest: digest)
        return hash([
            SSHBootstrapScript.probe,
            SSHBootstrapScript.cachePreamble(digest: digest) + "\n" + SSHBootstrapScript.verify(size: 1, digest: digest),
            SSHBootstrapScript.upload(digest: digest, size: 1, staging: "upload-0"),
            SSHBootstrap.publish(sessionID: session, relativePath: relative),
            SSHBootstrap.publish(sessionID: session, relativePath: nil, reason: "reason"),
            SSHLauncherCommand.remoteCommand(sessionID: session, grant: .init(profile: .statistics), command: nil),
            SSHLauncherCommand.remoteCommand(sessionID: session, grant: .init(profile: .full), command: "command"),
        ])
    }

    /// Every git request the files data layer makes, for fixed values, as the source receives them.
    private static func gitRequests() async -> String {
        let source = FakeFilesSource.mockupAPI()
        let queries = GitQueries(source: source, root: "/r")
        let hash = String(repeating: "b", count: 40), tip = String(repeating: "c", count: 40)
        let commit = GitCommit(hash: hash, parents: [tip], subject: "s", body: "", author: "a", email: "e", date: .distantPast, refs: [])
        let merge = GitCommit(hash: hash, parents: [tip, hash], subject: "s", body: "", author: "a", email: "e", date: .distantPast, refs: [])
        _ = try? await GitQueries.repository(of: "/r/sub", source: source)
        _ = try? await queries.status()
        _ = try? await queries.numstat(cached: true)
        _ = try? await queries.numstat(cached: false)
        _ = try? await queries.diff(GitChange(path: "a.txt", kind: .modified, area: .staged))
        _ = try? await queries.diff(GitChange(path: "a.txt", kind: .modified, area: .unstaged))
        _ = try? await queries.sizes(GitChange(path: "a.bin", kind: .modified, area: .unstaged, binary: true))
        for scope in [GitLogScope.branch, .all] {
            for match in [GitLogMatch.everything, .message("m"), .author("a")] {
                _ = try? await queries.log(scope: scope, match: match, skip: 200, count: 200, from: tip)
            }
        }
        _ = await queries.verify(hash)
        _ = try? await queries.head()
        _ = try? await queries.refs()
        _ = try? await queries.commit(hash)
        for parent in [commit, merge] {
            _ = try? await queries.commitDiff(parent, path: "a.txt", oldPath: "o.txt")
            _ = try? await queries.commitSource(parent, path: "a.txt", oldPath: nil)
        }
        // Concurrent requests arrive in either order: the set of them is what recordings hold.
        return Self.hash(source.gitCalls.sorted())
    }

    /// The defaults that decide what files mode asks a host for.
    private static var filesDefaults: String {
        let preferences = Preferences(), loader = FilesLoader.Preferences()
        return hash(["show hidden \(preferences.filesShowHidden)", "follow shell \(loader.followShell)",
                     "git \(preferences.gitEnabled)", "loader \(loader)"])
    }

    /// The last fingerprint each migration file names, in their order (file names sort as they apply).
    private static func declared() throws -> [String: String] {
        let directory = try directory
        return try AppReplay.live {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            var fingerprints: [String: String] = [:]
            for file in files {
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                                           file.lastPathComponent)
                for (name, value) in object["fingerprints"] as? [String: String] ?? [:] { fingerprints[name] = value }
            }
            return fingerprints
        }
    }

    func testRecordedInputsChangeOnlyWithAMigration() async throws {
        let current = ["ssh-setup": Self.sshSetup, "git-requests": await Self.gitRequests(), "files-defaults": Self.filesDefaults]
        let declared = try Self.declared()
        for (name, hash) in current.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(declared[name], hash, """
            What the app records as \(name) changed. Add a migration in test/replay-migrations (a rewrite where the recorded \
            answers still hold, else a rerecord of the tests whose answers change; docs/replay.md, Migrations) that names \
            "fingerprints": {"\(name)": "\(hash)"}.
            """)
        }
    }
}
