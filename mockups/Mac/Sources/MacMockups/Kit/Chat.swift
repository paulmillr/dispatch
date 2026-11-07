import SwiftUI

// A chat pane (ChatView, ChatTranscriptView, ChatComposer), at the app's defaults. The transcript 22 points in: the
// user's bubbles right with their tail at the bottom right; the agent's in bordered bubbles. Items group as the app's
// rows do (ChatSession.preparedRows): tool steps right after an agent message join its bubble, under the text, with
// the message's time at the end of their header; two or more steps after anything else are a bubble of their own (the
// header alone); one such step is a lone tool card; a reply after steps is its own bubble with its time in the corner.
// A group shows its steps as Settings › Tool steps does by default (Current step): the live turn's newest group only
// the step the agent is on, every other group none. Then the composer, its footer carrying the agent's activity.
// Colours are ChatColors (the terminal scheme's), metrics ChatType's (ChatTypography's).

struct ToolStep {
    var symbol = "terminal"
    var title: String
    var summary: String
    var added: Int?
    var removed: Int?
    /// How long it ran; its time shows on an opened group's timeline, and its bar is as wide as its share of the
    /// group's. Nil: unknown (the bars share the chart equally, and the group shows no total).
    var seconds: Double?
    var kind = Kind.other
    var status = Status.done
    /// A failed step's exit code ("exit 1"); nil says "Failed".
    var exitCode: Int?
    var expanded = false
    enum Status { case done, failed, running }
    /// What the chart and the rail tell apart (ChatToolStep.Kind): edits in the accent, the web in cyan, the rest blue.
    enum Kind { case edit, web, other }
}

/// How much of a tool group shows (ChatToolGroupDisclosure): its header alone, the step the agent is on, every step.
enum StepsShown { case collapsed, current, all }

enum ChatItem {
    /// The user's message (Markdown).
    case user(String)
    /// An agent message (Markdown) and its time.
    case agent(String, time: String? = nil)
    /// Tool steps. `shown` nil: as the app shows them by default (the live turn's newest group its current step,
    /// others collapsed); set, as the user opened or closed the group.
    case tools([ToolStep], shown: StepsShown? = nil)
    /// "worked for 2m 10s" between two rules: after a turn of two minutes or more.
    case worked(String)
    /// The reply placeholder (ChatReplyPlaceholderStatus): an empty agent bubble with the activity where the reply's
    /// first word will be ("thinking", "4s"); the composer's footer dims its own meanwhile.
    case pending(label: String, time: String)
    /// Anything else, drawn in the transcript's column.
    case custom(AnyView)
}

