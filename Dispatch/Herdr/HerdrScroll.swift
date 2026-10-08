import Foundation

/// Turns wheel deltas into whole lines, keeping the remainder between events.
struct HerdrScrollAccumulator {
    private var remainder: Double = 0
    mutating func consume(delta: Double, precise: Bool, lineHeight: Double, began: Bool = false) -> Int {
        guard delta.isFinite, lineHeight.isFinite else { return 0 }
        if began || delta * remainder < 0 { remainder = 0 }
        remainder += precise ? delta / max(1, lineHeight) : delta * 3
        let lines = Int(min(65535, max(-65535, remainder.rounded(.towardZero))))
        remainder -= Double(lines)
        return lines
    }
}
