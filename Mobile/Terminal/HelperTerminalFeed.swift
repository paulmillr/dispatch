import Foundation
import Synchronization

/// A terminal node of a host's helper as a `TerminalFeed`: `terminals.attach` streams the node's output
/// (`terminal.output`), its history position (`terminal.scroll`) and its exit; keys go out through
/// `terminals.input`, sizes through `terminals.resize`, history steps through `terminals.scroll`, the screen through
/// `terminals.publish` (chat input is verified against it).
///
/// Outgoing calls run one at a time in the order they were made, like the Mac's per-tab input chain
/// (`HelperWorkspace`): input made while a call is in flight is sent as one batch after it, resizes made meanwhile
/// collapse into the latest, and so do publications. Scroll steps made meanwhile join into one step (a finger makes
/// one per line, and each waited a round trip: over a real link a swipe trailed the finger by seconds and held the
/// keys behind it). A detach drops what its attachment had not sent yet. Nothing is retried.
final class HelperTerminalFeed: TerminalFeed {
    /// The AsyncStream is count-bounded, so split untrusted output first to make its memory bound meaningful.
    private static let outputChunk = 64 * 1024
    /// A whole reply the connection accepts (its aggregate bound), split into chunks, plus the small events around
    /// it: a reply is yielded in one go, faster than the presence takes it, and an event the stream drops ends the
    /// attachment.
    private static let eventBufferCount = HelperConnection.replyLimit / outputChunk + 128

    let client: HelperClient
    let terminal: UInt64

    private enum Operation {
        case attach(TerminalFeedSize)
        case input(Data)
        case resize(TerminalFeedSize)
        /// One step for the server, answering every scroll call it joined.
        case scroll(TerminalScrollRequest, [CheckedContinuation<TerminalScrollResult, Never>])
        case publish(TerminalScreen)
    }

    private struct State {
        /// Counts attachments: work and updates of an older one are dropped.
        var generation = 0
        var attached = false
        /// The attach request (the observer to cancel at detach), once the helper took it.
        var request: UInt64?
        var events: AsyncStream<TerminalFeedEvent>.Continuation?
        var queue: [(generation: Int, operation: Operation)] = []
    }

    private final class Shared: Sendable {
        let state = Mutex(State())
    }

    private let shared = Shared()
    private let wake: AsyncStream<Void>.Continuation
    private let worker: Task<Void, Never>

