import SwiftUI

/// The composer's words (the phone's `ChatThreadView` placeholder, docs/watch.md, Composer and queue).
@MainActor
enum ThreadComposer {
    /// What the input asks for: "Message" when it sends at once, "Queue a message…" (or "Queue another…" with messages
    /// waiting) while the agent works, "Queued on your iPhone" while the conversation is not live.
    static func prompt(route: WatchRoute, queued: Int) -> String {
        switch route {
        case .outbox: "Queued on your iPhone"
        case .queue: queued > 0 ? "Queue another…" : "Queue a message…"
        case .send, .unknown: "Message"
        }
    }

    /// The button's title: the prompt, but "Message" while not live (its line under it says where it waits).
    static func title(route: WatchRoute, queued: Int) -> String {
        route == .outbox ? "Message" : prompt(route: route, queued: queued)
    }

    /// Where a reply goes, said on the confirm screen (K5): nothing when it is sent at once.
    static func routeLine(_ state: (route: WatchRoute, queued: Int)?) -> String? {
        switch state?.route {
        case .queue?: state!.queued > 0 ? "Queued after \(state!.queued) more" : "Queued until this turn ends"
        case .outbox?: "Queued on your iPhone"
        case .send?, .unknown?, nil: nil
        }
    }

    /// Steer is the phone's long-press send: offered while a live agent works.
    static func canSteer(_ thread: WatchThread) -> Bool { thread.working && thread.phase == .live }

    /// One button of the confirm screen (K5) and the line under it saying what it does.
    struct ReplyAction: Equatable, Identifiable {
        let title: String
        var symbol: String? = nil
        let style: CapsuleLabel.Style
        /// Into the running turn rather than routed as a message.
        let steer: Bool
        let line: String?
        var id: String { title }
    }

    /// The confirm screen's choice, made once the words exist (the phone's tap queues, its hold offers Steer): while a
    /// live agent works, Queue (accent) or Steer now; otherwise Send with where it goes. Cancel follows either way.
    static func actions(_ thread: WatchThread?) -> [ReplyAction] {
        let template = thread.map(canSteer) == true
            ? [ReplyAction(title: "Queue", symbol: "text.append", style: .accent, steer: false, line: nil),
               ReplyAction(title: "Steer now", symbol: "arrow.turn.down.right", style: .glass, steer: true, line: nil)]
            : [ReplyAction(title: "Send", symbol: "arrow.up", style: .accent, steer: false, line: nil)]
        return relabel(template, thread)
    }

    /// The screen's buttons stay as it opened (none moves under a finger); each line says what that button does with
    /// the thread as it is now, as the phone will route it (`MobileChatSession.route(steer:)`): Steer now once the turn
    /// ended sends as Send would, Send while a turn runs queues.
    static func relabel(_ actions: [ReplyAction], _ thread: WatchThread?) -> [ReplyAction] {
        let ahead = thread.map { ahead($0.queue) } ?? 0
        let steerable = thread.map(canSteer) ?? false
        return actions.map { action in
            var line: String?
            if action.steer, steerable {
                line = "Goes into the running turn"
            } else if steerable {
                line = ahead > 0 ? "Queued after \(ahead) more" : "Queued after this turn"
            } else {
                line = routeLine(thread.map { ($0.route, ahead) }) ?? (action.title == "Send" ? nil : "Sent now: the turn ended")
            }
            return ReplyAction(title: action.title, symbol: action.symbol, style: action.style, steer: action.steer, line: line)
        }
    }

    /// The queued messages a new one waits behind: those that send by themselves (one paused or not sent waits for the
    /// user and does not hold a later one back).
    static func ahead(_ queue: [WatchQueued]) -> Int {
        split(queue).queued.filter { $0.status == nil }.count
    }

    /// The queue as rows, and the watch's own message on its way (`WatchModel.sendingID`), drawn as a faded bubble.
    static func split(_ queue: [WatchQueued]) -> (queued: [WatchQueued], sending: [WatchQueued]) {
        (queue.filter { !WatchModel.isSending($0) }, queue.filter(WatchModel.isSending))
    }
}

/// One queued message: its text and, when it does not send by itself, why ("Paused after Stop.").
struct QueuedRow: View {
    let item: WatchQueued

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.text).font(.footnote).lineLimit(3)
            if let status = item.status, !status.isEmpty {
                Text(status).font(.caption2).foregroundStyle(AgentsColor.working)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityHint(item.canSendNow ? (item.status == nil ? "Swipe for Send now or Remove" : "Swipe for Send or Remove")
            : "Swipe to remove")
    }
}

/// The queue's header, the phone's "Queued · 3" in pink.
struct QueueHeader: View {
    let count: Int

    var body: some View {
        Text("Queued · \(count)")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AgentsColor.pink)
            .textCase(nil)
    }
}
