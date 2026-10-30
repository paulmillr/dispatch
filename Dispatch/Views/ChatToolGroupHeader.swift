import SwiftUI

/// A tool group's header: a run chart of its steps, their count and time, and the reply time. Clicking it opens
/// every step. The children are rendered as separate lazy transcript rows, not in this view.
struct ChatToolGroupHeader: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: ChatToolGroup
    var replyTime: Date? = nil
    let disclosure: ChatToolGroupDisclosure
    /// The live turn's newest group: its steps animate in, and its time waits for the turn to end.
    var live = false
    @State private var settling = false
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                // A group that stops being live keeps the live chart while its color fades, then takes the static one
                // that draws the same bars.
                if live || settling {
                    ChatLiveStepChart(steps: group.steps, disclosure: disclosure, width: theme.typography.characterWidth * 16)
                } else {
                    ChatStepChart(steps: group.steps, disclosure: disclosure, width: theme.typography.characterWidth * 16)
                }
                // A live group's time waits for the turn to end, then fades in. (Its count doesn't roll: a numeric text
                // transition kept a live turn's CPU twice as high while the agent waited.)
                Text(Self.caption(count: group.children.count, elapsed: live ? nil : group.elapsed, radio: theme.radioLog)).fixedSize()
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: live)
                if let replyTime {
                    Spacer(minLength: 8)
                    ChatReplyTime(date: replyTime)
                }
            }
            .font(theme.typography.detail).foregroundStyle(theme.muted)
            .frame(maxWidth: .infinity, minHeight: theme.typography.detailLineHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .onChange(of: live) { old, new in settling = old && !new && !reduceMotion }
        .task(id: settling) {
            guard settling else { return }
            try? await Task.sleep(for: .milliseconds(400))
            settling = false
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.children.count) tool runs")
        .accessibilityValue(disclosure == .all ? "Expanded" : disclosure == .current ? "Current step" : "Collapsed")
        .accessibilityIdentifier("tool-group-header-\(group.id)")
    }

    /// "6 steps · 47s"; the time only when every step's is known.
    static func caption(count: Int, elapsed: TimeInterval?, radio: Bool) -> String {
        "\(count < 1000 ? String(count) : count.formatted()) \(noun(count, radio: radio))" + (elapsed.map { " · " + ChatTranscript.elapsed($0.rounded()) } ?? "")
    }

    /// Nautical logs a tool run as a manoeuvre.
    nonisolated static func noun(_ count: Int, radio: Bool) -> String {
        radio ? (count == 1 ? "manoeuvre" : "manoeuvres") : (count == 1 ? "step" : "steps")
    }

    /// The operations a step chart tells apart: edits and web browsing.
    nonisolated static func category(_ item: ChatItem) -> String? {
        switch ChatToolStep.kind(of: item) {
        case .edit: "Patch"
        case .web: "Browse web"
        case .other: nil
        }
    }
}

struct ChatReplyTime: View {
    @Environment(\.chatTheme) private var theme
    let date: Date

    var body: some View {
        Text(date, format: .dateTime.hour().minute())
            .font(theme.typography.detail).monospacedDigit()
            .foregroundStyle(theme.muted.opacity(0.75)).fixedSize()
            .accessibilityLabel("Reply time " + date.formatted(.dateTime.hour().minute()))
    }
}

/// A tool group's steps as a run chart: one bar each, as wide as its share of the group's time (all equal when a time
/// is unknown). Collapsed it stays grayscale, edits a shade stronger, so it doesn't compete with the message; opened
/// it takes the steps' colors; live, only the current step's bar does. Drawn as one filled shape per shade present
/// (a canvas would be its own layer in every header of a long history).
struct ChatStepChart: View {
    @Environment(\.chatTheme) private var theme
    let steps: [ChatToolStep]
    let disclosure: ChatToolGroupDisclosure
    var width: CGFloat
    var height: CGFloat = 6

    struct Bar: Equatable {
        let x: CGFloat
        let width: CGFloat
        let step: ChatToolStep
    }

