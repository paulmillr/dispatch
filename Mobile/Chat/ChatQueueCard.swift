import SwiftUI

/// The queue (M5c), as Messages' Send Later: each queued message is one of the user's bubbles at the thread's end, faded,
/// under the working row while the agent works. A tap (or a long press) opens its menu, every action named: Send (one
/// paused or uncertain), Send Now (saying it interrupts the turn while the agent works), Edit (in the composer: the
/// composer's ✓ saves it in its place, `MobileChatSession.beginQueueEdit`), Move Up and Move Down, Delete. Under a
/// bubble, why it waits (its status) or that it is being edited; under the last, when the queue sends, with Resume after
/// Stop. While the link is down (M4c) the same bubbles, held until the host is back: Send Now and moves wait for it.
struct ChatQueuedBubbles: View {
    let session: MobileChatSession
    /// Edit: the message into the composer, focused (the thread's).
    let edit: (MobileChatSession.QueueRow) -> Void
    @ReduceMotion private var reduceMotion

    var body: some View {
        let rows = session.queueRows
        let held = session.phase != .verified
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            VStack(spacing: 5) {
                Menu {
                    items(row, index: index, count: rows.count, held: held)
                } label: {
                    ChatUserMessage(text: row.text, attachments: row.attachments, host: session.key.host,
                                    read: { [session] in try await session.attachmentBytes($0) }, faded: true)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .contentShape(Rectangle())
                } primaryAction: {
                    // Held only: a tap in passing (scrolling, reaching for the composer) opens nothing.
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuOrder(.fixed)
                // The hold that opens it is felt, as Send's.
                .menuHoldHaptic()
                .accessibilityLabel("Queued: " + Self.accessibilityLabel(row))
                .accessibilityHint("Touch and hold for what you can do with it")
                .accessibilityActions { items(row, index: index, count: rows.count, held: held) }
                .accessibilityIdentifier("chat-queued-\(row.id)")
                if session.queueEdit?.row == row.id {
                    ChatCaption(text: "Editing in the composer", trailing: true)
                } else if let status = row.status {
                    ChatCaption(text: status, trailing: true)
                }
                if index == rows.count - 1 { footer(held: held, count: rows.count) }
            }
            // One queued rises from the composer as a sent one does; one that goes leaves at once, as the row that
            // takes its place comes.
            .transition(.asymmetric(insertion: ChatSendRise.transition(reduceMotion: reduceMotion), removal: .identity))
        }
    }

    @ViewBuilder
    private func items(_ row: MobileChatSession.QueueRow, index: Int, count: Int, held: Bool) -> some View {
        if session.canResend(row) {
            Button("Send", systemImage: "paperplane") { session.resendQueued(row) }
        }
        if !held, session.canSendNow(row) {
            Button { session.sendQueuedNow(row) } label: {
                Text("Send Now")
                if session.working { Text("Interrupts the current turn") }
                Image(systemName: "arrow.up.circle")
            }
        }
        if session.canEditQueued(row) {
            Button("Edit", systemImage: "pencil") { edit(row) }
        }
        if count > 1, !held {
            if index > 0 {
                Button("Move Up", systemImage: "arrow.up") { session.moveQueued(from: index, to: index - 1) }
            }
            if index < count - 1 {
                Button("Move Down", systemImage: "arrow.down") { session.moveQueued(from: index, to: index + 1) }
            }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { session.removeQueued(row) }
    }

    /// Under the last bubble: when the queue sends, and Resume while Stop paused it.
    @ViewBuilder
    private func footer(held: Bool, count: Int) -> some View {
        let queued = count == 1 ? "Queued" : "\(count) queued"
        if held {
            ChatCaption(text: "\(queued) · sends when \(session.hostName) is back", trailing: true)
        } else if session.queueStopped {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Text("\(queued) · paused after Stop").font(.caption).foregroundStyle(Color(uiColor: .tertiaryLabel))
                Button("Resume") { session.resumeQueue() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.dispatchPink)
                    .accessibilityLabel("Resume the queue")
                    .accessibilityIdentifier("chat-queue-resume")
            }
            .padding(.horizontal, 6)
        } else {
            ChatCaption(text: "\(queued) · " + (session.working ? "sends after this turn" : "sends next"), trailing: true)
        }
    }

    /// "Run the migration, paused after Stop": the message, its attachments, then its status.
    static func accessibilityLabel(_ row: MobileChatSession.QueueRow) -> String {
        [row.text.isEmpty ? nil : row.text, row.attachments.isEmpty ? nil : ChatAttachmentSummary.text(row.attachments),
         row.status].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Over the composer while it edits a queued message: Cancel brings the draft set aside back; the composer's ✓ saves.
struct ChatQueueEditBar: View {
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil").font(.caption.weight(.semibold))
            Text("Editing queued message").font(.footnote.weight(.semibold))
            Spacer(minLength: 8)
            Button("Cancel", action: cancel)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.dispatchPink)
                .accessibilityIdentifier("chat-queue-edit-cancel")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(minHeight: 32)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-queue-edit")
    }
}
