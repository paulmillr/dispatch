import AppKit
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
    /// The promises of the drag being started, by tab: every row dragged together arrives as one copy.
    private var openBatches: [UUID: FilesPromiseBatch] = [:]

    init(engine: FileTransferEngine = .shared,
         coordinator: @escaping @MainActor () -> FilesCoordinator = { TerminalRuntime.shared.files },
         localSource: @escaping @MainActor () -> (any FilesSource)? = { FilesSources.local() },
         enabled: @escaping @MainActor () -> Bool = FilesTransferSettings.enabled) {
        self.engine = engine
        self.coordinator = coordinator
        self.localSource = localSource
        self.enabled = enabled
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
    /// is refused.
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
            self.copyIn(paths, into: directory, in: session)
        }
        return true
    }

    /// Copies files of this Mac into `directory` of the tab's host (a Finder drop, ⌘V). Refused, as a drop would
    /// be, when the tab shows this Mac and a file would land where it is or a folder inside itself.
    @discardableResult
    func copyIn(_ paths: [String], into directory: String, in session: FilesSession) -> Bool {
        guard !paths.isEmpty, let target = session.source, let local = localSource() else { return false }
        if target.readOnly { refuse(session, target); return false }
        if target.endpoint.isLocal, paths.contains(where: { Self.contains($0, directory) }) { return false }
        engine.copy(items: paths, from: local, to: target, directory: directory, in: session,
                    kind: target.endpoint.isLocal ? .local : .copyIn)
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
