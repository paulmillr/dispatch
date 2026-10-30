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

/// One terminal node of a host on the phone, attached whether or not a view shows it: the Chat segment needs it too,
/// since the helper verifies `chat.send` against the terminal's screen, which it reads only for an attached terminal:
/// from tmux or herdr itself when its hello accepted `screens.host` (`TerminalFeed.hostsScreens`), else from the
/// screens a client publishes (`terminal_unavailable` without one). The presence attaches its feed, parses output into
/// its `TerminalSession` (frames only while a `TerminalHostView` shows it), answers the program through the feed,
/// publishes the screen at most 30 times a second to a helper that does not read it itself (and reads nothing for one
/// that does), and keeps the scroll model and what the header shows (title, directory, the end).
///
/// Held output (`terminals.follow`, `TerminalFeed.holdsOutput`): while no terminal view shows an attached presence (only
/// a conversation uses it: the Chat segment, another tab), its output is held on the host after `followGrace`, so
/// nothing arrives, is parsed or drawn; a view showing it again asks for one whole repaint at once, which is parsed as
/// ordinary output (tmux: `\ec` and the whole history; herdr: the alternate screen's full frame).
///
/// Output is coalesced: the feed's events only append to an inbox; a parse task feeds everything that arrived
/// since its last turn in one batch (tmux sends one `terminal.output` per `%output` line, 29 bytes on average), up to
/// `batchLimit` bytes so a frame never waits long for the lock. Nothing is dropped.
@MainActor @Observable
final class TerminalPresence {
    @ObservationIgnored let session: TerminalSession
    @ObservationIgnored private(set) var feed: any TerminalFeed
    @ObservationIgnored var scroll: TerminalScrollModel
    @ObservationIgnored private(set) var scrollback: TerminalScrollback
    private(set) var configuration: TerminalConfiguration
    /// The window title (OSC 0/2) and working directory (OSC 7, a path) the program last set.
    private(set) var title: String?
    private(set) var directory: String?
    /// The attachment ended: the process exited or the attachment failed.
    private(set) var ended: TerminalFeedEvent?
    private(set) var attached = false
    /// The conversations sending through this terminal now (`chat.send`, a queue start, an answer: the helper verifies
    /// them against the screen this presence publishes). Reset terminal waits for them.
    private(set) var chatSends: Set<AnyHashable> = []
    var chatSending: Bool { !chatSends.isEmpty }
    /// The grid the screen is laid out at when it is not the view's: tmux keeps one size per window for every client,
    /// so while another client (the Mac) holds the window at its size, output comes for that grid. As the Mac's
    /// `tmuxGrid`, the view then draws it at the same font size from the top left, and keeps asking for its own.
    private(set) var shownGrid: (columns: Int, rows: Int)?
    /// The view's own grid, the size `resize` asks for.
    @ObservationIgnored private var available: TerminalFeedSize?
    /// The window's size on the server (the topology's `size`, tmux only).
    @ObservationIgnored private var serverGrid: (columns: Int, rows: Int)?
    @ObservationIgnored private var lastResize = ContinuousClock.now - .seconds(60)
    @ObservationIgnored private var settling: Task<Void, Never>?
    /// The view's grid waiting for its run to settle (`resizeQuiet`) before the feed gets it.
    @ObservationIgnored private var resizing: Task<Void, Never>?
    /// The grid the feed last got (or attached at).
    @ObservationIgnored private var sent: TerminalFeedSize?
    /// The view showing this presence lays out again (the shown grid changed).
    @ObservationIgnored var relayout: (() -> Void)?
    /// A server size different from the view's right after a resize is the old one: the server's comes within this.
    nonisolated static let resizeSettle = Duration.milliseconds(1500)
    /// A run of grid changes (a live window resize, a pinch, the keyboard's frames) reaches the server once, at its
    /// last size, when none has come for this long: each `terminals.resize` makes tmux and the program redraw, and
    /// the redraws of sizes the view has already left arrived after it and repainted the screen at the wrong size,
    /// several times over. The view's own grid follows every frame, as the Mac's does in a live resize.
    nonisolated static let resizeQuiet = Duration.milliseconds(100)

