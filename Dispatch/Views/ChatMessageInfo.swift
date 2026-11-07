import AppKit
import SwiftUI

/// What a message's Info shows (clicking its time, or Info in its right-click menu): its details as the iPhone's M1
/// lays them out (`ChatMessageDetailsView`), and under Record the exact time behind the minutes, the message's
/// identities and the helper record it was read from, as the agent's transcript gave it.
struct ChatMessageInfo {
    struct Field: Equatable {
        let label: String
        let value: String
    }

    let date: Date
    let item: ChatItem
    let rowID: String
    var turnID: String? = nil
    var agent: String? = nil
    var conversation: String? = nil
    var host: String? = nil
    /// Where the item starts in its transcript file, when the index read it from one.
    var offset: UInt64? = nil
    /// The conversation, read when the details show (its turn, tokens and model now); nil: the record alone.
    var session: ChatSession? = nil
    /// The conversation's directory, which step paths are shown relative to.
    var directory: String? = nil
    /// Quotes the message into the composer; nil: no Reply (your own messages).
    var reply: (() -> Void)? = nil
    /// Switches the tab to its terminal; nil where there is none.
    var showTerminal: (() -> Void)? = nil

    /// The message's turn, as the conversation has it now.
    @MainActor var turn: ChatTurn? {
        guard let turnID, let session else { return nil }
        return session.turns.last { $0.id == turnID }
    }

    /// In display order; unknown values are left out.
    var fields: [Field] {
        let local = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current)
        let utc = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let recorded = item.source?.time_ms
        var fields = [
            Field(label: "Local", value: date.formatted(local) + " " + TimeZone.current.identifier),
            Field(label: "UTC", value: date.formatted(utc)),
            Field(label: "Epoch ms", value: String(recorded ?? Int64((date.timeIntervalSince1970 * 1000).rounded()))),
            Field(label: "Time from", value: recorded != nil ? "record time_ms" : "transcript index"),
            Field(label: "Kind", value: item.source?.kind ?? item.kind.rawValue),
            Field(label: "Item", value: item.id),
            Field(label: "Row", value: rowID),
        ]
        let optional: [(String, String?)] = [
            ("Turn", item.source?.turn ?? turnID), ("Agent", agent), ("Conversation", conversation), ("Host", host),
            ("Offset", offset.map { "\($0) bytes" }),
            ("Completed", item.kind == .tool || item.exitCode != nil ? (item.completed ? "yes" : "no") : nil),
            ("Exit code", item.exitCode.map(String.init)),
        ]
        fields += optional.compactMap { label, value in value.map { Field(label: label, value: $0) } }
        return fields
    }

    /// The helper record as sorted, indented JSON; nil for a message the app made itself (a prompt not yet read back).
    var record: String? {
        guard let source = item.source else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(source)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Everything shown, as text for the pasteboard.
    var text: String {
        let fields = fields, width = fields.map(\.label.count).max() ?? 0
        let lines = fields.map { $0.label.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + $0.value }
        return (lines + ["", record ?? "No helper record."]).joined(separator: "\n")
    }
}

/// A message's time, which opens its `ChatMessageInfo` when it has one.
struct ChatMessageTime<Label: View>: View {
    @Environment(\.chatTheme) private var theme
    let info: ChatMessageInfo?
    @ViewBuilder let label: () -> Label
    @State private var presented = false

    var body: some View {
        if let info {
            Button { presented.toggle() } label: { label().contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the message's details")
                .popover(isPresented: $presented, arrowEdge: .bottom) {
                    ChatMessageDetailsView(info: info) { presented = false }.chatPopoverChrome(theme)
                }
        } else {
            label()
        }
    }
}

extension View {
    /// A message popover's fill and appearance: on glass the popover's own glass shows through instead of the sidebar
    /// fill.
    @MainActor func chatPopoverChrome(_ theme: ChatTheme) -> some View {
        background(LiquidGlassStore.shared.active ? Color.clear : theme.sidebar)
            .environment(\.chatTheme, theme)
            .preferredColorScheme(theme.isDark ? .dark : .light)
    }
}

/// What right-clicking a message's text offers above the text's own menu, as the iPhone's long press does: Copy
/// Message (its Markdown), Reply on an agent's message, and Info (`ChatMessageInfo`), which opens where the click was.
/// Set by the transcript's row (`ChatTranscriptRowView`) for messages; read by the text views (`ChatSelectableText`).
/// Built and read on the main actor only (the environment's values must be Sendable).
struct ChatMessageMenu: Equatable, @unchecked Sendable {
    let id: String
    let text: String
    var reply: (() -> Void)? = nil
    var info: ChatMessageInfo? = nil

