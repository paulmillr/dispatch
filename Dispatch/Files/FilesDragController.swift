import AppKit
import Darwin
import os
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Rows dragged out of a files view: a property list naming their host, tab and absolute paths, so another files
    /// view (same host or not) or a terminal can take them.
    static let filesPaths = NSPasteboard.PasteboardType("yachts.dispatch.files-paths")
}

/// What one dragged row carries besides its file promise (`.filesPaths`).
struct FilesDragPayload: Equatable, Sendable {
    var endpoint: FilesEndpoint
    var session: UUID
    var paths: [String]

    var propertyList: [String: Any] {
        ["endpoint": Self.encode(endpoint), "session": session.uuidString, "paths": paths]
    }

    init(endpoint: FilesEndpoint, session: UUID, paths: [String]) {
        self.endpoint = endpoint
        self.session = session
        self.paths = paths
    }

    init?(propertyList: Any?) {
        guard let dictionary = propertyList as? [String: Any],
              let endpoint = (dictionary["endpoint"] as? String).flatMap(Self.decode),
              let session = (dictionary["session"] as? String).flatMap(UUID.init(uuidString:)),
              let paths = dictionary["paths"] as? [String], !paths.isEmpty,
              paths.allSatisfy({ $0.hasPrefix("/") }) else { return nil }
        self.init(endpoint: endpoint, session: session, paths: paths)
    }

    static func encode(_ endpoint: FilesEndpoint) -> String {
        switch endpoint {
        case .local: "local"
        case .remote(let id): "remote:" + id.rawValue.uuidString
        }
    }

    static func decode(_ text: String) -> FilesEndpoint? {
        if text == "local" { return .local }
        guard text.hasPrefix("remote:"), let id = UUID(uuidString: String(text.dropFirst("remote:".count))) else { return nil }
        return .remote(SSHConnectionID(id))
    }

    /// The rows on a pasteboard, one item per row, merged; rows from another tab than the first are left out.
    static func read(_ pasteboard: NSPasteboard) -> FilesDragPayload? {
        var merged: FilesDragPayload?
        for item in pasteboard.pasteboardItems ?? [] {
            guard let payload = FilesDragPayload(propertyList: item.propertyList(forType: .filesPaths)) else { continue }
            guard var current = merged else {
                merged = payload
                continue
            }
            guard current.endpoint == payload.endpoint, current.session == payload.session else { continue }
            current.paths += payload.paths.filter { !current.paths.contains($0) }
            merged = current
        }
        return merged
    }
}

/// The outline's drag sources and drop targets (F2b, F2c), one for every files view (`TerminalRuntime.shared.files`).
/// Drops of Finder files, of rows from another files view and pastes become copies through `FileTransferEngine`;
/// rows dragged out carry one file promise each, fetched only when the destination asks.
@MainActor final class FilesDragController: FilesDragDelegate {
    static let shared = FilesDragController()

    private let engine: FileTransferEngine
    private let coordinator: @MainActor () -> FilesCoordinator
    private let localSource: @MainActor () -> (any FilesSource)?
    private let enabled: @MainActor () -> Bool
    private let stage: @Sendable ([String]) throws -> FilesDropStaging
    /// The account's home, under which `ProtectedFolders` lie.
    private let home: String
    /// The promises of the drag being started, by tab: every row dragged together arrives as one copy.
    private var openBatches: [UUID: FilesPromiseBatch] = [:]
    /// ⌥ is held: rows dragged within their own list copy only then (Files copies and never moves, so a plain drag
    /// there, which moves in Finder, is refused). Tests set it.
    var optionHeld: @MainActor () -> Bool = { NSEvent.modifierFlags.contains(.option) }

