import Foundation
import Synchronization
import UIKit
@preconcurrency import Term

/// Which side keeps a terminal's scrollback, from the backend kind in the topology (docs/ios.md, Helper contract):
/// tmux replays the pane's whole history into the client on every attach, so Term's own scrollback holds it and
/// `terminals.scroll` is never asked; herdr scrolls on the server through `terminals.scroll` and reports
/// `terminal.scroll`. Other multiplexers are learned from the first answer (`scrollback_app_owned`).
enum TerminalScrollback: Equatable, Sendable {
    case client, server, unknown

    /// From the multiplexer's name (`HelperClient.Multiplexer.name` of the node's backend).
    init(multiplexer name: String?) {
        switch name?.lowercased() {
        case "tmux": self = .client
        case "herdr": self = .server
        default: self = .unknown
        }
    }
}

/// The screen the helper verifies chat input against (`terminals.publish`, the Mac's `publishScreen`): the active
/// area's text, the cursor cell, and whether the text after the cursor is all faint (a shell's suggestion).
struct TerminalScreen: Equatable, Sendable {
    var text: String
    var column: UInt32
    var row: UInt32
    var faintTail: Bool
}

/// One terminal node of a host on the phone, attached and parsed whether or not a view shows it: the Chat segment
/// needs it too, since the helper refuses `chat.send` (`terminal_unavailable`) unless someone publishes the
/// terminal's screen. The presence attaches its feed, parses output into its `TerminalSession` (frames only while a
/// `TerminalHostView` shows it), answers the program through the feed, publishes the screen at most 30 times a
/// second, and keeps the scroll model and what the header shows (title, directory, the end).
///
/// Output is coalesced: the feed's events only append to an inbox; a parse task feeds everything that arrived
/// since its last turn in one batch (tmux sends one `terminal.output` per `%output` line, 29 bytes on average), up to
/// `batchLimit` bytes so a frame never waits long for the lock. Nothing is dropped.
@MainActor @Observable
final class TerminalPresence {
    @ObservationIgnored let session: TerminalSession
    @ObservationIgnored private(set) var feed: any TerminalFeed
    @ObservationIgnored var scroll: TerminalScrollModel
    @ObservationIgnored let scrollback: TerminalScrollback
    private(set) var configuration: TerminalConfiguration
    /// The window title (OSC 0/2) and working directory (OSC 7, a path) the program last set.
    private(set) var title: String?
    private(set) var directory: String?
    /// The attachment ended: the process exited or the attachment failed.
    private(set) var ended: TerminalFeedEvent?
    private(set) var attached = false

    /// What the view showing this presence handles (selection, background, bell, clipboard).
    @ObservationIgnored var onViewEvent: ((TerminalSession.Event) -> Void)?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var parser: Task<Void, Never>?
    @ObservationIgnored private var attachments = 0
    /// The current attachment's output; each attachment has its own, so a parse task still draining after `stop`
    /// never takes the next attachment's bytes.
    @ObservationIgnored private var inbox = TerminalInbox()
    @ObservationIgnored private var publication = Publication()
    /// A publication is on its way to the main queue (set by the parse task, cleared when it is scheduled).
    @ObservationIgnored private let publishQueued = TerminalFlag()

    nonisolated static let batchLimit = 256 * 1024
    nonisolated static let publishInterval = Duration.milliseconds(33)

    private struct Publication {
        var last: TerminalScreen?
        var lastTime: ContinuousClock.Instant?
        var pending: Task<Void, Never>?
    }

