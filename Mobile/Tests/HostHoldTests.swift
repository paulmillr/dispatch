import XCTest
@testable import DispatchMobile

/// A watch request's hold on a host while the app is in the background (docs/watch.md, Background): the host's own
/// session connects quietly, stays for `holdLength` after the last hold, and the foreground takes over.
@MainActor
final class HostHoldTests: XCTestCase {
    private let studio = ResilienceFixture.host("studio")

    func testAHoldConnectsInTheBackgroundAndExpires() async throws {
        let driver = ScriptedHostSessionDriver()
        let hosts = ResilienceFixture.sessions([studio], driver: driver, active: false)
        hosts.holdLength = .milliseconds(300)
        let session = try XCTUnwrap(hosts.session(studio.id))
        XCTAssertEqual(session.link, .disconnected)
        await hosts.hold(studio.id)
        XCTAssertEqual(session.link, .connected, "returns once connected")
        XCTAssertTrue(hosts.isHeld(studio.id))
        XCTAssertNotNil(session.client, "the app's own session: Chat sees its client")
        // Another request extends the hold without a second connection.
        await hosts.hold(studio.id)
        XCTAssertEqual(driver.runs(studio.id), 1)
        try await TestSupport.eventually { session.link == .disconnected }
        XCTAssertFalse(hosts.isHeld(studio.id))
    }

    /// Coming to the foreground clears every hold (the host stays, interactive); going back disconnects as before.
    func testTheForegroundTakesOverAHold() async throws {
        let hosts = ResilienceFixture.sessions([studio], active: false)
        hosts.holdLength = .milliseconds(200)
        let session = try XCTUnwrap(hosts.session(studio.id))
        await hosts.hold(studio.id)
        hosts.setActive(true)
        XCTAssertFalse(hosts.isHeld(studio.id))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(session.link, .connected, "no expiry in the foreground")
        await hosts.hold(studio.id)
        XCTAssertFalse(hosts.isHeld(studio.id), "the foreground's sessions need no hold")
        hosts.setActive(false)
        XCTAssertEqual(session.link, .disconnected)
    }

    /// A quiet attempt asks nothing: an unknown host key fails it with no sheet, and Spaces' sheet asks once the app is
    /// in the foreground.
    func testAHoldNeverAsksAboutAHostKey() async throws {
        let offer = HostKeyOffer(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: Data([1, 2, 3]))
        let driver = ScriptedHostSessionDriver { host in [.hostKey(offer)] + ScriptedHostSessionDriver.connects(host) }
        let hosts = ResilienceFixture.sessions([studio], driver: driver, active: false)
        let session = try XCTUnwrap(hosts.session(studio.id))
        await hosts.hold(studio.id)
        XCTAssertEqual(session.link, .failed("The host key wasn't trusted."))
        XCTAssertTrue(hosts.trustRequests.isEmpty)
        XCTAssertEqual(hosts.quietRefusals[studio.id], .hostKey)
        let app = ResilienceFixture.composition(hosts)
        XCTAssertEqual(WatchSnapshotBuilder(composition: app).build().hosts.first?.blocked, .trustHostKey)

        // The refused run ends (its events finish) just after the failure; a later foreground starts a new one.
        try await Task.sleep(for: .milliseconds(100))
        hosts.setActive(true)
        XCTAssertNil(hosts.quietRefusals[studio.id])
        try await TestSupport.eventually { hosts.trustRequests.count == 1 }
    }

    /// In the foreground a host key sheet waits for the user: the hold returns at once (the watch is told to open the
    /// phone) instead of after its budget, and the sheet stays.
    func testAHoldReturnsWhileASheetAsks() async throws {
        let offer = HostKeyOffer(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: Data([1, 2, 3]))
        let driver = ScriptedHostSessionDriver { host in [.hostKey(offer)] + ScriptedHostSessionDriver.connects(host) }
        let hosts = ResilienceFixture.sessions([studio], driver: driver, active: true)
        hosts.holdBudget = .seconds(5)
        try await TestSupport.eventually { hosts.trustRequests.count == 1 }
        let started = ContinuousClock.now
        await hosts.hold(studio.id)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        XCTAssertEqual(hosts.trustRequests.count, 1)
        let app = ResilienceFixture.composition(hosts)
        XCTAssertEqual(WatchSnapshotBuilder(composition: app).build().hosts.first?.blocked, .trustHostKey)
    }