    /// The row and its text: what the items act on. The closures and the info only reach the conversation through
    /// references that stay the same.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text && (lhs.reply == nil) == (rhs.reply == nil) && (lhs.info == nil) == (rhs.info == nil)
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension ChatSession {
    /// A message's Reply: the message quoted above the draft, and the composer focused, as the iPhone's Reply does.
    /// Blank lines stay in the quote (as ">"), so its paragraphs do.
    func reply(quoting text: String) {
        let quote = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        draft = quote + "\n\n" + draft
        focusRequest = System.uuid()
    }
}

extension EnvironmentValues {
    @Entry var chatMessageMenu: ChatMessageMenu? = nil
}

/// Info from a message's menu: a popover at the point clicked, which a SwiftUI popover can't anchor to (a reply can be
/// taller than the window). One at a time; it closes when clicked outside.
@MainActor enum ChatMessageInfoPopover {
    private static var shown: NSPopover?

    static func show(_ info: ChatMessageInfo, theme: ChatTheme, at point: NSPoint, in view: NSView) {
        shown?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let host = NSHostingController(rootView: ChatMessageDetailsView(info: info) { [weak popover] in popover?.close() }
            .chatPopoverChrome(theme))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: view, preferredEdge: .maxY)
        shown = popover
    }
}

/// A message's details, laid out as the iPhone's (M1, `ChatMessageDetails`): who wrote it and when with its actions,
/// the whole message raw (Markdown unrendered, one selection), how its turn went and when, the conversation's facts
/// (the turn's changes, tokens so far, its model now), then the turn's steps, folded past `ChatStepFold.threshold`.
/// Record, closed, keeps what the time showed before: the exact times, identities and the helper record.
struct ChatMessageDetailsView: View {
    @Environment(\.chatTheme) private var theme
    let info: ChatMessageInfo
    var close: () -> Void = {}
    @State private var unfolded: Set<String> = []
    @State private var showingAll = false
    @State private var showingRecord = false

