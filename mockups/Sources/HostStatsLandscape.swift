import SwiftUI

// L19: the host sheet on a phone's side as the app ships it (`HostStatsLandscape`): a chart screen in the landscape
// tabs' chrome. No header row; one rail on the Dynamic Island's side, 2 points clear of it (the island's inset less 10:
// 52 on this iPhone), Close and the host's disc (a tab menu disc's ⋯ badge) at its top and Edit at its foot, where a
// tab's rail holds its mode's action; the content runs into the other side's inset to 12 points from the glass. The
// host's name shows as the tabs' title capsule for 2.5 s as the screen opens (L19b), then goes; its facts (the upright
// sheet's connection rows) and its action are behind the disc (L19c). CPU, Memory and Disk in a row, then CPU and
// memory in one chart on one 0–100% axis (memory as a share of the host's), the gridlines' values inside it: all the
// height below the row, 748 of the 874 points' width (86%).
/// What a chart shows: its samples (0–100 of the axis), the axis' labels, the live value and its sub-line.
private enum Series {
    case cpu, memory

    var title: String { self == .cpu ? "CPU" : "Memory" }
    var color: Color { self == .cpu ? hostTint : Color(red: 0.62, green: 0.52, blue: 0.86) }
    var values: [Double?] {
        switch self {
        case .cpu: MockStats.history
        case .memory: MockStats.history.enumerated().map { index, value in
            value.map { _ in 31 + 6 * sin(Double(index) / 9) + (index > 40 ? 4 : 0) }
        }
        }
    }
    /// The gridlines' values, bottom to top, at 0, 50 and 100% of the axis.
    var ticks: [String] { self == .cpu ? ["0%", "50%", "100%"] : ["0", "16 GB", "32 GB"] }
    var live: (value: String, unit: String) { self == .cpu ? ("34", "%") : ("11", "GB") }
    var sub: String { self == .cpu ? "2.71 load · peak 82% · avg 31%" : "of 32 GB · peak 13 GB · avg 11 GB" }
    func reading(_ value: Double) -> String { self == .cpu ? "\(Int(value))%" : String(format: "%.1f GB", value * 0.32) }
}

/// A series as runs of line over a fading fill, broken where a bucket has no sample (the host slept), and the live dot.
private func plot(_ values: [Double?], color: Color, fill: Double = 0.35, in context: inout GraphicsContext, size: CGSize) {
    let x = { (index: Int) in size.width * Double(index) / Double(values.count - 1) }
    let y = { (value: Double) in size.height - size.height * value / 100 }
    var runs: [[CGPoint]] = [[]]
    for (index, value) in values.enumerated() {
        if let value { runs[runs.count - 1].append(CGPoint(x: x(index), y: y(value))) }
        else if !(runs.last?.isEmpty ?? true) { runs.append([]) }
    }
    for run in runs where run.count > 1 {
        var line = Path()
        line.addLines(run)
        var area = line
        area.addLine(to: CGPoint(x: run.last!.x, y: size.height))
        area.addLine(to: CGPoint(x: run[0].x, y: size.height))
        area.closeSubpath()
        context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(fill), color.opacity(0.02)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }
    if let last = runs.last?.last {
        context.fill(Path(ellipseIn: CGRect(x: last.x - 4.5, y: last.y - 4.5, width: 9, height: 9)), with: .color(color))
    }
}

