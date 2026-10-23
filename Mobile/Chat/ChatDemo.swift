#if DEBUG
import Dictation
import SwiftUI
import UIKit

/// Debug builds only: the mockup's thread states (M3a, M3b, M4a, M4b, M4c, M5a, M5b, M5c, M5d, M5e, M5f, M9a) driven through the
/// real `MobileChatSession` by an in-process helper peer on two pipes, which replays the real helper's recorded pages
/// (Mobile/Tests/Fixtures/Chat, read from the checkout the build came from: the simulator sees the Mac's disk).
/// Launch with `DISPATCH_MOBILE_CHAT_DEMO=<screen id>` (`SIMCTL_CHILD_DISPATCH_MOBILE_CHAT_DEMO` through simctl).
enum ChatDemo {
    static var screen: String? { ProcessInfo.processInfo.environment["DISPATCH_MOBILE_CHAT_DEMO"] }
    /// `DISPATCH_MOBILE_CHAT_DEMO_WIDTH=<points>`: M3a in a sidebar column that wide.
    static var sidebarWidth: CGFloat? {
        ProcessInfo.processInfo.environment["DISPATCH_MOBILE_CHAT_DEMO_WIDTH"].flatMap(Double.init).map { CGFloat($0) }
    }

    static let conversation = "00000000-0000-4000-8000-000000000201"
    static let host = UUID(uuidString: "6A0F2D6E-6B4E-4C59-9D7E-2C1F2E1D0B01")!

