import SwiftUI
import UIKit

/// The composer with code (M5e), with a small interface (the draft, a placeholder, the trailing slot's state and its
/// actions): "+" for attachments, the field, and the slot (mic while the draft is empty, Stop while the agent works
/// with an empty draft, else the pink send; a long press on send steers into the running turn). The field is a
/// `UITextView` that grows with the draft up to a bound and renders its Markdown as you type (`CodeTextView`). With a
/// fenced block in the draft the slot moves under the text, so the panel spans the field. While the field is focused a
/// glass key row above the keyboard offers the backtick, the fence and code pairs, and a paste of several lines offers
/// "Paste as code".
struct CodeComposer: View {
    enum Slot: Equatable { case mic, send, stop }

    @Binding var text: String
    var placeholder: String
    /// The agent works: an empty draft shows Stop.
    var working: Bool
    var stopping = false
    var focus: FocusState<Bool>.Binding
    var send: () -> Void
    var steer: (() -> Void)?
    var stop: () -> Void
    var attach: () -> Void = {}

    @State private var editor = CodeEditorModel()
    @ReduceMotion private var reduceMotion

    static func slot(text: String, working: Bool) -> Slot {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return empty ? (working ? .stop : .mic) : .send
    }

    /// The slot sits under the text once the draft holds a fenced block.
    static func stacked(_ text: String) -> Bool { !ComposerFence.scan(text).isEmpty }

    var body: some View {
        let stacked = Self.stacked(text)
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button("Photo or screenshot", systemImage: "photo") {}.disabled(true)
                    Button("File", systemImage: "doc") {}.disabled(true)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .frame(width: 34, height: 34)
                        .background(Color.primary.opacity(0.1), in: Circle())
                }
                .accessibilityLabel("Attach")
                .padding(.bottom, 1)
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(alignment: .bottom, spacing: 6) {
                        CodeEditorField(text: $text, placeholder: placeholder, focus: focus, editor: editor, send: send)
                            .frame(height: editor.height)
                            .focused(focus)
                        if !stacked { slot.padding(.bottom, 4) }
                    }
                    if stacked { slot }
                }
                .padding(.leading, 14)
                .padding(.trailing, stacked ? 6 : 4)
                .padding(.top, stacked ? 1 : 0)
                .padding(.bottom, stacked ? 6 : 0)
                .frame(minHeight: 36)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(uiColor: .tertiaryLabel), lineWidth: 0.5))
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { editor.pillWidth = $0 }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(alignment: .topLeading) {
                if editor.pasteOffer != nil {
                    Button { editor.pasteAsCode() } label: {
                        Label("Paste as code", systemImage: "curlybraces")
                            .scaledFont(14, weight: .medium, relativeTo: .subheadline)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .frame(minHeight: 34)
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 56)
                    .offset(y: -36)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
                }
            }
            if editor.editing {
                CodeKeyRow { editor.press($0) }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        // Its own height always: the thread above gives way (with the keyboard up, too).
        .fixedSize(horizontal: false, vertical: true)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: editor.pasteOffer != nil)
        .onChange(of: stacked) { _, _ in editor.measure(text: text) }
    }

    @ViewBuilder private var slot: some View {
        switch Self.slot(text: text, working: working) {
        case .mic:
            Button { focus.wrappedValue = true; editor.focus() } label: {
                Image(systemName: "mic")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    // A 44 point target around the 28 point glyph; the outer padding gives the room back to the layout.
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(-8)
            .accessibilityLabel("Dictate")
        case .stop:
            Button(action: stop) {
                RoundedRectangle(cornerRadius: 2).fill(Color(uiColor: .systemBackground)).frame(width: 10, height: 10)
                    .frame(width: 28, height: 28)
                    .background(Color.primary, in: Circle())
                    .opacity(stopping ? 0.5 : 1)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(-8)
            .disabled(stopping)
            .accessibilityLabel("Stop")
        case .send:
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.onAccent)
                .frame(width: 28, height: 28)
                .background(Color.dispatchPink, in: Circle())
                .padding(8)
                .contentShape(Rectangle())
                .onTapGesture(perform: send)
                .onLongPressGesture(minimumDuration: 0.4) { (steer ?? send)() }
                .accessibilityElement()
                .accessibilityLabel("Send")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: "Send into the running turn") { (steer ?? send)() }
                .padding(-8)
        }
    }
}

