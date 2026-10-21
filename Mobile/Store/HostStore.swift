import Foundation
import Observation

/// Where the iPhone app keeps its own files: Application Support in the app container, out of device backups.
/// Nothing here syncs or leaves the phone (plan 3.6).
enum MobileFiles {
    static var hosts: URL { Home.support.appendingPathComponent("hosts.json") }
    static var keys: URL { Home.support.appendingPathComponent("keys.json") }
    static var knownHosts: URL { Home.support.appendingPathComponent("known_hosts.json") }

    /// A versioned JSON document, or nil when missing, unreadable or from another version. A file that is there but
    /// cannot be read is moved aside (`<name>.unreadable-<time>`, still private and out of backups) unless `keep` is
    /// false: the store starts empty, and its next save must not write over the only copy of the user's hosts, keys or
    /// trusted host keys. Remove all data deletes the moved files too (`removeUnreadable`).
    static func read<Value: Decodable>(_ type: Value.Type, from url: URL, version: Int, keep: Bool = true) -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let data = try? Data(contentsOf: url),
           let envelope = try? decoder.decode(Envelope.self, from: data), envelope.version == version,
           let value = try? decoder.decode(type, from: data) {
            return value
        }
        if keep { try? moveAside(url) }
        return nil
    }

    /// Moves an unreadable file aside (`<name>.unreadable-<time>`, still private and out of backups).
    static func moveAside(_ url: URL) throws {
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + unreadable + String(Int(Date().timeIntervalSince1970)) + "-"
                + UUID().uuidString.prefix(8).lowercased())
        try FileManager.default.moveItem(at: url, to: aside)
    }

    private static let unreadable = ".unreadable-"

    /// The files `read` moved aside in `directory` (Settings' Remove all data).
    static func removeUnreadable(in directory: URL = Home.support) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.contains(unreadable) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private struct Envelope: Decodable { let version: Int }

    /// Moves the files older builds wrote as class A (`complete`: unreadable while the phone is locked) in `directory`
    /// to `PrivateFile`'s class C, so a watch request with the phone locked can read them. Run while the phone is
    /// unlocked: a class A file's class cannot change while it is locked. Returns how many moved; a second run moves
    /// none (the simulator reports no class, so it never moves anything there).
    @discardableResult
    static func reclassify(in directory: URL = Home.support) -> Int {
        let manager = FileManager.default
        var moved = 0
        for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let path = directory.appendingPathComponent(name).path
            guard let attributes = try? manager.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  attributes[.protectionKey] as? FileProtectionType == .complete,
                  (try? manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: path)) != nil else { continue }
            moved += 1
        }
        return moved
    }

    /// Owner-only and atomic (`PrivateFile`), excluded from backups.
    static func write(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try PrivateFile.write(encoder.encode(value), to: url, excludedFromBackup: true)
    }

    // Dates as Foundation's default (seconds since 2001): exact through a round trip.
    private static var decoder: JSONDecoder { JSONDecoder() }
}

/// The hosts on this phone, in the user's order (M1e), saved as `hosts.json`.
@MainActor @Observable
final class HostStore {
    private struct Document: Codable {
        var version = 1
        var hosts: [HostRecord]
    }

    /// Sorted by `order`.
    private(set) var hosts: [HostRecord]
    /// The last save's failure, if it failed: the list stays as edited in memory and Spaces says so with a retry.
    private(set) var saveError: String?
    /// Hosts added or changed since the last save that reached the disk (empty once one does).
    private(set) var unsaved: Set<UUID> = []
    @ObservationIgnored let url: URL?

    /// `url` nil keeps the hosts in memory only (previews, tests).
    init(url: URL? = MobileFiles.hosts, hosts: [HostRecord] = []) {
        self.url = url
        let saved = url.flatMap { MobileFiles.read(Document.self, from: $0, version: 1)?.hosts } ?? hosts
        self.hosts = saved.sorted { $0.order < $1.order }
        renumber()
        publishColors()
    }

    func record(_ id: UUID) -> HostRecord? { hosts.first { $0.id == id } }

    /// Adds `host` last.
    func add(_ host: HostRecord) {
        guard record(host.id) == nil else { return update(host) }
        var host = host
        host.order = (hosts.map(\.order).max() ?? -1) + 1
        if host.color == nil { host.color = Self.freeColor(seed: host.tint.seed, among: hosts) }
        hosts.append(host)
        save(changed: [host.id])
    }

    /// The colour a new host gets (HostRegistry.assignColors): one the fewest hosts show, its seed breaking ties.
    static func freeColor(seed: UInt32, among hosts: [HostRecord]) -> HostColor {
        var used: [HostColor: Int] = [:]
        for host in hosts { used[host.color ?? Self.hashColor(host.tint.seed), default: 0] += 1 }
        let fewest = HostColor.allCases.map { used[$0, default: 0] }.min() ?? 0
        let candidates = HostColor.allCases.filter { used[$0, default: 0] == fewest }
        return candidates[Int(seed % UInt32(candidates.count))]
    }

    private static func hashColor(_ seed: UInt32) -> HostColor {
        HostColor.allCases[Int(seed % UInt32(HostColor.allCases.count))]
    }

    /// Each host's colour where `HostTint` reads it (by machine), as HostRegistry publishes the Mac's. Only the saved
    /// list does: an in-memory store (previews, tests) leaves the shared colours alone.
    private func publishColors() {
        guard url != nil else { return }
        var automatic: [String: HostColor] = [:]
        for host in hosts { if let color = host.color, automatic[host.tint.machine] == nil { automatic[host.tint.machine] = color } }
        if HostColorStore.shared.automatic != automatic { HostColorStore.shared.automatic = automatic }
    }

    /// Replaces the saved host with `host`'s fields, keeping its place.
    func update(_ host: HostRecord) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }), hosts[index] != host else { return }
        var host = host
        host.order = hosts[index].order
        hosts[index] = host
        save(changed: [host.id])
    }

    func remove(_ id: UUID) {
        guard hosts.contains(where: { $0.id == id }) else { return }
        hosts.removeAll { $0.id == id }
        renumber()
        unsaved.remove(id)
        save()
    }

    /// List reordering (`onMove`).
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var moved = hosts
        let items = source.sorted().map { moved[$0] }
        for index in source.sorted(by: >) { moved.remove(at: index) }
        let target = destination - source.filter { $0 < destination }.count
        moved.insert(contentsOf: items, at: max(0, min(target, moved.count)))
        guard moved.map(\.id) != hosts.map(\.id) else { return }
        hosts = moved
        renumber()
        save(changed: Set(hosts.map(\.id)))
    }

    private func renumber() {
        for index in hosts.indices where hosts[index].order != index { hosts[index].order = index }
    }

    /// Writes the list again after a failed save (the notice's Retry).
    func retrySave() { save() }

    private func save(changed: Set<UUID> = []) {
        publishColors()
        guard let url else { return }
        do {
            try MobileFiles.write(Document(hosts: hosts), to: url)
            if saveError != nil { saveError = nil }
            if !unsaved.isEmpty { unsaved = [] }
        } catch {
            saveError = error.localizedDescription
            unsaved.formUnion(changed)
        }
    }
}
