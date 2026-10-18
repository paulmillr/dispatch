import Foundation
import Observation

/// Settings › Files › Drag and drop and Ask before replacing, as the transfer code reads them.
@MainActor enum FilesTransferSettings {
    /// Drag and drop: drop targets, drag sources and terminal drops.
    static func enabled() -> Bool { TerminalRuntime.shared.preferences.filesDragAndDrop }
    /// Ask before replacing: off keeps both without asking.
    static func asksBeforeReplacing() -> Bool { TerminalRuntime.shared.preferences.filesAskBeforeReplacing }
}

/// Copies files between two `FilesSource`s and drives the rows under the list.
///
/// A copy first lists the target and asks about top-level names that already exist, before anything is written.
/// Then a few small regular files (≤ 20, ≤ 4 MiB in all) travel one by one (`read` → `write`, which the helper
/// writes to a temporary name and renames); anything else travels as archives: `pack` on the source, `read` in
/// 4 MiB windows guarded by the first window's revision, `openUnpack` / `writeUnpack` on the target, then
/// `closeUnpack(commit: true)`, which extracts beside the target and moves the entries in last. Both endpoints are
/// whatever sources the caller hands in, so local → local, remote → local and remote → remote (through this Mac)
/// share this one path. Clean-up after a failure or a cancel (abort the staging, drop the archive) is awaited
/// before the row settles, so a retry never meets its own leftovers.
///
/// Conflicts. Names are compared case-insensitively whatever the target: a macOS volume usually is, a Linux one
/// usually is not, and taking a case variant for a conflict only ever asks one question too many. Only names the
/// prompt listed are ever replaced: the helper applies one policy per archive, so items are grouped by policy as
/// well as by folder, and only the archive of agreed names goes with `.replace`; the others go with `.keep`
/// (`.skip` under Skip), which never overwrite whatever appeared since the listing. A target listing cut short by
/// its bound cannot rule a name out, so a name past it is never replaced either: it is kept beside.
/// Two dragged items with one name (from different folders) keep both: the later ones travel in later archives,
/// after the first has taken the name.
@MainActor final class FileTransferEngine {
    static let shared = FileTransferEngine()

    struct Limits: Sendable {
        /// The few-and-small path: at most this many regular files…
        var files = 20
        /// …and at most this many bytes in all.
        var bytes: UInt64 = 4 << 20
        /// One archive read and one unpack write: what the app holds in memory at a time.
        var window: UInt64 = 4 << 20
        /// The waits before asking a busy helper again (a pack still finishing after a cancel, another client's
        /// copy); past the last the copy fails as busy.
        var busyWaits: [Duration] = [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(2),
                                     .seconds(4), .seconds(4), .seconds(8), .seconds(8)]
    }

    var limits = Limits()
    /// How long a finished or cancelled row stays before it slides away.
    var dismissDelay: Duration = .seconds(4)
    /// The rate is averaged over this much recent sending.
    var rateWindow: TimeInterval = 2
    /// Waits for the dismissal; the recording's clock, so a replay dismisses where its capture did.
    var sleep: @MainActor (Duration, String) async throws -> Void = { duration, name in
        try await System.sleep(for: duration, name)
    }
    /// Waits before asking a busy helper again; the recording's clock too.
    var pause: @MainActor (Duration, String) async throws -> Void = { duration, name in
        try await System.sleep(for: duration, name)
    }

    private let coordinator: @MainActor () -> FilesCoordinator
    private let asksBeforeReplacing: @MainActor () -> Bool
    private var runs: [UUID: Run] = [:]
    /// One pack and one open unpack per helper at a time (the helper answers `busy` otherwise): archive copies
    /// that need the same helper wait for each other instead of failing.
    private var held: Set<String> = []
    private var waiters: [Waiter] = []
    private var nextTicket = 0
    private var watchingSessions = false

    init(coordinator: @escaping @MainActor () -> FilesCoordinator = { TerminalRuntime.shared.files },
         asksBeforeReplacing: @escaping @MainActor () -> Bool = FilesTransferSettings.asksBeforeReplacing) {
        self.coordinator = coordinator
        self.asksBeforeReplacing = asksBeforeReplacing
    }

