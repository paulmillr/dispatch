import SwiftUI

extension View {
    @ViewBuilder func fittedPopoverPresentation() -> some View {
        if #available(macOS 15, *) {
            presentationSizing(.fitted)
        } else {
            self
        }
    }
}

private struct FittingPopoverHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct FittingPopoverContent<Content: View>: View {
    let maxHeight: CGFloat
    let content: Content
    @State private var idealHeight: CGFloat = 0

    init(maxHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight
        self.content = content()
    }

    var body: some View {
        Group {
            if idealHeight > maxHeight + 0.5 {
                overflowContent.frame(height: maxHeight)
            } else {
                measuredContent
            }
        }.frame(maxHeight: maxHeight)
        .onPreferenceChange(FittingPopoverHeightKey.self) { height in
            if abs(height - idealHeight) > 0.5 { idealHeight = height }
        }
    }

    private var measuredContent: some View {
        content.fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: FittingPopoverHeightKey.self, value: geometry.size.height)
                }
            }
    }

    @ViewBuilder private var overflowContent: some View {
        if #available(macOS 26, *) {
            ScrollView { measuredContent }
                .scrollEdgeEffectHidden()
        } else {
            ScrollView { measuredContent }
        }
    }
}

/// Local and authorized SSH statistics share the same presentation and sampler.
struct HostStatsView: View {
    var host: HostRecord = .local
    var preferred: SSHConnectionID? = nil
    @State private var selected: SSHStatisticsStore.Key?
    var stats = HostStats.shared
    var samplesAutomatically = true
    var showsIdentity = true
    var sourceChanged: ((HostStatisticsStore.Source) -> Void)? = nil

    private var store: HostStatisticsStore { HostStatisticsStore(local: stats) }
    private var source: HostStatisticsStore.Source { store.source(host: host.id, preferred: preferred, selected: selected) }
    private var accounts: [SSHStatisticsStore.Key] { store.remote.keys(for: host.id) }

    var body: some View {
        // Materialize once per update. Each label and chart then reads the same
        // snapshot without repeatedly copying an hour of history.
        HostStatsPresentation(host: host, sample: store.snapshot(source), source: source, accounts: accounts,
            accountLabels: Dictionary(uniqueKeysWithValues: accounts.map { key in
                let scope = store.remote.series[key]!.scope
                return (key, "\(scope.account) · \(scope.destination)")
            }), selected: $selected, showsIdentity: showsIdentity)
        .onChange(of: source, initial: true) { _, source in sourceChanged?(source) }
        .task(id: source) {
            // Keep the chosen account after its terminal disconnects. A new
            // account is selected only by the user, never as failover.
            if case .ssh(let key) = source { selected = key }
            guard samplesAutomatically, let subscription = store.subscribe(source, preferred: preferred) else { return }
            let latencyKey: SSHStatisticsStore.Key? = if showsIdentity, case .ssh(let key) = source { key } else { nil }
            let latencyToken = latencyKey.flatMap { store.remote.subscribeLatency($0, preferred: preferred) }
            defer {
                store.unsubscribe(subscription)
                if let latencyKey, let latencyToken { store.remote.unsubscribeLatency(latencyToken, from: latencyKey) }
            }
            do { while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) } } catch {}
        }
    }
}

struct LocalHostStatsPopover: View {
    @Environment(\.appTypography) private var typography
    var stats = HostStats.shared
    var samplesAutomatically = true

    var body: some View {
        HostStatsView(stats: stats, samplesAutomatically: samplesAutomatically)
            .frame(width: typography.expanded(356))
            .preferredColorScheme(Chrome.colorScheme)
            .fittedPopoverPresentation()
    }
}

