import SwiftUI

/// The queue in the working row. Today (Q0) the working row says "thinking · 38s" and, trailing, "4 steps · editing",
/// then Stop and the steps' chevron; the queue is a line of its own under it ("Queued · 2  sends after this turn") that
/// opens to the card. The options fold the queue into the row so the thread ends in one line while the agent works, and
/// in all of them Stop moves beside the clock, away from the trailing controls a thumb reaches for:
///
/// - Q1: the step's kind goes ("4 steps"), a queue capsule (glyph and count, pink) takes its place before the chevron.
/// - Q1b: Q1 tapped: the capsule lit as a selected toggle and the card open under the row, as today's.
/// - Q2: the row's trailing side as controls only: queue capsule and the steps' count inside the chevron's capsule.
/// - Q3: words, not an icon: "thinking · 38s · 2 queued" on the thinking line, "4 steps" trailing.
/// - Q4: the queue as a stack of the user's own bubbles (their colour, the count on the top one).
/// - Q5: the glyphs tried for the capsule.
/// - Q6: no working row (paused after Stop, the agent idle): the queue falls back to today's line, with Resume.
enum QueueRowStyle { case today, capsule, controls, inline, bubbles }

struct QueueRowScreen: View {
    var style: QueueRowStyle
    var open = false
    var body: some View {
        let state = ModeButtonState(shown: .chat, agent: true)
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 10) {
                        Spacer(minLength: 60)
                        Bubble(text: "Make billing webhook retries idempotent.", user: true)
                        BubbleH(text: "Stripe retries the same event with a new attempt counter, so a counter-based guard can double-process. I'll key on the event id instead and persist what we've seen.",
                                summary: "2 files +38 −4 · 10:17")
                        Bubble(text: "Also cover invoice.paid — it has a separate handler.", user: true)
                        BubbleH(text: "The invoice.paid path has its own handler in src/routes/invoices.ts and bypasses the guard. Moving the check into a shared middleware so both routes get it.")
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                    WorkingRowMock(style: style, open: open)
                    if style == .today || open {
                        QueueCardMock(open: open)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
                }
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .safeAreaBar(edge: .bottom) { Composer() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ModeTabHeader(title: "Billing webhook retries", subtitle: AnyView(TabSubtitle(folder: "app")), state: state, layout: .hostLeading) }
        }
    }
}

/// The app's working row (`ChatWorkingRow`), still: the hairline with the glint a third along it, the ◆ with its
/// satellite, "thinking" with the light on it, the clock; the trailing side by `style`.
struct WorkingRowMock: View {
    var style: QueueRowStyle
    var open = false
    var queued = 2
    var glyph = QueueGlyph.symbol
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color("ThinkingBorder")).frame(height: 1)
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, .dispatchPink, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.3).opacity(0.7).offset(x: g.size.width * 0.05)
                    }
                }
            HStack(spacing: 8) {
                ThinkingGlyphMock()
                Text("thinking").font(.subheadline.weight(.semibold))
                    .foregroundStyle(LinearGradient(colors: [Color("ShimmerBase"), Color("ShimmerHighlight"), Color("ShimmerBase")],
                                                    startPoint: .init(x: -0.2, y: 0.5), endPoint: .init(x: 0.7, y: 0.5)))
                Text("·").foregroundStyle(.tertiary)
                Text("38s").monospacedDigit()
                if style == .inline {
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(queued) queued").foregroundStyle(Color.dispatchPink)
                }
                // Stop beside the clock, away from the trailing controls a thumb reaches for.
                StopDisc().padding(.leading, 2)
                Spacer(minLength: 8)
                switch style {
                case .today:
                    stepsText("4 steps · editing")
                case .capsule:
                    stepsText("4 steps")
                    QueueCapsule(count: queued, lit: open, glyph: glyph)
                case .controls:
                    QueueCapsule(count: queued, lit: open, glyph: glyph)
                case .inline:
                    stepsText("4 steps")
                case .bubbles:
                    stepsText("4 steps")
                    QueueBubbleStack(count: queued)
                }
                if style == .controls { StepsCapsule(count: 4) } else { ChevronDisc() }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
            .padding(.horizontal, 16)
        }
    }

    private func stepsText(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
    }
}

struct ThinkingGlyphMock: View {
    var body: some View {
        ZStack {
            Text("◆").font(.system(size: 16 * 0.72)).foregroundStyle(Color.dispatchPink)
            Circle().fill(Color.dispatchPink).frame(width: 4, height: 4).shadow(color: .dispatchPink, radius: 3)
                .offset(y: -8).rotationEffect(.degrees(130))
        }
        .frame(width: 16, height: 16)
    }
}

/// Stop as a quiet control: the square in primary ink on the chevron's chip fill, not a solid primary disc (the app's
/// white disc in dark mode was the loudest thing in the row).
struct StopDisc: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.85)).frame(width: 9, height: 9)
            .frame(width: 28, height: 28)
            .background(Color.chipFill, in: Circle())
    }
}

struct ChevronDisc: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(Color.chipFill, in: Circle())
    }
}

/// Q2: the steps' count and the disclosure in one capsule, "4 ›".
struct StepsCapsule: View {
    let count: Int
    var body: some View {
        HStack(spacing: 3) {
            Text("\(count)").font(.footnote.weight(.semibold)).monospacedDigit()
            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.chipFill, in: Capsule())
    }
}

