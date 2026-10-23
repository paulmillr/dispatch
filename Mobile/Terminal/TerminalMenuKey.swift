import SwiftUI
import UIKit

/// The key capsule's last key (T2): its role's glyph drawn in SwiftUI, and over it a clear `UIButton` that carries the
/// system menu (glass, anchored on the key, sections in order) and says when the menu opens and closes, which a
/// SwiftUI `Menu` does not. A tap does the role's own thing (show the keyboard, fold the capsule) or, while the
/// software keyboard is up, opens the menu; a long press always opens it. While the menu shows the key is the
/// ellipsis, lit pink.
struct TerminalMenuKey: View {
    let controller: TerminalController
    @State private var pressed = false
    @Environment(\.terminalMenuScheme) private var menuScheme

    var body: some View {
        let role = controller.menuKey, open = controller.menuOpen
        let symbol = role.symbol(menuOpen: open)
        Image(systemName: symbol)
            .scaledFont(role == .hideKeys && !open ? 17 : 19, relativeTo: .callout)
            .foregroundStyle(symbol == "ellipsis.circle" ? Color.dispatchPink : Color.primary)
            .opacity(pressed ? 0.55 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
            .overlay {
                TerminalMenuButton(role: role, controller: controller, scheme: menuScheme, pressed: $pressed)
            }
    }
}

/// The clear button over the key (`TerminalMenuKey`).
struct TerminalMenuButton: UIViewRepresentable {
    let role: TerminalMenuKeyRole
    let controller: TerminalController
    /// The app's appearance (the key itself is dark over the terminal); nil: the key's own.
    let scheme: ColorScheme?
    @Binding var pressed: Bool

    func makeUIView(context: Context) -> TerminalMenuButtonView { TerminalMenuButtonView() }

    func updateUIView(_ button: TerminalMenuButtonView, context: Context) {
        let controller = controller, role = role, pressed = $pressed
        button.showsMenuAsPrimaryAction = role.opensOnTap
        // The menu is the app's, light or dark as the rest of it, though the capsule stays dark over the terminal.
        button.overrideUserInterfaceStyle = switch scheme {
        case .light?: .light
        case .dark?: .dark
        default: .unspecified
        }
        button.primary = { [weak controller] in
            guard let controller else { return }
            switch controller.menuKey {
            case .keyboard: controller.toggleKeyboard()
            case .hideKeys: controller.hideKeys()
            case .menu: break
            }
        }
        button.items = { [weak controller] in controller.map(Self.menu) ?? [] }
        button.onMenu = { [weak controller] open in controller?.menu(open: open) }
        button.onPress = { down in if pressed.wrappedValue != down { pressed.wrappedValue = down } }
        button.accessibilityLabel = role.label
        button.accessibilityHint = role.opensOnTap ? nil : "Touch and hold for the terminal menu"
        button.accessibilityCustomActions = TerminalMenuItem.sections(keyboardVisible: controller.keyboardVisible).joined().map { item in
            UIAccessibilityCustomAction(name: item.title) { [weak controller] _ in
                controller?.perform(item)
                return true
            }
        }
    }

    /// The menu as it opens: its sections inline, Paste only with text on the pasteboard (asked without reading it).
    @MainActor static func menu(_ controller: TerminalController) -> [UIMenuElement] {
        TerminalMenuItem.sections(keyboardVisible: controller.keyboardVisible).map { section in
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
    var primary: () -> Void = {}
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
        addAction(UIAction { [weak self] _ in
            guard let self, !self.showsMenuAsPrimaryAction else { return }
            self.primary()
        }, for: .primaryActionTriggered)
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
