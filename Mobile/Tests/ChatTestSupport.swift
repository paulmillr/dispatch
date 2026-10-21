import Foundation
import XCTest
@testable import DispatchMobile

/// The scripted helper of every iPhone test: the far end of two pipes (the pattern of
/// DispatchTests/HelperClient/HelperClientTests.swift). The code under test talks to it through the production
/// `HelperConnection`; the script answers each request (Foundation values in JSON shapes, or helper binary values) and
/// can publish notifications on any open subscription.
final class ScriptedHelper: @unchecked Sendable {
    struct Request: @unchecked Sendable {
        let id: UInt64
        let method: String
        let params: [String: Any]
        /// The frame's body as sent, for decoding the params into a Codable type.
        let body: Data
    }
    enum Reply {
        case result(Any)
        /// A result already in the helper's binary value form.
        case binary(HelperBinary.Value)
        case error(code: String, message: String)
        /// A subscription that stays open (`chat.open`); notifications follow through `notify`.
        case open
        /// Notifications on the request's id; the subscription stays open.
        case notify([(method: String, params: HelperBinary.Value)])

        static func value<T: Encodable>(_ value: T) -> Reply { .binary(try! HelperBinary.value(encoding: value)) }
        static var empty: Reply { .binary(.null) }
        static func failure(code: String, message: String) -> Reply { .error(code: code, message: message) }
        static func closed(_ closed: Bool, confirmation: Bool) -> Reply {
            .binary(.object(["closed": .bool(closed), "confirmation": .bool(confirmation)]))
        }
    }

    let client: HelperClient
    private let transport: HelperTransport
    private let lock = NSLock()
    private var decoder = HelperWire.Decoder()
    private var handler: (Request) -> Reply
    private var log: [Request] = []
    private var cancelled: Set<UInt64> = []

    /// `script` answers or returns nil, which leaves the request unanswered.
    static func scripted(_ script: @escaping @Sendable (Request) -> Reply?) -> ScriptedHelper {
        ScriptedHelper { script($0) ?? .open }
    }

    init(_ handler: @escaping (Request) -> Reply = { _ in .result(NSNull()) }) {
        let incoming = Pipe(), outgoing = Pipe()
        client = HelperClient(HelperConnection(read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting))
        transport = HelperTransport(read: outgoing.fileHandleForReading, write: incoming.fileHandleForWriting)
        self.handler = handler
        transport.start(receive: { [weak self] bytes in self?.receive(bytes) }, closed: { _ in })
    }

    deinit { close() }

    func script(_ handler: @escaping (Request) -> Reply) {
        lock.withLock { self.handler = handler }
    }

    var requests: [Request] { lock.withLock { log } }
    func requests(_ method: String) -> [Request] { requests.filter { $0.method == method } }
    var methods: [String] { requests.map(\.method) }
    func subscription(_ method: String) -> UInt64? { requests(method).last?.id }
    var cancellations: Set<UInt64> { lock.withLock { cancelled } }

