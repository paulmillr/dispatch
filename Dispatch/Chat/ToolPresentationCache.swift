import Foundation

/// Bounded, memory-only formatting cache. Large payloads are parsed away from
/// AppKit; scrolling revisits already formatted rows without parsing them again.
actor ToolPresentationCache {
    static let shared = ToolPresentationCache()
    private final class Entry: NSObject {
        let value: ToolPresentation
        init(_ value: ToolPresentation) { self.value = value }
    }
    // NSCache synchronizes its own reads/writes; entries contain immutable
    // Sendable presentations. A warm view can read without suspending for the
    // formatting actor and briefly replacing expanded output with a header.
    private final class Storage: @unchecked Sendable {
        let entries = NSCache<NSUUID, Entry>()
        init() {
            entries.countLimit = 512
            entries.totalCostLimit = 24 * 1024 * 1024
        }
    }
    private nonisolated let storage = Storage()
    private(set) var builds = 0
    nonisolated func cached(for item: ChatItem) -> ToolPresentation? {
        storage.entries.object(forKey: item.presentationID as NSUUID)?.value
    }
    nonisolated func removeAll() { storage.entries.removeAllObjects() }
    func presentation(for item: ChatItem) -> ToolPresentation {
        let key = item.presentationID as NSUUID
        if let value = cached(for: item) { return value }
        let value = ToolPresentation(item)
        builds += 1
        storage.entries.setObject(Entry(value), forKey: key, cost: item.text.utf8.count + item.output.utf8.count + value.output.utf8.count)
        return value
    }
}

/// Small geometry records belong to the retained transcript, independently of
/// the evictable payload cache. One measurement per tool revision is sufficient
/// to avoid collapsing a previously expanded row while cold formatting loads.
@MainActor
final class ChatToolLayoutCache {
    private struct Measurement {
        let size: CGSize
        let typography: ChatTypography
    }
    private var measurements: [UUID: Measurement] = [:]
    var count: Int { measurements.count }
    func height(for revision: UUID, width: CGFloat, typography: ChatTypography) -> CGFloat? {
        guard let value = measurements[revision], value.typography == typography,
              abs(value.size.width - width) < 0.5 else { return nil }
        return value.size.height
    }
    func remember(_ size: CGSize, for revision: UUID, typography: ChatTypography) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        measurements[revision] = Measurement(size: size, typography: typography)
    }
    func retain(_ revisions: Set<UUID>) {
        measurements = measurements.filter { revisions.contains($0.key) }
    }
    func removeAll() { measurements.removeAll() }
}