    init(engine: FileTransferEngine = .shared,
         coordinator: @escaping @MainActor () -> FilesCoordinator = { TerminalRuntime.shared.files },
         localSource: @escaping @MainActor () -> (any FilesSource)? = { FilesSources.local() },
         enabled: @escaping @MainActor () -> Bool = FilesTransferSettings.enabled,
         stage: @escaping @Sendable ([String]) throws -> FilesDropStaging = FilesDropStaging.make,
         home: String = System.home.path) {
        self.engine = engine
        self.coordinator = coordinator
        self.localSource = localSource
        self.enabled = enabled
        self.stage = stage
        self.home = home
    }

    var dragEnabled: Bool { enabled() }

    var acceptedTypes: [NSPasteboard.PasteboardType] { [.filesPaths, .fileURL] }

    /// One writer per dragged row (as `NSOutlineView` asks for them), naming all of `paths` as text and as
    /// `.filesPaths`. A remote row promises the first of them, fetched only when the destination asks; a row of this
    /// Mac is its file URL, which every app takes (not all take promises) and Finder copies itself.
    func pasteboardWriter(for paths: [String], in session: FilesSession) -> NSPasteboardWriting? {
        guard dragEnabled, let source = session.source, let first = paths.first else { return nil }
        let payload = FilesDragPayload(endpoint: source.endpoint, session: session.id, paths: paths)
        if source.endpoint.isLocal { return Self.localItem(payload) }
        let batch = batch(for: session, source: source)
        let name = (first as NSString).lastPathComponent
        let parent = (first as NSString).deletingLastPathComponent
        let entry = session.listings[parent]?.entries.first { $0.name == name }
        let type = entry?.isDirectory == true ? UTType.folder
            : UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        return FilesPromiseProvider(payload: payload, name: name, fileType: type.identifier) { url, completion in
            batch.request(first, into: url, completion: completion)
        }
    }

