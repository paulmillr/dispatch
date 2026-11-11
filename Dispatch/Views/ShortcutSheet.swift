import SwiftUI

/// One key and what it does, for the ⌘/ shortcut sheets.
struct ShortcutRow: Identifiable {
    let key: String
    let explanation: String
    var id: String { key + " " + explanation }

    init(_ key: String, _ explanation: String) { self.key = key; self.explanation = explanation }

    /// What each digit group does; Settings › Keyboard describes its recorders the same way.
    static let tabDigits = "switch to tab (or pane when split) · 9 the last tab"
    static let spaceDigits = "switch to space · 9 the last space"
    /// The layouts by the names the View menu and the layout picker give them, in their keys' order.
    static var splitDigits: String { LayoutPreset.allCases.filter { $0.shortcutKey != nil }.map(\.title).joined(separator: " · ") }

    /// The digit chords lead, in Settings › Keyboard' order and following it; then stepping through tabs, panes and spaces,
    /// as the Navigate menu names them, and the prefix keys last while the focused space answers them.
    @MainActor static var navigation: [ShortcutRow] {
        let keys = KeyGroupsStore.shared.current, steps = keys.steps
        func brackets(_ modifiers: NSEvent.ModifierFlags) -> String {
            let symbols = KeyGroups.symbols(modifiers)
            return "\(symbols)[ / \(symbols)]"
        }
        let rows: [ShortcutRow?] = [
            // An unbound group has no shortcut, so no row.
            keys.shortcut(\.tabs, "1…9").map { .init($0, tabDigits) },
            keys.shortcut(\.spaces, "1…9").map { .init($0, spaceDigits) },
            keys.shortcut(\.splits, "1…4, 6, 8").map { .init($0, splitDigits) },
            steps.tabs.map { .init(brackets($0), "previous / next tab") },
            .init("⌃⇥ / ⌃⇧⇥", "next / previous tab"),
            .init(brackets(KeyGroups.paneStep), "previous / next pane"),
            steps.spaces.map { .init(brackets($0), "previous / next space") },
            .init("⌘P", "search spaces"),
            .init("⌃⌘S", "show or hide the sidebar · also ⌘\\"),
            prefix.map { .init("\($0.prefix.symbol) …", "prefix keys, listed under More") },
            voiceNavigation,
        ]
        return rows.compactMap { $0 }
    }

    /// The prefix table the focused terminal answers (Settings › Keyboard › Prefix keys), nil while it has none.
    @MainActor static var prefix: PrefixTable? {
        guard let controller = NSApp.delegate as? AppDelegate, let surface = controller.workspace.activeSurfaceID else { return nil }
        return controller.prefixTable(for: surface)
    }

    /// The focused space's prefix keys, each binding as the prefix then its key; a window's digits in one row. Bindings
    /// Dispatch cannot run are listed as such.
    @MainActor static func prefixRows(_ table: PrefixTable) -> [ShortcutRow] {
        let prefix = table.prefix.symbol
        var digits: [String] = [], rows: [(key: String, row: ShortcutRow)] = []
        for (key, binding) in table.bindings where !table.arms(key) {
            if case .selectWindow = binding.action, key.name.count == 1, key.name.first?.isNumber == true, !key.control, !key.option {
                digits.append(key.name)
                continue
            }
            rows.append((key.symbol, .init("\(prefix) \(key.symbol)", binding.action.title)))
        }
        for (key, command) in table.rejected {
            rows.append((key.symbol, .init("\(prefix) \(key.symbol)", "“\(command)”, which Dispatch can't run")))
        }
        let sorted = rows.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map(\.row)
        let windows = digits.sorted()
        let window = windows.isEmpty ? [] : [ShortcutRow("\(prefix) \(windows.count > 1 ? "\(windows.first!)…\(windows.last!)" : windows[0])",
                                                         "window by its number")]
        return window + sorted + [.init("\(prefix) \(prefix)", "send \(prefix) to the program")]
    }

