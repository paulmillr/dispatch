import SwiftUI

/// The stat strip (W1a): CPU, memory and disk in a row as Stocks' key stats, over one 15-minute sparkline of the chosen
/// metric. Tapping CPU or Memory chooses the chart (and the process card's order); dragging across the chart reads a
/// bar's value and time in the caption (W3). Dimmed while the numbers are not current (W5).
struct StatStripCard: View {
    let stats: HostStatistics
    @Binding var metric: HostStatistics.Metric
    /// The chart's tint: the host's colour.
    var tint: Color
    var dimmed = false
    /// The bar being read, while dragging (W3).
    @Binding var scrub: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                let sample = stats.sample
                stat(.cpu, title: "CPU", value: HostStatsFormat.percent(sample?.cpu), unit: "%",
                     sub: HostStatsFormat.load(sample?.load), warn: HostStatsFormat.cpuHigh(sample?.cpu))
                divider
                let memory = HostStatsFormat.size(sample?.memoryUsed)
                stat(.memory, title: "Memory", value: memory.value, unit: memory.unit,
                     sub: sample?.memoryTotal.map { "of \(HostStatsFormat.sizeText($0))" } ?? "memory",
                     warn: HostStatsFormat.memoryHigh(sample?.memoryPercent))
                divider
                let free = HostStatsFormat.size(stats.disk?.free)
                stat(nil, title: "Disk", value: free.value, unit: free.unit,
                     sub: stats.disk?.usedPercent.map { "free · \(HostStatsFormat.percent($0))% used" } ?? "free",
                     warn: HostStatsFormat.diskHigh(stats.disk?.usedPercent))
            }
            .padding(.vertical, 12)
            // The timeline steps the grid every 15 s while nothing comes in; each sample redraws the chart at its own
            // time, so the newest bar follows the 2 s samples (a tick older than the sample left it out).
            TimelineView(.periodic(from: .now, by: HostStatistics.barSpan)) { context in
                chart(at: Self.chartDate(context.date, stats: stats))
            }
        }
        .opacity(dimmed ? 0.5 : 1)
        .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 20))
    }

    /// The chart's present: the timeline's, or the newest sample's when that is later.
    static func chartDate(_ timeline: Date, stats: HostStatistics) -> Date {
        max(timeline, stats.sample?.date ?? timeline)
    }

    private func chart(at now: Date) -> some View {
        let bars = stats.bars(metric, at: now)
        return VStack(spacing: 0) {
            Sparkline(bars: bars, color: tint, live: stats.live, scrub: $scrub)
                .frame(height: 70)
                .padding(.horizontal, 16).padding(.bottom, 6)
                .accessibilityElement()
                .accessibilityLabel("\(metric.title), last 15 minutes")
                .accessibilityValue(Self.chartValue(bars, peak: stats.peak(metric, at: now), average: stats.average(metric, at: now)))
            HStack {
                Text(leadingCaption(bars, now: now)).monospacedDigit()
                Spacer()
                if let line = HostStatsFormat.peakLine(peak: stats.peak(metric, at: now), average: stats.average(metric, at: now)) {
                    Text(line).monospacedDigit()
                }
            }
            .font(.caption2).foregroundStyle(.tertiary)
            .padding(.horizontal, 16).padding(.bottom, 10)
            .accessibilityHidden(true)
        }
    }

    /// "now 34%, peak 82% · avg 31%" for VoiceOver: the newest bar, then the window's peak and average.
    static func chartValue(_ bars: [Double?], peak: Double?, average: Double?) -> String {
        let latest = bars.last.flatMap { $0 }.map { "now \(HostStatsFormat.percent($0))%" }
        let parts = [latest, HostStatsFormat.peakLine(peak: peak, average: average)].compactMap { $0 }
        return parts.isEmpty ? "No samples yet" : parts.joined(separator: ", ")
    }

    /// "CPU · 15 min", or while scrubbing the bar's value and time ("CPU 47% · 2:14 PM", "Memory no sample · 2:14 PM").
    private func leadingCaption(_ bars: [Double?], now: Date) -> String {
        guard let scrub, bars.indices.contains(scrub) else { return "\(metric.title) · 15 min" }
        let value = bars[scrub].map { "\(HostStatsFormat.percent($0))%" } ?? "no sample"
        return "\(metric.title) \(value) · \(HostStatsFormat.time(HostStatistics.barStart(scrub, at: now)))"
    }

    private var divider: some View {
        Rectangle().fill(Color(uiColor: .separator)).frame(width: 0.5, height: 44)
    }

    @ViewBuilder
    private func stat(_ choice: HostStatistics.Metric?, title: String, value: String, unit: String, sub: String, warn: Bool) -> some View {
        let selected = choice == metric
        let column = VStack(spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(selected ? tint : .secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(warn ? Color.destructive : .primary)
                Text(unit).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .lineLimit(1).minimumScaleFactor(0.6)
            Text(sub).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        if let choice {
            Button {
                withAnimation(.snappy) { metric = choice }
            } label: { column }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue("\(value) \(unit), \(sub)")
            .accessibilityHint("Shows \(title == "CPU" ? "CPU" : "memory") in the chart and orders the processes by it")
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            column
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue("\(value) \(unit) \(sub)")
        }
    }
}

/// The 15-minute history as a line over a fading fill (W1a): one point per bar, broken where a bar has no sample (the
/// host was offline, the app in the background), the newest point a dot while samples are coming. A drag reads bars:
/// `scrub` is the bar under the finger, marked with a rule.
struct Sparkline: View {
    let bars: [Double?]
    var color: Color
    var live = true
    @Binding var scrub: Int?

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in draw(in: &context, size: size) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let index = Self.index(at: value.location.x, width: proxy.size.width, count: bars.count)
                        if scrub != index { scrub = index }
                    }
                    .onEnded { _ in scrub = nil })
        }
    }

    /// The bar under `x`.
    static func index(at x: CGFloat, width: CGFloat, count: Int) -> Int {
        guard count > 1, width > 0 else { return 0 }
        return min(count - 1, max(0, Int((x / width * CGFloat(count - 1)).rounded())))
    }

    /// The runs of consecutive bars with a value, as points.
    static func segments(_ bars: [Double?], size: CGSize) -> [[CGPoint]] {
        guard bars.count > 1 else { return [] }
        var result: [[CGPoint]] = [], run: [CGPoint] = []
        for (index, bar) in bars.enumerated() {
            guard let bar else {
                if !run.isEmpty { result.append(run); run = [] }
                continue
            }
            run.append(CGPoint(x: size.width * CGFloat(index) / CGFloat(bars.count - 1),
                               y: size.height - size.height * CGFloat(min(100, max(0, bar))) / 100))
        }
        if !run.isEmpty { result.append(run) }
        return result
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let segments = Self.segments(bars, size: size)
        for points in segments {
            var line = Path()
            line.move(to: points[0])
            for point in points.dropFirst() { line.addLine(to: point) }
            if points.count == 1 {
                // A lone sample between gaps: a short tick, so it shows.
                line.addLine(to: CGPoint(x: points[0].x + 1, y: points[0].y))
            }
            var area = line
            area.addLine(to: CGPoint(x: points.last!.x, y: size.height))
            area.addLine(to: CGPoint(x: points[0].x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0.02)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        if live, bars.last.flatMap({ $0 }) != nil, let last = segments.last?.last {
            context.fill(Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)), with: .color(color))
        }
        if let scrub, bars.indices.contains(scrub) {
            let x = size.width * CGFloat(scrub) / CGFloat(max(1, bars.count - 1))
            var rule = Path()
            rule.move(to: CGPoint(x: x, y: 0))
            rule.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(rule, with: .color(.secondary), lineWidth: 1)
            if let value = bars[scrub] {
                let y = size.height - size.height * CGFloat(value) / 100
                context.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(color))
            }
        }
    }
}

