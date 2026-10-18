import XCTest
@testable import DispatchMobile

@MainActor
final class HostStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HostStoreTests-" + UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func host(_ name: String, auth: HostRecord.Auth = .password) -> HostRecord {
        HostRecord(name: name, address: name + ".tail3f.ts.net", user: "alex", auth: auth)
    }

    /// A hosts file this build cannot read is moved aside, never written over by the next save (Remove all data deletes
    /// it); a multiplexer preference this build does not know reads as Automatic instead of making the file unreadable.
    func testAnUnreadableFileIsKeptAsideAndAnUnknownPreferenceIsAutomatic() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("hosts.json")
        let broken = Data(#"{"version":1,"hosts":[{"id":"not a host"}]}"#.utf8)
        try broken.write(to: url)
        let store = HostStore(url: url)
        XCTAssertTrue(store.hosts.isEmpty)
        store.add(host("studio"))
        XCTAssertEqual(HostStore(url: url).hosts.map(\.name), ["studio"])
        let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("hosts.json.unreadable-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(aside[0])), broken, "The user's file is kept as it was")
        MobileFiles.removeUnreadable(in: directory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["hosts.json"])

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(host("ai"))) as? [String: Any])
        object["multiplexer"] = "zellij"
        let decoded = try JSONDecoder().decode(HostRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.multiplexer, .automatic)
        XCTAssertEqual(decoded.name, "ai")
    }

    /// Hosts survive a relaunch whole, in order, from an owner-only file.
    /// A failed save keeps the edit in memory, flagged unsaved, and Spaces' notice names it with a retry; the retry
    /// that reaches the disk clears it. Keys fail the same way.
    func testAFailedSaveIsShownAndRetried() async throws {
        // A file where the store's folder should be: every write fails until it goes.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocked = directory.appendingPathComponent("support")
        try Data().write(to: blocked)
        let store = HostStore(url: blocked.appendingPathComponent("hosts.json"))
        let keys = KeyStore(url: blocked.appendingPathComponent("keys.json"), vault: MemoryVault(), keyProtection: .none,
                            secureEnclaveAvailable: false)
        let sessions = HostSessions(store: store, keys: keys, knownHosts: KnownHostStore(url: nil),
                                    driver: ScriptedHostSessionDriver())
        let actions: SpacesHostActions = sessions
        XCTAssertNil(actions.saveFailure)

        let studio = host("studio")
        store.add(studio)
        XCTAssertEqual(store.hosts.map(\.name), ["studio"], "kept in memory")
        XCTAssertEqual(store.unsaved, [studio.id])
        XCTAssertNotNil(store.saveError)
        let key = try keys.generateED25519(label: "phone")
        XCTAssertEqual(keys.unsaved, [key.id])
        let notice = try XCTUnwrap(actions.saveFailure)
        XCTAssertTrue(notice.hasPrefix("studio isn't saved on this iPhone: "), notice)
        XCTAssertTrue(notice.contains("\nThe key “phone” isn't saved on this iPhone: "), notice)

        actions.retrySave()
        XCTAssertNotNil(actions.saveFailure, "still blocked")
        try FileManager.default.removeItem(at: blocked)
        actions.retrySave()
        XCTAssertNil(actions.saveFailure)
        XCTAssertTrue(store.unsaved.isEmpty)
        XCTAssertTrue(keys.unsaved.isEmpty)
        XCTAssertEqual(HostStore(url: store.url).hosts.map(\.name), ["studio"])
        XCTAssertEqual(KeyStore(url: keys.url, vault: MemoryVault(), keyProtection: .none, secureEnclaveAvailable: false)
            .keys.map(\.label), ["phone"])
    }

    func testHostsRoundTripThroughThePrivateFile() throws {
        let url = directory.appendingPathComponent("hosts.json")
        let store = HostStore(url: url)
        var studio = host("studio", auth: .key(UUID()))
        studio.port = 2222
        studio.multiplexer = .tmux
        studio.lastConnected = Date(timeIntervalSince1970: 1_800_000_000)
        studio.system = HostSystem(os: "Linux", distribution: "ubuntu", name: "Ubuntu 24.04.1 LTS")
        studio.osLabel = "Ubuntu 24.04"
        store.add(studio)
        store.add(host("ai"))
        XCTAssertEqual(store.hosts.map(\.order), [0, 1])

        let reloaded = HostStore(url: url)
        XCTAssertEqual(reloaded.hosts, store.hosts)
        XCTAssertEqual(reloaded.hosts.first?.port, 2222)
        XCTAssertEqual(reloaded.hosts.first?.tintSeed, studio.id.uuidString)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testUpdateRemoveAndReorder() {
        let store = HostStore(url: directory.appendingPathComponent("hosts.json"))
        let a = host("a"), b = host("b"), c = host("c")
        [a, b, c].forEach(store.add)
        store.move(fromOffsets: [2], toOffset: 0)
        XCTAssertEqual(store.hosts.map(\.name), ["c", "a", "b"])
        XCTAssertEqual(store.hosts.map(\.order), [0, 1, 2])
        store.move(fromOffsets: [0], toOffset: 3)
        XCTAssertEqual(store.hosts.map(\.name), ["a", "b", "c"])

        var renamed = b
        renamed.name = "bee"
        renamed.order = 99
        store.update(renamed)
        XCTAssertEqual(store.hosts.map(\.name), ["a", "bee", "c"], "An update keeps the host's place")
        store.remove(a.id)
        XCTAssertEqual(store.hosts.map(\.name), ["bee", "c"])
        XCTAssertEqual(store.hosts.map(\.order), [0, 1])
        XCTAssertEqual(HostStore(url: store.url).hosts.map(\.name), ["bee", "c"])
    }

    /// A file from another version, or a damaged one, starts empty rather than failing.
    func testUnreadableFileStartsEmpty() throws {
        let url = directory.appendingPathComponent("hosts.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"version": 2, "hosts": []}"#.utf8).write(to: url)
        XCTAssertEqual(HostStore(url: url).hosts, [])
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(HostStore(url: url).hosts, [])
    }

    func testKnownHostsVerifyMatchUnknownAndMismatch() {
        let url = directory.appendingPathComponent("known_hosts.json")
        let store = KnownHostStore(url: url)
        let key = SSHKeyEncoding.string("ssh-ed25519") + SSHKeyEncoding.string(Array(repeating: UInt8(7), count: 32))
        let other = SSHKeyEncoding.string("ssh-ed25519") + SSHKeyEncoding.string(Array(repeating: UInt8(8), count: 32))
        XCTAssertEqual(store.verify(host: "Studio.local", port: 22, algorithm: "ssh-ed25519", key: key), .unknown)

        let seen = Date(timeIntervalSince1970: 1_800_000_000)
        store.trust(host: "Studio.local", port: 22, algorithm: "ssh-ed25519", key: key, at: seen)
        XCTAssertEqual(store.verify(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: key), .match,
                       "Host names compare without case")
        XCTAssertEqual(store.verify(host: "studio.local", port: 2222, algorithm: "ssh-ed25519", key: key), .unknown,
                       "Another port is another host")
        let trusted = KnownHostStore.Entry(algorithm: "ssh-ed25519", key: key, firstSeen: seen)
        XCTAssertEqual(store.verify(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: other), .mismatch(trusted))
        XCTAssertEqual(store.verify(host: "studio.local", port: 22, algorithm: "ecdsa-sha2-nistp256", key: key),
                       .mismatch(trusted), "Another algorithm is a mismatch, not a new key")

        let reloaded = KnownHostStore(url: url)
        XCTAssertEqual(reloaded.verify(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: key), .match)
        XCTAssertEqual(reloaded.entry(host: "studio.local", port: 22)?.firstSeen, seen)
        reloaded.forget(host: "STUDIO.local", port: 22)
        XCTAssertEqual(KnownHostStore(url: url).verify(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: key),
                       .unknown)
    }

    /// An unreadable or other-version `known_hosts.json` fails closed: nothing is trusted, asked about or written, and the
    /// file stays where it is until the user chooses Retry (read again) or Reset (set it aside, start empty).
    func testUnreadableKnownHostsFailClosedUntilRetryOrReset() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("known_hosts.json")
        let other = Data(#"{"version":2,"hosts":{}}"#.utf8)
        try other.write(to: url)
        let key = Data([1, 2, 3])
        let store = KnownHostStore(url: url)
        XCTAssertTrue(store.unreadable)
        XCTAssertEqual(store.verify(host: "studio", port: 22, algorithm: "ssh-ed25519", key: key), .unavailable,
                       "not unknown: an empty list would ask about every host as on first use")
        store.trust(host: "studio", port: 22, algorithm: "ssh-ed25519", key: key)
        store.forget(host: "studio", port: 22)
        XCTAssertEqual(try Data(contentsOf: url), other, "never written over")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["known_hosts.json"],
                       "not moved aside silently")

        XCTAssertFalse(store.retryRead(), "still unreadable")
        try FileManager.default.removeItem(at: url)
        let readable = KnownHostStore(url: url)
        readable.trust(host: "studio", port: 22, algorithm: "ssh-ed25519", key: key)
        XCTAssertTrue(store.retryRead(), "Retry reads it once it is readable")
        XCTAssertEqual(store.verify(host: "studio", port: 22, algorithm: "ssh-ed25519", key: key), .match)

        try other.write(to: url)
        let damaged = KnownHostStore(url: url)
        damaged.reset()
        XCTAssertFalse(damaged.unreadable)
        XCTAssertEqual(damaged.verify(host: "studio", port: 22, algorithm: "ssh-ed25519", key: key), .unknown)
        let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("known_hosts.json.unreadable-") }
        XCTAssertEqual(aside.count, 1, "Reset keeps the file aside")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testKnownHostNamesFollowOpenSSH() {
        XCTAssertEqual(KnownHostStore.key(host: "Studio", port: 22), "studio")
        XCTAssertEqual(KnownHostStore.key(host: "studio", port: 2222), "[studio]:2222")
        XCTAssertEqual(KnownHostStore.key(host: "fd00::1", port: 22), "[fd00::1]:22")
    }
}
