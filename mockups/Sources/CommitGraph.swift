import SwiftUI

/// One row of the log as the graph lays it out.
struct GraphRow: Identifiable {
    enum Kind { case uncommitted, commit }
    let kind: Kind
    let subject: String
    let age: String
    /// 0 the branch's lane, 1 the merged branch's.
    var lane = 0
    /// A merge: the second lane leaves this dot and runs down until `base`.
    var merge = false
    /// Where the second lane rejoins the first.
    var base = false
    let id = UUID()
}

/// The graph's colours. The current branch has one; merged branches take `merged` in turn down the log.
struct GraphPalette {
    var current: Color
    var merged: [Color]
    /// Merged branches' dots as rings, so the current branch is the only filled run (H3c).
    var hollowMerged = false
    /// Subjects inside a merged span in the secondary colour (H3c).
    var dimMerged = false

    func merged(_ n: Int) -> Color { merged[n % merged.count] }

    /// H3 as drawn: green and amber, the diff's added and caution colours.
    static let status = GraphPalette(current: .added, merged: [.caution])
    /// H3d: H3's green and amber with more chroma at the same lightness (dark #3FD98A / #F2B33D, light #12804A / #A86A00).
    static let vivid = GraphPalette(current: .dynamic(light: 0x12804A, dark: 0x3FD98A),
                                    merged: [.dynamic(light: 0xA86A00, dark: 0xF2B33D)])
    /// H3f–h: H3d's green with another colour than amber for merged branches; none of them a diff colour; the rose is warmer than the orchid accent (#E07BE0).
    static let vividBlue = vivid(merged: .dynamic(light: 0x1F6FD6, dark: 0x5AA9FF))
    static let vividRose = vivid(merged: .dynamic(light: 0xD63A7A, dark: 0xFF6FA8))
    /// H3i: merged branches neutral, the system grey (#8E8E93 in both appearances).
    static let vividGray = vivid(merged: Color(.systemGray))
    static let vividCyan = vivid(merged: .dynamic(light: 0x0A7F99, dark: 0x45CCE6))
    static func vivid(merged: Color) -> GraphPalette { GraphPalette(current: vivid.current, merged: [merged]) }
    /// H3e: fully saturated, the system's own green and orange tones (dark #30D158 / #FF9F0A, light #0A9A3C / #C26A00).
    static let saturated = GraphPalette(current: .dynamic(light: 0x0A9A3C, dark: 0x30D158),
                                        merged: [.dynamic(light: 0xC26A00, dark: 0xFF9F0A)])
    /// H3a: the app's tint for the current branch, neutral grey for everything merged into it.
    static let tint = GraphPalette(current: .dispatchPink, merged: [Color(.systemGray)])
    /// H3b: a hue per branch, none of them a diff or state colour (no green, red or amber).
    static let hues = GraphPalette(current: .blue, merged: [.purple, .teal, .orange, .indigo])
    /// H3c: ink. The current branch in the label colour, merged ones grey with hollow dots and quieter subjects.
    static let ink = GraphPalette(current: .primary, merged: [Color(.systemGray2)], hollowMerged: true, dimMerged: true)
}

enum MockLog {
    static let rows: [GraphRow] = [
        .init(kind: .uncommitted, subject: "Uncommitted changes", age: ""),
        .init(kind: .commit, subject: "Sidebar theme toggle and unread rows", age: "25m"),
        .init(kind: .commit, subject: "Theme tokens: dark palette and contrast fixes", age: "2h"),
        .init(kind: .commit, subject: "useTheme hook with system preference tracking", age: "5h"),
        .init(kind: .commit, subject: "Merge branch 'router-upgrade'", age: "1d", merge: true),
        .init(kind: .commit, subject: "Upgrade react-router to v7", age: "1d", lane: 1),
        .init(kind: .commit, subject: "Fix nested route links losing the active class", age: "2d", lane: 1),
        .init(kind: .commit, subject: "Release 1.4.0", age: "3d"),
        .init(kind: .commit, subject: "Docs: deployment notes for the preview environment", age: "4d", base: true),
        .init(kind: .commit, subject: "Spaces list: keyboard navigation", age: "5d"),
        .init(kind: .commit, subject: "CI: cache pnpm store between jobs", age: "6d"),
        .init(kind: .commit, subject: "Header: collapse search on narrow widths", age: "1w"),
        .init(kind: .commit, subject: "Initial Vite scaffold", age: "3w"),
    ]