    /// Copies `items` (absolute paths on `source`) into `directory` on `target`, shown as a row on `session`.
    /// `kind` `.copyOut` binds the row to the session's source (rows dragged out of it); every other kind binds it
    /// to the session's target, and `origin`, when given, to the tab the items were dragged from. `relay` adds the
    /// second row of a remote → remote copy on the target's session. `label` names the target when it is not the
    /// shown folder (a Finder drop: "Downloads"). `finished` runs once the row settles (done, failed, cancelled),
    /// after the clean-up.
    @discardableResult
    func copy(items: [String], from source: any FilesSource, to target: any FilesSource, directory: String,
              in session: FilesSession, kind: FileTransfer.Kind, origin: FilesSession? = nil, relay: FilesSession? = nil,
              label: String? = nil, retryable: Bool = true,
              finished: (@MainActor (FileTransfer) -> Void)? = nil) -> FileTransfer {
        let label = label ?? FileTransferFormatting.folderLabel(directory)
        let primary = FileTransfer(kind: kind, items: items.count, targetPath: directory, targetLabel: label)
        var rows = [Run.Row(transfer: primary, session: session)]
        if let relay {
            let second = FileTransfer(kind: .relay, items: items.count, targetPath: directory, targetLabel: label)
            rows.append(Run.Row(transfer: second, session: relay))
        }
        let run = Run(id: primary.id, items: items, source: source, target: target, directory: directory, rows: rows,
                      sourceSession: kind == .copyOut ? session : origin,
                      targetSession: kind == .copyOut ? relay : session,
                      retryable: retryable, finished: finished)
        runs[run.id] = run
        for row in rows {
            row.transfer.cancel = { [weak self, weak run] in self?.cancel(run) }
            row.session.transfers.append(row.transfer)
        }
        watchSessions()
        // A running copy keeps its engine: the rows must reach an end.
        run.task = Task { await self.execute(run) }
        return primary
    }

    /// Copies whose rows are still held (running, failed and waiting for the user, or about to slide away).
    var runCount: Int { runs.count }

    /// The helper's keep-both name (helper/core/src/system/archive.rs `numbered`): Finder's "name 2", "name 3" …,
    /// before a file's extension (not a leading dot's, not a trailing one's) and after a folder's whole name.
    nonisolated static func keptName(_ name: String, folder: Bool = false, taken: (String) -> Bool) -> String {
        let bytes = Array(name.utf8)
        var at = bytes.lastIndex(of: UInt8(ascii: "."))
        if folder || at == 0 || at.map({ $0 + 1 >= bytes.count }) == true { at = nil }
        let stem = String(decoding: bytes[..<(at ?? bytes.count)], as: UTF8.self)
        let tail = String(decoding: bytes[(at ?? bytes.count)...], as: UTF8.self)
        var n = 2
        while true {
            let candidate = "\(stem) \(n)\(tail)"
            if !taken(candidate) { return candidate }
            n += 1
        }
    }

    nonisolated static func keptName(_ name: String, folder: Bool = false, taken: Set<String>) -> String {
        keptName(name, folder: folder) { taken.contains($0) }
    }

    /// How names are compared for conflicts: case and Unicode normalization folded, as an APFS volume compares them.
    nonisolated static func folded(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// A dragged item's name as it will be written in the target: refused unless it is one plain name. The paths
    /// come from a listing a remote helper answered; `..`, `.` or an embedded NUL would write outside the target.
    nonisolated static func plainName(of path: String) throws -> String {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw UnsafeName(name: name)
        }
        return name
    }

    /// Whether a failure came from the connection rather than the files, so the same copy may work again.
    nonisolated static func isTransport(_ error: any Error) -> Bool {
        let error = error as? FilesSourceError ?? HelperFilesSource.map(error, path: "", host: nil)
        switch error {
        case .offline, .busy: return true
        case .other(let code, _): return transportCodes.contains(code)
        default: return false
        }
    }

