import SwiftUI

// Exploration: the ⌘/ sheet's keys in columns, so every modifier and every key stands where the same one stands in the
// rows above and below it. Today a row's key is one string ("⇧⌘1…9", "⌘N / ⇧⌘N"), so nothing lines up. Each layout
// below splits a chord into its modifiers and its key, gives a pair ("⌘N / ⇧⌘N") a row each, keeps "[ ]" as one key,
// and gaps the rows into groups (switch, step, make and close, modes and sidebar, voice).

enum ShortcutColumns {
    static let screens: [Screen] = [
        Screen("S1-shortcut-columns", group: "shortcuts", "The ⌘/ sheet's keys in columns: three layouts beside today's, symbols and names") {
            board {
                HStack(alignment: .top, spacing: 28) {
                    tile("Now", "One string per key: nothing lines up.") { Card(layout: .now, names: false) }
                    tile("A · Slots", "A column per modifier, in macOS's order ⌃ ⌥ ⇧ ⌘; then the key.") { Card(layout: .slots, names: false) }
                    tile("B · Flush", "Modifiers right-aligned against the key column; ⌘ always lands in one place.") { Card(layout: .flush, names: false) }
                    tile("C · Keycaps", "B, each key on a keycap.") { Card(layout: .keycaps, names: false) }
                }
                HStack(alignment: .top, spacing: 28) {
                    tile("Now, names", "shift+cmd+1…9") { Card(layout: .now, names: true) }
                    tile("A · Slots, names", "ctrl opt shift cmd columns.") { Card(layout: .slots, names: true) }
                    tile("B · Flush, names", "No “+”: the space is the join.") { Card(layout: .flush, names: true) }
                    tile("C · Keycaps, names", "A keycap per word.") { Card(layout: .keycaps, names: true) }
                }
            }
        },
    ]

    enum Layout { case now, slots, flush, keycaps }

    enum Mod: Int, CaseIterable {
        case ctrl, opt, shift, cmd
        var symbol: String { ["⌃", "⌥", "⇧", "⌘"][rawValue] }
        var name: String { ["ctrl", "opt", "shift", "cmd"][rawValue] }
    }

    struct Row {
        var mods: [Mod]
        var key: String
        var keyName: String? = nil
        var text: String
        /// A second chord for the row above's action, muted.
        var also = false
        /// Today's string for the row, and whether today folds it into the row above.
        var now: String? = nil
    }

    static let groups: [[Row]] = [
        [
            Row(mods: [.cmd], key: "1…9", text: "tab, or pane when split · 9 the last", now: "⌘1…9"),
            Row(mods: [.shift, .cmd], key: "1…9", text: "space · 9 the last", now: "⇧⌘1…9"),
            Row(mods: [.ctrl], key: "1…4, 6, 8", text: "layout with that many panes", now: "⌃1…4, 6, 8"),
        ],
        [
            Row(mods: [.cmd], key: "[ ]", text: "previous / next tab", now: "⌘[ / ⌘]"),
            Row(mods: [.opt, .cmd], key: "[ ]", text: "previous / next pane", now: "⌥⌘[ / ⌥⌘]"),
            Row(mods: [.shift, .cmd], key: "[ ]", text: "previous / next space", now: "⇧⌘[ / ⇧⌘]"),
        ],
        [
            Row(mods: [.cmd], key: "N", text: "new space", now: "⌘N / ⇧⌘N"),
            Row(mods: [.shift, .cmd], key: "N", text: "new local space"),
            Row(mods: [.cmd], key: "T", text: "new tab", now: "⌘T"),
            Row(mods: [.cmd], key: "W", text: "close tab", now: "⌘W / ⇧⌘W"),
            Row(mods: [.shift, .cmd], key: "W", text: "close space"),
            Row(mods: [.cmd], key: "D", text: "split right", now: "⌘D / ⇧⌘D"),
            Row(mods: [.shift, .cmd], key: "D", text: "split down"),
        ],
        [
            Row(mods: [.shift, .cmd], key: "C", text: "switch terminal / chat", now: "⇧⌘C"),
            Row(mods: [.shift, .cmd], key: "F", text: "switch terminal / files", now: "⇧⌘F"),
            Row(mods: [.cmd], key: "\\", text: "show or hide the sidebar", now: "⌘\\ / ⌃⌘S"),
            Row(mods: [.ctrl, .cmd], key: "S", text: "also", also: true),
        ],
        [
            Row(mods: [], key: "right ⌘", keyName: "right cmd", text: "say “Dispatch, …” then a space, tab or “back”", now: "right ⌘"),
        ],
    ]

    // MARK: The sheet

    struct Card: View {
        let layout: Layout
        let names: Bool

