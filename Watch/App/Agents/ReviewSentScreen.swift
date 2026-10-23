import SwiftUI

/// K8: the phone just sent a review to an agent; the wrist mirrors it with Undo until the deadline ("Sent from your
/// iPhone. Undo for 8 s, then claude reads it."). Presented by `WatchRoot` when the snapshot brings a review whose Undo
/// is still open (`WatchModel.review`). After the deadline Undo goes and the line says the agent has it.
struct ReviewSentScreen: View {
    let model: WatchModel
    let review: WatchReviewSent

    var body: some View {
        NavigationStack {
            ReviewSentContent(model: model, review: review)
                .navigationTitle("Review")
        }
    }

    /// The phone's own Undo took it back.
    static let withdrawn = "Taken back on your iPhone."

    /// "3 comments · 2 files".
    static func counts(_ review: WatchReviewSent) -> String {
        "\(review.comments) \(review.comments == 1 ? "comment" : "comments") · \(review.files) \(review.files == 1 ? "file" : "files")"
    }

    /// "Sent from your iPhone. Undo for 8 s, then claude reads it." (the window the phone gave), then once it closed,
    /// "Sent from your iPhone. claude has it."
    static func line(_ review: WatchReviewSent, now: Date) -> String {
        let agent = review.agent ?? "the agent"
        guard review.undoable(at: now) else { return "Sent from your iPhone. \(agent) has it." }
        let window = max(1, Int(review.undoUntil.timeIntervalSince(review.sent).rounded()))
        return "Sent from your iPhone. Undo for \(window) s, then \(agent) reads it."
    }
}

/// The screen's content, without its stack (the tests draw it: `ImageRenderer` cannot draw a navigation stack).
struct ReviewSentContent: View {
    let model: WatchModel
    let review: WatchReviewSent

    @State private var undoing = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let withdrawn = model.reviewWithdrawn && model.review?.id == review.id
        let open = review.undoable(at: now) && !withdrawn
        return ScrollView {
            VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(AgentsColor.added)
                        Text("Review sent").font(.headline)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 5) {
                        AgentGlyph(agent: review.agent, size: 12)
                        Text(review.title).font(.footnote).lineLimit(1)
                    }
                    Text(ReviewSentScreen.counts(review)).font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AgentsColor.groupedRow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityElement(children: .combine)
                if open {
                    Button(action: undo) {
                        CapsuleLabel(title: "Undo", symbol: "arrow.uturn.backward", enabled: !undoing)
                    }
                    .buttonStyle(.plain)
                    .disabled(undoing)
                    .accessibilityLabel("Undo")
                    .accessibilityHint("Takes the review back before the agent reads it")
                }
                Text(withdrawn ? ReviewSentScreen.withdrawn : failure ?? ReviewSentScreen.line(review, now: now))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 2)
        }
    }

    private func undo() {
        undoing = true
        Task {
            if let failed = await model.undoReview(review) {
                failure = failed.message
            } else {
                dismiss()
            }
            undoing = false
        }
    }
}
