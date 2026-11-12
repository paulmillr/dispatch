import CoreText
import SwiftUI
import UIKit

/// The chat tab's header control (C5): the mode button, which becomes a pink waveform disc while conversation mode is on
/// (a tap ends it). Tabs' `TabScreen` puts it in the header's trailing slot on the Chat segment
/// (`TabsContent.chatTrailing`); the conversation's items (Search, the side conversations, Manage goal) are in the title
/// capsule's menu (`chatMenu`).
struct ChatHeaderControls<Disc: View>: View {
    let session: MobileChatSession
    @ViewBuilder var disc: Disc
    @State private var voice = MobileVoiceConversation.shared

    var body: some View {
        if voice.active(for: session) { waveform } else { disc }
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

extension TabsContent {
    /// The Chat segment's header for the conversation `session(tab, pane)` (`chatTrailing`, `chatMenu`): the mode
    /// button, which conversation mode's waveform replaces, and the conversation's items for the tab's menu.
    mutating func chatHeader(_ session: @escaping @MainActor (MobileTab, MobilePane) -> MobileChatSession) {
        chatTrailing = { tab, pane, disc in AnyView(ChatHeaderControls(session: session(tab, pane)) { disc }) }
        chatMenu = { tab, pane in AnyView(ChatThreadMenuItems(session: session(tab, pane))) }
    }
}

/// A conversation's menu items: Search, the side conversations (read-only; the open one instead while it
/// lasts), Manage goal. Conversation mode is the composer's ("+", and a long press on the mic).
struct ChatThreadMenuItems: View {
    let session: MobileChatSession
    /// What the tab's menu puts right under Search (the host's Stats, `TabMenuItems`).
    @Environment(\.chatMenuAfterSearch) private var afterSearch

    var body: some View {
        Button("Search", systemImage: "magnifyingglass") { session.search.open() }
        if let afterSearch { afterSearch }
        if session.side != nil {
            Button("Side Conversation", systemImage: "bubble.left.and.text.bubble.right") { session.showingSide = true }
        } else if session.offersSide(.btw) {
            // The read-only side conversation only: one with changes is the composer's `/side`.
            Button("Side Conversation", systemImage: "bubble.left.and.text.bubble.right") { session.openSide(.btw) }
                .disabled(session.phase != .verified)
        }
        if session.goal != nil {
            Button("Manage Goal", systemImage: "flag") { session.managingGoal = true }
        }
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

/// C7: "Jump to latest", a glass arrow at the thread's trailing edge just above the composer whenever the end is out of
/// view; the rows that came meanwhile badge it with their count (`ChatFollow`). Out of the reading column, where the
/// thumb rests.
struct ChatJumpButton: View {
    let count: Int
    let action: () -> Void
    @ReduceMotion private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .overlay(alignment: .topTrailing) {
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(count)))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Color.stateUnread, in: Capsule())
                    .offset(x: 4, y: -4)
                    .animation(.snappy(duration: 0.25), value: count)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .accessibilityLabel(count > 0 ? "Jump to latest, \(count) new" : "Jump to latest")
        .accessibilityIdentifier("chat-jump-latest")
    }
}

/// Whether the thread follows its end, and how many rows came while it did not (C6). The thread follows until something
/// other than the app moves it away from the end: the user's drag or fling (stops following the moment it starts), or
/// any other scroll toward older rows (VoiceOver's scroll and focus, the status bar's tap, Page Up and the arrow keys).
/// Content that grows, the keyboard or the composer changing height take the end out of view without moving the offset
/// up, so the thread goes back to it (`moved` answers true) instead of counting what comes meanwhile; the app's own
/// animated scroll to the end (the button) is let run. A drag that only took the keyboard down keeps a following thread
/// following. "Jump to latest" (C7) shows whenever the thread does not follow and its end is out of view: never at the
/// end, also not for a frame, nor during a drag that stays there; at the end again, after the button or a send, it
/// follows again.
struct ChatFollow: Equatable {
    private(set) var following: Bool
    private(set) var unseen = 0
    /// The user's finger or fling moves the thread.
    private(set) var dragging = false
    /// The app's animated scroll to the end is under way (the pill): its offsets are the app's.
    private(set) var scrollingToEnd = false
    private var followedBeforeDrag = false
    private var dismissedKeyboard = false
    private var offset: CGFloat?
    /// The end was in view at the last move.
    private(set) var atEnd: Bool

