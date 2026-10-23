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
}

/// The log: a continuous graph in the gutter, one line per commit, the age in mono at the trailing edge. Rows inside a
/// merged branch's span indent past its lane.
struct CommitGraphList: View {
    var rows = MockLog.rows
    /// The commit open beside the log (iPad).
    var selected: Int? = nil
    static let rowHeight: CGFloat = 44
    static let lane0: CGFloat = 26
    static let lane1: CGFloat = 46
    static let indent: CGFloat = 20

    private var span: Range<Int> {
        let start = rows.firstIndex { $0.merge } ?? 0
        let end = rows.firstIndex { $0.base } ?? start
        return start..<(end + 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 0) {
                    Color.clear.frame(width: Self.lane0 + 22 + (span.contains(index) ? Self.indent : 0))
                    Text(row.subject)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(row.kind == .uncommitted ? .primary : .primary)
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
            let green = Color.added, amber = Color.caution
            let stroke = StrokeStyle(lineWidth: 2.5, lineCap: .round)
            // The branch's lane, from the uncommitted ring down to the last row.
            var main = Path()
            main.move(to: CGPoint(x: Self.lane0, y: y(0)))
            main.addLine(to: CGPoint(x: Self.lane0, y: y(rows.count - 1)))
            ctx.stroke(main, with: .color(green), style: stroke)
            // The merged branch: out of the merge dot, down its lane, back into the base.
            if let m = rows.firstIndex(where: { $0.merge }), let b = rows.firstIndex(where: { $0.base }) {
                var side = Path()
                side.move(to: CGPoint(x: Self.lane0, y: y(m)))
                side.addQuadCurve(to: CGPoint(x: Self.lane1, y: y(m) + 22), control: CGPoint(x: Self.lane1, y: y(m)))
                side.addLine(to: CGPoint(x: Self.lane1, y: y(b) - 22))
                side.addQuadCurve(to: CGPoint(x: Self.lane0, y: y(b)), control: CGPoint(x: Self.lane1, y: y(b)))
                ctx.stroke(side, with: .color(amber), style: stroke)
            }
            for (i, row) in rows.enumerated() {
                let x = row.lane == 1 ? Self.lane1 : Self.lane0
                let color = row.lane == 1 ? amber : green
                let r: CGFloat = row.kind == .uncommitted ? 6 : 6.5
                let dot = Path(ellipseIn: CGRect(x: x - r, y: y(i) - r, width: 2 * r, height: 2 * r))
                if row.kind == .uncommitted {
                    ctx.fill(dot, with: .color(.canvas))
                    ctx.stroke(dot, with: .color(green), style: StrokeStyle(lineWidth: 2.5))
                } else {
                    ctx.fill(dot, with: .color(color))
                }
            }
        }
        .frame(width: Self.lane1 + 20, height: Self.rowHeight * CGFloat(rows.count))
    }
}
