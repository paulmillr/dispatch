import SwiftUI
import UIKit

/// The search capsule (T1), in the key capsule's place while the terminal is searched: a glass field (the needle in
/// the monospaced font, "2 of 3", a clear button), the up and down pair that steps to the older and newer match, and
/// Done. In the field Return is the next (older) match, ⇧Return the previous, Esc is Done; ⌘G and ⇧⌘G step from the
/// menu bar. Over the terminal, so dark in either appearance, as the key capsule is.
struct TerminalSearchBar: View {
    let controller: TerminalController
    @Environment(\.dynamicTypeSize) private var typeSize
    static let height = 44.0

    private var search: TerminalSearch { controller.search }
    /// As the key capsule's, capped at the first accessibility size so the terminal keeps its rows.
    private var height: CGFloat { min(typeSize, .accessibility1).scaled(Self.height, relativeTo: .body) }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TerminalSearchField(controller: controller)
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                Text(search.count)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityIdentifier("search-count")
                    .accessibilityLabel(search.count.isEmpty ? "" : search.count + " matches")
                if !search.query.isEmpty {
                    Button { search.update("") } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 28)
                            .contentShape(Rectangle().inset(by: -6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: height)
            .glassEffect(.regular.interactive(), in: Capsule())

            HStack(spacing: 0) {
                stepButton("chevron.up", "Older match") { search.next() }
                stepButton("chevron.down", "Newer match") { search.previous() }
            }
            .font(.body.weight(.semibold))
            .frame(height: height)
            .glassEffect(.regular.interactive(), in: Capsule())

            Button { controller.closeSearch() } label: {
                Text("Done")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.dispatchPink)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .frame(height: height)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
            .accessibilityLabel("Done")
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        // In the key capsule's slot, at its height: swapping the two never changes the terminal's grid.
        .frame(height: max(height, TerminalKeyCapsule.height(typeSize)), alignment: .bottom)
    }

    private func stepButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 36, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyCapsuleButtonStyle())
        .foregroundStyle(Color.primary)
        .disabled(!search.canStep)
        .opacity(search.canStep ? 1 : 0.4)
        .accessibilityLabel(label)
    }
}

/// The search capsule's field: a `UITextField`, so Return steps without the keyboard going away, ⇧Return and Esc are
/// key commands, and the menu bar's Find Next and Find Previous reach it while it has the focus (the terminal is not
/// in its responder chain). Nothing typed here reaches the program.
struct TerminalSearchField: UIViewRepresentable {
    let controller: TerminalController

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TerminalSearchTextField {
        let field = TerminalSearchTextField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 16, weight: .regular),
                                                                   maximumPointSize: 24)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = .label
        field.tintColor = UIColor(named: "AccentColor")
        field.attributedPlaceholder = NSAttributedString(string: "Search", attributes: [.foregroundColor: UIColor.secondaryLabel])
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.inlinePredictionType = .no
        field.keyboardAppearance = .dark
        field.returnKeyType = .search
        field.enablesReturnKeyAutomatically = false
        field.overrideUserInterfaceStyle = .dark
        field.accessibilityLabel = "Search terminal"
        #if DEBUG
        // `-DispatchHardwareKeyboard YES` stands in for an attached keyboard: no software keyboard, as the terminal's
        // and Chat's composer under it.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "DispatchHardwareKeyboard") != nil, defaults.bool(forKey: "DispatchHardwareKeyboard") {
            field.inputView = UIView(frame: .zero)
        }
        #endif
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: TerminalSearchTextField, context: Context) {
        let search = controller.search
        context.coordinator.search = search
        field.step = { [weak search] forward in forward ? search?.next() : search?.previous() }
        field.done = { [weak controller] in controller?.closeSearch() }
        if field.text != search.query, field.markedTextRange == nil { field.text = search.query }
        if context.coordinator.focused != search.focusRequest {
            context.coordinator.focused = search.focusRequest
            // After this update: the field may only now be in a window.
            DispatchQueue.main.async {
                if field.window != nil, !field.isFirstResponder { field.becomeFirstResponder() }
                field.selectAll(nil)
            }
        }
    }

    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        weak var search: TerminalSearch?
        var focused = 0

        @objc func changed(_ field: UITextField) {
            // The input method's marked text is not a needle yet.
            guard field.markedTextRange == nil else { return }
            search?.update(field.text ?? "")
        }

        /// Return: the next match; the keyboard stays.
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            search?.next()
            return false
        }
    }
}

/// The field's keys: ⇧Return steps back, Esc is Done (both before the text system sees them), and the menu bar's
/// Find commands act on the search while the field has the focus.
final class TerminalSearchTextField: UITextField {
    var step: (Bool) -> Void = { _ in }
    var done: () -> Void = {}
    /// Room before the first glyph: a monospaced "t" at the field's edge lost its left side to the clip and the caret.
    static let inset = UIEdgeInsets(top: 0, left: 2, bottom: 0, right: 0)

    override func textRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: Self.inset) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: Self.inset) }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: Self.inset) }

    override var keyCommands: [UIKeyCommand]? {
        let back = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(stepBack(_:)))
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(finish(_:)))
        for command in [back, escape] { command.wantsPriorityOverSystemBehavior = true }
        return [back, escape]
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(stepBack(_:)), #selector(finish(_:)), #selector(find(_:)), #selector(findNext(_:)), #selector(findPrevious(_:)): true
        default: super.canPerformAction(action, withSender: sender)
        }
    }

    @objc func stepBack(_ sender: Any?) { step(false) }
    @objc func finish(_ sender: Any?) { done() }

    /// ⌘F again: the needle selected, to type a new one.
    override func find(_ sender: Any?) { selectAll(nil) }
    override func findNext(_ sender: Any?) { step(true) }
    override func findPrevious(_ sender: Any?) { step(false) }
}