    init(following: Bool = true) {
        self.following = following
        atEnd = following
    }

    /// What the view draws from this (the button, its badge and the size-change anchor); the rest changes as the thread
    /// scrolls and draws nothing.
    struct Shown: Equatable {
        var following: Bool
        var unseen: Int
        var atEnd: Bool
        var showsJump: Bool { !following && !atEnd }
    }

    var shown: Shown { Shown(following: following, unseen: unseen, atEnd: atEnd) }
    var showsJump: Bool { shown.showsJump }

    /// The offset or the end's visibility changed. True: go back to the end now (a plain scroll; nothing else is
    /// moving the thread). `resized`: the insets or the visible height changed with it (a pushed screen's navigation bar
    /// arriving after the first layout, the keyboard), so an offset toward older rows is the layout's, not the user's.
    mutating func moved(offset: CGFloat, atEnd: Bool, resized: Bool = false) -> Bool {
        let previous = self.offset
        self.offset = offset
        self.atEnd = atEnd
        if atEnd {
            unseen = 0
            scrollingToEnd = false
            if !dragging { following = true }
            return false
        }
        guard following, !dragging, !scrollingToEnd else { return false }
        if let previous, offset < previous - 0.5, !resized {
            // Toward older rows, and not the app: the user's (VoiceOver, the status bar, keys).
            following = false
            return false
        }
        return true
    }

    /// The thread came into its window: an offset sampled before is no scroll of anyone's to compare with.
    mutating func attached() { offset = nil }

    /// The user's drag began: the thread stops following at once.
    mutating func dragBegan() {
        if !dragging { followedBeforeDrag = following }
        dragging = true
        dismissedKeyboard = false
        scrollingToEnd = false
        following = false
    }

    /// The drag took the keyboard down (`ChatKeyboardDragDismissal`).
    mutating func draggedKeyboardDown() { if dragging { dismissedKeyboard = true } }

    /// The drag and its fling ended. True: go back to the end (a drag that took the keyboard down from a following
    /// thread).
    mutating func dragEnded(atEnd: Bool) -> Bool {
        guard dragging else { return false }
        dragging = false
        if atEnd {
            follow()
            scrollingToEnd = false
            return false
        }
        if dismissedKeyboard, followedBeforeDrag {
            follow()
            scrollingToEnd = false
            return true
        }
        return false
    }

    /// Rows arrived at the end.
    mutating func appended(_ count: Int) { if !following { unseen += count } }

    /// A send, or the button: the thread follows its end again, and the app scrolls there (`scrolling`: animated, let it
    /// run).
    mutating func follow(scrolling: Bool = false) {
        following = true
        unseen = 0
        dragging = false
        scrollingToEnd = scrolling
    }

    /// The thread came to rest: the app's animated scroll ended, or was taken over. True: it follows its end but rests
    /// away from it (a fling's inertia outran the button's scroll to the end): go there, animated, let run as the button's.
    mutating func rested(atEnd: Bool) -> Bool {
        let again = following && !dragging && !atEnd
        scrollingToEnd = again
        return again
    }

    /// The thread moved away on the user's request (a search match).
    mutating func leave() {
        following = false
        scrollingToEnd = false
    }
}

/// S6d: a turn's summary in its last bubble's bottom-right corner, where messengers put a message's time: small
/// secondary text, uncoloured ("3 files +127 −22 · 10:17", `ChatTurnSummary.corner`). One line over the room the
/// bubble's text keeps (`room`), so the text never runs under it; `wrapped`, on trailing lines of its own below the text
/// when it cannot share a line (`MobileChatMarkdownView`). Tapping the bubble opens the steps.
struct ChatTurnCorner: View {
    let text: String
    var wrapped = false