    /// Whether a request may have happened although it failed: no answer arrived (the connection dropped, it timed
    /// out, or it was cancelled in flight). A busy helper refused it outright.
    nonisolated static func isUncertain(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        let error = error as? FilesSourceError ?? HelperFilesSource.map(error, path: "", host: nil)
        switch error {
        case .offline, .cancelled: return true
        case .other(let code, _): return transportCodes.contains(code)
        default: return false
        }
    }

    private nonisolated static let transportCodes: Set<String> = ["unavailable", "connection_closed", "disconnected", "io_failure",
                                                      "uncertain", "timeout", "timed_out"]

    // MARK: Running

    @MainActor private final class Run {
        struct Row {
            let transfer: FileTransfer
            let session: FilesSession
        }

        let id: UUID
        let items: [String]
        var source: any FilesSource
        var target: any FilesSource
        let directory: String
        let rows: [Row]
        /// The tabs a remote endpoint was lent by: the copy fails as "The connection changed" when the tab's source
        /// moves to another connection, and a retry goes on through the tab's new connection to the same host.
        let sourceSession: FilesSession?
        let targetSession: FilesSession?
        let retryable: Bool
        let finished: (@MainActor (FileTransfer) -> Void)?
        var attempt = 0
        var task: Task<Void, Never>?
        var cancelled = false
        var stage: FileTransfer.Stage = .preparing
        var conflict: CheckedContinuation<FileTransfer.ConflictResolution, Never>?
        var samples: [(date: Date, bytes: UInt64)] = []

        init(id: UUID, items: [String], source: any FilesSource, target: any FilesSource, directory: String, rows: [Row],
             sourceSession: FilesSession?, targetSession: FilesSession?, retryable: Bool,
             finished: (@MainActor (FileTransfer) -> Void)?) {
            self.id = id
            self.items = items
            self.source = source
            self.target = target
            self.directory = directory
            self.rows = rows
            self.sourceSession = sourceSession
            self.targetSession = targetSession
            self.retryable = retryable
            self.finished = finished
        }

        var primary: FileTransfer { rows[0].transfer }
    }

    /// One top-level item and what happens when its name is taken in the target.
    private struct Item {
        let path: String
        let name: String
        let policy: ConflictPolicy
        var base: String { (path as NSString).deletingLastPathComponent }
    }

    /// Items that travel in one archive: one folder (the archive names entries relative to it), one policy.
    private struct Group {
        let base: String
        let policy: ConflictPolicy
        var items: [Item]
    }

    /// The session's source moved to another endpoint, or the session is gone.
    private struct ConnectionChanged: Error {}

    /// A dragged item whose name is not one plain name.
    struct UnsafeName: Error {
        let name: String
    }

    private func execute(_ run: Run) async {
        let outcome: FileTransfer.Stage
        do {
            try await perform(run)
            outcome = .done
        } catch {
            outcome = settled(run, error)
        }
        finish(run, outcome)
    }

    private func perform(_ run: Run) async throws {
        set(run, .preparing)
        let names = try run.items.map(Self.plainName(of:))
        let listing = try await run.target.list(run.directory, hidden: true)
        try check(run)
        let present = Set(listing.entries.map { Self.folded($0.name) })
        // A name dragged twice: the later items keep both, so only the first is asked about.
        var seen = Set<String>(), repeated = Set<Int>()
        for (index, name) in names.enumerated() where !seen.insert(Self.folded(name)).inserted { repeated.insert(index) }
        let conflicting = names.indices.filter { !repeated.contains($0) && present.contains(Self.folded(names[$0])) }
        var resolution = FileTransfer.ConflictResolution.keepBoth
        if !conflicting.isEmpty, asksBeforeReplacing() {
            resolution = await ask(run, conflicting.map { names[$0] })
            if resolution == .cancel {
                run.cancelled = true
                throw CancellationError()
            }
            try check(run)
            set(run, .preparing)
        }
        let agreed = Set(conflicting)
        var items: [Item] = []
        var skipped: UInt64 = 0
        for (index, path) in run.items.enumerated() {
            let taken = present.contains(Self.folded(names[index]))
            let policy: ConflictPolicy
            switch resolution {
            case .replace: policy = agreed.contains(index) ? .replace : .keep
            case .skip:
                // Skipped names never travel: packing them only to drop them at the target would waste the copy.
                if taken {
                    skipped += 1
                    continue
                }
                policy = repeated.contains(index) ? .keep : .skip
            case .keepBoth, .cancel: policy = .keep
            }
            items.append(Item(path: path, name: names[index], policy: policy))
        }
        update(run) { $0.skipped = skipped }
        guard !items.isEmpty else { return }
        if let bytes = try await planned(run, items) {
            let rest = try await writeFiles(run, items, bytes: bytes, taken: present)
            // A file grew past the few-and-small bound since it was listed: what is left travels as archives.
            if !rest.isEmpty { try await sendArchives(run, Self.grouped(rest), done: run.primary.entriesDone) }
        } else {
            try await sendArchives(run, Self.grouped(items), done: 0)
        }
    }

