import Foundation
import ImageIO

/// Decides what the selected entry is and reads it into its `FilePreviewState` (F2d). The pane runs `load` in a
/// task keyed by the state, so selecting another row cancels the read in flight; a cancelled load never writes,
/// and each load writes only the state it was given, so one file's content never shows under another's header.
@MainActor enum FilePreviewLoader {
    /// The first window: enough to tell text from binary by a NUL byte.
    static let sniffLength: UInt64 = 8_192
    /// Text up to this size is read whole and highlighted; larger text is read on request.
    static let textLimit: UInt64 = 2 * 1_048_576
    /// "Show first 64 KB".
    static let headLength: UInt64 = 65_536
    /// Images are read whole; past this they are treated as binary rather than read.
    static let imageLimit: UInt64 = 32 * 1_048_576
    /// Reject implausible image canvases before ImageIO allocates their backing storage. Encoded byte size alone
    /// does not bound a highly compressed image's decoded memory.
    nonisolated static let imageDimensionLimit = 32_768
    nonisolated static let imagePixelLimit = 64_000_000
    /// Even actual-size mode uses a bounded thumbnail. The view may lay it out larger, but a preview never asks
    /// ImageIO for an unbounded source-sized bitmap.
    nonisolated static let imageDecodeDimensionLimit = 4_096

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tif", "tiff", "bmp"]
    static let markdownExtensions: Set<String> = ["md", "markdown"]

    /// What a file is, from its name, its size and its first window.
    enum Decision: Equatable {
        case image
        case binary
        case tooLarge
        case markdown
        case text(language: String)
    }

    static func decide(name: String, size: UInt64, head: Data) -> Decision {
        let ext = (name as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return size <= imageLimit ? .image : .binary }
        if head.contains(0) { return .binary }
        if validUTF8PrefixLength(head, allowingIncompleteSuffix: UInt64(head.count) < size) == nil { return .binary }
        if size > textLimit { return .tooLarge }
        if markdownExtensions.contains(ext) { return .markdown }
        return .text(language: SyntaxHighlight.language(name))
    }

    /// Loads `preview` once; an already loaded state is left as it is (switching modes remounts the pane, and a
    /// reload there would blank content the user is reading). A folder whose count a cancelled load left unfinished
    /// counts again.
    static func load(_ preview: FilePreviewState, from source: any FilesSource) async {
        switch preview.kind {
        case .loading, .error, .folder(nil): break
        default: return
        }
        if let entry = preview.entry {
            if entry.isDirectory { return await loadFolder(preview, from: source) }
            if entry.kind == .other {
                preview.kind = .error("A socket, pipe or device has no preview")
                return
            }
        }
        // A file that changes between the first window and the rest is read again from the start once; a file
        // that keeps changing says so rather than showing a mix of two versions.
        for attempt in 0..<2 {
            do {
                try await loadFile(preview, from: source)
                return
            } catch FilesSourceError.changed where attempt == 0 {
                guard !Task.isCancelled else { return }
                continue
            } catch {
                fail(preview, error)
                return
            }
        }
    }

    /// "Show first 64 KB" of a binary or too large file.
    static func loadHead(_ preview: FilePreviewState, from source: any FilesSource) async {
        let size: UInt64
        let binary: Bool
        switch preview.kind {
        case .binary(let total, .none): size = total; binary = true
        case .tooLarge(let total, .none): size = total; binary = false
        default: return
        }
        do {
            let result = try await source.read(preview.path, offset: 0, length: headLength, revision: preview.revision)
            guard !Task.isCancelled else { return }
            guard result.revision == preview.revision, result.revision.size == size,
                  UInt64(result.data.count) == min(headLength, size) else {
                throw FilesSourceError.changed(preview.path)
            }
            preview.revision = result.revision
            preview.kind = binary ? .binary(size: size, head: result.data)
                : textPrefix(result.data).map { .tooLarge(size: size, head: $0) }
                    ?? .binary(size: size, head: result.data)
        } catch FilesSourceError.changed {
            // The file is a different one now (it may even fit the preview): classify it again.
            guard !Task.isCancelled else { return }
            preview.kind = .loading
            preview.revision = nil
            await load(preview, from: source)
        } catch {
            fail(preview, error)
        }
    }

    private static func loadFolder(_ preview: FilePreviewState, from source: any FilesSource) async {
        if case .folder(.some) = preview.kind { return }
        preview.kind = .folder(nil)
        do {
            let summary = try await source.summary(preview.path)
            guard !Task.isCancelled else { return }
            preview.kind = .folder(summary)
        } catch {
            fail(preview, error)
        }
    }

