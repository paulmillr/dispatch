#if DEBUG
import Foundation
import Synchronization

/// One demo host's helper, in process (`DemoScenario`): answers the requests the app makes of a connected host with
/// the scenario's conversations and terminals, over the real wire codec. Chats: `chat.state`, `chat.page` and
/// `chat.open` (history, then the open approval or question); terminals: `terminals.attach` replays the recorded
/// screen, a live tab keeps appending lines, and typing echoes with a fresh prompt on Return. Anything that would
/// change a host answers "unavailable".
final class DemoHelper: @unchecked Sendable {
    let client: HelperClient
    private let transport: HelperTransport
    private let host: DemoScenario.Host
    private let terminals: [UInt64: DemoScenario.Content]
    private let lock = NSLock()
    private var decoder = HelperWire.Decoder()
    private var serial: UInt64 = 0
    private var attachments: [String: Data] = [:]
    private var live: [UInt64: Task<Void, Never>] = [:]
    private let launched = Date()

    /// Each host's current helper: the client alone does not keep its peer alive, and a freed peer closed the pipes
    /// ("Helper disconnected"). A reconnect replaces it.
    private static let current = Mutex<[UUID: DemoHelper]>([:])

    static func connect(_ host: DemoScenario.Host) -> HelperClient {
        let helper = DemoHelper(host: host)
        current.withLock { $0[host.record.id] = helper }
        return helper.client
    }

    init(host: DemoScenario.Host) {
        self.host = host
        terminals = host.terminals
        let incoming = Pipe(), outgoing = Pipe()
        client = HelperClient(HelperConnection(read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting))
        transport = HelperTransport(read: outgoing.fileHandleForReading, write: incoming.fileHandleForWriting)
        transport.start(receive: { [weak self] in self?.receive($0) }, closed: { [weak self] _ in self?.stopLive() })
    }

    deinit { stopLive() }

    private func stopLive() {
        lock.withLock {
            live.values.forEach { $0.cancel() }
            live.removeAll()
        }
    }

    private func receive(_ bytes: Data) {
        var messages: [HelperWire.Message] = []
        lock.withLock { try? decoder.feed(bytes) { messages.append($0) } }
        for message in messages where message.kind == .request {
            guard let value = try? HelperBinary.decode(message.body), case .object(let object) = value,
                  case .string(let method)? = object["method"] else { continue }
            let params = HelperBinary.foundation(object["params"] ?? .null) as? [String: Any] ?? [:]
            handle(message.id, method, params, raw: object["params"] ?? .null)
        }
    }

    // MARK: Requests

    private func handle(_ id: UInt64, _ method: String, _ params: [String: Any], raw: HelperBinary.Value) {
        let terminal = (params["terminal"] as? UInt64) ?? (params["terminal"] as? Int).map(UInt64.init) ?? 0
        switch method {
        case "chat.state":
            guard case .agent(_, let agent, let state, _)? = terminals[terminal] else { return fail(id, "No agent in this terminal") }
            respond(id, ["binding": binding(terminal, agent), "state": chatState(agent, state)])
        case "chat.page":
            guard case .agent? = terminals[terminal] else { return fail(id, "No agent in this terminal") }
            respond(id, ["records": records(terminal), "earlier": NSNull()])
        case "chat.open": open(id, terminal: terminal)
        case "terminals.attach": attach(id, terminal: terminal)
        case "terminals.observe": break  // A subscription: claims and exit, which the demo never has.
        case "terminals.input": input(id, raw: raw)
        case "terminals.resize", "terminals.scroll", "layouts.resize", "tabs.recent", "tabs.collapsed":
            respond(id, NSNull())
        case "queue.list": respond(id, [Any]())
        case "queue.add":
            serial += 1
            respond(id, ["id": "demo-\(serial)", "mode": "prompt", "revision": 1,
                         "preview": [["kind": "text", "text": params["text"] as? String ?? ""]], "editable": true,
                         "editing": false, "paused": NSNull(), "error": NSNull()])
        case "interactions.answer": respond(id, ["written": true, "may_have_sent": true, "reason": NSNull()])
        case "launches.list":
            respond(id, [["launch": 0, "key": "claude", "label": "Claude Code", "program": "claude"],
                         ["launch": 1, "key": "codex", "label": "Codex", "program": "codex"]])
        case "chat.models":
            let codex = terminals[terminal].map { if case .agent(_, .codex, _, _) = $0 { true } else { false } } ?? false
            let choices = codex ? ["astra-6", "astra-6-mini"] : ["fable-5.1", "sonnet-5"]
            respond(id, ["choices": choices.map { ["id": $0, "label": $0, "detail": NSNull()] }, "current": choices[0],
                         "default": NSNull()])
        case "chat.settings":
            respond(id, ["choices": ["low", "medium", "high"].map { ["id": $0, "label": $0, "detail": NSNull()] },
                         "current": "high", "default": NSNull()])
        case "projects.recent":
            let now = UInt64(Date().timeIntervalSince1970 * 1000)
            let home = host.hello.account?.home ?? "/Users/alex"
            respond(id, [("src/web", 2), ("src/api", 26), ("notes", 120)].map { path, hours in
                ["path": "\(home)/\(path)", "time_ms": now - UInt64(hours) * 3_600_000, "agents": ["claude"], "exists": true]
            })
        // Attachments (feature chat.attachments; the demo hosts do not name it): kept in memory, read back as stored.
        case "attachments.put":
            let name = params["name"] as? String ?? "attachment"
            let bytes = params["bytes"] as? Data ?? Data()
            serial += 1
            let path = (host.hello.account?.home ?? "/Users/alex") + "/.dispatch/attachments/" + String(format: "%032llx", serial) + "/" + name
            lock.withLock { attachments[path] = bytes }
            let image = ["png", "jpg", "jpeg", "gif", "webp"].contains((name as NSString).pathExtension.lowercased())
            respond(id, ["path": path, "name": name, "kind": image ? "image" : "file", "size": UInt64(bytes.count)])
        case "attachments.read":
            guard let bytes = lock.withLock({ attachments[params["path"] as? String ?? ""] }) else { return fail(id, "Gone") }
            respond(id, ["bytes": bytes, "size": UInt64(bytes.count)])
        default: fail(id, "This is a demo host")
        }
    }

