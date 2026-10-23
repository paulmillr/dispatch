import Dictation
import SwiftUI

/// R4: the comment composer, risen from the bottom in glass (the selection pill morphs into it): the place as a chip
/// ("Lines 45–48 ×", × cancels), the first quoted line, the text in the phone's code text view (`CodeEditorField`, as
/// the chat composer; never a SwiftUI text field), the mic while it is empty and the pink send arrow. It rides above
/// the keyboard as the screen's bottom bar.
struct ReviewDiffComposer: View {
    @Binding var text: String
    let location: String
    let quote: String?
    let editing: Bool
    /// Raises the keyboard on appear (the Debug demo's still shows the composer without it, as R4 draws it).
    var focusOnAppear = true
    let namespace: Namespace.ID
    let cancel: () -> Void
    let send: () -> Void

    @FocusState private var focused: Bool
    @State private var editor = CodeEditorModel()
    @ReduceMotion private var reduceMotion

    /// Whose dictation the mic starts (`Dictation` keeps one at a time).
    static let dictationOwner = "review-comment"
    private var dictation: Dictation { .shared }
    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble.fill").foregroundStyle(Color.stateUnread).accessibilityHidden(true)
                    Text(location).font(.caption.weight(.semibold)).lineLimit(1)
                    Button(action: cancel) {
                        Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                            .frame(width: 22, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(editing ? "Cancel editing" : "Cancel comment")
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .frame(minHeight: 28)
                .background(Color.chipFill, in: Capsule())
                if let quote {
                    Text(quote.trimmingCharacters(in: .whitespaces))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .accessibilityLabel("Quoted: \(quote.trimmingCharacters(in: .whitespaces))")
                }
                Spacer(minLength: 0)
            }
            if let status = dictationStatus {
                Label(status.text, systemImage: status.failed ? "exclamationmark.triangle.fill" : "waveform")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(status.failed ? Color.destructive : Color.secondary)
                    .lineLimit(2)
                    .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: 10) {
                CodeEditorField(text: $text, placeholder: editing ? "Edit the comment" : "Comment", focus: $focused,
                                editor: editor, send: send)
                    .frame(height: editor.height)
                    .focused($focused)
                    // The field measures its height at its own width (the chat composer's sums assume its pill).
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { editor.pillWidth = $0 + 52 }
                    .accessibilityLabel("Comment text")
                slot
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .glassEffectID("composer", in: namespace)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: dictationStatus == nil)
        .onAppear { if focusOnAppear { focused = true } }
        .onDisappear { if dictation.active(Self.dictationOwner) { dictation.cancel() } }
    }

    @ViewBuilder private var slot: some View {
        let dictating = dictation.active(Self.dictationOwner)
        HStack(spacing: 8) {
            if empty || dictating {
                Button(action: dictate) {
                    Group {
                        if dictating && dictation.phase == .listening {
                            Circle().fill(Color.red)
                                .overlay { RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 10, height: 10) }
                        } else if dictating {
                            ProgressView()
                        } else {
                            Image(systemName: "mic").font(.body).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dictating ? (dictation.phase == .listening ? "Stop dictation" : "Cancel dictation") : "Dictate")
            }
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Color.onAccent)
                    .frame(width: 34, height: 34)
                    .background(Color.dispatchPink, in: Circle())
                    .opacity(empty ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(empty)
            .accessibilityLabel(editing ? "Save comment" : "Send comment")
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var dictationStatus: (text: String, failed: Bool)? {
        if dictation.active(Self.dictationOwner) {
            switch dictation.phase {
            case .idle: return nil
            case .starting: return ("Starting…", false)
            case .listening: return ("Listening…", false)
            case .transcribing: return ("Transcribing…", false)
            }
        }
        return dictation.error(for: Self.dictationOwner).map { ($0, true) }
    }

    /// Dictates into the comment with Settings' engine, as the chat composer's mic: what it hears goes after the text as
    /// it comes; a cancelled or failed dictation puts the text back.
    private func dictate() {
        let choice = MobileSettings.dictation()
        let binding = $text
        let draft = text
        let end = NSRange(location: (draft as NSString).length, length: 0)
        dictation.toggle(owner: Self.dictationOwner, engine: choice.engine, model: choice.model) { update in
            switch update {
            case .heard(let words), .utterance(let words), .finished(let words):
                binding.wrappedValue = DictationText.insert(words, into: draft, selection: end).text
            case .ended: binding.wrappedValue = draft
            }
        }
    }
}