private struct HostStatsPresentation: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let host: HostRecord
    let sample: HostStatisticsSnapshot
    let source: HostStatisticsStore.Source
    let accounts: [SSHStatisticsStore.Key]
    let accountLabels: [SSHStatisticsStore.Key: String]
    @Binding var selected: SSHStatisticsStore.Key?
    let showsIdentity: Bool
    private enum Metric { case cpu, memory }
    @State private var selectedMetric: Metric?
    private var memorySelected: Bool { selectedMetric == .memory }
    private let accent = Color(red: 126/255, green: 166/255, blue: 201/255)
    var body: some View {
        Group {
            if showsIdentity {
                FittingPopoverContent(maxHeight: typography.popoverHeight(620)) { popoverContent }
            } else {
                popoverContent.fixedSize(horizontal: false, vertical: true)
            }
        }
            .font(typography.font(offset: -0.5))
            .foregroundStyle(Chrome.ink)
            .statsPopoverBackground()
            .accessibilityIdentifier("host-stats-popover")
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsIdentity {
                HostIdentityHeader(host: host, state: sample.state == .ready ? .connected : .disconnected,
                    latency: { if case .ssh(let key) = source { SSHStatisticsStore.shared.series[key]?.latency } else { nil } }())
            }
            statusAndAccount
            if showsIdentity { HStack {
                Text("host").foregroundStyle(StatsStyle.muted)
                Spacer()
                Text(sample.host).textSelection(.enabled)
            }.font(typography.font(offset: -0.5)).padding(.vertical, 8)
                .overlay(alignment: .top) { if !StatsStyle.glass { Rectangle().fill(StatsStyle.track).frame(height: 1) } } }
            if sample.state == .unavailable {
                statisticsContent.hidden().overlay {
                    Text("Stats unavailable")
                        .font(typography.font(offset: 3.5, weight: .medium))
                        .foregroundStyle(StatsStyle.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("stats-unavailable")
                }
            } else {
                statisticsContent
            }
        }.padding(.horizontal, showsIdentity ? 18 : 0).padding(.vertical, showsIdentity ? 16 : 0)
    }

    private var statisticsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                metricButton(memory: false, title: "cpu", value: sample.cpu,
                    detail: sample.load?.first.map { String(format: "%.2f load", $0) } ?? "load unavailable")
                metricButton(memory: true, title: "mem", value: sample.memoryPercent,
                    detail: "\(gib(sample.memoryUsed)) / \(gib(sample.memoryTotal)) G")
                HostMetricSummary(title: "disk", value: sample.diskPercent,
                    detail: "\(gib(sample.diskFree)) G free", warning: (sample.diskPercent ?? 0) > 80)
            }
            if selectedMetric != nil {
                topProcesses
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            metricHistory
        }
    }

    private var topProcesses: some View {
        VStack(alignment: .leading, spacing: 4) {
            let rows = Array((memorySelected ? sample.topMemory : sample.topCPU).prefix(3))
            HStack(spacing: 6) {
                Text("top processes")
                if sample.processesPartial { Text("· partial").accessibilityIdentifier("stats-processes-partial") }
            }.font(typography.font(offset: -1.5)).foregroundStyle(StatsStyle.muted)
            processes(rows).overlay(alignment: .topLeading) {
                if rows.isEmpty {
                    Text(sample.processes?.isEmpty == false ? "Measuring process CPU…" : "Process data unavailable")
                        .font(typography.font(offset: -1)).foregroundStyle(StatsStyle.muted)
                        .padding(.vertical, 4)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusAndAccount: some View {
        if accounts.count > 1 {
            Picker("Account", selection: Binding(get: {
                if case .ssh(let key) = source { return key }
                return accounts[0]
            }, set: { selected = $0 })) {
                ForEach(accounts, id: \.self) { key in
                    Text(accountLabels[key] ?? key.host).tag(key)
                }
            }.pickerStyle(.menu).accessibilityIdentifier("stats-account")
        }
        if sample.state != .unavailable, let status = sample.statusText {
            Text(status).font(typography.font(offset: -1.5)).foregroundStyle(StatsStyle.muted)
                .accessibilityIdentifier("stats-status")
        }
    }

    private func gib(_ bytes: UInt64?) -> String { HostStatisticsSnapshot.gib(bytes) }

    private func processes(_ rows: [HostProcess]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Keep three real text-line slots, including before the first sample.
            // Hidden blank lines use the same font and padding as populated rows.
            ForEach(0..<3) { index in
                HStack(spacing: 8) {
                    if index < rows.count {
                        let process = rows[index]
                        Text(process.name).lineLimit(1).truncationMode(.middle).help(process.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(memorySelected ? "\(gib(process.memory)) G" : process.cpu.map { String(format: "%.1f%%", $0) } ?? "—")
                            .foregroundStyle(StatsStyle.secondary)
                            .fixedSize()
                    } else {
                        Text(" ").frame(maxWidth: .infinity, alignment: .leading).hidden()
                    }
                }
                .font(typography.font(offset: -1)).monospacedDigit()
                .padding(.vertical, 4)
                .overlay(alignment: .top) {
                    if index < rows.count { Rectangle().fill(StatsStyle.track).frame(height: 1) }
                }
                .accessibilityHidden(index >= rows.count)
            }
        }
    }

    private func metricButton(memory: Bool, title: String, value: Double?, detail: String) -> some View {
        let metric: Metric = memory ? .memory : .cpu
        return Button {
            withAnimation(InterfaceMotion.animation(reduce: reduceMotion)) {
                selectedMetric = selectedMetric == metric ? nil : metric
            }
        } label: {
            HostMetricSummary(title: title, value: value, detail: detail,
                              selectionColor: selectedMetric == metric ? accent : nil)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(memory ? "Show memory processes and history" : "Show CPU processes and history")
            .accessibilityIdentifier(memory ? "stats-select-memory" : "stats-select-cpu")
            .accessibilityAddTraits(selectedMetric == metric ? .isSelected : [])
    }

    private var metricHistory: some View {
        TimelineView(.periodic(from: .distantPast, by: 2)) { timeline in
            let points = sample.historySegments(memory: memorySelected, at: timeline.date).flatMap { $0 }
            VStack(alignment: .leading, spacing: 5) {
                Text("15-min history")
                    .foregroundStyle(StatsStyle.muted).font(typography.font(offset: -1.5))
                Canvas { context, size in
                    // One bar per 15-second bucket; missing samples stay empty.
                    let count = 60
                    var buckets = [Int: Double]()
                    for point in points {
                        guard let value = memorySelected ? point.memoryPercent : point.cpu else { continue }
                        let position = 1 + point.date.timeIntervalSince(timeline.date) / HostStatisticsSnapshot.historyWindow
                        let index = min(count - 1, max(0, Int(position * Double(count))))
                        buckets[index] = max(buckets[index] ?? 0, min(100, max(0, value)))
                    }
                    let width = size.width / Double(count)
                    for (index, value) in buckets {
                        let height = max(1, size.height * value / 100)
                        let rect = CGRect(x: Double(index) * width, y: size.height - height,
                                          width: max(1, width - 1), height: height)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1),
                                     with: .color(index == count - 1 ? StatsStyle.secondary : accent.opacity(0.45)))
                    }
                }.frame(height: 28)
                    .accessibilityLabel(memorySelected ? "Memory history, last 15 minutes" : "CPU history, last 15 minutes")
            }
        }.accessibilityIdentifier(memorySelected ? "stats-memory-history" : "stats-cpu-history")
    }

}

private struct HostMetricSummary: View {
    @Environment(\.appTypography) private var typography
    let title: String
    let value: Double?
    let detail: String
    var warning = false
    var selectionColor: Color? = nil
    private var valueColor: Color { warning ? StatsStyle.warning : selectionColor ?? Chrome.ink }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(typography.font(offset: -1.5)).foregroundStyle(warning ? StatsStyle.warning : selectionColor ?? StatsStyle.muted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.map { String(format: "%.0f", $0) } ?? "—").font(typography.font(offset: 13.5, weight: .medium))
                    .tracking(-0.52).foregroundStyle(valueColor)
                Text("%").font(typography.font(offset: -1.5)).foregroundStyle(StatsStyle.muted)
            }.monospacedDigit().fixedSize()
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 2).fill(warning ? StatsStyle.warning : selectionColor ?? StatsStyle.secondary)
                    .frame(width: geometry.size.width * min(100, max(0, value ?? 0)) / 100)
            }.frame(height: 3).background(StatsStyle.track, in: RoundedRectangle(cornerRadius: 2))
                .accessibilityHidden(true)
            detailText
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detailText: some View {
        Text(detail).font(typography.font(offset: -1.5))
            .foregroundStyle(StatsStyle.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor enum StatsStyle {
    /// The host popovers sit on the system popover's own glass: no ground of their own, the system's label colors
    /// (tuned for glass) instead of grays picked for the flat card, and capsules rather than small rounded rects.
    static var glass: Bool { LiquidGlassStore.shared.active }
    static var muted: Color {
        if glass { return Color(nsColor: .tertiaryLabelColor) }
        return Chrome.palette.isDark ? Color(red: 111/255, green: 111/255, blue: 120/255) : Chrome.muted
    }
    static var secondary: Color {
        if glass { return Color(nsColor: .secondaryLabelColor) }
        return Chrome.palette.isDark ? Color(red: 154/255, green: 154/255, blue: 162/255) : Chrome.palette.secondary
    }
    static var faint: Color { Chrome.palette.faint }
    static var warning: Color { Chrome.palette.isDark ? Color(red: 224/255, green: 123/255, blue: 123/255) : .red }
    static var track: Color {
        if glass { return Color(nsColor: .quaternaryLabelColor) }
        return Chrome.palette.isDark ? Color(red: 38/255, green: 38/255, blue: 43/255) : Chrome.palette.control
    }
    static var rowBorder: Color { Chrome.palette.separator }
    static var popover: Color { Chrome.palette.isDark ? Color(red: 26/255, green: 26/255, blue: 30/255) : Chrome.window }
    /// Badges and hover highlights inside the popovers; on glass the radius clamps to half the height, a capsule.
    static func chip(radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: glass ? 999 : radius)
    }
}

extension View {
    /// A host popover's ground: the flat card, or nothing on Liquid Glass so the popover's glass (and its arrow)
    /// reads as one piece.
    @ViewBuilder func statsPopoverBackground() -> some View {
        if StatsStyle.glass { self } else { background(StatsStyle.popover) }
    }
}
