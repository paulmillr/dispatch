import Foundation
@testable import DispatchApp

/// An in-memory host for files tests: a tree of folders, files and symlinks with optional latency and
/// scripted failures, serving the same `FilesSource` calls the helper does. Pack and unpack carry a
/// subtree as JSON inside an opaque "archive" node, so transfer tests round-trip through the real
/// sequence (pack → read windows → open/write/close) without a helper.
final class FakeFilesSource: FilesSource, @unchecked Sendable {
    final class Node {
        var kind: FileEntryKind
        var data: Data
        var children: [String: Node]
        var modified: Date
        var target: String?
        var mode: UInt32
        let inode: UInt64

        init(kind: FileEntryKind, data: Data = Data(), children: [String: Node] = [:], modified: Date,
             target: String? = nil, mode: UInt32 = 0o644, inode: UInt64) {
            self.kind = kind
            self.data = data
            self.children = children
            self.modified = modified
            self.target = target
            self.mode = mode
            self.inode = inode
        }
    }

    let endpoint: FilesEndpoint
    var home: String?
    var hostLabel: String?
    /// A host whose grant has Files without Copy files in.
    var readOnly = false
    /// Waited before every call through `System.sleep`, so tests that replay stay deterministic.
    var latency: Duration?
    /// Scripted failures by `"<method> <path>"`, or `"<method>"` for every call of that method.
    var failures: [String: FilesSourceError] = [:]
    /// Like `failures`, for errors that are not `FilesSourceError` (what a broken helper stream throws).
    var thrown: [String: any Error] = [:]
    /// Calls (keyed like `failures`) that never answer until their task is cancelled: a stalled disk or helper.
    var hangs: Set<String> = []
    /// Entries past this count are reported as truncated.
    var listLimit = 10_000
    /// Scripted `git` answers by the arguments joined with spaces (e.g. "status --porcelain=v2 -z"), tried with the
    /// path prefixed ("/Users/ivan/src/api status …") first. Unscripted commands answer like a folder outside any
    /// repository: status 128 and git's own words.
    var gitAnswers: [String: GitOutput] = [:]
    /// Extra top-level files every pack slips into its archive, by name: a host answering for more than was asked.
    var planted: [String: String] = [:]
    /// The `names` each `openUnpack` was given, in call order.
    var unpackNames: [[String]] { lock.withLock { opened } }

    private let lock = NSLock()
    private var root: Node
    private var nextInode: UInt64 = 1
    private var recorded: [String] = []
    private var ran: [String] = []
    private var bounds: [UInt64] = []
    private var opened: [[String]] = []
    private var once: [String: [FilesSourceError]] = [:]
    private var archives: [String: (path: String, base: String, dropped: Bool)] = [:]
    private var transfers: [String: (target: String, policy: ConflictPolicy, names: Set<String>, staging: String,
                                     staged: Data)] = [:]

    init(endpoint: FilesEndpoint = .local, home: String? = "/Users/ivan", hostLabel: String? = nil) {
        self.endpoint = endpoint
        self.home = home
        self.hostLabel = hostLabel
        root = Node(kind: .directory, modified: Date(timeIntervalSince1970: 1_760_000_000), inode: 0)
    }

    /// Method names with paths, in call order.
    var calls: [String] { lock.withLock { recorded } }
    /// Each `git` call as "<path> <args joined with spaces>", in call order.
    var gitCalls: [String] { lock.withLock { ran } }
    /// The output bound (`limit`) each `git` call asked for, in call order beside `gitCalls`.
    var gitLimits: [UInt64] { lock.withLock { bounds } }

    /// The next `errors.count` calls matching `key` (as in `failures`) fail with these, in order.
    func fail(_ key: String, with errors: [FilesSourceError]) {
        lock.withLock { once[key, default: []] += errors }
    }

    // MARK: Building the tree

    @discardableResult
    func directory(_ path: String, modified: Date = Date(timeIntervalSince1970: 1_760_000_000)) -> Node {
        lock.withLock { makeDirectory(path, modified: modified) }
    }

    @discardableResult
    func file(_ path: String, _ text: String, modified: Date = Date(timeIntervalSince1970: 1_760_000_000),
              mode: UInt32 = 0o644) -> Node {
        file(path, Data(text.utf8), modified: modified, mode: mode)
    }

    @discardableResult
    func file(_ path: String, _ data: Data, modified: Date = Date(timeIntervalSince1970: 1_760_000_000),
              mode: UInt32 = 0o644) -> Node {
        lock.withLock {
            let (parent, name) = split(path)
            let directory = makeDirectory(parent, modified: modified)
            let node = Node(kind: .file, data: data, modified: modified, mode: mode, inode: allocate())
            directory.children[name] = node
            return node
        }
    }