    /// Items by round, folder and policy, in drag order. A name's first item is in round 0, its second in round 1…:
    /// a later round's archive unpacks after the earlier one took the name, so keep-both numbers it.
    private static func grouped(_ items: [Item]) -> [Group] {
        var rounds: [[Group]] = []
        var occurrences: [String: Int] = [:]
        for item in items {
            let key = folded(item.name)
            let round = occurrences[key, default: 0]
            occurrences[key] = round + 1
            while rounds.count <= round { rounds.append([]) }
            if let index = rounds[round].firstIndex(where: { $0.base == item.base && $0.policy == item.policy }) {
                rounds[round][index].items.append(item)
            } else {
                rounds[round].append(Group(base: item.base, policy: item.policy, items: [item]))
            }
        }
        return rounds.flatMap { $0 }
    }

    /// The few-and-small path's total, or nil for the archive path. Stats the items through their parents'
    /// listings, stopping as soon as the archive path is certain.
    private func planned(_ run: Run, _ items: [Item]) async throws -> UInt64? {
        guard items.count <= limits.files else { return nil }
        var bases: [String] = []
        for item in items where !bases.contains(item.base) { bases.append(item.base) }
        var bytes: UInt64 = 0
        for base in bases {
            let listing = try await run.source.list(base, hidden: true)
            try check(run)
            var entries: [String: FileEntry] = [:]
            for entry in listing.entries { entries[entry.name] = entries[entry.name] ?? entry }
            for item in items where item.base == base {
                guard let entry = entries[item.name] else {
                    // Past the listing bound the item may still exist; the archive path finds out.
                    if listing.truncated { return nil }
                    throw FilesSourceError.notFound(item.path)
                }
                // Folders, and symlinks (copied as links), need the archive.
                guard entry.kind == .file else { return nil }
                bytes += entry.size
                if bytes > limits.bytes { return nil }
            }
        }
        return bytes
    }

    /// Reads and writes the items one by one; returns those left once a file read longer than the bound allows.
    private func writeFiles(_ run: Run, _ items: [Item], bytes: UInt64, taken: Set<String>) async throws -> [Item] {
        var taken = taken
        update(run) {
            $0.archived = false
            $0.bytesTotal = bytes
            $0.entries = UInt64(items.count)
        }
        set(run, .sending)
        sample(run, 0)
        var sent: UInt64 = 0, written: UInt64 = 0, skipped = run.primary.skipped
        for (index, item) in items.enumerated() {
            // One byte past what is left of the bound tells a file that grew from one that fits exactly.
            let budget = limits.bytes - min(sent, limits.bytes)
            let data = try await run.source.read(item.path, offset: 0, length: budget + 1, revision: nil).data
            try check(run)
            if UInt64(data.count) > budget { return Array(items[index...]) }
            if let placed = try await place(run, data, item: item, taken: &taken) {
                taken.insert(Self.folded(placed))
                written += 1
            } else {
                skipped += 1
            }
            try check(run)
            sent += UInt64(data.count)
            sample(run, sent)
            update(run) {
                $0.entriesDone = written
                $0.skipped = skipped
            }
        }
        return []
    }

