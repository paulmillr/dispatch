import Foundation
import Observation
import Synchronization

/// One shell tab as the launch cache keeps it (`HostCacheEntry.shells`): its id, number, the program's title and when it
/// was made. No screen and no state: after a relaunch the tab comes back ended, as a card without a screen.
struct ShellTabEntry: Codable, Equatable, Sendable {
    var id: UUID
    var number: Int
    var title: String?
    var created: Date

    init(id: UUID, number: Int, title: String?, created: Date) {
        self.id = id
        self.number = number
        self.title = title
        self.created = created
    }

    /// An entry without an id or a number is left out (`lenientArray`); a missing title or time takes its default.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        number = try values.decode(Int.self, forKey: .number)
        title = values.lenient(String.self, forKey: .title)
        created = values.lenient(Date.self, forKey: .created, default: .distantPast)
    }
}

/// The shell tabs the phone made on one plain SSH host (docs/ios.md, Plain SSH), held by its `HostSession`: each tab is
/// a PTY channel on the host's own connection, shown in the host's one synthetic space, "Shell" (`MobileTabs.sync`).
///
/// A tab's presence (`TerminalPresences`, key `Key(host, node: "shell:<uuid>")`) is opened when the tab is made and kept
/// attached by this object for as long as the tab exists: detaching a plain shell's feed closes its channel, so the
/// Terminal segment's own use coming and going must not end it. A tab ends with its shell (the presence's `ended`: an
/// exit status, or a failed open) or with the connection (`connectionEnded`, every live tab `.ended(nil)`), and stays
/// as a card with its last screen until it is closed. Nothing reopens an ended shell; New tab makes another.
@MainActor @Observable
final class ShellSessions {
    enum State: Equatable, Sendable {
        case live
        /// The shell's exit status (128 after a signal); nil when it was lost (the channel or the connection closed first).
        case ended(Int32?)

        var isLive: Bool { self == .live }

        /// What a tab's row and its ended card say: nil while live; "Exited", "Exited with status 3", "Session ended".
        var summary: String? {
            switch self {
            case .live: nil
            case .ended(0?): "Exited"
            case .ended(let status?): "Exited with status \(status)"
            case .ended(nil): "Session ended"
            }
        }

        /// The ended card's line under "Session ended": the exit, when there was a status.
        var exitDetail: String? {
            if case .ended(_?) = self { summary } else { nil }
        }
    }

    struct ShellTab: Identifiable, Equatable, Sendable {
        let id: UUID
        /// For the default title ("Shell 2"); increasing per host while the app runs.
        let number: Int
        /// The program's window title (OSC 0/2), while it set one.
        var title: String?
        let created: Date
        /// When output last arrived (at most every `ShellSessions.outputGranularity`); nil before any.
        var lastOutput: Date?
        var state: State

        /// The tab's phone-only key: its `TabRef.key`, its pane's key and its presence's node.
        var key: String { ShellSessions.key(for: id) }
        /// The name it shows: the program's title, else "Shell n".
        var label: String { title ?? "Shell \(number)" }
        /// Its time in the lists (the Activity sort's too): the last output, else when it was made.
        var activity: Date { lastOutput.map { max($0, created) } ?? created }

        var entry: ShellTabEntry { ShellTabEntry(id: id, number: number, title: title, created: created) }
    }

    nonisolated static let keyPrefix = "shell:"
    nonisolated static func key(for id: UUID) -> String { keyPrefix + id.uuidString.lowercased() }
    /// Whether a tab or node key is a shell tab's (helper keys are `tmux:…`, `herdr:…`, `term_…`).
    nonisolated static func isKey(_ key: String) -> Bool { key.hasPrefix(keyPrefix) }
    /// Output dates a tab at most this often: each new date is a sync of the lists.
    nonisolated static let outputGranularity: TimeInterval = 5