    @discardableResult
    func symlink(_ path: String, to target: String,
                 modified: Date = Date(timeIntervalSince1970: 1_760_000_000)) -> Node {
        lock.withLock {
            let (parent, name) = split(path)
            let directory = makeDirectory(parent, modified: modified)
            let node = Node(kind: .symlink, data: Data(target.utf8), modified: modified, target: target,
                            inode: allocate())
            directory.children[name] = node
            return node
        }
    }

    func remove(_ path: String) {
        lock.withLock {
            let (parent, name) = split(path)
            node(at: parent)?.children[name] = nil
        }
    }

    func node(_ path: String) -> Node? { lock.withLock { node(at: path) } }

    func text(_ path: String) -> String? { node(path).flatMap { String(data: $0.data, encoding: .utf8) } }

    func exists(_ path: String) -> Bool { node(path) != nil }

    /// Every path below `path`, depth first, relative to it.
    func paths(below path: String = "/") -> [String] {
        lock.withLock {
            guard let start = node(at: path) else { return [] }
            var out: [String] = []
            func walk(_ node: Node, _ prefix: String) {
                for name in node.children.keys.sorted() {
                    let child = node.children[name]!
                    let relative = prefix.isEmpty ? name : prefix + "/" + name
                    out.append(relative)
                    walk(child, relative)
                }
            }
            walk(start, "")
            return out
        }
    }

    /// The tree of the F2a mockup under `~/src/api`, its times relative to `now`: a window's list measures its ages from
    /// the clock, so a case that reads them on screen passes the clock's now.
    static func mockupAPI(home: String = "/Users/ivan", now: Date = Date(timeIntervalSince1970: 1_760_700_000)) -> FakeFilesSource {
        let source = FakeFilesSource(home: home)
        let base = home + "/src/api"
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        source.directory(base + "/.github", modified: ago(2 * 86_400))
        source.file(base + "/.github/workflows/ci.yml", "name: ci\n", modified: ago(2 * 86_400))
        source.file(base + "/src/routes/billing.ts", String(repeating: "export const billing = 1\n", count: 150),
                    modified: ago(6 * 60))
        source.file(base + "/src/routes/health.ts", "export const health = () => 'ok'\n", modified: ago(3 * 86_400))
        source.file(base + "/src/lib/db.ts", String(repeating: "export const db = {}\n", count: 100), modified: ago(8 * 60))
        source.file(base + "/src/lib/stripe.ts", String(repeating: "export const stripe = {}\n", count: 40),
                    modified: ago(86_400))
        source.file(base + "/src/index.ts", String(repeating: "import './routes'\n", count: 100), modified: ago(2 * 86_400))
        source.file(base + "/tests/idempotency.test.ts", "test('idempotent', () => {})\n", modified: ago(35 * 60))
        source.file(base + "/node_modules/left-pad/index.js", "module.exports = (s) => s\n", modified: ago(15 * 3_600))
        source.file(base + "/.gitignore", "node_modules\n", modified: ago(13 * 86_400))
        source.file(base + "/CHANGELOG.md", "# Changelog\n\n## 2.4.0\n", modified: ago(12 * 60))
        source.file(base + "/package.json", "{\n  \"name\": \"api\"\n}\n", modified: ago(5 * 3_600))
        source.file(base + "/pnpm-lock.yaml", String(repeating: "lockfileVersion: 9\n", count: 10_000), modified: ago(5 * 3_600))
        source.file(base + "/README.md", "# api\n\nThe billing service.\n", modified: ago(9 * 86_400))
        source.file(base + "/tsconfig.json", "{\n  \"strict\": true\n}\n", modified: ago(13 * 86_400))
        return source
    }

    // MARK: FilesSource

    func list(_ path: String, hidden: Bool) async throws -> FileListing {
        try await enter("list", path)
        return try lock.withLock {
            guard let node = node(at: path) else { throw FilesSourceError.notFound(path) }
            guard node.kind == .directory else { throw FilesSourceError.notDirectory(path) }
            var names = node.children.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            if !hidden { names.removeAll { $0.hasPrefix(".") } }
            let truncated = names.count > listLimit
            if truncated { names = Array(names.prefix(listLimit)) }
            let entries = names.map { name -> FileEntry in
                let child = node.children[name]!
                return FileEntry(name: name, kind: child.kind, size: child.kind == .directory ? 0 : UInt64(child.data.count),
                                 modified: child.modified, targetKind: targetKind(of: child, in: path), mark: nil,
                                 identity: FileIdentity(device: 1, inode: child.inode))
            }
            return FileListing(path: normalize(path), entries: entries, truncated: truncated,
                               identity: FileIdentity(device: 1, inode: node.inode))
        }
    }

