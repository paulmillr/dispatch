import SwiftUI

/// S6b: the turn's summary in the agent bubble's bottom-right corner, where messengers put a message's time. It shares
/// the bubble's last line when that line leaves room, and takes a line of its own, trailing, when it doesn't. Steps
/// and time and line counts all in the bubble's secondary ink; tapping the bubble opens its details. S6c phrases it
/// "12 steps in 2m · +127 −22", the time rounded to whole minutes (seconds under one).
struct ChatCornerMetaScreen: View {
    var phrased = false
    var body: some View {
        ChatShell {
            ScrollView {
                VStack(spacing: 10) {
                    Spacer(minLength: 60)
                    Bubble(text: "Make billing webhook retries idempotent.", user: true)
                    MetaBubble(text: "Stripe retries the same event with a new attempt counter, so a counter-based guard can double-process. I'll key on the event id instead and persist what we've seen.",
                               steps: 5, time: phrased ? "1m" : "1m 26s", add: 38, del: 4, phrased: phrased)
                    Bubble(text: "Also cover invoice.paid — it has a separate handler.", user: true)
                    MetaBubble(text: "Right, the invoice.paid path has its own handler in src/routes/invoices.ts and bypasses the guard. Moving the check into a shared middleware so both routes get it.",
                               steps: 12, time: phrased ? "2m" : "2m 4s", add: phrased ? 127 : 132, del: phrased ? 22 : 17, phrased: phrased)
                    Bubble(text: "Does the replay command reuse ids?", user: true)
                    MetaBubble(text: "Yes, it keeps the original id.", steps: 1, time: phrased ? "6s" : "6s", phrased: phrased)
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 16)
            }
            .defaultScrollAnchor(.bottom)
        } bottom: {
            Composer()
        } overlay: { EmptyView() }
    }
}

/// S6d: the corner says what the turn changed and when it ended, the time last where messengers put a message's time:
/// "3 files +127 −22 · 10:17", the file's name when it changed one ("idempotent.ts +38 −4 · 10:14"). A turn that changed
/// nothing in a step or two (a plain answer) has no summary; the steps and their time are in the details. S6e: while
/// the agent works, the same corner carries a spinner and the current step with its time, and settles into the
/// summary when the turn ends.
struct ChatCornerTimeScreen: View {
    var working = false
    var body: some View {
        ChatShell {
            ScrollView {
                VStack(spacing: 10) {
                    Spacer(minLength: 60)
                    Bubble(text: "Make billing webhook retries idempotent.", user: true)
                    MetaBubble(text: "Stripe retries the same event with a new attempt counter, so a counter-based guard can double-process. I'll key on the event id instead and persist what we've seen.",
                               summary: "idempotent.ts +38 −4 · 10:14")
                    Bubble(text: "Also cover invoice.paid — it has a separate handler.", user: true)
                    MetaBubble(text: "Right, the invoice.paid path has its own handler in src/routes/invoices.ts and bypasses the guard. Moving the check into a shared middleware so both routes get it.",
                               summary: "3 files +127 −22 · 10:17")
                    Bubble(text: "Does the replay command reuse ids?", user: true)
                    MetaBubble(text: "Yes, it keeps the original id.", summary: nil)
                    if working {
                        Bubble(text: "Add a test for the retry path.", user: true)
                        MetaBubble(text: "Writing a test that delivers the same event twice and checks the second one is skipped.",
                                   summary: "step 4 · 38s", working: true)
                    }
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 16)
            }
            .defaultScrollAnchor(.bottom)
        } bottom: {
            Composer()
        } overlay: { EmptyView() }
    }
}

/// An agent bubble with the turn's summary in its bottom-right corner. The message text ends with an invisible copy of
/// the summary, so the last line reserves its room and the real summary is laid over that spot.
struct MetaBubble: View {
    let text: String
    let summary: String?
    var working = false

    init(text: String, summary: String?, working: Bool = false) {
        self.text = text
        self.summary = summary
        self.working = working
    }

    /// S6b/S6c: "5 steps · 1m 26s · +38 −4", or "5 steps in 1m · +38 −4" phrased.
    init(text: String, steps: Int, time: String, add: Int = 0, del: Int = 0, phrased: Bool = false) {
        var summary = "\(steps) \(steps == 1 ? "step" : "steps")\(phrased ? " in " : " · ")\(time)"
        if add > 0 || del > 0 { summary += " · +\(add) −\(del)" }
        self.init(text: text, summary: summary)
    }

    var body: some View {
        HStack {
            Group {
                if let summary {
                    // The em spaces keep the spinner's room as well.
                    (Text(text).foregroundStyle(.primary) + Text(working ? "   \u{2003}" : "   ")
                        + Text(summary).font(.caption2.monospacedDigit()).foregroundStyle(.clear))
                        .padding(.bottom, 2)
                        .overlay(alignment: .bottomTrailing) {
                            HStack(spacing: 5) {
                                if working { ProgressView().controlSize(.mini) }
                                Text(summary).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.trailing, -2).padding(.bottom, -3)
                        }
                } else {
                    Text(text).foregroundStyle(.primary)
                }
            }
            .font(.body)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.bubbleAgent, in: RoundedRectangle(cornerRadius: 18))
            Spacer(minLength: 60)
        }
    }
}
