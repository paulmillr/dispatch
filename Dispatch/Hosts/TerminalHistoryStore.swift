import Foundation

/// Plain local and SSH tabs' output from the last proper quit, for the next launch only. It is written
/// once as the app quits (never mid-session, so a crash or kill leaves nothing new), taken off
/// the disk as the next launch starts whether or not it is used, excluded from backups, and
/// ignored after a week.
struct TerminalHistoryStore {
    let url: URL

    /// The file: this header as one JSON line, then each tab's UTF-8 text in its order (raw, so
    /// large output is neither escaped nor parsed).
    struct Header: Codable {
        struct Tab: Codable { var id: UUID; var bytes: Int }
        var version = 1
        var saved: Date
        var tabs: [Tab]
    }

    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// Per tab, a terminal's whole scrollback: its text is always smaller, so nothing a tab
    /// still shows is cut.
    static let tabLimit = TerminalRuntime.scrollbackLimit
    /// In total, 1/32 of this Mac's memory (256 MB with 8 GB), held while quitting and until
    /// each restored tab is shown.
    static let totalLimit = Int(clamping: ProcessInfo.processInfo.physicalMemory / 32)

    /// Replaces the saved output; nothing to save removes it.
    func save(_ tabs: [UUID: String]) throws {
        guard !tabs.isEmpty else { return try remove() }
        let entries = tabs.map { (id: $0.key, text: $0.value) }
        let header = Header(saved: Date(), tabs: entries.map { .init(id: $0.id, bytes: $0.text.utf8.count) })
        try PrivateFile.write(to: url, excludedFromBackup: true) { file in
            try file.write(contentsOf: JSONEncoder().encode(header) + [0x0A])
            for entry in entries { try file.write(contentsOf: Data(entry.text.utf8)) }
        }
    }

    /// The saved output, removed from the disk first: empty when missing, unreadable, too large,
    /// too old or from another version.
    func take() -> [UUID: String] {
        let data = try? Data(contentsOf: url, options: .alwaysMapped)
        try? remove()
        guard let data, data.count <= Self.totalLimit + 1024 * 1024, let newline = data.firstIndex(of: 0x0A),
              let header = try? JSONDecoder().decode(Header.self, from: data[..<newline]), header.version == 1,
              abs(header.saved.timeIntervalSinceNow) <= Self.maxAge,
              header.tabs.allSatisfy({ (0...data.count).contains($0.bytes) }), header.tabs.reduce(0, { $0 + $1.bytes }) == data.count - newline - 1 else { return [:] }
        var tabs: [UUID: String] = [:], offset = newline + 1
        for tab in header.tabs {
            let text = Self.tail(String(decoding: data[offset..<offset + tab.bytes], as: UTF8.self))
            offset += tab.bytes
            if !text.isEmpty { tabs[tab.id] = text }
        }
        return tabs
    }

    func remove() throws {
        PrivateFile.removeStale(for: url)
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile { }
    }

    /// The end of `text` within `limit` UTF-8 bytes, starting at a line.
    static func tail(_ text: String, limit: Int = tabLimit) -> String {
        let utf8 = text.utf8
        guard utf8.count > limit else { return text }
        let start = utf8.index(utf8.endIndex, offsetBy: -limit)
        guard let line = utf8[start...].firstIndex(of: 0x0A) else { return "" }
        return String(text[utf8.index(after: line)...])
    }

    /// Saved text as terminal output: faint lines, then a reset on a new line for the shell.
    /// C0 and C1 controls are dropped, so a saved file can only print text.
    static func replay(_ text: String) -> [UInt8] {
        var out = Array("\u{1B}[0;2m".utf8)
        out.reserveCapacity(text.utf8.count + text.utf8.count / 16 + 16)
        var lead = false   // 0xC2: C1 controls are U+0080...U+009F, C2 80...C2 9F
        for byte in text.utf8 {
            if lead {
                lead = false
                if byte < 0xA0 { continue }
                out.append(0xC2)
            }
            switch byte {
            case 0x0A: out += [0x0D, 0x0A]
            case 0..<0x20, 0x7F: continue
            case 0xC2: lead = true
            default: out.append(byte)
            }
        }
        return out + Array("\r\n\u{1B}[0m".utf8)
    }
}

/// Owner-only files replaced whole: created 0600 under a temporary name beside the target,
/// synced, then renamed over it, so no reader or crash sees a partial or more readable file.
enum PrivateFile {
    static func write(_ data: Data, to url: URL, excludedFromBackup: Bool = false) throws {
        try write(to: url, excludedFromBackup: excludedFromBackup) { try $0.write(contentsOf: data) }
    }

    /// `body` writes the contents in parts.
    static func write(to url: URL, excludedFromBackup: Bool = false, _ body: (FileHandle) throws -> Void) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var temporary = directory.appendingPathComponent(prefix(url) + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try body(handle)
            try handle.synchronize()
            try handle.close()
            if excludedFromBackup {
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try temporary.setResourceValues(values)
            }
            guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            unlink(temporary.path)
            throw error
        }
    }

    /// Temporary files a killed write left behind.
    static func removeStale(for url: URL) {
        let directory = url.deletingLastPathComponent(), prefix = prefix(url)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix(prefix) {
            unlink(directory.appendingPathComponent(name).path)
        }
    }

    private static func prefix(_ url: URL) -> String { "." + url.lastPathComponent + ".tmp-" }
}
