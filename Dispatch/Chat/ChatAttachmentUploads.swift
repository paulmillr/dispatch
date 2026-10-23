import AppKit
import Quartz
import UniformTypeIdentifiers

/// One file the user picked, dropped or pasted into the Mac composer (docs/integrations.md, Attachments). The app reads
/// it here, in its own process, where the open panel, the drag or the pasteboard granted it; the agent never opens it.
enum ChatAttachmentSource: Equatable, Sendable {
    case file(URL)
    /// Image data without a file (a screenshot taken to the clipboard), named for its format.
    case data(name: String, Data)

    var name: String {
        switch self {
        case .file(let url): ChatAttachmentImage.clean(url.lastPathComponent)
        case .data(let name, _): name
        }
    }

    /// An image file read for scaling (`ChatAttachmentImage.prepare` re-encodes larger ones under the limit).
    static let imageReadLimit = 128 << 20

    /// What a paste or drop of `pasteboard` attaches: Finder's files, else image data that is not a picture of copied
    /// text (a spreadsheet's cells carry both; those paste as text). Nothing for rows of a files view, whose paths are
    /// already on a host and are typed as text (`TerminalDrop.text`), and nothing for plain text.
    @MainActor static func read(_ pasteboard: NSPasteboard) -> [ChatAttachmentSource] {
        if FilesDragPayload.read(pasteboard) != nil { return [] }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return urls.map { .file($0) } }
        if let text = pasteboard.string(forType: .string), !text.isEmpty { return [] }
        let images: [(NSPasteboard.PasteboardType, String)] = [(.png, "png"), (.init(UTType.jpeg.identifier), "jpg"), (.tiff, "tiff")]
        for (type, ext) in images {
            if let data = pasteboard.data(forType: type), !data.isEmpty { return [.data(name: "Pasted image." + ext, data)] }
        }
        return []
    }

    /// The bytes to upload, read and converted off the main thread: a folder, an unreadable file or one too large to
    /// send is refused before anything is uploaded.
    func prepare() throws -> ChatAttachmentImage.Prepared {
        switch self {
        case .data(let name, let data):
            return try ChatAttachmentImage.prepare(name: name, data: data)
        case .file(let url):
            let name = self.name
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey])
            guard values?.isDirectory != true else { throw ChatAttachmentError.unreadable(name) }
            let image = values?.contentType?.conforms(to: .image) == true
            if let size = values?.fileSize, size > (image ? Self.imageReadLimit : ChatAttachment.limit) {
                throw ChatAttachmentError.tooLarge(name)
            }
            let data: Data
            do { data = try Data(contentsOf: url) } catch { throw ChatAttachmentError.unreadable(name) }
            return try ChatAttachmentImage.prepare(name: url.lastPathComponent, data: data)
        }
    }
}

/// A composer attachment still being read or uploaded, or one whose upload failed (kept for Retry). Transient: the draft
/// holds only what the host stored. It belongs to the draft it was started for (`draft` in `scope`): it shows on that
/// draft and lands in it, wherever the user switched meanwhile.
struct ChatAttachmentUpload: Identifiable {
    let id: String
    var draft: UUID
    var scope: String
    var name: String
    var size = 0
    var thumbnail: Data?
    /// Why the read or upload failed; nil while it runs.
    var failure: String?
    let source: ChatAttachmentSource
    var task: Task<Void, Never>?

    var uploading: Bool { failure == nil }
    /// The chip shows what the draft's attachments show.
    var attachment: ChatAttachment {
        ChatAttachment(id: id, name: name, kind: thumbnail == nil ? .file : .image, size: size, path: nil, thumbnail: thumbnail)
    }
}

/// Thumbnails for attachments a transcript names without one (another device sent them, or the app restarted): read
/// from the host with `attachments.read` while it keeps the copy, a few at a time, and kept in memory only.
@MainActor @Observable final class ChatAttachmentThumbnails {
    static let shared = ChatAttachmentThumbnails()

    struct Key: Hashable {
        let endpoint: HelperWorkspace.Endpoint
        let path: String
    }

