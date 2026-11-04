import Foundation

/// A binary file as the hex view reads it: the head the loader already has, then 64 KB pages read as rows come into
/// view (at most `concurrentReads` at once, nearest first, the last `cachedPages` kept), each at the revision the
/// preview was classified at. A page read that finds the file changed sets `changed` and the preview reloads, so
/// rows from two versions never show together. It also holds the selection, the Strings scan and copying.
@MainActor @Observable final class FileHexDocument {
    static let pageSize: UInt64 = 65_536
    static let cachedPages = 32
    static let concurrentReads = 2
    /// Copy reads at most this much: past it, the bar says to select less.
    static let copyLimit: UInt64 = 1_048_576
    /// Strings looks at the file's first 16 MB, read 1 MB at a time.
    static let stringsLimit: UInt64 = 16 * 1_048_576
    static let stringsChunk: UInt64 = 1_048_576
    /// `strings`' default: runs of at least 4 printable ASCII characters (space and tab included).
    nonisolated static let stringsMinimum: UInt64 = 4
    static let stringsCount = 100_000
    /// A string longer than this shows its start and " …"; selecting it still selects all of it.
    nonisolated static let stringShown = 200

    enum Mode { case hex, strings }

    enum CopyFormat: CaseIterable {
        case hex, cArray, base64, text

        var title: String {
            switch self {
            case .hex: "Copy as Hex"
            case .cArray: "Copy as C Array"
            case .base64: "Copy as Base64"
            case .text: "Copy as Text"
            }
        }
    }

    /// One of the inspector's readings: "32-bit", "1,179,403,647".
    struct Value: Identifiable, Equatable, Sendable {
        let label: String
        let value: String
        var id: String { label }
    }

    struct Found: Identifiable, Equatable, Sendable {
        let offset: UInt64
        let length: UInt64
        /// The run's first `stringShown` characters, with " …" when it is longer.
        let text: String
        var id: UInt64 { offset }
    }

    /// A run of printable bytes a chunk ended inside: the next chunk continues it.
    struct Run: Equatable, Sendable {
        var offset: UInt64
        var length: UInt64
        var prefix: [UInt8]
    }

    let path: String
    let size: UInt64
    let revision: FileRevision?
    @ObservationIgnored let head: Data
    @ObservationIgnored private let source: (any FilesSource)?

    /// Bumped when a page arrives: the inspector reads its bytes again (the grid is told through `redraw`).
    private(set) var loaded = 0
    /// A read failed for a reason other than the file changing; the bar says so.
    private(set) var failure: String?
    /// The bar's passing message (copy refused or done).
    var notice: String?
    /// A read found the file changed since the preview was classified: the preview reads it again.
    private(set) var changed = false
    var mode = Mode.hex {
        didSet { if mode == .strings { scanStrings() } }
    }

    /// Where a selection started (a click) and where it ends now (a drag, shift-click or shift-arrow).
    private(set) var anchor: UInt64?
    private(set) var caret: UInt64?

    private(set) var strings: [Found] = []
    /// How far Strings has read.
    private(set) var scanned: UInt64 = 0
    private(set) var scanning = false

    /// Set by the grid from its width (16, or 8 in a narrow pane) and height.
    @ObservationIgnored var bytesPerRow: UInt64 = 16
    /// The grid's scroll position in points, kept here so Strings and back returns to the same rows.
    @ObservationIgnored var scrollTop: Double = 0
    @ObservationIgnored var visibleRows: UInt64 = 1
    /// A byte the grid should scroll to: `jump` (Go to, a string) sets it a third down the view; a key just brings it
    /// into view. The grid clears it.
    @ObservationIgnored var reveal: (offset: UInt64, jump: Bool)?
    /// Tells the grid to draw again: a page arrived, the selection moved.
    @ObservationIgnored var redraw: (() -> Void)?

    @ObservationIgnored private var pages: [UInt64: Data] = [:]
    /// Pages by use, oldest first: past `cachedPages` the oldest goes.
    @ObservationIgnored private var recent: [UInt64] = []
    @ObservationIgnored private var wanted: [UInt64] = []
    @ObservationIgnored private var reads: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var scan: Task<Void, Never>?
    @ObservationIgnored private var closed = false

    init(path: String, size: UInt64, revision: FileRevision?, head: Data, source: (any FilesSource)?) {
        self.path = path
        self.size = size
        self.revision = revision
        self.head = head
        self.source = source
    }

    var selection: ClosedRange<UInt64>? {
        guard let anchor, let caret else { return nil }
        return min(anchor, caret)...max(anchor, caret)
    }