    init(client: HelperClient, terminal: UInt64) {
        self.client = client
        self.terminal = terminal
        let (signals, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.wake = wake
        let shared = shared
        worker = Task { [client, terminal] in
            for await _ in signals {
                while let (generation, operation) = Self.next(shared) {
                    await Self.perform(operation, generation: generation, client: client, terminal: terminal, shared: shared)
                }
            }
        }
    }

    deinit {
        detach()
        wake.finish()
        worker.cancel()
    }

    func attach(_ size: TerminalFeedSize) -> AsyncStream<TerminalFeedEvent> {
        let (events, continuation) = AsyncStream<TerminalFeedEvent>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.eventBufferCount))
        let previous = shared.state.withLock { state -> (UInt64?, AsyncStream<TerminalFeedEvent>.Continuation?, [ScrollReply]) in
            defer {
                state.generation += 1
                state.attached = true
                state.request = nil
                state.events = continuation
                state.queue.append((state.generation, .attach(size)))
            }
            return (state.request, state.events, Self.drop(&state.queue))
        }
        if let request = previous.0 { client.connection.cancel(request) }
        previous.1?.finish()
        for reply in previous.2 { reply.resume(returning: .failed) }
        wake.yield()
        return events
    }

    func detach() {
        let previous = shared.state.withLock { state -> (UInt64?, AsyncStream<TerminalFeedEvent>.Continuation?, [ScrollReply])? in
            guard state.attached else { return nil }
            defer {
                state.generation += 1
                state.attached = false
                state.request = nil
                state.events = nil
            }
            return (state.request, state.events, Self.drop(&state.queue))
        }
        guard let previous else { return }
        if let request = previous.0 { client.connection.cancel(request) }
        previous.1?.finish()
        // A scroll step waiting in the queue is answered, never left suspended.
        for reply in previous.2 { reply.resume(returning: .failed) }
    }

    private typealias ScrollReply = CheckedContinuation<TerminalScrollResult, Never>

    /// Empties the queue; the scroll steps in it, to be answered `failed` outside the lock.
    private static func drop(_ queue: inout [(generation: Int, operation: Operation)]) -> [ScrollReply] {
        defer { queue.removeAll() }
        return queue.flatMap { item -> [ScrollReply] in
            if case .scroll(_, let replies) = item.operation { replies } else { [] }
        }
    }

    /// Calls waiting behind the one in flight (tests).
    var queuedCount: Int { shared.state.withLock { $0.queue.count } }

    func send(_ input: Data) {
        guard !input.isEmpty else { return }
        enqueue(.input(input))
    }

    func resize(_ size: TerminalFeedSize) { enqueue(.resize(size)) }

    func publish(_ screen: TerminalScreen) { enqueue(.publish(screen)) }

    func scroll(_ request: TerminalScrollRequest) async -> TerminalScrollResult {
        await withCheckedContinuation { reply in
            let queued = shared.state.withLock { state -> Bool in
                guard state.attached else { return false }
                state.queue.append((state.generation, .scroll(request, [reply])))
                return true
            }
            if queued { wake.yield() } else { reply.resume(returning: .failed) }
        }
    }

    private func enqueue(_ operation: Operation) {
        let queued = shared.state.withLock { state -> Bool in
            guard state.attached else { return false }
            state.queue.append((state.generation, operation))
            return true
        }
        if queued { wake.yield() }
    }

    /// The next call to make: consecutive input joins into one batch, consecutive resizes keep the latest, consecutive
    /// scroll steps of the same kind add up (at the latest cell). Work of an older attachment is dropped (its scroll
    /// steps answer `failed`).
    private static func next(_ shared: Shared) -> (Int, Operation)? {
        let (item, dropped) = shared.state.withLock { state -> ((Int, Operation)?, [CheckedContinuation<TerminalScrollResult, Never>]) in
            var dropped: [CheckedContinuation<TerminalScrollResult, Never>] = []
            while let first = state.queue.first, first.generation != state.generation {
                state.queue.removeFirst()
                if case .scroll(_, let replies) = first.operation { dropped += replies }
            }
            guard !state.queue.isEmpty else { return (nil, dropped) }
            var (generation, operation) = state.queue.removeFirst()
            while let following = state.queue.first, following.generation == generation {
                switch (operation, following.operation) {
                case (.input(let a), .input(let b)): operation = .input(a + b)
                case (.resize, .resize(let latest)): operation = .resize(latest)
                case (.publish, .publish(let latest)): operation = .publish(latest)
                case (.scroll(let a, let first), .scroll(let b, let second)) where a.page == b.page && a.modifiers == b.modifiers:
                    var joined = b
                    joined.lines = a.lines + b.lines
                    operation = .scroll(joined, first + second)
                default: return ((generation, operation), dropped)
                }
                state.queue.removeFirst()
            }
            return ((generation, operation), dropped)
        }
        for reply in dropped { reply.resume(returning: .failed) }
        return item
    }

    private static func current(_ shared: Shared, _ generation: Int) -> Bool {
        shared.state.withLock { $0.generation == generation && $0.attached }
    }

    private static func grid(_ size: TerminalFeedSize) -> HelperTopology.Grid {
        let clamp = { (value: Int) in UInt16(clamping: max(0, value)) }
        return HelperTopology.Grid(columns: max(1, clamp(size.columns)), rows: max(1, clamp(size.rows)),
                                   cell_width: size.cellWidth > 0 ? clamp(size.cellWidth) : nil,
                                   cell_height: size.cellHeight > 0 ? clamp(size.cellHeight) : nil)
    }

    private static func perform(_ operation: Operation, generation: Int, client: HelperClient, terminal: UInt64,
                                shared: Shared) async {
        switch operation {
        case .attach(let size):
            let emit = { @Sendable (event: TerminalFeedEvent, last: Bool) -> Bool in
                let events = shared.state.withLock { state -> AsyncStream<TerminalFeedEvent>.Continuation? in
                    guard state.generation == generation else { return nil }
                    if last { state.attached = false }
                    return state.events
                }
                guard let events else { return false }
                let accepted: Bool
                switch events.yield(event) {
                case .enqueued: accepted = true
                case .dropped, .terminated: accepted = false
                @unknown default: accepted = false
                }
                if last { events.finish() }
                if !accepted { events.finish() }
                return accepted
            }
            do {
                let request = try await client.attach(.init(terminal: terminal, size: grid(size), takeover: false)) { result in
                    switch result {
                    case .success(.output(let output)) where output.terminal == terminal:
                        var offset = output.bytes.startIndex
                        while offset < output.bytes.endIndex {
                            let end = min(offset + Self.outputChunk, output.bytes.endIndex)
                            guard emit(.output(Data(output.bytes[offset..<end])), false) else { break }
                            offset = end
                        }
                    case .success(.history(let history)) where history.terminal == terminal:
                        _ = emit(.history(.init(offset: history.offset, maximum: history.max, viewport: history.viewport)), false)
                    case .success(.attached): _ = emit(.attached, false)
                    case .success(.exit(let exit)) where exit.terminal == terminal: _ = emit(.exited(exit.status), true)
                    // There is no mobile consent surface for a remote helper to write the system clipboard.
                    case .success(.clipboard): break
                    case .failure(let error): _ = emit(.failed(Self.message(error)), true)
                    default: break
                    }
                }
                let stale = shared.state.withLock { state -> Bool in
                    guard state.generation == generation else { return true }
                    state.request = request
                    return false
                }
                if stale { client.connection.cancel(request) }
            } catch {
                emit(.failed(message(error)), true)
            }
        case .input(let bytes):
            guard current(shared, generation) else { return }
            do { try await client.input(.init(terminal: terminal, bytes: bytes)) } catch {
                // Uncertain delivery is never retried; the attachment stays.
                print("Terminal input failed: terminal=\(terminal), error=\(message(error))")
            }
        case .resize(let size):
            guard current(shared, generation) else { return }
            do { try await client.resize(.init(terminal: terminal, size: grid(size))) } catch {
                print("Terminal resize failed: terminal=\(terminal), error=\(message(error))")
            }
        case .publish(let screen):
            guard current(shared, generation) else { return }
            do {
                try await client.publish(.init(terminal: terminal, text: screen.text, cursor: .init(column: screen.column, row: screen.row),
                                               faint_tail: screen.faintTail))
            } catch {
                print("Terminal publish failed: terminal=\(terminal), error=\(message(error))")
            }
        case .scroll(let request, let replies):
            let answer = { (result: TerminalScrollResult) in for reply in replies { reply.resume(returning: result) } }
            guard current(shared, generation) else { answer(.failed); return }
            let at = { (value: Int?) in value.map { UInt16(clamping: max(0, $0)) } }
            do {
                try await client.scroll(.init(terminal: terminal, lines: Int64(request.lines), page: request.page,
                                              column: at(request.column), row: at(request.row), modifiers: request.modifiers))
                answer(.server)
            } catch let failure as HelperFailure where failure.code == "scrollback_app_owned" {
                answer(.appOwned)
            } catch {
                answer(.failed)
            }
        }
    }

    private static func message(_ error: any Error) -> String {
        guard let failure = error as? HelperFailure else { return error.localizedDescription }
        return failure.message.isEmpty ? failure.code : failure.message
    }
}
