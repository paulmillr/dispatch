import Foundation
import OSLog
import Observation

/// A bounded flight recorder for missing transcript rows. No conversation text,
/// paths, host names, or original row IDs enter the record.
@MainActor @Observable
final class ChatViewportTrace {
    enum Event: String, Codable, Sendable {
        case attached, connected, disconnected, geometry, scrolled, userScroll
        case transcript, history, followRequested, correction, restoreRequested
        case watchdog, blank, recovered, redraw, recoveryRequested, rebuildRequested
        /// Checks shortly after a scroll view attaches, before the watchdog's
        /// first interval, and the first visible content after a blank one.
        case mountCheck, mountBlank, mountRecovered
    }
    struct Transcript: Codable, Sendable {
        let revision: Int
        let historyRevision: Int
        let rows: Int
        let turns: Int
        let busy: Bool
        let atBottom: Bool
        let following: Bool
        let loadingHistory: Bool
        let loadingEarlier: Bool
    }
    struct Rect: Codable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        init(_ rect: CGRect) {
            x = rect.minX; y = rect.minY; width = rect.width; height = rect.height
        }
    }
    struct Anchor: Codable, Sendable {
        let token: String
        let offset: Double
    }
    struct Row: Codable, Sendable {
        let token: String
        let frame: Rect
        let alpha: Double
        var hidden = false
        /// Position in the transcript and a content-free row category.
        var index: Int?
        var kind: String?
    }
    struct RowInfo: Sendable {
        let index: Int
        let kind: String
    }
    /// SwiftUI's own scroll geometry (macOS 15+), whole points. Comparing it with
    /// the native clip shows whether both agree on the visible region.
    struct SwiftUIScroll: Codable, Equatable, Sendable {
        let offsetY: Double
        let contentHeight: Double
        let containerHeight: Double
        let visibleY: Double
        let visibleHeight: Double
    }
    struct Markers: Codable, Sendable {
        var registered = 0
        var mounted = 0
        var visible = 0
        var hidden = 0
        var transparent = 0
        var empty = 0
        var rows: [Row] = []
    }
    struct Correction: Codable, Sendable {
        let from: Double
        let to: Double
    }
    struct Sample: Codable, Sendable {
        var version = 3
        let date: Date
        let elapsed: Double
        let viewport: UUID
        let event: Event
        let events: [String: Int]
        let transcript: Transcript?
        let clip: Rect?
        let document: Rect?
        let documentNeedsLayout: Bool
        let documentNeedsDisplay: Bool
        let clipNeedsDisplay: Bool
        let windowVisible: Bool
        let windowOccluded: Bool
        let scrollHidden: Bool
        let markers: Markers
        let saved: Anchor?
        let pending: Anchor?
        let correction: Correction?
        let interaction: Int
        let adjusting: Bool
        let adjustmentScheduled: Bool
        let tracking: Bool
        let liveScrolling: Bool
        let realizationAttempts: Int
        let emptyChecks: Int
        let blankDuration: Double?
        let geometryAge: Double
        let wheelAge: Double?
        var sinceAttach: Double? = nil
        var swiftUI: SwiftUIScroll? = nil
    }

    static let shared = ChatViewportTrace(writer: ChatViewportTraceWriter(directory:
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Dispatch/Diagnostics")))
    private static let samplingAllowed: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["DISPATCH_CHAT_VIEWPORT_TRACE"] != "0" && environment["DISPATCH_TESTING"] != "1"
    }()
    static var enabled: Bool { shared.isEnabled && samplingAllowed }
    private static let log = Logger(subsystem: "com.dispatch.app", category: "ChatViewport")
    let directory: URL
    private(set) var isEnabled = false
    private(set) var error: String?
    @ObservationIgnored
    private let writer: ChatViewportTraceWriter
    @ObservationIgnored
    private var pending: [Sample] = []
    @ObservationIgnored
    private var flushTask: Task<Void, Never>?
    @ObservationIgnored
    private(set) var dropped = 0
    @ObservationIgnored private var generation = UUID()
    /// The launch applies the saved setting and keeps logs across restarts;
    /// any later opt-in starts a new log rather than appending to an old one.
    @ObservationIgnored private var configured = false
    private let capacity: Int

    init(writer: ChatViewportTraceWriter, capacity: Int = 256) {
        self.writer = writer; directory = writer.directory; self.capacity = max(1, capacity)
    }

    func setEnabled(_ enabled: Bool) {
        let restart = configured
        configured = true
        guard enabled != isEnabled else { return }
        isEnabled = enabled; error = nil
        generation = UUID()
        flushTask?.cancel(); flushTask = nil
        pending.removeAll(); dropped = 0
        if enabled { scheduleFlush(prepare: true, clearing: restart) }
    }

    func record(_ sample: Sample) {
        guard isEnabled else { return }
        if pending.count == capacity { pending.removeFirst(); dropped += 1 }
        pending.append(sample)
        scheduleFlush()
    }

    private func scheduleFlush(prepare: Bool = false, clearing: Bool = false) {
        guard flushTask == nil else { return }
        let generation = generation
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        flushTask = Task { [weak self] in
            // One bounded batch in flight, even if the disk stalls.
            if prepare, let self {
                do { try await writer.prepare(version: version, build: build, clearing: clearing) }
                catch {
                    guard self.generation == generation else { return }
                    self.writeFailed()
                }
            }
            while let self, self.isEnabled, self.generation == generation, !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard self.isEnabled, self.generation == generation else { return }
                let batch = self.pending
                self.pending.removeAll(keepingCapacity: true)
                let dropped = self.dropped; self.dropped = 0
                if batch.isEmpty && dropped == 0 { self.flushTask = nil; return }
                do {
                    try await self.writer.append(batch, dropped: dropped)
                    guard self.generation == generation else { return }
                    self.error = nil
                } catch {
                    guard self.generation == generation else { return }
                    self.writeFailed()
                }
                if self.pending.isEmpty { self.flushTask = nil; return }
            }
        }
    }

    private func writeFailed() {
        // Error descriptions can contain user paths. Keep both UI and unified
        // logs fixed, and never copy raw system logs into the diagnostics folder.
        error = "Could not write diagnostics. Check access to the log folder."
        Self.log.error("Could not write diagnostics")
    }
}