/// A grouped card with an optional title row (the stats sheet's Top processes).
struct HostStatsCard<Content: View>: View {
    var title: String? = nil
    var trailing: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack {
                    Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if let trailing { Text(trailing).font(.subheadline).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 20))
    }
}

/// The top processes by CPU or by memory, each with a bar proportional to the first (W1, W2).
struct HostProcessesCard: View {
    let stats: HostStatistics
    let metric: HostStatistics.Metric
    var tint: Color

    var body: some View {
        let top = stats.top(metric)
        let values = top.map { metric == .cpu ? ($0.cpu ?? 0) : Double($0.memory) }
        let largest = max(values.max() ?? 0, 1)
        HostStatsCard(title: "Top processes", trailing: metric == .cpu ? "by CPU" : "by memory") {
            if top.isEmpty {
                Text(stats.sample == nil ? "No processes yet" : "No processes")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(zip(top, values)), id: \.0.id) { process, value in
                        HostProcessRow(name: process.name,
                                       value: metric == .cpu ? "\(HostStatsFormat.percent(process.cpu))%" : HostStatsFormat.sizeText(process.memory),
                                       fraction: value / largest, color: tint)
                    }
                }
            }
        }
    }
}

struct HostProcessRow: View {
    let name: String
    let value: String
    let fraction: Double
    var color: Color

    var body: some View {
        HStack(spacing: 12) {
            Text(name).font(.body).lineLimit(1).truncationMode(.middle)
            Spacer()
            Capsule().fill(color.opacity(0.25)).frame(width: 70, height: 6)
                .overlay(alignment: .leading) { Capsule().fill(color).frame(width: 70 * min(1, max(0, fraction))) }
                .accessibilityHidden(true)
            Text(value).font(.body).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 56, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A connection fact: the label in grey, the value monospaced (W4, W1c).
struct FactRow: View {
    let label: String
    let value: String
    var chevron = false
    var warning = false

    var body: some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(warning ? Color.caution : .primary).lineLimit(1).truncationMode(.middle)
            if chevron { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

/// A row of the sheet's connection list: label, value in grey, an optional swatch and chevron.
struct HostStatsListRow: View {
    let label: String
    let value: String
    var chevron = false
    var swatch: Color? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.body).foregroundStyle(Color.primary)
            Spacer()
            if let swatch { Circle().fill(swatch).frame(width: 14, height: 14).accessibilityHidden(true) }
            Text(value).font(.body).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The inset hairline between rows of a card.
struct HostStatsHairline: View {
    var inset: CGFloat = 16
    var body: some View {
        Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5).padding(.leading, inset)
    }
}

/// The host's disc, name and status line: the stats sheet's title, the popover's header.
struct HostStatsIdentity: View {
    let session: HostSession
    var line: String
    var live: Bool

    var body: some View {
        HStack(spacing: 10) {
            HostGlyph(host: session.host, size: 17)
                .foregroundStyle(session.host.tint.color)
                .frame(width: 34, height: 34)
                .background(session.host.tint.color.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.host.name).font(.headline).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(live ? Color.stateConnected : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                    Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
