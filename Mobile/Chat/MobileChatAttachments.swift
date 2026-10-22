import Foundation
import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One picked, pasted or dropped file before it is uploaded: its name and how to read it. The app reads it once, in
/// its own process (docs/ios.md, Attachments); `MobileChatSession.attach` prepares and uploads it.
struct MobileAttachmentSource: Sendable {
    let name: String
    /// What it most likely is, for the strip while it loads (`ChatAttachmentImage.prepare` decides).
    var kind: ChatAttachment.Kind = .file
    let load: @Sendable () async throws -> Data

    /// Bytes the app reads at most: an image beyond `ChatAttachment.limit` is scaled down, so it may be larger, but
    /// not without bound.
    static let readLimit = 64 << 20

    init(name: String, kind: ChatAttachment.Kind = .file, load: @escaping @Sendable () async throws -> Data) {
        self.name = name; self.kind = kind; self.load = load
    }

    /// Bytes already in memory (a paste).
    static func data(_ data: Data, name: String, kind: ChatAttachment.Kind) -> MobileAttachmentSource {
        MobileAttachmentSource(name: name, kind: kind) { data }
    }

    /// A file the document picker returned: read under its security scope, refused when it is far too large.
    static func file(_ url: URL) -> MobileAttachmentSource {
        let name = url.lastPathComponent
        let kind: ChatAttachment.Kind = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true ? .image : .file
        return MobileAttachmentSource(name: name, kind: kind) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > readLimit {
                throw ChatAttachmentError.tooLarge(name)
            }
            do { return try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw ChatAttachmentError.unreadable(name) }
        }
    }

    /// A photo from the library (`PhotosPicker`), in its stored format (HEIC becomes JPEG when prepared).
    static func photo(_ item: PhotosPickerItem, index: Int) -> MobileAttachmentSource {
        let type = item.supportedContentTypes.first { $0.conforms(to: .image) }
        let base = index == 0 ? "Photo" : "Photo \(index + 1)"
        let name = base + "." + (type?.preferredFilenameExtension ?? "jpg")
        return MobileAttachmentSource(name: name, kind: .image) {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw ChatAttachmentError.unreadable(name) }
            return data
        }
    }

    /// The images on a pasteboard (a screenshot, a photo copied from Photos), in the first image format each item has;
    /// empty when it has none.
    static func images(on pasteboard: UIPasteboard) -> [MobileAttachmentSource] {
        guard pasteboard.hasImages else { return [] }
        var sources: [MobileAttachmentSource] = []
        let preferred: [UTType] = [.png, .jpeg, .heic, .gif, .webP, .tiff, .image]
        for (index, item) in pasteboard.items.enumerated() {
            let types = item.keys.compactMap(UTType.init)
            guard let type = preferred.lazy.compactMap({ wanted in types.first { $0.conforms(to: wanted) } }).first else { continue }
            let data: Data? = switch item[type.identifier] {
            case let data as Data: data
            case let image as UIImage: image.pngData()
            default: nil
            }
            guard let data else { continue }
            let ext = type == .image ? "png" : type.preferredFilenameExtension ?? "png"
            sources.append(.data(data, name: (index == 0 ? "Pasted image" : "Pasted image \(index + 1)") + "." + ext, kind: .image))
        }
        if sources.isEmpty, let image = pasteboard.image, let data = image.pngData() {
            sources.append(.data(data, name: "Pasted image.png", kind: .image))
        }
        return sources
    }

    /// What a drop carries (an iPad dragging from Photos or Files): each item's image, else its file; text is left to
    /// the field.
    static func dropped(_ providers: [NSItemProvider]) -> [MobileAttachmentSource] {
        providers.compactMap { provider in
            let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
            let image = types.first { $0.conforms(to: .image) }
            guard let type = image ?? types.first(where: { $0.conforms(to: .data) && !$0.conforms(to: .text) }) else { return nil }
            let suggested = provider.suggestedName ?? (image != nil ? "Image" : "File")
            let ext = (suggested as NSString).pathExtension.isEmpty ? type.preferredFilenameExtension.map { "." + $0 } : nil
            let name = suggested + (ext ?? "")
            let box = ProviderBox(provider)
            return MobileAttachmentSource(name: name, kind: image != nil ? .image : .file) {
                try await withCheckedThrowingContinuation { continuation in
                    _ = box.provider.loadDataRepresentation(for: type) { data, error in
                        if let data { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: error ?? ChatAttachmentError.unreadable(name)) }
                    }
                }
            }
        }
    }

    /// The drop's types the composer takes.
    static let dropTypes: [UTType] = [.image, .data]

    private final class ProviderBox: @unchecked Sendable {
        let provider: NSItemProvider
        init(_ provider: NSItemProvider) { self.provider = provider }
    }
}

/// A file on its way to the host, as the composer's strip shows it: a spinner while it runs, the error and Retry after
/// it failed. Session state only (`MobileChatSession.uploads`).
struct ChatUpload: Identifiable, Equatable, Sendable {
    let id: String
    /// The draft it was started for (in its collection's `scope`): it shows there and lands there.
    var draft: UUID
    var scope: String
    var name: String
    var kind: ChatAttachment.Kind
    var thumbnail: Data?
    /// Why it failed; nil while it runs.
    var error: String?
}

