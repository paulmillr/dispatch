import Foundation
@preconcurrency import Term

extension TerminalPresence {
    /// What Open in Terminal reads of the pane's emulator before it types (`FilesAsk.ready`, `FilesAsk.typing`): whether a
    /// full-screen program holds the screen, and whether the program asked for bracketed paste. Trust it only while the
    /// presence is `current`.
    var filesTypingState: (alternate: Bool, bracketed: Bool) {
        session.locked { (session.surface.terminal.isAlternate, PasteOptions(session.surface.terminal).bracketed) }
    }
}

extension TerminalPresences {
    /// The node's presence through the session's current client and the pane's id on it, as the Terminal segment opens
    /// it: a presence of a previous connection reattaches through this one.
    func current(_ key: Key, pane: MobilePane, session: HostSession, client: HelperClient) -> TerminalPresence {
        let node = session.topology?.nodes.first { $0.key == pane.key }
        return open(key, feed: HelperTerminalFeed(client: client, terminal: pane.id, features: session.features),
                    terminal: pane.id, client: client, scrollback: TerminalScrollback(multiplexer: session.following),
                    grid: node?.size.map { (Int($0.columns), Int($0.rows)) })
    }
}

/// Open in Terminal's typing (docs/ios.md, Files): the `cd` goes only into a shell whose screen the phone knows as it
/// is now. The caller attaches the pane's presence (a use that shows it, so held output follows again); this waits for
/// it to be `current` (the attachment's screen, or the repaint after a hold, parsed), checks again that the pane is a
/// shell with no full-screen program up, builds the bytes from that screen (bracketed paste as the shell asked for it
/// then), and awaits the helper's answer, all within `limit`. Nothing is retried: a send that failed says so, and one
/// whose delivery is unknown (no answer in time, the link lost, the screen left) says it may have arrived.
///
/// What the phone cannot see: the screen it checks is the one the helper had sent when it answered, so a program that
/// takes the screen between that and the shell reading the input (a command queued just before, a full-screen program
/// starting) gets the bytes. Only the helper, typing against the pane's live state, could close that window.
@MainActor
enum FilesTerminalTyping {
    static let busy = "The terminal is busy."
    static let stale = "The terminal did not show its screen in time, so nothing was typed. Try again."
    static let stopped = "Open in Terminal stopped before typing anything."
    /// herdr sends its own rendering of the pane (always on the alternate screen, its own modes): the program's modes
    /// never reach the phone.
    static let unknownModes = "herdr does not tell the phone what holds this terminal, so nothing was typed. Type the cd in Terminal."
    static let changed = "A full-screen program took the terminal as the folder was typed. Check the terminal."
    static func failed(_ detail: String) -> String { "The cd did not reach the terminal (\(detail)). Nothing was retried." }
    static func uncertain(_ detail: String) -> String {
        "The cd may not have reached the terminal (\(detail)). Check it in Terminal; nothing was retried."
    }
    static func ended(_ event: TerminalFeedEvent) -> String {
        switch event {
        case .failed(let reason): "The terminal is not attached (\(reason)), so nothing was typed."
        default: "The terminal's program has ended, so nothing was typed."
        }
    }

    /// How long the presence may take to show the server's screen, and the whole operation with the helper's answer.
    static let timeout: Duration = .seconds(5)
    static let limit: Duration = .seconds(10)

    /// The helper's codes after which the input may still have been typed.
    static let unknownOutcomes: Set<String> = ["uncertain", "cancelled", "connection_closed", "unavailable", "invalid_response",
                                               "timeout", "deadline", "offline"]

    /// Types ^U `cd '<folder>'` Return into `presence`'s terminal through `send` once the presence is current and
    /// `ready` (the pane's program is a shell, no agent: `FilesAsk.ready`; the screen still shown) still holds. Nil when
    /// the helper took it, else why not. A cancelled caller types nothing once cancelled (a send already going is
    /// cancelled too, its outcome unknown).
    static func type(_ folder: String, into presence: TerminalPresence, ready: () -> Bool,
                     send: @escaping @MainActor (Data) async throws -> Void, timeout: Duration = timeout,
                     limit: Duration = limit, step: Duration = .milliseconds(20)) async -> String? {
        if presence.scrollback == .server { return unknownModes }
        let start = ContinuousClock.now
        let deadline = start + min(timeout, limit)
        while !presence.current {
            if Task.isCancelled { return stopped }
            if let end = presence.ended { return ended(end) }
            guard ContinuousClock.now < deadline else { return stale }
            try? await Task.sleep(for: step)
        }
        guard !Task.isCancelled else { return stopped }
        // Read and built in the turn the send starts in: what is typed matches the screen it was checked on.
        let state = presence.filesTypingState
        guard ready(), !state.alternate, let bytes = FilesAsk.typing(folder, bracketed: state.bracketed) else { return busy }
        let sending = Task { @MainActor in try await send(bytes) }
        let bound = start + limit
        let timer = Task {
            try? await Task.sleep(until: bound)
            sending.cancel()
        }
        let result = await withTaskCancellationHandler { await sending.result } onCancel: { sending.cancel() }
        timer.cancel()
        if case .failure(let error) = result {
            if ContinuousClock.now >= bound { return uncertain("no answer in time") }
            return outcome(error)
        }
        // Seen only when the switch reached the phone before the answer (see above).
        if presence.filesTypingState.alternate { return changed }
        return nil
    }

    /// A send's error as Open in Terminal words it: refused by the helper (not typed), or with an unknown outcome.
    static func outcome(_ error: any Error) -> String {
        guard let failure = error as? HelperFailure, !unknownOutcomes.contains(failure.code) else {
            let detail = (error as? HelperFailure)?.message ?? ""
            return uncertain(detail.isEmpty ? (error is CancellationError ? "stopped" : error.localizedDescription) : detail)
        }
        return failed(failure.message.isEmpty ? failure.code : failure.message)
    }
}