    /// Settings › Dictation › Navigate by voice, while dictation and its voice key are on.
    @MainActor static var voiceNavigation: ShortcutRow? {
        let store = DictationStore.shared
        guard let key = store.shortcut, store.navigation else { return nil }
        return .init("\(key.name) “\(store.wakeWord), …”", "say a space or tab, or the sidebar: “billing tab 2”, “next space”, “back”, “hide sidebar”")
    }

    @MainActor static var window: [ShortcutRow] { windowRows(KeyGroupsStore.shared.current) }

    /// ⌃⌘1…3 are the files tabs' unless a Settings › Keyboard group takes ⌃⌘ digits (AppDelegate.filesTabModifiers). Worded
    /// as the menus are.
    @MainActor static func windowRows(_ keys: KeyGroups) -> [ShortcutRow] { [
        .init("⌘N / ⇧⌘N", "new space / new local space"),
        .init("⌘T", "new tab"),
        .init("⌘W / ⇧⌘W", "close tab / close space (detach space in tmux and herdr)"),
        .init("⌥⌘W", "close window and quit"),
        .init("⌘D / ⇧⌘D", "split right / split down"),
        .init("⌘J / ⇧⌘J", "next / previous attention"),
        .init("⇧⌘C", "switch between terminal and chat"),
        .init("⇧⌘F", "switch between terminal and files"),
        .init("⇧⌘U / ⇧⌘L", "show files on the Review / Commits tab"),
        .init("⌃⌘1…3", "files tabs: Files / Review / Commits"),
        .init("⌥⌘P", "show or hide the files preview"),
        .init("⌥↓ / ⌥↑", "Review: next / previous comment"),
        .init("⇧⌘⏎", "Review: create the review"),
        .init("⌘K", "clear screen and scrollback (not in full-screen programs, tmux or herdr)"),
        .init("⌘F", "find · ⌘G / ⇧⌘G next / previous"),
        .init("⌘-click", "open a link · hover with ⌘ to see where it goes"),
        .init("right-click", "copy, paste, clear, split and modes · ⌃-click too"),
        .init("⌘+ / ⌘- / ⌘0", "bigger / smaller / reset font size"),
        .init("⌃⌘F", "full screen"),
        .init("⌘,", "settings"),
        .init("⌘/", "show this shortcut sheet"),
    ].filter { $0.key != "⌃⌘1…3" || AppDelegate.filesTabModifiers(keys) != nil } }
}

struct ShortcutGroup: Identifiable {
    var title: String?
    let rows: [ShortcutRow]
    var id: String { title ?? rows.first?.id ?? "" }
}

struct ShortcutSheetStyle {
    let ink: Color
    let muted: Color
    let background: Color
    let colorScheme: ColorScheme
    let font: Font
    let keyFont: Font
}

/// The sheet ⌘/ opens: the shortcuts for where you are, then everything else under More.
struct ShortcutSheet: View {
    let style: ShortcutSheetStyle
    let primary: [ShortcutGroup]
    let more: [ShortcutGroup]

