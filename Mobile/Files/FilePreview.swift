import Foundation
import Observation
import ImageIO
import SwiftUI
import UIKit

/// What F2 shows for a path, read through `files.read` (docs/ios.md, Files): text with its syntax colours, Markdown
/// (rendered, or its source), an image, a binary's kind and size, or a folder (which the screen shows as a listing).
/// Text past `headLimit` shows its first `headLimit` bytes with Load all (up to `wholeLimit`); a file that changes
/// between two reads is read again from the start once, then says so.
@MainActor @Observable
final class FilePreview {
    enum Content: Equatable {
        case loading
        /// UTF-8 text: the whole file, or its first `headLimit` bytes (`truncated`).
        case text(String, language: String, truncated: Bool)
        case markdown(String, truncated: Bool)
        case image(Data)
        case binary
        case folder
        case failed(String)
    }

    /// What a file is, from its name, size and first bytes.
    enum Kind: Equatable {
        case text(language: String)
        case markdown
        case image
        case binary
    }

    let path: String
    private(set) var content: Content = .loading
    /// The revision the content was read at (its size, its modified time).
    private(set) var revision: FileRevision?
    /// The whole of a truncated text is being read.
    private(set) var loadingAll = false
    /// Text's lines in the syntax palette (`CodeSyntax.lines`), made once per text; tabs drawn as four spaces.
    private(set) var lines: [AttributedString] = []
    /// The longest line's characters: the code's width without wrapping.
    private(set) var longest = 0
    /// Bumped whenever `lines` change (Find searches again on it; comparing the lines themselves is not free).
    private(set) var version = 0
    /// The image shown is a smaller copy of one past `FilesImage.pixelCap`: Share and Ask read the file again.
    private(set) var downsampled = false

    @ObservationIgnored private let source: @MainActor () -> (any MobileFilesSource)?
    @ObservationIgnored let host: String

    /// Text read whole up to this; past it the first `headLimit` bytes, with Load all.
    static let headLimit: UInt64 = 256 * 1024
    /// Load all reads at most this (a phone draws no more as code).
    static let wholeLimit: UInt64 = 8 * 1024 * 1024
    /// Images are read whole up to this; larger ones are binary.
    static let imageLimit: UInt64 = 32 * 1024 * 1024
    /// Share reads a binary file whole up to this.
    static let shareLimit: UInt64 = 64 * 1024 * 1024
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tif", "tiff", "bmp"]
    static let markdownExtensions: Set<String> = ["md", "markdown"]

    init(path: String, host: String, source: @escaping @MainActor () -> (any MobileFilesSource)?) {
        self.path = path
        self.host = host
        self.source = source
    }

    var name: String { FilesPath.name(path) }
    var size: UInt64? { revision?.size }

    /// The text shown (text or Markdown), nil for other content.
    var text: String? {
        switch content {
        case .text(let text, _, _), .markdown(let text, _): text
        default: nil
        }
    }

    var truncated: Bool {
        switch content {
        case .text(_, _, let truncated), .markdown(_, let truncated): truncated
        default: false
        }
    }

    /// Only a truncated text that fits `wholeLimit` offers Load all.
    var canLoadAll: Bool { truncated && (size ?? .max) <= Self.wholeLimit }

    static func decide(name: String, size: UInt64, head: Data) -> Kind {
        let ext = (name as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return size <= imageLimit ? .image : .binary }
        if head.contains(0) { return .binary }
        if decode(head, partial: UInt64(head.count) < size) == nil { return .binary }
        if markdownExtensions.contains(ext) { return .markdown }
        return .text(language: CodeSyntax.language(name))
    }

