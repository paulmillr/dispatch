import SwiftUI

/// S6d: the corner says what the turn changed and when it ended, the time last where messengers put a message's time:
/// "3 files +127 −22 · 10:17", the file's name when it changed one ("idempotent.ts +38 −4 · 10:14"). A turn that changed
/// nothing in a step or two (a plain answer) has no summary; the steps and their time are in the details. While the
/// agent works the working row tells the work.
struct ChatCornerTimeScreen: View {
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
