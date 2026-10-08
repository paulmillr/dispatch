import SwiftUI

@MainActor @Observable
final class ContentSearch {
    var visible = false
    var query = "" { didSet { if query != oldValue { total = nil; selected = nil } } }
    var total: Int?
    var selected: Int?
    var status: String?
    var focusRequest = UUID()
    var navigation = UUID()
    var direction = 1

    func open() { visible = true; focusRequest = UUID() }
    func close() { visible = false; total = nil; selected = nil; status = nil }
    func move(_ direction: Int) { self.direction = direction; navigation = UUID() }
}

struct ContentSearchBar: View {
    @Bindable var search: ContentSearch
    let focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
            ContentSearchField(search: search, focused: focused).frame(minWidth: 80, idealWidth: 200)
            Text(search.query.isEmpty ? "" : search.total.map { "\(search.selected.map { $0 + 1 } ?? 0) of \($0)" } ?? "Searching…")
                .font(AppFont.ui(size: 11)).foregroundStyle(Chrome.muted).fixedSize()
                .accessibilityIdentifier("find-count")
            Button { search.move(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous match").disabled(search.total == nil || search.total == 0)
            Button { search.move(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Next match").disabled(search.total == nil || search.total == 0)
            Button { search.close() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close Find")
        }
        if let status = search.status { Text(status).font(AppFont.ui(size: 11)).foregroundStyle(Chrome.muted) }
        }
        .buttonStyle(.plain).padding(8)
        // A glass panel over the terminal or chat; otherwise the bordered sidebar-colored panel.
        .liquidGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(LiquidGlassStore.shared.active ? Color.clear : Chrome.sidebar, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(LiquidGlassStore.shared.active ? Color.clear : Chrome.border, lineWidth: 1) }
        .frame(maxWidth: 440).padding(8).accessibilityIdentifier("content-find")
    }
}

private struct ContentSearchField: NSViewRepresentable {
    let search: ContentSearch
    let focused: Bool
    func makeCoordinator() -> Coordinator { Coordinator(search: search) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Find"
        field.setAccessibilityIdentifier("find-query")
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != search.query { field.stringValue = search.query }
        guard focused, context.coordinator.request != search.focusRequest else { return }
        context.coordinator.request = search.focusRequest
        DispatchQueue.main.async { [weak field] in
            guard search.visible, let field, field.window?.isKeyWindow == true else { return }
            field.selectText(nil)
        }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let search: ContentSearch
        var request: UUID?
        init(search: ContentSearch) { self.search = search }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { search.query = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) { search.close(); return true }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                search.move(NSEvent.modifierFlags.contains(.shift) ? -1 : 1); return true
            }
            return false
        }
    }
}

/// Terminal identity owns chat state even when its tab, pane, or space moves.
struct TerminalContentView: View {
    let tab: TerminalTab
    let workspace: Workspace
    let spaceID: UUID
    var windowTabID: UUID?
    let paneID: UUID
    let focused: Bool
    let isPresented: Bool
    let floatingSwitch: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A glass strip over the pane's top: the terminal always sits below it, so switching to chat never resizes
    /// the PTY; chat scrolls under it.
    @Environment(\.glassStripInset) private var glassInset
    @State private var presentationID = UUID()

    var body: some View {
        let chat = TerminalRuntime.shared.chat
        let session = chat.session(for: tab.id)
        let search = session.terminalSearch
        let canShowChat = chat.canEnterChat(session) || session.showChat
        VStack(spacing: 0) {
            SSHReconnectOverlay(surface: tab.id, workspace: workspace).padding(.top, glassInset)
            ZStack(alignment: .topTrailing) {
                TerminalHost(tab: tab, spaceID: spaceID, windowTabID: windowTabID, paneID: paneID, focusRequest: workspace.focusRequest,
                             focused: focused && !session.showChat,
                             visible: isPresented && !session.showChat)
                    .padding(.top, glassInset)
                    .opacity(session.showChat ? 0 : 1)
                    .offset(y: session.showChat && !reduceMotion ? -8 : 0)
                    .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: InterfaceMotion.modeSwitchDuration), value: session.showChat)
                    .allowsHitTesting(!session.showChat)
                    .accessibilityHidden(session.showChat)
                if session.showChat {
                    ChatView(session: session, coordinator: chat, focused: focused,
                             floatingSwitch: floatingSwitch && canShowChat, workspace: workspace, topInset: glassInset)
                        .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 8)))
                        .zIndex(1)
                }
                if floatingSwitch && canShowChat && !(session.showChat ? session.search.visible : search.visible) { ChatModeSwitch(session: session, coordinator: chat, floating: true).padding(.top, 10 + glassInset).padding(.trailing, Chrome.paneContentInset).zIndex(3) }
                if !session.showChat, search.visible {
                    ContentSearchBar(search: search, focused: focused && isPresented).padding(.top, glassInset).zIndex(4)
                }
            }
            .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: InterfaceMotion.modeSwitchDuration), value: session.showChat)
            .overlay(alignment: .bottomTrailing) {
                if let armed = workspace.prefixKeys.armed, tab.surfaceIDs.contains(armed) { PrefixIndicator() }
            }
        }
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { session.setPresented(isPresented, by: presentationID) }
        .onChange(of: isPresented) { _, visible in session.setPresented(visible, by: presentationID) }
        .onDisappear { session.setPresented(false, by: presentationID) }
        .onChange(of: search.query) { _, query in
            guard search.visible else { return }
            TerminalRuntime.shared.views[tab.id]?.performBindingAction("search:" + query)
        }
        .onChange(of: search.navigation) { _, _ in
            TerminalRuntime.shared.views[tab.id]?.performBindingAction("navigate_search:" + (search.direction > 0 ? "next" : "previous"))
        }
        .onChange(of: search.visible) { _, visible in
            let runtime = TerminalRuntime.shared
            runtime.views[tab.id]?.performBindingAction(visible ? "search:" + search.query : "end_search")
            if !visible, focused, isPresented { runtime.focusActive() }
        }
        .id(tab.id)
    }
}

/// Shown while ⌃B waits for the key that completes a tmux- or herdr-style binding.
private struct PrefixIndicator: View {
    @Environment(\.appTypography) private var typography

    var body: some View {
        Text("⌃B").font(typography.shortcut()).foregroundStyle(Chrome.accent)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .modifier(PrefixIndicatorSurface())
            .padding(10)
            .allowsHitTesting(false)
            .accessibilityLabel("Prefix key pressed").accessibilityIdentifier("prefix-indicator")
    }
}

/// A small glass capsule over the terminal, or the accent-bordered badge without glass.
private struct PrefixIndicatorSurface: ViewModifier {
    func body(content: Content) -> some View {
        if LiquidGlassStore.shared.active {
            content.padding(.horizontal, 2).liquidGlass(in: Capsule())
        } else {
            content.background(RoundedRectangle(cornerRadius: 5).fill(Chrome.sidebar))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Chrome.accent.opacity(0.5)))
        }
    }
}
