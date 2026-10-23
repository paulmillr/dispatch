import Dictation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The composer with code (M5e), with a small interface (the draft, a placeholder, the trailing slot's state and its
/// actions): "+" for attachments, the field, and the slot (mic while the draft is empty, Stop while the agent works
/// with an empty draft, else the pink send; a long press on send steers into the running turn). The mic dictates with
/// Settings' engine (`Dictation`): what it hears fills the draft as it comes, and tapped again it stops; while it listens a
/// capsule above the field says so, and after a failure, why. The field is a
/// `UITextView` that grows with the draft up to a bound and renders its Markdown as you type (`CodeTextView`). With a
/// fenced block in the draft the slot moves under the text, so the panel spans the field. While the field is focused a
/// glass key row above the keyboard offers the backtick, the fence and code pairs, and a paste of several lines offers
/// "Paste as code". With a hardware keyboard the keys follow the Mac's composer (`ComposerHardwareKeys`): Return sends
/// and Shift-Return starts a new line, which puts the draft in editor mode, where Return inserts newlines and ⌘Return
/// sends; ⌥Return steers, ⌘E toggles editor mode, Esc leaves editor mode, else stops a running turn, else leaves the
/// field. The key row stays away then: the keyboard has every key it offers. With `attachments`, "+" picks photos or
/// files, an image pasted into the field or a drop on the composer attaches, and a strip above the field shows them
/// (docs/ios.md, Attachments); a draft with attachments sends without text.
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
    /// What "+", a paste and a drop attach to and the strip shows; nil: attaching is not offered.
    var attachments: ComposerAttachments? = nil
    /// Whose dictation the mic starts and shows (the conversation).
    var dictationOwner: AnyHashable = "composer"
    /// The draft's editor mode (`ChatDraft.multiline`): Return inserts a newline from a hardware keyboard.
    var multiline: Binding<Bool> = .constant(false)
    /// A long press on the mic starts conversation mode (C5); nil: the mic only dictates.
    var converse: (() -> Void)? = nil

    @State private var editor = CodeEditorModel()
    @State private var keyboard = HardwareKeyboard.shared
    @State private var choosingPhotos = false
    @State private var choosingFiles = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var dropTargeted = false
    @State private var visible = false
    @ReduceMotion private var reduceMotion

    /// The trailing slot: send for text or attachments, else Stop while the agent works, else the mic.
    static func slot(text: String, working: Bool, dictating: Bool = false, attached: Bool = false) -> Slot {
        if dictating { return .mic }
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !attached
        return empty ? (working ? .stop : .mic) : .send
    }

    /// Edit › Attach Files… (⇧⌘A, `MobileCommands`): the composer on screen opens its file picker.
    static let attachRequested = Notification.Name("DispatchMobileComposerAttach")

    private var attaching: Bool { attachments?.enabled == true && (attachments?.remaining ?? 0) > 0 }
    /// Stored attachments, not running or failed uploads: what a send carries.
    private var attached: Bool { attachments?.chips.contains { !$0.uploading && $0.error == nil } == true }

    private var dictation: Dictation { .shared }

    /// The key row above the keyboard shows while the field edits, unless a hardware keyboard is attached: then there
    /// is no software keyboard to ride on and the keys it offers are on the keyboard.
    static func showsKeyRow(editing: Bool, hardwareKeyboard: Bool) -> Bool { editing && !hardwareKeyboard }

    /// The editor-mode hint shows only where Return means something else in it: with a hardware keyboard.
    static func showsEditorHint(multiline: Bool, hardwareKeyboard: Bool) -> Bool { multiline && hardwareKeyboard }

    /// Carries out a hardware key's action (the field inserts newlines and leaves focus itself).
    private func perform(_ action: ComposerKeyAction) {
        switch action {
        case .send: send()
        case .steer: (steer ?? send)()
        case .stop: stop()
        case .toggleEditor: multiline.wrappedValue.toggle()
        case .leaveEditor: multiline.wrappedValue = false
        case .newline, .resign, .system: break
        }
    }

    /// The slot sits under the text once the draft holds a fenced block.
    static func stacked(_ text: String) -> Bool { !ComposerFence.scan(text).isEmpty }

    var body: some View {
        let stacked = Self.stacked(text)
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if let attachments, !attachments.chips.isEmpty || attachments.error != nil {
                    ComposerAttachmentStrip(attachments: attachments)
                        .padding(.top, 4)
                        .transition(.opacity)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    Menu {
                        Button("Photo or screenshot", systemImage: "photo") { choosingPhotos = true }.disabled(!attaching)
                        Button("File", systemImage: "doc") { choosingFiles = true }.disabled(!attaching)
                    } label: {
                        // The mockups' glass disc beside the glass field (S6, C2).
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.primary)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                            .contentShape(.hoverEffect, Circle())
                            .hoverEffect(.highlight)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("Attach")
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(alignment: .bottom, spacing: 6) {
                            CodeEditorField(text: $text, placeholder: placeholder, focus: focus, editor: editor, send: send,
                                            keyState: { (multiline.wrappedValue, working) }, keyAction: perform,
                                            pasteImages: attaching ? attachments?.add : nil)
                                .frame(height: editor.height)
                                .focused(focus)
                            if !stacked { slot.padding(.bottom, 4) }
                        }
                        if stacked { slot }
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, stacked ? 6 : 4)
                    .padding(.top, stacked ? 5 : 4)
                    .padding(.bottom, stacked ? 10 : 4)
                    .frame(minHeight: 44)
                    // A glass field, a capsule while it holds one line (S6), its corners kept as it grows.
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        if dropTargeted {
                            RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.dispatchPink, lineWidth: 1.5)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { editor.pillWidth = $0 }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
            // Over the strip too: the hints float above whatever the composer shows on top.
            .overlay(alignment: .topTrailing) {
                if dictationStatus == nil, editor.pasteOffer == nil,
                   Self.showsEditorHint(multiline: multiline.wrappedValue, hardwareKeyboard: keyboard.attached) {
                    // The Mac's "editor" badge: Return now starts a line, so say what sends.
                    Text("Editor · ⌘↩ sends")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .padding(.trailing, 20)
                        .alignmentGuide(.top) { $0[.bottom] + 2 }
                        .accessibilityIdentifier("composer-editor-mode")
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if let status = dictationStatus {
                    Button { if !dictation.active(dictationOwner) { dictation.dismissError() } } label: {
                        Label(status.text, systemImage: status.failed ? "exclamationmark.triangle.fill" : "waveform")
                            .scaledFont(14, weight: .medium, relativeTo: .subheadline)
                            .foregroundStyle(status.failed ? Color.red : Color.primary)
                            .lineLimit(2)
                            .truncationMode(.head)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .frame(minHeight: 34)
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .alignmentGuide(.top) { $0[.bottom] + 4 }
                    .accessibilityIdentifier("composer-dictation-status")
                    .transition(.opacity)
                } else if editor.pasteOffer != nil {
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
            if Self.showsKeyRow(editing: editor.editing, hardwareKeyboard: keyboard.attached) {
                // On an iPad the terminal capsule's width, centred: six keys spread over a 1,000-point column read
                // as a phone's row stretched.
                CodeKeyRow { editor.press($0) }
                    .frame(maxWidth: CodeKeyRow.maxWidth(idiom: UIDevice.current.userInterfaceIdiom))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        // Its own height always: the thread above gives way (with the keyboard up, too).
        .fixedSize(horizontal: false, vertical: true)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: editor.pasteOffer != nil)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: dictationStatus == nil)
        .onChange(of: stacked) { _, _ in editor.measure(text: text) }
        .photosPicker(isPresented: $choosingPhotos, selection: $photos, maxSelectionCount: attachments?.remaining ?? 1,
                      matching: .any(of: [.images, .screenshots]))
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            attachments?.add(items.enumerated().map { MobileAttachmentSource.photo($1, index: $0) })
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            attachments?.add(urls.map(MobileAttachmentSource.file))
        }
        // An iPad drags photos and files from other apps onto the composer.
        .onDrop(of: MobileAttachmentSource.dropTypes, isTargeted: $dropTargeted) { providers in
            guard attaching else { return false }
            let sources = MobileAttachmentSource.dropped(providers)
            guard !sources.isEmpty else { return false }
            attachments?.add(sources)
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.attachRequested)) { _ in
            if visible, attaching { choosingFiles = true }
        }
        .onAppear { visible = true }
        // A conversation left behind stops listening (the microphone indicator would stay on with nothing to show it).
        .onDisappear {
            visible = false
            if dictation.active(dictationOwner) { dictation.cancel() }
        }
    }

    private var dictationStatus: (text: String, failed: Bool)? {
        if dictation.active(dictationOwner) {
            switch dictation.phase {
            case .idle: return nil
            case .starting: return ("Starting…", false)
            case .listening: return ("Listening…", false)
            case .transcribing: return ("Transcribing…", false)
            }
        }
        return dictation.error(for: dictationOwner).map { ($0, true) }
    }

    /// Starts dictation, or stops it: what it hears goes after the draft as it comes (the mic shows only while it is
    /// empty), and a cancelled or failed dictation puts the draft back.
    private func dictate() {
        let choice = MobileSettings.dictation()
        let text = $text
        let draft = text.wrappedValue
        let end = NSRange(location: (draft as NSString).length, length: 0)
        dictation.toggle(owner: dictationOwner, engine: choice.engine, model: choice.model) { update in
            switch update {
            // The iPhone dictates one message at a time: no utterances come.
            case .heard(let words), .utterance(let words), .finished(let words): text.wrappedValue = DictationText.insert(words, into: draft, selection: end).text
            case .ended: text.wrappedValue = draft
            }
        }
    }

    /// The mic: a tap dictates (again: stops); with `converse`, a long press starts conversation mode instead.
    @ViewBuilder private func micSlot(dictating: Bool) -> some View {
        let label = dictating ? (dictation.phase == .listening ? "Stop dictation" : "Cancel dictation") : "Dictate"
        if let converse, !dictating {
            // As the send slot's steer: a tap dictates, a long press starts conversation mode.
            micGlyph(dictating: dictating)
                .onTapGesture(perform: dictate)
                .onLongPressGesture(minimumDuration: 0.5, perform: converse)
                .accessibilityElement()
                .accessibilityLabel(label)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, dictate)
                .accessibilityAction(named: "Conversation mode", converse)
                .padding(-8)
        } else {
            Button(action: dictate) { micGlyph(dictating: dictating) }
                .buttonStyle(.plain)
                .padding(-8)
                .accessibilityLabel(label)
        }
    }

    private func micGlyph(dictating: Bool) -> some View {
        ZStack {
            if dictating && dictation.phase == .listening {
                Circle().fill(Color.red)
                    .scaleEffect(0.85 + 0.3 * CGFloat(dictation.level))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: dictation.level)
                RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 10, height: 10)
            } else if dictating {
                ProgressView()
            } else {
                Image(systemName: "mic")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        // A 44 point target around the 28 point glyph; the outer padding gives the room back to the layout.
        .padding(8)
        .contentShape(Rectangle())
        .contentShape(.hoverEffect, Circle().inset(by: 8))
        .hoverEffect(.highlight)
    }

    @ViewBuilder private var slot: some View {
        let dictating = dictation.active(dictationOwner)
        switch Self.slot(text: text, working: working, dictating: dictating, attached: attached) {
        case .mic:
            micSlot(dictating: dictating)
        case .stop:
            Button(action: stop) {
                RoundedRectangle(cornerRadius: 2).fill(Color(uiColor: .systemBackground)).frame(width: 10, height: 10)
                    .frame(width: 28, height: 28)
                    .background(Color.primary, in: Circle())
                    .opacity(stopping ? 0.5 : 1)
                    .padding(8)
                    .contentShape(Rectangle())
                    .contentShape(.hoverEffect, Circle().inset(by: 8))
                    .hoverEffect(.highlight)
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
                .contentShape(.hoverEffect, Circle().inset(by: 8))
                .hoverEffect(.highlight)
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

    /// As wide as the terminal's key capsule at most (`TerminalAdaptation.capsuleMaxWidth`): the phone's row spans
    /// the composer, an iPad's keeps six phone-width keys.
    static func maxWidth(idiom: UIUserInterfaceIdiom) -> CGFloat { TerminalAdaptation.capsuleMaxWidth(idiom: idiom) }

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
    var keyState: () -> (multiline: Bool, working: Bool) = { (false, false) }
    var keyAction: ((ComposerKeyAction) -> Void)? = nil
    /// Takes the images a paste carries (nil: a paste of images does nothing, text pastes as ever).
    var pasteImages: (([MobileAttachmentSource]) -> Void)? = nil

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
        view.keyState = keyState
        view.keyAction = keyAction
        view.pasteImages = pasteImages
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
