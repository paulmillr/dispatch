import SwiftUI
import UIKit

/// Times on swipe, as Messages shows them: a drag toward the leading edge slides the user's messages over to show their
/// times past them (`ChatRevealSent`), and fades the agent's times and turn summaries in at the thread's trailing edge
/// beside replies that stay where they are (`ChatRevealReceived`); letting go hides them again. The times stay out of
/// the bubbles' corners; VoiceOver reads a reply's as the bubble's value (`ChatCorner.spokenOnly`).
///
/// How far the swipe has pulled. Only the rows' reveal wrappers read it, so a drag redraws none of the rows' content.
@MainActor @Observable final class ChatReveal {
    var offset: CGFloat = 0
    /// The pull that shows the times in full (`ChatRevealPan.width`).
    private(set) var width: CGFloat = 1

    /// How far the times have come in, 0 to 1.
    var progress: CGFloat { min(1, offset / max(width, 1)) }

    /// Follows a drag `translation` along x: toward the leading edge up to `width`, then a fifth as far.
    func drag(_ translation: CGFloat, width: CGFloat) {
        self.width = width
        offset = Self.offset(translation, width: width)
    }

    nonisolated static func offset(_ translation: CGFloat, width: CGFloat) -> CGFloat {
        let pulled = max(0, -translation)
        return pulled <= width ? pulled : width + (pulled - width) / 5
    }

    func release(reduceMotion: Bool) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0)) { offset = 0 }
    }
}

/// A user's message as the swipe shows it: the row slides toward the leading edge, its time coming in after it from
/// past the trailing edge (`ChatRevealDetail`).
struct ChatRevealSent<Content: View>: View {
    let reveal: ChatReveal
    let corner: ChatCorner?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if let corner { ChatRevealDetail(corner: corner) }
            }
            .offset(x: -reveal.offset)
    }
}

/// A reply as the swipe shows it, as Messages shows a received message: the bubble stays where it is and its time fades
/// in at the thread's trailing edge, in the room beside the bubble, on two lines where it needs them ("Yesterday" over
/// "10:17").
struct ChatRevealReceived<Content: View>: View {
    let reveal: ChatReveal
    let time: String?
    @ViewBuilder var content: Content
    @Environment(\.chatColumnWidth) private var column
    /// The bubble's drawn width (`ChatBubbleWidth`).
    @State private var bubble: CGFloat = 0

    /// Between the bubble and its time.
    static var gap: CGFloat { 6 }
    /// The narrowest the time gets: a day's word ("Yesterday") on a line, over the bubble's rounded corner at worst.
    static var narrowest: CGFloat { 50 }

    /// The time's width beside a reply `bubble` points wide in a `column`: the room right of it less the gap.
    static func room(column: CGFloat, bubble: CGFloat) -> CGFloat { max(narrowest, column - bubble - gap) }

    var body: some View {
        if let time {
            content
                .onPreferenceChange(ChatBubbleWidth.self) { bubble = $0 }
                .overlay(alignment: .bottomTrailing) {
                    ChatTurnCorner(text: time, wrapped: true)
                        .frame(width: Self.room(column: column, bubble: bubble), alignment: .trailing)
                        .padding(.bottom, 9)
                        .opacity(reveal.progress)
                        .accessibilityHidden(true)
                }
        } else {
            content
        }
    }
}

/// An agent bubble's drawn width (`ChatBubble`), for the swipe's room beside it (`ChatRevealReceived`).
struct ChatBubbleWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The swipe: a pan that begins only for a drag toward the leading edge, so the thread's vertical scrolling keeps
/// working (as `ReviewSwipeGesture`); nothing begins while the setting is off.
struct ChatRevealPan: UIGestureRecognizerRepresentable {
    let reveal: ChatReveal
    /// How far the thread slides: the times' column and its gap.
    let width: CGFloat
    let reduceMotion: Bool

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {}

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: reveal.drag(recognizer.translation(in: recognizer.view).x, width: width)
        case .ended, .cancelled, .failed: reveal.release(reduceMotion: reduceMotion)
        default: break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.x < 0 && abs(velocity.x) > abs(velocity.y) * 1.2
        }
    }
}

/// A user message's time as the swipe shows it (`ChatRevealSent`): a column past the row's trailing edge, at the
/// bubble's foot, which the row's slide brings in. Drawn only.
struct ChatRevealDetail: View {
    let corner: ChatCorner
    @ScaledMetric(relativeTo: .caption2) private var width = ChatRevealDetail.width

    /// The column's width at the default text size (the thread scales it the same way): a time, "Yesterday" over
    /// "10:17" where it needs two lines.
    static let width: CGFloat = 72
    /// Between the row's trailing edge and the column.
    static let gap: CGFloat = 16

    var body: some View {
        ChatTurnCorner(text: Self.lines(corner.room), wrapped: true)
            .frame(width: width, alignment: .trailing)
            .padding(.bottom, 9)
            .offset(x: width + Self.gap)
            .accessibilityHidden(true)
    }

    /// "2 files +4 −4 · 10:17" as "2 files +4 −4" over "10:17".
    static func lines(_ corner: String) -> String {
        corner.replacingOccurrences(of: " · ", with: "\n")
    }
}

extension ChatCorner {
    /// The corner for VoiceOver only: no room in the text and nothing drawn; the swipe's column draws it.
    var spokenOnly: ChatCorner {
        ChatCorner(room: "", fits: true, view: { _ in AnyView(EmptyView()) }, spoken: spoken, hint: hint, drawn: false)
    }
}
