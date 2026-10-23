import Foundation
import Observation

/// What git says about the folder a tab or space is in, per host and topology key: the repository's root
/// (`files.git rev-parse --show-toplevel` in that folder) and its branch (`files.branch`, as the Mac's `SpaceBranch`
/// reads it). Read only through a helper whose grant has `git.read` (the host's Files & git switch, `HelperGrant`);
/// without one nothing is asked and the last facts stay. The capsule's Files modes show their bar only inside a
/// repository; Spaces' branch chips and the iPad strip's git modes read the same facts.
///
/// The root is read once per key, folder and connection (`resolve`): again when the folder changes, when the host's
/// connection or grant changes (`invalidate`, a new `generation`), or when the last read failed. The branch is polled
/// every `interval` (the Mac's cadence for its branch names) only while something shows it (`watch`: the Files
/// segment, a visible space's branch chip); nothing polls otherwise. One read per key at a time; a read asked meanwhile
/// runs after it with the latest folder, and the previous facts stay until it answers.
@MainActor @Observable
final class SpaceGitFacts {
    struct Key: Hashable, Sendable {
        let host: UUID
        /// A tab's or space's topology key (stable across helper connections).
        let key: String
    }

    struct Facts: Equatable, Sendable {
        /// The folder these facts are for.
        var directory: String
        /// The repository's root, nil outside any.
        var root: String?
        /// The checked-out branch, nil outside a repository or on a detached head.
        var branch: String?

        var isRepository: Bool { root != nil }
    }

    /// How a folder's root and branch are asked: a thrown error is a read that failed (keep what was known).
    struct Reader: Sendable {
        var root: @Sendable (HelperClient, String) async throws -> String?
        var branch: @Sendable (HelperClient, String) async throws -> String?
    }

    private(set) var facts: [Key: Facts] = [:]
    /// Per host, bumped when its connection or grant changes (`invalidate`): roots are read again.
    private(set) var generations: [UUID: Int] = [:]
    /// The host's helper when its grant has `git.read`, else nil (`MobileComposition` wires it to `HostSessions`).
    @ObservationIgnored var client: @MainActor (UUID) -> HelperClient? = { _ in nil }
    @ObservationIgnored private let reader: Reader
    @ObservationIgnored let interval: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    /// The folder and generation each key's root was last read for; a failed read records nothing.
    @ObservationIgnored private var rooted: [Key: (directory: String, generation: Int)] = [:]
    @ObservationIgnored private var reading: Set<Key> = []
    /// A root read asked while another read of the key ran: the latest folder asked.
    @ObservationIgnored private var again: [Key: String] = [:]

    init(interval: Duration = .seconds(2), reader: Reader = SpaceGitFacts.helper,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.interval = interval
        self.reader = reader
        self.sleep = sleep
    }

    /// The facts for `key`, if read for `directory` (or the last read, for any folder, when nil).
    func facts(_ key: Key, directory: String? = nil) -> Facts? {
        guard let facts = facts[key], directory == nil || facts.directory == directory else { return nil }
        return facts
    }

    /// Whether `key`'s folder is in a repository: nil until read.
    func isRepository(_ key: Key, directory: String? = nil) -> Bool? { facts(key, directory: directory)?.isRepository }

    func generation(_ host: UUID) -> Int { generations[host] ?? 0 }

    /// The host's connection or grant changed (or, without a host, every host's): roots are read again at the next
    /// `resolve` or `watch` tick. Views key their tasks by `generation`, so a shown one asks at once.
    func invalidate(host: UUID? = nil) {
        let hosts = host.map { [$0] } ?? Array(Set(rooted.keys.map(\.host)).union(generations.keys))
        for host in hosts { generations[host, default: 0] += 1 }
    }

    /// The root (and the branch with it) for `key`'s folder, unless already read for this folder and connection.
    func resolve(_ key: Key, directory: String) async {
        guard needsRoot(key, directory) else { return }
        await readRoot(key, directory)
    }