    // MARK: Chats

    private func chat(_ terminal: UInt64) -> (name: String, agent: DemoScenario.Agent, state: DemoScenario.State, minutesAgo: Double)? {
        guard case .agent(let name, let agent, let state, let minutesAgo)? = terminals[terminal] else { return nil }
        return (name, agent, state, minutesAgo)
    }

    /// The chat's records, moved so the last lands `minutesAgo` before launch (the fixtures are dated 2000-01-01), and
    /// ages from there as a finished chat does. A working turn's start lands `started` seconds before this request
    /// instead: dated from launch, its thinking row read minutes a while into the demo rather than about 48 s.
    private func records(_ terminal: UInt64) -> [[String: Any]] {
        guard let chat = chat(terminal) else { return [] }
        let records = DemoScenario.records(chat.name)
        let times = records.compactMap { $0["time_ms"] as? Int64 }
        guard let last = times.max() else { return records }
        var shift = Int64(launched.timeIntervalSince1970 * 1000) - Int64(chat.minutesAgo * 60_000) - last
        if case .working(let started) = chat.state,
           let start = records.last(where: { $0["kind"] as? String == "turn_started" })?["time_ms"] as? Int64 {
            shift = Int64(Date().timeIntervalSince1970 * 1000) - Int64(started) * 1000 - start
        }
        return records.map { record in
            var record = record
            if let time = record["time_ms"] as? Int64 { record["time_ms"] = time + shift }
            return record
        }
    }

    private func binding(_ terminal: UInt64, _ agent: DemoScenario.Agent) -> [String: Any] {
        ["session": chat(terminal)?.name ?? "demo", "transcript": NSNull(), "pid": 4000 + Int(terminal), "start": [946_719_000, 0],
         "executable": agent.executable]
    }

    private func chatState(_ agent: DemoScenario.Agent, _ state: DemoScenario.State) -> [String: Any] {
        var fields: [String: Any] = [
            "busy": false, "activity": NSNull(), "model": agent.model, "model_label": NSNull(), "effort": "high", "usage": NSNull(),
            "goal": NSNull(), "draft": NSNull(), "attention": NSNull(), "leaf": NSNull(), "dialog": NSNull(), "title": NSNull(),
            "version": NSNull(), "pending": false, "compacting": false, "service_tier": NSNull(), "mode": NSNull(), "agents": [],
        ]
        switch state {
        case .working: fields["busy"] = true
        case .approval: fields["attention"] = "Waiting for approval"
        case .question: fields["attention"] = "Asked a question"
        case .finished, .idle: break
        }
        return fields
    }

