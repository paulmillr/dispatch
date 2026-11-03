import XCTest

#if SWIFT_PACKAGE
@testable import DispatchHelperPolicy
#elseif os(iOS)
@testable import DispatchMobile
#else
@testable import DispatchApp
#endif

final class HelperPolicyTests: XCTestCase {
    /// A frozen grant snapshot makes an unintended authority increase visible when shared groups change.
    private let phoneCapabilities: Set<String> = [
        "agent.events", "agent.inspect", "agent.pi", "agent.pi.configure", "agent.queue", "agent.side", "agent.submit",
        "agent.version", "backend.register", "cancel", "events", "file.read", "file.text", "git.read", "herdr.rpc",
        "herdr.start", "herdr.terminal", "hooks.configure", "host.identity", "input.window", "shell.lifecycle", "stats.ping",
        "stats.processes", "stats.sample", "tmux.pane",
    ]

    func testPlatformGrantsKeepTheirExistingAuthority() {
        XCTAssertEqual(Set(HelperCapabilities.mobile()), phoneCapabilities)
        XCTAssertEqual(HelperCapabilities.mobile(), phoneCapabilities.sorted())
        XCTAssertEqual(HelperCapabilities.full(hooks: true), phoneCapabilities.union(["file.write"]))
        XCTAssertEqual(HelperCapabilities.full(hooks: false), phoneCapabilities.union(["file.write"])
            .subtracting(["hooks.configure", "agent.pi", "agent.pi.configure"]))
        XCTAssertEqual(HelperCapabilities.statistics,
                       ["host.identity", "shell.lifecycle", "cancel", "events", "input.window",
                        "stats.sample", "stats.ping", "stats.processes"])
        #if os(iOS) || SWIFT_PACKAGE
        XCTAssertEqual(HelperGrant.capabilities, phoneCapabilities.sorted())
        #else
        XCTAssertEqual(SSHIntegrationGrant(profile: .full, hooks: true).capabilities, phoneCapabilities.union(["file.write"]))
        XCTAssertEqual(SSHIntegrationGrant(profile: .statistics).capabilities, HelperCapabilities.statistics)
        XCTAssertTrue(SSHIntegrationGrant(profile: .ordinary, hooks: true).capabilities.isEmpty)
        #endif
    }

    func testPhoneSwitchesOnlyRemoveTheirDisclosedAuthority() {
        let chat: Set<String> = ["agent.events", "agent.inspect", "agent.pi", "agent.pi.configure", "agent.queue",
                                 "agent.side", "agent.submit", "agent.version", "hooks.configure"]
        for chatEnabled in [false, true] {
            for filesEnabled in [false, true] {
                var expected = phoneCapabilities
                if !chatEnabled { expected.subtract(chat) }
                if !filesEnabled { expected.remove("git.read") }
                let grant = HelperCapabilities.mobile(chat: chatEnabled, files: filesEnabled)
                XCTAssertEqual(grant, expected.sorted())
                XCTAssertFalse(grant.contains("file.write"))
                #if os(iOS) || SWIFT_PACKAGE
                XCTAssertEqual(HelperGrant.capabilities(chat: chatEnabled, files: filesEnabled), grant)
                #endif
            }
        }
    }

    func testLegacyFullGrantsKeepTheRecordedCapabilityOrder() throws {
        let deterministic = System.environment("SWIFT_DETERMINISTIC_HASHING") != nil
        try XCTSkipUnless(deterministic, "Set order is stable only with deterministic hashing, as app replays run.")
        // Existing host.reply journals compare these encoded arrays exactly, even though the grant is a Set.
        let cases: [(hooks: Bool, recorded: [String])] = [
            (false, ["cancel", "events", "herdr.rpc", "file.write", "stats.processes", "file.text", "agent.submit",
                     "agent.inspect", "herdr.terminal", "herdr.start", "agent.version", "agent.events", "agent.side",
                     "backend.register", "file.read", "input.window", "shell.lifecycle", "tmux.pane", "git.read",
                     "stats.ping", "host.identity", "agent.queue", "stats.sample"]),
            (true, ["agent.pi.configure", "herdr.start", "herdr.rpc", "herdr.terminal", "file.write", "stats.sample",
                    "agent.inspect", "stats.ping", "backend.register", "agent.side", "events", "file.text", "file.read",
                    "git.read", "host.identity", "agent.events", "hooks.configure", "shell.lifecycle", "agent.submit",
                    "agent.queue", "input.window", "agent.version", "tmux.pane", "stats.processes", "agent.pi", "cancel"]),
        ]
        for (hooks, recorded) in cases {
            let encoded = try JSONEncoder().encode(HelperCapabilities.full(hooks: hooks))
            XCTAssertEqual(try JSONDecoder().decode([String].self, from: encoded), recorded)
        }
    }