    var body: some View {
        let turn = info.turn
        let summary = turn.map(ChatTurnSummary.init)
        let steps = turn.map { ChatStep.steps($0, directory: info.directory, reasoning: false) } ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                quote
                if turn != nil { outcome(turn, summary: summary) }
                facts(summary)
                if !steps.isEmpty { stepSection(steps) }
                record
            }
            .padding(16)
        }
        .frame(width: 520)
        .frame(maxHeight: 640)
        .fixedSize(horizontal: false, vertical: true)
        .font(theme.typography.detail)
        .foregroundStyle(theme.ink)
        .accessibilityIdentifier("chat-message-details")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.item.kind == .user ? "You" : info.agent ?? "Agent").font(theme.typography.font(weight: .semibold))
                Text(ChatTurnSummary.moment(info.date)).foregroundStyle(theme.muted).monospacedDigit()
            }
            Spacer(minLength: 8)
            Button("Copy") { copy(info.item.text) }
            if let reply = info.reply {
                Button("Reply") { close(); reply() }
            }
            if let showTerminal = info.showTerminal {
                Button("Show in Terminal") { close(); showTerminal() }
            }
        }
        .controlSize(.small)
    }

    /// The message as a block quote: a bar on its leading edge and no fill, so it never reads as one of the cards.
    private var quote: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule().fill(theme.accent.opacity(0.55)).frame(width: 3)
            ScrollView {
                Text(info.item.text.isEmpty ? " " : info.item.text)
                    .font(theme.typography.codeDetail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("chat-message-details-text")
    }

    /// "✓ Finished · 10:28 – 10:32 · 4m 12s": how the turn went, then when, as far as the transcript says.
    private func outcome(_ turn: ChatTurn?, summary: ChatTurnSummary?) -> some View {
        let working = turn != nil && turn?.id == info.session?.liveTurnID
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            if working {
                Label("Working", systemImage: "circle.dotted").foregroundStyle(theme.muted)
            } else {
                Label("Finished", systemImage: "checkmark.circle.fill").foregroundStyle(theme.green)
            }
            if let when = ChatTurnSummary.span(turn, duration: summary?.duration) {
                Text("·").foregroundStyle(theme.muted).accessibilityHidden(true)
                Text(when).foregroundStyle(theme.muted).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func facts(_ summary: ChatTurnSummary?) -> some View {
        let usage = info.session?.usage
        let model = info.session.map { session in
            [session.model, session.effort].compactMap { $0 }.joined(separator: " · ")
        }
        if summary?.files.isEmpty == false || usage != nil || model?.isEmpty == false {
            card {
                if let summary, !summary.files.isEmpty {
                    fact("Changes") {
                        Text(ChatTurnSummary.count(summary.files.count, "file"))
                        Text("+\(summary.additions)").foregroundStyle(theme.green)
                        Text("−\(summary.deletions)").foregroundStyle(theme.red)
                    }
                }
                if let usage, usage.input != nil || usage.output != nil || usage.contextRemaining != nil {
                    // The conversation's counts (the agent reports no turn's own), hence "so far".
                    fact("Tokens so far") {
                        if let tokens = ChatTurnSummary.tokens(usage) { Text(tokens).monospacedDigit() }
                        if let remaining = usage.contextRemaining, let window = usage.contextWindow {
                            Text("\(Int(((1 - remaining) * 100).rounded()))% of \(ChatTurnSummary.compact(window)) context")
                                .foregroundStyle(remaining < 0.2 ? theme.yellow : theme.muted).monospacedDigit()
                        }
                    }
                }
                // The conversation's model now: a turn before a switch may have used another.
                if let model, !model.isEmpty { fact("Model") { Text(model) } }
            }
        }
    }

    private func stepSection(_ steps: [ChatStep]) -> some View {
        let folds = ChatStepFold.entries(steps).contains { if case .fold = $0 { true } else { false } }
        let entries = showingAll ? steps.indices.map { ChatStepFold.Entry.step($0) } : ChatStepFold.entries(steps)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("STEPS").tracking(0.6).accessibilityAddTraits(.isHeader)
                Text("\(steps.count)").foregroundStyle(theme.muted.opacity(0.7))
                Spacer()
                if folds {
                    Button(showingAll ? "Show fewer" : "Show all") { showingAll.toggle(); unfolded = [] }
                        .buttonStyle(.plain).foregroundStyle(theme.accent)
                }
            }
            .foregroundStyle(theme.muted)
            card {
                ForEach(entries) { entry in
                    switch entry {
                    case .step(let at):
                        stepRow(steps[at], nested: false)
                    case .fold(let range, let summary):
                        let key = steps[range.lowerBound].id
                        let open = unfolded.contains(key)
                        foldRow(summary, count: range.count, open: open) {
                            if open { unfolded.remove(key) } else { unfolded.insert(key) }
                        }
                        if open {
                            ForEach(steps[range]) { stepRow($0, nested: true) }
                        }
                    }
                }
            }
        }
    }

    private func stepRow(_ step: ChatStep, nested: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: step.failed ? "xmark.octagon" : step.kind.symbol)
                .foregroundStyle(step.failed ? theme.red : theme.muted)
                .frame(width: 16)
                .accessibilityLabel(step.kind.label)
            Text(step.title).font(theme.typography.codeDetail).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(step.detail.map { step.title + "\n" + $0 } ?? step.title)
            if step.running {
                ProgressView().controlSize(.mini)
            } else if step.kind == .patch, step.additions + step.deletions > 0 {
                Text("+\(step.additions)").foregroundStyle(theme.green)
                Text("−\(step.deletions)").foregroundStyle(theme.red)
            } else if step.failed {
                Text("failed").foregroundStyle(theme.red)
            }
        }
        .padding(.leading, nested ? 26 : 0)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    /// The steps between two shown ones, folded: what they did in words, and a disclosure that opens them in place.
    private func foldRow(_ summary: String, count: Int, open: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: "ellipsis").foregroundStyle(theme.muted).frame(width: 16)
                Text(summary).foregroundStyle(theme.muted).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").foregroundStyle(theme.accent).rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary), \(ChatTurnSummary.count(count, "step"))")
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isButton)
    }

    private var record: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { showingRecord.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(showingRecord ? 90 : 0)).frame(width: 8)
                    Text("Record")
                    Spacer(minLength: 0)
                }
                .foregroundStyle(theme.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showingRecord ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("chat-message-record-toggle")
            if showingRecord { ChatMessageRecordView(info: info) }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4, content: content)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func fact<Value: View>(_ name: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).foregroundStyle(theme.muted)
            Spacer(minLength: 12)
            value()
        }
        .lineLimit(1)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The message's record (what its time showed before Info): exact times, identities and the helper record as JSON.
private struct ChatMessageRecordView: View {
    @Environment(\.chatTheme) private var theme
    let info: ChatMessageInfo
    /// A tool's record can carry megabytes of output: the popover shows its start, Copy takes all of it.
    private static let shownBytes = 64 * 1024

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(info.fields, id: \.label) { field in
                    GridRow {
                        Text(field.label).foregroundStyle(theme.muted)
                        Text(field.value).foregroundStyle(theme.ink).lineLimit(1).truncationMode(.middle).help(field.value)
                    }
                }
            }
            Rectangle().fill(theme.border).frame(height: 1)
            if let record = info.record {
                ScrollView {
                    Text(Self.shown(record)).foregroundStyle(theme.ink).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
                .accessibilityIdentifier("chat-message-record")
            } else {
                Text("No helper record: the app made this message and the agent hasn't recorded it yet.")
                    .foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Copy Record") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.text, forType: .string)
                }
                .controlSize(.small)
            }
        }
        .font(theme.typography.detail.monospaced())
        .textSelection(.enabled)
    }

    private static func shown(_ record: String) -> String {
        let bytes = record.utf8.count
        guard bytes > shownBytes else { return record }
        return String(decoding: record.utf8.prefix(shownBytes), as: UTF8.self)
            + "\n… \((bytes - shownBytes).formatted()) more bytes (Copy Record has all of them)"
    }
}
