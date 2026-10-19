import Foundation
import Observation

/// Host keys the user trusted on first use (plan 3.6), saved as `known_hosts.json`: one key per host and port. A key
/// that differs from the saved one (another key or another algorithm) is a mismatch and a hard stop.
///
/// Fails closed: a file that is there but cannot be read (damaged, another version, not readable yet) is not treated
/// as empty, which would turn every host into a first-use question. Every check answers `unavailable` and nothing is
/// written until the user chooses Retry (read it again) or Reset (move it aside and start empty, every host asking
/// about its key again).
@MainActor @Observable
final class KnownHostStore {
    struct Entry: Codable, Equatable, Sendable {
        let algorithm: String
        /// The SSH wire public key blob.
        let key: Data
        let firstSeen: Date
        var fingerprint: String { SSHKeyEncoding.fingerprint(key) }
    }

    enum Verdict: Equatable, Sendable {
        case match
        case unknown
        /// The saved entry the offered key differs from.
        case mismatch(Entry)
        /// The trusted keys could not be read: no key is trusted or asked about until the user acts.
        case unavailable
    }

    /// The link's failure while the file is unreadable, and the notice's text.
    static let unreadableLink = "Known hosts unreadable: Reset or Retry"
    static let unreadableNotice = "Dispatch can't read its trusted host keys, so it connects to no host. Retry reads them again; Reset sets the file aside and every host asks about its key again."

    private struct Document: Codable {
        var version = 1
        var hosts: [String: Entry]
    }

    private(set) var entries: [String: Entry] = [:]
    /// The file is there but could not be read: every check is `unavailable` until `retryRead` or `reset`.
    private(set) var unreadable = false
    /// The last save's failure, if it failed: the keys stay trusted in memory and Spaces says so with a retry.
    private(set) var saveError: String?
    @ObservationIgnored let url: URL?

    init(url: URL? = MobileFiles.knownHosts) {
        self.url = url
        load()
    }

    /// Reads the file; an unreadable one stays where it is (never moved aside without the user).
    private func load() {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            entries = [:]
            unreadable = false
            return
        }
        if let document = MobileFiles.read(Document.self, from: url, version: 1, keep: false) {
            entries = document.hosts
            unreadable = false
        } else {
            entries = [:]
            unreadable = true
        }
    }

    /// Retry: reads the file again (it may have been unreadable only until the phone was unlocked). True when it read.
    @discardableResult
    func retryRead() -> Bool {
        load()
        return !unreadable
    }

    /// Reset: the unreadable file is moved aside (kept, private, out of backups; Remove all data deletes it) and the
    /// store starts empty.
    func reset() {
        guard unreadable else { return }
        if let url { try? MobileFiles.moveAside(url) }
        entries = [:]
        unreadable = false
    }

    /// OpenSSH's `known_hosts` naming: the host name in lower case, bracketed with its port unless it is 22.
    nonisolated static func key(host: String, port: Int) -> String {
        let host = host.lowercased()
        return port == 22 && !host.contains(":") ? host : "[\(host)]:\(port)"
    }

    func entry(host: String, port: Int) -> Entry? { entries[Self.key(host: host, port: port)] }

    func verify(host: String, port: Int, algorithm: String, key: Data) -> Verdict {
        guard !unreadable else { return .unavailable }
        guard let entry = entry(host: host, port: port) else { return .unknown }
        return entry.algorithm == algorithm && entry.key == key ? .match : .mismatch(entry)
    }

    func trust(host: String, port: Int, algorithm: String, key: Data, at date: Date = Date()) {
        guard !unreadable else { return }
        entries[Self.key(host: host, port: port)] = Entry(algorithm: algorithm, key: key, firstSeen: date)
        save()
    }

    func forget(host: String, port: Int) {
        guard !unreadable, entries.removeValue(forKey: Self.key(host: host, port: port)) != nil else { return }
        save()
    }

    /// Forgets every key (Settings' Remove all data), an unreadable file too.
    func removeAll() {
        entries = [:]
        unreadable = false
        saveError = nil
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// Writes the keys again after a failed save (the notice's Retry).
    func retrySave() { save() }

    private func save() {
        guard let url, !unreadable else { return }
        do {
            try MobileFiles.write(Document(hosts: entries), to: url)
            if saveError != nil { saveError = nil }
        } catch {
            saveError = error.localizedDescription
        }
    }
}
