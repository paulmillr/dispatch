import Foundation
import Synchronization

/// A driver that plays a script: link changes, a host key to verify, a ready helper with fixture hello and topology,
/// latency, pauses. For previews, tests and the scripted demo (`DISPATCH_MOBILE_SCRIPTED=1`). Its `HelperClient` is
/// real but talks to a silent peer over pipes: requests wait until the session disconnects.
final class ScriptedHostSessionDriver: HostSessionDriver {
    enum Step: Sendable {
        case event(HostSessionEvent)
        /// Offers the key through `verifyHostKey`; a refusal ends the run with `.failed`.
        case hostKey(HostKeyOffer)
        /// `.ready` with a scripted client and these fixtures.
        case ready(hello: HelperSession.Info, multiplexers: [HelperClient.Multiplexer], versions: [String: String],
                   topology: HelperTopology?)
        case sleep(Duration)
        /// Waits for `HostSession.retryNow()`.
        case awaitRetry
        /// Stays connected until cancelled; the default end of a script.
        case hold
    }

    private let script: @Sendable (HostRecord) -> [Step]
    private let state = Mutex<(runs: [UUID: Int], refused: [UUID: Int])>(([:], [:]))

    init(script: @escaping @Sendable (HostRecord) -> [Step] = { ScriptedHostSessionDriver.connects($0) }) {
        self.script = script
    }

    /// How many times each host was run, and how many runs ended on a refused host key.
    func runs(_ host: UUID) -> Int { state.withLock { $0.runs[host] ?? 0 } }
    func refusals(_ host: UUID) -> Int { state.withLock { $0.refused[host] ?? 0 } }