    static func records() -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/Chat/claude-thread.json")
        guard let data = try? Data(contentsOf: url),
              let pages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return pages.flatMap { $0["records"] as? [[String: Any]] ?? [] }
    }

    /// C3's side conversation and its question.
    static let side = "00000000-0000-4000-8000-0000000002b1"
    static let sideQuestion = "Which handler runs first for a retried invoice.paid event?"

    /// The goal screens talk to Codex (goals are Codex's).
    static func codex(_ screen: String) -> Bool { ["C4", "C4b"].contains(screen) }

    /// The commands the real harnesses list (helper/harnesses/*/src/harness.rs `commands`).
    static func commands(key: String) -> [String] {
        key == "codex"
            ? ["/btw", "/side", "/fast", "/compact", "/rename", "/init", "/review", "/stop", "/copy", "/model", "/plan", "/goal",
               "/clear", "/new", "/status", "/terminal", "/hooks", "/permissions", "/resume", "/exit", "/quit"]
            : ["/btw", "/side", "/terminal", "/model", "/effort", "/init", "/clear", "/compact", "/resume", "/help", "/exit", "/quit"]
    }

    /// A question and its answer as one ended turn.
    static func exchange(_ turn: String, question: String, answer: String) -> [[String: Any]] {
        let base: Int64 = ["p2b": 946_719_300_000, "p3": 946_719_400_000][turn] ?? 946_719_500_000
        func record(_ id: String, _ kind: String, text: String = "", time: Int64) -> [String: Any] {
            ["id": id, "turn": turn, "kind": kind, "text": text, "title": "", "output": "", "blocks": [], "completed": true,
             "exit_code": NSNull(), "patch": NSNull(), "documents": [], "tool": NSNull(), "inline_reasoning": false,
             "time_ms": time, "position": NSNull()]
        }
        return [record(turn + ":started", "turn_started", time: base), record(turn + ":user", "user", text: question, time: base),
                record(turn + ":answer", "assistant", text: answer, time: base + 9_000), record(turn + ":ended", "turn_ended", time: base + 9_000)]
    }

    /// The state a screen opens with: C4's goal, subagents and context.
    static func state(screen: String, busy: Bool) -> [String: Any] {
        var state = state(busy: busy)
        if codex(screen) {
            state["model"] = "gpt-5.5"
            state["goal"] = ["objective": "All webhook routes idempotent, tests green", "status": "active",
                             "tokensUsed": 48_210, "timeUsedSeconds": 754, "tokenBudget": 200_000]
            state["usage"] = ["info": ["total_token_usage": ["input_tokens": 41_000, "output_tokens": 7_210],
                                       "last_token_usage": ["total_tokens": 158_000], "model_context_window": 250_000]]
            state["agents"] = ["explorer", "worker"]
        }
        return state
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
        private var stored: [String: Data] = [:]

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
            case "chat.open" where params["session"] as? String == ChatDemo.side: openSide(id, terminal: terminal)
            case "chat.open": open(id, terminal: terminal)
            // C1's earlier page never comes: the search says it is still looking.
            case "chat.page" where params["earlier"] is String: return
            case "chat.side":
                var binding = ChatDemo.binding
                binding["session"] = ChatDemo.side
                respond(id, binding)
            case "chat.command":
                respond(id, ["kind": "sent", "sent": ["written": true, "may_have_sent": true, "reason": NSNull()]])
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
            // M4b's chips: the answer is written, as the helper's hook would report it. A message or a stop from the
            // composer is typed into the terminal (the thread keeps the sent bubble; no turn follows).
            case "interactions.answer", "chat.send", "chat.stop":
                respond(id, ["written": true, "may_have_sent": true, "reason": NSNull()])
            case "queue.add":
                serial += 1
                respond(id, item("held-\(serial)", params["text"] as? String ?? ""))
            // Attachments (feature chat.attachments): kept in memory under a host-like path, read back as stored.
            case "attachments.put":
                serial += 1
                let name = params["name"] as? String ?? "attachment"
                let bytes = params["bytes"] as? Data ?? Data()
                let path = "/Users/paul/.dispatch/attachments/\(String(format: "%032llx", serial))/\(name)"
                lock.withLock { stored[path] = bytes }
                let image = ["png", "jpg", "jpeg", "gif", "webp"].contains((name as NSString).pathExtension.lowercased())
                respond(id, ["path": path, "name": name, "kind": image ? "image" : "file", "size": UInt64(bytes.count)])
            case "attachments.read":
                let bytes = lock.withLock { stored[params["path"] as? String ?? ""] } ?? Data()
                respond(id, ["bytes": bytes, "size": UInt64(bytes.count)])
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
            if screen == "C6" {
                // C6: a longer thread read from its top, two more messages arriving while it is scrolled up.
                records += ChatDemo.exchange("p2b", question: "Does the guard survive a deploy?",
                                             answer: "Yes: the seen event ids live in the idempotency_keys table, not in memory, so a restart keeps them.")
                records += ChatDemo.exchange("p3", question: "What about the Stripe CLI’s replay command, does it reuse event ids?",
                                             answer: "Yes, stripe events resend keeps the original id, so the guard treats it as a retry and skips it. That is what we want for replays of real events.")
            }
            notify(id, "chat.history", history(terminal: terminal, records: [], state: ChatDemo.state(screen: screen, busy: busy), pending: true))
            notify(id, "chat.history", history(terminal: terminal, records: records, state: nil, pending: false))
            if screen == "C6" {
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { [self] in
                    notify(id, "chat.records", ["terminal": terminal, "session": ChatDemo.conversation, "replace": NSNull(), "earlier": NSNull(),
                                                "records": ChatDemo.exchange("p4", question: "And the dashboard’s Resend button?",
                                                                             answer: "That one creates a new event with a new id, so it is processed again. Worth a note in the runbook.")])
                }
            }
            if screen == "M4b" {
                let operation = #"{"command":"playwright test --headed tests/checkout.spec.ts","description":"Can I run this? It opens a browser on mba2; the flake only reproduces headed."}"#
                notify(id, "interaction.opened", ["terminal": terminal, "session": ChatDemo.conversation, "interaction": [
                    "id": "approval-1", "key": NSNull(), "approval": true, "blocking": true, "turn": NSNull(), "record": NSNull(),
                    "questions": [["id": "approval", "header": "Bash", "text": operation, "secret": false, "multiple": false, "custom": false,
                                   "options": ["Allow", "Deny", "Terminal", "Allow for this session"].map { ["id": $0, "label": $0, "detail": NSNull()] },
                                   "blocks": [["kind": "code", "language": "json", "text": operation]]]]]])
            }
        }

        /// C3's side conversation: the question, three reads and the answer, 12 s.
        private func openSide(_ id: UInt64, terminal: UInt64) {
            let reads = Set(["tool-c1", "tool-d1", "tool-d2"])
            let base: Int64 = 946_719_300_000
            var records: [[String: Any]] = [record("s:started", "turn_started", turn: "s1", time: base),
                                            record("s:user", "user", turn: "s1", text: ChatDemo.sideQuestion, time: base)]
            for (index, var tool) in ChatDemo.records().filter({ reads.contains($0["id"] as? String ?? "") }).enumerated() {
                tool["turn"] = "s1"
                tool["time_ms"] = base + Int64(index + 1) * 1_000
                records.append(tool)
            }
            records.append(record("s:answer", "assistant", turn: "s1", text: "The route handler in src/routes/invoices.ts runs before the shared middleware, because it is mounted on the router directly. The guard sees the event only on the second pass.", time: base + 12_000))
            records.append(record("s:ended", "turn_ended", turn: "s1", time: base + 12_000))
            notify(id, "chat.history", ["terminal": terminal, "binding": ChatDemo.binding, "session": ChatDemo.side, "label": "claude",
                                        "key": "claude", "commands": [], "native_queue": false, "state": ChatDemo.state(busy: false),
                                        "state_error": NSNull(), "records": records, "earlier": NSNull(), "history_error": NSNull(),
                                        "history_pending": false, "capabilities": ["state", "history"]])
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
            let key = ChatDemo.codex(screen) ? "codex" : "claude"
            return ["terminal": terminal, "binding": ChatDemo.binding, "session": ChatDemo.conversation, "label": key, "key": key,
                    "commands": ChatDemo.commands(key: key), "native_queue": false, "state": state ?? NSNull(),
                    "state_error": NSNull(), "records": records,
                    // C1: an earlier page that is still loading ("Searching earlier messages…").
                    "earlier": screen == "C1" && !pending ? "c1-earlier" : NSNull(), "history_error": NSNull(),
                    "history_pending": pending, "capabilities": ["state", "history"]]
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
        if screen.hasPrefix("C5") {
            MobileVoiceConversation.shared = MobileVoiceConversation(
                listener: DemoListener(words: screen == "C5" ? "and add a test for the retry path" : nil), speaker: DemoSpeaker())
        }
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
            conversations.update(ChatHostSnapshot(id: host, name: "mba2", link: .connected, client: peer.client, topology: topology(),
                                                  features: [ChatAttachment.feature]))
            Task { @MainActor in
                _ = conversations.session(for: ChatConversationKey(host: host, node: "tmux:s:$0:%0"))
                try? await Task.sleep(for: .milliseconds(600))
                conversations.update(ChatHostSnapshot(id: host, name: "mba2", link: link, client: nil, topology: topology()))
            }
        } else {
            conversations.update(ChatHostSnapshot(id: host, name: "mba2", link: link, client: peer.client, topology: topology(),
                                                  features: [ChatAttachment.feature]))
        }
        if ProcessInfo.processInfo.environment["DISPATCH_MOBILE_CHAT_DEMO_LINK"] == "cycle" {
            // Frame checks of M4c's banner: the link drops after 3 s and comes back 4 s later (the thread reattaches).
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                conversations.update(ChatHostSnapshot(id: host, name: "mba2", link: .reconnecting(attempt: 1, since: Date()),
                                                      client: nil, topology: topology()))
                try? await Task.sleep(for: .seconds(4))
                conversations.update(ChatHostSnapshot(id: host, name: "mba2", link: .connected, client: peer.client, topology: topology(),
                                                  features: [ChatAttachment.feature]))
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
            let agents = NavigationStack {
                AgentsScreen(conversations: conversations, look: ChatDemo.look, open: { _ in }, close: { _ in })
                    // The app's canvas, as the shell gives the Agents tab (#F2F2F7 in light, L1a).
                    .background(Color.canvas)
            }
            .task { await conversations.refresh(host: ChatDemo.host) }
            if let width = ChatDemo.sidebarWidth {
                // As a split's sidebar column (an iPad, the unfolded Duo) beside an empty detail column.
                HStack(spacing: 0) {
                    agents.frame(width: width).environment(\.tabsNarrowSidebar, MobileSplit.narrow(sidebar: width))
                    Rectangle().fill(Color.hairline).frame(width: 0.5).ignoresSafeArea()
                    Color.canvas.ignoresSafeArea()
                }
            } else { agents }
        case "M9a":
            Color.canvas.sheet(isPresented: .constant(true)) {
                NewChatSheet(conversations: conversations, memory: ChatDemo.memory, look: ChatDemo.look, started: { _ in })
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
            let redesign = screen.hasPrefix("C") || screen == "S6"
            NavigationStack {
                VStack(spacing: 0) {
                    ChatDemoHeader(session: session, needsYou: redesign ? 2 : 1, title: redesign ? "Billing webhook retries" : "app")
                    ChatThreadView(session: session, space: "app", tab: redesign ? "Billing webhook retries" : "claude",
                                   directory: "/Users/alex/src/app",
                                   homes: HomePath(account: "/Users/alex"), focusOnAppear: ["M3b", "M5e"].contains(screen),
                                   memory: ChatDemo.memory, expandSteps: screen == "M5f", expandQueue: screen == "M5c",
                                   startsAtTop: screen == "C6")
                }
                .toolbar(.hidden, for: .navigationBar)
                // M5e: M4a's thread with the code draft in the composer; the C screens' state, once the conversation is
                // verified.
                .task {
                    for _ in 0..<100 where session.transcript.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
                    ChatDemo.prepare(screen, session: session)
                }
            }
            .toolbar(.hidden, for: .tabBar)
        }
    }
}

