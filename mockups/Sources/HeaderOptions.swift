import SwiftUI

// X: the tab header's layout options (2026-10-30), over the Chat segment. X0 is today's; X1–X5 trade the back pill's
// label, the host disc and the ⋯ menu for the title's room; X6 swaps the rows: the switch goes up into the bar as
// glyphs, the title takes the row under it at the screen's width. The subtitle is the host and the folder's name only.

enum HeaderOption: Equatable { case today, menu, hostLeading, twoLineTitle, twoLineSmall, hostTrailing, switchInBar, twoLineTop, adaptive, discBadge(String) }

struct HeaderOptionScreen: View {
    let option: HeaderOption
    var title = "Chat mode narrow pane footer fix"

    var body: some View {
        NavigationStack {
            Transcript()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.canvas)
                .safeAreaBar(edge: .top, spacing: 0) {
                    if option == .switchInBar {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.headline).lineLimit(2)
                            HostPath(host: "mini", path: "dispatch", mono: false)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 10)
                    } else {
                        SegmentCapsule(selected: 1, badge: 2).padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10)
                    }
                }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .safeAreaBar(edge: .bottom) { Composer() }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { OptionHeader(option: option, title: title) }
        }
    }
}

private struct OptionHeader: ToolbarContent {
    let option: HeaderOption
    let title: String

    /// The bar's width less its 20-point margins and the trailing item with the bar's 12-point gap before it.
    private var leadingWidth: CGFloat {
        let screen = UIScreen.main.bounds.width - 40
        switch option {
        case .today: return screen - (44 + 8 + 44) - 12
        case .menu, .twoLineTitle, .twoLineSmall, .hostTrailing, .twoLineTop: return screen - 44 - 12
        case .hostLeading: return screen - 12
        case .switchInBar: return 44
        case .adaptive: return screen - HostMenuPill.width - 12
        case .discBadge: return screen - 44 - 12
        }
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 12) {
                switch option {
                case .today:
                    BackPill(count: nil, title: "dispatch")
                case .hostLeading:
                    HStack(spacing: 8) { ChevronBack(); HostDisc() }
                default:
                    ChevronBack()
                }
                if option != .switchInBar { titleColumn.padding(.leading, 4) }
            }
            .frame(width: leadingWidth, alignment: .leading)
        }
        .sharedBackgroundVisibility(.hidden)
        if option == .switchInBar {
            ToolbarItem(placement: .principal) { GlyphSwitch(selected: 1, badge: 2) }
                .sharedBackgroundVisibility(.hidden)
        }
        ToolbarItem(placement: .topBarTrailing) {
            switch option {
            case .today: HStack(spacing: 8) { MenuDisc(); HostDisc() }
            case .menu, .twoLineTop: MenuDisc()
            case .adaptive: HostMenuPill()
            case .discBadge(let symbol): HostMenuDisc(badge: symbol)
            case .hostLeading: EmptyView()
            default: HostDisc()
            }
        }
        .sharedBackgroundVisibility(.hidden)
    }

    @ViewBuilder private var titleColumn: some View {
        switch option {
        case .twoLineTitle:
            Text(title).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        case .twoLineSmall:
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        case .adaptive, .discBadge:
            // Two lines' height, top-aligned: a title that fits on one line keeps host · folder under it; a longer
            // one takes both lines and the host stays on the pill.
            ViewThatFits(in: .horizontal) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    HostPath(host: "mini", path: "dispatch", mono: false).font(.caption).foregroundStyle(.secondary)
                }
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(height: 40, alignment: .topLeading)
        case .twoLineTop:
            // Two lines' height whatever the title's length: a short title sits on the first line.
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
        default:
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).lineLimit(1)
                Group {
                    if option == .today {
                        HostPath(host: "mini", path: "~/De…r/dispatch")
                    } else {
                        HostPath(host: "mini", path: "dispatch", mono: false)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// The back button without a label: the iOS 26 system's chevron circle.
private struct ChevronBack: View {
    var body: some View {
        Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.dispatchPink)
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: Circle())
    }
}

/// The host's glyph with a chevron: a pull-down button by its shape (the system's menu buttons carry the chevron),
/// holding the conversation's actions, the tab's and the host's.
private struct HostMenuPill: View {
    static let width: CGFloat = 68
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "apple.logo").font(.system(size: 20)).foregroundStyle(hostTint)
            Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
        }
        .frame(width: Self.width, height: 44)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

/// The host disc as a menu button: a small badge on its lower trailing edge, as on an avatar that opens a menu.
private struct HostMenuDisc: View {
    let badge: String
    var body: some View {
        Image(systemName: "apple.logo").font(.system(size: 20)).foregroundStyle(hostTint)
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: Circle())
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: badge).font(.system(size: 8, weight: .heavy)).foregroundStyle(.primary)
                    .frame(width: 17, height: 17)
                    .background(Color(white: 0.28), in: Circle())
                    .overlay { Circle().stroke(Color.canvas, lineWidth: 2) }
                    .offset(x: 2, y: 2)
            }
    }
}

/// The conversation's ⋯ menu.
private struct MenuDisc: View {
    var body: some View {
        Image(systemName: "ellipsis").font(.body.weight(.semibold))
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: Circle())
    }
}

/// Terminal · Chat · Files as glyphs in the bar (the Duo header's switch), the Files badge on its glyph's corner.
private struct GlyphSwitch: View {
    let selected: Int
    var badge: Int? = nil
    private let symbols = ["apple.terminal", "text.bubble", "folder"]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { i, symbol in
                Image(systemName: symbol).font(.body.weight(.medium))
                    .frame(width: 52, height: 40)
                    .background { if i == selected { Capsule().fill(Color.lens) } }
                    .overlay(alignment: .topTrailing) {
                        if i == 2, let badge {
                            Text("\(badge)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                .frame(minWidth: 16, minHeight: 16).background(Color.stateUnread, in: Capsule())
                                .offset(x: -6, y: 2)
                        }
                    }
            }
        }
        .padding(2)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}