    /// `data` as UTF-8; `partial` (a window of a longer file) lets up to three bytes of a character cut at its end go.
    static func decode(_ data: Data, partial: Bool) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        guard partial else { return nil }
        for cut in 1...3 where data.count > cut {
            if let text = String(data: data.dropLast(cut), encoding: .utf8) { return text }
        }
        return nil
    }

    /// Reads the file (once: a loaded preview stays as it is).
    func load() async {
        switch content {
        case .loading, .failed: break
        default: return
        }
        content = .loading
        for attempt in 0..<2 {
            do {
                try await read()
                return
            } catch FilesSourceError.changed where attempt == 0 {
                guard !Task.isCancelled else { return }
            } catch {
                fail(error)
                return
            }
        }
    }

    private func read() async throws {
        guard let source = source() else { throw FilesSourceError.offline(host) }
        let first: (data: Data, revision: FileRevision)
        do {
            first = try await source.read(path, offset: 0, length: Self.headLimit, revision: nil)
        } catch FilesSourceError.unsupported(let detail) {
            // A folder has no bytes to read: it lists.
            if (try? await source.list(path, hidden: false)) != nil { content = .folder; return }
            throw FilesSourceError.unsupported(detail)
        }
        try Task.checkCancellation()
        if first.revision.kind == .directory { content = .folder; return }
        let size = first.revision.size
        guard UInt64(first.data.count) == min(Self.headLimit, size) else { throw FilesSourceError.changed(path) }
        revision = first.revision
        switch Self.decide(name: name, size: size, head: first.data) {
        case .binary:
            content = .binary
        case .image:
            var data = first.data
            if UInt64(data.count) < size {
                let whole = try await source.read(path, offset: 0, length: size, revision: first.revision)
                try Task.checkCancellation()
                guard whole.revision == first.revision, UInt64(whole.data.count) == size else { throw FilesSourceError.changed(path) }
                data = whole.data
            }
            // Its size read from the header first: past the cap only a smaller copy is ever decoded.
            let bytes = data
            let shown = await Task.detached(priority: .userInitiated) { FilesImage.shown(bytes) }.value
            try Task.checkCancellation()
            switch shown {
            case .image(let image, let smaller):
                downsampled = smaller
                content = .image(image)
            case .tooLarge, .none:
                content = .binary
            }
        case .markdown:
            let truncated = UInt64(first.data.count) < size
            guard let text = Self.decode(first.data, partial: truncated) else { content = .binary; return }
            await show(.markdown(text, truncated: truncated), text: text, language: "markdown")
        case .text(let language):
            let truncated = UInt64(first.data.count) < size
            guard let text = Self.decode(first.data, partial: truncated) else { content = .binary; return }
            await show(.text(text, language: language, truncated: truncated), text: text, language: language)
        }
    }

    /// Load all: the whole text, at the revision the head was read at (a changed file reads again from the start).
    func loadAll() async {
        guard canLoadAll, !loadingAll, let revision, let source = source() else { return }
        loadingAll = true
        defer { loadingAll = false }
        do {
            let whole = try await source.read(path, offset: 0, length: revision.size, revision: revision)
            guard whole.revision == revision, UInt64(whole.data.count) == revision.size,
                  let text = Self.decode(whole.data, partial: false) else { throw FilesSourceError.changed(path) }
            switch content {
            case .text(_, let language, _):
                await show(.text(text, language: language, truncated: false), text: text, language: language)
            case .markdown:
                await show(.markdown(text, truncated: false), text: text, language: "markdown")
            default: break
            }
        } catch FilesSourceError.changed {
            content = .loading
            self.revision = nil
            await load()
        } catch {
            fail(error)
        }
    }

    /// The file's bytes for Share and Ask: what is loaded when it is the whole file, else a read of it (up to `limit`).
    func bytes(limit: UInt64 = FilePreview.shareLimit) async throws -> Data {
        if let text, !truncated { return Data(text.utf8) }
        if case .image(let data) = content, !downsampled { return data }
        guard let source = source() else { throw FilesSourceError.offline(host) }
        let size = revision?.size ?? limit
        guard size <= limit else { throw FilesSourceError.limit("\(name) is larger than \(FilesFormatting.size(limit))") }
        return try await source.read(path, offset: 0, length: size, revision: revision).data
    }

    /// The text's lines are made off the main actor (a Load all of megabytes), then they and the content change in one
    /// turn, so no frame shows the new text with the old lines.
    private func show(_ next: Content, text: String, language: String) async {
        let (lines, longest) = await Task.detached(priority: .userInitiated) { Self.layout(text, language: language) }.value
        guard !Task.isCancelled else { return }
        self.lines = lines
        self.longest = longest
        version += 1
        content = next
    }

    /// `text` as lines in the syntax palette (`CodeSyntax.lines`, which colours up to its 64 KB bound and leaves longer
    /// text plain), tabs drawn as four spaces, and the longest line's length.
    nonisolated static func layout(_ text: String, language: String) -> ([AttributedString], Int) {
        let shown = text.replacingOccurrences(of: "\t", with: "    ")
        var lines = CodeSyntax.lines(shown, language: language)
        // A final newline ends the last line; it starts no empty one.
        if lines.count > 1, shown.hasSuffix("\n") { lines.removeLast() }
        return (lines, lines.reduce(0) { max($0, $1.characters.count) })
    }

    /// Markdown past what chat renders (`TextRendering.richLineLimit` lines or `richScalarLimit` characters): the
    /// rendered view shows its start and says so; Show source has all of it.
    var markdownCapped: Bool {
        guard case .markdown(let text, _) = content else { return false }
        return text.unicodeScalars.count > TextRendering.richScalarLimit
            || text.utf8.reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) } > TextRendering.richLineLimit
    }

    private func fail(_ error: any Error) {
        let failure = error as? FilesSourceError
        switch failure {
        case .cancelled?: return
        case .notFound?: content = .failed("\(name) is not on \(host) any more.")
        case .permissionDenied?: content = .failed("\(host) does not let this account read \(name).")
        case .changed?: content = .failed("\(name) keeps changing while it is read.")
        case .offline?: content = .failed("\(host) is offline.")
        default: content = .failed(failure?.message ?? error.localizedDescription)
        }
    }
}