    private static func loadFile(_ preview: FilePreviewState, from source: any FilesSource) async throws {
        let first: (data: Data, revision: FileRevision)
        do {
            first = try await source.read(preview.path, offset: 0, length: sniffLength, revision: nil)
        } catch let error as FilesSourceError {
            // Without an entry the row may be a folder: a folder's summary works where its read does not.
            guard preview.entry == nil, case .unsupported = error, let summary = try? await source.summary(preview.path) else {
                throw error
            }
            try Task.checkCancellation()
            preview.kind = .folder(summary)
            return
        }
        try Task.checkCancellation()
        let size = first.revision.size
        guard first.revision.kind == .file,
              UInt64(first.data.count) == min(sniffLength, size) else {
            throw FilesSourceError.changed(preview.path)
        }
        let decision = decide(name: preview.name, size: size, head: first.data)
        switch decision {
        case .binary:
            preview.revision = first.revision
            preview.kind = .binary(size: size, head: nil)
            return
        case .tooLarge:
            preview.revision = first.revision
            preview.kind = .tooLarge(size: size, head: nil)
            return
        case .image, .markdown, .text:
            break
        }
        var data = first.data
        var revision = first.revision
        if UInt64(first.data.count) < size {
            // Never turn a small preview into the source's protocol-wide (128 MB) "to the end" read. The revision
            // protects the file race; the explicit length also bounds a buggy or older remote source.
            let whole = try await source.read(preview.path, offset: 0, length: size, revision: first.revision)
            try Task.checkCancellation()
            guard whole.revision == first.revision, UInt64(whole.data.count) == size else {
                throw FilesSourceError.changed(preview.path)
            }
            data = whole.data
            revision = whole.revision
        }
        preview.revision = revision
        switch decision {
        case .image:
            // Only the header is read here; the pane decodes at the size it draws (`decodeImage`).
            let pixels = await imagePixelSize(data)
            try Task.checkCancellation()
            guard let pixels else {
                preview.kind = .binary(size: size, head: nil)
                return
            }
            guard isSafeImageSize(pixels) else {
                preview.kind = .error("Image dimensions are too large to preview safely")
                return
            }
            preview.kind = .image(data, pixelSize: pixels)
        case .markdown:
            guard let text = text(data) else {
                preview.kind = .binary(size: size, head: nil)
                return
            }
            preview.kind = .markdown(text)
        case .text(let language):
            guard let text = text(data) else {
                preview.kind = .binary(size: size, head: nil)
                return
            }
            preview.kind = .text(text, language: language)
        case .binary, .tooLarge:
            break
        }
    }

    /// The first image's pixels as it shows (EXIF rotation applied), from its header alone; nil when `data` holds no
    /// image ImageIO reads. Off the main actor: parsing a large file's header is not free.
    @concurrent nonisolated static func imagePixelSize(_ data: Data) async -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        // Orientations 5 to 8 turn the image a quarter.
        let turned = (properties[kCGImagePropertyOrientation] as? Int).map { $0 >= 5 } ?? false
        return turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// The image in `data` decoded no larger than `maxPixels` on its long side (nil: the hard preview cap), rotated
    /// as it shows. Off the main actor, and bounded: a 40-megapixel photo is never decoded at source size.
    @concurrent nonisolated static func decodeImage(_ data: Data, maxPixels: Int?) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        var options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true]
        options[kCGImageSourceThumbnailMaxPixelSize] = min(imageDecodeDimensionLimit, max(1, maxPixels ?? imageDecodeDimensionLimit))
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated static func isSafeImageSize(_ size: CGSize) -> Bool {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= CGFloat(imageDimensionLimit), size.height <= CGFloat(imageDimensionLimit) else { return false }
        return size.width * size.height <= CGFloat(imagePixelLimit)
    }

    /// Exact UTF-8 text. Lossy replacement characters can conceal different source bytes, so malformed input is
    /// offered as a hex preview instead. A leading UTF-8 BOM is metadata and is omitted from display.
    static func text(_ data: Data) -> String? {
        guard validUTF8PrefixLength(data, allowingIncompleteSuffix: false) == data.count else { return nil }
        let start = data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        return String(decoding: data.dropFirst(start), as: UTF8.self)
    }

    /// A bounded head can end midway through an otherwise valid scalar. Decode its complete prefix; invalid bytes
    /// before that boundary make the head binary instead of silently changing what the user sees.
    static func textPrefix(_ data: Data) -> String? {
        guard let count = validUTF8PrefixLength(data, allowingIncompleteSuffix: true) else { return nil }
        let start = data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        return String(decoding: data.dropFirst(start).prefix(max(0, count - start)), as: UTF8.self)
    }

    /// Returns the number of bytes in the valid prefix. With `allowingIncompleteSuffix`, only a well-formed scalar
    /// cut off at the end is accepted; overlong encodings, surrogates and values past U+10FFFF remain invalid.
    static func validUTF8PrefixLength(_ data: Data, allowingIncompleteSuffix: Bool) -> Int? {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let first = bytes[index]
            if first < 0x80 { index += 1; continue }
            let length: Int
            let second: ClosedRange<UInt8>
            switch first {
            case 0xC2...0xDF: length = 2; second = 0x80...0xBF
            case 0xE0: length = 3; second = 0xA0...0xBF
            case 0xE1...0xEC, 0xEE...0xEF: length = 3; second = 0x80...0xBF
            case 0xED: length = 3; second = 0x80...0x9F
            case 0xF0: length = 4; second = 0x90...0xBF
            case 0xF1...0xF3: length = 4; second = 0x80...0xBF
            case 0xF4: length = 4; second = 0x80...0x8F
            default: return nil
            }
            let available = min(length, bytes.count - index)
            if available >= 2, !second.contains(bytes[index + 1]) { return nil }
            if available >= 3 {
                for offset in 2..<available where !(0x80...0xBF).contains(bytes[index + offset]) { return nil }
            }
            guard available == length else { return allowingIncompleteSuffix ? index : nil }
            index += length
        }
        return index
    }

    private static func fail(_ preview: FilePreviewState, _ error: any Error) {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        if let error = error as? FilesSourceError {
            switch error {
            case .cancelled: return
            case .changed: preview.kind = .error("\(preview.name) kept changing while it was read")
            default: preview.kind = .error(error.message)
            }
            return
        }
        preview.kind = .error(error.localizedDescription)
    }
}