    var body: some View {
        if wrapped {
            Text(text)
                .font(Self.font)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            Text(text)
                .font(Self.font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    static let font = Font.caption2.monospacedDigit()
    /// The gap the room keeps before the corner.
    static let gap = "    "

    /// The room the bubble's text keeps for `text`: the gap, then `text` in the corner's font and clear ink, its
    /// characters joined so it wraps as one piece (onto a short line of its own when the last line is full).
    static func room(_ text: String) -> AttributedString {
        var room = AttributedString(gap + text.map(String.init).joined(separator: "\u{2060}"))
        room.font = font
        room.foregroundColor = .clear
        return room
    }
}

/// What an agent reply says in its corner (S6d, its time) and how its text keeps room for it (`MobileChatMarkdownView`).
struct ChatCorner {
    /// What the room is kept for: the widest the corner draws.
    var room: String
    /// The room fits one line of the bubble's text (`ChatCornerMetrics.fits`); else the corner takes lines of its own.
    var fits: Bool
    /// The corner as drawn: one line over the room, or `wrapped` on trailing lines of its own.
    var view: (_ wrapped: Bool) -> AnyView
    /// For VoiceOver, the value of the element the room ends (or the label of the corner's own lines); nil or empty:
    /// nothing to read, and no element.
    var spoken: String?
    var hint: String? = nil
    /// False for a corner VoiceOver alone reads (`spokenOnly`): the text keeps no room and nothing is drawn.
    var drawn = true

    /// An agent reply's corner, told against `now`: the ended turn's summary on its last one (S6d), which ends with
    /// when the turn ended; else when the reply was written ("10:17", `ChatTurnSummary.time`), as a messenger dates
    /// every message. Nil for a reply read without a time.
    @MainActor static func reply(time: Date?, summary: ChatTurnSummary?, now: Date, metrics: ChatCornerMetrics) -> ChatCorner? {
        let calendar = Calendar.autoupdatingCurrent
        if let summary, let text = summary.corner(now: now, calendar: calendar, fits: metrics.fits) {
            return ChatCorner(room: text, fits: metrics.fits(text), view: { AnyView(ChatTurnCorner(text: text, wrapped: $0)) },
                              spoken: summary.spokenCorner(now: now, calendar: calendar), hint: "Shows the steps")
        }
        guard let time else { return nil }
        let text = ChatTurnSummary.time(time, now: now, calendar: calendar)
        return ChatCorner(room: text, fits: metrics.fits(text), view: { AnyView(ChatTurnCorner(text: text, wrapped: $0)) },
                          spoken: text)
    }

    /// A reply as Times on swipe shows it: nothing in its corner, and beside the bubble on the swipe its time
    /// (`ChatRevealReceived`), under the turn's step count on the turn's last reply ("23 steps"; what it changed is the
    /// message's details'). VoiceOver reads the full corner as the bubble's value (`spokenOnly`).
    @MainActor static func swiped(time: Date?, summary: ChatTurnSummary?, now: Date,
                                  metrics: ChatCornerMetrics) -> (corner: ChatCorner?, time: String?) {
        let calendar = Calendar.autoupdatingCurrent
        let when = (time ?? summary?.ended).map { ChatTurnSummary.time($0, now: now, calendar: calendar) }
        let steps = summary.flatMap { $0.steps.isEmpty ? nil : ChatTurnSummary.count($0.steps.count, "step") }
        let shown = [steps, when].compactMap { $0 }.joined(separator: "\n")
        return (reply(time: time, summary: summary, now: now, metrics: metrics)?.spokenOnly, shown.isEmpty ? nil : shown)
    }
}

/// The corner's font as UIKit measures it, against the width of the bubble's text: whether a corner can share a line.
/// Every bubble of the thread asks on each pass, so fonts and widths are kept per text size.
@MainActor struct ChatCornerMetrics {
    let font: UIFont
    let size: DynamicTypeSize
    /// The widest the bubble's text runs (`ChatMeasure.bubble` less the padding).
    let column: CGFloat

    init(column: CGFloat, measure: CGFloat, size: DynamicTypeSize) {
        self.column = ChatMeasure.bubble(user: false, column: column, measure: measure) - ChatMeasure.padding
        self.size = size
        if let font = Self.fonts[size] { self.font = font } else {
            font = Self.font(size)
            Self.fonts[size] = font
        }
    }

    private struct Measured: Hashable {
        let text: String
        let size: DynamicTypeSize
    }
    private static var fonts: [DynamicTypeSize: UIFont] = [:]
    private static var widths: [Measured: CGFloat] = [:]

    /// The room's width for `text`: the gap and the text, in caption2 with monospaced digits at `size`.
    func width(_ text: String) -> CGFloat {
        let key = Measured(text: text, size: size)
        if let width = Self.widths[key] { return width }
        let width = ceil((ChatTurnCorner.gap + text as NSString).size(withAttributes: [.font: font]).width)
        if Self.widths.count >= 2048 { Self.widths.removeAll(keepingCapacity: true) }
        Self.widths[key] = width
        return width
    }

    /// `text`'s room fits one line of the bubble's text, with a point to spare for rounding.
    func fits(_ text: String) -> Bool { width(text) + 2 <= column }

    /// The wider room of the two.
    func wider(_ a: String, _ b: String) -> String { width(b) > width(a) ? b : a }

    private static func font(_ size: DynamicTypeSize) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: .caption2,
                                        compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size)))
        let digits = base.fontDescriptor.addingAttributes([.featureSettings: [[
            UIFontDescriptor.FeatureKey.type: kNumberSpacingType, UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector]]])
        return UIFont(descriptor: digits, size: 0)
    }
}