    /// `resolve`, then the branch every `interval` (the root again if its read failed) until the task is cancelled.
    func watch(_ key: Key, directory: String) async {
        await resolve(key, directory: directory)
        while !Task.isCancelled {
            do { try await sleep(interval) } catch { return }
            guard !Task.isCancelled else { return }
            if needsRoot(key, directory) {
                await readRoot(key, directory)
            } else if facts[key]?.isRepository == true {
                await readBranch(key, directory)
            }
        }
    }

    /// Keeps only `keys` of `host` (the tabs and spaces it still has).
    func retain(host: UUID, keys: Set<String>) {
        for key in facts.keys where key.host == host && !keys.contains(key.key) { facts[key] = nil }
        for key in rooted.keys where key.host == host && !keys.contains(key.key) { rooted[key] = nil }
    }

    /// The host was removed: its facts go.
    func forget(host: UUID) {
        for key in facts.keys where key.host == host { facts[key] = nil }
        for key in rooted.keys where key.host == host { rooted[key] = nil }
        generations[host] = nil
    }

    #if DEBUG
    /// Facts known without a read (the Spaces sample, previews).
    func seed(_ key: Key, _ facts: Facts) {
        self.facts[key] = facts
        rooted[key] = (facts.directory, generation(key.host))
    }
    #endif

    private func needsRoot(_ key: Key, _ directory: String) -> Bool {
        guard let rooted = rooted[key] else { return true }
        return rooted.directory != directory || rooted.generation != generation(key.host)
    }

    private func set(_ key: Key, _ next: Facts) {
        if facts[key] != next { facts[key] = next }
    }

    private func readRoot(_ key: Key, _ directory: String) async {
        guard let client = client(key.host) else { return }
        guard !reading.contains(key) else {
            again[key] = directory
            return
        }
        reading.insert(key)
        var directory = directory
        while true {
            let generation = generation(key.host)
            do {
                let root = try await reader.root(client, directory)
                let previous = facts[key]
                var branch: String?
                if root != nil {
                    do { branch = try await reader.branch(client, directory) } catch {
                        branch = previous?.directory == directory && previous?.root == root ? previous?.branch : nil
                    }
                }
                set(key, Facts(directory: directory, root: root, branch: branch))
                rooted[key] = (directory, generation)
            } catch {
                // Not answered: what was known stays, and the next tick asks again.
            }
            guard let next = again.removeValue(forKey: key) else { break }
            directory = next
        }
        reading.remove(key)
    }

    private func readBranch(_ key: Key, _ directory: String) async {
        guard let client = client(key.host), !reading.contains(key) else { return }
        reading.insert(key)
        if let branch = try? await reader.branch(client, directory), var current = facts[key], current.directory == directory {
            current.branch = branch
            set(key, current)
        }
        reading.remove(key)
        if let next = again.removeValue(forKey: key) { await readRoot(key, next) }
    }

    /// The helper's answers: the root by `rev-parse --show-toplevel` (git's 128 outside a repository: no root), the
    /// branch by `files.branch` (nil on a detached head).
    nonisolated static let helper = Reader(root: { client, directory in
        struct GitRun: Encodable, Sendable { let path: String; let args: [String]; let limit: UInt64 }
        struct Git: Decodable, Sendable { let status: Int64; let output: String; let truncated: Bool }
        let top: Git = try await client.connection.request(
            "files.git", params: GitRun(path: directory, args: ["rev-parse", "--show-toplevel"], limit: 4096))
        let root = top.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return top.status == 0 && root.hasPrefix("/") ? root : nil
    }, branch: { client, directory in
        struct Path: Encodable, Sendable { let path: String }
        let branch: String? = try await client.connection.request("files.branch", params: Path(path: directory))
        return branch.flatMap { $0.isEmpty ? nil : $0 }
    })
}