    func summary(_ path: String) async throws -> FolderSummary {
        try await enter("summary", path)
        return try lock.withLock {
            guard let node = node(at: path) else { throw FilesSourceError.notFound(path) }
            var summary = FolderSummary(files: 0, folders: 0, bytes: 0, truncated: false)
            func walk(_ node: Node) {
                for child in node.children.values {
                    switch child.kind {
                    case .directory:
                        summary.folders += 1
                        walk(child)
                    case .file:
                        summary.files += 1
                        summary.bytes += UInt64(child.data.count)
                    case .symlink, .other:
                        summary.files += 1
                    }
                }
            }
            walk(node)
            return summary
        }
    }

    func read(_ path: String, offset: UInt64, length: UInt64?, revision: FileRevision?) async throws
        -> (data: Data, revision: FileRevision) {
        try await enter("read", path)
        return try lock.withLock {
            guard let node = resolved(at: path) else { throw FilesSourceError.notFound(path) }
            guard node.kind == .file else { throw FilesSourceError.unsupported("\(path) is not a regular file") }
            let current = self.revision(of: node)
            if let revision, revision != current { throw FilesSourceError.changed(path) }
            let start = min(Int(offset), node.data.count)
            let end = length.map { min(start + Int($0), node.data.count) } ?? node.data.count
            return (node.data.subdata(in: start..<end), current)
        }
    }

    func write(_ path: String, data: Data, mode: UInt32?, replace: Bool, parent expectedParent: FileIdentity,
               replaced: FileIdentity?) async throws -> FileRevision {
        try await enter("write", path)
        return try lock.withLock {
            let (parent, name) = split(path)
            guard let directory = node(at: parent), directory.kind == .directory else {
                throw FilesSourceError.notFound(parent)
            }
            guard expectedParent == FileIdentity(device: 1, inode: directory.inode) else {
                throw FilesSourceError.changed(parent)
            }
            if replace {
                guard let current = directory.children[name],
                      replaced == FileIdentity(device: 1, inode: current.inode) else { throw FilesSourceError.changed(path) }
            } else if replaced != nil {
                throw FilesSourceError.changed(path)
            }
            if directory.children[name] != nil, !replace { throw FilesSourceError.exists(path) }
            let node = Node(kind: .file, data: data, modified: System.date(), mode: mode ?? 0o644, inode: allocate())
            directory.children[name] = node
            return revision(of: node)
        }
    }

    func pack(transfer: String, base: String, paths: [String]) async throws -> PackedArchive {
        try await enter("pack", base)
        return try lock.withLock {
            let base = normalize(base)
            var payload: [[String: Any]] = []
            var files: UInt64 = 0, folders: UInt64 = 0, bytes: UInt64 = 0
            for path in paths {
                let path = normalize(path)
                guard path.hasPrefix(base + "/") else {
                    throw FilesSourceError.other(code: "invalid_request", message: "\(path) is outside \(base)")
                }
                guard let node = node(at: path) else { throw FilesSourceError.notFound(path) }
                func add(_ node: Node, _ relative: String) {
                    var entry: [String: Any] = ["path": relative, "kind": node.kind.rawValue,
                                                "modified": node.modified.timeIntervalSince1970, "mode": Int(node.mode)]
                    switch node.kind {
                    case .directory:
                        folders += 1
                        payload.append(entry)
                        for name in node.children.keys.sorted() { add(node.children[name]!, relative + "/" + name) }
                        return
                    case .file:
                        files += 1
                        bytes += UInt64(node.data.count)
                        entry["data"] = node.data.base64EncodedString()
                    case .symlink:
                        files += 1
                        entry["target"] = node.target ?? ""
                    case .other:
                        return
                    }
                    payload.append(entry)
                }
                add(node, String(path.dropFirst(base.count + 1)))
            }
            for (name, text) in planted.sorted(by: { $0.key < $1.key }) {
                payload.append(["path": name, "kind": "file", "modified": 0.0, "mode": 0o644,
                                "data": Data(text.utf8).base64EncodedString()])
            }
            let data = try JSONSerialization.data(withJSONObject: payload)
            let archive = "/tmp/dispatch-pack-\(transfer).tar.zst"
            let (parent, name) = split(archive)
            makeDirectory(parent, modified: System.date()).children[name] =
                Node(kind: .file, data: data, modified: System.date(), mode: 0o600, inode: allocate())
            archives[transfer] = (archive, base, false)
            return PackedArchive(archive: archive, entries: files + folders, files: files, folders: folders, bytes: bytes,
                                 size: UInt64(data.count), skipped: 0)
        }
    }