        private var colors: ChatColors { .current }
        private var keyFont: Font { .system(size: 13 * ChatType.scale, weight: .medium, design: .monospaced) }
        private var textFont: Font { ChatType.font(13) }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                switch layout {
                case .now: now
                case .slots: slots
                case .flush, .keycaps: flush(caps: layout == .keycaps)
                }
                footer.padding(.top, 4)
            }
            .font(textFont).foregroundStyle(colors.muted)
            .padding(12)
            .fixedSize()
            .background(ModelLadder.PopoverCard(arrow: nil, lifted: false))
        }

        private func named(_ text: String) -> String {
            guard names else { return text }
            var out = text
            for mod in Mod.allCases { out = out.replacingOccurrences(of: mod.symbol, with: mod.name + "+") }
            out = out.replacingOccurrences(of: "+ ", with: " ")
            return out.hasSuffix("+") ? String(out.dropLast()) : out
        }

        private func keyText(_ row: Row) -> String { names ? row.keyName ?? row.key : row.key }

        // Today: one string per row, pairs folded.
        private var now: some View {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
                ForEach(Array(groups.joined().enumerated()), id: \.offset) { _, row in
                    if let key = row.now {
                        GridRow {
                            Text(named(key)).font(keyFont).foregroundStyle(colors.ink)
                            Text(nowText(row))
                        }
                    }
                }
            }
        }

        private func nowText(_ row: Row) -> String {
            switch row.now {
            case "⌘N / ⇧⌘N": "new space / new local space"
            case "⌘W / ⇧⌘W": "close tab / close space"
            case "⌘D / ⇧⌘D": "split right / split down"
            default: row.text
            }
        }

        // A · a column per modifier.
        private var slots: some View {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: names ? 7 : 5, verticalSpacing: 7) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { gap(columns: 6) }
                    ForEach(Array(group.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Mod.allCases, id: \.self) { mod in
                                Text(row.mods.contains(mod) ? (names ? mod.name : mod.symbol) : "")
                                    .font(keyFont).foregroundStyle(row.also ? colors.muted : colors.ink)
                                    .gridColumnAlignment(.center)
                            }
                            Text(keyText(row)).font(keyFont).foregroundStyle(row.also ? colors.muted : colors.ink)
                                .padding(.leading, 4)
                            text(row).padding(.leading, 8)
                        }
                    }
                }
            }
        }

        // B and C · modifiers flush right, the key column after them.
        private func flush(caps: Bool) -> some View {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: caps ? 6 : 8, verticalSpacing: caps ? 6 : 7) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { gap(columns: 3) }
                    ForEach(Array(group.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            HStack(spacing: caps ? 3 : (names ? 6 : 2)) {
                                ForEach(row.mods, id: \.self) { mod in
                                    cap(names ? mod.name : mod.symbol, caps: caps, muted: row.also)
                                }
                            }
                            .gridColumnAlignment(.trailing)
                            HStack(spacing: 3) {
                                if caps && row.key == "[ ]" {
                                    cap("[", caps: true, muted: row.also); cap("]", caps: true, muted: row.also)
                                } else {
                                    cap(keyText(row), caps: caps, muted: row.also)
                                }
                            }
                            text(row).padding(.leading, 8)
                        }
                    }
                }
            }
        }

        private func cap(_ label: String, caps: Bool, muted: Bool) -> some View {
            Text(label).font(caps ? .system(size: 12 * ChatType.scale, weight: .medium, design: names ? .rounded : .monospaced) : keyFont)
                .foregroundStyle(muted ? colors.muted : colors.ink)
                .padding(.horizontal, caps ? 5 : 0).padding(.vertical, caps ? 1.5 : 0)
                .frame(minWidth: caps ? 20 : nil)
                .background {
                    if caps {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(colors.ink.opacity(0.08))
                            .overlay(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(colors.ink.opacity(0.12), lineWidth: 0.5)
                            }
                    }
                }
        }

        private func text(_ row: Row) -> some View {
            Text(row.text).foregroundStyle(row.also ? colors.muted.opacity(0.7) : colors.muted)
        }

        private func gap(columns: Int) -> some View {
            GridRow { Color.clear.frame(height: 2).gridCellColumns(columns) }
        }

        private var footer: some View {
            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    Text("More shortcuts")
                }.foregroundStyle(colors.ink)
                Spacer(minLength: 0)
                Picker("Keys", selection: .constant(names)) {
                    Text("⌘ ⇧").tag(false)
                    Text("cmd shift").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            }
        }
    }

    // MARK: The board

    @MainActor private static func board(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 36) { content() }
            .padding(32)
            .background(ChatColors.current.terminal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @MainActor private static func tile(_ title: String, _ note: String, @ViewBuilder _ content: () -> some View) -> some View {
        let colors = ChatColors.current
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.ink)
                Text(note).font(.system(size: 11.5)).foregroundStyle(colors.muted)
                    .lineLimit(2, reservesSpace: true).frame(maxWidth: 300, alignment: .leading)
            }
            content()
        }
        .fixedSize()
    }
}