    /// A bar's color, apart from the theme.
    enum Shade: Hashable, Sendable {
        case muted, mutedEdit, failed, edit, web, other

        nonisolated init(_ step: ChatToolStep, colored: Bool) {
            if !colored { self = step.kind == .edit ? .mutedEdit : .muted }
            else if step.failed { self = .failed }
            else {
                switch step.kind {
                case .edit: self = .edit
                case .web: self = .web
                case .other: self = .other
                }
            }
        }
    }

    var body: some View {
        // The bars once per header, grouped by shade: one filled shape each.
        let colored = Colored(disclosure), bars = Self.bars(steps, width: width)
        var shades: [Painted] = []
        for (index, bar) in bars.enumerated() {
            let shade = Shade(bar.step, colored: colored.colors(index, of: bars.count))
            let rect = CGRect(x: bar.x, y: 0, width: bar.width, height: height)
            if let at = shades.firstIndex(where: { $0.shade == shade }) { shades[at].rects.append(rect) }
            else { shades.append(Painted(shade: shade, rects: [rect])) }
        }
        return ZStack(alignment: .topLeading) {
            ForEach(shades, id: \.shade) { shade in
                Rects(rects: shade.rects).fill(Self.color(shade.shade, theme: theme))
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private struct Painted { let shade: Shade; var rects: [CGRect] }


    /// Bars laid out in the chart's own coordinates.
    private struct Rects: Shape {
        let rects: [CGRect]
        nonisolated func path(in rect: CGRect) -> Path {
            var path = Path()
            for bar in rects {
                let radius = min(1.5, bar.width / 2)
                path.addRoundedRect(in: bar.offsetBy(dx: rect.minX, dy: rect.minY), cornerSize: CGSize(width: radius, height: radius))
            }
            return path
        }
    }

    /// Which bars take their color: all (opened), the last (the live step), or none (collapsed).
    enum Colored: Equatable, Sendable {
        case all, last, none
        init(_ disclosure: ChatToolGroupDisclosure) {
            switch disclosure {
            case .all: self = .all
            case .current: self = .last
            case .collapsed: self = .none
            }
        }
        nonisolated func colors(_ index: Int, of count: Int) -> Bool { self == .all || (self == .last && index == count - 1) }
    }

    static func color(_ step: ChatToolStep, colored: Bool, theme: ChatTheme) -> Color {
        color(Shade(step, colored: colored), theme: theme)
    }

    static func color(_ shade: Shade, theme: ChatTheme) -> Color {
        switch shade {
        case .muted: theme.muted.opacity(0.32)
        case .mutedEdit: theme.muted.opacity(0.7)
        case .failed: theme.yellow  // as a failed tool's status and exit code
        case .edit: theme.accent
        case .web: theme.cyan
        case .other: theme.blue
        }
    }

    /// Bars at least `minimum` wide with `gap` between them, filling `width`. Steps beyond what fits share bars,
    /// consecutive ones together: a failure or an edit among them marks the shared bar.
    nonisolated static func bars(_ steps: [ChatToolStep], width: CGFloat, minimum: CGFloat = 3, gap: CGFloat = 2) -> [Bar] {
        guard !steps.isEmpty, width > 0 else { return [] }
        let capacity = max(1, Int((width + gap) / (minimum + gap)))
        let size = (steps.count + capacity - 1) / capacity
        let shown: [ChatToolStep] = size == 1 ? steps : stride(from: 0, to: steps.count, by: size).map { start in
            let slice = steps[start..<min(start + size, steps.count)]
            let kind: ChatToolStep.Kind = slice.contains { $0.kind == .edit } ? .edit : slice.contains { $0.kind == .web } ? .web : .other
            let seconds = slice.contains { $0.seconds == nil } ? nil : slice.reduce(0) { $0 + ($1.seconds ?? 0) }
            return ChatToolStep(kind: kind, failed: slice.contains(where: \.failed), seconds: seconds)
        }
        let total = shown.contains { $0.seconds == nil } ? 0 : shown.reduce(0) { $0 + ($1.seconds ?? 0) }
        let free = max(0, width - gap * CGFloat(shown.count - 1) - minimum * CGFloat(shown.count))
        var x: CGFloat = 0
        return shown.map { step in
            let share = total > 0 ? CGFloat((step.seconds ?? 0) / total) : 1 / CGFloat(shown.count)
            defer { x += minimum + free * share + gap }
            return Bar(x: x, width: minimum + free * share, step: step)
        }
    }
}

/// The live group's chart: a step that joins grows in at the end while the bars before it make room, so the chart
/// shows each step being added. Only the live group's header uses it (one per chat); finished headers stay static.
struct ChatLiveStepChart: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let steps: [ChatToolStep]
    let disclosure: ChatToolGroupDisclosure
    var width: CGFloat
    var height: CGFloat = 6
    /// The step count the bars grow from, and how far they have grown (0 → 1).
    @State private var from: Int?
    @State private var progress: Double = 1
    /// The bars last in color, which fade out over the gray when the chart stops coloring them (a turn ending).
    @State private var lit: ChatStepChart.Colored = .last

    var body: some View {
        let colored = ChatStepChart.Colored(disclosure)
        let target = ChatStepChart.bars(steps, width: width)
        let start = from.map { ChatStepChart.bars(Array(steps.prefix($0)), width: width) } ?? target
        // Every bar in gray, then the colored ones over it: a bar's color then fades rather than switching.
        return ZStack(alignment: .topLeading) {
            layer(start: start, target: target, colored: .none, only: false)
            layer(start: start, target: target, colored: colored == .none ? lit : colored, only: true)
                .opacity(colored == .none ? 0 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: colored)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .onChange(of: colored, initial: true) { _, new in if new != .none { lit = new } }
        .onChange(of: steps.count) { old, new in
            guard new > old, !reduceMotion else { from = nil; progress = 1; return }
            from = old; progress = 0
            // Linear in time: each new bar eases on its own clock, a burst's one after another.
            withAnimation(.linear(duration: Growing.duration(adding: new - old))) { progress = 1 }
        }
        .accessibilityHidden(true)
    }

    /// One filled shape per shade present: every bar, or only those `colored` colors.
    private func layer(start: [ChatStepChart.Bar], target: [ChatStepChart.Bar], colored: ChatStepChart.Colored, only: Bool) -> some View {
        var shades: [ChatStepChart.Shade] = []
        for (index, bar) in target.enumerated() where !only || colored.colors(index, of: target.count) {
            let shade = ChatStepChart.Shade(bar.step, colored: colored.colors(index, of: target.count))
            if !shades.contains(shade) { shades.append(shade) }
        }
        return ForEach(shades, id: \.self) { shade in
            Growing(start: start, target: target, colored: colored, shade: shade, only: only, height: height, progress: progress)
                .fill(ChatStepChart.color(shade, theme: theme))
        }
    }

    /// The bars of one shade between the layout before the new steps and the layout with them: bars that stay move and
    /// resize, new ones grow from nothing at the end, each a beat after the one before, so a burst of steps reads as
    /// that many. A regrouping of crowded bars just shows the new layout.
    private struct Growing: Shape {
        /// One bar's growth, and the beat between a burst's bars (shortened so a long burst stays brief).
        nonisolated static let growth = 0.45, beat = 0.07
        nonisolated static func stagger(_ added: Int) -> Double { added > 1 ? min(beat, 0.3 / Double(added - 1)) : 0 }
        nonisolated static func duration(adding added: Int) -> Double { growth + stagger(added) * Double(max(0, added - 1)) }
        nonisolated static func easeOut(_ t: CGFloat) -> CGFloat { 1 - pow(1 - min(1, max(0, t)), 3) }

        let start: [ChatStepChart.Bar], target: [ChatStepChart.Bar]
        let colored: ChatStepChart.Colored, shade: ChatStepChart.Shade
        /// Only the bars `colored` colors.
        let only: Bool
        let height: CGFloat
        var progress: Double
        nonisolated var animatableData: Double {
            get { progress }
            set { progress = newValue }
        }

        nonisolated func path(in rect: CGRect) -> Path {
            var path = Path()
            let regrouped = start.count > target.count, added = target.count - start.count
            let duration = Self.duration(adding: added), beat = Self.stagger(added) / duration
            let clock = CGFloat(progress), t = Self.easeOut(clock)
            let end = start.last.map { $0.x + $0.width } ?? 0
            for (index, bar) in target.enumerated() where !only || colored.colors(index, of: target.count) {
                guard ChatStepChart.Shade(bar.step, colored: colored.colors(index, of: target.count)) == shade else { continue }
                var x = bar.x, width = bar.width
                if !regrouped, clock < 1 {
                    if index < start.count {
                        x = start[index].x + (bar.x - start[index].x) * t
                        width = start[index].width + (bar.width - start[index].width) * t
                    } else {
                        let grown = Self.easeOut((clock - CGFloat(index - start.count) * beat) * duration / Self.growth)
                        x = end + (bar.x - end) * t
                        width = bar.width * grown
                    }
                }
                guard width > 0.01 else { continue }
                let radius = min(1.5, width / 2)
                path.addRoundedRect(in: CGRect(x: rect.minX + x, y: rect.minY, width: width, height: height),
                                    cornerSize: CGSize(width: radius, height: radius))
            }
            return path
        }
    }
}

/// A shown step's place on its group's timeline: a dot in its kind's color on a line to the steps before and after.
/// Each step is its own transcript row, so each draws its part of the line, out into the row padding between them.
struct ChatStepRail: View {
    @Environment(\.chatTheme) private var theme
    let timeline: ChatTranscriptRow.Timeline
    /// The row padding above and below that the line crosses to meet its neighbours'.
    var overhang: CGFloat = 3
    static let width: CGFloat = 10

    var body: some View {
        // Level with the step's header line (ChatToolCard's embedded header: 3 + 1 points above its text).
        let center = 4 + theme.typography.detailLineHeight / 2
        let color = ChatStepChart.color(timeline.step, colored: true, theme: theme)
        // Two shapes that take the row's height (the rail overlays its step), no geometry reader: the line stops at
        // the dot's ring, so an open ring needs no fill to hide it.
        ZStack {
            Line(first: timeline.first, last: timeline.last, center: center, overhang: overhang).fill(theme.border)
            Dot(center: center, filled: timeline.current).fill(color, style: FillStyle(eoFill: true))
        }
        .frame(width: Self.width)
        .accessibilityHidden(true)
    }

    /// The line to the steps before and after, out into the row padding between them, broken by the dot.
    private struct Line: Shape {
        let first: Bool, last: Bool, center: CGFloat, overhang: CGFloat
        nonisolated func path(in rect: CGRect) -> Path {
            var path = Path()
            let x = rect.midX - 0.75, top = rect.minY + center - Dot.radius, bottom = rect.minY + center + Dot.radius
            if !first { path.addRect(CGRect(x: x, y: rect.minY - overhang, width: 1.5, height: top - rect.minY + overhang)) }
            if !last { path.addRect(CGRect(x: x, y: bottom, width: 1.5, height: rect.maxY + overhang - bottom)) }
            return path
        }
    }

    /// The step's dot, level with its header line: a disc for the current step, a ring for the others.
    private struct Dot: Shape {
        static let radius: CGFloat = 4
        let center: CGFloat, filled: Bool
        nonisolated func path(in rect: CGRect) -> Path {
            let outer = CGRect(x: rect.midX - Self.radius, y: rect.minY + center - Self.radius, width: Self.radius * 2, height: Self.radius * 2)
            var path = Path(ellipseIn: outer)
            if !filled { path.addEllipse(in: outer.insetBy(dx: 1.5, dy: 1.5)) }
            return path
        }
    }
}