    /// What the view showing this presence handles (selection, background, bell).
    @ObservationIgnored var onViewEvent: ((TerminalSession.Event) -> Void)?
    /// Where a program's clipboard write goes (only from a feed with `clipboardWrite`); tests give their own.
    @ObservationIgnored var pasteboard: @MainActor (String) -> Void = TerminalPresence.systemPasteboard
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var parser: Task<Void, Never>?
    @ObservationIgnored private(set) var attachments = 0
    /// The current attachment's output; each attachment has its own, so a parse task still draining after `stop`
    /// never takes the next attachment's bytes.
    @ObservationIgnored private var inbox = TerminalInbox()
    @ObservationIgnored private var publication = Publication()
    /// A publication is on its way to the main queue (set by the parse task, cleared when it is scheduled).
    @ObservationIgnored private let publishQueued = TerminalFlag()
    /// The current attachment publishes its screens (its helper does not read them itself): the parse task asks for
    /// no publication otherwise, so nothing reads the screen's text.
    @ObservationIgnored private let publishing = TerminalFlag()
    /// How many terminal views show this presence (`TerminalPresences.retain(_:showing:)`).
    @ObservationIgnored private var views = 0
    /// This presence asked the helper to hold the current attachment's output (`terminals.follow` false).
    private(set) var holding = false
    /// Waiting out `followGrace` before the output is held.
    @ObservationIgnored private var grace: Task<Void, Never>?
    /// The `terminals.follow` calls, one after the other in the order asked.
    @ObservationIgnored private var follows: Task<Void, Never>?
    /// The multiplexer answered `unsupported`: this presence keeps following and never asks again.
    @ObservationIgnored private(set) var unfollowable = false
    /// How long no view shows an attached presence before its output is held: a glance at Chat and back holds nothing.
    nonisolated static let followGrace = Duration.seconds(2)
    @ObservationIgnored var followGrace = TerminalPresence.followGrace

    nonisolated static let batchLimit = 256 * 1024
    /// One whole helper reply (an attach replays a tmux pane's entire history as one `terminal.output`, up to the
    /// connection's own bound) arriving before the parse task takes any of it, plus 8 MiB for a rendering stall; never
    /// an unbounded claim on the phone's memory. Overflow ends the attachment: dropping terminal bytes would leave its
    /// parser in a state different from the remote terminal. (8 MiB alone ended every attach of a long history.)
    nonisolated static let inboxLimit = HelperConnection.replyLimit + 8 * 1024 * 1024
    /// Where the consumer stops taking output until the parser drains (`inboxLimit` stays the hard bound).
    nonisolated static let inboxHighWater = 16 * 1024 * 1024
    nonisolated static let publishInterval = Duration.milliseconds(33)

    private struct Publication {
        var last: TerminalScreen?
        var lastTime: ContinuousClock.Instant?
        var pending: Task<Void, Never>?
    }