    /// `grid`: the size to attach at until a view sizes it (the node's size in the topology keeps a shared tmux
    /// window as it is); nil: 80 x 24.
    init(feed: any TerminalFeed, scrollback: TerminalScrollback = .unknown, grid: (columns: Int, rows: Int)? = nil,
         configuration: TerminalConfiguration = TerminalController.storedConfiguration(), scale: Double = 3) {
        self.feed = feed
        self.scrollback = scrollback
        self.configuration = configuration
        scroll = TerminalScrollModel(scrollback: scrollback)
        do { session = try TerminalSession(configuration: configuration, scale: scale) } catch {
            fatalError("The terminal needs Metal and its bundled fonts: \(error)")
        }
        session.setVisible(false)
        session.setFocus(false)
        let grid = grid ?? (80, 24)
        session.setGrid(columns: grid.columns, rows: grid.rows)
        session.output = { [weak feed] data in feed?.send(data) }
        session.onGrid = { [weak self] size in
            guard let self, self.attached else { return }
            self.feed.resize(size)
        }
        session.onEvent = { [weak self] event in self?.handle(event) }
        let queued = publishQueued
        session.onParsed = { [weak self] in
            guard queued.withLock({ queued in defer { queued = true }; return !queued }) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.schedulePublication() } }
        }
    }

    isolated deinit {
        consumer?.cancel()
        parser?.cancel()
        publication.pending?.cancel()
        if attached { feed.detach() }
        session.close()
    }

    /// Attaches the feed at the session's grid (no-op while attached).
    func start() {
        guard !attached else { return }
        attached = true
        ended = nil
        attachments += 1
        // A later attachment repaints the whole screen; the last one stays shown until its first output arrives, so a
        // terminal shown again (or reattached after a reconnect) never flashes empty.
        let repaint = attachments > 1
        let stream = feed.attach(session.currentSize)
        inbox = TerminalInbox()
        let session = session, inbox = inbox, attachment = attachments
        let (signals, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        parser = Task.detached(priority: .userInitiated) {
            var clear = repaint
            for await _ in signals {
                while !Task.isCancelled, let batch = inbox.take(limit: Self.batchLimit) {
                    if clear { session.reset(); clear = false }
                    session.feed(batch)
                }
            }
        }
        consumer = Task.detached(priority: .userInitiated) { [weak self] in
            for await event in stream {
                if case .output(let bytes) = event {
                    if inbox.append(bytes) { signal.yield() }
                } else {
                    await MainActor.run { self?.handle(event, attachment: attachment) }
                }
            }
            signal.finish()
        }
    }

    /// Stops observing; the server-owned session keeps running (docs/architecture.md).
    func stop() {
        guard attached else { return }
        attached = false
        consumer?.cancel()
        consumer = nil
        parser?.cancel()
        parser = nil
        feed.detach()
        inbox.clear()
        publication.pending?.cancel()
        publication = Publication()
    }

    /// The same terminal through a new feed: node ids are per helper process, so after a reconnect Tabs finds the
    /// node by its topology key and hands its new feed here. The screen is cleared and repainted by the new
    /// attachment; a view showing this presence keeps showing it.
    func reattach(_ feed: any TerminalFeed) {
        let wasAttached = attached
        stop()
        self.feed = feed
        session.output = { [weak feed] data in feed?.send(data) }
        scroll.reattached()
        if wasAttached { start() }
    }

    func configure(_ configuration: TerminalConfiguration) {
        guard configuration != self.configuration else { return }
        self.configuration = configuration
        session.configure(configuration)
    }

    /// An event of attachment number `attachment`: one that reaches the main actor after `stop` or a reattach (its
    /// hop was queued before) belongs to an attachment that is gone and must not end the current one.
    private func handle(_ event: TerminalFeedEvent, attachment: Int) {
        guard attached, attachment == attachments else { return }
        switch event {
        case .output: break
        case .attached: session.refresh()
        case .history(let position): scroll.history(position)
        case .clipboard(let bytes): UIPasteboard.general.string = String(decoding: bytes, as: UTF8.self)
        case .exited, .failed:
            ended = event
            attached = false
        }
    }

    private func handle(_ event: TerminalSession.Event) {
        switch event {
        case .title(let text): title = text.isEmpty ? nil : text
        case .pwd(let url): directory = TerminalSubtitle.path(fromWorkingDirectory: url)
        // A program's copy (OSC 52, kitty clipboard): allowed, as on the Mac for hosts with the helper.
        case .clipboard(let text):
            UIPasteboard.general.string = text
            return
        default: break
        }
        onViewEvent?(event)
    }

    /// The screen as the helper reads it (the Mac's `publishScreen`).
    var screen: TerminalScreen {
        session.locked {
            let cursor = session.surface.cursorFaintTail()
            return TerminalScreen(text: String(decoding: session.surface.readText(.active), as: UTF8.self),
                                  column: UInt32(cursor.x), row: UInt32(cursor.y), faintTail: cursor.faint)
        }
    }

    /// After output or input: the screen goes to the helper at most every 33 ms, the latest always last.
    func schedulePublication() {
        publishQueued.withLock { $0 = false }
        guard attached, publication.pending == nil else { return }
        let now = ContinuousClock.now
        let wait = publication.lastTime.map { max(.zero, $0 + Self.publishInterval - now) } ?? .zero
        publication.pending = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard let self, !Task.isCancelled else { return }
            self.publication.pending = nil
            self.publication.lastTime = ContinuousClock.now
            let screen = self.screen
            guard screen != self.publication.last, self.attached else { return }
            self.publication.last = screen
            self.feed.publish(screen)
        }
    }
}

