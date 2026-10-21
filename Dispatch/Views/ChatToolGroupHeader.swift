import SwiftUI

/// A tool group's header: a run chart of its steps, their count and time, and the reply time. Clicking it opens
/// every step. The children are rendered as separate lazy transcript rows, not in this view.
struct ChatToolGroupHeader: View {
    @Environment(\.chatTheme) private var theme
    let group: ChatToolGroup
    var replyTime: Date? = nil
    let disclosure: ChatToolGroupDisclosure
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                ChatStepChart(steps: group.steps, disclosure: disclosure)
                    .frame(width: theme.typography.characterWidth * 16, height: 6)
                Text(Self.caption(count: group.children.count, elapsed: group.elapsed, radio: theme.radioLog)).fixedSize()
                if let replyTime {
                    Spacer(minLength: 8)
                    ChatReplyTime(date: replyTime)
                }
            }
            .font(theme.typography.detail).foregroundStyle(theme.muted)
            .frame(maxWidth: .infinity, minHeight: theme.typography.detailLineHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.children.count) tool runs")
        .accessibilityValue(disclosure == .all ? "Expanded" : disclosure == .current ? "Current step" : "Collapsed")
        .accessibilityIdentifier("tool-group-header-\(group.id)")
    }

    /// "6 steps · 47s"; the time only when every step's is known.
    static func caption(count: Int, elapsed: TimeInterval?, radio: Bool) -> String {
        "\(count.formatted()) \(noun(count, radio: radio))" + (elapsed.map { " · " + ChatTranscript.elapsed($0.rounded()) } ?? "")
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
/// it takes the steps' colors; live, only the current step's bar does. One canvas per header, whatever the count.
struct ChatStepChart: View {
    @Environment(\.chatTheme) private var theme
    let steps: [ChatToolStep]
    let disclosure: ChatToolGroupDisclosure

    struct Bar: Equatable {
        let x: CGFloat
        let width: CGFloat
        let step: ChatToolStep
    }

    var body: some View {
        let theme = theme, disclosure = disclosure, steps = steps
        Canvas { context, size in
            let bars = Self.bars(steps, width: size.width)
            for (index, bar) in bars.enumerated() {
                let colored = disclosure == .all || (disclosure == .current && index == bars.count - 1)
                let rect = CGRect(x: bar.x, y: 0, width: bar.width, height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: min(1.5, bar.width / 2)),
                             with: .color(Self.color(bar.step, colored: colored, theme: theme)))
            }
        }
        .accessibilityHidden(true)
    }

    static func color(_ step: ChatToolStep, colored: Bool, theme: ChatTheme) -> Color {
        guard colored else { return theme.muted.opacity(step.kind == .edit ? 0.7 : 0.32) }
        if step.failed { return theme.yellow }  // as a failed tool's status and exit code
        switch step.kind {
        case .edit: return theme.accent
        case .web: return theme.cyan
        case .other: return theme.blue
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
        let center = 4 + theme.typography.detailLineHeight / 2, x = Self.width / 2
        let color = ChatStepChart.color(timeline.step, colored: true, theme: theme)
        Color.clear.frame(width: Self.width)
            .overlay {
                GeometryReader { geometry in
                    Path { path in
                        if !timeline.first { path.move(to: CGPoint(x: x, y: -overhang)); path.addLine(to: CGPoint(x: x, y: center)) }
                        if !timeline.last {
                            path.move(to: CGPoint(x: x, y: center)); path.addLine(to: CGPoint(x: x, y: geometry.size.height + overhang))
                        }
                    }
                    .stroke(theme.border, lineWidth: 1.5)
                    Circle().fill(timeline.current ? color : theme.sidebar)
                        .overlay(Circle().stroke(color, lineWidth: 1.5))
                        .frame(width: 8, height: 8)
                        .position(x: x, y: center)
                }
            }
            .accessibilityHidden(true)
    }
}
