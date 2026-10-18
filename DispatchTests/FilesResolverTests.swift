import Foundation
import XCTest
@testable import DispatchApp

/// Which host a tab's files come from (F2e): the decision table over the app's facts, and the one-source-per-
/// connection rule that keeps a reused terminal UUID away from an older connection's helper.
@MainActor
final class FilesResolverTests: XCTestCase {
    private typealias Facts = FilesResolver.Facts

    private let scope = SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "homelab",
                                            configuration: "hostname homelab.lan\nuser ivan\nport 22")

    func testDecisionTable() {
        let connection = SSHConnectionID(System.uuid())
        let dropped = Date(timeIntervalSince1970: 1_760_000_000), listed = Date(timeIntervalSince1970: 1_760_000_100)
        let granted = Facts.Link(grantsFiles: true, scope: scope, home: "/home/ivan")
        func decide(_ facts: Facts, lastRefresh: Date? = nil) -> FilesResolver.Decision {
            FilesResolver.decide(facts, lastRefresh: lastRefresh)
        }
        func ssh(_ change: (inout Facts) -> Void = { _ in }) -> Facts {
            var facts = Facts(machine: .ssh(destination: "homelab"), connection: connection, link: granted, host: "homelab",
                              state: .connected)
            change(&facts)
            return facts
        }

        XCTAssertEqual(decide(Facts(machine: .local, host: "")), .local)
        XCTAssertEqual(decide(Facts(machine: .none, host: "")), .unavailable("This tab has closed"))
        XCTAssertEqual(decide(ssh()), .remote(connection, home: "/home/ivan", host: "homelab"))
        XCTAssertEqual(decide(ssh { $0.link?.grantsWrite = false }), .remote(connection, home: "/home/ivan", host: "homelab", readOnly: true),
                       "Files without Copy files in lists read-only")
        XCTAssertEqual(decide(ssh { $0.link?.grantsFiles = false }), .notGranted(host: "homelab", scope: scope))
        XCTAssertEqual(decide(ssh { $0.link = nil; $0.connection = nil }), .plainSSH(host: "homelab"),
                       "No connection of the app's: the user's own ssh")
        XCTAssertEqual(decide(ssh { $0.link = nil; $0.state = .connecting }), .loading, "The helper is still starting")
        XCTAssertEqual(decide(ssh { $0.link = nil; $0.helperGone = true }),
                       .unavailable("The helper on homelab stopped. Files return with its next connection."))
        XCTAssertEqual(decide(ssh { $0.link = nil; $0.live = false }), .offline(host: "homelab", since: nil))

        // Offline wins over the grant: the last listing is shown dimmed, never as live.
        let reconnecting = ssh { $0.reconnecting = true; $0.disconnectedAt = dropped; $0.state = .connecting }
        XCTAssertEqual(decide(reconnecting), .offline(host: "homelab", since: dropped))
        XCTAssertEqual(decide(reconnecting, lastRefresh: listed), .offline(host: "homelab", since: listed),
                       "Offline is as old as the last live listing")
        XCTAssertEqual(decide(ssh { $0.state = .disconnected; $0.link = nil }, lastRefresh: listed),
                       .offline(host: "homelab", since: listed))
        XCTAssertEqual(decide(ssh { $0.machine = .ssh(destination: "homelab"); $0.connection = nil; $0.link = nil
            $0.reconnecting = true; $0.disconnectedAt = dropped }), .offline(host: "homelab", since: dropped))

        // A remote backend's pane: a local machine with its space's connection.
        XCTAssertEqual(decide(ssh { $0.machine = .local }), .remote(connection, home: "/home/ivan", host: "homelab"))
        XCTAssertEqual(decide(ssh { $0.machine = .local; $0.link = nil; $0.live = false }), .offline(host: "homelab", since: nil))
    }

    func testOneSourcePerConnection() throws {
        let resolver = FilesResolver()
        let first = SSHConnectionID(System.uuid()), second = SSHConnectionID(System.uuid())
        let a = resolver.source(for: first, home: "/home/ivan", host: "homelab")
        XCTAssertTrue(resolver.source(for: first, home: "/home/ivan", host: "homelab") === a)
        XCTAssertEqual(a.endpoint, .remote(first))
        XCTAssertEqual(a.home, "/home/ivan")
        XCTAssertEqual(a.hostLabel, "homelab")

        // The reconnected login is a new connection: a new source, even for the same terminal.
        let b = resolver.source(for: second, home: "/home/ivan", host: "homelab")
        XCTAssertFalse(a === b)
        XCTAssertEqual(b.endpoint, .remote(second))
        let available = try XCTUnwrap(resolver.availability(.remote(second, home: "/home/ivan", host: "homelab")).source)
        XCTAssertTrue(available === b)

        resolver.prune(keeping: [second])
        XCTAssertFalse(resolver.source(for: first, home: "/home/ivan", host: "homelab") === a, "An ended connection's source is gone")
        XCTAssertTrue(resolver.source(for: second, home: "/home/ivan", host: "homelab") === b)

        // Copy files in turned off while the connection lives: a read-only source from then on.
        let readOnly = try XCTUnwrap(resolver.availability(.remote(second, home: "/home/ivan", host: "homelab", readOnly: true)).source)
        XCTAssertFalse(readOnly === b)
        XCTAssertTrue(readOnly.readOnly)
        XCTAssertFalse(b.readOnly)
    }

    func testLocalTabsShareThisMacsSource() throws {
        let resolver = FilesResolver(), other = FilesResolver()
        let source = try XCTUnwrap(resolver.availability(.local).source)
        XCTAssertTrue(other.availability(.local).source === source)
        XCTAssertTrue(FilesSources.local() === source)
        XCTAssertEqual(source.endpoint, .local)
        XCTAssertEqual(source.home, System.home.path)
        XCTAssertNil(source.hostLabel)
    }

    func testOtherDecisionsCarryNoSource() {
        let resolver = FilesResolver()
        guard case .plainSSH(let host) = resolver.availability(.plainSSH(host: "nas")) else { return XCTFail() }
        XCTAssertEqual(host, "nas")
        guard case .notGranted(let granted, let scope) = resolver.availability(.notGranted(host: "nas", scope: scope)) else {
            return XCTFail()
        }
        XCTAssertEqual(granted, "nas")
        XCTAssertEqual(scope, self.scope)
        XCTAssertNil(resolver.availability(.offline(host: "nas", since: nil)).source)
        XCTAssertNil(resolver.availability(.loading).source)
        XCTAssertNil(resolver.availability(.unavailable("x")).source)
    }
}
