import SwiftUI

/// The diff with Liquid Glass comments: code flows unbroken; a commented range is tinted with a floating glass chip in
/// the margin; the open comment is a glass card hovering over the code; selecting lines shows selection handles and a
/// glass composer rises from the bottom.
struct GlassDiffScreen: View {
    enum Mode { case comments, selecting, composing }
    var mode: Mode = .comments
    static let rowHeight: CGFloat = 20
    static let cardRoom: CGFloat = 140
    private let lines = MockGit.sidebarDiff
    private var top: CGFloat { 6 }

    func y(ofNew line: Int) -> CGFloat {
        let index = lines.firstIndex { $0.new == line } ?? 0
        let shift: CGFloat = mode == .comments && line > 42 ? Self.cardRoom : 0
        return top + CGFloat(index) * Self.rowHeight + shift
    }

    var body: some View {
        PushedShell(back: "Review", title: "Sidebar.tsx") {
            HStack(spacing: 6) {
                Text("src/components").font(.system(.caption, design: .monospaced))
                Text("·")
                Text("M").font(.system(.caption, design: .monospaced).weight(.bold)).foregroundStyle(Color.caution)
                Counts(add: 14, del: 6, font: .system(.caption, design: .monospaced))
            }
        } trailing: {
            Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: Circle())
        } content: { pane() }
    }

    /// The diff itself: the pushed screen's content with its bottom bar, and a pane beside the list on an iPad
    /// (no bottom bar: the picker and Comment sit in the pane's header; the card at most `cardWidth`).
    func pane(bottomBar: Bool = true, cardWidth: CGFloat? = nil) -> some View {
            ScrollView {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(lines) { line in
                            DiffRow(line: line, selected: false)
                                .overlay { rangeTint(line) }
                            if mode == .comments, line.new == 42 { Color.clear.frame(height: Self.cardRoom) }
                        }
                        Color.clear.frame(height: 160)
                    }
                    .padding(.top, top)
                    GlassEffectContainer(spacing: 20) {
                        ZStack(alignment: .topLeading) {
                            // Comment chips in the margin, at the first line of each range.
                            chip(count: 1, at: y(ofNew: 42), open: mode == .comments)
                            if mode == .comments {
                                chip(count: 1, at: y(ofNew: 45), open: false)
                                openCard(at: y(ofNew: 42) + Self.rowHeight - 4, maxWidth: cardWidth)
                            }
                            if mode != .comments { handles }
                        }
                    }
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .safeAreaBar(edge: .bottom) { if bottomBar { bottom } }
    }

    /// The commented or selected lines: a tint and an accent at the leading edge.
    @ViewBuilder private func rangeTint(_ line: MockGit.Line) -> some View {
        let n = line.new ?? -1
        let commented = n == 42 || (mode == .comments && (45...48).contains(n))
        let selected = mode != .comments && (45...48).contains(n)
        if commented || selected {
            Rectangle().fill(Color.stateUnread.opacity(selected ? 0.22 : 0.12))
                .overlay(alignment: .leading) { if !selected { Rectangle().fill(Color.stateUnread).frame(width: 3) } }
                .allowsHitTesting(false)
        }
    }

    /// A glass chip hugging the trailing edge: the bubble, the count.
    private func chip(count: Int, at y: CGFloat, open: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: open ? "text.bubble.fill" : "text.bubble").font(.caption.weight(.semibold))
            Text("\(count)").font(.caption.weight(.bold))
        }
        .foregroundStyle(open ? Color.onAccent : Color.stateUnread)
        .padding(.horizontal, 8).frame(height: 26)
        .glassEffect(open ? .regular.tint(Color.stateUnread).interactive() : .regular.interactive(), in: Capsule())
        .glassEffectID("chip-\(Int(y))", in: ns)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 6)
        .offset(y: y - 3)
    }

    @Namespace private var ns

    /// The open comment: a glass card over the code, under its range.
    private func openCard(at y: CGFloat, maxWidth: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill").foregroundStyle(Color.stateUnread)
                Text("Line 42").font(.subheadline.weight(.semibold))
                Text("· 2m").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            Text(MockGit.comments[0].text).font(.subheadline)
            HStack(spacing: 8) {
                Label("Edit", systemImage: "pencil").font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(Color.chipFill, in: Capsule())
                Label("Delete", systemImage: "trash").font(.caption.weight(.semibold)).foregroundStyle(Color.destructive)
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(Color.chipFill, in: Capsule())
                Spacer()
                Text("1 of 3").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    Image(systemName: "chevron.up").frame(width: 30, height: 30)
                    Image(systemName: "chevron.down").frame(width: 30, height: 30)
                }
                .font(.caption.weight(.bold))
                .background(Color.chipFill, in: Capsule())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .glassEffectID("card", in: ns)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .frame(maxWidth: maxWidth ?? .infinity)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .offset(y: y)
    }

    /// Text-selection style handles at the range's corners.
    private var handles: some View {
        let yTop = y(ofNew: 45), yBottom = y(ofNew: 48) + Self.rowHeight
        return ZStack(alignment: .topLeading) {
            Handle().offset(x: 4, y: yTop - 6)
            Handle(flipped: true).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 4).offset(y: yBottom - 28)
        }
    }

    @ViewBuilder private var bottom: some View {
        switch mode {
        case .comments:
            HStack(spacing: 10) {
                Picker("Show", selection: .constant(0)) {
                    Text("Diff").tag(0); Text("Source").tag(1)
                }
                .pickerStyle(.segmented).frame(width: 150)
                Spacer()
                Label("Comment", systemImage: "plus.bubble").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).frame(height: 44)
                    .glassEffect(.regular.interactive(), in: Capsule())
            }
            .padding(.horizontal, 16).padding(.bottom, 4)
        case .selecting:
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble.fill")
                    Text("Comment on 45–48")
                }
                .font(.body.weight(.semibold)).foregroundStyle(Color.onAccent)
                .padding(.horizontal, 18).frame(height: 50)
                .glassEffect(.regular.tint(.dispatchPink).interactive(), in: Capsule())
                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 50, height: 50)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .padding(.bottom, 8)
        case .composing:
            GlassComposer()
        }
    }
}

/// The selection handle: a dot and a stem, as the text selection's.
struct Handle: View {
    var flipped = false
    var body: some View {
        VStack(spacing: 0) {
            if !flipped { Circle().fill(Color.stateUnread).frame(width: 12, height: 12) }
            Rectangle().fill(Color.stateUnread).frame(width: 2.5, height: 22)
            if flipped { Circle().fill(Color.stateUnread).frame(width: 12, height: 12) }
        }
    }
}

/// The composer, risen from the bottom: the quoted range as a chip, the field, Send.
struct GlassComposer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble.fill").foregroundStyle(Color.stateUnread)
                    Text("Lines 45–48").font(.caption.weight(.semibold))
                    Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(Color.chipFill, in: Capsule())
                Text("<li key={space.id} className={s…").font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                Spacer()
            }
            HStack(alignment: .bottom, spacing: 10) {
                Text("Keep the old markup. The unread class belongs on the link, not the item, and `end` breaks nested routes.")
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(Color.onAccent)
                    .frame(width: 34, height: 34)
                    .background(Color.dispatchPink, in: Circle())
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 10).padding(.bottom, 6)
    }
}