/// Output waiting for the parse task: appends from the feed's events, batches taken in order.
final class TerminalInbox: Sendable {
    private let state = Mutex(Data())

    /// True: the inbox was empty (the parse task needs a signal).
    func append(_ bytes: Data) -> Bool {
        state.withLock { pending in
            let wasEmpty = pending.isEmpty
            pending.append(bytes)
            return wasEmpty
        }
    }

    func clear() { state.withLock { $0 = Data() } }

    /// Up to `limit` bytes, oldest first; nil: empty.
    func take(limit: Int) -> Data? {
        state.withLock { pending in
            guard !pending.isEmpty else { return nil }
            if pending.count <= limit {
                defer { pending = Data() }
                return pending
            }
            let batch = pending.prefix(limit)
            pending = Data(pending.dropFirst(limit))
            return Data(batch)
        }
    }
}

/// A flag shared with the parse task.
final class TerminalFlag: Sendable {
    private let state = Mutex(false)
    func withLock<T>(_ body: (inout Bool) -> T) -> T { state.withLock { body(&$0) } }
}

/// The presences of the terminals the phone shows or chats with, by host and topology key: the Terminal segment and
/// the Chat stream share one per node, and a reconnect hands the same presence the new helper's feed.
///
/// A presence is attached only while something uses it (`retain`/`release`): the Terminal segment while it is on
/// screen, a conversation while its chat needs the screen published. When the last user lets go the attachment ends
/// (nothing is parsed or published) but the presence keeps its last screen, so showing the terminal again draws it at
/// once while the new attachment repaints it. A reconnect reattaches only presences in use.
@MainActor
final class TerminalPresences {
    struct Key: Hashable, Sendable {
        var host: UUID
        /// The node's topology key (tmux `…:%<pane>`, herdr `term_…`): stable across helpers, unlike its id.
        var node: String
    }

    private var presences: [Key: TerminalPresence] = [:]
    /// How many users each presence has (absent: none).
    private var users: [Key: Int] = [:]

    func presence(_ key: Key) -> TerminalPresence? { presences[key] }

    /// The host's nodes with a presence.
    func keys(host: UUID) -> [Key] { presences.keys.filter { $0.host == host } }

    /// Whether something uses the node's presence (it is then kept attached).
    func inUse(_ key: Key) -> Bool { (users[key] ?? 0) > 0 }

    /// The node's presence, made with `feed` on first use; attached while it is in use. An existing one keeps its
    /// feed unless `feed` names another terminal id or another client (a new helper after a reconnect: its node ids
    /// start over, so the same id comes back for an unchanged layout), which it reattaches to. An attachment that
    /// ended (the program exited, the attach failed) is not started again on the same feed: views ask for their
    /// presence on every update.
    func open(_ key: Key, feed: @autoclosure () -> any TerminalFeed, terminal: UInt64? = nil, client: HelperClient? = nil,
              scrollback: TerminalScrollback = .unknown, grid: (columns: Int, rows: Int)? = nil) -> TerminalPresence {
        if let existing = presences[key] {
            let current = existing.feed as? HelperTerminalFeed
            if terminal.map({ $0 != current?.terminal }) == true || client.map({ $0 !== current?.client }) == true {
                existing.reattach(feed())
                if inUse(key) { existing.start() }
            } else if existing.ended == nil, inUse(key) {
                existing.start()
            }
            return existing
        }
        let presence = TerminalPresence(feed: feed(), scrollback: scrollback, grid: grid)
        presences[key] = presence
        if inUse(key) { presence.start() }
        return presence
    }

    /// One more user of the node's presence: it attaches (when it exists and its attachment has not ended).
    func retain(_ key: Key) {
        users[key, default: 0] += 1
        if let presence = presences[key], !presence.attached, presence.ended == nil { presence.start() }
    }

    /// One user fewer: the last one detaches the presence, which keeps its screen for the next time it shows.
    func release(_ key: Key) {
        guard let count = users[key] else { return }
        if count > 1 {
            users[key] = count - 1
            return
        }
        users[key] = nil
        presences[key]?.stop()
    }

    /// The node closed: stop observing it and forget it.
    func close(_ key: Key) {
        users[key] = nil
        presences.removeValue(forKey: key)?.stop()
    }

    /// The host disconnected: every presence of it stops (those in use reattach after the reconnect).
    func stopAll(host: UUID) {
        for (key, presence) in presences where key.host == host { presence.stop() }
    }
}
