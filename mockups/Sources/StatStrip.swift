import SwiftUI

// Three small-sheet designs without rings: the same header and Disconnect, different metric displays.

/// Shared: the sheet shell around a content block.
struct SmallSheetShell<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                content
                Text("Disconnect").font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity).frame(height: 50).glassEffect(.regular.interactive(), in: Capsule())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 4)
            .background(Color.canvas)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 10) {
                        Image(systemName: "apple.logo").font(.system(size: 17)).foregroundStyle(hostTint)
                            .frame(width: 34, height: 34).background(hostTint.opacity(0.15), in: Circle())
                        VStack(alignment: .leading, spacing: 0) {
                            Text("mba2").font(.headline)
                            HStack(spacing: 5) {
                                Circle().fill(Color.stateConnected).frame(width: 6, height: 6)
                                Text("macOS 26.1 · 18 ms").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) { Button {} label: { Image(systemName: "xmark") } }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

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

/// The small sheet: the strip card and Disconnect.
struct SmallVariantB: View {
    var body: some View { SmallSheetShell { StatStripCard() } }
}

struct SmallVariantHost<V: View>: View {
    let height: CGFloat
    @ViewBuilder var sheet: V
    var body: some View {
        SpacesRootScreen()
            .sheet(isPresented: .constant(true)) {
                sheet.presentationDetents([.height(height)]).presentationDragIndicator(.visible)
            }
    }
}