/// Find in file: the query's occurrences, in order, one of them current.
struct FileFind: Equatable {
    struct Match: Equatable {
        let line: Int
        /// Which occurrence on its line.
        let occurrence: Int
    }

    var query = ""
    private(set) var matches: [Match] = []
    var current = 0

    /// Every occurrence of the query in `lines`, any case.
    mutating func search(_ lines: [AttributedString]) {
        matches = []
        current = 0
        guard !query.isEmpty else { return }
        for (index, line) in lines.enumerated() {
            let text = String(line.characters)
            var from = text.startIndex, occurrence = 0
            while let found = text.range(of: query, options: [.caseInsensitive], range: from..<text.endIndex) {
                matches.append(Match(line: index, occurrence: occurrence))
                occurrence += 1
                from = found.upperBound
                if found.isEmpty { break }
            }
        }
    }

    mutating func next() { if !matches.isEmpty { current = (current + 1) % matches.count } }
    mutating func previous() { if !matches.isEmpty { current = (current - 1 + matches.count) % matches.count } }

    var currentMatch: Match? { matches.indices.contains(current) ? matches[current] : nil }

    /// "3 of 12", "No matches".
    var position: String { matches.isEmpty ? (query.isEmpty ? "" : "No matches") : "\(current + 1) of \(matches.count)" }

    /// `line` with its occurrences marked: the current one strong, the others faint.
    func highlighted(_ line: AttributedString, index: Int) -> AttributedString {
        guard !query.isEmpty, matches.contains(where: { $0.line == index }) else { return line }
        var line = line
        var from = line.startIndex, occurrence = 0
        while from < line.endIndex, let found = line[from...].range(of: query, options: [.caseInsensitive]) {
            let strong = currentMatch == Match(line: index, occurrence: occurrence)
            line[found].backgroundColor = strong ? Color.findCurrent : Color.findOther
            occurrence += 1
            from = found.upperBound
            if found.isEmpty { break }
        }
        return line
    }
}

extension Color {
    /// Find in file's marks: the current occurrence in the app tint, the others faint (both legible in either scheme).
    static let findCurrent = Color.dispatchPink.opacity(0.45)
    static let findOther = Color.caution.opacity(0.28)
}

/// Image files without decoding what they cannot hold: the pixel size from the header (`CGImageSource` properties),
/// a smaller copy (`CGImageSourceCreateThumbnailAtIndex`) past `pixelCap`, nothing past `dimensionLimit`.
enum FilesImage {
    static let pixelCap = 40_000_000
    static let dimensionLimit = 32_768
    /// The smaller copy's longest side.
    static let thumbnailEdge = 4_096

    enum Shown: Equatable {
        /// The bytes to draw: the file's own, or a smaller copy's (`smaller`).
        case image(Data, smaller: Bool)
        /// Its canvas is too large to read safely.
        case tooLarge
    }

    /// The pixel size the header names; nil when `data` holds no image ImageIO reads.
    nonisolated static func pixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        return CGSize(width: width, height: height)
    }

    /// What to draw for `data`: nil when it is no image.
    nonisolated static func shown(_ data: Data, cap: Int = pixelCap, edge: Int = thumbnailEdge) -> Shown? {
        guard let size = pixelSize(data), size.width > 0, size.height > 0 else { return nil }
        guard Int(size.width) <= dimensionLimit, Int(size.height) <= dimensionLimit else { return .tooLarge }
        guard Int(size.width) * Int(size.height) > cap else { return .image(data, smaller: false) }
        guard let image = thumbnail(data, edge: edge),
              let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else { return .tooLarge }
        return .image(jpeg, smaller: true)
    }

    /// A copy at most `edge` pixels on its longest side, its orientation applied.
    nonisolated static func thumbnail(_ data: Data, edge: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: edge]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
