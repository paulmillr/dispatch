import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A file sent with a chat message (docs/integrations.md, Attachments). The app reads it once, in its own process, and
/// `attachments.put` stores a copy in the helper's attachment folder on the agent's host; the message names that copy,
/// so the agent never opens the original (no Desktop/Documents prompt, and the same path on an SSH host).
struct ChatAttachment: Codable, Equatable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case image, file }

    var id: String
    var name: String
    var kind: Kind
    /// Bytes stored on the host; 0 when a transcript names an attachment without its size.
    var size: Int
    /// The host copy `attachments.put` answered with; nil for an image an agent's transcript keeps without a path.
    var path: String?
    /// A small JPEG for chips and bubbles (`ChatAttachmentImage.thumbnail`); nil for files and for attachments only a
    /// transcript names, whose image `attachments.read` fetches while the host still keeps it.
    var thumbnail: Data?

    init(id: String = System.uuid().uuidString, name: String, kind: Kind, size: Int, path: String?, thumbnail: Data? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.size = size; self.path = path; self.thumbnail = thumbnail
    }

    /// Bytes one attachment may have (the helper's `attachments.put` limit); larger images are scaled down to fit.
    static let limit = 8 << 20
    /// Attachments one message may carry (the helper's `chat.send` limit).
    static let maximumCount = 10
    /// The hello feature that offers `attachments.put`/`attachments.read` and `attachments` on `chat.send`/`queue.add`.
    static let feature = "chat.attachments"

    /// `attachments` keep their thumbnails from `earlier` (the same message as the app sent it), matched by path, else
    /// by position among the earlier ones of the same kind not matched yet (a transcript names images without the
    /// thumbnail the composer made, sometimes without a path). Each earlier item is used once; ids stay unique.
    static func merge(_ attachments: [ChatAttachment], keeping earlier: [ChatAttachment]) -> [ChatAttachment] {
        guard !earlier.isEmpty, !attachments.isEmpty else { return attachments.isEmpty ? earlier : attachments }
        var used = Set<Int>()
        var matches = [Int?](repeating: nil, count: attachments.count)
        for (index, item) in attachments.enumerated() {
            guard let path = item.path, let match = earlier.indices.first(where: { !used.contains($0) && earlier[$0].path == path })
            else { continue }
            matches[index] = match; used.insert(match)
        }
        for (index, item) in attachments.enumerated() where matches[index] == nil {
            // Another host copy is another file: only one side without a path pairs by position.
            guard let match = earlier.indices.first(where: {
                !used.contains($0) && earlier[$0].kind == item.kind && (item.path == nil || earlier[$0].path == nil)
            }) else { continue }
            matches[index] = match; used.insert(match)
        }
        var merged = attachments.enumerated().map { index, item in
            guard let match = matches[index] else { return item }
            let previous = earlier[match]
            var item = item
            item.id = previous.id
            if item.thumbnail == nil { item.thumbnail = previous.thumbnail }
            if item.size == 0 { item.size = previous.size }
            if item.path == nil { item.path = previous.path }
            if item.name.isEmpty || item.name == Self.untitled(item.kind) { item.name = previous.name }
            return item
        }
        // An unmatched item keeps its own id, which an earlier one (now another item's) may share.
        var ids = Set(merged.indices.filter { matches[$0] != nil }.map { merged[$0].id })
        for index in merged.indices where matches[index] == nil {
            var id = merged[index].id, suffix = index
            while ids.contains(id) { id = merged[index].id + "~\(suffix)"; suffix += 1 }
            merged[index].id = id; ids.insert(id)
        }
        return merged
    }

    /// Whether two copies of a user message carry the same attachments: as many, and the same host copy wherever both
    /// name one. Image-only messages all have the same (empty) text; this tells them apart.
    static func same(_ lhs: [ChatAttachment], _ rhs: [ChatAttachment]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.path == nil || $1.path == nil || $0.path == $1.path }
    }

    static func untitled(_ kind: Kind) -> String { kind == .image ? "Image" : "File" }

    /// "412 KB" for a chip.
    var sizeText: String { size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) : "" }
}

enum ChatAttachmentError: LocalizedError, Equatable {
    case tooLarge(String)
    case unreadable(String)
    case tooMany