    private func open(_ id: UInt64, terminal: UInt64) {
        guard let chat = chat(terminal) else { return fail(id, "No agent in this terminal") }
        let state = chatState(chat.agent, chat.state)
        func history(_ records: [[String: Any]], pending: Bool) -> [String: Any] {
            ["terminal": terminal, "binding": binding(terminal, chat.agent), "session": chat.name, "label": chat.agent.key,
             "key": chat.agent.key, "commands": [], "native_queue": false, "state": state, "state_error": NSNull(),
             "records": records, "earlier": NSNull(), "history_error": NSNull(), "history_pending": pending,
             "capabilities": ["state", "history"]]
        }
        notify(id, "chat.history", history([], pending: true))
        notify(id, "chat.history", history(records(terminal), pending: false))
        switch chat.state {
        case .approval(let command, let description):
            let operation = (try? String(data: JSONSerialization.data(withJSONObject: ["command": command, "description": description],
                                                                       options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)) ?? command
            interaction(id, terminal: terminal, session: chat.name, [
                "id": "approval-\(terminal)", "key": NSNull(), "approval": true, "blocking": true, "turn": NSNull(), "record": NSNull(),
                "questions": [["id": "approval", "header": "Bash", "text": operation, "secret": false, "multiple": false, "custom": false,
                               "options": ["Allow", "Deny", "Terminal", "Allow for this session"].map { ["id": $0, "label": $0, "detail": NSNull()] },
                               "blocks": [["kind": "code", "language": "json", "text": operation]]]]])
        case .question(let header, let text, let options):
            interaction(id, terminal: terminal, session: chat.name, [
                "id": "question-\(terminal)", "key": NSNull(), "approval": false, "blocking": true, "turn": NSNull(), "record": NSNull(),
                "questions": [["id": "choice", "header": header, "text": text, "secret": false, "multiple": false, "custom": true,
                               "options": options.map { ["id": $0.label, "label": $0.label, "detail": $0.detail] }, "blocks": []]]])
        case .working, .finished, .idle: break
        }
    }

    private func interaction(_ id: UInt64, terminal: UInt64, session: String, _ interaction: [String: Any]) {
        notify(id, "interaction.opened", ["terminal": terminal, "session": session, "interaction": interaction])
    }

    // MARK: Terminals

    private func shell(_ terminal: UInt64) -> (name: String, live: Bool)? {
        switch terminals[terminal] {
        case .shell(let name, let live)?: (name, live)
        case .agent(_, let agent, _, _)?: ("agent-\(agent.key)", false)
        case nil: nil
        }
    }

    private func attach(_ id: UInt64, terminal: UInt64) {
        notifyUpdate(id, "terminal.attached", .attached)
        guard let shell = shell(terminal) else { return }
        notifyUpdate(id, "terminal.output", .output(.init(terminal: terminal, bytes: DemoScenario.terminal(shell.name))))
        guard shell.live else { return }
        let lines = DemoScenario.liveLines(shell.name)
        guard !lines.isEmpty else { return }
        let task = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.notifyUpdate(id, "terminal.output", .output(.init(terminal: terminal, bytes: Data((lines[index] + "\r\n").utf8))))
                index = (index + 1) % lines.count
            }
        }
        lock.withLock {
            live[terminal]?.cancel()
            live[terminal] = task
        }
    }

    /// Typing echoes; Return starts a fresh prompt (the screen's last line); backspace rubs out. A live tab's process
    /// owns its terminal: only ^C ends nothing, and its echo is the process's.
    private func input(_ id: UInt64, raw: HelperBinary.Value) {
        respond(id, NSNull())
        guard let input = try? HelperBinary.decode(HelperClient.Output.self, from: raw), let shell = shell(input.terminal),
              !shell.live, !shell.name.hasPrefix("agent-") else { return }
        var echo = Data()
        for byte in input.bytes {
            switch byte {
            case 0x0d: echo.append(contentsOf: Array("\r\n".utf8) + Array(prompt(shell.name).utf8))
            case 0x7f, 0x08: echo.append(contentsOf: [0x08, 0x20, 0x08])
            case 0x03: echo.append(contentsOf: Array("^C\r\n".utf8) + Array(prompt(shell.name).utf8))
            case 0x20...0x7e, 0x80...: echo.append(byte)
            default: break
            }
        }
        guard !echo.isEmpty else { return }
        notifyAll(terminal: input.terminal, bytes: echo)
    }

    /// The recorded screen's last line: the shell's prompt.
    private func prompt(_ name: String) -> String {
        let text = String(decoding: DemoScenario.terminal(name), as: UTF8.self)
        return text.components(separatedBy: "\n").last ?? "$ "
    }

    /// Echo goes out on the terminal's attach subscriptions.
    private var attaches: [UInt64: UInt64] = [:]

    private func notifyAll(terminal: UInt64, bytes: Data) {
        guard let id = lock.withLock({ attaches[terminal] }) else { return }
        notifyUpdate(id, "terminal.output", .output(.init(terminal: terminal, bytes: bytes)))
    }

    // MARK: Wire

    private func respond(_ id: UInt64, _ value: Any) {
        guard let result = try? HelperBinary.value(["result": value]), let body = try? HelperBinary.encode(result) else { return }
        send(.init(kind: .response, id: id, body: body))
    }

    private func fail(_ id: UInt64, _ message: String) {
        guard let error = try? HelperBinary.value(["error": ["code": "unavailable", "message": message]]),
              let body = try? HelperBinary.encode(error) else { return }
        send(.init(kind: .response, id: id, body: body))
    }

    private func notify(_ id: UInt64, _ method: String, _ params: Any) {
        guard let value = try? HelperBinary.value(params) else { return }
        notifyValue(id, method, value)
    }

    private func notifyUpdate(_ id: UInt64, _ method: String, _ update: HelperClient.Update) {
        if case .output(let output) = update { lock.withLock { attaches[output.terminal] = id } }
        guard let value = try? update.encode() else { return }
        notifyValue(id, method, value)
    }

    private func notifyValue(_ id: UInt64, _ method: String, _ value: HelperBinary.Value) {
        guard let body = try? HelperBinary.encode(.object(["method": .string(method), "params": value])) else { return }
        send(.init(kind: .notify, id: id, body: body))
    }

    private func send(_ message: HelperWire.Message) {
        guard let frame = try? HelperWire.encode(message) else { return }
        transport.send(frame)
    }
}
#endif
