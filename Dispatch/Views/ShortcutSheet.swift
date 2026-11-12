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

    /// What you reach for most, in groups the sheet sets apart: the digit chords, in Settings › Keyboard' order and
    /// following it; stepping through tabs, panes and spaces (⌃⇥ and search are under More); making, closing and
    /// splitting; the tab's modes and the sidebar; voice. A chord a row, so its modifiers and its key line up with the
    /// rows' around it (`ShortcutRow.chord`); the words are brief, so each row keeps to one line.
    @MainActor static var navigationGroups: [[ShortcutRow]] {
        let keys = KeyGroupsStore.shared.current, steps = keys.steps
        func brackets(_ modifiers: NSEvent.ModifierFlags) -> String { KeyGroups.symbols(modifiers) + "[ ]" }
        let groups: [[ShortcutRow?]] = [
            [
                // An unbound group has no shortcut, so no row.
                keys.shortcut(\.tabs, "1…9").map { .init($0, "tab, or pane when split · 9 the last") },
                keys.shortcut(\.spaces, "1…9").map { .init($0, "space · 9 the last") },
                // A layout's key is its pane count (`LayoutPreset.shortcutKey`).
                keys.shortcut(\.splits, "1…4, 6, 8").map { .init($0, "layout with that many panes") },
            ],
            [
                steps.tabs.map { .init(brackets($0), "previous / next tab") },
                .init(brackets(KeyGroups.paneStep), "previous / next pane"),
                steps.spaces.map { .init(brackets($0), "previous / next space") },
            ],
            [
                .init("⌘N", "new space"),
                .init("⇧⌘N", "new local space"),
                .init("⌘T", "new tab"),
                .init("⌘W", "close tab"),
                .init("⇧⌘W", "close space"),
                .init("⌘D", "split right"),
                .init("⇧⌘D", "split down"),
            ],
            [
                .init("⇧⌘C", "switch terminal / chat"),
                .init("⇧⌘F", "switch terminal / files"),
                .init("⌘\\", "show or hide the sidebar"),
                .init("⌃⌘S", "also"),
            ],
            [voiceNavigation],
        ]
        return groups.map { $0.compactMap { $0 } }.filter { !$0.isEmpty }
    }

    @MainActor static var navigation: [ShortcutRow] { Array(navigationGroups.joined()) }

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
            rows.append((key.symbol, .init("\(prefix) \(key.symbol)", "can't run “\(command)”")))
        }
        let sorted = rows.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map(\.row)
        let windows = digits.sorted()
        let window = windows.isEmpty ? [] : [ShortcutRow("\(prefix) \(windows.count > 1 ? "\(windows.first!)…\(windows.last!)" : windows[0])",
                                                         "window by its number")]
        return window + sorted + [.init("\(prefix) \(prefix)", "send \(prefix) to the program")]
    }

    /// Settings › Dictation › Navigate by voice, while dictation and its voice key are on: the key alone, the wake word
    /// in what to say.
    @MainActor static var voiceNavigation: ShortcutRow? {
        let store = DictationStore.shared
        guard let key = store.shortcut, store.navigation else { return nil }
        return .init(key.name, "say “\(store.wakeWord), …” then a space, tab or “back”")
    }

    @MainActor static var window: [ShortcutRow] { windowRows(KeyGroupsStore.shared.current) }
    @MainActor static var windowGroups: [[ShortcutRow]] { windowGroups(KeyGroupsStore.shared.current) }
    @MainActor static func windowRows(_ keys: KeyGroups) -> [ShortcutRow] { Array(windowGroups(keys).joined()) }

    /// Under More, in groups: getting around; the modes and Review; the terminal; the window and app. ⌃⌘1…5 are the tab's
    /// modes unless a Settings › Keyboard group takes ⌃⌘ digits (AppDelegate.modeModifiers). Worded as the menus are.
    @MainActor static func windowGroups(_ keys: KeyGroups) -> [[ShortcutRow]] { [
        [
            .init("⌃⇥", "next tab"),
            .init("⌃⇧⇥", "previous tab"),
            .init("⌘P", "search spaces"),
            .init("⌘J", "next attention"),
            .init("⇧⌘J", "previous attention"),
        ],
        [
            .init("⌃⌘1…5", "terminal / chat / files / review / commits"),
            .init("⇧⌘U / ⇧⌘L", "files on Review / Commits"),
            .init("⌥⌘P", "show or hide the files preview"),
            .init("⌥↓ / ⌥↑", "next / previous review comment"),
            .init("⇧⌘⏎", "create the review"),
        ].filter { $0.key != "⌃⌘1…5" || AppDelegate.modeModifiers(keys) != nil },
        [
            .init("⌘F", "find"),
            .init("⌘G", "next match"),
            .init("⇧⌘G", "previous match"),
            .init("⌘K", "clear screen and scrollback"),
            .init("⌘+ / ⌘- / ⌘0", "bigger / smaller / reset font"),
            .init("⌘-click", "open a link · hold ⌘ to see where"),
            .init("right-click", "copy, paste, split · ⌃-click too"),
        ],
        [
            .init("⌥⌘W", "close window and quit"),
            .init("⌃⌘F", "full screen"),
            .init("⌘,", "settings"),
            .init("⌘/", "this sheet"),
        ],
    ] }

    /// The key split for the sheet's two key columns: the modifiers (or a prefix key, as "⌃B" of "⌃B c"), drawn flush
    /// against the key, and the key, so ⌘ and the keys after it stand in one column down the sheet. Chords that share
    /// their modifiers keep them once ("⌥↓ / ⌥↑" is ⌥ and "↓ / ↑"); nil for a key the columns cannot split (chords with
    /// different modifiers, as "⌥⏎ / ⇧⏎"), which spans both. A key with no modifiers ("right-click", "⌘-click", "⎋
    /// twice") is all key; a side's modifier ("right ⌘") all modifiers.
    var chord: (modifiers: String, key: String)? {
        func modifiers(_ part: Substring) -> Substring { part.prefix { ShortcutKeyStyle.modifierNames[$0] != nil } }
        let parts = key.components(separatedBy: " / ").map { Substring($0) }
        if parts.count == 1 {
            // A held modifier named by its side ("right ⌘"): all in the modifiers' column, so its ⌘ stands under the
            // others.
            if let last = key.last, ShortcutKeyStyle.modifierNames[last] != nil, key.contains(" ") { return (key, "") }
            // A prefix key and what follows it: "⌃B c", "⌃B 0…9"; one modified key before the space, so not "⌘[ ]" or
            // "⌃1…4, 6, 8".
            if !key.hasSuffix("[ ]"), let space = key.firstIndex(of: " ") {
                let first = key[..<space]
                if !modifiers(first).isEmpty, first.count - modifiers(first).count == 1 {
                    return (String(first), String(key[key.index(after: space)...]))
                }
            }
        }
        var shared: Substring?, keys: [Substring] = []
        for part in parts {
            let leading = modifiers(part), rest = part.dropFirst(leading.count)
            // "⌘-click" is a word, not ⌘ and "-click".
            if rest.isEmpty || (rest.count > 1 && rest.first == "-" && rest.dropFirst().first?.isLetter == true) {
                return parts.count == 1 ? ("", key) : nil
            }
            if let shared, shared != leading { return nil }
            shared = leading
            keys.append(rest)
        }
        return (String(shared ?? ""), keys.joined(separator: " / "))
    }
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

