import Foundation
import Observation
import XCTest
@testable import DispatchApp

/// The loader against an in-memory host: the root follows the shell then pins, folders load and prune, the
/// 2 s poll runs only while files shows (its sleeps are the test's to release), and nothing redraws for an
/// unchanged folder.
@MainActor
final class FilesLoadingTests: XCTestCase {
    /// Stands in for the 2 s wait: each sleep waits until the test releases it, and is counted.
    final class Sleeper: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [Int: CheckedContinuation<Void, any Error>] = [:]
        private var started = 0

        var pending: Int { lock.withLock { waiting.count } }
        var count: Int { lock.withLock { started } }

        func sleep(_ duration: Duration) async throws {
            let id = lock.withLock { started += 1; return started }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let cancelled: Bool = lock.withLock {
                        if Task.isCancelled { return true }
                        waiting[id] = continuation
                        return false
                    }
                    if cancelled { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                lock.withLock { waiting.removeValue(forKey: id) }?.resume(throwing: CancellationError())
            }
        }

        /// Ends every pending sleep, as if 2 s passed.
        func fire() {
            let all = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
                defer { waiting.removeAll() }
                return Array(waiting.values)
            }
            for continuation in all { continuation.resume() }
        }
    }

    @MainActor @Observable final class Tab {
        var directory: String?
        init(_ directory: String?) { self.directory = directory }
    }

    @MainActor final class Clock {
        var now = Date(timeIntervalSince1970: 1_760_700_000)
    }

    final class Redraws: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var marked: Bool { lock.withLock { value } }
        func mark() { lock.withLock { value = true } }
    }

    @MainActor final class Current {
        var source: any FilesSource
        init(_ source: any FilesSource) { self.source = source }
    }

    @MainActor struct Fixture {
        let coordinator: FilesCoordinator
        let session: FilesSession
        let tab: Tab
        let sleeper: Sleeper
        let clock: Clock
        var loader: FilesLoader { coordinator.loader }

        /// Waits for the session's task to finish the pass that follows `before` and settle into a wait.
        func settled(after before: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
            try await TestSupport.eventually(file: file, line: line) {
                loader.passes(session.id) > before && loader.waiting(session.id) != nil
            }
        }
    }

    private let api = "/Users/ivan/src/api"

    private func fixture(_ source: FakeFilesSource, directory: String?, visible: Bool = true, presented: Bool = true,
                         preferences: FilesLoader.Preferences = .init(),
                         resolve: (@MainActor (UUID, Date?) -> FilesAvailability)? = nil) -> Fixture {
        let coordinator = FilesCoordinator { nil }
        let tab = Tab(directory), sleeper = Sleeper(), clock = Clock()
        let session = coordinator.session(for: System.uuid())
        session.visible = visible
        session.presented = presented
        coordinator.loader.environment = FilesLoader.Environment(
            resolve: resolve ?? { _, _ in .available(source) },
            directory: { _ in tab.directory },
            track: { _ in },
            preferences: { preferences },
            sleep: { try await sleeper.sleep($0) },
            now: { clock.now })
        coordinator.observe(session)
        return Fixture(coordinator: coordinator, session: session, tab: tab, sleeper: sleeper, clock: clock)
    }

    private func lists(_ source: FakeFilesSource) -> [String] { source.calls.filter { $0.hasPrefix("list ") } }

    func testRootFollowsTheTabDirectoryThenPins() async throws {
        let source = FakeFilesSource.mockupAPI()
        source.file("/Users/ivan/docs/notes.md", "# notes\n")
        let f = fixture(source, directory: api)
        try await TestSupport.eventually { f.session.listings[api]?.listing != nil }
        XCTAssertEqual(f.session.listings[api]?.entries.map(\.name),
                       ["CHANGELOG.md", "README.md", "node_modules", "package.json", "pnpm-lock.yaml", "src", "tests",
                        "tsconfig.json"])
        XCTAssertEqual(f.session.home, "/Users/ivan")
        XCTAssertNotNil(f.session.lastRefresh)
        f.session.selection = [api + "/README.md"]
        f.session.anchor = api + "/README.md"

        // A cd in the shell moves the root: the old root's listing goes and the selection with it.
        f.tab.directory = "/Users/ivan/docs/"
        try await TestSupport.eventually { f.session.listings["/Users/ivan/docs"]?.listing != nil }
        XCTAssertNil(f.session.listings[api])
        XCTAssertEqual(f.session.selection, [])
        XCTAssertNil(f.session.anchor)

        // A pin holds the root while the shell moves on.
        f.session.pinnedRoot = api
        try await TestSupport.eventually { f.session.listings[api]?.listing != nil }
        XCTAssertNil(f.session.listings["/Users/ivan/docs"])
        let before = f.loader.passes(f.session.id)
        f.tab.directory = "/Users/ivan"
        try await f.settled(after: before)
        XCTAssertFalse(lists(source).contains("list /Users/ivan"))
        XCTAssertNotNil(f.session.listings[api]?.listing)

        // ↩ returns to the shell's directory; an empty one falls back to home.
        f.session.pinnedRoot = nil
        try await TestSupport.eventually { f.session.listings["/Users/ivan"]?.listing != nil }
        f.tab.directory = ""
        let unchanged = f.loader.passes(f.session.id)
        try await f.settled(after: unchanged)
        XCTAssertNotNil(f.session.listings["/Users/ivan"]?.listing)
    }

    func testFollowShellOffKeepsTheRootWhereItWas() async throws {
        let source = FakeFilesSource.mockupAPI()
        source.file("/Users/ivan/docs/notes.md", "# notes\n")
        let f = fixture(source, directory: api, preferences: .init(followShell: false))
        try await TestSupport.eventually { f.session.listings[api]?.listing != nil }
        XCTAssertEqual(f.session.pinnedRoot, api, "With following off the first root stays as a pin")
        let before = f.loader.passes(f.session.id)
        f.tab.directory = "/Users/ivan/docs"
        try await f.settled(after: before)
        XCTAssertFalse(lists(source).contains("list /Users/ivan/docs"))
        XCTAssertEqual(f.session.root(tabDirectory: f.tab.directory), api)
    }

    func testExpandedFoldersLoadAndPrune() async throws {
        let source = FakeFilesSource.mockupAPI()
        let f = fixture(source, directory: api)
        try await TestSupport.eventually { f.session.listings[api]?.listing != nil }
        f.session.expanded = [api + "/src", api + "/src/routes", "/Users/ivan/elsewhere"]
        try await TestSupport.eventually {
            f.session.listings[api + "/src"]?.listing != nil && f.session.listings[api + "/src/routes"]?.listing != nil
        }
        XCTAssertEqual(f.session.listings[api + "/src/routes"]?.entries.map(\.name), ["billing.ts", "health.ts"])
        XCTAssertEqual(f.session.expanded, [api + "/src", api + "/src/routes"], "A folder outside the root is pruned")
        XCTAssertFalse(lists(source).contains("list /Users/ivan/elsewhere"))

        // Pinning a subfolder keeps what is inside it.
        f.session.expanded.insert(api + "/tests")
        try await TestSupport.eventually { f.session.listings[api + "/tests"]?.listing != nil }
        f.session.pinnedRoot = api + "/src"
        try await TestSupport.eventually { f.session.listings[api + "/src"]?.listing != nil && f.session.listings[api] == nil }
        XCTAssertEqual(f.session.expanded, [api + "/src", api + "/src/routes"])
        XCTAssertNil(f.session.listings[api + "/tests"])
        XCTAssertNotNil(f.session.listings[api + "/src/routes"]?.listing)
    }

    func testPollingRunsOnlyWhileFilesShows() async throws {
        let source = FakeFilesSource.mockupAPI()
        let f = fixture(source, directory: api, visible: false)
        try await TestSupport.eventually { f.loader.waiting(f.session.id) == .change }
        XCTAssertEqual(f.sleeper.count, 0, "Hidden: no poll is armed")
        XCTAssertEqual(lists(source), [], "Hidden: nothing is listed")

        f.session.visible = true
        try await TestSupport.eventually { f.loader.waiting(f.session.id) == .poll && f.sleeper.pending == 1 }
        XCTAssertEqual(lists(source), ["list " + api])
        f.session.expanded = [api + "/src"]
        try await TestSupport.eventually { lists(source).count == 2 && f.sleeper.pending == 1 }
        XCTAssertEqual(lists(source).last, "list " + api + "/src", "A new folder alone is listed when it expands")

        // Each 2 s lists the root and every expanded folder again.
        f.sleeper.fire()
        try await TestSupport.eventually { lists(source).count == 4 && f.sleeper.pending == 1 }
        XCTAssertEqual(Set(lists(source).suffix(2)), ["list " + api, "list " + api + "/src"])

        f.session.visible = false
        try await TestSupport.eventually { f.loader.waiting(f.session.id) == .change }
        XCTAssertEqual(f.sleeper.pending, 0, "Hiding cancels the armed poll")
        XCTAssertEqual(lists(source).count, 4)
        let sleeps = f.sleeper.count
        f.sleeper.fire()
        f.coordinator.refreshNow(f.session.id)
        try await f.settled(after: f.loader.passes(f.session.id))
        XCTAssertEqual(lists(source).count, 4, "A refresh while hidden lists nothing")
        XCTAssertEqual(f.sleeper.count, sleeps)

        // Showing again lists everything at once (the listings may be old).
        f.session.visible = true
        try await TestSupport.eventually { lists(source).count == 6 && f.sleeper.pending == 1 }
    }

    func testATabInFilesModeThatIsNotOnScreenListsNothing() async throws {
        let source = FakeFilesSource.mockupAPI()
        let f = fixture(source, directory: api, presented: false)
        try await TestSupport.eventually { f.loader.waiting(f.session.id) == .change }
        XCTAssertEqual(f.sleeper.count, 0, "Not presented: no poll is armed")
        XCTAssertEqual(lists(source), [])
        f.coordinator.shellPromptedNow(f.session.id)
        f.coordinator.refreshNow(f.session.id)
        try await f.settled(after: f.loader.passes(f.session.id))
        XCTAssertEqual(lists(source), [], "Prompts and refreshes list nothing either")

        f.session.presented = true
        try await TestSupport.eventually { f.loader.waiting(f.session.id) == .poll && f.sleeper.pending == 1 }
        XCTAssertEqual(lists(source), ["list " + api])
        f.session.presented = false
        try await TestSupport.eventually { f.loader.waiting(f.session.id) == .change && f.sleeper.pending == 0 }
    }

    func testAListingThatNeverAnswersGivesWayToTheNextRoot() async throws {
        let source = FakeFilesSource.mockupAPI()
        source.file("/Users/ivan/docs/notes.md", "# notes\n")
        source.hangs = ["list " + api]
        let f = fixture(source, directory: api)
        try await TestSupport.eventually { lists(source) == ["list " + api] }
        XCTAssertEqual(f.session.listings[api]?.loading, true)
        f.tab.directory = "/Users/ivan/docs"
        try await TestSupport.eventually { f.session.listings["/Users/ivan/docs"]?.listing != nil }
        XCTAssertNil(f.session.listings[api], "The stuck folder's loading mark went with its root")
        try await TestSupport.eventually { f.sleeper.pending == 1 }
        f.sleeper.fire()
        try await TestSupport.eventually { lists(source).count == 3 }
        XCTAssertEqual(lists(source).last, "list /Users/ivan/docs", "The poll goes on for the new root")
    }

    func testUnchangedListingKeepsItsState() async throws {
        let source = FakeFilesSource.mockupAPI()
        let f = fixture(source, directory: api)
        try await TestSupport.eventually { f.session.listings[api]?.listing != nil && f.sleeper.pending == 1 }
        let loadedAt = f.session.listings[api]?.loadedAt
        let redraws = Redraws()
        withObservationTracking { _ = f.session.listings } onChange: { redraws.mark() }
        f.clock.now += 2
        f.sleeper.fire()
        try await TestSupport.eventually { lists(source).count == 2 && f.sleeper.pending == 1 }
        XCTAssertFalse(redraws.marked, "An identical listing does not touch the listings")
        XCTAssertEqual(f.session.listings[api]?.loadedAt, loadedAt)
        XCTAssertEqual(f.session.lastRefresh, f.clock.now)

        source.file(api + "/NEW.md", "new\n")
        f.clock.now += 2
        f.sleeper.fire()
        try await TestSupport.eventually { f.session.listings[api]?.entries.contains { $0.name == "NEW.md" } == true }
        XCTAssertTrue(redraws.marked)
        XCTAssertEqual(f.session.listings[api]?.loadedAt, f.clock.now)
    }

    func testOfflineKeepsEntriesAndMarksThemStale() async throws {
        let source = FakeFilesSource.mockupAPI()
        let f = fixture(source, directory: api)
        try await TestSupport.eventually { f.session.listings[api]?.listing != nil && f.sleeper.pending == 1 }
        let live = f.session.lastRefresh
        source.failures["list"] = .offline("homelab")
        f.clock.now += 2
        f.sleeper.fire()
        try await TestSupport.eventually { f.session.staleSince != nil }
        XCTAssertEqual(f.session.staleSince, live, "Stale since the last live listing")
        XCTAssertEqual(f.session.listings[api]?.entries.count, 8, "The last entries stay")
        guard case .offline(_, let since) = f.session.availability else { return XCTFail("\(f.session.availability)") }
        XCTAssertEqual(since, live)

        // Another failed poll changes nothing; the first live one clears the mark.
        f.clock.now += 2
        f.sleeper.fire()
        try await TestSupport.eventually { lists(source).count == 3 && f.sleeper.pending == 1 }
        XCTAssertEqual(f.session.staleSince, live)
        source.failures["list"] = nil
        f.sleeper.fire()
        try await TestSupport.eventually { f.session.staleSince == nil }
        XCTAssertTrue(f.session.availability.source === source)
    }

    func testOtherFailuresShowInTheFolder() async throws {
        let source = FakeFilesSource.mockupAPI()
        let f = fixture(source, directory: api)
        try await TestSupport.eventually { f.session.listings[api]?.listing != nil && f.sleeper.pending == 1 }
        source.failures["list " + api + "/secret"] = .permissionDenied(api + "/secret")
        f.session.expanded = [api + "/secret"]
        try await TestSupport.eventually { f.session.listings[api + "/secret"]?.error != nil }
        XCTAssertEqual(f.session.listings[api + "/secret"]?.error, .permissionDenied(api + "/secret"))
        XCTAssertNil(f.session.listings[api + "/secret"]?.listing)
        XCTAssertEqual(f.session.listings[api + "/secret"]?.loading, false)
        source.remove(api + "/tests")
        f.session.expanded.insert(api + "/tests")
        try await TestSupport.eventually { f.session.listings[api + "/tests"]?.error == .notFound(api + "/tests") }
    }

    func testShellPromptRefreshesOncePerHalfSecond() async throws {
        let source = FakeFilesSource.mockupAPI()
        let f = fixture(source, directory: api)
        try await TestSupport.eventually { f.session.listings[api]?.listing != nil && f.sleeper.pending == 1 }
        var before = f.loader.passes(f.session.id)
        f.coordinator.shellPromptedNow(f.session.id)
        f.coordinator.shellPromptedNow(f.session.id)
        f.clock.now += 0.4
        f.coordinator.shellPromptedNow(f.session.id)
        try await f.settled(after: before)
        XCTAssertEqual(f.loader.passes(f.session.id), before + 1)
        XCTAssertEqual(lists(source).count, 2, "A burst of prompts lists once")

        f.clock.now += 0.2
        before = f.loader.passes(f.session.id)
        f.coordinator.shellPromptedNow(f.session.id)
        try await f.settled(after: before)
        XCTAssertEqual(lists(source).count, 3)

        f.session.visible = false
        try await TestSupport.eventually { f.loader.waiting(f.session.id) == .change }
        before = f.loader.passes(f.session.id)
        f.clock.now += 1
        f.coordinator.shellPromptedNow(f.session.id)
        XCTAssertEqual(f.loader.waiting(f.session.id), .change, "A prompt while hidden wakes nothing")
        XCTAssertEqual(f.loader.passes(f.session.id), before)
    }

    func testReconnectKeepsTheListingAndAnotherHostDropsIt() async throws {
        let first = FakeFilesSource.mockupAPI(), again = FakeFilesSource.mockupAPI(), other = FakeFilesSource.mockupAPI()
        for source in [first, again, other] { source.hostLabel = source === other ? "nas" : "homelab" }
        let current = Current(first)
        let f = fixture(first, directory: api, resolve: { _, _ in .available(current.source) })
        try await TestSupport.eventually { f.session.listings[api]?.listing != nil && f.sleeper.pending == 1 }
        XCTAssertEqual(f.session.hostLabel, "homelab")
        f.session.expanded = [api + "/src"]
        try await TestSupport.eventually { f.session.listings[api + "/src"]?.listing != nil }

        current.source = again
        f.sleeper.fire()
        try await TestSupport.eventually { lists(again).count == 2 }
        XCTAssertNotNil(f.session.listings[api + "/src"]?.listing, "The same host's new connection keeps what shows")
        XCTAssertTrue(f.session.availability.source === again)

        current.source = other
        f.sleeper.fire()
        try await TestSupport.eventually { f.session.hostLabel == "nas" && f.session.listings[api]?.listing != nil }
        XCTAssertEqual(f.session.expanded, [])
        XCTAssertEqual(lists(other), ["list " + api])
    }

    func testForgettingTheSessionEndsItsTask() async throws {
        let source = FakeFilesSource.mockupAPI()
        let f = fixture(source, directory: api)
        try await TestSupport.eventually { f.sleeper.pending == 1 }
        f.coordinator.forget(f.session.id)
        try await TestSupport.eventually { f.loader.waiting(f.session.id) == nil && f.sleeper.pending == 0 }
        XCTAssertEqual(f.loader.passes(f.session.id), 0)
    }

    func testHelperFailuresMapToFilesErrors() {
        let path = "/srv/app"
        func map(_ code: String, message: String = "", host: String? = "homelab") -> FilesSourceError {
            HelperFilesSource.map(HelperFailure(code: code, message: message), path: path, host: host)
        }
        XCTAssertEqual(map("not_found"), .notFound(path))
        XCTAssertEqual(map("permission_denied"), .permissionDenied(path))
        XCTAssertEqual(map("not_directory"), .notDirectory(path))
        XCTAssertEqual(map("changed"), .changed(path))
        XCTAssertEqual(map("exists"), .exists(path))
        XCTAssertEqual(map("limit"), .limit("/srv/app is larger than the helper copies at once"))
        XCTAssertEqual(map("limit", message: "Over 8 MiB"), .limit("Over 8 MiB"))
        XCTAssertEqual(map("busy"), .busy("The helper on homelab is busy with another copy"))
        XCTAssertEqual(map("unsupported"), .unsupported("The helper on homelab can’t do this yet"))
        XCTAssertEqual(map("unsupported", host: nil), .unsupported("This Mac’s helper can’t do this yet"))
        XCTAssertEqual(map("unavailable"), .offline("homelab"))
        XCTAssertEqual(map("connection_closed"), .offline("homelab"))
        XCTAssertEqual(map("unavailable", message: "The bundled helper is missing.", host: nil),
                       .other(code: "unavailable", message: "The bundled helper is missing."))
        XCTAssertEqual(map("cancelled"), .cancelled)
        XCTAssertEqual(map("io", message: "Input/output error"), .other(code: "io", message: "Input/output error"))
        XCTAssertEqual(map("invalid_request"), .other(code: "invalid_request", message: "The helper on homelab failed (invalid_request)"))
        XCTAssertEqual(HelperFilesSource.map(CancellationError(), path: path, host: "homelab"), .cancelled)
        XCTAssertEqual(HelperFilesSource.map(FilesSourceError.busy("x"), path: path, host: "homelab"), .busy("x"))
        let timeout = HerdrFailure("The remote operation timed out. Its outcome may be uncertain; it was not retried.")
        XCTAssertEqual(HelperFilesSource.map(timeout, path: path, host: "homelab"), .other(code: "uncertain", message: timeout.message))

        // A broken stream ends the connection: offline remotely, a transport failure on this Mac, retryable both.
        for error: any Error in [HelperWire.Failure.truncated, HelperWire.Failure.kind, HelperBinary.Failure.invalid,
                                 HelperFailure(code: "invalid_response", message: "Invalid helper message.")] {
            XCTAssertEqual(HelperFilesSource.map(error, path: path, host: "homelab"), .offline("homelab"), "\(error)")
            let local = HelperFilesSource.map(error, path: path, host: nil)
            guard case .other(let code, _) = local, code == "disconnected" else { return XCTFail("\(error): \(local)") }
            XCTAssertTrue(FileTransferEngine.isTransport(error), "\(error)")
            XCTAssertTrue(FileTransferEngine.isTransport(local), "\(error)")
        }
        XCTAssertTrue(FileTransferEngine.isTransport(HelperFailure(code: "connection_closed", message: "")))
        XCTAssertFalse(FileTransferEngine.isTransport(HelperFailure(code: "not_found", message: "")))
    }

    func testRemoteBoundsGrowWithTheBytesMoved() {
        XCTAssertEqual(HelperFilesSource.Bound.quick.duration, .seconds(10))
        XCTAssertEqual(HelperFilesSource.Bound.bytes(0).duration, .seconds(10))
        XCTAssertEqual(HelperFilesSource.Bound.bytes(4 << 20).duration, .seconds(74), "A 4 MiB window at 64 KiB/s")
        XCTAssertEqual(HelperFilesSource.Bound.bytes(.max).duration, .seconds(600))
        XCTAssertNil(HelperFilesSource.Bound.job.duration, "A pack or a commit runs as long as it takes")
    }

    func testPathsInsideTheRoot() {
        XCTAssertEqual(FilesLoader.normalized("/a/b//"), "/a/b")
        XCTAssertEqual(FilesLoader.normalized("/"), "/")
        XCTAssertNil(FilesLoader.normalized("relative"))
        XCTAssertNil(FilesLoader.normalized(""))
        XCTAssertTrue(FilesLoader.path("/a/b", isInside: "/a"))
        XCTAssertTrue(FilesLoader.path("/a", isInside: "/a"))
        XCTAssertFalse(FilesLoader.path("/ab", isInside: "/a"))
        XCTAssertTrue(FilesLoader.path("/x", isInside: "/"))
    }
}
