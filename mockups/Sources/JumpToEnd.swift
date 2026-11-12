import SwiftUI

// C7: Jump to latest as the app ships it (`ChatJumpButton`): a round glass button at the trailing edge just above the
// composer, an arrow down, whenever the thread is scrolled up; newer rows put their count on it as a badge. Out of the
// reading column's way, where the thumb rests. The thread is read from its top, the end several messages below.

struct JumpToEndScreen: View {
    /// Newer rows came while scrolled up.
    var unseen = 0

    var body: some View {
        ChatShell {
            ScrollView {
                VStack(spacing: 10) {
                    Bubble(text: "Make billing webhook retries idempotent.", user: true)
                    BubbleH(text: "Stripe retries the same event with a new attempt counter, so a counter-based guard can double-process. I'll key on the event id instead and persist what we've seen.")
                    Bubble(text: "Also cover invoice.paid — it has a separate handler.", user: true)
                    Bubble(text: "Right, the invoice.paid path has its own handler in src/routes/invoices.ts and bypasses the guard.", user: false)
                    Bubble(text: "What about the Stripe CLI's replay command, does it reuse event ids?", user: true)
                    Bubble(text: "Yes, stripe events resend keeps the original id, so the guard treats it as a retry and skips it. That is what we want for replays of real events.", user: false)
                    Spacer(minLength: 300)
                }
                .padding(.horizontal, 16).padding(.top, 8)
            }
            .defaultScrollAnchor(.top)
        } bottom: {
            Composer()
        } overlay: {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    CornerJump(unseen: unseen)
                }
            }
            .padding(.trailing, 16).padding(.bottom, 12)
        }
    }
}

/// C7: the arrow in a glass circle; newer rows badge it with their count.
private struct CornerJump: View {
    let unseen: Int
    var body: some View {
        Image(systemName: "arrow.down")
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: Circle())
            .overlay(alignment: .topTrailing) {
                if unseen > 0 {
                    Text("\(unseen)")
                        .font(.caption2.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                        .background(Color.stateUnread, in: Capsule())
                        .offset(x: 4, y: -4)
                }
            }
    }
}