    /// Waits until `count` requests of `method` arrived.
    func wait(for method: String, count: Int = 1, timeout: TimeInterval = 5) async throws -> [Request] {
        let deadline = Date().addingTimeInterval(timeout)
        while requests(method).count < count {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for \(count) \(method); got \(methods)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return requests(method)
    }

    /// A notification on subscription `id`.
    func notify(_ id: UInt64, _ method: String, _ params: Any) {
        notify(id, method, value: try! HelperBinary.value(params))
    }

    func notify(_ id: UInt64, _ method: String, value params: HelperBinary.Value) {
        let body = try! HelperBinary.encode(.object(["method": .string(method), "params": params]))
        transport.send(try! HelperWire.encode(.init(kind: .notify, id: id, body: body)))
    }

    /// Answers request `id` now (one the script left open).
    func reply(_ id: UInt64, _ reply: Reply) {
        switch reply {
        case .result(let value): respond(id, ["result": value])
        case .binary(let value): respond(id, value: .object(["result": value]))
        case .error(let code, let text): respond(id, ["error": ["code": code, "message": text]])
        case .open: break
        case .notify(let notes):
            for note in notes { notify(id, note.method, value: note.params) }
        }
    }

    /// The link drops: the client's pending requests and subscriptions fail.
    func close() {
        transport.close()
        client.connection.close()
    }

    private func receive(_ bytes: Data) {
        var messages: [HelperWire.Message] = []
        lock.withLock { try? decoder.feed(bytes) { messages.append($0) } }
        for message in messages {
            if message.kind == .cancel {
                _ = lock.withLock { cancelled.insert(message.id) }
                continue
            }
            guard message.kind == .request,
                  let object = HelperBinary.foundation(try! HelperBinary.decode(message.body)) as? [String: Any],
                  let method = object["method"] as? String else { continue }
            let request = Request(id: message.id, method: method, params: object["params"] as? [String: Any] ?? [:],
                                  body: message.body)
            let handler = lock.withLock { log.append(request); return self.handler }
            reply(message.id, handler(request))
        }
    }

    private func respond(_ id: UInt64, _ envelope: [String: Any]) {
        respond(id, value: try! HelperBinary.value(envelope))
    }

    private func respond(_ id: UInt64, value: HelperBinary.Value) {
        let body = try! HelperBinary.encode(value)
        transport.send(try! HelperWire.encode(.init(kind: .response, id: id, body: body)))
    }
}

/// The recorded `chat.page` replies of the real helper (Mobile/Tests/Fixtures/Chat/provenance.md).
enum ChatFixture {
    static func pages(_ name: String) throws -> [[String: Any]] {
        let url = System.checkout.appendingPathComponent("Mobile/Tests/Fixtures/Chat/\(name).json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
    }

    static func records(_ name: String) throws -> [[String: Any]] {
        try pages(name).flatMap { $0["records"] as! [[String: Any]] }
    }

    static func state(_ name: String) throws -> [String: Any] {
        try pages(name).first?["state"] as? [String: Any] ?? [:]
    }

    static let node = "tmux:s:$0:%7"

    nonisolated(unsafe) static let binding: [String: Any] = ["session": "00000000-0000-4000-8000-000000000201", "transcript": "/work/t.jsonl",
                                         "pid": 4242, "start": [946719000, 0], "executable": "/usr/local/bin/claude"]

    static var topologyBinding: HelperTopology.Binding {
        try! JSONDecoder().decode(HelperTopology.Binding.self, from: JSONSerialization.data(withJSONObject: binding))
    }

    /// The `chat.history` notification `chat.open` publishes (helper/core/src/dispatch/chat.rs `Chat`): first with
    /// `history_pending` and the state, then with the page.
    static func history(terminal: UInt64 = 7, session: String = "00000000-0000-4000-8000-000000000201", key: String = "claude",
                        records: [[String: Any]] = [], earlier: String? = nil, state: [String: Any]? = nil,
                        pending: Bool = false, binding: [String: Any] = binding) -> [String: Any] {
        var value: [String: Any] = [
            "terminal": terminal, "binding": binding, "session": session, "label": key == "claude" ? "Claude Code" : "Codex",
            "key": key, "commands": [], "native_queue": false, "state": state ?? NSNull(), "state_error": NSNull(),
            "records": records, "earlier": earlier ?? NSNull(), "history_error": NSNull(), "history_pending": pending,
            "capabilities": ["state", "history"]]
        if pending { value["records"] = [] }
        return value
    }

    static func state(busy: Bool, activity: String? = nil, attention: String? = nil, model: String = "fable-5.1",
                      effort: String = "high") -> [String: Any] {
        ["busy": busy, "activity": activity ?? NSNull(), "model": model, "model_label": NSNull(), "effort": effort,
         "usage": NSNull(), "goal": NSNull(), "draft": NSNull(), "attention": attention ?? NSNull(), "leaf": NSNull(),
         "dialog": NSNull(), "title": NSNull(), "version": NSNull(), "pending": false, "compacting": false,
         "service_tier": NSNull(), "mode": NSNull(), "agents": []]
    }

    /// A record in the helper's shape.
    static func record(_ id: String, _ kind: String, turn: String, text: String = "", time: Int64? = nil,
                       completed: Bool = true) -> [String: Any] {
        ["id": id, "turn": turn, "kind": kind, "text": text, "title": "", "output": "", "blocks": [], "completed": completed,
         "exit_code": NSNull(), "patch": NSNull(), "documents": [], "tool": NSNull(), "inline_reasoning": false,
         "time_ms": time ?? NSNull(), "position": NSNull()]
    }

    /// The approval Claude Code's PermissionRequest hook becomes (helper/harnesses/claude/src/hooks.rs), for the real
    /// hook input of DispatchTests/Fixtures/hooks-observed-0.153.2.json; `options` adds a session-scoped choice.
    static func approval(id: String = "approval-1", options: [String] = ["Allow", "Deny", "Terminal"]) -> [String: Any] {
        // The hook's text is "<tool>\n<input>" (hooks.rs `operation`).
        let operation = "Bash\n" + #"{"command":"printf 'DISPATCH_LOCAL_TOOL_OK\\n'","description":"Allow the local fixture to print its test marker?"}"#
        return ["id": id, "key": NSNull(), "approval": true, "blocking": true, "turn": NSNull(), "record": NSNull(),
                "questions": [["id": "approval", "header": "Bash", "text": operation, "secret": false, "multiple": false,
                               "custom": false, "options": options.map { ["id": $0, "label": $0, "detail": NSNull()] },
                               "blocks": [["kind": "code", "language": "json", "text": operation]]]]]
    }

    static func sent(written: Bool = true, mayHaveSent: Bool = false, reason: String? = nil) -> [String: Any] {
        ["written": written, "may_have_sent": mayHaveSent, "reason": reason ?? NSNull()]
    }

    static func queued(_ id: String, _ text: String, revision: UInt64 = 1, paused: String? = nil) -> [String: Any] {
        ["id": id, "mode": "prompt", "revision": revision, "preview": [["kind": "text", "text": text]], "editable": true,
         "editing": false, "paused": paused ?? NSNull(), "error": NSNull()]
    }
}

@MainActor
extension MobileChatSession {
    /// A session attached to `helper` for terminal 7, bound like the fixture.
    static func scripted(_ helper: ScriptedHelper, host: UUID = UUID(), outbox: ChatOutbox = ChatOutbox(store: ChatOutboxMemoryStore()),
                         drafts: ChatDraftRepository = ChatDraftRepository(store: ChatDraftMemoryStore()),
                         presence: (any ChatTerminalPresence)? = nil, connected: Bool = true) -> MobileChatSession {
        let session = MobileChatSession(key: ChatConversationKey(host: host, node: ChatFixture.node), hostName: "mba2",
                                        presence: presence, drafts: drafts, outbox: outbox)
        session.update(terminal: 7, binding: ChatFixture.topologyBinding)
        if connected { session.update(link: .connected, client: helper.client) }
        else { session.update(link: .reconnecting(attempt: 1, since: Date()), client: nil) }
        return session
    }
}