/// How the ⌘/ sheets write keys: as macOS does (⇧⌘C) or by name (shift+cmd+C), chosen in the sheet and kept across
/// launches (`UserDefaults.app`, never under test).
@MainActor @Observable final class ShortcutKeyStyle {
    static let shared = ShortcutKeyStyle()
    private static let defaultsKey = "ShortcutSheetKeyNames"
    var names = UserDefaults.app?.bool(forKey: ShortcutKeyStyle.defaultsKey) ?? false {
        didSet { UserDefaults.app?.set(names, forKey: Self.defaultsKey) }
    }

    func text(_ text: String) -> String { names ? Self.named(text) : text }

    nonisolated static let modifierNames: [Character: String] = ["⌃": "ctrl", "⌥": "opt", "⇧": "shift", "⌘": "cmd"]
    nonisolated static let keyNames: [Character: String] = [
        "⏎": "return", "⇥": "tab", "⌫": "delete", "⌦": "fwd delete", "⎋": "esc", "␣": "space",
        "↑": "up", "↓": "down", "←": "left", "→": "right",
    ]

    /// Every key symbol in `text` by name: a modifier joins the key after it with "+" ("⇧⌘C" is "shift+cmd+C", "⌘-" is
    /// "cmd+-"), but keeps a word's hyphen ("⌘-click" is "cmd-click") and a sentence's space ("hold ⌘ to" is "hold cmd
    /// to"); keys side by side ("↑↓") are spaced apart. Everything else is kept as it is.
    nonisolated static func named(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        for (index, character) in characters.enumerated() {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if let name = modifierNames[character] {
                result += name
                guard let next, next != " " else { continue }
                if next == "-", index + 2 < characters.count, characters[index + 2].isLetter { continue }
                result += "+"
            } else if let name = keyNames[character] {
                result += name
                if let next, keyNames[next] != nil || modifierNames[next] != nil { result += " " }
            } else {
                result.append(character)
            }
        }
        return result
    }
}