    /// A local row as a plain pasteboard item: its file URL, `.filesPaths`, and its path as text.
    static func localItem(_ payload: FilesDragPayload) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if let first = payload.paths.first {
            item.setString(URL(fileURLWithPath: first).absoluteString, forType: .fileURL)
        }
        item.setPropertyList(payload.propertyList, forType: .filesPaths)
        item.setString(payload.paths.joined(separator: "\n"), forType: .string)
        return item
    }

    func validateDrop(_ info: NSDraggingInfo, onto directory: String, in session: FilesSession) -> NSDragOperation {
        validate(info.draggingPasteboard, onto: directory, in: session)
    }

    func acceptDrop(_ info: NSDraggingInfo, onto directory: String, in session: FilesSession) -> Bool {
        accept(info.draggingPasteboard, onto: directory, in: session)
    }

    func dragEnded(paths: [String], operation: NSDragOperation, in session: FilesSession) {
        // Promises already handed out still arrive; a later drag starts its own copy.
        openBatches[session.id] = nil
    }

    /// `validateDrop` on a pasteboard: a copy for Finder files or rows of a files view, when drag and drop is on
    /// and the tab shows files. A drop that would copy a folder into itself, or rows into the folder they are in,
    /// is refused, and so are rows dragged within their own list unless ⌥ is held.
    func validate(_ pasteboard: NSPasteboard, onto directory: String, in session: FilesSession) -> NSDragOperation {
        guard dragEnabled, let target = session.source else { return [] }
        // A host without Copy files in takes nothing, and says so while the drag is over it.
        if target.readOnly {
            if FilesDragPayload.read(pasteboard) != nil || !Self.droppedFiles(pasteboard).isEmpty { refuse(session, target) }
            return []
        }
        if let payload = FilesDragPayload.read(pasteboard) {
            guard source(for: payload) != nil else { return [] }
            if payload.endpoint == target.endpoint, payload.paths.contains(where: { Self.contains($0, directory) }) { return [] }
            // Within its own list a drag would move in Finder; here only ⌥ copies, and the list says so.
            if payload.session == session.id, payload.endpoint == target.endpoint, !optionHeld() {
                session.refuseMove()
                return []
            }
            return .copy
        }
        let files = Self.droppedFiles(pasteboard)
        guard !files.isEmpty, localSource() != nil else { return [] }
        // Only paths a URL spells out are checked here: a file reference's is known once the drop resolves it.
        if target.endpoint.isLocal, files.compactMap(Self.plainPath).contains(where: { Self.contains($0, directory) }) {
            return []
        }
        return .copy
    }

    func accept(_ pasteboard: NSPasteboard, onto directory: String, in session: FilesSession) -> Bool {
        guard validate(pasteboard, onto: directory, in: session) == .copy, let target = session.source else { return false }
        if let payload = FilesDragPayload.read(pasteboard) {
            guard let (source, origin) = source(for: payload) else { return false }
            if !source.endpoint.isLocal, !target.endpoint.isLocal, source.endpoint != target.endpoint, let origin {
                // Two hosts: the bytes pass through this Mac, shown on both tabs.
                engine.copy(items: payload.paths, from: source, to: target, directory: directory, in: origin,
                            kind: .copyOut, relay: session)
            } else {
                engine.copy(items: payload.paths, from: source, to: target, directory: directory, in: session,
                            kind: source.endpoint.isLocal && target.endpoint.isLocal ? .local : .copyIn, origin: origin)
            }
            return true
        }
        return copyIn(dropped: Self.droppedFiles(pasteboard), into: directory, in: session)
    }

    /// A Finder drop (or ⌘V): answered at once, its paths resolved off the main thread once the drop has returned,
    /// then copied as `copyIn` copies them (refused, silently, where a drop would have been).
    @discardableResult
    func copyIn(dropped files: [String], into directory: String, in session: FilesSession) -> Bool {
        guard !files.isEmpty else { return false }
        if let target = session.source, target.readOnly { refuse(session, target); return false }
        Task { @MainActor [weak self, weak session] in
            let paths = await Task.detached { Self.resolve(files) }.value
            guard let self, let session else { return }
            await self.copyInDropped(paths, into: directory, in: session)
        }
        return true
    }

    /// Whether `path` lies in one of the home's folders macOS guards with a consent prompt (`ProtectedFolders`). All
    /// on the home's volume, so staging one of their files is a clone.
    nonisolated static func isProtected(_ path: String, home: String) -> Bool { ProtectedFolders.isProtected(path, home: home) }

    /// Files the user dropped or pasted, which macOS lets this app read even in a folder it was denied (Desktop,
    /// Documents, Downloads), but not the helper it started. The app copies those into a private folder in its
    /// temporary folder (`FilesDropStaging`, a clone on APFS), and the copy reads them from there; the folder goes
    /// when the copy settles. Files in a `ProtectedFolders` folder are staged without the helper trying them first:
    /// its read would be the folder's first access when the app has no answer for it yet, and would raise the
    /// consent prompt for a copy that needs no consent. Elsewhere (a removable or network volume, where staging is a
    /// full copy) the helper tries each, and only those it is refused (`permission_denied`) are staged.
    private func copyInDropped(_ paths: [String], into directory: String, in session: FilesSession) async {
        guard let local = localSource() else { return }
        var denied: [String] = []
        for path in paths {
            if Self.isProtected(path, home: home) {
                denied.append(path)
                continue
            }
            do {
                _ = try await local.read(path, offset: 0, length: 0, revision: nil)
            } catch FilesSourceError.permissionDenied {
                denied.append(path)
            } catch FilesSourceError.privacyBlocked {
                denied.append(path)
            } catch {}
        }
        guard !denied.isEmpty else {
            copyIn(paths, into: directory, in: session)
            return
        }
        let stage = self.stage
        let staged: FilesDropStaging
        do {
            staged = try await Task.detached { try stage(denied) }.value
        } catch {
            // The app may not read them either: the copy goes as asked and fails with the setting's message.
            copyIn(paths, into: directory, in: session)
            return
        }
        let items = paths.map { staged.paths[$0] ?? $0 }
        guard copyIn(items, into: directory, in: session, finished: { transfer in
            switch transfer.stage {
            case .failed(_, true): break  // Retry reads the staged copies again; the next drop sweeps them.
            default: staged.remove()
            }
        }) else { return staged.remove() }
    }

    /// Copies files of this Mac into `directory` of the tab's host (a Finder drop, ⌘V). Refused, as a drop would
    /// be, when the tab shows this Mac and a file would land where it is or a folder inside itself.
    @discardableResult
    func copyIn(_ paths: [String], into directory: String, in session: FilesSession,
                finished: (@MainActor (FileTransfer) -> Void)? = nil) -> Bool {
        guard !paths.isEmpty, let target = session.source, let local = localSource() else { return false }
        if target.readOnly { refuse(session, target); return false }
        if target.endpoint.isLocal, paths.contains(where: { Self.contains($0, directory) }) { return false }
        engine.copy(items: paths, from: local, to: target, directory: directory, in: session,
                    kind: target.endpoint.isLocal ? .local : .copyIn, finished: finished)
        return true
    }

    private func refuse(_ session: FilesSession, _ target: any FilesSource) {
        session.refuseWrite(host: target.hostLabel ?? "This host")
    }

    /// Finder's files on a pasteboard, as file URLs: for ⌘V, never during a drag (`resolve` asks the file system).
    nonisolated static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        resolve(droppedFiles(pasteboard)).map { URL(fileURLWithPath: $0) }
    }

    /// Finder's files on a pasteboard, as the URL strings it wrote, read without touching the disk. Finder writes
    /// file references (`file:///.file/id=…`), whose path only the file system knows: `readObjects` as `NSURL`, or
    /// even `URL(string:)`, resolves them there and then, and in a protected folder (Downloads, Desktop) that may
    /// wait on a consent prompt. Validating and accepting a drop run while Finder's drag is live, where nothing may
    /// wait, so they read these strings and `resolve` runs after the drop.
    nonisolated static func droppedFiles(_ pasteboard: NSPasteboard) -> [String] {
        (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .fileURL) }.filter { $0.hasPrefix("file:") }
    }

    /// The path a dropped file's URL spells out, by string work alone; nil for a file reference.
    nonisolated static func plainPath(_ url: String) -> String? {
        guard !isReference(url), let parsed = URL(string: url), parsed.isFileURL else { return nil }
        // `standardized`, not `standardizedFileURL`: the latter checks the disk before dropping a /private prefix.
        let path = parsed.standardized.path
        return path.isEmpty ? nil : path
    }

    /// The dropped files' paths, asking the file system for file references (one that no longer resolves is left
    /// out). Never during a drag.
    nonisolated static func resolve(_ urls: [String]) -> [String] {
        urls.compactMap { url in
            guard isReference(url) else { return plainPath(url) }
            guard let path = NSURL(string: url)?.filePathURL?.standardized.path, !path.isEmpty else { return nil }
            return path
        }
    }

    nonisolated static func isReference(_ url: String) -> Bool { url.hasPrefix("file:///.file/") }

    /// `item` dropped on `directory` would land where it is, or inside itself.
    private static func contains(_ item: String, _ directory: String) -> Bool {
        let item = item.count > 1 && item.hasSuffix("/") ? String(item.dropLast()) : item
        return directory == item || directory.hasPrefix(item + "/") || (item as NSString).deletingLastPathComponent == directory
    }

    /// The source the dragged rows are read from: their tab's, while it still shows that host.
    private func source(for payload: FilesDragPayload) -> (any FilesSource, FilesSession?)? {
        if let session = coordinator().existing(payload.session), let source = session.source,
           source.endpoint == payload.endpoint {
            return (source, session)
        }
        if payload.endpoint.isLocal, let local = localSource() { return (local, nil) }
        return nil
    }

    private func batch(for session: FilesSession, source: any FilesSource) -> FilesPromiseBatch {
        if let batch = openBatches[session.id], batch.source === source { return batch }
        let batch = FilesPromiseBatch(session: session, source: source, engine: engine, localSource: localSource)
        openBatches[session.id] = batch
        // The outline asks for every row's writer in one go: the next drag, even without `dragEnded`, starts afresh.
        Task { @MainActor [weak self, weak batch] in
            if let batch, self?.openBatches[session.id] === batch { self?.openBatches[session.id] = nil }
        }
        return batch
    }
}

