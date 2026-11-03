import SwiftUI
import UIKit

/// The key capsule's "…" key (T2), between the d-pad and the keyboard key: the ellipsis drawn in SwiftUI, and over it a
/// clear `UIButton` that carries the system menu (glass, anchored on the key, sections in order) and says when the menu
/// opens and closes, which a SwiftUI `Menu` does not. A tap opens the menu, whether or not the software keyboard is up;
/// while it shows the ellipsis is lit pink.
struct TerminalMenuKey: View {
    let controller: TerminalController
    @State private var pressed = false
    @Environment(\.terminalMenuScheme) private var menuScheme

    var body: some View {
        let open = controller.menuOpen
        Image(systemName: open ? "ellipsis.circle" : "ellipsis")
            .scaledFont(19, relativeTo: .callout)
            .foregroundStyle(open ? Color.dispatchPink : Color.primary)
            .opacity(pressed ? 0.55 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
            .overlay {
                TerminalMenuButton(controller: controller, scheme: menuScheme, pressed: $pressed)
            }
    }
}

/// The capsule's last key: shows the software keyboard while it is down, hides it while it is up, or (a hardware
/// keyboard on an iPad) folds the capsule. A plain key: no menu on a long press, the "…" key has it.
struct TerminalKeyboardKeyView: View {
    let controller: TerminalController

    var body: some View {
        let role = controller.keyboardKey
        Button { controller.pressKeyboardKey() } label: {
            Image(systemName: role.symbol)
                .scaledFont(role == .hideKeys ? 17 : 19, relativeTo: .callout)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(role.label)
    }
}

/// The clear button over the "…" key (`TerminalMenuKey`).
struct TerminalMenuButton: UIViewRepresentable {
    let controller: TerminalController
    /// The app's appearance (the key itself is dark over the terminal); nil: the key's own.
    let scheme: ColorScheme?
    @Binding var pressed: Bool

    func makeUIView(context: Context) -> TerminalMenuButtonView { TerminalMenuButtonView() }

    func updateUIView(_ button: TerminalMenuButtonView, context: Context) {
        let pressed = $pressed
        button.showsMenuAsPrimaryAction = true
        // The menu is the app's, light or dark as the rest of it, though the capsule stays dark over the terminal.
        button.overrideUserInterfaceStyle = switch scheme {
        case .light?: .light
        case .dark?: .dark
        default: .unspecified
        }
        button.items = { [weak controller] in controller.map(Self.menu) ?? [] }
        button.onMenu = { [weak controller] open in controller?.menu(open: open) }
        button.onPress = { down in if pressed.wrappedValue != down { pressed.wrappedValue = down } }
        button.accessibilityLabel = "Terminal menu"
        button.accessibilityCustomActions = TerminalMenuItem.sections.joined().map { item in
            UIAccessibilityCustomAction(name: item.title) { [weak controller] _ in
                controller?.perform(item)
                return true
            }
        }
    }

    /// The menu as it opens: its sections inline, Paste only with text on the pasteboard (asked without reading it).
    @MainActor static func menu(_ controller: TerminalController) -> [UIMenuElement] {
        TerminalMenuItem.sections.map { section in
            UIMenu(options: .displayInline, children: section.map { item in
                let sending = !controller.canReset
                let action = UIAction(title: item.title, subtitle: item.note(chatSending: sending),
                                      image: UIImage(systemName: item.symbol)) { [weak controller] _ in
                    controller?.perform(item)
                }
                if item == .paste, !UIPasteboard.general.hasStrings { action.attributes = .disabled }
                if !item.enabled(chatSending: sending) { action.attributes = .disabled }
                return action
            })
        }
    }
}

/// A clear `UIButton` whose menu is built when it opens; it reports presses and the menu's presentation.
final class TerminalMenuButtonView: UIButton {
    var items: () -> [UIMenuElement] = { [] }
    var onMenu: (Bool) -> Void = { _ in }
    var onPress: (Bool) -> Void = { _ in }

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        preferredMenuElementOrder = .fixed
        menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            MainActor.assumeIsolated { done(self?.items() ?? []) }
        }])
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var isHighlighted: Bool {
        didSet { if isHighlighted != oldValue { onPress(isHighlighted) } }
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                         animator: (any UIContextMenuInteractionAnimating)?) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        onMenu(true)
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
                                         animator: (any UIContextMenuInteractionAnimating)?) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        onMenu(false)
    }
}

extension EnvironmentValues {
    /// The app's colour scheme for the key bar's menu, set where the capsule is forced dark (`TerminalSegmentView`).
    @Entry var terminalMenuScheme: ColorScheme? = nil
}