/// C5: "Reading aloud · 0:08" under the bubble being read.
struct ChatReadingFootnote: View {
    let since: Date
    /// Read Aloud's: a Stop button ends the reading (conversation mode has its own controls).
    var stop: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(Color.dispatchPink)
                    Text("Reading aloud · " + MobileVoiceConversation.clock(context.date.timeIntervalSince(since)))
                        .font(.footnote)
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))
                }
            }
            .accessibilityElement(children: .combine)
            if let stop {
                Button("Stop", action: stop)
                    .font(.footnote.weight(.semibold))
                    .tint(Color.dispatchPink)
                    .accessibilityLabel("Stop reading")
                    .accessibilityIdentifier("chat-reading-stop")
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 22)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-reading-aloud")
    }
}

/// A message's Read Aloud, or Stop Reading while it is read (`MobileMessageReader`): in its bubble's long press and in
/// message details' ⋯.
struct ChatReadAloudButton: View {
    let reader: MobileMessageReader
    let text: String
    let row: String

    var body: some View {
        if reader.isReading(row) {
            Button("Stop Reading", systemImage: "stop.circle") { reader.stop() }
        } else {
            Button("Read Aloud", systemImage: "speaker.wave.2") { reader.toggle(text, row: row) }
        }
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

/// The agent's background shells, over the composer while any runs (they outlive their turn): one names what it does,
/// more say how many; a tap lists them (`ChatShellsSheet`).
struct ChatShellsLine: View {
    let shells: [ChatShell]
    let open: () -> Void

    /// "Serve the docs" for one shell, "2 shells running" for more.
    static func label(_ shells: [ChatShell]) -> String {
        shells.count == 1 ? shells[0].title : ChatTurnSummary.count(shells.count, "shell") + " running"
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "apple.terminal").font(.caption.weight(.semibold))
                Text(Self.label(shells)).font(.footnote).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel(shells.count == 1 ? "1 shell running: \(shells[0].title)" : Self.label(shells))
        .accessibilityHint("Lists the running shells")
        .accessibilityIdentifier("chat-shells")
        .padding(.top, 4)
    }
}

/// The running shells, a medium sheet: one row per shell, oldest first, with what it does, its command and how long
/// it has run. It closes with the last shell (`MobileChatSession.showingShells`).
struct ChatShellsSheet: View {
    let session: MobileChatSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(session.shells) { shell in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shell.title)
                        if let detail = shell.detail {
                            Text(detail).font(.footnote.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(ChatTurnSummary.elapsed(context.date.timeIntervalSince(shell.started)))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chat-shell-\(shell.id)")
            }
            .navigationTitle("Running shells")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.canvas)
    }
}

/// Switches the tab to Terminal (`TabScreen`), for "/terminal".
struct ChatTerminalSwitch {
    let show: () -> Void
}

extension EnvironmentValues {
    @Entry var chatShowTerminal: ChatTerminalSwitch? = nil
}

