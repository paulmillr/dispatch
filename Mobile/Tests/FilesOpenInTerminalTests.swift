import Foundation
import XCTest
@testable import DispatchMobile

/// Open in Terminal through the composition (`MobileComposition.filesOpenInTerminal`): offered for a tmux shell tab,
/// not for herdr; the pane's presence opened through the current connection and held while it types; Terminal shown and
/// the Files screens taken off only after the helper took the input; nothing typed once the preview is gone.
@MainActor
final class FilesOpenInTerminalTests: XCTestCase {
    private func composition(_ helper: ScriptedHelper, multiplexer: String = "tmux") -> (MobileComposition, HostRecord) {
        let record = HostRecord(name: "studio", address: "studio.local", user: "alex", auth: .password, order: 0, tintSeed: "studio")
        let client = helper.client
        let driver = ScriptedHostSessionDriver { host in
            [.event(.link(.connecting)), .event(.following(multiplexer)),
             .readyWith(client: { client }, hello: HostFixture.hello(identity: host.tintSeed),
                        multiplexers: HostFixture.multiplexers([multiplexer]), versions: [multiplexer: "1.0"],
                        topology: HostFixture.topology()),
             .hold]
        }
        let hosts = HostSessions(store: HostStore(url: nil, hosts: [record]),
                                 keys: KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none, secureEnclaveAvailable: false),
                                 knownHosts: KnownHostStore(url: nil), driver: driver, active: true)
        let defaults = UserDefaults(suiteName: "files-open-\(UUID().uuidString)")!
        let app = MobileComposition(hosts: hosts, tabs: MobileTabs(activity: TabActivityStore(url: nil), defaults: defaults),
                                    presences: TerminalPresences(), markers: ChatMarkers(store: ChatMarkerMemoryStore()),
                                    outbox: ChatOutbox(store: ChatOutboxMemoryStore()),
                                    drafts: ChatDraftRepository(store: ChatDraftMemoryStore()))
        return (app, record)
    }

    /// The fixture's shell tab (zsh, no agent) once the host is connected and its topology live.
    private func shellTab(_ app: MobileComposition, _ record: HostRecord) async throws -> MobileTab {
        let session = try XCTUnwrap(app.hosts.session(record.id))
        try await TestSupport.eventually { session.link == .connected && session.topologyIsLive }
        try await TestSupport.eventually { app.tabs.workspace(record.id)?.tabs.contains { $0.atShell && $0.agentPane == nil } == true }
        return try XCTUnwrap(app.tabs.workspace(record.id)?.tabs.first { $0.atShell && $0.agentPane == nil })
    }

    private static func helper() -> ScriptedHelper {
        ScriptedHelper { request in request.method == "terminals.attach" ? .open : .empty }
    }

    func testTypesThenShowsTerminalAndLetsThePresenceGo() async throws {
        let helper = Self.helper()
        defer { helper.close() }
        let (app, record) = composition(helper)
        let tab = try await shellTab(app, record)
        let ref = tab.ref, pane = try XCTUnwrap(tab.activePane)
        let key = TerminalPresences.Key(host: ref.host, node: pane.key)
        app.navigator.path = [.tab(ref), .files(ref, .preview("/Users/alex/src/docs/README.md"))]
        var switched: TabSegment?
        let observer = NotificationCenter.default.addObserver(forName: TabSegment.switchRequested, object: nil, queue: nil) { note in
            if TabSegment.switchRequest(note) == ref { switched = TabSegment.switchTarget(note) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let open = try XCTUnwrap(app.filesOpenInTerminal(tab, folder: "/Users/alex/src/docs"))
        let typing = Task { await open() }
        let attach = try await helper.wait(for: "terminals.attach")[0]
        XCTAssertTrue(app.presences.inUse(key), "Held while it types")
        XCTAssertEqual(app.navigator.path.count, 2, "Nothing shown before the input was taken")
        XCTAssertTrue(helper.requests("terminals.input").isEmpty)
        helper.notify(attach.id, .output(.init(terminal: pane.id, bytes: Data("$ ".utf8))), method: "terminal.output")
        helper.notify(attach.id, .attached, method: "terminal.attached")
        let result = await typing.value
        XCTAssertNil(result)
        XCTAssertEqual(helper.requests("terminals.input").count, 1)
        XCTAssertEqual(switched, .terminal)
        XCTAssertEqual(app.navigator.path, [.tab(ref)])
        XCTAssertTrue(app.presences.inUse(key), "Kept for the Terminal segment to take over")
        try await TestSupport.eventually { !app.presences.inUse(key) }
    }

    /// The preview left (the stack no longer shows this tab's Files screen) before the screen came: nothing typed,
    /// nothing shown, the presence let go.
    func testNothingIsTypedOnceThePreviewIsGone() async throws {
        let helper = Self.helper()
        defer { helper.close() }
        let (app, record) = composition(helper)
        let tab = try await shellTab(app, record)
        let ref = tab.ref, pane = try XCTUnwrap(tab.activePane)
        let key = TerminalPresences.Key(host: ref.host, node: pane.key)
        app.navigator.path = [.tab(ref), .files(ref, .preview("/Users/alex/src/docs/README.md"))]
        let open = try XCTUnwrap(app.filesOpenInTerminal(tab, folder: "/Users/alex/src/docs"))
        let typing = Task { await open() }
        let attach = try await helper.wait(for: "terminals.attach")[0]
        app.navigator.path = [.tab(ref)]
        helper.notify(attach.id, .output(.init(terminal: pane.id, bytes: Data("$ ".utf8))), method: "terminal.output")
        helper.notify(attach.id, .attached, method: "terminal.attached")
        let result = await typing.value
        XCTAssertEqual(result, FilesTerminalTyping.busy)
        XCTAssertTrue(helper.requests("terminals.input").isEmpty)
        XCTAssertFalse(app.presences.inUse(key))
    }

    /// herdr's panes are not offered: their modes never reach the phone.
    func testNotOfferedOnHerdr() async throws {
        let helper = Self.helper()
        defer { helper.close() }
        let (app, record) = composition(helper, multiplexer: "herdr")
        let tab = try await shellTab(app, record)
        XCTAssertNil(app.filesOpenInTerminal(tab, folder: "/Users/alex/src/docs"))
    }
}