    var errorDescription: String? {
        switch self {
        case .tooLarge(let name): "\(name) is larger than \(ByteCountFormatter.string(fromByteCount: Int64(ChatAttachment.limit), countStyle: .file))."
        case .unreadable(let name): "\(name) could not be read."
        case .tooMany: "A message can carry at most \(ChatAttachment.maximumCount) attachments."
        }
    }
}

/// What the app uploads for one picked, dropped or pasted file: the bytes to store and the attachment that names
/// them. Pure ImageIO, so the Mac and the iPhone prepare files the same way.
enum ChatAttachmentImage {
    struct Prepared: Sendable {
        var name: String
        var kind: ChatAttachment.Kind
        var bytes: Data
        var thumbnail: Data?
    }

    /// Image formats every agent reads as an image (Claude Code and Codex take a pasted path ending in one of these).
    static let portable: [UTType] = [.png, .jpeg, .gif, .webP]
    /// The longest edge a chip or bubble draws, in pixels (2x of the largest bubble thumbnail).
    static let thumbnailEdge = 480

    /// An image in a format agents read (HEIC, TIFF and BMP become JPEG) and within `ChatAttachment.limit` (scaled down
    /// when it is larger); any other file as it is, refused when it is too large.
    static func prepare(name: String, data: Data) throws -> Prepared {
        let name = clean(name)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier), type.conforms(to: .image),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else {
            guard data.count <= ChatAttachment.limit else { throw ChatAttachmentError.tooLarge(name) }
            return Prepared(name: name, kind: .file, bytes: data, thumbnail: nil)
        }
        let thumbnail = self.thumbnail(source)
        if let portable = portable.first(where: { type.conforms(to: $0) }) {
            // Where and with what a photo was taken stays on this device; an image without such metadata is sent as is
            // (one that could not be stripped is re-encoded below, which drops it).
            let stripped = identifies(source, type: portable) ? withoutMetadata(source, type: portable) : (data, portable)
            if let (bytes, format) = stripped, bytes.count <= ChatAttachment.limit {
                return Prepared(name: named(name, format), kind: .image, bytes: bytes, thumbnail: thumbnail)
            }
        }
        // An animation cannot be re-encoded frame by frame here; one too large to send stays out.
        if CGImageSourceGetCount(source) > 1, type.conforms(to: .gif) { throw ChatAttachmentError.tooLarge(name) }
        for edge in [0, 4096, 3072, 2048, 1536] {
            guard let encoded = jpeg(source, edge: edge) else { break }
            if encoded.count <= ChatAttachment.limit {
                return Prepared(name: named(name, .jpeg), kind: .image, bytes: encoded, thumbnail: thumbnail)
            }
        }
        throw ChatAttachmentError.tooLarge(name)
    }

    /// Exif keys that say nothing about who, where or with what: they describe the pixels.
    private static let pixelKeys = Set([kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
                                        kCGImagePropertyExifColorSpace].map { $0 as String })
    /// TIFF keys that only lay the pixels out.
    private static let layoutKeys = Set([kCGImagePropertyTIFFOrientation, kCGImagePropertyTIFFXResolution, kCGImagePropertyTIFFYResolution,
                                         kCGImagePropertyTIFFResolutionUnit, kCGImagePropertyTIFFTileWidth,
                                         kCGImagePropertyTIFFTileLength].map { $0 as String })

    /// Whether the image carries GPS, Exif (beyond its pixel size), IPTC or camera TIFF metadata. GIFs are sent as
    /// they are.
    static func identifies(_ source: CGImageSource, type: UTType) -> Bool {
        guard !type.conforms(to: .gif),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        func keys(_ dictionary: CFString) -> Set<String> {
            Set((properties[dictionary] as? [String: Any])?.keys.map(\.self) ?? [])
        }
        return properties[kCGImagePropertyGPSDictionary] != nil || properties[kCGImagePropertyIPTCDictionary] != nil
            || properties[kCGImagePropertyExifAuxDictionary] != nil || properties[kCGImagePropertyMakerAppleDictionary] != nil
            || !keys(kCGImagePropertyExifDictionary).subtracting(pixelKeys).isEmpty
            || !keys(kCGImagePropertyTIFFDictionary).subtracting(layoutKeys).isEmpty
    }

    /// The image without that metadata, its orientation kept: a JPEG copied without re-encoding
    /// (`CGImageDestinationCopyImageSource`), a PNG (or a WebP, which ImageIO cannot write) re-encoded losslessly as PNG.
    static func withoutMetadata(_ source: CGImageSource, type: UTType) -> (Data, UTType)? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if type.conforms(to: .jpeg) {
            let metadata = CGImageMetadataCreateMutable()
            if orientation != 1 {
                _ = CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                                 kCGImagePropertyTIFFOrientation, orientation as NSNumber)
            }
            let data = NSMutableData()
            let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: false,
                                            kCGImageMetadataShouldExcludeGPS: true]
            if let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil),
               CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) {
                return (data as Data, .jpeg)
            }
        }
        // ImageIO's copy keeps a PNG's metadata: the pixels go into a new file, which carries only the orientation.
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let format: UTType = type.conforms(to: .jpeg) ? .jpeg : .png
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.identifier as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if format == .jpeg { options[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? (data as Data, format) : nil
    }

    /// A JPEG at most `thumbnailEdge` pixels on its longest edge, upright.
    static func thumbnail(_ data: Data) -> Data? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(thumbnail)
    }

    private static func thumbnail(_ source: CGImageSource) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailEdge, kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encode(image, quality: 0.8)
    }

    /// The first frame as a JPEG, its longest edge at most `edge` pixels (0: full size), upright.
    private static func jpeg(_ source: CGImageSource, edge: Int) -> Data? {
        let image: CGImage?
        if edge == 0 {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        return image.flatMap { encode($0, quality: 0.85) }
    }

    private static func encode(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The last path component without control characters or a leading dot, never empty.
    static func clean(_ name: String) -> String {
        var name = (name as NSString).lastPathComponent
        name = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "/" }))
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.utf8.count > 200 { name = String(name.prefix(120)) + "." + (name as NSString).pathExtension }
        return name.isEmpty ? "attachment" : name
    }

    /// `name` with `type`'s extension, so an agent that recognizes images by extension (Claude Code) sees one.
    static func named(_ name: String, _ type: UTType) -> String {
        let ext = (name as NSString).pathExtension
        if let current = UTType(filenameExtension: ext), current.conforms(to: type) { return name }
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        // "jpg", the extension a JPEG usually has (UTType prefers "jpeg").
        return (base.isEmpty ? "image" : base) + "." + (type == .jpeg ? "jpg" : type.preferredFilenameExtension ?? "jpg")
    }
}