/// The promises of one drag. The destination asks for each row separately and almost at once; the batch gathers
/// them for a moment and fetches them as one copy (one row: "Copying 2 items to Downloads") into a folder of its
/// own, then moves each into the URL the destination named. A promise never asked for packs nothing.
@MainActor final class FilesPromiseBatch {
    struct Request {
        let path: String
        let url: URL
        let completion: ((any Error)?) -> Void
    }

    weak var session: FilesSession?
    let source: any FilesSource
    private let engine: FileTransferEngine
    private let localSource: @MainActor () -> (any FilesSource)?
    private var pending: [Request] = []
    private var gathering = false

    init(session: FilesSession, source: any FilesSource, engine: FileTransferEngine,
         localSource: @escaping @MainActor () -> (any FilesSource)?) {
        self.session = session
        self.source = source
        self.engine = engine
        self.localSource = localSource
    }

    func request(_ path: String, into url: URL, completion: @escaping ((any Error)?) -> Void) {
        pending.append(Request(path: path, url: url, completion: completion))
        guard !gathering else { return }
        gathering = true
        Task { @MainActor in
            try? await System.sleep(for: .milliseconds(50), "files.promise.gather")
            self.fetch()
        }
    }

    private func fetch() {
        let requests = pending
        pending = []
        gathering = false
        guard let session, let local = localSource() else {
            for request in requests { request.completion(FilesPromiseError(message: "The files are no longer available")) }
            return
        }
        // Two rows with the same name (from different folders) cannot share one folder: each goes in its own copy.
        var groups: [[Request]] = []
        for request in requests {
            let name = (request.path as NSString).lastPathComponent
            if let index = groups.firstIndex(where: { !$0.contains { ($0.path as NSString).lastPathComponent == name } }) {
                groups[index].append(request)
            } else {
                groups.append([request])
            }
        }
        for group in groups { fetch(group, session: session, local: local) }
    }

