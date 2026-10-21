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

    /// Steer is the phone's long-press send: offered while a live agent works.
    static func canSteer(_ thread: WatchThread) -> Bool { thread.working && thread.phase == .live }

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
        .accessibilityHint(item.canSendNow ? "Swipe for Send now or Remove" : "Swipe to remove")
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
