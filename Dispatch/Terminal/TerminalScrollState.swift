import Foundation

/// Row coordinates start at the oldest retained line, independent of the backend.
struct TerminalScrollState: Equatable, Sendable {
    let total: UInt64
    let offset: UInt64
    let visible: UInt64

    init(total: UInt64 = 0, offset: UInt64 = 0, visible: UInt64 = 0) {
        self.total = total
        self.visible = min(visible, total)
        self.offset = min(offset, total - self.visible)
    }

    var maximum: UInt64 { total - visible }
    var canScroll: Bool { visible > 0 && maximum > 0 }
    var fraction: Double { maximum > 0 ? Double(offset) / Double(maximum) : 1 }
    var proportion: Double { total > 0 ? Double(visible) / Double(total) : 1 }

    func row(at fraction: Double) -> UInt64 {
        guard fraction.isFinite else { return offset }
        if fraction <= 0 { return 0 }
        if fraction >= 1 { return maximum }
        let value = (fraction * Double(maximum)).rounded(.down)
        // Double(UInt64.max) rounds up to 2^64; do not convert that back to UInt64.
        return value >= Double(maximum) ? maximum : UInt64(value)
    }
}