    var body: some View {
        HuggingWidth(maxWidth: 500) {
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    groups(primary)
                    if !more.isEmpty {
                        DisclosureGroup("More shortcuts") {
                            VStack(alignment: .leading, spacing: 9) { groups(more) }.padding(.top, 8)
                        }.padding(.top, 3)
                    }
                }.padding(12)
            }
        }.frame(maxHeight: 480)
            .fixedSize(horizontal: false, vertical: true)
            .font(style.font).foregroundStyle(style.muted)
            // On glass the popover's own system glass shows through.
            .background(LiquidGlassStore.shared.active ? Color.clear : style.background).preferredColorScheme(style.colorScheme)
    }

    /// A grid, so the key column takes its widest key and each explanation keeps to one line where it fits.
    private func groups(_ groups: [ShortcutGroup]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
            ForEach(groups) { group in
                if let title = group.title {
                    Text(title).foregroundStyle(style.ink).padding(.top, 6)
                }
                ForEach(group.rows) { row($0) }
            }
        }
    }

    private func row(_ row: ShortcutRow) -> some View {
        GridRow {
            Text(row.key).font(style.keyFont).foregroundStyle(style.ink).fixedSize()
            Text(row.explanation).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Sizes its only subview to the subview's ideal width, up to `maxWidth`: the sheet is as wide as its longest row, and
/// only a row longer than `maxWidth` wraps.
private struct HuggingWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let width = min(subview.sizeThatFits(.unspecified).width, maxWidth)
        return subview.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// The ⌘/ key chip: opens its sheet on click, from the Help menu, or after a short hover.
struct ShortcutSheetButton<Sheet: View>: View {
    @Binding var presented: Bool
    let keyFont: Font
    let ink: Color
    let muted: Color
    let label: String
    let identifier: String
    /// An SF Symbol in place of the ⌘/ chip (which moves to the help); on glass, shown as a GlassPanelControl.
    var symbol: String? = nil
    /// The chip's minimum square: the chat composer matches its paperclip and microphone.
    var side: CGFloat = 24
    /// While the sheet shows: the chip in this color with no fill (the sidebar's header controls, as GlassPanelControl);
    /// nil keeps it `ink` on its hover fill (the chat composer, in the chat theme's colors).
    var accent: Color? = nil
    @ViewBuilder let sheet: () -> Sheet
    @State private var hovering = false
    @State private var hoverFocus: (window: NSWindow, responder: NSResponder)?

    var body: some View {
        Button { hoverFocus = nil; presented.toggle() } label: {
            if let symbol, LiquidGlassStore.shared.active {
                Image(systemName: symbol).modifier(GlassPanelControl(active: presented))
            } else {
                Group {
                    if let symbol { Image(systemName: symbol) } else { Text("⌘/") }
                }.font(keyFont)
                    .frame(minWidth: side, minHeight: side)
                    .foregroundStyle(presented ? accent ?? ink : hovering ? ink : muted)
                    .background(hovering || (presented && accent == nil) ? ink.opacity(0.07) : .clear,
                                in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
            }
        }.buttonStyle(.plain)
            .help("Keyboard shortcuts · ⌘/")
            .accessibilityLabel(label).accessibilityIdentifier(identifier)
            .onHover { hovering = $0 }
            .task(id: hovering) {
                guard hovering, !presented else { return }
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                guard !presented else { return }
                if let window = NSApp.keyWindow, let responder = window.firstResponder {
                    hoverFocus = (window, responder)
                }
                presented = true
            }
            .popover(isPresented: $presented, arrowEdge: .top) {
                sheet().onAppear {
                    // Hover is a preview: AppKit must keep typing where it was
                    // instead of moving focus to the sheet's disclosure control.
                    if let hoverFocus {
                        DispatchQueue.main.async {
                            guard presented, hoverFocus.window.isVisible else { return }
                            hoverFocus.window.makeKey()
                            hoverFocus.window.makeFirstResponder(hoverFocus.responder)
                        }
                    }
                }
            }
            .onChange(of: presented) { _, visible in if !visible { hoverFocus = nil } }
    }
}

/// Outside chat: navigation first, window shortcuts under More.
struct WorkspaceShortcutSheet: View {
    @Environment(\.appTypography) private var typography

    var body: some View {
        ShortcutSheet(style: .init(ink: Chrome.ink, muted: Chrome.muted, background: Chrome.sidebar,
                                   colorScheme: Chrome.colorScheme, font: typography.font(.body),
                                   keyFont: typography.shortcut()),
                      primary: [.init(rows: ShortcutRow.navigation)],
                      more: [.init(rows: ShortcutRow.window)]
                        + (ShortcutRow.prefix.map { [.init(title: "Prefix keys", rows: ShortcutRow.prefixRows($0))] } ?? []))
            .accessibilityIdentifier("workspace-shortcut-sheet")
    }
}