struct ChatPane: View {
    var items: [ChatItem]
    var composer = ComposerModel()
    /// The last turn is live: its newest group is on its last step.
    var live = false
    var body: some View {
        let colors = ChatColors.current
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            row(block, content: geometry.size.width - 44)
                        }
                    }
                    .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 23)
                }
                .scrollDisabled(true)
                .defaultScrollAnchor(.bottom)
            }
            // Earlier rows scroll away under the strip.
            .clipped()
            ComposerCard(model: composer, handedOff: items.contains { if case .pending = $0 { true } else { false } })
        }
        .foregroundStyle(colors.ink)
        .background(colors.terminal)
    }

    /// What the transcript draws, item by item.
    enum Block {
        case user(String)
        case message(String, time: String?, group: ToolGroup?)
        case group(ToolGroup)
        case tool(ToolStep)
        case worked(String)
        case pending(label: String, time: String)
        case custom(AnyView)
    }

    struct ToolGroup {
        var steps: [ToolStep]
        var shown: StepsShown
        /// The live turn's newest group: its last step runs, and its time waits for the turn to end.
        var live: Bool
    }

    private var blocks: [Block] {
        let lastGroup = items.lastIndex { if case .tools = $0 { true } else { false } }
        var out: [Block] = []
        for (index, item) in items.enumerated() {
            switch item {
            case .user(let text): out.append(.user(text))
            case .agent(let text, let time): out.append(.message(text, time: time, group: nil))
            case .tools(let steps, let shown):
                let isLive = live && index == lastGroup
                let group = ToolGroup(steps: steps, shown: shown ?? (isLive ? .current : .collapsed), live: isLive)
                if case .message(let text, let time, nil)? = out.last {
                    out[out.count - 1] = .message(text, time: time, group: group)
                } else if steps.count >= 2 {
                    out.append(.group(group))
                } else {
                    out.append(contentsOf: steps.map { .tool($0) })
                }
            case .worked(let text): out.append(.worked(text))
            case .pending(let label, let time): out.append(.pending(label: label, time: time))
            case .custom(let view): out.append(.custom(view))
            }
        }
        return out
    }

    @ViewBuilder private func row(_ block: Block, content: CGFloat) -> some View {
        let colors = ChatColors.current
        let bubble = min(content, ChatType.characterWidth * 80)
        switch block {
        case .user(let text):
            // ChatUserMessage: 60 percent of a wide pane and 80 characters, room for 40 in a narrow one.
            let width = min(max(content * 0.6, min(content * 0.85, ChatType.characterWidth * 40)), ChatType.characterWidth * 80)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(markdown(text)).font(ChatType.body).lineSpacing(4)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(colors.ink.opacity(0.08),
                                in: UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 3, topTrailingRadius: 10))
                    .frame(maxWidth: width, alignment: .trailing)
            }
        case .message(let text, let time, let group):
            AgentBubble(width: bubble, text: text, time: time, group: group)
        case .group(let group):
            AgentBubble(width: bubble, group: group)
        case .tool(let step):
            AgentBubble(width: bubble, lone: step)
        case .worked(let text):
            HStack(spacing: 12) {
                Rectangle().fill(colors.border).frame(height: 1)
                Text(text).font(ChatType.detail).foregroundStyle(colors.muted).fixedSize()
                Rectangle().fill(colors.border).frame(height: 1)
            }
            .padding(.vertical, 4)
        case .pending(let label, let time):
            AgentBubble(width: bubble, pending: (label, time))
        case .custom(let view):
            view
        }
    }
}

func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
}

/// An agent bubble (ChatTranscriptRowView.standardBody, its rows drawn together): 16 points in, 12 above and below,
/// 3 between its rows; the message, then its group's header 4 below it, then the shown steps on their timeline.
struct AgentBubble: View {
    let width: CGFloat
    var text: String?
    var time: String?
    var group: ChatPane.ToolGroup?
    var lone: ToolStep?
    var pending: (label: String, time: String)?
    var body: some View {
        let colors = ChatColors.current
        let shape = UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 3, bottomTrailingRadius: 10, topTrailingRadius: 10)
        let shown = group.map(Self.shownSteps) ?? []
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if let text {
                    Text(markdown(text)).font(ChatType.body).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let lone { ToolRow(step: lone, column: false) }
                if let pending { PlaceholderStatus(label: pending.label, time: pending.time) }
                if let group {
                    ToolGroupHeader(group: group, replyTime: time).padding(.top, text == nil ? 0 : 4)
                } else if let time {
                    Text(time).font(ChatType.detail).foregroundStyle(colors.muted.opacity(0.75)).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.top, 12).padding(.bottom, shown.isEmpty ? 12 : 3)
            ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
                ToolRow(step: item.step, column: true, rail: .init(kind: item.step.kind, failed: item.step.status == .failed,
                                                                  first: index == 0, last: index == shown.count - 1,
                                                                  current: group?.shown == .current),
                        running: item.running)
                    .padding(.top, 3).padding(.bottom, index == shown.count - 1 ? 12 : 3)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: width, alignment: .leading)
        .background(colors.sidebar, in: shape)
        .overlay(shape.strokeBorder(colors.border, lineWidth: 1))
    }

    /// The steps a group shows (ChatSession.visibleTranscriptRows): all, the last, or none; the live group's last step
    /// runs.
    static func shownSteps(_ group: ChatPane.ToolGroup) -> [(step: ToolStep, running: Bool)] {
        let indices: [Int]
        switch group.shown {
        case .collapsed: indices = []
        case .current: indices = group.steps.indices.suffix(1).map { $0 }
        case .all: indices = Array(group.steps.indices)
        }
        return indices.map { index in
            let running = group.live && index == group.steps.count - 1
            var step = group.steps[index]
            if running { step.status = .running }
            return (step, running)
        }
    }
}

