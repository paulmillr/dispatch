import SwiftUI

/// R2's open comment: a glass card under its lines (or above the diff for a comment on the file, or one not among the
/// rows): the bubble, "Line 42 · 2m", ×, the text, Edit and Delete, and "1 of 3" with a stepper through the file's
/// comments.
struct ReviewCommentCard: View {
    let comment: ReviewComment
    let now: Date
    /// The comment's place among the file's comments (1-based) and their count.
    let position: Int
    let count: Int
    let close: () -> Void
    let edit: () -> Void
    let delete: () -> Void
    let step: (Int) -> Void

    var body: some View {
        let header = ReviewDiffText.header(comment, now: now)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill").foregroundStyle(Color.stateUnread).accessibilityHidden(true)
                Text(header.location).font(.subheadline.weight(.semibold))
                Text("· \(header.age)").font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                ReviewCardClose(label: "Close comment", action: close)
            }
            .accessibilityElement(children: .contain)
            Text(ReviewCommentText.attributed(comment.text))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions; Spacer(minLength: 8); stepper }
                VStack(alignment: .leading, spacing: 8) { HStack(spacing: 8) { actions }; stepper }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Comment, \(header.location)")
    }

    @ViewBuilder private var actions: some View {
        ReviewCardChip(title: "Edit", symbol: "pencil", label: "Edit comment", action: edit)
        ReviewCardChip(title: "Delete", symbol: "trash", label: "Delete comment", destructive: true, action: delete)
    }

    private var stepper: some View {
        HStack(spacing: 8) {
            Text("\(position) of \(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            HStack(spacing: 0) {
                Button { step(-1) } label: {
                    Image(systemName: "chevron.up").frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .accessibilityLabel("Previous comment")
                Button { step(1) } label: {
                    Image(systemName: "chevron.down").frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .accessibilityLabel("Next comment")
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.bold))
            .foregroundStyle(.primary)
            .background(Color.chipFill, in: Capsule())
            .disabled(count < 2)
        }
    }
}

/// S5: a comment whose quoted lines are no longer in the file, above the diff with an amber edge: "Outdated · was
/// lines 12–14", its quote's first line, the text, why, Keep for the file and Delete.
struct ReviewOutdatedCard: View {
    let comment: ReviewComment
    let close: () -> Void
    let keep: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.caution).accessibilityHidden(true)
                Text("Outdated").font(.subheadline.weight(.semibold))
                Text("· \(ReviewDiffText.was(comment))").font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                ReviewCardClose(label: "Close comment", action: close)
            }
            if let quote = comment.quote.first {
                Text(quote.text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.faintFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityLabel("Quoted: \(quote.text.trimmingCharacters(in: .whitespaces))")
            }
            Text(ReviewCommentText.attributed(comment.text))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Text("The lines this comment quoted are no longer in the file.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ReviewCardChip(title: "Keep for the file", symbol: "doc.text", label: "Keep for the file", action: keep)
                ReviewCardChip(title: "Delete", symbol: "trash", label: "Delete comment", destructive: true, action: delete)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.caution.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Outdated comment, \(ReviewDiffText.was(comment))")
    }
}

/// A card's ×.
struct ReviewCardClose: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-6)
        .accessibilityLabel(label)
    }
}

/// A card's action: a label in a small filled capsule.
struct ReviewCardChip: View {
    let title: String
    let symbol: String
    let label: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(destructive ? Color.destructive : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background(Color.chipFill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A comment's text with its inline Markdown (`code`, emphasis) drawn, as the composer shows it while typing.
enum ReviewCommentText {
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
