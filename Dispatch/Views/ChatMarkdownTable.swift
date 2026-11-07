import SwiftUI

/// A Markdown table's cells in columns that fit the width offered, as a browser sizes an automatic table: every column
/// as wide as its widest cell on one line when they all fit; otherwise each column gets at least its longest word
/// (`ChatSelectableText.wordWidth`) and the room left goes to the columns in proportion to how much more they would
/// take, so long prose wraps and short values stay on one line. Only when even the longest words do not fit are the
/// columns narrowed below them (in proportion), breaking within words: the table never scrolls sideways.
///
/// Its subviews are the cells row by row, `columns` per row, and after each row but the last its separator, which
/// spans the table. Cells sit at their row's top.
struct ChatTableLayout: Layout {
    let columns: Int
    var columnSpacing: CGFloat = 18
    var rowSpacing: CGFloat = 8
    /// The narrowest column made while the longest words fit (or the column's widest cell, when narrower): the
    /// minimum a cell reports may be a single character (SwiftUI's `Text`, before macOS 26).
    static let narrowest: CGFloat = 56
    /// The widest a column's minimum gets: a long path or URL wraps within itself rather than squeezing the rest.
    static let widestMinimum: CGFloat = 240

    struct Cache {
        /// Per column: its widest cell on one line, and the narrowest it can be without breaking a word.
        var ideal: [CGFloat] = []
        var minimum: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Cache {
        var cache = Cache(ideal: Array(repeating: 0, count: columns), minimum: Array(repeating: 0, count: columns))
        for row in 0..<rows(subviews) {
            for column in 0..<columns {
                let cell = subviews[row * (columns + 1) + column]
                cache.ideal[column] = max(cache.ideal[column], ceil(cell.sizeThatFits(.unspecified).width))
                cache.minimum[column] = max(cache.minimum[column], ceil(cell.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width))
            }
        }
        for column in 0..<columns {
            let ideal = cache.ideal[column]
            cache.minimum[column] = min(ideal, max(min(cache.minimum[column], Self.widestMinimum), Self.narrowest))
        }
        return cache
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let widths = widths(for: proposal.width, cache: cache)
        let width = widths.reduce(0, +) + gutters
        return CGSize(width: width, height: rowHeights(widths, subviews).reduce(0, +) + separators(width, subviews))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let widths = widths(for: bounds.width, cache: cache)
        let width = widths.reduce(0, +) + gutters
        let heights = rowHeights(widths, subviews)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            var x = bounds.minX
            for column in 0..<columns {
                subviews[row * (columns + 1) + column].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: widths[column], height: nil))
                x += widths[column] + columnSpacing
            }
            y += height
            guard row < heights.count - 1 else { break }
            let separator = subviews[row * (columns + 1) + columns]
            let line = separator.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            separator.place(at: CGPoint(x: bounds.minX, y: y + rowSpacing), anchor: .topLeading,
                            proposal: ProposedViewSize(width: width, height: line))
            y += rowSpacing * 2 + line
        }
    }

    /// The columns' widths in `available` points (nil: no limit), gutters left out.
    func widths(for available: CGFloat?, cache: Cache) -> [CGFloat] {
        let ideal = cache.ideal, minimum = cache.minimum
        guard let available, available.isFinite else { return ideal }
        let room = max(0, available - gutters)
        let wanted = ideal.reduce(0, +), least = minimum.reduce(0, +)
        if wanted <= room { return ideal }
        if least >= room {
            let scale = least > 0 ? room / least : 0
            return minimum.map { ($0 * scale).rounded(.down) }
        }
        // `wanted > room > least`, so some column would take more than its minimum.
        let spare = room - least, flexible = wanted - least
        return zip(ideal, minimum).map { ideal, minimum in (minimum + spare * (ideal - minimum) / flexible).rounded(.down) }
    }

    private var gutters: CGFloat { CGFloat(max(0, columns - 1)) * columnSpacing }

    private func rows(_ subviews: Subviews) -> Int {
        columns > 0 ? (subviews.count + 1) / (columns + 1) : 0
    }

    private func rowHeights(_ widths: [CGFloat], _ subviews: Subviews) -> [CGFloat] {
        (0..<rows(subviews)).map { row in
            (0..<columns).map { column in
                subviews[row * (columns + 1) + column].sizeThatFits(ProposedViewSize(width: widths[column], height: nil)).height
            }.max() ?? 0
        }
    }

    /// The separators' height with the spacing around each.
    private func separators(_ width: CGFloat, _ subviews: Subviews) -> CGFloat {
        let count = max(0, rows(subviews) - 1)
        return (0..<count).reduce(0) { total, row in
            total + rowSpacing * 2 + subviews[row * (columns + 1) + columns].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
    }
}
