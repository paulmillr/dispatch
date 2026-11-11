import SwiftUI

// Replicas of the phone app's tab chrome (TabsChrome.swift, TabScreen.swift) with static data.

let hostTint = Color(red: 0x7E / 255, green: 0xA6 / 255, blue: 0xC9 / 255)

/// Back. A tab's (X9b, `TabsBackDisc`): the chevron alone on a 44-point glass disc, how many conversations need the
/// user as a pink badge on its corner. A pushed screen's (`TabsBackPill`): the chevron and the previous screen's title.
struct BackPill: View {
    var count: Int? = 2
    var title: String? = nil
    var body: some View {
        if let title {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 19, weight: .medium)).frame(width: 11)
                Text(title).font(.body).lineLimit(1)
            }
            .foregroundStyle(Color.dispatchPink)
            .padding(.leading, 12).padding(.trailing, 16)
            .frame(height: 44)
            .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.dispatchPink)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: Circle())
                .overlay(alignment: .topTrailing) {
                    if let count, count > 0 { CountBadge(label: "\(count)").offset(x: 6, y: -4) }
                }
        }
    }
}

/// The needs-you count (`TabsCountBadge`): white on pink.
struct CountBadge: View {
    let label: String
    var body: some View {
        Text(label).font(.footnote.weight(.bold)).monospacedDigit()
            .foregroundStyle(Color.onAccent)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(Color.dispatchPink, in: Capsule())
    }
}

struct HostDisc: View {
    var body: some View {
        Image(systemName: "apple.logo").font(.system(size: 22)).foregroundStyle(hostTint)
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: Circle())
    }
}

/// A tab's menu on the phone (X9b, `TabHeaderMenu`): the host disc with a ⋯ badge on its lower trailing edge. It holds
/// the conversation's items on Chat, the tab's and the host's.
struct TabMenuDisc: View {
    var body: some View {
        HostDisc()
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "ellipsis").font(.system(size: 8, weight: .heavy)).foregroundStyle(.primary)
                    .frame(width: 17, height: 17)
                    .background(Color(uiColor: .systemGray4), in: Circle())
                    .overlay { Circle().stroke(Color.canvas, lineWidth: 2) }
                    .offset(x: 2, y: 2)
            }
    }
}

/// A tab's subtitle on the phone (X9b): host · folder, and the shell's name in Terminal ("mba2 · web · pnpm").
struct TabSubtitle: View {
    var host = "mba2"
    var folder = "web"
    var shell: String? = nil
    var body: some View {
        HStack(spacing: 0) {
            Text(host).foregroundStyle(hostTint)
            Text(" · " + folder + (shell.map { " · " + $0 } ?? "")).foregroundStyle(.secondary)
        }
        .font(.caption)
        .lineLimit(1)
    }
}

/// host · path, the host in its tint.
struct HostPath: View {
    var host = "mba2"
    let path: String
    var mono = true
    var body: some View {
        HStack(spacing: 0) {
            Text(host).foregroundStyle(hostTint)
            Text(" · ").foregroundStyle(.secondary)
            Text(path).foregroundStyle(.secondary).font(mono ? .system(.caption, design: .monospaced) : .caption)
        }
        .font(.caption)
        .lineLimit(1)
    }
}

/// A tab screen's bar. A tab (X9b): Back with the needs-you badge, the title block (subheadline semibold, two lines
/// tall: host · folder under a title that fits one line, else the title on both), the tab's menu disc. A pushed screen:
/// the back pill with its title, the title over its subtitle, the screen's control.
struct TabHeader: ToolbarContent {
    var title = "Sidebar theme toggle"
    var subtitle: AnyView = AnyView(TabSubtitle())
    var back: BackPill = BackPill()
    var trailing: AnyView = AnyView(TabMenuDisc())
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 12) {
                back
                if back.title == nil {
                    ViewThatFits(in: .horizontal) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).lineLimit(1)
                            subtitle.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(title).lineLimit(2, reservesSpace: true).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 40, alignment: .topLeading)
                    .padding(.leading, 4)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.headline).lineLimit(1)
                        subtitle.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
            }
            .frame(width: 402 - 52 - 44, alignment: .leading)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .topBarTrailing) { trailing }.sharedBackgroundVisibility(.hidden)
    }
}

/// A round 34 pt glass button for the mode bar.
struct BarButton: View {
    let symbol: String
    var tinted = false
    var body: some View {
        Image(systemName: symbol).font(.subheadline.weight(.semibold))
            .foregroundStyle(tinted ? Color.onAccent : .primary)
            .frame(width: 34, height: 34)
            .glassEffect(tinted ? .regular.tint(.dispatchPink).interactive() : .regular.interactive(), in: Circle())
    }
}

/// A pushed screen's shell: back pill with its title, the screen's title and subtitle.
struct PushedShell<Content: View, Subtitle: View, Trailing: View>: View {
    let back: String
    let title: String
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content
    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.canvas)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { TabHeader(title: title, subtitle: AnyView(subtitle), back: BackPill(count: nil, title: back), trailing: AnyView(trailing)) }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var count: Int? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(title).textCase(.uppercase)
            if let count { Text("\(count)").foregroundStyle(.tertiary) }
        }
        .font(.footnote).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 6)
    }
}

struct Hairline: View {
    var inset: CGFloat = 16
    var body: some View { Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5).padding(.leading, inset) }
}

/// +n −m in the code palette.
struct Counts: View {
    let add: Int
    let del: Int
    var font: Font = .system(.subheadline, design: .monospaced)
    var body: some View {
        HStack(spacing: 6) {
            if add > 0 { Text("+\(add)").foregroundStyle(Color.added) }
            if del > 0 { Text("−\(del)").foregroundStyle(Color.destructive) }
        }
        .font(font)
    }
}

/// The git status letter in a small square.
struct StatusBadge: View {
    let status: String
    var color: Color {
        switch status { case "A", "?": .added; case "D": .destructive; case "R": .codeType; default: .caution }
    }
    var body: some View {
        Text(status).font(.system(.caption, design: .monospaced).weight(.bold))
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// A changed file's row (Review, a commit's files).
struct ChangeRow: View {
    let change: MockChange
    var showComments = true
    var last = false
    /// The row open beside the list (iPad).
    var selected = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                StatusBadge(status: change.status)
                HStack(spacing: 0) {
                    Text(change.folder).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    Text(change.name).lineLimit(1).fixedSize().layoutPriority(1)
                }
                .font(.subheadline)
                Spacer(minLength: 8)
                if showComments, change.comments > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "text.bubble").font(.caption2)
                        Text("\(change.comments)").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white).padding(.horizontal, 6).frame(height: 18)
                    .background(Color.stateUnread, in: Capsule())
                }
                Counts(add: change.add, del: change.del, font: .system(.caption, design: .monospaced))
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background { if selected { Color.lens } }
            if !last { Hairline(inset: 48) }
        }
    }
}

/// The app's own symbols (`dispatch.chat`, `.fill`, in the shared asset catalog), else the system's, as the app's
/// `Image(symbol:)` (Mobile/App/MobileChrome.swift).
extension Image {
    init(symbol name: String) {
        self = name.hasPrefix("dispatch.") ? Image(name) : Image(systemName: name)
    }
}