    private(set) var images: [Key: NSImage] = [:]
    @ObservationIgnored private var order: [Key] = []
    /// Answered for good: the host no longer keeps it (`not_found`), refuses the path (`invalid_request`), or the bytes
    /// are no image.
    @ObservationIgnored private var unavailable: Set<Key> = []
    /// Failed for now (no link, a timeout, a helper without the feature): asked again once the wait is over.
    @ObservationIgnored private var retries: [Key: (after: Date, failures: Int)] = [:]
    @ObservationIgnored private var waiting: [Key] = []
    @ObservationIgnored private var loading: Set<Key> = []
    /// Thumbnails the attachments carry, decoded once per attachment.
    @ObservationIgnored private let decoded = NSCache<NSString, NSImage>()
    static let concurrency = 2
    static let capacity = 200
    /// Helper answers that will not change for the same path.
    static let permanent: Set<String> = ["not_found", "invalid_request"]

    /// The wait before asking again after `failures` transient failures in a row: 5 s, doubling, at most 5 minutes.
    static func backoff(_ failures: Int) -> TimeInterval { min(300, 5 * pow(2, Double(max(0, failures - 1)))) }

    /// The attachment's own thumbnail, else one read from its host earlier; nil until `request` has one.
    func image(_ attachment: ChatAttachment, endpoint: HelperWorkspace.Endpoint?) -> NSImage? {
        if let data = attachment.thumbnail {
            let key = (attachment.id + ":" + String(data.count)) as NSString
            if let image = decoded.object(forKey: key) { return image }
            guard let image = NSImage(data: data) else { return nil }
            decoded.setObject(image, forKey: key)
            return image
        }
        guard let endpoint, let path = attachment.path else { return nil }
        return images[Key(endpoint: endpoint, path: path)]
    }

    /// Reads the image's thumbnail from its host, unless one is shown, queued, known to be gone, or waiting out a
    /// transient failure.
    func request(_ attachment: ChatAttachment, endpoint: HelperWorkspace.Endpoint?, now: Date = Date()) {
        guard attachment.kind == .image, attachment.thumbnail == nil, let endpoint, let path = attachment.path else { return }
        let key = Key(endpoint: endpoint, path: path)
        guard asks(key, now: now) else { return }
        waiting.append(key)
        pump()
    }

    /// How one read ended (internal for tests): an image, or a failure that is permanent or not.
    func finish(_ key: Key, _ result: Result<NSImage, any Error>, now: Date = Date()) {
        loading.remove(key)
        switch result {
        case .success(let image):
            retries[key] = nil
            store(image, for: key)
        case .failure(let error as HelperFailure) where Self.permanent.contains(error.code):
            retries[key] = nil; unavailable.insert(key)
        case .failure(is ChatAttachmentError):
            retries[key] = nil; unavailable.insert(key)
        case .failure:
            let failures = (retries[key]?.failures ?? 0) + 1
            retries[key] = (now.addingTimeInterval(Self.backoff(failures)), failures)
        }
    }

    /// Whether `request` would read `key` now (tests).
    func asks(_ key: Key, now: Date = Date()) -> Bool {
        images[key] == nil && !unavailable.contains(key) && !loading.contains(key) && !waiting.contains(key)
            && (retries[key].map { $0.after <= now } ?? true)
    }

    private func pump() {
        while loading.count < Self.concurrency, !waiting.isEmpty {
            let key = waiting.removeFirst()
            loading.insert(key)
            Task { [weak self] in
                let result: Result<NSImage, any Error>
                do { result = .success(try await Self.thumbnail(key)) } catch { result = .failure(error) }
                guard let self else { return }
                self.finish(key, result)
                self.pump()
            }
        }
    }

    private func store(_ image: NSImage, for key: Key) {
        if images[key] == nil { order.append(key) }
        images[key] = image
        while order.count > Self.capacity { images.removeValue(forKey: order.removeFirst()) }
    }

