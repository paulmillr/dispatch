import SwiftUI

/// One key and what it does, for the ⌘/ shortcut sheets.
struct ShortcutRow: Identifiable {
    let key: String
    let explanation: String
    var id: String { key + " " + explanation }

    init(_ key: String, _ explanation: String) { self.key = key; self.explanation = explanation }

    /// What each digit group does; Settings › Keys describes its recorders the same way.
    static let tabDigits = "switch to tab (or pane when split)"
    static let spaceDigits = "switch to space"
    static let splitDigits = "splits: single / 2-column / 2 above / 2x2 grid"

    /// The digit chords lead, in Settings › Keys' order and following it; then stepping through tabs and spaces, and
    /// the prefix keys last.
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
            keys.shortcut(\.splits, "1…4").map { .init($0, splitDigits) },
            steps.tabs.map { .init(brackets($0), "tab scroll: previous / next") },
            steps.spaces.map { .init(brackets($0), "space scroll: previous / next") },
            .init("⌘\\", "show or hide the sidebar · also ⌃⌘S"),
            .init("⌃B …", "tmux or herdr prefix keys"),
        ]
        return rows.compactMap { $0 }
    }

    @MainActor static var window: [ShortcutRow] { [
        .init("⌘N / ⇧⌘N", "new space / new local space"),
        .init("⌘T", "new tab"),
        .init("⌘W / ⇧⌘W", "close tab / close space"),
        .init("⌘D / ⇧⌘D", "split right / split down"),
        .init("⌘J / ⇧⌘J", "notification scroll"),
        .init("⇧⌘C", "switch between terminal and chat"),
        .init("⌘K", "clear the terminal screen and scrollback"),
        .init("⌘F", "find · ⌘G / ⇧⌘G next / previous"),
        .init("⌘+ / ⌘- / ⌘0", "bigger / smaller / reset font size"),
        .init("⌃⌘F", "full screen"),
        .init("⌘,", "settings"),
        .init("⌘/", "show this shortcut sheet"),
    ] }
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
                    .frame(minWidth: 24, minHeight: 24)
                    .foregroundStyle(presented || hovering ? ink : muted)
                    .background(presented || hovering ? ink.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 4))
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
                                   colorScheme: Chrome.colorScheme, font: AppFont.ui(size: typography.size(offset: -1.5)),
                                   keyFont: typography.shortcut()),
                      primary: [.init(rows: ShortcutRow.navigation)],
                      more: [.init(rows: ShortcutRow.window)])
            .accessibilityIdentifier("workspace-shortcut-sheet")
    }
}