/// ChatReplyPlaceholderStatus: ◆ and its orbit, the label and "· time" on the reply's first line, and the time's line
/// kept below it.
private struct PlaceholderStatus: View {
    let label: String
    let time: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Orbit()
                Text(label)
                Text("· " + time).monospacedDigit()
            }
            .font(ChatType.detail).foregroundStyle(ChatColors.current.muted)
            .padding(.leading, -2)
            .frame(minHeight: ChatType.bodyLine, alignment: .leading)
            Text("\u{00A0}").font(ChatType.detail)
        }
    }
}

/// ChatToolGroupHeader: the steps as a run chart (16 characters wide; a bar per step as wide as its share of the time,
/// grey collapsed with edits a shade stronger, coloured opened, only the current step's coloured while it shows
/// alone), then "4 steps · 20s" (the time once every step's is known and the turn has ended), and the message's time
/// at the end.
struct ToolGroupHeader: View {
    let group: ChatPane.ToolGroup
    var replyTime: String?
    var body: some View {
        let colors = ChatColors.current
        let steps = group.steps
        let known = steps.allSatisfy { $0.seconds != nil }
        let total = known ? steps.reduce(0) { $0 + ($1.seconds ?? 0) } : 0
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                RunChart(group: group, width: ChatType.characterWidth * 16)
                Text("\(steps.count) \(steps.count == 1 ? "step" : "steps")" + (known && !group.live ? " · " + Self.elapsed(total) : "")).fixedSize()
            }
            .frame(maxWidth: .infinity, minHeight: ChatType.detailLineHeight, alignment: .leading)
            if let replyTime {
                Text(replyTime).foregroundStyle(colors.muted.opacity(0.75)).fixedSize()
            }
        }
        .font(ChatType.detail).foregroundStyle(colors.muted)
    }

    /// ChatTranscript.elapsed: 52s, 1m 26s, 2h 5m.
    static func elapsed(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s / 60 % 60)m"
    }
}