    let host: UUID
    private(set) var tabs: [ShellTab] = []
    /// Where the tabs' presences live (the composition's, through `HostSessions.presences`).
    @ObservationIgnored var presences: TerminalPresences = .shared
    /// The current connection's opener (`HostSession.shellOpener`): nil while the host is not plain-connected.
    @ObservationIgnored var opener: @MainActor () -> (any ShellOpener)? = { nil }
    /// Called after the tabs changed by themselves or by a command (the host session reports it, `HostSession.changed`).
    @ObservationIgnored var changed: (@MainActor () -> Void)?
    @ObservationIgnored var now: @Sendable () -> Date = { System.date() }
    /// The next tab's number.
    @ObservationIgnored private var next = 1
    /// The tabs whose presence this object holds a use of.
    @ObservationIgnored private var held: Set<UUID> = []

    init(host: UUID) { self.host = host }

    func tab(_ id: UUID) -> ShellTab? { tabs.first { $0.id == id } }
    func tab(key: String) -> ShellTab? { tabs.first { $0.key == key } }

    /// The presence key of a tab.
    func presenceKey(_ id: UUID) -> TerminalPresences.Key { .init(host: host, node: Self.key(for: id)) }

    /// New tab: a live tab whose presence opens a shell through the current connection (`PlainShellFeed`) and stays
    /// attached until the tab closes. Nil when the host is not plain-connected.
    @discardableResult
    func newTab() -> ShellTab? {
        guard let opener = opener() else { return nil }
        let id = System.uuid(for: "shell")
        let tab = ShellTab(id: id, number: next, title: nil, created: now(), lastOutput: nil, state: .live)
        next += 1
        tabs.append(tab)
        let now = now
        let feed = ShellTabFeed(PlainShellFeed(opener: opener), now: now) { [weak self] date in
            Task { @MainActor in self?.noteOutput(id, at: date) }
        }
        let key = presenceKey(id)
        let presence = presences.open(key, feed: feed)
        presences.retain(key)
        held.insert(id)
        watch(id, presence)
        changed?()
        return tab
    }

    /// Close tab: the tab goes, and its shell with it when live (its presence closes, which closes the channel).
    func close(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        tabs.removeAll { $0.id == id }
        release(id)
        changed?()
    }

    func close(key: String) {
        guard let tab = tab(key: key) else { return }
        close(tab.id)
    }

    /// Close space: every tab.
    func closeAll() {
        guard !tabs.isEmpty else { return }
        let ids = tabs.map(\.id)
        tabs = []
        for id in ids { release(id) }
        changed?()
    }

    /// The connection is gone (a drop, a reconnect, going to the background): its shells died with it, every live tab
    /// ends with no status and stays as a card with its last screen. The host session reports the change.
    func connectionEnded() {
        guard tabs.contains(where: \.state.isLive) else { return }
        for index in tabs.indices where tabs[index].state.isLive {
            tabs[index].state = .ended(nil)
            // Detached now, not when the transport notices: a view shown later starts nothing (the feed refuses a
            // second attachment, and the card shows).
            presences.presence(presenceKey(tabs[index].id))?.stop()
        }
    }

    /// What the launch cache keeps (`HostCache.record(shells:host:)`).
    var entries: [ShellTabEntry] { tabs.map(\.entry) }

    /// The launch cache's tabs, before any connection: ended cards without a screen. Ignored once tabs exist.
    func restore(_ entries: [ShellTabEntry]) {
        guard tabs.isEmpty, !entries.isEmpty else { return }
        tabs = entries.map { ShellTab(id: $0.id, number: $0.number, title: $0.title, created: $0.created, lastOutput: nil, state: .ended(nil)) }
        next = max(next, (entries.map(\.number).max() ?? 0) + 1)
    }

    /// A replacement session of the same host (an edit that changed the connection) takes the tabs, ended by then, and
    /// the uses of their presences.
    func adopt(_ other: ShellSessions) {
        guard other !== self, other.host == host else { return }
        tabs = other.tabs + tabs
        held.formUnion(other.held)
        next = max(next, other.next)
        other.tabs = []
        other.held = []
        for tab in tabs { if let presence = presences.presence(presenceKey(tab.id)) { watch(tab.id, presence) } }
    }

