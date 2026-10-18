#if DEBUG
import SwiftUI

/// Debug builds only: the mockup's thread states (M3a, M3b, M4a, M4b, M4c, M5a, M5b, M5c, M5d, M5e, M5f, M9a) driven through the
/// real `MobileChatSession` by an in-process helper peer on two pipes, which replays the real helper's recorded pages
/// (Mobile/Tests/Fixtures/Chat, read from the checkout the build came from: the simulator sees the Mac's disk).
/// Launch with `DISPATCH_MOBILE_CHAT_DEMO=<screen id>` (`SIMCTL_CHILD_DISPATCH_MOBILE_CHAT_DEMO` through simctl).
enum ChatDemo {
    static var screen: String? { ProcessInfo.processInfo.environment["DISPATCH_MOBILE_CHAT_DEMO"] }

    static let conversation = "00000000-0000-4000-8000-000000000201"
    static let host = UUID(uuidString: "6A0F2D6E-6B4E-4C59-9D7E-2C1F2E1D0B01")!

    static func records() -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/Chat/claude-thread.json")
        guard let data = try? Data(contentsOf: url),
              let pages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return pages.flatMap { $0["records"] as? [[String: Any]] ?? [] }
    }

    static func state(busy: Bool) -> [String: Any] {
        ["busy": busy, "activity": NSNull(), "model": "fable-5.1", "model_label": NSNull(), "effort": "high", "usage": NSNull(),
         "goal": NSNull(), "draft": NSNull(), "attention": NSNull(), "leaf": NSNull(), "dialog": NSNull(), "title": NSNull(),
         "version": NSNull(), "pending": false, "compacting": false, "service_tier": NSNull(), "mode": NSNull(), "agents": []]
    }

    @MainActor final class DraftStore: ChatDraftPersistence {
        var buckets: [String: ChatDraftBucket] = [:]
        func load() throws -> [String: ChatDraftBucket] { buckets }
        func save(_ buckets: [String: ChatDraftBucket]) throws { self.buckets = buckets }
    }

    nonisolated(unsafe) static let binding: [String: Any] = ["session": conversation, "transcript": "/work/t.jsonl", "pid": 4242,
                                         "start": [946719000, 0], "executable": "/usr/local/bin/claude"]

    static func topology(agents: Int = 5) -> HelperTopology {
        var nodes: [[String: Any]] = [["id": 1, "key": "tmux:s:$0", "parent": NSNull(), "kind": "workspace", "name": "app", "detached": false]]
        let tabs = ["app", "e2e", "docs", "curves", "billing"]
        for (index, name) in tabs.prefix(agents).enumerated() {
            let tab = 10 + index * 2, terminal = tab + 1
            var agent = binding
            agent["session"] = index == 0 ? conversation : "conversation-\(name)"
            nodes.append(["id": tab, "key": "tmux:s:$0:@\(index)", "parent": 1, "kind": "tab", "name": name, "detached": false])
            nodes.append(["id": terminal, "key": "tmux:s:$0:%\(index)", "parent": tab, "kind": "terminal", "name": "claude",
                          "cwd": "/Users/paul/src/\(name)", "agent": agent, "detached": false])
        }
        let object: [String: Any] = ["backend": 9, "nodes": nodes, "layouts": [], "focus": NSNull()]
        return try! JSONDecoder().decode(HelperTopology.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// The helper side: answers requests and publishes the screen's notifications on `chat.open`.
    final class Peer: @unchecked Sendable {
        let client: HelperClient
        private let transport: HelperTransport
        private let lock = NSLock()
        private var decoder = HelperWire.Decoder()
        private let screen: String
        private var serial: UInt64 = 0

        init(screen: String) {
            self.screen = screen
            let incoming = Pipe(), outgoing = Pipe()
            client = HelperClient(HelperConnection(read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting))
            transport = HelperTransport(read: outgoing.fileHandleForReading, write: incoming.fileHandleForWriting)
            transport.start(receive: { [weak self] in self?.receive($0) }, closed: { _ in })
        }

        private func receive(_ bytes: Data) {
            var messages: [HelperWire.Message] = []
            lock.withLock { try? decoder.feed(bytes) { messages.append($0) } }
            for message in messages where message.kind == .request {
                guard let object = HelperBinary.foundation((try? HelperBinary.decode(message.body)) ?? .null) as? [String: Any],
                      let method = object["method"] as? String else { continue }
                let params = object["params"] as? [String: Any] ?? [:]
                handle(message.id, method, params)
            }
        }

        private func handle(_ id: UInt64, _ method: String, _ params: [String: Any]) {
            let terminal = params["terminal"] as? UInt64 ?? 11
            switch method {
            case "chat.open": open(id, terminal: terminal)
            case "chat.state":
                // app works, e2e waits for an approval; docs and curves have results this phone has not seen.
                var state = ChatDemo.state(busy: terminal == 11)
                if terminal == 13 { state["attention"] = "Waiting for approval" }
                respond(id, ["binding": ChatDemo.binding, "state": state])
            case "chat.page":
                let previews = [11: "Moving the check into a shared middleware so both routes get it.",
                                13: "Run playwright test --headed? It opens a browser on the host.",
                                15: "Wrote the Hooks page. Want a review pass before I touch the nav?",
                                17: "Fitted the bezier easing; curves.ts updated and tests green.",
                                19: "Done. Webhook retries are keyed on the Stripe event id and persisted in idempotency_keys."]
                let minutes: [UInt64: Int64] = [11: 0, 13: 9, 15: 52, 17: 60 * 22, 19: 60 * 24 * 5]
                let time = Int64(Date().timeIntervalSince1970 * 1000) - (minutes[terminal] ?? 0) * 60_000
                respond(id, ["records": [record("a\(terminal)", "assistant", turn: "t", text: previews[Int(terminal)] ?? "", time: time),
                                         record("e\(terminal)", "turn_ended", turn: "t", time: time)], "earlier": NSNull()])
            case "queue.list": respond(id, screen == "M5c" ? queued() : [])
            // M4b's chips: the answer is written, as the helper's hook would report it.
            case "interactions.answer": respond(id, ["written": true, "may_have_sent": true, "reason": NSNull()])
            case "queue.add":
                serial += 1
                respond(id, item("held-\(serial)", params["text"] as? String ?? ""))
            case "launches.list":
                respond(id, [["launch": 0, "key": "claude", "label": "Claude Code", "program": "claude"],
                             ["launch": 1, "key": "codex", "label": "Codex", "program": "codex"]])
            case "chat.models":
                respond(id, ["choices": [["id": "fable-5.1", "label": "fable-5.1", "detail": NSNull()],
                                         ["id": "sonnet-5", "label": "sonnet-5", "detail": NSNull()]], "current": "fable-5.1", "default": NSNull()])
            case "chat.settings":
                respond(id, ["choices": ["low", "medium", "high"].map { ["id": $0, "label": $0, "detail": NSNull()] }, "current": "high", "default": NSNull()])
            default: respond(id, NSNull())
            }
        }

        private func open(_ id: UInt64, terminal: UInt64) {
            var records = ChatDemo.records()
            let busy = ["M5a", "M5f", "M5c"].contains(screen)
            if screen == "M3b" { records = [] }
            if busy {
                // Turn 2 still running: its first steps are in, the answer is not.
                records = records.filter { $0["id"] as? String != "f2:ended" && $0["id"] as? String != "claude-f2-0" }
                if screen == "M5c" { records = records.filter { $0["turn"] as? String == "p1" && $0["kind"] as? String == "user" } }
            }
            // M4b's approval and M4c's queued message come after the first turn: the thread shows that turn only.
            if ["M4b", "M4c"].contains(screen) { records = records.filter { $0["turn"] as? String == "p1" } }
            if busy {
                // The running turn started 48 s ago, as in the mockup's clock.
                let started = records.last { $0["kind"] as? String == "turn_started" }?["time_ms"] as? Int64 ?? 0
                let shift = Int64(Date().timeIntervalSince1970 * 1000) - 48_000 - started
                records = records.map { record in
                    var record = record
                    if let time = record["time_ms"] as? Int64 { record["time_ms"] = time + shift }
                    return record
                }
            }
            notify(id, "chat.history", history(terminal: terminal, records: [], state: ChatDemo.state(busy: busy), pending: true))
            notify(id, "chat.history", history(terminal: terminal, records: records, state: nil, pending: false))
            if screen == "M4b" {
                let operation = #"{"command":"playwright test --headed tests/checkout.spec.ts","description":"Can I run this? It opens a browser on mba2; the flake only reproduces headed."}"#
                notify(id, "interaction.opened", ["terminal": terminal, "session": ChatDemo.conversation, "interaction": [
                    "id": "approval-1", "key": NSNull(), "approval": true, "blocking": true, "turn": NSNull(), "record": NSNull(),
                    "questions": [["id": "approval", "header": "Bash", "text": operation, "secret": false, "multiple": false, "custom": false,
                                   "options": ["Allow", "Deny", "Terminal", "Allow for this session"].map { ["id": $0, "label": $0, "detail": NSNull()] },
                                   "blocks": [["kind": "code", "language": "json", "text": operation]]]]]])
            }
        }

        private func queued() -> [[String: Any]] {
            [item("held-a", "Also cover invoice.paid — it has a separate handler."),
             item("held-b", "Add a unit test for the duplicate-event case."),
             item("held-c", "Then run the full suite and paste the summary")]
        }

        private func item(_ id: String, _ text: String) -> [String: Any] {
            ["id": id, "mode": "prompt", "revision": 1, "preview": [["kind": "text", "text": text]], "editable": true,
             "editing": false, "paused": NSNull(), "error": NSNull()]
        }

        private func record(_ id: String, _ kind: String, turn: String, text: String = "", time: Int64) -> [String: Any] {
            ["id": id, "turn": turn, "kind": kind, "text": text, "title": "", "output": "", "blocks": [], "completed": true,
             "exit_code": NSNull(), "patch": NSNull(), "documents": [], "tool": NSNull(), "inline_reasoning": false,
             "time_ms": time, "position": NSNull()]
        }

        private func history(terminal: UInt64, records: [[String: Any]], state: [String: Any]?, pending: Bool) -> [String: Any] {
            ["terminal": terminal, "binding": ChatDemo.binding, "session": ChatDemo.conversation, "label": "claude", "key": "claude",
             "commands": [], "native_queue": false, "state": state ?? NSNull(), "state_error": NSNull(), "records": records,
             "earlier": NSNull(), "history_error": NSNull(), "history_pending": pending, "capabilities": ["state", "history"]]
        }

        private func respond(_ id: UInt64, _ value: Any) {
            let body = try! HelperBinary.encode(try! HelperBinary.value(["result": value]))
            transport.send(try! HelperWire.encode(.init(kind: .response, id: id, body: body)))
        }

        private func notify(_ id: UInt64, _ method: String, _ params: Any) {
            let body = try! HelperBinary.encode(.object(["method": .string(method), "params": try! HelperBinary.value(params)]))
            transport.send(try! HelperWire.encode(.init(kind: .notify, id: id, body: body)))
        }
    }

    /// The demo's model: one host "mba2" with five agent tabs in the space "app".
    @MainActor static func conversations(screen: String) -> (ChatConversations, Peer) {
        let peer = Peer(screen: screen)
        let memory = ChatOutbox(store: ChatOutboxMemoryStore(screen == "M4c" ? [
            ChatOutboxItem(key: ChatConversationKey(host: host, node: "tmux:s:$0:%0"), conversation: conversation,
                           text: "Also cover invoice.paid — it has a separate handler.")] : []))
        let markers = ChatMarkerMemoryStore()
        for name in ["docs", "curves", "billing"] {
            markers.document.seen[ChatMarkers.seenKey(host: host, conversation: "conversation-\(name)")] = name == "billing" ? .max : 0
        }
        let conversations = ChatConversations(presence: ChatTerminalPresenceStub(), markers: ChatMarkers(store: markers),
                                              outbox: memory, drafts: ChatDraftRepository(store: DraftStore()))
        let link: HostLink = screen == "M4c" ? .reconnecting(attempt: 3, since: Date().addingTimeInterval(-14)) : .connected
        if screen == "M4c" {
            // Connected first so the thread loads, then the link drops.
            conversations.update(ChatHostSnapshot(id: host, name: "mba2", link: .connected, client: peer.client, topology: topology()))
            Task { @MainActor in
                _ = conversations.session(for: ChatConversationKey(host: host, node: "tmux:s:$0:%0"))
                try? await Task.sleep(for: .milliseconds(600))
                conversations.update(ChatHostSnapshot(id: host, name: "mba2", link: link, client: nil, topology: topology()))
            }
        } else {
            conversations.update(ChatHostSnapshot(id: host, name: "mba2", link: link, client: peer.client, topology: topology()))
        }
        if ProcessInfo.processInfo.environment["DISPATCH_MOBILE_CHAT_DEMO_LINK"] == "cycle" {
            // Frame checks of M4c's banner: the link drops after 3 s and comes back 4 s later (the thread reattaches).
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                conversations.update(ChatHostSnapshot(id: host, name: "mba2", link: .reconnecting(attempt: 1, since: Date()),
                                                      client: nil, topology: topology()))
                try? await Task.sleep(for: .seconds(4))
                conversations.update(ChatHostSnapshot(id: host, name: "mba2", link: .connected, client: peer.client, topology: topology()))
            }
        }
        return (conversations, peer)
    }
}