/// ChatStepChart: bars at least 3 wide, 2 apart, 6 tall, filling the width by each step's share of the time.
private struct RunChart: View {
    let group: ChatPane.ToolGroup
    let width: CGFloat
    var body: some View {
        let steps = group.steps
        let gap: CGFloat = 2, minimum: CGFloat = 3
        let total = steps.contains { $0.seconds == nil } ? 0 : steps.reduce(0) { $0 + ($1.seconds ?? 0) }
        let free = max(0, width - gap * CGFloat(steps.count - 1) - minimum * CGFloat(steps.count))
        HStack(spacing: gap) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let share = total > 0 ? CGFloat((step.seconds ?? 0) / total) : 1 / CGFloat(steps.count)
                let colored = group.shown == .all || (group.shown == .current && index == steps.count - 1)
                RoundedRectangle(cornerRadius: 1.5).fill(Self.color(step, colored: colored))
                    .frame(width: minimum + free * share, height: 6)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    static func color(_ step: ToolStep, colored: Bool) -> Color {
        let colors = ChatColors.current
        if !colored { return colors.muted.opacity(step.kind == .edit ? 0.7 : 0.32) }
        if step.status == .failed { return colors.yellow }
        return step.kind.color
    }
}

extension ToolStep.Kind {
    @MainActor var color: Color {
        let colors = ChatColors.current
        switch self {
        case .edit: return colors.accent
        case .web: return colors.cyan
        case .other: return colors.blue
        }
    }
}

/// ChatToolCard's embedded header (3 + 1 points above and below its line): the icon, the title (in the opened group's
/// title column), the summary, changed lines, a failure's exit, its time, its status and the disclosure chevron; on
/// the group's timeline (ChatStepRail) 8 points after the rail.
struct ToolRow: View {
    let step: ToolStep
    /// In an opened group: the title in the shared column, and the time shown.
    var column = true
    var rail: Rail.Place?
    var running = false
    var body: some View {
        let colors = ChatColors.current
        HStack(spacing: 9) {
            Image(systemName: step.symbol).foregroundStyle(colors.muted).frame(width: 14)
            if column && step.status != .running && !step.summary.isEmpty {
                Text(step.title).fontWeight(.semibold).lineLimit(1).truncationMode(.tail).frame(width: ChatType.stepTitleWidth, alignment: .leading)
            } else if column {
                Text(step.title).fontWeight(.semibold).fixedSize().frame(minWidth: ChatType.stepTitleWidth, alignment: .leading)
            } else {
                Text(step.title).fontWeight(.semibold).fixedSize()
            }
            Text(step.summary).foregroundStyle(colors.muted).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if let added = step.added, added > 0 { Text("+\(added)").foregroundStyle(colors.green).fixedSize() }
            if let removed = step.removed, removed > 0 { Text("−\(removed)").foregroundStyle(colors.red).fixedSize() }
            if step.status == .failed {
                Text(step.exitCode.map { $0 != 0 ? "exit \($0)" : "Failed" } ?? "Failed").foregroundStyle(colors.yellow).fixedSize()
            }
            if column && !running, let seconds = step.seconds {
                Text(ToolGroupHeader.elapsed(seconds)).foregroundStyle(colors.muted.opacity(0.75)).fixedSize()
            }
            Group {
                switch step.status {
                case .done: Image(systemName: "checkmark.circle").foregroundStyle(colors.green)
                case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(colors.yellow)
                case .running: Image(systemName: "circle.dotted").foregroundStyle(colors.muted)
                }
            }
            .frame(width: 14)
            Image(systemName: "chevron.right").foregroundStyle(colors.muted).rotationEffect(.degrees(step.expanded ? 90 : 0)).frame(width: 8)
        }
        .font(ChatType.detail)
        .padding(.vertical, 1).padding(.vertical, 3)
        .padding(.leading, rail == nil ? 0 : Rail.width + 8)
        .overlay(alignment: .leading) { if let rail { Rail(place: rail) } }
    }

    /// ChatStepRail: a 4-point dot in the step's colour level with its line (a disc for the current step shown alone,
    /// a ring otherwise), on a 1.5-point line out into the row padding to its neighbours, broken by the dot.
    struct Rail: View {
        struct Place { let kind: ToolStep.Kind; let failed: Bool; let first: Bool; let last: Bool; let current: Bool }
        static let width: CGFloat = 10
        let place: Place
        var body: some View {
            let border = ChatColors.current.border
            let color = place.failed ? ChatColors.current.yellow : place.kind.color
            let center = 4 + ChatType.detailLineHeight / 2, radius: CGFloat = 4, overhang: CGFloat = 3
            GeometryReader { box in
                ZStack(alignment: .topLeading) {
                    if !place.first {
                        Rectangle().fill(border).frame(width: 1.5, height: center - radius + overhang)
                            .offset(x: box.size.width / 2 - 0.75, y: -overhang)
                    }
                    if !place.last {
                        Rectangle().fill(border).frame(width: 1.5, height: max(0, box.size.height + overhang - center - radius))
                            .offset(x: box.size.width / 2 - 0.75, y: center + radius)
                    }
                    Group {
                        if place.current { Circle().fill(color) } else { Circle().strokeBorder(color, lineWidth: 1.5) }
                    }
                    .frame(width: radius * 2, height: radius * 2)
                    .offset(x: box.size.width / 2 - radius, y: center - radius)
                }
            }
            .frame(width: Self.width)
        }
    }
}

/// ChatComposerOrbit, still: ◆ in the accent with its dot a quarter way round, in a 16-point slot.
struct Orbit: View {
    var size: CGFloat = 11.5
    var body: some View {
        let accent = ChatColors.current.accent
        ZStack {
            Text("◆").font(.system(size: size)).foregroundStyle(accent)
            Circle().fill(accent).frame(width: 4, height: 4).offset(x: 8 * cos(.pi / 4), y: -8 * sin(.pi / 4))
        }
        .frame(width: 16, height: 20)
    }
}

struct ComposerModel {
    /// The draft; nil shows the empty composer's "Reply…".
    var draft: String? = nil
    /// The model's ID label (AgentModelMenu.label: claude-opus-5-5 → opus-5.5) and effort.
    var model = "opus-5.5"
    var effort = "high"
    /// The agent is working: the footer's activity (a label of AgentWorkingState's: thinking, running, reading,
    /// searching, working, waiting on agents), the accent border and Stop; Send reads Queue.
    var working: (label: String, time: String)? = nil
    var dictation = true
    /// The pane is focused. Unfocused, the editor and the footer's details hide: on glass the round reply button
    /// stands where Send was (or, while the agent works, the footer's activity alone); flat, "Reply…".
    var focused = true
}

/// The composer (ChatView.input, ChatComposerFocusChrome): on Liquid Glass its frame is the glass, 12-point corners,
/// no border while idle; flat, the sidebar's panel with 8-point corners and the theme's border. While the agent
/// works, an accent border at 0.35 and a 6-point halo at 0.06.
struct ComposerCard: View {
    let model: ComposerModel
    /// The reply placeholder carries the activity: the footer's dims and its time blanks, the composer stays neutral.
    var handedOff = false
    var body: some View {
        let glass = Mock.glass
        card
            .padding(.horizontal, Chrome.paneContentInset)
            .padding(.top, glass ? 10 : 14).padding(.bottom, glass ? 6 : 14)
    }

