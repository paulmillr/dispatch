import SwiftUI

// The redesign's shared pieces (mockups/Sources/Chrome.swift): the round glass bar button, the agents' marks, the
// hairline, the counted section header, the +n −m counts, the git status letter and a changed file's row. Files,
// Review, Commits, Spaces and the iPad strip draw with these, so one look holds across them.

/// A round 34 point glass button for a mode's bar (search, the "…" menu, the filter): the symbol in the primary
/// label, or dark on the app tint when `tinted` (an active filter).
struct MobileBarButton: View {
    let symbol: String
    /// The accessibility label: what the button does ("Search", "More").
    let label: String
    var tinted = false
    let action: () -> Void

    static let size: CGFloat = 34

    var body: some View {
        Button(action: action) {
            MobileBarGlyph(symbol: symbol, tinted: tinted)
        }
        .buttonStyle(.plain)
        .glassEffect(tinted ? .regular.tint(.dispatchPink).interactive() : .regular.interactive(), in: Circle())
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
    }
}

/// The bar button's face without the button: a `Menu`'s label draws it in the same glass circle
/// (`.glassEffect(.regular.interactive(), in: Circle())` around it).
struct MobileBarGlyph: View {
    let symbol: String
    var tinted = false

    var body: some View {
        Image(systemName: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tinted ? Color.onAccent : Color.primary)
            .frame(width: MobileBarButton.size, height: MobileBarButton.size)
            .contentShape(Circle())
            // A bar's controls keep their size; the large content viewer shows the glyph at the larger sizes.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// A tab's mark (the mockups' Y5): the Chat segment's bubble for every agent's chat, the Terminal segment's glyph for a
/// tab without an agent, both secondary. The agent itself is not told apart: one monochrome mark for all of them.
/// `agent` is the helper's launch key (`claude`, `codex`, `pi`, or "agent"); nil draws the terminal.
struct AgentGlyph: View {
    let agent: String?
    var size: CGFloat = 18

    var body: some View {
        Image(symbol: agent == nil ? TabSegment.terminal.symbol : TabSegment.chat.symbol)
            .foregroundStyle(.secondary)
            .font(.system(size: size))
        .frame(width: size + 8)
        .accessibilityHidden(true)
    }
}

/// The app's own symbols, SF Symbol templates in the asset catalog named `dispatch.*` (Chat's capsule, `dispatch.chat`
/// and `.fill`), else the system's: a mode's `symbol` may be either.
extension Image {
    init(symbol name: String) {
        self = name.hasPrefix("dispatch.") ? Image(name) : Image(systemName: name)
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ title: String, symbol: String) {
        self.init { Text(title) } icon: { Image(symbol: symbol) }
    }
}

/// The separator between rows, inset from the leading edge (the system's separator colour, half a point).
struct MobileHairline: View {
    var inset: CGFloat = 16

    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(height: 0.5)
            .padding(.leading, inset)
            .accessibilityHidden(true)
    }
}

/// A list section's header with its count, as Review's STAGED 2 and the Spaces tree's groups draw it: the title in
/// secondary capitals and the count in tertiary, outside any card (16 in, 18 above, 6 below).
struct MobileCountedSectionHeader: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(title).textCase(.uppercase)
            if let count { Text("\(count)").foregroundStyle(.tertiary).monospacedDigit() }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// "+n −m" in the code palette: green additions, red deletions, either left out at zero.
struct MobileCounts: View {
    let added: Int
    let deleted: Int
    var font: Font = .system(.subheadline, design: .monospaced)

    var body: some View {
        HStack(spacing: 6) {
            if added > 0 { Text("+\(added)").foregroundStyle(Color.added) }
            if deleted > 0 { Text("−\(deleted)").foregroundStyle(Color.removed) }
        }
        .font(font)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(added: added, deleted: deleted))
    }

    static func spoken(added: Int, deleted: Int) -> String {
        [added > 0 ? "\(added) added" : nil, deleted > 0 ? "\(deleted) deleted" : nil].compactMap { $0 }.joined(separator: ", ")
    }
}

/// A file's git status as a letter in a small tinted square: A and ? green, D red, R purple, anything else (M, U, T,
/// C) amber.
struct GitStatusBadge: View {
    /// The porcelain letter: A, M, D, R, C, U, T or ?.
    let status: String

    static func color(_ status: String) -> Color {
        switch status {
        case "A", "?": .added
        case "D": .removed
        case "R": .codeType
        default: .caution
        }
    }

    static func spoken(_ status: String) -> String {
        switch status {
        case "A": "Added"
        case "?": "Untracked"
        case "D": "Deleted"
        case "R": "Renamed"
        case "C": "Copied"
        case "U": "Conflicted"
        case "T": "Type changed"
        default: "Modified"
        }
    }

    @ScaledMetric(relativeTo: .caption) private var side: CGFloat = 22

    var body: some View {
        let color = Self.color(status)
        Text(status)
            .font(.system(.caption, design: .monospaced).weight(.bold))
            .foregroundStyle(color)
            .frame(width: side, height: side)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel(Self.spoken(status))
    }
}

/// A changed file's row (Review, a commit's files): the status letter, the folder dimmed and truncated from its head
/// before the file name, the review comments' count, the +n −m counts and a chevron. `selected` lights it with the lens
/// (the row open beside the list, iPad). The caller puts it in a card and wraps it in its link or button.
struct MobileChangeRow: View {
    let status: String
    /// The path relative to the repository: "src/components/Sidebar.tsx".
    let path: String
    var added = 0
    var deleted = 0
    /// Review comments on the file; zero draws none.
    var comments = 0
    var last = false
    var selected = false

    /// "src/components/" and "Sidebar.tsx".
    static func split(_ path: String) -> (folder: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[...slash]), String(path[path.index(after: slash)...]))
    }

    var body: some View {
        let (folder, name) = Self.split(path)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                GitStatusBadge(status: status)
                HStack(spacing: 0) {
                    Text(folder).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    Text(name).lineLimit(1).layoutPriority(1)
                }
                .font(.subheadline)
                Spacer(minLength: 8)
                if comments > 0 { MobileCommentBadge(count: comments) }
                MobileCounts(added: added, deleted: deleted, font: .system(.caption, design: .monospaced))
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background { if selected { Color.lens } }
            .contentShape(Rectangle())
            if !last { MobileHairline(inset: 48) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(status: status, path: path, added: added, deleted: deleted, comments: comments))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    static func accessibilityLabel(status: String, path: String, added: Int, deleted: Int, comments: Int) -> String {
        let counts = MobileCounts.spoken(added: added, deleted: deleted)
        let notes = comments > 0 ? "\(comments) \(comments == 1 ? "comment" : "comments")" : ""
        return [path, GitStatusBadge.spoken(status), counts, notes].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// The review comments' count on a row: a bubble and the number, white on the unread blue.
struct MobileCommentBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "text.bubble").font(.caption2)
            Text("\(count)").font(.caption.weight(.semibold)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(minHeight: 18)
        .background(Color.stateUnread, in: Capsule())
        .accessibilityLabel("\(count) \(count == 1 ? "comment" : "comments")")
    }
}