    private func fetch(_ requests: [Request], session: FilesSession, local: any FilesSource) {
        let folder = System.temporary.appendingPathComponent("dispatch-promise-" + System.uuid().uuidString)
        do {
            try System.directory(folder)
        } catch {
            for request in requests { request.completion(error) }
            return
        }
        let destination = requests[0].url.deletingLastPathComponent().lastPathComponent
        engine.copy(items: requests.map(\.path), from: source, to: local, directory: folder.path, in: session,
                    kind: .copyOut, label: destination, retryable: false) { transfer in
            for request in requests {
                guard transfer.stage == .done else {
                    let message = if case .failed(let message, _) = transfer.stage { message } else { "Cancelled" }
                    request.completion(FilesPromiseError(message: message))
                    continue
                }
                let staged = folder.appendingPathComponent((request.path as NSString).lastPathComponent)
                // The destination named a free URL; a move never replaces what is there.
                do {
                    try System.move(staged, to: request.url)
                    request.completion(nil)
                } catch {
                    request.completion(error)
                }
            }
            try? System.remove(folder)
        }
    }
}

/// Dropped items the app copied for the helper (`FilesDragController.copyInDropped`): one private folder in the app's
/// temporary folder, each item under its own name (a name already taken goes in a numbered subfolder, so names stay
/// as dropped). A failed copy removes what it made; staging sweeps folders an earlier run or retry left behind.
struct FilesDropStaging: Sendable {
    static let prefix = "dispatch-drop-"