    func dropArchive(transfer: String) async throws {
        try await enter("pack.drop", transfer)
        lock.withLock {
            if let archive = archives.removeValue(forKey: transfer) {
                let (parent, name) = split(archive.path)
                node(at: parent)?.children[name] = nil
            }
        }
    }

    func openUnpack(transfer: String, target: String, policy: ConflictPolicy, names: [String], parent: FileIdentity,
                    replacements: [String: FileIdentity]) async throws -> UnpackTransfer {
        try await enter("unpack.open", target)
        return try lock.withLock {
            opened.append(names)
            guard let node = node(at: target) else { throw FilesSourceError.notFound(target) }
            guard node.kind == .directory else { throw FilesSourceError.notDirectory(target) }
            guard parent == FileIdentity(device: 1, inode: node.inode) else { throw FilesSourceError.changed(target) }
            if policy == .replace {
                guard Set(replacements.keys) == Set(names), replacements.allSatisfy({ name, identity in
                    node.children[name].map { identity == FileIdentity(device: 1, inode: $0.inode) } ?? false
                }) else { throw FilesSourceError.changed(target) }
            } else if !replacements.isEmpty {
                throw FilesSourceError.changed(target)
            }
            if transfers.values.contains(where: { $0.target == normalize(target) }) {
                throw FilesSourceError.busy("A copy into \(target) is already open")
            }
            let staging = normalize(target) + "/.dispatch-copy-" + transfer
            makeDirectory(staging, modified: System.date())
            transfers[transfer] = (normalize(target), policy, Set(names), staging, Data())
            return UnpackTransfer(transfer: transfer, staging: staging)
        }
    }

    func writeUnpack(transfer: String, data: Data) async throws -> UInt64 {
        try await enter("unpack.write", transfer)
        return try lock.withLock {
            guard transfers[transfer] != nil else { throw FilesSourceError.notFound(transfer) }
            transfers[transfer]!.staged.append(data)
            return UInt64(transfers[transfer]!.staged.count)
        }
    }