/// The demo screens, with a temporary header standing in for Tabs' `TabScreen` (back pill with the needs-you count,
/// title, host and directory, the host disc, the Terminal / Chat control).
struct ChatDemoRoot: View {
    let screen: String
    @State private var model: (ChatConversations, ChatDemo.Peer)?

    var body: some View {
        Group {
            if let (conversations, _) = model {
                content(conversations)
            } else { Color.canvas }
        }
        .task { if model == nil { model = ChatDemo.conversations(screen: screen) } }
    }

    @ViewBuilder private func content(_ conversations: ChatConversations) -> some View {
        let key = ChatConversationKey(host: ChatDemo.host, node: "tmux:s:$0:%0")
        switch screen {
        case "M3a":
            NavigationStack {
                AgentsScreen(conversations: conversations, look: ChatDemo.look, open: { _ in }, close: { _ in })
                    // The app's canvas, as the shell gives the Agents tab (#F2F2F7 in light, L1a).
                    .background(Color.canvas)
            }
            .task { await conversations.refresh(host: ChatDemo.host) }
        case "M9a":
            Color.canvas.sheet(isPresented: .constant(true)) {
                NewChatSheet(conversations: conversations, memory: ChatDemo.memory, look: ChatDemo.look, newSpace: {}, started: { _ in })
                    .presentationDetents([.large])
            }
        case "M5d":
            // The diff viewer with the mockup's own patch (CodeDemo), as a Patch step in message details pushes it.
            NavigationStack { DiffView(model: CodeDemo.model()) }
                .toolbar(.hidden, for: .tabBar)
        case "M5b":
            let session = conversations.session(for: key)
            NavigationStack {
                Group {
                    if let row = session.transcript.rows.last {
                        ChatMessageDetails(session: session, row: row, space: "app", tab: "claude", directory: "/Users/paul/src/app") { _ in }
                    } else { Color.canvas }
                }
            }
            .toolbar(.hidden, for: .tabBar)
        default:
            let session = conversations.session(for: key)
            NavigationStack {
                VStack(spacing: 0) {
                    ChatDemoHeader(session: session, needsYou: 1)
                    ChatThreadView(session: session, space: "app", tab: "claude", directory: "/Users/paul/src/app",
                                   homes: HomePath(account: "/Users/paul"), focusOnAppear: ["M3b", "M5e"].contains(screen),
                                   memory: ChatDemo.memory, expandSteps: screen == "M5f", expandQueue: screen == "M5c")
                }
                .toolbar(.hidden, for: .navigationBar)
                // M5e: M4a's thread with the code draft in the composer, once the conversation is verified.
                .task {
                    guard screen == "M5e" else { return }
                    for _ in 0..<100 where session.transcript.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
                    session.drafts.edit(text: CodeDemo.draft)
                }
            }
            .toolbar(.hidden, for: .tabBar)
        }
    }
}

