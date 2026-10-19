import Foundation

/// The last activity known in each terminal and tab, per host and topology key, kept lightly on the device: the changes
/// the phone saw (by pane key) and the server's own times (`terminals.activity`, by the key it names, a tmux window's).
/// A small JSON file in Application Support, written a moment after a change, holding at most `limit` keys per host and
/// nothing older than `age`. It orders the Tabs list by activity (M2a) and gives rows their time, also before the host
/// connects. Losing it costs only those times.
@MainActor
final class TabActivityStore {
    /// `tab-activity.json` held the times the phone noticed changes, also those found after a reconnect (any time
    /// before), so most rows showed the last launch: it is dropped, and only times something happened go in this one.
    static let shared: TabActivityStore = {
        try? FileManager.default.removeItem(at: Home.support.appendingPathComponent("tab-activity.json"))
        return TabActivityStore(url: Home.support.appendingPathComponent("tab-activity-2.json"))
    }()

    private let url: URL?
    private var dates: [UUID: [String: Date]] = [:]
    private var pending: Task<Void, Never>?
    let limit: Int
    let age: TimeInterval

    /// `url` nil keeps everything in memory (tests, previews).
    init(url: URL?, limit: Int = 400, age: TimeInterval = 60 * 24 * 3600) {
        self.url = url
        self.limit = limit
        self.age = age
        if let url, let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            dates = (try? decoder.decode([UUID: [String: Date]].self, from: data)) ?? [:]
        }
    }

    func date(host: UUID, key: String) -> Date? { dates[host]?[key] }

    func note(host: UUID, key: String, at date: Date) {
        if let current = dates[host]?[key], current >= date { return }
        dates[host, default: [:]][key] = date
        if let entries = dates[host], entries.count > limit {
            let kept = entries.sorted { $0.value > $1.value }.prefix(limit)
            dates[host] = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        schedule()
    }

    /// Forget a host (removed from the phone).
    func forget(host: UUID) {
        guard dates.removeValue(forKey: host) != nil else { return }
        schedule()
    }

    private func schedule() {
        guard url != nil, pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.save()
        }
    }

    /// Writes now (also when the app leaves the foreground).
    func save() {
        pending?.cancel()
        pending = nil
        guard let url else { return }
        let cutoff = Date().addingTimeInterval(-age)
        dates = dates.compactMapValues { entries in
            let kept = entries.filter { $0.value >= cutoff }
            return kept.isEmpty ? nil : kept
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(dates) else { return }
        // Like every file of the app: owner-only, atomic, out of device backups (docs/security.md).
        try? PrivateFile.write(data, to: url, excludedFromBackup: true)
    }
}