    func run(_ host: HostRecord, context: HostSessionContext) -> AsyncStream<HostSessionEvent> {
        state.withLock { $0.runs[host.id, default: 0] += 1 }
        let steps = script(host)
        let (stream, continuation) = AsyncStream<HostSessionEvent>.makeStream()
        let task = Task {
            var peers: [Pipe] = []
            defer { withExtendedLifetime(peers) {} }
            var retries = context.retries.makeAsyncIterator()
            for step in steps {
                if Task.isCancelled { break }
                switch step {
                case .event(let event):
                    continuation.yield(event)
                case .hostKey(let offer):
                    guard await context.verifyHostKey(offer) else {
                        self.state.withLock { $0.refused[host.id, default: 0] += 1 }
                        continuation.yield(.link(.failed("The host key wasn't trusted.")))
                        continuation.finish()
                        return
                    }
                case .ready(let hello, let multiplexers, let versions, let topology):
                    let incoming = Pipe(), outgoing = Pipe()
                    peers += [incoming, outgoing]
                    let client = HelperClient(HelperConnection(read: incoming.fileHandleForReading,
                                                               write: outgoing.fileHandleForWriting))
                    continuation.yield(.ready(client: client, hello: hello, multiplexers: multiplexers,
                                              versions: versions, topology: topology))
                case .sleep(let duration):
                    try? await Task.sleep(for: duration)
                case .awaitRetry:
                    _ = await retries.next()
                case .hold:
                    while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Connecting, authenticating, starting the helper, then ready as a Mac with tmux and two spaces. Timed as the
    /// helper spike measured over loopback ssh (docs/ios-helper-spike.md): about 90 ms to `hello` (71 to 113), a
    /// 0.16 ms ping; pass a network's latency for hosts elsewhere.
    @Sendable static func connects(_ host: HostRecord) -> [Step] { connects(host, latency: .microseconds(160)) }

    static func connects(_ host: HostRecord, latency: Duration) -> [Step] {
        [.event(.link(.connecting)), .sleep(.milliseconds(30)), .event(.link(.authenticating)), .sleep(.milliseconds(25)),
         .event(.link(.bootstrapping)), .sleep(.milliseconds(35)),
         .ready(hello: HostFixture.hello(), multiplexers: HostFixture.multiplexers(["tmux"]), versions: ["tmux": "3.7"],
                topology: HostFixture.topology()),
         .event(.latency(latency)), .hold]
    }
}

/// Helper records for the scripted driver, decoded the way the helper's are.
enum HostFixture {
    /// A `hello` from a host with this identity and OS.
    static func hello(identity: String = "00000000-0000-0000-0000-000000000001", hostname: String = "studio",
                      os: String = "Darwin", distribution: String? = nil, osName: String? = nil,
                      label: String? = "macOS 26.1", version: String? = "26.1",
                      home: String = "/Users/alex") -> HelperSession.Info {
        decode([
            "version": HelperBinary.version, "os": os == "Darwin" ? "macos" : "linux", "arch": "aarch64",
            "plugins": ["files", "stats"], "unavailable_harnesses": [String](), "ops": ["hello"],
            "frame_limit": 12_000_013, "chunk_kind": 5, "chunk_limit": 65_536,
            "account": ["uid": 501, "home": home] as [String: Any],
            "identity": identityFields(identity, hostname: hostname, os: os, distribution: distribution, osName: osName,
                                       label: label, version: version),
        ])
    }

    private static func identityFields(_ host: String, hostname: String, os: String, distribution: String?, osName: String?,
                                       label: String?, version: String?) -> [String: Any] {
        var fields: [String: Any] = ["host": host, "boot": "00000000-0000-0000-0000-000000000002",
                                     "hostname": hostname, "os": os,
                                     "distribution": distribution.map { $0 as Any } ?? NSNull(),
                                     "os_name": osName.map { $0 as Any } ?? NSNull()]
        // Newer helpers (host.identity, docs/ios-helper-spike.md): "macOS 26.1" or "Ubuntu 24.04", and the version.
        if let label { fields["os_label"] = label }
        if let version { fields["os_version"] = version }
        return fields
    }

    /// `multiplexers.list` entries for these names.
    static func multiplexers(_ names: [String]) -> [HelperClient.Multiplexer] {
        names.enumerated().map { index, name in
            decode(["mux": index + 1, "name": name, "external": true, "claimed": true])
        }
    }

    struct Space {
        var name: String
        var cwd: String
        var tabs: Int
        var agents: Int
    }

    /// A topology with these spaces: each a workspace with `tabs` tabs of one terminal, the first `agents` of them
    /// running an agent.
    static func topology(_ spaces: [Space] = [Space(name: "docs", cwd: "/Users/alex/src/docs", tabs: 2, agents: 1),
                                              Space(name: "billing", cwd: "/Users/alex/src/api", tabs: 1, agents: 1)]
    ) -> HelperTopology {
        var nodes: [[String: Any]] = [], layouts: [[String: Any]] = []
        var next = 3
        func id() -> Int { defer { next += 1 }; return next }
        for space in spaces {
            let workspace = id()
            nodes.append(["id": workspace, "parent": NSNull(), "key": "tmux:fixture:\(workspace)", "kind": "workspace",
                          "name": space.name, "cwd": NSNull(), "size": NSNull(), "agent": NSNull(), "tty": NSNull(),
                          "detached": false])
            for index in 0..<space.tabs {
                let tab = id(), terminal = id()
                nodes.append(["id": tab, "parent": workspace, "key": "tmux:fixture:\(tab)", "kind": "tab",
                              "name": "zsh", "cwd": NSNull(), "size": NSNull(), "agent": NSNull(), "tty": NSNull(),
                              "detached": false])
                let agent: Any = index < space.agents
                    ? ["session": "fixture-\(terminal)", "transcript": NSNull(), "pid": NSNull(), "start": NSNull(),
                       "executable": NSNull()] as [String: Any]
                    : NSNull()
                nodes.append(["id": terminal, "parent": tab, "key": "tmux:fixture:\(terminal)", "kind": "terminal",
                              "name": "terminal", "cwd": space.cwd, "size": ["columns": 80, "rows": 24],
                              "agent": agent, "tty": NSNull(), "detached": false])
                layouts.append(["container": tab, "full": ["terminal": terminal], "visible": ["terminal": terminal],
                                "focus": terminal])
            }
        }
        return decode(["backend": 2, "nodes": nodes, "layouts": layouts, "focus": NSNull()])
    }

    private static func decode<Value: Decodable>(_ object: [String: Any]) -> Value {
        // Fixtures are literals above: a failure is a programming error.
        try! JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