    /// `grid`: the size to attach at until a view sizes it (the node's size in the topology keeps a shared tmux
    /// window as it is); nil: 80 x 24. `scrollback` unknown takes the feed's own (a plain shell's is the client's),
    /// and the feed decides whether programs may write the pasteboard (`TerminalFeed.clipboardWrite`).
    init(feed: any TerminalFeed, scrollback: TerminalScrollback = .unknown, grid: (columns: Int, rows: Int)? = nil,
         configuration: TerminalConfiguration = TerminalController.storedConfiguration(), scale: Double = 3) {
        let scrollback = scrollback == .unknown ? feed.scrollback : scrollback
        var configuration = configuration
        configuration.clipboardWrite = feed.clipboardWrite
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
            // Laid out at the server's grid: the view asks for its own (`offer`), never for the grid it shows.
            guard let self, self.attached, self.shownGrid == nil else { return }
            self.resize(size)
        }
        session.onEvent = { [weak self] event in self?.handle(event) }
        let queued = publishQueued, publishing = publishing
        session.onParsed = { [weak self] in
            guard publishing.withLock({ $0 }),
                  queued.withLock({ queued in defer { queued = true }; return !queued }) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.schedulePublication() } }
        }
        // A change of system text size scales every open terminal's size by the same ratio (a pinched one too).
        textScale = TerminalAdaptation.textScale(TerminalAdaptation.category)
        textSizeObserver = NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil,
                                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.textSizeChanged(TerminalAdaptation.category) }
        }
        // Settings' terminal style reaches every open terminal at once (its font size stays: a pinch made it).
        styleObserver = NotificationCenter.default.addObserver(forName: TerminalStyle.changed, object: nil, queue: .main) { [weak self] note in
            let style = TerminalStyle(note.object as? UserDefaults ?? .standard)
            MainActor.assumeIsolated { self?.restyle(style) }
        }
    }

    @ObservationIgnored private var styleObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var textSizeObserver: (any NSObjectProtocol)?
    /// The system text size's factor this terminal's size was last scaled for.
    @ObservationIgnored private var textScale = 1.0
    /// The view showing this presence redraws what it draws itself (its background, the selection handles) after a
    /// restyle (`TerminalHostView`).
    @ObservationIgnored var restyled: (() -> Void)?

    /// Settings changed the terminal style: this terminal draws with it, at its own font size, and its view follows.
    func restyle(_ style: TerminalStyle) {
        let next = style.applied(to: configuration)
        guard next != configuration else { return }
        configure(next)
        restyled?()
    }

    /// The system text size changed: this terminal's size moves by the change in its factor, within the terminal's sizes.
    func textSizeChanged(_ category: UIContentSizeCategory) {
        let scale = TerminalAdaptation.textScale(category)
        guard scale != textScale else { return }
        var next = configuration
        let size = (configuration.fontSize * scale / textScale * 100).rounded() / 100
        next.fontSize = min(max(size, TerminalConfiguration.fontSizes.lowerBound), TerminalConfiguration.fontSizes.upperBound)
        textScale = scale
        guard next != configuration else { return }
        configure(next)
        restyled?()
    }

    isolated deinit {
        if let styleObserver { NotificationCenter.default.removeObserver(styleObserver) }
        if let textSizeObserver { NotificationCenter.default.removeObserver(textSizeObserver) }
        settling?.cancel()
        resizing?.cancel()
        consumer?.cancel()
        parser?.cancel()
        publication.pending?.cancel()
        grace?.cancel()
        follows?.cancel()
        if attached { feed.detach() }
        session.close()
    }

    private func resize(_ size: TerminalFeedSize) {
        available = size
        request(size)
    }

    /// The view's own grid while it shows the server's: asked for when it changes.
    func offer(_ size: TerminalFeedSize) {
        guard size != available else { return }
        available = size
        guard attached else { return }
        request(size)
    }

    /// The feed gets `size` once the run it belongs to settles (`resizeQuiet`); a run that ends where it began sends
    /// nothing. Meanwhile the server's size counts as the old one (`evaluate`).
    private func request(_ size: TerminalFeedSize) {
        lastResize = .now
        resizing?.cancel()
        resizing = nil
        if size != sent {
            resizing = Task { [weak self] in
                try? await Task.sleep(for: Self.resizeQuiet)
                guard !Task.isCancelled, let self, self.attached, self.available == size else { return }
                self.resizing = nil
                self.sent = size
                self.lastResize = .now
                self.feed.resize(size)
                self.evaluate()
            }
        }
        evaluate()
    }

    /// The window's size on the server, from each topology (nil: unknown). Only tmux shares one size between clients.
    func server(grid: (columns: Int, rows: Int)?) {
        serverGrid = scrollback == .client ? grid : nil
        evaluate()
    }

    /// The screen follows the server's grid once it has differed from the view's for longer than a resize takes, and
    /// the view's again as soon as they agree: never a frame of a size the server is about to leave.
    private func evaluate() {
        settling?.cancel()
        settling = nil
        guard let server = serverGrid, let available, attached,
              server.columns != available.columns || server.rows != available.rows else {
            if shownGrid != nil { shownGrid = nil; relayout?() }
            return
        }
        if let shown = shownGrid, shown == server { return }
        let waited = ContinuousClock.now - lastResize
        guard waited >= Self.resizeSettle else {
            settling = Task { [weak self] in
                try? await Task.sleep(for: Self.resizeSettle - waited)
                guard !Task.isCancelled else { return }
                self?.evaluate()
            }
            return
        }
        shownGrid = server
        relayout?()
    }

    /// Attaches the feed at the session's grid (no-op while attached).
    func start() {
        guard !attached else { return }
        attached = true
        ended = nil
        attachments += 1
        // A new attachment follows: the helper forgot the last one's hold with it.
        holding = false
        publishing.withLock { $0 = !feed.hostsScreens }
        // A later attachment repaints the whole screen; the last one stays shown until its first output arrives, so a
        // terminal shown again (or reattached after a reconnect) never flashes empty.
        let repaint = attachments > 1
        sent = session.currentSize
        let stream = feed.attach(session.currentSize)
        inbox = TerminalInbox(limit: Self.inboxLimit)
        let session = session, inbox = inbox, attachment = attachments, feed = feed
        let (signals, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // The parse task says when it took a batch, so a consumer ahead of it can wait instead of filling the inbox.
        let (drains, drained) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        parser = Task.detached(priority: .userInitiated) {
            var clear = repaint
            for await _ in signals {
                while !Task.isCancelled, let batch = inbox.take(limit: Self.batchLimit) {
                    drained.yield()
                    if clear { session.reset(); clear = false }
                    session.feed(batch)
                }
            }
            drained.finish()
        }
        consumer = Task.detached(priority: .userInitiated) { [weak self] in
            var draining = drains.makeAsyncIterator()
            for await event in stream {
                if case .output(let bytes) = event {
                    switch inbox.append(bytes) {
                    case .signal: signal.yield()
                    case .queued: break
                    case .overflow:
                        signal.finish()
                        await MainActor.run {
                            self?.end(attachment, feed: feed, "Terminal output exceeded the device buffer limit.")
                        }
                        return
                    }
                    // Backpressure: past the high-water mark the next events wait in the feed's own bounded stream
                    // until the parser catches up, so a burst never reaches the inbox's limit (which ends the
                    // attachment) while the parser is merely behind.
                    while inbox.count > Self.inboxHighWater, !Task.isCancelled {
                        guard await draining.next() != nil else { break }
                    }
                } else {
                    await MainActor.run { self?.handle(event, attachment: attachment) }
                }
            }
            signal.finish()
            // A producer that ends without an exit/failure event overflowed its bounded event queue or broke its
            // subscription. Cancel it and make the loss visible; continuing after dropped terminal bytes is unsafe.
            await MainActor.run { self?.end(attachment, feed: feed, "Terminal output stream ended unexpectedly.") }
        }
        reconsider()
    }

    /// Stops observing; the server-owned session keeps running (docs/architecture.md).
    func stop() {
        guard attached else { return }
        attached = false
        resizing?.cancel()
        resizing = nil
        consumer?.cancel()
        consumer = nil
        parser?.cancel()
        parser = nil
        feed.detach()
        inbox.clear()
        publication.pending?.cancel()
        publication = Publication()
        // The attachment's hold ends with it.
        grace?.cancel()
        grace = nil
        holding = false
    }

    /// Whether a terminal view shows this presence (`TerminalPresences`): hidden, its output is held after
    /// `followGrace`; shown, it follows again at once.
    func show(_ shown: Bool) {
        views = max(0, views + (shown ? 1 : -1))
        reconsider()
    }

    /// Whether a terminal view shows this presence.
    var shown: Bool { views > 0 }

    /// Whether the current attachment's output should be held now: attached, on a helper that reads the screens itself
    /// and holds output (`holdsOutput`), whose multiplexer can repaint, and no terminal view shows it.
    private var holds: Bool { attached && feed.holdsOutput && !unfollowable && !shown }

    /// The view or the attachment changed: hold the output once nothing has shown it for `followGrace`, follow again
    /// at once when a view shows it.
    private func reconsider() {
        guard holds else {
            grace?.cancel()
            grace = nil
            if holding {
                holding = false
                follow(true)
            }
            return
        }
        guard !holding, grace == nil else { return }
        let attachment = attachments, wait = followGrace
        grace = Task { [weak self] in
            do { try await Task.sleep(for: wait) } catch { return }
            guard let self, !Task.isCancelled, self.attachments == attachment else { return }
            self.grace = nil
            guard self.holds, !self.holding else { return }
            self.holding = true
            self.follow(false)
        }
    }

    /// Sends `terminals.follow` for the current attachment after the previous call. `unsupported`: it keeps following
    /// and never asks again. A failed `false` keeps following; a failed `true` leaves the output held, so the terminal
    /// attaches again for a fresh screen. Answers for an attachment that is gone change nothing.
    private func follow(_ following: Bool) {
        let previous = follows, attachment = attachments, feed = feed
        follows = Task { [weak self] in
            await previous?.value
            let result = await feed.follow(following)
            guard let self, self.attached, self.attachments == attachment, self.feed === feed else { return }
            switch result {
            case .done, .stale: break
            case .unsupported:
                self.unfollowable = true
                self.holding = false
            case .failed where following:
                self.reattach(feed)
            case .failed:
                self.holding = false
            }
        }
    }

    /// Reset terminal (the key bar's menu): a new attachment of the same feed, whose first output repaints a terminal
    /// fully reset (RIS) from the server's screen and history, as a reattach does. A feed that ends on detach (a plain
    /// shell), or a presence not attached, resets the emulator alone (Ghostty's `reset`): the program's next output
    /// draws on the fresh terminal.
    /// A send in flight (`chatSending`) refuses it: the reattach would end the attachment the helper is verifying the
    /// send against (its own reads need it as much as a publication does).
    func resetTerminal() {
        guard !chatSending else { return }
        guard attached, !feed.endsOnDetach else {
            session.fullReset()
            return
        }
        // A reattach of the same feed: the server's history position starts over (herdr reports it again).
        reattach(feed)
    }

    /// A conversation (`token`) started or finished sending through this terminal.
    func chat(_ token: AnyHashable, sending: Bool) {
        if sending { chatSends.insert(token) } else { chatSends.remove(token) }
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
        learn(feed.scrollback)
        configure(configuration)
        if wasAttached { start() }
    }

    /// The backend kind, when the presence was made without it (Chat opens presences knowing only the node): a tmux
    /// terminal shown later in the Terminal segment scrolls its own history at once instead of asking the server first.
    func learn(_ scrollback: TerminalScrollback) {
        guard self.scrollback == .unknown, scrollback != .unknown else { return }
        self.scrollback = scrollback
        scroll.learn(scrollback)
    }

    /// A new configuration (font size, theme); whether programs may write the pasteboard stays the feed's.
    func configure(_ configuration: TerminalConfiguration) {
        var configuration = configuration
        configuration.clipboardWrite = feed.clipboardWrite
        guard configuration != self.configuration else { return }
        self.configuration = configuration
        session.configure(configuration)
    }

    /// Attachment number `attachment` lost output: its feed is detached and the end shown, unless it is gone already.
    /// A stream that ended because of `stop` is not a loss, and detaching then would end the next attachment of the
    /// same feed (a segment shown again started it meanwhile): the terminal stayed on screen, but nothing typed reached
    /// it and nothing new was drawn.
    private func end(_ attachment: Int, feed: any TerminalFeed, _ message: String) {
        guard attached, attachment == attachments else { return }
        feed.detach()
        handle(.failed(message), attachment: attachment)
    }

    /// An event of attachment number `attachment`: one that reaches the main actor after `stop` or a reattach (its
    /// hop was queued before) belongs to an attachment that is gone and must not end the current one.
    private func handle(_ event: TerminalFeedEvent, attachment: Int) {
        guard attached, attachment == attachments else { return }
        switch event {
        case .output: break
        case .attached: session.refresh()
        case .history(let position): scroll.history(position)
        // Remote helper clipboard writes are denied on iPhone; only explicit user copy actions touch the pasteboard.
        case .clipboard: break
        case .exited, .failed:
            ended = event
            attached = false
            grace?.cancel()
            grace = nil
            holding = false
        }
    }

    private func handle(_ event: TerminalSession.Event) {
        switch event {
        case .title(let text): title = text.isEmpty ? nil : text
        case .pwd(let url): directory = TerminalSubtitle.path(fromWorkingDirectory: url)
        // A program's OSC 52 write: the session posts it only under `clipboard-write = allow`; checked again here so a
        // configuration slip cannot open the pasteboard to a helper feed.
        case .clipboard(let text):
            if feed.clipboardWrite { pasteboard(text) }
            return
        default: break
        }
        onViewEvent?(event)
    }

    static func systemPasteboard(_ text: String) { UIPasteboard.general.string = text }

    /// How often the screen's text was read for a publication (tests: a helper reading the screens itself costs none).
    @ObservationIgnored private(set) var screensRead = 0

    /// The screen as the helper reads it (the Mac's `publishScreen`).
    var screen: TerminalScreen {
        screensRead += 1
        return session.locked {
            let cursor = session.surface.cursorFaintTail()
            return TerminalScreen(text: String(decoding: session.surface.readText(.active), as: UTF8.self),
                                  column: UInt32(cursor.x), row: UInt32(cursor.y), faintTail: cursor.faint)
        }
    }

    /// After output or input: the screen goes to the helper at most every 33 ms, the latest always last; never to a
    /// helper that reads it itself (`hostsScreens`).
    func schedulePublication() {
        publishQueued.withLock { $0 = false }
        guard attached, !feed.hostsScreens, publication.pending == nil else { return }
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
    enum Append: Equatable { case signal, queued, overflow }

    /// The bytes and where the next batch starts: a batch is taken by moving `head`, never by copying what is left
    /// (which made draining a full inbox quadratic: every 256 KiB batch copied the tens of MiB behind it).
    private struct Pending {
        var bytes = Data()
        var head = 0
        var count: Int { bytes.count - head }
    }

    private let state = Mutex(Pending())
    private let limit: Int

    init(limit: Int = TerminalPresence.inboxLimit) { self.limit = limit }

    /// `signal`: the inbox was empty (the parse task needs a signal); `overflow`: no bytes were appended.
    func append(_ bytes: Data) -> Append {
        state.withLock { pending in
            guard pending.count <= limit, bytes.count <= limit - pending.count else { return .overflow }
            let wasEmpty = pending.count == 0
            pending.bytes.append(bytes)
            return wasEmpty ? .signal : .queued
        }
    }

    /// The bytes waiting for the parse task.
    var count: Int { state.withLock { $0.count } }

    func clear() { state.withLock { $0 = Pending() } }

    /// Up to `limit` bytes, oldest first; nil: empty.
    func take(limit: Int) -> Data? {
        state.withLock { pending in
            guard pending.count > 0 else { return nil }
            let start = pending.bytes.startIndex + pending.head
            let end = start + min(limit, pending.count)
            let batch = Data(pending.bytes[start..<end])
            pending.head += end - start
            if pending.count == 0 {
                pending = Pending()
            } else if pending.head >= pending.bytes.count / 2 {
                // Taken bytes go once they are half the buffer: each byte is moved at most once more, on average.
                pending.bytes.removeSubrange(pending.bytes.startIndex..<pending.bytes.startIndex + pending.head)
                pending.head = 0
            }
            return batch
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
/// screen (`showing`), a conversation while its chat needs the terminal attached. When the last user lets go the
/// attachment ends (nothing is parsed or published) but the presence keeps its last screen, so showing the terminal
/// again draws it at once while the new attachment repaints it. A presence only conversations use holds its output
/// (`TerminalPresence.show`). A reconnect reattaches only presences in use.
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
    /// How many of them are terminal views (absent: none).
    private var views: [Key: Int] = [:]

    func presence(_ key: Key) -> TerminalPresence? { presences[key] }

    /// The host's nodes with a presence.
    func keys(host: UUID) -> [Key] { presences.keys.filter { $0.host == host } }

    /// Whether something uses the node's presence (it is then kept attached).
    func inUse(_ key: Key) -> Bool { (users[key] ?? 0) > 0 }

    /// The node's presence, made with `feed` on first use; attached while it is in use. An existing one keeps its
    /// feed unless `feed` names another terminal id or another client (a new helper after a reconnect: its node ids
    /// start over, so the same id comes back for an unchanged layout), which it reattaches to. An attachment that
    /// ended (the program exited, the attach failed) is not started again on the same feed: views ask for their
    /// presence on every update. A plain shell (`shell:<uuid>`, `PlainShellFeed`) never reattaches here (it names no
    /// terminal or client), scrolls locally from the start (the feed's `scrollback`), and ends when its last user lets
    /// go: its detach closes the channel.
    func open(_ key: Key, feed: @autoclosure () -> any TerminalFeed, terminal: UInt64? = nil, client: HelperClient? = nil,
              scrollback: TerminalScrollback = .unknown, grid: (columns: Int, rows: Int)? = nil) -> TerminalPresence {
        if let existing = presences[key] {
            existing.learn(scrollback)
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
        for _ in 0..<(views[key] ?? 0) { presence.show(true) }
        if inUse(key) { presence.start() }
        return presence
    }

    /// One more user of the node's presence: it attaches (when it exists and its attachment has not ended).
    /// `showing`: the user is a terminal view on screen (the Terminal segment), which keeps its output following.
    func retain(_ key: Key, showing: Bool = false) {
        users[key, default: 0] += 1
        if showing {
            views[key, default: 0] += 1
            presences[key]?.show(true)
        }
        if let presence = presences[key], !presence.attached, presence.ended == nil { presence.start() }
    }

    /// One user fewer (`showing` as it was retained): the last one detaches the presence, which keeps its screen for the
    /// next time it shows; the last view leaves the rest holding its output.
    func release(_ key: Key, showing: Bool = false) {
        guard let count = users[key] else { return }
        if count > 1 {
            users[key] = count - 1
        } else {
            users[key] = nil
            presences[key]?.stop()
        }
        if showing, let shown = views[key] {
            views[key] = shown > 1 ? shown - 1 : nil
            presences[key]?.show(false)
        }
    }

    /// The node closed: stop observing it and forget it.
    func close(_ key: Key) {
        users[key] = nil
        views[key] = nil
        presences.removeValue(forKey: key)?.stop()
    }

    /// Each terminal's window size on the server, from the host's topology (`TerminalPresence.server(grid:)`).
    func serverGrids(host: UUID, topology: HelperTopology) {
        for node in topology.nodes where node.kind == .terminal {
            presences[Key(host: host, node: node.key)]?.server(grid: node.size.map { (Int($0.columns), Int($0.rows)) })
        }
    }

    /// The host disconnected: every presence of it stops (those in use reattach after the reconnect).
    func stopAll(host: UUID) {
        for (key, presence) in presences where key.host == host { presence.stop() }
    }
}
