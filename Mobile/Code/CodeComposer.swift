import Dictation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The composer with code (M5e), with a small interface (the draft, a placeholder, the trailing slot's state and its
/// actions): "+" for attachments, conversation mode and the code keys, the field, and the slot (mic while the draft is empty,
/// else the pink send; a tap sends as the draft goes now, a long press only offers the ways it can go, `sendOptions`:
/// Send, or Send now and Queue while the agent works). Stop is on the working row (`ChatWorkingRow`). The mic dictates with
/// Settings' engine (`Dictation`): what it hears fills the draft as it comes, and tapped again it stops; while it listens a
/// capsule above the field says so, and after a failure, why. The field is a
/// `UITextView` that grows with the draft up to a bound and renders its Markdown as you type (`CodeTextView`). With a
/// fenced block in the draft the slot moves under the text, so the panel spans the field. With "Show code keys" picked
/// under "+" (off by default, kept app-wide: `MobileSettings.composerCodeKeysKey`), while the field is focused a glass key row above the field
/// offers the backtick, the fence and code pairs. With a hardware
/// keyboard the keys follow the Mac's composer (`ComposerHardwareKeys`): Return sends; Option/Shift-Return starts a new line;
/// in editor mode (⌘E, a multi-line paste, Settings' default) Return inserts newlines and ⌘Return sends; ⌥⌘Return steers, ⌘E toggles
/// editor mode, Esc leaves editor mode, else stops a running turn, else leaves the field. The key row stays away then:
/// the keyboard has every key it offers. With `attachments`, "+" picks photos or
/// files, an image pasted into the field or a drop on the composer attaches, and a strip above the field shows them
/// (docs/ios.md, Attachments); a draft with attachments sends without text.
struct CodeComposer: View {
    enum Slot: Equatable { case mic, send }

    /// What a long press on send offers; a tap does what the first that is not `sendNow` would (the draft's own route),
    /// or Send now when Settings steers while the agent works (`queue` is given).
    enum SendOption: Hashable, Identifiable {
        /// The agent takes it now.
        case send
        /// Into the running turn (steer).
        case sendNow
        /// After the running turn (the queue).
        case queue
        /// The slash list's lit row goes into the draft (`MobileChatSession.sendFromComposer`): nothing is sent.
        case complete(String)
        /// "/terminal": the tab shows Terminal.
        case terminal

        var id: Self { self }
        var title: String {
            switch self {
            case .send: "Send"
            case .sendNow: "Send now"
            case .queue: "Queue"
            case .complete(let command): "Complete \(command)"
            case .terminal: "Open Terminal"
            }
        }
        var image: String {
            switch self {
            case .send: "arrow.up"
            case .sendNow: "arrow.up.circle"
            case .queue: "text.line.last.and.arrowtriangle.forward"
            case .complete: "text.badge.checkmark"
            case .terminal: "apple.terminal"
            }
        }
    }

    /// The long press's menu for a draft that goes to the agent: Send now and Queue while the tap queues and the agent
    /// can take it into its turn; Queue alone while the tap queues and it cannot (the terminal is not attached, the
    /// conversation is not verified, a command waits for an idle agent): "Send" there would promise what the tap does
    /// not do, so the one item names what happens; else Send alone.
    static func sendOptions(queues: Bool, steers: Bool) -> [SendOption] {
        guard queues else { return [.send] }
        return steers ? [.sendNow, .queue] : [.queue]
    }

    @Binding var text: String
    var placeholder: String
    /// The agent works: Esc from a hardware keyboard stops it.
    var working: Bool
    var focus: FocusState<Bool>.Binding
    var send: () -> Void
    var steer: (() -> Void)?
    /// Given when `send` steers (Settings › Chat, While the agent works: Steer): what Queue and ⌥⌘Return do then.
    var queue: (() -> Void)? = nil
    var stop: () -> Void
    /// What send's long press offers (`sendOptions`, or completing a command, opening Terminal); a tap does what the
    /// first that is not Send now would.
    var sendOptions: [SendOption] = [.send]
    /// The draft is a queued message being edited: send is ✓, Save.
    var saving = false
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
    @AppStorage(MobileSettings.composerCodeKeysKey) private var codeKeys = false
    /// The first Esc only arms the stop; another within a second stops the turn.
    @State private var stopArmed: Date?
    @ReduceMotion private var reduceMotion

    /// The trailing slot: send for text or attachments, else the mic.
    static func slot(text: String, dictating: Bool = false, attached: Bool = false) -> Slot {
        if dictating { return .mic }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !attached ? .mic : .send
    }

    /// Edit › Attach Files… (⇧⌘A, `MobileCommands`): the composer on screen opens its file picker.
    static let attachRequested = Notification.Name("DispatchMobileComposerAttach")

    private var attaching: Bool { attachments?.enabled == true && (attachments?.remaining ?? 0) > 0 }
    /// Stored attachments, not running or failed uploads: what a send carries.
    private var attached: Bool { attachments?.chips.contains { !$0.uploading && $0.error == nil } == true }

    private var dictation: Dictation { .shared }

    /// The key row above the field shows once the user asked for it ("+" › Show code keys), while the field edits,
    /// unless a hardware keyboard is attached: then there is no software keyboard to ride on and the keys it offers are
    /// on the keyboard.
    static func showsKeyRow(enabled: Bool, editing: Bool, hardwareKeyboard: Bool) -> Bool {
        enabled && editing && !hardwareKeyboard
    }

    /// The editor-mode hint shows only where Return means something else in it: with a hardware keyboard.
    static func showsEditorHint(multiline: Bool, hardwareKeyboard: Bool) -> Bool { multiline && hardwareKeyboard }

    /// Carries out a hardware key's action (the field inserts newlines and leaves focus itself).
    private func perform(_ action: ComposerKeyAction) {
        switch action {
        case .send: send()
        // ⌥⌘Return goes the other way from Return: steers, or queues when Return steers.
        case .alternateSend: (queue ?? steer ?? send)()
        case .stop: escape()
        case .toggleEditor: multiline.wrappedValue.toggle()
        case .leaveEditor: multiline.wrappedValue = false
        case .newline, .resign, .system: break
        }
    }

    /// Esc while the agent works: arms the stop for `ChatEscapeStop.window` and stops on the
    /// second press.
    private func escape() {
        let now = Date()
        if let armed = stopArmed, now.timeIntervalSince(armed) <= ChatEscapeStop.window {
            stopArmed = nil
            return stop()
        }
        stopArmed = now
        DispatchQueue.main.asyncAfter(deadline: .now() + ChatEscapeStop.window) { if stopArmed == now { stopArmed = nil } }
    }

    /// The slot sits under the text once the draft holds a fenced block.
    static func stacked(_ text: String) -> Bool { !ComposerFence.scan(text).isEmpty }

    var body: some View {
        let stacked = Self.stacked(text)
        VStack(spacing: 0) {
            if keyRow {
                // Above the field, where the eye already is while typing; on an iPad the terminal capsule's width,
                // centred: six keys spread over a 1,000-point column read as a phone's row stretched.
                CodeKeyRow { editor.press($0) }
                    .frame(maxWidth: CodeKeyRow.maxWidth(idiom: UIDevice.current.userInterfaceIdiom))
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }
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
                        if let converse {
                            Section { Button("Conversation Mode", systemImage: "waveform", action: converse) }
                        }
                        if !keyboard.attached {
                            // A hardware keyboard has the keys, and the row never shows with it.
                            Section {
                                Button(codeKeys ? "Hide code keys" : "Show code keys", systemImage: "curlybraces") {
                                    codeKeys.toggle()
                                    // The row rides on the keyboard: picked from an unfocused field, the field takes
                                    // focus.
                                    if codeKeys, !editor.editing { editor.focus() }
                                }
                            }
                        }
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
                    .accessibilityHint(converse == nil ? "Photos, files and the code keys" : "Photos, files, conversation mode and the code keys")
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(alignment: .bottom, spacing: 6) {
                            CodeEditorField(text: $text, placeholder: placeholder, focus: focus, editor: editor, send: send,
                                            // Return still sends a one-line command in editor mode, as on the Mac.
                                            keyState: { (multiline.wrappedValue && !AgentInput.isCommand(text, multiline: text.contains(where: \.isNewline)), working) },
                                            keyAction: perform, pasteImages: attaching ? attachments?.add : nil,
                                            pastedLines: { multiline.wrappedValue = true })
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
        }
        // Over the key row and the strip too: the hints float above whatever the composer shows on top.
        .overlay(alignment: .topTrailing) {
            if stopArmed != nil, working {
                Text("Esc again to stop")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .padding(.trailing, 20)
                    .alignmentGuide(.top) { $0[.bottom] + 2 }
                    .accessibilityIdentifier("composer-stop-armed")
                    .allowsHitTesting(false)
            } else if dictationStatus == nil, Self.showsEditorHint(multiline: multiline.wrappedValue, hardwareKeyboard: keyboard.attached) {
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
            }
        }
        // Its own height always: the thread above gives way (with the keyboard up, too).
        .fixedSize(horizontal: false, vertical: true)
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

    /// The key row shows: the field edits and no hardware keyboard has the keys.
    private var keyRow: Bool {
        Self.showsKeyRow(enabled: codeKeys, editing: editor.editing, hardwareKeyboard: keyboard.attached)
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
        switch Self.slot(text: text, dictating: dictating, attached: attached) {
        case .mic:
            micSlot(dictating: dictating)
        case .send:
            // A tap sends; a long press presents the ways the draft can go and sends nothing by itself.
            Menu {
                ForEach(sendOptions) { option in
                    Button(option.title, systemImage: option.image) { perform(option) }
                }
            } label: {
                Image(systemName: saving ? "checkmark" : "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.onAccent)
                    .frame(width: 28, height: 28)
                    .background(Color.dispatchPink, in: Circle())
                    .padding(8)
                    .contentShape(Rectangle())
                    .contentShape(.hoverEffect, Circle().inset(by: 8))
                    .hoverEffect(.highlight)
            } primaryAction: {
                send()
            }
            .buttonStyle(.plain)
            .menuOrder(.fixed)
            .menuHoldHaptic()
            .accessibilityLabel(saving ? "Save" : "Send")
            .accessibilityActions {
                if let queue { Button("Queue", action: queue) } else if let steer { Button("Send now", action: steer) }
            }
            .padding(-8)
        }
    }

    private func perform(_ option: SendOption) {
        switch option {
        case .send, .complete, .terminal: send()
        case .queue: (queue ?? send)()
        case .sendNow: (steer ?? send)()
        }
    }
}

/// The key row above the composer's field (M5e): the same Liquid Glass capsule as the terminal's key capsule (M6a), keys of
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

/// The composer's state outside the text view: its height and whether it is editing.
@MainActor @Observable final class CodeEditorModel {
    var height: CGFloat = 36
    private(set) var editing = false
    @ObservationIgnored var pillWidth: CGFloat = 0 {
        didSet { if pillWidth != oldValue, let view { measure(text: view.textStorage.string) } }
    }
    @ObservationIgnored weak var view: CodeTextView?

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
    func ended() { editing = false }

    func focus() { view?.becomeFirstResponder() }

    func press(_ key: ComposerKey) { view?.press(key) }
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
    /// A paste of more than one line (editor mode).
    var pastedLines: (() -> Void)? = nil

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
        return view
    }

    func updateUIView(_ view: CodeTextView, context: Context) {
        context.coordinator.parent = self
        view.submit = send
        view.keyState = keyState
        view.keyAction = keyAction
        view.pasteImages = pasteImages
        view.pastedLines = pastedLines
        if view.placeholder != placeholder { view.placeholder = placeholder }
        if view.textStorage.string != text {
            view.setDraft(text)
            editor.measure(text: text)
        }
        // A request for focus (a new chat, Reply, the slash list): the binding's rising edge, so the field never fights
        // the keyboard (`Coordinator.requests`).
        let wanted = focus.wrappedValue
        if context.coordinator.requests(wanted: wanted, focused: view.isFirstResponder) {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CodeTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: editor.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditorField
        /// The binding as last seen in an update or set by the field itself.
        var wantedFocus = false
        /// When UIKit last ended the field's editing (the keyboard dragged down, another field), until an update
        /// brings the binding's false.
        var ended: Date?

        /// Whether an update with the binding at `wanted` asks the field to take focus: its rising edge. Right after
        /// UIKit ends the field's editing an update can still carry the old true (the editor's own change draws
        /// first): that is not a request, and taking it as one brought the keyboard back up as it went down. A true
        /// that comes later with no false seen in between is one (a request SwiftUI coalesced with the false).
        func requests(wanted: Bool, focused: Bool, now: Date = Date()) -> Bool {
            defer { wantedFocus = wanted }
            guard wanted else {
                ended = nil
                return false
            }
            guard !focused else { return false }
            if !wantedFocus { return true }
            guard let ended, now.timeIntervalSince(ended) > Self.staleWindow else { return false }
            self.ended = nil
            return true
        }

        /// How long after the field's editing ended an update's true is taken for the old one.
        static let staleWindow: TimeInterval = 0.3

        init(parent: CodeEditorField) { self.parent = parent }

        func changed(_ text: String) {
            if parent.text != text { parent.text = text }
            parent.editor.measure(text: text)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? CodeTextView)?.updateCaretContext()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.editor.began()
            if !parent.focus.wrappedValue { parent.focus.wrappedValue = true }
            wantedFocus = true
            ended = nil
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.editor.ended()
            if parent.focus.wrappedValue { parent.focus.wrappedValue = false }
            ended = Date()
        }
    }
}