/// The key row above the keyboard (M5e): the same Liquid Glass capsule as the terminal's key capsule (M6a), keys of
/// equal width with no gaps, mono labels.
struct CodeKeyRow: View {
    let press: (ComposerKey) -> Void
    static let height = 44.0

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ComposerKey.allCases) { key in
                Button { press(key) } label: {
                    Text(key.label)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(key == .tab ? Color(uiColor: .secondaryLabel) : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(KeyCapsuleButtonStyle())
                .accessibilityLabel(key.accessibilityLabel)
            }
        }
        .keyCapsule(height: height)
    }

    @Environment(\.dynamicTypeSize) private var typeSize
    private var height: CGFloat { min(typeSize, .accessibility1).scaled(Self.height, relativeTo: .subheadline) }
}

/// The composer's state outside the text view: its height, whether it is editing, the paste offer.
@MainActor @Observable final class CodeEditorModel {
    var height: CGFloat = 36
    private(set) var editing = false
    private(set) var pasteOffer: NSRange?
    @ObservationIgnored var pillWidth: CGFloat = 0 {
        didSet { if pillWidth != oldValue, let view { measure(text: view.textStorage.string) } }
    }
    @ObservationIgnored weak var view: CodeTextView?
    @ObservationIgnored private var offerExpiry: Task<Void, Never>?

    /// The field's width in the pill for `text` (beside the slot, or full width over it).
    func fieldWidth(text: String) -> CGFloat {
        CodeComposer.stacked(text) ? pillWidth - 14 - 6 : pillWidth - 14 - 4 - 6 - 28
    }

    /// Measures the field for `text` at the width it will have, in the same update as the text.
    func measure(text: String) {
        guard let view else { return }
        let width = pillWidth > 0 ? fieldWidth(text: text) : view.bounds.width
        guard width > 0 else { return }
        let next = view.fittingHeight(width: width)
        if abs(next - height) > 0.25 { height = next }
    }

    func began() { editing = true }
    func ended() { editing = false; dismissOffer() }

    func focus() { view?.becomeFirstResponder() }

    func press(_ key: ComposerKey) {
        dismissOffer()
        view?.press(key)
    }

    func offer(_ range: NSRange?) {
        offerExpiry?.cancel()
        pasteOffer = range
        guard range != nil else { return }
        offerExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.pasteOffer = nil
        }
    }

    func dismissOffer() { if pasteOffer != nil { offer(nil) } }

    func pasteAsCode() {
        guard let range = pasteOffer else { return }
        offer(nil)
        view?.fence(range)
    }
}

/// The `UITextView` in SwiftUI: the binding is the draft; the view reports edits, focus and its height.
struct CodeEditorField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focus: FocusState<Bool>.Binding
    let editor: CodeEditorModel
    var send: () -> Void

    func makeUIView(context: Context) -> CodeTextView {
        let view = CodeTextView()
        view.delegate = context.coordinator
        view.setDraft(text)
        view.placeholder = placeholder
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        editor.view = view
        let coordinator = context.coordinator
        view.changed = { [weak coordinator] text in coordinator?.changed(text) }
        view.pasted = { [weak editor] range in editor?.offer(range) }
        return view
    }

    func updateUIView(_ view: CodeTextView, context: Context) {
        context.coordinator.parent = self
        view.submit = send
        if view.placeholder != placeholder { view.placeholder = placeholder }
        if view.textStorage.string != text {
            view.setDraft(text)
            editor.dismissOffer()
            editor.measure(text: text)
        }
        // A request for focus (a new chat, Reply): only the rising edge, so the field never fights the keyboard.
        let wanted = focus.wrappedValue
        if wanted, !context.coordinator.wantedFocus, !view.isFirstResponder {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        }
        context.coordinator.wantedFocus = wanted
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CodeTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: editor.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditorField
        var wantedFocus = false

        init(parent: CodeEditorField) { self.parent = parent }

        func changed(_ text: String) {
            if parent.text != text { parent.text = text }
            parent.editor.measure(text: text)
        }

        func textViewDidChange(_ textView: UITextView) {
            // CodeTextView restyles and reports the text itself (UITextView.textDidChangeNotification).
            parent.editor.dismissOffer()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? CodeTextView)?.updateCaretContext()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.editor.began()
            if !parent.focus.wrappedValue { parent.focus.wrappedValue = true }
            wantedFocus = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.editor.ended()
            if parent.focus.wrappedValue { parent.focus.wrappedValue = false }
            wantedFocus = false
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let view = textView as? CodeTextView, let string = UIPasteboard.general.string,
                  ComposerMarkdown.offersCode(string), !view.markdown.isCode(at: range.location, in: view.textStorage.string)
            else { return nil }
            let action = UIAction(title: "Paste as Code", image: UIImage(systemName: "curlybraces")) { [weak view] _ in
                view?.pasteAsCode(nil)
            }
            return UIMenu(children: suggestedActions + [action])
        }
    }
}
