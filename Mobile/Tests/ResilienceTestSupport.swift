import Foundation
import Synchronization
import XCTest
@testable import DispatchMobile

/// A host session driver whose ready connection is a `ScriptedHelper`'s client, recording the context of every run
/// (the grant, the preferences stream) for the Resilience and Settings tests.
final class ClientDriver: HostSessionDriver {
    private let helper: @Sendable (HostRecord) -> ScriptedHelper
    private let hello: HelperSession.Info
    private let topology: HelperTopology?
    private let state = Mutex<(runs: Int, launches: [HelperLaunch], preferences: [HostRecord.MultiplexerPreference])>((0, [], []))

    init(hello: HelperSession.Info = ResilienceFixture.hello(), topology: HelperTopology? = HostFixture.topology(),
         helper: @escaping @Sendable (HostRecord) -> ScriptedHelper) {
        self.helper = helper
        self.hello = hello
        self.topology = topology
    }

    var runs: Int { state.withLock { $0.runs } }
    var launches: [HelperLaunch] { state.withLock { $0.launches } }
    var preferences: [HostRecord.MultiplexerPreference] { state.withLock { $0.preferences } }

    func run(_ host: HostRecord, context: HostSessionContext) -> AsyncStream<HostSessionEvent> {
        state.withLock { $0.runs += 1; $0.launches.append(context.launch) }
        let (stream, continuation) = AsyncStream<HostSessionEvent>.makeStream()
        let helper = helper(host), hello = hello, topology = topology
        let task = Task {
            let watching = Task {
                for await value in context.preferences { self.state.withLock { $0.preferences.append(value) } }
            }
            defer { watching.cancel() }
            continuation.yield(.link(.connecting))
            continuation.yield(.ready(client: helper.client, hello: hello, multiplexers: HostFixture.multiplexers(["tmux"]),
                                      versions: ["tmux": "3.7"], topology: topology))
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            withExtendedLifetime(helper) {}
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

enum ResilienceFixture {
    /// A hello that accepted these features, with this account home (and login HOME).
    static func hello(features: [String] = ["chat.list"], home: String = "/Users/alex", loginHome: String? = nil) -> HelperSession.Info {
        var account: [String: Any] = ["uid": 501, "home": home]
        if let loginHome { account["login_home"] = loginHome }
        let object: [String: Any] = [
            "version": HelperBinary.version, "os": "macos", "arch": "aarch64", "plugins": ["files", "stats"],
            "unavailable_harnesses": [String](), "ops": ["hello", "chat.list"], "frame_limit": 12_000_013, "chunk_kind": 5,
            "chunk_limit": 65_536, "account": account, "features": features,
            "identity": ["host": "00000000-0000-0000-0000-000000000001", "boot": "00000000-0000-0000-0000-000000000002",
                         "hostname": "studio", "os": "Darwin", "distribution": NSNull(), "os_name": NSNull(),
                         "os_label": "macOS 26.1", "os_version": "26.1"] as [String: Any],
        ]
        return try! JSONDecoder().decode(HelperSession.Info.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// `HostFixture.topology()` under another backend id, as a reconnect's helper reports the same server.
    static func topology(backend: Int) -> HelperTopology {
        let data = try! JSONEncoder().encode(HostFixture.topology())
        var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["backend"] = backend
        return try! JSONDecoder().decode(HelperTopology.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// The fixture topology's agent-bound terminals: "tmux:fixture:5" in docs, "tmux:fixture:10" in billing.
    static let docsAgent = "tmux:fixture:5", billingAgent = "tmux:fixture:10"

    static func host(_ name: String, chat: Bool = true, order: Int = 0) -> HostRecord {
        HostRecord(name: name, address: name + ".local", user: "alex", auth: .password, chat: chat, order: order, tintSeed: name)
    }

    @MainActor
    static func sessions(_ records: [HostRecord], driver: any HostSessionDriver = ScriptedHostSessionDriver(),
                         active: Bool = true, vault: MemoryVault = MemoryVault(),
                         knownHosts: KnownHostStore = KnownHostStore(url: nil)) -> HostSessions {
        HostSessions(store: HostStore(url: nil, hosts: records),
                     keys: KeyStore(url: nil, vault: vault, keyProtection: .none, secureEnclaveAvailable: false),
                     knownHosts: knownHosts, driver: driver, active: active)
    }

    @MainActor
    static func composition(_ hosts: HostSessions, cache: HostCache = HostCache(url: nil),
                            markers: ChatMarkers = ChatMarkers(store: ChatMarkerMemoryStore()),
                            outbox: ChatOutbox = ChatOutbox(store: ChatOutboxMemoryStore()),
                            drafts: ChatDraftRepository = ChatDraftRepository(store: ChatDraftMemoryStore()),
                            settings: MobileSettings? = nil, modelMemory: ChatModelMemory = ChatModelMemory(url: nil),
                            tabs: MobileTabs? = nil) -> MobileComposition {
        let defaults = UserDefaults(suiteName: "resilience-\(UUID().uuidString)")!
        return MobileComposition(hosts: hosts, tabs: tabs ?? MobileTabs(activity: TabActivityStore(url: nil), defaults: defaults),
                                 presences: TerminalPresences(), markers: markers, outbox: outbox, drafts: drafts,
                                 cache: cache, settings: settings ?? MobileSettings(defaults: defaults), modelMemory: modelMemory)
    }

    /// A cache entry for a host as the app last saw it: the fixture's hello, tmux, the topology and two rows.
    static func entry(saved: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> HostCacheEntry {
        var entry = HostCacheEntry(saved: saved)
        entry.hello = hello()
        entry.multiplexers = HostFixture.multiplexers(["tmux"]).map(HostCacheEntry.Multiplexer.init)
        entry.versions = ["tmux": "3.7"]
        entry.following = "tmux"
        entry.topology = HostFixture.topology()
        entry.conversations = [
            docsAgent: .init(ChatConversationSummary(preview: "Docs are rebuilt.", finished: true,
                                                     lastActivity: Date(timeIntervalSince1970: 1_800_000_100))),
            billingAgent: .init(ChatConversationSummary(attention: "approval", preview: "Run the migration?",
                                                        lastActivity: Date(timeIntervalSince1970: 1_800_000_050))),
        ]
        return entry
    }
}

/// Values appended from any task, read in the test.
final class Recorder<Value: Sendable>: Sendable {
    private let storage = Mutex<[Value]>([])
    func append(_ value: Value) { storage.withLock { $0.append(value) } }
    var values: [Value] { storage.withLock { $0 } }
}