    /// Writes one file under its policy and returns the name it took; nil when it was skipped. Only a name the user
    /// agreed to replace is ever replaced: one that appeared since the listing is kept beside it (skipped under Skip).
    private func place(_ run: Run, _ data: Data, item: Item, taken: inout Set<String>) async throws -> String? {
        let name = item.name
        var candidate = item.policy == .keep && taken.contains(Self.folded(name))
            ? Self.keptName(name) { [taken] in taken.contains(Self.folded($0)) } : name
        for _ in 0..<16 {
            let path = (run.directory as NSString).appendingPathComponent(candidate)
            update(run) { $0.uncertain = true }
            do {
                _ = try await run.target.write(path, data: data, mode: nil, replace: item.policy == .replace && candidate == name)
                update(run) { $0.uncertain = false }
                return candidate
            } catch {
                // An answer, even a refusal, says the request wrote nothing.
                if !Self.isUncertain(error) { update(run) { $0.uncertain = false } }
                guard case .exists = error as? FilesSourceError else { throw error }
                try check(run)
                if item.policy == .skip { return nil }
                taken.insert(Self.folded(candidate))
                candidate = Self.keptName(name) { [taken] in taken.contains(Self.folded($0)) }
            }
        }
        throw FilesSourceError.exists((run.directory as NSString).appendingPathComponent(name))
    }

    private func sendArchives(_ run: Run, _ groups: [Group], done: UInt64) async throws {
        var sentBefore: UInt64 = 0, total: UInt64 = 0, entries = done, arrived = done, skipped = run.primary.skipped
        run.samples = []
        update(run) {
            $0.archived = true
            $0.bytesDone = 0
            $0.bytesTotal = nil
        }
        for (index, group) in groups.enumerated() {
            // The first archive is named for the row, so a host's leftovers can be traced to it.
            let transfer = index == 0 && run.attempt == 0 ? run.id.uuidString : System.uuid().uuidString
            let source = run.source, target = run.target
            let keys: Set<String> = ["pack " + Self.key(source.endpoint), "unpack " + Self.key(target.endpoint)]
            try await acquire(keys)
            // Released only after the clean-up below returned: the next archive never meets this one's leftovers.
            defer { release(keys) }
            try check(run)
            // `open`: the target may hold this transfer's staging; `committed`: the helper ends it itself from then on.
            var open = false, committed = false
            do {
                set(run, .packing)
                let packed = try await retryingBusy(run) {
                    try await source.pack(transfer: transfer, base: group.base, paths: group.items.map(\.path))
                }
                try check(run)
                entries += packed.entries
                total += packed.size
                update(run) {
                    $0.entries = entries
                    $0.bytesTotal = total
                }
                do {
                    _ = try await retryingBusy(run) {
                        try await target.openUnpack(transfer: transfer, target: run.directory, policy: group.policy,
                                                    names: group.items.map(\.name))
                    }
                    open = true
                } catch {
                    // Unanswered, the open may have happened: the abort below removes it (an unknown transfer is
                    // refused harmlessly). Refused, there is nothing to abort.
                    open = Self.isUncertain(error)
                    throw error
                }
                try check(run)
                set(run, .sending)
                sample(run, sentBefore)
                var offset: UInt64 = 0
                var revision: FileRevision?
                while offset < packed.size {
                    let window = try await source.read(packed.archive, offset: offset, length: limits.window,
                                                       revision: revision)
                    try check(run)
                    revision = revision ?? window.revision
                    // A shorter archive than `pack` reported is one that changed under the copy.
                    guard !window.data.isEmpty else { throw FilesSourceError.changed(packed.archive) }
                    _ = try await target.writeUnpack(transfer: transfer, data: window.data)
                    try check(run)
                    offset += UInt64(window.data.count)
                    sample(run, sentBefore + offset)
                }
                sentBefore += packed.size
                // One helper call extracts beside the target and moves the entries in: Cancel is gone from here, and
                // the call runs to its end even if this task is cancelled, since the target must not be left half
                // moved. Until it answers, what arrived is unknown.
                set(run, .unpacking)
                committed = true
                update(run) { $0.uncertain = true }
                let result = try await Task { try await target.closeUnpack(transfer: transfer, commit: true) }.value
                arrived += result.entries
                skipped += result.skipped
                update(run) {
                    $0.uncertain = false
                    $0.entriesDone = arrived
                    $0.skipped = skipped
                }
                await cleanUp(source: source, target: target, transfer: transfer, abort: false)
            } catch {
                // After a commit the helper has ended the transfer whatever happened (or is still moving it in, when
                // the answer was lost): an abort then could only race it.
                await cleanUp(source: source, target: target, transfer: transfer, abort: open && !committed)
                throw error
            }
        }
    }