    let folder: URL
    /// Each dropped path → its copy.
    let paths: [String: String]

    func remove() {
        try? System.remove(folder)
        Self.live.withLock { _ = $0.remove(folder.path) }
    }

    private static let live = OSAllocatedUnfairLock(initialState: Set<String>())

    static func make(_ items: [String]) throws -> FilesDropStaging {
        sweep()
        let folder = System.temporary.appendingPathComponent(prefix + System.uuid().uuidString)
        try System.directory(folder)
        live.withLock { _ = $0.insert(folder.path) }
        let staging = FilesDropStaging(folder: folder, paths: [:])
        do {
            var paths: [String: String] = [:]
            var taken: Set<String> = []
            for (index, item) in items.enumerated() {
                let name = (item as NSString).lastPathComponent
                var parent = folder
                if !taken.insert(name).inserted {
                    parent = folder.appendingPathComponent(String(index))
                    try System.directory(parent)
                }
                let copy = parent.appendingPathComponent(name)
                try System.copy(URL(fileURLWithPath: item), to: copy)
                paths[item] = copy.path
            }
            return FilesDropStaging(folder: folder, paths: paths)
        } catch {
            staging.remove()
            throw error
        }
    }

    /// Staging folders no copy uses any more (a failed copy dismissed without a retry, a quit mid-copy).
    private static func sweep() {
        let live = live.withLock { $0 }
        for name in (try? System.list(System.temporary)) ?? [] where name.hasPrefix(prefix) {
            let path = System.temporary.appendingPathComponent(name).path
            if !live.contains(path) { try? System.remove(URL(fileURLWithPath: path)) }
        }
    }
}

struct FilesPromiseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One dragged row: a file promise, plus its paths as text (one per line) and as `.filesPaths`.
final class FilesPromiseProvider: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    let payload: FilesDragPayload
    let name: String
    private let write: @MainActor (URL, @escaping ((any Error)?) -> Void) -> Void

    init(payload: FilesDragPayload, name: String, fileType: String,
         write: @escaping @MainActor (URL, @escaping ((any Error)?) -> Void) -> Void) {
        self.payload = payload
        self.name = name
        self.write = write
        super.init()
        self.fileType = fileType
        // The provider keeps its delegate weakly: being its own delegate keeps both alive for the drag.
        self.delegate = self
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.filesPaths, .string]
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType,
                                 pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == .filesPaths || type == .string ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .filesPaths: payload.propertyList
        case .string: payload.paths.joined(separator: "\n")
        default: super.pasteboardPropertyList(forType: type)
        }
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        name
    }

    /// Writes run on the main queue: the copy itself is asynchronous, so nothing blocks while the destination waits.
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping ((any Error)?) -> Void) {
        // The main queue (`operationQueue`) delivers this; the provider and the handler stay on it.
        nonisolated(unsafe) let completion = completionHandler
        let write = self.write
        MainActor.assumeIsolated { write(url) { completion($0) } }
    }
}

// MARK: Copy and Download (the row menu)

