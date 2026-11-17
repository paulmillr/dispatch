import Foundation

/// Agents' foreground read of every host's rows (docs/ios.md, Agents), on the shared clock's 15 s ticks
/// (`HostTraffic`), so its `chat.list` leaves with the stats' samples and the ping instead of on a clock of its own.
/// The helper's activity push (`agents.activity`, `ChatConversations.activityChanged`) brings most changes; the poll
/// catches what it cannot: Pi agents (no transcript watch), a change of `attention` alone, and a connection kept through
/// the background linger, whose rows nothing else reads again. So it reads at once when it starts (the foreground's
/// first read), then a host whose helper pushes every fourth tick (once a minute, on the minute) and a host with a
/// bound Pi agent or without the push every tick (`ChatConversations.pollsEveryTick`). Under frugal mode (`Frugal`) only
/// the fourth ticks read, for every host. Runs between `start` and `stop` (the app in the foreground).
@MainActor
final class AgentsPoll {
    /// A host whose helper pushes its agents' changes is read on every this many ticks.
    nonisolated static let quietTicks = 4

    private let conversations: ChatConversations
    var now: @MainActor () -> Date = { System.date() }
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var frugal: @MainActor () -> Bool = { Frugal.active }
    private var task: Task<Void, Never>?

    init(conversations: ChatConversations) {
        self.conversations = conversations
    }

    var running: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        let conversations = conversations, now = now, sleep = sleep, frugal = frugal
        task = Task {
            // The foreground's first read: a lingering connection is the same client, which `update` would not refetch.
            await conversations.refreshAll()
            while !Task.isCancelled {
                let date = now()
                // The next tick at least a second away: never two reads a moment apart.
                let tick = HostTraffic.tick(after: date, minimum: .seconds(1))
                do { try await sleep(.milliseconds(Int((tick.timeIntervalSince(date) * 1000).rounded(.up)))) } catch { return }
                guard !Task.isCancelled else { return }
                await conversations.poll(quiet: Self.quiet(tick), frugal: frugal())
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Whether `tick` (of the shared clock) is one of every `quietTicks`: once a minute on the wall clock, so every host
    /// is read on the same ticks, which are also the frugal stats' (every other tick).
    nonisolated static func quiet(_ tick: Date) -> Bool {
        let index = Int((tick.timeIntervalSinceReferenceDate / HostTraffic.interval.seconds).rounded())
        return index % quietTicks == 0
    }
}