/// Dragging a thread down onto its composer takes the keyboard down. `scrollDismissesKeyboard(.interactively)` starts
/// only where the finger meets the keyboard, and the composer sits between the thread and the keyboard: a drag down the
/// thread crossed the whole composer (the field, and the code keys when shown) before anything moved, so it seemed not
/// to work. Put in the background of the scroll view's content, this finds the thread's `UIScrollView` and watches its
/// own pan: once a downward drag passes the thread's visible bottom edge while a software keyboard shows, it ends
/// editing, and the keyboard and the composer go down together (`dismissed` is told). With only a hardware keyboard
/// (an iPad's shortcuts bar at most) it does nothing: the field keeps its focus. It takes no touches and adds no
/// gesture of its own, so scrolling is unchanged.
struct ChatKeyboardDragDismissal: UIViewRepresentable {
    var dismissed: () -> Void = {}

    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.dismissed = dismissed }

    /// Whether a drag at `location` (window coordinates, moved `translation` since it began) has crossed the thread's
    /// visible bottom edge going down.
    static func crosses(location: CGPoint, translation: CGPoint, bottom: CGFloat) -> Bool {
        translation.y > 0 && location.y >= bottom
    }

    /// A software keyboard shows: the keyboard's visible height in the window is a keyboard's, not a hardware
    /// keyboard's shortcuts bar (nil: not known yet, then no hardware keyboard is attached).
    static func softwareKeyboard(visibleHeight: CGFloat?, hardwareKeyboard: Bool) -> Bool {
        guard let visibleHeight else { return !hardwareKeyboard }
        return visibleHeight >= 150
    }

    final class Probe: UIView {
        var dismissed: () -> Void = {}
        private weak var scrollView: UIScrollView?
        private var fired = false
        /// The keyboard's visible height in the window, from its last frame change.
        private var keyboardHeight: CGFloat?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanges), name: name, object: nil)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        @objc private func keyboardChanges(_ note: Notification) {
            let end = note.name == UIResponder.keyboardWillHideNotification
                ? nil : note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            guard let end, let window else { keyboardHeight = 0; return }
            let frame = window.convert(end, from: window.screen.coordinateSpace)
            keyboardHeight = window.bounds.intersection(frame).height
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(pan))
            scrollView = nil
            guard window != nil else { return }
            var view = superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            guard let found = view as? UIScrollView else { return }
            scrollView = found
            found.panGestureRecognizer.addTarget(self, action: #selector(pan))
        }

        @objc private func pan(_ gesture: UIPanGestureRecognizer) {
            guard let scrollView, let window else { return }
            switch gesture.state {
            case .began: fired = false
            case .changed where !fired:
                let frame = scrollView.convert(scrollView.bounds, to: window)
                let bottom = frame.maxY - scrollView.adjustedContentInset.bottom
                guard ChatKeyboardDragDismissal.crosses(location: gesture.location(in: window),
                                                        translation: gesture.translation(in: window), bottom: bottom),
                      ChatKeyboardDragDismissal.softwareKeyboard(visibleHeight: keyboardHeight,
                                                                 hardwareKeyboard: HardwareKeyboard.shared.attached)
                else { return }
                fired = true
                window.endEditing(true)
                dismissed()
            default: break
            }
        }
    }
}

/// While a conversation loads, what it is doing and for how long: "Opening conversation…" until the helper answers,
/// then "Reading Claude's transcript…" (`history_pending`), the seconds after the first two ("· 4s"). The helper says
/// no more than that, so nothing pretends to a percentage.
struct ChatLoadingLine: View {
    let session: MobileChatSession

    var body: some View {
        let stage = session.historyPending
            ? "Reading \(session.agentLabel.flatMap { $0.isEmpty ? nil : $0 + "’s" } ?? "the") transcript…"
            : "Opening conversation…"
        ProgressView {
            if let since = session.loadingSince {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Self.text(stage, elapsed: context.date.timeIntervalSince(since)))
                }
            } else {
                Text(stage)
            }
        }
        .font(.footnote)
        .accessibilityIdentifier("chat-loading")
    }

    /// The stage, and from the third second on how long it has taken: "Opening conversation… · 3s".
    static func text(_ stage: String, elapsed: TimeInterval) -> String {
        let seconds = Int(elapsed)
        return seconds < 3 ? stage : stage + " · \(seconds)s"
    }
}

/// A tap felt as a hold reveals a menu (Send's options), as the system's context menus give one. The hold itself is what
/// is felt: SwiftUI builds a menu's items whenever the view draws, not as it opens, so counting their appearing buzzed
/// at launch and on every plain tap (a send, a mode switch) and not on the hold. A plain tap gives none, nor does the tab's
/// menu, which a tap opens. The mode button is a system bar item, which passes no gesture on: it has none of its own.
extension View {
    func menuHoldHaptic() -> some View { modifier(MenuHoldHaptic()) }
}

struct MenuHoldHaptic: ViewModifier {
    /// About when the system's menu opens under a held finger.
    static let hold = 0.4
    @State private var held = 0

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(LongPressGesture(minimumDuration: Self.hold).onEnded { _ in held += 1 })
            .sensoryFeedback(.impact(weight: .medium), trigger: held)
    }
}

extension EnvironmentValues {
    /// A menu item the conversation's items show right under Search (`ChatThreadMenuItems`): the tab's menu puts the
    /// host's Stats there.
    @Entry var chatMenuAfterSearch: AnyView? = nil
}