    func testHelloEncodesOnlyTheCallersFeaturesInTheirOrder() throws {
        let features = ["stdio.liveness", "screens.host", "custom.feature", "screens.host"]
        let data = try JSONEncoder().encode(HelperHello(features: features))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String]])
        XCTAssertEqual(fields, ["features": features])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(HelperHello(features: []))) as? [String: [String]],
                       ["features": []])
    }

    func testHelloRejectsTheVersionBeforeCheckingMissingTransportFields() throws {
        XCTAssertThrowsError(try HelperHello.Transport(version: 1, expectedVersion: 2, limit: nil, chunkKind: nil,
                                                      chunkLimit: nil, ops: [])) {
            XCTAssertEqual($0 as? HelperHello.Failure, .protocolVersion)
        }
        for missing in 0..<3 {
            XCTAssertThrowsError(try HelperHello.Transport(version: 2, expectedVersion: 2,
                                                          limit: missing == 0 ? nil : 1_048_576,
                                                          chunkKind: missing == 1 ? nil : 5,
                                                          chunkLimit: missing == 2 ? nil : 65_536, ops: [])) {
                XCTAssertEqual($0 as? HelperHello.Failure, .transportLimits)
            }
        }
    }

    func testHelloPassesTransportBoundsAndOperationsToTheConnectionUnchanged() throws {
        let ops = ["hello", "echo", "echo", "future.operation"]
        let transport = try HelperHello.Transport(version: 2, expectedVersion: 2, limit: 1_048_576,
                                                 chunkKind: 5, chunkLimit: 65_536, ops: ops)
        XCTAssertEqual(transport.limit, 1_048_576)
        XCTAssertEqual(transport.chunkKind, 5)
        XCTAssertEqual(transport.chunkLimit, 65_536)
        XCTAssertEqual(transport.ops, ops)
        // Validation of malformed bounds belongs to HelperConnection, retaining its transport failure type.
        let malformed = try HelperHello.Transport(version: 2, expectedVersion: 2, limit: 0,
                                                 chunkKind: 255, chunkLimit: 0, ops: [])
        XCTAssertEqual(malformed.limit, 0)
        XCTAssertEqual(malformed.chunkKind, 255)
        XCTAssertEqual(malformed.chunkLimit, 0)
    }

    func testMultiplexerRowsKeepUnknownAndReportedServerStateDistinct() throws {
        let json = #"[{"mux":1,"name":"tmux","external":true},{"mux":2,"name":"herdr","external":true,"program":"herdr","installed":true,"version":"0.9.3","running":false},{"mux":3,"name":"native","external":false,"installed":null,"running":null},{"mux":4,"name":"tmux","external":true,"version":"3.7a","paste_state":true,"running":true}]"#
        let rows = try JSONDecoder().decode([HelperMultiplexer].self, from: Data(json.utf8))
        XCTAssertEqual(rows.map(\.running), [nil, false, nil, true])
        XCTAssertEqual(rows.map(\.installed), [nil, true, nil, nil])
        XCTAssertEqual(rows.map(\.paste_state), [nil, nil, nil, true])
        XCTAssertEqual(rows[0], HelperMultiplexer(mux: 1, name: "tmux", external: true))
        XCTAssertEqual(rows[1].program, "herdr")
        XCTAssertEqual(rows[3].version, "3.7a")
    }
}
