import SwiftUI

/// The host sheet on a phone's side (L19, docs/ios.md, The host sheet): a chart screen in the landscape tabs' chrome.
/// No header row: one rail on the Dynamic Island's side (`MobileLandscape.railEdge`, its glass 2 points clear of the
/// island, `railInset`) with Close and the host's disc (its facts and the action behind it, with a tab menu disc's ⋯ badge) at the top and Edit at
/// its foot, + above Edit while the host can take a space; the content runs into the other side's inset to 12 points
/// from the glass. The host's name shows as a capsule for 2.5 s as the screen opens (`MobileLandscape.titleDuration`),
/// as a tab's does. The content: CPU, Memory and Disk in a row, then CPU and memory in one chart on one 0–100% axis
/// (memory as a share of the host's), the gridlines' values inside it, the last 15 minutes along the bottom; a drag
/// reads both at a bar's time. The processes are the upright sheet's.
struct HostStatsLandscape: View {
    let session: HostSession
    @Binding var editing: Bool
    var newSpace: HostNewSpace?
    let close: @MainActor () -> Void

    @State private var scrub: Int?
    @State private var titleShown = true
    @State private var facts = false
    @State private var edge: HorizontalEdge = .leading
    @State private var island: CGFloat = MobileLandscape.defaultIsland
    @ReduceMotion private var reduceMotion

