import SwiftUI
import UIKit

/// The chat tab's header controls (C1, C3, C4b, C5): the ⋯ menu (Search, Conversation mode, Manage goal, the side
/// conversations) beside the host disc, which becomes a pink waveform disc while conversation mode is on (a tap ends
/// it). Tabs' `TabScreen` puts them in the header's trailing slot on the Chat segment (`TabsContent.chatTrailing`);
/// beside the Duo's sidebar, where the Terminal / Chat switch takes the disc's place, the menu sits before the switch.
struct ChatHeaderControls<Disc: View>: View {
    let session: MobileChatSession
    /// Beside the Duo's sidebar `disc` is the Terminal / Chat switch, which stays: the waveform disc takes the menu's
    /// place instead of the disc's.
    var keepsDisc = false
    @ViewBuilder var disc: Disc
    @State private var voice = MobileVoiceConversation.shared

    /// The slot's width: the menu (or the waveform disc), the bar's gap, the disc (`disc` points wide).
    static func width(disc: CGFloat = 44) -> CGFloat { 44 + 8 + disc }

    var body: some View {
        HStack(spacing: 8) {
            if keepsDisc {
                if voice.active(for: session) { waveform } else { ChatThreadMenu(session: session) }
                disc
            } else {
                ChatThreadMenu(session: session)
                if voice.active(for: session) { waveform } else { disc }
            }
        }
    }

    private var waveform: some View {
        Button { voice.stop() } label: {
            ChatWaveform(level: voice.level, bars: 5, color: .onAccent)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.dispatchPink).interactive(), in: Circle())
        .accessibilityLabel("End conversation mode")
        .accessibilityIdentifier("chat-conversation-disc")
    }
}

/// The ⋯ menu of a conversation.
struct ChatThreadMenu: View {
    let session: MobileChatSession
    @State private var voice = MobileVoiceConversation.shared

    var body: some View {
        Menu {
            Button("Search", systemImage: "magnifyingglass") { session.search.open() }
            if voice.active(for: session) {
                Button("End Conversation Mode", systemImage: "waveform.slash") { voice.stop() }
            } else {
                Button("Conversation Mode", systemImage: "waveform") { voice.start(session) }
                    .disabled(session.phase != .verified)
            }
            if session.goal != nil {
                Button("Manage Goal", systemImage: "flag") { session.managingGoal = true }
            }
            if session.side != nil {
                Button("Side Conversation", systemImage: "arrow.triangle.branch") { session.showingSide = true }
            } else if session.offersSide(.btw) || session.offersSide(.side) {
                Section {
                    if session.offersSide(.btw) {
                        Button("Ask on the Side", systemImage: "arrow.triangle.branch") { session.openSide(.btw) }
                    }
                    if session.offersSide(.side) {
                        Button("Side Conversation with Changes", systemImage: "pencil") { session.openSide(.side) }
                    }
                }
                .disabled(session.phase != .verified)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        // 44 points, as `ChatHeaderControls.width` counts it (`SpaceMenu`'s note).
        .menuStyle(.button)
        .buttonStyle(.plain)
        .tint(Color.primary)
        .glassEffect(.regular.interactive(), in: Circle())
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.highlight)
        .accessibilityLabel("Conversation menu")
    }
}

/// C4: the goal under the header: flag, "Goal · working" and the objective, Pause (Resume while paused) and Stop discs.
/// A tap on the text opens Manage goal (C4b).
struct ChatGoalStrip: View {
    let session: MobileChatSession
    let goal: ChatGoal

    var body: some View {
        HStack(spacing: 10) {
            Button { session.managingGoal = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: goal.status == "paused" ? "flag" : "flag.fill")
                        .foregroundStyle(Color.dispatchPink)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Goal · " + ChatGoalStrip.state(goal)).font(.subheadline.weight(.semibold))
                        Text(goal.objective).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Goal, " + ChatGoalStrip.state(goal))
            .accessibilityValue(goal.objective)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Manages the goal")
            if goal.status == "active" || goal.status == "paused" {
                disc(goal.status == "active" ? "pause.fill" : "play.fill", label: goal.status == "active" ? "Pause goal" : "Resume goal") {
                    session.goal(goal.status == "active" ? "pause" : "resume")
                }
            }
            disc("stop.fill", label: "Stop goal", tint: .destructive) { session.goal("clear") }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 4)
        .disabled(session.phase != .verified)
    }

