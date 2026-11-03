import Foundation
import XCTest
@testable import DispatchApp

/// A folder git names through another path (a symlink, `/tmp` for `/private/tmp`): the repository's root is spelled as
/// the folder spells it only where git confirms that spelling is the repository's own top, never because a folder
/// above has the repository's name. Against the in-memory host's scripted git.
final class GitSymlinkRootTests: XCTestCase {
    private func ok(_ output: String) -> GitOutput { GitOutput(status: 0, output: output, truncated: false) }

    private func answer(_ source: FakeFilesSource, _ folder: String, _ top: String) {
        source.gitAnswers[folder + " rev-parse --show-toplevel"] = ok(top + "\n")
    }

    /// A link inside an unrelated folder (or repository) of the repository's name: that folder is not the root.
    func testAnUnrelatedFolderOfTheSameNameIsNotTheRoot() async throws {
        for unrelated in [nil, "/work/api"] {
            let source = FakeFilesSource()
            // /work/api/child → /real/api.
            answer(source, "/work/api/child/src", "/real/api")
            answer(source, "/work/api/child", "/real/api")
            if let unrelated { answer(source, "/work/api", unrelated) }
            let repository = try await GitQueries.repository(of: "/work/api/child/src", source: source)
            XCTAssertEqual(repository?.root, "/work/api/child", "the link is the root, not the folder named api")
        }
    }

    /// A folder inside the repository named like it is not its top: its parent is in the repository too.
    func testAFolderOfTheRepositoryNamedLikeItIsNotTheRoot() async throws {
        let source = FakeFilesSource()
        // /vol/api → /real/api, which has pkg/api inside.
        answer(source, "/vol/api/pkg/api/src", "/real/api")
        answer(source, "/vol/api/pkg/api", "/real/api")
        answer(source, "/vol/api/pkg", "/real/api")
        answer(source, "/vol/api", "/real/api")
        let repository = try await GitQueries.repository(of: "/vol/api/pkg/api/src", source: source)
        XCTAssertEqual(repository?.root, "/vol/api")
        XCTAssertEqual(source.gitCalls, ["/vol/api/pkg/api/src", "/vol/api/pkg/api", "/vol/api/pkg", "/vol/api", "/vol"]
            .map { $0 + " rev-parse --show-toplevel" })
    }

    /// A worktree or nested repository named like the one a link inside it leads to is another repository.
    func testANestedRepositoryOfTheSameNameIsNotTheRoot() async throws {
        let source = FakeFilesSource()
        // /w/api is a worktree of its own; /w/api/link → /real/api.
        answer(source, "/w/api/link/src", "/real/api")
        answer(source, "/w/api/link", "/real/api")
        answer(source, "/w/api", "/w/api")
        let repository = try await GitQueries.repository(of: "/w/api/link/src", source: source)
        XCTAssertEqual(repository?.root, "/w/api/link")

        // Inside the nested one, through a link to its outer repository's folder: the nested one is the root.
        let nested = FakeFilesSource()
        answer(nested, "/view/api/wt/api/src", "/real/api/wt/api")
        answer(nested, "/view/api/wt/api", "/real/api/wt/api")
        answer(nested, "/view/api/wt", "/real/api")
        let inner = try await GitQueries.repository(of: "/view/api/wt/api/src", source: nested)
        XCTAssertEqual(inner?.root, "/view/api/wt/api")
    }

    /// Several links on the way (/Users/sam/l1 → /Volumes/data, l2 → code): the spelled folder git confirms.
    func testSeveralLinksOnTheWay() async throws {
        let source = FakeFilesSource()
        answer(source, "/Users/sam/l1/l2/api/src/lib", "/Volumes/data/code/api")
        answer(source, "/Users/sam/l1/l2/api", "/Volumes/data/code/api")
        let repository = try await GitQueries.repository(of: "/Users/sam/l1/l2/api/src/lib", source: source)
        XCTAssertEqual(repository?.root, "/Users/sam/l1/l2/api")
    }

    /// The folder itself named like the repository is not asked twice: only its parent is.
    func testTheFolderItselfIsAskedOnce() async throws {
        let source = FakeFilesSource()
        answer(source, "/var/t/api", "/private/var/t/api")
        let repository = try await GitQueries.repository(of: "/var/t/api", source: source)
        XCTAssertEqual(repository?.root, "/var/t/api")
        XCTAssertEqual(source.gitCalls, ["/var/t/api rev-parse --show-toplevel", "/var/t rev-parse --show-toplevel"])
    }