    private static func thumbnail(_ key: Key) async throws -> NSImage {
        let data = try await bytes(key.path, endpoint: key.endpoint)
        guard let thumbnail = await Task.detached(priority: .utility, operation: { ChatAttachmentImage.thumbnail(data) }).value,
              let image = NSImage(data: thumbnail)
        else { throw ChatAttachmentError.unreadable((key.path as NSString).lastPathComponent) }
        return image
    }

    /// A stored attachment's bytes (`attachments.read`), from a helper that accepted `chat.attachments`.
    static func bytes(_ path: String, endpoint: HelperWorkspace.Endpoint) async throws -> Data {
        guard await HelperApp.shared.features(endpoint).contains(ChatAttachment.feature) else {
            throw HelperFailure(code: "unavailable", message: "This helper does not keep attachments.")
        }
        let params = HelperChat.AttachmentRead(path: path)
        let read: @Sendable () async throws -> HelperChat.AttachmentBytes = {
            try await HelperApp.shared.connection(endpoint).request("attachments.read", params: params)
        }
        guard endpoint.connection != nil else { return try await read().bytes }
        let bound = HelperFilesSource.Bound.bytes(UInt64(ChatAttachment.limit))
        return try await SSHTimeout.run(bound.duration ?? .seconds(600), "chat.attachments.read", operation: read).bytes
    }
}

/// Quick Look for an attachment: its host copy when the helper still has it, else the thumbnail the app kept. The
/// panel reads a private copy in the app's temporary folder: the next preview replaces it, and closing the panel or
/// quitting removes it (and any a crash left). The app delegate takes control of the panel through the responder chain
/// (`acceptsPreviewPanelControl`) while a preview is open, and hands it this data source.
@MainActor final class ChatAttachmentPreview: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = ChatAttachmentPreview()
    private(set) var item: URL?
    private var swept = false
    /// Where the copies live: one folder per preview.
    static var folder: URL { System.temporary.appendingPathComponent("Dispatch attachments", isDirectory: true) }

    func open(_ attachment: ChatAttachment, endpoint: HelperWorkspace.Endpoint?) {
        Task {
            if let endpoint, let path = attachment.path,
               let data = try? await ChatAttachmentThumbnails.bytes(path, endpoint: endpoint) {
                return show(data, name: ChatAttachmentImage.clean(attachment.name))
            }
            // A thumbnail is a JPEG whatever the original's name.
            guard let thumbnail = attachment.thumbnail else { NSSound.beep(); return }
            show(thumbnail, name: ChatAttachmentImage.named(attachment.name, .jpeg))
        }
    }

    /// Writes the private copy the panel shows, removing the one before (internal for tests: nothing is shown).
    @discardableResult func write(_ data: Data, name: String) -> URL? {
        let folder = Self.folder
        // Copies an earlier run left behind (a crash) go first.
        if !swept { swept = true; try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(System.uuid().uuidString, isDirectory: true).appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try PrivateFile.write(data, to: url)
        } catch { return nil }
        removeCopy()
        item = url
        return url
    }

    private func show(_ data: Data, name: String) {
        guard write(data, name: name) != nil else { NSSound.beep(); return }
        guard let panel = QLPreviewPanel.shared() else { return }
        // The responder chain names the controller (AppDelegate); without one, the panel still reads this source.
        panel.updateController()
        if panel.currentController == nil { panel.dataSource = self }
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// The panel's controller: taken while a preview is open.
    var acceptsControl: Bool { item != nil }

    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.reloadData()
    }

    /// The panel closed (or another controller took it): its copy goes.
    func end(_ panel: QLPreviewPanel) {
        if panel.dataSource === self { panel.dataSource = nil }
        removeCopy()
    }

    /// Removes the copy the panel showed (internal for tests).
    func removeCopy() {
        guard let previous = item else { return }
        item = nil
        try? FileManager.default.removeItem(at: previous.deletingLastPathComponent())
    }

    /// Every copy, at quit; best effort.
    func removeAll() {
        item = nil
        try? FileManager.default.removeItem(at: Self.folder)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { item == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { item.map { $0 as NSURL } }
}
