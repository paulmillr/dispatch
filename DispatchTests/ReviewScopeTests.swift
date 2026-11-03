import Foundation
import XCTest
@testable import DispatchApp

/// Whose review a tab shows: this Mac's repository, or a remote host's by its stable identity (never its shown name),
/// under a versioned key no host or root can forge; and the keys of older versions, migrated where their host is known.
@MainActor
final class ReviewScopeTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_760_700_000)

    private func review(_ text: String) -> Review {
        Review(comments: [ReviewComment(id: System.uuid(), path: "a.ts", start: nil, end: nil, quote: [], text: text,
                                        created: created)],
               modified: System.date())
    }

    private func session(_ source: FakeFilesSource, root: String) -> FilesSession {
        let session = FilesSession(id: System.uuid())
        session.availability = .available(source)
        session.git = .repository(GitRepository(root: root))
        return session
    }

    /// The key is versioned and every part escaped: a `|` or `%` in a host or a root cannot spell another's key, and the
    /// key reads back as what it names.
    func testKeysAreVersionedAndCollisionFree() throws {
        let local = ReviewRepository.scope(local: true, host: nil, root: "/Users/sam/src/api")
        XCTAssertEqual(local, "v2|local||/Users/sam/src/api")
        let remote = ReviewRepository.scope(local: false, host: "ssh:4c4c4544-0042", root: "/home/sam/api")
        XCTAssertEqual(remote, "v2|remote|ssh:4c4c4544-0042|/home/sam/api")
        XCTAssertEqual(ReviewScope(key: remote), ReviewScope(kind: .remote, host: "ssh:4c4c4544-0042", root: "/home/sam/api"))

        let tricky = [
            ReviewScope(kind: .remote, host: "a|b", root: "/c"),
            ReviewScope(kind: .remote, host: "a", root: "b|/c"),
            ReviewScope(kind: .remote, host: "a%7Cb", root: "/c"),
            ReviewScope(kind: .remote, host: "a", root: "/c|"),
            ReviewScope(kind: .remote, host: "a", root: "/c%"),
            ReviewScope(kind: .remote, host: "", root: "/c"),
            ReviewScope(kind: .local, host: "", root: "/c"),
            ReviewScope(kind: .local, host: "", root: "|remote|a|/c"),
        ]
        XCTAssertEqual(Set(tricky.map(\.key)).count, tricky.count, "no two scopes share a key")
        for scope in tricky { XCTAssertEqual(ReviewScope(key: scope.key), scope, scope.key) }
        XCTAssertNil(ReviewScope(key: "local|/c"), "an old key is not a scope")
        XCTAssertNil(ReviewScope(key: "v2|local|ssh:x|/c"), "this Mac's names no host")
        XCTAssertEqual(ReviewScope(kind: .local, host: "ignored", root: "/c").key, "v2|local||/c")
    }

    /// Two hosts both shown as "homelab", with the same checkout path, keep their own reviews; one renamed keeps its
    /// own; a remote source whose host is not identified yet has no review at all.
    func testHostsNamedAlikeOrRenamedKeepTheirOwnReviews() throws {
        let root = "/home/sam/api"
        let first = FakeFilesSource(endpoint: .remote(SSHConnectionID()), home: "/home/sam", hostLabel: "homelab")
        first.hostIdentity = "ssh:11111111-aaaa"
        let second = FakeFilesSource(endpoint: .remote(SSHConnectionID()), home: "/home/sam", hostLabel: "homelab")
        second.hostIdentity = "ssh:22222222-bbbb"
        let a = try XCTUnwrap(session(first, root: root).reviewScope)
        let b = try XCTUnwrap(session(second, root: root).reviewScope)
        XCTAssertNotEqual(a, b, "the same name and path on two machines are two reviews")

        let renamed = FakeFilesSource(endpoint: .remote(SSHConnectionID()), home: "/home/sam", hostLabel: "build box")
        renamed.hostIdentity = first.hostIdentity
        XCTAssertEqual(session(renamed, root: root).reviewScope, a, "a rename (or a reconnect) keeps the review")

        let unknown = FakeFilesSource(endpoint: .remote(SSHConnectionID()), home: "/home/sam", hostLabel: "homelab")
        XCTAssertNil(session(unknown, root: root).reviewScope, "no identity: no review to mix up")
        XCTAssertEqual(session(FakeFilesSource(), root: "/Users/sam/src/api").reviewScope,
                       ReviewRepository.scope(local: true, host: nil, root: "/Users/sam/src/api"))
    }

    /// The resolver hands the greeting's identity to the connection's source, and a new identity makes a new source.
    func testTheResolverGivesTheSourceItsHostsIdentity() throws {
        let connection = SSHConnectionID()
        var facts = FilesResolver.Facts(machine: .ssh(destination: "homelab"), connection: connection,
                                        link: .init(grantsFiles: true, scope: nil, home: "/home/sam"), host: "homelab")
        facts.hostIdentity = "ssh:11111111-aaaa"
        let decision = FilesResolver.decide(facts, lastRefresh: nil)
        XCTAssertEqual(decision, .remote(connection, home: "/home/sam", host: "homelab", identity: "ssh:11111111-aaaa"))
        let resolver = FilesResolver()
        let source = resolver.source(for: connection, home: "/home/sam", host: "homelab", identity: "ssh:11111111-aaaa")
        XCTAssertEqual(source.hostIdentity, "ssh:11111111-aaaa")
        XCTAssertTrue(resolver.source(for: connection, home: "/home/sam", host: "homelab", identity: "ssh:11111111-aaaa") === source)
        XCTAssertFalse(resolver.source(for: connection, home: "/home/sam", host: "homelab", identity: "ssh:2") === source)
    }

    /// Old keys: this Mac's always move; a remote one moves when exactly one remembered host can be the name it
    /// holds (whatever `|` the name or the root has), merged into a review already under its new key; the rest stay
    /// as they were, kept and shown nowhere.
    func testOldKeysMoveWhereTheirHostIsKnown() throws {
        let hosts: [String: Set<String>] = [
            "homelab": ["ssh:11111111-aaaa"],
            "twin": ["ssh:33333333-cccc", "ssh:44444444-dddd"],
            "a|/b": ["ssh:55555555-eeee"],
            "a": ["ssh:66666666-ffff"],
        ]
        let identify: @MainActor (String) -> Set<String> = { hosts[$0] ?? [] }
        let stored: [String: Review] = [
            "local|/Users/sam/src/api": review("local"),
            "remote:homelab|/home/sam/a|b": review("unique"),
            "remote:twin|/home/sam/api": review("two hosts called twin"),
            "remote:nobody|/home/sam/api": review("unknown host"),
            "remote:a|/b|/srv/x": review("two readings"),
            "remote:homelab|relative": review("no absolute root"),
            ReviewRepository.scope(local: false, host: "ssh:11111111-aaaa", root: "/home/sam/taken"): review("new"),
            "remote:homelab|/home/sam/taken": review("taken"),
        ]
        let store = MemoryReviewStore()
        store.stored = stored
        let repository = ReviewRepository(store: store, identify: identify)
        XCTAssertEqual(repository.review(ReviewRepository.scope(local: true, host: nil, root: "/Users/sam/src/api"))
            .comments.map(\.text), ["local"])
        XCTAssertEqual(repository.review(ReviewRepository.scope(local: false, host: "ssh:11111111-aaaa", root: "/home/sam/a|b"))
            .comments.map(\.text), ["unique"], "a root holding the old separator still reads one way")
        XCTAssertEqual(repository.review(ReviewRepository.scope(local: false, host: "ssh:11111111-aaaa", root: "/home/sam/taken"))
            .comments.map(\.text).sorted(), ["new", "taken"], "a taken key gets the old review's comments too")
        for kept in ["remote:twin|/home/sam/api", "remote:nobody|/home/sam/api", "remote:a|/b|/srv/x",
                     "remote:homelab|relative"] {
            XCTAssertEqual(repository.reviews[kept], stored[kept], "\(kept) stays as it was")
        }
        XCTAssertNil(repository.reviews["remote:homelab|/home/sam/taken"])
        XCTAssertEqual(repository.reviews.count, stored.count - 1, "nothing is dropped: one merged")
        XCTAssertEqual(store.saved.count, 1, "the migration is written once")
        XCTAssertEqual(store.saved.last, repository.reviews)

        let again = ReviewRepository(store: store, identify: identify)
        XCTAssertEqual(again.reviews, repository.reviews)
        XCTAssertEqual(store.saved.count, 1, "nothing to migrate: nothing written")
    }

    /// A host renamed while its reviews were kept by name: both old keys name it now, and whichever sorts first, the
    /// live review and the stale one end up together under its key, the newer's overall comment first.
    func testARenamedHostsOldReviewsMerge() throws {
        let now = System.date()
        let host = "4D1C6A52-0000-4000-8000-00000000B001"
        var stale = review("from when it was box")
        stale.summary = "Old summary."
        stale.modified = now.addingTimeInterval(-40 * 24 * 3600)
        var live = review("written today")
        live.summary = "Current summary."
        let store = MemoryReviewStore()
        store.stored = ["remote:box|/srv/app": stale, "remote:work|/srv/app": live]
        let repository = ReviewRepository(store: store, identify: { ["box", "work"].contains($0) ? [host] : [] })
        let merged = repository.review(ReviewRepository.scope(local: false, host: host, root: "/srv/app"))
        XCTAssertEqual(Set(merged.comments.map(\.text)), ["from when it was box", "written today"])
        XCTAssertEqual(merged.summary, "Current summary.\n\nOld summary.")
        XCTAssertEqual(repository.reviews.count, 1)
    }

    /// An old review whose host cannot be told (two remembered hosts share its name, or none has it) waits under its
    /// old key however old it is; once it moves it has 30 days from then.
    func testAnUnmovedReviewDoesNotExpire() throws {
        let now = System.date()
        var old = review("ambiguous")
        old.modified = now.addingTimeInterval(-90 * 24 * 3600)
        let store = MemoryReviewStore()
        store.stored = ["remote:twin|/srv/app": old]
        let waiting = ReviewRepository(store: store, identify: { $0 == "twin" ? ["A", "B"] : [] })
        XCTAssertEqual(waiting.reviews["remote:twin|/srv/app"], old, "kept while its host is unknown")
        let moved = ReviewRepository(store: store, identify: { $0 == "twin" ? ["A"] : [] })
        let scope = ReviewRepository.scope(local: false, host: "A", root: "/srv/app")
        XCTAssertEqual(moved.review(scope).comments.map(\.text), ["ambiguous"], "not dropped as it moves")
        XCTAssertGreaterThan(try XCTUnwrap(moved.review(scope).modified), now.addingTimeInterval(-60))
    }

    /// Each identified host has the app's own UUID, the same every time it is asked; this Mac, a connection not yet
    /// identified and a host with no record have none.
    func testEachIdentifiedHostHasItsOwnUUID() {
        let hosts = HostRegistry(defaults: nil)
        let first = HostID.authenticated("11111111-aaaa"), second = HostID.authenticated("22222222-bbbb")
        hosts.restore([HostRecord(id: first, name: "homelab", destinations: [], order: 0),
                       HostRecord(id: second, name: "homelab", destinations: [], order: 1)])
        let key = hosts.key(for: first)
        XCTAssertNotNil(key)
        XCTAssertEqual(hosts.key(for: first), key)
        XCTAssertNotEqual(hosts.key(for: second), key, "two hosts named alike")
        XCTAssertNil(hosts.key(for: .local))
        XCTAssertNil(hosts.key(for: .provisional(System.uuid())))
        XCTAssertNil(hosts.key(for: .authenticated("unknown")))
        hosts.reset()
        XCTAssertNil(hosts.key(for: first), "Remove all data forgets them")
    }

    /// The Mac's old keys named a host by what the sidebar showed: its name, hostname or SSH destination. Only an
    /// identified host is one; this Mac and a connection still being identified are not.
    func testOldNamesAreTheRememberedHostsNamesHostnamesAndDestinations() {
        let records = [
            HostRecord(id: .authenticated("11111111-aaaa"), name: "homelab", hostname: "lab.example.test", destinations: ["lab"], order: 0),
            HostRecord(id: .authenticated("22222222-bbbb"), name: "build", hostname: "homelab", destinations: [], order: 1),
            HostRecord(id: .provisional(System.uuid()), name: "homelab", destinations: [], order: 2),
            HostRecord(id: .local, name: "homelab", destinations: [], order: -1),
        ]
        XCTAssertEqual(ReviewRepository.hosts(named: "homelab", in: records), ["ssh:11111111-aaaa", "ssh:22222222-bbbb"])
        XCTAssertEqual(ReviewRepository.hosts(named: "lab", in: records), ["ssh:11111111-aaaa"])
        XCTAssertEqual(ReviewRepository.hosts(named: "build", in: records), ["ssh:22222222-bbbb"])
        XCTAssertEqual(ReviewRepository.hosts(named: "elsewhere", in: records), [])
    }

    /// A version 1 file is read and written back as version 2; an unknown version is refused, never overwritten.
    func testTheFileMovesToVersionTwo() throws {
        let directory = System.temporary.appendingPathComponent("review-\(System.uuid().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("reviews.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(ReviewFileStore.Document(version: 1, reviews: ["local|/r": review("old")])).write(to: url)
        let repository = ReviewRepository(store: ReviewFileStore(url: url))
        let scope = ReviewRepository.scope(local: true, host: nil, root: "/r")
        XCTAssertEqual(repository.review(scope).comments.map(\.text), ["old"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let written = try decoder.decode(ReviewFileStore.Document.self, from: Data(contentsOf: url))
        XCTAssertEqual(written.version, 2)
        XCTAssertEqual(Set(written.reviews.keys), [scope])

        try encoder.encode(ReviewFileStore.Document(version: 3, reviews: [:])).write(to: url)
        let newer = ReviewRepository(store: ReviewFileStore(url: url))
        XCTAssertNotNil(newer.error)
        newer.add(review("x").comments[0], to: scope)
        XCTAssertEqual(try decoder.decode(ReviewFileStore.Document.self, from: Data(contentsOf: url)).version, 3,
                       "a file this version cannot read is left alone")
    }
}