    /// A host that stops answering while a spelling is checked fails the question; it is not taken as "no".
    func testAFailedCheckIsAnError() async throws {
        let source = FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "homelab")
        answer(source, "/srv/api/src", "/data/api")
        source.failures["git /srv/api"] = .offline("homelab")
        do {
            _ = try await GitQueries.repository(of: "/srv/api/src", source: source)
            XCTFail("An offline check resolved")
        } catch {
            XCTAssertEqual(error, .source(.offline("homelab")))
        }
    }
}

/// The same against this Mac's helper and real repositories in the test's temporary folder (which git names through
/// /private): links in unrelated folders of the same name, unrelated repositories of the same name, a nested worktree
/// and several links on the way.
final class GitSymlinkRootEndToEndTests: XCTestCase {
    private var session: HelperSession!
    private var root: URL!
    private var source: HelperFilesSource!

    override func setUp() async throws {
        root = URL(fileURLWithPath: try XCTUnwrap(System.environment("TMPDIR")))
            .appendingPathComponent("s" + System.uuid().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        let process = Process()
        process.executableURL = try XCTUnwrap(HelperApp.executable)
        process.arguments = ["--stdio"]
        process.environment = System.inherited.merging(["HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1"]) { _, new in new }
        process.standardError = FileHandle.nullDevice
        session = try await HelperSession(process: process)
        addTeardownBlock { [session] in session?.close() }
        source = HelperFilesSource(endpoint: .local, connection: session.connection, home: root.path, hostLabel: nil)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func git(_ directory: URL, _ args: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Sam Example", "-c", "user.email=sam@example.com", "-c", "init.defaultBranch=main",
                             "-c", "commit.gpgsign=false", "-C", directory.path] + args
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                               "GIT_AUTHOR_DATE": "1760000000 +0000", "GIT_COMMITTER_DATE": "1760000000 +0000"]
        process.standardError = FileHandle.nullDevice
        let exit = try TestSupport.live(process)
        XCTAssertEqual(exit.status, 0, "git " + args.joined(separator: " "))
    }

    /// A repository at `path` with one commit and a `src` folder.
    @discardableResult private func repository(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: url.appendingPathComponent("src/a.txt"))
        try git(url, "init", "-q")
        try git(url, "add", "-A")
        try git(url, "commit", "-q", "-m", "First")
        return url
    }

    private func folder(_ path: String) -> String { root.appendingPathComponent(path).path }

    private func link(_ path: String, to target: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(path),
                                                   withDestinationURL: root.appendingPathComponent(target))
    }

    private func resolve(_ path: String) async throws -> String? {
        try await GitQueries.repository(of: folder(path), source: source)?.root
    }

    func testLinkedRootsResolveToTheirOwnRepository() async throws {
        try repository("real/api")
        // A plain folder named api holding a link to the repository, and an unrelated repository named api holding one.
        try link("plain/api/child", to: "real/api")
        try repository("other/api")
        try link("other/api/child", to: "real/api")
        // Two links on the way: l1 → hops, hops/l2 → real.
        try link("l1", to: "hops")
        try link("hops/l2", to: "real")
        // A worktree named api inside the repository.
        try git(root.appendingPathComponent("real/api"), "worktree", "add", "-q", "-b", "side",
                root.appendingPathComponent("real/api/wt/api").path)

        let direct = try await resolve("real/api/src")
        XCTAssertEqual(direct, folder("real/api"), "the folder's own spelling of the top git names through /private")
        let plain = try await resolve("plain/api/child/src")
        XCTAssertEqual(plain, folder("plain/api/child"), "not the plain folder named api")
        let unrelated = try await resolve("other/api/child/src")
        XCTAssertEqual(unrelated, folder("other/api/child"), "not the unrelated repository named api")
        let hops = try await resolve("l1/l2/api/src")
        XCTAssertEqual(hops, folder("l1/l2/api"))
        let worktree = try await resolve("real/api/wt/api/src")
        XCTAssertEqual(worktree, folder("real/api/wt/api"), "the worktree is its own repository")
        let outer = try await resolve("l1/l2/api/wt")
        XCTAssertEqual(outer, folder("l1/l2/api"), "a folder of the outer repository holding the worktree")
    }
}