    /// Stops every read; the document is not used again.
    func close() {
        closed = true
        reads.values.forEach { $0.cancel() }
        reads = [:]
        wanted = []
        scan?.cancel()
        scan = nil
    }

    // MARK: Bytes

    func byte(at offset: UInt64) -> UInt8? {
        guard offset < size else { return nil }
        if offset < UInt64(head.count) { return head[head.startIndex + Int(offset)] }
        let page = offset / Self.pageSize
        guard let data = pages[page] else { return nil }
        let index = Int(offset - page * Self.pageSize)
        return index < data.count ? data[data.startIndex + index] : nil
    }

    /// The bytes at `offset` up to `count` of them, stopping at the first one not read yet.
    func bytes(at offset: UInt64, count: Int) -> [UInt8] {
        var result: [UInt8] = []
        var index = offset
        while result.count < count, let byte = byte(at: index) {
            result.append(byte)
            index += 1
        }
        return result
    }

    /// The bytes the grid shows (and a screen past them): their pages are read, in this order; pages wanted before
    /// and not started are dropped, so a fast scroll through a large file reads only where it stops.
    func want(_ range: Range<UInt64>) {
        guard !closed, !changed, size > 0, range.lowerBound < size else { return }
        let first = range.lowerBound / Self.pageSize
        let last = (min(range.upperBound, size) - 1) / Self.pageSize
        guard first <= last else { return }
        wanted = []
        for page in first...last {
            // Rows the head already holds need no page.
            let needed = min(range.upperBound, (page + 1) * Self.pageSize, size)
            if pages[page] != nil { touch(page) } else if needed > UInt64(head.count) { wanted.append(page) }
        }
        pump()
    }

    /// Page reads running now (at most `concurrentReads`).
    var readsInFlight: Int { reads.count }

    private func touch(_ page: UInt64) {
        recent.removeAll { $0 == page }
        recent.append(page)
    }

    private func pump() {
        while reads.count < Self.concurrentReads, let page = wanted.first(where: { reads[$0] == nil && pages[$0] == nil }) {
            wanted.removeAll { $0 == page }
            start(page)
        }
    }

    private func start(_ page: UInt64) {
        guard let source else {
            failure = FilesSourceError.offline(path).message
            return
        }
        let offset = page * Self.pageSize
        let length = min(Self.pageSize, size - offset)
        let path = path, revision = revision
        reads[page] = Task { [weak self] in
            let result: Result<Data, any Error>
            do {
                let read = try await source.read(path, offset: offset, length: length, revision: revision)
                guard revision == nil || read.revision == revision, UInt64(read.data.count) == length else {
                    throw FilesSourceError.changed(path)
                }
                result = .success(read.data)
            } catch {
                result = .failure(error)
            }
            self?.finish(page, result)
        }
    }

    private func finish(_ page: UInt64, _ result: Result<Data, any Error>) {
        reads[page] = nil
        guard !closed else { return }
        switch result {
        case .success(let data):
            pages[page] = data
            touch(page)
            while recent.count > Self.cachedPages { pages[recent.removeFirst()] = nil }
            loaded += 1
            redraw?()
        case .failure(let error):
            if handle(error) { return }
        }
        pump()
    }

    /// Records a failed read; true when the document stops (the file changed).
    @discardableResult private func handle(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if case FilesSourceError.changed = error {
            changed = true
            close()
            return true
        }
        if case FilesSourceError.cancelled = error { return false }
        failure = (error as? FilesSourceError)?.message ?? error.localizedDescription
        return false
    }

    // MARK: Selection

    /// A click at `offset`; with `extend` (shift) the selection runs from where it started.
    func click(_ offset: UInt64, extend: Bool) {
        let offset = clamped(offset)
        if extend, anchor != nil { caret = offset } else { anchor = offset; caret = offset }
        redraw?()
    }

    /// A drag from the click to `offset`.
    func drag(to offset: UInt64) {
        guard anchor != nil else { return click(offset, extend: false) }
        caret = clamped(offset)
        redraw?()
    }

    /// The caret moved by `delta` bytes (arrows, pages), or to `to` (Home, End); `extend` keeps the anchor.
    func move(by delta: Int64 = 0, to target: UInt64? = nil, extend: Bool) {
        guard size > 0 else { return }
        let from = caret ?? 0
        let next: UInt64 = if let target { clamped(target) }
            else if delta < 0 { from >= delta.magnitude ? from - delta.magnitude : 0 }
            else { clamped(from &+ UInt64(delta)) }
        if extend { if anchor == nil { anchor = from } } else { anchor = next }
        caret = next
        reveal = (next, false)
        redraw?()
    }