enum QueueGlyph: CaseIterable {
    case symbol, ellipsis, tray, stack, list, forward
    var name: String {
        switch self {
        case .symbol: "arrow.up.message"
        case .ellipsis: "ellipsis.message"
        case .tray: "tray.full"
        case .stack: "square.stack"
        case .list: "list.number"
        case .forward: "text.line.last.and.arrowtriangle.forward"
        }
    }
}

/// The queue as a capsule the size of Stop: glyph and count in pink on a faint pink fill; lit (the card open) the fill
/// is the accent and the ink on it, as a selected toggle.
struct QueueCapsule: View {
    let count: Int
    var lit = false
    var glyph = QueueGlyph.symbol
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: glyph.name).font(.footnote.weight(.semibold))
            Text("\(count)").font(.footnote.weight(.semibold)).monospacedDigit()
        }
        .foregroundStyle(lit ? Color.onAccent : Color.dispatchPink)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(lit ? Color.dispatchPink : Color.dispatchPink.opacity(0.14), in: Capsule())
    }
}

/// Q4: the queued messages as two of the user's bubbles stacked, the count on the front one.
struct QueueBubbleStack: View {
    let count: Int
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 7).fill(Color("BubbleUser").opacity(0.45))
                .frame(width: 26, height: 20).offset(x: -5, y: -5)
            Text("\(count)").font(.caption.weight(.bold)).monospacedDigit()
                .foregroundStyle(Color("BubbleUserText"))
                .frame(width: 26, height: 20)
                .background(Color("BubbleUser"), in: RoundedRectangle(cornerRadius: 7))
        }
        .frame(width: 34, height: 28)
    }
}

/// Today's queue (`ChatQueueCard`): folded, the line "Queued · 2  sends after this turn"; open, the card with its rows.
struct QueueCardMock: View {
    var open = false
    var paused = false
    let rows = ["Also add a test that delivers the same event twice.", "Then run the webhook suite and tell me what fails."]
    var body: some View {
        if open {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Queued · \(rows.count)").font(.footnote.weight(.semibold)).foregroundStyle(Color.dispatchPink)
                    Text(subtitle).font(.caption).foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    Text("Done").font(.footnote).foregroundStyle(Color.dispatchPink).padding(.horizontal, 6)
                }
                .frame(minHeight: 36).padding(.leading, 16).padding(.trailing, 12)
                .overlay(alignment: .bottom) { Hairline() }
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    HStack(spacing: 12) {
                        Text(row).font(.subheadline).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.up.circle.fill").font(.title3).foregroundStyle(Color.dispatchPink).frame(width: 36, height: 36)
                        Image(systemName: "line.3.horizontal").font(.subheadline).foregroundStyle(.tertiary).frame(width: 28, height: 36)
                    }
                    .padding(.vertical, 10).padding(.leading, 16).padding(.trailing, 12).frame(minHeight: 52)
                    if i < rows.count - 1 { Hairline() }
                }
            }
            .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.dispatchPink.opacity(0.35), lineWidth: 0.5))
            .frame(width: 320)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 4)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Queued · \(rows.count)").font(.footnote.weight(.semibold)).foregroundStyle(Color.dispatchPink)
                Text(subtitle).font(.caption).foregroundStyle(.tertiary)
                if paused { Text("Resume").font(.footnote).foregroundStyle(Color.dispatchPink).padding(.leading, 6) }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 4)
        }
    }
    private var subtitle: String { paused ? "paused after Stop" : "sends after this turn" }
}

/// Q5: the capsule's glyph candidates, each in its row, folded and lit.
struct QueueGlyphsScreen: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(QueueGlyph.allCases, id: \.self) { glyph in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(glyph.name).font(.caption.monospaced()).foregroundStyle(.secondary).padding(.horizontal, 16)
                            WorkingRowMock(style: .capsule, glyph: glyph)
                            HStack(spacing: 10) {
                                QueueCapsule(count: 2, glyph: glyph)
                                QueueCapsule(count: 2, lit: true, glyph: glyph)
                                QueueCapsule(count: 12, glyph: glyph)
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
                .padding(.vertical, 16)
            }
            .background(Color.canvas)
            .navigationTitle("Queue glyph")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Q6: the agent stopped with messages still queued: no working row, so the queue keeps today's line, Resume in it.
struct QueuePausedScreen: View {
    var body: some View {
        let state = ModeButtonState(shown: .chat, agent: true)
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    Spacer(minLength: 60)
                    Bubble(text: "Make billing webhook retries idempotent.", user: true)
                    BubbleH(text: "Stripe retries the same event with a new attempt counter, so a counter-based guard can double-process. I'll key on the event id instead and persist what we've seen.",
                            summary: "2 files +38 −4 · 10:17")
                    Bubble(text: "Also cover invoice.paid — it has a separate handler.", user: true)
                    BubbleH(text: "The invoice.paid path has its own handler in src/routes/invoices.ts and bypasses the guard.",
                            summary: "Stopped · 10:21")
                    QueueCardMock(paused: true)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .safeAreaBar(edge: .bottom) { Composer() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ModeTabHeader(title: "Billing webhook retries", subtitle: AnyView(TabSubtitle(folder: "app")), state: state, layout: .hostLeading) }
        }
    }
}