    private var line: CGFloat { ChatType.replyLineHeight + 14 }
    private var working: Bool { model.working != nil && !handedOff }

    @ViewBuilder private var card: some View {
        let colors = ChatColors.current
        let glass = Mock.glass
        let radius: CGFloat = glass ? 12 : 8
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let draft = model.draft, !draft.isEmpty {
                    Text(draft).font(ChatType.reply).foregroundStyle(colors.ink)
                        + Text("|").font(ChatType.reply).foregroundStyle(colors.accent)
                } else {
                    Text("Reply…").font(ChatType.reply).foregroundStyle(colors.muted)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: ChatType.replyLineHeight + 10, alignment: .leading)
            .opacity(model.focused || (!glass && model.working == nil) ? 1 : 0)
            footer
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 9)
                .opacity(model.focused || model.working != nil ? 1 : 0)
        }
        .padding(.top, 4)
        .background {
            if model.focused {
                if glass {
                    shape.fill(GlassTone.track).overlay(shape.strokeBorder(GlassTone.trackEdge, lineWidth: 1))
                } else {
                    shape.fill(Chrome.sidebar).overlay(shape.strokeBorder(colors.border, lineWidth: 1))
                }
            }
        }
        .overlay {
            if working && model.focused {
                shape.stroke(colors.accent.opacity(0.06), lineWidth: 6)
                shape.strokeBorder(colors.accent.opacity(0.35), lineWidth: 1)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !model.focused && model.working == nil && glass {
                // The round reply button where Send sits, centred on the footer row, at the strip's trailing inset.
                Image(systemName: "arrowshape.turn.up.left").font(.system(size: line * 0.4, weight: .medium))
                    .foregroundStyle(colors.muted)
                    .frame(width: line, height: line)
                    .background(Circle().fill(GlassTone.track)).overlay(Circle().strokeBorder(GlassTone.trackEdge, lineWidth: 1))
                    .padding(.trailing, Chrome.stripInset - Chrome.paneContentInset)
                    .padding(.bottom, max(0, 9 + max(24, ChatType.detailLineHeight) / 2 - line / 2))
            }
        }
    }

