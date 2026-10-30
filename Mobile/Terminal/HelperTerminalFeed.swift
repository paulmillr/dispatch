import Foundation
import Synchronization

/// A terminal node of a host's helper as a `TerminalFeed`: `terminals.attach` streams the node's output
/// (`terminal.output`), its history position (`terminal.scroll`) and its exit; keys go out through
/// `terminals.input`, sizes through `terminals.resize`, history steps through `terminals.scroll`, the screen through
/// `terminals.publish` (chat input is verified against it), output holds and repaints through `terminals.follow`.
/// A helper that accepted `screens.host` reads tmux and herdr screens itself: the feed then publishes nothing
/// (`hostsScreens`), and with `terminals.follow` too its output can be held while no view shows it (`holdsOutput`).
///
/// Outgoing calls run one at a time in the order they were made (the Mac's `HelperInputQueue` sends input without
/// waiting for each reply): input made while a call is in flight is sent as one batch after it, resizes made meanwhile
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
    let hostsScreens: Bool
    let holdsOutput: Bool

    private enum Operation {
        case attach(TerminalFeedSize)
        case input(Data)
        case resize(TerminalFeedSize)
        /// One step for the server, answering every scroll call it joined.
        case scroll(TerminalScrollRequest, [CheckedContinuation<TerminalScrollResult, Never>])
        case publish(TerminalScreen)
        /// `terminals.follow` on the attachment, answering the caller.
        case follow(Bool, CheckedContinuation<TerminalFollowResult, Never>)
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

    /// `features`: what the connection's hello accepted (`HostSession.features`); none behaves as before them.
    init(client: HelperClient, terminal: UInt64, features: Set<String> = []) {
        self.client = client
        self.terminal = terminal
        hostsScreens = features.contains(HelperSession.screensHost)
        holdsOutput = hostsScreens && features.contains(HelperSession.terminalsFollow)
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
        let previous = shared.state.withLock { state -> (UInt64?, AsyncStream<TerminalFeedEvent>.Continuation?, [Abandoned]) in
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
        for abandoned in previous.2 { abandoned.answer() }
        wake.yield()
        return events
    }

    func detach() {
        let previous = shared.state.withLock { state -> (UInt64?, AsyncStream<TerminalFeedEvent>.Continuation?, [Abandoned])? in
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
        // A scroll step or follow waiting in the queue is answered, never left suspended.
        for abandoned in previous.2 { abandoned.answer() }
    }

    /// A call dropped from the queue whose caller waits: a scroll step answers `failed`, a follow `stale`.
    private enum Abandoned {
        case scroll([CheckedContinuation<TerminalScrollResult, Never>])
        case follow(CheckedContinuation<TerminalFollowResult, Never>)

        init?(_ operation: Operation) {
            switch operation {
            case .scroll(_, let replies): self = .scroll(replies)
            case .follow(_, let reply): self = .follow(reply)
            default: return nil
            }
        }

        func answer() {
            switch self {
            case .scroll(let replies): for reply in replies { reply.resume(returning: .failed) }
            case .follow(let reply): reply.resume(returning: .stale)
            }
        }
    }

    /// Empties the queue; the calls in it whose callers wait, to be answered outside the lock.
    private static func drop(_ queue: inout [(generation: Int, operation: Operation)]) -> [Abandoned] {
        defer { queue.removeAll() }
        return queue.compactMap { Abandoned($0.operation) }
    }

    /// Calls waiting behind the one in flight (tests).
    var queuedCount: Int { shared.state.withLock { $0.queue.count } }

    func send(_ input: Data) {
        guard !input.isEmpty else { return }
        enqueue(.input(input))
    }

    func resize(_ size: TerminalFeedSize) { enqueue(.resize(size)) }

    /// Never for a helper that reads the screens itself: one publication would turn its host reads off.
    func publish(_ screen: TerminalScreen) {
        guard !hostsScreens else { return }
        enqueue(.publish(screen))
    }

    func follow(_ following: Bool) async -> TerminalFollowResult {
        guard holdsOutput else { return .unsupported }
        return await withCheckedContinuation { reply in
            let queued = shared.state.withLock { state -> Bool in
                guard state.attached else { return false }
                state.queue.append((state.generation, .follow(following, reply)))
                return true
            }
            if queued { wake.yield() } else { reply.resume(returning: .stale) }
        }
    }

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
    /// steps answer `failed`, its follows `stale`).
    private static func next(_ shared: Shared) -> (Int, Operation)? {
        let (item, dropped) = shared.state.withLock { state -> ((Int, Operation)?, [Abandoned]) in
            var dropped: [Abandoned] = []
            while let first = state.queue.first, first.generation != state.generation {
                state.queue.removeFirst()
                if let abandoned = Abandoned(first.operation) { dropped.append(abandoned) }
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
        for abandoned in dropped { abandoned.answer() }
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
            // Input, sizes and screens wait for the helper to confirm the attach (`terminal.attached`), as the Mac's do: a
            // multiplexer may refuse input to a terminal it has not attached yet. A failed or ended attach releases them.
            let (confirmed, confirm) = AsyncStream<Void>.makeStream()
            do {
                let request = try await client.attach(.init(terminal: terminal, size: grid(size), takeover: false)) { result in
                    switch result {
                    case .success(.attached), .success(.exit), .failure: confirm.finish()
                    default: break
                    }
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
                if stale {
                    client.connection.cancel(request)
                    confirm.finish()
                }
            } catch {
                confirm.finish()
                emit(.failed(message(error)), true)
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for await _ in confirmed {} }
                // Never held for good by a reply that does not come: the queue goes on as it did before the wait.
                group.addTask { try? await Task.sleep(for: Self.attachWait) }
                await group.next()
                group.cancelAll()
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
        case .follow(let following, let reply):
            guard current(shared, generation) else { reply.resume(returning: .stale); return }
            do {
                try await client.follow(.init(terminal: terminal, following: following))
                reply.resume(returning: .done)
            } catch let failure as HelperFailure where failure.code == "unsupported" {
                reply.resume(returning: .unsupported)
            } catch {
                print("Terminal follow failed: terminal=\(terminal), following=\(following), error=\(message(error))")
                reply.resume(returning: .failed)
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

    /// The longest the queue waits for `terminal.attached`.
    static let attachWait = Duration.seconds(10)

    private static func message(_ error: any Error) -> String {
        guard let failure = error as? HelperFailure else { return error.localizedDescription }
        return failure.message.isEmpty ? failure.code : failure.message
    }
}
