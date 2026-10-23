import Dictation
import SwiftUI
import UIKit

/// One comment in Create review (R5): the file and its line(s), the first quoted line, the text in two lines. A tap
/// opens the diff at it; a swipe left shows Delete (R5b), a long swipe deletes at once. VoiceOver deletes through the
/// row's action.
struct ReviewSheetCommentRow: View {
    let comment: ReviewComment
    @Binding var opened: UUID?
    let open: () -> Void
    let delete: () -> Void
    /// The live drag's translation while the finger is down.
    @State private var drag: CGFloat?

    /// The Delete button's width; past `deleteDistance` letting go deletes.
    static let deleteWidth: CGFloat = 92
    static let deleteDistance: CGFloat = 220

    /// "42", "45–48", "File", "removed 9".
    static func lines(_ comment: ReviewComment) -> String {
        guard let end = comment.end else { return "File" }
        let start = comment.start ?? end
        let range = start.number == end.number || start.side != end.side ? "\(end.number)" : "\(start.number)–\(end.number)"
        return end.side == .old ? "removed \(range)" : range
    }

    var body: some View {
        let offset = drag.map { min(0, ($0 + (opened == comment.id ? -Self.deleteWidth : 0))) }
            ?? (opened == comment.id ? -Self.deleteWidth : 0)
        Button {
            if opened != nil { withAnimation(.snappy) { opened = nil } } else { open() }
        } label: {
            content
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction(named: "Delete", delete)
        .background(Color.raisedRow)
        .offset(x: offset)
        .background(alignment: .trailing) {
            if offset < 0 {
                Button(action: delete) {
                    VStack(spacing: 4) {
                        Image(systemName: "trash.fill").font(.body.weight(.semibold))
                        Text("Delete").font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: max(Self.deleteWidth, -offset))
                    .frame(maxHeight: .infinity)
                    .background(Color.destructive)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete")
            }
        }
        .clipped()
        .gesture(ReviewSwipeGesture(changed: { drag = $0 }, ended: { translation, velocity in
            let base: CGFloat = opened == comment.id ? -Self.deleteWidth : 0
            let end = base + translation
            drag = nil
            if end < -Self.deleteDistance {
                delete()
            } else {
                withAnimation(.snappy) {
                    opened = end < -Self.deleteWidth / 2 || velocity < -400 ? comment.id : (opened == comment.id ? nil : opened)
                }
            }
        }))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill").font(.caption).foregroundStyle(Color.stateUnread)
                Text(verbatim: FilesPath.name(comment.path)).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(verbatim: Self.lines(comment))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            if let quote = comment.quote.first?.text.trimmingCharacters(in: .whitespaces), !quote.isEmpty {
                Text(verbatim: quote)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.faintFill, in: RoundedRectangle(cornerRadius: 6))
            }
            Text(verbatim: comment.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var accessibilityText: String {
        "\(FilesPath.name(comment.path)), \(ReviewText.location(comment)): \(comment.text)"
    }
}

/// A horizontal pan for a row inside a scroll view: it begins only for a sideways drag, so vertical scrolling keeps
/// working (a SwiftUI `DragGesture` there takes the scroll's touches).
struct ReviewSwipeGesture: UIGestureRecognizerRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let x = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed: changed(x)
        case .ended: ended(x, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed: ended(0, 0)
        default: break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.2
        }
    }
}

/// Create review's overall comment: the composer's text view (never a SwiftUI `TextField`), at least 80 points high,
/// with the composer's dictation (Settings' engine) behind the mic.
struct ReviewSummaryField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    let placeholder: String
    @State private var editor = CodeEditorModel()
    @ReduceMotion private var reduceMotion

    private var dictation: Dictation { .shared }
    private static let owner: AnyHashable = "review-summary"

    var body: some View {
        let dictating = dictation.active(Self.owner)
        HStack(alignment: .top, spacing: 8) {
            CodeEditorField(text: $text, placeholder: placeholder, focus: focus, editor: editor, send: {})
                .frame(height: editor.height)
                .focused(focus)
                // The editor measures itself against the composer's pill (its slot's room taken off).
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { editor.pillWidth = $0 + 14 + 4 + 6 + 28 }
                .accessibilityLabel("Overall comment")
            Button(action: dictate) {
                ZStack {
                    if dictating && dictation.phase == .listening {
                        Circle().fill(Color.red)
                            .scaleEffect(0.85 + 0.3 * CGFloat(dictation.level))
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: dictation.level)
                        RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 10, height: 10)
                    } else if dictating {
                        ProgressView()
                    } else {
                        Image(systemName: "mic").font(.body).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 28, height: 28)
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(-8)
            .padding(.top, 2)
            .accessibilityLabel(dictating ? (dictation.phase == .listening ? "Stop dictation" : "Cancel dictation") : "Dictate")
        }
        // The mockup's 56 points of room inside 12 of padding: the editor's own 7 point inset stands in for part of it.
        .frame(minHeight: 66, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.raisedRow, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { editor.focus() }
        .onDisappear { if dictation.active(Self.owner) { dictation.cancel() } }
    }

    /// Starts dictation, or stops it: what it hears goes after the text as it comes; a cancelled or failed dictation
    /// puts the text back (as the composer's mic).
    private func dictate() {
        let choice = MobileSettings.dictation()
        let binding = $text
        let draft = text
        let end = NSRange(location: (draft as NSString).length, length: 0)
        dictation.toggle(owner: Self.owner, engine: choice.engine, model: choice.model) { update in
            switch update {
            case .heard(let words), .utterance(let words), .finished(let words):
                binding.wrappedValue = DictationText.insert(words, into: draft, selection: end).text
            case .ended: binding.wrappedValue = draft
            }
        }
    }
}

/// Preview: the exact markdown Send or Copy hands over, its lines found again first; selectable, with Copy.
struct ReviewPreviewScreen: View {
    let context: ReviewContext
    @State private var text: String?
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let text {
                    ScrollView {
                        Text(verbatim: text)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    .accessibilityIdentifier("review-preview-text")
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Checking the lines…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.canvas)
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .tint(Color.dispatchPink)
                        .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let text { context.review.outlet.copy(text); copied = true }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(text == nil)
                    .accessibilityLabel(copied ? "Copied" : "Copy")
                }
            }
        }
        .task { text = await context.review.rendered(context: context) }
    }
}