extension FilesDragController {
    /// Copy (⌘C) on rows: their paths at once, as text and `.filesPaths` (a terminal or chat here types them, another
    /// files view copies them), and the files themselves for Finder and other apps: a local row's file URL; a remote
    /// row's once fetched into a private folder (`FilesClipboardFolder`, a row "Copying … to Clipboard"), added only
    /// while the clipboard still holds this copy. Rows sharing a name (from different folders) stay text.
    func copyToClipboard(_ paths: [String], in session: FilesSession, pasteboard: NSPasteboard = .general) {
        guard let source = session.source, !paths.isEmpty else { return }
        let payload = FilesDragPayload(endpoint: source.endpoint, session: session.id, paths: paths)
        if source.endpoint.isLocal {
            Self.write(payload, files: paths.map { URL(fileURLWithPath: $0) }, to: pasteboard)
            return
        }
        Self.write(payload, files: [], to: pasteboard)
        let names = paths.map { ($0 as NSString).lastPathComponent }
        guard Set(names).count == names.count, let local = localSource(),
              let folder = try? FilesClipboardFolder.next() else { return }
        let change = pasteboard.changeCount
        engine.copy(items: paths, from: source, to: local, directory: folder.path, in: session, kind: .copyOut,
                    label: "Clipboard", retryable: false) { transfer in
            guard transfer.stage == .done, pasteboard.changeCount == change else {
                FilesClipboardFolder.remove(folder)
                return
            }
            Self.write(payload, files: names.map { folder.appendingPathComponent($0) }, to: pasteboard)
            FilesClipboardFolder.keep(folder, whileOwnedBy: pasteboard, change: pasteboard.changeCount)
        }
    }

    /// One item per row: the first carries every path as text and `.filesPaths`, each its file URL when it has one.
    static func write(_ payload: FilesDragPayload, files: [URL], to pasteboard: NSPasteboard) {
        let first = NSPasteboardItem()
        first.setPropertyList(payload.propertyList, forType: .filesPaths)
        first.setString(payload.paths.joined(separator: "\n"), forType: .string)
        if let url = files.first { first.setString(url.absoluteString, forType: .fileURL) }
        let rest = files.dropFirst().map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([first] + rest)
    }

    /// Download…: `paths` fetched into a private folder, as a drag out is, then moved by the app to `destinations`
    /// (one URL per path, which a save or open panel let it write; the helper may not write in Downloads or Desktop).
    /// A destination that exists is replaced: the panel asked. `done` gets the failure, if any, once it settles.
    func download(_ paths: [String], to destinations: [URL], replacing replacements: [FileIdentity?]? = nil,
                  in session: FilesSession,
                  done: @escaping @MainActor ((any Error)?) -> Void = { _ in }) {
        guard let source = session.source, let local = localSource(), paths.count == destinations.count, !paths.isEmpty else { return }
        let replacements = replacements ?? Array(repeating: nil, count: destinations.count)
        guard replacements.count == destinations.count else { return }
        let folder = System.temporary.appendingPathComponent("dispatch-download-" + System.uuid().uuidString)
        do { try System.directory(folder) } catch { done(error); return }
        let label = destinations[0].deletingLastPathComponent().lastPathComponent
        engine.copy(items: paths, from: source, to: local, directory: folder.path, in: session, kind: .copyOut,
                    label: label, retryable: false) { transfer in
            defer { try? System.remove(folder) }
            guard transfer.stage == .done else { return done(nil) }
            do {
                for ((path, destination), replacement) in zip(zip(paths, destinations), replacements) {
                    let staged = folder.appendingPathComponent((path as NSString).lastPathComponent)
                    if let replacement { try System.replace(staged, at: destination, replacing: replacement) }
                    else { try System.move(staged, to: destination) }
                }
                done(nil)
            } catch { done(error) }
        }
    }

    /// Where Download… puts `names` in `folder`: each under its own name, or Finder's "name 2" beside one already
    /// there (or picked for an earlier one).
    nonisolated static func destinations(for names: [String], folders: [Bool], in folder: URL,
                                         exists: (URL) -> Bool) -> [URL] {
        var taken = Set<String>(), chosen: [URL] = []
        for (name, isFolder) in zip(names, folders) {
            func free(_ candidate: String) -> Bool { !taken.contains(candidate) && !exists(folder.appendingPathComponent(candidate)) }
            let name = free(name) ? name : FileTransferEngine.keptName(name, folder: isFolder) { !free($0) }
            taken.insert(name)
            chosen.append(folder.appendingPathComponent(name))
        }
        return chosen
    }
}