    /// Selects `range` and scrolls to its start (Go to, a string).
    func select(_ range: Range<UInt64>) {
        guard size > 0, range.lowerBound < size else { return }
        anchor = range.lowerBound
        caret = clamped(max(range.lowerBound, range.upperBound - 1))
        reveal = (range.lowerBound, true)
        redraw?()
    }

    func selectAll() {
        guard size > 0 else { return }
        anchor = 0
        caret = size - 1
        redraw?()
    }

    private func clamped(_ offset: UInt64) -> UInt64 { min(offset, size == 0 ? 0 : size - 1) }

    /// What Go to takes: "0x1a0", "1a0" (hex digits with a letter), "416" (decimal), "-16" (from the end), "end".
    static func offset(_ text: String, size: UInt64) -> UInt64? {
        var text = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: "")
        guard !text.isEmpty, size > 0 else { return nil }
        if text == "end" { return size - 1 }
        let fromEnd = text.hasPrefix("-")
        if fromEnd { text.removeFirst() }
        let value: UInt64?
        if text.hasPrefix("0x") { value = UInt64(text.dropFirst(2), radix: 16) }
        else if text.hasPrefix("$") { value = UInt64(text.dropFirst(), radix: 16) }
        else if text.contains(where: { ("a"..."f").contains($0) }) { value = UInt64(text, radix: 16) }
        else { value = UInt64(text) }
        guard let value else { return nil }
        if fromEnd { return value == 0 || value > size ? nil : size - value }
        return value < size ? value : nil
    }

    // MARK: Copy

    /// The selection as `format`, read whole (at most `copyLimit`); nil, with `notice` saying why, when it cannot be.
    func copyText(_ format: CopyFormat) async -> String? {
        guard let selection else { return nil }
        let length = selection.upperBound - selection.lowerBound + 1
        guard length <= Self.copyLimit else {
            notice = "Copy takes at most \(FilesFormatting.size(Self.copyLimit)): select less"
            return nil
        }
        do {
            let data = try await read(selection.lowerBound, length: length)
            guard let text = Self.render(data, as: format) else {
                notice = "The selection is not UTF-8 text"
                return nil
            }
            notice = "Copied \(FilesFormatting.count(length)) \(length == 1 ? "byte" : "bytes")"
            return text
        } catch {
            handle(error)
            return nil
        }
    }

    static func render(_ data: Data, as format: CopyFormat) -> String? {
        let digits = Array("0123456789abcdef")
        let hex = { (byte: UInt8) in String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]]) }
        switch format {
        case .hex:
            return data.map(hex).joined(separator: " ")
        case .cArray:
            let rows = stride(from: 0, to: data.count, by: 12).map { start in
                "    " + data[(data.startIndex + start)..<(data.startIndex + min(start + 12, data.count))]
                    .map { "0x" + hex($0) }.joined(separator: ", ")
            }
            return "unsigned char bytes[\(data.count)] = {\n" + rows.joined(separator: ",\n") + "\n};"
        case .base64:
            return data.base64EncodedString()
        case .text:
            return FilePreviewContent.text(data)
        }
    }

    /// `length` bytes at `offset`: sliced from the head or one page already read when they hold it all, else in one
    /// read at the revision.
    private func read(_ offset: UInt64, length: UInt64) async throws -> Data {
        let end = offset + length
        if end <= UInt64(head.count) {
            return head.subdata(in: (head.startIndex + Int(offset))..<(head.startIndex + Int(end)))
        }
        let page = offset / Self.pageSize
        if let data = pages[page], end <= page * Self.pageSize + UInt64(data.count) {
            let start = Int(offset - page * Self.pageSize)
            return data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + Int(length)))
        }
        guard let source else { throw FilesSourceError.offline(path) }
        let read = try await source.read(path, offset: offset, length: length, revision: revision)
        guard revision == nil || read.revision == revision, UInt64(read.data.count) == length else {
            throw FilesSourceError.changed(path)
        }
        return read.data
    }

    // MARK: Strings

    /// Reads the first `stringsLimit` bytes a chunk at a time and lists their strings as they are found. Once.
    private func scanStrings() {
        guard scan == nil, scanned == 0, !closed, !changed else { return }
        scanning = true
        scan = Task { [weak self] in await self?.runScan() }
    }

    private func runScan() async {
        defer { scanning = false }
        let end = min(size, Self.stringsLimit)
        var run: Run?
        var offset: UInt64 = 0
        while offset < end, !Task.isCancelled, !closed {
            let length = min(Self.stringsChunk, end - offset)
            do {
                let data = try await read(offset, length: length)
                guard !Task.isCancelled, !closed else { return }
                let (found, next) = await Self.strings(in: data, at: offset, continuing: run, last: offset + length == end)
                guard !Task.isCancelled, !closed else { return }
                run = next
                strings.append(contentsOf: found.prefix(Self.stringsCount - strings.count))
                scanned = offset + length
                if strings.count >= Self.stringsCount { return }
            } catch {
                handle(error)
                return
            }
            offset += length
        }
    }

    /// The strings in `data` (at `base` in the file), continuing `run` from the chunk before. A run still open at the
    /// end is returned to continue, unless this is the `last` chunk. Off the main actor: 16 MB is a lot of bytes.
    @concurrent nonisolated static func strings(in data: Data, at base: UInt64, continuing run: Run?,
                                                last: Bool) async -> (found: [Found], run: Run?) {
        scanStrings(data, at: base, continuing: run, last: last)
    }

    nonisolated static func scanStrings(_ data: Data, at base: UInt64, continuing run: Run?,
                                        last: Bool) -> (found: [Found], run: Run?) {
        var found: [Found] = []
        var run = run
        func close() {
            if let current = run, current.length >= stringsMinimum {
                var text = String(decoding: current.prefix, as: UTF8.self)
                if current.length > UInt64(stringShown) { text += " …" }
                found.append(Found(offset: current.offset, length: current.length, text: text))
            }
            run = nil
        }
        var offset = base
        for byte in data {
            if (0x20...0x7E).contains(byte) || byte == 0x09 {
                if run == nil { run = Run(offset: offset, length: 0, prefix: []) }
                run!.length += 1
                if run!.prefix.count < stringShown { run!.prefix.append(byte == 0x09 ? 0x20 : byte) }
            } else {
                close()
            }
            offset += 1
        }
        if last { close() }
        return (found, run)
    }

    // MARK: Inspector

    /// The selection's first bytes read as numbers, in either byte order: "8-bit 255 (−1)", "32-bit 1,179,403,647",
    /// "float 1". A width the bytes do not reach (the end of the file, a page not read yet) reads "—": the inspector
    /// keeps its rows, so its height never changes under the hex.
    nonisolated static func values(_ bytes: [UInt8], littleEndian: Bool) -> [Value] {
        func integer(_ width: Int) -> UInt64? {
            guard bytes.count >= width else { return nil }
            let slice = bytes.prefix(width)
            return (littleEndian ? Array(slice.reversed()) : Array(slice)).reduce(0) { $0 << 8 | UInt64($1) }
        }
        func pair(_ unsigned: UInt64, width: Int) -> String {
            let shift = UInt64(64 - width * 8)
            let signed = Int64(bitPattern: unsigned << shift) >> Int64(shift)
            let text = FilesFormatting.count(unsigned)
            return signed < 0 ? "\(text) (\(FilesFormatting.count(signed).replacingOccurrences(of: "-", with: "−")))" : text
        }
        var result: [Value] = []
        let none = "—"
        for (label, width) in [("8-bit", 1), ("16-bit", 2), ("32-bit", 4), ("64-bit", 8)] {
            result.append(Value(label: label, value: integer(width).map { pair($0, width: width) } ?? none))
        }
        result.append(Value(label: "float", value: integer(4).map { number(Double(Float(bitPattern: UInt32($0)))) } ?? none))
        result.append(Value(label: "double", value: integer(8).map { number(Double(bitPattern: $0)) } ?? none))
        let bits = bytes.first.map { first -> String in
            let digits = String(first, radix: 2)
            let padded = String(repeating: "0", count: 8 - digits.count) + digits
            return String(padded.prefix(4)) + " " + String(padded.suffix(4))
        }
        result.append(Value(label: "bits", value: bits ?? none))
        return result
    }

    private nonisolated static func number(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "−∞" : "∞" }
        let text = abs(value) >= 1e15 || (value != 0 && abs(value) < 1e-6)
            ? String(format: "%.6g", value) : String(format: "%.6f", value)
                .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        return text.replacingOccurrences(of: "-", with: "−")
    }

    /// The selection as UTF-8 text when it is that (at most 64 bytes of it), else nil.
    nonisolated static func utf8(_ bytes: [UInt8]) -> String? {
        guard !bytes.isEmpty, bytes.count <= 64 else { return nil }
        return FilePreviewContent.text(Data(bytes))
    }
}