    /// Asks again while the helper answers `busy`, after a short wait each time.
    private func retryingBusy<T>(_ run: Run, _ body: @MainActor () async throws -> T) async throws -> T {
        var waits = limits.busyWaits[...]
        while true {
            do {
                return try await body()
            } catch FilesSourceError.busy(let detail) {
                guard let wait = waits.popFirst() else { throw FilesSourceError.busy(detail) }
                try await pause(wait, "files.transfer.busy")
                try check(run)
            }
        }
    }

    /// Drops the archive on the source and, after a failure or cancel, removes the target's staging folder.
    /// Runs in its own task: a cancelled copy's clean-up must not be cancelled with it.
    private func cleanUp(source: any FilesSource, target: any FilesSource, transfer: String, abort: Bool) async {
        await Task {
            if abort { _ = try? await target.closeUnpack(transfer: transfer, commit: false) }
            try? await source.dropArchive(transfer: transfer)
        }.value
    }

    private static func key(_ endpoint: FilesEndpoint) -> String {
        switch endpoint {
        case .local: "local"
        case .remote(let id): id.rawValue.uuidString
        }
    }

    // MARK: Conflicts

    private func ask(_ run: Run, _ existing: [String]) async -> FileTransfer.ConflictResolution {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                run.conflict = continuation
                set(run, .conflict(existing: existing))
                update(run) { row in row.resolveConflict = { [weak self, weak run] in self?.resolve(run, $0) } }
            }
        } onCancel: {
            Task { @MainActor [weak self, weak run] in self?.resolve(run, .cancel) }
        }
    }

    private func resolve(_ run: Run?, _ resolution: FileTransfer.ConflictResolution) {
        guard let run, let continuation = run.conflict else { return }
        run.conflict = nil
        update(run) { $0.resolveConflict = nil }
        continuation.resume(returning: resolution)
    }

    // MARK: Rows

    private func set(_ run: Run, _ stage: FileTransfer.Stage) {
        guard !run.cancelled else { return }
        run.stage = stage
        update(run) { $0.stage = stage }
    }

    private func update(_ run: Run, _ body: (FileTransfer) -> Void) {
        for row in run.rows { body(row.transfer) }
    }

    private func sample(_ run: Run, _ bytes: UInt64) {
        let now = System.date()
        run.samples.append((now, bytes))
        // Keep one sample older than the window, so a slow window still spans it.
        while run.samples.count > 2, now.timeIntervalSince(run.samples[1].date) >= rateWindow { run.samples.removeFirst() }
        var rate: Double?
        if let first = run.samples.first, let last = run.samples.last {
            let elapsed = last.date.timeIntervalSince(first.date)
            if elapsed > 0.05, last.bytes >= first.bytes { rate = Double(last.bytes - first.bytes) / elapsed }
        }
        update(run) { $0.bytesDone = bytes; $0.rate = rate }
    }

    /// The stage a failed or cancelled attempt ends in. Retry starts the copy over, so it is offered only while the
    /// target is known to hold nothing of it: a second attempt after a partial one would copy what arrived twice.
    private func settled(_ run: Run, _ error: any Error) -> FileTransfer.Stage {
        if run.cancelled || error is CancellationError || (error as? FilesSourceError) == .cancelled { return .cancelled }
        let clean = run.primary.entriesDone == 0 && !run.primary.uncertain
        if error is ConnectionChanged { return .failed(message: "The connection changed", retryable: clean) }
        if let unsafe = error as? UnsafeName {
            return .failed(message: "\(unsafe.name.debugDescription) is not a name a copy can take", retryable: false)
        }
        let verb: String
        switch run.stage {
        case .packing: verb = "packing"
        case .sending: verb = "sending"
        case .unpacking: verb = "unpacking"
        default: verb = "preparing"
        }
        if Self.isTransport(error) {
            let mapped = error as? FilesSourceError ?? HelperFilesSource.map(error, path: "", host: nil)
            switch mapped {
            case .busy(let detail): return .failed(message: detail, retryable: clean)
            case .other(let code, _) where ["uncertain", "timeout", "timed_out"].contains(code):
                return .failed(message: "No answer while \(verb)", retryable: clean)
            default: return .failed(message: "Connection dropped while \(verb)", retryable: clean)
            }
        }
        guard let error = error as? FilesSourceError else {
            return .failed(message: error.localizedDescription, retryable: false)
        }
        func name(_ path: String) -> String { (path as NSString).lastPathComponent }
        let message: String
        switch error {
        case .notFound(let path): message = "\(name(path)) no longer exists"
        case .permissionDenied(let path) where onThisMac(path, run):
            // macOS refuses a folder it protects (Downloads, Desktop, Documents) once its consent prompt was denied,
            // and asks no more: the setting is the only way back.
            message = "No permission for \(name(path)). Allow Dispatch in System Settings › Privacy & Security › Files and Folders"
        case .permissionDenied(let path): message = "No permission for \(name(path))"
        case .notDirectory: message = "\(run.primary.targetLabel) is not a folder"
        case .changed(let path): message = run.stage == .sending && path.hasSuffix(".tar.zst")
            ? "The archive changed while sending" : "\(name(path)) changed while copying"
        case .exists(let path): message = "\(name(path)) already exists"
        default: message = error.message
        }
        return .failed(message: message, retryable: false)
    }

    /// Whether a path a request failed on is on this Mac: the dragged items and the folders above them are the
    /// source's, anything else the target's.
    private func onThisMac(_ path: String, _ run: Run) -> Bool {
        let folder = path.hasSuffix("/") ? path : path + "/"
        let sourceSide = run.items.contains { $0 == path || $0.hasPrefix(folder) }
        return (sourceSide ? run.source : run.target).endpoint.isLocal
    }

    private func finish(_ run: Run, _ stage: FileTransfer.Stage) {
        run.task = nil
        run.cancelled = false
        run.stage = stage
        let now = System.date()
        update(run) { row in
            row.stage = stage
            row.rate = nil
            row.finishedAt = now
            row.resolveConflict = nil
            if case .failed(_, true) = stage, run.retryable {
                row.retry = { [weak self, weak run] in self?.retry(run) }
            } else {
                row.retry = nil
            }
        }
        // Nobody is left to see or act on a row whose tabs closed.
        if orphaned(run) {
            dismiss(run)
        } else if stage == .done {
            // The new entries show without waiting for the next poll.
            if let session = run.targetSession { coordinator().refresh(session.id) }
            scheduleDismissal(run)
        } else if stage == .cancelled {
            scheduleDismissal(run)
        }
        run.finished?(run.primary)
    }

    private func cancel(_ run: Run?) {
        guard let run else { return }
        switch run.primary.stage {
        case .preparing, .packing, .sending:
            guard run.task != nil else { return }
            update(run) { $0.stage = .cancelled }
            run.cancelled = true
            run.task?.cancel()
        case .conflict:
            resolve(run, .cancel)
        case .unpacking:
            break
        case .done, .failed, .cancelled:
            dismiss(run)
        }
    }

    private func retry(_ run: Run?) {
        guard let run, run.task == nil, run.retryable, case .failed(_, true) = run.primary.stage else { return }
        // A reconnect lends the tab a new source (a new connection) to the same host: the copy goes on through it.
        if let session = run.sourceSession, !run.source.endpoint.isLocal {
            guard let current = current(session, sameHostAs: run.source) else { return finish(run, unavailable(run.source)) }
            run.source = current
        }
        if let session = run.targetSession, !run.target.endpoint.isLocal {
            guard let current = current(session, sameHostAs: run.target) else { return finish(run, unavailable(run.target)) }
            run.target = current
        }
        run.attempt += 1
        run.samples = []
        let now = System.date()
        update(run) { row in
            row.stage = .preparing
            row.retry = nil
            row.bytesDone = 0
            row.bytesTotal = nil
            row.entriesDone = 0
            row.entries = nil
            row.skipped = 0
            row.uncertain = false
            row.archived = true
            row.rate = nil
            row.startedAt = now
            row.finishedAt = nil
        }
        run.task = Task { await self.execute(run) }
    }

    /// The session's source when the session is still open and reaches the same host as `source`.
    private func current(_ session: FilesSession, sameHostAs source: any FilesSource) -> (any FilesSource)? {
        guard coordinator().existing(session.id) === session, let current = session.source,
              current.endpoint.isLocal == source.endpoint.isLocal, current.hostLabel == source.hostLabel else { return nil }
        return current
    }

    private func unavailable(_ source: any FilesSource) -> FileTransfer.Stage {
        .failed(message: source.hostLabel.map { "\($0) is not connected" } ?? "The connection changed", retryable: true)
    }

    private func scheduleDismissal(_ run: Run) {
        let delay = dismissDelay
        Task { [weak run] in
            do { try await self.sleep(delay, "files.transfer.dismiss") } catch { return }
            guard let run, run.primary.stage == .done || run.primary.stage == .cancelled else { return }
            self.dismiss(run)
        }
    }

    private func dismiss(_ run: Run) {
        for row in run.rows { row.session.transfers.removeAll { $0 === row.transfer } }
        if runs[run.id] === run { runs[run.id] = nil }
    }

    /// Every tab showing the run's rows has closed.
    private func orphaned(_ run: Run) -> Bool {
        let files = coordinator()
        return run.rows.allSatisfy { files.existing($0.session.id) !== $0.session }
    }

    /// Follows the coordinator's sessions while runs are held: a run whose tabs all closed lets its rows go, and one
    /// waiting for a conflict answer nobody can give is cancelled. A running one fails at its next check.
    private func watchSessions() {
        guard !watchingSessions, !runs.isEmpty else { return }
        watchingSessions = true
        let files = coordinator()
        withObservationTracking {
            _ = files.sessions
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.watchingSessions = false
                self.sessionsChanged()
                self.watchSessions()
            }
        }
    }

    private func sessionsChanged() {
        for run in Array(runs.values) where orphaned(run) {
            if run.conflict != nil {
                resolve(run, .cancel)
            } else if run.task == nil {
                dismiss(run)
            }
        }
    }

    /// The tabs a remote endpoint was lent by still lend it; a cancel stops here.
    private func check(_ run: Run) throws {
        if run.cancelled || Task.isCancelled { throw CancellationError() }
        let files = coordinator()
        for (session, source) in [(run.sourceSession, run.source), (run.targetSession, run.target)] {
            // This Mac's helper is no tab's to take away.
            guard let session, !source.endpoint.isLocal else { continue }
            guard files.existing(session.id) === session, let current = session.source,
                  current === source || current.endpoint == source.endpoint else { throw ConnectionChanged() }
        }
    }

    // MARK: Helper slots

    private struct Waiter {
        let ticket: Int
        let keys: Set<String>
        let continuation: CheckedContinuation<Void, any Error>
    }

    private func acquire(_ keys: Set<String>) async throws {
        if held.isDisjoint(with: keys), !waiters.contains(where: { !$0.keys.isDisjoint(with: keys) }) {
            held.formUnion(keys)
            return
        }
        nextTicket += 1
        let ticket = nextTicket
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(ticket: ticket, keys: keys, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.abandon(ticket) }
        }
    }

    private func release(_ keys: Set<String>) {
        held.subtract(keys)
        var index = 0
        while index < waiters.count {
            let waiter = waiters[index]
            if held.isDisjoint(with: waiter.keys) {
                held.formUnion(waiter.keys)
                waiters.remove(at: index)
                waiter.continuation.resume()
            } else {
                index += 1
            }
        }
    }

    private func abandon(_ ticket: Int) {
        guard let index = waiters.firstIndex(where: { $0.ticket == ticket }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