/// The private folder a Copy of remote rows is fetched into, in the app's temporary folder: one at a time, the
/// previous copy's removed when the next starts (a paste in Finder copies out of it; it never holds the original).
enum FilesClipboardFolder {
    static let prefix = "dispatch-clipboard-"

    @MainActor static func next() throws -> URL {
        if let current { remove(current) }
        guard let owner = AgentProcess.capture(System.pid) else { throw POSIXError(.ESRCH) }
        let name = [String(owner.pid), String(owner.startedSeconds), String(owner.startedMicroseconds), System.uuid().uuidString]
            .joined(separator: "-")
        let folder = System.temporary.appendingPathComponent(prefix + name)
        try System.directory(folder)
        current = folder
        return folder
    }

    /// The staged files live only while this copy still owns the pasteboard. A paste consumes their URLs but does not
    /// change the pasteboard; replacing the clipboard does, and releases them on the next short poll.
    @MainActor static func keep(_ folder: URL, whileOwnedBy pasteboard: NSPasteboard, change: Int) {
        guard current == folder else { return remove(folder) }
        ownership?.cancel()
        ownership = Task { @MainActor in
            while !Task.isCancelled, current == folder, pasteboard.changeCount == change {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled, current == folder else { return }
            remove(folder)
        }
    }

    @MainActor static func remove(_ folder: URL) {
        if current == folder {
            current = nil
            ownership?.cancel()
            ownership = nil
        }
        try? System.remove(folder)
    }

    /// Normal quit removes the backing copy for any file URLs this app put on the clipboard.
    @MainActor static func removeAll() {
        if let current { remove(current) }
    }

    /// Folders left by a crash have their creator's process identity in their name. A live other Dispatch keeps its
    /// own even when pids have been recycled; folders from older name formats are stale too. Replay performs no sweep.
    @MainActor static func sweep() {
        guard !AppReplay.replaying else { return }
        for name in (try? System.list(System.temporary)) ?? [] where name.hasPrefix(prefix) {
            let suffix = name.dropFirst(prefix.count)
            let parts = suffix.split(separator: "-", maxSplits: 3, omittingEmptySubsequences: false)
            let pid = parts.count == 4 ? Int32(parts[0]) : nil
            let seconds = parts.count == 4 ? UInt64(parts[1]) : nil
            let microseconds = parts.count == 4 ? UInt64(parts[2]) : nil
            let identifier = parts.count == 4 ? UUID(uuidString: String(parts[3])) : nil
            let process = pid.flatMap(AgentProcess.capture)
            let live = identifier != nil && process?.startedSeconds == seconds && process?.startedMicroseconds == microseconds
            if !live { try? System.remove(System.temporary.appendingPathComponent(name)) }
        }
    }

    @MainActor private static var current: URL?
    @MainActor private static var ownership: Task<Void, Never>?
}

/// The `scp` command that fetches rows of a remote files view into the current folder, by the destination the tab's
/// ssh connection was started with: `scp [-r] [-P port] dest:'/path' … .`.
enum FilesScpCommand {
    nonisolated static func make(destination: String, paths: [String], folders: Bool) -> String? {
        guard !paths.isEmpty else { return nil }
        var target = destination.trimmingCharacters(in: .whitespaces), port: String?
        if target.hasPrefix("ssh://") {
            target.removeFirst("ssh://".count)
            while target.hasSuffix("/") { target.removeLast() }
            if let colon = target.lastIndex(of: ":") {
                let digits = target[target.index(after: colon)...]
                if !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) {
                    port = String(digits)
                    target = String(target[..<colon])
                }
            }
        }
        guard !target.isEmpty else { return nil }
        let host = target.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "@._-[]:%".contains($0)) } ? target : quote(target)
        let sources = paths.map { host + ":" + quote($0) }
        return (["scp"] + (folders ? ["-r"] : []) + (port.map { ["-P", $0] } ?? []) + sources + ["."]).joined(separator: " ")
    }

    /// Single quotes for the shell the command is pasted into.
    nonisolated static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
