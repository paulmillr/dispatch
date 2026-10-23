import Foundation

/// The last-known state of one host, as the lists need it at launch before any host answers (plan 3.8, "instant
/// launch from cache"): the helper's hello (identity, OS line, homes), the multiplexers and the one followed, the
/// latest topology, Agents' rows (state, a preview no longer than the list shows, time), and a plain SSH host's shell
/// tabs (number, title, creation; never a screen). Nothing else of a transcript is kept, and no secret: what the lists
/// already show.
struct HostCacheEntry: Codable, Equatable, Sendable {
    struct Multiplexer: Codable, Equatable, Sendable {
        let mux: UInt64
        let name: String
        let external: Bool
        let program: String?

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            mux = try values.decode(UInt64.self, forKey: .mux)
            name = try values.decode(String.self, forKey: .name)
            external = values.lenient(Bool.self, forKey: .external, default: true)
            program = values.lenient(String.self, forKey: .program)
        }

        init(_ multiplexer: HelperClient.Multiplexer) {
            mux = multiplexer.mux
            name = multiplexer.name
            external = multiplexer.external
            program = multiplexer.program
        }

        var multiplexer: HelperClient.Multiplexer { HelperClient.Multiplexer(mux: mux, name: name, external: external, program: program) }
    }

    /// One row of Agents (M3a) as the list last showed it.
    struct Conversation: Codable, Equatable, Sendable {
        var busy: Bool
        var subagents: Int
        var attention: String?
        var preview: String?
        var finished: Bool
        var lastActivity: Date?
        var waiting: Bool
        var title: String?

        /// Longest preview kept: two lines of the list, with room to spare.
        static let previewLimit = 280

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            busy = values.lenient(Bool.self, forKey: .busy, default: false)
            subagents = values.lenient(Int.self, forKey: .subagents, default: 0)
            attention = values.lenient(String.self, forKey: .attention)
            preview = values.lenient(String.self, forKey: .preview)
            finished = values.lenient(Bool.self, forKey: .finished, default: false)
            lastActivity = values.lenient(Date.self, forKey: .lastActivity)
            waiting = values.lenient(Bool.self, forKey: .waiting, default: false)
            title = values.lenient(String.self, forKey: .title)
        }

        init(_ summary: ChatConversationSummary) {
            busy = summary.busy
            subagents = summary.subagents
            attention = summary.attention
            preview = summary.preview.map { $0.count > Self.previewLimit ? String($0.prefix(Self.previewLimit)) : $0 }
            finished = summary.finished
            lastActivity = summary.lastActivity
            waiting = summary.waiting
            title = summary.title
        }

        var summary: ChatConversationSummary {
            ChatConversationSummary(busy: busy, subagents: subagents, attention: attention, preview: preview,
                                    finished: finished, lastActivity: lastActivity, waiting: waiting,
                                    title: title)
        }
    }

    var hello: HelperSession.Info?
    var multiplexers: [Multiplexer] = []
    var versions: [String: String] = [:]
    var following: String?
    var topology: HelperTopology?
    /// By topology key.
    var conversations: [String: Conversation] = [:]
    /// When the live data was last written here.
    var saved: Date
    /// When the host's helper last answered (`HostSession.updated`, or a background refresh that reached it): the
    /// host's last update after a relaunch. Nil in older caches, whose `saved` stands in.
    var heard: Date?
    /// The plain SSH shell tabs the phone made on the host (`ShellSessions`), in order: listed after a relaunch as ended
    /// cards without a screen.
    var shells: [ShellTabEntry] = []

    init(saved: Date) { self.saved = saved }

    /// Every field on its own: a missing or unreadable one (another version's hello or topology) takes its default
    /// and the rest of the entry stays.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hello = values.lenient(HelperSession.Info.self, forKey: .hello)
        multiplexers = values.lenientArray(Multiplexer.self, forKey: .multiplexers)
        versions = values.lenientDictionary(String.self, forKey: .versions)
        following = values.lenient(String.self, forKey: .following)
        topology = values.lenient(HelperTopology.self, forKey: .topology)
        conversations = values.lenientDictionary(Conversation.self, forKey: .conversations)
        saved = values.lenient(Date.self, forKey: .saved, default: .distantPast)
        heard = values.lenient(Date.self, forKey: .heard)
        shells = values.lenientArray(ShellTabEntry.self, forKey: .shells)
    }
}

/// Every host's `HostCacheEntry`, in `host-cache.json` in Application Support through `PrivateFile` (owner-only,
/// atomic, out of backups). Read once, synchronously, when the app starts, so the first frame is populated; written a
/// moment after live data changes (coalesced) and at once when the app goes to the background.
@MainActor
final class HostCache {
    private struct Document: Codable {
        var version = 1
        /// By host id.
        var hosts: [String: HostCacheEntry]

        init(hosts: [String: HostCacheEntry]) { self.hosts = hosts }