extension ChatDemo {
    /// Puts a screen's thread in its state: M5e's code draft, C1's search, C2's "/", C3's side question, C4b's sheet,
    /// C5's conversation mode (with the scripted voice `conversations(screen:)` installed).
    @MainActor static func prepare(_ screen: String, session: MobileChatSession) {
        switch screen {
        case "M5e": session.drafts.edit(text: CodeDemo.draft)
        case "C1":
            session.search.open()
            session.search.query = "guard"
            // As the mockup draws it: the results without the keyboard.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        case "C2": session.drafts.edit(text: "/")
        case "C3": session.openSide(.btw, question: sideQuestion)
        case "C4b": session.managingGoal = true
        case "C5": MobileVoiceConversation.shared.start(session)
        case "C5r":
            MobileVoiceConversation.shared.start(session)
            MobileVoiceConversation.shared.readLast()
        default: break
        }
    }

    /// Conversation mode without audio: it hears C5's words and reads until stopped.
    @MainActor final class DemoListener: VoiceListener {
        var level: Float = 0.6
        var error: String? { nil }
        let words: String?
        init(words: String?) { self.words = words }
        func start(update: @escaping @MainActor (DictationUpdate) -> Void) {
            guard let words else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                update(.heard(words))
            }
        }
        func mute(_ muted: Bool) { level = muted ? 0 : 0.6 }
        func stop() {}
    }

    @MainActor final class DemoSpeaker: VoiceSpeaker {
        private var finished: (@MainActor () -> Void)?
        func speak(_ text: String, finished: @escaping @MainActor () -> Void) { self.finished = finished }
        func stop() { let finished = finished; self.finished = nil; finished?() }
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
    var title = "app"

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
                    Text(title).font(.headline)
                    (Text(session.hostName).foregroundStyle(TabsSample.mba2.tint) + Text(" · ")
                        + Text("~/src/app").font(.caption2.monospaced()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 4)
                Spacer()
                ChatHeaderControls(session: session) {
                    Image(systemName: "apple.logo")
                        .foregroundStyle(TabsSample.mba2.tint)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular, in: Circle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            // As Tabs' header in the navigation bar: it grows to xxxLarge.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            // Tabs' capsule (the mockups' C screens show the Files segment with the review count).
            TabSegmentCapsule(selection: .constant(.chat), segments: TabSegment.allCases, badge: 3)
                .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
        .background(Color.canvas)
    }
}
#endif