    /// Two merged branches, so a palette with a colour per branch shows it.
    static let twoBranches: [GraphRow] = [
        .init(kind: .uncommitted, subject: "Uncommitted changes", age: ""),
        .init(kind: .commit, subject: "Sidebar theme toggle and unread rows", age: "25m"),
        .init(kind: .commit, subject: "Merge branch 'dark-palette'", age: "2h", merge: true),
        .init(kind: .commit, subject: "Theme tokens: dark palette and contrast fixes", age: "3h", lane: 1),
        .init(kind: .commit, subject: "useTheme hook with system preference tracking", age: "5h", base: true),
        .init(kind: .commit, subject: "Merge branch 'router-upgrade'", age: "1d", merge: true),
        .init(kind: .commit, subject: "Upgrade react-router to v7", age: "1d", lane: 1),
        .init(kind: .commit, subject: "Fix nested route links losing the active class", age: "2d", lane: 1),
        .init(kind: .commit, subject: "Release 1.4.0", age: "3d"),
        .init(kind: .commit, subject: "Docs: deployment notes for the preview environment", age: "4d", base: true),
        .init(kind: .commit, subject: "Spaces list: keyboard navigation", age: "5d"),
        .init(kind: .commit, subject: "CI: cache pnpm store between jobs", age: "6d"),
        .init(kind: .commit, subject: "Header: collapse search on narrow widths", age: "1w"),
        .init(kind: .commit, subject: "Initial Vite scaffold", age: "3w"),
    ]
}

/// The log: a continuous graph in the gutter, one line per commit, the age in mono at the trailing edge. Rows inside a
/// merged branch's span indent past its lane.
struct CommitGraphList: View {
    var rows = MockLog.rows
    /// The commit open beside the log (iPad).
    var selected: Int? = nil
    var palette = GraphPalette.status
    static let rowHeight: CGFloat = 44
    static let lane0: CGFloat = 26
    static let lane1: CGFloat = 46
    static let indent: CGFloat = 20

    /// Each merged branch's rows, merge dot through base, in log order.
    private var spans: [ClosedRange<Int>] {
        var spans: [ClosedRange<Int>] = [], start: Int?
        for (i, row) in rows.enumerated() {
            if row.merge { start = i }
            if row.base, let s = start { spans.append(s...i); start = nil }
        }
        return spans
    }

    private func spanIndex(_ i: Int) -> Int? { spans.firstIndex { $0.contains(i) } }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 0) {
                    Color.clear.frame(width: Self.lane0 + 22 + (spanIndex(index) != nil ? Self.indent : 0))
                    Text(row.subject)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(palette.dimMerged && row.lane == 1 ? .secondary : .primary)
                    Spacer(minLength: 12)
                    if row.kind == .uncommitted {
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    } else {
                        Text(row.age).font(.system(.subheadline, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                .padding(.trailing, 20)
                .frame(height: Self.rowHeight)
                .background { if selected == index { Color.lens } }
                .contentShape(Rectangle())
            }
        }
        .background(alignment: .topLeading) { graph }
    }

    private var graph: some View {
        Canvas { ctx, _ in
            let h = Self.rowHeight
            func y(_ i: Int) -> CGFloat { h * CGFloat(i) + h / 2 }
            let current = palette.current
            let stroke = StrokeStyle(lineWidth: 2.5, lineCap: .round)
            // The branch's lane, from the uncommitted ring down to the last row.
            var main = Path()
            main.move(to: CGPoint(x: Self.lane0, y: y(0)))
            main.addLine(to: CGPoint(x: Self.lane0, y: y(rows.count - 1)))
            ctx.stroke(main, with: .color(current), style: stroke)
            // Each merged branch: out of the merge dot, down its lane, back into the base.
            for (n, span) in spans.enumerated() {
                let m = span.lowerBound, b = span.upperBound
                var side = Path()
                side.move(to: CGPoint(x: Self.lane0, y: y(m)))
                side.addQuadCurve(to: CGPoint(x: Self.lane1, y: y(m) + 22), control: CGPoint(x: Self.lane1, y: y(m)))
                side.addLine(to: CGPoint(x: Self.lane1, y: y(b) - 22))
                side.addQuadCurve(to: CGPoint(x: Self.lane0, y: y(b)), control: CGPoint(x: Self.lane1, y: y(b)))
                ctx.stroke(side, with: .color(palette.merged(n)), style: stroke)
            }
            for (i, row) in rows.enumerated() {
                let side = row.lane == 1
                let x = side ? Self.lane1 : Self.lane0
                let color = side ? palette.merged(spanIndex(i) ?? 0) : current
                let r: CGFloat = row.kind == .uncommitted ? 6 : 6.5
                let dot = Path(ellipseIn: CGRect(x: x - r, y: y(i) - r, width: 2 * r, height: 2 * r))
                if row.kind == .uncommitted || (side && palette.hollowMerged) {
                    ctx.fill(dot, with: .color(.canvas))
                    ctx.stroke(dot, with: .color(color), style: StrokeStyle(lineWidth: 2.5))
                } else {
                    ctx.fill(dot, with: .color(color))
                }
            }
        }
        .frame(width: Self.lane1 + 20, height: Self.rowHeight * CGFloat(rows.count))
    }
}

extension Color {
    /// An sRGB colour per appearance, written as 0xRRGGBB.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        func ui(_ v: UInt32) -> UIColor {
            UIColor(red: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }
}