    var body: some View {
        let presentation = HostStatsPresentation(session: session)
        HStack(spacing: 10) {
            if edge == .leading { rail(presentation) }
            content(presentation)
            if edge == .trailing { rail(presentation) }
        }
        .padding(.leading, edge == .leading ? MobileLandscape.railInset(island: island) : MobileLandscape.contentInset)
        .padding(.trailing, edge == .trailing ? MobileLandscape.railInset(island: island) : MobileLandscape.contentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .horizontal)
        .background(Color.canvas.ignoresSafeArea())
        .overlay(alignment: .top) {
            if titleShown {
                // A tab's title capsule as it opens: over the chart's empty top, under the row it would cover.
                HostStatsIdentity(session: session, line: presentation.line, live: presentation.phase == .live)
                    .padding(.leading, 4).padding(.trailing, 16)
                    .frame(minHeight: 44)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.top, 62)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .background { MobileOrientationReader { edge = MobileLandscape.railEdge($0) }.allowsHitTesting(false) }
        .background { MobileWindowReader { _, depth in island = depth }.allowsHitTesting(false) }
        .task {
            try? await Task.sleep(for: MobileLandscape.titleDuration)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { titleShown = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("host-stats-landscape")
    }

    // MARK: Rail

    private func rail(_ presentation: HostStatsPresentation) -> some View {
        VStack(spacing: 8) {
            disc("xmark", label: "Close", action: close)
            Button { facts = true } label: {
                HostGlyph(host: session.host, size: 19)
                    .foregroundStyle(session.host.tint.color)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(facts ? .regular.tint(session.host.tint.color.opacity(0.35)).interactive() : .regular.interactive(), in: Circle())
            // The ⋯ badge of a tab's menu disc: what is behind it is the host's.
            .overlay(alignment: .bottomTrailing) { TabHeaderMenuBadge().offset(x: 2, y: 2) }
            .accessibilityLabel(session.host.name)
            .accessibilityValue(presentation.line)
            .accessibilityHint("Shows the host's address, key and multiplexer")
            .accessibilityIdentifier("host-stats-facts")
            .popover(isPresented: $facts) {
                HostStatsFacts(session: session)
                    .presentationCompactAdaptation(.popover)
            }
            Spacer(minLength: MobileLandscape.railGap)
            if let newSpace, newSpace.offered(session.id) {
                HostNewSpaceButton(hostID: session.id, newSpace: newSpace, dismiss: close)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            disc("pencil", label: "Edit") { editing = true }
        }
        .frame(width: MobileLandscape.railWidth)
        .padding(.vertical, MobileLandscape.railMargin)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("host-stats-rail")
    }

    private func disc(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(label)
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ presentation: HostStatsPresentation) -> some View {
        if presentation.phase == .plain {
            VStack {
                Spacer(minLength: 0)
                HostPlainStatsCard(session: session).frame(maxWidth: 520)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        } else {
            let stats = session.stats
            let dimmed = presentation.phase != .live || !stats.live
            // The grid steps every 15 s while nothing comes; each sample redraws at its own time (`StatStripCard`).
            TimelineView(.periodic(from: .now, by: HostStatistics.barSpan)) { context in
                let now = StatStripCard.chartDate(context.date, stats: stats)
                VStack(alignment: .leading, spacing: 6) {
                    legend(stats, presentation: presentation, now: now)
                    HostStatsChart(cpu: stats.bars(.cpu, at: now), memory: stats.bars(.memory, at: now),
                                   cpuColor: session.host.tint.color, live: stats.live,
                                   memoryTotal: stats.sample?.memoryTotal, now: now, scrub: $scrub)
                        .accessibilityElement()
                        .accessibilityLabel("CPU and memory, last 15 minutes")
                        .accessibilityValue(Self.chartValue(stats, at: now))
                        .accessibilityIdentifier("host-stats-chart")
                }
                .opacity(dimmed ? 0.5 : 1)
            }
            .padding(.top, 8).padding(.bottom, 4)
        }
    }

    /// "CPU now 34%, peak 82% · avg 31%. Memory now 34%, …" for VoiceOver.
    static func chartValue(_ stats: HostStatistics, at now: Date) -> String {
        HostStatistics.Metric.allCases.map { metric in
            "\(metric.title) " + StatStripCard.chartValue(stats.bars(metric, at: now), peak: stats.peak(metric, at: now),
                                                          average: stats.average(metric, at: now))
        }.joined(separator: ". ")
    }

    private func legend(_ stats: HostStatistics, presentation: HostStatsPresentation, now: Date) -> some View {
        let sample = stats.sample
        let memory = HostStatsFormat.size(sample?.memoryUsed)
        let free = HostStatsFormat.size(stats.disk?.free)
        let cpuPeak = stats.peak(.cpu, at: now).map { "peak \(HostStatsFormat.percent($0))%" }
        var memoryPeak: String?
        if let peak = stats.peak(.memory, at: now), let total = sample?.memoryTotal {
            memoryPeak = "peak " + HostStatsFormat.sizeText(UInt64(Double(total) * peak / 100))
        }
        return HStack(alignment: .bottom, spacing: 32) {
            HostStatsLegendItem(title: "CPU", swatch: session.host.tint.color, value: HostStatsFormat.percent(sample?.cpu),
                                unit: "%", sub: [HostStatsFormat.load(sample?.load), cpuPeak].compactMap { $0 }.joined(separator: " · "),
                                warn: HostStatsFormat.cpuHigh(sample?.cpu))
            HostStatsLegendItem(title: "Memory", swatch: HostStatsChart.memoryColor, value: memory.value, unit: memory.unit,
                                sub: [sample?.memoryTotal.map { "of \(HostStatsFormat.sizeText($0))" }, memoryPeak]
                                    .compactMap { $0 }.joined(separator: " · "),
                                warn: HostStatsFormat.memoryHigh(sample?.memoryPercent))
            // The disk beside them, no swatch: it has no line in the chart.
            HostStatsLegendItem(title: "Disk", swatch: nil, value: free.value, unit: free.unit,
                                sub: stats.disk?.usedPercent.map { "free · \(HostStatsFormat.percent($0))% used" } ?? "free",
                                warn: HostStatsFormat.diskHigh(stats.disk?.usedPercent))
            Spacer(minLength: 8)
            // Offline or under Low Power Mode, the line says so where the chart's span is said.
            if let banner = presentation.offlineBanner ?? presentation.lowPowerBanner {
                Label(banner, systemImage: presentation.offlineBanner != nil ? "wifi.slash" : "battery.25percent")
                    .font(.caption)
                    .foregroundStyle(presentation.offlineBanner != nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.caution))
                    .lineLimit(1)
            } else {
                Text("Last 15 min").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

/// One block of the landscape legend: its swatch and name, the value large, one quiet line after it.
struct HostStatsLegendItem: View {
    let title: String
    let swatch: Color?
    let value: String
    let unit: String
    let sub: String
    var warn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                if let swatch { Capsule().fill(swatch).frame(width: 12, height: 4) }
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(warn ? Color.destructive : .primary)
                Text(unit).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(sub).font(.caption).foregroundStyle(.tertiary).padding(.leading, 6)
            }
            .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value) \(unit), \(sub)")
    }
}

/// CPU and memory over the last 15 minutes in one chart (L19): both on one 0–100% axis, memory's fill fainter under
/// CPU's, each broken where a bar has no sample; the gridlines' values inside it at the leading edge; the times along
/// the bottom. A drag reads a bar: a rule, a dot on each line and both values with the bar's time.
struct HostStatsChart: View {
    let cpu: [Double?]
    let memory: [Double?]
    let cpuColor: Color
    var live = true
    /// The host's memory, to read a bar's share in bytes.
    var memoryTotal: UInt64?
    let now: Date
    @Binding var scrub: Int?

    /// Memory's line: a soft lavender beside the host's colour (the system purple read as magenta beside it).
    static let memoryColor = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.66, green: 0.58, blue: 0.94, alpha: 1)
            : UIColor(red: 0.45, green: 0.36, blue: 0.80, alpha: 1)
    })

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let size = proxy.size
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        grid(in: &context, size: size)
                        plot(memory, color: Self.memoryColor, fill: 0.18, in: &context, size: size)
                        plot(cpu, color: cpuColor, fill: 0.3, in: &context, size: size)
                        if let scrub { rule(at: scrub, in: &context, size: size) }
                    }
                    ForEach(Array(["0%", "50%", "100%"].enumerated()), id: \.offset) { index, label in
                        let y = size.height * (1 - Double(index) / 2)
                        Text(label).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                            .fixedSize()
                            // Over its line; the top one under it.
                            .position(x: 18, y: y + (index == 2 ? 9 : -9))
                    }
                    if let scrub, cpu.indices.contains(scrub) {
                        readout(scrub)
                            .fixedSize()
                            .position(x: min(max(x(scrub, width: size.width), 80), size.width - 80), y: 32)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let index = Sparkline.index(at: value.location.x, width: size.width, count: cpu.count)
                        if scrub != index { scrub = index }
                    }
                    .onEnded { _ in scrub = nil })
            }
            GeometryReader { proxy in
                ForEach(Array(["15 min ago", "10 min", "5 min", "now"].enumerated()), id: \.offset) { index, label in
                    Text(label).font(.caption2).foregroundStyle(.tertiary).fixedSize()
                        .position(x: index == 0 ? 30 : index == 3 ? proxy.size.width - 12 : proxy.size.width * Double(index) / 3, y: 7)
                }
            }
            .frame(height: 14)
            .accessibilityHidden(true)
        }
    }

    private func x(_ index: Int, width: CGFloat) -> CGFloat { width * CGFloat(index) / CGFloat(max(1, cpu.count - 1)) }

    private func grid(in context: inout GraphicsContext, size: CGSize) {
        for line in 0..<3 {
            let y = size.height * (1 - Double(line) / 2)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(Color(uiColor: .separator)),
                           style: StrokeStyle(lineWidth: 0.5, dash: line == 0 ? [] : [3, 3]))
        }
    }

    private func plot(_ bars: [Double?], color: Color, fill: Double, in context: inout GraphicsContext, size: CGSize) {
        let segments = Sparkline.segments(bars, size: size)
        for points in segments {
            var line = Path()
            line.move(to: points[0])
            for point in points.dropFirst() { line.addLine(to: point) }
            if points.count == 1 { line.addLine(to: CGPoint(x: points[0].x + 1, y: points[0].y)) }
            var area = line
            area.addLine(to: CGPoint(x: points.last!.x, y: size.height))
            area.addLine(to: CGPoint(x: points[0].x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(fill), color.opacity(0.02)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        if live, bars.last.flatMap({ $0 }) != nil, let last = segments.last?.last {
            context.fill(Path(ellipseIn: CGRect(x: last.x - 4, y: last.y - 4, width: 8, height: 8)), with: .color(color))
        }
    }

    private func rule(at index: Int, in context: inout GraphicsContext, size: CGSize) {
        guard cpu.indices.contains(index) else { return }
        let x = x(index, width: size.width)
        var rule = Path()
        rule.move(to: CGPoint(x: x, y: 0))
        rule.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(rule, with: .color(.secondary), lineWidth: 1)
        for (bars, color) in [(memory, Self.memoryColor), (cpu, cpuColor)] {
            guard bars.indices.contains(index), let value = bars[index] else { continue }
            let y = size.height - size.height * CGFloat(min(100, max(0, value))) / 100
            context.fill(Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10)), with: .color(color))
        }
    }

    /// The bar's time and both values: "2:41 PM", "CPU 62%", "Memory 8.1 GB" (no sample: "—").
    private func readout(_ index: Int) -> some View {
        let cpuText = cpu[index].map { "\(HostStatsFormat.percent($0))%" } ?? "—"
        let memoryText = memory.indices.contains(index) ? memory[index].map { percent in
            memoryTotal.map { HostStatsFormat.sizeText(UInt64(Double($0) * percent / 100)) } ?? "\(HostStatsFormat.percent(percent))%"
        } ?? "—" : "—"
        return VStack(alignment: .leading, spacing: 1) {
            Text(HostStatsFormat.time(HostStatistics.barStart(index, at: now, count: cpu.count)))
                .font(.caption2).foregroundStyle(.secondary)
            reading("CPU", cpuText, color: cpuColor)
            reading("Memory", memoryText, color: Self.memoryColor)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }

    private func reading(_ title: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }
}

/// The popover of the host's disc (L19c): what the upright sheet's title, banners and connection list say, and its
/// one action.
struct HostStatsFacts: View {
    let session: HostSession
    /// The content's height: the popover is as tall as what it holds.
    @State private var height: CGFloat = 300

    var body: some View {
        let presentation = HostStatsPresentation(session: session)
        // In a stack for the multiplexer row's install hint.
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HostStatsIdentity(session: session, line: presentation.line, live: presentation.phase == .live)
                if let banner = presentation.offlineBanner {
                    HostStatsBanner(text: banner, symbol: session.link.isPending ? "arrow.triangle.2.circlepath" : "wifi.slash")
                }
                HostConnectionList(session: session)
                HostStatsAction(session: session)
            }
            .padding(16)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
            .frame(maxHeight: .infinity, alignment: .top)
            .toolbar(.hidden, for: .navigationBar)
        }
        .frame(width: 340, height: height)
        .tint(.dispatchPink)
    }
}