/// CPU and Memory in one chart on one 0–100% axis, the legend with both live values over it; scrubbed, one line
/// and both readings.
private struct CombinedChart: View {
    var scrub: Int? = nil
    /// The gridlines' values inside the chart at its leading edge, not in a trailing gutter.
    var inline = false
    private var gutter: CGFloat { inline ? 0 : 48 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 36) {
                legend(.cpu, value: "34", unit: "%", sub: "load 2.71 · peak 82%")
                legend(.memory, value: "11", unit: "GB", sub: "of 32 GB · peak 13 GB")
                // The disk beside them, no swatch: it has no line in the chart.
                VStack(alignment: .leading, spacing: 0) {
                    Text("Disk").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("48").font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(Color.destructive)
                        Text("GB").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("free · 90% used").font(.caption).foregroundStyle(.tertiary).padding(.leading, 6)
                    }
                }
                Spacer()
                Text("Last 15 min").font(.caption).foregroundStyle(.tertiary)
            }
            GeometryReader { box in
                let width = box.size.width - gutter, height = box.size.height
                let x = { (index: Int) in width * Double(index) / Double(MockStats.history.count - 1) }
                ZStack(alignment: .topLeading) {
                    ForEach(0..<3) { line in
                        let fraction = Double(line) / 2
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: height * (1 - fraction)))
                            path.addLine(to: CGPoint(x: width, y: height * (1 - fraction)))
                        }
                        .stroke(Color(uiColor: .separator), style: StrokeStyle(lineWidth: 0.5, dash: line == 0 ? [] : [3, 3]))
                        Text(["0%", "50%", "100%"][line]).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                            .fixedSize()
                            // Inline: over its line, the top one under it (the legend is above).
                            .position(x: inline ? 18 : width + gutter / 2 + 4,
                                      y: height * (1 - fraction) + (inline ? (line == 2 ? 9 : -9) : 0))
                    }
                    // Memory under CPU: its fill fainter, so CPU's spikes read over it.
                    Canvas { context, size in
                        plot(Series.memory.values, color: Series.memory.color, fill: 0.18, in: &context, size: size)
                        plot(Series.cpu.values, color: Series.cpu.color, fill: 0.3, in: &context, size: size)
                    }
                    .frame(width: width, height: height)
                    if let scrub, let cpu = Series.cpu.values[scrub], let memory = Series.memory.values[scrub] {
                        Path { path in
                            path.move(to: CGPoint(x: x(scrub), y: 0))
                            path.addLine(to: CGPoint(x: x(scrub), y: height))
                        }
                        .stroke(Color.primary.opacity(0.6), lineWidth: 1)
                        ForEach([(Series.cpu, cpu), (Series.memory, memory)], id: \.1) { series, value in
                            Circle().fill(series.color).frame(width: 10, height: 10)
                                .overlay(Circle().stroke(Color.canvas, lineWidth: 2))
                                .position(x: x(scrub), y: height - height * value / 100)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("2:41 PM").font(.caption2).foregroundStyle(.secondary)
                            reading(.cpu, Series.cpu.reading(cpu))
                            reading(.memory, Series.memory.reading(memory))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
                        .position(x: x(scrub) + 62, y: 34)
                    }
                }
            }
            GeometryReader { box in
                let width = box.size.width - gutter
                ForEach(Array(["15 min ago", "10 min", "5 min", "now"].enumerated()), id: \.offset) { index, label in
                    Text(label).font(.caption2).foregroundStyle(.tertiary).fixedSize()
                        .position(x: index == 0 ? 30 : index == 3 ? width - 12 : width * Double(index) / 3, y: 7)
                }
            }
            .frame(height: 14)
        }
    }

    /// One series' block: its swatch and name, the live value, one quiet line under it.
    private func legend(_ series: Series, value: String, unit: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Capsule().fill(series.color).frame(width: 12, height: 4)
                Text(series.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(sub).font(.caption).foregroundStyle(.tertiary).padding(.leading, 6)
            }
        }
    }

    private func reading(_ series: Series, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(series.color).frame(width: 7, height: 7)
            Text(series.title).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }
}


enum HostRailState { case rest, opening, facts }

struct HostStatsRailScreen: View {
    var state: HostRailState = .rest

    var body: some View {
        HStack(spacing: 10) {
            rail
            CombinedChart(scrub: nil, inline: true)
                .padding(.top, 8).padding(.bottom, 4)
        }
        .padding(.leading, 52).padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .horizontal)
        .background(Color.canvas.ignoresSafeArea())
        .overlay(alignment: .top) {
            if state == .opening {
                // The tabs' title capsule, the upright header's without its menu, for 2.5 s: over the chart's empty top,
                // under the legend it would cover.
                TitleCapsuleMock(title: "mba2", subtitle: AnyView(
                    HStack(spacing: 5) {
                        Circle().fill(Color.stateConnected).frame(width: 6, height: 6)
                        Text("macOS 26.1 · 18 ms")
                    }))
                .padding(.top, 70)
            }
        }
        .overlay(alignment: .topLeading) {
            if state == .facts { facts.padding(.leading, 52 + FullHeight.rail + 8).padding(.top, 58).ignoresSafeArea(edges: .horizontal) }
        }
    }

    private var rail: some View {
        VStack(spacing: 8) {
            disc("xmark")
            // The host's disc: its icon in its tint, a menu disc's ⋯ badge, the facts behind it.
            Image(systemName: "apple.logo").font(.system(size: 20)).foregroundStyle(hostTint)
                .frame(width: FullHeight.control, height: FullHeight.control)
                .glassEffect(state == .facts ? .regular.tint(hostTint.opacity(0.35)).interactive() : .regular.interactive(), in: Circle())
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "ellipsis").font(.system(size: 8, weight: .heavy)).foregroundStyle(.primary)
                        .frame(width: 17, height: 17)
                        .background(Color(uiColor: .systemGray4), in: Circle())
                        .overlay { Circle().stroke(Color.canvas, lineWidth: 2) }
                        .offset(x: 2, y: 2)
                }
            Spacer(minLength: 10)
            disc("pencil")
        }
        .frame(width: FullHeight.rail)
        .padding(.vertical, 10)
    }

    private func disc(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.body.weight(.semibold))
            .frame(width: FullHeight.control, height: FullHeight.control)
            .glassEffect(.regular.interactive(), in: Circle())
    }

    /// The disc's popover: what the upright sheet's header and connection rows say.
    private var facts: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("mba2").font(.headline)
                Circle().fill(Color.stateConnected).frame(width: 7, height: 7)
                Text("Connected").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            ForEach([("Address", "alex@mba2.tail3f.ts.net"), ("System", "macOS 26.1"), ("Latency", "18 ms"),
                     ("Sampling", "every 5 s"), ("Multiplexer", "herdr 0.9.5"), ("Helper", "Full features")], id: \.0) { label, value in
                Hairline()
                HStack {
                    Text(label).font(.subheadline)
                    Spacer(minLength: 16)
                    Text(value).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
            }
        }
        .frame(width: 330)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
    }
}