extension ChatDemo {
    @MainActor static let look = ChatHostLook(tint: { _ in TabsSample.mba2.tint }, glyph: { _ in AnyView(Image(systemName: "apple.logo").resizable().scaledToFit()) })
    @MainActor static let memory: ChatModelMemory = {
        let memory = ChatModelMemory(url: nil)
        memory.remember(agent: "claude", models: [AgentModelMenu.Choice(number: 1, name: "fable-5.1", detail: "fable-5.1", current: true, isDefault: false)])
        memory.remember(agent: "claude", efforts: ["low", "medium", "high"].enumerated().map {
            AgentModelMenu.Choice(number: $0.offset + 1, name: $0.element, detail: $0.element, current: false, isDefault: false)
        }, for: "fable-5.1")
        memory.remember(agent: "claude", model: "fable-5.1", effort: "high")
        return memory
    }()
}

/// Stands in for Tabs' `TabScreen` header in previews and the demo only.
struct ChatDemoHeader: View {
    let session: MobileChatSession
    var needsYou = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold))
                    if needsYou > 0 { Text("\(needsYou)").font(.callout.weight(.semibold)) }
                }
                .foregroundStyle(Color.dispatchPink)
                .padding(.leading, 12).padding(.trailing, 14)
                .frame(height: 44)
                .glassEffect(.regular, in: Capsule())
                VStack(alignment: .leading, spacing: 0) {
                    Text("app").font(.headline)
                    (Text(session.hostName).foregroundStyle(TabsSample.mba2.tint) + Text(" · ")
                        + Text("~/src/app").font(.caption2.monospaced()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 4)
                Spacer()
                Image(systemName: "apple.logo")
                    .foregroundStyle(TabsSample.mba2.tint)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: Circle())
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            // As Tabs' header in the navigation bar: it grows to xxxLarge.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            Picker("", selection: .constant(1)) {
                Text("Terminal").tag(0)
                Text("Chat").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
        .background(Color.canvas)
    }
}
#endif
