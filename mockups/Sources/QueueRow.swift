import SwiftUI

/// The queue as the app ships it (`ChatQueuedBubbles`, docs/ios.md, Chat): as Messages' Send Later, each queued message
/// is one of the user's bubbles, faded, at the thread's end under the working row, the last one captioned with when the
/// queue sends. Q1 the queue while the agent works; Q1b a queued bubble tapped: its menu, every action named; Q1c its
/// Edit: the text in the composer, a bar with Cancel, send a ✓ that saves it in its place; Q6 paused after Stop, no
/// working row, Resume under the last bubble.
struct QueueRowScreen: View {
    enum Variant { case queued, menu, editing }
    var variant = Variant.queued
    let queued = ["Also add a test that delivers the same event twice.", "Then run the webhook suite and tell me what fails."]

    var body: some View {
        let state = ModeButtonState(shown: .chat, agent: true)
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 10) {
                        Spacer(minLength: 60)
                        Bubble(text: "Make billing webhook retries idempotent.", user: true)
                        BubbleH(text: "Stripe retries the same event with a new attempt counter, so a counter-based guard can double-process. I'll key on the event id instead and persist what we've seen.")
                        Bubble(text: "Also cover invoice.paid — it has a separate handler.", user: true)
                        BubbleH(text: "The invoice.paid path has its own handler in src/routes/invoices.ts and bypasses the guard. Moving the check into a shared middleware so both routes get it.")
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                    WorkingRowMock()
                    QueuedBubblesMock(rows: queued, editing: variant == .editing ? 0 : nil, caption: "2 queued · sends after this turn")
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .safeAreaBar(edge: .bottom) {
                if variant == .editing {
                    VStack(spacing: 0) {
                        QueueEditBarMock()
                        Composer(text: queued[0], saving: true)
                    }
                } else {
                    Composer(placeholder: "Message")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { CapsuleTabHeader(title: "Billing webhook retries", subtitle: AnyView(TabSubtitle(folder: "app")), state: state) }
            .overlay { if variant == .menu { QueueMenuOverlay(text: queued[0]) } }
        }
    }
}

/// The queued messages: the user's bubbles, faded; under one being edited "Editing in the composer"; under the last,
/// when the queue sends (and Resume after Stop).
struct QueuedBubblesMock: View {
    let rows: [String]
    var editing: Int?
    let caption: String
    var resume = false

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                VStack(spacing: 5) {
                    QueuedBubble(text: row)
                    if editing == index { QueueCaption(text: "Editing in the composer") }
                    if index == rows.count - 1 {
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            Text(caption).font(.caption).foregroundStyle(Color(uiColor: .tertiaryLabel))
                            if resume { Text("Resume").font(.caption.weight(.semibold)).foregroundStyle(Color.dispatchPink) }
                        }
                        .padding(.horizontal, 6)
                    }
                }
            }
        }
    }
}

/// A queued message: the user's bubble, faded (`ChatUserMessage`'s `faded`).
struct QueuedBubble: View {
    let text: String
    var body: some View { Bubble(text: text, user: true).opacity(0.5) }
}

struct QueueCaption: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(Color(uiColor: .tertiaryLabel))
            .padding(.horizontal, 6).frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Over the composer while it edits a queued message (`ChatQueueEditBar`).
struct QueueEditBarMock: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil").font(.caption.weight(.semibold))
            Text("Editing queued message").font(.footnote.weight(.semibold))
            Spacer(minLength: 8)
            Text("Cancel").font(.footnote.weight(.semibold)).foregroundStyle(Color.dispatchPink)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(minHeight: 32)
    }
}

/// Q1b: the tapped bubble lifted in its place over the blurred thread, its menu above it (the bubble sits low, as the
/// system places a menu with no room under its view): Send Now saying it interrupts the turn, Edit, Move Down, Delete.
struct QueueMenuOverlay: View {
    let text: String
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            Color.black.opacity(0.2).ignoresSafeArea()
            VStack(alignment: .trailing, spacing: 10) {
                VStack(spacing: 0) {
                    QueueMenuItem(title: "Send Now", detail: "Interrupts the current turn", symbol: "arrow.up.circle")
                    Hairline()
                    QueueMenuItem(title: "Edit", symbol: "pencil")
                    Hairline()
                    QueueMenuItem(title: "Move Down", symbol: "arrow.down")
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 8)
                    QueueMenuItem(title: "Delete", symbol: "trash", destructive: true)
                }
                .frame(width: 250)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                QueuedBubble(text: text)
            }
            .padding(.horizontal, 16)
            // Over the first queued bubble, where Q1 draws it (measured on the iPhone Air's 874 points).
            .padding(.bottom, 80)
        }
    }
}

struct QueueMenuItem: View {
    let title: String
    var detail: String?
    let symbol: String
    var destructive = false
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Image(systemName: symbol).font(.body)
        }
        .foregroundStyle(destructive ? Color.red : Color.primary)
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
    }
}

/// The app's working row (`ChatWorkingRow`), still: the hairline with the glint a third along it, the ◆ with its
/// satellite, "thinking" with the light on it, the clock, Stop; trailing, the steps and the chevron.
struct WorkingRowMock: View {
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
                // Stop beside the clock, away from the trailing controls a thumb reaches for.
                StopDisc().padding(.leading, 2)
                Spacer(minLength: 8)
                Text("4 steps").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                ChevronDisc()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
            .padding(.horizontal, 16)
        }
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

/// Q6: the agent stopped with messages still queued: no working row; the last bubble's caption says the queue is
/// paused, Resume beside it.
struct QueuePausedScreen: View {
    var body: some View {
        let state = ModeButtonState(shown: .chat, agent: true)
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    Spacer(minLength: 60)
                    Bubble(text: "Make billing webhook retries idempotent.", user: true)
                    BubbleH(text: "Stripe retries the same event with a new attempt counter, so a counter-based guard can double-process. I'll key on the event id instead and persist what we've seen.")
                    Bubble(text: "Also cover invoice.paid — it has a separate handler.", user: true)
                    BubbleH(text: "The invoice.paid path has its own handler in src/routes/invoices.ts and bypasses the guard.")
                    QueuedBubblesMock(rows: ["Also add a test that delivers the same event twice.",
                                             "Then run the webhook suite and tell me what fails."],
                                      caption: "2 queued · paused after Stop", resume: true)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .safeAreaBar(edge: .bottom) { Composer(placeholder: "Message") }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { CapsuleTabHeader(title: "Billing webhook retries", subtitle: AnyView(TabSubtitle(folder: "app")), state: state) }
        }
    }
}