/// Encoding, rotation and disk I/O never run on the main actor. Two 4 MiB files
/// survive app restarts, retaining both automatic recovery and paint-only gaps.
actor ChatViewportTraceWriter {
    nonisolated let directory: URL
    let maximumBytes: Int
    private let encoder: JSONEncoder
    private struct Dropped: Encodable {
        let event = "dropped"
        let date = Date()
        let count: Int
    }

    init(directory: URL, maximumBytes: Int = 4 * 1024 * 1024) {
        self.directory = directory; self.maximumBytes = max(1, maximumBytes)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    func prepare(version: String, build: String, clearing: Bool = false) throws {
        try Task.checkCancellation()
        struct Manifest: Encodable {
            let format = 2
            let started = Date()
            let applicationVersion: String
            let applicationBuild: String
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        if clearing {
            for name in ["chat-viewport.jsonl", "chat-viewport.previous.jsonl"] {
                let log = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: log.path) { try FileManager.default.removeItem(at: log) }
            }
        }
        let file = directory.appendingPathComponent("diagnostics.json")
        let data = try encoder.encode(Manifest(applicationVersion: version, applicationBuild: build))
        try Task.checkCancellation()
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func append(_ samples: [ChatViewportTrace.Sample], dropped: Int = 0) throws {
        try Task.checkCancellation()
        guard !samples.isEmpty || dropped > 0 else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let current = directory.appendingPathComponent("chat-viewport.jsonl")
        let previous = directory.appendingPathComponent("chat-viewport.previous.jsonl")
        var records = try samples.map { try encoder.encode($0) }
        if dropped > 0 { records.insert(try encoder.encode(Dropped(count: dropped)), at: 0) }
        var size = (try? manager.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
        for var data in records {
            try Task.checkCancellation()
            data.append(0x0a)
            guard data.count <= maximumBytes else { continue }
            if size + data.count > maximumBytes {
                if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                if manager.fileExists(atPath: current.path) { try manager.moveItem(at: current, to: previous) }
                size = 0
            }
            if !manager.fileExists(atPath: current.path) {
                guard manager.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: current)
            do {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
            size += data.count
        }
    }
}
