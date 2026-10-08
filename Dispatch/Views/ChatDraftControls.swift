import SwiftUI

struct ChatDraftControls: View {
    @Environment(\.chatTheme) private var theme
    let session: ChatSession
    @State private var renaming: ChatDraft?
    @State private var title = ""
    var body: some View {
        let drafts = session.drafts
        HStack(spacing: 2) {
            if !drafts.saved.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text("drafts").foregroundStyle(theme.muted.opacity(0.65))
                        savedDrafts
                    }.fixedSize()
                    Menu {
                        ForEach(drafts.saved) { draft in
                            Button(draft.label) { drafts.select(draft.id) }
                        }
                        Menu("Manage drafts") {
                            ForEach(drafts.saved) { draft in
                                Menu(draft.label) {
                                    Button("Rename…") { title = draft.title ?? draft.label; renaming = draft }
                                    Button("Delete") { drafts.delete(draft.id) }
                                }
                            }
                        }
                        Divider()
                        draftActions
                    } label: { menuLabel("drafts \(drafts.saved.count)") }
                        .footerMenu()
                }
            }
            if drafts.saved.isEmpty && !drafts.recoverable.isEmpty {
                let count = drafts.recoverable.reduce(0) { $0 + drafts.recoverableDrafts($1).count }
                Menu { recoveryActions } label: { menuLabel(count == 1 ? "1 unsent draft" : "\(count) unsent drafts") }
                    .footerMenu()
                    .help("Drafts typed in conversations that are no longer open")
                    .accessibilityIdentifier("chat-recover-drafts")
            }
        }.font(theme.typography.font(offset: -1.5))
            .contentShape(Rectangle())
            .contextMenu { draftActions }
            .alert("Rename draft", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $title)
                Button("Save") { if let renaming { drafts.rename(renaming.id, title: title) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
    }
    private var savedDrafts: some View {
        let drafts = session.drafts
        return HStack(spacing: 2) {
            ForEach(drafts.saved) { draft in
                chip(draft.label, selected: drafts.selected == draft.id) { drafts.select(draft.id) }
                    .contextMenu {
                        Button("Rename…") { title = draft.title ?? draft.label; renaming = draft }
                        Button("Delete") { drafts.delete(draft.id) }
                    }
            }
        }.fixedSize()
    }
    @ViewBuilder private var draftActions: some View {
        let drafts = session.drafts
        Button("Working buffer") { drafts.select(nil) }
        Button("Discard current draft") { drafts.discard() }
            .disabled(drafts.current.text.isEmpty && !drafts.current.multiline)
        Button("Undo draft deletion") { drafts.undoDelete() }.disabled(!drafts.canUndoDelete)
        if !drafts.recoverable.isEmpty {
            Divider()
            recoveryActions
        }
    }
    /// One entry per departed conversation; recovering adds its drafts to this one's saved drafts.
    @ViewBuilder private var recoveryActions: some View {
        let drafts = session.drafts
        Section("From other conversations") {
            ForEach(drafts.recoverable, id: \.self) { key in
                let records = drafts.recoverableDrafts(key)
                if let newest = records.first {
                    Button {
                        drafts.recover(key)
                    } label: {
                        Text(newest.label)
                        Text([records.count > 1 ? "\(records.count) drafts" : nil,
                              newest.modified.formatted(.relative(presentation: .named))].compactMap { $0 }.joined(separator: " · "))
                    }
                }
            }
        }
    }
    /// Muted text with the underline the model control uses.
    private func menuLabel(_ text: String) -> some View {
        Text(text).foregroundStyle(theme.muted).footerMenuUnderline(theme.muted)
    }
    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).lineLimit(1).padding(.horizontal, 8)
                .frame(height: 20 * theme.typography.sizeScale)
                .background(selected ? theme.ink.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(DraftButtonStyle(foreground: selected ? theme.ink : theme.muted, hover: theme.ink))
            .accessibilityValue(selected ? "Selected" : "")
    }
}

private extension View {
    /// A menu drawn as its label alone, without the accent tint and chevron of a system menu button.
    func footerMenu() -> some View {
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

struct DraftButtonStyle: ButtonStyle {
    let foreground: Color
    let hover: Color
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering && isEnabled ? hover : foreground)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.5)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