/// Decoded thumbnails, in memory only: an attachment's own (`ChatAttachment.thumbnail`, by id) and the ones made from
/// a stored copy `attachments.read` fetched (by host and path), a few at a time. Never written anywhere; an image the
/// host no longer keeps stays a placeholder.
@MainActor @Observable final class MobileAttachmentThumbnails {
    static let shared = MobileAttachmentThumbnails()

    private(set) var images: [String: UIImage] = [:]
    @ObservationIgnored private var order: [String] = []
    /// Asked, or answered for good (`not_found`, `invalid_request`, bytes that are no image): not asked again.
    @ObservationIgnored private var requested: Set<String> = []
    /// Failed for now (no link, a timeout, another refusal): asked again once the wait is over.
    @ObservationIgnored private var retries: [String: (after: Date, failures: Int)] = [:]
    @ObservationIgnored private var waiting: [(key: String, read: () async throws -> Data?)] = []
    @ObservationIgnored private var running = 0
    /// Reads at once: each can be megabytes over one SSH channel, behind the conversation's own traffic.
    static let concurrency = 2
    /// Images kept; the oldest go first.
    static let capacity = 120
    /// Helper answers that will not change for the same path.
    static let permanent: Set<String> = ["not_found", "invalid_request"]

    /// The wait before asking again after `failures` transient failures in a row: 5 s, doubling, at most 5 minutes.
    static func backoff(_ failures: Int) -> TimeInterval { min(300, 5 * pow(2, Double(max(0, failures - 1)))) }

    static func key(host: UUID, path: String) -> String { host.uuidString + "|" + path }

    /// The attachment's image: its own thumbnail, else one fetched from `host` (requested here when `read` can), else nil.
    func image(_ attachment: ChatAttachment, host: UUID?, read: (@MainActor (String) async throws -> Data?)?,
               now: Date = Date()) -> UIImage? {
        if let data = attachment.thumbnail {
            let key = "id|" + attachment.id + "|\(data.count)"
            if let image = images[key] { return image }
            guard let image = UIImage(data: data) else { return nil }
            // Stored outside the view update that asked: SwiftUI reads this while it draws.
            Task { self.store(image, for: key) }
            return image
        }
        guard attachment.kind == .image, let host, let path = attachment.path else { return nil }
        let key = Self.key(host: host, path: path)
        if let image = images[key] { return image }
        if let read, !requested.contains(key), retries[key].map({ $0.after <= now }) ?? true {
            requested.insert(key)
            waiting.append((key, { try await read(path) }))
            Task { self.pump() }
        }
        return nil
    }

    private func pump() {
        while running < Self.concurrency, !waiting.isEmpty {
            let next = waiting.removeFirst()
            running += 1
            Task {
                defer { running -= 1; pump() }
                let result: Result<UIImage, any Error>
                do {
                    // Nil: this helper cannot say now (not connected, or without the feature).
                    guard let data = try await next.read() else { throw CancellationError() }
                    let thumbnail = await Task.detached(priority: .utility) { ChatAttachmentImage.thumbnail(data) }.value
                    guard let thumbnail, let image = UIImage(data: thumbnail) else {
                        throw ChatAttachmentError.unreadable((next.key as NSString).lastPathComponent)
                    }
                    result = .success(image)
                } catch { result = .failure(error) }
                finish(next.key, result)
            }
        }
    }

    /// How one read ended (internal for tests): an image, or a failure that is permanent or not.
    func finish(_ key: String, _ result: Result<UIImage, any Error>, now: Date = Date()) {
        switch result {
        case .success(let image):
            retries[key] = nil
            store(image, for: key)
        case .failure(let error as HelperFailure) where Self.permanent.contains(error.code):
            retries[key] = nil
        case .failure(is ChatAttachmentError):
            retries[key] = nil
        case .failure:
            requested.remove(key)
            let failures = (retries[key]?.failures ?? 0) + 1
            retries[key] = (now.addingTimeInterval(Self.backoff(failures)), failures)
        }
    }

    func store(_ image: UIImage, for key: String) {
        guard images[key] == nil else { return }
        images[key] = image
        order.append(key)
        while order.count > Self.capacity {
            // An evicted image is read again when a row shows it again.
            let evicted = order.removeFirst()
            images[evicted] = nil; requested.remove(evicted)
        }
    }

    /// Whether `key` would be read again now (tests).
    func asks(_ key: String, now: Date = Date()) -> Bool {
        images[key] == nil && !requested.contains(key) && (retries[key].map { $0.after <= now } ?? true)
    }

    /// Settings' Remove all data, and tests.
    func removeAll() {
        images = [:]; order = []; requested = []; waiting = []; retries = [:]
    }
}

/// A message's attachments in words, for VoiceOver, the queue and the watch: "Image", "3 files", "1 image, 2 files".
enum ChatAttachmentSummary {
    static func text(_ attachments: [ChatAttachment]) -> String {
        let images = attachments.filter { $0.kind == .image }.count
        let files = attachments.count - images
        func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }
        switch (images, files) {
        case (0, 0): return ""
        case (1, 0): return "Image"
        case (0, 1): return "File"
        case (_, 0): return count(images, "image")
        case (0, _): return count(files, "file")
        default: return count(images, "image") + ", " + count(files, "file")
        }
    }
}
