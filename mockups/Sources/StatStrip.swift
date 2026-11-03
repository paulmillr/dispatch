import SwiftUI

// Three small-sheet designs without rings: the same header and Disconnect, different metric displays.

/// A tiny sparkline of the last 15 minutes.
struct Sparkline: View {
    let bars: [Double?]
    var color: Color = hostTint
    var filled = true
    var body: some View {
        Canvas { ctx, size in
            let pts: [CGPoint] = bars.enumerated().compactMap { i, v in
                guard let v else { return nil }
                return CGPoint(x: size.width * Double(i) / Double(bars.count - 1), y: size.height - size.height * v / 100)
            }
            guard pts.count > 1 else { return }
            var line = Path(); line.move(to: pts[0])
            for p in pts.dropFirst() { line.addLine(to: p) }
            if filled {
                var area = line
                area.addLine(to: CGPoint(x: pts.last!.x, y: size.height)); area.addLine(to: CGPoint(x: pts[0].x, y: size.height)); area.closeSubpath()
                ctx.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0.02)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            let last = pts.last!
            ctx.fill(Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)), with: .color(color))
        }
    }
}

/// B: one stat strip and one wide chart. Three numbers in a row like Stocks' key stats, the CPU history as a filled
/// area under them with the live value's dot. Tapping a stat switches the chart.
struct StatStripCard: View {
    var selected = 0
    var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    stat("CPU", "34", "%", sub: "2.71 load", selected: selected == 0)
                    divider
                    stat("Memory", "11", "GB", sub: "of 32 GB", selected: selected == 1)
                    divider
                    stat("Disk", "48", "GB", sub: "free · 90% used", warn: true)
                }
                .padding(.vertical, 12)
                Sparkline(bars: selected == 1 ? MockStats.history.map { $0.map { 30 + $0 * 0.1 } } : MockStats.history).frame(height: 70)
                    .padding(.horizontal, 16).padding(.bottom, 6)
                HStack {
                    Text(selected == 1 ? "Memory · 15 min" : "CPU · 15 min").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Text(selected == 1 ? "peak 36% · avg 33%" : "peak 82% · avg 31%").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16).padding(.bottom, 10)
            }
            .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 20))
    }
    private var divider: some View { Rectangle().fill(Color(uiColor: .separator)).frame(width: 0.5, height: 44) }
    private func stat(_ title: String, _ value: String, _ unit: String, sub: String, selected: Bool = false, warn: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(selected ? hostTint : .secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(warn ? Color.destructive : .primary)
                Text(unit).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(sub).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}