    /// A key behind Face ID fails a quiet attempt at once (no prompt is tried); the foreground reads it.
    func testAHoldNeverPromptsForFaceID() async throws {
        let keys = KeyStore(url: nil, vault: MemoryVault(), keyProtection: .biometry, secureEnclaveAvailable: false)
        let key = try keys.generateED25519(label: "phone")
        var record = studio
        record.auth = .key(key.id)
        struct KeyReader: HostSessionDriver {
            func run(_ host: HostRecord, context: HostSessionContext) -> AsyncStream<HostSessionEvent> {
                AsyncStream { continuation in
                    Task {
                        do {
                            let material = try await context.key()
                            continuation.yield(.link(.failed(material == nil ? "none" : "read")))
                        } catch {
                            continuation.yield(.link(.failed(error.localizedDescription)))
                        }
                        continuation.finish()
                    }
                }
            }
        }
        let hosts = HostSessions(store: HostStore(url: nil, hosts: [record]), keys: keys, knownHosts: KnownHostStore(url: nil),
                                 driver: KeyReader(), active: false)
        let session = try XCTUnwrap(hosts.session(record.id))
        await hosts.hold(record.id)
        XCTAssertEqual(session.link, .failed(SecretVaultError.interactionNotAllowed.localizedDescription))
        XCTAssertEqual(hosts.quietRefusals[record.id], .faceID)
        try await Task.sleep(for: .milliseconds(100))
        hosts.setActive(true)
        try await TestSupport.eventually { session.link == .failed("read") }
    }

    /// Locked, a password still reads (after first unlock) and its host logs in; a key behind Face ID (when unlocked
    /// only) refuses the quiet read, as in the background.
    func testALockedPhoneHoldsAPasswordHostButNotAFaceIDOne() async throws {
        let vault = MemoryVault()
        let keys = KeyStore(url: nil, vault: vault, keyProtection: .biometry, secureEnclaveAvailable: false)
        var pi = ResilienceFixture.host("pi", order: 1)
        pi.auth = .key(try keys.generateED25519(label: "phone").id)
        try keys.setPassword("hunter2", for: studio.id)
        vault.locked = true
        /// Reads the host's secret as the SSH driver does and reports what it got.
        struct SecretReader: HostSessionDriver {
            func run(_ host: HostRecord, context: HostSessionContext) -> AsyncStream<HostSessionEvent> {
                AsyncStream { continuation in
                    Task {
                        do {
                            if case .key = host.auth {
                                let material = try await context.key()
                                continuation.yield(.link(.failed(material == nil ? "none" : "key")))
                            } else {
                                continuation.yield(.link(.failed(try await context.password() ?? "none")))
                            }
                        } catch {
                            continuation.yield(.link(.failed(error.localizedDescription)))
                        }
                        continuation.finish()
                    }
                }
            }
        }
        let hosts = HostSessions(store: HostStore(url: nil, hosts: [studio, pi]), keys: keys, knownHosts: KnownHostStore(url: nil),
                                 driver: SecretReader(), active: false)
        await hosts.hold(studio.id)
        await hosts.hold(pi.id)
        XCTAssertEqual(hosts.session(studio.id)?.link, .failed("hunter2"), "the password host was attempted with its password")
        XCTAssertNil(hosts.quietRefusals[studio.id])
        XCTAssertEqual(hosts.session(pi.id)?.link, .failed(SecretVaultError.interactionNotAllowed.localizedDescription))
        XCTAssertEqual(hosts.quietRefusals[pi.id], .faceID)
        let app = ResilienceFixture.composition(hosts)
        XCTAssertEqual(WatchSnapshotBuilder(composition: app, protectedDataAvailable: false).build().hosts.map(\.blocked),
                       [nil, .faceID])
    }
}
