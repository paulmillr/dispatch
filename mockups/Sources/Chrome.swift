import SwiftUI

// Replicas of the phone app's tab chrome (TabsChrome.swift, TabScreen.swift) with static data.

let hostTint = Color(red: 0x7E / 255, green: 0xA6 / 255, blue: 0xC9 / 255)

/// The back pill: chevron plus the needs-you badge, or a title.
struct BackPill: View {
    var count: Int? = 2
    var title: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.dispatchPink)
            if let title {
                Text(title).font(.body).foregroundStyle(Color.dispatchPink)
            } else if let count {
                Text("\(count)").font(.subheadline.weight(.semibold)).foregroundStyle(Color.onAccent)
                    .frame(width: 26, height: 26).background(Color.dispatchPink, in: Circle())
            }
        }
        .padding(.leading, 14).padding(.trailing, title == nil ? 9 : 16)
        .frame(height: 44)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

struct HostDisc: View {
    var body: some View {
        Image(systemName: "apple.logo").font(.system(size: 22)).foregroundStyle(hostTint)
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: Circle())
    }
}

/// host · path, the host in its tint.
struct HostPath: View {
    let path: String
    var mono = true
    var body: some View {
        HStack(spacing: 0) {
            Text("mba2").foregroundStyle(hostTint)
            Text(" · ").foregroundStyle(.secondary)
            Text(path).foregroundStyle(.secondary).font(mono ? .system(.caption, design: .monospaced) : .caption)
        }
        .font(.caption)
        .lineLimit(1)
    }
}

/// A tab screen's bar: back pill, title + subtitle, host disc.
struct TabHeader: ToolbarContent {
    var title = "Sidebar theme toggle"
    var subtitle: AnyView
    var back: BackPill = BackPill()
    var trailing: AnyView = AnyView(HostDisc())
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 12) {
                back
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline).lineLimit(1)
                    subtitle.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.leading, 4)
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