        /// An entry this build cannot read is left out; the other hosts' stay.
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = values.lenient(Int.self, forKey: .version, default: 1)
            hosts = values.lenientDictionary(HostCacheEntry.self, forKey: .hosts)
        }
    }

    static var file: URL { Home.support.appendingPathComponent("host-cache.json") }

    private(set) var entries: [UUID: HostCacheEntry]
    let url: URL?
    private let now: () -> Date
    private let delay: Duration
    private var pending: Task<Void, Never>?

    /// `url` nil keeps the cache in memory (tests, previews, Debug runs that save nothing).
    init(url: URL? = HostCache.file, now: @escaping () -> Date = Date.init, delay: Duration = .milliseconds(500)) {
        self.url = url
        self.now = now
        self.delay = delay
        let saved = url.flatMap { MobileFiles.read(Document.self, from: $0, version: 1, keep: false)?.hosts } ?? [:]
        entries = Dictionary(saved.compactMap { key, entry in UUID(uuidString: key).map { ($0, entry) } },
                             uniquingKeysWith: { first, _ in first })
    }

    func entry(_ host: UUID) -> HostCacheEntry? { entries[host] }

    /// A connected session's live state (its hello, multiplexers and topology).
    func record(_ session: HostSession) {
        guard session.link.isConnected else { return }
        if session.isPlain {
            // No helper on this connection: the kept spaces are not the host's any more; the rest stays for its labels.
            guard var entry = entries[session.id], entry.topology != nil else { return }
            entry.topology = nil
            write(entry, for: session.id)
            return
        }
        guard let hello = session.hello else { return }
        var entry = entries[session.id] ?? HostCacheEntry(saved: now())
        entry.hello = hello
        entry.multiplexers = session.multiplexers.map(HostCacheEntry.Multiplexer.init)
        entry.versions = session.multiplexerVersions
        entry.following = session.following
        // Only this connection's snapshot replaces the kept one; a live "no spaces" (no server) clears it.
        if session.topologyIsLive { entry.topology = session.topology }
        if let updated = session.updated { entry.heard = updated }
        write(entry, for: session.id)
    }

    /// When the host's helper last answered (`HostSession.updated`), kept for its label after a relaunch: written as
    /// the link changes (a drop, going to the background), not on every ping.
    func record(heard: Date?, host: UUID) {
        guard let heard, var entry = entries[host], entry.heard.map({ $0 < heard }) ?? true else { return }
        entry.heard = heard
        write(entry, for: host)
    }

    /// The last update a relaunch shows for `host`: when it last answered, else when its live data was last saved.
    func updated(_ host: UUID) -> Date? {
        guard let entry = entries[host] else { return nil }
        // An entry without a hello (a plain host's shell tabs alone) was never a helper's answer.
        return entry.heard ?? (entry.saved == .distantPast || entry.hello == nil ? nil : entry.saved)
    }

    /// A host's shell tabs (`ShellSessions.entries`), connected or not: a tab made or closed, a program's new title.
    /// A host without an entry gets one only for tabs.
    func record(shells: [ShellTabEntry], host: UUID) {
        guard var entry = entries[host] ?? (shells.isEmpty ? nil : HostCacheEntry(saved: now())), entry.shells != shells else { return }
        entry.shells = shells
        write(entry, for: host)
    }

    /// Agents' live rows for a connected host: `rows` by topology key; rows of nodes no longer in `present` go.
    func record(conversations rows: [String: ChatConversationSummary], present: Set<String>, host: UUID) {
        guard var entry = entries[host] else { return }
        var conversations = entry.conversations.filter { present.contains($0.key) }
        for (key, summary) in rows { conversations[key] = HostCacheEntry.Conversation(summary) }
        guard conversations != entry.conversations else { return }
        entry.conversations = conversations
        write(entry, for: host)
    }

    /// Replaces a host's entry (the background refresh's results).
    func replace(_ entry: HostCacheEntry, for host: UUID) { write(entry, for: host) }

    func remove(host: UUID) {
        guard entries.removeValue(forKey: host) != nil else { return }
        schedule()
    }

    /// Remove all data: the entries and the file.
    func removeAll() {
        pending?.cancel()
        pending = nil
        entries = [:]
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// Writes now (the app is going to the background, or a background refresh ends).
    func flush() {
        pending?.cancel()
        pending = nil
        save()
    }

    private func write(_ entry: HostCacheEntry, for host: UUID) {
        var entry = entry
        if let previous = entries[host] {
            entry.saved = previous.saved
            guard entry != previous else { return }
        }
        entry.saved = now()
        entries[host] = entry
        schedule()
    }

    private func schedule() {
        guard url != nil, pending == nil else { return }
        let delay = delay
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            self.save()
        }
    }

    private func save() {
        guard let url else { return }
        let hosts = Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) })
        try? MobileFiles.write(Document(hosts: hosts), to: url)
    }
}
