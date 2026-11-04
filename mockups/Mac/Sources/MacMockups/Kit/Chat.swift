import SwiftUI

// A chat pane (ChatView, ChatTranscriptView, ChatComposer): the transcript 22 points in, the user's bubbles right with
// their tail at the bottom right, the agent's replies in bordered blocks with the time in their corner, tool cards,
// the working row, and the composer card with its footer and pink Send. Colours are ChatColors (the terminal scheme's).

struct ToolStep {
    var symbol = "terminal"
    var title: String
    var summary: String
    var added: Int?
    var removed: Int?
    var time: String?
    var status = Status.done
    var expanded = false
    enum Status { case done, failed, running }
}

enum ChatItem {
    /// The user's message (Markdown).
    case user(String)
    /// The agent's reply (Markdown) and its time.
    case agent(String, time: String? = nil)
    /// Tool steps in one card.
    case tools([ToolStep])
    /// "worked for 2m 10s" between two rules.
    case worked(String)
    /// The working row: label and elapsed time ("thinking", "38s").
    case working(String, time: String)
    /// Anything else, drawn in the transcript's column.
    case custom(AnyView)
}

struct ChatPane: View {
    var items: [ChatItem]
    var composer = ComposerModel()
    var body: some View {
        let colors = ChatColors.current
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in row(item) }
                }
                .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 23)
            }
            .scrollDisabled(true)
            .defaultScrollAnchor(.bottom)
            ComposerCard(model: composer).padding(.horizontal, 22).padding(.vertical, 14)
        }
        .foregroundStyle(colors.ink)
        .background(colors.terminal)
    }

    @ViewBuilder private func row(_ item: ChatItem) -> some View {
        let colors = ChatColors.current
        switch item {
        case .user(let text):
            HStack {
                Spacer(minLength: 120)
                Text(markdown(text)).font(ChatType.body).lineSpacing(4)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(colors.ink.opacity(0.08),
                                in: UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 3, topTrailingRadius: 10))
            }
        case .agent(let text, let time):
            let shape = UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 3, bottomTrailingRadius: 10, topTrailingRadius: 10)
            VStack(alignment: .leading, spacing: 6) {
                Text(markdown(text)).font(ChatType.body).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                if let time {
                    Text(time).font(ChatType.detail).foregroundStyle(colors.muted.opacity(0.75)).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: 640, alignment: .leading)
            .background(colors.sidebar, in: shape)
            .overlay(shape.strokeBorder(colors.border, lineWidth: 1))
        case .tools(let steps):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in ToolRow(step: step) }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: 640, alignment: .leading)
            .background(colors.sidebar, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(colors.border, lineWidth: 1))
        case .worked(let text):
            HStack(spacing: 12) {
                Rectangle().fill(colors.border).frame(height: 1)
                Text(text).font(ChatType.detail).foregroundStyle(colors.muted).fixedSize()
                Rectangle().fill(colors.border).frame(height: 1)
            }
            .padding(.vertical, 4)
        case .working(let label, let time):
            WorkingRow(label: label, time: time)
        case .custom(let view):
            view
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

struct ToolRow: View {
    let step: ToolStep
    var body: some View {
        let colors = ChatColors.current
        HStack(spacing: 9) {
            Image(systemName: step.symbol).foregroundStyle(colors.muted).frame(width: 14)
            Text(step.title).fontWeight(.semibold)
            Text(step.summary).foregroundStyle(colors.muted).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let added = step.added { Text("+\(added)").foregroundStyle(colors.green) }
            if let removed = step.removed { Text("−\(removed)").foregroundStyle(colors.red) }
            if let time = step.time { Text(time).foregroundStyle(colors.muted.opacity(0.75)) }
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
        .padding(.vertical, 1)
    }
}

/// The agent at work: ◆ with its orbiting dot, the label, the time, and the rule under it.
struct WorkingRow: View {
    let label: String
    let time: String
    var body: some View {
        let colors = ChatColors.current
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Orbit(size: 12)
                Text(label).fontWeight(.medium)
                Text("· \(time)").monospacedDigit()
            }
            .font(ChatType.detail).foregroundStyle(colors.muted).frame(minHeight: 20)
            Rectangle().fill(colors.border).frame(height: 1)
        }
        .padding(.vertical, 8)
    }
}

/// ChatComposerOrbit, still: ◆ in the accent with its dot a quarter way round.
struct Orbit: View {
    var size: CGFloat = 11.5
    var body: some View {
        let accent = ChatColors.current.accent
        ZStack {
            Text("◆").font(.system(size: size)).foregroundStyle(accent)
            Circle().fill(accent).frame(width: 4, height: 4).offset(x: 8 * cos(.pi / 4), y: -8 * sin(.pi / 4))
        }
        .frame(width: 18, height: 20)
    }
}

struct ComposerModel {
    /// The draft; nil shows the unfocused "Reply…".
    var draft: String? = nil
    var model = "opus"
    var effort = "high"
    /// The agent is working: the footer's activity, the accent edge and Stop.
    var working: (label: String, time: String)? = nil
    var dictation = true
}

struct ComposerCard: View {
    let model: ComposerModel
    var body: some View {
        let colors = ChatColors.current
        let shape = RoundedRectangle(cornerRadius: 8)
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let draft = model.draft {
                    Text(draft).font(ChatType.reply).foregroundStyle(colors.ink)
                        + Text("|").font(ChatType.reply).foregroundStyle(colors.accent)
                } else {
                    Text("Reply…").font(ChatType.reply).foregroundStyle(colors.muted)
                }
            }
            .padding(.horizontal, 12).padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                HStack(spacing: 12) {
                    HStack(spacing: 7) {
                        Text(model.model).overlay(alignment: .bottom) { Rectangle().fill(colors.muted.opacity(0.4)).frame(height: 1).offset(y: 2) }
                        Text("·")
                        Text(model.effort)
                    }
                    .foregroundStyle(colors.muted.opacity(0.65))
                    if let working = model.working {
                        HStack(spacing: 8) {
                            Orbit()
                            Text(working.label).fontWeight(.medium)
                            Text("· \(working.time)").monospacedDigit()
                            Image(systemName: "stop.fill").font(.system(size: 7)).frame(width: 18, height: 18)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(colors.border, lineWidth: 1))
                        }
                        .foregroundStyle(colors.muted)
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        Image(systemName: "paperclip").font(.system(size: 13, weight: .medium)).frame(width: 26, height: 26)
                        if model.dictation { Image(systemName: "mic").font(.system(size: 13, weight: .medium)).frame(width: 26, height: 26) }
                        Text("⌘/").font(.system(size: 14, weight: .medium, design: .monospaced)).frame(width: 26, height: 26)
                    }
                    .foregroundStyle(colors.muted)
                    let enabled = model.draft?.isEmpty == false
                    HStack(spacing: 5) {
                        Text("Send")
                        Text("⏎").font(.system(size: 12, design: .monospaced)).opacity(0.7)
                    }
                    .font(ChatType.detail)
                    .foregroundStyle(enabled ? colors.terminal : colors.muted)
                    .padding(.horizontal, 9).frame(height: 26)
                    .background(enabled ? colors.accent : colors.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .font(ChatType.detail)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 9)
        }
        .background(Chrome.sidebar, in: shape)
        .overlay(shape.strokeBorder(model.working != nil ? colors.accent.opacity(0.35) : colors.border, lineWidth: 1))
        .background(model.working != nil ? shape.stroke(colors.accent.opacity(0.06), lineWidth: 12) : nil)
    }
}