    /// "working", "paused", "usage limited": the goal's status in the strip's words.
    static func state(_ goal: ChatGoal) -> String { goal.status == "active" ? "working" : goal.statusLabel }

    private func disc(_ symbol: String, label: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .padding(5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(-5)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(label)
    }
}

/// C4's status line over the composer: "12m on the goal · 2 subagents" and the context used on the right.
struct ChatGoalStatusLine: View {
    let parts: [String]
    var body: some View {
        let context = parts.last?.hasSuffix("context") == true ? parts.last : nil
        let leading = context == nil ? parts : Array(parts.dropLast())
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(leading.joined(separator: " · "))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let context { Text(context).fixedSize() }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 22)
        .padding(.top, 4)
    }
}

/// C4b: Manage goal, a medium sheet: the objective (editable: Codex's own `/goal` sets it), the status the agent
/// reports, Pause or Resume, Stop goal. Codex's `/goal` has no turn limit or confirmation rules, so neither is offered.
struct ChatGoalSheet: View {
    let session: MobileChatSession
    @State private var objective = ""
    @FocusState private var editing: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let goal = session.goal {
                    Section {
                        // One line: Codex keeps an objective on a single line, so a pasted newline becomes a space.
                        TextField("Objective", text: Binding(get: { objective }, set: { objective = Self.oneLine($0) }))
                            .focused($editing)
                            .submitLabel(.done)
                            .onSubmit(save)
                            .accessibilityLabel("Goal objective")
                    } header: {
                        Text("Goal")
                    } footer: {
                        Text("One line. Codex keeps the objective on a single line.")
                    }
                    Section("Status") {
                        // The strip says working or paused; another state (usage or budget limited) is said here.
                        if goal.status != "active" && goal.status != "paused" {
                            row("Status", goal.statusLabel.capitalized)
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            row("Time", Self.time(goal, since: session.goalUpdatedAt, now: context.date))
                        }
                        row("Tokens", Self.tokens(goal))
                    }
                    Section {
                        if goal.status == "active" {
                            Button("Pause") { session.goal("pause") }
                        } else if goal.status == "paused" {
                            Button("Resume") { session.goal("resume") }
                        }
                        Button("Stop Goal", role: .destructive) { session.goal("clear"); dismiss() }
                    }
                    .disabled(session.phase != .verified)
                }
            }
            .navigationTitle("Manage goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { save(); dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .onAppear { objective = session.goal?.objective ?? "" }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.canvas)
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    /// The time on the goal at `now`: what the agent reported, plus the time since while the goal is active.
    static func time(_ goal: ChatGoal, since updated: Date, now: Date) -> String {
        ChatTurnSummary.elapsed(TimeInterval(goal.timeUsedSeconds)
            + (goal.status == "active" ? max(0, now.timeIntervalSince(updated)) : 0))
    }

    /// `text` on one line: line breaks become spaces.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// "48,210 of 200,000", or the count alone without a budget.
    static func tokens(_ goal: ChatGoal) -> String {
        let used = goal.tokensUsed.formatted()
        return goal.tokenBudget.map { "\(used) of \($0.formatted())" } ?? used
    }

    private func save() {
        editing = false
        session.setGoal(objective)
    }
}

/// C5: the listening bar in the composer's place: the hint above, a pink glass capsule with the live waveform and what
/// is being heard (or the message so far), and × to end conversation mode.
struct ChatListeningBar: View {
    let voice: MobileVoiceConversation
    @ReduceMotion private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("chat-listening-hint")
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion || voice.phase != .listening)) { _ in
                        ChatWaveform(level: voice.phase == .listening ? voice.level : 0, bars: 9, color: .dispatchPink)
                    }
                    .frame(width: 44, height: 22)
                    .accessibilityHidden(true)
                    // The newest words: a long message keeps its end in view.
                    Text(words.isEmpty ? " " : words)
                        .font(.body)
                        .accessibilityLabel(words.isEmpty ? (voice.phase == .speaking ? "Reading aloud" : "Listening") : words)
                        .lineLimit(2)
                        .truncationMode(.head)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .frame(minHeight: 50)
                .contentShape(Capsule())
                .glassEffect(.regular.tint(Color.dispatchPink.opacity(0.35)), in: Capsule())
                // Half-duplex: while it reads, the microphone is off, so a tap (not "quiet") stops the reading.
                .onTapGesture { if voice.phase == .speaking { voice.quiet() } }
                .accessibilityElement(children: .contain)
                .accessibilityAction(named: "Stop reading") { voice.quiet() }
                Button { voice.stop() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 50, height: 50)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("End conversation mode")
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var words: String {
        [voice.message, voice.heard].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var hint: String {
        if let failure = voice.failure { return failure }
        if voice.phase == .speaking { return "Reading aloud · tap to stop reading" }
        if let note = voice.note { return note }
        return "Listening · say “send” or pause to send"
    }
}