    private func release(_ id: UUID) {
        held.remove(id)
        presences.close(presenceKey(id))
    }

    private func noteOutput(_ id: UUID, at date: Date) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].state.isLive,
              tabs[index].lastOutput.map({ date.timeIntervalSince($0) >= Self.outputGranularity }) ?? true else { return }
        tabs[index].lastOutput = date
        changed?()
    }

    /// The tab follows its presence: the program's title, and the end of its shell.
    private func watch(_ id: UUID, _ presence: TerminalPresence) {
        let (title, ended) = withObservationTracking {
            (presence.title, presence.ended)
        } onChange: { [weak self, weak presence] in
            Task { @MainActor in
                guard let self, let presence, self.tab(id) != nil,
                      self.presences.presence(self.presenceKey(id)) === presence else { return }
                self.watch(id, presence)
            }
        }
        apply(id, title: title, ended: ended)
    }

    private func apply(_ id: UUID, title: String?, ended: TerminalFeedEvent?) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        var tab = tabs[index]
        // An ended card keeps the title it had; a live program's title follows the program (nil: "Shell n" again).
        if tab.state.isLive { tab.title = title }
        if tab.state.isLive, let ended {
            switch ended {
            case .exited(let status): tab.state = .ended(status)
            default: tab.state = .ended(nil)
            }
        }
        guard tab != tabs[index] else { return }
        tabs[index] = tab
        changed?()
    }
}

/// A plain shell's feed as its tab sees it: everything is the `PlainShellFeed`'s, and output also dates the tab, at most
/// every `ShellSessions.outputGranularity` (one hop to the main actor per date, none per output). Events are read only
/// as the presence takes them, so the presence's backpressure still reaches the channel.
final class ShellTabFeed: TerminalFeed {
    let shell: PlainShellFeed
    private let now: @Sendable () -> Date
    private let output: @Sendable (Date) -> Void
    private let last = Mutex<Date?>(nil)

    init(_ shell: PlainShellFeed, now: @escaping @Sendable () -> Date, output: @escaping @Sendable (Date) -> Void) {
        self.shell = shell
        self.now = now
        self.output = output
    }

    var scrollback: TerminalScrollback { shell.scrollback }
    var clipboardWrite: Bool { shell.clipboardWrite }

    func attach(_ size: TerminalFeedSize) -> AsyncStream<TerminalFeedEvent> {
        let events = Events(shell.attach(size).makeAsyncIterator())
        return AsyncStream(unfolding: { [weak self] in
            let event = await events.next()
            if case .output? = event { self?.noteOutput() }
            return event
        })
    }

    func detach() { shell.detach() }
    func send(_ input: Data) { shell.send(input) }
    func resize(_ size: TerminalFeedSize) { shell.resize(size) }
    func scroll(_ request: TerminalScrollRequest) async -> TerminalScrollResult { await shell.scroll(request) }
    func publish(_ screen: TerminalScreen) { shell.publish(screen) }

    private func noteOutput() {
        let date = now()
        let due = last.withLock { last -> Bool in
            if let previous = last, date.timeIntervalSince(previous) < ShellSessions.outputGranularity { return false }
            last = date
            return true
        }
        if due { output(date) }
    }

    /// The shell feed's events, read by one consumer at a time (AsyncStream's single iterator).
    private final class Events: @unchecked Sendable {
        private var iterator: AsyncStream<TerminalFeedEvent>.Iterator
        init(_ iterator: AsyncStream<TerminalFeedEvent>.Iterator) { self.iterator = iterator }
        func next() async -> TerminalFeedEvent? {
            var iterator = self.iterator
            defer { self.iterator = iterator }
            return await iterator.next()
        }
    }
}
