import Foundation
import OSLog
import Synchronization

/// A terminal feed over a PTY shell on the host's own SSH connection (plain SSH mode). Unlike helper feeds, `detach()`
/// closes the channel: nothing on the host keeps the shell.
///
/// One attachment per feed. `attach(size)` opens the channel at that size (the presence attaches at its session's
/// grid, so the PTY starts at the size the view laid out, or 80 x 24 before any layout; later sizes arrive as
/// `resize` = window-change). Its events, in order: `.attached` as soon as the channel is open (there is no server
/// screen to wait for, so it comes before any output), then `.output` as the shell writes, then `.exited(status)`
/// (128 after a signal; nil: the shell was lost with its channel or the connection) when the shell ends; a failed open is `.failed(text)`. Output
/// is read from the channel only as the presence takes it, so the presence's backpressure reaches the SSH window.
/// Input and sizes made while the channel opens are delivered after it opens, in order; nothing is retried (a write
/// that fails is dropped, docs/architecture.md, Delivery). A second `attach` (after the shell ended or was detached)
/// is refused with `.failed`: a shell cannot be reattached, the presence shows the ended card.
final class PlainShellFeed: TerminalFeed {
    static let term = "xterm-256color"
    /// What a second attachment answers.
    static let endedMessage = "This shell has ended."
    private static let log = Logger(subsystem: "yachts.dispatch.mobile", category: "Terminal")

    private enum Operation: Sendable {
        case write(Data)
        case resize(columns: Int, rows: Int)

        var name: String {
            switch self {
            case .write: "write"
            case .resize: "resize"
            }
        }
    }

    private struct State {
        /// `attach` was called: the one attachment has started (or the feed was refused for good).
        var used = false
        var detached = false
        /// The attachment's ordered writes and sizes (nil: not attached, or detached).
        var operations: AsyncStream<Operation>.Continuation?
        var opening: Task<any ShellChannel, any Error>?
    }

    let opener: any ShellOpener
    private let state = Mutex(State())

    init(opener: any ShellOpener) {
        self.opener = opener
    }

    deinit { detach() }

    /// Plain shells keep no history on a server: the emulator's scrollback is the only one.
    var scrollback: TerminalScrollback { .client }

    /// Term's own OSC 52 writes go to the phone's pasteboard: the program is one the user started in a shell they
    /// opened, with no helper or multiplexer between (TerminalConfiguration, clipboard).
    var clipboardWrite: Bool { true }

    func attach(_ size: TerminalFeedSize) -> AsyncStream<TerminalFeedEvent> {
        let (operations, queue) = AsyncStream<Operation>.makeStream()
        let opener = opener
        let columns = max(1, size.columns), rows = max(1, size.rows)
        let opening = state.withLock { state -> Task<any ShellChannel, any Error>? in
            guard !state.used else { return nil }
            state.used = true
            let opening = Task { try await opener.open(term: Self.term, columns: columns, rows: rows) }
            state.opening = opening
            state.operations = queue
            return opening
        }
        guard let opening else {
            queue.finish()
            return AsyncStream { $0.yield(.failed(Self.endedMessage)); $0.finish() }
        }
        // Writes and sizes in the order they were made, once the channel is open; a failed open drops them, and so
        // does a detach (what was still queued is never sent late).
        Task { [weak self] in
            guard let channel = try? await opening.value else { return }
            for await operation in operations {
                guard let self, !self.isDetached else { return }
                do {
                    switch operation {
                    case .write(let data): try await channel.write(data)
                    case .resize(let columns, let rows): try await channel.resize(columns: columns, rows: rows)
                    }
                } catch {
                    Self.log.notice("Plain shell \(operation.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        let reader = Reader(opening: opening, feed: self)
        return AsyncStream(unfolding: { await reader.next() })
    }

    func detach() {
        let (queue, opening) = state.withLock { state -> (AsyncStream<Operation>.Continuation?, Task<any ShellChannel, any Error>?) in
            guard state.used, !state.detached else { return (nil, nil) }
            state.detached = true
            defer { state.operations = nil; state.opening = nil }
            return (state.operations, state.opening)
        }
        queue?.finish()
        guard let opening else { return }
        // Opened before or after the detach, the channel is closed: nothing keeps the shell.
        Task { if let channel = try? await opening.value { await channel.close() } }
    }

    func send(_ input: Data) {
        guard !input.isEmpty else { return }
        enqueue(.write(input))
    }

    func resize(_ size: TerminalFeedSize) {
        enqueue(.resize(columns: max(1, size.columns), rows: max(1, size.rows)))
    }

    /// The emulator scrolls its own history; nothing goes to the host.
    func scroll(_ request: TerminalScrollRequest) async -> TerminalScrollResult { .appOwned }

    /// Nothing verifies chat input against a plain shell.
    func publish(_ screen: TerminalScreen) {}

    private func enqueue(_ operation: Operation) {
        _ = state.withLock { $0.operations }?.yield(operation)
    }

    fileprivate var isDetached: Bool { state.withLock { $0.detached } }

    /// The attachment's events, produced as the presence reads them: the open, then the channel's output, then its end.
    /// `next` is called by one consumer at a time (AsyncStream's single iterator).
    private final class Reader: @unchecked Sendable {
        private enum Phase {
            case opening
            case streaming(any ShellChannel, AsyncStream<Data>.Iterator)
            case done
        }

        private let opening: Task<any ShellChannel, any Error>
        private weak var feed: PlainShellFeed?
        private var phase = Phase.opening

        init(opening: Task<any ShellChannel, any Error>, feed: PlainShellFeed) {
            self.opening = opening
            self.feed = feed
        }

        func next() async -> TerminalFeedEvent? {
            switch phase {
            case .done:
                return nil
            case .opening:
                do {
                    let channel = try await opening.value
                    phase = .streaming(channel, channel.output.makeAsyncIterator())
                    return detached ? finish() : .attached
                } catch {
                    phase = .done
                    return detached ? nil : .failed(Self.message(error))
                }
            case .streaming(let channel, var iterator):
                let data = await iterator.next()
                if let data {
                    phase = .streaming(channel, iterator)
                    return detached ? finish() : .output(data)
                }
                phase = .done
                // The end of the output is the end of the shell; a detach (or a cancelled read) closed it ourselves.
                guard !detached, !Task.isCancelled else { return nil }
                let exit = await channel.exit()
                // Ended: its channel is closed now, not when its tab closes (the fd and the engine's handle go with it).
                await channel.close()
                guard !detached else { return nil }
                switch exit {
                case .status(let status): return .exited(status)
                case .lost: return .exited(nil)
                }
            }
        }

        private var detached: Bool { feed?.isDetached ?? true }

        private func finish() -> TerminalFeedEvent? {
            phase = .done
            return nil
        }

        private static func message(_ error: any Error) -> String {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return text.isEmpty ? "The shell could not be opened." : text
        }
    }
}