/// Bars that follow the microphone's level (C5), lowest at the ends.
struct ChatWaveform: View {
    let level: Float
    var bars = 9
    var color: Color = .dispatchPink
    private static let shape: [CGFloat] = [0.36, 0.64, 0.9, 0.54, 1, 0.45, 0.72, 0.36, 0.54]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<bars, id: \.self) { index in
                let base = Self.shape[index % Self.shape.count]
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: 4 + 18 * base * CGFloat(0.35 + 0.65 * min(1, max(0, level))))
            }
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

/// C6: "Jump to latest" over the thread's bottom while it is scrolled up and newer messages came, with how many.
struct ChatJumpPill: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down")
                Text("Jump to latest")
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Color.stateUnread, in: Capsule())
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .accessibilityLabel(count > 0 ? "Jump to latest, \(count) new" : "Jump to latest")
        .accessibilityIdentifier("chat-jump-latest")
    }
}

/// S6: a turn's footnote under its last bubble ("5 steps in 1m 26s · 2 files +38 −4"), the counts in green and red.
struct ChatTurnFootnote: View {
    let summary: ChatTurnSummary

    var body: some View {
        if let text = summary.footnote {
            footnote(text)
                .font(.footnote)
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 22)
                .accessibilityLabel(text.replacingOccurrences(of: "−", with: "minus "))
        }
    }

    /// The counts after the files coloured; the rest as it reads.
    private func footnote(_ text: String) -> Text {
        guard !summary.files.isEmpty, let range = text.range(of: " +\(summary.additions) −\(summary.deletions)", options: .backwards)
        else { return Text(text) }
        let added = Text("+\(summary.additions)").foregroundStyle(Color.added.opacity(0.85))
        let removed = Text("−\(summary.deletions)").foregroundStyle(Color.destructive.opacity(0.85))
        return Text("\(String(text[..<range.lowerBound])) \(added) \(removed)")
    }
}

/// C5: "Reading aloud · 0:08" under the bubble being read.
struct ChatReadingFootnote: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(Color.dispatchPink)
                Text("Reading aloud · " + MobileVoiceConversation.clock(context.date.timeIntervalSince(since)))
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 22)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-reading-aloud")
    }
}

/// Over the composer while a side conversation stays open behind the main thread: a tap returns to it.
struct ChatSideReturn: View {
    let side: MobileSideConversation
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.caption.weight(.semibold))
                Text(side.title).font(.footnote.weight(.semibold).monospaced())
                Text(side.busy ? "· answering…" : "· side conversation").font(.footnote)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel("Return to the side conversation")
        .padding(.top, 4)
    }
}

/// Switches the tab to Terminal (`TabScreen`), for "/terminal".
struct ChatTerminalSwitch {
    let show: () -> Void
}

extension EnvironmentValues {
    @Entry var chatShowTerminal: ChatTerminalSwitch? = nil
}