    /// ChatView.composerFooter: one row with everything, or one with every optional item folded at once
    /// (FooterDensity): Send's key, the ⌘/ chip, effort as its meter, the activity's label, a long model name.
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            footerRow(.full)
            footerRow(.compact)
        }
        .font(ChatType.detail)
    }

    private enum Density { case full, compact }

    private func footerRow(_ density: Density) -> some View {
        let colors = ChatColors.current
        let compact = density == .compact
        return HStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Text(model.model).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: compact ? ChatType.detailSize * 9 : nil, alignment: .leading)
                        .overlay(alignment: .bottom) { Rectangle().fill(colors.muted.opacity(0.4)).frame(height: 1).offset(y: 2) }
                    if !compact { Text("·") }
                    Group {
                        if compact { EffortMeter(effort: model.effort) } else { Text(model.effort) }
                    }
                    .frame(minWidth: 24, minHeight: 20)
                }
                .foregroundStyle(colors.muted.opacity(0.65))
                .fixedSize()
                .opacity(model.focused ? 1 : 0)
                if let working = model.working {
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Orbit()
                            if !compact { Text(working.label) }
                            Text((compact ? "" : "· ") + working.time).monospacedDigit().opacity(handedOff ? 0 : 1)
                        }
                        .opacity(handedOff ? 0.45 : 1)
                        Image(systemName: "stop.fill").font(.system(size: 7)).frame(width: 18, height: 18)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(colors.border, lineWidth: 1))
                    }
                    .foregroundStyle(colors.muted)
                    .fixedSize()
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                let side = max(24, ChatType.detailLineHeight + 10)
                HStack(spacing: 2) {
                    Image(systemName: "paperclip").font(.system(size: ChatType.detailSize + 1, weight: .medium)).frame(width: side, height: side)
                    if model.dictation { Image(systemName: "mic").font(.system(size: ChatType.detailSize + 1, weight: .medium)).frame(width: side, height: side) }
                    if !compact {
                        Text("⌘/").font(.system(size: ChatType.detailSize + 2, weight: .medium, design: .monospaced)).frame(minWidth: side, minHeight: side)
                    }
                }
                .foregroundStyle(colors.muted)
                SendButton(title: model.working != nil ? "Queue" : "Send", enabled: model.draft?.isEmpty == false, showsKey: !compact)
            }
            .fixedSize()
            .opacity(model.focused ? 1 : 0)
        }
    }
}

/// ChatEffortMeter: four bars 3 wide and 4, 7, 10, 10 tall, filled to the effort (high: two), the fourth in the accent.
private struct EffortMeter: View {
    let effort: String
    var body: some View {
        let colors = ChatColors.current
        let filled = ["low": 0, "medium": 1, "high": 2, "xhigh": 3, "extra high": 3, "max": 3, "ultra": 4][effort.lowercased()] ?? 0
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < filled ? (index == 3 ? colors.accent : colors.ink.opacity(0.8)) : .clear)
                    .overlay {
                        if index < 3 && index >= filled { RoundedRectangle(cornerRadius: 1).strokeBorder(colors.muted.opacity(0.5), lineWidth: 1) }
                    }
                    .frame(width: 3, height: CGFloat(min(10, 4 + index * 3)))
            }
        }
        .frame(width: 18, height: 10, alignment: .bottomLeading)
    }
}

/// ChatReplyButton: the action ("Send", "Queue" while the agent works) and its key, 24 tall; on glass an
/// accent-tinted glass capsule (clear glass while it can't send), flat an accent fill (ink at 0.08 while it can't).
private struct SendButton: View {
    let title: String
    let enabled: Bool
    var showsKey = true
    var body: some View {
        let colors = ChatColors.current
        let label = HStack(spacing: 5) {
            ZStack {
                Text("Requeue").hidden()
                Text(title)
            }
            if showsKey {
                // Sized for the widest key it shows (⌥⌘⏎), as the app's ZStack reserves.
                ZStack {
                    Text("⌥⌘⏎").hidden()
                    Text("⏎")
                }
                .font(AppFont.shortcut(size: ChatType.codeDetailSize)).opacity(0.7)
            }
        }
        .font(ChatType.detail)
        .foregroundStyle(enabled ? colors.terminal : colors.muted)
        .padding(.horizontal, 9).frame(height: max(24, ChatType.detailLineHeight + 10))
        .fixedSize()
        if Mock.glass {
            label.background(Capsule().fill(enabled ? colors.accent : GlassTone.track))
                .overlay(Capsule().strokeBorder(enabled ? Color.white.opacity(0.18) : GlassTone.trackEdge, lineWidth: 1))
        } else {
            label.background(enabled ? colors.accent : colors.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
