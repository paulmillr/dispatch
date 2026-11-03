import Foundation

/// Fixed wall-clock buckets, oldest first. A bucket keeps its own peak; only empty buckets can take the next
/// sample's interval average. Callers choose how long a sampling gap may be held (Mac 20 s, phone 35 s).
enum StatisticsHistory {
    static func bars<Point>(_ history: [Point], at now: Date, window: TimeInterval, count: Int,
                            hold: TimeInterval, date: (Point) -> Date, value: (Point) -> Double?) -> [Double?] {
        guard count > 0 else { return [] }
        let span = window / Double(count)
        func slot(_ date: Date) -> Int { Int((date.timeIntervalSinceReferenceDate / span).rounded(.down)) }
        let first = slot(now) - (count - 1)
        var bars = [Double?](repeating: nil, count: count), held = bars
        var previous: Date?
        for point in history where date(point) <= now {
            defer { previous = date(point) }
            guard let raw = value(point), raw.isFinite else { continue }
            let clamped = min(100, max(0, raw)), own = slot(date(point)) - first
            if bars.indices.contains(own) { bars[own] = max(bars[own] ?? 0, clamped) }
            guard let previous, date(point) > previous, date(point).timeIntervalSince(previous) <= hold else { continue }
            let gap = max(0, slot(previous) + 1 - first), end = min(count, own)
            if gap < end { for index in gap..<end { held[index] = max(held[index] ?? 0, clamped) } }
        }
        return zip(bars, held).map { $0 ?? $1 }
    }
}