    func closeUnpack(transfer: String, commit: Bool) async throws -> UnpackResult {
        try await enter("unpack.close", transfer)
        return try lock.withLock {
            guard let open = transfers.removeValue(forKey: transfer) else { throw FilesSourceError.notFound(transfer) }
            defer {
                let (parent, name) = split(open.staging)
                node(at: parent)?.children[name] = nil
            }
            var result = UnpackResult(entries: 0, bytes: 0, replaced: 0, kept: 0, skipped: 0)
            guard commit else { return result }
            guard let payload = try? JSONSerialization.jsonObject(with: open.staged) as? [[String: Any]] else {
                throw FilesSourceError.other(code: "invalid_request", message: "The archive is not complete")
            }
            guard let target = node(at: open.target) else { throw FilesSourceError.notFound(open.target) }
            // Build the tree in staging first, then move the top-level entries in: nothing in the target
            // changes if an entry is malformed.
            let tree = Node(kind: .directory, modified: System.date(), inode: allocate())
            for entry in payload {
                guard let relative = entry["path"] as? String, !relative.isEmpty, !relative.hasPrefix("/"),
                      !relative.split(separator: "/").contains(".."),
                      let kind = (entry["kind"] as? String).flatMap(FileEntryKind.init(rawValue:)) else {
                    throw FilesSourceError.other(code: "invalid_request", message: "The archive holds an unsafe path")
                }
                let modified = Date(timeIntervalSince1970: entry["modified"] as? TimeInterval ?? 0)
                let mode = UInt32(entry["mode"] as? Int ?? 0o644)
                let (parentPath, name) = split("/" + relative)
                var parent = tree
                for part in parentPath.split(separator: "/") {
                    let child = parent.children[String(part)] ?? Node(kind: .directory, modified: modified, inode: allocate())
                    parent.children[String(part)] = child
                    parent = child
                }
                switch kind {
                case .directory:
                    parent.children[name] = parent.children[name] ?? Node(kind: .directory, modified: modified, inode: allocate())
                case .file:
                    let data = (entry["data"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
                    parent.children[name] = Node(kind: .file, data: data, modified: modified, mode: mode, inode: allocate())
                    result.bytes += UInt64(data.count)
                case .symlink:
                    let link = entry["target"] as? String ?? ""
                    parent.children[name] = Node(kind: .symlink, data: Data(link.utf8), modified: modified, target: link,
                                                 inode: allocate())
                case .other:
                    continue
                }
                result.entries += 1
            }
            // As the helper does: an archive naming anything at its top but what was dragged is refused whole.
            if !open.names.isEmpty, let stray = tree.children.keys.sorted().first(where: { !open.names.contains($0) }) {
                throw FilesSourceError.other(code: "invalid_request", message: "The archive holds \(stray), which was not sent")
            }
            for name in tree.children.keys.sorted() {
                let incoming = tree.children[name]!
                if target.children[name] == nil {
                    target.children[name] = incoming
                    continue
                }
                switch open.policy {
                case .replace:
                    target.children[name] = incoming
                    result.replaced += 1
                case .keep:
                    let kept = FileTransferEngine.keptName(name, folder: incoming.kind == .directory,
                                                           taken: Set(target.children.keys))
                    target.children[kept] = incoming
                    result.kept += 1
                case .skip:
                    result.skipped += 1
                }
            }
            return result
        }
    }

    func git(_ path: String, args: [String], limit: UInt64) async throws -> GitOutput {
        let key = args.joined(separator: " ")
        lock.withLock {
            ran.append(path + " " + key)
            bounds.append(limit)
        }
        try await enter("git", path)
        return lock.withLock {
            gitAnswers[normalize(path) + " " + key] ?? gitAnswers[key]
                ?? GitOutput(status: 128, output: "fatal: not a git repository (or any of the parent directories): .git\n",
                             truncated: false)
        }
    }

    // MARK: Internals

    private func enter(_ method: String, _ path: String) async throws {
        let keys = ["\(method) \(normalize(path))", "\(method) \(path)", method]
        let (failure, error, hang): (FilesSourceError?, (any Error)?, Bool) = lock.withLock {
            recorded.append("\(method) \(path)")
            if let key = keys.first(where: { once[$0]?.isEmpty == false }) { return (once[key]!.removeFirst(), nil, false) }
            return (keys.lazy.compactMap { self.failures[$0] }.first, keys.lazy.compactMap { self.thrown[$0] }.first,
                    keys.contains { hangs.contains($0) })
        }
        if let failure { throw failure }
        if let error { throw error }
        if hang { try await Hang().wait() }
        if let latency { try await System.sleep(for: latency, "fake-files") }
    }

    private func allocate() -> UInt64 {
        defer { nextInode += 1 }
        return nextInode
    }

    private func revision(of node: Node) -> FileRevision {
        let ns = String(Int64(node.modified.timeIntervalSince1970 * 1_000_000_000))
        return FileRevision(kind: node.kind, size: UInt64(node.data.count), device: 1, inode: node.inode,
                            modifiedNs: ns, changedNs: ns)
    }

    private func targetKind(of node: Node, in directory: String) -> FileEntryKind? {
        guard node.kind == .symlink, let target = node.target else { return nil }
        let path = target.hasPrefix("/") ? target : directory + "/" + target
        return self.node(at: path)?.kind
    }

    /// The node a path names, following a final symlink.
    private func resolved(at path: String) -> Node? {
        guard let node = node(at: path) else { return nil }
        guard node.kind == .symlink, let target = node.target else { return node }
        let (parent, _) = split(path)
        return self.node(at: target.hasPrefix("/") ? target : parent + "/" + target)
    }

    private func node(at path: String) -> Node? {
        var node = root
        for part in components(path) {
            guard let child = node.children[part] else { return nil }
            node = child
        }
        return node
    }

    @discardableResult
    private func makeDirectory(_ path: String, modified: Date) -> Node {
        var node = root
        for part in components(path) {
            if let child = node.children[part] {
                node = child
            } else {
                let child = Node(kind: .directory, modified: modified, inode: allocate())
                node.children[part] = child
                node = child
            }
        }
        return node
    }

    private func components(_ path: String) -> [String] {
        var out: [String] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = out.popLast()
            default: out.append(String(part))
            }
        }
        return out
    }

    private func normalize(_ path: String) -> String { "/" + components(path).joined(separator: "/") }

    private func split(_ path: String) -> (parent: String, name: String) {
        var parts = components(path)
        let name = parts.popLast() ?? ""
        return ("/" + parts.joined(separator: "/"), name)
    }
}

/// A wait that ends only when its task is cancelled.
final class Hang: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var cancelled = false

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let stop = lock.withLock {
                    if cancelled { return true }
                    self.continuation = continuation
                    return false
                }
                if stop { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiting = lock.withLock {
                cancelled = true
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(throwing: CancellationError())
        }
    }
}