extension HelperChat {
    /// `attachments.put` (helper/PROTOCOL.md): one file into the helper's attachment folder.
    struct AttachmentUpload: Encodable, Sendable {
        let name: String
        let bytes: Data
    }

    /// `attachments.put`'s reply.
    struct StoredAttachment: Decodable, Equatable, Sendable {
        let path: String
        let name: String
        let kind: String
        let size: UInt64

        func attachment(id: String, thumbnail: Data?) -> ChatAttachment {
            ChatAttachment(id: id, name: name, kind: kind == "image" ? .image : .file, size: Int(size), path: path, thumbnail: thumbnail)
        }
    }

    /// `attachments.read` (helper/PROTOCOL.md): a stored attachment's bytes, for a thumbnail the app no longer has.
    struct AttachmentRead: Encodable, Sendable { let path: String }
    struct AttachmentBytes: Decodable, Sendable {
        let bytes: Data
        let size: UInt64
    }
}

extension HelperChat.Record {
    /// What a user record carries besides its text (`{kind: "image"|"file", path, text: name}` blocks), in order.
    var attachments: [ChatAttachment] {
        blocks.enumerated().compactMap { index, block in
            guard block.kind == "image" || block.kind == "file" else { return nil }
            let kind: ChatAttachment.Kind = block.kind == "image" ? .image : .file
            let name = block.text.flatMap { $0.isEmpty ? nil : $0 }
                ?? block.path.map { ($0 as NSString).lastPathComponent } ?? ChatAttachment.untitled(kind)
            return ChatAttachment(id: "\(id)#\(index)", name: name, kind: kind, size: 0, path: block.path)
        }
    }
}
