import SwiftUI

// Y1: Reply as the app ships it (`ChatReplyBar`, `ChatReplyQuote`), as Messages and Slack reply: Reply puts "Replying
// to Claude" and the message's first sentence over the composer, which stays empty for the user's words; the sent
// bubble carries the excerpt as a small quote on top, and the agent gets only that excerpt as the quote (it has the
// whole message already). Y1a writing, Y1b sent.

enum ReplySample {
    static let paragraphs = [
        "Stripe retries the same event with a new attempt counter, so a counter-based guard can double-process.",
        "I'll key on the event id instead and persist what we've seen in a processed_events table with a unique index.",
        "Two options for the window: keep ids for 30 days (Stripe's retry horizon is 3 days), or forever and prune with a nightly job.",
        "I went with 30 days. Say if you'd rather keep them.",
    ]
    static var message: String { paragraphs.joined(separator: "\n\n") }
    static let reply = "Keep them forever, storage is cheap"
}

/// The thread both ideas start from: the user's ask, the agent's long answer.
private struct ReplyThread: View {
    var dimmed = false
    var sent: AnyView? = nil
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Spacer(minLength: 40)
                Bubble(text: "Make billing webhook retries idempotent.", user: true)
                Bubble(text: ReplySample.message, user: false)
                if let sent { sent }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
        .defaultScrollAnchor(.bottom)
    }
}

// MARK: Y1 reply bar

/// Y1a: Reply pressed: the bar over the composer, the composer empty for the user's words.
struct ReplyBarScreen: View {
    var sent = false

    var body: some View {
        ChatShell {
            ReplyThread(sent: sent ? AnyView(ReplySentBubble(excerpt: ReplySample.paragraphs[0], text: ReplySample.reply)) : nil)
        } bottom: {
            if sent {
                Composer()
            } else {
                VStack(spacing: 6) {
                    ReplyBar(excerpt: ReplySample.paragraphs[0])
                    Composer(text: ReplySample.reply)
                }
            }
        } overlay: { EmptyView() }
    }
}

/// Over the composer while replying: the accent's bar, who is answered, the message's first words, ✕.
struct ReplyBar: View {
    let excerpt: String
    var body: some View {
        HStack(spacing: 10) {
            Capsule().fill(Color.dispatchPink).frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to Claude").font(.caption.weight(.semibold)).foregroundStyle(Color.dispatchPink)
                Text(excerpt).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                .frame(width: 26, height: 26).background(Color.chipFill, in: Circle())
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
    }
}

/// Y1b: the sent reply: the excerpt as a quote at the bubble's top (two lines at most), the user's words under it.
struct ReplySentBubble: View {
    let excerpt: String
    let text: String
    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Capsule().fill(Color("BubbleUserText").opacity(0.55)).frame(width: 2.5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Claude").font(.caption.weight(.semibold))
                        Text(excerpt).font(.footnote).lineLimit(2)
                    }
                    .opacity(0.8)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(text).font(.system(.callout, design: .rounded)).lineSpacing(2)
                    .padding(.horizontal, 4)
            }
            .foregroundStyle(Color("BubbleUserText"))
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 9)
            .background(Color("BubbleUser"), in: UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: 20, bottomLeading: 20, bottomTrailing: 6, topTrailing: 20), style: .continuous))
            .frame(maxWidth: 370 * 0.78, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