/// The sheet ⌘/ opens: the shortcuts for where you are, then everything else under More, and beside More the choice
/// between keys as symbols and by name (ShortcutKeyStyle).
struct ShortcutSheet: View {
    let style: ShortcutSheetStyle
    let primary: [ShortcutGroup]
    let more: [ShortcutGroup]
    @State private var expanded = false
    private var keys: ShortcutKeyStyle { .shared }

    var body: some View {
        // Names are wider than symbols: the sheet widens with them before any row wraps.
        HuggingWidth(maxWidth: keys.names ? 620 : 500) {
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    groups(primary)
                    footer.padding(.top, 3)
                    if expanded && !more.isEmpty { groups(more) }
                }.padding(12)
            }
        }.frame(maxHeight: 480)
            .fixedSize(horizontal: false, vertical: true)
            .font(style.font).foregroundStyle(style.muted)
            // On glass the popover's own system glass shows through.
            .background(LiquidGlassStore.shared.active ? Color.clear : style.background).preferredColorScheme(style.colorScheme)
    }

    /// More shortcuts' disclosure, and at the end the keys' style.
    private var footer: some View {
        HStack(spacing: 12) {
            if !more.isEmpty {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text("More shortcuts")
                    }.foregroundStyle(style.ink).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("More shortcuts").accessibilityValue(expanded ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("shortcut-sheet-more")
            }
            Spacer(minLength: 0)
            Picker("Keys", selection: Binding(get: { keys.names }, set: { keys.names = $0 })) {
                Text("⌘ ⇧").tag(false)
                Text("cmd shift").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            .help("Keys as symbols or by name")
            .accessibilityIdentifier("shortcut-sheet-key-style")
        }
    }

    /// A grid: the modifiers flush right against the key (ShortcutRow.chord), the keys in a column after them, then the
    /// explanations, each on one line where it fits. Untitled groups after the first stand a little apart.
    private func groups(_ groups: [ShortcutGroup]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 7) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if let title = group.title {
                    Text(title).foregroundStyle(style.ink).padding(.top, 6)
                } else if index > 0 {
                    Color.clear.frame(height: 2).gridCellUnsizedAxes(.horizontal)
                }
                ForEach(group.rows) { row($0) }
            }
        }
    }

    private func row(_ row: ShortcutRow) -> some View {
        GridRow {
            if let chord = row.chord {
                Text(modifiers(chord.modifiers)).font(style.keyFont).foregroundStyle(style.ink).fixedSize()
                    .gridColumnAlignment(.trailing)
                Text(keys.text(chord.key)).font(style.keyFont).foregroundStyle(style.ink).fixedSize()
            } else {
                Text(keys.text(row.key)).font(style.keyFont).foregroundStyle(style.ink).fixedSize()
                    .gridCellColumns(2)
            }
            Text(keys.text(row.explanation)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)
        }
    }

    /// The modifier column: by name joined by spaces ("shift cmd"), no "+" (the column is the join); a prefix key as
    /// written elsewhere ("ctrl+B").
    private func modifiers(_ text: String) -> String {
        guard keys.names else { return text }
        if text.allSatisfy({ ShortcutKeyStyle.modifierNames[$0] != nil }) {
            return text.compactMap { ShortcutKeyStyle.modifierNames[$0] }.joined(separator: " ")
        }
        return ShortcutKeyStyle.named(text)
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

/// The ⌘/ key chip: opens its sheet on click or from the Help menu (⌘/); hovering only lights it.
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

    var body: some View {
        Button { presented.toggle() } label: {
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
            .popover(isPresented: $presented, arrowEdge: .top) { sheet() }
    }
}

/// Outside chat: navigation first, window shortcuts under More.
struct WorkspaceShortcutSheet: View {
    @Environment(\.appTypography) private var typography

    var body: some View {
        ShortcutSheet(style: .init(ink: Chrome.ink, muted: Chrome.muted, background: Chrome.sidebar,
                                   colorScheme: Chrome.colorScheme, font: typography.font(.body),
                                   keyFont: typography.shortcut()),
                      primary: ShortcutRow.navigationGroups.map { .init(rows: $0) },
                      more: ShortcutRow.windowGroups.map { .init(rows: $0) }
                        + (ShortcutRow.prefix.map { [.init(title: "Prefix keys", rows: ShortcutRow.prefixRows($0))] } ?? []))
            .accessibilityIdentifier("workspace-shortcut-sheet")
    }
}
