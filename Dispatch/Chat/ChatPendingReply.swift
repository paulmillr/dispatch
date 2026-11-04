import Foundation

// The reply placeholder. Once the agent acknowledges a sent prompt, an empty assistant bubble stands where its reply
// will be: the composer footer's activity (◆ and orbit, label, time) where its first word will be, its outline lapped by
// the composer's working light, while the composer and its footer stay quiet. The first reply, tool step or narration
// takes over its row, the light fades into the bubble's outline as the words type in, and then the composer's light
// comes back for the rest of the turn.

struct ChatPendingReply: Equatable {
    /// After sending, at the earliest: the send flight lands first (0.42 s).
    static let delay: TimeInterval = 0.5

    let id: String
    /// The last turn when the prompt was sent: content in a later turn is the reply.
    let afterTurn: String?
}

/// The reply that took over the placeholder's row and when (system uptime), until its halo settled.
struct ChatLandedReply: Equatable {
    let rowID: String
    let at: TimeInterval
}

/// Where the reply halo draws: the rows of one bubble and what the light does there.
struct ChatReplyHalo: Equatable {
    enum Phase: Equatable {
        case lapping
        /// Fading into the outline from `since` (system uptime).
        case settling(since: TimeInterval)
    }
    let first: String
    let last: String
    let phase: Phase
    /// How long a settle takes; a halo settled longer ago than this draws nothing.
    static let settle: TimeInterval = 1.2

    #if canImport(AppKit)
    @MainActor static func target(_ session: ChatSession, rows: [ChatTranscriptRow],
                                  now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> ChatReplyHalo? {
        if let pending = session.pendingReply, rows.last?.id == pending.id {
            return ChatReplyHalo(first: pending.id, last: pending.id, phase: .lapping)
        }
        guard let landed = session.landedReply, now - landed.at <= settle,
              var end = rows.lastIndex(where: { $0.id == landed.rowID }) else { return nil }
        // The bubble the landed row starts: its later rows until the bubble ends.
        let turn = rows[end].turnID
        while end + 1 < rows.count, !rows[end].bubbleEnd, rows[end + 1].turnID == turn { end += 1 }
        var start = end
        while start > 0, !rows[start].bubbleStart, rows[start - 1].turnID == turn { start -= 1 }
        return ChatReplyHalo(first: rows[start].id, last: rows[end].id, phase: .settling(since: landed.at))
    }
    #endif
}
